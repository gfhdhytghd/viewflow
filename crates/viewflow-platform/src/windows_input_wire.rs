//! Fixed-size local input-service messages. Network leases are checked by the receiver.
use super::windows_input::{DesktopPointerDisplay, WindowsInputError};
use viewflow_protocol::*;

pub const REQUEST_SIZE: usize = 140;
pub fn encode(
    event: Option<InputEvent>,
    display: Option<DesktopPointerDisplay>,
) -> [u8; REQUEST_SIZE] {
    let mut b = [0; REQUEST_SIZE];
    b[..4].copy_from_slice(b"VFI2");
    let (tag, x, y) = match event.map(|e| e.event).unwrap_or(InputEventKind::ReleaseAll) {
        InputEventKind::Touchpad(frame) => {
            b[68..72].copy_from_slice(&frame.width.to_le_bytes());
            b[72..76].copy_from_slice(&frame.height.to_le_bytes());
            b[76] = frame.count;
            for (i, c) in frame.contacts.iter().enumerate() {
                let base = 80 + i * 12;
                b[base..base + 4].copy_from_slice(&c.id.to_le_bytes());
                b[base + 4..base + 8].copy_from_slice(&c.x.to_le_bytes());
                b[base + 8..base + 12].copy_from_slice(&c.y.to_le_bytes());
            }
            (6, 0, 0)
        }
        InputEventKind::ReleaseAll => (0, 0, 0),
        InputEventKind::DesktopPointerPosition(p) => (1, p.x_millidip as u64, p.y_millidip as u64),
        InputEventKind::PointerMotion(p) => (2, p.delta_x_dip.to_bits(), p.delta_y_dip.to_bits()),
        InputEventKind::PointerWheel(p) => (
            3,
            p.vertical_delta_detents.to_bits(),
            p.horizontal_delta_detents.to_bits(),
        ),
        InputEventKind::PointerButton(p) => (
            4,
            match p.button {
                PointerButton::Left => 0,
                PointerButton::Middle => 1,
                PointerButton::Right => 2,
                PointerButton::Back => 3,
                PointerButton::Forward => 4,
            },
            u64::from(p.state == InputSwitchState::Pressed),
        ),
        InputEventKind::KeyboardHidUsage(k) => (
            5,
            u64::from(k.usage_page) | (u64::from(k.usage_id) << 16),
            u64::from(k.state == InputSwitchState::Pressed) | (u64::from(k.repeat) << 1),
        ),
    };
    b[4] = tag;
    b[8..16].copy_from_slice(&x.to_le_bytes());
    b[16..24].copy_from_slice(&y.to_le_bytes());
    if let Some(d) = display {
        b[5] = 1;
        b[24..32].copy_from_slice(&d.bounds.x_millidip.to_le_bytes());
        b[32..40].copy_from_slice(&d.bounds.y_millidip.to_le_bytes());
        b[40..48].copy_from_slice(&d.bounds.width_millidip.to_le_bytes());
        b[48..56].copy_from_slice(&d.bounds.height_millidip.to_le_bytes());
        b[56..60].copy_from_slice(&d.native_x.to_le_bytes());
        b[60..64].copy_from_slice(&d.native_y.to_le_bytes());
        b[64..68].copy_from_slice(&d.scale_milli.to_le_bytes());
    }
    b
}

