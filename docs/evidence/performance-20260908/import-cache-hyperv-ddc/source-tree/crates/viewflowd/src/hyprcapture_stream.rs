//! Metadata for the local decorated-window stream (not the network protocol).
//! Pixels travel in one sealed memfd, never in the bounded seqpacket header.
use anyhow::{Result, bail};

pub const HEADER_BYTES: usize = 96;

/// Clock shared with the compositor's HCSF timestamps (not wall-clock time).
#[cfg(target_os = "linux")]
#[allow(unsafe_code)] // One clock_gettime call into initialized stack storage.
#[allow(clippy::missing_errors_doc)]
pub fn monotonic_now_ns() -> Result<u64> {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: time is valid writable timespec storage for the entire call.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &raw mut time) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if time.tv_sec < 0 || !(0..1_000_000_000).contains(&time.tv_nsec) {
        bail!("invalid monotonic clock sample");
    }
    u64::try_from(time.tv_sec)?
        .checked_mul(1_000_000_000)
        .and_then(|seconds| seconds.checked_add(u64::try_from(time.tv_nsec).ok()?))
        .ok_or_else(|| anyhow::anyhow!("monotonic timestamp overflow"))
}

/// Translate a producer `CLOCK_MONOTONIC` timestamp to the transport session's
/// local time origin, preserving all elapsed capture/queue/import time. Callers
/// sample both current clocks together; this never restamps a frame as fresh.
#[allow(clippy::missing_errors_doc)]
pub fn session_capture_timestamp(
    capture_monotonic_ns: u64,
    monotonic_now_ns: u64,
    session_now_ns: u64,
) -> Result<u64> {
    let age = monotonic_now_ns
        .checked_sub(capture_monotonic_ns)
        .ok_or_else(|| anyhow::anyhow!("capture timestamp is in the future"))?;
    session_now_ns
        .checked_sub(age)
        .ok_or_else(|| anyhow::anyhow!("capture predates the transport session"))
}

/// Import an immutable frame FD after authenticating the socket peer. The FD
/// is consumed on success and failure. Positional reads ignore the sender's
/// shared file offset. Pixel conversion happens after this bounded import.
#[cfg(target_os = "linux")]
#[allow(unsafe_code)] // Small Linux FD boundary; each syscall is documented below.
#[allow(clippy::missing_errors_doc)]
pub fn read_sealed_pixels(
    fd: std::os::fd::OwnedFd,
    header_bytes: &[u8],
    max_pixel_bytes: u64,
) -> Result<(FrameHeader, Vec<u8>)> {
    let (header, file) = validate_sealed_frame(fd, header_bytes, max_pixel_bytes)?;
    let pixels = read_validated_pixels(&file, &header)?;
    Ok((header, pixels))
}

/// Validate a sealed capture FD without reading its pixel payload.
///
/// This is useful for a latest-only receiver: skipped frames must undergo the
/// same header, seal, ownership, and length validation as imported frames.
/// The returned file remains sealed, so it is safe to read after a later
/// bounded queue drain.
#[cfg(target_os = "linux")]
#[allow(unsafe_code)] // Small Linux FD boundary; each syscall is documented below.
#[allow(clippy::missing_errors_doc)]
pub fn validate_sealed_frame(
    fd: std::os::fd::OwnedFd,
    header_bytes: &[u8],
    max_pixel_bytes: u64,
) -> Result<(FrameHeader, std::fs::File)> {
    let header = FrameHeader::decode(header_bytes, max_pixel_bytes)?;
    let file = std::fs::File::from(fd);
    validate_frame_file(&file, &header)?;
    Ok((header, file))
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)] // One fcntl/geteuid validation boundary.
fn validate_frame_file(file: &std::fs::File, header: &FrameHeader) -> Result<()> {
    use std::os::{fd::AsRawFd, unix::fs::MetadataExt};
    // SAFETY: fcntl queries the live descriptor without touching pointers.
    let seals = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GET_SEALS) };
    let required = libc::F_SEAL_WRITE | libc::F_SEAL_GROW | libc::F_SEAL_SHRINK | libc::F_SEAL_SEAL;
    if seals < 0 || seals & required != required {
        bail!("capture FD is not fully sealed");
    }
    let metadata = file.metadata()?;
    // SAFETY: geteuid takes no arguments and has no preconditions.
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.len() != header.payload_bytes
    {
        bail!("capture FD identity or length mismatch");
    }
    Ok(())
}

