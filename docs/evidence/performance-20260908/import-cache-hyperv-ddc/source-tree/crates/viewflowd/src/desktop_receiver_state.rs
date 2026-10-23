//! Receiver-owned desktop gesture sequencing, distinct from application input.
use crate::desktop_pointer::AtlasDesktopMove;
use anyhow::{Context, Result, ensure};
use viewflow_protocol::{
    AtlasFrame, DesktopWindowMove, DesktopWindowMoveAck, DesktopWindowMovePhase as Phase,
    DesktopWindowMoveResult as Outcome, Id128,
};

#[derive(Default)]
pub(crate) struct DesktopReceiverState {
    active: Option<DesktopWindowMove>,
    pending: Option<DesktopWindowMove>,
    pending_ordinal: u64,
    native_sequence: u64,
    deferred: Option<AtlasDesktopMove>,
    confirmed_end_ordinal: u64,
    rejected_drag: Option<(Id128, Id128)>,
}

impl DesktopReceiverState {
    /// Keep the newest consecutive position while preserving gesture boundaries.
    /// At most one bounded channel worth of events is examined per tick.
    pub(crate) fn next_event(
        &mut self,
        moves: &mut tokio::sync::mpsc::Receiver<AtlasDesktopMove>,
    ) -> Option<AtlasDesktopMove> {
        let mut event = self.deferred.take().or_else(|| moves.try_recv().ok())?;
        if event.phase != Phase::Update {
            return Some(event);
        }
        for _ in 0..64 {
            let Ok(next) = moves.try_recv() else {
                break;
            };
            if next.phase == Phase::Update
                && next.drag_id == event.drag_id
                && next.selection.window_id == event.selection.window_id
                && next.selection.stream_id == event.selection.stream_id
                && next.selection.config_generation == event.selection.config_generation
                && next.topology_generation == event.topology_generation
                && event.selection.sequence.checked_add(1) == Some(next.selection.sequence)
                && next.ingress_ordinal() > event.ingress_ordinal()
            {
                event = next;
            } else {
                self.deferred = Some(next);
                break;
            }
        }
        Some(event)
    }

    pub(crate) fn allows_native_ordinal(&self, ordinal: u64) -> bool {
        self.confirmed_end_ordinal == 0 || ordinal > self.confirmed_end_ordinal
    }
    pub(crate) fn active(&self) -> bool {
        self.active.is_some()
            || self.rejected_drag.is_some()
            || self
                .deferred
                .is_some_and(|event| event.phase == Phase::Begin)
    }
    pub(crate) fn discard_rejected_drag(&mut self, event: AtlasDesktopMove) -> bool {
        if self.rejected_drag != Some((event.selection.window_id, Id128(u128::from(event.drag_id))))
        {
            return false;
        }
        if matches!(event.phase, Phase::End | Phase::Cancel) {
            self.rejected_drag = None;
            self.confirmed_end_ordinal = event.ingress_ordinal();
        }
        true
    }
    pub(crate) fn pending(&self) -> bool {
        self.pending.is_some()
    }
    pub(crate) fn check_deadline(&self, now: u64) -> Result<()> {
        ensure!(
            self.pending.is_none_or(|p| now < p.sender_not_after_ns),
            "desktop move acknowledgement expired"
        );
        Ok(())
    }

    pub(crate) fn reject_begin(&mut self, event: AtlasDesktopMove) {
        debug_assert_eq!(event.phase, Phase::Begin);
        self.rejected_drag = Some((event.selection.window_id, Id128(u128::from(event.drag_id))));
    }

