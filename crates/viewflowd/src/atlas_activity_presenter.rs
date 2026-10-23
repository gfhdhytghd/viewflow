//! Concurrent V11 handoffs over one native pipe. The writer serializes bytes,
//! while the reader matches either decoder's receipt without a FIFO ACK wait.
use std::{collections::{BTreeMap, VecDeque}, sync::{Arc, Mutex}};
use anyhow::{Context, Result, ensure};
use tokio::{io::{AsyncRead, AsyncWrite, AsyncWriteExt}, sync::{oneshot, Notify}, time::{Instant, timeout_at}};
use crate::{atlas_presenter::{AtlasDisposition, read_line_bounded}, atlas_runtime::AdmittedAtlas,
    gpu_presenter_pipe::{NativePresentationDeadline, encode_atlas_record}};

type Clock = Arc<dyn Fn() -> Result<(u64, u64)> + Send + Sync>;
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Key { Frame(u64), Recovery(u64) }
enum Expect {
    Frame { lane: usize, tiles: usize, start: u64, native: NativePresentationDeadline },
    Recovery { confirmation: crate::atlas_input_recovery::InputRecoveryConfirmation, start: u64 },
}
enum Receipt { Frame(AtlasDisposition), Recovery(u64) }
struct Pending {
    expect: Expect,
    deadline: Instant,
    completion: oneshot::Sender<Result<Receipt>>,
}
#[derive(Default)]
struct State {
    failure: Option<String>,
    pending: BTreeMap<Key, Pending>,
    last_frame: [u64; 2],
    needs_keyframe: [bool; 2],
    committed: VecDeque<u64>,
    last_recovery: u64,
}
struct WriteGuard<'a> { state: &'a Mutex<State>, changed: &'a Notify, complete: bool }
impl Drop for WriteGuard<'_> {
    fn drop(&mut self) {
        if !self.complete {
            self.state.lock().unwrap().fail("native activity write cancelled");
            self.changed.notify_one();
        }
    }
}
impl State {
    fn ready(&self) -> Result<()> {
        ensure!(self.failure.is_none(), "native activity pipe ended: {}", self.failure.as_deref().unwrap_or(""));
        Ok(())
    }
    fn fail(&mut self, error: impl std::fmt::Display) {
        let reason = error.to_string();
        self.failure.get_or_insert_with(|| reason.clone());
        for (_, pending) in std::mem::take(&mut self.pending) {
            let _ = pending.completion.send(Err(anyhow::anyhow!("{reason}")));
        }
    }
}

