//! Versioned types shared by Viewflow processes and peers.

use std::fmt;

mod application_icon;
pub use application_icon::ApplicationIcon;
mod atlas;
pub use atlas::{AtlasFrame, AtlasPatch, AtlasTile};
mod desktop;
pub use desktop::{
    AtlasDesktopLayout, AtlasWindowPlacement, DesktopRect, DesktopWindowMove, DesktopWindowMoveAck,
    DesktopWindowMovePhase, DesktopWindowMoveResult,
};
mod atlas_selection;
pub use atlas_selection::{
    AtlasSelectionRejectionReason, AtlasWindowSelection, AtlasWindowSelectionAccepted,
    AtlasWindowSelectionRejected,
};

mod window_input;
mod window_keyboard;
pub use window_input::{
    WindowPointerAck, WindowPointerAuthorization, WindowPointerButton, WindowPointerMotion,
    WindowPointerResult, WindowPointerWheel,
};
pub use window_keyboard::{
    WindowKeyboardAck, WindowKeyboardAuthorization, WindowKeyboardEvent, WindowKeyboardMode,
    WindowKeyboardResult,
};

/// Generated protobuf representation used on QUIC control streams.
pub mod wire {
    #![allow(clippy::doc_markdown, clippy::must_use_candidate)]

    include!(concat!(env!("OUT_DIR"), "/viewflow.v1.rs"));
}

pub const PROTOCOL_VERSION: ProtocolVersion = ProtocolVersion { major: 2, minor: 1 };
const MIN_COMPATIBLE_PROTOCOL_MINOR: u16 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct ProtocolVersion {
    pub major: u16,
    pub minor: u16,
}

impl ProtocolVersion {
    #[must_use]
    pub const fn is_compatible_with(self, other: Self) -> bool {
        self.major == other.major
            && self.minor >= MIN_COMPATIBLE_PROTOCOL_MINOR
            && other.minor >= MIN_COMPATIBLE_PROTOCOL_MINOR
    }
}

#[derive(Clone, Copy, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct Id128(pub u128);

impl fmt::Debug for Id128 {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:032x}", self.0)
    }
}

pub type DeviceId = Id128;
pub type WindowId = Id128;
pub type WindowFamilyId = Id128;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub origin: Point,
    pub size: Size,
}

impl Rect {
    #[must_use]
    pub fn area(self) -> f64 {
        self.size.width.max(0.0) * self.size.height.max(0.0)
    }