    /// Native events and committed-layout notices arrive on separate channels.
    /// Wait for a not-yet-published picture without consuming the gesture tail;
    /// an evicted picture may use the current layout of the same window.
    pub(crate) fn prepare_when_committed(
        &mut self,
        mut event: AtlasDesktopMove,
        source: Id128,
        owner: Id128,
        deadline: u64,
        frames: &std::collections::VecDeque<AtlasFrame>,
    ) -> Result<Option<DesktopWindowMove>> {
        if event.phase == Phase::Begin {
            ensure!(
                self.active.is_none() && self.pending.is_none() && event.selection.sequence == 1,
                "desktop begin conflicts with active gesture"
            );
            ensure!(
                self.deferred.is_none(),
                "desktop deferred event already occupied"
            );
            let selection = event.selection;
            if !frames.iter().any(|frame| selection.matches(frame)) {
                let Some(latest) = frames.back() else {
                    self.deferred = Some(event);
                    return Ok(None);
                };
                if latest.stream_id != selection.stream_id
                    || latest.config_generation != selection.config_generation
                {
                    self.reject_begin(event);
                    return Ok(None);
                }
                if latest.frame_id < selection.atlas_frame_id {
                    self.deferred = Some(event);
                    return Ok(None);
                }
                // Never redirect a stale event to another window or an old
                // membership snapshot. The source still validates this base.
                let compatible = latest.desktop.as_ref().is_some_and(|layout| {
                    layout.topology_generation == event.topology_generation
                        && layout
                            .windows
                            .iter()
                            .any(|window| window.window_id == selection.window_id && window.movable)
                }) && latest.tiles.iter().any(|tile| {
                    tile.window_id == selection.window_id
                        && tile.geometry_epoch == selection.source_geometry_epoch
                        && tile.placement_generation == selection.placement_generation
                });
                if !compatible {
                    self.reject_begin(event);
                    return Ok(None);
                }
                event.selection = viewflow_protocol::AtlasWindowSelection::from_frame(
                    latest,
                    selection.window_id,
                    selection.sequence,
                    selection.sender_not_after_ns,
                )
                .map_err(|error| {
                    anyhow::anyhow!("invalid committed desktop selection: {error:?}")
                })?;
            }
        }
        self.prepare(event, source, owner, deadline, frames)
            .map(Some)
    }

