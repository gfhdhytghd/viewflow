#![allow(unsafe_code)] // Narrow Linux FD/syscall boundary; every unsafe operation is documented.

//! Linux `SOCK_SEQPACKET` receiver for the local `HyprCapture` frame stream.
//!
//! This owns an already-connected socket.  Connecting, pathname ownership,
//! and starting the producer deliberately live outside this small boundary.

use std::{
    io,
    mem::{self, MaybeUninit},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::PermissionsExt,
    },
    path::Path,
};

use anyhow::{Result, bail};

use crate::hyprcapture_gpu_socket::HyprCaptureGpuSocketReceiver;
use crate::hyprcapture_stream::{
    FrameCursor, FrameHeader, HEADER_BYTES, ReadOnlyFrameMapping, read_sealed_pixels,
    read_validated_pixels, validate_sealed_frame,
};

/// Maximum number of queued packets inspected by one latest-only receive.
///
/// This bounds syscall, descriptor-validation, and metadata work per event
/// loop turn while still shedding a substantial part of a producer backlog.
pub const MAX_LATEST_DRAIN_PACKETS: usize = 8;

/// Result of one non-blocking packet receive.
#[derive(Debug, PartialEq)]
pub enum ReceiveOutcome {
    /// A complete, authenticated frame was imported from its sealed memfd.
    Frame(FrameHeader, Vec<u8>),
    /// The socket has no complete packet available at this moment.
    WouldBlock,
    /// The connected producer closed its socket.
    Disconnected,
}

/// Result of one non-blocking latest-only mmap receive.
///
/// The mapped bytes are an immutable view of the validated sealed memfd and
/// are unmapped automatically when the mapping is dropped.
pub enum MappedReceiveOutcome {
    /// A complete, authenticated frame was imported as a read-only mapping.
    Frame(FrameHeader, ReadOnlyFrameMapping),
    /// The socket has no complete packet available at this moment.
    WouldBlock,
    /// The connected producer closed its socket.
    Disconnected,
}

/// An authenticated local `HyprCapture` packet receiver.
///
/// `expected_pid` is intentionally exact: matching only the Unix uid would
/// permit another process owned by the desktop user to submit frames.
pub struct HyprCaptureSocketReceiver {
    socket: OwnedFd,
    max_pixel_bytes: u64,
    cursor: FrameCursor,
}

/// Outcome of accepting a producer connection without blocking the compositor.
pub enum AcceptOutcome {
    /// No producer has completed a connection yet.
    WouldBlock,
    /// An authenticated connected producer socket.
    Receiver(HyprCaptureSocketReceiver),
}

/// Outcome of accepting an authenticated HCGF producer connection.
pub enum GpuAcceptOutcome {
    WouldBlock,
    Receiver(HyprCaptureGpuSocketReceiver),
}

/// Owner-private listener for one `HyprCapture` producer session.
///
/// Dropping this only closes the listening FD.  Session cleanup owns removal
/// of the filesystem entry, avoiding an unlink of a path later replaced by
/// another process.
pub struct HyprCaptureSocketListener {
    socket: OwnedFd,
}

