//! Thread-bound DMA-BUF to CUDA/NVENC ownership boundary.
//!
//! This module never sends HCGR. On any error the capture session must retire;
//! successful native encoding is not proof of remote presentation.
#![allow(unsafe_code)] // Reviewed C ABI and CLOCK_MONOTONIC boundary.

use std::{marker::PhantomData, os::fd::AsRawFd, ptr::NonNull, rc::Rc};

use anyhow::{Context, Result, bail, ensure};

use crate::hyprcapture_gpu_socket::GpuFrame;

#[repr(C)]
struct EncoderOpaque {
    _private: [u8; 0],
}
#[repr(C)]
struct OutputOpaque {
    _private: [u8; 0],
}
#[repr(C)]
struct CConfig {
    width: u32,
    height: u32,
    max_access_unit_bytes: u64,
}
#[repr(C)]
#[derive(Default)]
struct CFrame {
    dma_buf_fd: i32,
    native_fence_fd: i32,
    image_width: u32,
    image_height: u32,
    stride: u32,
    offset: u32,
    fourcc: u32,
    modifier: u64,
    crop_x: i32,
    crop_y: i32,
    crop_width: i32,
    crop_height: i32,
    flip_y: u32,
    frame_id: u64,
    capture_timestamp_ns: u64,
    geometry_epoch: u64,
    shadow_enabled: u32,
    shadow_left: f64,
    shadow_top: f64,
    shadow_width: f64,
    shadow_height: f64,
    shadow_cutout_left: f64,
    shadow_cutout_top: f64,
    shadow_cutout_width: f64,
    shadow_cutout_height: f64,
    shadow_range: f64,
    shadow_rounding: f64,
    shadow_window_rounding: f64,
    shadow_rounding_power: f64,
    shadow_power: u32,
    shadow_red: u8,
    shadow_green: u8,
    shadow_blue: u8,
    shadow_alpha: u8,
    shadow_sharp: u32,
}
impl CFrame {
    fn from_gpu(frame: &GpuFrame) -> Result<Self> {
        let header = frame.metadata();
        let mut input = Self {
            dma_buf_fd: frame.image_fd().as_raw_fd(),
            native_fence_fd: frame.fence_fd().as_raw_fd(),
            image_width: header.image_width,
            image_height: header.image_height,
            stride: header.stride,
            offset: u32::try_from(header.offset)?,
            fourcc: header.fourcc,
            modifier: header.modifier,
            crop_x: i32::try_from(header.crop_x)?,
            crop_y: i32::try_from(header.crop_y)?,
            crop_width: i32::try_from(header.crop_width)?,
            crop_height: i32::try_from(header.crop_height)?,
            flip_y: u32::from(header.flip_y),
            frame_id: header.sequence,
            capture_timestamp_ns: header.capture_monotonic_ns,
            geometry_epoch: header.geometry_epoch,
            ..Self::default()
        };
        if let Some(shadow) = &header.shadow {
            input.set_shadow(shadow);
        }
        Ok(input)
    }

