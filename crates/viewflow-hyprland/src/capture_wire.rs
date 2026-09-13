//! Native capture commands share the window-input socket and sequence space.
//! These local messages are not remote authority; the paired runtime owns that check.
use std::io;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DragTarget {
    pub pid: u32,
    pub address: u64,
    pub surface: u64,
    pub reverse_id: u64,
    pub grab_offset: Option<(f64, f64)>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CaptureCommand {
    Configure {
        generation: u64,
        monitor_id: i64,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        raw_touchpad: bool,
        // A separately connected native HID owner consumes the physical
        // touchpad.  It still needs Hyprland's finger-derived events muted,
        // but must never receive raw frames over this cursor connection.
        external_touchpad: bool,
    },
    Activate {
        generation: u64,
        target: [u8; 16],
        loopback: bool,
    },
    Release {
        generation: u64,
        return_position: Option<(f64, f64)>,
        drag_target: Option<DragTarget>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CaptureReceipt {
    pub generation: u64,
    pub command: u16,
    pub applied: bool,
}

impl CaptureCommand {
    #[must_use]
    pub const fn generation(self) -> u64 {
        match self {
            Self::Configure { generation, .. }
            | Self::Activate { generation, .. }
            | Self::Release { generation, .. } => generation,
        }
    }
    #[must_use]
    pub const fn tag(self) -> u16 {
        match self {
            Self::Configure { .. } => 42,
            Self::Activate { .. } => 40,
            Self::Release { .. } => 41,
        }
    }
    pub(crate) fn packet(self, sequence: u64) -> io::Result<Vec<u8>> {
        let invalid = || {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid native capture command",
            )
        };
        if self.generation() == 0 || sequence == 0 {
            return Err(invalid());
        }
        let mut payload = self.generation().to_le_bytes().to_vec();
        match self {
            Self::Configure {
                monitor_id,
                x,
                y,
                width,
                height,
                raw_touchpad,
                external_touchpad,
                ..
            } => {
                if monitor_id < 0
                    || ![x, y, width, height, x + width, y + height]
                        .into_iter()
                        .all(f64::is_finite)
                    || width <= 0.0
                    || height <= 0.0
                {
                    return Err(invalid());
                }
                if raw_touchpad && external_touchpad {
                    return Err(invalid());
                }
                payload.extend(monitor_id.to_le_bytes());
                for number in [x, y, width, height] {
                    payload.extend(number.to_le_bytes());
                }
                // Legacy 48-byte topology keeps raw touchpad forwarding.
                // Explicit modes are: 0 derived, 1 raw over this connection,
                // and 2 separately-owned native HID.
                if external_touchpad {
                    payload.push(2);
                } else if !raw_touchpad {
                    payload.push(0);
                }
            }
            Self::Activate {
                target, loopback, ..
            } => {
                if target == [0; 16] {
                    return Err(invalid());
                }
                payload.extend(target);
                payload.push(u8::from(loopback));
            }
            Self::Release {
                return_position,
                drag_target,
                ..
            } => {
                if let Some((x, y)) = return_position {
                    if !x.is_finite() || !y.is_finite() {
                        return Err(invalid());
                    }
                    payload.extend(x.to_le_bytes());
                    payload.extend(y.to_le_bytes());
                }
                if let Some(target) = drag_target {
                    if return_position.is_none()
                        || target.pid == 0
                        || target.address == 0
                        || (target.surface == 0 && target.reverse_id == 0)
                    {
                        return Err(invalid());
                    }
                    payload.extend(target.pid.to_le_bytes());
                    payload.extend(target.address.to_le_bytes());
                    payload.extend(target.surface.to_le_bytes());
                    if target.reverse_id != 0 {
                        payload.extend(target.reverse_id.to_le_bytes());
                    }
                    if let Some((x, y)) = target.grab_offset {
                        if target.reverse_id == 0
                            || !x.is_finite()
                            || !y.is_finite()
                            || x.abs() > 1_000_000.
                            || y.abs() > 1_000_000.
                        {
                            return Err(invalid());
                        }
                        payload.extend(x.to_le_bytes());
                        payload.extend(y.to_le_bytes());
                    }
                }
            }
        }
        let mut bytes = b"VFHY\x01\x00".to_vec();
        bytes.extend(self.tag().to_le_bytes());
        bytes.extend(
            u32::try_from(payload.len())
                .map_err(|_| invalid())?
                .to_le_bytes(),
        );
        bytes.extend(sequence.to_le_bytes());
        bytes.extend(payload);
        Ok(bytes)
    }

    pub(crate) fn receipt(self, bytes: &[u8]) -> io::Result<CaptureReceipt> {
        let invalid = || {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "unmatched native capture receipt",
            )
        };
        if bytes.len() != 31 || bytes[30] > 1 {
            return Err(invalid());
        }
        let generation = u64::from_le_bytes(bytes[20..28].try_into().map_err(|_| invalid())?);
        let command = u16::from_le_bytes(bytes[28..30].try_into().map_err(|_| invalid())?);
        if generation != self.generation() || command != self.tag() {
            return Err(invalid());
        }
        Ok(CaptureReceipt {
            generation,
            command,
            applied: bytes[30] == 1,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn touchpad_modes_keep_the_legacy_topology_prefix() {
        let raw = CaptureCommand::Configure {
            generation: 1,
            monitor_id: 2,
            x: 3072.0,
            y: 390.0,
            width: 1920.0,
            height: 1200.0,
            raw_touchpad: true,
            external_touchpad: false,
        }
        .packet(1)
        .unwrap();
        let derived = CaptureCommand::Configure {
            generation: 1,
            monitor_id: 2,
            x: 3072.0,
            y: 390.0,
            width: 1920.0,
            height: 1200.0,
            raw_touchpad: false,
            external_touchpad: false,
        }
        .packet(1)
        .unwrap();
        let external = CaptureCommand::Configure {
            generation: 1,
            monitor_id: 2,
            x: 3072.0,
            y: 390.0,
            width: 1920.0,
            height: 1200.0,
            raw_touchpad: false,
            external_touchpad: true,
        }
        .packet(1)
        .unwrap();
        assert_eq!(raw.len(), 68);
        assert_eq!(derived.len(), 69);
        assert_eq!(external.len(), 69);
        assert_eq!(&raw[20..], &derived[20..68]);
        assert_eq!(derived[68], 0);
        assert_eq!(&raw[20..], &external[20..68]);
        assert_eq!(external[68], 2);
        assert!(
            CaptureCommand::Configure {
                generation: 1,
                monitor_id: 2,
                x: 0.,
                y: 0.,
                width: 1.,
                height: 1.,
                raw_touchpad: true,
                external_touchpad: true
            }
            .packet(1)
            .is_err()
        );
    }
    #[test]
    fn drag_return_requires_a_position_and_complete_native_identity() {
        let target = DragTarget {
            pid: 12,
            address: 0x1234,
            surface: 0x5678,
            reverse_id: 0,
            grab_offset: None,
        };
        let command = CaptureCommand::Release {
            generation: 3,
            return_position: Some((99.999, 40.)),
            drag_target: Some(target),
        };
        let packet = command.packet(1).unwrap();
        assert_eq!(packet.len(), 64);
        let proxy = DragTarget {
            surface: 0,
            reverse_id: 42,
            ..target
        };
        let returned = CaptureCommand::Release {
            generation: 3,
            return_position: Some((99.999, 40.)),
            drag_target: Some(proxy),
        }
        .packet(2)
        .unwrap();
        assert_eq!(returned.len(), 72);
        assert_eq!(&returned[64..72], &42u64.to_le_bytes());
        let anchored = DragTarget {
            grab_offset: Some((566., 14.)),
            ..proxy
        };
        let anchored_packet = CaptureCommand::Release {
            generation: 3,
            return_position: Some((3012., 700.)),
            drag_target: Some(anchored),
        }
        .packet(3)
        .unwrap();
        assert_eq!(anchored_packet.len(), 88);
        assert_eq!(&anchored_packet[72..80], &566f64.to_le_bytes());
        assert_eq!(&anchored_packet[80..88], &14f64.to_le_bytes());
        assert!(
            CaptureCommand::Release {
                generation: 3,
                return_position: Some((3012., 700.)),
                drag_target: Some(DragTarget {
                    grab_offset: Some((f64::NAN, 14.)),
                    ..proxy
                })
            }
            .packet(4)
            .is_err()
        );
        assert_eq!(&packet[44..48], &12u32.to_le_bytes());
        assert_eq!(&packet[48..56], &0x1234u64.to_le_bytes());
        assert_eq!(&packet[56..64], &0x5678u64.to_le_bytes());
        for (position, target) in [
            (None, target),
            (Some((0., 0.)), DragTarget { pid: 0, ..target }),
            (Some((f64::NAN, 0.)), target),
        ] {
            assert!(
                CaptureCommand::Release {
                    generation: 3,
                    return_position: position,
                    drag_target: Some(target)
                }
                .packet(1)
                .is_err()
            );
        }
        assert_eq!(
            CaptureCommand::Release {
                generation: 3,
                return_position: None,
                drag_target: None
            }
            .packet(1)
            .unwrap()
            .len(),
            28
        );
    }
}