impl HyprCaptureSocketListener {
    /// Bind a new `AF_UNIX` seqpacket listener at a previously absent path.
    #[allow(clippy::missing_errors_doc)]
    pub fn bind(path: &Path) -> Result<Self> {
        validate_socket_parent(path)?;
        match std::fs::symlink_metadata(path) {
            Ok(_) => bail!("refusing to replace existing HyprCapture socket path"),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let address = unix_address(path)?;
        // SAFETY: AF_UNIX/SOCK_SEQPACKET and CLOEXEC/NONBLOCK are Linux socket
        // creation flags and need no pointer arguments.
        let raw = unsafe {
            libc::socket(
                libc::AF_UNIX,
                libc::SOCK_SEQPACKET | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
                0,
            )
        };
        if raw < 0 {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: the fresh descriptor has exactly one owner until moved below.
        let socket = unsafe { OwnedFd::from_raw_fd(raw) };
        // SAFETY: `address` is a fully initialized sockaddr_un with the exact
        // pathname length; `socket` remains valid for the system call.
        if unsafe {
            libc::bind(
                socket.as_raw_fd(),
                (&raw const address).cast(),
                address_len(path)?,
            )
        } != 0
        {
            return Err(io::Error::last_os_error().into());
        }
        // The validated private parent prevents access while bind's umask-
        // dependent mode is tightened. Do not change the process-wide umask.
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        // SAFETY: `socket` is a successfully bound SOCK_SEQPACKET descriptor.
        if unsafe { libc::listen(socket.as_raw_fd(), 1) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        Ok(Self { socket })
    }

    /// Non-blockingly accept, then require the exact compositor uid and pid.
    #[allow(clippy::missing_errors_doc, clippy::similar_names)]
    pub fn accept(
        &self,
        expected_uid: u32,
        expected_pid: u32,
        max_pixel_bytes: u64,
    ) -> Result<AcceptOutcome> {
        // SAFETY: null address arguments intentionally discard the peer's
        // pathname; the accepted FD is obtained only on a nonnegative result.
        let raw = unsafe {
            libc::accept4(
                self.socket.as_raw_fd(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            )
        };
        if raw < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::WouldBlock {
                Ok(AcceptOutcome::WouldBlock)
            } else {
                Err(error.into())
            };
        }
        // SAFETY: a successful accept4 returns a newly owned descriptor.
        let socket = unsafe { OwnedFd::from_raw_fd(raw) };
        Ok(AcceptOutcome::Receiver(HyprCaptureSocketReceiver::new(
            socket,
            expected_uid,
            expected_pid,
            max_pixel_bytes,
        )?))
    }

    /// Non-blockingly accept a HCGF producer with exact compositor credentials.
    #[allow(clippy::missing_errors_doc)]
    pub fn accept_gpu(
        &self,
        expected_uid: u32,
        expected_process_id: u32,
    ) -> Result<GpuAcceptOutcome> {
        // SAFETY: peer pathname is intentionally ignored; ownership starts on success.
        let raw = unsafe {
            libc::accept4(
                self.socket.as_raw_fd(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            )
        };
        if raw < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::WouldBlock {
                Ok(GpuAcceptOutcome::WouldBlock)
            } else {
                Err(error.into())
            };
        }
        // SAFETY: successful accept4 returns a newly owned descriptor.
        let socket = unsafe { OwnedFd::from_raw_fd(raw) };
        Ok(GpuAcceptOutcome::Receiver(
            HyprCaptureGpuSocketReceiver::new(socket, expected_uid, expected_process_id)?,
        ))
    }
}

fn validate_socket_parent(path: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    if !path.is_absolute() || path.file_name().is_none() {
        bail!("HyprCapture socket path must be absolute and name a filesystem entry");
    }
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("HyprCapture socket path has no parent"))?;
    let expected_uid = current_euid();
    let mut current = parent;
    loop {
        let metadata = std::fs::symlink_metadata(current)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            bail!("HyprCapture socket parent chain contains a non-directory or symlink");
        }
        let mode = metadata.mode() & 0o777;
        let shared_runtime_base = current == Path::new("/tmp") || current == Path::new("/dev/shm");
        if shared_runtime_base {
            // The private descendants above were checked one by one. These
            // two system-owned sticky directories are valid runtime roots.
            if current == parent || metadata.uid() != 0 || metadata.mode() & 0o1000 == 0 {
                bail!("HyprCapture runtime base is not a trusted sticky directory");
            }
            return Ok(());
        }
        if current == parent {
            if metadata.uid() != expected_uid || mode != 0o700 {
                bail!("HyprCapture socket immediate parent must be owned 0700");
            }
        } else if metadata.uid() != expected_uid || mode & 0o077 != 0 {
            bail!("HyprCapture socket parent chain is not owner-private");
        }
        if current == Path::new("/") {
            return Ok(());
        }
        current = current
            .parent()
            .ok_or_else(|| anyhow::anyhow!("HyprCapture socket path has no parent"))?;
    }
}

fn unix_address(path: &Path) -> Result<libc::sockaddr_un> {
    use std::os::unix::ffi::OsStrExt;

    let bytes = path.as_os_str().as_bytes();
    let capacity =
        mem::size_of::<libc::sockaddr_un>() - mem::offset_of!(libc::sockaddr_un, sun_path);
    if bytes.is_empty() || bytes.len() >= capacity || bytes.contains(&0) {
        bail!("HyprCapture socket path is not a valid filesystem Unix socket path");
    }
    // SAFETY: zero is a valid initial representation for sockaddr_un.
    let mut address = unsafe { mem::zeroed::<libc::sockaddr_un>() };
    address.sun_family = libc::sa_family_t::try_from(libc::AF_UNIX)?;
    // SAFETY: checked pathname length leaves one NUL byte inside sun_path.
    unsafe {
        std::ptr::copy_nonoverlapping(
            bytes.as_ptr(),
            address.sun_path.as_mut_ptr().cast::<u8>(),
            bytes.len(),
        );
    }
    Ok(address)
}

fn address_len(path: &Path) -> Result<libc::socklen_t> {
    use std::os::unix::ffi::OsStrExt;

    let length = mem::offset_of!(libc::sockaddr_un, sun_path)
        .checked_add(path.as_os_str().as_bytes().len())
        .and_then(|value| value.checked_add(1))
        .ok_or_else(|| anyhow::anyhow!("HyprCapture socket path is too long"))?;
    Ok(length.try_into()?)
}

#[allow(unsafe_code)] // Linux identity query has no inputs or pointers.
fn current_euid() -> u32 {
    // SAFETY: geteuid takes no arguments and has no preconditions.
    unsafe { libc::geteuid() }
}

impl HyprCaptureSocketReceiver {
    /// Validate a connected Linux Unix-domain `SOCK_SEQPACKET` socket and its
    /// immutable peer credentials before accepting any ancillary descriptors.
    #[allow(clippy::missing_errors_doc, clippy::similar_names)]
    pub fn new(
        socket: OwnedFd,
        expected_uid: u32,
        expected_pid: u32,
        max_pixel_bytes: u64,
    ) -> Result<Self> {
        if max_pixel_bytes == 0 {
            bail!("HyprCapture maximum pixel size must be nonzero");
        }
        let raw = socket.as_raw_fd();
        let mut socket_type = 0_i32;
        let mut socket_type_len = libc::socklen_t::try_from(mem::size_of_val(&socket_type))?;
        // SAFETY: `raw` is owned by `socket`; the output pointers refer to the
        // live local variables and their supplied lengths are exact.
        if unsafe {
            libc::getsockopt(
                raw,
                libc::SOL_SOCKET,
                libc::SO_TYPE,
                (&raw mut socket_type).cast(),
                &raw mut socket_type_len,
            )
        } != 0
        {
            return Err(io::Error::last_os_error().into());
        }
        if socket_type_len as usize != mem::size_of_val(&socket_type)
            || socket_type != libc::SOCK_SEQPACKET
        {
            bail!("HyprCapture socket is not SOCK_SEQPACKET");
        }

        let mut domain = 0_i32;
        let mut domain_len = libc::socklen_t::try_from(mem::size_of_val(&domain))?;
        // SAFETY: `raw` is owned by `socket`; the output pointers refer to the
        // live local variables and their supplied lengths are exact.
        if unsafe {
            libc::getsockopt(
                raw,
                libc::SOL_SOCKET,
                libc::SO_DOMAIN,
                (&raw mut domain).cast(),
                &raw mut domain_len,
            )
        } != 0
        {
            return Err(io::Error::last_os_error().into());
        }
        if domain_len as usize != mem::size_of_val(&domain) || domain != libc::AF_UNIX {
            bail!("HyprCapture socket is not an AF_UNIX socket");
        }

        let mut peer = MaybeUninit::<libc::ucred>::zeroed();
        let mut peer_len = libc::socklen_t::try_from(mem::size_of::<libc::ucred>())?;
        // SAFETY: `raw` is valid and `peer` is suitably sized output storage.
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
        if peer_len as usize != mem::size_of::<libc::ucred>() {
            bail!("HyprCapture socket returned malformed peer credentials");
        }
        // SAFETY: the kernel wrote a complete `ucred`, checked by `peer_len`.
        let peer = unsafe { peer.assume_init() };
        if peer.uid != expected_uid
            || peer.pid <= 0
            || u32::try_from(peer.pid).ok() != Some(expected_pid)
        {
            bail!("HyprCapture socket peer uid or pid did not match compositor");
        }
        Ok(Self {
            socket,
            max_pixel_bytes,
            cursor: FrameCursor::default(),
        })
    }