    fn set_shadow(&mut self, shadow: &crate::hyprcapture_gpu_wire::ShadowSnapshot) {
        self.shadow_enabled = 1;
        self.shadow_left = shadow.left;
        self.shadow_top = shadow.top;
        self.shadow_width = shadow.width;
        self.shadow_height = shadow.height;
        self.shadow_cutout_left = shadow.cutout_left;
        self.shadow_cutout_top = shadow.cutout_top;
        self.shadow_cutout_width = shadow.cutout_width;
        self.shadow_cutout_height = shadow.cutout_height;
        self.shadow_range = shadow.range;
        self.shadow_rounding = shadow.rounding;
        self.shadow_window_rounding = shadow.window_rounding;
        self.shadow_rounding_power = shadow.rounding_power;
        self.shadow_power = shadow.power;
        self.shadow_sharp = u32::from(shadow.sharp);
        [
            self.shadow_red,
            self.shadow_green,
            self.shadow_blue,
            self.shadow_alpha,
        ] = shadow.rgba;
    }
}
#[repr(C)]
struct CAtlasTile {
    frame: CFrame,
    x: i32,
    y: i32,
    deadline_monotonic_ns: i64,
}
#[repr(C)]
struct CAtlas {
    struct_size: u32,
    version: u32,
    tile_count: u32,
    reserved: u32,
    tiles: *const CAtlasTile,
    frame_id: u64,
    capture_timestamp_ns: u64,
    geometry_epoch: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GpuSparseSource {
    pub x: i64,
    pub y: i64,
    pub z: u32,
    pub grid: u32,
    pub clip_enabled: u32,
    pub clip_x: u32,
    pub clip_y: u32,
    pub clip_width: u32,
    pub clip_height: u32,
}
#[repr(C)]
struct CSparseScene {
    mode: u32,
    max_width: u32,
    max_height: u32,
    source_count: u32,
    sources: *const GpuSparseSource,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GpuSparsePatch {
    pub source: u32,
    pub source_x: u32,
    pub source_y: u32,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GpuSparseInfo {
    pub enabled: u32,
    pub patch_count: u32,
    pub required_width: u32,
    pub required_height: u32,
    pub input_pixels: u64,
    pub stored_pixels: u64,
    pub occluded_pixels: u64,
    pub empty_pixels: u64,
    pub omitted_pixels: u64,
}
#[derive(Debug)]
pub struct GpuSparseResult {
    pub info: GpuSparseInfo,
    pub patches: Vec<GpuSparsePatch>,
}
pub struct GpuSparseScene<'a> {
    pub prerender: bool,
    pub canvas_limit: (u32, u32),
    pub sources: &'a [GpuSparseSource],
}

#[repr(C)]
#[derive(Default)]
struct CInfo {
    frame_id: u64,
    capture_timestamp_ns: u64,
    geometry_epoch: u64,
    idr: u32,
    color_annex_b_bytes: u64,
    raw_alpha_bytes: u64,
}

unsafe extern "C" {
    fn vf_gpu_dmabuf_encoder_encode_sparse_recoverable(
        encoder: *mut EncoderOpaque,
        atlas: *const CAtlas,
        scene: *const CSparseScene,
        force_idr: u32,
        deadline: i64,
        output: *mut *mut OutputOpaque,
    ) -> u32;
    fn vf_gpu_dmabuf_output_get_sparse_info(
        output: *const OutputOpaque,
        info: *mut GpuSparseInfo,
    ) -> u32;
    fn vf_gpu_dmabuf_output_copy_sparse_patches(
        output: *const OutputOpaque,
        patches: *mut GpuSparsePatch,
        capacity: usize,
        required: *mut usize,
    ) -> u32;

    fn vf_gpu_dmabuf_encoder_create_with_codec(
        config: *const CConfig,
        codec: u32,
        output: *mut *mut EncoderOpaque,
    ) -> u32;
    fn vf_gpu_dmabuf_encoder_destroy(encoder: *mut EncoderOpaque) -> u32;
    fn vf_gpu_dmabuf_encoder_copy_last_error(
        encoder: *const EncoderOpaque,
        destination: *mut std::ffi::c_char,
        capacity: usize,
        required: *mut usize,
    ) -> u32;
    fn vf_gpu_dmabuf_encoder_encode(
        encoder: *mut EncoderOpaque,
        frame: *const CFrame,
        force_idr: u32,
        deadline: i64,
        output: *mut *mut OutputOpaque,
    ) -> u32;
    fn vf_gpu_dmabuf_encoder_encode_recoverable(
        encoder: *mut EncoderOpaque,
        frame: *const CFrame,
        force_idr: u32,
        deadline: i64,
        output: *mut *mut OutputOpaque,
    ) -> u32;
    fn vf_gpu_dmabuf_encoder_encode_atlas_recoverable(
        encoder: *mut EncoderOpaque,
        atlas: *const CAtlas,
        force_idr: u32,
        deadline: i64,
        output: *mut *mut OutputOpaque,
    ) -> u32;
    fn vf_gpu_dmabuf_output_get_info(output: *const OutputOpaque, info: *mut CInfo) -> u32;
    fn vf_gpu_dmabuf_output_copy_color(
        output: *const OutputOpaque,
        destination: *mut u8,
        capacity: usize,
        required: *mut usize,
    ) -> u32;
    fn vf_gpu_dmabuf_output_copy_raw_alpha(
        output: *const OutputOpaque,
        destination: *mut u8,
        capacity: usize,
        required: *mut usize,
    ) -> u32;
    fn vf_gpu_dmabuf_output_view_raw_alpha(
        output: *const OutputOpaque,
        data: *mut *const u8,
        length: *mut usize,
    ) -> u32;
    fn vf_gpu_dmabuf_output_destroy(output: *mut OutputOpaque) -> u32;
}

/// Immutable alpha storage, retained with its native output on the encoding thread.
/// Native allocations are independent of the encoder and are never converted into
/// a Rust Vec: the allocator and destructor must remain paired across the ABI.
/// The Rc marker also keeps the owned-copy variant on the same thread.
pub struct RawAlpha {
    storage: AlphaStorage,
    _owner_thread: PhantomData<Rc<()>>,
}

enum AlphaStorage {
    Owned(Vec<u8>),
    Native {
        _output: Output,
        data: NonNull<u8>,
        length: usize,
    },
}

impl From<Vec<u8>> for RawAlpha {
    fn from(bytes: Vec<u8>) -> Self {
        Self {
            storage: AlphaStorage::Owned(bytes),
            _owner_thread: PhantomData,
        }
    }
}

impl AsRef<[u8]> for RawAlpha {
    fn as_ref(&self) -> &[u8] {
        match &self.storage {
            AlphaStorage::Owned(bytes) => bytes,
            AlphaStorage::Native { data, length, .. } => {
                // SAFETY: successful ABI validation established initialized length;
                // _output retains this immutable allocation for the whole borrow.
                // RawAlpha is !Send/!Sync and the pointer never escapes as mutable.
                unsafe { std::slice::from_raw_parts(data.as_ptr(), *length) }
            }
        }
    }
}

impl std::ops::Deref for RawAlpha {
    type Target = [u8];
    fn deref(&self) -> &Self::Target {
        self.as_ref()
    }
}

/// Encoded color and independent, lossless straight-alpha bytes.
pub struct EncodedGpuFrame {
    pub sparse: Option<GpuSparseResult>,
    pub frame_id: u64,
    pub capture_monotonic_ns: u64,
    pub geometry_epoch: u64,
    pub idr: bool,
    pub color_annex_b: Vec<u8>,
    pub raw_alpha: RawAlpha,
}

/// A coded frame or verified expiry with completed GPU cleanup.
pub enum GpuEncodeOutcome {
    Encoded(EncodedGpuFrame),
    ExpiredClean,
    /// Packet drained and GPU cleanup complete; repair color and alpha references.
    ExpiredAfterSubmission,
    /// All reads completed; caller releases leases before reallocating.
    NeedsCanvas {
        width: u32,
        height: u32,
    },
}

/// Identity of the entire encoded atlas, independent of its constituent windows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GpuAtlasIdentity {
    pub frame_id: u64,
    pub capture_monotonic_ns: u64,
    pub geometry_epoch: u64,
}

/// Borrows an authenticated source and its original (never renewed) lease deadline.
pub struct GpuAtlasTile<'a> {
    pub frame: &'a GpuFrame,
    pub x: i32,
    pub y: i32,
    pub deadline_monotonic_ns: i64,
}

