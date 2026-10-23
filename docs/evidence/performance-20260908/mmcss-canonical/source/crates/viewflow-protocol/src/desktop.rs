//! Immutable logical desktop placement and frame-bound window drag controls.

use crate::{DeviceId, Id128, WindowId, WireError, required_id, wire};

pub const MAX_DESKTOP_COORDINATE_MILLIDIP: i64 = 1_000_000_000;
pub const MAX_DESKTOP_EXTENT_MILLIDIP: i64 = 32_768_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DesktopRect {
    pub x_millidip: i64,
    pub y_millidip: i64,
    pub width_millidip: u64,
    pub height_millidip: u64,
}

impl DesktopRect {
    /// # Errors
    ///
    /// Rejects empty, oversized, overflowing, or out-of-range logical bounds.
    pub fn validate(self) -> Result<(), WireError> {
        let valid_axis = |origin: i64, extent: u64| {
            let extent = i64::try_from(extent).ok();
            origin.unsigned_abs() <= MAX_DESKTOP_COORDINATE_MILLIDIP as u64
                && extent.is_some_and(|extent| {
                    extent > 0
                        && extent <= MAX_DESKTOP_EXTENT_MILLIDIP
                        && origin.checked_add(extent).is_some_and(|end| {
                            end.unsigned_abs() <= MAX_DESKTOP_COORDINATE_MILLIDIP as u64
                        })
                })
        };
        if valid_axis(self.x_millidip, self.width_millidip)
            && valid_axis(self.y_millidip, self.height_millidip)
        {
            Ok(())
        } else {
            Err(WireError::InvalidField("desktop_rect"))
        }
    }

