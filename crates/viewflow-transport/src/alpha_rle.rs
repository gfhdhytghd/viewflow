//! Bounded lossless 8-bit alpha coding for backends without H.264 alpha.
//!
//! The payload is independently intra-frame coded. It carries no prediction
//! state, so a lost frame cannot corrupt a later alpha frame.

use std::{error::Error, fmt};

use bytes::{Buf, BufMut, Bytes, BytesMut};

const MAGIC: &[u8; 4] = b"VFAR";
const VERSION: u8 = 1;
/// Fixed header size before raw or mixed-RLE alpha samples.
pub const ALPHA_RLE_HEADER_BYTES: usize = 24;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum AlphaRleMode {
    /// One byte per alpha sample; selected when RLE would not save bytes.
    Raw = 0,
    /// Literal and repeated runs, independently decodable within this frame.
    Rle = 1,
}

impl TryFrom<u8> for AlphaRleMode {
    type Error = AlphaRleError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::Raw),
            1 => Ok(Self::Rle),
            _ => Err(AlphaRleError::UnknownMode(value)),
        }
    }
}

/// Caller-selected limits checked before any decoded RLE allocation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AlphaRleLimits {
    pub max_coded_width: u32,
    pub max_coded_height: u32,
    pub max_luma_samples: u64,
    pub max_decoded_bytes: u64,
    pub max_encoded_bytes: usize,
}

/// Fully checked, straight 8-bit alpha samples.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DecodedAlpha {
    pub width: u32,
    pub height: u32,
    pub samples: Bytes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AlphaRleProfile {
    pub width: u32,
    pub height: u32,
    pub mode: AlphaRleMode,
    pub decoded_bytes: usize,
    pub encoded_bytes: usize,
    pub savings_bytes: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AlphaRleError {
    InvalidLength,
    InvalidMagic,
    UnsupportedVersion(u8),
    UnknownMode(u8),
    NonZeroReserved,
    InvalidDimensions,
    DecodedLengthMismatch,
    ResourceLimit,
    SizeOverflow,
    RawLengthMismatch,
    TruncatedRun,
    OutputOverflow,
    TrailingBytes,
    InvalidRgbaStride,
    RgbaLengthMismatch,
}

impl fmt::Display for AlphaRleError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "lossless alpha RLE error: {self:?}")
    }
}

impl Error for AlphaRleError {}

/// Encodes a complete, straight 8-bit alpha plane.
///
/// The hybrid RLE stream uses a control byte whose low seven bits encode
/// `run_length - 1`. A clear control precedes literal bytes; a set high bit
/// precedes one repeated byte. The raw mode is selected whenever that stream
/// is equal to or larger than the raw samples.
///
/// # Errors
///
/// Rejects zero dimensions, checked size overflow, or a sample slice whose
/// length does not exactly equal `width * height`.
pub fn encode_alpha_rle(width: u32, height: u32, samples: &[u8]) -> Result<Bytes, AlphaRleError> {
    let decoded_bytes = dimensions_bytes(width, height)?;
    if samples.len() != decoded_bytes {
        return Err(AlphaRleError::DecodedLengthMismatch);
    }
    // Without any repeated triplet the RLE writer can only add literal
    // headers. Skip that allocation and per-literal assembly altogether.
    // This exact precheck changes neither decoded samples nor mode selection.
    let has_repeat = samples.windows(3).any(|p| p[0] == p[1] && p[1] == p[2]);
    let rle = if has_repeat {
        rle_payload(samples)
    } else {
        Vec::new()
    };
    let (mode, payload) = if has_repeat && rle.len() < samples.len() {
        (AlphaRleMode::Rle, rle.as_slice())
    } else {
        (AlphaRleMode::Raw, samples)
    };
    let mut encoded = encoded_prefix(width, height, decoded_bytes, mode, payload.len())?;
    encoded.put_slice(payload);
    Ok(encoded.freeze())
}

