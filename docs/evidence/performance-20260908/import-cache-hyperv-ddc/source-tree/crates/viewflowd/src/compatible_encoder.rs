//! H.264/NV12 plus lossless-alpha producer for NVENC implementations without
//! a usable H.264 4:4:4 alpha profile.
//!
//! The native encoder uses color-only conversion and receives the source
//! without interpreting its alpha. The unmodified straight alpha samples
//! travel in a separately, independently decodable `VFAR` plane. This is
//! intentionally not an adapter around
//! `encoded_media`: that adapter describes the native paired-H.264 contract.

use anyhow::{Result, bail};
use bytes::Bytes;
use viewflow_protocol::WindowId;
use viewflow_transport::{
    AlphaInterpretation, AlphaPlanePolicy, CodecDescriptor, CodecSessionPolicy, CodedPixelFormat,
    Colorimetry, FrameCodecMetadata, MediaPlane, MediaPlaneFrame, VideoCodec, VideoPlaneRole,
    encode_rgba_alpha_rle,
};

use crate::{
    hyprcapture_encoder::{Config as NativeConfig, HyprcaptureEncoder},
    hyprcapture_stream::FrameHeader,
    nvenc_runtime::{
        AlphaFidelity, AlphaPolicy, EncodedAccessUnit, FrameMetadata, StreamDescriptor,
    },
};

const H264_HIGH_8: u32 = 0;

#[cfg(test)]
#[derive(Clone, Copy, Debug, Default)]
struct SubmitProfile {
    parallel: std::time::Duration,
    adapt: std::time::Duration,
}

#[cfg(test)]
thread_local! {
    static LAST_SUBMIT_PROFILE: std::cell::Cell<SubmitProfile> = const { std::cell::Cell::new(SubmitProfile {
        parallel: std::time::Duration::ZERO,
        adapt: std::time::Duration::ZERO,
    }) };
    static FORCE_SERIAL_ALPHA: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Explicit caller-owned identity for one negotiated codec generation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodecIdentity {
    pub window_id: WindowId,
    pub config_generation: u64,
}

/// Bounded resource configuration for [`CompatibleEncoder`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Config {
    pub max_input_bytes: usize,
    pub max_color_access_unit_bytes: usize,
    pub max_alpha_access_unit_bytes: usize,
    pub max_pending_frames: usize,
}

/// Reliable descriptors for the H.264 color and `VFAR` alpha planes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DescriptorPair {
    pub color: CodecDescriptor,
    pub alpha: CodecDescriptor,
}

/// One matched color/alpha frame ready for transport fragmentation.
#[derive(Clone, Debug)]
pub struct MediaFrame {
    pub color: MediaPlaneFrame,
    pub color_metadata: FrameCodecMetadata,
    pub alpha: MediaPlaneFrame,
    pub alpha_metadata: FrameCodecMetadata,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct GenerationKey {
    identity: CodecIdentity,
    epoch: u64,
    width: u32,
    height: u32,
}

#[derive(Clone, Debug)]
struct PendingAlpha {
    metadata: FrameMetadata,
    payload: Bytes,
}

struct EncodedAlpha {
    payload: Bytes,
}

/// Owns a color-only NVENC producer and exact lossless alpha side channel.
///
/// The caller supplies a new nonzero `config_generation` whenever its
/// descriptor changes.  A changed identity, epoch, or physical size clears
/// delayed output and rebuilds the native producer so old color can never be
/// paired with alpha from a new generation.
pub struct CompatibleEncoder {
    config: Config,
    native: Option<HyprcaptureEncoder>,
    generation: Option<GenerationKey>,
    pending: Vec<PendingAlpha>,
    last_header: Option<FrameHeader>,
    window_id: Option<WindowId>,
    last_config_generation: Option<u64>,
}

impl CompatibleEncoder {
    /// # Errors
    /// Returns an error when any caller-selected resource bound is zero.
    pub fn new(config: Config) -> Result<Self> {
        if config.max_input_bytes == 0
            || config.max_color_access_unit_bytes == 0
            || config.max_alpha_access_unit_bytes == 0
            || config.max_pending_frames == 0
        {
            bail!("compatible encoder bounds must be nonzero");
        }
        Ok(Self {
            config,
            native: None,
            generation: None,
            pending: Vec::new(),
            last_header: None,
            window_id: None,
            last_config_generation: None,
        })
    }

