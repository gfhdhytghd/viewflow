//! Ordered cursor injection independent of preview recovery waits. The atlas
//! reader and shared writer remain the only authenticated transport owners.
use anyhow::{Context, Result, bail, ensure};
use std::time::Duration;
use tokio::sync::{mpsc, watch};
#[cfg(test)]
use viewflow_protocol::InputAppliedResult;
use viewflow_protocol::{DomainControl, Id128};

pub(crate) fn is_cursor_control(control: &DomainControl) -> bool {
    matches!(
        control,
        DomainControl::InputLease(_)
            | DomainControl::InputEvent(_)
            | DomainControl::InputLeaseRevoke(_)
    )
}

pub(crate) async fn route(
    mut incoming: mpsc::Receiver<DomainControl>,
    cursor: mpsc::Sender<DomainControl>,
    preview: mpsc::Sender<DomainControl>,
) -> Result<()> {
    // Independent bounded queues let cursor ACKs progress while preview
    // recovery waits. Saturation applies backpressure, never disconnects.
    let mut cursors = std::collections::VecDeque::new();
    let mut previews = std::collections::VecDeque::new();
    let mut closed = false;
    loop {
        if closed && cursors.is_empty() && previews.is_empty() {
            bail!("atlas input control owner disappeared");
        }
        tokio::select! {
            permit = cursor.reserve(), if !cursors.is_empty() => {
                permit.context("atlas cursor input owner stopped")?
                    .send(cursors.pop_front().expect("queued cursor control"));
            }
            permit = preview.reserve(), if !previews.is_empty() => {
                permit.context("atlas preview input owner stopped")?
                    .send(previews.pop_front().expect("queued preview control"));
            }
            control = incoming.recv(), if !closed && cursors.len() + previews.len() < 256 => {
                match control {
                    Some(control) if is_cursor_control(&control) => cursors.push_back(control),
                    Some(control) => previews.push_back(control),
                    None => closed = true,
                }
            }
        }
    }
}

struct OwnedReceiver(Option<crate::input_runtime::InputReceiver>);
impl Drop for OwnedReceiver {
    fn drop(&mut self) {
        if let Some(receiver) = &mut self.0 {
            if let Err(error) = receiver.release_all() {
                eprintln!("atlas cursor owner cleanup failed: {error:#}");
            }
        }
    }
}

