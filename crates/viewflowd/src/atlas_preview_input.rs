//! Receiver-side local window selection and ordered pointer forwarding.
use crate::{
    atlas_pointer::AtlasNativePointer,
    atlas_receiver_presenter::AtlasInputRecoveryRequest,
    window_preview_input::{
        PreviewPointerEvent, PreviewPointerEvents, PreviewPointerState, WindowPreviewInput,
    },
};
use anyhow::{Context, Result, ensure};
use std::{
    collections::{BTreeMap, VecDeque},
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot, watch};
use viewflow_protocol::{AtlasFrame, DomainControl, Id128, WindowPointerAuthorization, wire};

// A cancellation control is not an input event, but it still must not wait
// indefinitely for source cleanup.  This is an owner-local bound; it is never
// copied into a source lease or used to extend a native event deadline.
const RECOVERY_SOURCE_SELECTION_BUDGET_NS: u64 = 100_000_000;
const RECOVERY_NATIVE_BUDGET_NS: u64 = 100_000_000;

// Existing exact-frame authority cannot answer a newly issued selection: the
// source may reject that selection and END the old grant. Keep its event behind
// the exact source receipt, independently of unsolicited grant announcements.
struct AwaitingSelection {
    selection: viewflow_protocol::AtlasWindowSelection,
    authorized: bool,
}

impl AwaitingSelection {
    fn new(selection: viewflow_protocol::AtlasWindowSelection) -> Self {
        Self {
            selection,
            authorized: false,
        }
    }

    fn accept(&mut self, accepted: viewflow_protocol::AtlasWindowSelectionAccepted) -> Result<()> {
        ensure!(
            self.selection == accepted.selection && !self.authorized,
            "selection acceptance does not name the outstanding request"
        );
        self.authorized = true;
        Ok(())
    }
}

struct PendingAtlasRecovery {
    notice: crate::atlas_input_recovery::NativeRecoveryNotice,
    selection: viewflow_protocol::AtlasWindowSelection,
    previous_authorization: WindowPointerAuthorization,
    fresh_authorization: Option<WindowPointerAuthorization>,
    source_deadline_ns: u64,
    drained: bool,
    receipt: Option<oneshot::Receiver<Result<u64>>>,
}

struct PendingRejectedGesture {
    rejected: viewflow_protocol::AtlasWindowSelectionRejected,
    cancel_sequence: u64,
    receipt: Option<oneshot::Receiver<Result<u64>>>,
    cancel_confirmed: bool,
    notice: Option<crate::atlas_input_recovery::NativeRecoveryNotice>,
    drained: bool,
    selection: Option<viewflow_protocol::AtlasWindowSelection>,
    authorization: Option<WindowPointerAuthorization>,
    retry_after: Option<viewflow_protocol::AtlasWindowSelection>,
}

struct AtlasRecoveryInput {
    notices: mpsc::Receiver<crate::atlas_input_recovery::NativeRecoveryNotice>,
    submit: mpsc::Sender<AtlasInputRecoveryRequest>,
    fence: crate::atlas_receiver_presenter::AtlasInputRecoveryFence,
    authorizations: BTreeMap<Id128, WindowPointerAuthorization>,
    pending: Option<PendingAtlasRecovery>,
    control_sequence: u64,
    rejected: Option<PendingRejectedGesture>,
}

pub struct AtlasPreviewInput {
    owner: Id128,
    source: Id128,
    origin: Instant,
    native: mpsc::Receiver<AtlasNativePointer>,
    native_backlog: VecDeque<AtlasNativePointer>,
    focus_release_qpc: std::collections::BTreeMap<Id128, u64>,
    committed: watch::Receiver<VecDeque<AtlasFrame>>,
    qpc: Box<dyn FnMut() -> Result<(u64, u64)> + Send>,
    allow_wheel: bool,
    allow_keyboard: bool,
    // None is the normal/default path. Recovery has no silent capability
    // upgrade: it is wired only by the recovery-aware owner.
    recovery: Option<AtlasRecoveryInput>,
    desktop_cursor: Option<viewflow_platform::windows_input::DesktopPointerDisplay>,
    desktop_moves: Option<mpsc::Receiver<crate::desktop_pointer::AtlasDesktopMove>>,
}

fn recovery_notice_matches(
    candidate: crate::atlas_input_recovery::NativeRecoveryNotice,
    cancelled: crate::atlas_input_recovery::NativeRecoveryNotice,
) -> bool {
    candidate.selection.stream_id == cancelled.selection.stream_id
        && candidate.selection.window_id == cancelled.selection.window_id
        && candidate.selection.atlas_geometry_epoch == cancelled.selection.atlas_geometry_epoch
        && candidate.selection.config_generation == cancelled.selection.config_generation
        && candidate.selection.layout_revision >= cancelled.selection.layout_revision
        && candidate.previous_epoch == cancelled.previous_epoch
        && candidate.previous_atlas_frame == cancelled.previous_atlas_frame
        && candidate.previous_source_frame == cancelled.previous_source_frame
        && candidate.frequency == cancelled.frequency
}

fn recovery_selection_advances_or_matches(
    candidate: viewflow_protocol::AtlasWindowSelection,
    previous: viewflow_protocol::AtlasWindowSelection,
) -> bool {
    if candidate.stream_id != previous.stream_id
        || candidate.window_id != previous.window_id
        || candidate.atlas_geometry_epoch != previous.atlas_geometry_epoch
        || candidate.config_generation != previous.config_generation
        || candidate.layout_revision < previous.layout_revision
        || candidate.placement_generation < previous.placement_generation
        || candidate.atlas_frame_id < previous.atlas_frame_id
        || candidate.source_geometry_epoch < previous.source_geometry_epoch
        || candidate.source_frame_id < previous.source_frame_id
    {
        return false;
    }
    if candidate.source_geometry_epoch > previous.source_geometry_epoch
        && candidate.source_frame_id <= previous.source_frame_id
    {
        return false;
    }
    true
}

