//! The two media senders share one reader of the negotiated feedback stream.
use anyhow::{Context, Result, ensure};
use std::{collections::BTreeMap, sync::{Arc, Mutex}};
use tokio::{io::{AsyncRead, AsyncReadExt}, sync::oneshot};
use viewflow_protocol::AtlasFrame;
use crate::atlas_feedback::{AtlasFrameDisposition, RECORD_BYTES};

type Reply = oneshot::Sender<Result<AtlasFrameDisposition>>;
#[derive(Default)]
struct State {
    pending: BTreeMap<u64, (AtlasFrame, Reply)>,
    closed: Option<String>,
}
pub(crate) struct AtlasActivityFeedback {
    state: Arc<Mutex<State>>,
    reader: tokio::task::JoinHandle<()>,
}
pub(crate) struct FeedbackTicket {
    id: u64,
    state: Arc<Mutex<State>>,
    reply: oneshot::Receiver<Result<AtlasFrameDisposition>>,
}
impl FeedbackTicket {
    pub(crate) async fn wait(mut self) -> Result<AtlasFrameDisposition> {
        (&mut self.reply).await.context("atlas feedback owner ended")?
    }
}
impl Drop for FeedbackTicket {
    fn drop(&mut self) {
        if let Ok(mut state) = self.state.lock() { state.pending.remove(&self.id); }
    }
}
impl AtlasActivityFeedback {
    pub(crate) fn new(mut input: impl AsyncRead + Unpin + Send + 'static) -> Arc<Self> {
        let state = Arc::new(Mutex::new(State::default()));
        let owner = state.clone();
        let reader = tokio::spawn(async move {
            let result = async {
                loop {
                    let mut record = [0; RECORD_BYTES];
                    input.read_exact(&mut record).await?;
                    let id = u64::from_be_bytes(record[20..28].try_into().unwrap());
                    let pending = owner.lock().unwrap().pending.remove(&id);
                    if let Some((frame, reply)) = pending {
                        let disposition = crate::atlas_feedback::decode(&record, &frame)?;
                        let _ = reply.send(Ok(disposition));
                    }
                }
                #[allow(unreachable_code)]
                Ok::<(), anyhow::Error>(())
            }.await;
            let reason = result.err().map_or_else(|| "atlas feedback closed".into(), |error| format!("{error:#}"));
            let mut state = owner.lock().unwrap();
            state.closed = Some(reason.clone());
            for (_, (_, reply)) in std::mem::take(&mut state.pending) {
                let _ = reply.send(Err(anyhow::anyhow!(reason.clone())));
            }
        });
        Arc::new(Self { state, reader })
    }
    pub(crate) fn register(&self, frame: &AtlasFrame) -> Result<FeedbackTicket> {
        let mut state = self.state.lock().map_err(|_| anyhow::anyhow!("atlas feedback state poisoned"))?;
        ensure!(state.closed.is_none(), "atlas feedback closed: {:?}", state.closed);
        ensure!(state.pending.len() < 2 && !state.pending.contains_key(&frame.frame_id), "atlas feedback lane already pending");
        let (send, reply) = oneshot::channel();
        state.pending.insert(frame.frame_id, (frame.clone(), send));
        Ok(FeedbackTicket { id: frame.frame_id, state: self.state.clone(), reply })
    }
}
impl Drop for AtlasActivityFeedback {
    fn drop(&mut self) { self.reader.abort(); }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;
    fn frame(id: u64) -> AtlasFrame {
        AtlasFrame { activity: Some(viewflow_protocol::AtlasActivity { lane: (id % 2) as u32,
            epoch: 1, preferred: None, focus: None, members: vec![] }),
            stream_id: viewflow_protocol::Id128(99), frame_id: id, geometry_epoch: 1,
            config_generation: 1, layout_revision: 0, width: 2, height: 2,
            source_submitted_ns: 100+id, tiles: vec![], color_keyframe: true,
            alpha_keyframe: true, desktop: None, patches: None }
    }
    #[tokio::test]
    async fn priority_feedback_does_not_wait_for_background() {
        let (input, mut output) = tokio::io::duplex(512);
        let hub = AtlasActivityFeedback::new(input);
        let background = hub.register(&frame(4)).unwrap();
        let priority = hub.register(&frame(5)).unwrap();
        output.write_all(&crate::atlas_feedback::encode(&frame(5), AtlasFrameDisposition::Committed).unwrap()).await.unwrap();
        assert_eq!(priority.wait().await.unwrap(), AtlasFrameDisposition::Committed);
        assert!(hub.register(&frame(4)).is_err());
        output.write_all(&crate::atlas_feedback::encode(&frame(4), AtlasFrameDisposition::Superseded).unwrap()).await.unwrap();
        assert_eq!(background.wait().await.unwrap(), AtlasFrameDisposition::Superseded);
        let next = hub.register(&frame(7)).unwrap();
        drop(output);
        assert!(next.wait().await.is_err());
    }
}