pub(crate) async fn serve(
    receiver: Option<crate::input_runtime::InputReceiver>,
    mut controls: mpsc::Receiver<DomainControl>,
    writer: crate::shared_control::SharedControlSender,
    source: Id128,
    owner: Id128,
    _clock: crate::ProcessClock,
    _snapshots: watch::Receiver<Option<crate::input_runtime::ClockSnapshot>>,
) -> Result<()> {
    let mut owned = OwnedReceiver(receiver);
    loop {
        let control = controls
            .recv()
            .await
            .context("atlas cursor control owner disappeared")?;
        let receiver = owned.0.as_mut().context("desktop cursor input disabled")?;
        let payload = match control {
            DomainControl::InputLease(lease) => {
                ensure!(
                    lease.owner == source && lease.route_to == owner,
                    "desktop cursor lease identity mismatch"
                );
                receiver.apply_lease(lease)?;
                continue;
            }
            DomainControl::InputEvent(event) => {
                if event.sequence == 1 {
                    eprintln!(
                        "atlas-cursor-received {}",
                        crate::input_runtime::input_event_diagnostic(&event)
                    );
                }
                if let Err(error) = receiver.apply_ordered_event(&event) {
                    eprintln!(
                        "atlas cursor input rejected: {} result={error:?}",
                        crate::input_runtime::input_event_diagnostic(&event)
                    );
                    if error == crate::input_runtime::InputApplyError::InjectionFailed {
                        receiver
                            .release_all()
                            .context("cursor native failure cleanup")?;
                    }
                }
                continue;
            }
            DomainControl::InputLeaseRevoke(revoke) => {
                ensure!(
                    revoke.owner_device == source && revoke.target_device == owner,
                    "desktop cursor revoke identity mismatch"
                );
                let ack = receiver.apply_lease_revoke(revoke)?;
                crate::input_runtime::input_lease_revoked_ack_payload(ack)
            }
            _ => bail!("non-cursor control reached cursor owner"),
        };
        writer
            .send(
                payload,
                tokio::time::Instant::now() + Duration::from_millis(24),
            )
            .await?;
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn run(
    connection: &quinn::Connection,
    incoming: mpsc::Receiver<DomainControl>,
    preview: mpsc::Sender<DomainControl>,
    receiver: Option<crate::input_runtime::InputReceiver>,
    writer: crate::shared_control::SharedControlSender,
    source: Id128,
    owner: Id128,
    clock: crate::ProcessClock,
    snapshots: watch::Receiver<Option<crate::input_runtime::ClockSnapshot>>,
) -> Result<()> {
    ensure!(
        writer.belongs_to(connection),
        "cursor writer belongs to another connection"
    );
    let (cursor_send, cursor_controls) = mpsc::channel(64);
    let routing = route(incoming, cursor_send, preview);
    let injection = serve(
        receiver,
        cursor_controls,
        writer,
        source,
        owner,
        clock,
        snapshots,
    );
    tokio::pin!(routing, injection);
    let result = tokio::select! {
        result = &mut routing => result,
        result = &mut injection => result,
    };
    connection.close(0_u32.into(), b"atlas cursor input owner ended");
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{
        DesktopPointerPosition, InputEvent, InputEventKind, InputLease, InputLeaseRevoke,
        InputLeaseState,
    };
    use viewflow_transport::{ClockEstimate, ControlSequencer, receive_control_sequenced};

    #[tokio::test]
    async fn blocked_preview_does_not_block_ordered_cursor_acks_or_cleanup() {
        let (_client, _server, connection, remote) = crate::atlas_session::tests::pair().await;
        let writer = crate::shared_control::SharedControlWriter::start(&connection).unwrap();
        let (send, incoming) = mpsc::channel(64);
        let (preview, mut blocked_preview) = mpsc::channel(64);
        let clock = crate::ProcessClock {
            origin: std::time::Instant::now(),
        };
        let (_snapshots, snapshots) = watch::channel(Some(crate::input_runtime::ClockSnapshot {
            estimate: ClockEstimate {
                remote_offset_ns: 0,
                network_round_trip_ns: 0,
                uncertainty_ns: 0,
            },
            measured_at_local_ns: 0,
        }));
        let native = crate::input_runtime::InputReceiver::new(
            crate::input_runtime::InputBackendMode::Disabled,
            Some(Id128(2)),
        )
        .unwrap();
        let network = connection.clone();
        let sender = writer.sender();
        let task_clock = clock.clone();
        let work = tokio::spawn(async move {
            run(
                &network,
                incoming,
                preview,
                Some(native),
                sender,
                Id128(1),
                Id128(2),
                task_clock,
                snapshots,
            )
            .await
        });
        // Stand in for a preview actor blocked indefinitely on its native fence.
        send.send(DomainControl::WindowPointerAuthorization(
            viewflow_protocol::WindowPointerAuthorization {
                lease_generation: 1,
                owner_device: Id128(2),
                target_device: Id128(1),
                target_window: Id128(3),
                geometry_epoch: 1,
                presented_frame: 1,
                source_not_after_ns: 1,
            },
        ))
        .await
        .unwrap();
        for (generation, state) in [(1, InputLeaseState::Offered), (2, InputLeaseState::Active)] {
            send.send(DomainControl::InputLease(InputLease {
                generation,
                owner: Id128(1),
                route_to: Id128(2),
                state,
            }))
            .await
            .unwrap();
        }
        let event = InputEvent {
            lease_generation: 2,
            target_device: Id128(2),
            sequence: 1,
            sender_not_after_ns: clock.now_ns() + 24_000_000,
            event: InputEventKind::DesktopPointerPosition(DesktopPointerPosition {
                x_millidip: 1000,
                y_millidip: 2000,
            }),
        };
        send.send(DomainControl::InputEvent(event)).await.unwrap();
        send.send(DomainControl::InputEvent(event)).await.unwrap();
        send.send(DomainControl::InputLeaseRevoke(InputLeaseRevoke {
            operation_id: Id128(3),
            lease_generation: 3,
            owner_device: Id128(1),
            target_device: Id128(2),
            state: InputLeaseState::Revoked,
        }))
        .await
        .unwrap();
        let mut sequence = ControlSequencer::default();
        // Ordinary events produce no reply; only release cleanup is confirmed.
        for expected in [None::<InputAppliedResult>] {
            let envelope = tokio::time::timeout(
                Duration::from_millis(100),
                receive_control_sequenced(&remote, &mut sequence),
            )
            .await
            .unwrap()
            .unwrap();
            match (expected, DomainControl::try_from(envelope).unwrap()) {
                (Some(expected), DomainControl::InputAppliedAck(ack)) => {
                    assert_eq!(ack.result, expected);
                    assert_eq!(ack.event_sequence, 1);
                }
                (None, DomainControl::InputLeaseRevokedAck(ack)) => {
                    assert_eq!(ack.lease_generation, 3)
                }
                other => panic!("cursor FIFO violated: {other:?}"),
            }
        }
        assert_eq!(
            blocked_preview.len(),
            1,
            "preview was never required to drain"
        );
        assert!(matches!(
            blocked_preview.try_recv().unwrap(),
            DomainControl::WindowPointerAuthorization(_)
        ));
        assert!(connection.close_reason().is_none());
        drop(send);
        assert!(work.await.unwrap().is_err());
        assert!(
            connection.close_reason().is_some(),
            "control owner loss retires the session"
        );
    }

    #[tokio::test]
    async fn full_cursor_queue_waits_then_delivers_in_order() {
        let (send, incoming) = mpsc::channel(2);
        let (cursor, mut cursor_rx) = mpsc::channel(1);
        let (preview, _preview_rx) = mpsc::channel(1);
        for generation in [1, 2] {
            send.send(DomainControl::InputLease(InputLease {
                generation,
                owner: Id128(1),
                route_to: Id128(2),
                state: InputLeaseState::Offered,
            }))
            .await
            .unwrap();
        }
        let task = tokio::spawn(route(incoming, cursor, preview));
        tokio::time::sleep(Duration::from_millis(40)).await;
        assert!(!task.is_finished());
        for expected in [1, 2] {
            assert!(matches!(
                cursor_rx.recv().await.unwrap(),
                DomainControl::InputLease(InputLease { generation, .. }) if generation == expected
            ));
        }
        assert!(!task.is_finished());
        drop(send);
        assert!(task.await.unwrap().is_err());
    }

    #[tokio::test]
    async fn disabled_cursor_route_does_not_accept_remote_input() {
        let (_client, _server, connection, _remote) = crate::atlas_session::tests::pair().await;
        let writer = crate::shared_control::SharedControlWriter::start(&connection).unwrap();
        let (send, incoming) = mpsc::channel(64);
        let (preview, _blocked) = mpsc::channel(64);
        let (_snapshots, snapshots) = watch::channel(None);
        send.send(DomainControl::InputLease(InputLease {
            generation: 1,
            owner: Id128(1),
            route_to: Id128(2),
            state: InputLeaseState::Offered,
        }))
        .await
        .unwrap();
        let error = run(
            &connection,
            incoming,
            preview,
            None,
            writer.sender(),
            Id128(1),
            Id128(2),
            crate::ProcessClock {
                origin: std::time::Instant::now(),
            },
            snapshots,
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("desktop cursor input disabled"));
        assert!(connection.close_reason().is_some());
    }

    #[tokio::test]
    async fn cursor_owner_mismatch_closes_the_same_session() {
        let (_client, _server, connection, _remote) = crate::atlas_session::tests::pair().await;
        let writer = crate::shared_control::SharedControlWriter::start(&connection).unwrap();
        let (send, incoming) = mpsc::channel(64);
        let (preview, _blocked) = mpsc::channel(64);
        let (_snapshots, snapshots) = watch::channel(None);
        let receiver = crate::input_runtime::InputReceiver::new(
            crate::input_runtime::InputBackendMode::Disabled,
            Some(Id128(2)),
        )
        .unwrap();
        send.send(DomainControl::InputLease(InputLease {
            generation: 1,
            owner: Id128(9),
            route_to: Id128(2),
            state: InputLeaseState::Offered,
        }))
        .await
        .unwrap();
        let error = run(
            &connection,
            incoming,
            preview,
            Some(receiver),
            writer.sender(),
            Id128(1),
            Id128(2),
            crate::ProcessClock {
                origin: std::time::Instant::now(),
            },
            snapshots,
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("identity mismatch"));
        assert!(connection.close_reason().is_some());
    }
}