    /// Receive one full seqpacket and consume its one sealed pixel memfd.
    ///
    /// Descriptor ownership is transferred immediately into `OwnedFd`s, so
    /// every rejection path closes all received `SCM_RIGHTS` descriptors.
    #[allow(clippy::missing_errors_doc, clippy::missing_panics_doc)]
    pub fn recv_frame(&mut self) -> Result<ReceiveOutcome> {
        let (header, fd) = match self.recv_packet()? {
            PacketReceiveOutcome::Packet(header, fd) => (header, fd),
            PacketReceiveOutcome::WouldBlock => return Ok(ReceiveOutcome::WouldBlock),
            PacketReceiveOutcome::Disconnected => return Ok(ReceiveOutcome::Disconnected),
        };
        let (frame, pixels) = read_sealed_pixels(fd, &header, self.max_pixel_bytes)?;
        self.cursor.accept(&frame)?;
        Ok(ReceiveOutcome::Frame(frame, pixels))
    }

    /// Receive up to a bounded number of packets and import only the newest.
    ///
    /// Every drained packet is fully authenticated and its sealed memfd is
    /// validated before it is discarded.  Consequently malformed or replayed
    /// intermediate packets remain fatal rather than being hidden by frame
    /// shedding; only the costly pixel read is deferred to the newest packet.
    #[allow(clippy::missing_errors_doc, clippy::missing_panics_doc)]
    pub fn recv_latest_frame(&mut self) -> Result<ReceiveOutcome> {
        let mut latest = None;
        let mut disconnected = false;
        for _ in 0..MAX_LATEST_DRAIN_PACKETS {
            match self.recv_packet()? {
                PacketReceiveOutcome::Packet(header, fd) => {
                    let (frame, file) = validate_sealed_frame(fd, &header, self.max_pixel_bytes)?;
                    self.cursor.accept(&frame)?;
                    latest = Some((frame, file));
                }
                PacketReceiveOutcome::WouldBlock => break,
                PacketReceiveOutcome::Disconnected => {
                    disconnected = true;
                    break;
                }
            }
        }
        if let Some((frame, file)) = latest {
            return Ok(ReceiveOutcome::Frame(
                frame.clone(),
                read_validated_pixels(&file, &frame)?,
            ));
        }
        if disconnected {
            Ok(ReceiveOutcome::Disconnected)
        } else {
            Ok(ReceiveOutcome::WouldBlock)
        }
    }