/// Read pixels from an FD already accepted by [`validate_sealed_frame`].
#[cfg(target_os = "linux")]
#[allow(clippy::missing_errors_doc)]
pub fn read_validated_pixels(file: &std::fs::File, header: &FrameHeader) -> Result<Vec<u8>> {
    use std::os::unix::fs::FileExt;

    let length = usize::try_from(header.payload_bytes)?;
    let mut pixels = Vec::new();
    pixels.try_reserve_exact(length)?;
    pixels.resize(length, 0);
    file.read_exact_at(&mut pixels, 0)?;
    Ok(pixels)
}

/// A validated, private, read-only mapping of a sealed frame payload.
///
/// This type deliberately exposes only immutable byte access. Its constructor
/// is crate-private and independently repeats the ownership, seal, and
/// exact-length checks before constructing a slice-capable mapping.
#[cfg(target_os = "linux")]
pub struct ReadOnlyFrameMapping {
    address: std::ptr::NonNull<u8>,
    length: usize,
}

#[cfg(target_os = "linux")]
impl ReadOnlyFrameMapping {
    /// Map pixels from an FD already accepted by [`validate_sealed_frame`].
    ///
    /// `F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL` keeps the
    /// backing object immutable and its checked length stable, preventing a
    /// later truncate from turning a valid mapped range into a SIGBUS.
    #[allow(unsafe_code)] // Narrow mmap boundary; mapping is read-only/private.
    #[allow(clippy::missing_errors_doc)]
    pub(crate) fn from_validated(file: &std::fs::File, header: &FrameHeader) -> Result<Self> {
        // Revalidate here rather than trusting the crate-private caller. This
        // keeps the safe slice construction sound even if a future internal
        // caller hands this function an arbitrary File.
        validate_frame_file(file, header)?;
        let length = usize::try_from(header.payload_bytes)?;
        if length == 0 || length > isize::MAX as usize {
            bail!("capture mapping length is not addressable");
        }
        // SAFETY: `file` is validated sealed storage with exactly `length`
        // bytes. The checked nonzero length fits `isize`; mmap receives no
        // writable mapping permission and MAP_PRIVATE prevents this process
        // from modifying the backing object.
        let address = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                length,
                libc::PROT_READ,
                libc::MAP_PRIVATE,
                std::os::fd::AsRawFd::as_raw_fd(file),
                0,
            )
        };
        if address == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error().into());
        }
        let Some(address) = std::ptr::NonNull::new(address.cast()) else {
            // SAFETY: mmap succeeded for this exact range, so release it even
            // on the theoretically possible null success address.
            let _ = unsafe { libc::munmap(address, length) };
            bail!("capture mapping returned a null address");
        };
        Ok(Self { address, length })
    }
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)] // Slice view is bounded by this RAII mapping's lifetime.
impl AsRef<[u8]> for ReadOnlyFrameMapping {
    fn as_ref(&self) -> &[u8] {
        // SAFETY: this object owns a live mmap of exactly `length` bytes until
        // Drop. The public API never exposes a mutable reference to it.
        unsafe { std::slice::from_raw_parts(self.address.as_ptr(), self.length) }
    }
}

