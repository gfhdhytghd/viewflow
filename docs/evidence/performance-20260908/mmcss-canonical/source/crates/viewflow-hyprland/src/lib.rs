//! Read-mostly Hyprland 0.56 platform backend using the compositor's Unix IPC.
//!
//! The backend deliberately does not use `hyprctl`. Capture, proxy presentation,
//! and compositor scene reconstruction are not implemented in this crate yet.

#[cfg(target_os = "linux")]
pub mod capture_wire;
pub mod desktop_window;
mod ids;
mod ipc;
mod model;
pub mod window_pointer_socket;
pub mod window_pointer_wire;

use std::path::PathBuf;

pub use desktop_window::{
    DesktopWindowClient, DesktopWindowError, EnrollRequest, Enrollment, MoveRequest, ReleaseRequest,
};
pub use ipc::{HyprIpcClient, HyprIpcError, resolve_socket_path};
pub use model::{
    AlphaCapability, BlurCapability, HyprMonitor, HyprWindow, RoleEvidence, WindowEffects,
    parse_monitors, parse_windows, physical_rect_to_dip,
};
use viewflow_platform::{PlatformBackend, PlatformError, PlatformKind, SharedTexture};
use viewflow_protocol::{
    DeviceId, DeviceTopology, DisplayDescriptor, FramePlaneReady, GeometryEpoch, Rect,
    WindowDescriptor, WindowFamilyId, WindowId,
};

/// Whether mutating Hyprland IPC commands are permitted.
///
/// The default is intentionally read-only. Callers must opt in explicitly before
/// creating or removing a headless output.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum MutationPolicy {
    #[default]
    ReadOnly,
    AllowHeadlessOutputs,
}

#[derive(Debug)]
pub enum HyprlandError {
    Ipc(HyprIpcError),
    Json(serde_json::Error),
    MutationNotAllowed,
    InvalidOutputName,
    CommandRejected(String),
    Unsupported(&'static str),
}

impl std::fmt::Display for HyprlandError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ipc(error) => write!(formatter, "Hyprland IPC failed: {error}"),
            Self::Json(error) => write!(formatter, "invalid Hyprland JSON: {error}"),
            Self::MutationNotAllowed => formatter.write_str(
                "mutating Hyprland IPC is disabled; explicitly opt in to headless outputs",
            ),
            Self::InvalidOutputName => formatter.write_str("invalid headless output name"),
            Self::CommandRejected(reply) => {
                write!(formatter, "Hyprland rejected the command: {reply}")
            }
            Self::Unsupported(operation) => write!(formatter, "unsupported: {operation}"),
        }
    }
}

impl std::error::Error for HyprlandError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Ipc(error) => Some(error),
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

impl From<HyprIpcError> for HyprlandError {
    fn from(value: HyprIpcError) -> Self {
        Self::Ipc(value)
    }
}

impl From<serde_json::Error> for HyprlandError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}

/// A parsed window plus Viewflow's stable identifiers and effect capabilities.
#[derive(Clone, Debug, PartialEq)]
pub struct HyprWindowRecord {
    pub descriptor: WindowDescriptor,
    pub effects: WindowEffects,
    pub role_evidence: RoleEvidence,
    pub address: String,
    pub title: String,
    pub class: String,
}

#[derive(Clone, Debug)]
pub struct HyprlandBackend {
    ipc: HyprIpcClient,
    instance_signature: String,
    source_device: DeviceId,
    mutation_policy: MutationPolicy,
}

impl HyprlandBackend {
    /// Creates a backend for a known compositor socket.
    #[must_use]
    pub fn new(
        socket_path: PathBuf,
        instance_signature: impl Into<String>,
        source_device: DeviceId,
        mutation_policy: MutationPolicy,
    ) -> Self {
        Self {
            ipc: HyprIpcClient::new(socket_path),
            instance_signature: instance_signature.into(),
            source_device,
            mutation_policy,
        }
    }

    /// Creates a read-only backend from the current Hyprland environment.
    ///
    /// # Errors
    ///
    /// Returns an error when the current Hyprland environment is incomplete.
    pub fn from_env(source_device: DeviceId) -> Result<Self, HyprlandError> {
        #[cfg(not(unix))]
        {
            let _ = source_device;
            Err(HyprlandError::Unsupported(
                "Hyprland backend requires a Unix platform",
            ))
        }

        #[cfg(unix)]
        {
            let instance_signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
                .map_err(|_| HyprIpcError::MissingEnvironment("HYPRLAND_INSTANCE_SIGNATURE"))?;
            let socket_path = resolve_socket_path()?;
            Ok(Self::new(
                socket_path,
                instance_signature,
                source_device,
                MutationPolicy::ReadOnly,
            ))
        }
    }

    /// Reads and parses `j/monitors` without invoking `hyprctl`.
    ///
    /// # Errors
    ///
    /// Returns an IPC or JSON error when the compositor cannot be queried.
    pub fn monitors(&self) -> Result<Vec<HyprMonitor>, HyprlandError> {
        Ok(parse_monitors(&self.ipc.request("j/monitors")?)?)
    }