    /// Descriptors for the active caller-selected generation, if any.
    #[must_use]
    pub fn descriptors(&self) -> Option<DescriptorPair> {
        Some(descriptor_pair(self.generation?))
    }

    /// This producer never marks an actual alpha plane as omitted, including
    /// fully opaque source frames.
    #[must_use]
    pub const fn codec_session_policy(&self) -> CodecSessionPolicy {
        CodecSessionPolicy {
            alpha_plane: AlphaPlanePolicy::Required,
        }
    }

    /// Starts lossless-alpha coding beside native color submission, then joins
    /// delayed color output by exact source metadata (`sequence`, timestamp,
    /// and epoch). Neither path copies or mutates the owned RGBA input.
    ///
    /// # Errors
    /// Any malformed input, native failure, mismatched delayed AU, or resource
    /// bound violation drops the active generation and its pending alpha.
    #[allow(
        clippy::needless_pass_by_value,
        reason = "retains the established owned-frame API while borrowed mapped-frame callers use submit_borrowed"
    )]
    pub fn submit(
        &mut self,
        identity: CodecIdentity,
        header: FrameHeader,
        rgba: Vec<u8>,
    ) -> Result<Vec<MediaFrame>> {
        self.submit_borrowed(identity, header, &rgba)
    }

    /// Borrowed variant for sealed/mapped HCSF frames. The input is never
    /// mutated: color-only native encoding ignores source alpha while VFAR
    /// retains it exactly. Errors clear the active generation just like
    /// [`Self::submit`].
    ///
    /// # Errors
    ///
    /// Returns the same validation, resource-bound, or native-encoder errors
    /// as [`Self::submit`] and clears the active generation on failure.
    pub fn submit_borrowed(
        &mut self,
        identity: CodecIdentity,
        header: FrameHeader,
        rgba: &[u8],
    ) -> Result<Vec<MediaFrame>> {
        let result = self.submit_inner(identity, header, rgba);
        if result.is_err() {
            self.clear_generation();
        }
        result
    }

    /// Ask the existing native context for an IDR on its next input. This does
    /// not change identities, configuration, capture timestamps, or pending AUs.
    /// Before initialization, the first frame already requests an IDR.
    pub fn request_keyframe(&mut self) {
        if let Some(native) = self.native.as_mut() {
            native.request_keyframe();
        }
    }

    fn submit_inner(
        &mut self,
        identity: CodecIdentity,
        header: FrameHeader,
        rgba: &[u8],
    ) -> Result<Vec<MediaFrame>> {
        validate_input(&header, rgba, self.config.max_input_bytes)?;
        if identity.config_generation == 0 || header.geometry_epoch == 0 {
            bail!("codec identity and geometry epoch must be nonzero");
        }
        validate_lineage(self.last_header.as_ref(), &header)?;
        if self
            .window_id
            .is_some_and(|window_id| window_id != identity.window_id)
        {
            bail!("compatible encoder cannot change window identity");
        }
        if header.width % 2 != 0 || header.height % 2 != 0 {
            bail!("H.264 NV12 requires even dimensions");
        }
        let key = GenerationKey {
            identity,
            epoch: header.geometry_epoch,
            width: header.width,
            height: header.height,
        };
        if self.generation.as_ref() != Some(&key) {
            if self
                .last_config_generation
                .is_some_and(|last| identity.config_generation <= last)
            {
                bail!("new codec generation must be explicitly increased by the caller");
            }
            self.clear_generation();
            self.native = Some(HyprcaptureEncoder::new(NativeConfig {
                max_input_bytes: self.config.max_input_bytes,
                max_access_unit_bytes: self.config.max_color_access_unit_bytes,
                max_pending_frames: self.config.max_pending_frames,
                // Color RGB is independent of straight alpha. Source alpha is
                // carried exactly by VFAR below, so native must explicitly
                // report external alpha rather than infer opacity.
                alpha_policy: AlphaPolicy::ColorOnlyExternalAlpha,
                alpha_fidelity: AlphaFidelity::Lossless,
            })?);
            self.generation = Some(key);
            self.window_id = Some(identity.window_id);
            self.last_config_generation = Some(identity.config_generation);
        }
        if self.pending.len() >= self.config.max_pending_frames {
            bail!("compatible encoder pending alpha bound exceeded");
        }

        let metadata = FrameMetadata {
            frame_id: header.sequence,
            timestamp_ns: header.capture_monotonic_ns,
            geometry_epoch: header.geometry_epoch,
        };
        #[cfg(test)]
        let parallel_started = std::time::Instant::now();
        #[cfg(test)]
        let force_serial_alpha = FORCE_SERIAL_ALPHA.with(std::cell::Cell::get);
        #[cfg(test)]
        let (output, alpha) = if force_serial_alpha {
            self.submit_serial_alpha(&header, rgba)?
        } else {
            self.submit_parallel_alpha(&header, rgba)?
        };
        #[cfg(not(test))]
        let (output, alpha) = self.submit_parallel_alpha(&header, rgba)?;
        #[cfg(test)]
        let parallel_elapsed = parallel_started.elapsed();
        let alpha_payload = alpha.payload;
        if alpha_payload.len() > self.config.max_alpha_access_unit_bytes {
            bail!("lossless alpha payload exceeds configured bound");
        }
        self.pending.push(PendingAlpha {
            metadata,
            payload: alpha_payload,
        });

        #[cfg(test)]
        let adapt_started = std::time::Instant::now();
        let frames: Result<Vec<_>> = output.into_iter().map(|au| self.adapt(au)).collect();
        #[cfg(test)]
        LAST_SUBMIT_PROFILE.with(|profile| {
            profile.set(SubmitProfile {
                parallel: parallel_elapsed,
                adapt: adapt_started.elapsed(),
            });
        });
        if frames.is_ok() {
            self.last_header = Some(header);
        }
        frames
    }

    /// Runs native color submission in the caller thread while a scoped worker
    /// encodes the independent VFAR plane from the same immutable source.
    /// Joining happens before either error is returned, so the caller's
    /// generation-clearing wrapper cannot leave pending alpha behind.
    fn submit_parallel_alpha(
        &mut self,
        header: &FrameHeader,
        rgba: &[u8],
    ) -> Result<(Vec<EncodedAccessUnit>, EncodedAlpha)> {
        std::thread::scope(|scope| -> Result<_> {
            let alpha_worker = std::thread::Builder::new()
                .name("viewflow-vfar".into())
                .spawn_scoped(scope, || {
                    let payload = encode_rgba_alpha_rle(
                        header.width,
                        header.height,
                        rgba,
                        usize::try_from(header.stride)?,
                    )?;
                    Ok::<_, anyhow::Error>(EncodedAlpha { payload })
                })
                .map_err(|error| anyhow::anyhow!("could not start VFAR worker: {error}"))?;
            let native_result = self
                .native
                .as_mut()
                .ok_or_else(|| anyhow::anyhow!("native encoder generation was unavailable"))
                .and_then(|native| native.submit(header.clone(), rgba));
            let alpha_result = alpha_worker
                .join()
                .map_err(|_| anyhow::anyhow!("VFAR worker panicked"))
                .and_then(std::convert::identity);
            Ok((native_result?, alpha_result?))
        })
    }

    #[cfg(test)]
    fn submit_serial_alpha(
        &mut self,
        header: &FrameHeader,
        rgba: &[u8],
    ) -> Result<(Vec<EncodedAccessUnit>, EncodedAlpha)> {
        let alpha = EncodedAlpha {
            payload: encode_rgba_alpha_rle(
                header.width,
                header.height,
                rgba,
                usize::try_from(header.stride)?,
            )?,
        };
        let output = self
            .native
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("native encoder generation was unavailable"))?
            .submit(header.clone(), rgba)?;
        Ok((output, alpha))
    }

    #[cfg(test)]
    fn last_submit_profile() -> SubmitProfile {
        LAST_SUBMIT_PROFILE.with(std::cell::Cell::get)
    }

    fn adapt(&mut self, access_unit: EncodedAccessUnit) -> Result<MediaFrame> {
        let generation = self
            .generation
            .ok_or_else(|| anyhow::anyhow!("missing compatible encoder generation"))?;
        if access_unit.metadata.geometry_epoch != generation.epoch {
            bail!("NVENC output crossed a geometry epoch");
        }
        if !is_color_contract(access_unit.color_stream) {
            bail!("NVENC output did not use the H.264 High NV12 color contract");
        }
        if access_unit.color_annex_b.is_empty()
            || access_unit.color_annex_b.len() > self.config.max_color_access_unit_bytes
        {
            bail!("NVENC color access unit violates configured bound");
        }
        // Native ColorOnlyExternalAlpha never observes source alpha. Seeing
        // an alpha stream or an opaque-omission claim would misdescribe VFAR.
        if !access_unit.alpha_external
            || access_unit.alpha_omitted
            || access_unit.alpha_stream.is_some()
            || !access_unit.alpha_annex_b.is_empty()
            || access_unit.alpha_is_idr
        {
            bail!("NVENC did not report color-only external alpha");
        }
        let index = self
            .pending
            .iter()
            .position(|pending| pending.metadata == access_unit.metadata)
            .ok_or_else(|| anyhow::anyhow!("NVENC output has no exact pending alpha match"))?;
        let alpha = self.pending.remove(index);
        let color = MediaPlaneFrame {
            window_id: generation.identity.window_id,
            frame_id: access_unit.metadata.frame_id,
            geometry_epoch: access_unit.metadata.geometry_epoch,
            plane: MediaPlane::Color,
            source_submitted_ns: access_unit.metadata.timestamp_ns,
            payload: Bytes::from(access_unit.color_annex_b),
        };
        let alpha_frame = MediaPlaneFrame {
            window_id: generation.identity.window_id,
            frame_id: alpha.metadata.frame_id,
            geometry_epoch: alpha.metadata.geometry_epoch,
            plane: MediaPlane::Alpha,
            source_submitted_ns: alpha.metadata.timestamp_ns,
            payload: alpha.payload,
        };
        Ok(MediaFrame {
            color,
            color_metadata: FrameCodecMetadata {
                config_generation: generation.identity.config_generation,
                keyframe: access_unit.color_is_idr,
            },
            alpha: alpha_frame,
            // VFAR is independently intra-coded for every frame.
            alpha_metadata: FrameCodecMetadata {
                config_generation: generation.identity.config_generation,
                keyframe: true,
            },
        })
    }

    fn clear_generation(&mut self) {
        self.native = None;
        self.generation = None;
        self.pending.clear();
    }
}