/// Encodes alpha directly from an RGBA image with one or more bytes of row
/// padding.  This avoids materializing a full intermediate alpha plane.
///
/// `rgba_stride` is measured in bytes and the input must contain exactly
/// `height * rgba_stride` bytes.  Alpha samples are read from byte three of
/// each pixel.  The generated VFAR bytes are deliberately identical to
/// [`encode_alpha_rle`] applied to the same tightly packed alpha samples.
///
/// # Errors
/// Rejects zero dimensions, arithmetic overflow, a stride smaller than one
/// RGBA row, or a slice whose length does not exactly match the stated stride.
pub fn encode_rgba_alpha_rle(
    width: u32,
    height: u32,
    rgba: &[u8],
    rgba_stride: usize,
) -> Result<Bytes, AlphaRleError> {
    let decoded_bytes = dimensions_bytes(width, height)?;
    let row_bytes =
        usize::try_from(u64::from(width) * 4).map_err(|_| AlphaRleError::SizeOverflow)?;
    if rgba_stride < row_bytes {
        return Err(AlphaRleError::InvalidRgbaStride);
    }
    let expected_input = rgba_stride
        .checked_mul(usize::try_from(height).map_err(|_| AlphaRleError::SizeOverflow)?)
        .ok_or(AlphaRleError::SizeOverflow)?;
    if rgba.len() != expected_input {
        return Err(AlphaRleError::RgbaLengthMismatch);
    }

    if rgba_stride == row_bytes {
        // CompatibleEncoder's authenticated HCSF inputs land here.  Keep this
        // path division-free: the fourth byte of pixel `index` is alpha.
        encode_alpha_from(width, height, decoded_bytes, &|index| rgba[index * 4 + 3])
    } else {
        let width_usize = usize::try_from(width).map_err(|_| AlphaRleError::SizeOverflow)?;
        encode_alpha_from(width, height, decoded_bytes, &|index| {
            let row = index / width_usize;
            let column = index % width_usize;
            rgba[row * rgba_stride + column * 4 + 3]
        })
    }
}

fn encode_alpha_from(
    width: u32,
    height: u32,
    decoded_bytes: usize,
    sample_at: &impl Fn(usize) -> u8,
) -> Result<Bytes, AlphaRleError> {
    if !has_repeat(decoded_bytes, sample_at) {
        return encode_raw_from(width, height, decoded_bytes, sample_at);
    }
    let rle = rle_payload_from(decoded_bytes, sample_at);
    if rle.len() < decoded_bytes {
        let mut encoded =
            encoded_prefix(width, height, decoded_bytes, AlphaRleMode::Rle, rle.len())?;
        encoded.put_slice(&rle);
        Ok(encoded.freeze())
    } else {
        encode_raw_from(width, height, decoded_bytes, sample_at)
    }
}

fn encode_raw_from(
    width: u32,
    height: u32,
    decoded_bytes: usize,
    sample_at: &impl Fn(usize) -> u8,
) -> Result<Bytes, AlphaRleError> {
    let mut encoded = encoded_prefix(
        width,
        height,
        decoded_bytes,
        AlphaRleMode::Raw,
        decoded_bytes,
    )?;
    for index in 0..decoded_bytes {
        encoded.put_u8(sample_at(index));
    }
    Ok(encoded.freeze())
}

fn encoded_prefix(
    width: u32,
    height: u32,
    decoded_bytes: usize,
    mode: AlphaRleMode,
    payload_bytes: usize,
) -> Result<BytesMut, AlphaRleError> {
    let mut encoded = BytesMut::with_capacity(
        ALPHA_RLE_HEADER_BYTES
            .checked_add(payload_bytes)
            .ok_or(AlphaRleError::SizeOverflow)?,
    );
    encoded.put_slice(MAGIC);
    encoded.put_u8(VERSION);
    encoded.put_u8(mode as u8);
    encoded.put_u16(0);
    encoded.put_u32(width);
    encoded.put_u32(height);
    encoded.put_u64(u64::try_from(decoded_bytes).map_err(|_| AlphaRleError::SizeOverflow)?);
    Ok(encoded)
}