    /// Reads and parses `j/clients` without invoking `hyprctl`.
    ///
    /// # Errors
    ///
    /// Returns an IPC or JSON error when the compositor cannot be queried.
    pub fn windows(&self) -> Result<Vec<HyprWindow>, HyprlandError> {
        Ok(parse_windows(&self.ipc.request("j/clients")?)?)
    }

    /// Enumerates mapped windows and describes effects that require future capture work.
    ///
    /// # Errors
    ///
    /// Returns an IPC or JSON error when the compositor cannot be queried.
    pub fn window_records(&self) -> Result<Vec<HyprWindowRecord>, HyprlandError> {
        Ok(self
            .windows()?
            .into_iter()
            .filter(|window| window.mapped && !window.hidden)
            .map(|window| window.to_record(&self.instance_signature, self.source_device))
            .collect())
    }

    /// Creates a named headless output after an explicit mutation opt-in.
    ///
    /// # Errors
    ///
    /// Returns an error when mutation is not enabled, the name is invalid, IPC
    /// fails, or Hyprland rejects the command.
    pub fn create_headless_output(&self, name: &str) -> Result<(), HyprlandError> {
        self.headless_output_command(&format!("/output create headless {name}"), name)
    }

    /// Removes a named headless output after an explicit mutation opt-in.
    ///
    /// # Errors
    ///
    /// Returns an error when mutation is not enabled, the name is invalid, IPC
    /// fails, or Hyprland rejects the command.
    pub fn remove_headless_output(&self, name: &str) -> Result<(), HyprlandError> {
        self.headless_output_command(&format!("/output remove {name}"), name)
    }

    fn headless_output_command(&self, command: &str, name: &str) -> Result<(), HyprlandError> {
        if self.mutation_policy != MutationPolicy::AllowHeadlessOutputs {
            return Err(HyprlandError::MutationNotAllowed);
        }
        if !valid_output_name(name) {
            return Err(HyprlandError::InvalidOutputName);
        }

        let reply = self.ipc.request(command)?;
        if reply.trim() == "ok" {
            Ok(())
        } else {
            Err(HyprlandError::CommandRejected(reply.trim().to_owned()))
        }
    }

    fn topology_result(&self) -> Result<DeviceTopology, HyprlandError> {
        let monitors = self.monitors()?;
        let mut generation_material = String::new();
        let displays = monitors
            .iter()
            .filter(|monitor| !monitor.disabled)
            .map(|monitor| {
                generation_material.push_str(&monitor.identity_material());
                DisplayDescriptor {
                    id: ids::stable_id(
                        "hyprland-display",
                        &[&self.instance_signature, &monitor.name],
                    ),
                    device_id: self.source_device,
                    bounds_dip: monitor.bounds_dip(),
                    scale: monitor.scale,
                    refresh_millihz: monitor.refresh_millihz(),
                }
            })
            .collect();

        let generation_bytes = ids::stable_id(
            "hyprland-topology",
            &[&self.instance_signature, &generation_material],
        )
        .0
        .to_le_bytes();
        Ok(DeviceTopology {
            generation: u64::from_le_bytes([
                generation_bytes[0],
                generation_bytes[1],
                generation_bytes[2],
                generation_bytes[3],
                generation_bytes[4],
                generation_bytes[5],
                generation_bytes[6],
                generation_bytes[7],
            ]),
            displays,
        })
    }
}

impl PlatformBackend for HyprlandBackend {
    fn kind(&self) -> PlatformKind {
        PlatformKind::Hyprland
    }

    fn topology(&self) -> Result<DeviceTopology, PlatformError> {
        self.topology_result()
            .map_err(|error| map_platform_error(&error))
    }

    fn enumerate_windows(&self) -> Result<Vec<WindowDescriptor>, PlatformError> {
        self.window_records()
            .map(|records| {
                records
                    .into_iter()
                    .map(|record| record.descriptor)
                    .collect()
            })
            .map_err(|error| map_platform_error(&error))
    }

    fn virtualize_family(
        &mut self,
        _family: WindowFamilyId,
        _render_scale: f64,
    ) -> Result<(), PlatformError> {
        Err(PlatformError::Unsupported)
    }

    fn create_proxy(
        &mut self,
        _window: WindowId,
        _visible_bounds_dip: Rect,
    ) -> Result<(), PlatformError> {
        Err(PlatformError::Unsupported)
    }

    fn apply_geometry(&mut self, _geometry: GeometryEpoch) -> Result<(), PlatformError> {
        Err(PlatformError::Unsupported)
    }

    fn capture_plane(&mut self, _ready: FramePlaneReady) -> Result<SharedTexture, PlatformError> {
        Err(PlatformError::Unsupported)
    }

    fn present_proxy(
        &mut self,
        _window: WindowId,
        _texture: SharedTexture,
    ) -> Result<(), PlatformError> {
        Err(PlatformError::Unsupported)
    }
}

