#[cfg(unix)]
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(unix)]
const SOCKET_NAME: &str = ".socket.sock";

#[derive(Debug)]
pub enum HyprIpcError {
    MissingEnvironment(&'static str),
    UnsupportedPlatform,
    InvalidCommand,
    Io(std::io::Error),
    InvalidUtf8(std::string::FromUtf8Error),
}

impl std::fmt::Display for HyprIpcError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingEnvironment(name) => {
                write!(formatter, "required environment variable {name} is missing")
            }
            Self::UnsupportedPlatform => {
                formatter.write_str("Hyprland IPC requires a Unix platform")
            }
            Self::InvalidCommand => formatter.write_str("IPC command is empty or contains NUL"),
            Self::Io(error) => error.fmt(formatter),
            Self::InvalidUtf8(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for HyprIpcError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::InvalidUtf8(error) => Some(error),
            _ => None,
        }
    }
}

impl From<std::io::Error> for HyprIpcError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<std::string::FromUtf8Error> for HyprIpcError {
    fn from(value: std::string::FromUtf8Error) -> Self {
        Self::InvalidUtf8(value)
    }
}

#[derive(Clone, Debug)]
pub struct HyprIpcClient {
    socket_path: PathBuf,
    timeout: Duration,
}

impl HyprIpcClient {
    #[must_use]
    pub fn new(socket_path: PathBuf) -> Self {
        Self {
            socket_path,
            timeout: Duration::from_secs(5),
        }
    }

    #[must_use]
    pub const fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    #[must_use]
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Sends one request and reads the complete response after Hyprland closes the socket.
    ///
    /// # Errors
    ///
    /// Returns an error when the command is invalid, the socket cannot be used,
    /// a timeout expires, or Hyprland returns non-UTF-8 bytes.
    pub fn request(&self, command: &str) -> Result<String, HyprIpcError> {
        if command.is_empty() || command.as_bytes().contains(&0) {
            return Err(HyprIpcError::InvalidCommand);
        }

        #[cfg(not(unix))]
        return Err(HyprIpcError::UnsupportedPlatform);

        #[cfg(unix)]
        {
            let mut stream = UnixStream::connect(&self.socket_path)?;
            stream.set_read_timeout(Some(self.timeout))?;
            stream.set_write_timeout(Some(self.timeout))?;
            stream.write_all(command.as_bytes())?;

            let mut reply = Vec::new();
            stream.read_to_end(&mut reply)?;
            Ok(String::from_utf8(reply)?)
        }
    }
}

/// Resolves the command socket for the current Hyprland session.
///
/// # Errors
///
/// Returns an error when `XDG_RUNTIME_DIR` or
/// `HYPRLAND_INSTANCE_SIGNATURE` is not present.
pub fn resolve_socket_path() -> Result<PathBuf, HyprIpcError> {
    #[cfg(not(unix))]
    return Err(HyprIpcError::UnsupportedPlatform);

    #[cfg(unix)]
    {
        let runtime_dir = std::env::var_os("XDG_RUNTIME_DIR")
            .ok_or(HyprIpcError::MissingEnvironment("XDG_RUNTIME_DIR"))?;
        let instance = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").ok_or(
            HyprIpcError::MissingEnvironment("HYPRLAND_INSTANCE_SIGNATURE"),
        )?;
        Ok(PathBuf::from(runtime_dir)
            .join("hypr")
            .join(instance)
            .join(SOCKET_NAME))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::net::UnixListener;
    #[cfg(unix)]
    use std::sync::mpsc;
    #[cfg(unix)]
    use std::thread;

    #[cfg(unix)]
    #[test]
    fn request_writes_exact_bytes_and_reads_until_close() {
        let path =
            std::env::temp_dir().join(format!("viewflow-hyprland-ipc-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 64];
            let size = stream.read(&mut request).unwrap();
            sender.send(request[..size].to_vec()).unwrap();
            stream.write_all(b"[{\"id\":1}]").unwrap();
        });

        let reply = HyprIpcClient::new(path.clone())
            .request("j/monitors")
            .unwrap();
        assert_eq!(receiver.recv().unwrap(), b"j/monitors");
        assert_eq!(reply, "[{\"id\":1}]");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn nul_commands_are_rejected_before_connecting() {
        let client = HyprIpcClient::new(PathBuf::from("/not/used"));
        assert!(matches!(
            client.request("j/clients\0/output create headless injected"),
            Err(HyprIpcError::InvalidCommand)
        ));
    }

    #[cfg(not(unix))]
    #[test]
    fn valid_commands_are_explicitly_unsupported() {
        let client = HyprIpcClient::new(PathBuf::from("unused"));
        assert!(matches!(
            client.request("j/clients"),
            Err(HyprIpcError::UnsupportedPlatform)
        ));
        assert!(matches!(
            resolve_socket_path(),
            Err(HyprIpcError::UnsupportedPlatform)
        ));
    }
}
