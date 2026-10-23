//! Physical-key wire identity only; neither parsing nor proxy focus is a grant.

use crate::{DeviceId, InputSwitchState, KeyboardHidUsage, WindowId, WireError, required_id, wire};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowKeyboardMode {
    DirectApplication,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowKeyboardAuthorization {
    pub lease_generation: u64,
    pub owner_device: DeviceId,
    pub target_device: DeviceId,
    pub target_window: WindowId,
    pub geometry_epoch: u64,
    pub presented_frame: u64,
    pub source_not_after_ns: u64,
    pub mode: WindowKeyboardMode,
}

impl TryFrom<wire::WindowKeyboardAuthorization> for WindowKeyboardAuthorization {
    type Error = WireError;
    fn try_from(value: wire::WindowKeyboardAuthorization) -> Result<Self, Self::Error> {
        let mode = match value.mode {
            1 => WindowKeyboardMode::DirectApplication,
            _ => {
                return Err(WireError::InvalidField(
                    "window_keyboard_authorization.mode",
                ));
            }
        };
        // Reuse structural identity validation, not pointer authority. There is
        // deliberately no domain From<WindowPointerAuthorization> conversion.
        let binding =
            crate::WindowPointerAuthorization::try_from(wire::WindowPointerAuthorization {
                lease_generation: value.lease_generation,
                owner_device: value.owner_device,
                target_device: value.target_device,
                target_window: value.target_window,
                geometry_epoch: value.geometry_epoch,
                presented_frame: value.presented_frame,
                source_not_after_ns: value.source_not_after_ns,
            })?;
        Ok(Self {
            lease_generation: binding.lease_generation,
            owner_device: binding.owner_device,
            target_device: binding.target_device,
            target_window: binding.target_window,
            geometry_epoch: binding.geometry_epoch,
            presented_frame: binding.presented_frame,
            source_not_after_ns: binding.source_not_after_ns,
            mode,
        })
    }
}

impl From<WindowKeyboardAuthorization> for wire::WindowKeyboardAuthorization {
    #[allow(clippy::cast_possible_truncation)] // Low ID half retains exactly 64 bits.
    fn from(value: WindowKeyboardAuthorization) -> Self {
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
            mode: match value.mode {
                WindowKeyboardMode::DirectApplication => 1,
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowKeyboardResult {
    KeySent,
    Rejected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowKeyboardAck {
    pub event: WindowKeyboardEvent,
    pub result: WindowKeyboardResult,
}

impl TryFrom<wire::WindowKeyboardAck> for WindowKeyboardAck {
    type Error = WireError;
    fn try_from(value: wire::WindowKeyboardAck) -> Result<Self, Self::Error> {
        Ok(Self {
            event: value
                .event
                .ok_or(WireError::MissingField("window_keyboard_ack.event"))?
                .try_into()?,
            result: match value.result {
                1 => WindowKeyboardResult::KeySent,
                2 => WindowKeyboardResult::Rejected,
                _ => return Err(WireError::InvalidField("window_keyboard_ack.result")),
            },
        })
    }
}

impl From<WindowKeyboardAck> for wire::WindowKeyboardAck {
    fn from(value: WindowKeyboardAck) -> Self {
        Self {
            event: Some(value.event.into()),
            result: match value.result {
                WindowKeyboardResult::KeySent => 1,
                WindowKeyboardResult::Rejected => 2,
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowKeyboardEvent {
    pub lease_generation: u64,
    pub target_device: DeviceId,
    pub target_window: WindowId,
    pub geometry_epoch: u64,
    pub presented_frame: u64,
    pub sequence: u64,
    pub sender_not_after_ns: u64,
    pub key: KeyboardHidUsage,
}

impl TryFrom<wire::WindowKeyboardEvent> for WindowKeyboardEvent {
    type Error = WireError;

    fn try_from(value: wire::WindowKeyboardEvent) -> Result<Self, Self::Error> {
        let event = Self {
            lease_generation: value.lease_generation,
            target_device: required_id(value.target_device, "window_keyboard.device")?,
            target_window: required_id(value.target_window, "window_keyboard.window")?,
            geometry_epoch: value.geometry_epoch,
            presented_frame: value.presented_frame,
            sequence: value.event_sequence,
            sender_not_after_ns: value.sender_not_after_ns,
            key: value
                .key
                .ok_or(WireError::MissingField("window_keyboard.key"))?
                .try_into()?,
        };
        event.validate()?;
        Ok(event)
    }
}

impl WindowKeyboardEvent {
    /// Validate domain values too: callers can construct them without protobuf.
    /// Native backends must separately reject unsupported physical usages.
    /// # Errors
    /// Rejects empty identities, invalid usages and repeat-on-release.
    pub fn validate(self) -> Result<(), WireError> {
        if self.target_device.0 == 0
            || self.target_window.0 == 0
            || self.lease_generation == 0
            || self.geometry_epoch == 0
            || self.presented_frame == 0
            || self.sequence == 0
            || self.sender_not_after_ns == 0
        {
            return Err(WireError::InvalidField("window_keyboard.identity"));
        }
        if self.key.usage_page == 0
            || self.key.usage_id == 0
            || (self.key.repeat && self.key.state != InputSwitchState::Pressed)
        {
            return Err(WireError::InvalidField("window_keyboard.key"));
        }
        Ok(())
    }
}

impl From<WindowKeyboardEvent> for wire::WindowKeyboardEvent {
    #[allow(clippy::cast_possible_truncation)] // Low ID half retains exactly 64 bits.
    fn from(value: WindowKeyboardEvent) -> Self {
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
            key: Some(wire::KeyboardHidUsage {
                usage_page: u32::from(value.key.usage_page),
                usage_id: u32::from(value.key.usage_id),
                state: match value.key.state {
                    InputSwitchState::Pressed => 1,
                    InputSwitchState::Released => 2,
                },
                repeat: value.key.repeat,
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DomainControl, Id128, PROTOCOL_VERSION};
    use prost::Message;

    fn authorization() -> WindowKeyboardAuthorization {
        let event = WindowKeyboardEvent::try_from(valid()).unwrap();
        WindowKeyboardAuthorization {
            lease_generation: event.lease_generation,
            owner_device: Id128((91 << 64) | 1),
            target_device: event.target_device,
            target_window: event.target_window,
            geometry_epoch: event.geometry_epoch,
            presented_frame: event.presented_frame,
            source_not_after_ns: 900,
            mode: WindowKeyboardMode::DirectApplication,
        }
    }

    #[test]
    fn keyboard_authority_has_explicit_mode_and_complete_binding() {
        let expected = authorization();
        let encoded = wire::WindowKeyboardAuthorization::from(expected);
        assert_eq!(
            WindowKeyboardAuthorization::try_from(encoded).unwrap(),
            expected
        );
        for field in 0..14 {
            let mut invalid = encoded;
            match field {
                0 => invalid.mode = 0,
                1 => invalid.mode = 2,
                2 => invalid.mode = u32::MAX,
                3 => invalid.lease_generation = 0,
                4 => invalid.owner_device = None,
                5 => invalid.target_device = None,
                6 => invalid.target_window = None,
                7 => invalid.geometry_epoch = 0,
                8 => invalid.presented_frame = 0,
                9 => invalid.source_not_after_ns = 0,
                10 => invalid.owner_device = Some(wire::Id128 { high: 0, low: 0 }),
                11 => invalid.target_device = Some(wire::Id128 { high: 0, low: 0 }),
                12 => invalid.target_window = Some(wire::Id128 { high: 0, low: 0 }),
                _ => {
                    invalid.target_window = Some(wire::Id128 { high: 0, low: 0 });
                    invalid.mode = 0;
                }
            }
            assert!(
                WindowKeyboardAuthorization::try_from(invalid).is_err(),
                "field {field}"
            );
        }
    }

    #[test]
    fn keyboard_ack_requires_full_event_and_known_result() {
        let event = WindowKeyboardEvent::try_from(valid()).unwrap();
        for result in [
            WindowKeyboardResult::KeySent,
            WindowKeyboardResult::Rejected,
        ] {
            let ack = WindowKeyboardAck { event, result };
            assert_eq!(
                WindowKeyboardAck::try_from(wire::WindowKeyboardAck::from(ack)).unwrap(),
                ack
            );
        }
        for result in [0, 3, 4, 5, u32::MAX] {
            assert!(
                WindowKeyboardAck::try_from(wire::WindowKeyboardAck {
                    event: Some(valid()),
                    result
                })
                .is_err()
            );
        }
        assert!(
            WindowKeyboardAck::try_from(wire::WindowKeyboardAck {
                event: None,
                result: 1
            })
            .is_err()
        );
        let mut wrong = valid();
        wrong.sender_not_after_ns = 0;
        assert!(
            WindowKeyboardAck::try_from(wire::WindowKeyboardAck {
                event: Some(wrong),
                result: 1
            })
            .is_err()
        );
        // The echoed key and original deadline survive intact, not merely the
        // sequence number that might be reused under another grant.
        for field in 0..11 {
            let mut different = event;
            match field {
                0 => different.lease_generation += 1,
                1 => different.target_device.0 += 1,
                2 => different.target_window.0 += 1,
                3 => different.geometry_epoch += 1,
                4 => different.presented_frame += 1,
                5 => different.sequence += 1,
                6 => different.sender_not_after_ns += 1,
                7 => different.key.usage_page += 1,
                8 => different.key.usage_id += 1,
                9 => different.key.state = InputSwitchState::Released,
                _ => different.key.repeat = true,
            }
            let decoded =
                WindowKeyboardAck::try_from(wire::WindowKeyboardAck::from(WindowKeyboardAck {
                    event: different,
                    result: WindowKeyboardResult::KeySent,
                }))
                .unwrap();
            assert_ne!(decoded.event, event, "field {field}");
        }
    }

    #[test]
    fn keyboard_ack_and_authority_are_not_pointer_or_device_controls() {
        #[derive(Clone, PartialEq, Message)]
        struct Legacy {
            #[prost(message, optional, tag = "26")]
            device_ack: Option<wire::InputAppliedAck>,
            #[prost(message, optional, tag = "30")]
            pointer_ack: Option<wire::WindowPointerAck>,
            #[prost(message, optional, tag = "31")]
            pointer_authority: Option<wire::WindowPointerAuthorization>,
        }
        let auth = authorization();
        let ack = WindowKeyboardAck {
            event: WindowKeyboardEvent::try_from(valid()).unwrap(),
            result: WindowKeyboardResult::KeySent,
        };
        for (payload, expected) in [
            (
                wire::control_envelope::Payload::WindowKeyboardAuthorization(auth.into()),
                DomainControl::WindowKeyboardAuthorization(auth),
            ),
            (
                wire::control_envelope::Payload::WindowKeyboardAck(ack.into()),
                DomainControl::WindowKeyboardAck(ack),
            ),
        ] {
            let envelope = wire::ControlEnvelope {
                protocol_major: 2,
                protocol_minor: 1,
                sequence: 1,
                payload: Some(payload),
            };
            let bytes = envelope.encode_to_vec();
            assert_eq!(Legacy::decode(bytes.as_slice()).unwrap(), Legacy::default());
            assert_eq!(
                DomainControl::try_from(wire::ControlEnvelope::decode(bytes.as_slice()).unwrap())
                    .unwrap(),
                expected
            );
        }
    }

    fn valid() -> wire::WindowKeyboardEvent {
        WindowKeyboardEvent {
            lease_generation: 1,
            target_device: Id128((42 << 64) | 2),
            target_window: Id128((73 << 64) | 3),
            geometry_epoch: 4,
            presented_frame: 5,
            sequence: 6,
            sender_not_after_ns: 7,
            key: KeyboardHidUsage {
                usage_page: 7,
                usage_id: 4,
                state: InputSwitchState::Pressed,
                repeat: false,
            },
        }
        .into()
    }

    #[test]
    fn keyboard_roundtrip_preserves_physical_usage_and_full_identity() {
        for (page, usage) in [(7, 4), (7, 0xe1), (0xc, 0xe9), (65535, 65535)] {
            for (state, repeat) in [(1, false), (1, true), (2, false)] {
                let mut wire = valid();
                wire.key = Some(wire::KeyboardHidUsage {
                    usage_page: page,
                    usage_id: usage,
                    state,
                    repeat,
                });
                let decoded = WindowKeyboardEvent::try_from(wire).unwrap();
                assert_eq!(wire::WindowKeyboardEvent::from(decoded), wire);
            }
        }
    }

    #[test]
    fn keyboard_rejects_missing_invalid_and_overflowing_fields() {
        for field in 0..18 {
            let mut event = valid();
            match field {
                0 => event.lease_generation = 0,
                1 => event.target_device = None,
                2 => event.target_window = None,
                3 => event.target_device = Some(wire::Id128 { high: 0, low: 0 }),
                4 => event.target_window = Some(wire::Id128 { high: 0, low: 0 }),
                5 => event.geometry_epoch = 0,
                6 => event.presented_frame = 0,
                7 => event.event_sequence = 0,
                8 => event.sender_not_after_ns = 0,
                9 => event.key = None,
                10 => event.key.as_mut().unwrap().usage_page = 0,
                11 => event.key.as_mut().unwrap().usage_id = 0,
                12 => event.key.as_mut().unwrap().usage_page = 65536,
                13 => event.key.as_mut().unwrap().usage_id = 65536,
                14 => event.key.as_mut().unwrap().state = 0,
                15 => event.key.as_mut().unwrap().state = 3,
                16 => event.key.as_mut().unwrap().state = -1,
                _ => {
                    let key = event.key.as_mut().unwrap();
                    key.state = 2;
                    key.repeat = true;
                }
            }
            assert!(
                WindowKeyboardEvent::try_from(event).is_err(),
                "field {field}"
            );
        }
    }

    #[test]
    fn keyboard_never_aliases_old_device_pointer_or_wheel_payloads() {
        #[derive(Clone, PartialEq, Message)]
        struct Legacy {
            #[prost(message, optional, tag = "25")]
            device: Option<wire::InputEvent>,
            #[prost(message, optional, tag = "29")]
            motion: Option<wire::WindowPointerMotion>,
            #[prost(message, optional, tag = "32")]
            button: Option<wire::WindowPointerButton>,
            #[prost(message, optional, tag = "35")]
            wheel: Option<wire::WindowPointerWheel>,
        }
        let event = WindowKeyboardEvent::try_from(valid()).unwrap();
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence: 1,
            payload: Some(wire::control_envelope::Payload::WindowKeyboardEvent(
                event.into(),
            )),
        };
        let bytes = envelope.encode_to_vec();
        let old = Legacy::decode(bytes.as_slice()).unwrap();
        assert_eq!(old, Legacy::default());
        assert_eq!(
            DomainControl::try_from(wire::ControlEnvelope::decode(bytes.as_slice()).unwrap())
                .unwrap(),
            DomainControl::WindowKeyboardEvent(event)
        );
    }
}