/// Decodes one complete alpha payload after enforcing caller limits.
///
/// # Errors
///
/// Rejects malformed headers, a shape or encoded payload outside limits,
/// inconsistent decoded size, truncated/overflowing runs, and unconsumed
/// trailing bytes. Resource limits are checked before RLE output allocation.
pub fn decode_alpha_rle(
    mut encoded: Bytes,
    limits: AlphaRleLimits,
) -> Result<DecodedAlpha, AlphaRleError> {
    let (width, height, decoded_bytes, mode) = alpha_header(&mut encoded, limits)?;
    let samples = match mode {
        AlphaRleMode::Raw => {
            if encoded.len() != decoded_bytes {
                return Err(AlphaRleError::RawLengthMismatch);
            }
            encoded
        }
        AlphaRleMode::Rle => decode_rle_payload(encoded, decoded_bytes)?,
    };
    Ok(DecodedAlpha {
        width,
        height,
        samples,
    })
}

/// Validate all VFAR structure without allocating the expanded alpha plane.
/// Returns the checked dimensions; useful when forwarding to a local decoder.
///
/// # Errors
/// Rejects the same malformed headers, runs and resource overruns as decoding.
pub fn validate_alpha_rle(
    mut encoded: Bytes,
    limits: AlphaRleLimits,
) -> Result<(u32, u32), AlphaRleError> {
    let (width, height, decoded_bytes, mode) = alpha_header(&mut encoded, limits)?;
    if mode == AlphaRleMode::Raw {
        if encoded.len() != decoded_bytes {
            return Err(AlphaRleError::RawLengthMismatch);
        }
    } else {
        let mut produced = 0;
        while produced < decoded_bytes {
            if encoded.is_empty() {
                return Err(AlphaRleError::TruncatedRun);
            }
            let control = encoded.get_u8();
            let run = usize::from(control & 0x7f) + 1;
            if run > decoded_bytes - produced {
                return Err(AlphaRleError::OutputOverflow);
            }
            let consumed = if control & 0x80 != 0 { 1 } else { run };
            if encoded.len() < consumed {
                return Err(AlphaRleError::TruncatedRun);
            }
            encoded.advance(consumed);
            produced += run;
        }
        if !encoded.is_empty() {
            return Err(AlphaRleError::TrailingBytes);
        }
    }
    Ok((width, height))
}

/// Inspect a fully validated alpha payload without expanding its samples.
/// Savings include the encoded header and may be negative for raw mode.
///
/// # Errors
/// Rejects malformed payloads, caller-limit violations, and sizes that cannot
/// be represented by the signed savings counter.
pub fn profile_alpha_rle(
    encoded: Bytes,
    limits: AlphaRleLimits,
) -> Result<AlphaRleProfile, AlphaRleError> {
    validate_alpha_rle(encoded.clone(), limits)?;
    let encoded_bytes = encoded.len();
    let mut header = encoded;
    let (width, height, decoded_bytes, mode) = alpha_header(&mut header, limits)?;
    Ok(AlphaRleProfile {
        width,
        height,
        mode,
        decoded_bytes,
        encoded_bytes,
        savings_bytes: i64::try_from(decoded_bytes).map_err(|_| AlphaRleError::SizeOverflow)?
            - i64::try_from(encoded_bytes).map_err(|_| AlphaRleError::SizeOverflow)?,
    })
}

fn alpha_header(
    encoded: &mut Bytes,
    limits: AlphaRleLimits,
) -> Result<(u32, u32, usize, AlphaRleMode), AlphaRleError> {
    if encoded.len() < ALPHA_RLE_HEADER_BYTES {
        return Err(AlphaRleError::InvalidLength);
    }
    if encoded.len() > limits.max_encoded_bytes {
        return Err(AlphaRleError::ResourceLimit);
    }
    if &encoded[..4] != MAGIC {
        return Err(AlphaRleError::InvalidMagic);
    }
    encoded.advance(4);
    let version = encoded.get_u8();
    if version != VERSION {
        return Err(AlphaRleError::UnsupportedVersion(version));
    }
    let mode = AlphaRleMode::try_from(encoded.get_u8())?;
    if encoded.get_u16() != 0 {
        return Err(AlphaRleError::NonZeroReserved);
    }
    let width = encoded.get_u32();
    let height = encoded.get_u32();
    let declared_bytes = encoded.get_u64();
    let decoded_bytes = dimensions_bytes(width, height)?;
    if width > limits.max_coded_width
        || height > limits.max_coded_height
        || u64::try_from(decoded_bytes).map_err(|_| AlphaRleError::SizeOverflow)?
            > limits.max_luma_samples
        || u64::try_from(decoded_bytes).map_err(|_| AlphaRleError::SizeOverflow)?
            > limits.max_decoded_bytes
    {
        return Err(AlphaRleError::ResourceLimit);
    }
    if declared_bytes != u64::try_from(decoded_bytes).map_err(|_| AlphaRleError::SizeOverflow)? {
        return Err(AlphaRleError::DecodedLengthMismatch);
    }
    Ok((width, height, decoded_bytes, mode))
}

