//! GPU H.264 High/NV12 + independent lossless VFAR transport adapter.
//! Local source timestamps remain untouched; only outbound timestamps use the
//! caller's established session-clock mapping. This module never sends HCGR.

use crate::{
    compatible_encoder::{CodecIdentity, Config, DescriptorPair, MediaFrame},
    gpu_nvenc_runtime::{
        EncodedGpuFrame, GpuAtlasIdentity, GpuAtlasTile, GpuEncodeOutcome, GpuEncoder,
    },
    hyprcapture_gpu_socket::GpuFrame,
};
use anyhow::{Result, ensure};
use bytes::Bytes;
use std::collections::BTreeMap;
use viewflow_core::AtlasSnapshot;
use viewflow_protocol::WindowId;
use viewflow_transport::{
    AlphaInterpretation, CodecDescriptor, CodedPixelFormat, Colorimetry, FrameCodecMetadata,
    MediaPlane, MediaPlaneFrame, VideoCodec, VideoPlaneRole, encode_alpha_rle,
};

#[derive(Clone, Copy, PartialEq, Eq)]
struct Generation {
    identity: CodecIdentity,
    epoch: u64,
    width: u32,
    height: u32,
}

/// One bounded generation-local lossless-alpha payload. `Bytes` clones share
/// its allocation; raw alpha moves here on a miss so no extra full-frame clone
/// is retained per submission.
struct AlphaCache {
    generation: Generation,
    config: Config,
    raw_alpha: Vec<u8>,
    encoded: Bytes,
}

/// Only `ExpiredClean` proves an expired input can release its GPU-read lease.
pub enum GpuSubmitOutcome {
    Encoded(Vec<MediaFrame>),
    ExpiredClean,
}

pub struct AtlasSource<'a> {
    pub window: WindowId,
    pub frame: &'a GpuFrame,
    pub deadline_monotonic_ns: i64,
}
impl AtlasSource<'_> {
    fn identity(&self) -> AtlasSourceIdentity {
        let header = self.frame.metadata();
        AtlasSourceIdentity {
            window: self.window,
            frame_id: header.sequence,
            capture_monotonic_ns: header.capture_monotonic_ns,
            geometry_epoch: header.geometry_epoch,
            width: header.crop_width,
            height: header.crop_height,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasSourceIdentity {
    pub window: WindowId,
    pub frame_id: u64,
    pub capture_monotonic_ns: u64,
    pub geometry_epoch: u64,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy)]
pub struct AtlasSubmission<'a> {
    /// Negotiated atlas media stream ID; never a constituent window's input ID.
    pub codec: CodecIdentity,
    pub layout: &'a AtlasSnapshot,
    pub identity: GpuAtlasIdentity,
    pub mapped_source_ns: u64,
    pub deadline_monotonic_ns: i64,
    pub sources: &'a [AtlasSource<'a>],
    /// Immutable logical desktop geometry copied from the exact HCGF frames
    /// still retained by this submission. `None` preserves non-desktop Atlas.
    pub desktop: Option<&'a viewflow_protocol::AtlasDesktopLayout>,
}

/// These pieces must be published together. This local result is not itself a
/// negotiated wire format or permission to inject input into any window.
pub enum AtlasSubmitOutcome {
    Encoded {
        manifest: Box<viewflow_protocol::AtlasFrame>,
        layout: AtlasSnapshot,
        sources: Vec<AtlasSourceIdentity>,
        media: Vec<MediaFrame>,
    },
    ExpiredClean,
}

/// One persistent GPU encoder for a device-pair atlas, not one encoder per tile.
pub struct GpuAtlasCompatibleEncoder {
    inner: GpuCompatibleEncoder,
    last_layout: Option<AtlasSnapshot>,
    last_sources: BTreeMap<WindowId, AtlasSourceIdentity>,
}

