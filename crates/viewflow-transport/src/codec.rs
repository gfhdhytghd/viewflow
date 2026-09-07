//! Separately negotiated video-codec descriptors.
//!
//! These fixed-size records deliberately do not alter the `VFMD` datagram
//! header. A peer exchanges and accepts a descriptor on a reliable control
//! path before using its `config_generation` in media. Frame identity and
//! geometry remain in `MediaDatagram`; [`FrameCodecMetadata`] only carries the
//! codec configuration generation and whether that individual access unit is
//! independently decodable.

use std::{error::Error, fmt};

use bytes::{Buf, BufMut, Bytes, BytesMut};
use viewflow_protocol::WindowId;

use crate::{MediaPlane, MediaPlaneFrame};

const DESCRIPTOR_MAGIC: &[u8; 4] = b"VFCD";
const FRAME_MAGIC: &[u8; 4] = b"VFCF";
const VERSION: u8 = 1;
/// Fixed descriptor size; a decoder rejects both truncation and extensions.
pub const CODEC_DESCRIPTOR_BYTES: usize = 36;
/// Fixed per-frame metadata size; a decoder rejects both truncation and extensions.
pub const FRAME_CODEC_METADATA_BYTES: usize = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum VideoCodec {
    RawBgra = 1,
    H264 = 2,
    /// Lossless independently intra-coded 8-bit alpha; see `VFAR`.
    LosslessAlpha = 3,
    /// AV1 Main 8-bit color in low-overhead OBU access units.
    Av1 = 4,
}

impl TryFrom<u8> for VideoCodec {
    type Error = CodecDescriptorError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::RawBgra),
            2 => Ok(Self::H264),
            3 => Ok(Self::LosslessAlpha),
            4 => Ok(Self::Av1),
            _ => Err(CodecDescriptorError::UnknownCodec(value)),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum VideoPlaneRole {
    Color = 1,
    Alpha = 2,
}

impl TryFrom<u8> for VideoPlaneRole {
    type Error = CodecDescriptorError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Color),
            2 => Ok(Self::Alpha),
            _ => Err(CodecDescriptorError::UnknownPlaneRole(value)),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum CodedPixelFormat {
    /// Premultiplied BGRA8; valid only for the raw fallback color plane.
    Bgra8Premultiplied = 1,
    /// 4:2:0 8-bit YUV; valid only for H.264 color.
    Nv12 = 2,
    /// Full-resolution 8-bit YUV; valid only for the H.264 alpha carrier.
    Yuv444p = 3,
    /// Straight 8-bit samples; valid only for `LosslessAlpha` alpha.
    Gray8 = 4,
}

impl TryFrom<u8> for CodedPixelFormat {
    type Error = CodecDescriptorError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Bgra8Premultiplied),
            2 => Ok(Self::Nv12),
            3 => Ok(Self::Yuv444p),
            4 => Ok(Self::Gray8),
            _ => Err(CodecDescriptorError::UnknownPixelFormat(value)),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Colorimetry {
    Srgb = 1,
    Bt709Limited = 2,
    /// Full-range opacity samples for an alpha plane; not a color transfer function.
    AlphaFullRange = 3,
}

impl TryFrom<u8> for Colorimetry {
    type Error = CodecDescriptorError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Srgb),
            2 => Ok(Self::Bt709Limited),
            3 => Ok(Self::AlphaFullRange),
            _ => Err(CodecDescriptorError::UnknownColorimetry(value)),
        }
    }
}

/// How a decoder/compositor must interpret the color and alpha outputs.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum AlphaInterpretation {
    /// Color samples already contain premultiplied source alpha.
    PremultipliedEmbedded = 1,
    /// Color samples are straight/unassociated and require the paired alpha plane.
    StraightWithExternalPlane = 2,
    /// The luma samples of the declared YUV carrier are paired full-range alpha;
    /// chroma is neutral and must not be interpreted as color.
    AlphaPlane = 3,
}

impl TryFrom<u8> for AlphaInterpretation {
    type Error = CodecDescriptorError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::PremultipliedEmbedded),
            2 => Ok(Self::StraightWithExternalPlane),
            3 => Ok(Self::AlphaPlane),
            _ => Err(CodecDescriptorError::UnknownAlphaInterpretation(value)),
        }
    }
}

/// One reliable session configuration for one media plane.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodecDescriptor {
    pub codec: VideoCodec,
    pub plane: VideoPlaneRole,
    pub pixel_format: CodedPixelFormat,
    pub colorimetry: Colorimetry,
    pub alpha_interpretation: AlphaInterpretation,
    pub coded_width: u32,
    pub coded_height: u32,
    /// Must equal every associated `MediaDatagram::geometry_epoch`.
    pub geometry_epoch: u64,
    /// New decoder configuration or coded geometry requires a new nonzero value.
    pub config_generation: u64,
}

