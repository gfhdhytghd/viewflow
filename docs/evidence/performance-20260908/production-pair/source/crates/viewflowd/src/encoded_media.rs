//! Adapter from the Linux NVENC output contract to negotiated transport media.
//!
//! This module deliberately only prepares reliable codec descriptors and
//! `VFMD` plane frames.  It neither sends datagrams nor invokes a decoder.  The
//! caller supplies the configuration generation on the reliable-control path;
//! every access unit is then checked against the native encoder contract before
//! it can enter a [`viewflow_transport::CodecSession`].

use std::{error::Error, fmt};

use bytes::Bytes;
use viewflow_protocol::WindowId;
use viewflow_transport::{
    AlphaInterpretation, AlphaPlanePolicy, CodecDescriptor, CodecSessionPolicy, CodedPixelFormat,
    Colorimetry, FrameCodecMetadata, MediaPlane, MediaPlaneFrame, VideoCodec, VideoPlaneRole,
};

use crate::nvenc_runtime::{AlphaPolicy, EncodedAccessUnit, EncoderConfig, StreamDescriptor};

// Kept in lockstep with `platform/nvenc-encoder/nvenc_encoder_cabi.h`.  These
// identify the C ABI's actual output profiles, rather than an FFmpeg profile
// number inferred by a receiver.
const H264_HIGH_8: u32 = 0;
const H264_HIGH_444_PREDICTIVE_8: u32 = 1;

/// Native NVENC-to-transport adapter for one encoded geometry/configuration.
///
/// Its dimensions and alpha policy come directly from the `EncoderConfig`
/// used to create the producer. `config_generation` is deliberately supplied
/// by the reliable-control owner, not invented per access unit.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NvencMediaAdapter {
    window_id: WindowId,
    coded_width: u32,
    coded_height: u32,
    geometry_epoch: u64,
    config_generation: u64,
    max_access_unit_bytes: usize,
    alpha_policy: AlphaPolicy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NvencDescriptorPair {
    pub color: CodecDescriptor,
    pub alpha: CodecDescriptor,
}

/// Frames and their per-access-unit control metadata, ready for fragmentation.
#[derive(Clone, Debug)]
pub struct NvencMediaFrame {
    pub color: MediaPlaneFrame,
    pub color_metadata: FrameCodecMetadata,
    pub alpha: Option<(MediaPlaneFrame, FrameCodecMetadata)>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NvencMediaError {
    InvalidConfiguration,
    GeometryEpochMismatch,
    WrongColorProfile,
    WrongAlphaProfile,
    EmptyColorAccessUnit,
    EmptyAlphaAccessUnit,
    ColorAccessUnitTooLarge,
    AlphaAccessUnitTooLarge,
    MissingAlpha,
    UnexpectedAlpha,
    InvalidOmittedAlpha,
}

impl fmt::Display for NvencMediaError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "NVENC media adapter error: {self:?}")
    }
}

impl Error for NvencMediaError {}

impl NvencMediaAdapter {
    /// Binds a native encoder's exact configured input geometry to one reliable
    /// codec generation.
    ///
    /// H.264/NV12 needs even dimensions, and zero epochs/generations cannot be
    /// represented by the negotiated descriptor contract.
    ///
    /// # Errors
    ///
    /// Returns [`NvencMediaError::InvalidConfiguration`] when the encoder
    /// dimensions or access-unit bound cannot form a canonical H.264 session.
    pub const fn new(
        window_id: WindowId,
        geometry_epoch: u64,
        config_generation: u64,
        encoder: &EncoderConfig,
    ) -> Result<Self, NvencMediaError> {
        if encoder.width == 0
            || encoder.height == 0
            || encoder.width % 2 != 0
            || encoder.height % 2 != 0
            || encoder.max_access_unit_bytes == 0
            || geometry_epoch == 0
            || config_generation == 0
        {
            return Err(NvencMediaError::InvalidConfiguration);
        }
        Ok(Self {
            window_id,
            coded_width: encoder.width,
            coded_height: encoder.height,
            geometry_epoch,
            config_generation,
            max_access_unit_bytes: encoder.max_access_unit_bytes,
            alpha_policy: encoder.alpha_policy,
        })
    }

    /// Builds the reliable descriptor pair that must be accepted before any
    /// corresponding [`Self::adapt`] output is admitted.
    #[must_use]
    pub const fn descriptors(self) -> NvencDescriptorPair {
        NvencDescriptorPair {
            color: CodecDescriptor {
                codec: VideoCodec::H264,
                plane: VideoPlaneRole::Color,
                pixel_format: CodedPixelFormat::Nv12,
                colorimetry: Colorimetry::Bt709Limited,
                alpha_interpretation: AlphaInterpretation::StraightWithExternalPlane,
                coded_width: self.coded_width,
                coded_height: self.coded_height,
                geometry_epoch: self.geometry_epoch,
                config_generation: self.config_generation,
            },
            alpha: CodecDescriptor {
                codec: VideoCodec::H264,
                plane: VideoPlaneRole::Alpha,
                pixel_format: CodedPixelFormat::Yuv444p,
                colorimetry: Colorimetry::AlphaFullRange,
                alpha_interpretation: AlphaInterpretation::AlphaPlane,
                coded_width: self.coded_width,
                coded_height: self.coded_height,
                geometry_epoch: self.geometry_epoch,
                config_generation: self.config_generation,
            },
        }
    }