    /// Receive up to a bounded number of packets and map only the newest.
    ///
    /// Every drained packet is fully decoded, seal/owner/length validated,
    /// and sequence checked before it is discarded. The returned mapping is
    /// established only after those checks pass and never exposes mutable
    /// pixels; all rejected packet descriptors are dropped promptly.
    #[allow(clippy::missing_errors_doc, clippy::missing_panics_doc)]
    pub fn recv_latest_mapped_frame(&mut self) -> Result<MappedReceiveOutcome> {
        let mut latest = None;
        let mut disconnected = false;
        for _ in 0..MAX_LATEST_DRAIN_PACKETS {
            match self.recv_packet()? {
                PacketReceiveOutcome::Packet(header, fd) => {
                    let (frame, file) = validate_sealed_frame(fd, &header, self.max_pixel_bytes)?;
                    self.cursor.accept(&frame)?;
                    latest = Some((frame, file));
                }
                PacketReceiveOutcome::WouldBlock => break,
                PacketReceiveOutcome::Disconnected => {
                    disconnected = true;
                    break;
                }
            }
        }
        if let Some((frame, file)) = latest {
            let mapping = ReadOnlyFrameMapping::from_validated(&file, &frame)?;
            return Ok(MappedReceiveOutcome::Frame(frame, mapping));
        }
        if disconnected {
            Ok(MappedReceiveOutcome::Disconnected)
        } else {
            Ok(MappedReceiveOutcome::WouldBlock)
        }
    }

    /// Receive and structurally validate one seqpacket, transferring exactly
    /// one descriptor to the caller. All rejection paths close received FDs.
    #[allow(clippy::missing_errors_doc, clippy::missing_panics_doc)]
    fn recv_packet(&self) -> Result<PacketReceiveOutcome> {
        let mut header = [0_u8; HEADER_BYTES];
        let mut iov = libc::iovec {
            iov_base: header.as_mut_ptr().cast(),
            iov_len: header.len(),
        };
        // `usize` gives this buffer `cmsghdr` alignment.  It deliberately
        // holds many FDs so excess-descriptor packets are detected rather than
        // silently clipped.  Larger packets set MSG_CTRUNC and are rejected.
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
        // SAFETY: all `msghdr` buffers point to valid writable local storage
        // for the duration of this call; the socket remains owned by `self`.
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
                Ok(PacketReceiveOutcome::WouldBlock)
            } else {
                Err(error.into())
            };
        }
        let (received_fds, control_valid) = received_rights(&message)?;
        // `received_fds` stays in scope on all errors below, and therefore
        // closes every descriptor received from the untrusted peer.
        if message.msg_flags & (libc::MSG_TRUNC | libc::MSG_CTRUNC) != 0 {
            bail!("truncated HyprCapture seqpacket or ancillary data");
        }
        if received == 0 {
            if !control_valid || !received_fds.is_empty() {
                bail!("zero-byte HyprCapture packet carried ancillary data");
            }
            return Ok(PacketReceiveOutcome::Disconnected);
        }
        if !control_valid || received_fds.len() != 1 {
            bail!("HyprCapture packet must carry exactly one SCM_RIGHTS FD");
        }
        if usize::try_from(received).ok() != Some(HEADER_BYTES) {
            bail!("HyprCapture seqpacket has an invalid header length");
        }
        Ok(PacketReceiveOutcome::Packet(
            header,
            received_fds
                .into_iter()
                .next()
                .expect("checked exactly one FD"),
        ))
    }
}

enum PacketReceiveOutcome {
    Packet([u8; HEADER_BYTES], OwnedFd),
    WouldBlock,
    Disconnected,
}