pub fn decode(
    b: &[u8; REQUEST_SIZE],
) -> Result<(InputEvent, Option<DesktopPointerDisplay>), WindowsInputError> {
    let invalid = WindowsInputError::DeltaOutOfRange;
    if &b[..4] != b"VFI2" || b[5] > 1 || b[6..8] != [0, 0] {
        return Err(invalid);
    }
    let word = |i| u64::from_le_bytes(b[i..i + 8].try_into().unwrap());
    let x = word(8);
    let y = word(16);
    let state = if y & 1 == 1 {
        InputSwitchState::Pressed
    } else {
        InputSwitchState::Released
    };
    if b[77..80] != [0; 3] || (b[4] != 6 && b[68..] != [0; 72]) {
        return Err(invalid);
    }
    let event = match b[4] {
        6 if x == 0 && y == 0 => {
            let mut frame = TouchpadFrame {
                width: u32::from_le_bytes(b[68..72].try_into().unwrap()),
                height: u32::from_le_bytes(b[72..76].try_into().unwrap()),
                count: b[76],
                ..TouchpadFrame::default()
            };
            for (i, c) in frame.contacts.iter_mut().enumerate() {
                let base = 80 + i * 12;
                c.id = u32::from_le_bytes(b[base..base + 4].try_into().unwrap());
                c.x = u32::from_le_bytes(b[base + 4..base + 8].try_into().unwrap());
                c.y = u32::from_le_bytes(b[base + 8..base + 12].try_into().unwrap());
            }
            frame.validate().map_err(|_| invalid)?;
            InputEventKind::Touchpad(frame)
        }
        0 if x == 0 && y == 0 => InputEventKind::ReleaseAll,
        1 => InputEventKind::DesktopPointerPosition(DesktopPointerPosition {
            x_millidip: x as i64,
            y_millidip: y as i64,
        }),
        2 if f64::from_bits(x).is_finite() && f64::from_bits(y).is_finite() => {
            InputEventKind::PointerMotion(RelativePointerMotion {
                delta_x_dip: f64::from_bits(x),
                delta_y_dip: f64::from_bits(y),
            })
        }
        3 if f64::from_bits(x).is_finite() && f64::from_bits(y).is_finite() => {
            InputEventKind::PointerWheel(PointerWheelEvent {
                vertical_delta_detents: f64::from_bits(x),
                horizontal_delta_detents: f64::from_bits(y),
            })
        }
        4 if y <= 1 => InputEventKind::PointerButton(PointerButtonEvent {
            button: match x {
                0 => PointerButton::Left,
                1 => PointerButton::Middle,
                2 => PointerButton::Right,
                3 => PointerButton::Back,
                4 => PointerButton::Forward,
                _ => return Err(invalid),
            },
            state,
        }),
        5 if x <= u64::from(u32::MAX) && y <= 3 => {
            InputEventKind::KeyboardHidUsage(KeyboardHidUsage {
                usage_page: x as u16,
                usage_id: (x >> 16) as u16,
                state,
                repeat: y & 2 != 0,
            })
        }
        _ => return Err(invalid),
    };
    let display = if b[5] == 1 {
        let d = DesktopPointerDisplay {
            bounds: DesktopRect {
                x_millidip: word(24) as i64,
                y_millidip: word(32) as i64,
                width_millidip: word(40),
                height_millidip: word(48),
            },
            native_x: i32::from_le_bytes(b[56..60].try_into().unwrap()),
            native_y: i32::from_le_bytes(b[60..64].try_into().unwrap()),
            scale_milli: u32::from_le_bytes(b[64..68].try_into().unwrap()),
        };
        d.bounds.validate().map_err(|_| invalid)?;
        if !(125..=8000).contains(&d.scale_milli) {
            return Err(invalid);
        }
        Some(d)
    } else {
        None
    };
    // No mapping means physical pixels; the console worker resolves its desktop.
    Ok((
        InputEvent {
            lease_generation: 0,
            target_device: Id128(0),
            sequence: 0,
            sender_not_after_ns: 0,
            event,
        },
        display,
    ))
}

