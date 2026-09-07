use std::{error::Error, fmt};

use bytes::{BufMut, Bytes, BytesMut};
use viewflow_protocol::{Id128, WindowId};

const MAGIC: &[u8; 4] = b"VFMD";
const VERSION: u8 = 1;
const HEADER_LEN: usize = 52;

/// One encoded plane before transport fragmentation. The payload may also use
/// the explicitly selected raw BGRA fallback codec.
#[derive(Clone, Debug)]
pub struct MediaPlaneFrame {
    pub window_id: WindowId,
    pub frame_id: u64,
    pub geometry_epoch: u64,
    pub plane: MediaPlane,
    pub source_submitted_ns: u64,
    pub payload: Bytes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MediaFragmentError {
    DatagramTooSmall,
    EmptyPayload,
    TooManyChunks,
}

impl fmt::Display for MediaFragmentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "media fragmentation error: {self:?}")
    }
}

impl Error for MediaFragmentError {}

impl MediaPlaneFrame {
    /// Splits a plane into zero-copy slices bounded by the peer's current
    /// `Connection::max_datagram_size()`. No packet-sized copy is made until
    /// the caller encodes each datagram; the iterator does not queue all bytes.
    ///
    /// # Errors
    /// Rejects empty payloads, a datagram budget without payload space, or a
    /// plane requiring more chunks than the wire's u16 count can represent.
    pub fn fragment(
        self,
        max_datagram_bytes: usize,
    ) -> Result<impl ExactSizeIterator<Item = MediaDatagram>, MediaFragmentError> {
        let chunk_bytes = max_datagram_bytes
            .checked_sub(HEADER_LEN)
            .filter(|size| *size > 0)
            .ok_or(MediaFragmentError::DatagramTooSmall)?;
        if self.payload.is_empty() {
            return Err(MediaFragmentError::EmptyPayload);
        }
        let count = u16::try_from(self.payload.len().div_ceil(chunk_bytes))
            .map_err(|_| MediaFragmentError::TooManyChunks)?;
        Ok((0..count).map(move |index| {
            let start = usize::from(index) * chunk_bytes;
            let end = start.saturating_add(chunk_bytes).min(self.payload.len());
            MediaDatagram {
                window_id: self.window_id,
                frame_id: self.frame_id,
                geometry_epoch: self.geometry_epoch,
                plane: self.plane,
                chunk_index: index,
                chunk_count: count,
                source_submitted_ns: self.source_submitted_ns,
                payload: self.payload.slice(start..end),
            }
        }))
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(u8)]
pub enum MediaPlane {
    Color = 1,
    Alpha = 2,
    Audio = 3,
    BlurBackground = 4,
}

impl TryFrom<u8> for MediaPlane {
    type Error = MediaDatagramError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Color),
            2 => Ok(Self::Alpha),
            3 => Ok(Self::Audio),
            4 => Ok(Self::BlurBackground),
            _ => Err(MediaDatagramError::UnknownPlane(value)),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaDatagram {
    pub window_id: WindowId,
    pub frame_id: u64,
    pub geometry_epoch: u64,
    pub plane: MediaPlane,
    pub chunk_index: u16,
    pub chunk_count: u16,
    pub source_submitted_ns: u64,
    pub payload: Bytes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MediaDatagramError {
    Truncated,
    InvalidMagic,
    UnsupportedVersion(u8),
    UnknownPlane(u8),
    InvalidChunkRange,
}

impl fmt::Display for MediaDatagramError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated => write!(formatter, "media datagram is shorter than its header"),
            Self::InvalidMagic => write!(formatter, "media datagram magic is invalid"),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported media datagram version {version}")
            }
            Self::UnknownPlane(plane) => write!(formatter, "unknown media plane {plane}"),
            Self::InvalidChunkRange => {
                write!(formatter, "media chunk index is outside chunk count")
            }
        }
    }
}

impl Error for MediaDatagramError {}

