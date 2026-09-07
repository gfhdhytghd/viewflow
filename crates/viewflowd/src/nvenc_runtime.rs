//! Safe, bounded ownership wrapper for the Linux NVENC C ABI.
#![allow(unsafe_code)] // This module is the reviewed FFI boundary.

use std::{fmt, marker::PhantomData, ptr::NonNull};

const CABI_VERSION: u32 = 1;

#[repr(C)]
struct EncoderOpaque {
    _private: [u8; 0],
}
#[repr(C)]
struct AuOpaque {
    _private: [u8; 0],
}
#[repr(C)]
struct CConfig {
    struct_size: u32,
    version: u32,
    width: u32,
    height: u32,
    max_access_unit_bytes: usize,
    max_pending_frames: usize,
    alpha_policy: u32,
    alpha_fidelity: u32,
    alpha_max_quantizer: u8,
    reserved: [u8; 7],
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CMetadata {
    frame_id: u64,
    timestamp_ns: u64,
    geometry_epoch: u64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct CDescriptor {
    profile: u32,
    full_range: u8,
    luma_is_straight_alpha: u8,
    chroma_is_neutral: u8,
    reserved: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct CInfo {
    struct_size: u32,
    version: u32,
    metadata: CMetadata,
    alpha_disposition: u32,
    color_is_idr: u8,
    alpha_is_idr: u8,
    has_alpha_stream: u8,
    reserved: [u8; 5],
    color_stream: CDescriptor,
    alpha_stream: CDescriptor,
    color_annex_b_bytes: usize,
    alpha_annex_b_bytes: usize,
}
#[repr(C)]
struct CList {
    struct_size: u32,
    version: u32,
    items: *mut *mut AuOpaque,
    count: usize,
}

unsafe extern "C" {
    fn vf_nvenc_output_list_init(list: *mut CList);
    fn vf_nvenc_output_list_destroy(list: *mut CList) -> u32;
    fn vf_nvenc_output_list_take(list: *mut CList, index: usize, output: *mut *mut AuOpaque)
    -> u32;
    fn vf_nvenc_output_au_destroy(output: *mut AuOpaque);
    fn vf_nvenc_encoder_create(config: *const CConfig, output: *mut *mut EncoderOpaque) -> u32;
    fn vf_nvenc_encoder_destroy(encoder: *mut EncoderOpaque);
    fn vf_nvenc_encoder_submit(
        encoder: *mut EncoderOpaque,
        rgba: *const u8,
        len: usize,
        metadata: CMetadata,
        force_idr: u8,
        output: *mut CList,
    ) -> u32;
    fn vf_nvenc_encoder_drain(encoder: *mut EncoderOpaque, output: *mut CList) -> u32;
    fn vf_nvenc_output_au_get_info(output: *const AuOpaque, info: *mut CInfo) -> u32;
    fn vf_nvenc_output_au_copy_color(
        output: *const AuOpaque,
        dst: *mut u8,
        cap: usize,
        required: *mut usize,
    ) -> u32;
    fn vf_nvenc_output_au_copy_alpha(
        output: *const AuOpaque,
        dst: *mut u8,
        cap: usize,
        required: *mut usize,
    ) -> u32;
}

const OK: u32 = 0;
const BUFFER_TOO_SMALL: u32 = 6;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AlphaPolicy {
    Required,
    OpaqueMayOmit,
    ColorOnlyExternalAlpha,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AlphaFidelity {
    Lossless,
    BoundedLossy { max_quantizer: u8 },
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EncoderConfig {
    pub width: u32,
    pub height: u32,
    pub max_access_unit_bytes: usize,
    pub max_pending_frames: usize,
    pub alpha_policy: AlphaPolicy,
    pub alpha_fidelity: AlphaFidelity,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FrameMetadata {
    pub frame_id: u64,
    pub timestamp_ns: u64,
    pub geometry_epoch: u64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StreamDescriptor {
    pub profile: u32,
    pub full_range: bool,
    pub luma_is_straight_alpha: bool,
    pub chroma_is_neutral: bool,
}
#[derive(Clone, Debug, Eq, PartialEq)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "mirrors independently validated C ABI access-unit flags without losing their wire-level distinctions"
)]
pub struct EncodedAccessUnit {
    pub metadata: FrameMetadata,
    pub alpha_omitted: bool,
    pub alpha_external: bool,
    pub color_is_idr: bool,
    pub alpha_is_idr: bool,
    pub color_stream: StreamDescriptor,
    pub alpha_stream: Option<StreamDescriptor>,
    pub color_annex_b: Vec<u8>,
    pub alpha_annex_b: Vec<u8>,
}
#[derive(Debug, Clone, Eq, PartialEq)]
pub enum NvencError {
    /// Output was consumed but could not be delivered; create a new encoder.
    Poisoned,
    InvalidConfig(&'static str),
    Status(u32),
    BoundExceeded {
        required: usize,
        maximum: usize,
    },
}
impl fmt::Display for NvencError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "NVENC runtime error: {self:?}")
    }
}
impl std::error::Error for NvencError {}

pub struct Encoder {
    raw: NonNull<EncoderOpaque>,
    max_access_unit_bytes: usize,
    poisoned: bool,
    _not_send: PhantomData<*mut ()>,
}
impl Encoder {
    /// # Errors
    /// Rejects invalid resource bounds or alpha quantizers, unsupported native
    /// configuration, and GPU/driver initialization failures.
    pub fn new(config: EncoderConfig) -> Result<Self, NvencError> {
        if config.width == 0
            || config.height == 0
            || config.max_access_unit_bytes == 0
            || config.max_pending_frames == 0
        {
            return Err(NvencError::InvalidConfig(
                "dimensions and bounds must be nonzero",
            ));
        }
        let (fidelity, quantizer) = match config.alpha_fidelity {
            AlphaFidelity::Lossless => (0, 0),
            AlphaFidelity::BoundedLossy { max_quantizer } if (1..=51).contains(&max_quantizer) => {
                (1, max_quantizer)
            }
            AlphaFidelity::BoundedLossy { .. } => {
                return Err(NvencError::InvalidConfig(
                    "bounded alpha quantizer must be in 1..=51",
                ));
            }
        };
        let c = CConfig {
            struct_size: u32::try_from(std::mem::size_of::<CConfig>())
                .map_err(|_| NvencError::InvalidConfig("CConfig is too large"))?,
            version: CABI_VERSION,
            width: config.width,
            height: config.height,
            max_access_unit_bytes: config.max_access_unit_bytes,
            max_pending_frames: config.max_pending_frames,
            alpha_policy: match config.alpha_policy {
                AlphaPolicy::Required => 0,
                AlphaPolicy::OpaqueMayOmit => 1,
                AlphaPolicy::ColorOnlyExternalAlpha => 2,
            },
            alpha_fidelity: fidelity,
            alpha_max_quantizer: quantizer,
            reserved: [0; 7],
        };
        let mut raw = std::ptr::null_mut();
        let status = unsafe { vf_nvenc_encoder_create(&raw const c, &raw mut raw) };
        status_ok(status)?;
        Ok(Self {
            poisoned: false,
            raw: NonNull::new(raw).ok_or(NvencError::Status(8))?,
            max_access_unit_bytes: config.max_access_unit_bytes,
            _not_send: PhantomData,
        })
    }
    /// # Errors
    /// Returns input/driver errors or bounded output-copy failures. A consumed
    /// output that cannot be copied poisons this session; recreate it with IDR.
    pub fn submit(
        &mut self,
        rgba: &[u8],
        metadata: FrameMetadata,
        force_idr: bool,
    ) -> Result<Vec<EncodedAccessUnit>, NvencError> {
        if self.poisoned {
            return Err(NvencError::Poisoned);
        }
        let mut list = OutputList::new();
        let status = unsafe {
            vf_nvenc_encoder_submit(
                self.raw.as_ptr(),
                rgba.as_ptr(),
                rgba.len(),
                metadata.into(),
                u8::from(force_idr),
                &raw mut list.raw,
            )
        };
        status_ok(status)?;
        self.collect_or_poison(list)
    }
    /// # Errors
    /// Returns native flush or bounded output-copy errors, or `Poisoned` when
    /// this session has already lost output at the Rust ownership boundary.
    pub fn drain(&mut self) -> Result<Vec<EncodedAccessUnit>, NvencError> {
        if self.poisoned {
            return Err(NvencError::Poisoned);
        }
        let mut list = OutputList::new();
        status_ok(unsafe { vf_nvenc_encoder_drain(self.raw.as_ptr(), &raw mut list.raw) })?;
        self.collect_or_poison(list)
    }
    fn collect_or_poison(
        &mut self,
        list: OutputList,
    ) -> Result<Vec<EncodedAccessUnit>, NvencError> {
        let result = self.collect(list);
        // C++ has already advanced reference-frame state. Losing an AU at the
        // Rust copy boundary must not allow later dependent frames to escape.
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }
    fn collect(&self, mut list: OutputList) -> Result<Vec<EncodedAccessUnit>, NvencError> {
        let count = list.raw.count;
        let mut out = Vec::with_capacity(count);
        // `take` compacts the C-owned list, so every remaining AU is index 0.
        for _ in 0..count {
            let mut raw = std::ptr::null_mut();
            status_ok(unsafe { vf_nvenc_output_list_take(&raw mut list.raw, 0, &raw mut raw) })?;
            out.push(
                AccessUnit {
                    raw: NonNull::new(raw).ok_or(NvencError::Status(8))?,
                }
                .copy(self.max_access_unit_bytes)?,
            );
        }
        Ok(out)
    }
}
impl Drop for Encoder {
    fn drop(&mut self) {
        unsafe { vf_nvenc_encoder_destroy(self.raw.as_ptr()) }
    }
}
struct OutputList {
    raw: CList,
}
impl OutputList {
    fn new() -> Self {
        let mut raw = CList {
            struct_size: 0,
            version: 0,
            items: std::ptr::null_mut(),
            count: 0,
        };
        unsafe { vf_nvenc_output_list_init(&raw mut raw) };
        Self { raw }
    }
}
impl Drop for OutputList {
    fn drop(&mut self) {
        unsafe {
            let _ = vf_nvenc_output_list_destroy(&raw mut self.raw);
        }
    }
}
struct AccessUnit {
    raw: NonNull<AuOpaque>,
}
impl Drop for AccessUnit {
    fn drop(&mut self) {
        unsafe { vf_nvenc_output_au_destroy(self.raw.as_ptr()) }
    }
}
impl AccessUnit {
    fn copy(self, maximum: usize) -> Result<EncodedAccessUnit, NvencError> {
        let mut info = CInfo {
            struct_size: u32::try_from(std::mem::size_of::<CInfo>())
                .map_err(|_| NvencError::InvalidConfig("CInfo is too large"))?,
            version: CABI_VERSION,
            metadata: CMetadata {
                frame_id: 0,
                timestamp_ns: 0,
                geometry_epoch: 0,
            },
            alpha_disposition: 0,
            color_is_idr: 0,
            alpha_is_idr: 0,
            has_alpha_stream: 0,
            reserved: [0; 5],
            color_stream: CDescriptor {
                profile: 0,
                full_range: 0,
                luma_is_straight_alpha: 0,
                chroma_is_neutral: 0,
                reserved: 0,
            },
            alpha_stream: CDescriptor {
                profile: 0,
                full_range: 0,
                luma_is_straight_alpha: 0,
                chroma_is_neutral: 0,
                reserved: 0,
            },
            color_annex_b_bytes: 0,
            alpha_annex_b_bytes: 0,
        };
        status_ok(unsafe { vf_nvenc_output_au_get_info(self.raw.as_ptr(), &raw mut info) })?;
        let color = self.copy_plane(vf_nvenc_output_au_copy_color, maximum)?;
        let alpha = self.copy_plane(vf_nvenc_output_au_copy_alpha, maximum)?;
        Ok(EncodedAccessUnit {
            metadata: info.metadata.into(),
            alpha_omitted: info.alpha_disposition == 1,
            alpha_external: info.alpha_disposition == 2,
            color_is_idr: info.color_is_idr != 0,
            alpha_is_idr: info.alpha_is_idr != 0,
            color_stream: info.color_stream.into(),
            alpha_stream: (info.has_alpha_stream != 0).then(|| info.alpha_stream.into()),
            color_annex_b: color,
            alpha_annex_b: alpha,
        })
    }
    fn copy_plane(
        &self,
        f: unsafe extern "C" fn(*const AuOpaque, *mut u8, usize, *mut usize) -> u32,
        maximum: usize,
    ) -> Result<Vec<u8>, NvencError> {
        let mut required = 0;
        let status = unsafe {
            f(
                self.raw.as_ptr(),
                std::ptr::null_mut(),
                0,
                &raw mut required,
            )
        };
        if status != OK && status != BUFFER_TOO_SMALL {
            return Err(NvencError::Status(status));
        }
        if required > maximum {
            return Err(NvencError::BoundExceeded { required, maximum });
        }
        let mut bytes = vec![0; required];
        if required != 0 {
            status_ok(unsafe {
                f(
                    self.raw.as_ptr(),
                    bytes.as_mut_ptr(),
                    bytes.len(),
                    &raw mut required,
                )
            })?;
            bytes.truncate(required);
        }
        Ok(bytes)
    }
}
impl From<FrameMetadata> for CMetadata {
    fn from(v: FrameMetadata) -> Self {
        Self {
            frame_id: v.frame_id,
            timestamp_ns: v.timestamp_ns,
            geometry_epoch: v.geometry_epoch,
        }
    }
}
impl From<CMetadata> for FrameMetadata {
    fn from(v: CMetadata) -> Self {
        Self {
            frame_id: v.frame_id,
            timestamp_ns: v.timestamp_ns,
            geometry_epoch: v.geometry_epoch,
        }
    }
}
impl From<CDescriptor> for StreamDescriptor {
    fn from(v: CDescriptor) -> Self {
        Self {
            profile: v.profile,
            full_range: v.full_range != 0,
            luma_is_straight_alpha: v.luma_is_straight_alpha != 0,
            chroma_is_neutral: v.chroma_is_neutral != 0,
        }
    }
}
fn status_ok(status: u32) -> Result<(), NvencError> {
    if status == OK {
        Ok(())
    } else {
        Err(NvencError::Status(status))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires NVIDIA GPU and NVENC driver"]
    fn lost_output_poisons_gpu_session() {
        let mut encoder = Encoder::new(EncoderConfig {
            width: 256,
            height: 256,
            max_access_unit_bytes: 1024 * 1024,
            max_pending_frames: 8,
            alpha_policy: AlphaPolicy::Required,
            alpha_fidelity: AlphaFidelity::Lossless,
        })
        .unwrap();
        // Inject a copy-bound failure after the native encoder accepted input.
        // The native AU limit remains unchanged, exercising Rust's boundary.
        encoder.max_access_unit_bytes = 0;
        let pixels = vec![128; 256 * 256 * 4];
        let metadata = FrameMetadata {
            frame_id: 1,
            timestamp_ns: 1,
            geometry_epoch: 1,
        };
        let result = encoder.submit(&pixels, metadata, true);
        let failure = match result {
            Ok(outputs) => {
                assert!(outputs.is_empty());
                encoder.drain().unwrap_err()
            }
            Err(error) => error,
        };
        assert!(matches!(
            failure,
            NvencError::BoundExceeded { maximum: 0, .. }
        ));
        assert_eq!(
            encoder.submit(&pixels, metadata, true),
            Err(NvencError::Poisoned)
        );
        assert_eq!(encoder.drain(), Err(NvencError::Poisoned));
    }

    #[test]
    #[ignore = "requires NVIDIA GPU and NVENC driver"]
    fn persistent_gpu_pair_preserves_metadata() {
        let mut encoder = Encoder::new(EncoderConfig {
            width: 256,
            height: 256,
            max_access_unit_bytes: 1024 * 1024,
            max_pending_frames: 8,
            alpha_policy: AlphaPolicy::Required,
            alpha_fidelity: AlphaFidelity::Lossless,
        })
        .unwrap();
        let mut outputs = Vec::new();
        for frame_id in 1..=3 {
            let mut rgba = vec![0; 256 * 256 * 4];
            for (i, pixel) in rgba.chunks_exact_mut(4).enumerate() {
                pixel.copy_from_slice(&[i as u8, (i / 256) as u8, 128, (i % 256) as u8]);
            }
            outputs.extend(
                encoder
                    .submit(
                        &rgba,
                        FrameMetadata {
                            frame_id,
                            timestamp_ns: frame_id * 16_666_667,
                            geometry_epoch: 1,
                        },
                        frame_id == 1,
                    )
                    .unwrap(),
            );
        }
        outputs.extend(encoder.drain().unwrap());
        assert_eq!(outputs.len(), 3);
        for (index, au) in outputs.iter().enumerate() {
            let frame_id = index as u64 + 1;
            assert_eq!(
                au.metadata,
                FrameMetadata {
                    frame_id,
                    timestamp_ns: frame_id * 16_666_667,
                    geometry_epoch: 1,
                }
            );
            assert!(!au.color_annex_b.is_empty());
            assert!(!au.alpha_annex_b.is_empty());
            assert!(!au.alpha_omitted);
            let alpha = au.alpha_stream.unwrap();
            assert!(alpha.full_range && alpha.luma_is_straight_alpha && alpha.chroma_is_neutral);
        }
        assert!(outputs[0].color_is_idr && outputs[0].alpha_is_idr);
    }

    #[test]
    fn abi_layout_and_invalid_config_are_stable() {
        assert_eq!(std::mem::size_of::<CConfig>(), 48);
        assert_eq!(std::mem::size_of::<CMetadata>(), 24);
        assert_eq!(std::mem::size_of::<CDescriptor>(), 8);
        assert_eq!(std::mem::size_of::<CInfo>(), 80);
        assert!(matches!(
            Encoder::new(EncoderConfig {
                width: 0,
                height: 1,
                max_access_unit_bytes: 1,
                max_pending_frames: 1,
                alpha_policy: AlphaPolicy::Required,
                alpha_fidelity: AlphaFidelity::Lossless
            }),
            Err(NvencError::InvalidConfig(_))
        ));
        assert!(matches!(
            Encoder::new(EncoderConfig {
                width: 1,
                height: 1,
                max_access_unit_bytes: 1,
                max_pending_frames: 1,
                alpha_policy: AlphaPolicy::Required,
                alpha_fidelity: AlphaFidelity::BoundedLossy { max_quantizer: 52 }
            }),
            Err(NvencError::InvalidConfig(_))
        ));
    }
}
