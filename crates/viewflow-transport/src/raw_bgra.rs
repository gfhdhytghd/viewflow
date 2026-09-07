//! Uncompressed premultiplied BGRA payload for the native presentation path.
//!
//! This explicit format is a bring-up/fallback codec, not a replacement for
//! negotiated hardware video codecs. Geometry/frame identity stays in VFMD.

use bytes::{Buf, BufMut, Bytes, BytesMut};

const HEADER_BYTES: usize = 20;
const MAGIC: &[u8; 4] = b"VFBG";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RawBgraPayload {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub pixels: Bytes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RawBgraError {
    InvalidHeader,
    InvalidDimensions,
    InvalidLength,
    ResourceLimit,
    NotPremultiplied,
}

impl std::fmt::Display for RawBgraError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "raw BGRA payload error: {self:?}")
    }
}

impl std::error::Error for RawBgraError {}

impl RawBgraPayload {
    /// Convert tightly packed straight RGBA into premultiplied BGRA in place.
    /// Keeps the supplied allocation; transparent RGB is normalized to zero.
    ///
    /// # Errors
    /// Rejects invalid dimensions, lengths, and resource limits before mutation.
    pub fn from_straight_rgba(
        width: u32,
        height: u32,
        mut pixels: Vec<u8>,
        max_bytes: usize,
    ) -> Result<Self, RawBgraError> {
        let stride = width
            .checked_mul(4)
            .filter(|n| *n != 0)
            .ok_or(RawBgraError::InvalidDimensions)?;
        if height == 0 {
            return Err(RawBgraError::InvalidDimensions);
        }
        let size = u64::from(stride) * u64::from(height);
        if size > u64::try_from(max_bytes).unwrap_or(u64::MAX) {
            return Err(RawBgraError::ResourceLimit);
        }
        if size != pixels.len() as u64 {
            return Err(RawBgraError::InvalidLength);
        }
        for p in pixels.chunks_exact_mut(4) {
            let alpha = u16::from(p[3]);
            // Both factors are <=255; rounded result is therefore <=255.
            #[allow(clippy::cast_possible_truncation)]
            let premultiply = |v| ((u16::from(v) * alpha + 127) / 255) as u8;
            let r = premultiply(p[0]);
            p[0] = premultiply(p[2]);
            p[1] = premultiply(p[1]);
            p[2] = r;
        }
        Ok(Self {
            width,
            height,
            stride,
            pixels: Bytes::from(pixels),
        })
    }
    /// Validates resource usage and premultiplied active pixels.
    ///
    /// # Errors
    /// Rejects invalid dimensions, lengths, pixel values, or caller limits.
    pub fn validate(&self, max_bytes: usize) -> Result<(), RawBgraError> {
        let row = self
            .width
            .checked_mul(4)
            .ok_or(RawBgraError::InvalidDimensions)?;
        if row == 0 || self.height == 0 || self.stride < row {
            return Err(RawBgraError::InvalidDimensions);
        }
        let size = u64::from(self.stride) * u64::from(self.height);
        if size > u64::try_from(max_bytes).unwrap_or(u64::MAX) {
            return Err(RawBgraError::ResourceLimit);
        }
        if size != self.pixels.len() as u64 {
            return Err(RawBgraError::InvalidLength);
        }
        for row_bytes in self.pixels.chunks_exact(self.stride as usize) {
            if row_bytes[..row as usize]
                .chunks_exact(4)
                .any(|p| p[0] > p[3] || p[1] > p[3] || p[2] > p[3])
            {
                return Err(RawBgraError::NotPremultiplied);
            }
        }
        Ok(())
    }

    /// Encodes a validated frame. All integer fields use network byte order.
    ///
    /// # Errors
    /// Returns the same validation errors as [`Self::validate`].
    pub fn encode(&self, max_bytes: usize) -> Result<Bytes, RawBgraError> {
        self.validate(max_bytes)?;
        let mut out = BytesMut::with_capacity(HEADER_BYTES + self.pixels.len());
        out.extend_from_slice(MAGIC);
        out.put_u8(1); // format version
        out.put_u8(1); // premultiplied BGRA8
        out.put_u16(0);
        out.put_u32(self.width);
        out.put_u32(self.height);
        out.put_u32(self.stride);
        out.extend_from_slice(&self.pixels);
        Ok(out.freeze())
    }

    /// Decodes without copying the pixel storage, before native allocation.
    ///
    /// # Errors
    /// Rejects unsupported headers and invalid or oversized pixel buffers.
    pub fn decode(mut bytes: Bytes, max_bytes: usize) -> Result<Self, RawBgraError> {
        if bytes.len() < HEADER_BYTES || &bytes[..4] != MAGIC || bytes[4..8] != [1, 1, 0, 0] {
            return Err(RawBgraError::InvalidHeader);
        }
        bytes.advance(8);
        let result = Self {
            width: bytes.get_u32(),
            height: bytes.get_u32(),
            stride: bytes.get_u32(),
            pixels: bytes,
        };
        result.validate(max_bytes)?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgba_import_reuses_allocation_and_handles_alpha() {
        let pixels = vec![255, 128, 64, 128, 255, 255, 255, 0, 1, 2, 3, 255];
        let pointer = pixels.as_ptr();
        let frame = RawBgraPayload::from_straight_rgba(3, 1, pixels, 12).unwrap();
        assert_eq!(frame.pixels.as_ptr(), pointer);
        assert_eq!(
            &frame.pixels[..],
            &[32, 64, 128, 128, 0, 0, 0, 0, 3, 2, 1, 255]
        );
        frame.validate(12).unwrap();
        assert!(RawBgraPayload::from_straight_rgba(1, 1, vec![0; 3], 4).is_err());
        assert!(RawBgraPayload::from_straight_rgba(1, 1, vec![0; 4], 3).is_err());
        assert!(RawBgraPayload::from_straight_rgba(u32::MAX, 1, vec![], usize::MAX).is_err());
    }

    fn frame() -> RawBgraPayload {
        RawBgraPayload {
            width: 2,
            height: 1,
            stride: 8,
            pixels: Bytes::from_static(&[0, 0, 0, 0, 20, 30, 40, 128]),
        }
    }

    #[test]
    fn transparent_pixels_round_trip() {
        let original = frame();
        let encoded = original.encode(8).unwrap();
        let decoded = RawBgraPayload::decode(encoded.clone(), 8).unwrap();
        assert_eq!(original, decoded);
        assert_eq!(decoded.pixels.as_ptr(), encoded[HEADER_BYTES..].as_ptr());
    }

    #[test]
    fn rejects_malformed_or_over_budget_buffers() {
        assert_eq!(frame().encode(7), Err(RawBgraError::ResourceLimit));
        let mut value = frame();
        value.width = u32::MAX;
        assert_eq!(value.validate(8), Err(RawBgraError::InvalidDimensions));
        value = frame();
        value.pixels = Bytes::from_static(&[1, 0, 0, 0, 20, 30, 40, 128]);
        assert_eq!(value.validate(8), Err(RawBgraError::NotPremultiplied));
        let mut wire = frame().encode(8).unwrap().to_vec();
        wire[6] = 1;
        assert_eq!(
            RawBgraPayload::decode(wire.into(), 8),
            Err(RawBgraError::InvalidHeader)
        );
    }
}