/// Caller/backend resource limits, deliberately separate from the wire shape.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodecResourceLimits {
    pub max_coded_width: u32,
    pub max_coded_height: u32,
    pub max_luma_samples: u64,
    pub max_decoded_bytes: u64,
}

/// Checked decoded allocation requirements for an accepted coded shape.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodecShape {
    pub luma_samples: u64,
    pub decoded_bytes: u64,
}

/// Whether an explicitly negotiated H.264 session may omit alpha for an
/// entirely opaque frame. The default is always paired alpha.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum AlphaPlanePolicy {
    #[default]
    Required,
    OpaqueMayOmit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodecSessionPolicy {
    pub alpha_plane: AlphaPlanePolicy,
}

impl Default for CodecSessionPolicy {
    fn default() -> Self {
        Self {
            alpha_plane: AlphaPlanePolicy::Required,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodecFrameAdmission {
    pub frame_id: u64,
    pub config_generation: u64,
    /// True only when both independently encoded planes were IDR/keyframes.
    pub paired_keyframe: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ActiveCodecPair {
    color: CodecDescriptor,
    alpha: CodecDescriptor,
}

/// Backend-facing configuration and access-unit gate. It does not invoke a
/// codec, allocate a decoded surface, or alter the existing `VFMD` wire.
#[derive(Debug)]
pub struct CodecSession {
    policy: CodecSessionPolicy,
    active: Option<ActiveCodecPair>,
    paired_keyframe_required: bool,
    alpha_keyframe_required: bool,
    last_frame_id: Option<u64>,
    window_id: Option<WindowId>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodecSessionError {
    Descriptor(CodecDescriptorError),
    PairMismatch,
    StaleConfiguration,
    GeometryEpochRegression,
    CombinedResourceLimit,
    NoActiveConfiguration,
    AlphaRequired,
    WindowMismatch,
    FrameIdMismatch,
    SourceTimestampMismatch,
    StaleFrame,
    PairedKeyframeRequired,
    AlphaKeyframeRequired,
}

impl fmt::Display for CodecSessionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "codec session error: {self:?}")
    }
}

impl Error for CodecSessionError {}

impl From<CodecDescriptorError> for CodecSessionError {
    fn from(value: CodecDescriptorError) -> Self {
        Self::Descriptor(value)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodecDescriptorError {
    InvalidLength,
    InvalidMagic,
    UnsupportedVersion(u8),
    NonZeroReserved,
    UnknownCodec(u8),
    UnknownPlaneRole(u8),
    UnknownPixelFormat(u8),
    UnknownColorimetry(u8),
    UnknownAlphaInterpretation(u8),
    InvalidDimensions,
    ZeroGeometryEpoch,
    ZeroConfigGeneration,
    InvalidCombination,
    UnsupportedAlignment,
    ResourceLimit,
    SizeOverflow,
    InvalidFrameFlags,
    GeometryEpochMismatch,
    ConfigGenerationMismatch,
    PlaneMismatch,
}

impl fmt::Display for CodecDescriptorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "codec descriptor error: {self:?}")
    }
}

impl Error for CodecDescriptorError {}

impl CodecDescriptor {
    /// # Errors
    ///
    /// Rejects zero dimensions/generations and ambiguous codec-plane contracts.
    pub fn validate(self) -> Result<(), CodecDescriptorError> {
        if self.coded_width == 0 || self.coded_height == 0 {
            return Err(CodecDescriptorError::InvalidDimensions);
        }
        if matches!(self.codec, VideoCodec::H264 | VideoCodec::Av1)
            && (self.coded_width % 2 != 0 || self.coded_height % 2 != 0)
        {
            return Err(CodecDescriptorError::UnsupportedAlignment);
        }
        if self.geometry_epoch == 0 {
            return Err(CodecDescriptorError::ZeroGeometryEpoch);
        }
        if self.config_generation == 0 {
            return Err(CodecDescriptorError::ZeroConfigGeneration);
        }
        let valid = matches!(
            (
                self.codec,
                self.plane,
                self.pixel_format,
                self.colorimetry,
                self.alpha_interpretation,
            ),
            (
                VideoCodec::RawBgra,
                VideoPlaneRole::Color,
                CodedPixelFormat::Bgra8Premultiplied,
                Colorimetry::Srgb,
                AlphaInterpretation::PremultipliedEmbedded,
            ) | (
                VideoCodec::H264 | VideoCodec::Av1,
                VideoPlaneRole::Color,
                CodedPixelFormat::Nv12,
                Colorimetry::Bt709Limited,
                AlphaInterpretation::StraightWithExternalPlane,
            ) | (
                VideoCodec::H264,
                VideoPlaneRole::Alpha,
                CodedPixelFormat::Yuv444p,
                Colorimetry::AlphaFullRange,
                AlphaInterpretation::AlphaPlane,
            ) | (
                VideoCodec::LosslessAlpha,
                VideoPlaneRole::Alpha,
                CodedPixelFormat::Gray8,
                Colorimetry::AlphaFullRange,
                AlphaInterpretation::AlphaPlane,
            )
        );
        if valid {
            Ok(())
        } else {
            Err(CodecDescriptorError::InvalidCombination)
        }
    }