fn recovery_authorization_matches(
    authorization: WindowPointerAuthorization,
    selection: viewflow_protocol::AtlasWindowSelection,
    previous: WindowPointerAuthorization,
) -> bool {
    authorization.owner_device == previous.owner_device
        && authorization.target_device == previous.target_device
        && authorization.target_window == selection.window_id
        && authorization.geometry_epoch == selection.source_geometry_epoch
        && authorization.presented_frame == selection.source_frame_id
        && authorization.lease_generation > previous.lease_generation
        && authorization.source_not_after_ns > previous.source_not_after_ns
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{
        AtlasTile, WindowPointerAck, WindowPointerAuthorization, WindowPointerResult,
    };
    use viewflow_transport::{
        PeerIdentity, build_client_config, build_server_config, receive_control,
    };

    #[test]
    fn recovery_requires_a_fresh_exact_source_authorization() {
        let selection = viewflow_protocol::AtlasWindowSelection {
            activate_keyboard: false,
            stream_id: Id128(9),
            atlas_frame_id: 10,
            atlas_geometry_epoch: 11,
            config_generation: 12,
            layout_revision: 13,
            window_id: Id128(14),
            placement_generation: 15,
            source_geometry_epoch: 16,
            source_frame_id: 17,
            sequence: 18,
            sender_not_after_ns: 19,
        };
        let previous = WindowPointerAuthorization {
            owner_device: Id128(1),
            target_device: Id128(2),
            target_window: selection.window_id,
            presented_frame: 7,
            geometry_epoch: 6,
            lease_generation: 5,
            source_not_after_ns: 20,
        };
        let accepted = viewflow_protocol::AtlasWindowSelectionAccepted {
            selection,
            authorization: WindowPointerAuthorization {
                target_window: selection.window_id,
                geometry_epoch: selection.source_geometry_epoch,
                presented_frame: selection.source_frame_id,
                ..previous
            },
        };
        let mut waiting = AwaitingSelection::new(selection);
        assert!(!waiting.authorized);
        assert!(
            waiting
                .accept(viewflow_protocol::AtlasWindowSelectionAccepted {
                    selection: viewflow_protocol::AtlasWindowSelection {
                        sequence: selection.sequence + 1,
                        ..selection
                    },
                    ..accepted
                })
                .is_err()
        );
        assert!(!waiting.authorized);
        waiting.accept(accepted).unwrap();
        assert!(waiting.authorized);
        assert!(waiting.accept(accepted).is_err());
        let fresh = WindowPointerAuthorization {
            presented_frame: selection.source_frame_id,
            geometry_epoch: selection.source_geometry_epoch,
            lease_generation: 6,
            source_not_after_ns: 21,
            ..previous
        };
        assert!(recovery_authorization_matches(fresh, selection, previous));
        for mutate in [
            |auth: &mut WindowPointerAuthorization| auth.target_window = Id128(99),
            |auth: &mut WindowPointerAuthorization| auth.geometry_epoch -= 1,
            |auth: &mut WindowPointerAuthorization| auth.presented_frame -= 1,
            |auth: &mut WindowPointerAuthorization| auth.lease_generation -= 1,
            |auth: &mut WindowPointerAuthorization| auth.source_not_after_ns -= 1,
        ] {
            let mut invalid = fresh;
            mutate(&mut invalid);
            assert!(!recovery_authorization_matches(
                invalid, selection, previous
            ));
        }
    }

    #[test]
    fn recovery_is_an_explicit_keyboard_only_opt_in() {
        let (_, native) = mpsc::channel(64);
        let (_notice_owner, notices) = mpsc::channel(64);
        let (submit, _requests) = mpsc::channel(1);
        let base = || {
            AtlasPreviewInput::new(
                Id128(1),
                Id128(2),
                Instant::now(),
                native,
                watch::channel(VecDeque::new()).1,
                || Ok((1, 1)),
            )
        };
        assert!(
            base()
                .unwrap()
                .with_input_recovery(
                    notices,
                    submit,
                    crate::atlas_receiver_presenter::AtlasInputRecoveryFence::default(),
                )
                .is_err()
        );

        let (_, native) = mpsc::channel(64);
        let (_notice_owner, notices) = mpsc::channel(64);
        let (submit, _requests) = mpsc::channel(1);
        let input = AtlasPreviewInput::new(
            Id128(1),
            Id128(2),
            Instant::now(),
            native,
            watch::channel(VecDeque::new()).1,
            || Ok((1, 1)),
        )
        .unwrap()
        .with_direct_keyboard()
        .with_input_recovery(
            notices,
            submit,
            crate::atlas_receiver_presenter::AtlasInputRecoveryFence::default(),
        )
        .unwrap();
        assert!(input.recovery.is_some());
    }

    #[tokio::test]
    async fn geometry_recovery_settles_inflight_publication_and_ignores_notice_age() {
        use crate::atlas_input_recovery::NativeRecoveryNotice;
        for notice_ahead in [false, true] {
            let origin = Instant::now();
            let old = AtlasFrame {
            patches: None,
                stream_id: Id128(99),
                frame_id: 100,
                geometry_epoch: 2,
                config_generation: 3,
                layout_revision: 4,
                width: 64,
                height: 64,
                source_submitted_ns: 100,
                tiles: vec![AtlasTile {
                    window_id: Id128(8),
                    placement_generation: 4,
                    geometry_epoch: 7,
                    source_frame_id: 19,
                    source_submitted_ns: 100,
                    x: 0,
                    y: 0,
                    width: 64,
                    height: 64,
                }],
                color_keyframe: true,
                alpha_keyframe: true,
                desktop: None,
            };
            let mut observed = old.clone();
            observed.frame_id = 101;
            observed.tiles[0].geometry_epoch = 8;
            observed.tiles[0].source_frame_id = 20;
            let mut settled = observed.clone();
            settled.frame_id = 150; // Notice has already left the 32-frame history.
            settled.layout_revision = 5;
            settled.tiles[0].placement_generation = 5;
            settled.tiles[0].geometry_epoch = 9;
            settled.tiles[0].source_frame_id = 69;
            let initial = VecDeque::from([if notice_ahead {
                old.clone()
            } else {
                settled.clone()
            }]);
            let (committed_owner, committed) = watch::channel(initial.clone());
            let (_native_owner, native) = mpsc::channel(64);
            let (_notice_owner, notices) = mpsc::channel(64);
            let (submit, mut requests) = mpsc::channel(1);
            let fence = crate::atlas_receiver_presenter::AtlasInputRecoveryFence::default();
            let mut input =
                AtlasPreviewInput::new(Id128(1), Id128(2), origin, native, committed, || {
                    Ok((130, 1000))
                })
                .unwrap()
                .with_direct_keyboard()
                .with_input_recovery(notices, submit, fence.clone())
                .unwrap();
            let previous = WindowPointerAuthorization {
                owner_device: Id128(1),
                target_device: Id128(2),
                target_window: Id128(8),
                presented_frame: if notice_ahead { 19 } else { 18 },
                geometry_epoch: 7,
                lease_generation: 7,
                source_not_after_ns: 1_000_000_000,
            };
            input.record_source_authorization(previous);
            let (_samples, rx) = watch::channel(PreviewPointerState::default());
            let (acks, _) = watch::channel(None);
            let mut preview =
                WindowPreviewInput::new(Id128(1), Id128(2), Id128(8), origin, rx, acks).unwrap();
            preview
                .select_presented(viewflow_core::PresentedInputIdentity {
                    window: Id128(8),
                    frame: previous.presented_frame,
                    geometry_epoch: 7,
                })
                .unwrap();
            preview.authorize(previous).unwrap();
            let notice = NativeRecoveryNotice {
                selection: viewflow_protocol::AtlasWindowSelection::from_frame(
                    &observed,
                    Id128(8),
                    1,
                    1,
                )
                .unwrap(),
                previous_epoch: 7,
                previous_atlas_frame: 100,
                previous_source_frame: 19,
                physical_drained: false,
                observed_qpc: 110,
                frequency: 1000,
                rejection: None,
            };
            let mut sequence = 10;
            assert!(
                input
                    .accept_recovery_notice(
                        notice,
                        1,
                        (120, 1000),
                        Some(&mut preview),
                        &mut sequence
                    )
                    .await
                    .unwrap()
                    .is_none()
            );
            assert!(!fence.is_armed());
            // Holding a key while the geometry changes must not start an
            // authorization timer or freeze media.
            assert!(
                input
                    .progress_recovery(10_000_000_000, &initial, None)
                    .unwrap()
            );
            assert!(requests.try_recv().is_err());
            let forward = fence.begin_media_forward().await.unwrap();
            let drain = NativeRecoveryNotice {
                physical_drained: true,
                observed_qpc: 120,
                ..notice
            };
            let selection = {
                let drain_work = input.accept_recovery_notice(
                    drain,
                    2,
                    (130, 1000),
                    Some(&mut preview),
                    &mut sequence,
                );
                tokio::pin!(drain_work);
                tokio::select! {
                    result = &mut drain_work => panic!("recovery crossed unfinished frame: {result:?}"),
                    _ = tokio::time::sleep(Duration::from_millis(2)) => {}
                }
                assert!(fence.is_armed());
                committed_owner.send_replace(VecDeque::from([settled.clone()]));
                drop(forward);
                drain_work.await.unwrap().unwrap()
            };
            assert_eq!(
                (
                    selection.atlas_frame_id,
                    selection.source_frame_id,
                    selection.source_geometry_epoch
                ),
                (150, 69, 9)
            );
            assert!(selection.activate_keyboard);
            assert_eq!(sequence, 11);
            assert!(
                input
                    .accept_recovery_notice(
                        drain,
                        3,
                        (130, 1000),
                        Some(&mut preview),
                        &mut sequence
                    )
                    .await
                    .unwrap()
                    .is_none()
            );
            input.record_source_authorization(WindowPointerAuthorization {
                presented_frame: 69,
                geometry_epoch: 9,
                lease_generation: 8,
                source_not_after_ns: 2_000_000_000,
                ..previous
            });
            let clock = crate::input_runtime::ClockSnapshot {
                estimate: viewflow_transport::ClockEstimate {
                    remote_offset_ns: 0,
                    network_round_trip_ns: 0,
                    uncertainty_ns: 0,
                },
                measured_at_local_ns: 1,
            };
            assert!(
                input
                    .progress_recovery(1000, &VecDeque::from([settled]), Some(clock))
                    .unwrap()
            );
            let resume = requests.recv().await.unwrap();
            assert_eq!(
                (
                    resume.confirmation.atlas_frame,
                    resume.confirmation.source_frame,
                    resume.confirmation.geometry_epoch,
                    resume.confirmation.previous_epoch
                ),
                (150, 69, 9, 7)
            );
            resume.response.send(Ok(140)).unwrap();
            assert!(!input.collect_recovery_receipt().unwrap());
            assert!(input.recovery.as_ref().unwrap().pending.is_none());
        }
    }

    #[tokio::test]
    async fn stale_capture_cancels_then_drains_then_selects_fresh_without_replaying_event() {
        use crate::atlas_input_recovery::{
            InputRejectionKind, NativeRecoveryNotice, NativeRejectedGesture,
        };
        let origin = Instant::now();
        let frame = AtlasFrame {
            patches: None,
            stream_id: Id128(99),
            frame_id: 100,
            geometry_epoch: 2,
            config_generation: 3,
            layout_revision: 4,
            width: 64,
            height: 64,
            source_submitted_ns: 100,
            tiles: vec![AtlasTile {
                window_id: Id128(8),
                placement_generation: 4,
                geometry_epoch: 7,
                source_frame_id: 19,
                source_submitted_ns: 100,
                x: 0,
                y: 0,
                width: 64,
                height: 64,
            }],
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
        };
        let old =
            viewflow_protocol::AtlasWindowSelection::from_frame(&frame, Id128(8), 2, 23_393_718)
                .unwrap();
        let mut newest = frame.clone();
        newest.frame_id += 1;
        newest.tiles[0].source_frame_id += 1;
        let (_native_owner, native) = mpsc::channel(64);
        let (_notice_owner, notices) = mpsc::channel(64);
        let (submit, mut requests) = mpsc::channel(1);
        let (committed_owner, committed) = watch::channel(VecDeque::from([frame, newest.clone()]));
        let mut input =
            AtlasPreviewInput::new(Id128(1), Id128(2), origin, native, committed, || {
                Ok((110, 1000))
            })
            .unwrap()
            .with_direct_keyboard()
            .with_input_recovery(
                notices,
                submit,
                crate::atlas_receiver_presenter::AtlasInputRecoveryFence::default(),
            )
            .unwrap();
        let previous = WindowPointerAuthorization {
            owner_device: Id128(1),
            target_device: Id128(2),
            target_window: Id128(8),
            presented_frame: 19,
            geometry_epoch: 7,
            lease_generation: 7,
            source_not_after_ns: 1_000_000_000,
        };
        input.record_source_authorization(previous);
        let (_samples, sample_rx) = watch::channel(PreviewPointerState::default());
        let (acks, _) = watch::channel(None);
        let mut preview =
            WindowPreviewInput::new(Id128(1), Id128(2), Id128(8), origin, sample_rx, acks).unwrap();
        preview
            .select_presented(viewflow_core::PresentedInputIdentity {
                window: Id128(8),
                frame: 19,
                geometry_epoch: 7,
            })
            .unwrap();
        preview.authorize(previous).unwrap();
        let rejected = viewflow_protocol::AtlasWindowSelectionRejected {
            selection: old,
            reason: viewflow_protocol::AtlasSelectionRejectionReason::CaptureExpired,
            released_generation: 7,
            capture_age_ns: 41_924_882,
            capture_limit_ns: 33_333_333,
        };
        assert!(
            input
                .begin_rejected_gesture(
                    viewflow_protocol::AtlasWindowSelectionRejected {
                        released_generation: 6,
                        ..rejected
                    },
                    &mut preview
                )
                .await
                .is_err()
        );
        assert!(requests.try_recv().is_err());
        input
            .begin_rejected_gesture(rejected, &mut preview)
            .await
            .unwrap();
        let cancel = requests.recv().await.unwrap();
        assert_eq!(
            cancel.confirmation.rejection.unwrap().kind,
            InputRejectionKind::Cancel
        );
        assert_eq!(cancel.confirmation.grant_generation, 0);
        assert!(
            !preview.authorized_presented(viewflow_core::PresentedInputIdentity {
                window: Id128(8),
                frame: 19,
                geometry_epoch: 7
            })
        );
        let mut sequence = old.sequence;
        assert!(
            input
                .progress_rejected_gesture(1, None, Some(&mut preview), &mut sequence)
                .await
                .unwrap()
                .is_none()
        );
        cancel.response.send(Ok(110)).unwrap();
        assert!(
            input
                .progress_rejected_gesture(1, None, Some(&mut preview), &mut sequence)
                .await
                .unwrap()
                .is_none()
        );
        let notice = NativeRecoveryNotice {
            selection: old,
            previous_epoch: 7,
            previous_atlas_frame: 100,
            previous_source_frame: 19,
            physical_drained: false,
            observed_qpc: 110,
            frequency: 1000,
            rejection: Some(NativeRejectedGesture {
                cancel_sequence: cancel.confirmation.sequence,
                ingress_boundary: 1,
            }),
        };
        assert!(
            input
                .accept_rejected_notice(
                    NativeRecoveryNotice {
                        physical_drained: true,
                        ..notice
                    },
                    (110, 1000)
                )
                .is_err()
        );
        let (moves, move_rx) = mpsc::channel(64);
        let queued_move = crate::desktop_pointer::AtlasDesktopMove::parse("desktop-move-v1 stream_hi=0 stream_lo=99 atlas_frame=100 atlas_epoch=2 config_generation=3 layout_revision=4 window_hi=0 window_lo=8 placement_generation=4 source_epoch=7 source_frame=19 topology_generation=5 drag_id=6 sequence=1 phase=begin deadline_qpc=5100 qpc_frequency=1000 x_millidip=0 y_millidip=0 width_millidip=640 height_millidip=480").unwrap();
        moves.try_send(queued_move).unwrap();
        input.desktop_moves = Some(move_rx);
        // Cancellation must discard only its own prefix. A later click in a
        // different HWND and a focus cleanup can already be in the same FIFO.
        let old_event = AtlasNativePointer::parse(crate::atlas_pointer::tests::MOTION).unwrap();
        _native_owner.try_send(old_event.fixture_ingress(1)).unwrap();
        let other = AtlasNativePointer::parse(&crate::atlas_pointer::tests::MOTION.replace("window_lo=8", "window_lo=9")).unwrap();
        _native_owner.try_send(other.fixture_ingress(2)).unwrap();
        let release = AtlasNativePointer::parse(&crate::atlas_pointer::tests::MOTION.replace("kind=motion", "kind=release")).unwrap();
        _native_owner.try_send(release.fixture_ingress(3)).unwrap();
        input.accept_rejected_notice(notice, (110, 1000)).unwrap();
        assert_eq!(input.native_backlog.len(), 2);
        assert_eq!(input.native_backlog[0].selection().window_id, Id128(9));
        assert!(input.native_backlog[1].releases_input());
        assert_eq!(input.desktop_moves.as_ref().unwrap().len(), 1);

        assert!(
            input
                .progress_rejected_gesture(1, None, Some(&mut preview), &mut sequence)
                .await
                .unwrap()
                .is_none()
        );
        input
            .accept_rejected_notice(
                NativeRecoveryNotice {
                    physical_drained: true,
                    ..notice
                },
                (110, 1000),
            )
            .unwrap();
        let fresh_creation_floor = u64::try_from(origin.elapsed().as_nanos()).unwrap();
        let fresh = input
            .progress_rejected_gesture(1, None, Some(&mut preview), &mut sequence)
            .await
            .unwrap()
            .unwrap();
        assert!(fresh.matches(&newest));
        assert!(fresh.sequence > old.sequence);
        assert!(fresh.sender_not_after_ns >= fresh_creation_floor + (crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS - crate::input_runtime::INPUT_CLOCK_MAPPING_HEADROOM_NS));
        assert!(
            fresh.sender_not_after_ns
                <= u64::try_from(origin.elapsed().as_nanos()).unwrap() + (crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS - crate::input_runtime::INPUT_CLOCK_MAPPING_HEADROOM_NS)
        );
        assert!(requests.try_recv().is_err()); // Fresh selection is not authorization.
        // Its 24 ms decision budget expiring must not erase correlation while
        // the exact source response is in flight. No input can escape here.
        assert!(
            input
                .progress_rejected_gesture(
                    fresh.sender_not_after_ns + 1,
                    None,
                    Some(&mut preview),
                    &mut sequence
                )
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            input
                .progress_rejected_gesture(
                    fresh.sender_not_after_ns + crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS,
                    None,
                    Some(&mut preview),
                    &mut sequence
                )
                .await
                .is_err()
        );
        let refused = viewflow_protocol::AtlasWindowSelectionRejected {
            selection: fresh,
            ..rejected
        };
        assert!(
            input
                .retry_rejected_recovery_selection(
                    viewflow_protocol::AtlasWindowSelectionRejected {
                        selection: viewflow_protocol::AtlasWindowSelection {
                            sequence: fresh.sequence + 1,
                            ..fresh
                        },
                        ..refused
                    }
                )
                .is_err()
        );
        assert!(input.retry_rejected_recovery_selection(refused).unwrap());
        assert!(!input.recovery.as_ref().unwrap().fence.is_armed());
        assert!(
            input
                .progress_rejected_gesture(1, None, Some(&mut preview), &mut sequence)
                .await
                .unwrap()
                .is_none()
        );
        assert!(requests.try_recv().is_err()); // Retry cannot reissue the same stale frame.
        newest.frame_id += 1;
        newest.tiles[0].source_frame_id += 1;
        committed_owner
            .send(VecDeque::from([newest.clone()]))
            .unwrap();
        let retried = input
            .progress_rejected_gesture(1, None, Some(&mut preview), &mut sequence)
            .await
            .unwrap()
            .unwrap();
        assert!(retried.sequence > fresh.sequence && retried.matches(&newest));
        assert!(!retried.activate_keyboard);
        assert!(input.recovery.as_ref().unwrap().fence.is_armed());
        assert_eq!(
            input
                .recovery
                .as_ref()
                .unwrap()
                .rejected
                .as_ref()
                .unwrap()
                .rejected
                .selection,
            old
        );
        assert!(input.native.is_empty());
        input.record_source_authorization(WindowPointerAuthorization {
            lease_generation: 8,
            presented_frame: 21,
            source_not_after_ns: retried.sender_not_after_ns + 1_000_000_000,
            ..previous
        });
        let clock = crate::input_runtime::ClockSnapshot {
            estimate: viewflow_transport::ClockEstimate {
                remote_offset_ns: 0,
                network_round_trip_ns: 0,
                uncertainty_ns: 0,
            },
            measured_at_local_ns: retried.sender_not_after_ns + 1,
        };
        input
            .progress_rejected_gesture(
                retried.sender_not_after_ns + 1,
                Some(clock),
                Some(&mut preview),
                &mut sequence,
            )
            .await
            .unwrap();
        let resume = requests.recv().await.unwrap();
        assert_eq!(
            resume.confirmation.rejection.unwrap().kind,
            InputRejectionKind::Resume
        );
        assert_eq!(resume.confirmation.grant_generation, 8);
        assert_eq!(resume.confirmation.atlas_frame, 102);
        resume.response.send(Ok(111)).unwrap();
        input
            .progress_rejected_gesture(3, Some(clock), Some(&mut preview), &mut sequence)
            .await
            .unwrap();
        assert!(input.recovery.as_ref().unwrap().rejected.is_none());
        assert!(preview.idle_for_selection());
        assert!(input.native.is_empty());
    }

    #[tokio::test]
    async fn native_events_select_two_windows_and_keep_source_identities() {
        forward_two_windows(false, false, false).await;
    }

    #[tokio::test]
    async fn wheel_events_select_two_windows_and_keep_source_identities() {
        forward_two_windows(true, true, false).await;
    }

    #[tokio::test]
    async fn wheel_without_local_opt_in_closes_before_selection_or_input() {
        forward_two_windows(true, false, false).await;
    }

    #[tokio::test]
    async fn keyboard_events_select_two_windows_with_separate_authority() {
        forward_two_windows(false, true, true).await;
    }

    #[tokio::test]
    async fn keyboard_without_local_opt_in_closes_before_selection_or_input() {
        forward_two_windows(false, false, true).await;
    }

    #[tokio::test]
    async fn missing_keyboard_authority_expires_with_exact_event_diagnostic() {
        forward_with_keyboard_authority(false, true, true, false).await;
    }

    async fn forward_two_windows(wheel: bool, enabled: bool, keyboard: bool) {
        forward_with_keyboard_authority(wheel, enabled, keyboard, true).await;
    }

    #[tokio::test]
    async fn deferred_source_sends_no_initial_grant_but_selection_bootstraps_input() {
        forward_with_initial_authority(false, false, false, true, false).await;
    }

    async fn forward_with_keyboard_authority(
        wheel: bool,
        enabled: bool,
        keyboard: bool,
        grant_keyboard: bool,
    ) {
        forward_with_initial_authority(wheel, enabled, keyboard, grant_keyboard, true).await;
    }

    async fn forward_with_initial_authority(
        wheel: bool,
        enabled: bool,
        keyboard: bool,
        grant_keyboard: bool,
        initial_pointer: bool,
    ) {
        forward_with_selection_result(
            wheel,
            enabled,
            keyboard,
            grant_keyboard,
            initial_pointer,
            false,
            0,
        )
        .await;
    }

    #[tokio::test]
    async fn old_exact_grant_cannot_forward_a_selection_that_is_rejected() {
        forward_with_selection_result(false, false, false, true, true, true, 0).await;
    }

    #[tokio::test]
    async fn late_exact_rejection_keeps_expired_event_correlated_and_unforwarded() {
        forward_with_selection_result(false, false, false, true, true, true, 150).await;
    }

    #[tokio::test]
    async fn late_exact_acceptance_discards_expired_motion_and_allows_only_new_input() {
        forward_with_selection_result(false, false, false, true, true, false, 150).await;
    }

    async fn forward_with_selection_result(
        wheel: bool,
        enabled: bool,
        keyboard: bool,
        grant_keyboard: bool,
        initial_pointer: bool,
        reject_first: bool,
        first_receipt_delay_ms: u64,
    ) {
        #[cfg(windows)]
        let _timer_resolution = crate::coded_peer::enable_windows_timer_resolution().unwrap();
        let tls = PeerIdentity::from_pem(
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let server = quinn::Endpoint::server(
            build_server_config(&tls).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(build_client_config(&tls).unwrap());
        let (remote, source) = tokio::join!(
            client
                .connect(server.local_addr().unwrap(), "localhost")
                .unwrap(),
            async { server.accept().await.unwrap().await }
        );
        let remote = remote.unwrap();
        let source = source.unwrap();
        let origin = Instant::now();
        let manifest = AtlasFrame {
            patches: None,
            stream_id: Id128(99),
            frame_id: 100,
            geometry_epoch: 2,
            config_generation: 3,
            layout_revision: 4,
            width: 128,
            height: 64,
            source_submitted_ns: 100,
            tiles: (0_u32..2)
                .map(|i| AtlasTile {
                    window_id: Id128(u128::from(8 + i)),
                    placement_generation: 4,
                    geometry_epoch: 7,
                    source_frame_id: u64::from(19 + i),
                    source_submitted_ns: 100,
                    x: i * 64,
                    y: 0,
                    width: 64,
                    height: 64,
                })
                .collect(),
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
        };
        let committed_layout = manifest.clone();
        let (committed_owner, committed) = watch::channel(VecDeque::new());
        let (native, native_rx) = mpsc::channel(64);
        let (controls, controls_rx) = mpsc::channel(16);
        let auth = |window, frame, generation| WindowPointerAuthorization {
            owner_device: Id128(1),
            target_device: Id128(2),
            target_window: Id128(window),
            presented_frame: frame,
            geometry_epoch: 7,
            lease_generation: generation,
            source_not_after_ns: 1_000_000_000,
        };
        let (observed, mut observations) = mpsc::channel(4);
        let (synced, sync_rx) = tokio::sync::oneshot::channel();
        let source_work = tokio::spawn(async move {
            // Native capture/input bootstrap can outlast one probe timeout.
            // No preview probe should start until the source route is ready.
            tokio::time::sleep(Duration::from_millis(400)).await;
            assert!(
                tokio::time::timeout(Duration::from_millis(5), receive_control(&source))
                    .await
                    .is_err()
            );
            controls
                .send(DomainControl::ClockSyncProbe(
                    viewflow_protocol::ClockSyncProbe {
                        probe_id: 1,
                        t0_send_ns: u64::try_from(origin.elapsed().as_nanos()).unwrap(),
                    },
                ))
                .await
                .unwrap();
            let mut synced = Some(synced);
            let mut selected_deadlines = BTreeMap::new();
            loop {
                let Ok(envelope) = receive_control(&source).await else {
                    break;
                };
                match DomainControl::try_from(envelope).unwrap() {
                    DomainControl::ClockSyncReply(reply) => {
                        assert_eq!(reply.probe_id, 1);
                        if initial_pointer {
                            controls
                                .send(DomainControl::WindowPointerAuthorization(auth(8, 19, 7)))
                                .await
                                .unwrap();
                        }
                    }
                    DomainControl::ClockSyncProbe(probe) => {
                        let now = u64::try_from(origin.elapsed().as_nanos()).unwrap();
                        controls
                            .send(DomainControl::ClockSyncReply(
                                viewflow_protocol::ClockSyncReply {
                                    probe_id: probe.probe_id,
                                    t0_send_ns: probe.t0_send_ns,
                                    t1_receive_ns: now,
                                    t2_send_ns: now,
                                },
                            ))
                            .await
                            .unwrap();
                        if let Some(s) = synced.take() {
                            let _ = s.send(());
                        }
                    }
                    DomainControl::AtlasWindowSelection(selection) => {
                        assert!(!(wheel || keyboard) || enabled);
                        assert!(selection.matches(&manifest));
                        assert_eq!(selection.activate_keyboard, keyboard);
                        selected_deadlines
                            .insert(selection.window_id, selection.sender_not_after_ns);
                        // Even an exact existing grant is not a response to this
                        // selection. No app input may arrive before its receipt.
                        assert!(
                            tokio::time::timeout(
                                Duration::from_millis(2),
                                receive_control(&source)
                            )
                            .await
                            .is_err()
                        );
                        if selection.window_id == Id128(8) && first_receipt_delay_ms != 0 {
                            tokio::time::sleep(Duration::from_millis(first_receipt_delay_ms)).await;
                        }
                        if reject_first {
                            controls.send(DomainControl::AtlasWindowSelectionRejected(viewflow_protocol::AtlasWindowSelectionRejected {
                                selection,
                                reason: viewflow_protocol::AtlasSelectionRejectionReason::CaptureExpired,
                                released_generation: 7,
                                capture_age_ns: 38_417_796,
                                capture_limit_ns: 33_333_333,
                            })).await.unwrap();
                            continue;
                        }
                        controls
                            .send(DomainControl::AtlasWindowSelectionAccepted(
                                viewflow_protocol::AtlasWindowSelectionAccepted {
                                    selection,
                                    authorization: auth(
                                        if selection.window_id == Id128(8) {
                                            8
                                        } else {
                                            9
                                        },
                                        selection.source_frame_id,
                                        if selection.window_id == Id128(8) {
                                            7
                                        } else {
                                            8
                                        },
                                    ),
                                },
                            ))
                            .await
                            .unwrap();
                        if keyboard && grant_keyboard {
                            // Pointer readiness alone must not forward the waiting key.
                            assert!(
                                tokio::time::timeout(
                                    Duration::from_millis(2),
                                    receive_control(&source)
                                )
                                .await
                                .is_err()
                            );
                            let auth = viewflow_protocol::WindowKeyboardAuthorization {
                                owner_device: Id128(1),
                                target_device: Id128(2),
                                target_window: selection.window_id,
                                presented_frame: selection.source_frame_id,
                                geometry_epoch: 7,
                                lease_generation: if selection.window_id == Id128(8) {
                                    7
                                } else {
                                    8
                                },
                                source_not_after_ns: 1_000_000_000,
                                mode: viewflow_protocol::WindowKeyboardMode::DirectApplication,
                            };
                            controls
                                .send(DomainControl::WindowKeyboardAuthorization(auth))
                                .await
                                .unwrap();
                        }
                    }
                    DomainControl::WindowPointerMotion(motion) => {
                        assert!(!wheel);
                        assert_eq!(
                            motion.sender_not_after_ns,
                            selected_deadlines[&motion.target_window]
                        );
                        controls
                            .send(DomainControl::WindowPointerAck(
                                WindowPointerAck::for_motion(
                                    motion,
                                    WindowPointerResult::MotionSent,
                                ),
                            ))
                            .await
                            .unwrap();
                        observed
                            .send((
                                motion.target_window,
                                motion.presented_frame,
                                motion.sequence,
                            ))
                            .await
                            .unwrap();
                    }
                    DomainControl::WindowPointerWheel(event) => {
                        assert!(wheel && enabled);
                        assert_eq!(event.delta.vertical_delta_detents, 0.25);
                        assert_eq!(event.delta.horizontal_delta_detents, -0.5);
                        controls
                            .send(DomainControl::WindowPointerAck(
                                WindowPointerAck::for_motion(
                                    event.position,
                                    WindowPointerResult::WheelSent,
                                ),
                            ))
                            .await
                            .unwrap();
                        observed
                            .send((
                                event.position.target_window,
                                event.position.presented_frame,
                                event.position.sequence,
                            ))
                            .await
                            .unwrap();
                    }
                    DomainControl::WindowKeyboardEvent(event) => {
                        assert!(keyboard && enabled);
                        assert_eq!(event.key.usage_page, 7);
                        assert_eq!(event.key.usage_id, 4);
                        controls
                            .send(DomainControl::WindowKeyboardAck(
                                viewflow_protocol::WindowKeyboardAck {
                                    event,
                                    result: viewflow_protocol::WindowKeyboardResult::KeySent,
                                },
                            ))
                            .await
                            .unwrap();
                        observed
                            .send((event.target_window, event.presented_frame, event.sequence))
                            .await
                            .unwrap();
                    }
                    other => panic!("unexpected source input {other:?}"),
                }
            }
        });
        let writer = crate::shared_control::SharedControlWriter::start(&remote).unwrap();
        let sender = writer.sender();
        let input = AtlasPreviewInput::new(
            Id128(1),
            Id128(2),
            origin,
            native_rx,
            committed,
            move || Ok((u64::try_from(origin.elapsed().as_nanos())?, 1_000_000_000)),
        )
        .unwrap()
        .with_wheel(enabled);
        let input = if keyboard && enabled {
            input.with_direct_keyboard()
        } else {
            input
        };
        let (_notices, notice_rx) = mpsc::channel(4);
        let (requests, mut recovery_requests) = mpsc::channel(1);
        let input = if reject_first {
            input
                .with_wheel(true)
                .with_direct_keyboard()
                .with_input_recovery(
                    notice_rx,
                    requests,
                    crate::atlas_receiver_presenter::AtlasInputRecoveryFence::default(),
                )
                .unwrap()
        } else {
            input
        };
        let work = tokio::spawn(async move {
            input
                .serve(
                    &remote,
                    controls_rx,
                    sender,
                    tokio::time::Instant::now() + Duration::from_secs(2),
                )
                .await
        });
        sync_rx.await.unwrap();
        let mut previous_sequence = 0;
        for (window, source_frame) in [(8, 19), (9, 20)] {
            let deadline = u64::try_from(origin.elapsed().as_nanos()).unwrap() + 30_000_000;
            let line = format!(
                "atlas-pointer-v1 stream_hi=0 stream_lo=99 atlas_frame=100 atlas_epoch=2 config_generation=3 layout_revision=4 window_hi=0 window_lo={window} placement_generation=4 source_epoch=7 source_frame={source_frame} kind=motion frame_identity=100 x_pixels=2 y_pixels=3 viewport_width=64 viewport_height=64 not_after_qpc={deadline} qpc_frequency=1000000000"
            );
            let line = if keyboard {
                format!(
                    "atlas-keyboard-v1 stream_hi=0 stream_lo=99 atlas_frame=100 atlas_epoch=2 config_generation=3 layout_revision=4 window_hi=0 window_lo={window} placement_generation=4 source_epoch=7 source_frame={source_frame} frame_identity=100 not_after_qpc={deadline} qpc_frequency=1000000000 usage_page=7 usage_id=4 state=1 repeat=0"
                )
            } else if wheel {
                format!(
                    "{} wheel_vertical_120=30 wheel_horizontal_120=-60",
                    line.replace("kind=motion", "kind=wheel")
                )
            } else {
                line
            };
            native
                .send(AtlasNativePointer::parse(&line).unwrap())
                .await
                .unwrap();
            if (wheel || keyboard) && !enabled {
                let error = tokio::time::timeout(Duration::from_secs(1), work)
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap_err();
                assert!(
                    error.to_string().contains(if keyboard {
                        "atlas keyboard is not locally enabled"
                    } else {
                        "atlas wheel is not locally enabled"
                    }),
                    "{error:#}"
                );
                tokio::time::timeout(Duration::from_secs(1), source_work)
                    .await
                    .unwrap()
                    .unwrap();
                assert!(observations.recv().await.is_none());
                return;
            }
            if window == 8 {
                // Native input can precede the media task publishing its
                // validated completion; keep the original event deadline.
                tokio::time::sleep(Duration::from_millis(2)).await;
                assert!(observations.try_recv().is_err());
                committed_owner
                    .send(VecDeque::from([committed_layout.clone()]))
                    .unwrap();
            }
            if window == 8 && first_receipt_delay_ms != 0 && !reject_first {
                tokio::time::sleep(Duration::from_millis(first_receipt_delay_ms + 10)).await;
                assert!(observations.try_recv().is_err());
                continue;
            }
            if reject_first {
                let cancel = tokio::time::timeout(
                    Duration::from_millis(first_receipt_delay_ms + 100),
                    recovery_requests.recv(),
                )
                .await
                .unwrap()
                .unwrap();
                assert_eq!(
                    cancel.confirmation.rejection.unwrap().kind,
                    crate::atlas_input_recovery::InputRejectionKind::Cancel
                );
                assert_eq!(cancel.confirmation.window, window);
                assert!(observations.try_recv().is_err());
                work.abort();
                assert!(work.await.unwrap_err().is_cancelled());
                source_work.abort();
                let _ = source_work.await;
                return;
            }
            if keyboard && !grant_keyboard {
                let error = tokio::time::timeout(Duration::from_secs(1), work)
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap_err()
                    .to_string();
                for expected in [
                    "atlas input expired awaiting selection:",
                    "sequence=1",
                    "frame=19",
                    "button=false wheel=false key=true",
                    "pointer_authorized=true keyboard_authorized=false",
                    "native_queued=0",
                ] {
                    assert!(error.contains(expected), "{error}");
                }
                assert!(!error.contains("usage_id"));
                tokio::time::timeout(Duration::from_secs(1), source_work)
                    .await
                    .unwrap()
                    .unwrap();
                assert!(observations.recv().await.is_none());
                return;
            }
            let motion = tokio::time::timeout(Duration::from_millis(100), observations.recv())
                .await
                .unwrap()
                .unwrap();
            assert_eq!(motion.0, Id128(window));
            assert_eq!(motion.1, source_frame);
            assert!(motion.2 > previous_sequence);
            previous_sequence = motion.2;
        }
        drop(native);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), work)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        tokio::time::timeout(Duration::from_secs(1), source_work)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn missing_source_readiness_expires_without_sending_a_probe() {
        let (_client, _server, remote, source) = crate::atlas_session::tests::pair().await;
        let (_native_owner, native) = mpsc::channel(4);
        let (_committed_owner, committed) = watch::channel(VecDeque::new());
        let (_controls_owner, controls) = mpsc::channel(4);
        let writer = crate::shared_control::SharedControlWriter::start(&remote).unwrap();
        let input = AtlasPreviewInput::new(
            Id128(1),
            Id128(2),
            Instant::now(),
            native,
            committed,
            || Ok((1, 1_000_000_000)),
        )
        .unwrap();
        let result = input
            .serve(
                &remote,
                controls,
                writer.sender(),
                tokio::time::Instant::now() + Duration::from_millis(30),
            )
            .await;
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("readiness timed out")
        );
        // The peer sees closure, not an early probe or any input authorization.
        assert!(receive_control(&source).await.is_err());
    }
}

