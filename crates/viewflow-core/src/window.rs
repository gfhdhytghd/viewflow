use viewflow_protocol::{DeviceId, GeometryEpoch, GeometryPhase, WindowDescriptor};

use crate::TopologyMap;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MigrationState {
    Local,
    EnteringVirtualCanvas { devices: Vec<DeviceId> },
    Virtualized { devices: Vec<DeviceId> },
    Fullscreen { target: DeviceId },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowError {
    StaleGeometryEpoch,
    GeometryUpdateWithoutBegin,
    GeometryEndWithoutBegin,
    InvalidGeometryPhase,
    FullscreenTargetNotVisible,
}

#[derive(Clone, Debug)]
pub struct WindowSession {
    pub descriptor: WindowDescriptor,
    pub migration: MigrationState,
    committed_epoch: u64,
    pending_epoch: Option<u64>,
}

impl WindowSession {
    #[must_use]
    pub fn new(descriptor: WindowDescriptor) -> Self {
        Self {
            descriptor,
            migration: MigrationState::Local,
            committed_epoch: 0,
            pending_epoch: None,
        }
    }

    #[must_use]
    pub fn committed_epoch(&self) -> u64 {
        self.committed_epoch
    }

    #[must_use]
    pub fn geometry_pending(&self) -> bool {
        self.pending_epoch.is_some()
    }

    pub fn update_migration(&mut self, topology: &TopologyMap) {
        if matches!(self.migration, MigrationState::Fullscreen { .. }) {
            return;
        }
        let devices = topology.devices_for(&self.descriptor);
        let crosses_device = devices
            .iter()
            .any(|device| *device != self.descriptor.source_device);
        self.migration = if crosses_device {
            MigrationState::Virtualized { devices }
        } else {
            MigrationState::Local
        };
    }

    /// Applies one RAIL-style geometry phase and returns true when committed.
    ///
    /// # Errors
    ///
    /// Rejects stale epochs and phase sequences that do not start with `Begin`
    /// and finish with a matching `End`.
    pub fn apply_geometry(&mut self, update: GeometryEpoch) -> Result<bool, WindowError> {
        if update.epoch <= self.committed_epoch {
            return Err(WindowError::StaleGeometryEpoch);
        }
        match update.phase {
            GeometryPhase::Begin => {
                if self.pending_epoch.is_some() {
                    return Err(WindowError::InvalidGeometryPhase);
                }
                self.pending_epoch = Some(update.epoch);
                self.descriptor.bounds_dip = update.bounds_dip;
                Ok(false)
            }
            GeometryPhase::Update => {
                if self.pending_epoch != Some(update.epoch) {
                    return Err(WindowError::GeometryUpdateWithoutBegin);
                }
                self.descriptor.bounds_dip = update.bounds_dip;
                Ok(false)
            }
            GeometryPhase::End => {
                if self.pending_epoch != Some(update.epoch) {
                    return Err(WindowError::GeometryEndWithoutBegin);
                }
                self.descriptor.bounds_dip = update.bounds_dip;
                self.pending_epoch = None;
                self.committed_epoch = update.epoch;
                Ok(true)
            }
        }
    }

    /// Makes the proxy exclusive to one currently intersecting device.
    ///
    /// # Errors
    ///
    /// Returns [`WindowError::FullscreenTargetNotVisible`] when the target does
    /// not currently contain a slice of this window.
    pub fn enter_fullscreen(
        &mut self,
        target: DeviceId,
        topology: &TopologyMap,
    ) -> Result<(), WindowError> {
        if !topology.devices_for(&self.descriptor).contains(&target) {
            return Err(WindowError::FullscreenTargetNotVisible);
        }
        self.migration = MigrationState::Fullscreen { target };
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{Id128, Point, Rect, Size, WindowDescriptor, WindowRole};

    fn descriptor() -> WindowDescriptor {
        WindowDescriptor {
            id: Id128(1),
            family_id: Id128(2),
            source_device: Id128(3),
            role: WindowRole::Main,
            bounds_dip: Rect {
                origin: Point::default(),
                size: Size {
                    width: 800.0,
                    height: 600.0,
                },
            },
            min_size_dip: Size::default(),
            max_size_dip: None,
            has_alpha: true,
            blur_radius_dip: None,
        }
    }

    fn geometry(epoch: u64, phase: GeometryPhase, width: f64) -> GeometryEpoch {
        GeometryEpoch {
            window_id: Id128(1),
            epoch,
            phase,
            bounds_dip: Rect {
                origin: Point::default(),
                size: Size {
                    width,
                    height: 600.0,
                },
            },
        }
    }

    #[test]
    fn commits_only_on_matching_geometry_end() {
        let mut session = WindowSession::new(descriptor());
        assert_eq!(
            session.apply_geometry(geometry(1, GeometryPhase::Begin, 900.0)),
            Ok(false)
        );
        assert_eq!(
            session.apply_geometry(geometry(1, GeometryPhase::Update, 1_000.0)),
            Ok(false)
        );
        assert_eq!(session.committed_epoch(), 0);
        assert_eq!(
            session.apply_geometry(geometry(1, GeometryPhase::End, 1_100.0)),
            Ok(true)
        );
        assert_eq!(session.committed_epoch(), 1);
    }

    #[test]
    fn rejects_out_of_order_geometry() {
        let mut session = WindowSession::new(descriptor());
        assert_eq!(
            session.apply_geometry(geometry(1, GeometryPhase::Update, 900.0)),
            Err(WindowError::GeometryUpdateWithoutBegin)
        );
    }
}
