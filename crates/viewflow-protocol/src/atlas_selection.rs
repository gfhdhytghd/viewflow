//! A frame-bound selection request, never an input authorization.
use crate::{AtlasFrame, Id128, WindowId, WireError, required_id, wire};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasWindowSelection {
    pub stream_id: Id128,
    pub atlas_frame_id: u64,
    pub atlas_geometry_epoch: u64,
    pub config_generation: u64,
    pub layout_revision: u64,
    pub window_id: WindowId,
    pub placement_generation: u64,
    pub source_frame_id: u64,
    pub source_geometry_epoch: u64,
    pub sequence: u64,
    pub sender_not_after_ns: u64,
    pub activate_keyboard: bool,
}

impl AtlasWindowSelection {
    /// Capture the exact native-presented atlas/tile identity with a fresh event.
    /// # Errors
    /// Rejects invalid manifests, absent windows and invalid event identity.
    pub fn from_frame(
        frame: &AtlasFrame,
        window: WindowId,
        sequence: u64,
        sender_not_after_ns: u64,
    ) -> Result<Self, WireError> {
        frame.validate()?;
        let tile = frame
            .tiles
            .iter()
            .find(|tile| tile.window_id == window)
            .ok_or(WireError::InvalidField(
                "atlas_selection.window_not_present",
            ))?;
        let request = Self {
            stream_id: frame.stream_id,
            atlas_frame_id: frame.frame_id,
            atlas_geometry_epoch: frame.geometry_epoch,
            config_generation: frame.config_generation,
            layout_revision: frame.layout_revision,
            window_id: window,
            placement_generation: tile.placement_generation,
            source_frame_id: tile.source_frame_id,
            source_geometry_epoch: tile.geometry_epoch,
            sequence,
            sender_not_after_ns,
            activate_keyboard: false,
        };
        request.validate()?;
        Ok(request)
    }
    /// # Errors
    /// Requires a nonempty, nonzero frame/tile identity and event deadline.
    pub fn validate(&self) -> Result<(), WireError> {
        if self.stream_id.0 == 0
            || self.window_id.0 == 0
            || self.stream_id == self.window_id
            || [
                self.atlas_frame_id,
                self.atlas_geometry_epoch,
                self.config_generation,
                self.layout_revision,
                self.placement_generation,
                self.source_frame_id,
                self.source_geometry_epoch,
                self.sequence,
                self.sender_not_after_ns,
            ]
            .contains(&0)
            || self.placement_generation > self.layout_revision
        {
            return Err(WireError::InvalidField("atlas_window_selection"));
        }
        Ok(())
    }

    /// Compare with source-owned committed evidence, not a peer-supplied frame.
    /// Matching still requires an independent source policy and freshness check.
    #[must_use]
    pub fn matches(&self, frame: &AtlasFrame) -> bool {
        self.validate().is_ok()
            && frame.validate().is_ok()
            && self.stream_id == frame.stream_id
            && self.atlas_frame_id == frame.frame_id
            && self.atlas_geometry_epoch == frame.geometry_epoch
            && self.config_generation == frame.config_generation
            && self.layout_revision == frame.layout_revision
            && frame.tiles.iter().any(|tile| {
                tile.window_id == self.window_id
                    && tile.placement_generation == self.placement_generation
                    && tile.source_frame_id == self.source_frame_id
                    && tile.geometry_epoch == self.source_geometry_epoch
            })
    }
}

impl TryFrom<wire::AtlasWindowSelection> for AtlasWindowSelection {
    type Error = WireError;
    fn try_from(value: wire::AtlasWindowSelection) -> Result<Self, Self::Error> {
        let request = Self {
            stream_id: required_id(value.stream_id, "atlas_selection.stream")?,
            window_id: required_id(value.window_id, "atlas_selection.window")?,
            atlas_frame_id: value.atlas_frame_id,
            atlas_geometry_epoch: value.atlas_geometry_epoch,
            config_generation: value.config_generation,
            layout_revision: value.layout_revision,
            placement_generation: value.placement_generation,
            source_frame_id: value.source_frame_id,
            source_geometry_epoch: value.source_geometry_epoch,
            sequence: value.sequence,
            sender_not_after_ns: value.sender_not_after_ns,
            activate_keyboard: value.activate_keyboard,
        };
        request.validate()?;
        Ok(request)
    }
}