impl AtlasPreviewInput {
    /// `committed` contains at most 32 successfully submitted native layouts,
    /// never merely received manifests. `qpc` samples the child's same-host clock.
    /// # Errors
    /// Rejects invalid paired device IDs and oversized native event queues.
    pub fn new(
        owner: Id128,
        source: Id128,
        origin: Instant,
        native: mpsc::Receiver<AtlasNativePointer>,
        committed: watch::Receiver<VecDeque<AtlasFrame>>,
        qpc: impl FnMut() -> Result<(u64, u64)> + Send + 'static,
    ) -> Result<Self> {
        ensure!(
            owner.0 != 0 && source.0 != 0 && owner != source && native.max_capacity() <= 64,
            "invalid atlas preview route"
        );
        Ok(Self {
            owner,
            source,
            origin,
            native,
            native_backlog: VecDeque::new(),
            focus_release_qpc: std::collections::BTreeMap::new(),
            committed,
            qpc: Box::new(qpc),
            allow_wheel: false,
            allow_keyboard: false,
            recovery: None,
            desktop_moves: None,
            desktop_cursor: None,
        })
    }

    /// Local policy only; this does not grant source input authority.
    #[must_use]
    pub fn with_wheel(mut self, enabled: bool) -> Self {
        self.allow_wheel = enabled;
        self
    }