    /// Applies caller-selected allocation/resource policy after wire decoding.
    ///
    /// # Errors
    ///
    /// Rejects shapes outside the caller's limits or whose checked decoded
    /// storage calculation overflows. Hardware capability checks remain a
    /// backend responsibility.
    pub fn validate_shape(
        self,
        limits: CodecResourceLimits,
    ) -> Result<CodecShape, CodecDescriptorError> {
        self.validate()?;
        if self.coded_width > limits.max_coded_width || self.coded_height > limits.max_coded_height
        {
            return Err(CodecDescriptorError::ResourceLimit);
        }
        let luma_samples = u64::from(self.coded_width)
            .checked_mul(u64::from(self.coded_height))
            .ok_or(CodecDescriptorError::SizeOverflow)?;
        if luma_samples > limits.max_luma_samples {
            return Err(CodecDescriptorError::ResourceLimit);
        }
        let decoded_bytes = match self.pixel_format {
            CodedPixelFormat::Bgra8Premultiplied => luma_samples.checked_mul(4),
            CodedPixelFormat::Nv12 => luma_samples
                .checked_mul(3)
                .and_then(|bytes| bytes.checked_div(2)),
            CodedPixelFormat::Yuv444p => luma_samples.checked_mul(3),
            CodedPixelFormat::Gray8 => Some(luma_samples),
        }
        .ok_or(CodecDescriptorError::SizeOverflow)?;
        if decoded_bytes > limits.max_decoded_bytes {
            return Err(CodecDescriptorError::ResourceLimit);
        }
        Ok(CodecShape {
            luma_samples,
            decoded_bytes,
        })
    }

    /// Canonically encodes this reliable descriptor.
    ///
    /// # Errors
    ///
    /// Returns validation errors without producing any bytes.
    pub fn encode(self) -> Result<Bytes, CodecDescriptorError> {
        self.validate()?;
        let mut bytes = BytesMut::with_capacity(CODEC_DESCRIPTOR_BYTES);
        bytes.put_slice(DESCRIPTOR_MAGIC);
        bytes.put_u8(VERSION);
        bytes.put_u8(self.codec as u8);
        bytes.put_u8(self.plane as u8);
        bytes.put_u8(self.pixel_format as u8);
        bytes.put_u8(self.colorimetry as u8);
        bytes.put_u8(self.alpha_interpretation as u8);
        bytes.put_u16(0);
        bytes.put_u32(self.coded_width);
        bytes.put_u32(self.coded_height);
        bytes.put_u64(self.geometry_epoch);
        bytes.put_u64(self.config_generation);
        debug_assert_eq!(bytes.len(), CODEC_DESCRIPTOR_BYTES);
        Ok(bytes.freeze())
    }

    /// Decodes a fixed-size canonical descriptor received on a reliable path.
    ///
    /// # Errors
    ///
    /// Rejects any unknown enum, nonzero reserved byte, extension, or invalid contract.
    pub fn decode(mut bytes: Bytes) -> Result<Self, CodecDescriptorError> {
        if bytes.len() != CODEC_DESCRIPTOR_BYTES {
            return Err(CodecDescriptorError::InvalidLength);
        }
        if &bytes[..4] != DESCRIPTOR_MAGIC {
            return Err(CodecDescriptorError::InvalidMagic);
        }
        bytes.advance(4);
        let version = bytes.get_u8();
        if version != VERSION {
            return Err(CodecDescriptorError::UnsupportedVersion(version));
        }
        let descriptor = Self {
            codec: VideoCodec::try_from(bytes.get_u8())?,
            plane: VideoPlaneRole::try_from(bytes.get_u8())?,
            pixel_format: CodedPixelFormat::try_from(bytes.get_u8())?,
            colorimetry: Colorimetry::try_from(bytes.get_u8())?,
            alpha_interpretation: AlphaInterpretation::try_from(bytes.get_u8())?,
            coded_width: {
                if bytes.get_u16() != 0 {
                    return Err(CodecDescriptorError::NonZeroReserved);
                }
                bytes.get_u32()
            },
            coded_height: bytes.get_u32(),
            geometry_epoch: bytes.get_u64(),
            config_generation: bytes.get_u64(),
        };
        descriptor.validate()?;
        Ok(descriptor)
    }

