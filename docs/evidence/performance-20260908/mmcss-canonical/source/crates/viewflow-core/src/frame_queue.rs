use std::collections::BTreeMap;

use viewflow_protocol::{FrameManifest, FramePlane, FramePlaneReady};

#[derive(Clone, Copy, Debug)]
pub struct FrameQueueConfig {
    pub refresh_millihz: u32,
    pub max_refresh_periods: u32,
    pub requires_alpha: bool,
}

impl FrameQueueConfig {
    #[must_use]
    pub fn deadline_ns(self) -> u64 {
        1_000_000_000_u64
            .saturating_mul(u64::from(self.max_refresh_periods))
            .saturating_mul(1_000)
            / u64::from(self.refresh_millihz.max(1))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FrameRejectReason {
    Late,
    StaleFrame,
    StaleGeometry,
    FutureGeometry,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FrameAdmission {
    Waiting,
    Ready(FrameManifest),
    Rejected(FrameRejectReason),
}

#[derive(Clone, Copy, Debug, Default)]
struct PendingFrame {
    color: Option<FramePlaneReady>,
    alpha: Option<FramePlaneReady>,
}

#[derive(Debug)]
pub struct FrameQueue {
    config: FrameQueueConfig,
    geometry_epoch: u64,
    last_presented_frame: Option<u64>,
    pending: BTreeMap<u64, PendingFrame>,
}

impl FrameQueue {
    #[must_use]
    pub fn new(config: FrameQueueConfig) -> Self {
        Self {
            config,
            geometry_epoch: 0,
            last_presented_frame: None,
            pending: BTreeMap::new(),
        }
    }

    pub fn set_geometry_epoch(&mut self, epoch: u64) {
        if epoch > self.geometry_epoch {
            self.geometry_epoch = epoch;
            self.pending.retain(|_, frame| {
                frame
                    .color
                    .or(frame.alpha)
                    .is_some_and(|plane| plane.geometry_epoch >= epoch)
            });
        }
    }

    pub fn push(&mut self, plane: FramePlaneReady) -> FrameAdmission {
        if plane.geometry_epoch < self.geometry_epoch {
            return FrameAdmission::Rejected(FrameRejectReason::StaleGeometry);
        }
        if plane.geometry_epoch > self.geometry_epoch {
            return FrameAdmission::Rejected(FrameRejectReason::FutureGeometry);
        }
        if self
            .last_presented_frame
            .is_some_and(|last| plane.frame_id <= last)
        {
            return FrameAdmission::Rejected(FrameRejectReason::StaleFrame);
        }
        if plane.received_ns.saturating_sub(plane.source_submitted_ns) > self.config.deadline_ns() {
            return FrameAdmission::Rejected(FrameRejectReason::Late);
        }

        // Latest-frame semantics: an incomplete older frame must never create a queue.
        self.pending
            .retain(|frame_id, _| *frame_id >= plane.frame_id);
        let pending = self.pending.entry(plane.frame_id).or_default();
        match plane.plane {
            FramePlane::Color => pending.color = Some(plane),
            FramePlane::Alpha => pending.alpha = Some(plane),
        }
        let ready =
            pending.color.is_some() && (!self.config.requires_alpha || pending.alpha.is_some());
        if !ready {
            return FrameAdmission::Waiting;
        }

        let Some(color) = pending.color else {
            return FrameAdmission::Waiting;
        };
        let received_ns = pending.alpha.map_or(color.received_ns, |alpha| {
            alpha.received_ns.max(color.received_ns)
        });
        if received_ns.saturating_sub(color.source_submitted_ns) > self.config.deadline_ns() {
            self.pending.remove(&plane.frame_id);
            return FrameAdmission::Rejected(FrameRejectReason::Late);
        }
        self.pending.clear();
        self.last_presented_frame = Some(plane.frame_id);
        FrameAdmission::Ready(FrameManifest {
            window_id: plane.window_id,
            frame_id: plane.frame_id,
            geometry_epoch: plane.geometry_epoch,
            source_submitted_ns: color.source_submitted_ns,
            received_ns,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::Id128;

    fn plane(frame_id: u64, kind: FramePlane, received_ns: u64) -> FramePlaneReady {
        FramePlaneReady {
            window_id: Id128(1),
            frame_id,
            geometry_epoch: 2,
            plane: kind,
            source_submitted_ns: 1_000_000,
            received_ns,
        }
    }

    #[test]
    fn color_and_alpha_are_admitted_atomically() {
        let mut queue = FrameQueue::new(FrameQueueConfig {
            refresh_millihz: 60_000,
            max_refresh_periods: 2,
            requires_alpha: true,
        });
        queue.set_geometry_epoch(2);
        assert_eq!(
            queue.push(plane(7, FramePlane::Color, 10_000_000)),
            FrameAdmission::Waiting
        );
        assert!(
            matches!(queue.push(plane(7, FramePlane::Alpha, 11_000_000)), FrameAdmission::Ready(frame) if frame.frame_id == 7)
        );
    }

    #[test]
    fn drops_late_and_incomplete_old_frames() {
        let mut queue = FrameQueue::new(FrameQueueConfig {
            refresh_millihz: 60_000,
            max_refresh_periods: 2,
            requires_alpha: true,
        });
        queue.set_geometry_epoch(2);
        assert_eq!(
            queue.push(plane(1, FramePlane::Color, 2_000_000)),
            FrameAdmission::Waiting
        );
        assert_eq!(
            queue.push(plane(2, FramePlane::Color, 3_000_000)),
            FrameAdmission::Waiting
        );
        assert_eq!(
            queue.push(plane(1, FramePlane::Alpha, 4_000_000)),
            FrameAdmission::Waiting
        );
        assert_eq!(
            queue.push(plane(3, FramePlane::Color, 40_000_000)),
            FrameAdmission::Rejected(FrameRejectReason::Late)
        );
    }

    #[test]
    fn rejects_future_geometry_until_commit() {
        let mut queue = FrameQueue::new(FrameQueueConfig {
            refresh_millihz: 60_000,
            max_refresh_periods: 2,
            requires_alpha: false,
        });
        queue.set_geometry_epoch(1);

        assert_eq!(
            queue.push(plane(1, FramePlane::Color, 2_000_000)),
            FrameAdmission::Rejected(FrameRejectReason::FutureGeometry)
        );

        queue.set_geometry_epoch(2);
        assert!(matches!(
            queue.push(plane(1, FramePlane::Color, 2_000_000)),
            FrameAdmission::Ready(frame) if frame.geometry_epoch == 2
        ));
    }
}