    /// Local native keyboard capability opt-in; source keyboard grants are
    /// still mandatory and cannot be inferred from pointer authorizations.
    #[must_use]
    pub fn with_direct_keyboard(mut self) -> Self {
        self.allow_keyboard = true;
        self.allow_wheel = true;
        self
    }

    /// Attach the separately supervised cancellation/drain stream.  This has
    /// no default and requires the exact native keyboard capability that owns
    /// the physical held-key ledger.
    /// # Errors
    /// Rejects a recovery channel on a non-keyboard route or an oversized
    /// bounded queue.  Sender failure remains terminal at transaction time.
    pub fn with_input_recovery(
        mut self,
        notices: mpsc::Receiver<crate::atlas_input_recovery::NativeRecoveryNotice>,
        submit: mpsc::Sender<AtlasInputRecoveryRequest>,
        fence: crate::atlas_receiver_presenter::AtlasInputRecoveryFence,
    ) -> Result<Self> {
        ensure!(
            self.allow_keyboard
                && self.recovery.is_none()
                && notices.max_capacity() <= 64
                && submit.max_capacity() <= 64,
            "atlas input recovery requires direct keyboard and a bounded notice queue"
        );
        self.recovery = Some(AtlasRecoveryInput {
            notices,
            submit,
            fence,
            authorizations: BTreeMap::new(),
            pending: None,
            control_sequence: 0,
            rejected: None,
        });
        Ok(self)
    }