pub(crate) struct ActivityAtlasPresenter<W> {
    writer: tokio::sync::Mutex<W>,
    state: Arc<Mutex<State>>,
    changed: Arc<Notify>,
    reader: tokio::task::JoinHandle<()>,
    clock: Clock,
    desktop: bool,
}
impl<W> Drop for ActivityAtlasPresenter<W> {
    fn drop(&mut self) {
        self.reader.abort();
        self.state.lock().unwrap().fail("native activity presenter stopped");
    }
}
impl<W: AsyncWrite + Unpin + Send> ActivityAtlasPresenter<W> {
    /// Caller has completed native readiness and all three warmup receipts.
    pub(crate) fn start<R: AsyncRead + Unpin + Send + 'static>(
        writer: W, reader: R, desktop: bool,
        clock: impl Fn() -> Result<(u64, u64)> + Send + Sync + 'static,
    ) -> Self {
        let state = Arc::new(Mutex::new(State::default()));
        let changed = Arc::new(Notify::new());
        let clock: Clock = Arc::new(clock);
        let task = tokio::spawn(read_receipts(reader, state.clone(), changed.clone(), clock.clone()));
        Self { writer: tokio::sync::Mutex::new(writer), state, changed, reader: task, clock, desktop }
    }

    async fn write(&self, record: &[u8], deadline: Instant) -> Result<()> {
        let mut guard = WriteGuard { state: &self.state, changed: &self.changed, complete: false };
        let result = timeout_at(deadline, async {
            let mut writer = self.writer.lock().await;
            self.state.lock().unwrap().ready()?;
            writer.write_all(record).await?;
            writer.flush().await?;
            Ok::<_, anyhow::Error>(())
        }).await.context("native activity pipe write watchdog expired").and_then(|r| r);
        if let Err(error) = &result {
            self.state.lock().unwrap().fail(error);
            self.changed.notify_one();
        }
        guard.complete = true;
        result
    }

    pub(crate) async fn submit(
        &self, frame: &AdmittedAtlas, native: NativePresentationDeadline,
        deadline: Instant, max_record_bytes: usize,
    ) -> Result<AtlasDisposition> {
        let activity = frame.layout.activity.as_ref().context("activity native handoff lacks lane")?;
        let lane = usize::try_from(activity.lane)?;
        ensure!(lane < 2 && frame.layout.frame_id % 2 == lane as u64, "native activity lane identity mismatch");
        ensure!(frame.layout.desktop.is_some() == self.desktop, "native activity desktop capability mismatch");
        let record = encode_atlas_record(frame, native, max_record_bytes)?;
        let (start, frequency) = (self.clock)()?;
        ensure!(start > 0 && frequency != 0 && frequency == native.frequency, "native activity clock changed");
        let (completion, receipt) = oneshot::channel();
        {
            let mut state = self.state.lock().unwrap();
            state.ready()?;
            ensure!(frame.layout.frame_id > state.last_frame[lane], "native activity frame replay");
            ensure!(!state.pending.values().any(|p| matches!(p.expect, Expect::Frame { lane: other, .. } if other == lane)),
                "native activity lane still owns a picture");
            ensure!(!state.needs_keyframe[lane] || (frame.layout.color_keyframe && frame.layout.alpha_keyframe),
                "native activity decode gap requires paired keyframe");
            state.last_frame[lane] = frame.layout.frame_id;
            if Instant::now() >= deadline {
                state.needs_keyframe[lane] = true;
                return Ok(AtlasDisposition::ExpiredUnbound);
            }
            state.pending.insert(Key::Frame(frame.layout.frame_id), Pending {
                expect: Expect::Frame { lane, tiles: frame.layout.tiles.len(), start, native },
                deadline, completion,
            });
        }
        self.changed.notify_one();
        self.write(&record, deadline).await?;
        match receipt.await.context("native activity receipt owner stopped")?? {
            Receipt::Frame(result) => Ok(result),
            _ => anyhow::bail!("native activity receipt type mismatch"),
        }
    }

    pub(crate) async fn recover_input(
        &self, confirmation: crate::atlas_input_recovery::InputRecoveryConfirmation, deadline: Instant,
    ) -> Result<u64> {
        let record = confirmation.encode()?;
        let (start, frequency) = (self.clock)()?;
        ensure!(start > 0 && start < confirmation.deadline_qpc && frequency == confirmation.frequency,
            "native activity recovery clock mismatch or expiry");
        let (completion, receipt) = oneshot::channel();
        {
            let mut state = self.state.lock().unwrap();
            state.ready()?;
            ensure!(state.committed.contains(&confirmation.atlas_frame), "native activity recovery has no committed frame");
            ensure!(confirmation.sequence > state.last_recovery
                && !state.pending.keys().any(|k| matches!(k, Key::Recovery(_))), "native activity recovery replay or overlap");
            state.last_recovery = confirmation.sequence;
            state.pending.insert(Key::Recovery(confirmation.sequence), Pending {
                expect: Expect::Recovery { confirmation, start }, deadline, completion,
            });
        }
        self.changed.notify_one();
        self.write(&record, deadline).await?;
        match receipt.await.context("native activity recovery owner stopped")?? {
            Receipt::Recovery(ticks) => Ok(ticks),
            _ => anyhow::bail!("native activity recovery type mismatch"),
        }
    }

    pub(crate) async fn desktop_geometry_ack(&self, ack: viewflow_protocol::DesktopWindowMoveAck,
        sequence: u64, deadline: Instant) -> Result<u64> {
        ensure!(self.desktop, "native activity desktop capability unavailable");
        let record = crate::atlas_presenter::encode_desktop_geometry_ack(ack, sequence)?;
        self.write(&record, deadline).await?;
        Ok(sequence)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use std::sync::atomic::{AtomicU64, Ordering};

    #[tokio::test]
    async fn native_priority_receipt_bypasses_pending_background_decode() {
        let (client, mut native) = tokio::io::duplex(8192);
        let (reader, writer) = tokio::io::split(client);
        let ticks = Arc::new(AtomicU64::new(100));
        let clock = ticks.clone();
        let presenter = ActivityAtlasPresenter::start(writer, reader, false,
            move || Ok((clock.load(Ordering::SeqCst), 1000)));
        let frame = |id| {
            let mut frame = crate::atlas_presenter::tests::test_frame();
            frame.layout.frame_id = id;
            frame.media.manifest.frame_id = id;
            frame.layout.activity = Some(viewflow_protocol::AtlasActivity {
                lane: (id % 2) as u32, epoch: 1, preferred: None, focus: None, members: vec![],
            });
            frame
        };
        let bg = frame(4);
        let fg = frame(5);
        let target = NativePresentationDeadline { ticks: 150, frequency: 1000 };
        let watchdog = Instant::now() + std::time::Duration::from_secs(2);
        let (priority_finished, received_priority) = oneshot::channel();
        let native_work = async {
            // Both complete records must arrive before either decode receipt.
            for _ in 0..2 {
                let mut prefix = [0_u8; 16];
                native.read_exact(&mut prefix).await.unwrap();
                let length = u32::from_be_bytes(prefix[8..12].try_into().unwrap()) as usize
                    + u32::from_be_bytes(prefix[12..16].try_into().unwrap()) as usize;
                assert!(length >= 16 && length <= 8192);
                let mut tail = vec![0; length - 16];
                native.read_exact(&mut tail).await.unwrap();
            }
            ticks.store(300, Ordering::SeqCst);
            native.write_all(b"atlas-disposition-v1 frame_identity=5 tile_count=0 outcome=committed deadline_ticks=150 frequency=1000 commit_ticks=200 physical_present_receipt=false\n").await.unwrap();
            received_priority.await.unwrap();
            native.write_all(b"atlas-disposition-v1 frame_identity=4 tile_count=0 outcome=superseded deadline_ticks=150 frequency=1000 commit_ticks=0 physical_present_receipt=false\n").await.unwrap();
        };
        let priority = async {
            let result = presenter.submit(&fg, target, watchdog, 8192).await.unwrap();
            assert_eq!(result, AtlasDisposition::CommittedLate { commit_ticks: 200 });
            assert!(presenter.state.lock().unwrap().pending.contains_key(&Key::Frame(4)));
            priority_finished.send(()).unwrap();
        };
        let all = async { tokio::join!(presenter.submit(&bg, target, watchdog, 8192), priority, native_work) };
        let (background, (), ()) = timeout_at(watchdog, all).await.unwrap();
        assert_eq!(background.unwrap(), AtlasDisposition::Superseded);
        let state = presenter.state.lock().unwrap();
        assert_eq!(state.committed.iter().copied().collect::<Vec<_>>(), vec![5]);
        assert_eq!(state.needs_keyframe, [false, false]);
    }
}