fn map_platform_error(error: &HyprlandError) -> PlatformError {
    match error {
        HyprlandError::MutationNotAllowed => PlatformError::PermissionDenied,
        HyprlandError::Ipc(HyprIpcError::UnsupportedPlatform) | HyprlandError::Unsupported(_) => {
            PlatformError::Unsupported
        }
        _ => PlatformError::BackendFailure,
    }
}

fn valid_output_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::io::{Read, Write};
    #[cfg(unix)]
    use std::os::unix::net::UnixListener;
    #[cfg(unix)]
    use std::sync::atomic::{AtomicU64, Ordering};
    #[cfg(unix)]
    use std::sync::mpsc;
    #[cfg(unix)]
    use std::thread;
    #[cfg(unix)]
    use std::time::Duration;
    use viewflow_protocol::Id128;

    #[cfg(unix)]
    static SOCKET_SEQUENCE: AtomicU64 = AtomicU64::new(1);

    #[cfg(unix)]
    fn socket_server(reply: &'static str) -> (PathBuf, mpsc::Receiver<String>) {
        let path = std::env::temp_dir().join(format!(
            "viewflow-hyprland-{}-{}.sock",
            std::process::id(),
            SOCKET_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).expect("bind fixture socket");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .expect("set timeout");
            let mut request = [0_u8; 256];
            let size = stream.read(&mut request).expect("read request");
            sender
                .send(String::from_utf8_lossy(&request[..size]).into_owned())
                .expect("record request");
            stream.write_all(reply.as_bytes()).expect("write reply");
        });
        (path, receiver)
    }

    #[test]
    fn defaults_to_read_only_for_headless_outputs() {
        let backend = HyprlandBackend::new(
            PathBuf::from("/not/used"),
            "fixture-instance",
            Id128(1),
            MutationPolicy::ReadOnly,
        );

        assert!(matches!(
            backend.create_headless_output("VIEWFLOW-1"),
            Err(HyprlandError::MutationNotAllowed)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn opted_in_headless_output_uses_native_ipc_command() {
        let (path, request) = socket_server("ok");
        let backend = HyprlandBackend::new(
            path.clone(),
            "fixture-instance",
            Id128(1),
            MutationPolicy::AllowHeadlessOutputs,
        );

        backend
            .create_headless_output("VIEWFLOW-1")
            .expect("headless output command succeeds");
        assert_eq!(
            request.recv_timeout(Duration::from_secs(1)).unwrap(),
            "/output create headless VIEWFLOW-1"
        );
        let _ = std::fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn removing_headless_output_uses_hyprland_remove_syntax() {
        let (path, request) = socket_server("ok");
        let backend = HyprlandBackend::new(
            path.clone(),
            "fixture-instance",
            Id128(1),
            MutationPolicy::AllowHeadlessOutputs,
        );

        backend
            .remove_headless_output("VIEWFLOW-1")
            .expect("headless output removal succeeds");
        assert_eq!(
            request.recv_timeout(Duration::from_secs(1)).unwrap(),
            "/output remove VIEWFLOW-1"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn capture_and_presentation_are_explicitly_unsupported() {
        let mut backend = HyprlandBackend::new(
            PathBuf::from("/not/used"),
            "fixture-instance",
            Id128(1),
            MutationPolicy::ReadOnly,
        );

        let ready = FramePlaneReady {
            window_id: Id128(2),
            frame_id: 1,
            geometry_epoch: 1,
            plane: viewflow_protocol::FramePlane::Color,
            source_submitted_ns: 0,
            received_ns: 0,
        };
        assert_eq!(
            backend.capture_plane(ready),
            Err(PlatformError::Unsupported)
        );
        assert_eq!(
            backend.present_proxy(
                Id128(2),
                SharedTexture {
                    id: Id128(3),
                    width: 1,
                    height: 1,
                    format: viewflow_platform::TextureFormat::Bgra8Srgb,
                }
            ),
            Err(PlatformError::Unsupported)
        );
    }

    #[cfg(unix)]
    #[test]
    #[ignore = "requires a live Hyprland session"]
    fn live_session_supports_read_only_monitor_and_window_queries() {
        let backend = HyprlandBackend::from_env(Id128(1)).expect("resolve live Hyprland session");
        let monitors = backend.monitors().expect("parse live j/monitors");
        let windows = backend.windows().expect("parse live j/clients");
        let topology = backend.topology().expect("convert live topology");
        let records = backend.window_records().expect("convert live windows");

        assert!(!monitors.is_empty());
        assert!(monitors.iter().all(|monitor| monitor.scale > 0.0));
        assert_eq!(
            topology.displays.len(),
            monitors.iter().filter(|monitor| !monitor.disabled).count()
        );
        assert_eq!(
            records.len(),
            windows
                .iter()
                .filter(|window| window.mapped && !window.hidden)
                .count()
        );
        assert!(windows.iter().all(|window| {
            window.size[0].is_finite() && window.size[1].is_finite() && !window.address.is_empty()
        }));
    }
}