    pub fn with_desktop_cursor(
        mut self,
        config: crate::desktop_config::AtlasReceiverDesktopConfig,
    ) -> Result<Self> {
        config.validate()?;
        self.desktop_cursor = Some(viewflow_platform::windows_input::DesktopPointerDisplay {
            bounds: config.display.rect()?,
            native_x: config.native_x,
            native_y: config.native_y,
            scale_milli: config.display.scale_milli()?,
        });
        Ok(self)
    }

    /// Attach the explicitly enabled desktop movement channel.
    /// # Errors
    /// Requires bounded local events and native input recovery.
    pub fn with_desktop_moves(
        mut self,
        moves: mpsc::Receiver<crate::desktop_pointer::AtlasDesktopMove>,
    ) -> Result<Self> {
        ensure!(
            self.recovery.is_some() && self.desktop_moves.is_none() && moves.max_capacity() <= 64,
            "desktop movement requires bounded recovery-aware native input"
        );
        self.desktop_moves = Some(moves);
        Ok(self)
    }

    fn record_source_authorization(&mut self, authorization: WindowPointerAuthorization) {
        let Some(recovery) = &mut self.recovery else {
            return;
        };
        recovery
            .authorizations
            .insert(authorization.target_window, authorization);
        if let Some(pending) = &mut recovery.rejected {
            if pending.selection.is_some_and(|selection| {
                authorization.target_window == selection.window_id
                    && authorization.geometry_epoch == selection.source_geometry_epoch
                    && authorization.presented_frame == selection.source_frame_id
                    && authorization.lease_generation > pending.rejected.released_generation
            }) {
                pending.authorization = Some(authorization);
            }
        }
        if let Some(pending) = &mut recovery.pending {
            if recovery_authorization_matches(
                authorization,
                pending.selection,
                pending.previous_authorization,
            ) {
                pending.fresh_authorization = Some(authorization);
            }
        }
    }

    async fn begin_rejected_gesture(
        &mut self,
        rejected: viewflow_protocol::AtlasWindowSelectionRejected,
        preview: &mut WindowPreviewInput,
    ) -> Result<()> {
        rejected
            .validate()
            .map_err(|e| anyhow::anyhow!("invalid selection rejection: {e:?}"))?;
        ensure!(
            rejected.reason != viewflow_protocol::AtlasSelectionRejectionReason::WindowWithdrawn,
            "rejected window was withdrawn"
        );
        let recovery = self
            .recovery
            .as_ref()
            .context("selection rejection requires native recovery")?;
        ensure!(
            recovery.pending.is_none() && recovery.rejected.is_none(),
            "overlapping selection rejection"
        );
        ensure!(
            preview.idle_for_selection()
                && preview.selected_window() == rejected.selection.window_id,
            "selection rejection overlaps forwarded input"
        );
        if let Some(previous) = recovery.authorizations.get(&rejected.selection.window_id) {
            ensure!(
                rejected.released_generation >= previous.lease_generation,
                "selection rejection lacks source END generation proof"
            );
        }
        preview.pause_for_desktop_move()?;
        recovery.fence.clone().arm().await;
        let (cancel_sequence, receipt) =
            self.submit_rejection_control(rejected.selection, rejected.selection, 0, None)?;
        self.recovery.as_mut().expect("checked recovery").rejected = Some(PendingRejectedGesture {
            rejected,
            cancel_sequence,
            receipt: Some(receipt),
            cancel_confirmed: false,
            notice: None,
            drained: false,
            selection: None,
            authorization: None,
            retry_after: None,
        });
        Ok(())
    }

    fn submit_rejection_control(
        &mut self,
        previous: viewflow_protocol::AtlasWindowSelection,
        current: viewflow_protocol::AtlasWindowSelection,
        grant_generation: u64,
        cancel_sequence: Option<u64>,
    ) -> Result<(u64, oneshot::Receiver<Result<u64>>)> {
        use crate::atlas_input_recovery::{
            InputRecoveryConfirmation, InputRejectionControl, InputRejectionKind,
        };
        let (ticks, frequency) = (self.qpc)()?;
        let budget = u64::try_from(
            (u128::from(frequency) * u128::from(RECOVERY_NATIVE_BUDGET_NS)).div_ceil(1_000_000_000),
        )?
        .max(1);
        let recovery = self
            .recovery
            .as_mut()
            .context("rejection recovery disabled")?;
        recovery.control_sequence = recovery
            .control_sequence
            .checked_add(1)
            .context("native recovery sequence exhausted")?;
        let sequence = recovery.control_sequence;
        let confirmation = InputRecoveryConfirmation {
            sequence,
            stream: current.stream_id.0,
            window: current.window_id.0,
            atlas_epoch: current.atlas_geometry_epoch,
            config_generation: current.config_generation,
            previous_epoch: previous.source_geometry_epoch,
            geometry_epoch: current.source_geometry_epoch,
            grant_generation,
            atlas_frame: current.atlas_frame_id,
            source_frame: current.source_frame_id,
            placement_generation: current.placement_generation,
            deadline_qpc: ticks
                .checked_add(budget)
                .context("rejection QPC overflow")?,
            frequency,
            rejection: Some(InputRejectionControl {
                kind: if cancel_sequence.is_some() {
                    InputRejectionKind::Resume
                } else {
                    InputRejectionKind::Cancel
                },
                cancel_sequence: cancel_sequence.unwrap_or(sequence),
                previous_atlas_frame: previous.atlas_frame_id,
                previous_source_frame: previous.source_frame_id,
            }),
        };
        let (response, receipt) = oneshot::channel();
        recovery
            .submit
            .try_send(AtlasInputRecoveryRequest {
                confirmation,
                deadline: tokio::time::Instant::now()
                    + Duration::from_nanos(RECOVERY_NATIVE_BUDGET_NS),
                response,
            })
            .map_err(|e| anyhow::anyhow!("rejected recovery owner unavailable: {e}"))?;
        Ok((sequence, receipt))
    }

    fn accept_rejected_notice(
        &mut self,
        notice: crate::atlas_input_recovery::NativeRecoveryNotice,
        qpc: (u64, u64),
    ) -> Result<()> {
        let marker = notice
            .rejection
            .context("missing rejected gesture marker")?;
        let pending = self
            .recovery
            .as_mut()
            .and_then(|r| r.rejected.as_mut())
            .context("unsolicited rejected gesture notice")?;
        let previous = pending.rejected.selection;
        ensure!(
            marker.cancel_sequence == pending.cancel_sequence
                && notice.previous_epoch == previous.source_geometry_epoch
                && notice.previous_atlas_frame == previous.atlas_frame_id
                && notice.previous_source_frame == previous.source_frame_id
                && recovery_selection_advances_or_matches(notice.selection, previous)
                && notice.selection.placement_generation >= previous.placement_generation
                && qpc.0 >= notice.observed_qpc
                && qpc.1 == notice.frequency,
            "rejected gesture notice binding mismatch"
        );
        if notice.physical_drained {
            let cancelled = pending
                .notice
                .context("physical drain before native cancellation")?;
            ensure!(
                notice.observed_qpc >= cancelled.observed_qpc
                    && marker.ingress_boundary
                        == cancelled
                            .rejection
                            .expect("rejected notice")
                            .ingress_boundary,
                "rejected gesture drain boundary mismatch"
            );
            pending.drained = true;
            pending.notice = Some(notice);
        } else {
            ensure!(pending.notice.is_none(), "duplicate rejected cancellation");
            // The single native stdout dispatcher stamped this boundary after
            // every record emitted before cancellation. Nothing after it may
            // be discarded or replayed under a fresh authorization.
            self.native_backlog.retain(|event| event.releases_input()
                || event.ingress_ordinal() > marker.ingress_boundary
                || event.selection().window_id != previous.window_id);
            while let Ok(event) = self.native.try_recv() {
                ensure!(event.ingress_ordinal() > 0, "native input lacks ingress order");
                if event.releases_input() || event.ingress_ordinal() > marker.ingress_boundary
                    || event.selection().window_id != previous.window_id {
                    self.native_backlog.push_back(event);
                }
            }
            ensure!(
                !self.native.is_closed(),
                "native event owner lost during cancellation"
            );
            // Window geometry is an independent ordered lane. A real drag can
            // begin while cancellation of application input is in flight.
            // Keep its bounded queue intact until recovery has completed.
            pending.notice = Some(notice);
        }
        Ok(())
    }

    fn retry_rejected_recovery_selection(
        &mut self,
        rejected: viewflow_protocol::AtlasWindowSelectionRejected,
    ) -> Result<bool> {
        let Some(recovery) = &mut self.recovery else {
            return Ok(false);
        };
        let Some(pending) = &mut recovery.rejected else {
            return Ok(false);
        };
        rejected
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid recovery selection rejection: {error:?}"))?;
        ensure!(
            pending.selection == Some(rejected.selection)
                && pending.cancel_confirmed
                && pending.drained
                && pending.receipt.is_none()
                && pending.authorization.is_none(),
            "recovery rejection does not name its outstanding selection"
        );
        ensure!(
            rejected.reason != viewflow_protocol::AtlasSelectionRejectionReason::WindowWithdrawn,
            "recovery selected window was withdrawn"
        );
        ensure!(
            rejected.released_generation >= pending.rejected.released_generation
                && recovery
                    .authorizations
                    .get(&rejected.selection.window_id)
                    .is_none_or(|authorization| rejected.released_generation
                        >= authorization.lease_generation),
            "recovery rejection regressed source END proof"
        );
        pending.rejected.released_generation = rejected.released_generation;
        pending.retry_after = Some(rejected.selection);
        pending.selection = None;
        // Keep the original native Cancel and physical-drain proof. Only media
        // may advance so the next selection can name a genuinely newer frame.
        recovery.fence.retry_cancelled_selection();
        Ok(true)
    }