fn descriptor_pair(generation: GenerationKey) -> DescriptorPair {
    DescriptorPair {
        color: CodecDescriptor {
            codec: VideoCodec::H264,
            plane: VideoPlaneRole::Color,
            pixel_format: CodedPixelFormat::Nv12,
            colorimetry: Colorimetry::Bt709Limited,
            alpha_interpretation: AlphaInterpretation::StraightWithExternalPlane,
            coded_width: generation.width,
            coded_height: generation.height,
            geometry_epoch: generation.epoch,
            config_generation: generation.identity.config_generation,
        },
        alpha: CodecDescriptor {
            codec: VideoCodec::LosslessAlpha,
            plane: VideoPlaneRole::Alpha,
            pixel_format: CodedPixelFormat::Gray8,
            colorimetry: Colorimetry::AlphaFullRange,
            alpha_interpretation: AlphaInterpretation::AlphaPlane,
            coded_width: generation.width,
            coded_height: generation.height,
            geometry_epoch: generation.epoch,
            config_generation: generation.identity.config_generation,
        },
    }
}

fn validate_input(header: &FrameHeader, rgba: &[u8], maximum: usize) -> Result<()> {
    let expected = usize::try_from(header.payload_bytes)?;
    let rgba_bytes = u64::from(header.width)
        .checked_mul(u64::from(header.height))
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| anyhow::anyhow!("RGBA size overflow"))?;
    let tight_stride = header
        .width
        .checked_mul(4)
        .ok_or_else(|| anyhow::anyhow!("RGBA stride overflow"))?;
    if expected > maximum
        || rgba.len() != expected
        || u64::try_from(expected)? != rgba_bytes
        || header.stride != tight_stride
    {
        bail!("HCSF RGBA payload violates compatible encoder bounds");
    }
    Ok(())
}

