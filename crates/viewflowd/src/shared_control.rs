//! One sequenced control writer shared by media and input on a paired connection.
use anyhow::{Context, Result, ensure};
use quinn::Connection;
use tokio::{
    sync::{mpsc, oneshot},
    task::JoinHandle,
    time::Instant,
};
use viewflow_protocol::wire;

#[derive(Clone)]
pub struct SharedControlSender {
    outbound: crate::OutboundSender,
    connection: Connection,
}

pub struct SharedControlWriter {
    sender: SharedControlSender,
    task: JoinHandle<Result<()>>,
}

impl SharedControlWriter {
    /// The caller must be the sole control-writer owner for this connection.
    /// All producers use clones of `sender`; none assign wire sequence numbers.
    /// # Errors
    /// Requires a live authenticated connection.
    pub fn start(connection: &Connection) -> Result<Self> {
        ensure!(
            connection.peer_identity().is_some() && connection.close_reason().is_none(),
            "shared control requires a live authenticated peer"
        );
        let (controls, receiver) = mpsc::channel(256);
        let outbound = crate::OutboundSender::new_connected(controls, connection.clone());
        Ok(Self {
            sender: SharedControlSender {
                outbound,
                connection: connection.clone(),
            },
            task: crate::spawn_control_writer(connection.clone(), receiver),
        })
    }

    #[must_use]
    pub fn sender(&self) -> SharedControlSender {
        self.sender.clone()
    }
}

impl Drop for SharedControlWriter {
    fn drop(&mut self) {
        self.sender
            .outbound
            .abort_peer("shared control owner stopped");
        self.task.abort();
    }
}

impl SharedControlSender {
    pub(crate) fn outbound(&self) -> crate::OutboundSender {
        self.outbound.clone()
    }
    pub(crate) fn belongs_to(&self, connection: &Connection) -> bool {
        self.connection.stable_id() == connection.stable_id()
            && self.connection.close_reason().is_none()
    }

    /// Confirm transport enqueue using the writer's connection-wide sequence.
    /// The deadline is a latency target. Once queued, the writer completes the
    /// record in order even if this waiter is cancelled. Payload validity and
    /// native acknowledgements remain the receiving input route's responsibility.
    /// # Errors
    /// Writer loss, disconnect and transport failure are reported to the caller.
    pub async fn send(
        &self,
        payload: wire::control_envelope::Payload,
        deadline: Instant,
    ) -> Result<()> {
        send_bounded_control(&self.outbound, payload, deadline).await
    }
}

pub(crate) async fn send_bounded_control(
    outbound: &crate::OutboundSender,
    payload: wire::control_envelope::Payload,
    deadline: Instant,
) -> Result<()> {
    let (sent, confirmation) = oneshot::channel();
    outbound
        .controls
        .send(crate::OutboundControl {
            payload,
            sent: Some(sent),
            input_gate: None,
        })
        .await
        .context("shared control writer queue stopped")?;
    confirmation
        .await
        .context("shared control confirmation owner stopped")?
        .map_err(|error| anyhow::anyhow!("shared control writer failed: {error}"))?;
    if Instant::now() > deadline {
        eprintln!(
            "shared control latency target missed by {}us; ordered send completed",
            Instant::now()
                .saturating_duration_since(deadline)
                .as_micros()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use viewflow_transport::receive_control;

    #[tokio::test]
    async fn delayed_or_cancelled_waiter_does_not_abort_queued_control_or_peer() {
        for cancelled in [false, true] {
            let (_client, _server, connection, remote) = crate::atlas_session::tests::pair().await;
            // Hold the writer queue beyond the caller's latency target.
            let (controls, queue) = mpsc::channel(1);
            let sender = SharedControlSender {
                outbound: crate::OutboundSender::new_connected(controls, connection.clone()),
                connection: connection.clone(),
            };
            let payload = |id| {
                wire::control_envelope::Payload::ClockSyncProbe(wire::ClockSyncProbe {
                    probe_id: id,
                    t0_send_ns: id,
                })
            };
            let first_sender = sender.clone();
            let work = tokio::spawn(async move {
                first_sender
                    .send(payload(1), Instant::now() + Duration::from_millis(10))
                    .await
            });
            tokio::time::sleep(Duration::from_millis(30)).await;
            assert!(!work.is_finished());
            let work = if cancelled {
                work.abort();
                assert!(work.await.unwrap_err().is_cancelled());
                None
            } else {
                Some(work)
            };
            assert!(connection.close_reason().is_none());
            let writer = crate::spawn_control_writer(connection.clone(), queue);
            let first = tokio::time::timeout(Duration::from_secs(1), receive_control(&remote))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(first.sequence, 1);
            if let Some(work) = work {
                work.await.unwrap().unwrap();
            }
            // Both a cancelled waiter and a delayed confirmation leave the
            // connection-wide sequence usable for the next ordered control.
            sender
                .send(payload(2), Instant::now() + Duration::from_secs(1))
                .await
                .unwrap();
            let second = tokio::time::timeout(Duration::from_secs(1), receive_control(&remote))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(second.sequence, 2);
            assert!(connection.close_reason().is_none());
            writer.abort();
        }
    }
}
