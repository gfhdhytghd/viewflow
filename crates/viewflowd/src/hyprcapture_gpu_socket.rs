#![allow(unsafe_code)] // Narrow Linux FD/syscall boundary; every unsafe operation is documented.

//! Linux `SOCK_SEQPACKET` receiver for HCGF GPU frames.
//!
//! This does not import a DMA-BUF or present a frame.  The consumer owns that
//! work and must call [`HyprCaptureGpuSocketReceiver::release_after_source_reads`]
//! only after its GPU has finished reading the exported source allocation.
//! Dropping [`GpuFrame`] closes its local descriptors but deliberately sends no
//! HCGR release.

use std::{
    io,
    mem::{self, MaybeUninit},
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};

use anyhow::{Result, bail};

use crate::{
    hyprcapture_gpu_release::GpuRelease,
    hyprcapture_gpu_wire::{
        HCGF_BYTES, HCGI_BYTES, HcgfFrame, InputGeometry, decode, decode_input_geometry,
    },
};

/// Result of a non-blocking HCGF receive.
pub enum GpuReceiveOutcome {
    /// A complete, authenticated frame with image then native-fence FD.
    Frame(Box<GpuFrame>),
    /// No complete packet is available now.
    WouldBlock,
    /// The peer closed the connected socket.
    Disconnected,
}

/// Exported source descriptors and their immutable HCGF metadata.
///
/// The descriptors are closed on drop.  This is intentionally not an ACK: a
/// producer must retire an unreleased allocation on disconnect/uncertainty.
pub struct GpuFrame {
    metadata: HcgfFrame,
    input_geometry: Option<InputGeometry>,
    image: OwnedFd,
    fence: OwnedFd,
    session: Arc<()>,
}

impl GpuFrame {
    #[must_use]
    pub fn input_geometry(&self) -> Option<InputGeometry> {
        self.input_geometry
    }

    #[must_use]
    pub fn metadata(&self) -> &HcgfFrame {
        &self.metadata
    }

    /// DMA-BUF descriptor, first in the HCGF `SCM_RIGHTS` payload.
    #[must_use]
    pub fn image_fd(&self) -> &OwnedFd {
        &self.image
    }

