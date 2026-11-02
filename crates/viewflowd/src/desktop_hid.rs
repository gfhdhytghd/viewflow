//! Nonblocking VFTP ABI 2 transport. Only the optional HID path is retired on failure.
//! The existing cursor feedback cadence drains backpressure and retries discovery.
use crate::sync_ext::LockExt;
use socket2::{Domain, SockAddr, Socket, Type};
use std::{
    collections::VecDeque,
    io::{self, Read, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use viewflow_protocol::NativeTouchpadReport;

pub(crate) type Shared = Arc<Mutex<DesktopHid>>;
#[derive(Debug)]
pub(crate) struct DesktopHid {
    path: Option<PathBuf>,
    socket: Option<std::os::unix::net::UnixStream>,
    pending: VecDeque<u8>,
    retry: Instant,
}
impl DesktopHid {
    pub fn new(enabled: bool) -> Self {
        Self::at(if enabled {
            std::env::var_os("HOME").map(|home| {
                PathBuf::from(home).join("Library/Application Support/Viewflow/run/hid.sock")
            })
        } else {
            None
        })
    }
    pub(crate) fn at(path: Option<PathBuf>) -> Self {
        Self {
            path,
            socket: None,
            pending: VecDeque::new(),
            retry: Instant::now(),
        }
    }
    fn close(&mut self) {
        if let Some(socket) = self.socket.take() {
            let _ = socket.shutdown(std::net::Shutdown::Both);
        }
        self.pending.clear();
    }
    fn failed(&mut self) {
        self.close();
        self.retry = Instant::now() + Duration::from_secs(1);
    }
    fn connect(&mut self) -> io::Result<()> {
        let path = self
            .path
            .as_ref()
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
        let socket = Socket::new(Domain::UNIX, Type::STREAM, None)?;
        socket.set_nonblocking(true)?;
        socket.connect(&SockAddr::unix(path)?)?;
        self.socket = Some(socket.into());
        self.pending.extend(b"VFTP\x02\0\0\0");
        Ok(())
    }
    fn drain(&mut self) -> io::Result<()> {
        let Some(socket) = self.socket.as_mut() else {
            return Ok(());
        };
        let mut response = [0; 4];
        match socket.read(&mut response) {
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::Interrupted =>
            {
                ()
            }
            Err(e) => return Err(e),
            Ok(_) => return Err(io::ErrorKind::BrokenPipe.into()), // exit status or EOF
        }
        while !self.pending.is_empty() {
            let (first, _) = self.pending.as_slices();
            match socket.write(first) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => {
                    self.pending.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
    pub fn available(&mut self) -> bool {
        if self.path.is_none() {
            return false;
        }
        if self.socket.is_none() && Instant::now() >= self.retry && self.connect().is_err() {
            self.failed();
        }
        if self.drain().is_err() {
            self.failed();
        }
        self.socket.is_some()
    }
    pub fn report(&mut self, report: NativeTouchpadReport) {
        if self.socket.is_none() {
            return;
        }
        if self.pending.len() + 72 > 72 * 256 {
            self.failed();
            return;
        }
        self.pending.extend(report.0);
        if self.drain().is_err() {
            self.failed();
        }
    }
    pub fn release(&mut self) {
        self.close();
    } // EOF releases contacts in the native host.
}
impl Drop for DesktopHid {
    fn drop(&mut self) {
        self.close();
    }
}

pub(crate) fn available(hid: &Shared) -> bool {
    hid.lock_or_recover().available()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disabled_and_missing_socket_do_not_advertise() {
        assert!(!DesktopHid::new(false).available());
        let root = tempfile::tempdir().unwrap();
        assert!(!DesktopHid::at(Some(root.path().join("absent"))).available());
    }
    #[test]
    fn header_report_order_release_and_receiver_failure() {
        use std::os::unix::net::UnixListener;
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("hid.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let mut hid = DesktopHid::at(Some(path));
        assert!(hid.available());
        let (mut peer, _) = listener.accept().unwrap();
        let mut report = [0u8; 72];
        report[0] = 1;
        report[13] = 1;
        hid.report(NativeTouchpadReport(report));
        let mut bytes = [0u8; 80];
        peer.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes[..8], b"VFTP\x02\0\0\0");
        assert_eq!(&bytes[8..], &report);
        hid.release();
        assert_eq!(peer.read(&mut [0; 1]).unwrap(), 0);
        assert!(hid.available());
        let (peer, _) = listener.accept().unwrap();
        drop(peer);
        assert!(!hid.available());
    }
}
