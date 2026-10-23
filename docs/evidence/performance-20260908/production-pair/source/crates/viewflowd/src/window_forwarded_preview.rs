//! Input consumer behind the atlas receiver's sole sequenced control reader.
use anyhow::{Context, Result, ensure};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};
use viewflow_protocol::{DomainControl, wire};

pub(crate) async fn serve(
    connection: &quinn::Connection,
    origin: Instant,
    mut preview: crate::window_preview_input::WindowPreviewInput,
    mut controls: mpsc::Receiver<DomainControl>,
    writer: crate::shared_control::SharedControlSender,
) -> Result<()> {
    ensure!(
        writer.belongs_to(connection),
        "preview shared writer belongs to another connection"
    );
    let outbound = writer.outbound();
    let recovery = preview.recovery_unconfirmed();
    let (replies, reply_rx) = mpsc::channel(4);
    let (snapshots, snapshot_rx) = watch::channel(None);
    let clock = crate::ProcessClock { origin };
    let mut guard = crate::WindowConnectionTasks {
        writer: None,
        probe: tokio::spawn(crate::run_probe_loop(
            "atlas-window-preview",
            connection.clone(),
            Duration::from_millis(250),
            Duration::from_millis(250),
            clock.clone(),
            outbound.clone(),
            reply_rx,
            snapshots,
        )),
        outbound: outbound.clone(),
    };
    let receiver = async {
        let mut tick = tokio::time::interval(Duration::from_millis(1));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                control = controls.recv() => {
                    dispatch(control.context("atlas input control owner disappeared")?,
                        &mut preview, &clock, &replies, &writer).await?;
                }
                _ = tick.tick() => {}
                reason = connection.closed() => return Err(reason).context("atlas preview disconnected"),
            }
            ensure!(
                !controls.is_closed(),
                "atlas input control owner disappeared"
            );
            snapshot_rx.has_changed()?;
            let snapshot = *snapshot_rx.borrow();
            preview.pump(snapshot, &outbound).await?;
        }
    };
    tokio::pin!(receiver);
    tokio::select! {
        biased;
        result = &mut guard.probe => crate::guard_liveness_recovery(result.context("atlas input clock task failed")?, &recovery),
        result = &mut receiver => result,
    }
}

async fn dispatch(
    control: DomainControl,
    preview: &mut crate::window_preview_input::WindowPreviewInput,
    clock: &crate::ProcessClock,
    replies: &mpsc::Sender<crate::ClockReplyDispatch>,
    writer: &crate::shared_control::SharedControlSender,
) -> Result<()> {
    match control {
        DomainControl::WindowPointerAuthorization(auth) => preview.authorize(auth),
        DomainControl::WindowPointerAck(ack) => preview.acknowledge(ack),
        DomainControl::WindowKeyboardAuthorization(auth) => preview.authorize_keyboard(auth),
        DomainControl::WindowKeyboardAck(ack) => preview.acknowledge_keyboard(ack),
        DomainControl::ClockSyncReply(reply) => crate::dispatch_clock_reply(replies, reply).await,
        DomainControl::ClockSyncProbe(probe) => {
            let t1_receive_ns = clock.now_ns();
            let t2_send_ns = clock.now_ns();
            writer
                .send(
                    wire::control_envelope::Payload::ClockSyncReply(wire::ClockSyncReply {
                        probe_id: probe.probe_id,
                        t0_send_ns: probe.t0_send_ns,
                        t1_receive_ns,
                        t2_send_ns,
                    }),
                    tokio::time::Instant::now() + Duration::from_millis(24),
                )
                .await
        }
        _ => anyhow::bail!("unexpected atlas preview control"),
    }
}
