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
    pub confirmation: crate::atlas_input_recovery::InputRecoveryConfirmation,
    pub deadline: Instant,
    pub response: oneshot::Sender<Result<u64>>,
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
        let _forward = self.0.forward_gate.lock().await;
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
    async fn recovery_fence_finishes_crossed_forward_then_rejects_later_admission() {
        let fence = AtlasInputRecoveryFence::default();
        // This models the media loop having crossed its boundary, then waiting
        // for a frame. The drain may arrive before that frame does.
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
        // This already-crossed forward may consume a delayed frame and must
        // finish its original bounded handoff. The armer cannot publish a
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

pub struct AtlasReceiverPresenter {
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
        let (mut child, native) = AtlasPresenterChild::spawn_with_input_capabilities(
            executable,
            native_record_limit(plan)?,
            plan.policy.max_tiles,
            deadline,
            wheel,
            keyboard,
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
        plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        deadline: Instant,
    ) -> Result<(Self, AtlasReceiverRecoveryInput)> {
        let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
        let (mut child, native, notices) = AtlasPresenterChild::spawn_with_input_recovery(
            executable,
            native_record_limit(plan)?,
            plan.policy.max_tiles,
            deadline,
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
        plan: crate::atlas_session::AtlasSessionPlan,
        executable: &std::path::Path,
        desktop: crate::desktop_config::AtlasReceiverDesktopConfig,
        deadline: Instant,
    ) -> Result<(Self, AtlasReceiverDesktopInput)> {
        let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
        let (mut child, native, notices, moves) = AtlasPresenterChild::spawn_with_desktop(
            executable,
            native_record_limit(plan)?,
            plan.policy.max_tiles,
            desktop,
            plan.color.codec,
            deadline,
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
        let mut child = AtlasPresenterChild::spawn_with_dispositions(
            executable,
            native_record_limit(plan)?,
            plan.policy.max_tiles,
            deadline,
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
            .next_frame(&mut now, deadline)
            .await;
        let frame = match result {
            Ok(frame) => frame,
            Err(error) if error.downcast_ref::<AtlasWaitExpired>().is_some() => return Err(error),
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
            let native = if remaining == 0 {
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
        let child = AtlasPresenterChild::spawn_with_capacity(
            executable,
            limit,
            plan.policy.max_tiles,
            deadline,
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
        let result = self
            .last_committed
            .as_ref()
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
        let result = self
            .recover_input_with_clock(request.confirmation, request.deadline, clock)
            .await;
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