#[derive(Clone, Copy)]
struct EncodeExpectation {
    identity: GpuAtlasIdentity,
    force_idr: bool,
    deadline: i64,
    allow_clean_expiry: bool,
}

fn admits_clean_expiry(opted_in: bool, status: u32, has_output: bool) -> bool {
    opted_in && status == 8 && !has_output
}

fn validate_output_transfer_deadline(
    recoverable: bool,
    completed: i64,
    deadline: i64,
) -> Result<()> {
    // Only called after successful native completion, lineage validation and
    // both host copies. A completed coded output is NOT pre-submission expiry:
    // the live caller must drop stale output and request a new IDR before send.
    ensure!(
        recoverable || completed < deadline,
        "GPU frame expired during output transfer ({} ns past deadline)",
        completed.saturating_sub(deadline)
    );
    Ok(())
}

/// Create/use/drop on the same worker; `Rc` marker prevents Send and Sync.
pub struct GpuEncoder {
    raw: NonNull<EncoderOpaque>,
    width: u32,
    height: u32,
    max_color: usize,
    alpha_bytes: usize,
    failed: bool,
    _thread_bound: PhantomData<Rc<()>>,
}

impl GpuEncoder {
    /// Allocate a persistent encoder before attempting a deadline-bound frame.
    /// # Errors
    /// Rejects invalid dimensions/resource limits or unavailable GPU encoding.
    pub fn new(width: u32, height: u32, max_color: usize, max_alpha: usize) -> Result<Self> {
        Self::new_with_codec(
            width,
            height,
            max_color,
            max_alpha,
            viewflow_transport::VideoCodec::H264,
        )
    }