    /// Session policy matching the native encoder's configured alpha policy.
    #[must_use]
    pub const fn codec_session_policy(self) -> CodecSessionPolicy {
        CodecSessionPolicy {
            alpha_plane: match self.alpha_policy {
                AlphaPolicy::Required | AlphaPolicy::ColorOnlyExternalAlpha => {
                    AlphaPlanePolicy::Required
                }
                AlphaPolicy::OpaqueMayOmit => AlphaPlanePolicy::OpaqueMayOmit,
            },
        }
    }

    /// Converts one bounded native access unit without changing its identity,
    /// source timestamp, geometry epoch, or IDR flags.
    ///
    /// This validates the native C ABI's color profile (limited-range High
    /// NV12) and alpha carrier (full-range High 4:4:4 Predictive, straight
    /// alpha in luma with neutral chroma). It moves Annex-B bytes into `Bytes`;
    /// no additional payload copy is made here.
    ///
    /// # Errors
    ///
    /// Rejects a geometry mismatch, profile/alpha-contract violation, empty
    /// plane, or plane above the native encoder's configured access-unit bound.
    pub fn adapt(self, access_unit: EncodedAccessUnit) -> Result<NvencMediaFrame, NvencMediaError> {
        if access_unit.alpha_external {
            return Err(NvencMediaError::MissingAlpha);
        }
        if access_unit.metadata.geometry_epoch != self.geometry_epoch {
            return Err(NvencMediaError::GeometryEpochMismatch);
        }
        if !is_color_contract(access_unit.color_stream) {
            return Err(NvencMediaError::WrongColorProfile);
        }
        validate_access_unit(
            access_unit.color_annex_b.len(),
            self.max_access_unit_bytes,
            NvencMediaError::EmptyColorAccessUnit,
            NvencMediaError::ColorAccessUnitTooLarge,
        )?;

        let color = MediaPlaneFrame {
            window_id: self.window_id,
            frame_id: access_unit.metadata.frame_id,
            geometry_epoch: access_unit.metadata.geometry_epoch,
            plane: MediaPlane::Color,
            source_submitted_ns: access_unit.metadata.timestamp_ns,
            payload: Bytes::from(access_unit.color_annex_b),
        };
        let color_metadata = FrameCodecMetadata {
            config_generation: self.config_generation,
            keyframe: access_unit.color_is_idr,
        };

        if access_unit.alpha_omitted {
            if self.alpha_policy != AlphaPolicy::OpaqueMayOmit {
                return Err(NvencMediaError::MissingAlpha);
            }
            if access_unit.alpha_stream.is_some()
                || !access_unit.alpha_annex_b.is_empty()
                || access_unit.alpha_is_idr
            {
                return Err(NvencMediaError::InvalidOmittedAlpha);
            }
            return Ok(NvencMediaFrame {
                color,
                color_metadata,
                alpha: None,
            });
        }

        let alpha_stream = access_unit
            .alpha_stream
            .ok_or(NvencMediaError::MissingAlpha)?;
        if !is_alpha_contract(alpha_stream) {
            return Err(NvencMediaError::WrongAlphaProfile);
        }
        validate_access_unit(
            access_unit.alpha_annex_b.len(),
            self.max_access_unit_bytes,
            NvencMediaError::EmptyAlphaAccessUnit,
            NvencMediaError::AlphaAccessUnitTooLarge,
        )?;
        let alpha = MediaPlaneFrame {
            window_id: self.window_id,
            frame_id: access_unit.metadata.frame_id,
            geometry_epoch: access_unit.metadata.geometry_epoch,
            plane: MediaPlane::Alpha,
            source_submitted_ns: access_unit.metadata.timestamp_ns,
            payload: Bytes::from(access_unit.alpha_annex_b),
        };
        Ok(NvencMediaFrame {
            color,
            color_metadata,
            alpha: Some((
                alpha,
                FrameCodecMetadata {
                    config_generation: self.config_generation,
                    keyframe: access_unit.alpha_is_idr,
                },
            )),
        })
    }
}

const fn is_color_contract(descriptor: StreamDescriptor) -> bool {
    descriptor.profile == H264_HIGH_8
        && !descriptor.full_range
        && !descriptor.luma_is_straight_alpha
        && !descriptor.chroma_is_neutral
}

const fn is_alpha_contract(descriptor: StreamDescriptor) -> bool {
    descriptor.profile == H264_HIGH_444_PREDICTIVE_8
        && descriptor.full_range
        && descriptor.luma_is_straight_alpha
        && descriptor.chroma_is_neutral
}