fn receipt_key(line: &str) -> Result<Key> {
    let mut fields = line.split(' ');
    let prefix = fields.next().context("missing native receipt prefix")?;
    let field = fields.next().context("missing native receipt identity")?;
    let (name, frame) = field.split_once('=').context("missing native receipt identity separator")?;
    let id: u64 = frame.parse()?;
    ensure!(id > 0 && id.to_string() == frame, "noncanonical native receipt identity");
    match (prefix, name) {
        ("atlas-disposition-v1", "frame_identity") => Ok(Key::Frame(id)),
        ("atlas-input-recovered-v1" | "atlas-input-recovered-v2" | "atlas-input-cancelled-v2", "sequence") => Ok(Key::Recovery(id)),
        _ => anyhow::bail!("unrecognized native activity receipt"),
    }
}

async fn read_receipts<R: AsyncRead + Unpin>(mut reader: R, state: Arc<Mutex<State>>, changed: Arc<Notify>, clock: Clock) {
    let result = async {
        loop {
            // Retain this future across queue notifications: a cancelled line
            // read could otherwise consume and lose half of a native receipt.
            let line = read_line_bounded(&mut reader, 1024);
            tokio::pin!(line);
            let line = loop {
                let deadline = {
                    let state = state.lock().unwrap();
                    state.ready()?;
                    state.pending.values().map(|p| p.deadline).min()
                };
                tokio::select! {
                    result = &mut line => break result?,
                    () = changed.notified() => {},
                    () = async { match deadline {
                        Some(deadline) => tokio::time::sleep_until(deadline).await,
                        None => std::future::pending().await,
                    } } => anyhow::bail!("native activity receipt watchdog expired"),
                }
            };
            let key = receipt_key(&line)?;
            let (observed, frequency) = clock()?;
            let mut state = state.lock().unwrap();
            let pending = state.pending.remove(&key).context("native receipt has no pending operation")?;
            let result = (|| -> Result<Receipt> {
                ensure!(Instant::now() < pending.deadline, "native activity receipt watchdog expired");
                match pending.expect {
                    Expect::Frame { lane, tiles, start, native } => {
                        ensure!(frequency == native.frequency, "native activity receipt clock changed");
                        let Key::Frame(id) = key else { unreachable!() };
                        let result = AtlasDisposition::parse(&line, id, tiles, start, observed, native)?;
                        state.needs_keyframe[lane] = result == AtlasDisposition::ExpiredUnbound;
                        if matches!(result, AtlasDisposition::CommittedWithinDeadline { .. } | AtlasDisposition::CommittedLate { .. }) {
                            state.committed.push_back(id);
                            if state.committed.len() > 32 { state.committed.pop_front(); }
                        }
                        Ok(Receipt::Frame(result))
                    }
                    Expect::Recovery { confirmation, start } => {
                        ensure!(frequency == confirmation.frequency, "native activity recovery clock changed");
                        Ok(Receipt::Recovery(confirmation.validate_receipt(&line, start, observed)?))
                    }
                }
            })();
            let failure = result.as_ref().err().map(ToString::to_string);
            let _ = pending.completion.send(result);
            if let Some(error) = failure { anyhow::bail!(error); }
        }
        #[allow(unreachable_code)]
        Ok::<_, anyhow::Error>(())
    }.await;
    if let Err(error) = result { state.lock().unwrap().fail(error); }
}