    pub fn new_with_codec(
        width: u32,
        height: u32,
        max_color: usize,
        max_alpha: usize,
        codec: viewflow_transport::VideoCodec,
    ) -> Result<Self> {
        ensure!(
            matches!(
                codec,
                viewflow_transport::VideoCodec::H264 | viewflow_transport::VideoCodec::Av1
            ),
            "unsupported NVENC color codec"
        );
        ensure!(
            width >= 2 && height >= 2 && width % 2 == 0 && height % 2 == 0,
            "GPU encoder requires positive even dimensions"
        );
        let alpha_bytes = usize::try_from(width)?
            .checked_mul(usize::try_from(height)?)
            .ok_or_else(|| anyhow::anyhow!("alpha dimensions overflow"))?;
        ensure!(
            max_color > 0 && alpha_bytes <= max_alpha,
            "GPU output exceeds resource bounds"
        );
        let config = CConfig {
            width,
            height,
            max_access_unit_bytes: u64::try_from(max_color)?,
        };
        let mut raw = std::ptr::null_mut();
        // SAFETY: config and output slot are valid for the synchronous call.
        let status = unsafe {
            vf_gpu_dmabuf_encoder_create_with_codec(&raw const config, codec as u32, &raw mut raw)
        };
        if status != 0 {
            if !raw.is_null() {
                // SAFETY: defensive cleanup of an unexpected returned owned handle.
                unsafe { vf_gpu_dmabuf_encoder_destroy(raw) };
            }
            bail!("GPU encoder creation failed with status {status}");
        }
        Ok(Self {
            raw: NonNull::new(raw).ok_or_else(|| anyhow::anyhow!("null GPU encoder"))?,
            width,
            height,
            max_color,
            alpha_bytes,
            failed: false,
            _thread_bound: PhantomData,
        })
    }

    /// Encode one authenticated source without changing its original timestamp.
    /// # Errors
    /// Any failure poisons this wrapper; caller must retire capture without HCGR.
    pub fn encode(
        &mut self,
        frame: &GpuFrame,
        force_idr: bool,
        deadline: i64,
    ) -> Result<EncodedGpuFrame> {
        ensure!(!self.failed, "GPU encoder session is retired");
        let result = self
            .encode_checked(frame, force_idr, deadline, false)
            .and_then(|outcome| match outcome {
                GpuEncodeOutcome::Encoded(frame) => Ok(frame),
                GpuEncodeOutcome::ExpiredClean
                | GpuEncodeOutcome::ExpiredAfterSubmission
                | GpuEncodeOutcome::NeedsCanvas { .. } => {
                    anyhow::bail!("legacy encoder returned recoverable expiry")
                }
            });
        if result.is_err() {
            self.failed = true;
        }
        result
    }

    /// Opt in to dropping an expired frame after verified GPU cleanup.
    /// Completed coded output can already be stale on return: callers must
    /// check freshness and recover the reference chain with an IDR when dropped.
    /// `ExpiredClean` permits releasing only this frame's capture lease; it
    /// does not represent coded output or authorize replay of this frame.
    /// # Errors
    /// `ExpiredAfterSubmission` also requires repairing color and alpha references.
    /// Any other failure retires this wrapper and must not produce HCGR.
    pub fn encode_recoverable(
        &mut self,
        frame: &GpuFrame,
        force_idr: bool,
        deadline: i64,
    ) -> Result<GpuEncodeOutcome> {
        ensure!(!self.failed, "GPU encoder session is retired");
        let result = self.encode_checked(frame, force_idr, deadline, true);
        if result.is_err() {
            self.failed = true;
        }
        result
    }