impl MediaDatagram {
    #[must_use]
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(HEADER_LEN + self.payload.len());
        bytes.put_slice(MAGIC);
        bytes.put_u8(VERSION);
        bytes.put_u8(self.plane as u8);
        bytes.put_u16(0);
        bytes.put_u128(self.window_id.0);
        bytes.put_u64(self.frame_id);
        bytes.put_u64(self.geometry_epoch);
        bytes.put_u16(self.chunk_index);
        bytes.put_u16(self.chunk_count);
        bytes.put_u64(self.source_submitted_ns);
        bytes.put_slice(&self.payload);
        bytes.freeze()
    }

    /// Decodes and validates the fixed low-overhead media header.
    ///
    /// # Errors
    ///
    /// Rejects truncated, incompatible, or structurally invalid datagrams.
    #[allow(clippy::needless_pass_by_value)] // Ownership keeps the payload slice zero-copy.
    pub fn decode(bytes: Bytes) -> Result<Self, MediaDatagramError> {
        if bytes.len() < HEADER_LEN {
            return Err(MediaDatagramError::Truncated);
        }
        if &bytes[..4] != MAGIC {
            return Err(MediaDatagramError::InvalidMagic);
        }
        if bytes[4] != VERSION {
            return Err(MediaDatagramError::UnsupportedVersion(bytes[4]));
        }
        let plane = MediaPlane::try_from(bytes[5])?;
        let window_id = Id128(u128::from_be_bytes(
            bytes[8..24]
                .try_into()
                .map_err(|_| MediaDatagramError::Truncated)?,
        ));
        let frame_id = u64::from_be_bytes(
            bytes[24..32]
                .try_into()
                .map_err(|_| MediaDatagramError::Truncated)?,
        );
        let geometry_epoch = u64::from_be_bytes(
            bytes[32..40]
                .try_into()
                .map_err(|_| MediaDatagramError::Truncated)?,
        );
        let chunk_index = u16::from_be_bytes(
            bytes[40..42]
                .try_into()
                .map_err(|_| MediaDatagramError::Truncated)?,
        );
        let chunk_count = u16::from_be_bytes(
            bytes[42..44]
                .try_into()
                .map_err(|_| MediaDatagramError::Truncated)?,
        );
        if chunk_count == 0 || chunk_index >= chunk_count {
            return Err(MediaDatagramError::InvalidChunkRange);
        }
        let source_submitted_ns = u64::from_be_bytes(
            bytes[44..52]
                .try_into()
                .map_err(|_| MediaDatagramError::Truncated)?,
        );
        Ok(Self {
            window_id,
            frame_id,
            geometry_epoch,
            plane,
            chunk_index,
            chunk_count,
            source_submitted_ns,
            payload: bytes.slice(HEADER_LEN..),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(payload: Bytes) -> MediaPlaneFrame {
        MediaPlaneFrame {
            window_id: Id128(5),
            frame_id: 9,
            geometry_epoch: 2,
            plane: MediaPlane::Color,
            source_submitted_ns: 100,
            payload,
        }
    }

    #[test]
    fn fragmented_plane_roundtrips_at_negotiated_datagram_size() {
        let bytes = Bytes::from(vec![123; 5000]);
        let packets = source(bytes.clone())
            .fragment(1200)
            .unwrap()
            .collect::<Vec<_>>();
        assert_eq!(packets.len(), 5);
        assert_eq!(packets[0].payload.as_ptr(), bytes.as_ptr());
        let mut assembler = crate::MediaAssembler::new(crate::MediaAssemblerConfig::default());
        let mut result = None;
        for packet in packets.into_iter().rev() {
            let encoded = packet.encode();
            assert!(encoded.len() <= 1200);
            result = assembler
                .push(MediaDatagram::decode(encoded).unwrap(), 200)
                .unwrap()
                .or(result);
        }
        assert_eq!(result.unwrap().payload, bytes);
    }

    #[test]
    fn fragmentation_limits_do_not_truncate_or_wrap() {
        assert!(matches!(
            source(Bytes::from_static(b"x")).fragment(HEADER_LEN),
            Err(MediaFragmentError::DatagramTooSmall)
        ));
        assert!(matches!(
            source(Bytes::new()).fragment(1200),
            Err(MediaFragmentError::EmptyPayload)
        ));
        assert!(matches!(
            source(Bytes::from(vec![0; 65536])).fragment(HEADER_LEN + 1),
            Err(MediaFragmentError::TooManyChunks)
        ));
        assert_eq!(
            source(Bytes::from(vec![0; 65535]))
                .fragment(HEADER_LEN + 1)
                .unwrap()
                .len(),
            65535
        );
    }

    #[test]
    fn media_header_round_trips_without_copying_payload() {
        let packet = MediaDatagram {
            window_id: Id128(0x1234),
            frame_id: 88,
            geometry_epoch: 9,
            plane: MediaPlane::Alpha,
            chunk_index: 1,
            chunk_count: 3,
            source_submitted_ns: 123_456,
            payload: Bytes::from_static(b"alpha payload"),
        };
        assert_eq!(MediaDatagram::decode(packet.encode()).unwrap(), packet);
    }

    #[test]
    fn media_header_rejects_out_of_range_chunk() {
        let packet = MediaDatagram {
            window_id: Id128(1),
            frame_id: 1,
            geometry_epoch: 1,
            plane: MediaPlane::Color,
            chunk_index: 2,
            chunk_count: 2,
            source_submitted_ns: 0,
            payload: Bytes::new(),
        };
        assert_eq!(
            MediaDatagram::decode(packet.encode()),
            Err(MediaDatagramError::InvalidChunkRange)
        );
    }
}