    pub(crate) fn prepare(
        &mut self,
        event: AtlasDesktopMove,
        source: Id128,
        owner: Id128,
        deadline: u64,
        frames: &std::collections::VecDeque<AtlasFrame>,
    ) -> Result<DesktopWindowMove> {
        ensure!(
            self.pending.is_none(),
            "desktop move already awaiting acknowledgement"
        );
        let selection = event.selection;
        ensure!(
            event.ingress_ordinal() > self.pending_ordinal,
            "desktop ingress order regressed"
        );
        if event.phase == Phase::Begin {
            ensure!(
                self.active.is_none() && selection.sequence == 1,
                "desktop begin conflicts with active gesture"
            );
            let frame = frames
                .iter()
                .find(|f| selection.matches(f))
                .context("desktop begin lacks exact committed frame")?;
            let layout = frame
                .desktop
                .as_ref()
                .context("desktop begin on non-desktop frame")?;
            ensure!(
                layout.topology_generation == event.topology_generation
                    && layout
                        .windows
                        .iter()
                        .any(|w| w.window_id == selection.window_id && w.movable),
                "desktop begin lacks movable placement"
            );
        } else {
            let previous = self.active.context("desktop update without begin")?;
            ensure!(
                previous.window_id == selection.window_id
                    && previous.stream_id == selection.stream_id
                    && previous.config_generation == selection.config_generation
                    && previous.topology_generation == event.topology_generation
                    && previous.drag_id == Id128(u128::from(event.drag_id))
                    && selection.sequence > self.native_sequence,
                "desktop gesture lineage mismatch"
            );
        }
        // A drag is anchored once at Begin. New video frames do not replace
        // its source geometry, and evicting that video frame cannot end a drag.
        let (base_atlas_frame, base_geometry_epoch) = if event.phase == Phase::Begin {
            (selection.atlas_frame_id, selection.source_geometry_epoch)
        } else {
            let previous = self.active.context("desktop update without begin")?;
            (previous.base_atlas_frame, previous.base_geometry_epoch)
        };
        let movement = DesktopWindowMove {
            source_device: source,
            owner_device: owner,
            stream_id: selection.stream_id,
            config_generation: selection.config_generation,
            topology_generation: event.topology_generation,
            window_id: selection.window_id,
            drag_id: Id128(u128::from(event.drag_id)),
            sequence: if event.phase == Phase::Begin {
                1
            } else {
                self.active
                    .context("desktop update without begin")?
                    .sequence
                    .checked_add(1)
                    .context("desktop sequence exhausted")?
            },
            phase: event.phase,
            base_atlas_frame,
            base_geometry_epoch,
            sender_not_after_ns: deadline,
            desired_x_millidip: event.desired_bounds.x_millidip,
            desired_y_millidip: event.desired_bounds.y_millidip,
            desired_width_millidip: event.desired_bounds.width_millidip,
            desired_height_millidip: event.desired_bounds.height_millidip,
        };
        movement
            .validate()
            .map_err(|e| anyhow::anyhow!("invalid desktop intent: {e:?}"))?;
        self.active = Some(movement);
        self.pending = Some(movement);
        self.pending_ordinal = event.ingress_ordinal();
        self.native_sequence = selection.sequence;
        Ok(movement)
    }
    pub(crate) fn acknowledge(&mut self, ack: DesktopWindowMoveAck, now: u64) -> Result<()> {
        self.check_deadline(now)?;
        let p = self
            .pending
            .context("unsolicited desktop acknowledgement")?;
        ensure!(
            ack.source_device == p.source_device
                && ack.owner_device == p.owner_device
                && ack.stream_id == p.stream_id
                && ack.config_generation == p.config_generation
                && ack.topology_generation == p.topology_generation
                && ack.window_id == p.window_id
                && ack.drag_id == p.drag_id
                && ack.sequence == p.sequence,
            "desktop acknowledgement lineage mismatch"
        );
        let ending = matches!(p.phase, Phase::End | Phase::Cancel);
        if ack.result == Outcome::Rejected
            || (p.phase == Phase::Update && ack.result == Outcome::Ended)
        {
            // The source has declined, locally cancelled, or handed off this gesture.
            // Drain only its remaining native events; other windows and the
            // shared media connection are unaffected by this recoverable result.
            if ending {
                self.confirmed_end_ordinal = self.pending_ordinal;
            } else {
                self.rejected_drag = Some((p.window_id, p.drag_id));
            }
            self.active = None;
            self.pending = None;
            return Ok(());
        }
        ensure!(
            ack.result
                == if ending {
                    Outcome::Ended
                } else {
                    Outcome::Applied
                },
            "desktop movement rejected"
        );
        self.pending = None;
        if ending {
            self.confirmed_end_ordinal = self.pending_ordinal;
            self.active = None;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use viewflow_protocol::{
        AtlasDesktopLayout, AtlasTile, AtlasWindowPlacement, DesktopRect, DesktopWindowMoveAck,
    };

    const STREAM: Id128 = Id128(9);
    const WINDOW: Id128 = Id128(8);

    fn bounds() -> DesktopRect {
        DesktopRect {
            x_millidip: 0,
            y_millidip: 0,
            width_millidip: 1_000,
            height_millidip: 1_000,
        }
    }

    fn frame(movable: bool) -> AtlasFrame {
        let bounds = bounds();
        AtlasFrame {
            patches: None,
            stream_id: STREAM,
            frame_id: 100,
            geometry_epoch: 2,
            config_generation: 3,
            layout_revision: 4,
            width: 64,
            height: 64,
            source_submitted_ns: 10,
            tiles: vec![AtlasTile {
                window_id: WINDOW,
                placement_generation: 4,
                geometry_epoch: 7,
                source_frame_id: 19,
                source_submitted_ns: 10,
                x: 0,
                y: 0,
                width: 64,
                height: 64,
            }],
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: Some(AtlasDesktopLayout {
                topology_generation: 5,
                viewport: bounds,
                windows: vec![AtlasWindowPlacement {
                    window_id: WINDOW,
                    bounds,
                    movable,
                    z_order: 0,
                    raise_serial: 0,
                }],
            }),
        }
    }

    fn event(phase: Phase, sequence: u64) -> AtlasDesktopMove {
        let phase = match phase {
            Phase::Begin => "begin",
            Phase::Update => "update",
            Phase::End => "end",
            Phase::Cancel => "cancel",
        };
        AtlasDesktopMove::parse(&format!(
            "desktop-move-v1 stream_hi=0 stream_lo=9 atlas_frame=100 atlas_epoch=2 config_generation=3 layout_revision=4 window_hi=0 window_lo=8 placement_generation=4 source_epoch=7 source_frame=19 topology_generation=5 drag_id=6 sequence={sequence} phase={phase} deadline_qpc=100 qpc_frequency=1000 x_millidip=0 y_millidip=0 width_millidip=1000 height_millidip=1000"
        ))
        .unwrap()
        .with_ingress_ordinal(sequence)
        .unwrap()
    }

    fn ack(request: DesktopWindowMove, result: Outcome) -> DesktopWindowMoveAck {
        DesktopWindowMoveAck {
            source_device: request.source_device,
            owner_device: request.owner_device,
            stream_id: request.stream_id,
            config_generation: request.config_generation,
            topology_generation: request.topology_generation,
            window_id: request.window_id,
            drag_id: request.drag_id,
            sequence: request.sequence,
            result,
            actual_bounds: bounds(),
        }
    }

    #[tokio::test]
    async fn queued_positions_coalesce_but_end_and_wire_order_are_preserved() {
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        for (phase, sequence) in [
            (Phase::Begin, 1),
            (Phase::Update, 2),
            (Phase::Update, 3),
            (Phase::Update, 4),
            (Phase::End, 5),
        ] {
            tx.send(event(phase, sequence)).await.unwrap();
        }
        let mut state = DesktopReceiverState::default();
        let frames = VecDeque::from([frame(true)]);
        for (native_sequence, wire_sequence, phase) in [
            (1, 1, Phase::Begin),
            (4, 2, Phase::Update),
            (5, 3, Phase::End),
        ] {
            let next = state.next_event(&mut rx).unwrap();
            assert_eq!(next.selection.sequence, native_sequence);
            assert_eq!(next.phase, phase);
            let request = state
                .prepare(next, Id128(1), Id128(2), 500, &frames)
                .unwrap();
            assert_eq!(request.sequence, wire_sequence);
            state
                .acknowledge(
                    ack(
                        request,
                        if phase == Phase::End {
                            Outcome::Ended
                        } else {
                            Outcome::Applied
                        },
                    ),
                    499,
                )
                .unwrap();
        }
        assert!(!state.active());
        assert!(!state.allows_native_ordinal(5));
        assert!(state.next_event(&mut rx).is_none());
    }

    #[tokio::test]
    async fn coalescing_preserves_cancel_and_separate_gestures() {
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        for (phase, sequence) in [
            (Phase::Update, 2),
            (Phase::Cancel, 3),
            (Phase::Begin, 1),
            (Phase::Update, 2),
        ] {
            tx.send(event(phase, sequence)).await.unwrap();
        }
        let mut state = DesktopReceiverState::default();
        for phase in [Phase::Update, Phase::Cancel, Phase::Begin, Phase::Update] {
            assert_eq!(state.next_event(&mut rx).unwrap().phase, phase);
        }
    }

    #[test]
    fn rejected_begin_drains_its_tail_then_allows_a_new_drag() {
        let mut state = DesktopReceiverState::default();
        let frames = VecDeque::from([frame(true)]);
        let begin = state
            .prepare(event(Phase::Begin, 1), Id128(1), Id128(2), 500, &frames)
            .unwrap();
        state
            .acknowledge(ack(begin, Outcome::Rejected), 499)
            .unwrap();
        assert!(!state.pending());
        assert!(state.discard_rejected_drag(event(Phase::Update, 2)));
        assert!(state.discard_rejected_drag(event(Phase::End, 3)));
        assert!(!state.active());
        let mut next = event(Phase::Begin, 1).with_ingress_ordinal(4).unwrap();
        next.drag_id += 1;
        state
            .prepare(next, Id128(1), Id128(2), 700, &frames)
            .unwrap();
    }

    #[test]
    fn source_rejection_of_update_or_end_does_not_retire_receiver() {
        for phase in [Phase::Update, Phase::End, Phase::Cancel] {
            let frames = VecDeque::from([frame(true)]);
            let mut state = DesktopReceiverState::default();
            let begin = state
                .prepare(event(Phase::Begin, 1), Id128(1), Id128(2), 500, &frames)
                .unwrap();
            state
                .acknowledge(ack(begin, Outcome::Applied), 499)
                .unwrap();
            let request = state
                .prepare(event(phase, 2), Id128(1), Id128(2), 700, &frames)
                .unwrap();
            state
                .acknowledge(ack(request, Outcome::Rejected), 699)
                .unwrap();
            assert!(!state.pending());
            if phase == Phase::Update {
                assert!(state.discard_rejected_drag(event(Phase::Update, 3)));
                assert!(state.discard_rejected_drag(event(Phase::End, 4)));
            }
            assert!(!state.active());
            assert!(!state.allows_native_ordinal(2));
            let mut next = event(Phase::Begin, 1).with_ingress_ordinal(5).unwrap();
            next.drag_id += 1;
            assert!(
                state
                    .prepare(next, Id128(1), Id128(2), 900, &frames)
                    .is_ok()
            );
        }
    }

    #[test]
    fn source_handoff_on_update_drains_tail_and_allows_next_drag() {
        let frames = VecDeque::from([frame(true)]);
        let mut state = DesktopReceiverState::default();
        let begin = state
            .prepare(event(Phase::Begin, 1), Id128(1), Id128(2), 500, &frames)
            .unwrap();
        state
            .acknowledge(ack(begin, Outcome::Applied), 499)
            .unwrap();
        let update = state
            .prepare(event(Phase::Update, 2), Id128(1), Id128(2), 700, &frames)
            .unwrap();
        // The source releases enrollment after transferring the window back
        // to its local desktop, even if the peer has not sent End yet.
        state.acknowledge(ack(update, Outcome::Ended), 699).unwrap();
        assert!(!state.pending());
        assert!(state.active());
        assert!(state.discard_rejected_drag(event(Phase::Update, 3)));
        assert!(state.discard_rejected_drag(event(Phase::End, 4)));
        assert!(!state.active());
        assert!(!state.allows_native_ordinal(4));
        assert!(state.allows_native_ordinal(5));
        let mut next = event(Phase::Begin, 1).with_ingress_ordinal(5).unwrap();
        next.drag_id += 1;
        state
            .prepare(next, Id128(1), Id128(2), 900, &frames)
            .unwrap();
    }

    #[tokio::test]
    async fn begin_waits_for_committed_notice_without_consuming_updates() {
        let (tx, mut rx) = tokio::sync::mpsc::channel(8);
        tx.send(event(Phase::Begin, 1)).await.unwrap();
        tx.send(event(Phase::Update, 2)).await.unwrap();
        let mut state = DesktopReceiverState::default();
        let begin = state.next_event(&mut rx).unwrap();
        assert!(
            state
                .prepare_when_committed(begin, Id128(1), Id128(2), 500, &VecDeque::new())
                .unwrap()
                .is_none()
        );
        assert!(!state.pending());
        assert!(state.active());
        let mut older = frame(true);
        older.frame_id = 99;
        let begin = state.next_event(&mut rx).unwrap();
        assert_eq!(begin.phase, Phase::Begin);
        assert!(
            state
                .prepare_when_committed(begin, Id128(1), Id128(2), 500, &VecDeque::from([older]))
                .unwrap()
                .is_none()
        );
        let begin = state.next_event(&mut rx).unwrap();
        let request = state
            .prepare_when_committed(
                begin,
                Id128(1),
                Id128(2),
                500,
                &VecDeque::from([frame(true)]),
            )
            .unwrap()
            .unwrap();
        assert_eq!(request.base_atlas_frame, 100);
        state
            .acknowledge(ack(request, Outcome::Applied), 499)
            .unwrap();
        assert_eq!(state.next_event(&mut rx).unwrap().phase, Phase::Update);
    }

    #[test]
    fn evicted_begin_rebases_same_window_and_keeps_drag_anchor() {
        let mut newest = frame(true);
        newest.frame_id = 132;
        newest.tiles[0].source_frame_id = 51;
        let frames = VecDeque::from([newest]);
        let mut state = DesktopReceiverState::default();
        let begin = state
            .prepare_when_committed(event(Phase::Begin, 1), Id128(1), Id128(2), 500, &frames)
            .unwrap()
            .unwrap();
        assert_eq!(begin.base_atlas_frame, 132);
        assert_eq!(begin.window_id, WINDOW);
        state
            .acknowledge(ack(begin, Outcome::Applied), 499)
            .unwrap();
        let end = state
            .prepare_when_committed(
                event(Phase::End, 2),
                Id128(1),
                Id128(2),
                700,
                &VecDeque::new(),
            )
            .unwrap()
            .unwrap();
        assert_eq!(end.base_atlas_frame, 132);
        state.acknowledge(ack(end, Outcome::Ended), 699).unwrap();
        assert!(!state.active());
    }

    #[test]
    fn unavailable_begin_is_local_and_next_drag_still_works() {
        for changed in 0..5 {
            let mut newest = frame(true);
            newest.frame_id = 132;
            match changed {
                0 => {
                    newest.tiles.clear();
                    newest.desktop.as_mut().unwrap().windows.clear();
                }
                1 => newest.config_generation += 1,
                2 => newest.desktop.as_mut().unwrap().topology_generation += 1,
                3 => newest.tiles[0].geometry_epoch += 1,
                _ => newest.desktop.as_mut().unwrap().windows[0].movable = false,
            }
            let mut state = DesktopReceiverState::default();
            assert!(
                state
                    .prepare_when_committed(
                        event(Phase::Begin, 1),
                        Id128(1),
                        Id128(2),
                        500,
                        &VecDeque::from([newest])
                    )
                    .unwrap()
                    .is_none()
            );
            assert!(!state.pending());
            assert!(state.discard_rejected_drag(event(Phase::Update, 2)));
            assert!(state.discard_rejected_drag(event(Phase::End, 3)));
            assert!(!state.active());
            let mut next = event(Phase::Begin, 1).with_ingress_ordinal(4).unwrap();
            next.drag_id += 1;
            assert!(
                state
                    .prepare_when_committed(
                        next,
                        Id128(1),
                        Id128(2),
                        700,
                        &VecDeque::from([frame(true)])
                    )
                    .unwrap()
                    .is_some()
            );
        }
    }

    #[test]
    fn begin_update_end_requires_exact_acknowledgements() {
        let mut state = DesktopReceiverState::default();
        let frames = VecDeque::from([frame(true)]);
        let begin = state
            .prepare(event(Phase::Begin, 1), Id128(1), Id128(2), 500, &frames)
            .unwrap();
        assert!(state.active() && state.pending());
        state
            .acknowledge(ack(begin, Outcome::Applied), 499)
            .unwrap();
        assert!(state.active() && !state.pending());

        let mut latest_update = event(Phase::Update, 2);
        latest_update.desired_bounds.width_millidip = 960_000;
        latest_update.desired_bounds.height_millidip = 1_080_000;
        latest_update.selection.atlas_frame_id += 100;
        latest_update.selection.source_geometry_epoch += 1;
        let update = state
            .prepare(latest_update, Id128(1), Id128(2), 600, &VecDeque::new())
            .unwrap();
        assert_eq!(update.desired_width_millidip, 960_000);
        assert_eq!(update.desired_height_millidip, 1_080_000);
        assert_eq!(update.base_atlas_frame, begin.base_atlas_frame);
        assert_eq!(update.base_geometry_epoch, begin.base_geometry_epoch);
        state
            .acknowledge(ack(update, Outcome::Applied), 599)
            .unwrap();
        assert!(state.active() && !state.pending());

        let end = state
            .prepare(
                event(Phase::End, 3),
                Id128(1),
                Id128(2),
                700,
                &VecDeque::new(),
            )
            .unwrap();
        state.acknowledge(ack(end, Outcome::Ended), 699).unwrap();
        assert!(!state.active() && !state.pending());
        assert!(!state.allows_native_ordinal(3));
        assert!(state.allows_native_ordinal(4));
    }

    #[test]
    fn pending_begin_rejects_stale_or_mismatched_ack_without_opening_another_gesture() {
        let mut state = DesktopReceiverState::default();
        let frames = VecDeque::from([frame(true)]);
        let begin = state
            .prepare(event(Phase::Begin, 1), Id128(1), Id128(2), 500, &frames)
            .unwrap();
        let mut wrong = ack(begin, Outcome::Applied);
        wrong.sequence += 1;
        assert!(state.acknowledge(wrong, 499).is_err());
        assert!(state.active() && state.pending());
        assert!(
            state
                .prepare(event(Phase::Begin, 1), Id128(1), Id128(2), 600, &frames)
                .is_err()
        );
        assert!(state.check_deadline(500).is_err());
    }

    #[test]
    fn begin_requires_the_exact_movable_desktop_frame() {
        let mut state = DesktopReceiverState::default();
        assert!(
            state
                .prepare(
                    event(Phase::Begin, 1),
                    Id128(1),
                    Id128(2),
                    500,
                    &VecDeque::from([frame(false)]),
                )
                .is_err()
        );
        assert!(
            state
                .prepare(
                    event(Phase::Begin, 1),
                    Id128(1),
                    Id128(2),
                    500,
                    &VecDeque::new()
                )
                .is_err()
        );
        assert!(!state.active() && !state.pending());
    }
}