#[cfg(target_os = "linux")]
impl Drop for ReadOnlyFrameMapping {
    #[allow(unsafe_code)] // Releases only this object's successful mmap range.
    fn drop(&mut self) {
        // SAFETY: address and length came from this object's successful mmap
        // call and are released exactly once by Drop.
        let _ = unsafe { libc::munmap(self.address.as_ptr().cast(), self.length) };
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FrameHeader {
    pub sequence: u64,
    /// Linux `CLOCK_MONOTONIC` at production of these exact pixels.
    pub capture_monotonic_ns: u64,
    pub geometry_epoch: u64,
    pub logical_rect: [f64; 4],
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub payload_bytes: u64,
}

/// Per-connection frame lineage. Recreate only for a newly authenticated
/// producer session. Rejected input leaves the accepted lineage unchanged.
#[derive(Default)]
pub struct FrameCursor {
    last: Option<FrameHeader>,
}

impl FrameCursor {
    #[allow(clippy::missing_errors_doc, clippy::float_cmp)]
    pub fn accept(&mut self, frame: &FrameHeader) -> Result<()> {
        if let Some(last) = &self.last {
            if frame.sequence <= last.sequence
                || frame.capture_monotonic_ns < last.capture_monotonic_ns
                || frame.geometry_epoch < last.geometry_epoch
            {
                bail!("stale HyprCapture stream frame");
            }
            if frame.geometry_epoch == last.geometry_epoch
                && (frame.logical_rect != last.logical_rect
                    || frame.width != last.width
                    || frame.height != last.height
                    || frame.stride != last.stride)
            {
                bail!("HyprCapture geometry changed without a new epoch");
            }
        }
        self.last = Some(frame.clone());
        Ok(())
    }
}

impl FrameHeader {
    /// Convert the imported straight-RGBA storage for the native/network raw
    /// presenter without another full-frame pixel allocation.
    #[allow(clippy::missing_errors_doc)]
    pub fn into_raw_bgra(
        &self,
        pixels: Vec<u8>,
        max_bytes: usize,
    ) -> Result<viewflow_transport::RawBgraPayload> {
        Ok(viewflow_transport::RawBgraPayload::from_straight_rgba(
            self.width,
            self.height,
            pixels,
            max_bytes,
        )?)
    }
    /// Decode before mapping the accompanying FD. This does not validate FD
    /// ownership, seals, file length, or peer credentials; the receiver must.
    #[allow(clippy::missing_errors_doc, clippy::missing_panics_doc)]
    pub fn decode(bytes: &[u8], max_pixel_bytes: u64) -> Result<Self> {
        if bytes.len() != HEADER_BYTES
            || &bytes[..4] != b"HCSF"
            || bytes[4..6] != 1_u16.to_be_bytes()
            || bytes[6..8] != u16::try_from(HEADER_BYTES)?.to_be_bytes()
        {
            bail!("invalid HyprCapture stream header");
        }
        let u64_at = |i| u64::from_be_bytes(bytes[i..i + 8].try_into().unwrap());
        let u32_at = |i| u32::from_be_bytes(bytes[i..i + 4].try_into().unwrap());
        let logical_rect = [32, 40, 48, 56].map(|i| f64::from_bits(u64_at(i)));
        let header = Self {
            sequence: u64_at(8),
            capture_monotonic_ns: u64_at(16),
            geometry_epoch: u64_at(24),
            logical_rect,
            width: u32_at(64),
            height: u32_at(68),
            stride: u32_at(72),
            payload_bytes: u64_at(80),
        };
        if header.sequence == 0
            || header.geometry_epoch == 0
            || u32_at(76) != 1
            || u64_at(88) != 0
            || logical_rect.iter().any(|v| !v.is_finite())
            || logical_rect[2] <= 0.0
            || logical_rect[3] <= 0.0
            || !(logical_rect[0] + logical_rect[2]).is_finite()
            || !(logical_rect[1] + logical_rect[3]).is_finite()
            || header.width == 0
            || header.height == 0
            || header.width.checked_mul(4) != Some(header.stride)
            || u64::from(header.stride) * u64::from(header.height) != header.payload_bytes
            || header.payload_bytes > max_pixel_bytes
        {
            bail!("invalid HyprCapture stream frame metadata");
        }
        Ok(header)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lineage_rejects_old_frames_and_unversioned_resize_without_mutation() {
        let mut cursor = FrameCursor::default();
        let first = FrameHeader::decode(&packet(), 464704).unwrap();
        cursor.accept(&first).unwrap();
        assert!(cursor.accept(&first).is_err());
        let mut resized = first.clone();
        resized.sequence += 1;
        resized.logical_rect[2] += 10.0;
        assert!(cursor.accept(&resized).is_err());
        resized.geometry_epoch += 1;
        cursor.accept(&resized).unwrap();
        let mut old_time = resized.clone();
        old_time.sequence += 1;
        old_time.capture_monotonic_ns -= 1;
        assert!(cursor.accept(&old_time).is_err());
        old_time.capture_monotonic_ns += 2;
        cursor.accept(&old_time).unwrap();
    }
    #[test]
    fn decodes_cpp_producer_golden() {
        // Emitted by HyprCapture tests/window_stream_test --golden-header-hex.
        let hex = "4843534600010060000000000000000900000000075bcd1e00000000000000114025000000000000c002000000000000406a8000000000004061200000000000000001a800000112000006a00000000100000000000717400000000000000000";
        let bytes: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect();
        let h = FrameHeader::decode(&bytes, 464704).unwrap();
        assert_eq!(h.sequence, 9);
        assert_eq!(h.capture_monotonic_ns, 123456798);
        assert_eq!(h.geometry_epoch, 17);
        assert_eq!(h.logical_rect, [10.5, -2.25, 212.0, 137.0]);
        assert_eq!(
            (h.width, h.height, h.stride, h.payload_bytes),
            (424, 274, 1696, 464704)
        );
    }
    #[test]
    fn clock_origin_translation_preserves_capture_age() {
        assert_eq!(
            session_capture_timestamp(1_000_000_000, 1_190_000_000, 300_000_000).unwrap(),
            110_000_000
        );
        assert!(session_capture_timestamp(101, 100, 100).is_err());
        assert!(session_capture_timestamp(0, 190, 100).is_err());
        assert_eq!(session_capture_timestamp(100, 100, 0).unwrap(), 0);
    }
    fn packet() -> [u8; HEADER_BYTES] {
        let mut b = [0; HEADER_BYTES];
        b[..4].copy_from_slice(b"HCSF");
        b[4..6].copy_from_slice(&1_u16.to_be_bytes());
        b[6..8].copy_from_slice(&96_u16.to_be_bytes());
        for (i, v) in [(8, 1_u64), (16, 1234), (24, 2), (80, 464704)] {
            b[i..i + 8].copy_from_slice(&v.to_be_bytes());
        }
        for (i, v) in [(32, -7_f64), (40, -7.0), (48, 212.0), (56, 137.0)] {
            b[i..i + 8].copy_from_slice(&v.to_be_bytes());
        }
        for (i, v) in [(64, 424_u32), (68, 274), (72, 1696), (76, 1)] {
            b[i..i + 4].copy_from_slice(&v.to_be_bytes());
        }
        b
    }
    #[test]
    fn preserves_source_time_and_logical_geometry() {
        let h = FrameHeader::decode(&packet(), 464704).unwrap();
        assert_eq!(h.capture_monotonic_ns, 1234);
        assert_eq!(h.logical_rect, [-7.0, -7.0, 212.0, 137.0]);
        assert_eq!(h.width, 424);
    }
    #[test]
    fn rejects_bounds_versions_reserved_and_truncation() {
        let b = packet();
        for len in 0..HEADER_BYTES {
            assert!(FrameHeader::decode(&b[..len], u64::MAX).is_err());
        }
        assert!(FrameHeader::decode(&b, 464703).is_err());
        for i in [4, 6, 76, 88] {
            let mut bad = b;
            bad[i] = 255;
            assert!(FrameHeader::decode(&bad, u64::MAX).is_err());
        }
        let mut bad = b;
        bad[48..56].copy_from_slice(&f64::NAN.to_be_bytes());
        assert!(FrameHeader::decode(&bad, u64::MAX).is_err());
    }

    #[cfg(target_os = "linux")]
    #[allow(unsafe_code)] // Test-only memfd construction and sealing.
    fn memfd(sealed: bool, length: usize) -> std::os::fd::OwnedFd {
        use std::{
            io::{Seek, SeekFrom, Write},
            os::fd::{AsRawFd, FromRawFd},
        };
        // SAFETY: static NUL-terminated name and supported flags.
        let raw = unsafe {
            libc::memfd_create(
                c"viewflow-stream-test".as_ptr(),
                libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
            )
        };
        assert!(raw >= 0);
        // SAFETY: newly created descriptor is uniquely owned.
        let mut f = unsafe { std::fs::File::from_raw_fd(raw) };
        f.write_all(&vec![37; length]).unwrap();
        f.seek(SeekFrom::End(0)).unwrap();
        if sealed {
            let flags =
                libc::F_SEAL_WRITE | libc::F_SEAL_GROW | libc::F_SEAL_SHRINK | libc::F_SEAL_SEAL;
            // SAFETY: f owns this descriptor and fcntl takes integer flags.
            assert_eq!(
                unsafe { libc::fcntl(f.as_raw_fd(), libc::F_ADD_SEALS, flags) },
                0
            );
        }
        f.into()
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn sealed_import_ignores_shared_offset_and_rejects_mutable_or_wrong_length() {
        let b = packet();
        let (_, pixels) = read_sealed_pixels(memfd(true, 464704), &b, 464704).unwrap();
        assert_eq!(pixels.len(), 464704);
        assert!(pixels.iter().all(|v| *v == 37));
        assert!(read_sealed_pixels(memfd(false, 464704), &b, 464704).is_err());
        assert!(read_sealed_pixels(memfd(true, 464703), &b, 464704).is_err());
        assert!(read_sealed_pixels(memfd(true, 464705), &b, 464704).is_err());
    }

    #[test]
    #[cfg(target_os = "linux")]
    #[allow(unsafe_code)] // Test-only mincore checks a range after its RAII Drop.
    fn mapped_import_requires_full_seals_and_unmaps_on_drop() {
        let b = packet();
        assert!(validate_sealed_frame(memfd(false, 464704), &b, 464704).is_err());
        assert!(validate_sealed_frame(memfd(true, 464703), &b, 464704).is_err());
        assert!(validate_sealed_frame(memfd(true, 464705), &b, 464704).is_err());

        // Even a direct crate-internal call cannot turn an unsealed File into
        // a slice-capable mapping: `from_validated` repeats all FD checks.
        let unsealed = std::fs::File::from(memfd(false, 464704));
        let header = FrameHeader::decode(&b, 464704).unwrap();
        assert!(ReadOnlyFrameMapping::from_validated(&unsealed, &header).is_err());

        let (frame, file) = validate_sealed_frame(memfd(true, 464704), &b, 464704).unwrap();
        let mapping = ReadOnlyFrameMapping::from_validated(&file, &frame).unwrap();
        // mmap starts at byte zero, independent of the sender's shared offset.
        assert_eq!(mapping.as_ref(), vec![37; 464704]);
        // The seals validated above also prohibit a writable shared mapping of
        // the backing object; the public mapping type has no mutable slice.
        assert_eq!(
            unsafe {
                libc::mmap(
                    std::ptr::null_mut(),
                    1,
                    libc::PROT_WRITE,
                    libc::MAP_SHARED,
                    std::os::fd::AsRawFd::as_raw_fd(&file),
                    0,
                )
            },
            libc::MAP_FAILED
        );
        let address = mapping.address.as_ptr().cast::<libc::c_void>();
        let page = usize::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap();
        assert!(page > 0);
        let mapped_pages = mapping.length.div_ceil(page) * page;
        let mut resident = vec![0_u8; mapped_pages / page];
        assert_eq!(
            unsafe { libc::mincore(address, mapped_pages, resident.as_mut_ptr()) },
            0
        );
        drop(mapping);
        assert_eq!(
            unsafe { libc::mincore(address, mapped_pages, resident.as_mut_ptr()) },
            -1
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ENOMEM)
        );
    }
}
