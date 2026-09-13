//! Checked private-file adapter for the Hyprland desktop-window Lua controller.
//!
//! This is intentionally a local compositor operation, not a network grant.
//! It verifies the compositor command endpoint immediately before invoking the
//! plugin and keeps the plugin request/reply file private to the current UID.

use crate::{HyprIpcClient, HyprIpcError};
use serde::{Deserialize, Serialize};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

#[cfg(target_os = "linux")]
use {
    nix::{
        libc,
        sys::socket::{self, sockopt},
    },
    std::{
        os::unix::{
            fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
            net::UnixStream,
        },
        time::Duration,
    },
};

const VERSION: u8 = 1;
const MAX_REQUEST_BYTES: usize = 4096;

#[derive(Debug)]
pub enum DesktopWindowError {
    Ipc(HyprIpcError),
    Io(std::io::Error),
    Json(serde_json::Error),
    Invalid(&'static str),
    EndpointIdentity,
    LuaRejected(String),
    Rejected(String),
}

impl std::fmt::Display for DesktopWindowError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ipc(error) => error.fmt(formatter),
            Self::Io(error) => error.fmt(formatter),
            Self::Json(error) => error.fmt(formatter),
            Self::Invalid(message) => formatter.write_str(message),
            Self::EndpointIdentity => formatter.write_str("Hyprland endpoint PID/UID mismatch"),
            Self::LuaRejected(reply) => write!(formatter, "Hyprland Lua request rejected: {reply}"),
            Self::Rejected(message) => {
                write!(formatter, "desktop-window request rejected: {message}")
            }
        }
    }
}

impl std::error::Error for DesktopWindowError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Ipc(error) => Some(error),
            Self::Io(error) => Some(error),
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

