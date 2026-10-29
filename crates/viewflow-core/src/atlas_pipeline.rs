//! Experimental, allocation-free metadata window for a future atlas pipeline.
//!
//! This does not admit media, retain alpha bytes, decode, present, send feedback,
//! or authorize input. Transport must remain stop-and-wait until those owners
//! implement the same window and validate the actual codec/patch dependencies.
//! The capacity of three is an experiment bound, not a measured wire contract.
use viewflow_protocol::Id128;

pub const MAX_PIPELINE_FRAMES: usize = 3;

/// One lane and one codec/geometry lineage. A recovery fence changes `serial`
/// even if wire generations do not change, so old callbacks cannot alias.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PipelineLineage {
    pub stream: Id128,
    pub geometry_epoch: u64,
    pub config_generation: u64,
    pub lane: u8,
    pub dual_lane: bool,
    pub serial: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PipelineToken {
    pub lineage: PipelineLineage,
    pub frame: u64,
}

/// Explicit dependencies, never inferred from transport arrival order.
/// Color dependencies name the preceding submitted lane frame. A patch
/// dependency does so only when an owner truly applies a temporal canvas delta;
/// existing spatial `AtlasPatch` lists alone do not imply a temporal dependency.
/// `None` means independent color / canvas / alpha content.
/// Alpha references name a full-alpha baseline. The payload owner must pin its
/// bytes until all dependents retire, even after a newer full alpha commits.
/// References do not replace the baseline for subsequent enqueue.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PipelineDependencies {
    pub color: Option<u64>,
    pub alpha: Option<u64>,
    pub patch: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PipelineOutcome {
    Committed,
    Lost,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PipelineError {
    InvalidLineage,
    InvalidCapacity,
    Full,
    Identity,
    Replay,
    Dependency,
    UnknownCompletion,
    DuplicateCompletion,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Status {
    Pending,
    Ready,
    Lost,
}

#[derive(Clone, Copy, Debug)]
struct Entry {
    token: PipelineToken,
    dependencies: PipelineDependencies,
    status: Status,
}

/// Metadata-only in-order retirement. Owners keep encoded bytes, decoded
/// surfaces and exact native receipts separately. `Ready` must mean the owner
/// can commit this frame, not merely that its media arrived. A caller must not
/// send a Committed disposition before `pop` returns Committed.
pub struct PipelineWindow {
    lineage: PipelineLineage,
    capacity: usize,
    entries: [Option<Entry>; MAX_PIPELINE_FRAMES],
    len: usize,
    last_submitted: Option<u64>,
    color_baseline: Option<u64>,
    alpha_baseline: Option<u64>,
    patch_baseline: Option<u64>,
}

impl PipelineWindow {
    /// Construct an empty bounded window without allocating payload storage.
    /// # Errors
    /// Rejects invalid identities, lane routing and capacities outside 1..=3.
    pub fn new(lineage: PipelineLineage, capacity: usize) -> Result<Self, PipelineError> {
        if lineage.stream.0 == 0
            || lineage.geometry_epoch == 0
            || lineage.config_generation == 0
            || lineage.serial == 0
            || lineage.lane > 1
            || (!lineage.dual_lane && lineage.lane != 0)
        {
            return Err(PipelineError::InvalidLineage);
        }
        if !(1..=MAX_PIPELINE_FRAMES).contains(&capacity) {
            return Err(PipelineError::InvalidCapacity);
        }
        Ok(Self {
            lineage,
            capacity,
            entries: [None; MAX_PIPELINE_FRAMES],
            len: 0,
            last_submitted: None,
            color_baseline: None,
            alpha_baseline: None,
            patch_baseline: None,
        })
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.len
    }
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    fn available(&self, frame: u64, baseline: Option<u64>, alpha: bool) -> bool {
        baseline == Some(frame)
            || self.entries.iter().flatten().any(|entry| {
                entry.token.frame == frame
                    && entry.status != Status::Lost
                    && (!alpha || entry.dependencies.alpha.is_none())
            })
    }

    /// Admit ordered metadata only. Arrival/completion may subsequently reorder.
    /// A rejected enqueue leaves every slot and baseline unchanged.
    /// # Errors
    /// Rejects wrong identities, replay, a full window and unavailable references.
    pub fn enqueue(
        &mut self,
        token: PipelineToken,
        dependencies: PipelineDependencies,
    ) -> Result<(), PipelineError> {
        if token.lineage != self.lineage
            || token.frame == 0
            || (self.lineage.dual_lane && token.frame % 2 != u64::from(self.lineage.lane))
        {
            return Err(PipelineError::Identity);
        }
        if self.last_submitted.is_some_and(|last| token.frame <= last) {
            return Err(PipelineError::Replay);
        }
        if self.len == self.capacity {
            return Err(PipelineError::Full);
        }
        for (dependency, baseline, alpha) in [
            (dependencies.color, self.color_baseline, false),
            (dependencies.alpha, self.alpha_baseline, true),
            (dependencies.patch, self.patch_baseline, false),
        ] {
            if let Some(frame) = dependency {
                if frame >= token.frame
                    || (!alpha && Some(frame) != self.last_submitted)
                    || !self.available(frame, baseline, alpha)
                {
                    return Err(PipelineError::Dependency);
                }
            }
        }
        self.entries[self.len] = Some(Entry {
            token,
            dependencies,
            status: Status::Pending,
        });
        self.len += 1;
        self.last_submitted = Some(token.frame);
        Ok(())
    }

    /// Record an exact completion. Loss invalidates all transitive dependents,
    /// including already-ready successors, but preserves independent snapshots.
    /// No outcome here implies connection or unrelated lane failure.
    /// # Errors
    /// Rejects unknown, stale, duplicate or already-invalidated completions.
    pub fn complete(
        &mut self,
        token: PipelineToken,
        outcome: PipelineOutcome,
    ) -> Result<(), PipelineError> {
        let entry = self
            .entries
            .iter_mut()
            .flatten()
            .find(|entry| entry.token == token)
            .ok_or(PipelineError::UnknownCompletion)?;
        if entry.status != Status::Pending {
            return Err(PipelineError::DuplicateCompletion);
        }
        entry.status = match outcome {
            PipelineOutcome::Committed => Status::Ready,
            PipelineOutcome::Lost => Status::Lost,
        };
        // Dependencies are strictly backward, so one forward pass is enough.
        for index in 0..self.len {
            let Some(current) = self.entries[index] else {
                continue;
            };
            let depends_on_loss = self.entries[..index].iter().flatten().any(|prior| {
                prior.status == Status::Lost
                    && [
                        current.dependencies.color,
                        current.dependencies.alpha,
                        current.dependencies.patch,
                    ]
                    .contains(&Some(prior.token.frame))
            });
            if depends_on_loss {
                if let Some(entry) = &mut self.entries[index] {
                    entry.status = Status::Lost;
                }
            }
        }
        Ok(())
    }

    /// Retire only the oldest completed slot. Loss feedback also stays ordered.
    /// Full alpha installs a baseline only here; enqueue/Ready never install it.
    pub fn pop(&mut self) -> Option<(PipelineToken, PipelineOutcome)> {
        let entry = self.entries[0]?;
        if entry.status == Status::Pending {
            return None;
        }
        let outcome = if entry.status == Status::Ready {
            self.color_baseline = Some(entry.token.frame);
            self.patch_baseline = Some(entry.token.frame);
            if entry.dependencies.alpha.is_none() {
                self.alpha_baseline = Some(entry.token.frame);
            }
            PipelineOutcome::Committed
        } else {
            PipelineOutcome::Lost
        };
        self.entries.rotate_left(1);
        self.entries[MAX_PIPELINE_FRAMES - 1] = None;
        self.len -= 1;
        Some((entry.token, outcome))
    }

    /// Drain metadata for every exact outstanding disposition before a reset.
    /// The owner must release associated payloads/surfaces and report or cancel
    /// these tokens. The new serial must increase even across geometry changes.
    /// A failed reset leaves the old window intact.
    /// # Errors
    /// Rejects an invalid lineage or a serial that does not increase.
    pub fn reset(
        &mut self,
        lineage: PipelineLineage,
    ) -> Result<[Option<PipelineToken>; MAX_PIPELINE_FRAMES], PipelineError> {
        if lineage.serial <= self.lineage.serial {
            return Err(PipelineError::InvalidLineage);
        }
        let next = Self::new(lineage, self.capacity)?;
        let drained = self.entries.map(|entry| entry.map(|entry| entry.token));
        *self = next;
        Ok(drained)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn lineage() -> PipelineLineage {
        PipelineLineage {
            stream: Id128(99),
            geometry_epoch: 1,
            config_generation: 1,
            lane: 0,
            dual_lane: false,
            serial: 1,
        }
    }
    fn token(frame: u64) -> PipelineToken {
        PipelineToken {
            lineage: lineage(),
            frame,
        }
    }
    fn chain(frame: u64) -> PipelineDependencies {
        PipelineDependencies {
            color: Some(frame),
            alpha: Some(1),
            patch: Some(frame),
        }
    }
    fn window() -> PipelineWindow {
        PipelineWindow::new(lineage(), 3).unwrap()
    }

    #[test]
    fn bounded_window_retires_reordered_completions_in_order() {
        for capacity in 1..=3 {
            let mut window = PipelineWindow::new(lineage(), capacity).unwrap();
            for id in 1..=capacity as u64 {
                window
                    .enqueue(token(id), PipelineDependencies::default())
                    .unwrap();
            }
            assert_eq!(
                window.enqueue(token(4), PipelineDependencies::default()),
                Err(PipelineError::Full)
            );
            for id in (2..=capacity as u64).rev() {
                window
                    .complete(token(id), PipelineOutcome::Committed)
                    .unwrap();
                assert_eq!(window.pop(), None);
            }
            window
                .complete(token(1), PipelineOutcome::Committed)
                .unwrap();
            for id in 1..=capacity as u64 {
                assert_eq!(window.pop(), Some((token(id), PipelineOutcome::Committed)));
            }
            assert!(window.is_empty());
            assert_eq!(
                window.enqueue(token(1), PipelineDependencies::default()),
                Err(PipelineError::Replay)
            );
        }
        assert!(matches!(
            PipelineWindow::new(lineage(), 0),
            Err(PipelineError::InvalidCapacity)
        ));
        assert!(matches!(
            PipelineWindow::new(lineage(), 4),
            Err(PipelineError::InvalidCapacity)
        ));
    }

    #[test]
    fn middle_loss_invalidates_ready_pictures_and_recovers_at_independent_snapshot() {
        let mut w = window();
        w.enqueue(token(1), PipelineDependencies::default())
            .unwrap();
        w.enqueue(token(2), chain(1)).unwrap();
        w.enqueue(token(3), chain(2)).unwrap();
        w.complete(token(3), PipelineOutcome::Committed).unwrap();
        w.complete(token(2), PipelineOutcome::Lost).unwrap();
        assert_eq!(w.pop(), None);
        w.complete(token(1), PipelineOutcome::Committed).unwrap();
        assert_eq!(w.pop(), Some((token(1), PipelineOutcome::Committed)));
        assert_eq!(w.pop(), Some((token(2), PipelineOutcome::Lost)));
        assert_eq!(w.pop(), Some((token(3), PipelineOutcome::Lost)));
        assert_eq!(
            w.enqueue(token(4), chain(3)),
            Err(PipelineError::Dependency)
        );
        w.enqueue(token(4), PipelineDependencies::default())
            .unwrap();
        w.complete(token(4), PipelineOutcome::Committed).unwrap();
        assert_eq!(w.pop(), Some((token(4), PipelineOutcome::Committed)));
        w.enqueue(
            token(5),
            PipelineDependencies {
                alpha: Some(4),
                ..chain(4)
            },
        )
        .unwrap();
    }

    #[test]
    fn color_alpha_and_patch_each_propagate_transitive_loss() {
        for plane in 0..3 {
            let mut w = window();
            w.enqueue(token(1), PipelineDependencies::default())
                .unwrap();
            let mut dependencies = PipelineDependencies::default();
            match plane {
                0 => dependencies.color = Some(1),
                1 => dependencies.alpha = Some(1),
                _ => dependencies.patch = Some(1),
            }
            w.enqueue(token(2), dependencies).unwrap();
            w.enqueue(
                token(3),
                PipelineDependencies {
                    color: Some(2),
                    ..Default::default()
                },
            )
            .unwrap();
            w.complete(token(1), PipelineOutcome::Lost).unwrap();
            for id in 1..=3 {
                assert_eq!(w.pop(), Some((token(id), PipelineOutcome::Lost)));
            }
        }
    }

    #[test]
    fn independent_keyframe_survives_loss_but_patch_or_alpha_reference_does_not() {
        let mut w = window();
        w.enqueue(token(1), PipelineDependencies::default())
            .unwrap();
        w.enqueue(token(2), PipelineDependencies::default())
            .unwrap();
        w.enqueue(
            token(3),
            PipelineDependencies {
                color: Some(2),
                alpha: Some(2),
                patch: Some(2),
            },
        )
        .unwrap();
        w.complete(token(3), PipelineOutcome::Committed).unwrap();
        w.complete(token(2), PipelineOutcome::Committed).unwrap();
        w.complete(token(1), PipelineOutcome::Lost).unwrap();
        assert_eq!(w.pop(), Some((token(1), PipelineOutcome::Lost)));
        assert_eq!(w.pop(), Some((token(2), PipelineOutcome::Committed)));
        assert_eq!(w.pop(), Some((token(3), PipelineOutcome::Committed)));
    }

    #[test]
    fn alpha_references_pin_full_baseline_and_cannot_reference_a_reference() {
        let mut w = window();
        w.enqueue(token(1), PipelineDependencies::default())
            .unwrap();
        w.complete(token(1), PipelineOutcome::Committed).unwrap();
        w.pop().unwrap();
        w.enqueue(token(2), chain(1)).unwrap();
        assert_eq!(
            w.enqueue(
                token(3),
                PipelineDependencies {
                    alpha: Some(2),
                    ..chain(2)
                }
            ),
            Err(PipelineError::Dependency)
        );
        w.enqueue(token(3), chain(2)).unwrap();
        w.complete(token(2), PipelineOutcome::Committed).unwrap();
        w.pop().unwrap();
        w.complete(token(3), PipelineOutcome::Committed).unwrap();
        w.pop().unwrap();
        w.enqueue(token(4), chain(3)).unwrap();
    }

    #[test]
    fn reset_drains_in_flight_and_rejects_stale_generation_epoch_and_fence_callbacks() {
        for change in 0..3 {
            let mut w = window();
            w.enqueue(token(1), PipelineDependencies::default())
                .unwrap();
            w.enqueue(token(2), chain(1)).unwrap();
            w.complete(token(2), PipelineOutcome::Committed).unwrap();
            let mut next = lineage();
            next.serial = 2;
            match change {
                0 => next.config_generation += 1,
                1 => next.geometry_epoch += 1,
                _ => {}
            }
            assert_eq!(
                w.reset(next).unwrap(),
                [Some(token(1)), Some(token(2)), None]
            );
            assert!(w.is_empty());
            assert_eq!(
                w.complete(token(2), PipelineOutcome::Committed),
                Err(PipelineError::UnknownCompletion)
            );
            assert_eq!(
                w.enqueue(token(3), PipelineDependencies::default()),
                Err(PipelineError::Identity)
            );
            let current = PipelineToken {
                lineage: next,
                frame: 1,
            };
            assert_eq!(w.enqueue(current, chain(1)), Err(PipelineError::Dependency));
            w.enqueue(current, PipelineDependencies::default()).unwrap();
            assert_eq!(w.reset(next), Err(PipelineError::InvalidLineage));
            assert_eq!(w.len(), 1);
        }
    }

    #[test]
    fn dual_lanes_have_independent_bounds_loss_and_exact_feedback() {
        let even = PipelineLineage {
            dual_lane: true,
            ..lineage()
        };
        let odd = PipelineLineage { lane: 1, ..even };
        let mut a = PipelineWindow::new(even, 2).unwrap();
        let mut b = PipelineWindow::new(odd, 2).unwrap();
        let tag = |lineage, frame| PipelineToken { lineage, frame };
        for (w, lane, first) in [(&mut a, even, 2), (&mut b, odd, 1)] {
            w.enqueue(tag(lane, first), PipelineDependencies::default())
                .unwrap();
            w.enqueue(
                tag(lane, first + 2),
                PipelineDependencies {
                    color: Some(first),
                    ..Default::default()
                },
            )
            .unwrap();
            assert_eq!(
                w.enqueue(tag(lane, first + 4), PipelineDependencies::default()),
                Err(PipelineError::Full)
            );
        }
        assert_eq!(
            a.complete(tag(odd, 1), PipelineOutcome::Lost),
            Err(PipelineError::UnknownCompletion)
        );
        a.complete(tag(even, 2), PipelineOutcome::Lost).unwrap();
        b.complete(tag(odd, 3), PipelineOutcome::Committed).unwrap();
        assert_eq!(b.pop(), None);
        b.complete(tag(odd, 1), PipelineOutcome::Committed).unwrap();
        for id in [1, 3] {
            assert_eq!(b.pop(), Some((tag(odd, id), PipelineOutcome::Committed)));
        }
        for id in [2, 4] {
            assert_eq!(a.pop(), Some((tag(even, id), PipelineOutcome::Lost)));
        }
        assert_eq!(
            a.enqueue(tag(even, 5), PipelineDependencies::default()),
            Err(PipelineError::Identity)
        );
    }

    #[test]
    fn invalid_dependencies_and_completions_do_not_mutate_the_window() {
        let mut w = window();
        w.enqueue(token(1), PipelineDependencies::default())
            .unwrap();
        assert_eq!(
            w.enqueue(
                token(2),
                PipelineDependencies {
                    color: Some(2),
                    ..Default::default()
                }
            ),
            Err(PipelineError::Dependency)
        );
        assert_eq!(
            w.complete(token(2), PipelineOutcome::Lost),
            Err(PipelineError::UnknownCompletion)
        );
        assert_eq!(w.len(), 1);
        w.complete(token(1), PipelineOutcome::Committed).unwrap();
        assert_eq!(
            w.complete(token(1), PipelineOutcome::Lost),
            Err(PipelineError::DuplicateCompletion)
        );
        assert_eq!(w.pop(), Some((token(1), PipelineOutcome::Committed)));
    }
}