    async fn progress_rejected_gesture(
        &mut self,
        now_ns: u64,
        clock: Option<crate::input_runtime::ClockSnapshot>,
        preview: Option<&mut WindowPreviewInput>,
        input_sequence: &mut u64,
    ) -> Result<Option<viewflow_protocol::AtlasWindowSelection>> {
        let Some(recovery) = self.recovery.as_mut() else {
            return Ok(None);
        };
        let Some(pending) = recovery.rejected.as_mut() else {
            return Ok(None);
        };
        if let Some(receipt) = &mut pending.receipt {
            match receipt.try_recv() {
                Ok(result) => {
                    result.context("native rejected gesture control failed")?;
                    pending.receipt = None;
                    if pending.cancel_confirmed {
                        recovery.rejected = None;
                        return Ok(None);
                    }
                    pending.cancel_confirmed = true;
                }
                Err(oneshot::error::TryRecvError::Empty) => return Ok(None),
                Err(oneshot::error::TryRecvError::Closed) => {
                    anyhow::bail!("native rejected gesture receipt lost")
                }
            }
        }
        if !pending.cancel_confirmed || !pending.drained {
            return Ok(None);
        }
        if pending.selection.is_none() {
            if let Some(previous) = pending.retry_after {
                if self.committed.borrow().back().is_none_or(|frame| {
                    frame.frame_id <= previous.atlas_frame_id
                        || frame
                            .tiles
                            .iter()
                            .find(|tile| tile.window_id == previous.window_id)
                            .is_some_and(|tile| tile.source_frame_id <= previous.source_frame_id)
                }) {
                    return Ok(None);
                }
            }
            let original = pending.rejected.selection;
            let fence = recovery.fence.clone();
            fence.arm().await;
            // This is a new selection-only control. The fence may have waited
            // for an in-flight media receipt, so sample its creation time here;
            // the rejected physical event keeps its original expired deadline.
            let selection_now_ns = u64::try_from(self.origin.elapsed().as_nanos())
                .context("fresh selection clock overflow")?;
            // Read after the media forwarding fence: the chosen frame is the
            // latest native committed frame, not the old event's picture.
            let committed = self.committed.borrow();
            let frame = committed.back().context("no committed recovery frame")?;
            *input_sequence = input_sequence
                .checked_add(1)
                .context("recovery selection sequence exhausted")?;
            let selection = viewflow_protocol::AtlasWindowSelection::from_frame(
                frame,
                original.window_id,
                *input_sequence,
                selection_now_ns
                    .checked_add((crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS - crate::input_runtime::INPUT_CLOCK_MAPPING_HEADROOM_NS))
                    .context("fresh selection deadline overflow")?,
            )
            .map_err(|e| anyhow::anyhow!("invalid fresh recovery frame: {e:?}"))?;
            ensure!(
                recovery_selection_advances_or_matches(selection, original)
                    && selection.placement_generation >= original.placement_generation,
                "fresh recovery frame changed rejected tile lineage"
            );
            preview
                .context("recovery preview missing")?
                .select_presented(viewflow_core::PresentedInputIdentity {
                    window: selection.window_id,
                    frame: selection.source_frame_id,
                    geometry_epoch: selection.source_geometry_epoch,
                })?;
            pending.selection = Some(selection);
            return Ok(Some(selection));
        }
        let selection = pending.selection.expect("checked selection");
        let Some(authorization) = pending.authorization else {
            ensure!(
                now_ns.saturating_sub(selection.sender_not_after_ns)
                    < crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS,
                "recovery selection terminal receipt expired"
            );
            return Ok(None);
        };
        crate::input_runtime::conservative_authorization_deadline(
            authorization.source_not_after_ns,
            clock,
            now_ns,
        )
        .map_err(|e| anyhow::anyhow!("fresh recovery source lease expired: {e:?}"))?;
        let original = pending.rejected.selection;
        let cancel_sequence = pending.cancel_sequence;
        let (_, receipt) = self.submit_rejection_control(
            original,
            selection,
            authorization.lease_generation,
            Some(cancel_sequence),
        )?;
        self.recovery
            .as_mut()
            .and_then(|r| r.rejected.as_mut())
            .expect("pending recovery")
            .receipt = Some(receipt);
        Ok(None)
    }

    fn take_recovery_notice(
        &mut self,
    ) -> Result<Option<crate::atlas_input_recovery::NativeRecoveryNotice>> {
        let Some(recovery) = &mut self.recovery else {
            return Ok(None);
        };
        loop {
            match recovery.notices.try_recv() {
                Ok(notice) if self.focus_release_qpc.get(&notice.selection.window_id)
                    .is_some_and(|boundary| notice.observed_qpc <= *boundary) => continue,
                Ok(notice) => return Ok(Some(notice)),
                Err(mpsc::error::TryRecvError::Empty) => return Ok(None),
                Err(mpsc::error::TryRecvError::Disconnected) => {
                    anyhow::bail!("atlas native recovery notice producer ended")
                }
            }
        }
    }

    async fn accept_recovery_notice(
        &mut self,
        notice: crate::atlas_input_recovery::NativeRecoveryNotice,
        now_ns: u64,
        qpc: (u64, u64),
        preview: Option<&mut WindowPreviewInput>,
        input_sequence: &mut u64,
    ) -> Result<Option<viewflow_protocol::AtlasWindowSelection>> {
        ensure!(
            qpc.0 >= notice.observed_qpc && qpc.1 == notice.frequency,
            "atlas recovery notice clock is stale or changed"
        );
        if notice.physical_drained {
            let recovery = self
                .recovery
                .as_ref()
                .context("atlas recovery is not enabled")?;
            let pending = recovery
                .pending
                .as_ref()
                .context("physical drain arrived without cancellation")?;
            ensure!(
                recovery_notice_matches(notice, pending.notice),
                "atlas recovery drain does not match cancelled binding"
            );
            ensure!(
                notice.observed_qpc >= pending.notice.observed_qpc,
                "atlas recovery drain QPC regressed"
            );
            if pending.drained {
                return Ok(None);
            }
            // Notices describe a past native observation. Do not compare them
            // with a watch snapshot sampled by another task. Finish any active
            // handoff first, then select from its final published layout.
            let fence = recovery.fence.clone();
            fence.arm().await;
            let latest = self.committed.borrow().clone();
            let frame = latest
                .back()
                .context("atlas recovery has no committed layout")?;
            *input_sequence = input_sequence
                .checked_add(1)
                .context("atlas input sequence exhausted during recovery drain")?;
            let deadline = u64::try_from(self.origin.elapsed().as_nanos())?
                .max(now_ns)
                .checked_add(RECOVERY_SOURCE_SELECTION_BUDGET_NS)
                .context("atlas recovery drain selection deadline overflow")?;
            let mut selection = viewflow_protocol::AtlasWindowSelection::from_frame(
                frame,
                notice.selection.window_id,
                *input_sequence,
                deadline,
            )
            .map_err(|error| {
                anyhow::anyhow!("atlas recovery current target unavailable: {error:?}")
            })?;
            selection.activate_keyboard = true;
            ensure!(
                recovery_selection_advances_or_matches(selection, notice.selection),
                "atlas recovery current target changed lineage"
            );
            let preview = preview.context("atlas recovery has no active preview route")?;
            ensure!(
                preview.selected_window() == selection.window_id && preview.idle_for_selection(),
                "atlas recovery drain has unresolved preview input"
            );
            preview.select_presented(viewflow_core::PresentedInputIdentity {
                window: selection.window_id,
                frame: selection.source_frame_id,
                geometry_epoch: selection.source_geometry_epoch,
            })?;
            let pending = self
                .recovery
                .as_mut()
                .and_then(|r| r.pending.as_mut())
                .context("atlas recovery cancellation disappeared")?;
            pending.notice = notice;
            pending.selection = selection;
            pending.source_deadline_ns = deadline;
            pending.fresh_authorization = None;
            pending.drained = true;
            return Ok(Some(selection));
        }
        // Cancellation comes from our native child and is not an input grant.
        // It may precede publication of its frame, or arrive after that frame
        // left the bounded history. Keep its identity only for the drain pair;
        // a fresh source selection is made after the physical drain below.
        match self.native.try_recv() {
            Err(mpsc::error::TryRecvError::Empty) => {}
            Ok(_) => anyhow::bail!("native input was queued before atlas recovery cancellation"),
            Err(mpsc::error::TryRecvError::Disconnected) => {
                anyhow::bail!("native input producer ended before atlas recovery cancellation")
            }
        }
        let (previous_authorization, no_pending) = {
            let recovery = self
                .recovery
                .as_ref()
                .context("atlas recovery is not enabled")?;
            (
                recovery
                    .authorizations
                    .get(&notice.selection.window_id)
                    .copied()
                    .context("atlas recovery has no source authorization for cancelled window")?,
                recovery.pending.is_none(),
            )
        };
        ensure!(no_pending, "overlapping atlas recovery cancellation");
        // Source grants and native commits have independent publication queues.
        // This grant is only the generation floor for the next source cleanup;
        // the native notice retains its own old binding for Cancel/Resume.
        eprintln!(
            "atlas-recovery-cancel window={:?} observed_atlas={} observed_source={} previous_source={} known_grant_frame={}",
            notice.selection.window_id,
            notice.selection.atlas_frame_id,
            notice.selection.source_frame_id,
            notice.previous_source_frame,
            previous_authorization.presented_frame
        );
        let preview = preview.context("atlas recovery has no active preview route")?;
        ensure!(
            preview.selected_window() == notice.selection.window_id && preview.idle_for_selection(),
            "atlas recovery cancellation has unresolved preview input"
        );
        let selection = notice.selection;
        let deadline = 0; // No source request exists until physical drain.
        let recovery = self
            .recovery
            .as_mut()
            .context("atlas recovery owner disappeared")?;
        recovery.pending = Some(PendingAtlasRecovery {
            notice,
            selection,
            previous_authorization,
            fresh_authorization: None,
            source_deadline_ns: deadline,
            drained: false,
            receipt: None,
        });
        Ok(None)
    }

    fn progress_recovery(
        &mut self,
        now_ns: u64,
        committed: &VecDeque<AtlasFrame>,
        clock: Option<crate::input_runtime::ClockSnapshot>,
    ) -> Result<bool> {
        let start = {
            let Some(recovery) = &self.recovery else {
                return Ok(false);
            };
            let Some(pending) = &recovery.pending else {
                return Ok(false);
            };
            if !pending.drained {
                return Ok(true);
            }
            ensure!(
                committed
                    .back()
                    .is_some_and(|frame| pending.selection.matches(frame)),
                "atlas recovery committed tile disappeared"
            );
            if pending.fresh_authorization.is_none() {
                ensure!(
                    now_ns < pending.source_deadline_ns,
                    "atlas recovery source authorization timed out"
                );
                return Ok(true);
            }
            crate::input_runtime::conservative_authorization_deadline(
                pending
                    .fresh_authorization
                    .expect("checked above")
                    .source_not_after_ns,
                clock,
                now_ns,
            )
            .map_err(|error| {
                anyhow::anyhow!("atlas recovery source lease is not current: {error:?}")
            })?;
            if !pending.drained || pending.receipt.is_some() {
                return Ok(true);
            }
            (
                pending.notice,
                pending.fresh_authorization.expect("checked above"),
                pending.selection,
            )
        };
        let (ticks, frequency) = (self.qpc)()?;
        ensure!(
            ticks >= start.0.observed_qpc && frequency == start.0.frequency,
            "atlas recovery QPC changed before native resume"
        );
        let budget_ticks = u64::try_from(
            (u128::from(frequency) * u128::from(RECOVERY_NATIVE_BUDGET_NS)).div_ceil(1_000_000_000),
        )?
        .max(1);
        let deadline_qpc = ticks
            .checked_add(budget_ticks)
            .context("atlas recovery QPC deadline overflow")?;
        let deadline = tokio::time::Instant::now()
            .checked_add(Duration::from_nanos(RECOVERY_NATIVE_BUDGET_NS))
            .context("atlas recovery local deadline overflow")?;
        let (sender, receiver) = oneshot::channel();
        let confirmation = {
            let recovery = self
                .recovery
                .as_mut()
                .context("atlas recovery owner disappeared")?;
            recovery.control_sequence = recovery
                .control_sequence
                .checked_add(1)
                .context("atlas recovery control sequence exhausted")?;
            crate::atlas_input_recovery::InputRecoveryConfirmation {
                sequence: recovery.control_sequence,
                stream: start.2.stream_id.0,
                window: start.2.window_id.0,
                atlas_epoch: start.2.atlas_geometry_epoch,
                config_generation: start.2.config_generation,
                previous_epoch: start.0.previous_epoch,
                geometry_epoch: start.2.source_geometry_epoch,
                grant_generation: start.1.lease_generation,
                atlas_frame: start.2.atlas_frame_id,
                source_frame: start.2.source_frame_id,
                placement_generation: start.2.placement_generation,
                deadline_qpc,
                frequency,
                rejection: None,
            }
        };
        let request = AtlasInputRecoveryRequest {
            confirmation,
            deadline,
            response: sender,
        };
        self.recovery
            .as_ref()
            .context("atlas recovery owner disappeared")?
            .submit
            .try_send(request)
            .map_err(|error| anyhow::anyhow!("atlas recovery media owner unavailable: {error}"))?;
        self.recovery
            .as_mut()
            .and_then(|recovery| recovery.pending.as_mut())
            .context("atlas recovery pending state disappeared")?
            .receipt = Some(receiver);
        Ok(true)
    }

