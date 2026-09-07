//! Kernel-authenticated identity for local control sockets.

use std::{io, os::unix::net::UnixStream};

#[cfg(any(target_os = "linux", target_os = "macos"))]
use std::os::fd::AsRawFd;

#[derive(Clone, Copy, Debug)]
pub(crate) struct PeerIdentity {
    pub uid: u32,
    pub pid: i32,
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)]
pub(crate) fn identity(stream: &UnixStream) -> io::Result<PeerIdentity> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the live socket and writable, exactly sized outputs remain valid
    // for this synchronous call.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut credentials).cast(),
            &raw mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != size_of::<libc::ucred>() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid peer credential size",
        ));
    }
    Ok(PeerIdentity {
        uid: credentials.uid,
        pid: credentials.pid,
    })
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
pub(crate) fn identity(stream: &UnixStream) -> io::Result<PeerIdentity> {
    let (mut uid, mut gid, mut pid) = (0, 0, 0 as libc::pid_t);
    let mut length = size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: both calls use this live socket and initialized outputs of the
    // exact types required by the Darwin socket API.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEEREPID,
            (&raw mut pid).cast(),
            &raw mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != size_of::<libc::pid_t>() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid peer PID size",
        ));
    }
    // SAFETY: uid and gid are writable uid_t/gid_t outputs for a live socket.
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &raw mut uid, &raw mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(PeerIdentity { uid, pid })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(crate) fn identity(_stream: &UnixStream) -> io::Result<PeerIdentity> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "local peer identity unavailable",
    ))
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests {
    use super::*;

    #[test]
    #[allow(unsafe_code)]
    fn connected_socket_identity_comes_from_kernel() {
        let (left, right) = UnixStream::pair().unwrap();
        for stream in [&left, &right] {
            let peer = identity(stream).unwrap();
            assert_eq!(u32::try_from(peer.pid).unwrap(), std::process::id());
            // SAFETY: geteuid takes no arguments and has no memory side effects.
            assert_eq!(peer.uid, unsafe { libc::geteuid() });
        }
    }
}
