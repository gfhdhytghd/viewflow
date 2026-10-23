//! Authenticated QUIC transport for control streams and low-latency media.

mod alpha_rle;
mod clock;
mod codec;
mod latency;
mod media;
mod raw_bgra;
mod reassembly;
mod reliable;
mod tls;

use std::{error::Error, fmt};

use bytes::Bytes;
use prost::Message;
use quinn::Connection;
use viewflow_protocol::wire;

pub use alpha_rle::{
    ALPHA_RLE_HEADER_BYTES, AlphaRleError, AlphaRleLimits, AlphaRleMode, AlphaRleProfile,
    DecodedAlpha, decode_alpha_rle, encode_alpha_rle, encode_rgba_alpha_rle, profile_alpha_rle,
    validate_alpha_rle,
};
pub use clock::{ClockDiscipline, ClockEstimate, ClockSyncError};
pub use codec::{
    AlphaInterpretation, AlphaPlanePolicy, CODEC_DESCRIPTOR_BYTES, CodecDescriptor,
    CodecDescriptorError, CodecFrameAdmission, CodecResourceLimits, CodecSession,
    CodecSessionError, CodecSessionPolicy, CodecShape, CodedPixelFormat, Colorimetry,
    FRAME_CODEC_METADATA_BYTES, FrameCodecMetadata, VideoCodec, VideoPlaneRole,
};
pub use latency::{LatencyClass, LatencyStats, LatencyWindow};
pub use media::{
    MediaDatagram, MediaDatagramError, MediaFragmentError, MediaPlane, MediaPlaneFrame,
};
pub use raw_bgra::{RawBgraError, RawBgraPayload};
pub use reassembly::{
    AssembledMedia, AssembledPlane, MediaAssembler, MediaAssemblerConfig, MediaAssemblerError,
};
pub use reliable::{BlobChunk, MAX_BLOB_CHUNK_BYTES, ReliableCodecError, ReliablePayload};
pub use tls::{PeerIdentity, build_client_config, build_server_config};

pub const ALPN: &[u8] = b"viewflow/1";
pub const MAX_CONTROL_BYTES: usize = 4 * 1024 * 1024;
const MAX_RELIABLE_STREAM_BYTES: usize = reliable::RELIABLE_HEADER_LEN
    + if MAX_CONTROL_BYTES > reliable::BLOB_HEADER_LEN + MAX_BLOB_CHUNK_BYTES {
        MAX_CONTROL_BYTES
    } else {
        reliable::BLOB_HEADER_LEN + MAX_BLOB_CHUNK_BYTES
    };

#[derive(Debug)]
pub enum TransportError {
    Connection(quinn::ConnectionError),
    Write(quinn::WriteError),
    Finish(quinn::ClosedStream),
    Read(quinn::ReadToEndError),
    Decode(prost::DecodeError),
    Sequence(ControlSequenceError),
    Reliable(ReliableCodecError),
    UnexpectedReliableKind,
    OversizedControl { actual: usize, maximum: usize },
}

impl fmt::Display for TransportError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Connection(error) => write!(formatter, "QUIC connection error: {error}"),
            Self::Write(error) => write!(formatter, "QUIC write error: {error}"),
            Self::Finish(error) => write!(formatter, "QUIC stream finish error: {error}"),
            Self::Read(error) => write!(formatter, "QUIC read error: {error}"),
            Self::Decode(error) => write!(formatter, "protobuf decode error: {error}"),
            Self::Sequence(error) => write!(formatter, "control sequence error: {error}"),
            Self::Reliable(error) => write!(formatter, "reliable stream codec error: {error:?}"),
            Self::UnexpectedReliableKind => {
                formatter.write_str("reliable stream did not contain the expected payload kind")
            }
            Self::OversizedControl { actual, maximum } => {
                write!(
                    formatter,
                    "control message is {actual} bytes, limit is {maximum}"
                )
            }
        }
    }
}

impl Error for TransportError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Connection(error) => Some(error),
            Self::Write(error) => Some(error),
            Self::Finish(error) => Some(error),
            Self::Read(error) => Some(error),
            Self::Decode(error) => Some(error),
            Self::Sequence(error) => Some(error),
            Self::Reliable(_) | Self::UnexpectedReliableKind | Self::OversizedControl { .. } => {
                None
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ControlSequenceError {
    Zero,
    NotIncreasing { received: u64, previous: u64 },
}

impl fmt::Display for ControlSequenceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Zero => formatter.write_str("sequence zero is reserved"),
            Self::NotIncreasing { received, previous } => write!(
                formatter,
                "received sequence {received} after sequence {previous}"
            ),
        }
    }
}

impl Error for ControlSequenceError {}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ControlSequencer {
    previous: Option<u64>,
}

