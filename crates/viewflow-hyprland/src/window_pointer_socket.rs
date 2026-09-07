//! Nonblocking, same-user native plugin transport. This is not a remote grant.
//! The caller owns socket-path cleanup and must retain metadata events.

use crate::capture_wire::{CaptureCommand, CaptureReceipt};
use crate::window_pointer_wire::{Outcome, Request};
use nix::sys::socket::{
    self, AddressFamily, Backlog, MsgFlags, SockFlag, SockType, UnixAddr, sockopt,
};
use std::{
    io,
    os::{
        fd::{AsRawFd, OwnedFd},
        unix::fs::MetadataExt,
    },
    path::Path,
};

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

pub struct Listener {
    fd: OwnedFd,
    expected_pid: i32,
}

impl Listener {
    /// Bind a new path inside a pre-existing private, owned directory. Never unlinks.
    /// # Errors
    /// Rejects insecure parent directories, invalid PID, or socket errors.
    pub fn bind(path: &Path, expected_pid: i32) -> io::Result<Self> {
        let parent =
            std::fs::symlink_metadata(path.parent().ok_or_else(|| invalid("missing parent"))?)?;
        if expected_pid <= 0
            || !parent.is_dir()
            || parent.uid() != nix::unistd::geteuid().as_raw()
            || parent.mode() & 0o077 != 0
        {
            return Err(invalid(
                "requires private owned directory and exact compositor PID",
            ));
        }
        let fd = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK | SockFlag::SOCK_CLOEXEC,
            None,
        )?;
        socket::bind(fd.as_raw_fd(), &UnixAddr::new(path)?)?;
        socket::listen(&fd, Backlog::new(1)?)?;
        Ok(Self { fd, expected_pid })
    }

    /// # Errors
    /// Returns `WouldBlock` when idle; rejects a different UID or compositor PID.
    pub fn accept(&self) -> io::Result<Connection> {
        use std::os::fd::FromRawFd;
        let raw = socket::accept4(
            self.fd.as_raw_fd(),
            SockFlag::SOCK_NONBLOCK | SockFlag::SOCK_CLOEXEC,
        )?;
        // SAFETY: accept4 returned a fresh descriptor; ownership is transferred once.
        #[allow(unsafe_code)]
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let peer = socket::getsockopt(&fd, sockopt::PeerCredentials)?;
        if peer.uid() != nix::unistd::geteuid().as_raw() || peer.pid() != self.expected_pid {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "unexpected native peer",
            ));
        }
        Ok(Connection {
            fd,
            incoming: 0,
            outgoing: 0,
            pending: None,
            capture_pending: None,
            failed: false,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (Connection, OwnedFd) {
        let (fd, peer) = socket::socketpair(
            AddressFamily::Unix,
            SockType::SeqPacket,
            None,
            SockFlag::SOCK_NONBLOCK | SockFlag::SOCK_CLOEXEC,
        )
        .unwrap();
        (
            Connection {
                fd,
                incoming: 0,
                outgoing: 0,
                pending: None,
                capture_pending: None,
                failed: false,
            },
            peer,
        )
    }

    fn packet(tag: u16, seq: u64, payload: &[u8]) -> Vec<u8> {
        let mut bytes = b"VFHY\x01\x00".to_vec();
        bytes.extend(tag.to_le_bytes());
        bytes.extend(u32::try_from(payload.len()).unwrap().to_le_bytes());
        bytes.extend(seq.to_le_bytes());
        bytes.extend(payload);
        bytes
    }

    #[test]
    fn real_seqpacket_retains_metadata_and_correlates_ack() {
        let (mut connection, peer) = pair();
        assert_eq!(
            connection.receive().err().unwrap().kind(),
            io::ErrorKind::WouldBlock
        );
        connection.send(Request::end(7, 3).unwrap()).unwrap();
        let mut received = [0; 128];
        let count = socket::recv(peer.as_raw_fd(), &mut received, MsgFlags::MSG_DONTWAIT).unwrap();
        assert_eq!(&received[..count], Request::end(7, 3).unwrap().packet());
        let metadata = packet(1, 1, &[42]);
        socket::send(peer.as_raw_fd(), &metadata, MsgFlags::MSG_NOSIGNAL).unwrap();
        assert!(
            matches!(connection.receive().unwrap(), Event::Metadata(bytes) if bytes == metadata)
        );
        let mut result = Vec::new();
        result.extend(3_u64.to_le_bytes());
        result.extend(7_u64.to_le_bytes());
        result.extend(3_u32.to_le_bytes());
        result.extend(0_u32.to_le_bytes());
        socket::send(
            peer.as_raw_fd(),
            &packet(53, 2, &result),
            MsgFlags::MSG_NOSIGNAL,
        )
        .unwrap();
        assert!(matches!(
            connection.receive().unwrap(),
            Event::Completed(Outcome::Ended)
        ));
        assert!(connection.send(Request::end(7, 3).unwrap()).is_err());
        connection.send(Request::end(8, 3).unwrap()).unwrap();
    }

    #[test]
    fn capture_and_window_commands_share_one_sequence_and_pending_lane() {
        let (mut connection, peer) = pair();
        let command = CaptureCommand::Activate {
            generation: 9,
            target: [1; 16],
            loopback: true,
        };
        connection.send_capture(command).unwrap();
        assert!(connection.send(Request::end(2, 3).unwrap()).is_err());
        assert!(connection.send_capture(command).is_err());
        let mut received = [0; 128];
        let count = socket::recv(peer.as_raw_fd(), &mut received, MsgFlags::MSG_DONTWAIT).unwrap();
        assert_eq!(&received[..count], command.packet(1).unwrap());
        let mut reply = 9_u64.to_le_bytes().to_vec();
        reply.extend(40_u16.to_le_bytes());
        reply.push(1);
        socket::send(
            peer.as_raw_fd(),
            &packet(43, 1, &reply),
            MsgFlags::MSG_NOSIGNAL,
        )
        .unwrap();
        assert!(matches!(
            connection.receive().unwrap(),
            Event::CaptureReceipt(CaptureReceipt {
                generation: 9,
                command: 40,
                applied: true
            })
        ));
        assert_eq!(connection.next_sequence(), 2);
        connection.send(Request::end(2, 3).unwrap()).unwrap();
    }

    #[test]
    fn unmatched_capture_receipt_closes_connection() {
        for wrong in [0, 1, 2] {
            let (mut connection, peer) = pair();
            connection
                .send_capture(CaptureCommand::Release {
                    generation: 9,
                    return_position: None,
                })
                .unwrap();
            let mut reply = if wrong == 0 { 8_u64 } else { 9_u64 }
                .to_le_bytes()
                .to_vec();
            reply.extend(if wrong == 1 { 40_u16 } else { 41_u16 }.to_le_bytes());
            reply.push(if wrong == 2 { 2 } else { 1 });
            socket::send(
                peer.as_raw_fd(),
                &packet(43, 1, &reply),
                MsgFlags::MSG_NOSIGNAL,
            )
            .unwrap();
            assert!(connection.receive().is_err());
            assert!(connection.failed);
        }
    }

    #[test]
    fn replay_and_oversize_close_connection() {
        for oversized in [false, true] {
            let (mut connection, peer) = pair();
            let first = packet(1, 1, &[]);
            socket::send(peer.as_raw_fd(), &first, MsgFlags::MSG_NOSIGNAL).unwrap();
            connection.receive().unwrap();
            let bad = if oversized {
                packet(1, 2, &vec![0; 16384])
            } else {
                first
            };
            socket::send(peer.as_raw_fd(), &bad, MsgFlags::MSG_NOSIGNAL).unwrap();
            assert!(connection.receive().is_err());
            assert!(connection.failed);
            assert!(connection.send(Request::end(1, 1).unwrap()).is_err());
        }
    }

    #[test]
    fn revocation_is_typed_without_a_pending_command_and_rejects_malformed_payloads() {
        let payload = || {
            let mut bytes = 9_u64.to_le_bytes().to_vec();
            bytes.extend(7_u32.to_le_bytes());
            bytes.extend(0_u32.to_le_bytes());
            bytes
        };
        let (mut connection, peer) = pair();
        socket::send(
            peer.as_raw_fd(),
            &packet(54, 1, &payload()),
            MsgFlags::MSG_NOSIGNAL,
        )
        .unwrap();
        assert!(matches!(
            connection.receive().unwrap(),
            Event::Revoked {
                generation: 9,
                reason: RevocationReason::LocalMotion
            }
        ));
        for bad in [
            vec![0; 16],
            {
                let mut b = payload();
                b[8..12].copy_from_slice(&16_u32.to_le_bytes());
                b
            },
            {
                let mut b = payload();
                b[12] = 1;
                b
            },
            {
                let mut b = payload();
                b.pop();
                b
            },
        ] {
            let (mut connection, peer) = pair();
            socket::send(
                peer.as_raw_fd(),
                &packet(54, 1, &bad),
                MsgFlags::MSG_NOSIGNAL,
            )
            .unwrap();
            assert!(connection.receive().is_err());
            assert!(connection.failed);
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RevocationReason {
    Cancelled,
    WindowUnmapped,
    SurfaceUnmapped,
    SurfaceDestroyed,
    Resized,
    SessionLocked,
    LocalMotion,
    LocalButton,
    LocalAxis,
    LocalKey,
    TargetInvalid,
    SeatUnavailable,
    Expired,
    FocusChanged,
    RouteUnavailable,
}

impl TryFrom<u32> for RevocationReason {
    type Error = io::Error;
    fn try_from(value: u32) -> io::Result<Self> {
        Ok(match value {
            1 => Self::Cancelled,
            2 => Self::WindowUnmapped,
            3 => Self::SurfaceUnmapped,
            4 => Self::SurfaceDestroyed,
            5 => Self::Resized,
            6 => Self::SessionLocked,
            7 => Self::LocalMotion,
            8 => Self::LocalButton,
            9 => Self::LocalAxis,
            10 => Self::LocalKey,
            11 => Self::TargetInvalid,
            12 => Self::SeatUnavailable,
            13 => Self::Expired,
            14 => Self::FocusChanged,
            15 => Self::RouteUnavailable,
            _ => return Err(invalid("unknown native revocation reason")),
        })
    }
}

pub enum Event {
    /// Includes the complete VFHY envelope, for the existing metadata dispatcher.
    Metadata(Vec<u8>),
    Completed(Outcome),
    CaptureReceipt(CaptureReceipt),
    /// Terminal notification, independent of a pending command. The session
    /// owner must revoke immediately rather than wait for another motion/renewal.
    Revoked {
        generation: u64,
        reason: RevocationReason,
    },
}

pub struct Connection {
    fd: OwnedFd,
    incoming: u64,
    outgoing: u64,
    pending: Option<Request>,
    capture_pending: Option<CaptureCommand>,
    failed: bool,
}

impl Connection {
    /// Close immediately so the compositor revokes any connection-owned session.
    pub fn close(&mut self) {
        self.fail();
    }

    fn fail(&mut self) {
        self.failed = true;
        self.pending = None;
        self.capture_pending = None;
        let _ = socket::shutdown(self.fd.as_raw_fd(), socket::Shutdown::Both);
    }

    /// The sequence to use for the next window or capture command.
    #[must_use]
    pub fn next_sequence(&self) -> u64 {
        self.outgoing.saturating_add(1)
    }

    /// Send through the same serialized native lane as window input.
    /// # Errors
    /// Rejects invalid commands, concurrent requests, and disconnected sockets.
    pub fn send_capture(&mut self, command: CaptureCommand) -> io::Result<()> {
        if self.failed || self.pending.is_some() || self.capture_pending.is_some() {
            return Err(invalid("connection unavailable"));
        }
        let sequence = self
            .outgoing
            .checked_add(1)
            .ok_or_else(|| invalid("sequence exhausted"))?;
        let bytes = command.packet(sequence)?;
        match socket::send(
            self.fd.as_raw_fd(),
            &bytes,
            MsgFlags::MSG_DONTWAIT | MsgFlags::MSG_NOSIGNAL,
        ) {
            Ok(count) if count == bytes.len() => {
                self.outgoing = sequence;
                self.capture_pending = Some(command);
                Ok(())
            }
            result => {
                self.fail();
                Err(result
                    .err()
                    .map_or_else(|| invalid("short packet send"), io::Error::from))
            }
        }
    }

    /// One outstanding command per connection. A failed send poisons the connection.
    /// # Errors
    /// Rejects replay, concurrent requests, broken connections and socket errors.
    pub fn send(&mut self, request: Request) -> io::Result<()> {
        if self.failed || self.pending.is_some() || self.capture_pending.is_some() {
            return Err(invalid("connection unavailable"));
        }
        let bytes = request.packet();
        let sequence = u64::from_le_bytes(bytes[12..20].try_into().map_err(|_| invalid("header"))?);
        if sequence <= self.outgoing {
            return Err(invalid("outgoing replay"));
        }
        match socket::send(
            self.fd.as_raw_fd(),
            bytes,
            MsgFlags::MSG_DONTWAIT | MsgFlags::MSG_NOSIGNAL,
        ) {
            Ok(count) if count == bytes.len() => {
                self.outgoing = sequence;
                self.pending = Some(request);
                Ok(())
            }
            result => {
                self.fail();
                Err(result
                    .err()
                    .map_or_else(|| invalid("short packet send"), io::Error::from))
            }
        }
    }

    /// # Errors
    /// `WouldBlock` leaves state unchanged. Malformed/replayed/unmatched packets close it.
    pub fn receive(&mut self) -> io::Result<Event> {
        if self.failed {
            return Err(invalid("connection closed"));
        }
        let result = self.receive_inner();
        if result
            .as_ref()
            .is_err_and(|e| e.kind() != io::ErrorKind::WouldBlock)
        {
            self.fail();
        }
        result
    }

    fn receive_inner(&mut self) -> io::Result<Event> {
        let mut bytes = vec![0; 16 * 1024];
        let count = socket::recv(
            self.fd.as_raw_fd(),
            &mut bytes,
            MsgFlags::MSG_DONTWAIT | MsgFlags::MSG_TRUNC,
        )?;
        if count < 20 || count > bytes.len() {
            return Err(invalid("truncated native packet"));
        }
        bytes.truncate(count);
        let length =
            u32::from_le_bytes(bytes[8..12].try_into().map_err(|_| invalid("length"))?) as usize;
        let sequence =
            u64::from_le_bytes(bytes[12..20].try_into().map_err(|_| invalid("sequence"))?);
        if &bytes[..6] != b"VFHY\x01\x00" || length != count - 20 || sequence <= self.incoming {
            return Err(invalid("invalid native envelope"));
        }
        self.incoming = sequence;
        if u16::from_le_bytes([bytes[6], bytes[7]]) == 53 {
            let request = self
                .pending
                .take()
                .ok_or_else(|| invalid("unsolicited result"))?;
            let (_, outcome) = request
                .complete(&bytes)
                .map_err(|_| invalid("invalid command result"))?;
            Ok(Event::Completed(outcome))
        } else if u16::from_le_bytes([bytes[6], bytes[7]]) == 43 {
            let command = self
                .capture_pending
                .take()
                .ok_or_else(|| invalid("unsolicited capture receipt"))?;
            Ok(Event::CaptureReceipt(command.receipt(&bytes)?))
        } else if u16::from_le_bytes([bytes[6], bytes[7]]) == 54 {
            if count != 36 || bytes[32..36] != [0; 4] {
                return Err(invalid("invalid native revocation layout"));
            }
            let generation = u64::from_le_bytes(
                bytes[20..28]
                    .try_into()
                    .map_err(|_| invalid("generation"))?,
            );
            if generation == 0 {
                return Err(invalid("zero revoked generation"));
            }
            let reason = RevocationReason::try_from(u32::from_le_bytes(
                bytes[28..32].try_into().map_err(|_| invalid("reason"))?,
            ))?;
            Ok(Event::Revoked { generation, reason })
        } else {
            Ok(Event::Metadata(bytes))
        }
    }
}