pub fn encode_result(result: Result<(), WindowsInputError>) -> [u8; 5] {
    match result {
        Ok(()) => [0; 5],
        Err(WindowsInputError::UnsupportedHidUsage {
            usage_page,
            usage_id,
        }) => {
            let p = usage_page.to_le_bytes();
            let i = usage_id.to_le_bytes();
            [1, p[0], p[1], i[0], i[1]]
        }
        Err(WindowsInputError::NonFiniteDelta) => [2, 0, 0, 0, 0],
        Err(WindowsInputError::DeltaOutOfRange) => [3, 0, 0, 0, 0],
        Err(WindowsInputError::SendInputFailed) => [4, 0, 0, 0, 0],
    }
}
pub fn decode_result(b: [u8; 5]) -> Result<(), WindowsInputError> {
    match b[0] {
        0 => Ok(()),
        1 => Err(WindowsInputError::UnsupportedHidUsage {
            usage_page: u16::from_le_bytes([b[1], b[2]]),
            usage_id: u16::from_le_bytes([b[3], b[4]]),
        }),
        2 => Err(WindowsInputError::NonFiniteDelta),
        3 => Err(WindowsInputError::DeltaOutOfRange),
        _ => Err(WindowsInputError::SendInputFailed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip_events_and_reject_malformed_requests() {
        let events = [
            InputEventKind::ReleaseAll,
            InputEventKind::PointerMotion(RelativePointerMotion {
                delta_x_dip: -3.5,
                delta_y_dip: 2.0,
            }),
            InputEventKind::KeyboardHidUsage(KeyboardHidUsage {
                usage_page: 7,
                usage_id: 0xe3,
                state: InputSwitchState::Pressed,
                repeat: true,
            }),
            InputEventKind::PointerButton(PointerButtonEvent {
                button: PointerButton::Forward,
                state: InputSwitchState::Released,
            }),
            InputEventKind::PointerWheel(PointerWheelEvent {
                vertical_delta_detents: -1.0,
                horizontal_delta_detents: 0.5,
            }),
        ];
        for event in events {
            let e = InputEvent {
                lease_generation: 1,
                target_device: Id128(2),
                sequence: 3,
                sender_not_after_ns: 0,
                event,
            };
            assert_eq!(decode(&encode(Some(e), None)).unwrap().0.event, event);
        }
        let mut b = encode(None, None);
        b[4] = 255;
        assert!(decode(&b).is_err());
        b[4] = 4;
        b[16] = 2;
        assert!(decode(&b).is_err());
        b[4] = 2;
        b[8..16].copy_from_slice(&f64::NAN.to_bits().to_le_bytes());
        assert!(decode(&b).is_err());
    }
    #[test]
    fn coordinates_preserve_negative_origin_and_scale() {
        let d = DesktopPointerDisplay {
            bounds: DesktopRect {
                x_millidip: -100000,
                y_millidip: 0,
                width_millidip: 100000,
                height_millidip: 100000,
            },
            native_x: -200,
            native_y: 0,
            scale_milli: 2000,
        };
        let p = DesktopPointerPosition {
            x_millidip: -50000,
            y_millidip: 50000,
        };
        let e = InputEvent {
            lease_generation: 0,
            target_device: Id128(0),
            sequence: 0,
            sender_not_after_ns: 0,
            event: InputEventKind::DesktopPointerPosition(p),
        };
        let (_, result) = decode(&encode(Some(e), Some(d))).unwrap();
        assert_eq!(result.unwrap().native_position(p), Ok((-100, 100)));
        assert!(decode(&encode(Some(e), None)).unwrap().1.is_none());
    }
    #[test]
    fn preserve_backend_errors() {
        for r in [
            Ok(()),
            Err(WindowsInputError::SendInputFailed),
            Err(WindowsInputError::UnsupportedHidUsage {
                usage_page: 7,
                usage_id: 255,
            }),
            Err(WindowsInputError::NonFiniteDelta),
            Err(WindowsInputError::DeltaOutOfRange),
        ] {
            assert_eq!(decode_result(encode_result(r)), r);
        }
    }
}

#[cfg(test)]
mod touchpad_tests {
    use super::*;
    #[test]
    fn broker_preserves_five_contacts_and_validates_count_and_coordinates() {
        let mut frame = TouchpadFrame {
            width: 16000,
            height: 11000,
            count: 5,
            ..TouchpadFrame::default()
        };
        for (i, c) in frame.contacts.iter_mut().enumerate() {
            *c = TouchpadContact {
                id: i as u32 + 100,
                x: i as u32 * 2000,
                y: 9000,
            };
        }
        let event = InputEvent {
            lease_generation: 2,
            target_device: Id128(2),
            sequence: 3,
            sender_not_after_ns: 1,
            event: InputEventKind::Touchpad(frame),
        };
        let bytes = encode(Some(event), None);
        assert_eq!(decode(&bytes).unwrap().0.event, event.event);
        let mut invalid = bytes;
        invalid[76] = 6;
        assert!(decode(&invalid).is_err());
        let mut invalid = bytes;
        invalid[84..88].copy_from_slice(&16001u32.to_le_bytes());
        assert!(decode(&invalid).is_err());
        let mut invalid = bytes;
        invalid[92..96].copy_from_slice(&100u32.to_le_bytes());
        assert!(decode(&invalid).is_err());
        let empty = InputEvent {
            event: InputEventKind::Touchpad(TouchpadFrame { count: 0, ..frame }),
            ..event
        };
        assert_eq!(
            decode(&encode(Some(empty), None)).unwrap().0.event,
            empty.event
        );
    }
}

#[cfg(test)]
mod prelogin_coordinate_tests {
    #[test]
    fn input_only_positions_round_trip_without_video_mapping() {
        use super::super::windows_input::DesktopPointerDisplay;
        use viewflow_protocol::*;
        let position = DesktopPointerPosition {
            x_millidip: -960_000,
            y_millidip: 1_199_000,
        };
        let event = InputEvent {
            lease_generation: 1,
            target_device: Id128(1),
            sequence: 1,
            sender_not_after_ns: 0,
            event: InputEventKind::DesktopPointerPosition(position),
        };
        let (decoded, display) = super::decode(&super::encode(Some(event), None)).unwrap();
        assert!(display.is_none());
        assert_eq!(decoded.event, event.event);
        let mapping = DesktopPointerDisplay::physical_pixels(-1920, 0, 5760, 2400).unwrap();
        assert_eq!(mapping.native_position(position).unwrap(), (-960, 1199));
        assert_eq!(
            mapping
                .native_position(DesktopPointerPosition {
                    x_millidip: 3_839_000,
                    y_millidip: 2_399_000
                })
                .unwrap(),
            (3839, 2399)
        );
        assert!(
            mapping
                .native_position(DesktopPointerPosition {
                    x_millidip: 3_840_000,
                    y_millidip: 0
                })
                .is_err()
        );
        assert!(DesktopPointerDisplay::physical_pixels(0, 0, 0, 2400).is_err());
    }
}