/// Copy `SCM_RIGHTS` descriptors out of a kernel-written control buffer.
#[allow(unsafe_code)] // Narrow ancillary-data parsing; pointer bounds are checked below.
fn received_rights(message: &libc::msghdr) -> Result<(Vec<OwnedFd>, bool)> {
    let total = message.msg_controllen;
    let header_len = mem::size_of::<libc::cmsghdr>();
    let align = mem::size_of::<usize>();
    let align_up = |value: usize| value.checked_add(align - 1).map(|v| v & !(align - 1));
    let mut offset = 0_usize;
    let mut fds = Vec::new();
    let mut valid = true;
    while offset < total {
        if total - offset < header_len {
            bail!("malformed HyprCapture ancillary data");
        }
        // SAFETY: `offset + header_len <= total`, and the kernel initialized
        // that returned control range. `read_unaligned` avoids alignment
        // assumptions while copying the fixed cmsghdr value.
        let cmsg: libc::cmsghdr = unsafe {
            std::ptr::read_unaligned((message.msg_control.cast::<u8>().add(offset)).cast())
        };
        let cmsg_len = cmsg.cmsg_len as usize;
        if cmsg_len < header_len || cmsg_len > total - offset {
            bail!("malformed HyprCapture ancillary data");
        }
        let payload_len = cmsg_len - header_len;
        if cmsg.cmsg_level != libc::SOL_SOCKET || cmsg.cmsg_type != libc::SCM_RIGHTS {
            valid = false;
        } else if payload_len % mem::size_of::<libc::c_int>() != 0 {
            bail!("malformed SCM_RIGHTS payload");
        } else {
            for index in 0..(payload_len / mem::size_of::<libc::c_int>()) {
                // SAFETY: the descriptor slot falls inside this validated cmsg
                // payload. Kernel-provided SCM_RIGHTS integers are owned by us.
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
                    bail!("malformed SCM_RIGHTS descriptor");
                }
                // SAFETY: SCM_RIGHTS transferred ownership of this descriptor
                // to this process; it is dropped unless moved to the importer.
                fds.push(unsafe { OwnedFd::from_raw_fd(raw) });
            }
        }
        let Some(next) = align_up(cmsg_len) else {
            bail!("malformed HyprCapture ancillary data");
        };
        if next > total {
            if offset + cmsg_len == total {
                break;
            }
            bail!("malformed HyprCapture ancillary data");
        }
        offset += next;
    }
    Ok((fds, valid))
}

