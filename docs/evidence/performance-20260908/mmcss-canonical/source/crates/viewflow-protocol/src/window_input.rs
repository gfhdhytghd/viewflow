//! Window-scoped input wire validation; this is not a lease or injection API.

use crate::{DeviceId, WindowId, WireError, required_id, wire};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowPointerWheel {
    pub position: WindowPointerMotion,
    pub delta: crate::PointerWheelEvent,
}

impl TryFrom<wire::WindowPointerWheel> for WindowPointerWheel {
    type Error = WireError;

    fn try_from(value: wire::WindowPointerWheel) -> Result<Self, Self::Error> {
        let position = value
            .position
            .ok_or(WireError::InvalidField("window_wheel.position"))?
            .try_into()?;
        let delta: crate::PointerWheelEvent = value
            .delta
            .ok_or(WireError::InvalidField("window_wheel.delta"))?
            .try_into()?;
        if delta.vertical_delta_detents == 0.0 && delta.horizontal_delta_detents == 0.0 {
            return Err(WireError::InvalidField("window_wheel.empty_delta"));
        }
        Ok(Self { position, delta })
    }
}

impl From<WindowPointerWheel> for wire::WindowPointerWheel {
    fn from(value: WindowPointerWheel) -> Self {
        Self {
            position: Some(value.position.into()),
            delta: Some(wire::PointerWheelEvent {
                vertical_delta_detents: value.delta.vertical_delta_detents,
                horizontal_delta_detents: value.delta.horizontal_delta_detents,
            }),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowPointerButton {
    pub position: WindowPointerMotion,
    pub transition: crate::PointerButtonEvent,
}

impl TryFrom<wire::WindowPointerButton> for WindowPointerButton {
    type Error = WireError;

    fn try_from(value: wire::WindowPointerButton) -> Result<Self, Self::Error> {
        Ok(Self {
            position: value
                .position
                .ok_or(WireError::InvalidField("window_button.position"))?
                .try_into()?,
            transition: value
                .transition
                .ok_or(WireError::InvalidField("window_button.transition"))?
                .try_into()?,
        })
    }
}

impl From<WindowPointerButton> for wire::WindowPointerButton {
    fn from(value: WindowPointerButton) -> Self {
        use crate::{InputSwitchState, PointerButton};
        Self {
            position: Some(value.position.into()),
            transition: Some(wire::PointerButtonEvent {
                button: match value.transition.button {
                    PointerButton::Left => 1,
                    PointerButton::Middle => 2,
                    PointerButton::Right => 3,
                    PointerButton::Back => 4,
                    PointerButton::Forward => 5,
                },
                state: match value.transition.state {
                    InputSwitchState::Pressed => 1,
                    InputSwitchState::Released => 2,
                },
            }),
        }
    }
}

/// A source announcement, not permission to inject on the receiving machine.
/// Valid only on the authenticated connection that delivered it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowPointerAuthorization {
    pub lease_generation: u64,
    pub owner_device: DeviceId,
    pub target_device: DeviceId,
    pub target_window: WindowId,
    pub geometry_epoch: u64,
    pub presented_frame: u64,
    pub source_not_after_ns: u64,
}

impl TryFrom<wire::WindowPointerAuthorization> for WindowPointerAuthorization {
    type Error = WireError;

    fn try_from(value: wire::WindowPointerAuthorization) -> Result<Self, Self::Error> {
        let owner_device = required_id(value.owner_device, "window_authorization.owner")?;
        let target_device = required_id(value.target_device, "window_authorization.target")?;
        let target_window = required_id(value.target_window, "window_authorization.window")?;
        if owner_device.0 == 0
            || target_device.0 == 0
            || target_window.0 == 0
            || value.lease_generation == 0
            || value.geometry_epoch == 0
            || value.presented_frame == 0
            || value.source_not_after_ns == 0
        {
            return Err(WireError::InvalidField("window_authorization.identity"));
        }
        Ok(Self {
            lease_generation: value.lease_generation,
            owner_device,
            target_device,
            target_window,
            geometry_epoch: value.geometry_epoch,
            presented_frame: value.presented_frame,
            source_not_after_ns: value.source_not_after_ns,
        })
    }
}

impl From<WindowPointerAuthorization> for wire::WindowPointerAuthorization {
    #[allow(clippy::cast_possible_truncation)] // Low half keeps exactly 64 bits.
    fn from(value: WindowPointerAuthorization) -> Self {
        let id = |value: crate::Id128| wire::Id128 {
            high: (value.0 >> 64) as u64,
            low: value.0 as u64,
        };
        Self {
            lease_generation: value.lease_generation,
            owner_device: Some(id(value.owner_device)),
            target_device: Some(id(value.target_device)),
            target_window: Some(id(value.target_window)),
            geometry_epoch: value.geometry_epoch,
            presented_frame: value.presented_frame,
            source_not_after_ns: value.source_not_after_ns,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowPointerResult {
    MotionSent,
    Rejected,
    ButtonSent,
    WheelSent,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowPointerAck {
    pub lease_generation: u64,
    pub target_device: DeviceId,
    pub target_window: WindowId,
    pub geometry_epoch: u64,
    pub presented_frame: u64,
    pub event_sequence: u64,
    pub result: WindowPointerResult,
}

impl WindowPointerAck {
    #[must_use]
    pub fn for_motion(event: WindowPointerMotion, result: WindowPointerResult) -> Self {
        Self {
            lease_generation: event.lease_generation,
            target_device: event.target_device,
            target_window: event.target_window,
            geometry_epoch: event.geometry_epoch,
            presented_frame: event.presented_frame,
            event_sequence: event.sequence,
            result,
        }
    }
}

impl From<WindowPointerAck> for wire::WindowPointerAck {
    #[allow(clippy::cast_possible_truncation)] // Low half deliberately keeps only 64 bits.
    fn from(value: WindowPointerAck) -> Self {
        let id = |value: crate::Id128| wire::Id128 {
            high: (value.0 >> 64) as u64,
            low: value.0 as u64,
        };
        Self {
            lease_generation: value.lease_generation,
            target_device: Some(id(value.target_device)),
            target_window: Some(id(value.target_window)),
            geometry_epoch: value.geometry_epoch,
            presented_frame: value.presented_frame,
            event_sequence: value.event_sequence,
            result: match value.result {
                WindowPointerResult::MotionSent => 1,
                WindowPointerResult::Rejected => 2,
                WindowPointerResult::ButtonSent => 3,
                WindowPointerResult::WheelSent => 4,
            },
        }
    }
}

impl TryFrom<wire::WindowPointerAck> for WindowPointerAck {
    type Error = WireError;
    fn try_from(value: wire::WindowPointerAck) -> Result<Self, Self::Error> {
        let target_device = required_id(value.target_device, "window_ack.target_device")?;
        let target_window = required_id(value.target_window, "window_ack.target_window")?;
        if target_device.0 == 0
            || target_window.0 == 0
            || value.lease_generation == 0
            || value.geometry_epoch == 0
            || value.presented_frame == 0
            || value.event_sequence == 0
        {
            return Err(WireError::InvalidField("window_ack.identity"));
        }
        let result = match value.result {
            1 => WindowPointerResult::MotionSent,
            2 => WindowPointerResult::Rejected,
            3 => WindowPointerResult::ButtonSent,
            4 => WindowPointerResult::WheelSent,
            _ => return Err(WireError::InvalidField("window_ack.result")),
        };
        Ok(Self {
            lease_generation: value.lease_generation,
            target_device,
            target_window,
            geometry_epoch: value.geometry_epoch,
            presented_frame: value.presented_frame,
            event_sequence: value.event_sequence,
            result,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowPointerMotion {
    pub lease_generation: u64,
    pub target_device: DeviceId,
    pub target_window: WindowId,
    pub geometry_epoch: u64,
    pub presented_frame: u64,
    pub sequence: u64,
    pub sender_not_after_ns: u64,
    pub x_pixels: u32,
    pub y_pixels: u32,
    pub viewport_width: u32,
    pub viewport_height: u32,
}

impl TryFrom<wire::WindowPointerMotion> for WindowPointerMotion {
    type Error = WireError;

    fn try_from(value: wire::WindowPointerMotion) -> Result<Self, Self::Error> {
        let device = required_id(value.target_device, "window_pointer.target_device")?;
        let window = required_id(value.target_window, "window_pointer.target_window")?;
        if device.0 == 0 || window.0 == 0 {
            return Err(WireError::InvalidField("window_pointer.target"));
        }
        if value.lease_generation == 0
            || value.geometry_epoch == 0
            || value.presented_frame == 0
            || value.event_sequence == 0
            || value.sender_not_after_ns == 0
        {
            return Err(WireError::InvalidField("window_pointer.identity"));
        }
        // A half-open viewport also rejects zero-size destinations. These are
        // native client pixels, not normalized source/global screen coordinates.
        if value.x_pixels >= value.viewport_width || value.y_pixels >= value.viewport_height {
            return Err(WireError::InvalidField("window_pointer.viewport"));
        }
        Ok(Self {
            lease_generation: value.lease_generation,
            target_device: device,
            target_window: window,
            geometry_epoch: value.geometry_epoch,
            presented_frame: value.presented_frame,
            sequence: value.event_sequence,
            sender_not_after_ns: value.sender_not_after_ns,
            x_pixels: value.x_pixels,
            y_pixels: value.y_pixels,
            viewport_width: value.viewport_width,
            viewport_height: value.viewport_height,
        })
    }
}

impl From<WindowPointerMotion> for wire::WindowPointerMotion {
    #[allow(clippy::cast_possible_truncation)] // Low half keeps exactly 64 bits.
    fn from(value: WindowPointerMotion) -> Self {
        let id = |value: crate::Id128| wire::Id128 {
            high: (value.0 >> 64) as u64,
            low: value.0 as u64,
        };
        Self {
            lease_generation: value.lease_generation,
            target_device: Some(id(value.target_device)),
            target_window: Some(id(value.target_window)),
            geometry_epoch: value.geometry_epoch,
            presented_frame: value.presented_frame,
            event_sequence: value.sequence,
            sender_not_after_ns: value.sender_not_after_ns,
            x_pixels: value.x_pixels,
            y_pixels: value.y_pixels,
            viewport_width: value.viewport_width,
            viewport_height: value.viewport_height,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DomainControl, PROTOCOL_VERSION};

    #[test]
    fn wheel_retains_fractional_axes_and_full_position() {
        for (vertical, horizontal) in [(0.25, -0.5), (-1.0, 0.0), (0.0, 0.125)] {
            let mut position = valid();
            position.target_device.as_mut().unwrap().high = 42;
            position.target_window.as_mut().unwrap().high = 73;
            let wheel = wire::WindowPointerWheel {
                position: Some(position),
                delta: Some(wire::PointerWheelEvent {
                    vertical_delta_detents: vertical,
                    horizontal_delta_detents: horizontal,
                }),
            };
            let decoded = WindowPointerWheel::try_from(wheel).unwrap();
            assert_eq!(wire::WindowPointerWheel::from(decoded), wheel);
            for field in 0..9 {
                let mut bad = wheel;
                match field {
                    0 => bad.position = None,
                    1 => bad.delta = None,
                    2 => bad.position.as_mut().unwrap().sender_not_after_ns = 0,
                    3 => bad.position.as_mut().unwrap().lease_generation = 0,
                    4 => bad.position.as_mut().unwrap().presented_frame = 0,
                    5 => bad.position.as_mut().unwrap().geometry_epoch = 0,
                    6 => bad.position.as_mut().unwrap().event_sequence = 0,
                    7 => bad.position.as_mut().unwrap().target_window = None,
                    _ => bad.position.as_mut().unwrap().viewport_width = 0,
                }
                assert!(WindowPointerWheel::try_from(bad).is_err());
            }
            for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
                for horizontal in [false, true] {
                    let mut bad = wheel;
                    if horizontal {
                        bad.delta.as_mut().unwrap().horizontal_delta_detents = invalid;
                    } else {
                        bad.delta.as_mut().unwrap().vertical_delta_detents = invalid;
                    }
                    assert!(WindowPointerWheel::try_from(bad).is_err());
                }
            }
        }
        for zero in [0.0, -0.0] {
            assert!(
                WindowPointerWheel::try_from(wire::WindowPointerWheel {
                    position: Some(valid()),
                    delta: Some(wire::PointerWheelEvent {
                        vertical_delta_detents: zero,
                        horizontal_delta_detents: zero,
                    }),
                })
                .is_err()
            );
        }
    }

    #[test]
    fn wheel_is_not_a_legacy_device_or_window_button_event() {
        use prost::Message;
        #[derive(Clone, PartialEq, Message)]
        struct LegacyEnvelope {
            #[prost(message, optional, tag = "25")]
            device: Option<wire::InputEvent>,
            #[prost(message, optional, tag = "29")]
            motion: Option<wire::WindowPointerMotion>,
            #[prost(message, optional, tag = "32")]
            button: Option<wire::WindowPointerButton>,
        }
        let wheel = WindowPointerWheel::try_from(wire::WindowPointerWheel {
            position: Some(valid()),
            delta: Some(wire::PointerWheelEvent {
                vertical_delta_detents: -0.25,
                horizontal_delta_detents: 0.5,
            }),
        })
        .unwrap();
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence: 1,
            payload: Some(wire::control_envelope::Payload::WindowPointerWheel(
                wheel.into(),
            )),
        };
        let bytes = envelope.encode_to_vec();
        let old = LegacyEnvelope::decode(bytes.as_slice()).unwrap();
        assert!(old.device.is_none() && old.motion.is_none() && old.button.is_none());
        assert_eq!(
            DomainControl::try_from(wire::ControlEnvelope::decode(bytes.as_slice()).unwrap())
                .unwrap(),
            DomainControl::WindowPointerWheel(wheel)
        );
    }

    #[test]
    fn window_button_requires_full_position_and_canonical_transition() {
        for button in 1..=5 {
            for state in 1..=2 {
                let value = wire::WindowPointerButton {
                    position: Some(valid()),
                    transition: Some(wire::PointerButtonEvent { button, state }),
                };
                let decoded = WindowPointerButton::try_from(value).unwrap();
                let encoded: wire::WindowPointerButton = decoded.into();
                assert_eq!(WindowPointerButton::try_from(encoded).unwrap(), decoded);
                let mut bad = encoded;
                bad.position = None;
                assert!(WindowPointerButton::try_from(bad).is_err());
                let mut bad = encoded;
                bad.transition = None;
                assert!(WindowPointerButton::try_from(bad).is_err());
                let mut bad = encoded;
                bad.position.as_mut().unwrap().sender_not_after_ns = 0;
                assert!(WindowPointerButton::try_from(bad).is_err());
                let mut bad = encoded;
                bad.position.as_mut().unwrap().x_pixels =
                    bad.position.as_ref().unwrap().viewport_width;
                assert!(WindowPointerButton::try_from(bad).is_err());
                for invalid in [0, -1, 6] {
                    let mut bad = encoded;
                    bad.transition.as_mut().unwrap().button = invalid;
                    assert!(WindowPointerButton::try_from(bad).is_err());
                }
                for invalid in [0, -1, 3] {
                    let mut bad = encoded;
                    bad.transition.as_mut().unwrap().state = invalid;
                    assert!(WindowPointerButton::try_from(bad).is_err());
                }
            }
        }
    }

    #[test]
    fn motion_encoder_preserves_full_identity_and_native_deadline() {
        let mut motion = WindowPointerMotion::try_from(valid()).unwrap();
        motion.target_device = crate::Id128((1_u128 << 110) + 2);
        motion.target_window = crate::Id128((1_u128 << 120) + 3);
        let encoded: wire::WindowPointerMotion = motion.into();
        assert_eq!(WindowPointerMotion::try_from(encoded).unwrap(), motion);
    }

    #[test]
    fn window_authorization_roundtrips_full_ids_and_rejects_missing_identity() {
        let authorization = WindowPointerAuthorization {
            lease_generation: 7,
            owner_device: crate::Id128((1_u128 << 110) + 1),
            target_device: crate::Id128((1_u128 << 100) + 2),
            target_window: crate::Id128((1_u128 << 120) + 3),
            geometry_epoch: 4,
            presented_frame: 5,
            source_not_after_ns: 100,
        };
        let valid: wire::WindowPointerAuthorization = authorization.into();
        assert_eq!(
            WindowPointerAuthorization::try_from(valid).unwrap(),
            authorization
        );
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence: 1,
            payload: Some(wire::control_envelope::Payload::WindowPointerAuthorization(
                valid,
            )),
        };
        assert_eq!(
            DomainControl::try_from(envelope).unwrap(),
            DomainControl::WindowPointerAuthorization(authorization)
        );
        for field in 0..10 {
            let mut invalid = valid;
            match field {
                0 => invalid.owner_device = None,
                1 => invalid.target_device = None,
                2 => invalid.target_window = None,
                3 => invalid.owner_device = Some(wire::Id128 { high: 0, low: 0 }),
                4 => invalid.target_device = Some(wire::Id128 { high: 0, low: 0 }),
                5 => invalid.target_window = Some(wire::Id128 { high: 0, low: 0 }),
                6 => invalid.lease_generation = 0,
                7 => invalid.geometry_epoch = 0,
                8 => invalid.presented_frame = 0,
                _ => invalid.source_not_after_ns = 0,
            }
            assert!(WindowPointerAuthorization::try_from(invalid).is_err());
        }
    }

    #[test]
    fn window_ack_roundtrips_exact_identity_and_rejects_unknown_results() {
        let mut event = WindowPointerMotion::try_from(valid()).unwrap();
        event.target_device = crate::Id128((1_u128 << 100) + 2);
        event.target_window = crate::Id128((1_u128 << 120) + 3);
        for result in [
            WindowPointerResult::MotionSent,
            WindowPointerResult::Rejected,
            WindowPointerResult::ButtonSent,
            WindowPointerResult::WheelSent,
        ] {
            let ack = WindowPointerAck::for_motion(event, result);
            let wire: wire::WindowPointerAck = ack.into();
            assert_eq!(WindowPointerAck::try_from(wire).unwrap(), ack);
            let envelope = wire::ControlEnvelope {
                protocol_major: u32::from(PROTOCOL_VERSION.major),
                protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                sequence: 1,
                payload: Some(wire::control_envelope::Payload::WindowPointerAck(wire)),
            };
            assert_eq!(
                DomainControl::try_from(envelope).unwrap(),
                DomainControl::WindowPointerAck(ack)
            );
            for field in 0..9 {
                let mut bad = wire;
                match field {
                    0 => bad.lease_generation = 0,
                    1 => bad.target_device = None,
                    2 => bad.target_window = None,
                    3 => bad.geometry_epoch = 0,
                    4 => bad.presented_frame = 0,
                    5 => bad.event_sequence = 0,
                    6 => bad.result = 0,
                    7 => bad.result = 5,
                    _ => bad.target_window = Some(wire::Id128 { high: 0, low: 0 }),
                }
                assert!(WindowPointerAck::try_from(bad).is_err());
            }
        }
    }

    fn valid() -> wire::WindowPointerMotion {
        wire::WindowPointerMotion {
            lease_generation: 1,
            target_device: Some(wire::Id128 { high: 0, low: 2 }),
            target_window: Some(wire::Id128 { high: 0, low: 3 }),
            geometry_epoch: 4,
            presented_frame: 5,
            event_sequence: 6,
            sender_not_after_ns: 7,
            x_pixels: 40,
            y_pixels: 80,
            viewport_width: 1626,
            viewport_height: 1240,
        }
    }

    #[test]
    fn window_motion_is_not_device_input() {
        use prost::Message;
        // Simulates a legacy decoder that only knows the device-input tag.
        #[derive(Clone, PartialEq, Message)]
        struct LegacyDeviceInputEnvelope {
            #[prost(message, optional, tag = "25")]
            input_event: Option<wire::InputEvent>,
        }
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            payload: Some(wire::control_envelope::Payload::WindowPointerMotion(valid())),
            ..Default::default()
        };
        let bytes = envelope.encode_to_vec();
        assert!(
            LegacyDeviceInputEnvelope::decode(bytes.as_slice())
                .unwrap()
                .input_event
                .is_none()
        );
        let decoded = wire::ControlEnvelope::decode(bytes.as_slice()).unwrap();
        assert_eq!(decoded, envelope);
        assert!(matches!(
            DomainControl::try_from(envelope),
            Ok(DomainControl::WindowPointerMotion(_))
        ));
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            payload: Some(wire::control_envelope::Payload::WindowPointerButton(
                wire::WindowPointerButton {
                    position: Some(valid()),
                    transition: Some(wire::PointerButtonEvent {
                        button: 1,
                        state: 1,
                    }),
                },
            )),
            ..Default::default()
        };
        let bytes = envelope.encode_to_vec();
        assert!(
            LegacyDeviceInputEnvelope::decode(bytes.as_slice())
                .unwrap()
                .input_event
                .is_none()
        );
        assert!(matches!(
            DomainControl::try_from(wire::ControlEnvelope::decode(bytes.as_slice()).unwrap()),
            Ok(DomainControl::WindowPointerButton(_))
        ));
    }

    #[test]
    fn rejects_missing_and_zero_identity_fields() {
        for field in 0..9 {
            let mut value = valid();
            match field {
                0 => value.target_device = None,
                1 => value.target_window = None,
                2 => value.target_device.as_mut().unwrap().low = 0,
                3 => value.target_window.as_mut().unwrap().low = 0,
                4 => value.lease_generation = 0,
                5 => value.geometry_epoch = 0,
                6 => value.presented_frame = 0,
                7 => value.event_sequence = 0,
                _ => value.sender_not_after_ns = 0,
            }
            assert!(WindowPointerMotion::try_from(value).is_err());
        }
    }

    #[test]
    fn rejects_outside_and_empty_viewport() {
        for field in 0..4 {
            let mut value = valid();
            match field {
                0 => value.x_pixels = value.viewport_width,
                1 => value.y_pixels = value.viewport_height,
                2 => value.viewport_width = 0,
                _ => value.viewport_height = 0,
            }
            assert!(WindowPointerMotion::try_from(value).is_err());
        }
        assert!(WindowPointerMotion::try_from(valid()).is_ok());
    }
}
