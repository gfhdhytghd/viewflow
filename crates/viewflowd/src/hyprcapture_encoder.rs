//! Authenticated HCSF straight-RGBA to persistent NVENC adaptation.
//!
//! A geometry epoch is an encoder-generation fence: old contexts are dropped
//! (not drained) before a new size/epoch is submitted, so delayed AUs can never
//! be returned with a newer capture epoch.

use anyhow::{Result, bail};

use crate::{
    hyprcapture_stream::FrameHeader,
    nvenc_runtime::{
        AlphaFidelity, AlphaPolicy, EncodedAccessUnit, Encoder, EncoderConfig, FrameMetadata,
    },
};

#[derive(Clone, Copy, Debug)]
pub struct Config {
    pub max_input_bytes: usize,
    pub max_access_unit_bytes: usize,
    pub max_pending_frames: usize,
    pub alpha_policy: AlphaPolicy,
    pub alpha_fidelity: AlphaFidelity,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct GenerationKey {
    epoch: u64,
    width: u32,
    height: u32,
}

pub struct HyprcaptureEncoder {
    config: Config,
    last: Option<FrameHeader>,
    generation: Option<GenerationKey>,
    encoder: Option<Encoder>,
    pending: Vec<FrameMetadata>,
    keyframe_requested: bool,
}

impl HyprcaptureEncoder {
    /// # Errors
    /// Returns an error for zero resource bounds.
    pub fn new(config: Config) -> Result<Self> {
        if config.max_input_bytes == 0
            || config.max_access_unit_bytes == 0
            || config.max_pending_frames == 0
        {
            bail!("NVENC adapter bounds must be nonzero");
        }
        Ok(Self {
            config,
            last: None,
            generation: None,
            encoder: None,
            pending: Vec::new(),
            keyframe_requested: false,
        })
    }

    /// Force an IDR on the next accepted input without rebuilding the encoder.
    /// Earlier pending outputs retain their original metadata and are not
    /// retroactively keyframes; callers must still inspect each returned AU.
    pub fn request_keyframe(&mut self) {
        self.keyframe_requested = true;
    }

    /// Submits authenticated, straight (not premultiplied/BGRA) HCSF storage.
    /// On a new epoch or physical size, pending output from the prior encoder is
    /// intentionally discarded and this frame forces IDR on both present streams.
    /// # Errors
    /// Returns an error for invalid lineage/input, encoder failure, or output
    /// metadata outside this generation; failures invalidate the generation.
    pub fn submit(&mut self, header: FrameHeader, pixels: &[u8]) -> Result<Vec<EncodedAccessUnit>> {
        validate_input(&header, pixels, self.config.max_input_bytes)?;
        validate_lineage(self.last.as_ref(), &header)?;
        let key = GenerationKey {
            epoch: header.geometry_epoch,
            width: header.width,
            height: header.height,
        };
        let recreate = self.encoder.is_none() || self.generation.as_ref() != Some(&key);
        if recreate {
            // Do not drain: old AUs are deliberately discarded at this epoch fence.
            self.encoder = None;
            self.generation = None;
            self.pending.clear();
            self.encoder = Some(
                Encoder::new(EncoderConfig {
                    width: header.width,
                    height: header.height,
                    max_access_unit_bytes: self.config.max_access_unit_bytes,
                    max_pending_frames: self.config.max_pending_frames,
                    alpha_policy: self.config.alpha_policy,
                    alpha_fidelity: self.config.alpha_fidelity,
                })
                .map_err(|error| anyhow::anyhow!(error))?,
            );
            self.generation = Some(key);
        }
        let metadata = FrameMetadata {
            frame_id: header.sequence,
            timestamp_ns: header.capture_monotonic_ns,
            geometry_epoch: header.geometry_epoch,
        };
        if self.pending.len() >= self.config.max_pending_frames {
            self.invalidate_generation();
            bail!("NVENC adapter pending metadata bound exceeded");
        }
        self.pending.push(metadata);
        let Some(encoder) = self.encoder.as_mut() else {
            self.invalidate_generation();
            bail!("NVENC encoder generation was unavailable");
        };
        let force_idr = std::mem::take(&mut self.keyframe_requested) || recreate;
        let output = match encoder.submit(pixels, metadata, force_idr) {
            Ok(output) => output,
            Err(error) => {
                self.invalidate_generation();
                return Err(anyhow::anyhow!(error));
            }
        };
        if output.iter().any(|au| {
            let Some(index) = self
                .pending
                .iter()
                .position(|pending| *pending == au.metadata)
            else {
                return true;
            };
            self.pending.remove(index);
            false
        }) {
            self.invalidate_generation();
            bail!("NVENC returned an access unit outside the active HCSF generation");
        }
        self.last = Some(header);
        Ok(output)
    }
    fn invalidate_generation(&mut self) {
        self.encoder = None;
        self.generation = None;
        self.pending.clear();
    }
}

fn validate_input(header: &FrameHeader, pixels: &[u8], maximum: usize) -> Result<()> {
    let expected = usize::try_from(header.payload_bytes)?;
    if expected > maximum || pixels.len() != expected {
        bail!("HCSF RGBA payload violates adapter bound or header length");
    }
    let rgba = usize::try_from(
        u64::from(header.width)
            .checked_mul(u64::from(header.height))
            .and_then(|pixels| pixels.checked_mul(4))
            .ok_or_else(|| anyhow::anyhow!("RGBA size overflow"))?,
    )?;
    if expected != rgba
        || header.stride
            != header
                .width
                .checked_mul(4)
                .ok_or_else(|| anyhow::anyhow!("RGBA stride overflow"))?
    {
        bail!("HCSF input is not tightly packed straight RGBA");
    }
    Ok(())
}

#[allow(clippy::float_cmp)] // HCSF's exact logical geometry is part of its authenticated epoch contract.
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

#[cfg(test)]
mod tests {
    use super::*;
    fn header() -> FrameHeader {
        FrameHeader {
            sequence: 1,
            capture_monotonic_ns: 9,
            geometry_epoch: 1,
            logical_rect: [0.0, 0.0, 256.0, 256.0],
            width: 256,
            height: 256,
            stride: 1024,
            payload_bytes: 262_144,
        }
    }
    #[test]
    fn oversized_geometry_returns_error_without_overflow() {
        let mut oversized = header();
        oversized.width = u32::MAX;
        oversized.height = u32::MAX;
        oversized.payload_bytes = 0;
        assert!(validate_input(&oversized, &[], usize::MAX).is_err());
    }