    /// # Errors
    ///
    /// Rejects a media plane, geometry epoch, or codec generation that differs
    /// from this already accepted reliable session configuration.
    pub fn validate_frame(
        self,
        frame: &MediaPlaneFrame,
        metadata: FrameCodecMetadata,
    ) -> Result<(), CodecDescriptorError> {
        let expected_plane = match self.plane {
            VideoPlaneRole::Color => MediaPlane::Color,
            VideoPlaneRole::Alpha => MediaPlane::Alpha,
        };
        if frame.plane != expected_plane {
            return Err(CodecDescriptorError::PlaneMismatch);
        }
        if frame.geometry_epoch != self.geometry_epoch {
            return Err(CodecDescriptorError::GeometryEpochMismatch);
        }
        if metadata.config_generation != self.config_generation {
            return Err(CodecDescriptorError::ConfigGenerationMismatch);
        }
        Ok(())
    }
}

impl CodecSession {
    #[must_use]
    pub const fn new(policy: CodecSessionPolicy) -> Self {
        Self {
            policy,
            active: None,
            paired_keyframe_required: true,
            alpha_keyframe_required: false,
            last_frame_id: None,
            window_id: None,
        }
    }

    /// Atomically accepts one H.264 color configuration and either supported
    /// alpha configuration.
    ///
    /// # Errors
    ///
    /// Rejects a malformed, mismatched, stale, or over-budget pair without
    /// changing the currently active configuration or frame watermarks.
    pub fn accept_descriptors(
        &mut self,
        color: CodecDescriptor,
        alpha: CodecDescriptor,
        limits: CodecResourceLimits,
    ) -> Result<(), CodecSessionError> {
        let color_shape = color.validate_shape(limits)?;
        let alpha_shape = alpha.validate_shape(limits)?;
        if !matches!(color.codec, VideoCodec::H264 | VideoCodec::Av1)
            || !matches!(alpha.codec, VideoCodec::H264 | VideoCodec::LosslessAlpha)
            || color.plane != VideoPlaneRole::Color
            || alpha.plane != VideoPlaneRole::Alpha
            || color.coded_width != alpha.coded_width
            || color.coded_height != alpha.coded_height
            || color.geometry_epoch != alpha.geometry_epoch
            || color.config_generation != alpha.config_generation
        {
            return Err(CodecSessionError::PairMismatch);
        }
        let combined_bytes = color_shape
            .decoded_bytes
            .checked_add(alpha_shape.decoded_bytes)
            .ok_or(CodecDescriptorError::SizeOverflow)?;
        if combined_bytes > limits.max_decoded_bytes {
            return Err(CodecSessionError::CombinedResourceLimit);
        }
        if self
            .active
            .is_some_and(|active| color.config_generation <= active.color.config_generation)
        {
            return Err(CodecSessionError::StaleConfiguration);
        }
        if self
            .active
            .is_some_and(|active| color.geometry_epoch < active.color.geometry_epoch)
        {
            return Err(CodecSessionError::GeometryEpochRegression);
        }

        self.active = Some(ActiveCodecPair { color, alpha });
        self.paired_keyframe_required = true;
        self.alpha_keyframe_required = false;
        self.last_frame_id = None;
        Ok(())
    }

    /// Validates an already reassembled media pair against active configuration.
    ///
    /// `alpha` is absent only under explicit [`AlphaPlanePolicy::OpaqueMayOmit`].
    /// A configuration/recovery boundary always needs both independent IDRs.
    /// Following an omitted-alpha frame, alpha must resume with its own IDR;
    /// this alpha-only recovery does not make the color frame a paired keyframe.
    ///
    /// # Errors
    ///
    /// Rejects stale/mismatched frames and recovery violations without changing
    /// active configuration or frame watermarks.
    pub fn accept_frame(
        &mut self,
        color: &MediaPlaneFrame,
        color_metadata: FrameCodecMetadata,
        alpha: Option<(&MediaPlaneFrame, FrameCodecMetadata)>,
    ) -> Result<CodecFrameAdmission, CodecSessionError> {
        let active = self
            .active
            .ok_or(CodecSessionError::NoActiveConfiguration)?;
        active.color.validate_frame(color, color_metadata)?;
        if self
            .window_id
            .is_some_and(|window| color.window_id != window)
        {
            return Err(CodecSessionError::WindowMismatch);
        }
        if self
            .last_frame_id
            .is_some_and(|last| color.frame_id <= last)
        {
            return Err(CodecSessionError::StaleFrame);
        }

        let alpha_keyframe = if let Some((frame, metadata)) = alpha {
            active.alpha.validate_frame(frame, metadata)?;
            if frame.window_id != color.window_id {
                return Err(CodecSessionError::WindowMismatch);
            }
            if frame.frame_id != color.frame_id {
                return Err(CodecSessionError::FrameIdMismatch);
            }
            if frame.source_submitted_ns != color.source_submitted_ns {
                return Err(CodecSessionError::SourceTimestampMismatch);
            }
            metadata.keyframe
        } else {
            if self.policy.alpha_plane != AlphaPlanePolicy::OpaqueMayOmit {
                return Err(CodecSessionError::AlphaRequired);
            }
            false
        };
        if self.paired_keyframe_required && (!color_metadata.keyframe || !alpha_keyframe) {
            return Err(CodecSessionError::PairedKeyframeRequired);
        }
        if self.alpha_keyframe_required && alpha.is_some() && !alpha_keyframe {
            return Err(CodecSessionError::AlphaKeyframeRequired);
        }

        let admitted = CodecFrameAdmission {
            frame_id: color.frame_id,
            config_generation: active.color.config_generation,
            paired_keyframe: color_metadata.keyframe && alpha_keyframe,
        };
        self.paired_keyframe_required = false;
        self.alpha_keyframe_required = alpha.is_none();
        self.last_frame_id = Some(color.frame_id);
        self.window_id = Some(color.window_id);
        Ok(admitted)
    }
}

/// Per-access-unit state, intentionally separate from the reliable session descriptor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FrameCodecMetadata {
    pub config_generation: u64,
    pub keyframe: bool,
}