    /// Native completion-fence descriptor, second in the `SCM_RIGHTS` payload.
    #[must_use]
    pub fn fence_fd(&self) -> &OwnedFd {
        &self.fence
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FrameIdentity {
    sequence: u64,
    geometry_epoch: u64,
}

/// Authenticated single-slot receiver for one GPU producer session.
pub struct HyprCaptureGpuSocketReceiver {
    socket: OwnedFd,
    // Registered lazily on the live source's I/O runtime. The duplicate stays
    // with this receiver across encoder ownership transfers; it reads nothing.
    readiness: Option<tokio::io::unix::AsyncFd<OwnedFd>>,
    readiness_failed: bool,
    session: Arc<()>,
    last_accepted: Option<FrameIdentity>,
    outstanding: Option<FrameIdentity>,
    retired: bool,
}

impl HyprCaptureGpuSocketReceiver {
    /// Validate a connected `AF_UNIX` `SOCK_SEQPACKET` socket and its exact
    /// compositor UID/PID credentials.
    ///
    /// # Errors
    ///
    /// Returns an error when socket type, domain, or peer credentials do not
    /// match the expected compositor connection.
    pub fn new(socket: OwnedFd, expected_uid: u32, expected_process_id: u32) -> Result<Self> {
        let raw = socket.as_raw_fd();
        let socket_type = socket_option_i32(raw, libc::SO_TYPE)?;
        if socket_type != libc::SOCK_SEQPACKET {
            bail!("HCGF socket is not SOCK_SEQPACKET");
        }
        let domain = socket_option_i32(raw, libc::SO_DOMAIN)?;
        if domain != libc::AF_UNIX {
            bail!("HCGF socket is not AF_UNIX");
        }
        let mut peer = MaybeUninit::<libc::ucred>::zeroed();
        let mut peer_len = libc::socklen_t::try_from(mem::size_of::<libc::ucred>())?;
        // SAFETY: `raw` is owned by `socket`; `peer` is exact-sized output storage.
        if unsafe {
            libc::getsockopt(
                raw,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                peer.as_mut_ptr().cast(),
                &raw mut peer_len,
            )
        } != 0
        {
            return Err(io::Error::last_os_error().into());
        }
        if usize::try_from(peer_len)? != mem::size_of::<libc::ucred>() {
            bail!("HCGF socket returned malformed peer credentials");
        }
        // SAFETY: kernel populated exactly `peer_len` bytes checked above.
        let peer = unsafe { peer.assume_init() };
        if peer.uid != expected_uid
            || peer.pid <= 0
            || u32::try_from(peer.pid).ok() != Some(expected_process_id)
        {
            bail!("HCGF socket peer uid or pid did not match compositor");
        }
        Ok(Self {
            socket,
            readiness: None,
            readiness_failed: false,
            session: Arc::new(()),
            last_accepted: None,
            outstanding: None,
            retired: false,
        })
    }

    /// Wake the sole capture collector without consuming a frame or sending
    /// HCGR. Registration failures retain periodic polling for this receiver.
    pub(crate) fn poll_readable(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        if self.retired || self.outstanding.is_some() || self.readiness_failed {
            return Poll::Pending;
        }
        if self.readiness.is_none() {
            match self.register_readiness() {
                Ok(readiness) => self.readiness = Some(readiness),
                Err(error) => {
                    self.readiness_failed = true;
                    eprintln!(
                        "atlas-capture-readiness fallback=periodic session_retained=true error={error}"
                    );
                    return Poll::Pending;
                }
            }
        }
        match self
            .readiness
            .as_ref()
            .expect("registered")
            .poll_read_ready(cx)
        {
            Poll::Ready(Ok(_guard)) => Poll::Ready(()),
            Poll::Pending => Poll::Pending,
            Poll::Ready(Err(error)) => {
                self.readiness = None;
                self.readiness_failed = true;
                eprintln!(
                    "atlas-capture-readiness fallback=periodic session_retained=true error={error}"
                );
                Poll::Pending
            }
        }
    }

    fn register_readiness(&self) -> io::Result<tokio::io::unix::AsyncFd<OwnedFd>> {
        let duplicate = self.socket.try_clone()?;
        // SAFETY: duplicate is an owned live socket. Both receive and HCGR
        // already use MSG_DONTWAIT; retaining other status flags is required.
        let flags = unsafe { libc::fcntl(duplicate.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe {
                libc::fcntl(
                    duplicate.as_raw_fd(),
                    libc::F_SETFL,
                    flags | libc::O_NONBLOCK,
                )
            } < 0
        {
            return Err(io::Error::last_os_error());
        }
        tokio::io::unix::AsyncFd::with_interest(duplicate, tokio::io::Interest::READABLE)
    }

    /// Receive one frame without queueing.  A second frame is rejected until
    /// the outstanding identity is explicitly released, enforcing one source
    /// allocation slot and preventing old packets from being mistaken as new.
    ///
    /// # Errors
    ///
    /// Returns an error when the session is retired or the packet violates
    /// the HCGF framing, descriptor, or lineage rules.
    pub fn recv_frame(&mut self) -> Result<GpuReceiveOutcome> {
        if self.retired {
            bail!("HCGF receiver session was retired after a protocol failure");
        }
        let result = self.recv_frame_checked();
        if result.is_err() {
            self.retire_session();
        }
        result
    }

    fn recv_frame_checked(&mut self) -> Result<GpuReceiveOutcome> {
        if self.outstanding.is_some() {
            bail!("HCGF source slot remains outstanding; release it after GPU reads complete");
        }
        let (bytes, fds) = match self.recv_packet()? {
            Packet::Data(bytes, fds) => (bytes, fds),
            Packet::WouldBlock => return Ok(GpuReceiveOutcome::WouldBlock),
            Packet::Disconnected => return Ok(GpuReceiveOutcome::Disconnected),
        };
        // `fds` remains owned here until moved into GpuFrame, including decode
        // and lineage rejection paths.
        let metadata = decode(&bytes[..HCGF_BYTES])
            .map_err(|error| anyhow::anyhow!("invalid HCGF metadata: {error:?}"))?;
        let input_geometry = if bytes.len() == HCGF_BYTES + HCGI_BYTES {
            Some(
                decode_input_geometry(&bytes[HCGF_BYTES..])
                    .map_err(|error| anyhow::anyhow!("invalid HCGI input geometry: {error:?}"))?,
            )
        } else {
            None
        };
        let identity = FrameIdentity {
            sequence: metadata.sequence,
            geometry_epoch: metadata.geometry_epoch,
        };
        if let Some(last) = self.last_accepted {
            if identity.sequence <= last.sequence || identity.geometry_epoch < last.geometry_epoch {
                bail!("HCGF frame sequence or geometry epoch is stale");
            }
        }
        let mut fds = fds.into_iter();
        let image = fds
            .next()
            .ok_or_else(|| anyhow::anyhow!("HCGF packet lost image FD"))?;
        let fence = fds
            .next()
            .ok_or_else(|| anyhow::anyhow!("HCGF packet lost fence FD"))?;
        self.last_accepted = Some(identity);
        self.outstanding = Some(identity);
        Ok(GpuReceiveOutcome::Frame(Box::new(GpuFrame {
            metadata,
            input_geometry,
            image,
            fence,
            session: Arc::clone(&self.session),
        })))
    }

    /// Wait a bounded amount of time for the native fence to become readable.
    ///
    /// The caller selects its original frame deadline; this helper never turns
    /// a timeout into a release or presentation acknowledgement.
    ///
    /// # Errors
    ///
    /// Returns an error if polling the native fence fails or it reports an
    /// invalid descriptor state.
    pub fn wait_for_fence(&self, frame: &GpuFrame, timeout: Duration) -> Result<bool> {
        let millis = i32::try_from(timeout.as_millis().min(i32::MAX as u128))?;
        let mut pollfd = libc::pollfd {
            fd: frame.fence.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: pollfd is initialized writable storage for exactly one entry.
        let status = unsafe { libc::poll(&raw mut pollfd, 1, millis) };
        if status < 0 {
            return Err(io::Error::last_os_error().into());
        }
        if status == 0 {
            return Ok(false);
        }
        if pollfd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            bail!("HCGF native fence became invalid");
        }
        Ok(pollfd.revents & libc::POLLIN != 0)
    }

    /// Send HCGR for exactly the outstanding allocation after all source GPU
    /// reads have completed.  This is explicit and is never invoked by Drop.
    ///
    /// # Errors
    ///
    /// Returns an error when the frame identity/session does not match the
    /// outstanding allocation or the release cannot be sent completely.
    pub fn release_after_source_reads(&mut self, frame: &GpuFrame) -> Result<()> {
        self.validate_outstanding(frame)?;
        let identity = FrameIdentity {
            sequence: frame.metadata.sequence,
            geometry_epoch: frame.metadata.geometry_epoch,
        };
        let bytes = GpuRelease {
            sequence: identity.sequence,
            geometry_epoch: identity.geometry_epoch,
        }
        .encode()
        .map_err(|error| anyhow::anyhow!("invalid HCGR identity: {error:?}"))?;
        // SAFETY: the byte array is valid input for the live seqpacket socket.
        let sent = unsafe {
            libc::send(
                self.socket.as_raw_fd(),
                bytes.as_ptr().cast(),
                bytes.len(),
                libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT,
            )
        };
        if sent < 0 {
            return Err(
                anyhow::Error::new(io::Error::last_os_error()).context(format!(
                    "release HCGF allocation sequence={} epoch={}",
                    identity.sequence, identity.geometry_epoch
                )),
            );
        }
        if usize::try_from(sent).ok() != Some(bytes.len()) {
            bail!("short HCGR seqpacket write");
        }
        self.outstanding = None;
        Ok(())
    }

    /// Verify ownership before passing a source allocation to a GPU reader.
    /// # Errors
    /// Rejects retired sessions, foreign frames and non-outstanding allocations.
    pub fn validate_outstanding(&self, frame: &GpuFrame) -> Result<()> {
        let identity = FrameIdentity {
            sequence: frame.metadata.sequence,
            geometry_epoch: frame.metadata.geometry_epoch,
        };
        if self.retired || self.outstanding != Some(identity) {
            bail!("HCGF allocation is not outstanding on a live receiver");
        }
        if !Arc::ptr_eq(&self.session, &frame.session) {
            bail!("HCGF frame belongs to a different receiver session");
        }
        Ok(())
    }

    /// Retire this receiver session without HCGR.
    ///
    /// Use this when native encoding/import fails, the source-read completion
    /// cannot be proven, or the consumer disconnects. Dropping the socket
    /// forces the producer to retire rather than reuse the outstanding source.
    pub fn retire_unreleased(self) {}

    fn retire_session(&mut self) {
        self.retired = true;
        // SAFETY: this is this receiver's connected socket; shutdown is
        // idempotent and causes the producer to retire uncertain ownership.
        let _ = unsafe { libc::shutdown(self.socket.as_raw_fd(), libc::SHUT_RDWR) };
    }

    fn recv_packet(&self) -> Result<Packet> {
        let Some(readiness) = &self.readiness else {
            return self.recv_packet_raw();
        };
        // Only an actual recvmsg EAGAIN clears cached readiness. All framing,
        // descriptor and lineage errors retain their existing handling.
        match readiness.try_io(tokio::io::Interest::READABLE, |_| {
            match self.recv_packet_raw() {
                Ok(Packet::WouldBlock) => Err(io::ErrorKind::WouldBlock.into()),
                result => Ok(result),
            }
        }) {
            Ok(result) => result,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(Packet::WouldBlock),
            Err(error) => Err(error.into()),
        }
    }

    fn recv_packet_raw(&self) -> Result<Packet> {
        let mut bytes = [0_u8; HCGF_BYTES + HCGI_BYTES];
        let mut iov = libc::iovec {
            iov_base: bytes.as_mut_ptr().cast(),
            iov_len: bytes.len(),
        };
        // Large enough to observe excess rights instead of silently accepting
        // them; MSG_CTRUNC remains a hard rejection for even larger payloads.
        let mut control = [0_usize; 64];
        let mut message = libc::msghdr {
            msg_name: std::ptr::null_mut(),
            msg_namelen: 0,
            msg_iov: &raw mut iov,
            msg_iovlen: 1,
            msg_control: control.as_mut_ptr().cast(),
            msg_controllen: mem::size_of_val(&control),
            msg_flags: 0,
        };
        // SAFETY: all pointers name live writable stack storage for this call.
        let received = unsafe {
            libc::recvmsg(
                self.socket.as_raw_fd(),
                &raw mut message,
                libc::MSG_CMSG_CLOEXEC | libc::MSG_DONTWAIT,
            )
        };
        if received < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::WouldBlock {
                Ok(Packet::WouldBlock)
            } else {
                Err(error.into())
            };
        }
        let (fds, valid_control) = received_rights(&message)?;
        if message.msg_flags & (libc::MSG_TRUNC | libc::MSG_CTRUNC) != 0 {
            bail!("truncated HCGF seqpacket or ancillary data");
        }
        if received == 0 {
            if !valid_control || !fds.is_empty() {
                bail!("zero-byte HCGF packet carried ancillary data");
            }
            return Ok(Packet::Disconnected);
        }
        let received = usize::try_from(received)?;
        if received != HCGF_BYTES && received != HCGF_BYTES + HCGI_BYTES {
            bail!("HCGF seqpacket must be 232 bytes, or 320 with HCGI");
        }
        if !valid_control || fds.len() != 2 {
            bail!("HCGF packet must carry exactly two SCM_RIGHTS FDs");
        }
        Ok(Packet::Data(bytes[..received].to_vec(), fds))
    }
}

fn socket_option_i32(raw: i32, name: i32) -> Result<i32> {
    let mut value = 0_i32;
    let mut length = libc::socklen_t::try_from(mem::size_of_val(&value))?;
    // SAFETY: valid owned socket and exact-sized writable output storage.
    if unsafe {
        libc::getsockopt(
            raw,
            libc::SOL_SOCKET,
            name,
            (&raw mut value).cast(),
            &raw mut length,
        )
    } != 0
    {
        return Err(io::Error::last_os_error().into());
    }
    if length as usize != mem::size_of_val(&value) {
        bail!("HCGF socket returned malformed option");
    }
    Ok(value)
}

enum Packet {
    Data(Vec<u8>, Vec<OwnedFd>),
    WouldBlock,
    Disconnected,
}

/// Transfer kernel-owned rights into RAII descriptors while validating every
/// cmsg boundary. Any later rejection simply drops this vector.
fn received_rights(message: &libc::msghdr) -> Result<(Vec<OwnedFd>, bool)> {
    let total = message.msg_controllen;
    let header_len = mem::size_of::<libc::cmsghdr>();
    let align = mem::size_of::<usize>();
    let mut offset = 0_usize;
    let mut fds = Vec::new();
    let mut valid = true;
    while offset < total {
        if total - offset < header_len {
            bail!("malformed HCGF ancillary data");
        }
        // SAFETY: the checked range contains a kernel-written cmsghdr.
        let cmsg: libc::cmsghdr = unsafe {
            std::ptr::read_unaligned((message.msg_control.cast::<u8>().add(offset)).cast())
        };
        let cmsg_len = cmsg.cmsg_len as usize;
        if cmsg_len < header_len || cmsg_len > total - offset {
            bail!("malformed HCGF ancillary data");
        }
        let payload_len = cmsg_len - header_len;
        if cmsg.cmsg_level != libc::SOL_SOCKET || cmsg.cmsg_type != libc::SCM_RIGHTS {
            valid = false;
        } else if payload_len % mem::size_of::<libc::c_int>() != 0 {
            bail!("malformed HCGF SCM_RIGHTS payload");
        } else {
            for index in 0..payload_len / mem::size_of::<libc::c_int>() {
                // SAFETY: index is bounded by the validated cmsg payload.
                let raw = unsafe {
                    std::ptr::read_unaligned(
                        message
                            .msg_control
                            .cast::<u8>()
                            .add(offset + header_len + index * mem::size_of::<libc::c_int>())
                            .cast(),
                    )
                };
                if raw < 0 {
                    bail!("malformed HCGF descriptor");
                }
                // SAFETY: SCM_RIGHTS transferred ownership to this process.
                fds.push(unsafe { OwnedFd::from_raw_fd(raw) });
            }
        }
        let Some(next) = cmsg_len.checked_add(align - 1).map(|n| n & !(align - 1)) else {
            bail!("malformed HCGF ancillary data");
        };
        if next > total {
            if offset + cmsg_len == total {
                break;
            }
            bail!("malformed HCGF ancillary data");
        }
        offset += next;
    }
    Ok((fds, valid))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hyprcapture_gpu_wire::{FLAG_PREMULTIPLIED, FORMAT_ABGR8888};

    #[allow(unsafe_code)]
    fn pair() -> (OwnedFd, OwnedFd) {
        let mut raw = [-1; 2];
        // SAFETY: output has exactly two descriptor slots.
        assert_eq!(
            unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0, raw.as_mut_ptr()) },
            0
        );
        // SAFETY: each successful socketpair result has one owner.
        unsafe { (OwnedFd::from_raw_fd(raw[0]), OwnedFd::from_raw_fd(raw[1])) }
    }

    #[allow(unsafe_code)]
    fn eventfd() -> OwnedFd {
        // SAFETY: eventfd has no pointer inputs and returns one owned FD.
        let raw = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        assert!(raw >= 0);
        // SAFETY: fresh successful descriptor is uniquely owned.
        unsafe { OwnedFd::from_raw_fd(raw) }
    }

    fn frame(sequence: u64, epoch: u64) -> [u8; HCGF_BYTES] {
        let mut bytes = [0_u8; HCGF_BYTES];
        bytes[..4].copy_from_slice(b"HCGF");
        bytes[4..6].copy_from_slice(&1_u16.to_be_bytes());
        bytes[6..8].copy_from_slice(&(HCGF_BYTES as u16).to_be_bytes());
        bytes[8..16].copy_from_slice(&sequence.to_be_bytes());
        bytes[16..24].copy_from_slice(&(1_u64).to_be_bytes());
        bytes[24..32].copy_from_slice(&epoch.to_be_bytes());
        for offset in [32, 40] {
            bytes[offset..offset + 8].copy_from_slice(&0_f64.to_bits().to_be_bytes());
        }
        for offset in [48, 56] {
            bytes[offset..offset + 8].copy_from_slice(&1_f64.to_bits().to_be_bytes());
        }
        for offset in [64, 68] {
            bytes[offset..offset + 4].copy_from_slice(&1_u32.to_be_bytes());
        }
        bytes[72..76].copy_from_slice(&FORMAT_ABGR8888.to_be_bytes());
        bytes[76..80].copy_from_slice(&4_u32.to_be_bytes());
        bytes[104..108].copy_from_slice(&1_u32.to_be_bytes());
        bytes[108..112].copy_from_slice(&1_u32.to_be_bytes());
        bytes[112..116].copy_from_slice(&FLAG_PREMULTIPLIED.to_be_bytes());
        bytes
    }

    #[allow(unsafe_code)]
    fn send(sender: &OwnedFd, bytes: &[u8], fds: &[i32]) {
        let mut iov = libc::iovec {
            iov_base: bytes.as_ptr().cast_mut().cast(),
            iov_len: bytes.len(),
        };
        let control_len = if fds.is_empty() {
            0
        } else {
            unsafe { libc::CMSG_SPACE(mem::size_of_val(fds) as _) as usize }
        };
        let mut control = vec![0_usize; control_len.div_ceil(mem::size_of::<usize>())];
        let message = libc::msghdr {
            msg_name: std::ptr::null_mut(),
            msg_namelen: 0,
            msg_iov: &raw mut iov,
            msg_iovlen: 1,
            msg_control: if fds.is_empty() {
                std::ptr::null_mut()
            } else {
                control.as_mut_ptr().cast()
            },
            msg_controllen: control_len,
            msg_flags: 0,
        };
        if !fds.is_empty() {
            // SAFETY: CMSG_SPACE allocated aligned writable control storage.
            let cmsg = unsafe { libc::CMSG_FIRSTHDR(&message) };
            assert!(!cmsg.is_null());
            // SAFETY: first header/data area fits the allocated control buffer.
            unsafe {
                (*cmsg).cmsg_level = libc::SOL_SOCKET;
                (*cmsg).cmsg_type = libc::SCM_RIGHTS;
                (*cmsg).cmsg_len = libc::CMSG_LEN(mem::size_of_val(fds) as _) as _;
                std::ptr::copy_nonoverlapping(
                    fds.as_ptr().cast::<u8>(),
                    libc::CMSG_DATA(cmsg),
                    mem::size_of_val(fds),
                );
            }
        }
        // SAFETY: message references live input and optional ancillary storage.
        assert_eq!(
            unsafe { libc::sendmsg(sender.as_raw_fd(), &message, 0) },
            bytes.len() as isize
        );
    }

    fn receiver(socket: OwnedFd) -> HyprCaptureGpuSocketReceiver {
        // SAFETY: test identity query has no preconditions.
        HyprCaptureGpuSocketReceiver::new(socket, unsafe { libc::geteuid() }, std::process::id())
            .unwrap()
    }

    #[test]
    fn receives_frozen_input_geometry_with_the_same_frame_and_fds() {
        for malformed in [false, true] {
            let (socket, sender) = pair();
            let image = eventfd();
            let fence = eventfd();
            let mut packet = frame(1, 1).to_vec();
            // Full artifact encloses the C++ fixture's global content rectangle.
            for (at, value) in [(32, -10_f64), (40, -10_f64), (48, 820_f64), (56, 640_f64)] {
                packet[at..at + 8].copy_from_slice(&value.to_be_bytes());
            }
            packet.extend(crate::hyprcapture_gpu_wire::input_geometry_golden());
            if malformed {
                packet[HCGF_BYTES + 80] = 1;
            }
            send(&sender, &packet, &[image.as_raw_fd(), fence.as_raw_fd()]);
            let mut receiver = receiver(socket);
            if malformed {
                assert!(receiver.recv_frame().is_err());
                assert!(receiver.retired);
            } else {
                let GpuReceiveOutcome::Frame(frame) = receiver.recv_frame().unwrap() else {
                    panic!("missing extended frame");
                };
                let input = frame.input_geometry().unwrap();
                assert_eq!(input.window, 0x1234);
                assert_eq!(input.surface_extent, [400.0, 300.0]);
                assert_eq!(frame.metadata().sequence, 1);
                use viewflow_core::PresentedInputIdentity;
                use viewflow_protocol::{Id128, Point, Size};
                let identity = PresentedInputIdentity {
                    window: Id128(3),
                    geometry_epoch: 1,
                    frame: 1,
                };
                let authorized = crate::window_input_runtime::AuthorizedWindow::from_gpu_frame(
                    &frame,
                    Id128(1),
                    Id128(2),
                    7,
                    1_000_000_000,
                    identity,
                )
                .unwrap();
                assert_eq!(authorized.native_surface, 0x5678);
                assert_eq!(authorized.content_scale, [0.5, 0.5]);
                let viewport = Size {
                    width: 820.0,
                    height: 640.0,
                };
                assert!(
                    authorized
                        .geometry
                        .map_pointer(identity, viewport, Point { x: 0.0, y: 0.0 })
                        .is_none()
                );
                let center = authorized
                    .geometry
                    .map_pointer(
                        identity,
                        viewport,
                        Point {
                            x: 407.5,
                            y: 313.25,
                        },
                    )
                    .unwrap();
                assert!((center.x * authorized.content_scale[0] - 200.0).abs() < 1e-9);
                assert!((center.y * authorized.content_scale[1] - 150.0).abs() < 1e-9);
                assert!(
                    crate::window_input_runtime::AuthorizedWindow::from_gpu_frame(
                        &frame,
                        Id128(1),
                        Id128(2),
                        7,
                        1_000_000_000,
                        PresentedInputIdentity {
                            frame: 2,
                            ..identity
                        }
                    )
                    .is_err()
                );
            }
        }
    }

    #[test]
    fn receives_exact_two_fds_and_explicitly_releases() {
        let (socket, sender) = pair();
        let image = eventfd();
        let fence = eventfd();
        send(
            &sender,
            &frame(1, 1),
            &[image.as_raw_fd(), fence.as_raw_fd()],
        );
        let mut receiver = receiver(socket);
        let received = match receiver.recv_frame().unwrap() {
            GpuReceiveOutcome::Frame(frame) => frame,
            _ => panic!("missing frame"),
        };
        assert!(receiver.wait_for_fence(&received, Duration::ZERO).unwrap() == false);
        receiver.release_after_source_reads(&received).unwrap();
        let mut release = [0_u8; 32];
        // SAFETY: release is valid writable storage and sender is live.
        assert_eq!(
            unsafe {
                libc::recv(
                    sender.as_raw_fd(),
                    release.as_mut_ptr().cast(),
                    release.len(),
                    0,
                )
            },
            32
        );
        assert_eq!(
            GpuRelease::decode(&release).unwrap(),
            GpuRelease {
                sequence: 1,
                geometry_epoch: 1
            }
        );
    }

    async fn wait_readable(receiver: &mut HyprCaptureGpuSocketReceiver) {
        tokio::time::timeout(
            Duration::from_secs(1),
            std::future::poll_fn(|cx| receiver.poll_readable(cx)),
        )
        .await
        .expect("capture readiness did not wake");
    }

    #[tokio::test]
    async fn capture_readiness_rearms_without_consuming_or_releasing() {
        let (socket, sender) = pair();
        let mut receiver = receiver(socket);
        let image = eventfd();
        let fence = eventfd();
        for sequence in 1..=64 {
            // After the previous frame this recvmsg must clear stale cached
            // readiness, allowing the next edge to wake the same receiver.
            assert!(matches!(
                receiver.recv_frame().unwrap(),
                GpuReceiveOutcome::WouldBlock
            ));
            let mut cx = Context::from_waker(std::task::Waker::noop());
            assert!(receiver.poll_readable(&mut cx).is_pending());
            send(
                &sender,
                &frame(sequence, 1),
                &[image.as_raw_fd(), fence.as_raw_fd()],
            );
            wait_readable(&mut receiver).await;
            assert!(receiver.outstanding.is_none());
            let received = match receiver.recv_frame().unwrap() {
                GpuReceiveOutcome::Frame(frame) => frame,
                _ => panic!("readiness lost the frame"),
            };
            assert_eq!(received.metadata().sequence, sequence);
            assert!(receiver.poll_readable(&mut cx).is_pending());
            let mut release = [0_u8; 32];
            // SAFETY: live test socket and exact writable output buffer.
            assert_eq!(
                unsafe {
                    libc::recv(
                        sender.as_raw_fd(),
                        release.as_mut_ptr().cast(),
                        release.len(),
                        libc::MSG_DONTWAIT,
                    )
                },
                -1
            );
            assert_eq!(io::Error::last_os_error().kind(), io::ErrorKind::WouldBlock);
            receiver.release_after_source_reads(&received).unwrap();
            // SAFETY: release is writable and HCGR was just sent synchronously.
            assert_eq!(
                unsafe {
                    libc::recv(
                        sender.as_raw_fd(),
                        release.as_mut_ptr().cast(),
                        release.len(),
                        libc::MSG_DONTWAIT,
                    )
                },
                32
            );
            assert_eq!(GpuRelease::decode(&release).unwrap().sequence, sequence);
        }
    }

    #[tokio::test]
    async fn capture_readiness_survives_cancelled_wait_and_reports_disconnect() {
        let (socket, sender) = pair();
        let mut receiver = receiver(socket);
        {
            let mut wait = std::pin::pin!(std::future::poll_fn(|cx| receiver.poll_readable(cx)));
            let mut cx = Context::from_waker(std::task::Waker::noop());
            assert!(std::future::Future::poll(wait.as_mut(), &mut cx).is_pending());
        }
        drop(sender);
        wait_readable(&mut receiver).await;
        assert!(matches!(
            receiver.recv_frame().unwrap(),
            GpuReceiveOutcome::Disconnected
        ));
    }

    #[cfg(feature = "native-gpu-nvenc")]
    #[tokio::test]
    async fn capture_readiness_collects_partial_sources_and_survives_restore() {
        use crate::gpu_atlas_capture::AtlasCapturePool;
        use viewflow_protocol::Id128;
        let (socket_a, sender_a) = pair();
        let (socket_b, sender_b) = pair();
        let image = eventfd();
        let fence = eventfd();
        let mut pool = AtlasCapturePool::new(
            vec![
                (Id128(1), receiver(socket_a)),
                (Id128(2), receiver(socket_b)),
            ],
            100,
        )
        .unwrap();
        for sequence in 1..=4 {
            assert!(pool.poll_ready_at(10).unwrap().is_none());
            let mut cx = Context::from_waker(std::task::Waker::noop());
            assert!(pool.poll_readable(&mut cx).is_pending());
            send(
                &sender_a,
                &frame(sequence, 1),
                &[image.as_raw_fd(), fence.as_raw_fd()],
            );
            tokio::time::timeout(
                Duration::from_secs(1),
                std::future::poll_fn(|cx| pool.poll_readable(cx)),
            )
            .await
            .unwrap();
            assert!(pool.poll_ready_at(10).unwrap().is_none());
            // A's cached readiness must not spin while its frame is held.
            assert!(pool.poll_readable(&mut cx).is_pending());
            send(
                &sender_b,
                &frame(sequence, 1),
                &[image.as_raw_fd(), fence.as_raw_fd()],
            );
            tokio::time::timeout(
                Duration::from_secs(1),
                std::future::poll_fn(|cx| pool.poll_readable(cx)),
            )
            .await
            .unwrap();
            let batch = pool.poll_ready_at(10).unwrap().unwrap();
            assert_eq!(batch.len(), 2);
            let mut returned = Vec::new();
            for mut source in batch {
                assert_eq!(source.frame.metadata().sequence, sequence);
                assert_eq!(source.deadline_monotonic_ns, 101);
                source
                    .receiver
                    .release_after_source_reads(&source.frame)
                    .unwrap();
                returned.push((source.window, source.receiver));
            }
            pool.restore(returned).unwrap();
        }
    }

    #[test]
    fn native_encode_failure_retires_without_ack() {
        let (socket, sender) = pair();
        let image = eventfd();
        let fence = eventfd();
        send(
            &sender,
            &frame(2, 1),
            &[image.as_raw_fd(), fence.as_raw_fd()],
        );
        let mut receiver = receiver(socket);
        let received = match receiver.recv_frame().unwrap() {
            GpuReceiveOutcome::Frame(frame) => frame,
            _ => panic!("missing frame"),
        };
        drop(received); // native encode/source-read completion was not proven.
        receiver.retire_unreleased();
        // EOF proves retirement; no HCGR packet was emitted before it.
        let mut byte = 0_u8;
        // SAFETY: valid one-byte output; MSG_DONTWAIT prevents a blocking test.
        assert_eq!(
            unsafe {
                libc::recv(
                    sender.as_raw_fd(),
                    (&raw mut byte).cast(),
                    1,
                    libc::MSG_DONTWAIT,
                )
            },
            0
        );
    }

    #[test]
    fn rejects_old_sequence_after_a_released_slot() {
        let (socket, sender) = pair();
        let image = eventfd();
        let fence = eventfd();
        send(
            &sender,
            &frame(2, 2),
            &[image.as_raw_fd(), fence.as_raw_fd()],
        );
        let mut receiver = receiver(socket);
        let received = match receiver.recv_frame().unwrap() {
            GpuReceiveOutcome::Frame(frame) => frame,
            _ => panic!("missing frame"),
        };
        receiver.release_after_source_reads(&received).unwrap();
        let mut release = [0_u8; 32];
        // SAFETY: release is valid writable storage for this local test socket.
        assert_eq!(
            unsafe {
                libc::recv(
                    sender.as_raw_fd(),
                    release.as_mut_ptr().cast(),
                    release.len(),
                    0,
                )
            },
            32
        );
        let image = eventfd();
        let fence = eventfd();
        send(
            &sender,
            &frame(1, 1),
            &[image.as_raw_fd(), fence.as_raw_fd()],
        );
        assert!(receiver.recv_frame().is_err());
    }

    #[test]
    #[cfg(feature = "native-gpu-nvenc")]
    fn removing_idle_source_keeps_other_lease_and_never_sends_unproved_release() {
        use crate::gpu_atlas_capture::AtlasCapturePool;
        use viewflow_protocol::Id128;
        for removed in [Id128(1), Id128(2)] {
            let (socket_a, sender_a) = pair();
            let (socket_b, sender_b) = pair();
            let image = eventfd();
            let fence = eventfd();
            let mut pool = AtlasCapturePool::new(
                vec![
                    (Id128(1), receiver(socket_a)),
                    (Id128(2), receiver(socket_b)),
                ],
                10,
            )
            .unwrap();
            send(
                &sender_a,
                &frame(1, 1),
                &[image.as_raw_fd(), fence.as_raw_fd()],
            );
            assert!(pool.poll_ready_at(5).unwrap().is_none());
            pool.remove_at_frame_boundary(removed).unwrap();
            if removed == Id128(1) {
                send(
                    &sender_b,
                    &frame(1, 1),
                    &[image.as_raw_fd(), fence.as_raw_fd()],
                );
            }
            let remaining = if removed == Id128(1) {
                Id128(2)
            } else {
                Id128(1)
            };
            let batch = pool.poll_ready_at(6).unwrap().unwrap();
            assert_eq!(batch.len(), 1);
            assert_eq!(batch[0].window, remaining);
            assert_eq!(batch[0].deadline_monotonic_ns, 11);
            assert!(pool.remove_at_frame_boundary(remaining).is_err());
            let mut bytes = [0; 32];
            // SAFETY: valid live socket and writable array. A removed collector
            // closes its socket; it never pretends a GPU reader completed.
            assert_eq!(
                unsafe {
                    libc::recv(
                        if removed == Id128(1) {
                            sender_a.as_raw_fd()
                        } else {
                            sender_b.as_raw_fd()
                        },
                        bytes.as_mut_ptr().cast(),
                        bytes.len(),
                        libc::MSG_DONTWAIT,
                    )
                },
                0
            );
            drop(batch);
        }
    }

    #[test]
    #[cfg(feature = "native-gpu-nvenc")]
    fn atlas_pool_disconnect_closes_pending_sources_without_release() {
        use crate::gpu_atlas_capture::AtlasCapturePool;
        use viewflow_protocol::Id128;
        let (socket_a, sender_a) = pair();
        let (socket_b, sender_b) = pair();
        let image = eventfd();
        let fence = eventfd();
        let mut pool = AtlasCapturePool::new(
            vec![
                (Id128(1), receiver(socket_a)),
                (Id128(2), receiver(socket_b)),
            ],
            10,
        )
        .unwrap();
        send(
            &sender_a,
            &frame(1, 1),
            &[image.as_raw_fd(), fence.as_raw_fd()],
        );
        assert!(pool.poll_ready_at(5).unwrap().is_none());
        drop(sender_b);
        assert!(pool.poll_ready_at(6).is_err());
        let mut packet = [0; crate::hyprcapture_gpu_release::RELEASE_BYTES];
        // SAFETY: live producer socket and valid writable buffer.
        let received = unsafe {
            libc::recv(
                sender_a.as_raw_fd(),
                packet.as_mut_ptr().cast(),
                packet.len(),
                libc::MSG_DONTWAIT,
            )
        };
        assert_eq!(
            received, 0,
            "pending source must close without an HCGR packet"
        );
        assert!(
            pool.restore(vec![])
                .unwrap_err()
                .to_string()
                .contains("retired")
        );
    }

    #[test]
    #[cfg(feature = "native-gpu-nvenc")]
    fn atlas_pool_holds_one_slot_and_expires_without_renewal() {
        use crate::gpu_atlas_capture::AtlasCapturePool;
        use viewflow_protocol::Id128;
        let (socket_a, sender_a) = pair();
        let (socket_b, sender_b) = pair();
        let image = eventfd();
        let fence = eventfd();
        let mut pool = AtlasCapturePool::new(
            vec![
                (Id128(1), receiver(socket_a)),
                (Id128(2), receiver(socket_b)),
            ],
            20,
        )
        .unwrap();
        send(
            &sender_a,
            &frame(1, 1),
            &[image.as_raw_fd(), fence.as_raw_fd()],
        );
        assert!(pool.poll_ready_at(5).unwrap().is_none());
        // A second poll must not recv from A's still-outstanding single slot.
        assert!(pool.poll_ready_at(6).unwrap().is_none());
        pool.tighten_age(10).unwrap();
        assert!(pool.tighten_age(11).is_err());
        assert!(pool.poll_ready_at(11).unwrap().is_none());
        let mut release = [0; crate::hyprcapture_gpu_release::RELEASE_BYTES];
        // SAFETY: valid writable array and live producer socket; non-blocking.
        let received = unsafe {
            libc::recv(
                sender_a.as_raw_fd(),
                release.as_mut_ptr().cast(),
                release.len(),
                libc::MSG_DONTWAIT,
            )
        };
        assert_eq!(usize::try_from(received).unwrap(), release.len());
        assert_eq!(GpuRelease::decode(&release).unwrap().sequence, 1);
        let mut next_a = frame(2, 1);
        next_a[16..24].copy_from_slice(&12_u64.to_be_bytes());
        let mut next_b = frame(1, 1);
        next_b[16..24].copy_from_slice(&12_u64.to_be_bytes());
        send(&sender_a, &next_a, &[image.as_raw_fd(), fence.as_raw_fd()]);
        send(&sender_b, &next_b, &[image.as_raw_fd(), fence.as_raw_fd()]);
        let batch = pool.poll_ready_at(13).unwrap().unwrap();
        assert_eq!(batch.len(), 2);
        assert!(pool.tighten_age(5).is_err());
        assert!(
            batch
                .iter()
                .all(|source| source.deadline_monotonic_ns == 22)
        );
        assert!(pool.poll_ready_at(14).is_err());
        let mut restored = Vec::new();
        for mut source in batch {
            source
                .receiver
                .release_after_source_reads(&source.frame)
                .unwrap();
            restored.push((source.window, source.receiver));
        }
        pool.restore(restored).unwrap();
        assert!(pool.poll_ready_at(15).unwrap().is_none());
    }

    #[test]
    fn rejects_release_from_another_receiver_session() {
        let (socket_a, sender_a) = pair();
        let (socket_b, sender_b) = pair();
        let image_a = eventfd();
        let fence_a = eventfd();
        let image_b = eventfd();
        let fence_b = eventfd();
        send(
            &sender_a,
            &frame(1, 1),
            &[image_a.as_raw_fd(), fence_a.as_raw_fd()],
        );
        send(
            &sender_b,
            &frame(1, 1),
            &[image_b.as_raw_fd(), fence_b.as_raw_fd()],
        );
        let mut receiver_a = receiver(socket_a);
        let mut receiver_b = receiver(socket_b);
        let frame_a = match receiver_a.recv_frame().unwrap() {
            GpuReceiveOutcome::Frame(frame) => frame,
            _ => panic!("missing first frame"),
        };
        let _frame_b = match receiver_b.recv_frame().unwrap() {
            GpuReceiveOutcome::Frame(frame) => frame,
            _ => panic!("missing second frame"),
        };
        assert!(receiver_a.validate_outstanding(&frame_a).is_ok());
        assert!(receiver_b.validate_outstanding(&frame_a).is_err());
        assert!(receiver_b.release_after_source_reads(&frame_a).is_err());
        receiver_a.release_after_source_reads(&frame_a).unwrap();
        assert!(receiver_a.validate_outstanding(&frame_a).is_err());
    }

    #[test]
    fn rejects_missing_or_extra_rights() {
        let (socket, sender) = pair();
        let image = eventfd();
        let fence = eventfd();
        let extra = eventfd();
        send(&sender, &frame(1, 1), &[image.as_raw_fd()]);
        assert!(receiver(socket).recv_frame().is_err());
        let (socket, sender) = pair();
        send(
            &sender,
            &frame(1, 1),
            &[image.as_raw_fd(), fence.as_raw_fd(), extra.as_raw_fd()],
        );
        assert!(receiver(socket).recv_frame().is_err());
    }

    #[test]
    fn rejects_wrong_compositor_pid() {
        let (socket, _sender) = pair();
        // socketpair's peer is this test process, not the supplied PID.
        assert!(
            HyprCaptureGpuSocketReceiver::new(
                socket,
                unsafe { libc::geteuid() },
                std::process::id().saturating_add(1),
            )
            .is_err()
        );
    }
}