#[allow(clippy::float_cmp)] // Authenticated HCSF logical geometry is exact lineage.
fn validate_lineage(last: Option<&FrameHeader>, next: &FrameHeader) -> Result<()> {
    if let Some(last) = last {
        if next.sequence <= last.sequence
            || next.capture_monotonic_ns < last.capture_monotonic_ns
            || next.geometry_epoch < last.geometry_epoch
        {
            bail!("stale HCSF frame");
        }
        if next.geometry_epoch == last.geometry_epoch
            && (next.width != last.width
                || next.height != last.height
                || next.stride != last.stride
                || next.logical_rect != last.logical_rect)
        {
            bail!("HCSF geometry changed without a new epoch");
        }
    }
    Ok(())
}

const fn is_color_contract(descriptor: StreamDescriptor) -> bool {
    descriptor.profile == H264_HIGH_8
        && !descriptor.full_range
        && !descriptor.luma_is_straight_alpha
        && !descriptor.chroma_is_neutral
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::Id128;
    use viewflow_transport::{AlphaRleLimits, CodecResourceLimits, CodecSession, decode_alpha_rle};

    const IDENTITY: CodecIdentity = CodecIdentity {
        window_id: Id128(7),
        config_generation: 2,
    };

    fn config() -> Config {
        Config {
            max_input_bytes: 256 * 256 * 4,
            max_color_access_unit_bytes: 1_000_000,
            max_alpha_access_unit_bytes: 256 * 256 + 24,
            max_pending_frames: 3,
        }
    }

    fn header() -> FrameHeader {
        FrameHeader {
            sequence: 4,
            capture_monotonic_ns: 99,
            geometry_epoch: 8,
            logical_rect: [0.0, 0.0, 256.0, 256.0],
            width: 256,
            height: 256,
            stride: 1024,
            payload_bytes: 256 * 256 * 4,
        }
    }

    #[test]
    fn direct_alpha_vfar_preserves_rgb_and_alpha_exactly() {
        let rgba = vec![12, 34, 56, 0, 78, 90, 123, 255];
        let vfar = encode_rgba_alpha_rle(2, 1, &rgba, 8).unwrap();
        let alpha = decode_alpha_rle(
            vfar,
            AlphaRleLimits {
                max_coded_width: 2,
                max_coded_height: 1,
                max_luma_samples: 2,
                max_decoded_bytes: 2,
                max_encoded_bytes: 26,
            },
        )
        .unwrap();
        assert_eq!(alpha.samples.as_ref(), [0, 255]);
        assert_eq!(rgba, [12, 34, 56, 0, 78, 90, 123, 255]);
    }

    #[test]
    fn descriptors_are_lossless_alpha_and_required() {
        let mut encoder = CompatibleEncoder::new(config()).unwrap();
        // Input validation happens before any GPU initialization.
        assert!(encoder.submit(IDENTITY, header(), vec![0; 3]).is_err());
        assert!(encoder.descriptors().is_none());
        assert_eq!(
            encoder.codec_session_policy(),
            CodecSessionPolicy {
                alpha_plane: AlphaPlanePolicy::Required
            }
        );
    }

    #[test]
    fn lossless_alpha_descriptor_pair_is_accepted_by_codec_session() {
        let descriptors = descriptor_pair(GenerationKey {
            identity: IDENTITY,
            epoch: 8,
            width: 256,
            height: 256,
        });
        let mut session = CodecSession::new(CodecSessionPolicy {
            alpha_plane: AlphaPlanePolicy::Required,
        });
        session
            .accept_descriptors(
                descriptors.color,
                descriptors.alpha,
                CodecResourceLimits {
                    max_coded_width: 256,
                    max_coded_height: 256,
                    max_luma_samples: 256 * 256,
                    max_decoded_bytes: 256 * 256 * 3,
                },
            )
            .unwrap();
    }

    #[test]
    #[ignore = "requires an NVENC GPU with the color High/NV12 profile"]
    fn gpu_nonopaque_gradient_omits_native_alpha_but_delivers_exact_lossless_alpha() {
        let mut encoder = CompatibleEncoder::new(config()).unwrap();
        let source_alpha: Vec<u8> = (0..(256_u32 * 256)).map(|i| i as u8).collect();
        let mut rgba = Vec::with_capacity(256 * 256 * 4);
        for alpha in &source_alpha {
            rgba.extend_from_slice(&[11, 22, 33, *alpha]);
        }
        let frames = encoder.submit(IDENTITY, header(), rgba).unwrap();
        assert!(!frames.is_empty());
        let descriptors = encoder.descriptors().unwrap();
        assert_eq!(descriptors.alpha.codec, VideoCodec::LosslessAlpha);
        assert_eq!(descriptors.alpha.pixel_format, CodedPixelFormat::Gray8);
        let mut session = CodecSession::new(encoder.codec_session_policy());
        session
            .accept_descriptors(
                descriptors.color,
                descriptors.alpha,
                CodecResourceLimits {
                    max_coded_width: 256,
                    max_coded_height: 256,
                    max_luma_samples: 256 * 256,
                    max_decoded_bytes: 256 * 256 * 3,
                },
            )
            .unwrap();
        for frame in frames {
            // A transparent/partial/opaque source alpha gradient must still
            // produce the negotiated color stream; native never keys color
            // encoding or omission off alpha in ColorOnlyExternalAlpha mode.
            assert!(!frame.color.payload.is_empty());
            let decoded = decode_alpha_rle(
                frame.alpha.payload.clone(),
                AlphaRleLimits {
                    max_coded_width: 256,
                    max_coded_height: 256,
                    max_luma_samples: 256 * 256,
                    max_decoded_bytes: 256 * 256,
                    max_encoded_bytes: 256 * 256 + 24,
                },
            )
            .unwrap();
            assert_eq!(decoded.samples.as_ref(), source_alpha.as_slice());
            session
                .accept_frame(
                    &frame.color,
                    frame.color_metadata,
                    Some((&frame.alpha, frame.alpha_metadata)),
                )
                .unwrap();
            let pipe_record = crate::gpu_presenter_pipe::encode_lossless_alpha_record(
                frame.color.frame_id,
                descriptors.color.coded_width,
                descriptors.color.coded_height,
                &frame.color.payload,
                frame.alpha.payload.clone(),
                1024 * 1024,
            )
            .unwrap();
            let color_end = crate::gpu_presenter_pipe::HEADER_BYTES + frame.color.payload.len();
            assert_eq!(
                &pipe_record[crate::gpu_presenter_pipe::HEADER_BYTES..color_end],
                frame.color.payload.as_ref()
            );
            assert_eq!(&pipe_record[color_end..], source_alpha.as_slice());
        }
    }

    #[test]
    #[ignore = "synthetic NVENC timing diagnostic; no capture source is opened"]
    fn gpu_profile_compatible_submit_1936x1732() {
        use std::time::{Duration, Instant};

        const WIDTH: u32 = 1936;
        const HEIGHT: u32 = 1732;
        const SAMPLES: u64 = 160;
        let pixels = usize::try_from(u64::from(WIDTH) * u64::from(HEIGHT)).unwrap();
        let config = Config {
            max_input_bytes: pixels * 4,
            max_color_access_unit_bytes: 32 * 1024 * 1024,
            max_alpha_access_unit_bytes: pixels + 24,
            max_pending_frames: 3,
        };
        let make_header = |sequence| FrameHeader {
            sequence,
            capture_monotonic_ns: sequence * 16_666_667,
            geometry_epoch: 1,
            logical_rect: [0.0, 0.0, f64::from(WIDTH), f64::from(HEIGHT)],
            width: WIDTH,
            height: HEIGHT,
            stride: WIDTH * 4,
            payload_bytes: u64::try_from(pixels * 4).unwrap(),
        };
        let make_rgba = |sequence| {
            let mut rgba = vec![0_u8; pixels * 4];
            for y in 0..HEIGHT as usize {
                for x in 0..WIDTH as usize {
                    let offset = (y * WIDTH as usize + x) * 4;
                    rgba[offset] = (x as u64 + sequence) as u8;
                    rgba[offset + 1] = (y as u64 + sequence * 3) as u8;
                    rgba[offset + 2] = 127;
                    // Transparent/partial 16-pixel border with opaque content.
                    let edge = x
                        .min(y)
                        .min(WIDTH as usize - 1 - x)
                        .min(HEIGHT as usize - 1 - y);
                    rgba[offset + 3] = if edge >= 16 { 255 } else { (edge * 16) as u8 };
                }
            }
            rgba
        };
        let percentile = |mut samples: Vec<Duration>| {
            samples.sort_unstable();
            let p50 = samples[samples.len() / 2].as_micros();
            let p95 = samples[(samples.len() - 1) * 95 / 100].as_micros();
            (p50, p95)
        };

        let run_profile = |serial_alpha| {
            FORCE_SERIAL_ALPHA.with(|force| force.set(serial_alpha));
            let mut encoder = CompatibleEncoder::new(config).unwrap();
            let mut total = Vec::with_capacity(SAMPLES as usize);
            let mut parallel = Vec::with_capacity(SAMPLES as usize);
            let mut adapt = Vec::with_capacity(SAMPLES as usize);
            for sequence in 1..=SAMPLES {
                let rgba = make_rgba(sequence);
                let started = Instant::now();
                encoder
                    .submit(IDENTITY, make_header(sequence), rgba)
                    .unwrap();
                total.push(started.elapsed());
                let profile = CompatibleEncoder::last_submit_profile();
                parallel.push(profile.parallel);
                adapt.push(profile.adapt);
            }
            FORCE_SERIAL_ALPHA.with(|force| force.set(false));
            (percentile(total), percentile(parallel), percentile(adapt))
        };
        let (serial_total, serial_parallel, serial_adapt) = run_profile(true);
        let (parallel_total, parallel_native_vfar, parallel_adapt) = run_profile(false);
        eprintln!(
            "compatible-profile synthetic={}x{} frames={} serial_total_us_p50={} p95={} serial_alpha_then_native_us_p50={} p95={} serial_adapt_us_p50={} p95={} parallel_total_us_p50={} p95={} parallel_native_vfar_us_p50={} p95={} parallel_adapt_us_p50={} p95={}",
            WIDTH,
            HEIGHT,
            SAMPLES,
            serial_total.0,
            serial_total.1,
            serial_parallel.0,
            serial_parallel.1,
            serial_adapt.0,
            serial_adapt.1,
            parallel_total.0,
            parallel_total.1,
            parallel_native_vfar.0,
            parallel_native_vfar.1,
            parallel_adapt.0,
            parallel_adapt.1,
        );
    }
}