    #[test]
    fn geometry_and_rgba_input_are_checked_without_gpu() {
        let first = header();
        assert!(validate_input(&first, &[0; 262_144], 262_144).is_ok());
        assert!(validate_input(&first, &[0; 15], 262_144).is_err());
        let mut changed = first.clone();
        changed.sequence = 2;
        changed.width = 512;
        changed.stride = 2048;
        changed.payload_bytes = 524_288;
        assert!(validate_lineage(Some(&first), &changed).is_err());
        changed.geometry_epoch = 2;
        assert!(validate_lineage(Some(&first), &changed).is_ok());
    }
    #[test]
    #[ignore = "requires paired NVENC hardware"]
    fn gpu_requested_keyframe_preserves_generation_and_timestamp() {
        let mut adapter = HyprcaptureEncoder::new(Config {
            max_input_bytes: 1024 * 1024,
            max_access_unit_bytes: 1024 * 1024,
            max_pending_frames: 3,
            alpha_policy: AlphaPolicy::Required,
            alpha_fidelity: AlphaFidelity::Lossless,
        })
        .unwrap();
        let first = header();
        adapter.submit(first.clone(), &vec![128; 262_144]).unwrap();
        adapter.request_keyframe();
        let mut next = first;
        next.sequence = 2;
        next.capture_monotonic_ns = 123;
        let output = adapter.submit(next, &vec![128; 262_144]).unwrap();
        let frame = output.iter().find(|au| au.metadata.frame_id == 2).unwrap();
        assert_eq!(frame.metadata.timestamp_ns, 123);
        assert_eq!(frame.metadata.geometry_epoch, 1);
        assert!(frame.color_is_idr && frame.alpha_is_idr);
        // Verify actual Annex-B IDR NALs, not only the encoder's keyframe flag.
        for plane in [&frame.color_annex_b, &frame.alpha_annex_b] {
            assert!(
                plane
                    .windows(4)
                    .any(|bytes| { bytes[..3] == [0, 0, 1] && bytes[3] & 0x1f == 5 })
            );
        }
    }

    #[test]
    #[ignore = "requires paired NVENC hardware"]
    fn gpu_resize_rebuilds_and_forces_idr() {
        let mut adapter = HyprcaptureEncoder::new(Config {
            max_input_bytes: 1024 * 1024,
            max_access_unit_bytes: 1024 * 1024,
            max_pending_frames: 3,
            alpha_policy: AlphaPolicy::Required,
            alpha_fidelity: AlphaFidelity::Lossless,
        })
        .unwrap();
        let first = header();
        let first_output = adapter.submit(first.clone(), &vec![255; 262_144]).unwrap();
        assert!(!first_output.is_empty());
        let mut resized = first;
        resized.sequence = 2;
        resized.geometry_epoch = 2;
        resized.width = 512;
        resized.height = 256;
        resized.stride = 2048;
        resized.payload_bytes = 524_288;
        resized.logical_rect[2] = 512.0;
        let out = adapter.submit(resized, &vec![255; 524_288]).unwrap();
        assert!(!out.is_empty());
        assert!(
            out.iter()
                .all(|au| au.color_is_idr && (!au.alpha_omitted && au.alpha_is_idr))
        );
    }
}