fn dimensions_bytes(width: u32, height: u32) -> Result<usize, AlphaRleError> {
    if width == 0 || height == 0 {
        return Err(AlphaRleError::InvalidDimensions);
    }
    let bytes = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or(AlphaRleError::SizeOverflow)?;
    usize::try_from(bytes).map_err(|_| AlphaRleError::SizeOverflow)
}

fn rle_payload(samples: &[u8]) -> Vec<u8> {
    rle_payload_from(samples.len(), &|index| samples[index])
}

fn has_repeat(length: usize, sample_at: &impl Fn(usize) -> u8) -> bool {
    if length < 3 {
        return false;
    }
    let mut prior = sample_at(0);
    let mut run = 1;
    for index in 1..length {
        let current = sample_at(index);
        if current == prior {
            run += 1;
            if run == 3 {
                return true;
            }
        } else {
            prior = current;
            run = 1;
        }
    }
    false
}

fn rle_payload_from(length: usize, sample_at: &impl Fn(usize) -> u8) -> Vec<u8> {
    let mut payload = Vec::with_capacity(length);
    let mut cursor = 0;
    while cursor < length {
        let repeat = repeated_len_from(length, cursor, sample_at);
        if repeat >= 3 {
            payload.push(0x80 | u8::try_from(repeat - 1).expect("run is at most 128"));
            payload.push(sample_at(cursor));
            cursor += repeat;
            continue;
        }
        let start = cursor;
        cursor += 1;
        while cursor < length && cursor - start < 128 {
            if repeated_len_from(length, cursor, sample_at) >= 3 {
                break;
            }
            cursor += 1;
        }
        let length = cursor - start;
        payload.push(u8::try_from(length - 1).expect("literal is at most 128"));
        for index in start..cursor {
            payload.push(sample_at(index));
        }
    }
    payload
}

fn repeated_len_from(length: usize, start: usize, sample_at: &impl Fn(usize) -> u8) -> usize {
    let value = sample_at(start);
    let mut end = start + 1;
    while end < length && end - start < 128 && sample_at(end) == value {
        end += 1;
    }
    end - start
}