    fn collect_recovery_receipt(&mut self) -> Result<bool> {
        let Some(recovery) = &mut self.recovery else {
            return Ok(false);
        };
        let Some(pending) = &mut recovery.pending else {
            return Ok(false);
        };
        let Some(receipt) = &mut pending.receipt else {
            return Ok(true);
        };
        match receipt.try_recv() {
            Ok(Ok(_)) => {
                match self.native.try_recv() {
                    Err(mpsc::error::TryRecvError::Empty) => {}
                    Ok(_) => anyhow::bail!("native input arrived while atlas recovery was fenced"),
                    Err(mpsc::error::TryRecvError::Disconnected) => {
                        anyhow::bail!("native input producer ended while atlas recovery was fenced")
                    }
                }
                recovery.pending = None;
                Ok(false)
            }
            Ok(Err(error)) => Err(error.context("atlas native recovery rejected")),
            Err(oneshot::error::TryRecvError::Empty) => Ok(true),
            Err(oneshot::error::TryRecvError::Closed) => {
                anyhow::bail!("atlas recovery media owner dropped its receipt")
            }
        }
    }

    /// Consume controls forwarded by the sole atlas media reader. Source grants
    /// confirm a locally selected window; grants cannot choose another window.
    /// Wait for source readiness within the original connection startup deadline
    /// before starting the unchanged periodic clock-liveness checks.
    /// # Errors
    /// Native/media/control owner loss, uncertain buttons or transport failure
    /// closes the connection, releasing its source-side native input session.
    #[allow(clippy::too_many_lines)] // Keep connection/task/queue ownership in one cancellation scope.
    pub async fn serve(
        mut self,
        connection: &quinn::Connection,
        controls: mpsc::Receiver<DomainControl>,
        writer: crate::shared_control::SharedControlSender,
        startup_deadline: tokio::time::Instant,
    ) -> Result<()> {
        ensure!(
            writer.belongs_to(connection),
            "atlas input writer belongs to another connection"
        );
        let mut application_icons = crate::window_icon::ReceiverIcons::new();
        let outbound = writer.outbound();
        let clock = crate::ProcessClock {
            origin: self.origin,
        };
        let (replies, reply_rx) = mpsc::channel(4);
        let (snapshots, snapshot_rx) = watch::channel(None);
        let (ready, readiness) = tokio::sync::oneshot::channel();
        let mut ready = Some(ready);
        let probe_connection = connection.clone();
        let probe_clock = clock.clone();
        let probe_outbound = outbound.clone();
        let mut tasks = crate::WindowConnectionTasks {
            writer: None,
            probe: tokio::spawn(async move {
                tokio::time::timeout_at(startup_deadline, readiness)
                    .await
                    .context("atlas source input readiness timed out")?
                    .context("atlas source input readiness owner ended")?;
                crate::run_probe_loop(
                    "atlas-selected-preview",
                    probe_connection,
                    Duration::from_millis(250),
                    Duration::from_millis(250),
                    probe_clock,
                    probe_outbound,
                    reply_rx,
                    snapshots,
                )
                .await
            }),
            outbound: outbound.clone(),
        };
        #[cfg(windows)]
        let cursor_receiver = self
            .desktop_cursor
            .map(|display| {
                crate::input_runtime::InputReceiver::new(
                    crate::input_runtime::InputBackendMode::Native,
                    Some(self.owner),
                )
                .map(|receiver| receiver.with_desktop_display(display))
            })
            .transpose()?;
        #[cfg(not(windows))]
        let cursor_receiver = None;
        let (preview_send, mut preview_controls) = mpsc::channel(64);
        let cursor_work = crate::atlas_cursor_receiver::run(
            connection,
            controls,
            preview_send,
            cursor_receiver,
            writer.clone(),
            self.source,
            self.owner,
            clock.clone(),
            snapshot_rx.clone(),
        );
        tokio::pin!(cursor_work);
        let work = async {
            let (samples, sample_rx) = watch::channel(PreviewPointerState::default());
            let (acks, _ack_rx) = watch::channel(None);
            let (events, event_rx) = PreviewPointerEvents::channel();
            let mut event_rx = Some(event_rx);
            let mut preview: Option<WindowPreviewInput> = None;
            let mut initial_authorization = None;
            let mut initial_keyboard_authorization = None;
            let mut waiting: Option<PreviewPointerEvent> = None;
            let mut waiting_selection: Option<AwaitingSelection> = None;
            let mut waiting_layout: Option<(
                viewflow_protocol::AtlasWindowSelection,
                PreviewPointerEvent,
            )> = None;
            let mut sequence = 0_u64;
            let mut released_selection_floor = 0_u64;
            let mut focus_releases = VecDeque::new();
            let mut desktop = crate::desktop_receiver_state::DesktopReceiverState::default();
            let mut tick = tokio::time::interval(Duration::from_millis(1));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    incoming = preview_controls.recv() => match incoming.context("atlas input control owner disappeared")? {
                        DomainControl::ApplicationIcon(icon) => {
                            if let Err(error) = application_icons.install(icon) {
                                eprintln!("application icon unavailable: {error:#}");
                            }
                        }
                        DomainControl::WindowPointerAuthorization(auth) => {
                            if let Some(ready) = ready.take() { let _ = ready.send(()); }
                            if desktop.active() { continue; }
                            // Old source announcements can be in flight at a local switch.
                            if let Some(p) = &mut preview {
                                if p.selected_window() == auth.target_window && p.accepts_selected_geometry(auth.geometry_epoch) { p.authorize(auth)?; }
                            } else {
                                initial_authorization = Some(auth);
                            }
                            if let Some(recovery) = &mut self.recovery {
                                recovery.authorizations.insert(auth.target_window, auth);
                            }
                        }
                        DomainControl::AtlasWindowSelectionAccepted(accepted) => {
                            if accepted.selection.sequence <= released_selection_floor { continue; }
                            accepted.validate().map_err(|error| anyhow::anyhow!("invalid selection acceptance: {error:?}"))?;
                            if let Some(waiting) = &mut waiting_selection {
                                waiting.accept(accepted)?;
                            } else {
                                ensure!(self.recovery.as_ref().is_some_and(|recovery|
                                    recovery.pending.as_ref().is_some_and(|pending| pending.selection == accepted.selection)
                                    || recovery.rejected.as_ref().is_some_and(|pending| pending.selection == Some(accepted.selection))),
                                    "selection acceptance has no outstanding request");
                            }
                            let auth = accepted.authorization;
                            if let Some(p) = &mut preview {
                                p.authorize_selection(accepted)?;
                            } else {
                                initial_authorization = Some(auth);
                            }
                            self.record_source_authorization(auth);
                        }
                        DomainControl::AtlasWindowSelectionRejected(rejected) => {
                            if rejected.selection.sequence <= released_selection_floor { continue; }
                            if self.retry_rejected_recovery_selection(rejected)? { continue; }
                            ensure!(waiting_selection.as_ref().is_some_and(|waiting| waiting.selection == rejected.selection) && waiting.is_some(), "selection rejection does not name an unforwarded event");
                            let p = preview.as_mut().context("selection rejected without preview")?;
                            self.begin_rejected_gesture(rejected, p).await?;
                            // The original event is destroyed only after exact rejection and END proof.
                            waiting = None;
                            waiting_selection = None;
                            samples.send_replace(PreviewPointerState::default());
                        }
                        DomainControl::WindowPointerAck(ack) => preview.as_mut().context("atlas ACK without local input")?.acknowledge(ack)?,
                        DomainControl::WindowKeyboardAuthorization(auth) => {
                            ensure!(self.allow_keyboard, "atlas keyboard is not locally enabled");
                            if desktop.active() { continue; }
                            if let Some(p) = &mut preview {
                                if p.selected_window() == auth.target_window && p.accepts_selected_geometry(auth.geometry_epoch) { p.authorize_keyboard(auth)?; }
                            } else { initial_keyboard_authorization = Some(auth); }
                        }
                        DomainControl::WindowKeyboardAck(ack) => {
                            ensure!(self.allow_keyboard, "atlas keyboard is not locally enabled");
                            preview.as_mut().context("atlas key ACK without local input")?.acknowledge_keyboard(ack)?;
                        }
                        DomainControl::DesktopWindowMoveAck(ack) => {
                            ensure!(self.desktop_moves.is_some(), "desktop ACK on disabled route");
                            desktop.acknowledge(ack, clock.now_ns())?;
                        }
                        DomainControl::ClockSyncReply(reply) => crate::dispatch_clock_reply(&replies, reply).await?,
                        DomainControl::ClockSyncProbe(probe) => {
                            let t1_receive_ns = clock.now_ns();
                            writer.send(wire::control_envelope::Payload::ClockSyncReply(wire::ClockSyncReply {
                                probe_id: probe.probe_id, t0_send_ns: probe.t0_send_ns,
                                t1_receive_ns, t2_send_ns: clock.now_ns(),
                            }), tokio::time::Instant::now() + Duration::from_nanos(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS)).await?;
                            // The source starts this route only after native
                            // bootstrap; reply before initiating our own probe.
                            if let Some(ready) = ready.take() { let _ = ready.send(()); }
                        }
                        _ => anyhow::bail!("unexpected selected atlas preview control"),
                    },
                    _ = tick.tick() => {},
                    reason = connection.closed() => return Err(reason).context("atlas selected preview disconnected"),
                }
                ensure!(
                    !preview_controls.is_closed() && !self.native.is_closed(),
                    "atlas input producer ended"
                );
                self.committed.has_changed()?;
                snapshot_rx.has_changed()?;
                let snapshot = *snapshot_rx.borrow();
                let committed = self.committed.borrow().clone();
                while self.native_backlog.len() < 128 {
                    match self.native.try_recv() {
                        Ok(event) => self.native_backlog.push_back(event),
                        Err(_) => break,
                    }
                }
                while let Some(index) = self.native_backlog.iter().position(AtlasNativePointer::releases_input) {
                    let event = self.native_backlog.remove(index).expect("located release");
                    let window = event.selection().window_id;
                    self.focus_release_qpc.insert(window, event.focus_release_qpc());
                    self.native_backlog.retain(|queued| queued.selection().window_id != window
                        || queued.ingress_ordinal() > event.ingress_ordinal());
                    focus_releases.push_back(window);
                    released_selection_floor = sequence;
                    waiting = None;
                    waiting_selection = None;
                    waiting_layout = None;
                    if let Some(recovery) = self.recovery.as_mut() {
                        recovery.pending = None;
                        recovery.rejected = None;
                        recovery.fence.retry_cancelled_selection();
                        while recovery.notices.try_recv().is_ok() {}
                    }
                }
                if !focus_releases.is_empty() {
                    if let Some(p) = preview.as_mut() { p.pump(snapshot, &outbound).await?; }
                    if preview.as_ref().is_some_and(|p| !p.idle_for_selection()) { continue; }
                    while let Some(window) = focus_releases.pop_front() {
                        writer.send(wire::control_envelope::Payload::WindowInputRelease(
                            wire::WindowInputRelease { window_id: Some(wire::Id128 {
                                high: (window.0 >> 64) as u64, low: window.0 as u64 }) }),
                            tokio::time::Instant::now() + Duration::from_secs(5)).await?;
                        if let Some(p) = preview.as_mut().filter(|p| p.selected_window() == window) {
                            p.pause_for_desktop_move()?;
                        }
                    }
                }
                desktop.check_deadline(clock.now_ns())?;
                if let Some(moves) = &mut self.desktop_moves {
                    ensure!(!moves.is_closed(), "desktop native event owner ended");
                    if !desktop.pending()
                        && self
                            .recovery
                            .as_ref()
                            .is_none_or(|r| r.pending.is_none() && r.rejected.is_none())
                        && waiting.is_none()
                        && waiting_layout.is_none()
                        && (desktop.active() || (self.native.is_empty() && self.native_backlog.is_empty()))
                        && preview
                            .as_ref()
                            .is_none_or(WindowPreviewInput::idle_for_selection)
                    {
                        if let Some(event) = desktop.next_event(moves) {
                            if desktop.discard_rejected_drag(event) {
                                continue;
                            }
                            ensure!(
                                self.recovery
                                    .as_ref()
                                    .is_none_or(|r| r.pending.is_none() && r.rejected.is_none()),
                                "desktop gesture overlaps input recovery"
                            );
                            let now = clock.now_ns();
                            let (qpc, frequency) = (self.qpc)()?;
                            let deadline_ns = event.sender_not_after_ns(qpc, frequency, now)?;
                            let movement = desktop.prepare(
                                event,
                                self.source,
                                self.owner,
                                deadline_ns,
                                &committed,
                            )?;
                            if movement.phase == viewflow_protocol::DesktopWindowMovePhase::Begin {
                                if let Some(p) = &mut preview {
                                    p.pause_for_desktop_move()?;
                                }
                                initial_authorization = None;
                                initial_keyboard_authorization = None;
                                samples.send_replace(PreviewPointerState::default());
                            }
                            let deadline = self
                                .origin
                                .checked_add(Duration::from_nanos(deadline_ns))
                                .context("desktop deadline overflow")?;
                            writer
                                .send(
                                    wire::control_envelope::Payload::DesktopWindowMove(
                                        movement.into(),
                                    ),
                                    deadline.into(),
                                )
                                .await?;
                        }
                    }
                }
                if desktop.active() {
                    continue;
                }
                // Record cancellation independently of the media publication
                // queue. Once physical input drains, settle the active frame
                // and request one source END/BEGIN for that current target.
                while let Some(notice) = self.take_recovery_notice()? {
                    let now = clock.now_ns();
                    let qpc = (self.qpc)()?;
                    if notice.rejection.is_some() {
                        self.accept_rejected_notice(notice, qpc)?;
                        continue;
                    }
                    if let Some(selection) = self
                        .accept_recovery_notice(notice, now, qpc, preview.as_mut(), &mut sequence)
                        .await?
                    {
                        let deadline = std::time::Instant::now()
                            + Duration::from_nanos(
                                crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS,
                            );
                        writer
                            .send(
                                wire::control_envelope::Payload::AtlasWindowSelection(
                                    selection.into(),
                                ),
                                deadline.into(),
                            )
                            .await?;
                    }
                }
                if let Some(selection) = self
                    .progress_rejected_gesture(
                        clock.now_ns(),
                        snapshot,
                        preview.as_mut(),
                        &mut sequence,
                    )
                    .await?
                {
                    let deadline = std::time::Instant::now()
                        + Duration::from_nanos(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS);
                    writer
                        .send(
                            wire::control_envelope::Payload::AtlasWindowSelection(selection.into()),
                            deadline.into(),
                        )
                        .await?;
                }
                if self.recovery.as_ref().is_some_and(|r| r.rejected.is_some()) {
                    continue;
                }
                let recovery_committed = self.committed.borrow().clone();
                let recovery_active =
                    self.progress_recovery(clock.now_ns(), &recovery_committed, snapshot)?;
                let recovery_active = self.collect_recovery_receipt()? || recovery_active;
                if recovery_active {
                    // Do not pump an old authorization or dequeue native input
                    // while source cleanup, physical drain, or native receipt
                    // is pending.  A queued pointer record at receipt time is
                    // terminal rather than being replayed under the new grant.
                    continue;
                }
                if let Some(event) = waiting {
                    let now = clock.now_ns();
                    if now >= event.sample.sender_not_after_ns {
                        if waiting_selection
                            .as_ref()
                            .is_some_and(|waiting| waiting.authorized)
                            && event.is_motion()
                        {
                            waiting = None;
                            waiting_selection = None;
                            continue;
                        }
                        ensure!(
                            now - event.sample.sender_not_after_ns
                                < crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS,
                            "expired unforwarded selection has no terminal receipt"
                        );
                        if self.recovery.is_some() {
                            // Preserve correlation for an explicit rejection while
                            // permanently forbidding forwarding after event expiry.
                            continue;
                        }
                        // Keys and wheels share this FIFO with buttons. Record
                        // metadata only (never key usages/text), so a failed
                        // selection identifies the actual event and missing
                        // authority without changing its original deadline.
                        ensure!(
                            event.is_motion(),
                            "atlas input expired awaiting selection: sequence={} window={:?} frame={} button={} wheel={} key={} overdue_ns={} pointer_authorized={} keyboard_authorized={} native_queued={}",
                            event.sample.sample_sequence,
                            event.sample.presented.window,
                            event.sample.presented.frame,
                            event.button.is_some(),
                            event.wheel.is_some(),
                            event.key.is_some(),
                            now - event.sample.sender_not_after_ns,
                            preview
                                .as_ref()
                                .is_some_and(|p| p.authorized_presented(event.sample.presented)),
                            preview
                                .as_ref()
                                .is_some_and(|p| p.keyboard_presented(event.sample.presented)),
                            self.native.len()
                        );
                        if waiting_selection
                            .as_ref()
                            .is_some_and(|waiting| waiting.authorized)
                        {
                            waiting = None;
                            waiting_selection = None;
                        }
                    } else if waiting_selection
                        .as_ref()
                        .is_some_and(|waiting| waiting.authorized)
                        && preview.as_ref().is_some_and(|p| {
                            p.authorized_presented(event.sample.presented)
                                && (event.key.is_none()
                                    || p.keyboard_presented(event.sample.presented))
                        })
                    {
                        samples.send_replace(PreviewPointerState {
                            presented: Some(event.sample.presented),
                            motion: None,
                        });
                        events.push(event)?;
                        waiting = None;
                        waiting_selection = None;
                    }
                }
                if let Some(p) = &mut preview {
                    p.pump(snapshot, &outbound).await?;
                }
                if waiting.is_some() || preview.as_ref().is_some_and(|p| !p.idle_for_selection()) {
                    continue;
                }
                // prepare_atlas deliberately grants no initial application
                // authority: it needs this first selection before native BEGIN.
                // A source clock probe also establishes route readiness. Once
                // our clock is sampled, dequeue to request selection, while
                // `waiting` still fences every app event until its exact grant.
                if preview.is_none() && (ready.is_some() || snapshot.is_none()) {
                    continue;
                }
                let candidate = if let Some(candidate) = waiting_layout.take() {
                    Some(candidate)
                } else {
                    let native = match self.native_backlog.pop_front().map(Ok).unwrap_or_else(|| self.native.try_recv()) {
                        Ok(event) => event,
                        Err(mpsc::error::TryRecvError::Empty) => continue,
                        Err(mpsc::error::TryRecvError::Disconnected) => {
                            anyhow::bail!("atlas native input ended")
                        }
                    };
                    sequence = sequence
                        .checked_add(1)
                        .context("atlas native sequence exhausted")?;
                    ensure!(
                        desktop.allows_native_ordinal(native.ingress_ordinal()),
                        "application input predates confirmed desktop end"
                    );
                    let local_ns = clock.now_ns(); // Sample before QPC to avoid deadline extension.
                    let (qpc, frequency) = (self.qpc)()?;
                    native.into_event(sequence, local_ns, qpc, frequency)?
                };
                let Some((mut selection, event)) = candidate else {
                    continue;
                };
                ensure!(
                    self.allow_wheel || event.wheel.is_none(),
                    "atlas wheel is not locally enabled"
                );
                ensure!(
                    self.allow_keyboard || event.key.is_none(),
                    "atlas keyboard is not locally enabled"
                );
                selection.activate_keyboard &= self.allow_keyboard;
                if clock.now_ns() >= selection.sender_not_after_ns {
                    ensure!(
                        event.is_motion(),
                        "atlas input expired awaiting committed layout: sequence={} window={:?} frame={} button={} wheel={} key={}",
                        event.sample.sample_sequence,
                        event.sample.presented.window,
                        event.sample.presented.frame,
                        event.button.is_some(),
                        event.wheel.is_some(),
                        event.key.is_some()
                    );
                    continue;
                }
                {
                    let committed = self.committed.borrow();
                    ensure!(committed.len() <= 32, "atlas committed history overflow");
                    if !committed.iter().any(|frame| selection.matches(frame)) {
                        waiting_layout = Some((selection, event));
                        continue;
                    }
                }
                if let Some(p) = &mut preview {
                    p.select_presented(event.sample.presented)?;
                } else {
                    let mut selected = WindowPreviewInput::new(
                        self.owner,
                        self.source,
                        selection.window_id,
                        self.origin,
                        sample_rx.clone(),
                        acks.clone(),
                    )?;
                    selected.select_presented(event.sample.presented)?;
                    let events = event_rx
                        .take()
                        .context("atlas native event receiver missing")?;
                    preview = Some(if self.allow_keyboard {
                        selected.with_direct_keyboard(events)?
                    } else if self.allow_wheel {
                        selected.with_buttons_and_wheel(events)?
                    } else {
                        selected.with_buttons(events)?
                    });
                    if let Some(auth) = initial_authorization.take() {
                        if auth.target_window == selection.window_id
                            && auth.geometry_epoch == selection.source_geometry_epoch
                        {
                            preview
                                .as_mut()
                                .context("selected preview missing")?
                                .authorize(auth)?;
                        }
                    }
                    if let Some(auth) = initial_keyboard_authorization.take() {
                        if auth.target_window == selection.window_id
                            && auth.geometry_epoch == selection.source_geometry_epoch
                        {
                            preview
                                .as_mut()
                                .context("selected preview missing")?
                                .authorize_keyboard(auth)?;
                        }
                    }
                }
                samples.send_replace(PreviewPointerState::default());
                let deadline = std::time::Instant::now()
                    + Duration::from_nanos(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS);
                writer
                    .send(
                        wire::control_envelope::Payload::AtlasWindowSelection(selection.into()),
                        deadline.into(),
                    )
                    .await?;
                waiting = Some(event);
                waiting_selection = Some(AwaitingSelection::new(selection));
            }
        };
        tokio::pin!(work);
        let result = tokio::select! {
            result = &mut tasks.probe => result.context("atlas input clock task failed")?,
            result = &mut work => result,
            result = &mut cursor_work => result,
        };
        connection.close(0_u32.into(), b"atlas selected input ended");
        result
    }
}