impl FrameCodecMetadata {
    /// # Errors
    ///
    /// Rejects a zero configuration generation.
    pub fn encode(self) -> Result<Bytes, CodecDescriptorError> {
        if self.config_generation == 0 {
            return Err(CodecDescriptorError::ZeroConfigGeneration);
        }
        let mut bytes = BytesMut::with_capacity(FRAME_CODEC_METADATA_BYTES);
        bytes.put_slice(FRAME_MAGIC);
        bytes.put_u8(VERSION);
        bytes.put_u8(u8::from(self.keyframe));
        bytes.put_u16(0);
        bytes.put_u64(self.config_generation);
        debug_assert_eq!(bytes.len(), FRAME_CODEC_METADATA_BYTES);
        Ok(bytes.freeze())
    }

    /// # Errors
    ///
    /// Rejects extensions, unknown flags, reserved bytes, or a zero generation.
    pub fn decode(mut bytes: Bytes) -> Result<Self, CodecDescriptorError> {
        if bytes.len() != FRAME_CODEC_METADATA_BYTES {
            return Err(CodecDescriptorError::InvalidLength);
        }
        if &bytes[..4] != FRAME_MAGIC {
            return Err(CodecDescriptorError::InvalidMagic);
        }
        bytes.advance(4);
        let version = bytes.get_u8();
        if version != VERSION {
            return Err(CodecDescriptorError::UnsupportedVersion(version));
        }
        let flags = bytes.get_u8();
        if flags & !1 != 0 {
            return Err(CodecDescriptorError::InvalidFrameFlags);
        }
        if bytes.get_u16() != 0 {
            return Err(CodecDescriptorError::NonZeroReserved);
        }
        let result = Self {
            config_generation: bytes.get_u64(),
            keyframe: flags & 1 != 0,
        };
        if result.config_generation == 0 {
            return Err(CodecDescriptorError::ZeroConfigGeneration);
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MediaPlane, MediaPlaneFrame};

    const RAW: CodecDescriptor = CodecDescriptor {
        codec: VideoCodec::RawBgra,
        plane: VideoPlaneRole::Color,
        pixel_format: CodedPixelFormat::Bgra8Premultiplied,
        colorimetry: Colorimetry::Srgb,
        alpha_interpretation: AlphaInterpretation::PremultipliedEmbedded,
        coded_width: 778,
        coded_height: 650,
        geometry_epoch: 7,
        config_generation: 11,
    };

    #[test]
    fn raw_descriptor_round_trips_canonically() {
        let bytes = RAW.encode().unwrap();
        assert_eq!(bytes.len(), CODEC_DESCRIPTOR_BYTES);
        assert_eq!(CodecDescriptor::decode(bytes).unwrap(), RAW);
    }

    #[test]
    fn decoded_storage_limits_are_exact_and_overflow_safe() {
        let mut limits = CodecResourceLimits {
            max_coded_width: u32::MAX,
            max_coded_height: u32::MAX,
            max_luma_samples: u64::MAX,
            max_decoded_bytes: u64::MAX,
        };
        let required = u64::from(RAW.coded_width) * u64::from(RAW.coded_height) * 4;
        limits.max_decoded_bytes = required;
        assert_eq!(RAW.validate_shape(limits).unwrap().decoded_bytes, required);
        limits.max_decoded_bytes -= 1;
        assert_eq!(
            RAW.validate_shape(limits),
            Err(CodecDescriptorError::ResourceLimit)
        );
        limits.max_decoded_bytes = u64::MAX;
        let huge = CodecDescriptor {
            coded_width: u32::MAX,
            coded_height: u32::MAX,
            ..RAW
        };
        // Wire metadata is valid without allocating pixels, but decoded RGBA
        // storage cannot be represented and must be rejected before allocation.
        assert!(huge.encode().is_ok());
        assert_eq!(
            huge.validate_shape(limits),
            Err(CodecDescriptorError::SizeOverflow)
        );
    }

    #[test]
    fn h264_color_and_alpha_descriptors_are_unambiguous() {
        let color = CodecDescriptor {
            codec: VideoCodec::H264,
            plane: VideoPlaneRole::Color,
            pixel_format: CodedPixelFormat::Nv12,
            colorimetry: Colorimetry::Bt709Limited,
            alpha_interpretation: AlphaInterpretation::StraightWithExternalPlane,
            ..RAW
        };
        let alpha = CodecDescriptor {
            plane: VideoPlaneRole::Alpha,
            pixel_format: CodedPixelFormat::Yuv444p,
            colorimetry: Colorimetry::AlphaFullRange,
            alpha_interpretation: AlphaInterpretation::AlphaPlane,
            ..color
        };
        assert_eq!(
            CodecDescriptor::decode(color.encode().unwrap()).unwrap(),
            color
        );
        assert_eq!(
            CodecDescriptor::decode(alpha.encode().unwrap()).unwrap(),
            alpha
        );
    }

    #[test]
    fn av1_color_roundtrips_with_lossless_alpha_but_is_not_an_alpha_codec() {
        let color = CodecDescriptor {
            codec: VideoCodec::Av1,
            plane: VideoPlaneRole::Color,
            pixel_format: CodedPixelFormat::Nv12,
            colorimetry: Colorimetry::Bt709Limited,
            alpha_interpretation: AlphaInterpretation::StraightWithExternalPlane,
            ..RAW
        };
        assert_eq!(
            CodecDescriptor::decode(color.encode().unwrap()).unwrap(),
            color
        );
        let alpha = CodecDescriptor {
            codec: VideoCodec::LosslessAlpha,
            plane: VideoPlaneRole::Alpha,
            pixel_format: CodedPixelFormat::Gray8,
            colorimetry: Colorimetry::AlphaFullRange,
            alpha_interpretation: AlphaInterpretation::AlphaPlane,
            ..RAW
        };
        assert!(alpha.validate().is_ok());
        assert!(
            CodecDescriptor {
                codec: VideoCodec::Av1,
                ..alpha
            }
            .validate()
            .is_err()
        );
        assert!(
            CodecDescriptor {
                coded_width: 3,
                ..color
            }
            .validate()
            .is_err()
        );
    }

    #[test]
    fn rejects_extensions_reserved_unknowns_and_ambiguous_alpha() {
        let mut bytes = RAW.encode().unwrap().to_vec();
        bytes.push(0);
        assert_eq!(
            CodecDescriptor::decode(bytes.into()),
            Err(CodecDescriptorError::InvalidLength)
        );
        let mut bytes = RAW.encode().unwrap().to_vec();
        bytes[10] = 1;
        assert_eq!(
            CodecDescriptor::decode(bytes.into()),
            Err(CodecDescriptorError::NonZeroReserved)
        );
        let mut bytes = RAW.encode().unwrap().to_vec();
        bytes[5] = 99;
        assert_eq!(
            CodecDescriptor::decode(bytes.into()),
            Err(CodecDescriptorError::UnknownCodec(99))
        );
        let invalid = CodecDescriptor {
            alpha_interpretation: AlphaInterpretation::StraightWithExternalPlane,
            ..RAW
        };
        assert_eq!(
            invalid.validate(),
            Err(CodecDescriptorError::InvalidCombination)
        );
        assert_eq!(
            CodecDescriptor {
                coded_width: 65_536,
                ..RAW
            }
            .validate(),
            Ok(())
        );
        let oversized = CodecDescriptor {
            coded_width: 65_536,
            ..RAW
        };
        assert_eq!(
            CodecDescriptor::decode(oversized.encode().unwrap()).unwrap(),
            oversized
        );
        assert_eq!(
            oversized.validate_shape(CodecResourceLimits {
                max_coded_width: 32_768,
                max_coded_height: 32_768,
                max_luma_samples: u64::MAX,
                max_decoded_bytes: u64::MAX,
            }),
            Err(CodecDescriptorError::ResourceLimit)
        );
    }

    #[test]
    fn frame_metadata_is_distinct_and_binds_generation_and_geometry() {
        let metadata = FrameCodecMetadata {
            config_generation: 11,
            keyframe: true,
        };
        assert_eq!(
            FrameCodecMetadata::decode(metadata.encode().unwrap()).unwrap(),
            metadata
        );
        let frame = MediaPlaneFrame {
            window_id: viewflow_protocol::Id128(1),
            frame_id: 4,
            geometry_epoch: 7,
            plane: MediaPlane::Color,
            source_submitted_ns: 1,
            payload: Bytes::from_static(b"access-unit"),
        };
        RAW.validate_frame(&frame, metadata).unwrap();
        assert_eq!(
            RAW.validate_frame(
                &MediaPlaneFrame {
                    geometry_epoch: 8,
                    ..frame.clone()
                },
                metadata
            ),
            Err(CodecDescriptorError::GeometryEpochMismatch)
        );
        assert_eq!(
            RAW.validate_frame(
                &frame,
                FrameCodecMetadata {
                    config_generation: 12,
                    keyframe: false
                }
            ),
            Err(CodecDescriptorError::ConfigGenerationMismatch)
        );
        let mut bytes = metadata.encode().unwrap().to_vec();
        bytes[5] = 2;
        assert_eq!(
            FrameCodecMetadata::decode(bytes.into()),
            Err(CodecDescriptorError::InvalidFrameFlags)
        );
    }

    fn limits(bytes: u64) -> CodecResourceLimits {
        CodecResourceLimits {
            max_coded_width: u32::MAX,
            max_coded_height: u32::MAX,
            max_luma_samples: u64::MAX,
            max_decoded_bytes: bytes,
        }
    }

    fn h264_pair(generation: u64, epoch: u64) -> (CodecDescriptor, CodecDescriptor) {
        let color = CodecDescriptor {
            codec: VideoCodec::H264,
            plane: VideoPlaneRole::Color,
            pixel_format: CodedPixelFormat::Nv12,
            colorimetry: Colorimetry::Bt709Limited,
            alpha_interpretation: AlphaInterpretation::StraightWithExternalPlane,
            coded_width: 4,
            coded_height: 2,
            geometry_epoch: epoch,
            config_generation: generation,
        };
        let alpha = CodecDescriptor {
            plane: VideoPlaneRole::Alpha,
            pixel_format: CodedPixelFormat::Yuv444p,
            colorimetry: Colorimetry::AlphaFullRange,
            alpha_interpretation: AlphaInterpretation::AlphaPlane,
            ..color
        };
        (color, alpha)
    }

    fn lossless_alpha_pair(generation: u64, epoch: u64) -> (CodecDescriptor, CodecDescriptor) {
        let (color, _) = h264_pair(generation, epoch);
        let alpha = CodecDescriptor {
            codec: VideoCodec::LosslessAlpha,
            plane: VideoPlaneRole::Alpha,
            pixel_format: CodedPixelFormat::Gray8,
            colorimetry: Colorimetry::AlphaFullRange,
            alpha_interpretation: AlphaInterpretation::AlphaPlane,
            ..color
        };
        (color, alpha)
    }

    fn media(frame_id: u64, epoch: u64, plane: MediaPlane) -> MediaPlaneFrame {
        MediaPlaneFrame {
            window_id: viewflow_protocol::Id128(1),
            frame_id,
            geometry_epoch: epoch,
            plane,
            source_submitted_ns: 1,
            payload: Bytes::from_static(b"access-unit"),
        }
    }

    fn metadata(generation: u64, keyframe: bool) -> FrameCodecMetadata {
        FrameCodecMetadata {
            config_generation: generation,
            keyframe,
        }
    }

    #[test]
    fn session_rejects_mismatched_pair_without_replacing_active_configuration() {
        let (color, alpha) = h264_pair(2, 3);
        let mut session = CodecSession::new(CodecSessionPolicy::default());
        session
            .accept_descriptors(color, alpha, limits(36))
            .unwrap();
        let (next_color, mut next_alpha) = h264_pair(3, 4);
        next_alpha.coded_height = 4;
        assert_eq!(
            session.accept_descriptors(next_color, next_alpha, limits(48)),
            Err(CodecSessionError::PairMismatch)
        );
        assert!(matches!(
            session.accept_frame(
                &media(1, 3, MediaPlane::Color),
                metadata(2, true),
                Some((&media(1, 3, MediaPlane::Alpha), metadata(2, true))),
            ),
            Ok(CodecFrameAdmission {
                config_generation: 2,
                ..
            })
        ));
    }

    #[test]
    fn session_rejects_combined_limit_and_stale_configuration() {
        let (color, alpha) = h264_pair(2, 3);
        let mut session = CodecSession::new(CodecSessionPolicy::default());
        // NV12(4x2)=12 plus YUV444P(4x2)=24.
        assert_eq!(
            session.accept_descriptors(color, alpha, limits(35)),
            Err(CodecSessionError::CombinedResourceLimit)
        );
        session
            .accept_descriptors(color, alpha, limits(36))
            .unwrap();
        assert_eq!(
            session.accept_descriptors(color, alpha, limits(36)),
            Err(CodecSessionError::StaleConfiguration)
        );
    }

    #[test]
    fn session_accepts_h264_color_with_lossless_gray8_alpha() {
        let (color, alpha) = lossless_alpha_pair(2, 3);
        assert_eq!(alpha.validate_shape(limits(8)).unwrap().decoded_bytes, 8);
        let mut session = CodecSession::new(CodecSessionPolicy::default());
        // NV12(4x2)=12 plus lossless Gray8(4x2)=8.
        session
            .accept_descriptors(color, alpha, limits(20))
            .unwrap();
        let admitted = session
            .accept_frame(
                &media(1, 3, MediaPlane::Color),
                metadata(2, true),
                Some((&media(1, 3, MediaPlane::Alpha), metadata(2, true))),
            )
            .unwrap();
        assert!(admitted.paired_keyframe);
    }

    #[test]
    fn session_requires_paired_idr_then_rejects_replay() {
        let (color_descriptor, alpha_descriptor) = h264_pair(2, 3);
        let mut session = CodecSession::new(CodecSessionPolicy::default());
        session
            .accept_descriptors(color_descriptor, alpha_descriptor, limits(36))
            .unwrap();
        let color = media(1, 3, MediaPlane::Color);
        let alpha = media(1, 3, MediaPlane::Alpha);
        assert_eq!(
            session.accept_frame(
                &color,
                metadata(2, true),
                Some((&alpha, metadata(2, false))),
            ),
            Err(CodecSessionError::PairedKeyframeRequired)
        );
        let admitted = session
            .accept_frame(&color, metadata(2, true), Some((&alpha, metadata(2, true))))
            .unwrap();
        assert!(admitted.paired_keyframe);
        assert_eq!(
            session.accept_frame(&color, metadata(2, true), Some((&alpha, metadata(2, true))),),
            Err(CodecSessionError::StaleFrame)
        );
    }

    #[test]
    fn opaque_omission_requires_explicit_policy_and_alpha_recovers_independently() {
        let (color_descriptor, alpha_descriptor) = h264_pair(2, 3);
        let mut session = CodecSession::new(CodecSessionPolicy {
            alpha_plane: AlphaPlanePolicy::OpaqueMayOmit,
        });
        session
            .accept_descriptors(color_descriptor, alpha_descriptor, limits(36))
            .unwrap();
        let first_color = media(1, 3, MediaPlane::Color);
        let first_alpha = media(1, 3, MediaPlane::Alpha);
        session
            .accept_frame(
                &first_color,
                metadata(2, true),
                Some((&first_alpha, metadata(2, true))),
            )
            .unwrap();
        let opaque = media(2, 3, MediaPlane::Color);
        assert!(
            !session
                .accept_frame(&opaque, metadata(2, false), None)
                .unwrap()
                .paired_keyframe
        );
        let color = media(3, 3, MediaPlane::Color);
        let alpha = media(3, 3, MediaPlane::Alpha);
        assert_eq!(
            session.accept_frame(
                &color,
                metadata(2, false),
                Some((&alpha, metadata(2, false))),
            ),
            Err(CodecSessionError::AlphaKeyframeRequired)
        );
        let admitted = session
            .accept_frame(
                &color,
                metadata(2, false),
                Some((&alpha, metadata(2, true))),
            )
            .unwrap();
        assert!(!admitted.paired_keyframe);
    }

    #[test]
    fn session_rejects_cross_window_or_timestamp_pair_without_consuming_retry() {
        let (color_descriptor, alpha_descriptor) = h264_pair(2, 3);
        let mut session = CodecSession::new(CodecSessionPolicy::default());
        session
            .accept_descriptors(color_descriptor, alpha_descriptor, limits(36))
            .unwrap();
        let color = media(1, 3, MediaPlane::Color);
        let mut wrong_window = media(1, 3, MediaPlane::Alpha);
        wrong_window.window_id = viewflow_protocol::Id128(2);
        assert_eq!(
            session.accept_frame(
                &color,
                metadata(2, true),
                Some((&wrong_window, metadata(2, true))),
            ),
            Err(CodecSessionError::WindowMismatch)
        );
        let mut wrong_time = media(1, 3, MediaPlane::Alpha);
        wrong_time.source_submitted_ns = 2;
        assert_eq!(
            session.accept_frame(
                &color,
                metadata(2, true),
                Some((&wrong_time, metadata(2, true))),
            ),
            Err(CodecSessionError::SourceTimestampMismatch)
        );
        let alpha = media(1, 3, MediaPlane::Alpha);
        // Both failed candidates left the IDR/frame watermark untouched.
        assert!(
            session
                .accept_frame(&color, metadata(2, true), Some((&alpha, metadata(2, true))))
                .is_ok()
        );
    }

    #[test]
    fn newer_configuration_cannot_regress_geometry_epoch() {
        let (color, alpha) = h264_pair(2, 3);
        let mut session = CodecSession::new(CodecSessionPolicy::default());
        session
            .accept_descriptors(color, alpha, limits(36))
            .unwrap();
        let (older_geometry_color, older_geometry_alpha) = h264_pair(3, 2);
        assert_eq!(
            session.accept_descriptors(older_geometry_color, older_geometry_alpha, limits(36)),
            Err(CodecSessionError::GeometryEpochRegression)
        );
        // The rejected descriptor pair did not replace the epoch-3 configuration.
        assert!(
            session
                .accept_frame(
                    &media(1, 3, MediaPlane::Color),
                    metadata(2, true),
                    Some((&media(1, 3, MediaPlane::Alpha), metadata(2, true))),
                )
                .is_ok()
        );
    }
}
