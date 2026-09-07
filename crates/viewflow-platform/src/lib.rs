//! Native platform boundary. Implementations live in OS-specific crates.

pub mod application_audio;
pub mod fake;
#[cfg(target_os = "linux")]
pub mod linux_application_audio;
#[cfg(target_os = "linux")]
pub mod linux_application_audio_capture;
#[cfg(target_os = "linux")]
pub mod linux_clipboard;
pub mod sidecar;
pub mod windows_input;
pub mod windows_proxy;
pub use fake::FakeBackend;
#[cfg(target_os = "linux")]
pub use linux_clipboard::{
    ClipboardCommandRunner, ClipboardConsent, ClipboardError, ClipboardObservation,
    ClipboardPayload, ClipboardPolicy, NativeClipboardSnapshot, RemoteClipboardReceipt,
    SystemClipboardCommandRunner, WlClipboardAdapter,
};

use viewflow_protocol::{
    DeviceTopology, FramePlaneReady, GeometryEpoch, Id128, InputLease, Rect, WindowDescriptor,
    WindowFamilyId, WindowId,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlatformKind {
    Windows,
    MacOs,
    Hyprland,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlatformError {
    PermissionDenied,
    ProtectedContent,
    Unsupported,
    BackendFailure,
}

/// Capabilities exposed by a native capture/presentation implementation.
/// These are descriptive gates; declaring a capability does not prove that a
/// platform backend is installed or that a compositor accepted a frame.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[allow(clippy::struct_excessive_bools)]
pub struct FrameCapabilities {
    pub capture: bool,
    pub presentation: bool,
    pub separate_alpha: bool,
    pub exact_blur: bool,
    pub rejects_protected_content: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AlphaMode {
    Opaque,
    Premultiplied,
    SeparatePlane,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlurMode {
    None,
    ExactBackground,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CapturedFrame {
    pub window_id: WindowId,
    pub frame_id: u64,
    pub geometry_epoch: u64,
    pub plane: viewflow_protocol::FramePlane,
    pub alpha: AlphaMode,
    pub blur: BlurMode,
    pub protected_content: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProxyLifecycle {
    Absent,
    Created,
    GeometryPending(u64),
    Presented { frame_id: u64, geometry_epoch: u64 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SharedTexture {
    pub id: Id128,
    pub width: u32,
    pub height: u32,
    pub format: TextureFormat,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextureFormat {
    Bgra8Srgb,
    Alpha8,
}

#[allow(clippy::missing_errors_doc)]
pub trait PlatformBackend: Send {
    fn kind(&self) -> PlatformKind;
    fn topology(&self) -> Result<DeviceTopology, PlatformError>;
    fn enumerate_windows(&self) -> Result<Vec<WindowDescriptor>, PlatformError>;
    fn virtualize_family(
        &mut self,
        family: WindowFamilyId,
        render_scale: f64,
    ) -> Result<(), PlatformError>;
    fn create_proxy(
        &mut self,
        window: WindowId,
        visible_bounds_dip: Rect,
    ) -> Result<(), PlatformError>;
    fn apply_geometry(&mut self, geometry: GeometryEpoch) -> Result<(), PlatformError>;
    fn capture_plane(&mut self, ready: FramePlaneReady) -> Result<SharedTexture, PlatformError>;
    fn present_proxy(
        &mut self,
        window: WindowId,
        texture: SharedTexture,
    ) -> Result<(), PlatformError>;
}

/// IPC contract for the separate Deskflow process. No Deskflow code is linked.
#[allow(clippy::missing_errors_doc)]
pub trait DeskflowSidecar: Send {
    fn apply_input_lease(&mut self, lease: InputLease) -> Result<(), PlatformError>;
    fn route_pointer(
        &mut self,
        target: WindowId,
        x_dip: f64,
        y_dip: f64,
    ) -> Result<(), PlatformError>;
    fn route_key(
        &mut self,
        target: WindowId,
        hid_usage: u32,
        pressed: bool,
    ) -> Result<(), PlatformError>;
    fn route_relative_pointer(
        &mut self,
        input: sidecar::RelativePointerInput,
    ) -> Result<(), PlatformError>;
    fn route_pointer_button(
        &mut self,
        input: sidecar::PointerButtonInput,
    ) -> Result<(), PlatformError>;
    fn route_pointer_wheel(
        &mut self,
        input: sidecar::PointerWheelInput,
    ) -> Result<(), PlatformError>;
    fn route_keyboard_hid(&mut self, input: sidecar::KeyboardHidInput)
    -> Result<(), PlatformError>;
    fn release_all(&mut self, input: sidecar::ReleaseAllInput) -> Result<(), PlatformError>;
    fn edge_activated(&mut self, event: sidecar::EdgeActivated) -> Result<(), PlatformError>;
    fn return_to_local(&mut self, command: sidecar::ReturnToLocal) -> Result<(), PlatformError>;
}