impl From<AtlasWindowSelection> for wire::AtlasWindowSelection {
    #[allow(clippy::cast_possible_truncation)] // Exact two halves of one u128.
    fn from(value: AtlasWindowSelection) -> Self {
        let id = |value: Id128| wire::Id128 {
            high: (value.0 >> 64) as u64,
            low: value.0 as u64,
        };
        Self {
            stream_id: Some(id(value.stream_id)),
            window_id: Some(id(value.window_id)),
            atlas_frame_id: value.atlas_frame_id,
            atlas_geometry_epoch: value.atlas_geometry_epoch,
            config_generation: value.config_generation,
            layout_revision: value.layout_revision,
            placement_generation: value.placement_generation,
            source_frame_id: value.source_frame_id,
            source_geometry_epoch: value.source_geometry_epoch,
            sequence: value.sequence,
            sender_not_after_ns: value.sender_not_after_ns,
            activate_keyboard: value.activate_keyboard,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;

    #[test]
    fn selection_is_exact_frame_bound_and_wire_validated() {
        let frame = AtlasFrame {
            stream_id: Id128(99),
            frame_id: 10,
            geometry_epoch: 2,
            config_generation: 3,
            layout_revision: 4,
            width: 64,
            height: 64,
            source_submitted_ns: 100,
            tiles: vec![crate::AtlasTile {
                window_id: Id128(3),
                placement_generation: 4,
                geometry_epoch: 5,
                source_frame_id: 6,
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
        let request = AtlasWindowSelection::from_frame(&frame, Id128(3), 7, 1000).unwrap();
        assert!(request.matches(&frame));
        let wire: wire::AtlasWindowSelection = request.into();
        let decoded = wire::AtlasWindowSelection::decode(wire.encode_to_vec().as_slice()).unwrap();
        assert_eq!(AtlasWindowSelection::try_from(decoded).unwrap(), request);
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(crate::PROTOCOL_VERSION.major),
            protocol_minor: u32::from(crate::PROTOCOL_VERSION.minor),
            sequence: 1,
            payload: Some(wire::control_envelope::Payload::AtlasWindowSelection(wire)),
        };
        assert_eq!(
            crate::DomainControl::try_from(envelope).unwrap(),
            crate::DomainControl::AtlasWindowSelection(request)
        );
        for field in 0..11 {
            let mut changed = request;
            match field {
                0 => changed.stream_id = Id128(98),
                1 => changed.atlas_frame_id += 1,
                2 => changed.atlas_geometry_epoch += 1,
                3 => changed.config_generation += 1,
                4 => changed.layout_revision += 1,
                5 => changed.window_id = Id128(4),
                6 => changed.placement_generation -= 1,
                7 => changed.source_frame_id += 1,
                8 => changed.source_geometry_epoch += 1,
                9 => changed.sequence = 0,
                _ => changed.sender_not_after_ns = 0,
            }
            assert!(!changed.matches(&frame), "field {field}");
        }
        for field in 0..11 {
            let mut invalid = wire;
            match field {
                0 => invalid.stream_id = None,
                1 => invalid.atlas_frame_id = 0,
                2 => invalid.atlas_geometry_epoch = 0,
                3 => invalid.config_generation = 0,
                4 => invalid.layout_revision = 0,
                5 => invalid.window_id = invalid.stream_id,
                6 => invalid.placement_generation = 5,
                7 => invalid.source_frame_id = 0,
                8 => invalid.source_geometry_epoch = 0,
                9 => invalid.sequence = 0,
                _ => invalid.sender_not_after_ns = 0,
            }
            assert!(AtlasWindowSelection::try_from(invalid).is_err());
        }
        assert!(AtlasWindowSelection::from_frame(&frame, Id128(4), 1, 100).is_err());
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AtlasSelectionRejectionReason {
    CaptureExpired,
    EventExpired,
    WindowWithdrawn,
    NativeUnavailable,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasWindowSelectionRejected {
    pub selection: AtlasWindowSelection,
    pub reason: AtlasSelectionRejectionReason,
    pub released_generation: u64,
    pub capture_age_ns: u64,
    pub capture_limit_ns: u64,
}
impl AtlasWindowSelectionRejected {
    pub fn validate(&self) -> Result<(), WireError> {
        self.selection.validate()?;
        if self.reason == AtlasSelectionRejectionReason::CaptureExpired
            && (self.capture_limit_ns == 0 || self.capture_age_ns < self.capture_limit_ns)
        {
            return Err(WireError::InvalidField(
                "atlas_selection_rejected.capture_age",
            ));
        }
        Ok(())
    }
}
impl TryFrom<wire::AtlasWindowSelectionRejected> for AtlasWindowSelectionRejected {
    type Error = WireError;
    fn try_from(value: wire::AtlasWindowSelectionRejected) -> Result<Self, Self::Error> {
        let value = Self {
            selection: value
                .selection
                .ok_or(WireError::InvalidField(
                    "atlas_selection_rejected.selection",
                ))?
                .try_into()?,
            reason: match value.reason {
                1 => AtlasSelectionRejectionReason::CaptureExpired,
                2 => AtlasSelectionRejectionReason::EventExpired,
                3 => AtlasSelectionRejectionReason::WindowWithdrawn,
                4 => AtlasSelectionRejectionReason::NativeUnavailable,
                _ => return Err(WireError::UnknownEnum("atlas_selection_rejected.reason")),
            },
            released_generation: value.released_generation,
            capture_age_ns: value.capture_age_ns,
            capture_limit_ns: value.capture_limit_ns,
        };
        value.validate()?;
        Ok(value)
    }
}
impl From<AtlasWindowSelectionRejected> for wire::AtlasWindowSelectionRejected {
    fn from(value: AtlasWindowSelectionRejected) -> Self {
        Self {
            selection: Some(value.selection.into()),
            reason: match value.reason {
                AtlasSelectionRejectionReason::CaptureExpired => 1,
                AtlasSelectionRejectionReason::EventExpired => 2,
                AtlasSelectionRejectionReason::WindowWithdrawn => 3,
                AtlasSelectionRejectionReason::NativeUnavailable => 4,
            },
            released_generation: value.released_generation,
            capture_age_ns: value.capture_age_ns,
            capture_limit_ns: value.capture_limit_ns,
        }
    }
}

#[cfg(test)]
mod rejection_tests {
    use super::*;
    #[test]
    fn selection_rejection_roundtrips_exact_identity_and_requires_evidence() {
        let rejection = AtlasWindowSelectionRejected {
            selection: AtlasWindowSelection {
                activate_keyboard: false,
                stream_id: Id128(99),
                atlas_frame_id: 1,
                atlas_geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 1,
                window_id: Id128(3),
                placement_generation: 1,
                source_frame_id: 1,
                source_geometry_epoch: 1,
                sequence: 2,
                sender_not_after_ns: 23_390_000,
            },
            reason: AtlasSelectionRejectionReason::CaptureExpired,
            released_generation: 7,
            capture_age_ns: 41_924_882,
            capture_limit_ns: 33_333_333,
        };
        let wire: wire::AtlasWindowSelectionRejected = rejection.into();
        assert_eq!(
            AtlasWindowSelectionRejected::try_from(wire).unwrap(),
            rejection
        );
        assert!(
            AtlasWindowSelectionRejected::try_from(wire::AtlasWindowSelectionRejected {
                selection: None,
                ..wire
            })
            .is_err()
        );
        assert!(
            AtlasWindowSelectionRejected::try_from(wire::AtlasWindowSelectionRejected {
                reason: 0,
                ..wire
            })
            .is_err()
        );
        assert!(
            AtlasWindowSelectionRejected::try_from(wire::AtlasWindowSelectionRejected {
                capture_limit_ns: 0,
                ..wire
            })
            .is_err()
        );
        assert!(
            AtlasWindowSelectionRejected::try_from(wire::AtlasWindowSelectionRejected {
                capture_age_ns: 1,
                ..wire
            })
            .is_err()
        );
        assert!(
            AtlasWindowSelectionRejected {
                capture_age_ns: 33_333_333,
                ..rejection
            }
            .validate()
            .is_ok()
        );
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasWindowSelectionAccepted {
    pub selection: AtlasWindowSelection,
    pub authorization: crate::WindowPointerAuthorization,
}
impl AtlasWindowSelectionAccepted {
    pub fn validate(&self) -> Result<(), WireError> {
        self.selection.validate()?;
        crate::WindowPointerAuthorization::try_from(wire::WindowPointerAuthorization::from(
            self.authorization,
        ))?;
        if self.authorization.target_window != self.selection.window_id
            || self.authorization.geometry_epoch != self.selection.source_geometry_epoch
            || self.authorization.presented_frame != self.selection.source_frame_id
        {
            return Err(WireError::InvalidField(
                "atlas_selection_accepted.authorization",
            ));
        }
        Ok(())
    }
}
impl TryFrom<wire::AtlasWindowSelectionAccepted> for AtlasWindowSelectionAccepted {
    type Error = WireError;
    fn try_from(value: wire::AtlasWindowSelectionAccepted) -> Result<Self, Self::Error> {
        let value = Self {
            selection: value
                .selection
                .ok_or(WireError::InvalidField(
                    "atlas_selection_accepted.selection",
                ))?
                .try_into()?,
            authorization: value
                .authorization
                .ok_or(WireError::InvalidField(
                    "atlas_selection_accepted.authorization",
                ))?
                .try_into()?,
        };
        value.validate()?;
        Ok(value)
    }
}
impl From<AtlasWindowSelectionAccepted> for wire::AtlasWindowSelectionAccepted {
    fn from(value: AtlasWindowSelectionAccepted) -> Self {
        Self {
            selection: Some(value.selection.into()),
            authorization: Some(value.authorization.into()),
        }
    }
}

#[cfg(test)]
mod acceptance_tests {
    use super::*;
    #[test]
    fn selection_acceptance_roundtrips_and_rejects_inexact_native_identity() {
        let selection = AtlasWindowSelection {
            activate_keyboard: false,
            stream_id: Id128(99),
            atlas_frame_id: 1,
            atlas_geometry_epoch: 1,
            config_generation: 1,
            layout_revision: 1,
            window_id: Id128(3),
            placement_generation: 1,
            source_frame_id: 1,
            source_geometry_epoch: 1,
            sequence: 2,
            sender_not_after_ns: 23_390_000,
        };
        let accepted = AtlasWindowSelectionAccepted {
            selection,
            authorization: crate::WindowPointerAuthorization {
                owner_device: Id128(1),
                target_device: Id128(2),
                target_window: Id128(3),
                lease_generation: 7,
                geometry_epoch: 1,
                presented_frame: 1,
                source_not_after_ns: 1_000_000_000,
            },
        };
        assert_eq!(
            AtlasWindowSelectionAccepted::try_from(wire::AtlasWindowSelectionAccepted::from(
                accepted
            ))
            .unwrap(),
            accepted
        );
        let activation = AtlasWindowSelectionAccepted {
            selection: AtlasWindowSelection {
                activate_keyboard: true,
                ..accepted.selection
            },
            ..accepted
        };
        assert_eq!(
            AtlasWindowSelectionAccepted::try_from(wire::AtlasWindowSelectionAccepted::from(
                activation
            ))
            .unwrap(),
            activation
        );
        for field in 0..4 {
            let mut invalid = accepted;
            match field {
                0 => invalid.authorization.target_window = Id128(4),
                1 => invalid.authorization.geometry_epoch += 1,
                2 => invalid.authorization.presented_frame += 1,
                _ => invalid.authorization.lease_generation = 0,
            }
            assert!(invalid.validate().is_err());
            assert!(
                AtlasWindowSelectionAccepted::try_from(wire::AtlasWindowSelectionAccepted::from(
                    invalid
                ))
                .is_err()
            );
        }
        assert!(
            AtlasWindowSelectionAccepted::try_from(wire::AtlasWindowSelectionAccepted {
                selection: None,
                authorization: Some(accepted.authorization.into())
            })
            .is_err()
        );
    }
}