impl From<HyprIpcError> for DesktopWindowError {
    fn from(value: HyprIpcError) -> Self {
        Self::Ipc(value)
    }
}
impl From<std::io::Error> for DesktopWindowError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}
impl From<serde_json::Error> for DesktopWindowError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnrollRequest {
    pub local_window_id: String,
    pub window_address: String,
    pub pid: u32,
    pub surface_address: Option<String>,
    pub not_after_monotonic_ns: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Enrollment {
    pub local_window_id: String,
    pub token: String,
    pub expires_at_monotonic_ns: u64,
    pub surface_address: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveRequest {
    pub local_window_id: String,
    pub token: String,
    pub sequence: u64,
    pub not_after_monotonic_ns: u64,
    pub desired_full_capture_x: f64,
    pub desired_full_capture_y: f64,
    pub desired_full_capture_width: f64,
    pub desired_full_capture_height: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseRequest {
    pub local_window_id: String,
    pub token: String,
    pub sequence: u64,
    pub not_after_monotonic_ns: u64,
    pub restore: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Reply {
    ok: bool,
    version: u8,
    error: Option<String>,
}

/// Synchronous adapter to the installed plugin's `hl.plugin.viewflow.desktop_window`.
/// The caller is responsible for issuing strictly consecutive sequence values.
#[derive(Clone, Debug)]
pub struct DesktopWindowClient {
    ipc: HyprIpcClient,
    request_path: PathBuf,
    expected_compositor_pid: i32,
}

impl DesktopWindowClient {
    #[must_use]
    pub fn new(ipc: HyprIpcClient, request_path: PathBuf, expected_compositor_pid: i32) -> Self {
        Self {
            ipc,
            request_path,
            expected_compositor_pid,
        }
    }

    /// Enrolls exactly one current Hyprland window and returns its opaque token.
    ///
    /// # Errors
    ///
    /// Returns an error if the local compositor endpoint or request file cannot
    /// be verified, or if the controller rejects the enrollment.
    pub fn enroll(&self, request: &EnrollRequest) -> Result<Enrollment, DesktopWindowError> {
        let encoded = serde_json::json!({
            "version": VERSION, "operation": "enroll",
            "localWindowId": request.local_window_id,
            "windowAddress": request.window_address, "pid": request.pid,
            "surfaceAddress": request.surface_address,
            "notAfterMonotonicNs": request.not_after_monotonic_ns,
        });
        let reply = self.invoke(&encoded)?;
        Ok(serde_json::from_value(reply)?)
    }

    /// Moves only a previously enrolled window to complete-capture logical coordinates.
    ///
    /// # Errors
    ///
    /// Returns an error if the local endpoint cannot be verified or the
    /// controller rejects the token, deadline, sequence, or move.
    /// Returns the renewed idle enrollment deadline when supported by the plugin.
    pub fn move_window(&self, request: &MoveRequest) -> Result<Option<u64>, DesktopWindowError> {
        let encoded = serde_json::json!({
            "version": VERSION, "operation": "move",
            "localWindowId": request.local_window_id, "token": request.token,
            "sequence": request.sequence, "notAfterMonotonicNs": request.not_after_monotonic_ns,
            "desiredFullCaptureX": request.desired_full_capture_x,
            "desiredFullCaptureY": request.desired_full_capture_y,
            "desiredFullCaptureWidth": request.desired_full_capture_width,
            "desiredFullCaptureHeight": request.desired_full_capture_height,
        });
        let reply = self.invoke(&encoded)?;
        Ok(reply
            .get("expiresAtMonotonicNs")
            .and_then(serde_json::Value::as_u64))
    }

    /// Releases only the matching owned enrollment; `restore` requests its retained origin.
    ///
    /// # Errors
    ///
    /// Returns an error if the local endpoint cannot be verified or the
    /// controller rejects the token, deadline, sequence, or release.
    pub fn release(&self, request: &ReleaseRequest) -> Result<(), DesktopWindowError> {
        let encoded = serde_json::json!({
            "version": VERSION, "operation": "release",
            "localWindowId": request.local_window_id, "token": request.token,
            "sequence": request.sequence, "notAfterMonotonicNs": request.not_after_monotonic_ns,
            "restore": request.restore,
        });
        self.invoke(&encoded)?;
        Ok(())
    }

    #[cfg(not(target_os = "linux"))]
    fn invoke(
        &self,
        _request: &serde_json::Value,
    ) -> Result<serde_json::Value, DesktopWindowError> {
        Err(DesktopWindowError::Invalid(
            "desktop-window adapter requires Linux",
        ))
    }

    #[cfg(target_os = "linux")]
    fn invoke(&self, request: &serde_json::Value) -> Result<serde_json::Value, DesktopWindowError> {
        let mut stream = self.verify_endpoint()?;
        let mut file = open_private_file(&self.request_path)?;
        let encoded = serde_json::to_vec(request)?;
        if encoded.is_empty() || encoded.len() > MAX_REQUEST_BYTES {
            return Err(DesktopWindowError::Invalid(
                "desktop-window request too large",
            ));
        }
        file.set_len(0)?;
        file.seek(SeekFrom::Start(0))?;
        file.write_all(&encoded)?;
        // File writes are visible to the same-host reader after write_all.
        // This is a transient IPC exchange, not durable state; fdatasync would
        // needlessly charge storage latency to every original input deadline.

        // Hyprland 0.56's `eval` reports command execution as `ok`; unlike
        // `repl`, it does not expose a Lua return value. The authenticated
        // per-request result remains the private JSON file below.
        let command = format!(
            "eval hl.plugin.viewflow.desktop_window({})",
            quote_lua_path(&self.request_path)?
        );
        // Send on the exact socket whose kernel peer credentials were checked,
        // rather than closing that probe and connecting to a second endpoint.
        stream.write_all(command.as_bytes())?;
        let mut lua_bytes = Vec::new();
        stream
            .take((MAX_REQUEST_BYTES + 1) as u64)
            .read_to_end(&mut lua_bytes)?;
        if lua_bytes.len() > MAX_REQUEST_BYTES {
            return Err(DesktopWindowError::Invalid(
                "desktop-window Lua reply too large",
            ));
        }
        let lua_reply = String::from_utf8(lua_bytes)
            .map_err(|_| DesktopWindowError::Invalid("desktop-window Lua reply is not UTF-8"))?;
        if lua_reply.trim() != "ok" {
            return Err(DesktopWindowError::LuaRejected(lua_reply.trim().to_owned()));
        }

        let mut reply_bytes = Vec::new();
        file.seek(SeekFrom::Start(0))?;
        file.read_to_end(&mut reply_bytes)?;
        if reply_bytes.is_empty() || reply_bytes.len() > MAX_REQUEST_BYTES {
            return Err(DesktopWindowError::Invalid("desktop-window reply invalid"));
        }
        let reply: Reply = serde_json::from_slice(&reply_bytes)?;
        if reply.version != VERSION {
            return Err(DesktopWindowError::Invalid(
                "desktop-window reply version invalid",
            ));
        }
        let value = serde_json::from_slice(&reply_bytes)?;
        if !reply.ok {
            return Err(DesktopWindowError::Rejected(
                reply
                    .error
                    .unwrap_or_else(|| "unknown plugin rejection".to_owned()),
            ));
        }
        Ok(value)
    }

    #[cfg(target_os = "linux")]
    fn verify_endpoint(&self) -> Result<UnixStream, DesktopWindowError> {
        if self.expected_compositor_pid <= 0 {
            return Err(DesktopWindowError::EndpointIdentity);
        }
        let metadata = std::fs::symlink_metadata(self.ipc.socket_path())?;
        let parent = self
            .ipc
            .socket_path()
            .parent()
            .ok_or(DesktopWindowError::EndpointIdentity)?;
        let parent_metadata = std::fs::symlink_metadata(parent)?;
        if !metadata.file_type().is_socket()
            || metadata.uid() != nix::unistd::geteuid().as_raw()
            || metadata.mode() & 0o022 != 0
            || !parent_metadata.is_dir()
            || parent_metadata.file_type().is_symlink()
            || parent_metadata.uid() != nix::unistd::geteuid().as_raw()
            || parent_metadata.mode() & 0o777 != 0o700
        {
            return Err(DesktopWindowError::EndpointIdentity);
        }
        let stream = UnixStream::connect(self.ipc.socket_path())?;
        stream.set_read_timeout(Some(Duration::from_secs(1)))?;
        stream.set_write_timeout(Some(Duration::from_secs(1)))?;
        let peer = socket::getsockopt(&stream, sockopt::PeerCredentials)
            .map_err(|error| std::io::Error::from_raw_os_error(error as i32))?;
        if peer.uid() != nix::unistd::geteuid().as_raw()
            || peer.pid() != self.expected_compositor_pid
        {
            return Err(DesktopWindowError::EndpointIdentity);
        }
        Ok(stream)
    }
}

fn quote_lua_path(path: &Path) -> Result<String, DesktopWindowError> {
    let path = path
        .to_str()
        .ok_or(DesktopWindowError::Invalid("request path is not UTF-8"))?;
    if !path.starts_with('/')
        || path.len() > MAX_REQUEST_BYTES
        || path.bytes().any(|byte| byte == 0 || byte < 0x20)
    {
        return Err(DesktopWindowError::Invalid("invalid private request path"));
    }
    Ok(format!(
        "\"{}\"",
        path.replace('\\', "\\\\").replace('"', "\\\"")
    ))
}

fn open_private_file(path: &Path) -> Result<File, DesktopWindowError> {
    #[cfg(not(target_os = "linux"))]
    {
        let _ = path;
        return Err(DesktopWindowError::Invalid(
            "desktop-window adapter requires Linux",
        ));
    }
    #[cfg(target_os = "linux")]
    {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file()
            || metadata.uid() != nix::unistd::geteuid().as_raw()
            || metadata.mode() & 0o777 != 0o600
            || metadata.nlink() != 1
        {
            return Err(DesktopWindowError::Invalid(
                "requires owned mode-0600 regular request file",
            ));
        }
        Ok(file)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "linux")]
    use std::{
        os::unix::{fs::PermissionsExt, net::UnixListener},
        sync::mpsc,
        thread,
    };

    #[cfg(target_os = "linux")]
    fn private_file(name: &str) -> (PathBuf, PathBuf) {
        let directory = std::env::temp_dir().join(format!(
            "viewflow-desktop-window-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let request = directory.join("request.json");
        std::fs::write(&request, b"{}").unwrap();
        std::fs::set_permissions(&request, std::fs::Permissions::from_mode(0o600)).unwrap();
        (directory, request)
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn fake_ipc_verifies_peer_and_round_trips_private_reply() {
        let (directory, request_path) = private_file("ok");
        // Empty-desktop startup may create only the private directory. The
        // adapter must create its exchange file before the first operation.
        std::fs::remove_file(&request_path).unwrap();
        let socket_path = directory.join("hypr.sock");
        let listener = UnixListener::bind(&socket_path).unwrap();
        // Hyprland 0.56.2 exposes its command socket as mode 0755, inside an
        // owner-only 0700 instance directory. Endpoint validation must accept
        // that while rejecting a socket writable by group or other users.
        std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o755)).unwrap();
        let reply_path = request_path.clone();
        let (sent, received) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut command = [0_u8; 1024];
            let count = stream.read(&mut command).unwrap();
            sent.send(String::from_utf8(command[..count].to_vec()).unwrap())
                .unwrap();
            std::fs::write(&reply_path, br#"{"ok":true,"version":1,"localWindowId":"owned","token":"0123456789abcdef0123456789abcdef0123456789abcdef","expiresAtMonotonicNs":99,"surfaceAddress":null}"#).unwrap();
            stream.write_all(b"ok").unwrap();
        });
        let client = DesktopWindowClient::new(
            HyprIpcClient::new(socket_path),
            request_path,
            i32::try_from(std::process::id()).unwrap(),
        );
        let enrolled = client
            .enroll(&EnrollRequest {
                local_window_id: "owned".into(),
                window_address: "0x1234".into(),
                pid: 7,
                surface_address: None,
                not_after_monotonic_ns: 99,
            })
            .unwrap();
        assert_eq!(enrolled.local_window_id, "owned");
        assert_eq!(
            std::fs::metadata(directory.join("request.json"))
                .unwrap()
                .mode()
                & 0o777,
            0o600
        );
        assert!(
            received
                .recv()
                .unwrap()
                .starts_with("eval hl.plugin.viewflow.desktop_window(\"")
        );
        let _ = std::fs::remove_dir_all(directory);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn endpoint_rejects_group_writable_socket_or_nonprivate_parent() {
        let (directory, request_path) = private_file("endpoint-permissions");
        let socket_path = directory.join("hypr.sock");
        let _listener = UnixListener::bind(&socket_path).unwrap();
        let client = DesktopWindowClient::new(
            HyprIpcClient::new(socket_path.clone()),
            request_path.clone(),
            i32::try_from(std::process::id()).unwrap(),
        );

        std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o775)).unwrap();
        assert!(matches!(
            client.verify_endpoint(),
            Err(DesktopWindowError::EndpointIdentity)
        ));

        std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(matches!(
            client.verify_endpoint(),
            Err(DesktopWindowError::EndpointIdentity)
        ));
        let _ = std::fs::remove_dir_all(directory);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn insecure_private_file_is_rejected_before_ipc() {
        let (directory, request_path) = private_file("mode");
        std::fs::set_permissions(&request_path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(matches!(
            open_private_file(&request_path),
            Err(DesktopWindowError::Invalid(_))
        ));
        let _ = std::fs::remove_dir_all(directory);
    }
}
