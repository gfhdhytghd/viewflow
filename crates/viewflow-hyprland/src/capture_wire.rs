//! Native capture commands share the window-input socket and sequence space.
//! These local messages are not remote authority; the paired runtime owns that check.
use std::io;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CaptureCommand {
    Configure {
        generation: u64,
        monitor_id: i64,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    },
    Activate {
        generation: u64,
        target: [u8; 16],
        loopback: bool,
    },
    Release {
        generation: u64,
        return_position: Option<(f64, f64)>,
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
                payload.extend(monitor_id.to_le_bytes());
                for number in [x, y, width, height] {
                    payload.extend(number.to_le_bytes());
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
                return_position, ..
            } => {
                if let Some((x, y)) = return_position {
                    if !x.is_finite() || !y.is_finite() {
                        return Err(invalid());
                    }
                    payload.extend(x.to_le_bytes());
                    payload.extend(y.to_le_bytes());
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