impl ControlSequencer {
    /// Accepts a strictly increasing peer control sequence.
    ///
    /// # Errors
    ///
    /// Rejects zero, duplicate, replayed, and out-of-order sequence numbers.
    pub fn accept(&mut self, sequence: u64) -> Result<(), ControlSequenceError> {
        if sequence == 0 {
            return Err(ControlSequenceError::Zero);
        }
        if let Some(previous) = self.previous {
            if sequence <= previous {
                return Err(ControlSequenceError::NotIncreasing {
                    received: sequence,
                    previous,
                });
            }
        }
        self.previous = Some(sequence);
        Ok(())
    }

    #[must_use]
    pub fn previous(self) -> Option<u64> {
        self.previous
    }
}

/// Sends one reliable, independently ordered control envelope.
///
/// # Errors
///
/// Returns an error when serialization exceeds the control limit or QUIC cannot
/// open, write, or finish the stream.
pub async fn send_control(
    connection: &Connection,
    envelope: &wire::ControlEnvelope,
) -> Result<(), TransportError> {
    let payload = envelope.encode_to_vec();
    if payload.len() > MAX_CONTROL_BYTES {
        return Err(TransportError::OversizedControl {
            actual: payload.len(),
            maximum: MAX_CONTROL_BYTES,
        });
    }
    let bytes = reliable::encode_control(&payload);
    let mut stream = connection
        .open_uni()
        .await
        .map_err(TransportError::Connection)?;
    stream
        .write_all(&bytes)
        .await
        .map_err(TransportError::Write)?;
    stream.finish().map_err(TransportError::Finish)
}

/// Receives and decodes one control envelope from its own QUIC stream.
///
/// # Errors
///
/// Returns an error for connection failures, oversized streams, or malformed
/// protobuf payloads.
pub async fn receive_control(
    connection: &Connection,
) -> Result<wire::ControlEnvelope, TransportError> {
    match receive_reliable(connection).await? {
        ReliablePayload::Control(bytes) => {
            if bytes.len() > MAX_CONTROL_BYTES {
                return Err(TransportError::OversizedControl {
                    actual: bytes.len(),
                    maximum: MAX_CONTROL_BYTES,
                });
            }
            wire::ControlEnvelope::decode(bytes).map_err(TransportError::Decode)
        }
        ReliablePayload::BlobChunk(_) => Err(TransportError::UnexpectedReliableKind),
    }
}

/// Sends one reliable file-transfer chunk on its own QUIC stream.
///
/// # Errors
///
/// Returns an error for oversized chunks or QUIC stream failures.
pub async fn send_blob_chunk(
    connection: &Connection,
    chunk: &BlobChunk,
) -> Result<(), TransportError> {
    let bytes = reliable::encode_blob_chunk(chunk).map_err(TransportError::Reliable)?;
    let mut stream = connection
        .open_uni()
        .await
        .map_err(TransportError::Connection)?;
    stream
        .write_all(&bytes)
        .await
        .map_err(TransportError::Write)?;
    stream.finish().map_err(TransportError::Finish)
}

/// Receives one typed reliable stream for control/blob multiplexing.
///
/// # Errors
///
/// Returns an error for connection failures, oversized streams, or malformed
/// reliable framing.
pub async fn receive_reliable(connection: &Connection) -> Result<ReliablePayload, TransportError> {
    let mut stream = connection
        .accept_uni()
        .await
        .map_err(TransportError::Connection)?;
    let bytes = stream
        .read_to_end(MAX_RELIABLE_STREAM_BYTES)
        .await
        .map_err(TransportError::Read)?;
    reliable::decode(&Bytes::from(bytes)).map_err(TransportError::Reliable)
}

/// Receives a control envelope and rejects replayed or reordered messages.
///
/// # Errors
///
/// Returns the same errors as [`receive_control`], plus sequence validation
/// failures before the message can enter the coordinator.
pub async fn receive_control_sequenced(
    connection: &Connection,
    sequencer: &mut ControlSequencer,
) -> Result<wire::ControlEnvelope, TransportError> {
    let envelope = receive_control(connection).await?;
    sequencer
        .accept(envelope.sequence)
        .map_err(TransportError::Sequence)?;
    Ok(envelope)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_sequence_rejects_zero_replay_and_reordering() {
        let mut sequence = ControlSequencer::default();
        assert_eq!(sequence.accept(0), Err(ControlSequenceError::Zero));
        assert_eq!(sequence.accept(4), Ok(()));
        assert_eq!(
            sequence.accept(4),
            Err(ControlSequenceError::NotIncreasing {
                received: 4,
                previous: 4,
            })
        );
        assert_eq!(
            sequence.accept(3),
            Err(ControlSequenceError::NotIncreasing {
                received: 3,
                previous: 4,
            })
        );
        assert_eq!(sequence.accept(5), Ok(()));
        assert_eq!(sequence.previous(), Some(5));
    }
}