    #[must_use]
    pub fn intersection(self, other: Self) -> Option<Self> {
        let left = self.origin.x.max(other.origin.x);
        let top = self.origin.y.max(other.origin.y);
        let right = (self.origin.x + self.size.width).min(other.origin.x + other.size.width);
        let bottom = (self.origin.y + self.size.height).min(other.origin.y + other.size.height);
        (right > left && bottom > top).then_some(Self {
            origin: Point { x: left, y: top },
            size: Size {
                width: right - left,
                height: bottom - top,
            },
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DisplayDescriptor {
    pub id: Id128,
    pub device_id: DeviceId,
    pub bounds_dip: Rect,
    pub scale: f64,
    pub refresh_millihz: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceTopology {
    pub generation: u64,
    pub displays: Vec<DisplayDescriptor>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowRole {
    Main,
    Dialog,
    Menu,
    Tooltip,
    Utility,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WindowDescriptor {
    pub id: WindowId,
    pub family_id: WindowFamilyId,
    pub source_device: DeviceId,
    pub role: WindowRole,
    pub bounds_dip: Rect,
    pub min_size_dip: Size,
    pub max_size_dip: Option<Size>,
    pub has_alpha: bool,
    pub blur_radius_dip: Option<f32>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GeometryPhase {
    Begin,
    Update,
    End,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GeometryEpoch {
    pub window_id: WindowId,
    pub epoch: u64,
    pub phase: GeometryPhase,
    pub bounds_dip: Rect,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FramePlane {
    Color,
    Alpha,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FramePlaneReady {
    pub window_id: WindowId,
    pub frame_id: u64,
    pub geometry_epoch: u64,
    pub plane: FramePlane,
    pub source_submitted_ns: u64,
    pub received_ns: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FrameManifest {
    pub window_id: WindowId,
    pub frame_id: u64,
    pub geometry_epoch: u64,
    pub source_submitted_ns: u64,
    pub received_ns: u64,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum InputLeaseState {
    Offered,
    Active,
    Revoked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InputLease {
    pub generation: u64,
    pub owner: DeviceId,
    pub route_to: DeviceId,
    pub state: InputLeaseState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InputLeaseRevoke {
    pub operation_id: Id128,
    pub lease_generation: u64,
    pub owner_device: DeviceId,
    pub target_device: DeviceId,
    pub state: InputLeaseState,
}

impl InputLeaseRevoke {
    #[must_use]
    pub const fn lease(self) -> InputLease {
        InputLease {
            generation: self.lease_generation,
            owner: self.owner_device,
            route_to: self.target_device,
            state: self.state,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RelativePointerMotion {
    /// Target-independent logical pixels; positive values move right.
    pub delta_x_dip: f64,
    /// Target-independent logical pixels; positive values move down.
    pub delta_y_dip: f64,
}

/// Absolute position in the shared global logical desktop.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DesktopPointerPosition {
    pub x_millidip: i64,
    pub y_millidip: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PointerButton {
    Left,
    Middle,
    Right,
    Back,
    Forward,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputSwitchState {
    Pressed,
    Released,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PointerButtonEvent {
    pub button: PointerButton,
    pub state: InputSwitchState,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PointerWheelEvent {
    /// Positive values scroll up; one unit is one standard detent.
    pub vertical_delta_detents: f64,
    /// Positive values scroll right; one unit is one standard detent.
    pub horizontal_delta_detents: f64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeyboardHidUsage {
    /// USB HID usage page.
    pub usage_page: u16,
    /// USB HID usage ID within `usage_page`.
    pub usage_id: u16,
    pub state: InputSwitchState,
    pub repeat: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TouchpadContact {
    pub id: u32,
    pub x: u32,
    pub y: u32,
}

/// Full contact snapshot. Missing contacts are lifted, including on empty frames.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TouchpadFrame {
    pub width: u32,
    pub height: u32,
    pub count: u8,
    pub contacts: [TouchpadContact; 5],
}
impl TouchpadFrame {
    pub fn validate(&self) -> Result<(), WireError> {
        if self.width == 0
            || self.height == 0
            || self.width > 100_000
            || self.height > 100_000
            || self.count > 5
        {
            return Err(WireError::InvalidField("touchpad.dimensions_or_count"));
        }
        for (i, contact) in self.contacts[..usize::from(self.count)].iter().enumerate() {
            if contact.x > self.width
                || contact.y > self.height
                || self.contacts[..i].iter().any(|old| old.id == contact.id)
            {
                return Err(WireError::InvalidField("touchpad.contact"));
            }
        }
        Ok(())
    }
}
impl TryFrom<wire::TouchpadFrame> for TouchpadFrame {
    type Error = WireError;
    fn try_from(value: wire::TouchpadFrame) -> Result<Self, Self::Error> {
        if value.contacts.len() > 5 {
            return Err(WireError::InvalidField("touchpad.count"));
        }
        let mut frame = Self {
            width: value.width,
            height: value.height,
            count: value.contacts.len() as u8,
            ..Self::default()
        };
        for (out, c) in frame.contacts.iter_mut().zip(value.contacts) {
            *out = TouchpadContact {
                id: c.id,
                x: c.x,
                y: c.y,
            };
        }
        frame.validate()?;
        Ok(frame)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum InputEventKind {
    Touchpad(TouchpadFrame),
    DesktopPointerPosition(DesktopPointerPosition),
    PointerMotion(RelativePointerMotion),
    PointerButton(PointerButtonEvent),
    PointerWheel(PointerWheelEvent),
    KeyboardHidUsage(KeyboardHidUsage),
    ReleaseAll,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InputEvent {
    /// Must equal the generation of the target's active input lease.
    pub lease_generation: u64,
    pub target_device: DeviceId,
    /// Strictly increasing within a lease generation and target pair.
    pub sequence: u64,
    /// Absolute expiry on the sender's process-monotonic clock.
    ///
    /// Zero is reserved for [`InputEventKind::ReleaseAll`] safety cleanup.
    pub sender_not_after_ns: u64,
    pub event: InputEventKind,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputAppliedResult {
    Applied,
    RejectedNoLease,
    RejectedLeaseNotActive,
    RejectedLeaseGeneration,
    RejectedTargetDevice,
    RejectedEventSequence,
    RejectedUnsupportedInput,
    RejectedInvalidInput,
    InjectionFailed,
    RejectedExpired,
    RejectedClockUnsynchronized,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InputAppliedAck {
    pub lease_generation: u64,
    pub target_device: DeviceId,
    pub event_sequence: u64,
    pub result: InputAppliedResult,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputLeaseRevokedResult {
    Applied,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InputLeaseRevokedAck {
    pub operation_id: Id128,
    pub lease_generation: u64,
    pub owner_device: DeviceId,
    pub target_device: DeviceId,
    pub state: InputLeaseState,
    pub result: InputLeaseRevokedResult,
}

impl From<InputAppliedResult> for wire::InputAppliedResult {
    fn from(value: InputAppliedResult) -> Self {
        match value {
            InputAppliedResult::Applied => Self::Applied,
            InputAppliedResult::RejectedNoLease => Self::RejectedNoLease,
            InputAppliedResult::RejectedLeaseNotActive => Self::RejectedLeaseNotActive,
            InputAppliedResult::RejectedLeaseGeneration => Self::RejectedLeaseGeneration,
            InputAppliedResult::RejectedTargetDevice => Self::RejectedTargetDevice,
            InputAppliedResult::RejectedEventSequence => Self::RejectedEventSequence,
            InputAppliedResult::RejectedUnsupportedInput => Self::RejectedUnsupportedInput,
            InputAppliedResult::RejectedInvalidInput => Self::RejectedInvalidInput,
            InputAppliedResult::InjectionFailed => Self::InjectionFailed,
            InputAppliedResult::RejectedExpired => Self::RejectedExpired,
            InputAppliedResult::RejectedClockUnsynchronized => Self::RejectedClockUnsynchronized,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardFlavor {
    pub name: String,
    pub size_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardOffer {
    pub id: Id128,
    pub owner: DeviceId,
    pub generation: u64,
    pub flavors: Vec<ClipboardFlavor>,
}

/// A digest-bound clipboard flavor used only by the explicit transfer lane.
/// Legacy [`ClipboardFlavor`] stays discovery-only for wire compatibility.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardTransferFlavor {
    pub name: String,
    pub size_bytes: u64,
    pub sha256: [u8; 32],
}

/// Explicit clipboard transfer offer. `consent_correlation` is auditable
/// correlation, not evidence of user consent; each endpoint must still require
/// its own local consent capability before sending or applying bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardTransferOffer {
    pub offer: ClipboardOffer,
    pub flavors: Vec<ClipboardTransferFlavor>,
    pub offer_nonce: [u8; 16],
    pub consent_correlation: [u8; 16],
    pub connection_binding: [u8; 32],
    pub payload_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardAccept {
    pub offer_id: Id128,
    pub generation: u64,
    pub offer_nonce: [u8; 16],
    pub mime_type: String,
    pub payload_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardPayload {
    pub offer_id: Id128,
    pub generation: u64,
    pub offer_nonce: [u8; 16],
    pub payload_sequence: u64,
    pub mime_type: String,
    pub data: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClipboardCompletionStatus {
    Completed,
    Cancelled,
    Rejected,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardComplete {
    pub offer_id: Id128,
    pub generation: u64,
    pub offer_nonce: [u8; 16],
    pub payload_sequence: u64,
    pub status: ClipboardCompletionStatus,
    pub error_message: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DragOperation {
    Copy,
    Move,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DragItem {
    pub relative_path: String,
    pub size_bytes: u64,
    pub content_hash: Option<[u8; 32]>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DragOffer {
    pub id: Id128,
    pub generation: u64,
    pub source_device: DeviceId,
    pub target_device: DeviceId,
    pub operation: DragOperation,
    pub items: Vec<DragItem>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DragAccept {
    pub offer_id: Id128,
    pub generation: u64,
    pub operation: DragOperation,
    pub destination_token: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DragProgress {
    pub offer_id: Id128,
    pub generation: u64,
    pub bytes_transferred: u64,
    pub total_bytes: u64,
    pub item_index: u32,
    pub offset_bytes: u64,
    pub chunk_size_bytes: u64,
    pub chunk_hash: Option<[u8; 32]>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DragCompletionStatus {
    Completed,
    Cancelled,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DragItemResult {
    pub item_index: u32,
    pub bytes_received: u64,
    pub content_hash: Option<[u8; 32]>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DragComplete {
    pub offer_id: Id128,
    pub generation: u64,
    pub status: DragCompletionStatus,
    pub error_message: Option<String>,
    pub item_results: Vec<DragItemResult>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioRoute {
    pub generation: u64,
    pub family_id: WindowFamilyId,
    pub source_device: DeviceId,
    pub target_device: DeviceId,
    pub target_output_id: String,
    pub enabled: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HidDeviceOffer {
    pub id: Id128,
    pub owner: DeviceId,
    pub vendor_id: u16,
    pub product_id: u16,
    pub interface_count: u8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HidLeaseState {
    Offered,
    Active,
    Revoked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HidDeviceLease {
    pub generation: u64,
    pub device_id: Id128,
    pub owner: DeviceId,
    pub route_to: DeviceId,
    pub state: HidLeaseState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ClockSyncProbe {
    pub probe_id: u64,
    pub t0_send_ns: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ClockSyncReply {
    pub probe_id: u64,
    pub t0_send_ns: u64,
    pub t1_receive_ns: u64,
    pub t2_send_ns: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum DomainControl {
    ApplicationIcon(ApplicationIcon),
    WindowInputRelease(WindowId),
    AtlasWindowSelection(AtlasWindowSelection),
    AtlasWindowSelectionRejected(AtlasWindowSelectionRejected),
    AtlasWindowSelectionAccepted(AtlasWindowSelectionAccepted),
    Topology(DeviceTopology),
    RegisterWindow(WindowDescriptor),
    Geometry(GeometryEpoch),
    FramePlane(FramePlaneReady),
    AtlasFrame(AtlasFrame),
    DesktopWindowMove(DesktopWindowMove),
    DesktopWindowMoveAck(DesktopWindowMoveAck),
    InputLease(InputLease),
    InputLeaseRevoke(InputLeaseRevoke),
    InputEvent(InputEvent),
    WindowPointerMotion(WindowPointerMotion),
    WindowPointerButton(WindowPointerButton),
    WindowPointerWheel(WindowPointerWheel),
    WindowKeyboardEvent(WindowKeyboardEvent),
    WindowKeyboardAck(WindowKeyboardAck),
    WindowKeyboardAuthorization(WindowKeyboardAuthorization),
    WindowPointerAck(WindowPointerAck),
    WindowPointerAuthorization(WindowPointerAuthorization),
    InputAppliedAck(InputAppliedAck),
    InputLeaseRevokedAck(InputLeaseRevokedAck),
    ClipboardOffer(ClipboardOffer),
    ClipboardTransferOffer(ClipboardTransferOffer),
    ClipboardAccept(ClipboardAccept),
    ClipboardPayload(ClipboardPayload),
    ClipboardComplete(ClipboardComplete),
    FileDragOffer(DragOffer),
    FileDragAccept(DragAccept),
    FileDragProgress(DragProgress),
    FileDragComplete(DragComplete),
    AudioRoute(AudioRoute),
    HidDeviceOffer(HidDeviceOffer),
    HidDeviceLease(HidDeviceLease),
    ClockSyncProbe(ClockSyncProbe),
    ClockSyncReply(ClockSyncReply),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WireError {
    IncompatibleVersion,
    MissingPayload,
    MissingField(&'static str),
    UnknownEnum(&'static str),
    InvalidField(&'static str),
}

fn id_from_wire(value: wire::Id128) -> Id128 {
    Id128((u128::from(value.high) << 64) | u128::from(value.low))
}

fn id_to_wire(value: Id128) -> wire::Id128 {
    wire::Id128 {
        high: u64::try_from(value.0 >> 64).expect("upper Id128 half always fits in u64"),
        low: u64::try_from(value.0 & u128::from(u64::MAX))
            .expect("lower Id128 half always fits in u64"),
    }
}

fn point_from_wire(value: wire::Point) -> Point {
    Point {
        x: value.x,
        y: value.y,
    }
}

fn size_from_wire(value: wire::Size) -> Size {
    Size {
        width: value.width,
        height: value.height,
    }
}

fn rect_from_wire(value: wire::Rect) -> Result<Rect, WireError> {
    Ok(Rect {
        origin: point_from_wire(value.origin.ok_or(WireError::MissingField("rect.origin"))?),
        size: size_from_wire(value.size.ok_or(WireError::MissingField("rect.size"))?),
    })
}

fn required_id(value: Option<wire::Id128>, field: &'static str) -> Result<Id128, WireError> {
    value
        .map(id_from_wire)
        .ok_or(WireError::MissingField(field))
}

fn sha256_from_wire(value: Vec<u8>, field: &'static str) -> Result<[u8; 32], WireError> {
    value.try_into().map_err(|_| WireError::InvalidField(field))
}

fn bytes16_from_wire(value: Vec<u8>, field: &'static str) -> Result<[u8; 16], WireError> {
    value.try_into().map_err(|_| WireError::InvalidField(field))
}

fn window_role_from_wire(value: i32) -> Result<WindowRole, WireError> {
    match wire::WindowRole::try_from(value).map_err(|_| WireError::UnknownEnum("window.role"))? {
        wire::WindowRole::Main => Ok(WindowRole::Main),
        wire::WindowRole::Dialog => Ok(WindowRole::Dialog),
        wire::WindowRole::Menu => Ok(WindowRole::Menu),
        wire::WindowRole::Tooltip => Ok(WindowRole::Tooltip),
        wire::WindowRole::Utility => Ok(WindowRole::Utility),
        wire::WindowRole::Unspecified => Err(WireError::UnknownEnum("window.role")),
    }
}

fn geometry_phase_from_wire(value: i32) -> Result<GeometryPhase, WireError> {
    match wire::GeometryPhase::try_from(value)
        .map_err(|_| WireError::UnknownEnum("geometry.phase"))?
    {
        wire::GeometryPhase::Begin => Ok(GeometryPhase::Begin),
        wire::GeometryPhase::Update => Ok(GeometryPhase::Update),
        wire::GeometryPhase::End => Ok(GeometryPhase::End),
        wire::GeometryPhase::Unspecified => Err(WireError::UnknownEnum("geometry.phase")),
    }
}

fn frame_plane_from_wire(value: i32) -> Result<FramePlane, WireError> {
    match wire::FramePlane::try_from(value).map_err(|_| WireError::UnknownEnum("frame.plane"))? {
        wire::FramePlane::Color => Ok(FramePlane::Color),
        wire::FramePlane::Alpha => Ok(FramePlane::Alpha),
        wire::FramePlane::Unspecified => Err(WireError::UnknownEnum("frame.plane")),
    }
}

fn input_lease_state_from_wire(value: i32) -> Result<InputLeaseState, WireError> {
    match wire::InputLeaseState::try_from(value)
        .map_err(|_| WireError::UnknownEnum("input_lease.state"))?
    {
        wire::InputLeaseState::Offered => Ok(InputLeaseState::Offered),
        wire::InputLeaseState::Active => Ok(InputLeaseState::Active),
        wire::InputLeaseState::Revoked => Ok(InputLeaseState::Revoked),
        wire::InputLeaseState::Unspecified => Err(WireError::UnknownEnum("input_lease.state")),
    }
}

fn pointer_button_from_wire(value: i32) -> Result<PointerButton, WireError> {
    match wire::PointerButton::try_from(value)
        .map_err(|_| WireError::UnknownEnum("pointer_button.button"))?
    {
        wire::PointerButton::Left => Ok(PointerButton::Left),
        wire::PointerButton::Middle => Ok(PointerButton::Middle),
        wire::PointerButton::Right => Ok(PointerButton::Right),
        wire::PointerButton::Back => Ok(PointerButton::Back),
        wire::PointerButton::Forward => Ok(PointerButton::Forward),
        wire::PointerButton::Unspecified => Err(WireError::UnknownEnum("pointer_button.button")),
    }
}

fn input_switch_state_from_wire(
    value: i32,
    field: &'static str,
) -> Result<InputSwitchState, WireError> {
    match wire::InputSwitchState::try_from(value).map_err(|_| WireError::UnknownEnum(field))? {
        wire::InputSwitchState::Pressed => Ok(InputSwitchState::Pressed),
        wire::InputSwitchState::Released => Ok(InputSwitchState::Released),
        wire::InputSwitchState::Unspecified => Err(WireError::UnknownEnum(field)),
    }
}

fn input_applied_result_from_wire(value: i32) -> Result<InputAppliedResult, WireError> {
    match wire::InputAppliedResult::try_from(value)
        .map_err(|_| WireError::UnknownEnum("input_applied_ack.result"))?
    {
        wire::InputAppliedResult::Applied => Ok(InputAppliedResult::Applied),
        wire::InputAppliedResult::RejectedNoLease => Ok(InputAppliedResult::RejectedNoLease),
        wire::InputAppliedResult::RejectedLeaseNotActive => {
            Ok(InputAppliedResult::RejectedLeaseNotActive)
        }
        wire::InputAppliedResult::RejectedLeaseGeneration => {
            Ok(InputAppliedResult::RejectedLeaseGeneration)
        }
        wire::InputAppliedResult::RejectedTargetDevice => {
            Ok(InputAppliedResult::RejectedTargetDevice)
        }
        wire::InputAppliedResult::RejectedEventSequence => {
            Ok(InputAppliedResult::RejectedEventSequence)
        }
        wire::InputAppliedResult::RejectedUnsupportedInput => {
            Ok(InputAppliedResult::RejectedUnsupportedInput)
        }
        wire::InputAppliedResult::RejectedInvalidInput => {
            Ok(InputAppliedResult::RejectedInvalidInput)
        }
        wire::InputAppliedResult::InjectionFailed => Ok(InputAppliedResult::InjectionFailed),
        wire::InputAppliedResult::RejectedExpired => Ok(InputAppliedResult::RejectedExpired),
        wire::InputAppliedResult::RejectedClockUnsynchronized => {
            Ok(InputAppliedResult::RejectedClockUnsynchronized)
        }
        wire::InputAppliedResult::Unspecified => {
            Err(WireError::UnknownEnum("input_applied_ack.result"))
        }
    }
}

fn input_lease_revoked_result_from_wire(value: i32) -> Result<InputLeaseRevokedResult, WireError> {
    match wire::InputLeaseRevokedResult::try_from(value)
        .map_err(|_| WireError::UnknownEnum("input_lease_revoked_ack.result"))?
    {
        wire::InputLeaseRevokedResult::Applied => Ok(InputLeaseRevokedResult::Applied),
        wire::InputLeaseRevokedResult::Unspecified => {
            Err(WireError::UnknownEnum("input_lease_revoked_ack.result"))
        }
    }
}

fn finite(value: f64, field: &'static str) -> Result<f64, WireError> {
    value
        .is_finite()
        .then_some(value)
        .ok_or(WireError::InvalidField(field))
}

fn nonzero(value: u64, field: &'static str) -> Result<u64, WireError> {
    (value != 0)
        .then_some(value)
        .ok_or(WireError::InvalidField(field))
}

fn hid_usage_component(value: u32, field: &'static str) -> Result<u16, WireError> {
    let value = u16::try_from(value).map_err(|_| WireError::InvalidField(field))?;
    (value != 0)
        .then_some(value)
        .ok_or(WireError::InvalidField(field))
}

fn drag_operation_from_wire(value: i32, field: &'static str) -> Result<DragOperation, WireError> {
    match wire::DragOperation::try_from(value).map_err(|_| WireError::UnknownEnum(field))? {
        wire::DragOperation::Copy => Ok(DragOperation::Copy),
        wire::DragOperation::Move => Ok(DragOperation::Move),
        wire::DragOperation::Unspecified => Err(WireError::UnknownEnum(field)),
    }
}

fn drag_completion_from_wire(value: i32) -> Result<DragCompletionStatus, WireError> {
    match wire::FileDragCompletionStatus::try_from(value)
        .map_err(|_| WireError::UnknownEnum("file_drag_complete.status"))?
    {
        wire::FileDragCompletionStatus::Completed => Ok(DragCompletionStatus::Completed),
        wire::FileDragCompletionStatus::Cancelled => Ok(DragCompletionStatus::Cancelled),
        wire::FileDragCompletionStatus::Failed => Ok(DragCompletionStatus::Failed),
        wire::FileDragCompletionStatus::Unspecified => {
            Err(WireError::UnknownEnum("file_drag_complete.status"))
        }
    }
}

fn clipboard_completion_from_wire(value: i32) -> Result<ClipboardCompletionStatus, WireError> {
    match wire::ClipboardCompletionStatus::try_from(value)
        .map_err(|_| WireError::UnknownEnum("clipboard_complete.status"))?
    {
        wire::ClipboardCompletionStatus::Completed => Ok(ClipboardCompletionStatus::Completed),
        wire::ClipboardCompletionStatus::Cancelled => Ok(ClipboardCompletionStatus::Cancelled),
        wire::ClipboardCompletionStatus::Rejected => Ok(ClipboardCompletionStatus::Rejected),
        wire::ClipboardCompletionStatus::Failed => Ok(ClipboardCompletionStatus::Failed),
        wire::ClipboardCompletionStatus::Unspecified => {
            Err(WireError::UnknownEnum("clipboard_complete.status"))
        }
    }
}

fn hid_lease_state_from_wire(value: i32) -> Result<HidLeaseState, WireError> {
    match wire::HidLeaseState::try_from(value)
        .map_err(|_| WireError::UnknownEnum("hid_device_lease.state"))?
    {
        wire::HidLeaseState::Offered => Ok(HidLeaseState::Offered),
        wire::HidLeaseState::Active => Ok(HidLeaseState::Active),
        wire::HidLeaseState::Revoked => Ok(HidLeaseState::Revoked),
        wire::HidLeaseState::Unspecified => Err(WireError::UnknownEnum("hid_device_lease.state")),
    }
}

impl TryFrom<wire::DisplayDescriptor> for DisplayDescriptor {
    type Error = WireError;

    fn try_from(value: wire::DisplayDescriptor) -> Result<Self, Self::Error> {
        Ok(Self {
            id: required_id(value.id, "display.id")?,
            device_id: required_id(value.device_id, "display.device_id")?,
            bounds_dip: rect_from_wire(
                value
                    .bounds_dip
                    .ok_or(WireError::MissingField("display.bounds_dip"))?,
            )?,
            scale: value.scale,
            refresh_millihz: value.refresh_millihz,
        })
    }
}

impl TryFrom<wire::DeviceTopology> for DeviceTopology {
    type Error = WireError;

    fn try_from(value: wire::DeviceTopology) -> Result<Self, Self::Error> {
        Ok(Self {
            generation: value.generation,
            displays: value
                .displays
                .into_iter()
                .map(DisplayDescriptor::try_from)
                .collect::<Result<_, _>>()?,
        })
    }
}

impl TryFrom<wire::WindowDescriptor> for WindowDescriptor {
    type Error = WireError;

    fn try_from(value: wire::WindowDescriptor) -> Result<Self, Self::Error> {
        Ok(Self {
            id: required_id(value.id, "window.id")?,
            family_id: required_id(value.family_id, "window.family_id")?,
            source_device: required_id(value.source_device, "window.source_device")?,
            role: window_role_from_wire(value.role)?,
            bounds_dip: rect_from_wire(
                value
                    .bounds_dip
                    .ok_or(WireError::MissingField("window.bounds_dip"))?,
            )?,
            min_size_dip: size_from_wire(
                value
                    .min_size_dip
                    .ok_or(WireError::MissingField("window.min_size_dip"))?,
            ),
            max_size_dip: value.max_size_dip.map(size_from_wire),
            has_alpha: value.has_alpha,
            blur_radius_dip: value.blur_radius_dip,
        })
    }
}

impl TryFrom<wire::GeometryEpoch> for GeometryEpoch {
    type Error = WireError;

    fn try_from(value: wire::GeometryEpoch) -> Result<Self, Self::Error> {
        Ok(Self {
            window_id: required_id(value.window_id, "geometry.window_id")?,
            epoch: value.epoch,
            phase: geometry_phase_from_wire(value.phase)?,
            bounds_dip: rect_from_wire(
                value
                    .bounds_dip
                    .ok_or(WireError::MissingField("geometry.bounds_dip"))?,
            )?,
        })
    }
}

impl TryFrom<wire::FramePlaneReady> for FramePlaneReady {
    type Error = WireError;

    fn try_from(value: wire::FramePlaneReady) -> Result<Self, Self::Error> {
        Ok(Self {
            window_id: required_id(value.window_id, "frame.window_id")?,
            frame_id: value.frame_id,
            geometry_epoch: value.geometry_epoch,
            plane: frame_plane_from_wire(value.plane)?,
            source_submitted_ns: value.source_submitted_ns,
            received_ns: value.received_ns,
        })
    }
}

impl TryFrom<wire::InputLease> for InputLease {
    type Error = WireError;

    fn try_from(value: wire::InputLease) -> Result<Self, Self::Error> {
        Ok(Self {
            generation: value.generation,
            owner: required_id(value.owner, "input_lease.owner")?,
            route_to: required_id(value.route_to, "input_lease.route_to")?,
            state: input_lease_state_from_wire(value.state)?,
        })
    }
}

impl TryFrom<wire::RelativePointerMotion> for RelativePointerMotion {
    type Error = WireError;

    fn try_from(value: wire::RelativePointerMotion) -> Result<Self, Self::Error> {
        Ok(Self {
            delta_x_dip: finite(value.delta_x_dip, "pointer_motion.delta_x_dip")?,
            delta_y_dip: finite(value.delta_y_dip, "pointer_motion.delta_y_dip")?,
        })
    }
}

impl TryFrom<wire::PointerButtonEvent> for PointerButtonEvent {
    type Error = WireError;

    fn try_from(value: wire::PointerButtonEvent) -> Result<Self, Self::Error> {
        Ok(Self {
            button: pointer_button_from_wire(value.button)?,
            state: input_switch_state_from_wire(value.state, "pointer_button.state")?,
        })
    }
}

impl TryFrom<wire::PointerWheelEvent> for PointerWheelEvent {
    type Error = WireError;

    fn try_from(value: wire::PointerWheelEvent) -> Result<Self, Self::Error> {
        Ok(Self {
            vertical_delta_detents: finite(
                value.vertical_delta_detents,
                "pointer_wheel.vertical_delta_detents",
            )?,
            horizontal_delta_detents: finite(
                value.horizontal_delta_detents,
                "pointer_wheel.horizontal_delta_detents",
            )?,
        })
    }
}

impl TryFrom<wire::KeyboardHidUsage> for KeyboardHidUsage {
    type Error = WireError;

    fn try_from(value: wire::KeyboardHidUsage) -> Result<Self, Self::Error> {
        let state = input_switch_state_from_wire(value.state, "keyboard_hid_usage.state")?;
        if value.repeat && state != InputSwitchState::Pressed {
            return Err(WireError::InvalidField("keyboard_hid_usage.repeat"));
        }
        Ok(Self {
            usage_page: hid_usage_component(value.usage_page, "keyboard_hid_usage.usage_page")?,
            usage_id: hid_usage_component(value.usage_id, "keyboard_hid_usage.usage_id")?,
            state,
            repeat: value.repeat,
        })
    }
}

impl TryFrom<wire::InputEvent> for InputEvent {
    type Error = WireError;

    fn try_from(value: wire::InputEvent) -> Result<Self, Self::Error> {
        let event = match value
            .event
            .ok_or(WireError::MissingField("input_event.event"))?
        {
            wire::input_event::Event::PointerMotion(value) => {
                InputEventKind::PointerMotion(value.try_into()?)
            }
            wire::input_event::Event::PointerButton(value) => {
                InputEventKind::PointerButton(value.try_into()?)
            }
            wire::input_event::Event::PointerWheel(value) => {
                InputEventKind::PointerWheel(value.try_into()?)
            }
            wire::input_event::Event::KeyboardHidUsage(value) => {
                InputEventKind::KeyboardHidUsage(value.try_into()?)
            }
            wire::input_event::Event::Touchpad(value) => {
                InputEventKind::Touchpad(value.try_into()?)
            }
            wire::input_event::Event::ReleaseAll(_) => InputEventKind::ReleaseAll,
            wire::input_event::Event::DesktopPointerPosition(value) => {
                if value.x_millidip.unsigned_abs() > 1_000_000_000
                    || value.y_millidip.unsigned_abs() > 1_000_000_000
                {
                    return Err(WireError::InvalidField("desktop_pointer_position"));
                }
                InputEventKind::DesktopPointerPosition(DesktopPointerPosition {
                    x_millidip: value.x_millidip,
                    y_millidip: value.y_millidip,
                })
            }
        };
        Ok(Self {
            lease_generation: nonzero(value.lease_generation, "input_event.lease_generation")?,
            target_device: required_id(value.target_device, "input_event.target_device")?,
            sequence: nonzero(value.event_sequence, "input_event.event_sequence")?,
            sender_not_after_ns: if value.sender_not_after_ns == 0
                && !matches!(event, InputEventKind::ReleaseAll)
            {
                return Err(WireError::InvalidField("input_event.sender_not_after_ns"));
            } else {
                value.sender_not_after_ns
            },
            event,
        })
    }
}

impl TryFrom<wire::InputAppliedAck> for InputAppliedAck {
    type Error = WireError;

    fn try_from(value: wire::InputAppliedAck) -> Result<Self, Self::Error> {
        Ok(Self {
            lease_generation: nonzero(
                value.lease_generation,
                "input_applied_ack.lease_generation",
            )?,
            target_device: required_id(value.target_device, "input_applied_ack.target_device")?,
            event_sequence: nonzero(value.event_sequence, "input_applied_ack.event_sequence")?,
            result: input_applied_result_from_wire(value.result)?,
        })
    }
}

impl TryFrom<wire::InputLeaseRevoke> for InputLeaseRevoke {
    type Error = WireError;

    fn try_from(value: wire::InputLeaseRevoke) -> Result<Self, Self::Error> {
        let state = input_lease_state_from_wire(value.state)?;
        if state != InputLeaseState::Revoked {
            return Err(WireError::InvalidField("input_lease_revoke.state"));
        }
        Ok(Self {
            operation_id: required_id(value.operation_id, "input_lease_revoke.operation_id")?,
            lease_generation: nonzero(
                value.lease_generation,
                "input_lease_revoke.lease_generation",
            )?,
            owner_device: required_id(value.owner_device, "input_lease_revoke.owner_device")?,
            target_device: required_id(value.target_device, "input_lease_revoke.target_device")?,
            state,
        })
    }
}

impl TryFrom<wire::InputLeaseRevokedAck> for InputLeaseRevokedAck {
    type Error = WireError;

    fn try_from(value: wire::InputLeaseRevokedAck) -> Result<Self, Self::Error> {
        Ok(Self {
            operation_id: required_id(value.operation_id, "input_lease_revoked_ack.operation_id")?,
            lease_generation: nonzero(
                value.lease_generation,
                "input_lease_revoked_ack.lease_generation",
            )?,
            owner_device: required_id(value.owner_device, "input_lease_revoked_ack.owner_device")?,
            target_device: required_id(
                value.target_device,
                "input_lease_revoked_ack.target_device",
            )?,
            state: {
                let state = input_lease_state_from_wire(value.state)?;
                if state != InputLeaseState::Revoked {
                    return Err(WireError::InvalidField("input_lease_revoked_ack.state"));
                }
                state
            },
            result: input_lease_revoked_result_from_wire(value.result)?,
        })
    }
}

impl TryFrom<wire::ClipboardOffer> for ClipboardOffer {
    type Error = WireError;

    fn try_from(value: wire::ClipboardOffer) -> Result<Self, Self::Error> {
        Ok(Self {
            id: required_id(value.id, "clipboard_offer.id")?,
            owner: required_id(value.owner, "clipboard_offer.owner")?,
            generation: value.generation,
            flavors: value
                .flavors
                .into_iter()
                .map(|flavor| ClipboardFlavor {
                    name: flavor.mime_type,
                    size_bytes: flavor.size_bytes,
                })
                .collect(),
        })
    }
}

impl From<ClipboardOffer> for wire::ClipboardOffer {
    fn from(value: ClipboardOffer) -> Self {
        Self {
            id: Some(id_to_wire(value.id)),
            owner: Some(id_to_wire(value.owner)),
            flavors: value
                .flavors
                .into_iter()
                .map(|flavor| wire::ClipboardFlavor {
                    mime_type: flavor.name,
                    size_bytes: flavor.size_bytes,
                })
                .collect(),
            generation: value.generation,
        }
    }
}

impl ClipboardTransferOffer {
    /// Validates the explicit transfer binding independently of any local
    /// consent UI. In particular, every discovery flavor must have exactly one
    /// digest-bound transfer flavor with the same MIME type and byte count.
    ///
    /// # Errors
    ///
    /// Returns [`WireError`] when identifiers, fixed-width bindings, sequences,
    /// MIME names, duplicate flavors, or advertised flavor correspondence are
    /// invalid.
    pub fn validate(&self) -> Result<(), WireError> {
        if self.offer.id.0 == 0 {
            return Err(WireError::InvalidField("clipboard_transfer_offer.offer.id"));
        }
        if self.offer.owner.0 == 0 {
            return Err(WireError::InvalidField(
                "clipboard_transfer_offer.offer.owner",
            ));
        }
        if self.offer.generation == 0 {
            return Err(WireError::InvalidField(
                "clipboard_transfer_offer.offer.generation",
            ));
        }
        if self.offer_nonce == [0; 16] {
            return Err(WireError::InvalidField(
                "clipboard_transfer_offer.offer_nonce",
            ));
        }
        if self.consent_correlation == [0; 16] {
            return Err(WireError::InvalidField(
                "clipboard_transfer_offer.consent_correlation",
            ));
        }
        if self.connection_binding == [0; 32] {
            return Err(WireError::InvalidField(
                "clipboard_transfer_offer.connection_binding",
            ));
        }
        if self.payload_sequence == 0 {
            return Err(WireError::InvalidField(
                "clipboard_transfer_offer.payload_sequence",
            ));
        }

        let mut advertised = std::collections::BTreeMap::new();
        for flavor in &self.offer.flavors {
            if flavor.name.is_empty()
                || advertised
                    .insert(flavor.name.as_str(), flavor.size_bytes)
                    .is_some()
            {
                return Err(WireError::InvalidField(
                    "clipboard_transfer_offer.offer.flavors",
                ));
            }
        }
        if advertised.is_empty() || advertised.len() != self.flavors.len() {
            return Err(WireError::InvalidField("clipboard_transfer_offer.flavors"));
        }
        let mut digested = std::collections::BTreeSet::new();
        for flavor in &self.flavors {
            if flavor.name.is_empty()
                || !digested.insert(flavor.name.as_str())
                || advertised.get(flavor.name.as_str()) != Some(&flavor.size_bytes)
            {
                return Err(WireError::InvalidField("clipboard_transfer_offer.flavors"));
            }
        }
        Ok(())
    }
}

impl TryFrom<wire::ClipboardTransferOffer> for ClipboardTransferOffer {
    type Error = WireError;

    fn try_from(value: wire::ClipboardTransferOffer) -> Result<Self, Self::Error> {
        let transfer = Self {
            offer: value
                .offer
                .ok_or(WireError::MissingField("clipboard_transfer_offer.offer"))?
                .try_into()?,
            flavors: value
                .flavors
                .into_iter()
                .map(|flavor| {
                    Ok(ClipboardTransferFlavor {
                        name: flavor.mime_type,
                        size_bytes: flavor.size_bytes,
                        sha256: sha256_from_wire(
                            flavor.sha256,
                            "clipboard_transfer_flavor.sha256",
                        )?,
                    })
                })
                .collect::<Result<_, WireError>>()?,
            offer_nonce: bytes16_from_wire(
                value.offer_nonce,
                "clipboard_transfer_offer.offer_nonce",
            )?,
            consent_correlation: bytes16_from_wire(
                value.consent_correlation,
                "clipboard_transfer_offer.consent_correlation",
            )?,
            connection_binding: sha256_from_wire(
                value.connection_binding,
                "clipboard_transfer_offer.connection_binding",
            )?,
            payload_sequence: nonzero(
                value.payload_sequence,
                "clipboard_transfer_offer.payload_sequence",
            )?,
        };
        transfer.validate()?;
        Ok(transfer)
    }
}

impl From<ClipboardTransferOffer> for wire::ClipboardTransferOffer {
    fn from(value: ClipboardTransferOffer) -> Self {
        Self {
            offer: Some(value.offer.into()),
            flavors: value
                .flavors
                .into_iter()
                .map(|flavor| wire::ClipboardTransferFlavor {
                    mime_type: flavor.name,
                    size_bytes: flavor.size_bytes,
                    sha256: flavor.sha256.to_vec(),
                })
                .collect(),
            offer_nonce: value.offer_nonce.to_vec(),
            consent_correlation: value.consent_correlation.to_vec(),
            connection_binding: value.connection_binding.to_vec(),
            payload_sequence: value.payload_sequence,
        }
    }
}

impl TryFrom<wire::ClipboardAccept> for ClipboardAccept {
    type Error = WireError;

    fn try_from(value: wire::ClipboardAccept) -> Result<Self, Self::Error> {
        let result = Self {
            offer_id: required_id(value.offer_id, "clipboard_accept.offer_id")?,
            generation: nonzero(value.generation, "clipboard_accept.generation")?,
            offer_nonce: bytes16_from_wire(value.offer_nonce, "clipboard_accept.offer_nonce")?,
            mime_type: value.mime_type,
            payload_sequence: nonzero(value.payload_sequence, "clipboard_accept.payload_sequence")?,
        };
        if result.offer_id.0 == 0 || result.offer_nonce == [0; 16] || result.mime_type.is_empty() {
            return Err(WireError::InvalidField("clipboard_accept"));
        }
        Ok(result)
    }
}

impl From<ClipboardAccept> for wire::ClipboardAccept {
    fn from(value: ClipboardAccept) -> Self {
        Self {
            offer_id: Some(id_to_wire(value.offer_id)),
            generation: value.generation,
            offer_nonce: value.offer_nonce.to_vec(),
            mime_type: value.mime_type,
            payload_sequence: value.payload_sequence,
        }
    }
}

impl TryFrom<wire::ClipboardPayload> for ClipboardPayload {
    type Error = WireError;

    fn try_from(value: wire::ClipboardPayload) -> Result<Self, Self::Error> {
        let result = Self {
            offer_id: required_id(value.offer_id, "clipboard_payload.offer_id")?,
            generation: nonzero(value.generation, "clipboard_payload.generation")?,
            offer_nonce: bytes16_from_wire(value.offer_nonce, "clipboard_payload.offer_nonce")?,
            payload_sequence: nonzero(
                value.payload_sequence,
                "clipboard_payload.payload_sequence",
            )?,
            mime_type: value.mime_type,
            data: value.data,
        };
        if result.offer_id.0 == 0 || result.offer_nonce == [0; 16] || result.mime_type.is_empty() {
            return Err(WireError::InvalidField("clipboard_payload"));
        }
        Ok(result)
    }
}

impl From<ClipboardPayload> for wire::ClipboardPayload {
    fn from(value: ClipboardPayload) -> Self {
        Self {
            offer_id: Some(id_to_wire(value.offer_id)),
            generation: value.generation,
            offer_nonce: value.offer_nonce.to_vec(),
            payload_sequence: value.payload_sequence,
            mime_type: value.mime_type,
            data: value.data,
        }
    }
}

impl TryFrom<wire::ClipboardComplete> for ClipboardComplete {
    type Error = WireError;

    fn try_from(value: wire::ClipboardComplete) -> Result<Self, Self::Error> {
        let result = Self {
            offer_id: required_id(value.offer_id, "clipboard_complete.offer_id")?,
            generation: nonzero(value.generation, "clipboard_complete.generation")?,
            offer_nonce: bytes16_from_wire(value.offer_nonce, "clipboard_complete.offer_nonce")?,
            payload_sequence: nonzero(
                value.payload_sequence,
                "clipboard_complete.payload_sequence",
            )?,
            status: clipboard_completion_from_wire(value.status)?,
            error_message: value.error_message,
        };
        if result.offer_id.0 == 0 || result.offer_nonce == [0; 16] {
            return Err(WireError::InvalidField("clipboard_complete"));
        }
        Ok(result)
    }
}

impl From<ClipboardComplete> for wire::ClipboardComplete {
    fn from(value: ClipboardComplete) -> Self {
        let status = match value.status {
            ClipboardCompletionStatus::Completed => wire::ClipboardCompletionStatus::Completed,
            ClipboardCompletionStatus::Cancelled => wire::ClipboardCompletionStatus::Cancelled,
            ClipboardCompletionStatus::Rejected => wire::ClipboardCompletionStatus::Rejected,
            ClipboardCompletionStatus::Failed => wire::ClipboardCompletionStatus::Failed,
        };
        Self {
            offer_id: Some(id_to_wire(value.offer_id)),
            generation: value.generation,
            offer_nonce: value.offer_nonce.to_vec(),
            payload_sequence: value.payload_sequence,
            status: status.into(),
            error_message: value.error_message,
        }
    }
}

impl TryFrom<wire::FileDragItem> for DragItem {
    type Error = WireError;

    fn try_from(value: wire::FileDragItem) -> Result<Self, Self::Error> {
        let content_hash = value
            .content_sha256
            .map(|digest| sha256_from_wire(digest, "file_drag_item.content_sha256"))
            .transpose()?;
        Ok(Self {
            relative_path: value.relative_path,
            size_bytes: value.size_bytes,
            content_hash,
        })
    }
}

impl TryFrom<wire::FileDragOffer> for DragOffer {
    type Error = WireError;

    fn try_from(value: wire::FileDragOffer) -> Result<Self, Self::Error> {
        Ok(Self {
            id: required_id(value.id, "file_drag_offer.id")?,
            generation: value.generation,
            source_device: required_id(value.source_device, "file_drag_offer.source_device")?,
            target_device: required_id(value.target_device, "file_drag_offer.target_device")?,
            operation: drag_operation_from_wire(value.operation, "file_drag_offer.operation")?,
            items: value
                .items
                .into_iter()
                .map(DragItem::try_from)
                .collect::<Result<_, _>>()?,
        })
    }
}

impl TryFrom<wire::FileDragAccept> for DragAccept {
    type Error = WireError;

    fn try_from(value: wire::FileDragAccept) -> Result<Self, Self::Error> {
        Ok(Self {
            offer_id: required_id(value.offer_id, "file_drag_accept.offer_id")?,
            generation: value.generation,
            operation: drag_operation_from_wire(value.operation, "file_drag_accept.operation")?,
            destination_token: value.destination_token,
        })
    }
}

impl TryFrom<wire::FileDragProgress> for DragProgress {
    type Error = WireError;

    fn try_from(value: wire::FileDragProgress) -> Result<Self, Self::Error> {
        let chunk_hash = value
            .chunk_sha256
            .map(|digest| sha256_from_wire(digest, "file_drag_progress.chunk_sha256"))
            .transpose()?;
        Ok(Self {
            offer_id: required_id(value.offer_id, "file_drag_progress.offer_id")?,
            generation: value.generation,
            bytes_transferred: value.bytes_transferred,
            total_bytes: value.total_bytes,
            item_index: value.item_index,
            offset_bytes: value.offset_bytes,
            chunk_size_bytes: value.chunk_size_bytes,
            chunk_hash,
        })
    }
}

impl TryFrom<wire::FileDragItemResult> for DragItemResult {
    type Error = WireError;

    fn try_from(value: wire::FileDragItemResult) -> Result<Self, Self::Error> {
        let content_hash = value
            .content_sha256
            .map(|digest| sha256_from_wire(digest, "file_drag_item_result.content_sha256"))
            .transpose()?;
        Ok(Self {
            item_index: value.item_index,
            bytes_received: value.bytes_received,
            content_hash,
        })
    }
}

impl TryFrom<wire::FileDragComplete> for DragComplete {
    type Error = WireError;

    fn try_from(value: wire::FileDragComplete) -> Result<Self, Self::Error> {
        Ok(Self {
            offer_id: required_id(value.offer_id, "file_drag_complete.offer_id")?,
            generation: value.generation,
            status: drag_completion_from_wire(value.status)?,
            error_message: value.error_message,
            item_results: value
                .item_results
                .into_iter()
                .map(DragItemResult::try_from)
                .collect::<Result<_, _>>()?,
        })
    }
}

impl TryFrom<wire::ApplicationAudioRoute> for AudioRoute {
    type Error = WireError;

    fn try_from(value: wire::ApplicationAudioRoute) -> Result<Self, Self::Error> {
        Ok(Self {
            generation: value.generation,
            family_id: required_id(value.family_id, "application_audio_route.family_id")?,
            source_device: required_id(
                value.source_device,
                "application_audio_route.source_device",
            )?,
            target_device: required_id(
                value.target_device,
                "application_audio_route.target_device",
            )?,
            target_output_id: value.target_output_id,
            enabled: value.enabled,
        })
    }
}

impl TryFrom<wire::HidDeviceOffer> for HidDeviceOffer {
    type Error = WireError;

    fn try_from(value: wire::HidDeviceOffer) -> Result<Self, Self::Error> {
        Ok(Self {
            id: required_id(value.id, "hid_device_offer.id")?,
            owner: required_id(value.owner, "hid_device_offer.owner")?,
            vendor_id: u16::try_from(value.vendor_id)
                .map_err(|_| WireError::InvalidField("hid_device_offer.vendor_id"))?,
            product_id: u16::try_from(value.product_id)
                .map_err(|_| WireError::InvalidField("hid_device_offer.product_id"))?,
            interface_count: u8::try_from(value.interface_count)
                .map_err(|_| WireError::InvalidField("hid_device_offer.interface_count"))?,
        })
    }
}

impl TryFrom<wire::HidDeviceLease> for HidDeviceLease {
    type Error = WireError;

    fn try_from(value: wire::HidDeviceLease) -> Result<Self, Self::Error> {
        Ok(Self {
            generation: value.generation,
            device_id: required_id(value.device_id, "hid_device_lease.device_id")?,
            owner: required_id(value.owner, "hid_device_lease.owner")?,
            route_to: required_id(value.route_to, "hid_device_lease.route_to")?,
            state: hid_lease_state_from_wire(value.state)?,
        })
    }
}

impl From<wire::ClockSyncProbe> for ClockSyncProbe {
    fn from(value: wire::ClockSyncProbe) -> Self {
        Self {
            probe_id: value.probe_id,
            t0_send_ns: value.t0_send_ns,
        }
    }
}

impl From<wire::ClockSyncReply> for ClockSyncReply {
    fn from(value: wire::ClockSyncReply) -> Self {
        Self {
            probe_id: value.probe_id,
            t0_send_ns: value.t0_send_ns,
            t1_receive_ns: value.t1_receive_ns,
            t2_send_ns: value.t2_send_ns,
        }
    }
}

impl TryFrom<wire::ControlEnvelope> for DomainControl {
    type Error = WireError;

    #[allow(clippy::too_many_lines)] // One exhaustive protobuf oneof decoder keeps additions explicit.
    fn try_from(value: wire::ControlEnvelope) -> Result<Self, Self::Error> {
        if value.protocol_major != u32::from(PROTOCOL_VERSION.major)
            || value.protocol_minor < u32::from(MIN_COMPATIBLE_PROTOCOL_MINOR)
        {
            return Err(WireError::IncompatibleVersion);
        }
        match value.payload.ok_or(WireError::MissingPayload)? {
            wire::control_envelope::Payload::AtlasWindowSelectionAccepted(value) => {
                Ok(Self::AtlasWindowSelectionAccepted(value.try_into()?))
            }
            wire::control_envelope::Payload::AtlasWindowSelectionRejected(value) => {
                Ok(Self::AtlasWindowSelectionRejected(value.try_into()?))
            }
            wire::control_envelope::Payload::AtlasWindowSelection(value) => {
                Ok(Self::AtlasWindowSelection(value.try_into()?))
            }
            wire::control_envelope::Payload::Topology(value) => {
                Ok(Self::Topology(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowInputRelease(value) => {
                Ok(Self::WindowInputRelease(required_id(
                    value.window_id,
                    "window_input_release.window_id",
                )?))
            }
            wire::control_envelope::Payload::ApplicationIcon(value) => {
                Ok(Self::ApplicationIcon(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowDescriptor(value) => {
                Ok(Self::RegisterWindow(value.try_into()?))
            }
            wire::control_envelope::Payload::Geometry(value) => {
                Ok(Self::Geometry(value.try_into()?))
            }
            wire::control_envelope::Payload::FramePlaneReady(value) => {
                Ok(Self::FramePlane(value.try_into()?))
            }
            wire::control_envelope::Payload::AtlasFrame(value) => {
                Ok(Self::AtlasFrame(value.try_into()?))
            }
            wire::control_envelope::Payload::DesktopWindowMove(value) => {
                Ok(Self::DesktopWindowMove(value.try_into()?))
            }
            wire::control_envelope::Payload::DesktopWindowMoveAck(value) => {
                Ok(Self::DesktopWindowMoveAck(value.try_into()?))
            }
            wire::control_envelope::Payload::InputLease(value) => {
                Ok(Self::InputLease(value.try_into()?))
            }
            wire::control_envelope::Payload::InputLeaseRevoke(value) => {
                Ok(Self::InputLeaseRevoke(value.try_into()?))
            }
            wire::control_envelope::Payload::InputEvent(value) => {
                Ok(Self::InputEvent(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowPointerMotion(value) => {
                Ok(Self::WindowPointerMotion(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowPointerButton(value) => {
                Ok(Self::WindowPointerButton(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowPointerWheel(value) => {
                Ok(Self::WindowPointerWheel(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowKeyboardEvent(value) => {
                Ok(Self::WindowKeyboardEvent(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowKeyboardAck(value) => {
                Ok(Self::WindowKeyboardAck(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowKeyboardAuthorization(value) => {
                Ok(Self::WindowKeyboardAuthorization(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowPointerAck(value) => {
                Ok(Self::WindowPointerAck(value.try_into()?))
            }
            wire::control_envelope::Payload::WindowPointerAuthorization(value) => {
                Ok(Self::WindowPointerAuthorization(value.try_into()?))
            }
            wire::control_envelope::Payload::InputAppliedAck(value) => {
                Ok(Self::InputAppliedAck(value.try_into()?))
            }
            wire::control_envelope::Payload::InputLeaseRevokedAck(value) => {
                Ok(Self::InputLeaseRevokedAck(value.try_into()?))
            }
            wire::control_envelope::Payload::ClipboardOffer(value) => {
                Ok(Self::ClipboardOffer(value.try_into()?))
            }
            wire::control_envelope::Payload::ClipboardTransferOffer(value) => {
                Ok(Self::ClipboardTransferOffer(value.try_into()?))
            }
            wire::control_envelope::Payload::ClipboardAccept(value) => {
                Ok(Self::ClipboardAccept(value.try_into()?))
            }
            wire::control_envelope::Payload::ClipboardPayload(value) => {
                Ok(Self::ClipboardPayload(value.try_into()?))
            }
            wire::control_envelope::Payload::ClipboardComplete(value) => {
                Ok(Self::ClipboardComplete(value.try_into()?))
            }
            wire::control_envelope::Payload::FileDragOffer(value) => {
                Ok(Self::FileDragOffer(value.try_into()?))
            }
            wire::control_envelope::Payload::FileDragAccept(value) => {
                Ok(Self::FileDragAccept(value.try_into()?))
            }
            wire::control_envelope::Payload::FileDragProgress(value) => {
                Ok(Self::FileDragProgress(value.try_into()?))
            }
            wire::control_envelope::Payload::FileDragComplete(value) => {
                Ok(Self::FileDragComplete(value.try_into()?))
            }
            wire::control_envelope::Payload::ApplicationAudioRoute(value) => {
                Ok(Self::AudioRoute(value.try_into()?))
            }
            wire::control_envelope::Payload::HidDeviceOffer(value) => {
                Ok(Self::HidDeviceOffer(value.try_into()?))
            }
            wire::control_envelope::Payload::HidDeviceLease(value) => {
                Ok(Self::HidDeviceLease(value.try_into()?))
            }
            wire::control_envelope::Payload::ClockSyncProbe(value) => {
                Ok(Self::ClockSyncProbe(value.into()))
            }
            wire::control_envelope::Payload::ClockSyncReply(value) => {
                Ok(Self::ClockSyncReply(value.into()))
            }
        }
    }
}

#[cfg(test)]
mod wire_tests {
    use prost::Message;

    use super::{
        AudioRoute, ClipboardAccept, ClipboardComplete, ClipboardCompletionStatus, ClipboardFlavor,
        ClipboardOffer, ClipboardPayload, ClipboardTransferFlavor, ClipboardTransferOffer,
        ClockSyncProbe, ClockSyncReply, DomainControl, DragAccept, DragComplete,
        DragCompletionStatus, DragItem, DragItemResult, DragOffer, DragOperation, DragProgress,
        HidDeviceLease, HidDeviceOffer, HidLeaseState, Id128, InputAppliedAck, InputAppliedResult,
        InputEvent, InputEventKind, InputLeaseRevoke, InputLeaseRevokedAck,
        InputLeaseRevokedResult, InputLeaseState, InputSwitchState, KeyboardHidUsage,
        PROTOCOL_VERSION, PointerButton, PointerButtonEvent, PointerWheelEvent, ProtocolVersion,
        RelativePointerMotion, WireError, wire,
    };

    fn id(seed: u64) -> wire::Id128 {
        wire::Id128 { high: 0, low: seed }
    }

    fn envelope(payload: wire::control_envelope::Payload) -> wire::ControlEnvelope {
        wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence: 1,
            payload: Some(payload),
        }
    }

    fn convert(payload: wire::control_envelope::Payload) -> Result<DomainControl, WireError> {
        DomainControl::try_from(envelope(payload))
    }

    fn input_payload(event: wire::input_event::Event) -> wire::control_envelope::Payload {
        wire::control_envelope::Payload::InputEvent(wire::InputEvent {
            lease_generation: 9,
            target_device: Some(id(7)),
            event_sequence: 12,
            sender_not_after_ns: 100,
            event: Some(event),
        })
    }

    #[test]
    fn control_envelope_round_trips_unknown_field_safe_protobuf() {
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence: 42,
            payload: Some(wire::control_envelope::Payload::InputLease(
                wire::InputLease {
                    generation: 7,
                    owner: Some(wire::Id128 { high: 1, low: 2 }),
                    route_to: Some(wire::Id128 { high: 3, low: 4 }),
                    state: wire::InputLeaseState::Active.into(),
                },
            )),
        };
        let bytes = envelope.encode_to_vec();
        let decoded = wire::ControlEnvelope::decode(bytes.as_slice()).unwrap();
        assert_eq!(decoded, envelope);
    }

    #[test]
    fn pointer_input_events_convert_to_domain() {
        let cases = [
            (
                wire::input_event::Event::DesktopPointerPosition(wire::DesktopPointerPosition {
                    x_millidip: -1_280_000,
                    y_millidip: 50_000,
                }),
                InputEventKind::DesktopPointerPosition(super::DesktopPointerPosition {
                    x_millidip: -1_280_000,
                    y_millidip: 50_000,
                }),
            ),
            (
                wire::input_event::Event::PointerMotion(wire::RelativePointerMotion {
                    delta_x_dip: 4.5,
                    delta_y_dip: -2.25,
                }),
                InputEventKind::PointerMotion(RelativePointerMotion {
                    delta_x_dip: 4.5,
                    delta_y_dip: -2.25,
                }),
            ),
            (
                wire::input_event::Event::PointerButton(wire::PointerButtonEvent {
                    button: wire::PointerButton::Back.into(),
                    state: wire::InputSwitchState::Pressed.into(),
                }),
                InputEventKind::PointerButton(PointerButtonEvent {
                    button: PointerButton::Back,
                    state: InputSwitchState::Pressed,
                }),
            ),
            (
                wire::input_event::Event::PointerWheel(wire::PointerWheelEvent {
                    vertical_delta_detents: -1.0,
                    horizontal_delta_detents: 0.25,
                }),
                InputEventKind::PointerWheel(PointerWheelEvent {
                    vertical_delta_detents: -1.0,
                    horizontal_delta_detents: 0.25,
                }),
            ),
        ];
        for (wire_event, domain_event) in cases {
            assert_eq!(
                convert(input_payload(wire_event)),
                Ok(DomainControl::InputEvent(InputEvent {
                    lease_generation: 9,
                    target_device: Id128(7),
                    sequence: 12,
                    sender_not_after_ns: 100,
                    event: domain_event,
                }))
            );
        }
    }

    #[test]
    fn keyboard_and_release_all_input_events_convert_to_domain() {
        let keyboard = wire::input_event::Event::KeyboardHidUsage(wire::KeyboardHidUsage {
            usage_page: 0x07,
            usage_id: 0x04,
            state: wire::InputSwitchState::Pressed.into(),
            repeat: true,
        });
        assert_eq!(
            convert(input_payload(keyboard)),
            Ok(DomainControl::InputEvent(InputEvent {
                lease_generation: 9,
                target_device: Id128(7),
                sequence: 12,
                sender_not_after_ns: 100,
                event: InputEventKind::KeyboardHidUsage(KeyboardHidUsage {
                    usage_page: 0x07,
                    usage_id: 0x04,
                    state: InputSwitchState::Pressed,
                    repeat: true,
                }),
            }))
        );

        let release_all = wire::input_event::Event::ReleaseAll(wire::ReleaseAllInput {});
        assert_eq!(
            convert(input_payload(release_all)),
            Ok(DomainControl::InputEvent(InputEvent {
                lease_generation: 9,
                target_device: Id128(7),
                sequence: 12,
                sender_not_after_ns: 100,
                event: InputEventKind::ReleaseAll,
            }))
        );
    }

    #[test]
    fn input_applied_ack_preserves_complete_event_identity_and_result() {
        let payload = wire::control_envelope::Payload::InputAppliedAck(wire::InputAppliedAck {
            lease_generation: 9,
            target_device: Some(id(7)),
            event_sequence: 12,
            result: wire::InputAppliedResult::InjectionFailed.into(),
        });
        assert_eq!(
            convert(payload),
            Ok(DomainControl::InputAppliedAck(InputAppliedAck {
                lease_generation: 9,
                target_device: Id128(7),
                event_sequence: 12,
                result: InputAppliedResult::InjectionFailed,
            }))
        );

        let invalid = wire::control_envelope::Payload::InputAppliedAck(wire::InputAppliedAck {
            lease_generation: 9,
            target_device: Some(id(7)),
            event_sequence: 12,
            result: wire::InputAppliedResult::Unspecified.into(),
        });
        assert_eq!(
            convert(invalid),
            Err(WireError::UnknownEnum("input_applied_ack.result"))
        );

        for result in [
            InputAppliedResult::RejectedExpired,
            InputAppliedResult::RejectedClockUnsynchronized,
        ] {
            let payload = wire::control_envelope::Payload::InputAppliedAck(wire::InputAppliedAck {
                lease_generation: 9,
                target_device: Some(id(7)),
                event_sequence: 12,
                result: i32::from(wire::InputAppliedResult::from(result)),
            });
            assert_eq!(
                convert(payload),
                Ok(DomainControl::InputAppliedAck(InputAppliedAck {
                    lease_generation: 9,
                    target_device: Id128(7),
                    event_sequence: 12,
                    result,
                }))
            );
        }
    }

    #[test]
    fn lease_revoke_and_applied_ack_preserve_exact_identity() {
        let revoke = wire::InputLeaseRevoke {
            operation_id: Some(id(11)),
            lease_generation: 9,
            owner_device: Some(id(1)),
            target_device: Some(id(2)),
            state: wire::InputLeaseState::Revoked.into(),
        };
        let revoke_envelope = envelope(wire::control_envelope::Payload::InputLeaseRevoke(revoke));
        let encoded = revoke_envelope.encode_to_vec();
        assert_eq!(
            wire::ControlEnvelope::decode(encoded.as_slice()).unwrap(),
            revoke_envelope
        );
        assert_eq!(
            convert(wire::control_envelope::Payload::InputLeaseRevoke(revoke,)),
            Ok(DomainControl::InputLeaseRevoke(InputLeaseRevoke {
                operation_id: Id128(11),
                lease_generation: 9,
                owner_device: Id128(1),
                target_device: Id128(2),
                state: InputLeaseState::Revoked,
            }))
        );

        let ack = wire::InputLeaseRevokedAck {
            operation_id: Some(id(11)),
            lease_generation: 9,
            owner_device: Some(id(1)),
            target_device: Some(id(2)),
            state: wire::InputLeaseState::Revoked.into(),
            result: wire::InputLeaseRevokedResult::Applied.into(),
        };
        let ack_envelope = envelope(wire::control_envelope::Payload::InputLeaseRevokedAck(ack));
        let encoded = ack_envelope.encode_to_vec();
        assert_eq!(
            wire::ControlEnvelope::decode(encoded.as_slice()).unwrap(),
            ack_envelope
        );
        assert_eq!(
            convert(wire::control_envelope::Payload::InputLeaseRevokedAck(ack,)),
            Ok(DomainControl::InputLeaseRevokedAck(InputLeaseRevokedAck {
                operation_id: Id128(11),
                lease_generation: 9,
                owner_device: Id128(1),
                target_device: Id128(2),
                state: InputLeaseState::Revoked,
                result: InputLeaseRevokedResult::Applied,
            }))
        );
    }

    #[test]
    fn lease_revoke_rejects_missing_identity_wrong_state_and_unspecified_result() {
        let valid_revoke = wire::InputLeaseRevoke {
            operation_id: Some(id(11)),
            lease_generation: 9,
            owner_device: Some(id(1)),
            target_device: Some(id(2)),
            state: wire::InputLeaseState::Revoked.into(),
        };
        for (revoke, expected) in [
            (
                wire::InputLeaseRevoke {
                    operation_id: None,
                    ..valid_revoke
                },
                WireError::MissingField("input_lease_revoke.operation_id"),
            ),
            (
                wire::InputLeaseRevoke {
                    owner_device: None,
                    ..valid_revoke
                },
                WireError::MissingField("input_lease_revoke.owner_device"),
            ),
            (
                wire::InputLeaseRevoke {
                    target_device: None,
                    ..valid_revoke
                },
                WireError::MissingField("input_lease_revoke.target_device"),
            ),
            (
                wire::InputLeaseRevoke {
                    state: wire::InputLeaseState::Active.into(),
                    ..valid_revoke
                },
                WireError::InvalidField("input_lease_revoke.state"),
            ),
        ] {
            assert_eq!(InputLeaseRevoke::try_from(revoke), Err(expected));
        }

        let valid_ack = wire::InputLeaseRevokedAck {
            operation_id: Some(id(11)),
            lease_generation: 9,
            owner_device: Some(id(1)),
            target_device: Some(id(2)),
            state: wire::InputLeaseState::Revoked.into(),
            result: wire::InputLeaseRevokedResult::Applied.into(),
        };
        assert_eq!(
            InputLeaseRevokedAck::try_from(wire::InputLeaseRevokedAck {
                state: wire::InputLeaseState::Active.into(),
                ..valid_ack
            }),
            Err(WireError::InvalidField("input_lease_revoked_ack.state"))
        );
        assert_eq!(
            InputLeaseRevokedAck::try_from(wire::InputLeaseRevokedAck {
                result: wire::InputLeaseRevokedResult::Unspecified.into(),
                ..valid_ack
            }),
            Err(WireError::UnknownEnum("input_lease_revoked_ack.result"))
        );
    }

    #[test]
    fn input_event_lease_target_and_sequence_constraints_are_strict() {
        let motion = || {
            Some(wire::input_event::Event::PointerMotion(
                wire::RelativePointerMotion {
                    delta_x_dip: 1.0,
                    delta_y_dip: 0.0,
                },
            ))
        };
        let cases = [
            (
                wire::InputEvent {
                    lease_generation: 0,
                    target_device: Some(id(1)),
                    event_sequence: 1,
                    sender_not_after_ns: 100,
                    event: motion(),
                },
                WireError::InvalidField("input_event.lease_generation"),
            ),
            (
                wire::InputEvent {
                    lease_generation: 1,
                    target_device: None,
                    event_sequence: 1,
                    sender_not_after_ns: 100,
                    event: motion(),
                },
                WireError::MissingField("input_event.target_device"),
            ),
            (
                wire::InputEvent {
                    lease_generation: 1,
                    target_device: Some(id(1)),
                    event_sequence: 0,
                    sender_not_after_ns: 100,
                    event: motion(),
                },
                WireError::InvalidField("input_event.event_sequence"),
            ),
            (
                wire::InputEvent {
                    lease_generation: 1,
                    target_device: Some(id(1)),
                    event_sequence: 1,
                    sender_not_after_ns: 100,
                    event: None,
                },
                WireError::MissingField("input_event.event"),
            ),
            (
                wire::InputEvent {
                    lease_generation: 1,
                    target_device: Some(id(1)),
                    event_sequence: 1,
                    sender_not_after_ns: 0,
                    event: motion(),
                },
                WireError::InvalidField("input_event.sender_not_after_ns"),
            ),
        ];
        for (event, expected) in cases {
            assert_eq!(InputEvent::try_from(event), Err(expected));
        }
    }

    #[test]
    fn release_all_is_the_only_input_allowed_without_a_deadline() {
        let payload = wire::control_envelope::Payload::InputEvent(wire::InputEvent {
            lease_generation: 9,
            target_device: Some(id(7)),
            event_sequence: 12,
            sender_not_after_ns: 0,
            event: Some(wire::input_event::Event::ReleaseAll(
                wire::ReleaseAllInput {},
            )),
        });
        assert_eq!(
            convert(payload),
            Ok(DomainControl::InputEvent(InputEvent {
                lease_generation: 9,
                target_device: Id128(7),
                sequence: 12,
                sender_not_after_ns: 0,
                event: InputEventKind::ReleaseAll,
            }))
        );
    }

    #[test]
    fn protocol_v1_input_is_rejected_after_the_safety_upgrade() {
        let mut incompatible = envelope(input_payload(wire::input_event::Event::ReleaseAll(
            wire::ReleaseAllInput {},
        )));
        incompatible.protocol_major = 1;
        assert_eq!(
            DomainControl::try_from(incompatible),
            Err(WireError::IncompatibleVersion)
        );
    }

    #[test]
    fn protocol_v2_1_compatibility_rejects_legacy_minor() {
        let legacy = ProtocolVersion { major: 2, minor: 0 };
        let future = ProtocolVersion { major: 2, minor: 2 };

        assert!(!PROTOCOL_VERSION.is_compatible_with(legacy));
        assert!(!legacy.is_compatible_with(PROTOCOL_VERSION));
        assert!(PROTOCOL_VERSION.is_compatible_with(future));
        assert!(!PROTOCOL_VERSION.is_compatible_with(ProtocolVersion { major: 3, minor: 1 }));
    }

    #[test]
    fn protocol_v2_0_wire_envelope_is_rejected_after_the_ack_upgrade() {
        let payload = input_payload(wire::input_event::Event::ReleaseAll(
            wire::ReleaseAllInput {},
        ));
        let mut legacy = envelope(payload.clone());
        legacy.protocol_minor = 0;
        assert_eq!(
            DomainControl::try_from(legacy),
            Err(WireError::IncompatibleVersion)
        );

        let mut future = envelope(payload);
        future.protocol_minor = u32::from(PROTOCOL_VERSION.minor) + 1;
        assert!(DomainControl::try_from(future).is_ok());
    }

    #[test]
    fn invalid_input_enums_and_numeric_values_are_rejected() {
        let bad_button = wire::PointerButtonEvent {
            button: 99,
            state: wire::InputSwitchState::Pressed.into(),
        };
        assert_eq!(
            PointerButtonEvent::try_from(bad_button),
            Err(WireError::UnknownEnum("pointer_button.button"))
        );

        let bad_state = wire::PointerButtonEvent {
            button: wire::PointerButton::Left.into(),
            state: wire::InputSwitchState::Unspecified.into(),
        };
        assert_eq!(
            PointerButtonEvent::try_from(bad_state),
            Err(WireError::UnknownEnum("pointer_button.state"))
        );

        let bad_motion = wire::RelativePointerMotion {
            delta_x_dip: f64::NAN,
            delta_y_dip: 0.0,
        };
        assert_eq!(
            RelativePointerMotion::try_from(bad_motion),
            Err(WireError::InvalidField("pointer_motion.delta_x_dip"))
        );

        let bad_wheel = wire::PointerWheelEvent {
            vertical_delta_detents: 0.0,
            horizontal_delta_detents: f64::INFINITY,
        };
        assert_eq!(
            PointerWheelEvent::try_from(bad_wheel),
            Err(WireError::InvalidField(
                "pointer_wheel.horizontal_delta_detents"
            ))
        );
    }

    #[test]
    fn invalid_keyboard_hid_values_are_rejected() {
        let cases = [
            (
                wire::KeyboardHidUsage {
                    usage_page: 0,
                    usage_id: 4,
                    state: wire::InputSwitchState::Pressed.into(),
                    repeat: false,
                },
                WireError::InvalidField("keyboard_hid_usage.usage_page"),
            ),
            (
                wire::KeyboardHidUsage {
                    usage_page: 7,
                    usage_id: u32::from(u16::MAX) + 1,
                    state: wire::InputSwitchState::Pressed.into(),
                    repeat: false,
                },
                WireError::InvalidField("keyboard_hid_usage.usage_id"),
            ),
            (
                wire::KeyboardHidUsage {
                    usage_page: 7,
                    usage_id: 4,
                    state: wire::InputSwitchState::Released.into(),
                    repeat: true,
                },
                WireError::InvalidField("keyboard_hid_usage.repeat"),
            ),
            (
                wire::KeyboardHidUsage {
                    usage_page: 7,
                    usage_id: 4,
                    state: 99,
                    repeat: false,
                },
                WireError::UnknownEnum("keyboard_hid_usage.state"),
            ),
        ];
        for (usage, expected) in cases {
            assert_eq!(KeyboardHidUsage::try_from(usage), Err(expected));
        }
    }

    #[test]
    fn clipboard_offer_converts_to_domain() {
        let payload = wire::control_envelope::Payload::ClipboardOffer(wire::ClipboardOffer {
            id: Some(id(1)),
            owner: Some(id(2)),
            generation: 8,
            flavors: vec![wire::ClipboardFlavor {
                mime_type: "text/plain;charset=utf-8".into(),
                size_bytes: 12,
            }],
        });
        assert_eq!(
            convert(payload),
            Ok(DomainControl::ClipboardOffer(ClipboardOffer {
                id: Id128(1),
                owner: Id128(2),
                generation: 8,
                flavors: vec![ClipboardFlavor {
                    name: "text/plain;charset=utf-8".into(),
                    size_bytes: 12,
                }],
            }))
        );
    }

    #[test]
    fn clipboard_transfer_requires_exact_digest_flavors_and_phase_identity() {
        let transfer = wire::ClipboardTransferOffer {
            offer: Some(wire::ClipboardOffer {
                id: Some(id(1)),
                owner: Some(id(2)),
                generation: 3,
                flavors: vec![wire::ClipboardFlavor {
                    mime_type: "text/plain;charset=utf-8".into(),
                    size_bytes: 4,
                }],
            }),
            flavors: vec![wire::ClipboardTransferFlavor {
                mime_type: "text/plain;charset=utf-8".into(),
                size_bytes: 4,
                sha256: vec![5; 32],
            }],
            offer_nonce: vec![6; 16],
            consent_correlation: vec![7; 16],
            connection_binding: vec![8; 32],
            payload_sequence: 9,
        };
        let expected = ClipboardTransferOffer {
            offer: ClipboardOffer {
                id: Id128(1),
                owner: Id128(2),
                generation: 3,
                flavors: vec![ClipboardFlavor {
                    name: "text/plain;charset=utf-8".into(),
                    size_bytes: 4,
                }],
            },
            flavors: vec![ClipboardTransferFlavor {
                name: "text/plain;charset=utf-8".into(),
                size_bytes: 4,
                sha256: [5; 32],
            }],
            offer_nonce: [6; 16],
            consent_correlation: [7; 16],
            connection_binding: [8; 32],
            payload_sequence: 9,
        };
        assert_eq!(
            convert(wire::control_envelope::Payload::ClipboardTransferOffer(
                transfer.clone(),
            )),
            Ok(DomainControl::ClipboardTransferOffer(expected))
        );
        let mut missing_digest = transfer.clone();
        missing_digest.flavors[0].sha256.clear();
        assert_eq!(
            convert(wire::control_envelope::Payload::ClipboardTransferOffer(
                missing_digest,
            )),
            Err(WireError::InvalidField("clipboard_transfer_flavor.sha256"))
        );
        let mut mismatched_flavor = transfer;
        mismatched_flavor.flavors[0].size_bytes = 5;
        assert_eq!(
            convert(wire::control_envelope::Payload::ClipboardTransferOffer(
                mismatched_flavor,
            )),
            Err(WireError::InvalidField("clipboard_transfer_offer.flavors"))
        );

        let accept = ClipboardAccept::try_from(wire::ClipboardAccept {
            offer_id: Some(id(1)),
            generation: 3,
            offer_nonce: vec![6; 16],
            mime_type: "text/plain;charset=utf-8".into(),
            payload_sequence: 9,
        })
        .unwrap();
        assert_eq!(accept.payload_sequence, 9);
        let payload = ClipboardPayload::try_from(wire::ClipboardPayload {
            offer_id: Some(id(1)),
            generation: 3,
            offer_nonce: vec![6; 16],
            payload_sequence: 9,
            mime_type: "text/plain;charset=utf-8".into(),
            data: b"data".to_vec(),
        })
        .unwrap();
        assert_eq!(payload.data, b"data");
        let complete = ClipboardComplete::try_from(wire::ClipboardComplete {
            offer_id: Some(id(1)),
            generation: 3,
            offer_nonce: vec![6; 16],
            payload_sequence: 9,
            status: wire::ClipboardCompletionStatus::Cancelled.into(),
            error_message: Some("echo".into()),
        })
        .unwrap();
        assert_eq!(complete.status, ClipboardCompletionStatus::Cancelled);
    }

    #[test]
    fn file_drag_lifecycle_converts_to_domain() {
        let offer = wire::control_envelope::Payload::FileDragOffer(wire::FileDragOffer {
            id: Some(id(3)),
            generation: 6,
            source_device: Some(id(4)),
            target_device: Some(id(5)),
            operation: wire::DragOperation::Copy.into(),
            items: vec![wire::FileDragItem {
                relative_path: "report.pdf".into(),
                size_bytes: 4096,
                content_sha256: Some(vec![7; 32]),
            }],
        });
        assert_eq!(
            convert(offer),
            Ok(DomainControl::FileDragOffer(DragOffer {
                id: Id128(3),
                generation: 6,
                source_device: Id128(4),
                target_device: Id128(5),
                operation: DragOperation::Copy,
                items: vec![DragItem {
                    relative_path: "report.pdf".into(),
                    size_bytes: 4096,
                    content_hash: Some([7; 32]),
                }],
            }))
        );

        let accept = wire::control_envelope::Payload::FileDragAccept(wire::FileDragAccept {
            offer_id: Some(id(3)),
            generation: 6,
            operation: wire::DragOperation::Move.into(),
            destination_token: "download-session/9".into(),
        });
        assert_eq!(
            convert(accept),
            Ok(DomainControl::FileDragAccept(DragAccept {
                offer_id: Id128(3),
                generation: 6,
                operation: DragOperation::Move,
                destination_token: "download-session/9".into(),
            }))
        );
    }

    #[test]
    fn file_drag_progress_and_completion_convert_to_domain() {
        let progress = wire::control_envelope::Payload::FileDragProgress(wire::FileDragProgress {
            offer_id: Some(id(3)),
            generation: 6,
            bytes_transferred: 1024,
            total_bytes: 4096,
            item_index: 0,
            offset_bytes: 0,
            chunk_size_bytes: 1024,
            chunk_sha256: Some(vec![8; 32]),
        });
        assert_eq!(
            convert(progress),
            Ok(DomainControl::FileDragProgress(DragProgress {
                offer_id: Id128(3),
                generation: 6,
                bytes_transferred: 1024,
                total_bytes: 4096,
                item_index: 0,
                offset_bytes: 0,
                chunk_size_bytes: 1024,
                chunk_hash: Some([8; 32]),
            }))
        );

        let complete = wire::control_envelope::Payload::FileDragComplete(wire::FileDragComplete {
            offer_id: Some(id(3)),
            generation: 6,
            status: wire::FileDragCompletionStatus::Failed.into(),
            error_message: Some("receiver storage full".into()),
            item_results: vec![wire::FileDragItemResult {
                item_index: 0,
                bytes_received: 1024,
                content_sha256: Some(vec![9; 32]),
            }],
        });
        assert_eq!(
            convert(complete),
            Ok(DomainControl::FileDragComplete(DragComplete {
                offer_id: Id128(3),
                generation: 6,
                status: DragCompletionStatus::Failed,
                error_message: Some("receiver storage full".into()),
                item_results: vec![DragItemResult {
                    item_index: 0,
                    bytes_received: 1024,
                    content_hash: Some([9; 32]),
                }],
            }))
        );
    }

    #[test]
    fn application_audio_and_hid_controls_convert_to_domain() {
        let audio =
            wire::control_envelope::Payload::ApplicationAudioRoute(wire::ApplicationAudioRoute {
                generation: 9,
                family_id: Some(id(10)),
                source_device: Some(id(11)),
                target_device: Some(id(12)),
                target_output_id: "speakers/default".into(),
                enabled: true,
            });
        assert_eq!(
            convert(audio),
            Ok(DomainControl::AudioRoute(AudioRoute {
                generation: 9,
                family_id: Id128(10),
                source_device: Id128(11),
                target_device: Id128(12),
                target_output_id: "speakers/default".into(),
                enabled: true,
            }))
        );

        let offer = wire::control_envelope::Payload::HidDeviceOffer(wire::HidDeviceOffer {
            id: Some(id(13)),
            owner: Some(id(11)),
            vendor_id: 0x05ac,
            product_id: 0x0324,
            interface_count: 3,
        });
        assert_eq!(
            convert(offer),
            Ok(DomainControl::HidDeviceOffer(HidDeviceOffer {
                id: Id128(13),
                owner: Id128(11),
                vendor_id: 0x05ac,
                product_id: 0x0324,
                interface_count: 3,
            }))
        );
    }

    #[test]
    fn hid_lease_and_clock_sync_controls_convert_to_domain() {
        let lease = wire::control_envelope::Payload::HidDeviceLease(wire::HidDeviceLease {
            generation: 7,
            device_id: Some(id(13)),
            owner: Some(id(11)),
            route_to: Some(id(12)),
            state: wire::HidLeaseState::Active.into(),
        });
        assert_eq!(
            convert(lease),
            Ok(DomainControl::HidDeviceLease(HidDeviceLease {
                generation: 7,
                device_id: Id128(13),
                owner: Id128(11),
                route_to: Id128(12),
                state: HidLeaseState::Active,
            }))
        );

        let probe = wire::control_envelope::Payload::ClockSyncProbe(wire::ClockSyncProbe {
            probe_id: 44,
            t0_send_ns: 1_000,
        });
        assert_eq!(
            convert(probe),
            Ok(DomainControl::ClockSyncProbe(ClockSyncProbe {
                probe_id: 44,
                t0_send_ns: 1_000,
            }))
        );

        let reply = wire::control_envelope::Payload::ClockSyncReply(wire::ClockSyncReply {
            probe_id: 44,
            t0_send_ns: 1_000,
            t1_receive_ns: 1_100,
            t2_send_ns: 1_120,
        });
        assert_eq!(
            convert(reply),
            Ok(DomainControl::ClockSyncReply(ClockSyncReply {
                probe_id: 44,
                t0_send_ns: 1_000,
                t1_receive_ns: 1_100,
                t2_send_ns: 1_120,
            }))
        );
    }

    #[test]
    fn missing_required_fields_are_rejected() {
        let cases = [
            (
                wire::control_envelope::Payload::ClipboardOffer(wire::ClipboardOffer {
                    id: None,
                    owner: Some(id(1)),
                    generation: 0,
                    flavors: vec![],
                }),
                WireError::MissingField("clipboard_offer.id"),
            ),
            (
                wire::control_envelope::Payload::FileDragProgress(wire::FileDragProgress {
                    offer_id: None,
                    generation: 0,
                    bytes_transferred: 0,
                    total_bytes: 0,
                    item_index: 0,
                    offset_bytes: 0,
                    chunk_size_bytes: 0,
                    chunk_sha256: None,
                }),
                WireError::MissingField("file_drag_progress.offer_id"),
            ),
            (
                wire::control_envelope::Payload::ApplicationAudioRoute(
                    wire::ApplicationAudioRoute {
                        generation: 0,
                        family_id: Some(id(1)),
                        source_device: None,
                        target_device: Some(id(2)),
                        target_output_id: String::new(),
                        enabled: false,
                    },
                ),
                WireError::MissingField("application_audio_route.source_device"),
            ),
            (
                wire::control_envelope::Payload::HidDeviceLease(wire::HidDeviceLease {
                    generation: 0,
                    device_id: Some(id(1)),
                    owner: Some(id(2)),
                    route_to: None,
                    state: wire::HidLeaseState::Active.into(),
                }),
                WireError::MissingField("hid_device_lease.route_to"),
            ),
        ];
        for (payload, expected) in cases {
            assert_eq!(convert(payload), Err(expected));
        }
    }

    #[test]
    fn unknown_and_unspecified_new_enums_are_rejected() {
        let cases = [
            (
                wire::control_envelope::Payload::FileDragOffer(wire::FileDragOffer {
                    id: Some(id(1)),
                    generation: 0,
                    source_device: Some(id(2)),
                    target_device: Some(id(3)),
                    operation: 99,
                    items: vec![],
                }),
                WireError::UnknownEnum("file_drag_offer.operation"),
            ),
            (
                wire::control_envelope::Payload::FileDragAccept(wire::FileDragAccept {
                    offer_id: Some(id(1)),
                    generation: 0,
                    operation: wire::DragOperation::Unspecified.into(),
                    destination_token: String::new(),
                }),
                WireError::UnknownEnum("file_drag_accept.operation"),
            ),
            (
                wire::control_envelope::Payload::FileDragComplete(wire::FileDragComplete {
                    offer_id: Some(id(1)),
                    generation: 0,
                    status: 99,
                    error_message: None,
                    item_results: vec![],
                }),
                WireError::UnknownEnum("file_drag_complete.status"),
            ),
            (
                wire::control_envelope::Payload::HidDeviceLease(wire::HidDeviceLease {
                    generation: 0,
                    device_id: Some(id(1)),
                    owner: Some(id(2)),
                    route_to: Some(id(3)),
                    state: wire::HidLeaseState::Unspecified.into(),
                }),
                WireError::UnknownEnum("hid_device_lease.state"),
            ),
        ];
        for (payload, expected) in cases {
            assert_eq!(convert(payload), Err(expected));
        }
    }

    #[test]
    fn fixed_width_fields_reject_invalid_wire_values() {
        let bad_hash = wire::FileDragItem {
            relative_path: "bad.bin".into(),
            size_bytes: 2,
            content_sha256: Some(vec![0; 31]),
        };
        assert_eq!(
            DragItem::try_from(bad_hash),
            Err(WireError::InvalidField("file_drag_item.content_sha256"))
        );

        let bad_chunk_hash = wire::FileDragProgress {
            offer_id: Some(id(1)),
            generation: 1,
            bytes_transferred: 4,
            total_bytes: 4,
            item_index: 0,
            offset_bytes: 0,
            chunk_size_bytes: 4,
            chunk_sha256: Some(vec![0; 33]),
        };
        assert_eq!(
            DragProgress::try_from(bad_chunk_hash),
            Err(WireError::InvalidField("file_drag_progress.chunk_sha256"))
        );

        let bad_final_hash = wire::FileDragItemResult {
            item_index: 0,
            bytes_received: 4,
            content_sha256: Some(vec![0; 16]),
        };
        assert_eq!(
            DragItemResult::try_from(bad_final_hash),
            Err(WireError::InvalidField(
                "file_drag_item_result.content_sha256"
            ))
        );

        let bad_hid = wire::HidDeviceOffer {
            id: Some(id(1)),
            owner: Some(id(2)),
            vendor_id: u32::from(u16::MAX) + 1,
            product_id: 1,
            interface_count: 1,
        };
        assert_eq!(
            HidDeviceOffer::try_from(bad_hid),
            Err(WireError::InvalidField("hid_device_offer.vendor_id"))
        );
    }
}