#[cfg(test)]
mod tests {
    #[test]
    fn listener_accepts_private_shared_memory_runtime_directory() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir_in("/dev/shm").unwrap();
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let _listener =
            super::HyprCaptureSocketListener::bind(&dir.path().join("frames.sock")).unwrap();
        assert!(
            super::HyprCaptureSocketListener::bind(std::path::Path::new("/dev/shm/frames.sock"))
                .is_err()
        );
    }
    use super::*;
    use std::{
        io::Write,
        os::fd::{AsRawFd, FromRawFd},
        os::unix::fs::PermissionsExt,
    };

    fn header() -> [u8; HEADER_BYTES] {
        let mut b = [0; HEADER_BYTES];
        b[..4].copy_from_slice(b"HCSF");
        b[4..6].copy_from_slice(&1_u16.to_be_bytes());
        b[6..8].copy_from_slice(&(HEADER_BYTES as u16).to_be_bytes());
        for (i, v) in [(8, 1_u64), (16, 2), (24, 3), (80, 4)] {
            b[i..i + 8].copy_from_slice(&v.to_be_bytes());
        }
        for (i, v) in [(32, 0_f64), (40, 0.0), (48, 1.0), (56, 1.0)] {
            b[i..i + 8].copy_from_slice(&v.to_be_bytes());
        }
        for (i, v) in [(64, 1_u32), (68, 1), (72, 4), (76, 1)] {
            b[i..i + 4].copy_from_slice(&v.to_be_bytes());
        }
        b
    }

    fn header_at(sequence: u64) -> [u8; HEADER_BYTES] {
        let mut bytes = header();
        bytes[8..16].copy_from_slice(&sequence.to_be_bytes());
        bytes[16..24].copy_from_slice(&(sequence + 1).to_be_bytes());
        bytes
    }

    #[allow(unsafe_code)] // Test socketpair/memfd construction.
    fn pair() -> (OwnedFd, OwnedFd) {
        let mut raw = [-1; 2];
        // SAFETY: output array has two descriptor slots.
        assert_eq!(
            unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0, raw.as_mut_ptr()) },
            0
        );
        // SAFETY: each newly-created socket descriptor has one unique owner.
        unsafe { (OwnedFd::from_raw_fd(raw[0]), OwnedFd::from_raw_fd(raw[1])) }
    }

    #[allow(unsafe_code)] // Test-only sealed memfd construction.
    fn sealed_memfd() -> OwnedFd {
        // SAFETY: static NUL-terminated name and supported Linux flags.
        let raw = unsafe {
            libc::memfd_create(
                c"viewflow-socket-test".as_ptr(),
                libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
            )
        };
        assert!(raw >= 0);
        // SAFETY: newly created descriptor is uniquely owned.
        let mut file = unsafe { std::fs::File::from_raw_fd(raw) };
        file.write_all(&[9; 4]).unwrap();
        let seals =
            libc::F_SEAL_WRITE | libc::F_SEAL_GROW | libc::F_SEAL_SHRINK | libc::F_SEAL_SEAL;
        // SAFETY: `file` owns this descriptor and only integer flags are read.
        assert_eq!(
            unsafe { libc::fcntl(file.as_raw_fd(), libc::F_ADD_SEALS, seals) },
            0
        );
        file.into()
    }

    #[allow(unsafe_code)] // Test-only inspection of a known local memfd inode.
    fn descriptor_alias_count(fd: &OwnedFd) -> usize {
        // SAFETY: `fd` is live and the stack storage is valid output space.
        let mut expected = unsafe { mem::zeroed::<libc::stat>() };
        assert_eq!(unsafe { libc::fstat(fd.as_raw_fd(), &raw mut expected) }, 0);
        std::fs::read_dir("/proc/self/fd")
            .unwrap()
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| entry.file_name().to_string_lossy().parse::<i32>().ok())
            .filter(|raw| {
                // SAFETY: fstat only reads the numeric descriptor and writes
                // into initialized stack storage. Races with unrelated test
                // threads merely make a closed descriptor fail this filter.
                let mut candidate = unsafe { mem::zeroed::<libc::stat>() };
                let status = unsafe { libc::fstat(*raw, &raw mut candidate) };
                status == 0
                    && candidate.st_dev == expected.st_dev
                    && candidate.st_ino == expected.st_ino
            })
            .count()
    }

    #[allow(unsafe_code)] // Test sender creates a conventional SCM_RIGHTS packet.
    fn send(sender: &OwnedFd, bytes: &[u8], fds: &[i32]) {
        let mut iov = libc::iovec {
            iov_base: bytes.as_ptr().cast_mut().cast(),
            iov_len: bytes.len(),
        };
        let control_len = if fds.is_empty() {
            0
        } else {
            unsafe { libc::CMSG_SPACE((std::mem::size_of_val(fds)) as _) as usize }
        };
        let words = control_len.div_ceil(mem::size_of::<usize>());
        let mut control = vec![0_usize; words];
        let msg = libc::msghdr {
            msg_name: std::ptr::null_mut(),
            msg_namelen: 0,
            msg_iov: &mut iov,
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
            // SAFETY: control is aligned writable space sized with CMSG_SPACE.
            let cmsg = unsafe { libc::CMSG_FIRSTHDR(&msg) };
            assert!(!cmsg.is_null());
            // SAFETY: first header and its data area fit in `control`.
            unsafe {
                (*cmsg).cmsg_level = libc::SOL_SOCKET;
                (*cmsg).cmsg_type = libc::SCM_RIGHTS;
                (*cmsg).cmsg_len = libc::CMSG_LEN(std::mem::size_of_val(fds) as _) as _;
                std::ptr::copy_nonoverlapping(
                    fds.as_ptr().cast::<u8>(),
                    libc::CMSG_DATA(cmsg),
                    std::mem::size_of_val(fds),
                );
            }
        }
        // SAFETY: message references valid input bytes and optional control.
        assert_eq!(
            unsafe { libc::sendmsg(sender.as_raw_fd(), &msg, 0) },
            bytes.len() as isize
        );
    }

    fn receiver(socket: OwnedFd) -> HyprCaptureSocketReceiver {
        // SAFETY: these test-only identity queries take no arguments.
        HyprCaptureSocketReceiver::new(
            socket,
            unsafe { libc::geteuid() },
            unsafe { libc::getpid() as u32 },
            4,
        )
        .unwrap()
    }

    #[allow(unsafe_code)] // Test-only AF_UNIX client construction.
    fn connect_listener(path: &Path) -> OwnedFd {
        let address = unix_address(path).unwrap();
        // SAFETY: AF_UNIX/SOCK_SEQPACKET needs no pointer arguments.
        let raw =
            unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0) };
        assert!(raw >= 0);
        // SAFETY: `address` is a valid pathname sockaddr_un and raw is live.
        assert_eq!(
            unsafe { libc::connect(raw, (&raw const address).cast(), address_len(path).unwrap()) },
            0
        );
        // SAFETY: successful socket call returned one owned descriptor.
        unsafe { OwnedFd::from_raw_fd(raw) }
    }

    #[test]
    fn imports_valid_sealed_memfd() {
        let (receiver_socket, sender) = pair();
        let fd = sealed_memfd();
        send(&sender, &header(), &[fd.as_raw_fd()]);
        let mut receiver = receiver(receiver_socket);
        assert_eq!(
            receiver.recv_frame().unwrap(),
            ReceiveOutcome::Frame(FrameHeader::decode(&header(), 4).unwrap(), vec![9; 4])
        );
    }

    #[test]
    fn latest_receive_imports_only_the_newest_queued_frame() {
        let (receiver_socket, sender) = pair();
        for sequence in 1..=3 {
            let fd = sealed_memfd();
            send(&sender, &header_at(sequence), &[fd.as_raw_fd()]);
        }
        let mut receiver = receiver(receiver_socket);
        assert!(matches!(
            receiver.recv_latest_frame().unwrap(),
            ReceiveOutcome::Frame(FrameHeader { sequence: 3, .. }, pixels) if pixels == vec![9; 4]
        ));
    }

    #[test]
    fn latest_mapped_receive_imports_only_the_newest_validated_frame() {
        let (receiver_socket, sender) = pair();
        for sequence in 1..=3 {
            let fd = sealed_memfd();
            send(&sender, &header_at(sequence), &[fd.as_raw_fd()]);
        }
        let mut receiver = receiver(receiver_socket);
        assert!(matches!(
            receiver.recv_latest_mapped_frame().unwrap(),
            MappedReceiveOutcome::Frame(FrameHeader { sequence: 3, .. }, pixels)
                if pixels.as_ref() == [9; 4]
        ));
    }

    #[test]
    fn latest_mapped_receive_rejects_invalid_intermediate_packet() {
        let (receiver_socket, sender) = pair();
        let first = sealed_memfd();
        send(&sender, &header_at(1), &[first.as_raw_fd()]);
        let invalid = sealed_memfd();
        let mut malformed = header_at(2);
        malformed[8..16].copy_from_slice(&0_u64.to_be_bytes());
        send(&sender, &malformed, &[invalid.as_raw_fd()]);
        let mut receiver = receiver(receiver_socket);
        assert!(receiver.recv_latest_mapped_frame().is_err());
        assert_eq!(descriptor_alias_count(&invalid), 1);
    }

    #[test]
    fn latest_receive_bounds_each_queue_drain() {
        let (receiver_socket, sender) = pair();
        for sequence in 1..=u64::try_from(MAX_LATEST_DRAIN_PACKETS + 2).unwrap() {
            let fd = sealed_memfd();
            send(&sender, &header_at(sequence), &[fd.as_raw_fd()]);
        }
        let mut receiver = receiver(receiver_socket);
        assert!(matches!(
            receiver.recv_latest_frame().unwrap(),
            ReceiveOutcome::Frame(FrameHeader { sequence, .. }, _) if sequence == MAX_LATEST_DRAIN_PACKETS as u64
        ));
        assert!(matches!(
            receiver.recv_latest_frame().unwrap(),
            ReceiveOutcome::Frame(FrameHeader { sequence, .. }, _) if sequence == (MAX_LATEST_DRAIN_PACKETS + 2) as u64
        ));
    }

    #[test]
    fn latest_receive_rejects_invalid_intermediate_and_closes_its_fd() {
        let (receiver_socket, sender) = pair();
        let mut receiver = receiver(receiver_socket);
        let first = sealed_memfd();
        send(&sender, &header_at(1), &[first.as_raw_fd()]);
        for _ in 0..32 {
            let invalid = sealed_memfd();
            let mut malformed = header_at(2);
            malformed[8..16].copy_from_slice(&0_u64.to_be_bytes());
            send(&sender, &malformed, &[invalid.as_raw_fd()]);
            assert!(receiver.recv_latest_frame().is_err());
            assert_eq!(descriptor_alias_count(&invalid), 1);
        }
        let final_fd = sealed_memfd();
        send(&sender, &header_at(3), &[final_fd.as_raw_fd()]);
        assert!(matches!(
            receiver.recv_latest_frame().unwrap(),
            ReceiveOutcome::Frame(FrameHeader { sequence: 3, .. }, _)
        ));
    }

    #[test]
    fn latest_receive_records_skipped_sequences_against_replay() {
        let (receiver_socket, sender) = pair();
        for sequence in 1..=2 {
            let fd = sealed_memfd();
            send(&sender, &header_at(sequence), &[fd.as_raw_fd()]);
        }
        let mut receiver = receiver(receiver_socket);
        assert!(matches!(
            receiver.recv_latest_frame().unwrap(),
            ReceiveOutcome::Frame(..)
        ));
        let replay = sealed_memfd();
        send(&sender, &header_at(1), &[replay.as_raw_fd()]);
        assert!(receiver.recv_latest_frame().is_err());
    }

    #[test]
    fn rejects_wrong_peer() {
        let (socket, _sender) = pair();
        // SAFETY: test-only identity query takes no arguments.
        assert!(HyprCaptureSocketReceiver::new(socket, unsafe { libc::geteuid() }, 1, 4).is_err());
    }

    #[test]
    fn rejects_missing_and_extra_descriptors() {
        let (receiver_socket, sender) = pair();
        send(&sender, &header(), &[]);
        assert!(receiver(receiver_socket).recv_frame().is_err());
        let (receiver_socket, sender) = pair();
        let fd = sealed_memfd();
        send(&sender, &header(), &[fd.as_raw_fd(), fd.as_raw_fd()]);
        assert!(receiver(receiver_socket).recv_frame().is_err());
    }

    #[test]
    fn rejects_truncated_payload_and_control() {
        let (receiver_socket, sender) = pair();
        let mut oversized = header().to_vec();
        oversized.push(0);
        send(&sender, &oversized, &[]);
        assert!(receiver(receiver_socket).recv_frame().is_err());
        let (receiver_socket, sender) = pair();
        let fd = sealed_memfd();
        let many = vec![fd.as_raw_fd(); 128];
        send(&sender, &header(), &many);
        assert!(receiver(receiver_socket).recv_frame().is_err());
    }

    #[test]
    fn distinguishes_would_block_and_disconnect() {
        let (receiver_socket, sender) = pair();
        let mut receiver = receiver(receiver_socket);
        assert_eq!(receiver.recv_frame().unwrap(), ReceiveOutcome::WouldBlock);
        drop(sender);
        assert_eq!(receiver.recv_frame().unwrap(), ReceiveOutcome::Disconnected);
    }

    #[test]
    fn rejects_zero_byte_packet_with_descriptor() {
        let (receiver_socket, sender) = pair();
        let fd = sealed_memfd();
        send(&sender, &[], &[fd.as_raw_fd()]);
        assert!(receiver(receiver_socket).recv_frame().is_err());
    }

    #[test]
    fn rejects_replayed_time_reversed_and_unversioned_geometry_changes() {
        let (receiver_socket, sender) = pair();
        let mut receiver = receiver(receiver_socket);
        let fd = sealed_memfd();
        send(&sender, &header(), &[fd.as_raw_fd()]);
        assert!(matches!(
            receiver.recv_frame().unwrap(),
            ReceiveOutcome::Frame(..)
        ));

        let fd = sealed_memfd();
        send(&sender, &header(), &[fd.as_raw_fd()]);
        assert!(receiver.recv_frame().is_err());

        let mut time_reversed = header();
        time_reversed[8..16].copy_from_slice(&2_u64.to_be_bytes());
        time_reversed[16..24].copy_from_slice(&1_u64.to_be_bytes());
        let fd = sealed_memfd();
        send(&sender, &time_reversed, &[fd.as_raw_fd()]);
        assert!(receiver.recv_frame().is_err());

        let mut geometry_changed = header();
        geometry_changed[8..16].copy_from_slice(&2_u64.to_be_bytes());
        geometry_changed[32..40].copy_from_slice(&1_f64.to_be_bytes());
        let fd = sealed_memfd();
        send(&sender, &geometry_changed, &[fd.as_raw_fd()]);
        assert!(receiver.recv_frame().is_err());
    }

    #[test]
    fn listener_refuses_existing_path_and_unsafe_parent() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let existing = directory.path().join("existing.sock");
        std::fs::File::create(&existing).unwrap();
        assert!(HyprCaptureSocketListener::bind(&existing).is_err());

        let unsafe_directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(
            unsafe_directory.path(),
            std::fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        assert!(
            HyprCaptureSocketListener::bind(&unsafe_directory.path().join("capture.sock")).is_err()
        );
    }

    #[test]
    fn listener_accepts_authenticated_seqpacket_peer() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("capture.sock");
        let listener = HyprCaptureSocketListener::bind(&path).unwrap();
        assert_eq!(
            std::fs::symlink_metadata(&path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600,
        );
        assert!(matches!(
            listener
                .accept(current_euid(), std::process::id(), 4)
                .unwrap(),
            AcceptOutcome::WouldBlock
        ));
        let _client = connect_listener(&path);
        assert!(matches!(
            listener
                .accept(current_euid(), std::process::id(), 4)
                .unwrap(),
            AcceptOutcome::Receiver(_)
        ));
    }
}
