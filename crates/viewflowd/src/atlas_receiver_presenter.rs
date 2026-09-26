//! Owns the admitted QUIC receiver and its native child across frame handoff.
use crate::{
    atlas_presenter::AtlasVisualSubmission,
    atlas_presenter_child::AtlasPresenterChild,
    atlas_session::{AtlasReceiverSession, AtlasWaitExpired},
    gpu_presenter_pipe::NativePresentationDeadline,
};
use anyhow::{Context, Result, ensure};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{sync::oneshot, time::Instant};

/// A receiver-supervisor request to resume native input after source cleanup.
///
/// The native notice and the fresh source authorization are validated by the
/// input supervisor before it constructs this request.  The media owner still
/// owns the native child, so it independently binds the control to its newest
/// successfully committed layout before touching the child pipe.
pub struct AtlasInputRecoveryRequest {
    pub confirmation: NativeGeometryControl,
    pub deadline: Instant,
    pub response: oneshot::Sender<Result<u64>>,
}

/// Ordered native controls share the media pipe so geometry receipts cannot
/// interleave bytes with a frame submission.
pub enum NativeGeometryControl {
    Input(crate::atlas_input_recovery::InputRecoveryConfirmation),
    Desktop { ack: viewflow_protocol::DesktopWindowMoveAck, native_sequence: u64 },
}
impl NativeGeometryControl {
    /// The shared queue carries two different operations. Only input authority
    /// recovery arms the admission fence. A desktop geometry receipt is written
    /// by the same sole media owner between complete frame submissions.
    fn native_write_deadline(&self, requested: Instant) -> Instant {
        match self {
            // Queue delay is not an expiry of geometry ownership. Start the
            // transport watchdog only when this complete record can be written.
            Self::Desktop { .. } => Instant::now() + Duration::from_secs(5),
            Self::Input(_) => requested,
        }
    }
    pub(crate) fn validate_media_fence(&self, armed: bool) -> Result<()> {
        ensure!(
            !matches!(self, Self::Input(_)) || armed,
            "atlas recovery request arrived before its media fence"
        );
        Ok(())
    }
}
#[cfg(test)]
impl NativeGeometryControl {
    pub(crate) fn input(&self) -> crate::atlas_input_recovery::InputRecoveryConfirmation {
        match self { Self::Input(value) => *value, Self::Desktop { .. } => panic!("expected input recovery") }
    }
}
impl From<crate::atlas_input_recovery::InputRecoveryConfirmation> for NativeGeometryControl {
    fn from(value: crate::atlas_input_recovery::InputRecoveryConfirmation) -> Self { Self::Input(value) }
}

/// One-way local fence from the recovery supervisor to the sole media owner.
/// It carries no authority or frame identity.  The media loop must finish an
/// already-admitted submission, then observe this fence before starting the
/// next one; it must never cancel `forward_next_*` mid-handoff.
#[derive(Default)]
struct AtlasInputRecoveryFenceState {
    armed: AtomicBool,
    changed: tokio::sync::Notify,
    // Crossing this mutex is the media admission boundary.  An armer marks
    // the fence first, then waits for an already-crossed forward to finish;
    // no later forward can cross it.
    forward_gate: Arc<tokio::sync::Mutex<()>>,
}

#[derive(Debug)]
pub(crate) struct AtlasMediaFenced;
impl std::fmt::Display for AtlasMediaFenced {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("atlas media admission is waiting for input recovery")
    }
}
impl std::error::Error for AtlasMediaFenced {}

#[derive(Clone, Default)]
pub struct AtlasInputRecoveryFence(Arc<AtlasInputRecoveryFenceState>);

impl AtlasInputRecoveryFence {
    /// Start fencing synchronously, then wait only for a forward that already
    /// crossed the media admission boundary.  This must never cancel it.
    pub(crate) async fn arm(&self) {
        self.0.armed.store(true, Ordering::Release);
        self.0.changed.notify_waiters();
        let _forward = self.0.forward_gate.lock().await;
    }

    async fn armed(&self) {
        loop {
            let changed = self.0.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if self.is_armed() {
                return;
            }
            changed.await;
        }
    }

    // Called only around the next receive operation, never disposition writes
    // or native submission. A ready receive wins and is processed in full.
    pub(crate) async fn wait_before_admission<T>(
        &self,
        waiting: impl std::future::Future<Output = Result<T>>,
    ) -> Result<T> {
        tokio::select! {
            biased;
            result = waiting => result,
            () = self.armed() => Err(AtlasMediaFenced.into()),
        }
    }

    fn clear(&self) {
        self.0.armed.store(false, Ordering::Release);
        self.0.changed.notify_waiters();
    }

    /// The input owner may reopen media after an exact rejected recovery
    /// selection only while native Cancel remains confirmed and drained.
    /// This does not resume native input or authorize the rejected event.
    pub(crate) fn retry_cancelled_selection(&self) {
        self.clear();
    }

    async fn cleared(&self) {
        loop {
            let changed = self.0.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if !self.is_armed() {
                return;
            }
            changed.await;
        }
    }

    #[must_use]
    pub fn is_armed(&self) -> bool {
        self.0.armed.load(Ordering::Acquire)
    }

    /// Acquire the exact boundary that separates a completed handoff from a
    /// future one.  The caller checks `is_armed` after acquiring this guard.
    pub(crate) async fn begin_media_forward(&self) -> Result<tokio::sync::OwnedMutexGuard<()>> {
        let guard = self.0.forward_gate.clone().lock_owned().await;
        if self.is_armed() {
            return Err(AtlasMediaFenced.into());
        }
        Ok(guard)
    }
}

pub struct QpcSample {
    pub ticks: u64,
    pub frequency: u64,
}

impl QpcSample {
    /// # Errors
    /// Requires a valid same-Windows-host performance counter and frequency.
    #[cfg(windows)]
    #[allow(unsafe_code)] // APIs only fill the two valid local output slots.
    pub fn current() -> Result<Self> {
        use windows_sys::Win32::System::Performance::{
            QueryPerformanceCounter, QueryPerformanceFrequency,
        };
        let mut ticks = 0_i64;
        let mut frequency = 0_i64;
        // SAFETY: synchronous output pointers remain valid throughout each call.
        anyhow::ensure!(
            unsafe { QueryPerformanceFrequency(&raw mut frequency) } != 0 && frequency > 0,
            "QPC frequency unavailable"
        );
        // SAFETY: same local output-slot contract as above.
        anyhow::ensure!(
            unsafe { QueryPerformanceCounter(&raw mut ticks) } != 0 && ticks >= 0,
            "QPC counter unavailable"
        );
        Ok(Self {
            ticks: u64::try_from(ticks)?,
            frequency: u64::try_from(frequency)?,
        })
    }
}