fn decode_rle_payload(mut encoded: Bytes, decoded_bytes: usize) -> Result<Bytes, AlphaRleError> {
    let mut samples = BytesMut::with_capacity(decoded_bytes);
    while samples.len() < decoded_bytes {
        if encoded.is_empty() {
            return Err(AlphaRleError::TruncatedRun);
        }
        let control = encoded.get_u8();
        let run = usize::from(control & 0x7f) + 1;
        if run > decoded_bytes - samples.len() {
            return Err(AlphaRleError::OutputOverflow);
        }
        if control & 0x80 != 0 {
            if encoded.is_empty() {
                return Err(AlphaRleError::TruncatedRun);
            }
            let value = encoded.get_u8();
            samples.resize(samples.len() + run, value);
        } else {
            if encoded.len() < run {
                return Err(AlphaRleError::TruncatedRun);
            }
            samples.put_slice(&encoded.split_to(run));
        }
    }
    if !encoded.is_empty() {
        return Err(AlphaRleError::TrailingBytes);
    }
    Ok(samples.freeze())
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIMITS: AlphaRleLimits = AlphaRleLimits {
        max_coded_width: 8_192,
        max_coded_height: 8_192,
        max_luma_samples: 8_192 * 8_192,
        max_decoded_bytes: 8_192 * 8_192,
        max_encoded_bytes: 80 * 1024 * 1024,
    };

    fn round_trip(width: u32, height: u32, samples: &[u8]) -> Bytes {
        let encoded = encode_alpha_rle(width, height, samples).unwrap();
        let decoded = decode_alpha_rle(encoded.clone(), LIMITS).unwrap();
        assert_eq!(decoded.width, width);
        assert_eq!(decoded.height, height);
        assert_eq!(decoded.samples.as_ref(), samples);
        encoded
    }

    #[test]
    fn allocation_free_validation_matches_decoder_for_mutated_records() {
        for samples in [vec![42; 256], (0..=255).collect::<Vec<u8>>()] {
            let encoded = encode_alpha_rle(16, 16, &samples).unwrap();
            assert_eq!(
                validate_alpha_rle(encoded.clone(), LIMITS).unwrap(),
                (16, 16)
            );
            let agrees = |candidate: Bytes| {
                assert_eq!(
                    validate_alpha_rle(candidate.clone(), LIMITS),
                    decode_alpha_rle(candidate, LIMITS).map(|d| (d.width, d.height))
                );
            };
            for end in 0..encoded.len() {
                agrees(encoded.slice(..end));
            }
            for index in 0..encoded.len() {
                for value in [0, 1, 127, 128, 255] {
                    let mut changed = encoded.to_vec();
                    changed[index] = value;
                    agrees(changed.into());
                }
            }
            let mut trailing = encoded.to_vec();
            trailing.push(0);
            agrees(trailing.into());
        }
    }

    #[test]
    fn random_alpha_round_trips_in_raw_mode() {
        let mut state = 0x1234_5678_u32;
        let samples: Vec<_> = (0..4_096)
            .map(|_| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (state >> 24) as u8
            })
            .collect();
        let encoded = round_trip(64, 64, &samples);
        assert_eq!(encoded[5], AlphaRleMode::Raw as u8);
    }

    fn rgba_with_stride(samples: &[u8], width: usize, stride: usize) -> Vec<u8> {
        let height = samples.len() / width;
        let mut rgba = vec![0xa5; height * stride];
        for (index, &alpha) in samples.iter().enumerate() {
            let row = index / width;
            let column = index % width;
            let pixel = row * stride + column * 4;
            rgba[pixel..pixel + 4].copy_from_slice(&[17, 34, 51, alpha]);
        }
        rgba
    }

    #[test]
    fn direct_rgba_encoder_is_byte_identical_for_alpha_patterns_and_row_boundaries() {
        let mut random_state = 0x9e37_79b9_u32;
        let mut random = Vec::with_capacity(257 * 3);
        for _ in 0..257 * 3 {
            random_state = random_state
                .wrapping_mul(1_664_525)
                .wrapping_add(1_013_904_223);
            random.push((random_state >> 24) as u8);
        }
        let mut boundary = vec![11; 127];
        boundary.extend([12, 12, 12]);
        boundary.extend(vec![13; 128]);
        boundary.extend([14, 14]);
        boundary.extend(vec![15; 129]);
        for (width, height, samples) in [
            (257_u32, 3_u32, random),
            (2, 2, vec![255, 255, 255, 255]),
            (2, 2, vec![0, 0, 0, 0]),
            (389, 1, boundary),
        ] {
            assert_eq!(samples.len(), width as usize * height as usize);
            let rgba = rgba_with_stride(&samples, width as usize, width as usize * 4);
            assert_eq!(
                encode_rgba_alpha_rle(width, height, &rgba, width as usize * 4).unwrap(),
                encode_alpha_rle(width, height, &samples).unwrap(),
            );
        }
    }

    #[test]
    fn direct_rgba_encoder_skips_padding_and_rejects_invalid_shapes() {
        let samples = vec![0, 1, 2, 3, 4, 5];
        let rgba = rgba_with_stride(&samples, 3, 16);
        let encoded = encode_rgba_alpha_rle(3, 2, &rgba, 16).unwrap();
        assert_eq!(encoded, encode_alpha_rle(3, 2, &samples).unwrap());
        assert_eq!(
            encode_rgba_alpha_rle(3, 2, &rgba, 11),
            Err(AlphaRleError::InvalidRgbaStride)
        );
        assert_eq!(
            encode_rgba_alpha_rle(3, 2, &rgba[..rgba.len() - 1], 16),
            Err(AlphaRleError::RgbaLengthMismatch)
        );
        assert_eq!(
            encode_rgba_alpha_rle(u32::MAX, u32::MAX, &[], usize::MAX),
            Err(AlphaRleError::SizeOverflow)
        );
    }

    #[test]
    fn direct_rgba_encoder_profile_1936x1732() {
        use std::time::Instant;

        const WIDTH: u32 = 1936;
        const HEIGHT: u32 = 1732;
        const ITERATIONS: usize = 12;
        let pixels = WIDTH as usize * HEIGHT as usize;
        let samples: Vec<u8> = (0..pixels)
            .map(|index| {
                let x = index % WIDTH as usize;
                let y = index / WIDTH as usize;
                let edge = x
                    .min(y)
                    .min(WIDTH as usize - 1 - x)
                    .min(HEIGHT as usize - 1 - y);
                if edge >= 16 {
                    255
                } else {
                    u8::try_from(edge * 16).unwrap()
                }
            })
            .collect();
        let rgba = rgba_with_stride(&samples, WIDTH as usize, WIDTH as usize * 4);
        let mut baseline = std::time::Duration::ZERO;
        let mut direct = std::time::Duration::ZERO;
        for _ in 0..ITERATIONS {
            let started = Instant::now();
            let extracted: Vec<u8> = rgba.chunks_exact(4).map(|pixel| pixel[3]).collect();
            let old = encode_alpha_rle(WIDTH, HEIGHT, &extracted).unwrap();
            baseline += started.elapsed();

            let started = Instant::now();
            let fused = encode_rgba_alpha_rle(WIDTH, HEIGHT, &rgba, WIDTH as usize * 4).unwrap();
            direct += started.elapsed();
            assert_eq!(fused, old);
        }
        eprintln!(
            "direct-rgba-alpha-profile {}x{} iterations={} baseline_extract_plus_vfar_us={} direct_vfar_us={}",
            WIDTH,
            HEIGHT,
            ITERATIONS,
            baseline.as_micros() / ITERATIONS as u128,
            direct.as_micros() / ITERATIONS as u128,
        );
    }

    #[test]
    fn constant_alpha_round_trips_in_rle_mode() {
        let samples = vec![77; 4_096];
        let encoded = round_trip(64, 64, &samples);
        assert_eq!(encoded[5], AlphaRleMode::Rle as u8);
        assert!(encoded.len() < ALPHA_RLE_HEADER_BYTES + 4_096);
    }

    #[test]
    fn gradient_alpha_round_trips_without_precision_loss() {
        let samples: Vec<_> = (0..256).flat_map(|_| 0_u8..=255).collect();
        let encoded = round_trip(256, 256, &samples);
        assert_eq!(encoded[5], AlphaRleMode::Raw as u8);
    }

    #[test]
    fn malformed_bombs_are_rejected_before_output_allocation() {
        let mut encoded = encode_alpha_rle(8, 8, &[1; 64]).unwrap().to_vec();
        encoded[8..12].copy_from_slice(&16_384_u32.to_be_bytes());
        encoded[12..16].copy_from_slice(&16_384_u32.to_be_bytes());
        encoded[16..24].copy_from_slice(&(u64::from(16_384_u32) * 16_384).to_be_bytes());
        assert_eq!(
            decode_alpha_rle(Bytes::from(encoded), LIMITS),
            Err(AlphaRleError::ResourceLimit)
        );
    }

    #[test]
    fn malformed_streams_and_trailing_bytes_are_rejected() {
        let mut truncated = encode_alpha_rle(4, 1, &[1; 4]).unwrap().to_vec();
        truncated.truncate(ALPHA_RLE_HEADER_BYTES + 1);
        assert_eq!(
            decode_alpha_rle(Bytes::from(truncated), LIMITS),
            Err(AlphaRleError::TruncatedRun)
        );
        let mut trailing = encode_alpha_rle(4, 1, &[1; 4]).unwrap().to_vec();
        trailing.push(0);
        assert_eq!(
            decode_alpha_rle(Bytes::from(trailing), LIMITS),
            Err(AlphaRleError::TrailingBytes)
        );
    }
}