impl GpuAtlasCompatibleEncoder {
    /// Continue the existing atlas lineage after startup pictures.
    pub(crate) fn next_frame_id(&self) -> Result<u64> {
        ensure!(!self.inner.failed, "atlas encoder is retired");
        self.inner.last_source.map_or(Ok(1), |(frame, _)| {
            frame
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("atlas frame sequence exhausted"))
        })
    }

    /// # Errors
    /// Invalid resource limits are rejected before GPU initialization.
    pub fn new(config: Config) -> Result<Self> {
        Ok(Self {
            inner: GpuCompatibleEncoder::new(config)?,
            last_layout: None,
            last_sources: BTreeMap::new(),
        })
    }

    pub fn set_color_codec(&mut self, codec: VideoCodec) -> Result<()> {
        ensure!(
            self.inner.encoder.is_none() && self.inner.generation.is_none(),
            "codec must be selected before GPU preparation"
        );
        ensure!(
            matches!(codec, VideoCodec::H264 | VideoCodec::Av1),
            "unsupported GPU color codec"
        );
        self.inner.color_codec = codec;
        Ok(())
    }

    /// # Errors
    /// Must run before capture leases are held, as for the single-window adapter.
    pub fn prepare_size(&mut self, width: u32, height: u32) -> Result<()> {
        self.inner.prepare_size(width, height)
    }

    #[must_use]
    pub fn descriptors(&self) -> Option<DescriptorPair> {
        self.inner.descriptors()
    }

    pub fn request_keyframe(&mut self) {
        self.inner.request_keyframe();
    }

    /// # Errors
    /// Any error retires the encoder and requires retirement of every source
    /// session without HCGR. Only `ExpiredClean` proves a dropped batch is clean.
    pub fn submit_recoverable(
        &mut self,
        request: AtlasSubmission<'_>,
    ) -> Result<AtlasSubmitOutcome> {
        ensure!(!self.inner.failed, "atlas encoder is retired");
        let result = self.submit_inner(request);
        if result.is_err() {
            self.inner.failed = true;
            self.inner.encoder = None;
            self.inner.alpha_cache = None;
        }
        result
    }

    fn submit_inner(&mut self, request: AtlasSubmission<'_>) -> Result<AtlasSubmitOutcome> {
        ensure!(request.sources.len() <= 4096, "atlas source bound exceeded");
        let sources: Vec<_> = request.sources.iter().map(AtlasSource::identity).collect();
        validate_atlas_batch(
            request.layout,
            &sources,
            self.last_layout.as_ref(),
            &self.last_sources,
        )?;
        validate_atlas_clock(request, &sources)?;
        ensure!(
            self.inner.prepared_size == Some((request.layout.width, request.layout.height)),
            "atlas GPU size must be prepared before capture admission"
        );
        let generation = Generation {
            identity: request.codec,
            epoch: request.identity.geometry_epoch,
            width: request.layout.width,
            height: request.layout.height,
        };
        validate_generation(self.inner.generation, generation)?;
        if let Some((frame_id, timestamp)) = self.inner.last_source {
            ensure!(
                request.identity.frame_id > frame_id
                    && request.identity.capture_monotonic_ns > timestamp,
                "atlas frame lineage did not advance"
            );
        }
        ensure!(
            request.identity.frame_id > 0 && request.identity.capture_monotonic_ns > 0,
            "atlas frame identity must be nonzero"
        );
        if self.inner.generation != Some(generation)
            || self.last_layout.as_ref() != Some(request.layout)
        {
            self.inner.force_idr = true;
            self.inner.alpha_cache = None;
        }
        self.inner.generation = Some(generation);
        let tiles = request
            .sources
            .iter()
            .map(|source| {
                let placement = request
                    .layout
                    .placements
                    .iter()
                    .find(|p| p.window == source.window)
                    .ok_or_else(|| anyhow::anyhow!("missing validated atlas placement"))?;
                Ok(GpuAtlasTile {
                    frame: source.frame,
                    x: i32::try_from(placement.allocation.x)?,
                    y: i32::try_from(placement.allocation.y)?,
                    deadline_monotonic_ns: source.deadline_monotonic_ns,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let outcome = self
            .inner
            .encoder
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("missing atlas GPU encoder"))?
            .encode_atlas_recoverable(
                &tiles,
                request.identity,
                self.inner.force_idr,
                request.deadline_monotonic_ns,
            )?;
        let outcome = self.inner.finish_submission(
            generation,
            (
                request.identity.frame_id,
                request.identity.capture_monotonic_ns,
            ),
            request.mapped_source_ns,
            outcome,
        )?;
        self.last_sources = sources
            .iter()
            .map(|source| (source.window, *source))
            .collect();
        self.last_layout = Some(request.layout.clone());
        Ok(match outcome {
            GpuSubmitOutcome::ExpiredClean => AtlasSubmitOutcome::ExpiredClean,
            GpuSubmitOutcome::Encoded(media) => AtlasSubmitOutcome::Encoded {
                manifest: Box::new(make_atlas_manifest(request, &sources, &media)?),
                layout: request.layout.clone(),
                sources,
                media,
            },
        })
    }
}

fn make_atlas_manifest(
    request: AtlasSubmission<'_>,
    sources: &[AtlasSourceIdentity],
    media: &[MediaFrame],
) -> Result<viewflow_protocol::AtlasFrame> {
    ensure!(media.len() == 1, "atlas must emit exactly one paired frame");
    let coded = &media[0];
    for plane in [&coded.color, &coded.alpha] {
        ensure!(
            plane.window_id == request.codec.window_id
                && plane.frame_id == request.identity.frame_id
                && plane.geometry_epoch == request.identity.geometry_epoch
                && plane.source_submitted_ns == request.mapped_source_ns,
            "atlas manifest/media identity mismatch"
        );
    }
    ensure!(
        coded.color_metadata.config_generation == request.codec.config_generation
            && coded.alpha_metadata.config_generation == request.codec.config_generation,
        "atlas manifest/media codec generation mismatch"
    );
    let by_window: BTreeMap<_, _> = sources
        .iter()
        .map(|source| (source.window, source))
        .collect();
    let mut tiles = request
        .layout
        .placements
        .iter()
        .map(|placement| {
            let source = by_window
                .get(&placement.window)
                .ok_or_else(|| anyhow::anyhow!("missing atlas source identity"))?;
            let delta = source
                .capture_monotonic_ns
                .checked_sub(request.identity.capture_monotonic_ns)
                .ok_or_else(|| anyhow::anyhow!("atlas source predates batch timestamp"))?;
            let mapped = request
                .mapped_source_ns
                .checked_add(delta)
                .ok_or_else(|| anyhow::anyhow!("atlas source clock mapping overflow"))?;
            Ok(viewflow_protocol::AtlasTile {
                window_id: placement.window,
                placement_generation: placement.generation,
                geometry_epoch: source.geometry_epoch,
                source_frame_id: source.frame_id,
                source_submitted_ns: mapped,
                x: placement.allocation.x,
                y: placement.allocation.y,
                width: placement.content_width,
                height: placement.content_height,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    tiles.sort_by_key(|tile| tile.window_id);
    let manifest = viewflow_protocol::AtlasFrame {
        color_keyframe: coded.color_metadata.keyframe,
        alpha_keyframe: coded.alpha_metadata.keyframe,
        desktop: request.desktop.cloned(),
        stream_id: request.codec.window_id,
        frame_id: request.identity.frame_id,
        geometry_epoch: request.identity.geometry_epoch,
        config_generation: request.codec.config_generation,
        layout_revision: request.layout.revision,
        width: request.layout.width,
        height: request.layout.height,
        source_submitted_ns: request.mapped_source_ns,
        tiles,
    };
    manifest
        .validate()
        .map_err(|error| anyhow::anyhow!("invalid atlas wire manifest: {error:?}"))?;
    Ok(manifest)
}

fn validate_atlas_clock(
    request: AtlasSubmission<'_>,
    sources: &[AtlasSourceIdentity],
) -> Result<()> {
    ensure!(
        request.codec.window_id.0 != 0 && request.mapped_source_ns > 0,
        "atlas stream identity and mapped timestamp required"
    );
    ensure!(
        sources
            .iter()
            .all(|source| source.window != request.codec.window_id),
        "atlas stream identity cannot alias a constituent window"
    );
    if let Some(oldest) = sources
        .iter()
        .map(|source| source.capture_monotonic_ns)
        .min()
    {
        ensure!(
            request.identity.capture_monotonic_ns == oldest,
            "atlas timestamp must preserve the oldest source capture time"
        );
    }
    Ok(())
}

fn validate_atlas_batch(
    layout: &AtlasSnapshot,
    sources: &[AtlasSourceIdentity],
    previous: Option<&AtlasSnapshot>,
    last_sources: &BTreeMap<WindowId, AtlasSourceIdentity>,
) -> Result<()> {
    ensure!(
        layout.width > 0
            && layout.height > 0
            && layout.width % 2 == 0
            && layout.height % 2 == 0
            && layout.placements.len() <= 4096
            && sources.len() == layout.placements.len(),
        "invalid atlas extent or source count"
    );
    if let Some(previous) = previous {
        ensure!(
            layout.revision >= previous.revision,
            "atlas layout revision regressed"
        );
        ensure!(
            layout.revision != previous.revision || layout == previous,
            "atlas layout changed without revision"
        );
    }
    let by_window: BTreeMap<_, _> = sources
        .iter()
        .map(|source| (source.window, source))
        .collect();
    ensure!(by_window.len() == sources.len(), "duplicate atlas source");
    let mut seen = BTreeMap::new();
    for placement in &layout.placements {
        ensure!(
            placement.window.0 != 0
                && placement.generation > 0
                && placement.generation <= layout.revision
                && placement.geometry_epoch > 0
                && placement.content_width > 0
                && placement.content_height > 0
                && placement.content_width <= placement.allocation.width
                && placement.content_height <= placement.allocation.height
                && placement
                    .allocation
                    .x
                    .checked_add(placement.allocation.width)
                    .is_some_and(|right| right <= layout.width)
                && placement
                    .allocation
                    .y
                    .checked_add(placement.allocation.height)
                    .is_some_and(|bottom| bottom <= layout.height),
            "invalid atlas placement"
        );
        ensure!(
            seen.insert(placement.window, placement).is_none(),
            "duplicate atlas placement"
        );
        let source = by_window
            .get(&placement.window)
            .ok_or_else(|| anyhow::anyhow!("missing atlas source"))?;
        ensure!(
            source.frame_id > 0
                && source.capture_monotonic_ns > 0
                && source.geometry_epoch == placement.geometry_epoch
                && source.width == placement.content_width
                && source.height == placement.content_height,
            "atlas source does not match placement: source={source:?} placement={placement:?}"
        );
        if let Some(old) = last_sources.get(&placement.window) {
            ensure!(
                source.frame_id > old.frame_id
                    && source.capture_monotonic_ns > old.capture_monotonic_ns
                    && source.geometry_epoch >= old.geometry_epoch,
                "atlas source lineage regressed or replayed"
            );
        }
        if let Some(previous) = previous {
            if let Some(old) = previous
                .placements
                .iter()
                .find(|p| p.window == placement.window)
            {
                ensure!(
                    placement == old || placement.generation > previous.revision,
                    "atlas placement changed without a fresh generation"
                );
            } else {
                ensure!(
                    placement.generation > previous.revision,
                    "reintroduced atlas placement is stale"
                );
            }
        }
    }
    validate_atlas_nonoverlap(layout)
}

// Called only after checked extent arithmetic for every placement.
fn validate_atlas_nonoverlap(layout: &AtlasSnapshot) -> Result<()> {
    for (i, a) in layout.placements.iter().enumerate() {
        for b in &layout.placements[..i] {
            let a = a.allocation;
            let b = b.allocation;
            ensure!(
                a.x >= b.x + b.width
                    || b.x >= a.x + a.width
                    || a.y >= b.y + b.height
                    || b.y >= a.y + a.height,
                "atlas allocations overlap"
            );
        }
    }
    Ok(())
}

/// Persistent, thread-bound producer; every error requires capture retirement.
pub struct GpuCompatibleEncoder {
    color_codec: VideoCodec,
    config: Config,
    encoder: Option<GpuEncoder>,
    prepared_size: Option<(u32, u32)>,
    generation: Option<Generation>,
    last_source: Option<(u64, u64)>,
    alpha_cache: Option<AlphaCache>,
    force_idr: bool,
    failed: bool,
}

impl GpuCompatibleEncoder {
    /// # Errors
    /// Rejects zero resource limits before creating a GPU context.
    pub fn new(config: Config) -> Result<Self> {
        ensure!(
            config.max_input_bytes > 0
                && config.max_color_access_unit_bytes > 0
                && config.max_alpha_access_unit_bytes > 0
                && config.max_pending_frames > 0,
            "GPU compatible encoder bounds must be nonzero"
        );
        Ok(Self {
            color_codec: VideoCodec::H264,
            config,
            encoder: None,
            prepared_size: None,
            generation: None,
            last_source: None,
            alpha_cache: None,
            force_idr: true,
            failed: false,
        })
    }

    #[must_use]
    pub fn descriptors(&self) -> Option<DescriptorPair> {
        self.generation.map(|generation| {
            let mut pair = descriptors(generation);
            pair.color.codec = self.color_codec;
            pair
        })
    }

    pub fn request_keyframe(&mut self) {
        self.force_idr = true;
    }

    /// Initialize the GPU while no compositor allocation is held or queued.
    /// This does not accept a frame or establish stream lineage.
    /// # Errors
    /// Rejects active/failed sessions, resource violations or GPU initialization failure.
    pub fn prepare_size(&mut self, width: u32, height: u32) -> Result<()> {
        ensure!(
            !self.failed && self.generation.is_none() && self.last_source.is_none(),
            "GPU preparation must precede stream admission"
        );
        self.failed = true;
        let pixels = usize::try_from(width)?
            .checked_mul(usize::try_from(height)?)
            .ok_or_else(|| anyhow::anyhow!("GPU frame size overflow"))?;
        ensure!(
            pixels
                .checked_mul(4)
                .is_some_and(|n| n <= self.config.max_input_bytes),
            "GPU frame exceeds input resource bound"
        );
        self.encoder = Some(GpuEncoder::new_with_codec(
            width,
            height,
            self.config.max_color_access_unit_bytes,
            pixels,
            self.color_codec,
        )?);
        self.prepared_size = Some((width, height));
        self.failed = false;
        Ok(())
    }

    /// Encode a GPU source into the existing H.264/VFAR transport contract.
    /// # Errors
    /// Rejects stale lineage, invalid generation, encoding/resource errors or
    /// expired deadlines. Any error poisons this adapter; caller must not ACK.
    pub fn submit(
        &mut self,
        identity: CodecIdentity,
        source: &GpuFrame,
        mapped_source_ns: u64,
        deadline: i64,
    ) -> Result<Vec<MediaFrame>> {
        ensure!(!self.failed, "GPU compatible encoder is retired");
        let result = self.submit_inner(identity, source, mapped_source_ns, deadline, false);
        if result.is_err() {
            self.failed = true;
            self.encoder = None;
            self.alpha_cache = None;
        }
        result.and_then(|outcome| match outcome {
            GpuSubmitOutcome::Encoded(frames) => Ok(frames),
            GpuSubmitOutcome::ExpiredClean => anyhow::bail!("legacy submit returned clean expiry"),
        })
    }

    /// Submit while allowing verified clean expiry to recover. A drained late
    /// NVENC packet resets both reference chains before the next submission.
    /// Completed coded frames may be stale after host transfer. The caller must
    /// drop them before transport and request a keyframe to repair references;
    /// they are deliberately not classified as pre-submission `ExpiredClean`.
    /// # Errors
    /// All other errors retire the adapter; no capture acknowledgement is safe.
    pub fn submit_recoverable(
        &mut self,
        identity: CodecIdentity,
        source: &GpuFrame,
        mapped_source_ns: u64,
        deadline: i64,
    ) -> Result<GpuSubmitOutcome> {
        ensure!(!self.failed, "GPU compatible encoder is retired");
        let result = self.submit_inner(identity, source, mapped_source_ns, deadline, true);
        if result.is_err() {
            self.failed = true;
            self.encoder = None;
            self.alpha_cache = None;
        }
        result
    }

    fn submit_inner(
        &mut self,
        identity: CodecIdentity,
        source: &GpuFrame,
        mapped_source_ns: u64,
        deadline: i64,
        allow_clean_expiry: bool,
    ) -> Result<GpuSubmitOutcome> {
        let header = source.metadata();
        ensure!(
            identity.config_generation > 0 && mapped_source_ns > 0,
            "nonzero codec generation/session timestamp required"
        );
        let generation = Generation {
            identity,
            epoch: header.geometry_epoch,
            width: header.crop_width,
            height: header.crop_height,
        };
        validate_generation(self.generation, generation)?;
        if let Some((sequence, timestamp)) = self.last_source {
            ensure!(
                header.sequence > sequence && header.capture_monotonic_ns > timestamp,
                "GPU capture lineage did not advance"
            );
        }
        let pixels = usize::try_from(generation.width)?
            .checked_mul(usize::try_from(generation.height)?)
            .ok_or_else(|| anyhow::anyhow!("GPU frame size overflow"))?;
        ensure!(
            pixels
                .checked_mul(4)
                .is_some_and(|bytes| bytes <= self.config.max_input_bytes),
            "GPU frame exceeds input resource bound"
        );
        if self.generation != Some(generation) {
            self.alpha_cache = None;
            if self.prepared_size != Some((generation.width, generation.height)) {
                self.encoder = None;
                self.encoder = Some(GpuEncoder::new_with_codec(
                    generation.width,
                    generation.height,
                    self.config.max_color_access_unit_bytes,
                    pixels,
                    self.color_codec,
                )?);
                self.prepared_size = Some((generation.width, generation.height));
            }
            self.generation = Some(generation);
            self.force_idr = true;
        }
        let encoder = self
            .encoder
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("missing GPU encoder"))?;
        let outcome = if allow_clean_expiry {
            encoder.encode_recoverable(source, self.force_idr, deadline)?
        } else {
            GpuEncodeOutcome::Encoded(encoder.encode(source, self.force_idr, deadline)?)
        };
        self.finish_submission(
            generation,
            (header.sequence, header.capture_monotonic_ns),
            mapped_source_ns,
            outcome,
        )
    }

    fn finish_submission(
        &mut self,
        generation: Generation,
        source_lineage: (u64, u64),
        mapped_source_ns: u64,
        outcome: GpuEncodeOutcome,
    ) -> Result<GpuSubmitOutcome> {
        let GpuEncodeOutcome::Encoded(encoded) = outcome else {
            // A drained late packet changed NVENC references despite having no
            // transport output. Repair both reference chains before continuing.
            if matches!(outcome, GpuEncodeOutcome::ExpiredAfterSubmission) {
                self.force_idr = true;
                self.alpha_cache = None;
            }
            self.last_source = Some(source_lineage);
            return Ok(GpuSubmitOutcome::ExpiredClean);
        };
        let frame = adapt(
            generation,
            encoded,
            mapped_source_ns,
            self.config,
            &mut self.alpha_cache,
        )?;
        self.force_idr = false;
        self.last_source = Some(source_lineage);
        Ok(GpuSubmitOutcome::Encoded(vec![frame]))
    }
}

fn validate_generation(previous: Option<Generation>, next: Generation) -> Result<()> {
    ensure!(
        next.epoch > 0 && next.identity.config_generation > 0 && next.width > 0 && next.height > 0,
        "invalid GPU codec geometry"
    );
    if let Some(previous) = previous {
        ensure!(
            next.identity.window_id == previous.identity.window_id,
            "GPU encoder cannot change window identity"
        );
        ensure!(
            next.epoch >= previous.epoch
                && next.identity.config_generation >= previous.identity.config_generation,
            "GPU codec generation regressed"
        );
        if next.epoch != previous.epoch
            || next.width != previous.width
            || next.height != previous.height
        {
            ensure!(
                next.identity.config_generation > previous.identity.config_generation,
                "changed GPU descriptor requires a new codec generation"
            );
        }
    }
    Ok(())
}

fn descriptors(generation: Generation) -> DescriptorPair {
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

fn adapt(
    generation: Generation,
    output: EncodedGpuFrame,
    mapped_source_ns: u64,
    config: Config,
    alpha_cache: &mut Option<AlphaCache>,
) -> Result<MediaFrame> {
    ensure!(
        output.geometry_epoch == generation.epoch && output.frame_id > 0,
        "GPU encoded generation mismatch"
    );
    ensure!(
        !output.color_annex_b.is_empty()
            && output.color_annex_b.len() <= config.max_color_access_unit_bytes,
        "GPU color exceeds transport bound"
    );
    let alpha = cached_alpha(generation, output.raw_alpha, config, alpha_cache)?;
    let plane = |kind, payload| MediaPlaneFrame {
        window_id: generation.identity.window_id,
        frame_id: output.frame_id,
        geometry_epoch: output.geometry_epoch,
        plane: kind,
        source_submitted_ns: mapped_source_ns,
        payload,
    };
    Ok(MediaFrame {
        color: plane(MediaPlane::Color, Bytes::from(output.color_annex_b)),
        alpha: plane(MediaPlane::Alpha, alpha),
        color_metadata: FrameCodecMetadata {
            config_generation: generation.identity.config_generation,
            keyframe: output.idr,
        },
        alpha_metadata: FrameCodecMetadata {
            config_generation: generation.identity.config_generation,
            keyframe: true,
        },
    })
}

fn cached_alpha(
    generation: Generation,
    raw_alpha: Vec<u8>,
    config: Config,
    cache: &mut Option<AlphaCache>,
) -> Result<Bytes> {
    if let Some(previous) = cache.as_ref()
        && previous.generation == generation
        && previous.config == config
        && previous.raw_alpha == raw_alpha
    {
        return Ok(previous.encoded.clone());
    }
    let encoded = encode_alpha_rle(generation.width, generation.height, &raw_alpha)?;
    ensure!(
        encoded.len() <= config.max_alpha_access_unit_bytes,
        "GPU lossless alpha exceeds transport bound"
    );
    let payload = encoded.clone();
    *cache = Some(AlphaCache {
        generation,
        config,
        raw_alpha,
        encoded,
    });
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn atlas_fixture() -> (viewflow_core::StableAtlas, Vec<AtlasSourceIdentity>) {
        let mut atlas = viewflow_core::StableAtlas::new(viewflow_core::AtlasConfig {
            width: 64,
            height: 64,
            alignment: 2,
            max_windows: 4,
        })
        .unwrap();
        let sources = (1..=2)
            .map(|id| {
                let window = viewflow_protocol::Id128(id);
                atlas.place(window, 1, 8, 8).unwrap();
                AtlasSourceIdentity {
                    window,
                    frame_id: 1,
                    capture_monotonic_ns: 10,
                    geometry_epoch: 1,
                    width: 8,
                    height: 8,
                }
            })
            .collect();
        (atlas, sources)
    }

    #[test]
    fn atlas_batch_requires_exact_membership_geometry_and_nonoverlap() {
        let (atlas, sources) = atlas_fixture();
        let layout = atlas.snapshot();
        let empty = BTreeMap::new();
        assert!(validate_atlas_batch(&layout, &sources, None, &empty).is_ok());
        assert!(validate_atlas_batch(&layout, &sources[..1], None, &empty).is_err());
        let mut duplicate = sources.clone();
        duplicate[1] = duplicate[0];
        assert!(validate_atlas_batch(&layout, &duplicate, None, &empty).is_err());
        for field in 0..5 {
            let mut bad = sources.clone();
            match field {
                0 => bad[0].geometry_epoch += 1,
                1 => bad[0].width += 1,
                2 => bad[0].frame_id = 0,
                3 => bad[0].capture_monotonic_ns = 0,
                _ => bad[0].window = viewflow_protocol::Id128(9),
            }
            assert!(validate_atlas_batch(&layout, &bad, None, &empty).is_err());
        }
        let mut overlap = layout.clone();
        overlap.placements[1].allocation = overlap.placements[0].allocation;
        assert!(validate_atlas_batch(&overlap, &sources, None, &empty).is_err());
        let mut overflow = layout.clone();
        overflow.placements[0].allocation.x = u32::MAX;
        assert!(validate_atlas_batch(&overflow, &sources, None, &empty).is_err());
        let mut duplicate = layout.clone();
        duplicate.placements[1] = duplicate.placements[0];
        assert!(validate_atlas_batch(&duplicate, &sources, None, &empty).is_err());
    }

    #[test]
    fn native_geometry_epoch_change_requires_a_new_atlas_placement() {
        let (mut atlas, sources) = atlas_fixture();
        let old = atlas.snapshot();
        let last: BTreeMap<_, _> = sources.iter().map(|s| (s.window, *s)).collect();
        let mut fresh: Vec<_> = sources
            .iter()
            .map(|s| AtlasSourceIdentity {
                frame_id: s.frame_id + 1,
                capture_monotonic_ns: s.capture_monotonic_ns + 1,
                ..*s
            })
            .collect();
        // A moved content rectangle can advance the capture epoch even when
        // its outer family dimensions have not changed. Old layout is invalid.
        fresh[0].geometry_epoch += 1;
        assert!(validate_atlas_batch(&old, &fresh, Some(&old), &last).is_err());
        atlas
            .place(fresh[0].window, fresh[0].geometry_epoch, 8, 8)
            .unwrap();
        let negotiated = atlas.snapshot();
        assert!(negotiated.revision > old.revision);
        assert!(validate_atlas_batch(&negotiated, &fresh, Some(&old), &last).is_ok());
        // Pixel growth also needs a matching new allocation, not scaling into
        // the old footprint or relabeling only the capture's epoch.
        fresh[0].width = 16;
        assert!(validate_atlas_batch(&negotiated, &fresh, Some(&old), &last).is_err());
        fresh[0].geometry_epoch += 1;
        atlas
            .place(fresh[0].window, fresh[0].geometry_epoch, 16, 8)
            .unwrap();
        assert!(validate_atlas_batch(&atlas.snapshot(), &fresh, Some(&negotiated), &last).is_ok());
    }

    #[test]
    fn atlas_batch_consumes_each_source_and_fences_layout_generations() {
        let (mut atlas, sources) = atlas_fixture();
        let old = atlas.snapshot();
        let last: BTreeMap<_, _> = sources.iter().map(|s| (s.window, *s)).collect();
        assert!(validate_atlas_batch(&old, &sources, Some(&old), &last).is_err());
        let fresh: Vec<_> = sources
            .iter()
            .map(|s| AtlasSourceIdentity {
                frame_id: s.frame_id + 1,
                capture_monotonic_ns: s.capture_monotonic_ns + 1,
                ..*s
            })
            .collect();
        assert!(validate_atlas_batch(&old, &fresh, Some(&old), &last).is_ok());
        let mut changed = old.clone();
        changed.width *= 2;
        assert!(validate_atlas_batch(&changed, &fresh, Some(&old), &last).is_err());
        changed = old.clone();
        changed.revision -= 1;
        assert!(validate_atlas_batch(&changed, &fresh, Some(&old), &last).is_err());
        atlas.remove(sources[1].window).unwrap();
        let removed = atlas.snapshot();
        assert!(validate_atlas_batch(&removed, &fresh[..1], Some(&old), &last).is_ok());
        let mut stale = old.clone();
        stale.revision = removed.revision + 1;
        assert!(validate_atlas_batch(&stale, &fresh, Some(&removed), &last).is_err());
        atlas.place(sources[1].window, 1, 8, 8).unwrap();
        assert!(validate_atlas_batch(&atlas.snapshot(), &fresh, Some(&removed), &last).is_ok());
    }

    #[test]
    fn atlas_continues_warmup_identity_without_resetting_source_floors() {
        let mut encoder = GpuAtlasCompatibleEncoder::new(config()).unwrap();
        assert_eq!(encoder.next_frame_id().unwrap(), 1);
        let (atlas, sources) = atlas_fixture();
        encoder.last_sources = sources.iter().map(|s| (s.window, *s)).collect();
        encoder.last_layout = Some(atlas.snapshot());
        encoder.inner.last_source = Some((3, 100));
        assert_eq!(encoder.next_frame_id().unwrap(), 4);
        encoder.request_keyframe();
        assert!(encoder.inner.force_idr);
        assert_eq!(encoder.inner.last_source, Some((3, 100)));
        assert_eq!(encoder.last_sources.len(), sources.len());
        assert!(
            validate_atlas_batch(
                &atlas.snapshot(),
                &sources,
                encoder.last_layout.as_ref(),
                &encoder.last_sources
            )
            .is_err()
        );
        encoder.inner.last_source = Some((u64::MAX, 100));
        assert!(encoder.next_frame_id().is_err());
        encoder.inner.failed = true;
        assert!(encoder.next_frame_id().is_err());
    }

    #[test]
    fn invalid_atlas_batch_retires_adapter_before_gpu_initialization() {
        let mut encoder = GpuAtlasCompatibleEncoder::new(Config {
            max_input_bytes: 4096,
            max_color_access_unit_bytes: 4096,
            max_alpha_access_unit_bytes: 4096,
            max_pending_frames: 1,
        })
        .unwrap();
        let layout = AtlasSnapshot {
            width: 0,
            height: 0,
            revision: 0,
            placements: vec![],
        };
        assert!(
            encoder
                .submit_recoverable(AtlasSubmission {
                    codec: generation().identity,
                    layout: &layout,
                    identity: GpuAtlasIdentity {
                        frame_id: 1,
                        capture_monotonic_ns: 1,
                        geometry_epoch: 1
                    },
                    mapped_source_ns: 1,
                    deadline_monotonic_ns: i64::MAX,
                    sources: &[],
                    desktop: None,
                })
                .is_err()
        );
        assert!(encoder.inner.failed && encoder.inner.encoder.is_none());
    }

    #[test]
    fn atlas_stream_identity_and_timestamp_cannot_disguise_window_freshness() {
        let (atlas, mut sources) = atlas_fixture();
        sources[1].capture_monotonic_ns = 20;
        let layout = atlas.snapshot();
        let request = AtlasSubmission {
            codec: CodecIdentity {
                window_id: viewflow_protocol::Id128(99),
                config_generation: 1,
            },
            layout: &layout,
            identity: GpuAtlasIdentity {
                frame_id: 1,
                capture_monotonic_ns: 10,
                geometry_epoch: 1,
            },
            mapped_source_ns: 100,
            deadline_monotonic_ns: i64::MAX,
            sources: &[],
            desktop: None,
        };
        assert!(validate_atlas_clock(request, &sources).is_ok());
        let newer = AtlasSubmission {
            identity: GpuAtlasIdentity {
                capture_monotonic_ns: 20,
                ..request.identity
            },
            ..request
        };
        assert!(validate_atlas_clock(newer, &sources).is_err());
        let alias = AtlasSubmission {
            codec: CodecIdentity {
                window_id: sources[0].window,
                ..request.codec
            },
            ..request
        };
        assert!(validate_atlas_clock(alias, &sources).is_err());
    }

    #[test]
    fn atlas_wire_manifest_binds_planes_and_maps_each_source_clock() {
        let (atlas, mut sources) = atlas_fixture();
        sources[1].capture_monotonic_ns = 20;
        let layout = atlas.snapshot();
        let request = AtlasSubmission {
            codec: CodecIdentity {
                window_id: viewflow_protocol::Id128(99),
                config_generation: 2,
            },
            layout: &layout,
            identity: GpuAtlasIdentity {
                frame_id: 77,
                capture_monotonic_ns: 10,
                geometry_epoch: 9,
            },
            mapped_source_ns: 100,
            deadline_monotonic_ns: i64::MAX,
            sources: &[],
            desktop: None,
        };
        // Synthetic coded bytes exercise metadata adaptation, not H.264 decode.
        let mut media = vec![
            adapt(
                Generation {
                    identity: request.codec,
                    epoch: 9,
                    width: 64,
                    height: 64,
                },
                EncodedGpuFrame {
                    frame_id: 77,
                    capture_monotonic_ns: 10,
                    geometry_epoch: 9,
                    idr: true,
                    color_annex_b: vec![0, 0, 0, 1, 0x65],
                    raw_alpha: vec![0; 4096],
                },
                100,
                Config {
                    max_input_bytes: 16384,
                    max_color_access_unit_bytes: 1024,
                    max_alpha_access_unit_bytes: 8192,
                    max_pending_frames: 1,
                },
                &mut None,
            )
            .unwrap(),
        ];
        let manifest = make_atlas_manifest(request, &sources, &media).unwrap();
        assert_eq!(manifest.frame_id, 77);
        assert_eq!(manifest.geometry_epoch, 9);
        assert_eq!(manifest.layout_revision, layout.revision);
        assert_eq!(manifest.tiles[0].source_submitted_ns, 100);
        assert_eq!(manifest.tiles[1].source_submitted_ns, 110);
        assert_eq!(manifest.tiles[0].geometry_epoch, 1);
        assert_eq!(
            viewflow_protocol::AtlasFrame::try_from(viewflow_protocol::wire::AtlasFrame::from(
                manifest.clone()
            ))
            .unwrap(),
            manifest
        );
        media[0].alpha.frame_id += 1;
        assert!(make_atlas_manifest(request, &sources, &media).is_err());
        media[0].alpha.frame_id -= 1;
        let overflow = AtlasSubmission {
            mapped_source_ns: u64::MAX - 5,
            ..request
        };
        media[0].color.source_submitted_ns = overflow.mapped_source_ns;
        media[0].alpha.source_submitted_ns = overflow.mapped_source_ns;
        assert!(make_atlas_manifest(overflow, &sources, &media).is_err());
    }

    #[test]
    fn clean_expiry_consumes_lineage_without_changing_pending_idr_or_alpha() {
        let config = Config {
            max_input_bytes: 16,
            max_color_access_unit_bytes: 1024,
            max_alpha_access_unit_bytes: 1024,
            max_pending_frames: 1,
        };
        for pending_idr in [false, true] {
            let mut encoder = GpuCompatibleEncoder::new(config).unwrap();
            encoder.generation = Some(generation());
            encoder.force_idr = pending_idr;
            encoder.last_source = Some((10, 100));
            encoder.alpha_cache = Some(AlphaCache {
                generation: generation(),
                config,
                raw_alpha: vec![7; 4],
                encoded: Bytes::from_static(b"cached"),
            });
            assert!(matches!(
                encoder
                    .finish_submission(generation(), (11, 110), 900, GpuEncodeOutcome::ExpiredClean)
                    .unwrap(),
                GpuSubmitOutcome::ExpiredClean
            ));
            assert_eq!(encoder.last_source, Some((11, 110)));
            assert_eq!(encoder.force_idr, pending_idr);
            assert!(!encoder.failed);
            let cache = encoder.alpha_cache.as_ref().unwrap();
            assert_eq!(cache.raw_alpha, vec![7; 4]);
            assert_eq!(cache.encoded.as_ref(), b"cached");
        }
    }
    #[test]
    fn drained_late_packet_consumes_lineage_and_repairs_both_reference_chains() {
        let config = Config {
            max_input_bytes: 16,
            max_color_access_unit_bytes: 1024,
            max_alpha_access_unit_bytes: 1024,
            max_pending_frames: 1,
        };
        let mut encoder = GpuCompatibleEncoder::new(config).unwrap();
        encoder.force_idr = false;
        encoder.alpha_cache = Some(AlphaCache {
            generation: generation(),
            config,
            raw_alpha: vec![7; 4],
            encoded: Bytes::from_static(b"cached"),
        });
        assert!(matches!(
            encoder
                .finish_submission(
                    generation(),
                    (11, 110),
                    900,
                    GpuEncodeOutcome::ExpiredAfterSubmission
                )
                .unwrap(),
            GpuSubmitOutcome::ExpiredClean
        ));
        assert_eq!(encoder.last_source, Some((11, 110)));
        assert!(encoder.force_idr);
        assert!(encoder.alpha_cache.is_none());
        assert!(!encoder.failed);
    }

    fn generation() -> Generation {
        Generation {
            identity: CodecIdentity {
                window_id: viewflow_protocol::Id128(1),
                config_generation: 1,
            },
            epoch: 1,
            width: 2,
            height: 2,
        }
    }
    #[test]
    fn descriptor_changes_require_new_generation() {
        let old = generation();
        let mut next = old;
        next.width = 4;
        assert!(validate_generation(Some(old), next).is_err());
        next.identity.config_generation = 2;
        assert!(validate_generation(Some(old), next).is_ok());
        next.epoch = 0;
        assert!(validate_generation(Some(old), next).is_err());
    }
    #[test]
    fn gpu_transport_keeps_alpha_and_session_lineage() {
        let generation = generation();
        let config = Config {
            max_input_bytes: 16,
            max_color_access_unit_bytes: 1024,
            max_alpha_access_unit_bytes: 1024,
            max_pending_frames: 1,
        };
        let frame = adapt(
            generation,
            EncodedGpuFrame {
                frame_id: 9,
                capture_monotonic_ns: 100,
                geometry_epoch: 1,
                idr: true,
                color_annex_b: vec![0, 0, 0, 1, 0x65],
                raw_alpha: vec![0, 1, 128, 255],
            },
            200,
            config,
            &mut None,
        )
        .unwrap();
        assert_eq!(frame.color.source_submitted_ns, 200);
        assert_eq!(frame.alpha.source_submitted_ns, 200);
        assert_eq!(frame.color.frame_id, frame.alpha.frame_id);
        assert_eq!(
            frame.alpha.payload,
            encode_alpha_rle(2, 2, &[0, 1, 128, 255]).unwrap()
        );
        let decoded = viewflow_transport::decode_alpha_rle(
            frame.alpha.payload.clone(),
            viewflow_transport::AlphaRleLimits {
                max_coded_width: 2,
                max_coded_height: 2,
                max_luma_samples: 4,
                max_decoded_bytes: 4,
                max_encoded_bytes: 1024,
            },
        )
        .unwrap();
        assert_eq!((decoded.width, decoded.height), (2, 2));
        assert_eq!(decoded.samples.as_ref(), &[0, 1, 128, 255]);
        assert!(frame.alpha_metadata.keyframe);
        assert_eq!(
            descriptors(generation).color.colorimetry,
            Colorimetry::Bt709Limited
        );
    }

    fn output(frame_id: u64, generation: Generation, raw_alpha: Vec<u8>) -> EncodedGpuFrame {
        EncodedGpuFrame {
            frame_id,
            capture_monotonic_ns: frame_id * 10,
            geometry_epoch: generation.epoch,
            idr: frame_id == 1,
            color_annex_b: vec![0, 0, 0, 1, 0x65],
            raw_alpha,
        }
    }

    fn config() -> Config {
        Config {
            max_input_bytes: 64,
            max_color_access_unit_bytes: 1024,
            max_alpha_access_unit_bytes: 1024,
            max_pending_frames: 1,
        }
    }

    #[test]
    fn lossless_alpha_cache_reuses_bytes_but_preserves_new_frame_metadata() {
        let generation = generation();
        let mut cache = None;
        let first = adapt(
            generation,
            output(1, generation, vec![0, 1, 128, 255]),
            100,
            config(),
            &mut cache,
        )
        .unwrap();
        let second = adapt(
            generation,
            output(2, generation, vec![0, 1, 128, 255]),
            200,
            config(),
            &mut cache,
        )
        .unwrap();
        assert_eq!(first.alpha.payload.as_ptr(), second.alpha.payload.as_ptr());
        assert_eq!(second.alpha.frame_id, 2);
        assert_eq!(second.alpha.source_submitted_ns, 200);
        assert_eq!(second.color.frame_id, 2);
        assert_eq!(second.color.source_submitted_ns, 200);
    }

    #[test]
    fn lossless_alpha_cache_reencodes_changed_samples_exactly() {
        let generation = generation();
        let mut cache = None;
        let _ = adapt(
            generation,
            output(1, generation, vec![0, 1, 128, 255]),
            100,
            config(),
            &mut cache,
        )
        .unwrap();
        let changed = adapt(
            generation,
            output(2, generation, vec![0, 1, 129, 255]),
            200,
            config(),
            &mut cache,
        )
        .unwrap();
        let decoded = viewflow_transport::decode_alpha_rle(
            changed.alpha.payload,
            viewflow_transport::AlphaRleLimits {
                max_coded_width: 2,
                max_coded_height: 2,
                max_luma_samples: 4,
                max_decoded_bytes: 4,
                max_encoded_bytes: 1024,
            },
        )
        .unwrap();
        assert_eq!(decoded.samples.as_ref(), &[0, 1, 129, 255]);
    }

    #[test]
    fn lossless_alpha_cache_invalidates_generation_dimensions_and_config() {
        let old = generation();
        let mut cache = None;
        let first = cached_alpha(old, vec![0, 1, 128, 255], config(), &mut cache).unwrap();
        let mut changed = old;
        changed.identity.config_generation = 2;
        changed.epoch = 2;
        let generation_changed =
            cached_alpha(changed, vec![0, 1, 128, 255], config(), &mut cache).unwrap();
        assert_ne!(first.as_ptr(), generation_changed.as_ptr());
        changed.width = 1;
        changed.height = 4;
        let dimensions_changed =
            cached_alpha(changed, vec![0, 1, 128, 255], config(), &mut cache).unwrap();
        assert_ne!(generation_changed.as_ptr(), dimensions_changed.as_ptr());
        let mut config_changed = config();
        config_changed.max_pending_frames = 2;
        let config_changed =
            cached_alpha(changed, vec![0, 1, 128, 255], config_changed, &mut cache).unwrap();
        assert_ne!(dimensions_changed.as_ptr(), config_changed.as_ptr());
    }
}