fn recovery_matches_committed(
    confirmation: crate::atlas_input_recovery::InputRecoveryConfirmation,
    committed: &viewflow_protocol::AtlasFrame,
) -> bool {
    let cancel = confirmation
        .rejection
        .is_some_and(|r| r.kind == crate::atlas_input_recovery::InputRejectionKind::Cancel);
    confirmation.stream == committed.stream_id.0
        && confirmation.atlas_epoch == committed.geometry_epoch
        && confirmation.config_generation == committed.config_generation
        && if cancel {
            confirmation.atlas_frame <= committed.frame_id
        } else {
            confirmation.atlas_frame == committed.frame_id
        }
        && committed.tiles.iter().any(|tile| {
            tile.window_id.0 == confirmation.window
                && if cancel {
                    tile.geometry_epoch >= confirmation.geometry_epoch
                } else {
                    tile.geometry_epoch == confirmation.geometry_epoch
                }
                && if cancel {
                    tile.source_frame_id >= confirmation.source_frame
                } else {
                    tile.source_frame_id == confirmation.source_frame
                }
                && if cancel {
                    tile.placement_generation >= confirmation.placement_generation
                } else {
                    tile.placement_generation == confirmation.placement_generation
                }
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{AtlasFrame, AtlasTile, Id128};

    fn committed() -> AtlasFrame {
        AtlasFrame {
            activity: None,
            patches: None,
            stream_id: Id128(2),
            frame_id: 9,
            geometry_epoch: 4,
            config_generation: 5,
            layout_revision: 6,
            width: 64,
            height: 64,
            source_submitted_ns: 7,
            tiles: vec![AtlasTile {
                window_id: Id128(3),
                placement_generation: 11,
                geometry_epoch: 8,
                source_frame_id: 10,
                source_submitted_ns: 7,
                x: 0,
                y: 0,
                width: 64,
                height: 64,
            }],
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
        }
    }

    #[tokio::test]
    async fn desktop_receipt_queue_does_not_require_or_clear_input_media_fence() {
        use viewflow_protocol::{DesktopWindowMoveAck, DesktopWindowMoveResult, DesktopRect, Id128};
        let fence=AtlasInputRecoveryFence::default();
        let (sender,mut receiver)=tokio::sync::mpsc::channel(2);
        let ack=DesktopWindowMoveAck {
            source_device:Id128(1),owner_device:Id128(2),stream_id:Id128(3),
            config_generation:1,topology_generation:1,window_id:Id128(4),drag_id:Id128(5),sequence:2,
            result:DesktopWindowMoveResult::Ended,
            actual_bounds:DesktopRect { x_millidip:0,y_millidip:0,width_millidip:640000,height_millidip:480000 },
        };
        let (response,_)=oneshot::channel();
        sender.send(AtlasInputRecoveryRequest {
            confirmation:NativeGeometryControl::Desktop { ack,native_sequence:3 },
            deadline:Instant::now()+Duration::from_secs(5),response,
        }).await.unwrap();
        // This is the exact queue-admission check used by the Windows receive
        // loop after it finishes the current frame. Desktop never arms a fence.
        let request=receiver.try_recv().unwrap();
        request.confirmation.validate_media_fence(fence.is_armed()).unwrap();
        let expired=Instant::now()-Duration::from_secs(30);
        assert!(request.confirmation.native_write_deadline(expired)>Instant::now());
        assert_eq!(NativeGeometryControl::Input(confirmation()).native_write_deadline(expired),expired);
        let forward=fence.begin_media_forward().await.unwrap();
        drop(forward);
        let input=NativeGeometryControl::Input(confirmation());
        assert!(input.validate_media_fence(fence.is_armed()).is_err());
        fence.arm().await;
        input.validate_media_fence(fence.is_armed()).unwrap();
        request.confirmation.validate_media_fence(fence.is_armed()).unwrap();
        assert!(fence.is_armed()); // A geometry receipt must not clear recovery.
    }

    fn confirmation() -> crate::atlas_input_recovery::InputRecoveryConfirmation {
        crate::atlas_input_recovery::InputRecoveryConfirmation {
            rejection: None,
            sequence: 1,
            stream: 2,
            window: 3,
            atlas_epoch: 4,
            config_generation: 5,
            previous_epoch: 7,
            geometry_epoch: 8,
            grant_generation: 12,
            atlas_frame: 9,
            source_frame: 10,
            placement_generation: 11,
            deadline_qpc: 100,
            frequency: 10,
        }
    }

    #[test]
    fn recovery_control_requires_every_newest_committed_tile_identity() {
        let committed = committed();
        assert!(recovery_matches_committed(confirmation(), &committed));
        let changes = [
            |c: &mut crate::atlas_input_recovery::InputRecoveryConfirmation| c.stream = 20,
            |c: &mut crate::atlas_input_recovery::InputRecoveryConfirmation| c.window = 30,
            |c: &mut crate::atlas_input_recovery::InputRecoveryConfirmation| c.atlas_epoch = 40,
            |c: &mut crate::atlas_input_recovery::InputRecoveryConfirmation| {
                c.config_generation = 50
            },
            |c: &mut crate::atlas_input_recovery::InputRecoveryConfirmation| c.atlas_frame = 90,
            |c: &mut crate::atlas_input_recovery::InputRecoveryConfirmation| c.geometry_epoch = 80,
            |c: &mut crate::atlas_input_recovery::InputRecoveryConfirmation| c.source_frame = 100,
            |c: &mut crate::atlas_input_recovery::InputRecoveryConfirmation| {
                c.placement_generation = 110
            },
        ];
        for change in changes {
            let mut confirmation = confirmation();
            change(&mut confirmation);
            assert!(!recovery_matches_committed(confirmation, &committed));
        }
    }

    #[test]
    fn cancellation_can_name_retained_frame_but_resume_requires_newest_exact_tile() {
        use crate::atlas_input_recovery::{InputRejectionControl, InputRejectionKind};
        let committed = committed();
        let mut c = confirmation();
        c.previous_epoch = c.geometry_epoch;
        c.atlas_frame -= 1;
        c.source_frame -= 1;
        c.grant_generation = 0;
        c.rejection = Some(InputRejectionControl {
            kind: InputRejectionKind::Cancel,
            cancel_sequence: c.sequence,
            previous_atlas_frame: c.atlas_frame,
            previous_source_frame: c.source_frame,
        });
        assert!(c.encode().is_ok());
        assert!(recovery_matches_committed(c, &committed));
        assert!(!recovery_matches_committed(
            crate::atlas_input_recovery::InputRecoveryConfirmation {
                geometry_epoch: c.geometry_epoch + 1,
                ..c
            },
            &committed
        ));
        assert!(!recovery_matches_committed(
            crate::atlas_input_recovery::InputRecoveryConfirmation {
                placement_generation: c.placement_generation + 1,
                ..c
            },
            &committed
        ));
        assert!(!recovery_matches_committed(
            crate::atlas_input_recovery::InputRecoveryConfirmation {
                atlas_frame: committed.frame_id + 1,
                ..c
            },
            &committed
        ));
        // Snap may advance geometry and atlas placement before cancellation
        // reaches the media owner. Cancelling the old input still names this
        // window; resuming below must name the exact new committed tile.
        let mut snapped = committed.clone();
        snapped.tiles[0].geometry_epoch += 1;
        snapped.tiles[0].placement_generation += 1;
        assert!(recovery_matches_committed(c, &snapped));
        c.rejection.as_mut().unwrap().kind = InputRejectionKind::Resume;
        c.sequence += 1;
        c.grant_generation = 20;
        assert!(c.encode().is_ok());
        assert!(!recovery_matches_committed(c, &committed));
        c.atlas_frame = committed.frame_id;
        c.source_frame = committed.tiles[0].source_frame_id;
        assert!(recovery_matches_committed(c, &committed));
    }

    #[tokio::test]
    async fn rejected_selection_retry_wakes_media_wait_without_resuming_input() {
        let fence = AtlasInputRecoveryFence::default();
        fence.arm().await;
        let wait = {
            let fence = fence.clone();
            tokio::spawn(async move { fence.cleared().await })
        };
        tokio::task::yield_now().await;
        assert!(!wait.is_finished());
        fence.retry_cancelled_selection();
        tokio::time::timeout(Duration::from_millis(20), wait)
            .await
            .unwrap()
            .unwrap();
        assert!(fence.begin_media_forward().await.is_ok());
        // Also cover a clear that preceded the wait's first poll.
        tokio::time::timeout(Duration::from_millis(20), fence.cleared())
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn recovery_fence_wakes_idle_reception_but_finishes_ready_admission() {
        let fence = AtlasInputRecoveryFence::default();
        let forward = fence.begin_media_forward().await.unwrap();
        let armer = {
            let fence = fence.clone();
            tokio::spawn(async move { fence.arm().await })
        };
        let error = tokio::time::timeout(
            Duration::from_millis(100),
            fence.wait_before_admission(std::future::pending::<Result<()>>()),
        )
        .await
        .unwrap()
        .unwrap_err();
        assert!(error.is::<AtlasMediaFenced>());
        assert!(!armer.is_finished());
        // A ready receive wins and is processed even when arming and readiness
        // are observed in the same poll.
        assert_eq!(
            fence.wait_before_admission(async { Ok(42) }).await.unwrap(),
            42
        );
        drop(forward);
        armer.await.unwrap();
        fence.clear();
        assert!(fence.begin_media_forward().await.is_ok());
    }

    #[tokio::test]
    async fn recovery_fence_finishes_crossed_forward_then_rejects_later_admission() {
        let fence = AtlasInputRecoveryFence::default();
        // This models a frame already admitted for native submission.
        let forward = fence.begin_media_forward().await.unwrap();
        let armer = {
            let fence = fence.clone();
            tokio::spawn(async move { fence.arm().await })
        };
        for _ in 0..8 {
            if fence.is_armed() {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert!(fence.is_armed());
        // This already-admitted frame must finish its handoff. The armer cannot publish a
        // cancellation or sample its final committed identity until it ends.
        assert!(!armer.is_finished());
        drop(forward);
        armer.await.unwrap();
        let error = fence.begin_media_forward().await.unwrap_err();
        assert!(error.is::<AtlasMediaFenced>());
        fence.clear();
        assert!(fence.begin_media_forward().await.is_ok());
    }
}

type ActivityCompletion = (viewflow_protocol::AtlasFrame, Result<crate::atlas_presenter::AtlasDisposition>, Instant);
type ActivityHandoff = std::pin::Pin<Box<dyn std::future::Future<Output = ActivityCompletion> + Send>>;

async fn next_activity_completion(pending: &mut Vec<ActivityHandoff>) -> ActivityCompletion {
    let (index, completion) = std::future::poll_fn(|cx| {
        for (index, handoff) in pending.iter_mut().enumerate() {
            if let std::task::Poll::Ready(completion) = handoff.as_mut().poll(cx) {
                return std::task::Poll::Ready((index, completion));
            }
        }
        std::task::Poll::Pending
    }).await;
    drop(pending.remove(index));
    completion
}

pub struct AtlasReceiverPresenter {
    activity: Option<crate::atlas_presenter_child::ActivityPresenterHandle>,
    activity_pending: Vec<ActivityHandoff>,
    activity_boundary: Option<tokio::sync::OwnedMutexGuard<()>>,
    activity_committed: std::collections::VecDeque<viewflow_protocol::AtlasFrame>,
    active: Option<(AtlasReceiverSession, AtlasPresenterChild)>,
    committed: Option<
        tokio::sync::watch::Sender<std::collections::VecDeque<viewflow_protocol::AtlasFrame>>,
    >,
    // This is intentionally distinct from the bounded history published to
    // pointer input. Recovery may name only the most recently committed native
    // layout; a historical visual commit must never be retagged as current.
    last_committed: Option<viewflow_protocol::AtlasFrame>,
    // Armed only by the media-owner recovery transaction.  A caller must
    // serialize `forward_next_*` and request handling; this flag makes an
    // accidental next submission fail before it can race the V6 control.
    recovery_fenced: bool,
    recovery_fence: AtlasInputRecoveryFence,
}

pub struct AtlasReceiverInput {
    pub native: tokio::sync::mpsc::Receiver<crate::atlas_pointer::AtlasNativePointer>,
    pub controls: tokio::sync::mpsc::Receiver<viewflow_protocol::DomainControl>,
    pub committed:
        tokio::sync::watch::Receiver<std::collections::VecDeque<viewflow_protocol::AtlasFrame>>,
}

/// Explicitly recovery-capable input ownership.  The cancellation/drain queue
/// is separate from ordinary native pointers, so a notice can never be
/// interpreted as a mouse/key event.
pub struct AtlasReceiverRecoveryInput {
    pub input: AtlasReceiverInput,
    pub notices: tokio::sync::mpsc::Receiver<crate::atlas_input_recovery::NativeRecoveryNotice>,
    pub fence: AtlasInputRecoveryFence,
}

/// Recovery-capable input ownership with the distinct native desktop-move
/// intent queue. Desktop records never share the pointer or recovery lanes.
pub struct AtlasReceiverDesktopInput {
    pub input: AtlasReceiverInput,
    pub notices: tokio::sync::mpsc::Receiver<crate::atlas_input_recovery::NativeRecoveryNotice>,
    pub moves: tokio::sync::mpsc::Receiver<crate::desktop_pointer::AtlasDesktopMove>,
    pub fence: AtlasInputRecoveryFence,
}

impl AtlasReceiverPresenter {
    pub(crate) fn enable_activity(&mut self,
        clock: impl Fn() -> Result<(u64, u64)> + Send + Sync + 'static,
    ) -> Result<()> {
        let (receiver, child) = self.active.as_mut().context("atlas owner retired")?;
        ensure!(receiver.activity_enabled(), "atlas activity was not negotiated");
        self.activity = Some(child.enable_activity(clock)?);
        Ok(())
    }

    async fn finish_activity(&mut self, completion: ActivityCompletion)
        -> Result<crate::atlas_feedback::AtlasFrameDisposition> {
        use crate::{atlas_presenter::AtlasDisposition, atlas_feedback::AtlasFrameDisposition};
        let (frame, result, delivery) = completion;
        let disposition = match result? {
            AtlasDisposition::ExpiredUnbound => AtlasFrameDisposition::ExpiredUnbound,
            AtlasDisposition::Superseded => AtlasFrameDisposition::Superseded,
            AtlasDisposition::CommittedWithinDeadline { .. } | AtlasDisposition::CommittedLate { .. } => AtlasFrameDisposition::Committed,
        };
        self.active.as_mut().context("atlas owner retired")?.0
            .report_disposition(&frame, disposition, delivery + Duration::from_millis(125)).await?;
        if disposition == AtlasFrameDisposition::Committed {
            self.last_committed = Some(frame.clone());
            self.activity_committed.push_back(frame.clone());
            if self.activity_committed.len() > 32 { self.activity_committed.pop_front(); }
            if let Some(committed) = &self.committed {
                ensure!(!committed.is_closed(), "atlas input layout owner disappeared");
                committed.send_modify(|history| {
                    history.push_back(frame);
                    if history.len() > 32 { history.pop_front(); }
                });
            }
        }
        if self.activity_pending.is_empty() { self.activity_boundary.take(); }
        Ok(disposition)
    }

    async fn drain_activity(&mut self) -> Result<()> {
        while !self.activity_pending.is_empty() {
            let completion = next_activity_completion(&mut self.activity_pending).await;
            if let Err(error) = self.finish_activity(completion).await {
                return Err(self.retire(error).await);
            }
        }
        self.activity_boundary.take();
        Ok(())
    }

    async fn forward_activity(&mut self, mut now: impl FnMut() -> u64,
        mut qpc: impl FnMut() -> Result<QpcSample>, deadline: Instant, max_record_bytes: usize,
    ) -> Result<crate::atlas_feedback::AtlasFrameDisposition> {
        ensure!(!self.recovery_fenced, "atlas recovery transaction is active");
        let result = async {
            loop {
                self.active.as_mut().context("atlas owner retired")?.1.check_activity_health().await?;
                if self.recovery_fence.is_armed() {
                    if self.activity_pending.is_empty() {
                        self.activity_boundary.take();
                        return Err(AtlasMediaFenced.into());
                    }
                    let completion = next_activity_completion(&mut self.activity_pending).await;
                    return self.finish_activity(completion).await;
                }
                if self.activity_boundary.is_none() {
                    self.activity_boundary = Some(self.recovery_fence.begin_media_forward().await?);
                }
                let receiver = &mut self.active.as_mut().context("atlas owner retired")?.0;
                let frame = tokio::select! {
                    // Poll existing handoffs before admitting more work, so a
                    // completed background lane also gets its feedback promptly.
                    biased;
                    completion = next_activity_completion(&mut self.activity_pending), if !self.activity_pending.is_empty() => {
                        return self.finish_activity(completion).await;
                    },
                    frame = receiver.next_frame_with_fence(&mut now, deadline, Some(&self.recovery_fence)) => frame,
                };
                let frame = match frame {
                    Ok(frame) => frame,
                    Err(error) if error.is::<AtlasMediaFenced>() && !self.activity_pending.is_empty() => continue,
                    Err(error) if error.is::<AtlasWaitExpired>() && !self.activity_pending.is_empty() => {
                        // The receive cadence elapsed, but native work owns its
                        // separate watchdog and must still finish.
                        let completion = next_activity_completion(&mut self.activity_pending).await;
                        return self.finish_activity(completion).await;
                    }
                    Err(error) => return Err(error),
                };
                ensure!(self.activity_pending.len() < 2, "atlas native lane capacity exceeded");
                let sample = qpc()?;
                let remaining = receiver.admission.remaining_budget_ns(&frame.layout, now())
                    .or_else(|error| match error {
                        crate::atlas_runtime::AtlasAdmissionError::Expired => Ok(0),
                        error => Err(anyhow::anyhow!("atlas activity handoff invalid: {error:?}")),
                    })?;
                let native = if u128::from(remaining) * u128::from(sample.frequency) < 1_000_000_000 {
                    // A sub-tick performance target is already missed at this
                    // clock's precision; it is not a connection failure.
                    NativePresentationDeadline { ticks: sample.ticks.max(1), frequency: sample.frequency }
                } else { NativePresentationDeadline::from_remaining_budget(sample.ticks, sample.frequency, remaining)? };
                let delivery = Instant::now() + Duration::from_secs(5);
                let pipe = self.activity.as_ref().context("atlas activity pipe unavailable")?.clone();
                self.activity_pending.push(Box::pin(async move {
                    let result = pipe.submit(&frame, native, delivery, max_record_bytes).await;
                    (frame.layout, result, delivery)
                }));
            }
        }.await;
        if result.as_ref().is_err_and(|error| error.is::<AtlasWaitExpired>() || error.is::<AtlasMediaFenced>()) {
            if self.activity_pending.is_empty() { self.activity_boundary.take(); }
            return result;
        }
        match result {
            Ok(result) => Ok(result),
            Err(error) => Err(self.retire(error).await),
        }
    }

    /// Prepare the real native pointer producer and the sole media/control
    /// reader together. Returned input receivers must be supervised with media.
    /// # Errors
    /// No fallback to input-disabled or legacy native modes is permitted.
    pub async fn accept_warmed_pointer_events(
        connection: &quinn::Connection,
        plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        deadline: Instant,
    ) -> Result<(Self, AtlasReceiverInput)> {
        Self::accept_warmed_pointer_mode(connection, plan, executable, deadline, false).await
    }

    /// # Errors
    /// Requires the exact native capability; never falls back to buttons-only.
    pub async fn accept_warmed_pointer_mode(
        connection: &quinn::Connection,
        plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        deadline: Instant,
        wheel: bool,
    ) -> Result<(Self, AtlasReceiverInput)> {
        Self::accept_warmed_input_capabilities(connection, plan, executable, deadline, wheel, false)
            .await
    }

    /// # Errors
    /// Rejects unsupported native keyboard capability without any fallback.
    pub async fn accept_warmed_input_capabilities(
        connection: &quinn::Connection,
        plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        deadline: Instant,
        wheel: bool,
        keyboard: bool,
    ) -> Result<(Self, AtlasReceiverInput)> {
        let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
        let (mut child, native) = AtlasPresenterChild::spawn_with_input_capabilities_codec(
            executable,
            native_record_limit(plan)?,
            plan.policy.max_tiles,
            deadline,
            wheel,
            keyboard,
            plan.color.codec,
        )
        .await?;
        let max_record = crate::atlas_session::warmup_limit(plan)?;
        let child_ref = &mut child;
        let result = crate::atlas_session::accept_warmed_atlas_dispositions(
            connection,
            plan,
            deadline,
            |frames| async move { child_ref.warmup(&frames, deadline, max_record).await },
        )
        .await;
        let mut receiver = match result {
            Ok(receiver) => receiver,
            Err(error) => {
                child.shutdown().await?;
                return Err(error);
            }
        };
        let (send_controls, controls) = tokio::sync::mpsc::channel(64);
        receiver.attach_shared_controls(send_controls)?;
        let (send_committed, committed) =
            tokio::sync::watch::channel(std::collections::VecDeque::new());
        let mut owner = Self::new(receiver, child);
        owner.committed = Some(send_committed);
        guard.0 = None;
        Ok((
            owner,
            AtlasReceiverInput {
                native,
                controls,
                committed,
            },
        ))
    }

    /// Launch the one opt-in recovery-capable native mode.  Normal receiver
    /// startup never calls this method.  The caller must wire `notices` to an
    /// `AtlasPreviewInput::with_input_recovery` supervisor and keep recovery
    /// requests on this presenter's sole media-owner task.
    /// # Errors
    /// No capability downgrade is permitted; all startup errors retire the
    /// native child and the admitted receiver together.
    pub async fn accept_warmed_input_recovery(
        connection: &quinn::Connection,
        mut plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        deadline: Instant,
    ) -> Result<(Self, AtlasReceiverRecoveryInput)> {
        let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
        let (mut child, native, notices) = AtlasPresenterChild::spawn_with_input_recovery_codec_activity(
            executable,
            native_record_limit(plan)?,
            plan.policy.max_tiles,
            deadline,
            plan.color.codec,
            plan.activity_priority_version == 1,
        )
        .await?;
        if !child.activity_capable() { plan.activity_priority_version = 0; }
        let max_record = crate::atlas_session::warmup_limit(plan)?;
        let child_ref = &mut child;
        let result = crate::atlas_session::accept_warmed_atlas_dispositions(
            connection,
            plan,
            deadline,
            |frames| async move { child_ref.warmup(&frames, deadline, max_record).await },
        )
        .await;
        let mut receiver = match result {
            Ok(receiver) => receiver,
            Err(error) => {
                child.shutdown().await?;
                return Err(error);
            }
        };
        let (send_controls, controls) = tokio::sync::mpsc::channel(64);
        receiver.attach_shared_controls(send_controls)?;
        let (send_committed, committed) =
            tokio::sync::watch::channel(std::collections::VecDeque::new());
        let mut owner = Self::new(receiver, child);
        owner.committed = Some(send_committed);
        #[cfg(windows)]
        if owner.active.as_ref().is_some_and(|(receiver, _)| receiver.activity_enabled()) {
            owner.enable_activity(|| {
                let sample = QpcSample::current()?;
                Ok((sample.ticks, sample.frequency))
            })?;
        }
        let fence = owner.recovery_fence.clone();
        guard.0 = None;
        Ok((
            owner,
            AtlasReceiverRecoveryInput {
                input: AtlasReceiverInput {
                    native,
                    controls,
                    committed,
                },
                notices,
                fence,
            },
        ))
    }

    /// Launch the native desktop route with the same recovery fence and
    /// ownership contract as input recovery. The move queue is returned to the
    /// preview supervisor, while recovery requests remain serialized by this
    /// presenter's media owner.
    /// # Errors
    /// No desktop/pointer/recovery capability downgrade is permitted; every
    /// startup failure retires the native child before returning.
    pub async fn accept_warmed_desktop(
        connection: &quinn::Connection,
        mut plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        desktop: crate::desktop_config::AtlasReceiverDesktopConfig,
        deadline: Instant,
    ) -> Result<(Self, AtlasReceiverDesktopInput)> {
        let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
        let (mut child, native, notices, moves) = AtlasPresenterChild::spawn_with_desktop_activity(
            executable,
            native_record_limit(plan)?,
            plan.policy.max_tiles,
            desktop,
            plan.color.codec,
            deadline,
            plan.activity_priority_version == 1,
        )
        .await?;
        if !child.activity_capable() { plan.activity_priority_version = 0; }
        let max_record = crate::atlas_session::warmup_limit(plan)?;
        let child_ref = &mut child;
        let result = crate::atlas_session::accept_warmed_atlas_dispositions(
            connection,
            plan,
            deadline,
            |frames| async move { child_ref.warmup(&frames, deadline, max_record).await },
        )
        .await;
        let mut receiver = match result {
            Ok(receiver) => receiver,
            Err(error) => {
                child.shutdown().await?;
                return Err(error);
            }
        };
        let (send_controls, controls) = tokio::sync::mpsc::channel(64);
        receiver.attach_shared_controls(send_controls)?;
        let (send_committed, committed) =
            tokio::sync::watch::channel(std::collections::VecDeque::new());
        let mut owner = Self::new(receiver, child);
        owner.committed = Some(send_committed);
        #[cfg(windows)]
        if owner.active.as_ref().is_some_and(|(receiver, _)| receiver.activity_enabled()) {
            owner.enable_activity(|| {
                let sample = QpcSample::current()?;
                Ok((sample.ticks, sample.frequency))
            })?;
        }
        let fence = owner.recovery_fence.clone();
        guard.0 = None;
        Ok((
            owner,
            AtlasReceiverDesktopInput {
                input: AtlasReceiverInput {
                    native,
                    controls,
                    committed,
                },
                notices,
                moves,
                fence,
            },
        ))
    }

    /// Opt in to V3 feedback only with a disposition-capable native child.
    /// # Errors
    /// No downgrade is permitted; startup failure retires both owned ends.
    pub async fn accept_warmed_dispositions(
        connection: &quinn::Connection,
        plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        deadline: Instant,
    ) -> Result<Self> {
        let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
        let mut child = AtlasPresenterChild::spawn_with_dispositions_codec(
            executable,
            native_record_limit(plan)?,
            plan.policy.max_tiles,
            deadline,
            plan.color.codec,
        )
        .await?;
        let max_record = crate::atlas_session::warmup_limit(plan)?;
        let child_ref = &mut child;
        let result = crate::atlas_session::accept_warmed_atlas_dispositions(
            connection,
            plan,
            deadline,
            |frames| async move { child_ref.warmup(&frames, deadline, max_record).await },
        )
        .await;
        match result {
            Ok(receiver) => {
                guard.0 = None;
                Ok(Self::new(receiver, child))
            }
            Err(error) => {
                child.shutdown().await?;
                Err(error)
            }
        }
    }

    /// Forward a V3 frame, then send only its validated native disposition.
    /// # Errors
    /// Ambiguous handoff, clock, feedback failures and cancellation retire both
    /// ends. A waiting-only timeout still preserves the receiver pump.
    pub async fn forward_next_disposition_with_clock(
        &mut self,
        mut now: impl FnMut() -> u64,
        mut sample_qpc: impl FnMut() -> Result<QpcSample>,
        deadline: Instant,
        max_record_bytes: usize,
    ) -> Result<crate::atlas_feedback::AtlasFrameDisposition> {
        if self.activity.is_some() {
            return self.forward_activity(&mut now, &mut sample_qpc, deadline, max_record_bytes).await;
        }
        ensure!(
            !self.recovery_fenced,
            "atlas native recovery transaction is active"
        );
        // Own admission through reception, native submission, and disposition.
        // An armer marks the fence immediately but waits for this guard: it
        // cannot issue Cancel/Resume or freeze a committed identity mid-forward.
        let _forward_boundary = self.recovery_fence.begin_media_forward().await?;
        let result = self
            .active
            .as_mut()
            .context("atlas owner retired")?
            .0
            .next_frame_with_fence(&mut now, deadline, Some(&self.recovery_fence))
            .await;
        let frame = match result {
            Ok(frame) => frame,
            Err(error) if error.downcast_ref::<AtlasWaitExpired>().is_some() => return Err(error),
            Err(error) if error.is::<AtlasMediaFenced>() => return Err(error),
            Err(error) => return Err(self.retire(error).await),
        };
        // The admission guard predates any concurrent arm. Finish this exact
        // frame under its original deadline; never defer, retag or cancel it.
        let (mut receiver, mut presenter) = self.active.take().context("atlas owner missing")?;
        let result = async {
            let instant = Instant::now();
            let qpc = sample_qpc()?;
            let source_remaining = receiver
                .admission
                .remaining_budget_ns(&frame.layout, now())
                .or_else(|error| match error {
                    crate::atlas_runtime::AtlasAdmissionError::Expired => Ok(0),
                    error => Err(anyhow::anyhow!("atlas handoff invalid: {error:?}")),
                })?;
            if instant >= deadline {
                let result = crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound;
                receiver.report_disposition(&frame.layout, result, instant + Duration::from_secs(5)).await?;
                return Ok(result);
            }
            let call_remaining = u64::try_from(
                deadline
                    .saturating_duration_since(Instant::now())
                    .as_nanos(),
            )
            .unwrap_or(u64::MAX);
            let remaining = source_remaining.min(call_remaining);
            let native = if u128::from(remaining) * u128::from(qpc.frequency) < 1_000_000_000 {
                // Already missed: preserve that fact in QPC while completing
                // the sole latest frame under the separate operation watchdog.
                NativePresentationDeadline { ticks: qpc.ticks.max(1), frequency: qpc.frequency }
            } else {
                NativePresentationDeadline::from_remaining_budget(qpc.ticks, qpc.frequency, remaining)?
            };
            // The frame freshness target remains in native QPC. Once handoff
            // starts, finish it under a separate stalled-operation watchdog.
            let delivery = instant + Duration::from_secs(5);
            let result = receiver
                .with_handoff_controls(presenter.submit_disposition(
                    &frame,
                    native,
                    delivery,
                    max_record_bytes,
                    || {
                        let sample = sample_qpc()?;
                        Ok((sample.ticks, sample.frequency))
                    },
                ))
                .await?;
            let result = match result {
                crate::atlas_presenter::AtlasDisposition::Superseded => {
                    crate::atlas_feedback::AtlasFrameDisposition::Superseded
                }
                crate::atlas_presenter::AtlasDisposition::ExpiredUnbound => {
                    crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound
                }
                crate::atlas_presenter::AtlasDisposition::CommittedWithinDeadline { .. } => {
                    crate::atlas_feedback::AtlasFrameDisposition::Committed
                }
                crate::atlas_presenter::AtlasDisposition::CommittedLate { commit_ticks } => {
                    if frame.layout.frame_id % 60 == 0 {
                        let line = format!("atlas-performance-target-missed frame={} commit_ticks={commit_ticks} target_ticks={}\n", frame.layout.frame_id, native.ticks);
                        use std::io::Write;
                        let _ = std::io::stderr().lock().write_all(line.as_bytes());
                    }
                    crate::atlas_feedback::AtlasFrameDisposition::Committed
                }
            };
            receiver
                .report_disposition(&frame.layout, result, delivery + Duration::from_millis(125))
                .await?;
            if result == crate::atlas_feedback::AtlasFrameDisposition::Committed {
                self.last_committed = Some(frame.layout.clone());
            }
            if let Some(committed) = &self.committed {
                anyhow::ensure!(
                    !committed.is_closed(),
                    "atlas input layout owner disappeared"
                );
                if result == crate::atlas_feedback::AtlasFrameDisposition::Committed {
                    committed.send_modify(|history| {
                        history.push_back(frame.layout.clone());
                        if history.len() > 32 {
                            history.pop_front();
                        }
                    });
                }
            }
            Ok(result)
        }
        .await;
        match result {
            Ok(result) => {
                self.active = Some((receiver, presenter));
                Ok(result)
            }
            Err(error) => {
                drop(receiver);
                match presenter.shutdown().await {
                    Ok(()) => Err(error),
                    Err(stop) => Err(error.context(format!("atlas child shutdown failed: {stop}"))),
                }
            }
        }
    }

    /// Launch the native child and negotiate version-2 startup on a dedicated,
    /// paired connection. Acceptance is withheld until all three source warmup
    /// pictures have completed native decode/unbound copy. Call from a desktop
    /// session that supports Windows Composition.
    /// # Errors
    /// Startup failures terminate/reap the child; cancellation kills it on drop.
    pub async fn accept_warmed(
        connection: &quinn::Connection,
        plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        deadline: Instant,
    ) -> Result<Self> {
        let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
        let limit = native_record_limit(plan)?;
        let child = AtlasPresenterChild::spawn_with_capacity_codec(
            executable,
            limit,
            plan.policy.max_tiles,
            deadline,
            plan.color.codec,
        )
        .await?;
        let owner = Self::accept_with_child(connection, plan, child, deadline).await?;
        guard.0 = None;
        Ok(owner)
    }

    pub(crate) async fn accept_with_child(
        connection: &quinn::Connection,
        plan: crate::atlas_session::AtlasSessionPlan,
        mut child: AtlasPresenterChild,
        deadline: Instant,
    ) -> Result<Self> {
        let result = async {
            let max_record = crate::atlas_session::warmup_limit(plan)?;
            let child_ref = &mut child;
            crate::atlas_session::accept_warmed_atlas(
                connection,
                plan,
                deadline,
                |frames| async move { child_ref.warmup(&frames, deadline, max_record).await },
            )
            .await
        }
        .await;
        match result {
            Ok(receiver) => Ok(Self::new(receiver, child)),
            Err(error) => match child.shutdown().await {
                Ok(()) => Err(error),
                Err(stop) => {
                    Err(error.context(format!("atlas startup child shutdown failed: {stop}")))
                }
            },
        }
    }

    pub fn new(receiver: AtlasReceiverSession, presenter: AtlasPresenterChild) -> Self {
        Self {
            activity: None,
            activity_pending: Vec::with_capacity(2),
            activity_boundary: None,
            activity_committed: Default::default(),
            active: Some((receiver, presenter)),
            committed: None,
            last_committed: None,
            recovery_fenced: false,
            recovery_fence: AtlasInputRecoveryFence::default(),
        }
    }

    /// Submit one already-authorized native recovery control.  This is an
    /// exclusive media-owner operation: callers must not attempt it from the
    /// pointer/control task, and a failure retires the owned child.  Do not
    /// race this with, or cancel, a `forward_next_*` future in `select!`;
    /// drain the admitted handoff first, then service this request on the same
    /// owner task.
    ///
    /// `confirmation` is intentionally not a source authorization.  It is
    /// accepted only when every visual identity field names the exact newest
    /// native committed tile retained by this owner.
    /// # Errors
    /// A stale/mismatched request or any child failure retires the presenter;
    /// the caller must treat the response as terminal and retire its input
    /// route rather than retrying a control record.
    pub async fn recover_input_with_clock(
        &mut self,
        confirmation: crate::atlas_input_recovery::InputRecoveryConfirmation,
        deadline: Instant,
        clock: impl FnMut() -> Result<(u64, u64)>,
    ) -> Result<u64> {
        ensure!(
            !self.recovery_fenced,
            "atlas input recovery transaction is already active"
        );
        self.recovery_fenced = true;
        let (receiver, mut child) = self.active.take().context("atlas owner retired")?;
        // A mismatched request is terminal just like a malformed control
        // record.  Taking ownership before validation prevents a supervisor
        // from probing stale historical tiles and then continuing this child.
        let committed = if self.activity.is_some() {
            self.activity_committed.iter().rev().find(|frame|
                frame.tiles.iter().any(|tile| tile.window_id.0 == confirmation.window))
        } else { self.last_committed.as_ref() };
        let result = committed
            .context("atlas input recovery has no committed native layout")
            .and_then(|committed| {
                ensure!(
                    recovery_matches_committed(confirmation, committed),
                    "atlas input recovery does not match newest committed tile"
                );
                Ok(())
            });
        let result = match result {
            Ok(()) => child.recover_input(confirmation, deadline, clock).await,
            Err(error) => Err(error),
        };
        match result {
            Ok(recovered) => {
                self.active = Some((receiver, child));
                self.recovery_fenced = false;
                self.recovery_fence.clear();
                Ok(recovered)
            }
            Err(error) => {
                drop(receiver);
                match child.shutdown().await {
                    Ok(()) => Err(error),
                    Err(stop) => {
                        Err(error.context(format!("atlas recovery child shutdown failed: {stop}")))
                    }
                }
            }
        }
    }

    /// Wait for the recovery request while continuing the sole reliable source
    /// control pump. A fresh grant must reach the input supervisor before it
    /// can create Resume; freezing this reader would deadlock that exchange.
    pub(crate) async fn wait_input_recovery_request(
        &mut self,
        requests: &mut tokio::sync::mpsc::Receiver<AtlasInputRecoveryRequest>,
        deadline: Instant,
    ) -> Result<Option<AtlasInputRecoveryRequest>> {
        ensure!(
            !self.recovery_fenced,
            "atlas recovery request wait requires an idle fence"
        );
        if !self.recovery_fence.is_armed() {
            return Ok(None);
        }
        self.drain_activity().await?;
        let fence = self.recovery_fence.clone();
        let waiting = async {
            tokio::time::timeout_at(deadline, async {
                tokio::select! {
                    () = fence.cleared() => Ok(None),
                    request = requests.recv() => request.map(Some)
                        .context("atlas recovery input owner closed before its media request"),
                }
            })
            .await
            .context("atlas recovery media-owner request wait expired")?
        };
        let result = self
            .active
            .as_mut()
            .context("atlas owner retired")?
            .0
            .with_fenced_controls(waiting)
            .await;
        match result {
            Ok(request) => Ok(request),
            Err(error) => Err(self.retire(error).await),
        }
    }

    /// Service an input-supervisor request on the sole media owner.  A dropped
    /// response receiver changes no recovery outcome; native work has either
    /// completed exactly or the child has been retired.
    pub async fn handle_input_recovery_with_clock(
        &mut self,
        request: AtlasInputRecoveryRequest,
        clock: impl FnMut() -> Result<(u64, u64)>,
    ) -> Result<()> {
        let deadline=request.confirmation.native_write_deadline(request.deadline);
        let result = match request.confirmation {
            NativeGeometryControl::Input(confirmation) => self.recover_input_with_clock(confirmation, deadline, clock).await,
            NativeGeometryControl::Desktop { ack, native_sequence } => {
                let (_, child) = self.active.as_mut().context("atlas owner retired")?;
                child.desktop_geometry_ack(ack, native_sequence, deadline).await
            }
        };
        // Both supervisors may race to report termination. Preserve the full
        // cause here even when the input owner cannot consume its response.
        let failure = result.as_ref().err().map(|error| format!("{error:#}"));
        let _ = request.response.send(result);
        if let Some(failure) = failure {
            anyhow::bail!("atlas input recovery transaction failed: {failure}")
        }
        Ok(())
    }

    /// Sample QPC on this host before computing the remaining original source
    /// budget. The `now` callback uses the already negotiated receiver clock.
    /// # Errors
    /// Waiting-only timeouts preserve the pump; handoff errors retire both ends.
    #[cfg(windows)]
    pub async fn forward_next(
        &mut self,
        now: impl FnMut() -> u64,
        deadline: Instant,
        max_record_bytes: usize,
    ) -> Result<AtlasVisualSubmission> {
        self.forward_next_with_clock(now, QpcSample::current, deadline, max_record_bytes)
            .await
    }

    /// Explicit clock-injection boundary for platform adapters and tests. The
    /// QPC callback must sample the native child's host, never a remote clock.
    /// # Errors
    /// Cancellation after admission drops the receiver and kills the owned
    /// child; it cannot continue a codec chain whose output was lost.
    pub async fn forward_next_with_clock(
        &mut self,
        mut now: impl FnMut() -> u64,
        sample_qpc: impl FnOnce() -> Result<QpcSample>,
        deadline: Instant,
        max_record_bytes: usize,
    ) -> Result<AtlasVisualSubmission> {
        ensure!(
            !self.recovery_fenced && !self.recovery_fence.is_armed(),
            "atlas media submission is fenced for input recovery"
        );
        let result = self
            .active
            .as_mut()
            .context("atlas receive/present owner retired")?
            .0
            .next_frame(&mut now, deadline)
            .await;
        let frame = match result {
            Ok(frame) => frame,
            Err(error) if error.downcast_ref::<AtlasWaitExpired>().is_some() => return Err(error),
            Err(error) => {
                return Err(self
                    .retire(error.context("atlas media admission failed"))
                    .await);
            }
        };
        // From here onward the codec has consumed a frame. State lives in the
        // future, so cancellation cannot restore either half of that session.
        let (receiver, mut presenter) = self.active.take().context("atlas owner missing")?;
        let result = async {
            let instant = Instant::now();
            let qpc = sample_qpc()?;
            let source_remaining = receiver
                .admission
                .remaining_budget_ns(&frame.layout, now())
                .map_err(|error| anyhow::anyhow!("atlas handoff expired: {error:?}"))?;
            let call_remaining = u64::try_from(
                deadline
                    .saturating_duration_since(Instant::now())
                    .as_nanos(),
            )
            .unwrap_or(u64::MAX);
            let remaining = source_remaining.min(call_remaining);
            let native = NativePresentationDeadline::from_remaining_budget(
                qpc.ticks,
                qpc.frequency,
                remaining,
            )?;
            let delivery = instant
                .checked_add(Duration::from_nanos(remaining))
                .context("atlas handoff deadline overflow")?
                .min(deadline);
            presenter
                .submit(&frame, native, delivery, max_record_bytes)
                .await
                .context("atlas native presentation handoff failed")
        }
        .await;
        match result {
            Ok(submitted) => {
                self.active = Some((receiver, presenter));
                Ok(submitted)
            }
            Err(error) => {
                drop(receiver);
                match presenter.shutdown().await {
                    Ok(()) => Err(error),
                    Err(stop) => Err(error.context(format!("atlas child shutdown failed: {stop}"))),
                }
            }
        }
    }

    async fn retire(&mut self, error: anyhow::Error) -> anyhow::Error {
        self.activity_pending.clear();
        self.activity.take();
        self.activity_boundary.take();
        if let Some((receiver, child)) = self.active.take() {
            drop(receiver);
            if let Err(stop) = child.shutdown().await {
                return error.context(format!("atlas child shutdown failed: {stop}"));
            }
        }
        error
    }

    /// # Errors
    /// Reports failure to terminate/reap the native child.
    pub async fn shutdown(mut self) -> Result<()> {
        if let Some((receiver, child)) = self.active.take() {
            drop(receiver);
            child.shutdown().await?;
        }
        Ok(())
    }
}

/// # Errors
/// Includes the largest authorized V5 tile header and the decoded allocation
/// budget, rather than silently imposing the legacy 16 MiB pipe default.
pub fn native_record_limit(plan: crate::atlas_session::AtlasSessionPlan) -> Result<usize> {
    let header = plan
        .policy
        .max_tiles
        .checked_mul(64)
        .and_then(|v| v.checked_add(112))
        .context("atlas header limit overflow")?;
    let header = if plan.activity_priority_version == 1 {
        header.checked_add(plan.policy.max_tiles.checked_mul(16)
            .and_then(|v| v.checked_add(52)).context("atlas activity header limit overflow")?)
            .context("atlas activity record limit overflow")?
    } else { header };
    let encoded = plan
        .policy
        .max_encoded_bytes
        .checked_add(header)
        .context("atlas encoded limit overflow")?;
    let limit = encoded.max(usize::try_from(plan.max_decoded_bytes)?);
    anyhow::ensure!(
        limit >= 112 && u32::try_from(limit).is_ok(),
        "native atlas limit out of range"
    );
    Ok(limit)
}

#[cfg(all(test, target_os = "linux"))]
mod activity_pipeline_tests {
    use super::*;

    #[tokio::test]
    async fn activity_owner_advances_priority_while_background_native_receipt_is_pending() {
        activity_owner_pipeline(false).await;
    }

    #[tokio::test]
    async fn activity_recovery_fence_drains_both_native_lanes_before_arming_completes() {
        activity_owner_pipeline(true).await;
    }

    async fn activity_owner_pipeline(fenced: bool) {
        use crate::atlas_session::{tests::{pair, plan, warmup_frames}, offer_warmed_atlas_dispositions,
            accept_warmed_atlas_dispositions};
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(4);
        let mut policy = plan();
        policy.activity_priority_version = 1;
        let frames = warmup_frames();
        // This fixture exercises pipe ownership and transport only. It never
        // creates windows, decodes pixels, or produces synthetic user input.
        let script = r#"
import sys, struct, os, time
def record():
    prefix = sys.stdin.buffer.read(16)
    if len(prefix) != 16: raise RuntimeError('missing record')
    size = sum(struct.unpack('>II', prefix[8:16]))
    data = prefix + sys.stdin.buffer.read(size-16)
    if len(data) != size: raise RuntimeError('partial record')
    return data
def identity(data): return struct.unpack('>Q', data[16:24])[0]
def receipt(data, outcome):
    ticks, frequency = struct.unpack('>QQ', data[40:56])
    commit = 100 if outcome == 'committed' else 0
    print(f'atlas-disposition-v1 frame_identity={identity(data)} tile_count=0 outcome={outcome} deadline_ticks={ticks} frequency={frequency} commit_ticks={commit} physical_present_receipt=false', flush=True)
print('atlas-native-ready disposition=v1 input_enabled=false activity=v11', flush=True)
for i in range(1, 4):
    data = record()
    print(f'atlas-warmup-completed identity={i} width=64 height=64', flush=True)
first, second = record(), record()
both = {identity(first): first, identity(second): second}
if os.environ.get('VF_TEST_FENCE') == '1':
    gate = os.environ['VF_TEST_GATE']
    open(gate + '/ready', 'w').close()
    while not os.path.exists(gate + '/resume'): time.sleep(0.001)
    receipt(both[5], 'committed')
    receipt(both[4], 'committed')
else:
    receipt(both[5], 'committed')
    third = record()
    assert identity(third) == 7
    receipt(both[4], 'superseded')
    receipt(third, 'committed')
sys.stdin.buffer.read()
"#;
        let mut command = tokio::process::Command::new("python3");
        command.args(["-u", "-c", script]);
        let gates = tempfile::tempdir().unwrap();
        command.env("VF_TEST_FENCE", if fenced { "1" } else { "0" }).env("VF_TEST_GATE", gates.path());
        let mut child = AtlasPresenterChild::spawn_activity_fixture(command, deadline).await.unwrap();
        let child_ref = &mut child;
        let (sender, receiver) = tokio::join!(
            offer_warmed_atlas_dispositions(&outbound, policy, &frames, deadline),
            accept_warmed_atlas_dispositions(&inbound, policy, deadline,
                |frames| async move { child_ref.warmup(&frames, deadline, 8192).await })
        );
        let mut background = sender.unwrap();
        let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
        background.attach_shared_control(writer.sender()).unwrap();
        let mut priority = background.fork_activity_lane().unwrap();
        let mut owner = AtlasReceiverPresenter::new(receiver.unwrap(), child);
        owner.enable_activity(|| Ok((100, 1000))).unwrap();
        let manifest = |id| viewflow_protocol::AtlasFrame {
            activity: Some(viewflow_protocol::AtlasActivity {
                lane: (id % 2) as u32, epoch: 1, preferred: None, focus: None, members: vec![],
            }),
            patches: None, stream_id: viewflow_protocol::Id128(99), frame_id: id,
            geometry_epoch: 1, config_generation: 1, layout_revision: 0, width: 64, height: 64,
            source_submitted_ns: 100 + id, tiles: vec![], color_keyframe: true, alpha_keyframe: true, desktop: None,
        };
        let priority_work = async {
            for &id in if fenced { &[5][..] } else { &[5, 7][..] } {
                priority.send_frame(manifest(id), frames[0].color.clone(), frames[0].alpha.clone(), id, deadline).await?;
            }
            Ok::<_, anyhow::Error>(())
        };
        let fence = owner.recovery_fence.clone();
        let arm_work = async {
            if !fenced { return; }
            while !gates.path().join("ready").exists() { tokio::time::sleep(Duration::from_millis(1)).await; }
            let arm = fence.arm();
            tokio::pin!(arm);
            // The native process has both full records and has emitted no
            // receipts. Arming must stay pending behind their shared boundary.
            std::future::poll_fn(|cx| {
                assert!(std::future::Future::poll(arm.as_mut(), cx).is_pending());
                std::task::Poll::Ready(())
            }).await;
            assert!(fence.is_armed());
            std::fs::write(gates.path().join("resume"), b"").unwrap();
            arm.await;
        };
        let receive_work = async {
            for _ in 0..if fenced { 1 } else { 3 } {
                owner.forward_next_disposition_with_clock(|| 110, || Ok(QpcSample { ticks: 100, frequency: 1000 }), deadline, 8192).await.unwrap();
            }
            if fenced { owner.drain_activity().await.unwrap(); }
            assert_eq!(owner.activity_committed.iter().map(|frame| frame.frame_id).collect::<Vec<_>>(), if fenced { vec![5, 4] } else { vec![5, 7] });
            assert!(owner.activity_pending.is_empty() && owner.activity_boundary.is_none());
        };
        let all = async { tokio::join!(
            background.send_frame(manifest(4), frames[0].color.clone(), frames[0].alpha.clone(), 4, deadline),
            priority_work, receive_work, arm_work,
        ) };
        let (background, priority, (), ()) = tokio::time::timeout_at(deadline, all).await.unwrap();
        background.unwrap();
        priority.unwrap();
        owner.shutdown().await.unwrap();
    }
}