    /// Encode one layout as one paired color/alpha frame. This is not an input
    /// authorization or transport mapping; the caller retains those identities.
    /// All capture leases remain borrowed through return. `ExpiredClean` covers
    /// the whole batch, with no NVENC submission. `ExpiredAfterSubmission` proves
    /// a drained packet and whole-batch cleanup, but requires reference repair.
    /// Other errors require retiring
    /// every capture session in the batch without HCGR.
    /// # Errors
    /// Any non-clean failure retires this wrapper. Coded output may be stale on
    /// return; dropping it requires IDR recovery, just like the single-frame API.
    pub fn encode_atlas_recoverable(
        &mut self,
        tiles: &[GpuAtlasTile<'_>],
        identity: GpuAtlasIdentity,
        force_idr: bool,
        deadline: i64,
    ) -> Result<GpuEncodeOutcome> {
        self.encode_atlas_with_scene(tiles, identity, force_idr, deadline, None)
    }

    pub fn encode_atlas_with_scene(
        &mut self,
        tiles: &[GpuAtlasTile<'_>],
        identity: GpuAtlasIdentity,
        force_idr: bool,
        deadline: i64,
        scene: Option<GpuSparseScene<'_>>,
    ) -> Result<GpuEncodeOutcome> {
        ensure!(!self.failed, "GPU encoder session is retired");
        let result = (|| {
            ensure!(tiles.len() <= 4096, "atlas tile bound exceeded");
            let deadline = tiles.iter().fold(deadline, |current, tile| {
                current.min(tile.deadline_monotonic_ns)
            });
            if monotonic_ns()? >= deadline {
                // No native submission or source read has begun. Return the
                // existing clean-drop result instead of retiring the stream.
                return Ok(GpuEncodeOutcome::ExpiredClean);
            }
            let native_tiles = tiles
                .iter()
                .map(|tile| {
                    Ok(CAtlasTile {
                        frame: CFrame::from_gpu(tile.frame)?,
                        x: tile.x,
                        y: tile.y,
                        deadline_monotonic_ns: tile.deadline_monotonic_ns,
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            let atlas = CAtlas {
                struct_size: u32::try_from(std::mem::size_of::<CAtlas>())?,
                version: 1,
                tile_count: u32::try_from(native_tiles.len())?,
                reserved: 0,
                tiles: native_tiles.as_ptr(),
                frame_id: identity.frame_id,
                capture_timestamp_ns: identity.capture_monotonic_ns,
                geometry_epoch: identity.geometry_epoch,
            };
            let mut output = std::ptr::null_mut();
            // SAFETY: thread-bound encoder, exact C layouts, live tile array and
            // borrowed GPU frames/FDs for the duration of the synchronous call.
            let status = if let Some(scene) = scene {
                ensure!(
                    scene.sources.len() == native_tiles.len(),
                    "sparse source count mismatch"
                );
                let scene = CSparseScene {
                    mode: if scene.prerender { 2 } else { 1 },
                    max_width: scene.canvas_limit.0,
                    max_height: scene.canvas_limit.1,
                    source_count: u32::try_from(scene.sources.len())?,
                    sources: scene.sources.as_ptr(),
                };
                // SAFETY: source descriptors and borrowed frames are live until this synchronous call returns.
                unsafe {
                    vf_gpu_dmabuf_encoder_encode_sparse_recoverable(
                        self.raw.as_ptr(),
                        &raw const atlas,
                        &raw const scene,
                        u32::from(force_idr),
                        deadline,
                        &raw mut output,
                    )
                }
            } else {
                // SAFETY: thread-owned encoder and exact C layouts with borrowed live descriptors.
                unsafe {
                    vf_gpu_dmabuf_encoder_encode_atlas_recoverable(
                        self.raw.as_ptr(),
                        &raw const atlas,
                        u32::from(force_idr),
                        deadline,
                        &raw mut output,
                    )
                }
            };
            self.finish_encode(
                status,
                output,
                EncodeExpectation {
                    identity,
                    force_idr,
                    deadline,
                    allow_clean_expiry: true,
                },
            )
        })();
        if result.is_err() {
            self.failed = true;
        }
        result
    }

    fn last_error(&self) -> String {
        let mut diagnostic = [0_u8; 256];
        let mut required = 0;
        // SAFETY: live thread-owned encoder, bounded writable error buffer.
        let copied = unsafe {
            vf_gpu_dmabuf_encoder_copy_last_error(
                self.raw.as_ptr(),
                diagnostic.as_mut_ptr().cast(),
                diagnostic.len(),
                &raw mut required,
            )
        };
        if copied == 0 && required > 0 && required <= diagnostic.len() {
            String::from_utf8_lossy(&diagnostic[..required - 1]).into_owned()
        } else {
            "diagnostic unavailable".to_owned()
        }
    }

    fn encode_checked(
        &self,
        frame: &GpuFrame,
        force_idr: bool,
        deadline: i64,
        allow_clean_expiry: bool,
    ) -> Result<GpuEncodeOutcome> {
        let header = frame.metadata();
        ensure!(
            header.crop_width == self.width && header.crop_height == self.height,
            "resize requires a new GPU encoder"
        );
        ensure!(
            monotonic_ns()? < deadline,
            "GPU frame expired before encoding"
        );
        let input = CFrame::from_gpu(frame)?;
        let mut output = std::ptr::null_mut();
        // SAFETY: both borrowed FDs and input remain alive throughout the call;
        // the encoder is thread-bound and exclusively borrowed by encode().
        let encode_call = if allow_clean_expiry {
            vf_gpu_dmabuf_encoder_encode_recoverable
        } else {
            vf_gpu_dmabuf_encoder_encode
        };
        let status = unsafe {
            encode_call(
                self.raw.as_ptr(),
                &raw const input,
                u32::from(force_idr),
                deadline,
                &raw mut output,
            )
        };
        self.finish_encode(
            status,
            output,
            EncodeExpectation {
                identity: GpuAtlasIdentity {
                    frame_id: header.sequence,
                    capture_monotonic_ns: header.capture_monotonic_ns,
                    geometry_epoch: header.geometry_epoch,
                },
                force_idr,
                deadline,
                allow_clean_expiry,
            },
        )
    }

    fn finish_encode(
        &self,
        status: u32,
        output: *mut OutputOpaque,
        expected: EncodeExpectation,
    ) -> Result<GpuEncodeOutcome> {
        let EncodeExpectation {
            identity,
            force_idr,
            deadline,
            allow_clean_expiry,
        } = expected;
        let owned = NonNull::new(output).map(Output);
        if admits_clean_expiry(allow_clean_expiry, status, owned.is_some()) {
            return Ok(GpuEncodeOutcome::ExpiredClean);
        }
        if allow_clean_expiry && status == 9 && owned.is_none() {
            return Ok(GpuEncodeOutcome::ExpiredAfterSubmission);
        }
        if allow_clean_expiry && status == 10 {
            let owned = owned.ok_or_else(|| anyhow::anyhow!("missing sparse resize result"))?;
            let sparse = owned
                .sparse_result()?
                .context("resize result missing sparse metadata")?;
            ensure!(
                sparse.info.required_width >= self.width
                    && sparse.info.required_height >= self.height
                    && sparse.info.required_width <= 8192
                    && sparse.info.required_height <= 4096
                    && (sparse.info.required_width, sparse.info.required_height)
                        != (self.width, self.height),
                "invalid sparse resize request"
            );
            return Ok(GpuEncodeOutcome::NeedsCanvas {
                width: sparse.info.required_width,
                height: sparse.info.required_height,
            });
        }
        if status != 0 {
            let text = self.last_error();
            bail!("GPU encoding failed with status {status}: {text}");
        }
        let owned = owned.ok_or_else(|| anyhow::anyhow!("GPU encoder returned no output"))?;
        let mut info = CInfo::default();
        // SAFETY: owned output and exact C layout info storage are live.
        let status = unsafe { vf_gpu_dmabuf_output_get_info(owned.0.as_ptr(), &raw mut info) };
        ensure!(status == 0, "GPU output info failed with status {status}");
        ensure!(
            info.frame_id == identity.frame_id
                && info.capture_timestamp_ns == identity.capture_monotonic_ns
                && info.geometry_epoch == identity.geometry_epoch,
            "GPU output lineage mismatch"
        );
        ensure!(
            info.idr <= 1 && (!force_idr || info.idr == 1),
            "GPU output IDR mismatch"
        );
        let color_len = usize::try_from(info.color_annex_b_bytes)?;
        ensure!(
            color_len > 0 && color_len <= self.max_color,
            "GPU color bound exceeded"
        );
        ensure!(
            usize::try_from(info.raw_alpha_bytes)? == self.alpha_bytes,
            "GPU alpha shape mismatch"
        );
        let color_annex_b = owned.copy_plane(color_len, vf_gpu_dmabuf_output_copy_color)?;

        let sparse = owned.sparse_result()?;
        // An opt-in copy mode provides the original path for matched A/B trials.
        // The default retains immutable native storage instead of copying 4K alpha.
        static COPY_ALPHA: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        let copy_alpha = *COPY_ALPHA.get_or_init(|| {
            let copy = std::env::var_os("VIEWFLOW_ALPHA_OUTPUT_COPY").is_some_and(|v| v == "1");
            crate::atlas_feedback::trace_line(format_args!(
                "alpha-output-storage mode={}",
                if copy {
                    "rust-copy"
                } else {
                    "native-owned-view"
                }
            ));
            copy
        });
        let raw_alpha = if copy_alpha {
            owned
                .copy_plane(self.alpha_bytes, vf_gpu_dmabuf_output_copy_raw_alpha)?
                .into()
        } else {
            owned.into_raw_alpha(self.alpha_bytes)?
        };
        let completed_ns = monotonic_ns()?;
        validate_output_transfer_deadline(allow_clean_expiry, completed_ns, deadline)?;
        Ok(GpuEncodeOutcome::Encoded(EncodedGpuFrame {
            sparse,
            frame_id: info.frame_id,
            capture_monotonic_ns: info.capture_timestamp_ns,
            geometry_epoch: info.geometry_epoch,
            idr: info.idr == 1,
            color_annex_b,
            raw_alpha,
        }))
    }
}

impl Drop for GpuEncoder {
    fn drop(&mut self) {
        // SAFETY: unique owned native handle; !Send/!Sync keeps the owner thread.
        unsafe { vf_gpu_dmabuf_encoder_destroy(self.raw.as_ptr()) };
    }
}

struct Output(NonNull<OutputOpaque>);
impl Output {
    fn into_raw_alpha(self, expected: usize) -> Result<RawAlpha> {
        let mut data = std::ptr::null();
        let mut length = 0;
        // SAFETY: unique owner-thread output and exact writable ABI arguments.
        let status = unsafe {
            vf_gpu_dmabuf_output_view_raw_alpha(self.0.as_ptr(), &raw mut data, &raw mut length)
        };
        ensure!(
            status == 0 && length == expected && length <= isize::MAX as usize,
            "GPU alpha view shape mismatch"
        );
        let data = NonNull::new(data.cast_mut()).context("GPU alpha view is null")?;
        Ok(RawAlpha {
            storage: AlphaStorage::Native {
                _output: self,
                data,
                length,
            },
            _owner_thread: PhantomData,
        })
    }

    fn sparse_result(&self) -> Result<Option<GpuSparseResult>> {
        let mut info = GpuSparseInfo::default();
        // SAFETY: owned native output and writable C layout on the same thread.
        let status =
            unsafe { vf_gpu_dmabuf_output_get_sparse_info(self.0.as_ptr(), &raw mut info) };
        ensure!(
            status == 0 && info.enabled <= 1 && info.patch_count <= 32768,
            "invalid GPU sparse metadata"
        );
        if info.enabled == 0 {
            return Ok(None);
        }
        let mut patches = vec![GpuSparsePatch::default(); info.patch_count as usize];
        let mut required = 0;
        // SAFETY: output is live; vector is writable for its exact capacity.
        let status = unsafe {
            vf_gpu_dmabuf_output_copy_sparse_patches(
                self.0.as_ptr(),
                patches.as_mut_ptr(),
                patches.len(),
                &raw mut required,
            )
        };
        ensure!(
            status == 0 && required == patches.len(),
            "GPU sparse patch transfer failed"
        );
        Ok(Some(GpuSparseResult { info, patches }))
    }

    fn copy_plane(
        &self,
        length: usize,
        copy: unsafe extern "C" fn(*const OutputOpaque, *mut u8, usize, *mut usize) -> u32,
    ) -> Result<Vec<u8>> {
        let mut bytes = Vec::new();
        bytes.try_reserve_exact(length)?;
        let mut required = 0;
        // SAFETY: owned output and allocation writable for `length` bytes.
        // Both native copy callbacks memcpy the complete plane before returning
        // success. Keep the Vec empty until that initialization is confirmed;
        // failures can then drop it without exposing uninitialized bytes.
        let status = unsafe {
            copy(
                self.0.as_ptr(),
                bytes.as_mut_ptr(),
                length,
                &raw mut required,
            )
        };
        ensure!(
            status == 0 && required == length,
            "GPU output plane copy failed"
        );
        // SAFETY: success and the exact required length above prove the native
        // copy initialized every byte, within the reserved allocation.
        unsafe { bytes.set_len(length) };
        Ok(bytes)
    }
}
impl Drop for Output {
    fn drop(&mut self) {
        // SAFETY: unique output on the encoding thread, freed exactly once.
        unsafe { vf_gpu_dmabuf_output_destroy(self.0.as_ptr()) };
    }
}

pub(crate) fn monotonic_ns() -> Result<i64> {
    let mut now = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: initialized timespec is writable storage for clock_gettime.
    ensure!(
        unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &raw mut now) } == 0,
        "CLOCK_MONOTONIC unavailable"
    );
    now.tv_sec
        .checked_mul(1_000_000_000)
        .and_then(|seconds| seconds.checked_add(now.tv_nsec))
        .ok_or_else(|| anyhow::anyhow!("CLOCK_MONOTONIC overflow"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn completed_output_expiry_is_recoverable_only_with_explicit_opt_in() {
        for completed in [99, 100, 101, i64::MAX] {
            assert_eq!(
                super::validate_output_transfer_deadline(false, completed, 100).is_ok(),
                completed < 100
            );
            assert!(super::validate_output_transfer_deadline(true, completed, 100).is_ok());
        }
    }
    #[test]
    fn clean_expiry_requires_opt_in_exact_status_and_no_output() {
        for opted_in in [false, true] {
            for status in 0..=10 {
                for has_output in [false, true] {
                    assert_eq!(
                        super::admits_clean_expiry(opted_in, status, has_output),
                        opted_in && status == 8 && !has_output
                    );
                }
            }
        }
    }
    use super::*;
    #[test]
    fn ffi_layout_matches_fixed_linux_abi() {
        assert_eq!(std::mem::size_of::<CConfig>(), 16);
        assert_eq!(std::mem::size_of::<CFrame>(), 208);
        assert_eq!(std::mem::offset_of!(CFrame, modifier), 32);
        assert_eq!(std::mem::offset_of!(CFrame, frame_id), 64);
        assert_eq!(std::mem::offset_of!(CFrame, shadow_left), 96);
        assert_eq!(std::mem::size_of::<CInfo>(), 48);
        assert_eq!(std::mem::size_of::<CAtlasTile>(), 224);
        assert_eq!(std::mem::offset_of!(CAtlasTile, deadline_monotonic_ns), 216);
        assert_eq!(std::mem::size_of::<CAtlas>(), 48);
        assert_eq!(std::mem::offset_of!(CAtlas, tiles), 16);
    }
    #[test]
    fn resource_rejection_precedes_gpu_initialization() {
        assert!(GpuEncoder::new(0, 2, 100, 100).is_err());
        assert!(GpuEncoder::new(3, 2, 100, 100).is_err());
        assert!(GpuEncoder::new(100, 100, 100, 9_999).is_err());
        assert!(GpuEncoder::new(2, 2, 0, 100).is_err());
    }

    #[test]
    #[ignore = "manual owned-buffer CUDA/NVENC hardware test; no desktop capture"]
    fn owned_empty_atlas_crosses_rust_native_boundary() {
        let mut encoder = GpuEncoder::new(256, 256, 1024 * 1024, 256 * 256).unwrap();
        let now = monotonic_ns().unwrap();
        let identity = GpuAtlasIdentity {
            frame_id: 1,
            capture_monotonic_ns: u64::try_from(now).unwrap(),
            geometry_epoch: 1,
        };
        let outcome = encoder
            .encode_atlas_recoverable(&[], identity, true, now + 5_000_000_000)
            .unwrap();
        let GpuEncodeOutcome::Encoded(frame) = outcome else {
            panic!("unexpected clean expiry");
        };
        assert_eq!(frame.frame_id, identity.frame_id);
        assert_eq!(frame.capture_monotonic_ns, identity.capture_monotonic_ns);
        assert_eq!(frame.geometry_epoch, identity.geometry_epoch);
        assert!(frame.idr && !frame.color_annex_b.is_empty());
        assert_eq!(frame.raw_alpha.as_ref(), &[0; 256 * 256]);
        let invalid = GpuAtlasIdentity {
            frame_id: 0,
            ..identity
        };
        assert!(
            encoder
                .encode_atlas_recoverable(&[], invalid, true, now + 5_000_000_000)
                .is_err()
        );
        assert!(encoder.failed);
        assert!(
            encoder
                .encode_atlas_recoverable(&[], identity, true, now + 5_000_000_000)
                .is_err()
        );
    }
}