const fn validate_access_unit(
    bytes: usize,
    maximum: usize,
    empty: NvencMediaError,
    too_large: NvencMediaError,
) -> Result<(), NvencMediaError> {
    if bytes == 0 {
        Err(empty)
    } else if bytes > maximum {
        Err(too_large)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::Id128;
    use viewflow_transport::{CodecResourceLimits, CodecSession};

    const WINDOW: WindowId = Id128(9);
    const EPOCH: u64 = 4;
    const GENERATION: u64 = 7;
    const LIMITS: CodecResourceLimits = CodecResourceLimits {
        max_coded_width: 4_096,
        max_coded_height: 4_096,
        max_luma_samples: 16_777_216,
        max_decoded_bytes: 80_000_000,
    };

    fn encoder(alpha_policy: AlphaPolicy) -> EncoderConfig {
        EncoderConfig {
            width: 1_556,
            height: 1_300,
            max_access_unit_bytes: 32,
            max_pending_frames: 2,
            alpha_policy,
            alpha_fidelity: crate::nvenc_runtime::AlphaFidelity::Lossless,
        }
    }

    fn adapter(alpha_policy: AlphaPolicy) -> NvencMediaAdapter {
        NvencMediaAdapter::new(WINDOW, EPOCH, GENERATION, &encoder(alpha_policy)).unwrap()
    }

    fn access_unit() -> EncodedAccessUnit {
        EncodedAccessUnit {
            metadata: crate::nvenc_runtime::FrameMetadata {
                frame_id: 12,
                timestamp_ns: 88,
                geometry_epoch: EPOCH,
            },
            alpha_omitted: false,
            alpha_external: false,
            color_is_idr: true,
            alpha_is_idr: true,
            color_stream: StreamDescriptor {
                profile: H264_HIGH_8,
                full_range: false,
                luma_is_straight_alpha: false,
                chroma_is_neutral: false,
            },
            alpha_stream: Some(StreamDescriptor {
                profile: H264_HIGH_444_PREDICTIVE_8,
                full_range: true,
                luma_is_straight_alpha: true,
                chroma_is_neutral: true,
            }),
            color_annex_b: vec![0, 0, 0, 1, 0x65],
            alpha_annex_b: vec![0, 0, 0, 1, 0x65],
        }
    }

    #[test]
    fn native_pair_is_admitted_by_transport_codec_session() {
        let adapter = adapter(AlphaPolicy::Required);
        let descriptors = adapter.descriptors();
        let mut session = CodecSession::new(adapter.codec_session_policy());
        session
            .accept_descriptors(descriptors.color, descriptors.alpha, LIMITS)
            .unwrap();
        let frame = adapter.adapt(access_unit()).unwrap();
        let admission = session
            .accept_frame(
                &frame.color,
                frame.color_metadata,
                frame
                    .alpha
                    .as_ref()
                    .map(|(plane, metadata)| (plane, *metadata)),
            )
            .unwrap();
        assert_eq!(admission.frame_id, 12);
        assert!(admission.paired_keyframe);
        assert_eq!(frame.color.payload.as_ref(), [0, 0, 0, 1, 0x65]);
        assert_eq!(frame.alpha.unwrap().0.payload.as_ref(), [0, 0, 0, 1, 0x65]);
    }

    #[test]
    fn bad_native_profile_is_rejected_before_transport_admission() {
        let mut au = access_unit();
        au.color_stream.full_range = true;
        assert!(matches!(
            adapter(AlphaPolicy::Required).adapt(au),
            Err(NvencMediaError::WrongColorProfile)
        ));
    }

    #[test]
    fn epoch_mismatch_is_rejected() {
        let mut au = access_unit();
        au.metadata.geometry_epoch += 1;
        assert!(matches!(
            adapter(AlphaPolicy::Required).adapt(au),
            Err(NvencMediaError::GeometryEpochMismatch)
        ));
    }

    #[test]
    fn required_alpha_cannot_be_dropped() {
        let mut au = access_unit();
        au.alpha_stream = None;
        au.alpha_annex_b.clear();
        assert!(matches!(
            adapter(AlphaPolicy::Required).adapt(au),
            Err(NvencMediaError::MissingAlpha)
        ));
    }

    #[test]
    fn opaque_omission_is_explicit_and_keeps_alpha_out_of_wire_frames() {
        let mut au = access_unit();
        au.alpha_omitted = true;
        au.alpha_is_idr = false;
        au.alpha_stream = None;
        au.alpha_annex_b.clear();
        assert!(
            adapter(AlphaPolicy::OpaqueMayOmit)
                .adapt(au)
                .unwrap()
                .alpha
                .is_none()
        );
    }

    #[test]
    fn per_plane_access_units_are_bounded() {
        let mut au = access_unit();
        au.alpha_annex_b.resize(33, 1);
        assert!(matches!(
            adapter(AlphaPolicy::Required).adapt(au),
            Err(NvencMediaError::AlphaAccessUnitTooLarge)
        ));
    }
}
