use bytes::{BufMut, Bytes, BytesMut};
use viewflow_protocol::Id128;

pub const RELIABLE_HEADER_LEN: usize = 8;
pub const BLOB_HEADER_LEN: usize = 32;
pub const MAX_BLOB_CHUNK_BYTES: usize = 1024 * 1024;

const MAGIC: &[u8; 4] = b"VFRS";
const VERSION: u8 = 1;
const KIND_CONTROL: u8 = 1;
const KIND_BLOB_CHUNK: u8 = 2;
const FLAG_FINAL: u8 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BlobChunk {
    pub transfer_id: Id128,
    pub item_index: u32,
    pub offset_bytes: u64,
    pub final_chunk: bool,
    pub payload: Bytes,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReliablePayload {
    Control(Bytes),
    BlobChunk(BlobChunk),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReliableCodecError {
    Truncated,
    InvalidMagic,
    UnsupportedVersion(u8),
    UnknownKind(u8),
    InvalidReservedBits,
    OversizedBlobChunk { actual: usize, maximum: usize },
}

pub fn encode_control(payload: &[u8]) -> Bytes {
    let mut encoded = BytesMut::with_capacity(RELIABLE_HEADER_LEN + payload.len());
    encode_header(&mut encoded, KIND_CONTROL);
    encoded.put_slice(payload);
    encoded.freeze()
}

/// Encodes one independently verifiable file-transfer chunk.
///
/// # Errors
///
/// Rejects payloads larger than [`MAX_BLOB_CHUNK_BYTES`].
pub fn encode_blob_chunk(chunk: &BlobChunk) -> Result<Bytes, ReliableCodecError> {
    if chunk.payload.len() > MAX_BLOB_CHUNK_BYTES {
        return Err(ReliableCodecError::OversizedBlobChunk {
            actual: chunk.payload.len(),
            maximum: MAX_BLOB_CHUNK_BYTES,
        });
    }
    let mut encoded =
        BytesMut::with_capacity(RELIABLE_HEADER_LEN + BLOB_HEADER_LEN + chunk.payload.len());
    encode_header(&mut encoded, KIND_BLOB_CHUNK);
    encoded.put_u128(chunk.transfer_id.0);
    encoded.put_u32(chunk.item_index);
    encoded.put_u64(chunk.offset_bytes);
    encoded.put_u8(u8::from(chunk.final_chunk));
    encoded.put_slice(&[0; 3]);
    encoded.put_slice(&chunk.payload);
    Ok(encoded.freeze())
}

/// Decodes the common reliable stream header and its typed payload.
///
/// # Errors
///
/// Rejects malformed headers, unknown versions/kinds, non-zero reserved bits,
/// and oversized blob chunks.
pub fn decode(bytes: &Bytes) -> Result<ReliablePayload, ReliableCodecError> {
    if bytes.len() < RELIABLE_HEADER_LEN {
        return Err(ReliableCodecError::Truncated);
    }
    if &bytes[..4] != MAGIC {
        return Err(ReliableCodecError::InvalidMagic);
    }
    if bytes[4] != VERSION {
        return Err(ReliableCodecError::UnsupportedVersion(bytes[4]));
    }
    if bytes[6..8] != [0, 0] {
        return Err(ReliableCodecError::InvalidReservedBits);
    }
    match bytes[5] {
        KIND_CONTROL => Ok(ReliablePayload::Control(bytes.slice(RELIABLE_HEADER_LEN..))),
        KIND_BLOB_CHUNK => decode_blob_chunk(bytes),
        kind => Err(ReliableCodecError::UnknownKind(kind)),
    }
}

fn encode_header(bytes: &mut BytesMut, kind: u8) {
    bytes.put_slice(MAGIC);
    bytes.put_u8(VERSION);
    bytes.put_u8(kind);
    bytes.put_u16(0);
}

fn decode_blob_chunk(bytes: &Bytes) -> Result<ReliablePayload, ReliableCodecError> {
    if bytes.len() < RELIABLE_HEADER_LEN + BLOB_HEADER_LEN {
        return Err(ReliableCodecError::Truncated);
    }
    let payload_start = RELIABLE_HEADER_LEN + BLOB_HEADER_LEN;
    let payload_len = bytes.len() - payload_start;
    if payload_len > MAX_BLOB_CHUNK_BYTES {
        return Err(ReliableCodecError::OversizedBlobChunk {
            actual: payload_len,
            maximum: MAX_BLOB_CHUNK_BYTES,
        });
    }
    let flags = bytes[RELIABLE_HEADER_LEN + 28];
    if flags & !FLAG_FINAL != 0 || bytes[RELIABLE_HEADER_LEN + 29..payload_start] != [0, 0, 0] {
        return Err(ReliableCodecError::InvalidReservedBits);
    }
    let transfer_id = Id128(u128::from_be_bytes(
        bytes[RELIABLE_HEADER_LEN..RELIABLE_HEADER_LEN + 16]
            .try_into()
            .map_err(|_| ReliableCodecError::Truncated)?,
    ));
    let item_index = u32::from_be_bytes(
        bytes[RELIABLE_HEADER_LEN + 16..RELIABLE_HEADER_LEN + 20]
            .try_into()
            .map_err(|_| ReliableCodecError::Truncated)?,
    );
    let offset_bytes = u64::from_be_bytes(
        bytes[RELIABLE_HEADER_LEN + 20..RELIABLE_HEADER_LEN + 28]
            .try_into()
            .map_err(|_| ReliableCodecError::Truncated)?,
    );
    Ok(ReliablePayload::BlobChunk(BlobChunk {
        transfer_id,
        item_index,
        offset_bytes,
        final_chunk: flags & FLAG_FINAL != 0,
        payload: bytes.slice(payload_start..),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_and_blob_have_unambiguous_stream_kinds() {
        assert_eq!(
            decode(&encode_control(b"protobuf")).unwrap(),
            ReliablePayload::Control(Bytes::from_static(b"protobuf"))
        );
        let chunk = BlobChunk {
            transfer_id: Id128(7),
            item_index: 3,
            offset_bytes: 4096,
            final_chunk: true,
            payload: Bytes::from_static(b"file data"),
        };
        assert_eq!(
            decode(&encode_blob_chunk(&chunk).unwrap()).unwrap(),
            ReliablePayload::BlobChunk(chunk)
        );
    }

    #[test]
    fn rejects_oversize_and_reserved_bits() {
        let chunk = BlobChunk {
            transfer_id: Id128(1),
            item_index: 0,
            offset_bytes: 0,
            final_chunk: false,
            payload: Bytes::from(vec![0; MAX_BLOB_CHUNK_BYTES + 1]),
        };
        assert!(matches!(
            encode_blob_chunk(&chunk),
            Err(ReliableCodecError::OversizedBlobChunk { .. })
        ));

        let mut encoded = encode_control(b"value").to_vec();
        encoded[7] = 1;
        assert_eq!(
            decode(&Bytes::from(encoded)),
            Err(ReliableCodecError::InvalidReservedBits)
        );
    }
}