    #[must_use]
    pub fn contains(self, other: Self) -> bool {
        let right = self
            .x_millidip
            .checked_add(i64::try_from(self.width_millidip).unwrap_or(i64::MAX));
        let bottom = self
            .y_millidip
            .checked_add(i64::try_from(self.height_millidip).unwrap_or(i64::MAX));
        let other_right = other
            .x_millidip
            .checked_add(i64::try_from(other.width_millidip).unwrap_or(i64::MAX));
        let other_bottom = other
            .y_millidip
            .checked_add(i64::try_from(other.height_millidip).unwrap_or(i64::MAX));
        right.is_some_and(|right| {
            bottom.is_some_and(|bottom| {
                other_right.is_some_and(|other_right| {
                    other_bottom.is_some_and(|other_bottom| {
                        self.x_millidip <= other.x_millidip
                            && self.y_millidip <= other.y_millidip
                            && other_right <= right
                            && other_bottom <= bottom
                    })
                })
            })
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AtlasWindowPlacement {
    pub window_id: WindowId,
    pub bounds: DesktopRect,
    pub movable: bool,
    pub z_order: u32,
    pub raise_serial: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AtlasDesktopLayout {
    pub topology_generation: u64,
    pub viewport: DesktopRect,
    /// Canonical ascending window-ID order and exact one-to-one atlas-tile map.
    pub windows: Vec<AtlasWindowPlacement>,
}

impl AtlasDesktopLayout {
    /// # Errors
    ///
    /// Rejects invalid topology/bounds or noncanonical, duplicate placements.
    pub fn validate(&self) -> Result<(), WireError> {
        if self.topology_generation == 0 || self.windows.len() > 4096 {
            return Err(WireError::InvalidField("atlas_desktop_layout"));
        }
        self.viewport.validate()?;
        let mut previous = None;
        for placement in &self.windows {
            if placement.window_id.0 == 0
                || previous.is_some_and(|id| id >= placement.window_id)
                || placement.bounds.validate().is_err()
            {
                return Err(WireError::InvalidField("atlas_desktop_layout.windows"));
            }
            previous = Some(placement.window_id);
        }
        Ok(())
    }

    /// # Errors
    ///
    /// Rejects any missing, additional, reordered, or mismatched tile window.
    pub fn validate_tiles(&self, tiles: &[crate::AtlasTile]) -> Result<(), WireError> {
        self.validate()?;
        if self.windows.len() != tiles.len()
            || self
                .windows
                .iter()
                .zip(tiles)
                .any(|(placement, tile)| placement.window_id != tile.window_id)
        {
            return Err(WireError::InvalidField(
                "atlas_desktop_layout.tile_membership",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DesktopWindowMovePhase {
    Begin,
    Update,
    End,
    Cancel,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DesktopWindowMove {
    pub source_device: DeviceId,
    pub owner_device: DeviceId,
    pub stream_id: Id128,
    pub config_generation: u64,
    pub topology_generation: u64,
    pub window_id: WindowId,
    pub drag_id: Id128,
    pub sequence: u64,
    pub phase: DesktopWindowMovePhase,
    pub base_atlas_frame: u64,
    pub base_geometry_epoch: u64,
    pub sender_not_after_ns: u64,
    pub desired_x_millidip: i64,
    pub desired_y_millidip: i64,
    /// Both zero retains the current size (older peers).
    pub desired_width_millidip: u64,
    pub desired_height_millidip: u64,
}

impl DesktopWindowMove {
    /// # Errors
    ///
    /// Rejects incomplete identity, stale-base fields, zero sequencing, or
    /// desired origins outside the bounded logical desktop coordinate range.
    pub fn validate(self) -> Result<(), WireError> {
        if self.source_device.0 == 0
            || self.owner_device.0 == 0
            || self.stream_id.0 == 0
            || self.window_id.0 == 0
            || self.drag_id.0 == 0
            || self.stream_id == self.window_id
            || self.config_generation == 0
            || self.topology_generation == 0
            || self.sequence == 0
            || self.base_atlas_frame == 0
            || self.base_geometry_epoch == 0
            || self.sender_not_after_ns == 0
            || self.desired_x_millidip.unsigned_abs() > MAX_DESKTOP_COORDINATE_MILLIDIP as u64
            || (self.desired_width_millidip == 0) != (self.desired_height_millidip == 0)
            || self.desired_width_millidip > MAX_DESKTOP_COORDINATE_MILLIDIP as u64
            || self.desired_height_millidip > MAX_DESKTOP_COORDINATE_MILLIDIP as u64
            || self.desired_y_millidip.unsigned_abs() > MAX_DESKTOP_COORDINATE_MILLIDIP as u64
        {
            return Err(WireError::InvalidField("desktop_window_move"));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DesktopWindowMoveResult {
    Applied,
    Rejected,
    Ended,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DesktopWindowMoveAck {
    pub source_device: DeviceId,
    pub owner_device: DeviceId,
    pub stream_id: Id128,
    pub config_generation: u64,
    pub topology_generation: u64,
    pub window_id: WindowId,
    pub drag_id: Id128,
    pub sequence: u64,
    pub result: DesktopWindowMoveResult,
    pub actual_bounds: DesktopRect,
}

impl DesktopWindowMoveAck {
    /// # Errors
    ///
    /// Rejects incomplete identity, zero sequence, or invalid actual bounds.
    pub fn validate(self) -> Result<(), WireError> {
        DesktopWindowMove {
            source_device: self.source_device,
            owner_device: self.owner_device,
            stream_id: self.stream_id,
            config_generation: self.config_generation,
            topology_generation: self.topology_generation,
            window_id: self.window_id,
            drag_id: self.drag_id,
            sequence: self.sequence,
            phase: DesktopWindowMovePhase::Update,
            base_atlas_frame: 1,
            base_geometry_epoch: 1,
            sender_not_after_ns: 1,
            desired_x_millidip: self.actual_bounds.x_millidip,
            desired_y_millidip: self.actual_bounds.y_millidip,
            desired_width_millidip: self.actual_bounds.width_millidip,
            desired_height_millidip: self.actual_bounds.height_millidip,
        }
        .validate()?;
        self.actual_bounds.validate()
    }
}

fn id(value: Id128) -> wire::Id128 {
    wire::Id128 {
        high: u64::try_from(value.0 >> 64).expect("upper Id128 half always fits in u64"),
        low: u64::try_from(value.0 & u128::from(u64::MAX))
            .expect("lower Id128 half always fits in u64"),
    }
}

impl TryFrom<wire::DesktopRect> for DesktopRect {
    type Error = WireError;
    fn try_from(value: wire::DesktopRect) -> Result<Self, Self::Error> {
        let value = Self {
            x_millidip: value.x_millidip,
            y_millidip: value.y_millidip,
            width_millidip: value.width_millidip,
            height_millidip: value.height_millidip,
        };
        value.validate()?;
        Ok(value)
    }
}

impl From<DesktopRect> for wire::DesktopRect {
    fn from(value: DesktopRect) -> Self {
        Self {
            x_millidip: value.x_millidip,
            y_millidip: value.y_millidip,
            width_millidip: value.width_millidip,
            height_millidip: value.height_millidip,
        }
    }
}

impl TryFrom<wire::AtlasDesktopLayout> for AtlasDesktopLayout {
    type Error = WireError;
    fn try_from(value: wire::AtlasDesktopLayout) -> Result<Self, Self::Error> {
        let layout = Self {
            topology_generation: value.topology_generation,
            viewport: value
                .viewport
                .ok_or(WireError::MissingField("atlas_desktop.viewport"))?
                .try_into()?,
            windows: value
                .windows
                .into_iter()
                .map(|placement| {
                    Ok(AtlasWindowPlacement {
                        window_id: required_id(placement.window_id, "atlas_desktop.window_id")?,
                        bounds: placement
                            .bounds
                            .ok_or(WireError::MissingField("atlas_desktop.bounds"))?
                            .try_into()?,
                        movable: placement.movable,
                        z_order: placement.z_order,
                        raise_serial: placement.raise_serial,
                    })
                })
                .collect::<Result<_, WireError>>()?,
        };
        layout.validate()?;
        Ok(layout)
    }
}

impl From<AtlasDesktopLayout> for wire::AtlasDesktopLayout {
    fn from(value: AtlasDesktopLayout) -> Self {
        Self {
            topology_generation: value.topology_generation,
            viewport: Some(value.viewport.into()),
            windows: value
                .windows
                .into_iter()
                .map(|placement| wire::AtlasWindowPlacement {
                    window_id: Some(id(placement.window_id)),
                    bounds: Some(placement.bounds.into()),
                    movable: placement.movable,
                    z_order: placement.z_order,
                    raise_serial: placement.raise_serial,
                })
                .collect(),
        }
    }
}

impl TryFrom<wire::DesktopWindowMove> for DesktopWindowMove {
    type Error = WireError;
    fn try_from(value: wire::DesktopWindowMove) -> Result<Self, Self::Error> {
        let phase = match wire::DesktopWindowMovePhase::try_from(value.phase)
            .map_err(|_| WireError::UnknownEnum("desktop_window_move.phase"))?
        {
            wire::DesktopWindowMovePhase::Begin => DesktopWindowMovePhase::Begin,
            wire::DesktopWindowMovePhase::Update => DesktopWindowMovePhase::Update,
            wire::DesktopWindowMovePhase::End => DesktopWindowMovePhase::End,
            wire::DesktopWindowMovePhase::Cancel => DesktopWindowMovePhase::Cancel,
            wire::DesktopWindowMovePhase::Unspecified => {
                return Err(WireError::UnknownEnum("desktop_window_move.phase"));
            }
        };
        let value = Self {
            source_device: required_id(value.source_device, "desktop_window_move.source_device")?,
            owner_device: required_id(value.owner_device, "desktop_window_move.owner_device")?,
            stream_id: required_id(value.stream_id, "desktop_window_move.stream_id")?,
            config_generation: value.config_generation,
            topology_generation: value.topology_generation,
            window_id: required_id(value.window_id, "desktop_window_move.window_id")?,
            drag_id: required_id(value.drag_id, "desktop_window_move.drag_id")?,
            sequence: value.sequence,
            phase,
            base_atlas_frame: value.base_atlas_frame,
            base_geometry_epoch: value.base_geometry_epoch,
            sender_not_after_ns: value.sender_not_after_ns,
            desired_x_millidip: value.desired_x_millidip,
            desired_y_millidip: value.desired_y_millidip,
            desired_width_millidip: value.desired_width_millidip,
            desired_height_millidip: value.desired_height_millidip,
        };
        value.validate()?;
        Ok(value)
    }
}

impl From<DesktopWindowMove> for wire::DesktopWindowMove {
    fn from(value: DesktopWindowMove) -> Self {
        Self {
            source_device: Some(id(value.source_device)),
            owner_device: Some(id(value.owner_device)),
            stream_id: Some(id(value.stream_id)),
            config_generation: value.config_generation,
            topology_generation: value.topology_generation,
            window_id: Some(id(value.window_id)),
            drag_id: Some(id(value.drag_id)),
            sequence: value.sequence,
            phase: match value.phase {
                DesktopWindowMovePhase::Begin => wire::DesktopWindowMovePhase::Begin,
                DesktopWindowMovePhase::Update => wire::DesktopWindowMovePhase::Update,
                DesktopWindowMovePhase::End => wire::DesktopWindowMovePhase::End,
                DesktopWindowMovePhase::Cancel => wire::DesktopWindowMovePhase::Cancel,
            }
            .into(),
            base_atlas_frame: value.base_atlas_frame,
            base_geometry_epoch: value.base_geometry_epoch,
            sender_not_after_ns: value.sender_not_after_ns,
            desired_x_millidip: value.desired_x_millidip,
            desired_y_millidip: value.desired_y_millidip,
            desired_width_millidip: value.desired_width_millidip,
            desired_height_millidip: value.desired_height_millidip,
        }
    }
}

impl TryFrom<wire::DesktopWindowMoveAck> for DesktopWindowMoveAck {
    type Error = WireError;
    fn try_from(value: wire::DesktopWindowMoveAck) -> Result<Self, Self::Error> {
        let result = match wire::DesktopWindowMoveResult::try_from(value.result)
            .map_err(|_| WireError::UnknownEnum("desktop_window_move_ack.result"))?
        {
            wire::DesktopWindowMoveResult::Applied => DesktopWindowMoveResult::Applied,
            wire::DesktopWindowMoveResult::Rejected => DesktopWindowMoveResult::Rejected,
            wire::DesktopWindowMoveResult::Ended => DesktopWindowMoveResult::Ended,
            wire::DesktopWindowMoveResult::Unspecified => {
                return Err(WireError::UnknownEnum("desktop_window_move_ack.result"));
            }
        };
        let value = Self {
            source_device: required_id(
                value.source_device,
                "desktop_window_move_ack.source_device",
            )?,
            owner_device: required_id(value.owner_device, "desktop_window_move_ack.owner_device")?,
            stream_id: required_id(value.stream_id, "desktop_window_move_ack.stream_id")?,
            config_generation: value.config_generation,
            topology_generation: value.topology_generation,
            window_id: required_id(value.window_id, "desktop_window_move_ack.window_id")?,
            drag_id: required_id(value.drag_id, "desktop_window_move_ack.drag_id")?,
            sequence: value.sequence,
            result,
            actual_bounds: value
                .actual_bounds
                .ok_or(WireError::MissingField(
                    "desktop_window_move_ack.actual_bounds",
                ))?
                .try_into()?,
        };
        value.validate()?;
        Ok(value)
    }
}

impl From<DesktopWindowMoveAck> for wire::DesktopWindowMoveAck {
    fn from(value: DesktopWindowMoveAck) -> Self {
        Self {
            source_device: Some(id(value.source_device)),
            owner_device: Some(id(value.owner_device)),
            stream_id: Some(id(value.stream_id)),
            config_generation: value.config_generation,
            topology_generation: value.topology_generation,
            window_id: Some(id(value.window_id)),
            drag_id: Some(id(value.drag_id)),
            sequence: value.sequence,
            result: match value.result {
                DesktopWindowMoveResult::Applied => wire::DesktopWindowMoveResult::Applied,
                DesktopWindowMoveResult::Rejected => wire::DesktopWindowMoveResult::Rejected,
                DesktopWindowMoveResult::Ended => wire::DesktopWindowMoveResult::Ended,
            }
            .into(),
            actual_bounds: Some(value.actual_bounds.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x_millidip: i64, y_millidip: i64) -> DesktopRect {
        DesktopRect {
            x_millidip,
            y_millidip,
            width_millidip: 1_000,
            height_millidip: 1_000,
        }
    }

    fn layout() -> AtlasDesktopLayout {
        AtlasDesktopLayout {
            topology_generation: 1,
            viewport: DesktopRect {
                x_millidip: -1_000,
                y_millidip: -1_000,
                width_millidip: 4_000,
                height_millidip: 4_000,
            },
            windows: vec![AtlasWindowPlacement {
                window_id: Id128(2),
                bounds: rect(0, 0),
                movable: true,
                z_order: 7,
                raise_serial: 1,
            }],
        }
    }

    #[test]
    fn layout_round_trips_and_requires_exact_tile_membership() {
        let value = layout();
        assert_eq!(
            AtlasDesktopLayout::try_from(wire::AtlasDesktopLayout::from(value.clone())).unwrap(),
            value
        );
        let tiles = [crate::AtlasTile {
            window_id: Id128(2),
            placement_generation: 1,
            geometry_epoch: 1,
            source_frame_id: 1,
            source_submitted_ns: 1,
            x: 0,
            y: 0,
            width: 2,
            height: 2,
        }];
        assert!(value.validate_tiles(&tiles).is_ok());
        let mut other = tiles;
        other[0].window_id = Id128(3);
        assert!(value.validate_tiles(&other).is_err());
    }

    #[test]
    fn layout_preserves_windows_outside_or_crossing_the_viewport() {
        let mut value = layout();
        value.windows[0].bounds = DesktopRect {
            x_millidip: -1_500,
            y_millidip: -500,
            width_millidip: 1_000,
            height_millidip: 1_000,
        };
        assert!(value.validate().is_ok());
        value.windows[0].bounds = DesktopRect {
            x_millidip: 10_000,
            y_millidip: 10_000,
            width_millidip: 1_000,
            height_millidip: 1_000,
        };
        assert!(value.validate().is_ok());
    }

    #[test]
    fn rect_rejects_bounds_that_cannot_be_a_native_desktop() {
        assert!(
            DesktopRect {
                x_millidip: MAX_DESKTOP_COORDINATE_MILLIDIP,
                y_millidip: 0,
                width_millidip: 1,
                height_millidip: 1,
            }
            .validate()
            .is_err()
        );
        assert!(
            DesktopRect {
                x_millidip: 0,
                y_millidip: 0,
                width_millidip: 0,
                height_millidip: 1,
            }
            .validate()
            .is_err()
        );
    }

    #[test]
    fn drag_controls_round_trip_through_the_distinct_envelope_payloads() {
        let move_request = DesktopWindowMove {
            source_device: Id128(1),
            owner_device: Id128(2),
            stream_id: Id128(3),
            config_generation: 4,
            topology_generation: 5,
            window_id: Id128(6),
            drag_id: Id128(7),
            sequence: 8,
            phase: DesktopWindowMovePhase::Update,
            base_atlas_frame: 9,
            base_geometry_epoch: 10,
            sender_not_after_ns: 11,
            desired_x_millidip: 12,
            desired_y_millidip: -13,
            desired_width_millidip: 800_000,
            desired_height_millidip: 600_000,
        };
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(crate::PROTOCOL_VERSION.major),
            protocol_minor: u32::from(crate::PROTOCOL_VERSION.minor),
            sequence: 1,
            payload: Some(wire::control_envelope::Payload::DesktopWindowMove(
                move_request.into(),
            )),
        };
        assert_eq!(
            crate::DomainControl::try_from(envelope).unwrap(),
            crate::DomainControl::DesktopWindowMove(move_request)
        );

        let ack = DesktopWindowMoveAck {
            source_device: Id128(1),
            owner_device: Id128(2),
            stream_id: Id128(3),
            config_generation: 4,
            topology_generation: 5,
            window_id: Id128(6),
            drag_id: Id128(7),
            sequence: 8,
            result: DesktopWindowMoveResult::Applied,
            actual_bounds: rect(12, -13),
        };
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(crate::PROTOCOL_VERSION.major),
            protocol_minor: u32::from(crate::PROTOCOL_VERSION.minor),
            sequence: 2,
            payload: Some(wire::control_envelope::Payload::DesktopWindowMoveAck(
                ack.into(),
            )),
        };
        assert_eq!(
            crate::DomainControl::try_from(envelope).unwrap(),
            crate::DomainControl::DesktopWindowMoveAck(ack)
        );
    }
}
