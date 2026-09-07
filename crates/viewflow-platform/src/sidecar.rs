//! Dependency-free local IPC contract for the separately licensed Deskflow sidecar.
//!
//! The wire format is deliberately distinct from the peer QUIC protocol. Every
//! frame is length-prefixed, versioned, bounded, and carries a request sequence.
//! Input messages additionally carry the generation of the active input lease,
//! preventing buffered input from an old route from reaching a new owner.

use std::fmt;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};

use sha2::{Digest, Sha256};
use viewflow_protocol::{
    DeviceId, Id128, InputLease, InputLeaseState, InputSwitchState, PointerButton, WindowId,
};

#[cfg(unix)]
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
#[cfg(unix)]
use std::path::{Path, PathBuf};

/// Current version of the private local sidecar protocol.
pub const SIDECAR_PROTOCOL_VERSION: u8 = 3;
/// Maximum encoded payload after the four-byte length prefix.
pub const MAX_FRAME_BYTES: usize = 64 * 1024;
/// Maximum number of reports accepted in one raw HID bundle.
pub const MAX_HID_REPORTS: usize = 64;
/// Maximum size of one raw HID report.
pub const MAX_HID_REPORT_BYTES: usize = 4 * 1024;

const KIND_INPUT_LEASE: u8 = 1;
const KIND_POINTER: u8 = 2;
const KIND_KEY: u8 = 3;
const KIND_RAW_HID_BUNDLE: u8 = 4;
const KIND_RELATIVE_POINTER: u8 = 5;
const KIND_POINTER_BUTTON: u8 = 6;
const KIND_POINTER_WHEEL: u8 = 7;
const KIND_KEYBOARD_HID: u8 = 8;
const KIND_RELEASE_ALL: u8 = 9;
const KIND_EDGE_ACTIVATED: u8 = 10;
const KIND_RETURN_TO_LOCAL: u8 = 11;
const KIND_QUARANTINE_RECOVERY: u8 = 12;
const KIND_CLEANUP_COMPLETE: u8 = 13;
const KIND_RESPONSE: u8 = 0x80;

pub const DURABLE_QUARANTINE_MARKER_MAGIC: [u8; 8] = *b"VFQST002";
pub const DURABLE_QUARANTINE_MARKER_SIZE: usize = 152;
pub const QUARANTINE_RECOVERY_BODY_SIZE: usize = 176;
pub const CLEANUP_COMPLETE_BODY_SIZE: usize = 277;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BoundPeerIdentity {
    pub epoch: u64,
    pub address: SocketAddr,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SidecarInputLease {
    pub lease: InputLease,
    pub bound_peer: BoundPeerIdentity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum QuarantineMarkerState {
    Active = 1,
    Uncertain = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DurableQuarantineMarker {
    pub state: QuarantineMarkerState,
    pub source_display: Id128,
    pub target_device: DeviceId,
    pub owner_device: DeviceId,
    pub old_daemon_boot_id: Id128,
    pub route_generation: u64,
    pub active_lease_generation: u64,
    pub last_sequence: u64,
    pub old_daemon_pid: u64,
    pub old_daemon_start_ticks: u64,
    pub bound_peer: BoundPeerIdentity,
}

impl DurableQuarantineMarker {
    /// Encodes the exact 152-byte runtime quarantine marker.
    ///
    /// # Errors
    ///
    /// Returns [`CodecError::InvalidPayload`] when an identity, generation,
    /// process value, or peer endpoint violates the marker contract.
    pub fn encode(self) -> Result<[u8; DURABLE_QUARANTINE_MARKER_SIZE], CodecError> {
        validate_marker(&self)?;
        let mut bytes = [0_u8; DURABLE_QUARANTINE_MARKER_SIZE];
        bytes[..8].copy_from_slice(&DURABLE_QUARANTINE_MARKER_MAGIC);
        bytes[8] = self.state as u8;
        bytes[16..32].copy_from_slice(&self.source_display.0.to_be_bytes());
        bytes[32..48].copy_from_slice(&self.target_device.0.to_be_bytes());
        bytes[48..64].copy_from_slice(&self.owner_device.0.to_be_bytes());
        bytes[64..80].copy_from_slice(&self.old_daemon_boot_id.0.to_be_bytes());
        bytes[80..88].copy_from_slice(&self.route_generation.to_be_bytes());
        bytes[88..96].copy_from_slice(&self.active_lease_generation.to_be_bytes());
        bytes[96..104].copy_from_slice(&self.last_sequence.to_be_bytes());
        bytes[104..112].copy_from_slice(&self.old_daemon_pid.to_be_bytes());
        bytes[112..120].copy_from_slice(&self.old_daemon_start_ticks.to_be_bytes());
        bytes[120..128].copy_from_slice(&self.bound_peer.epoch.to_be_bytes());
        encode_socket_identity(&mut bytes[128..152], self.bound_peer.address)?;
        Ok(bytes)
    }

    /// Decodes and validates one exact 152-byte runtime quarantine marker.
    ///
    /// # Errors
    ///
    /// Returns [`CodecError::InvalidPayload`] for an unsupported marker or an
    /// invalid field, and [`CodecError::FrameTooShort`] for a truncated field.
    pub fn decode(bytes: &[u8]) -> Result<Self, CodecError> {
        if bytes.len() != DURABLE_QUARANTINE_MARKER_SIZE {
            return Err(CodecError::InvalidPayload(
                "durable marker must be exactly 152 bytes",
            ));
        }
        if bytes[..8] != DURABLE_QUARANTINE_MARKER_MAGIC {
            return Err(CodecError::InvalidPayload(
                "unsupported durable marker magic",
            ));
        }
        if bytes[9..16].iter().any(|byte| *byte != 0) {
            return Err(CodecError::InvalidPayload(
                "durable marker reserved bytes must be zero",
            ));
        }
        let marker = Self {
            state: match bytes[8] {
                1 => QuarantineMarkerState::Active,
                2 => QuarantineMarkerState::Uncertain,
                _ => {
                    return Err(CodecError::InvalidPayload(
                        "unsupported durable marker state",
                    ));
                }
            },
            source_display: Id128(read_u128_at(bytes, 16)?),
            target_device: Id128(read_u128_at(bytes, 32)?),
            owner_device: Id128(read_u128_at(bytes, 48)?),
            old_daemon_boot_id: Id128(read_u128_at(bytes, 64)?),
            route_generation: read_u64_at(bytes, 80)?,
            active_lease_generation: read_u64_at(bytes, 88)?,
            last_sequence: read_u64_at(bytes, 96)?,
            old_daemon_pid: read_u64_at(bytes, 104)?,
            old_daemon_start_ticks: read_u64_at(bytes, 112)?,
            bound_peer: BoundPeerIdentity {
                epoch: read_u64_at(bytes, 120)?,
                address: decode_socket_identity(&bytes[128..152])?,
            },
        };
        validate_marker(&marker)?;
        Ok(marker)
    }

    /// Returns the SHA-256 digest of the complete validated marker.
    ///
    /// # Errors
    ///
    /// Returns [`CodecError::InvalidPayload`] when the marker is not valid.
    pub fn sha256(self) -> Result<[u8; 32], CodecError> {
        Ok(Sha256::digest(self.encode()?).into())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct QuarantineRecoveryRequest {
    pub marker: DurableQuarantineMarker,
    pub marker_sha256: [u8; 32],
}

impl QuarantineRecoveryRequest {
    /// Creates a recovery request bound to the complete marker digest.
    ///
    /// # Errors
    ///
    /// Returns [`CodecError::InvalidPayload`] when the marker is not valid.
    pub fn new(marker: DurableQuarantineMarker) -> Result<Self, CodecError> {
        let bytes = marker.encode()?;
        Ok(Self {
            marker,
            marker_sha256: Sha256::digest(bytes).into(),
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum CleanupMode {
    Normal = 1,
    Recovery = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum SequenceDisposition {
    Exact = 1,
    ProvenUnobservedReservation = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CleanupComplete {
    pub mode: CleanupMode,
    pub recovery_request_sequence: u64,
    pub marker_sha256: [u8; 32],
    pub cleanup_operation_id: Id128,
    pub receipt_issued_at_unix_ms: u64,
    pub receipt_expires_at_unix_ms: u64,
    pub source_display: Id128,
    pub route_generation: u64,
    pub target_device: DeviceId,
    pub owner_device: DeviceId,
    pub active_lease_generation: u64,
    pub marker_last_sequence: u64,
    pub observed_last_sequence: u64,
    pub sequence_disposition: SequenceDisposition,
    pub bound_peer: BoundPeerIdentity,
    pub release_all: ReleaseAllInput,
    pub release_all_applied: bool,
    pub revoke_operation_id: Id128,
    pub revoke_lease_generation: u64,
    pub revoke_owner_device: DeviceId,
    pub revoke_target_device: DeviceId,
    pub revoke_state: InputLeaseState,
    pub revoke_applied: bool,
}

/// Direction of one request on the full-duplex sidecar stream.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MessageDirection {
    DaemonToSidecar,
    SidecarToDaemon,
}

/// A logical display edge. Edge positions are normalized along this edge.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SidecarEdge {
    Left,
    Right,
    Top,
    Bottom,
}

/// One pointer event authorized by a generation-numbered input lease.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PointerInput {
    pub generation: u64,
    pub target: WindowId,
    pub x_dip: f64,
    pub y_dip: f64,
}

/// One keyboard event authorized by a generation-numbered input lease.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeyInput {
    pub generation: u64,
    pub target: WindowId,
    pub hid_usage: u32,
    pub pressed: bool,
}

/// Relative pointer motion in target-independent logical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RelativePointerInput {
    pub generation: u64,
    pub target_device: DeviceId,
    pub event_sequence: u64,
    /// Absolute `CLOCK_MONOTONIC` deadline captured by the Linux input producer.
    pub apply_deadline_monotonic_ns: u64,
    pub delta_x_dip: f64,
    pub delta_y_dip: f64,
}

/// Pointer button input for the current lease.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PointerButtonInput {
    pub generation: u64,
    pub target_device: DeviceId,
    pub event_sequence: u64,
    /// Absolute `CLOCK_MONOTONIC` deadline captured by the Linux input producer.
    pub apply_deadline_monotonic_ns: u64,
    pub button: PointerButton,
    pub state: InputSwitchState,
}

/// High-resolution pointer wheel input measured in standard detents.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PointerWheelInput {
    pub generation: u64,
    pub target_device: DeviceId,
    pub event_sequence: u64,
    /// Absolute `CLOCK_MONOTONIC` deadline captured by the Linux input producer.
    pub apply_deadline_monotonic_ns: u64,
    pub vertical_delta_detents: f64,
    pub horizontal_delta_detents: f64,
}

/// USB HID keyboard usage input for the current lease.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeyboardHidInput {
    pub generation: u64,
    pub target_device: DeviceId,
    pub event_sequence: u64,
    /// Absolute `CLOCK_MONOTONIC` deadline captured by the Linux input producer.
    pub apply_deadline_monotonic_ns: u64,
    pub usage_page: u16,
    pub usage_id: u16,
    pub state: InputSwitchState,
    pub repeat: bool,
}

/// Idempotent release of every pressed key and pointer button.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReleaseAllInput {
    pub generation: u64,
    pub target_device: DeviceId,
    pub event_sequence: u64,
}

/// Notification emitted by the Deskflow sidecar when a configured edge activates.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EdgeActivated {
    pub route_generation: u64,
    pub source_display: Id128,
    pub route_to: DeviceId,
    pub edge: SidecarEdge,
    /// Position along the edge, in the inclusive range 0.0 through 1.0.
    pub edge_position: f64,
}

/// Command from the daemon that returns portal ownership to a local display.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReturnToLocal {
    pub generation: u64,
    pub target_display: Id128,
    pub edge: SidecarEdge,
    /// Position along the edge, in the inclusive range 0.0 through 1.0.
    pub edge_position: f64,
}

/// One timestamped report from a raw HID interface.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RawHidReport {
    pub timestamp_ns: u64,
    pub bytes: Vec<u8>,
}

/// A bounded batch of reports from one device interface.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RawHidReportBundle {
    pub generation: u64,
    pub device_id: Id128,
    pub interface: u8,
    pub reports: Vec<RawHidReport>,
}

/// Message body exchanged with the independent Deskflow/HID process.
#[derive(Clone, Debug, PartialEq)]
pub enum SidecarMessage {
    InputLease(SidecarInputLease),
    Pointer(PointerInput),
    Key(KeyInput),
    RawHidReportBundle(RawHidReportBundle),
    RelativePointer(RelativePointerInput),
    PointerButton(PointerButtonInput),
    PointerWheel(PointerWheelInput),
    KeyboardHid(KeyboardHidInput),
    ReleaseAll(ReleaseAllInput),
    EdgeActivated(EdgeActivated),
    ReturnToLocal(ReturnToLocal),
    QuarantineRecovery(QuarantineRecoveryRequest),
    CleanupComplete(CleanupComplete),
}

impl SidecarMessage {
    /// Returns which peer is permitted to originate this message.
    #[must_use]
    pub const fn direction(&self) -> MessageDirection {
        match self {
            Self::InputLease(_) | Self::ReturnToLocal(_) | Self::CleanupComplete(_) => {
                MessageDirection::DaemonToSidecar
            }
            Self::Pointer(_)
            | Self::Key(_)
            | Self::RawHidReportBundle(_)
            | Self::RelativePointer(_)
            | Self::PointerButton(_)
            | Self::PointerWheel(_)
            | Self::KeyboardHid(_)
            | Self::ReleaseAll(_)
            | Self::EdgeActivated(_)
            | Self::QuarantineRecovery(_) => MessageDirection::SidecarToDaemon,
        }
    }
}

/// A sequenced request on the local stream.
#[derive(Clone, Debug, PartialEq)]
pub struct SidecarRequest {
    pub sequence: u64,
    pub message: SidecarMessage,
}

/// Stable rejection category returned to the sidecar.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum RejectCode {
    StaleGeneration = 1,
    FutureGeneration = 2,
    LeaseNotActive = 3,
    BackendFailure = 4,
    ReplayedEvent = 5,
    WrongDirection = 6,
    InvalidLeaseTransition = 7,
    WrongTarget = 8,
}

impl RejectCode {
    fn from_wire(value: u8) -> Result<Self, CodecError> {
        match value {
            1 => Ok(Self::StaleGeneration),
            2 => Ok(Self::FutureGeneration),
            3 => Ok(Self::LeaseNotActive),
            4 => Ok(Self::BackendFailure),
            5 => Ok(Self::ReplayedEvent),
            6 => Ok(Self::WrongDirection),
            7 => Ok(Self::InvalidLeaseTransition),
            8 => Ok(Self::WrongTarget),
            _ => Err(CodecError::InvalidPayload("unknown rejection code")),
        }
    }
}

/// Response matching a request sequence.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SidecarResponse {
    pub sequence: u64,
    pub result: Result<(), RejectCode>,
}

/// An accepted event that may be forwarded to Deskflow or a native HID bridge.
pub type SidecarEvent = SidecarMessage;

/// Result of processing one request from a stream.
#[derive(Clone, Debug, PartialEq)]
pub enum ServiceOutcome {
    EndOfStream,
    Accepted(Box<SidecarEvent>),
    Rejected(RejectCode),
}

/// Framing or payload validation failure.
#[derive(Debug)]
pub enum CodecError {
    Io(io::Error),
    FrameTooLarge { declared: usize, maximum: usize },
    FrameTooShort,
    UnsupportedVersion(u8),
    UnknownMessageKind(u8),
    InvalidPayload(&'static str),
    TooManyReports { declared: usize, maximum: usize },
    ReportTooLarge { declared: usize, maximum: usize },
    NonFiniteCoordinate,
}

impl fmt::Display for CodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "sidecar I/O error: {error}"),
            Self::FrameTooLarge { declared, maximum } => {
                write!(
                    formatter,
                    "sidecar frame is {declared} bytes, maximum is {maximum}"
                )
            }
            Self::FrameTooShort => formatter.write_str("sidecar frame is truncated"),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported sidecar protocol version {version}")
            }
            Self::UnknownMessageKind(kind) => write!(formatter, "unknown sidecar message {kind}"),
            Self::InvalidPayload(reason) => write!(formatter, "invalid sidecar payload: {reason}"),
            Self::TooManyReports { declared, maximum } => {
                write!(
                    formatter,
                    "HID bundle has {declared} reports, maximum is {maximum}"
                )
            }
            Self::ReportTooLarge { declared, maximum } => {
                write!(
                    formatter,
                    "HID report is {declared} bytes, maximum is {maximum}"
                )
            }
            Self::NonFiniteCoordinate => formatter.write_str("pointer coordinates must be finite"),
        }
    }
}

impl std::error::Error for CodecError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for CodecError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

/// Stateful gate that ensures only the currently active lease can emit input.
#[derive(Clone, Debug, Default)]
pub struct SidecarSession {
    lease: Option<SidecarInputLease>,
    last_event_sequence: Option<u64>,
    last_recovery_request_sequence: Option<u64>,
    pending_recovery: Option<PendingRecovery>,
}

#[derive(Clone, Copy, Debug)]
struct PendingRecovery {
    request_sequence: u64,
    request: QuarantineRecoveryRequest,
}

impl SidecarSession {
    #[must_use]
    pub fn lease(&self) -> Option<InputLease> {
        self.lease.map(|lease| lease.lease)
    }

    #[must_use]
    pub fn bound_peer(&self) -> Option<BoundPeerIdentity> {
        self.lease.map(|lease| lease.bound_peer)
    }

    /// Validates a request and advances lease state when appropriate.
    ///
    /// # Errors
    ///
    /// Rejects non-increasing lease updates, input from a stale or unknown
    /// generation, and input while the current lease is not active.
    pub fn accept(&mut self, request: SidecarRequest) -> Result<SidecarEvent, RejectCode> {
        self.accept_inner(request)
    }

    /// Validates both the sender direction and the lease generation.
    ///
    /// # Errors
    ///
    /// Returns [`RejectCode::WrongDirection`] when a peer originates a command
    /// owned by the other side of the local IPC boundary.
    pub fn accept_from(
        &mut self,
        origin: MessageDirection,
        request: SidecarRequest,
    ) -> Result<SidecarEvent, RejectCode> {
        if request.message.direction() != origin {
            return Err(RejectCode::WrongDirection);
        }
        self.accept_inner(request)
    }

    fn accept_inner(&mut self, request: SidecarRequest) -> Result<SidecarEvent, RejectCode> {
        let request_sequence = request.sequence;
        match request.message {
            SidecarMessage::InputLease(lease) => {
                self.accept_lease(lease)?;
                self.last_event_sequence = None;
                self.lease = Some(lease);
                Ok(SidecarMessage::InputLease(lease))
            }
            SidecarMessage::QuarantineRecovery(recovery) => {
                validate_quarantine_recovery(&recovery)
                    .map_err(|_| RejectCode::InvalidLeaseTransition)?;
                if request_sequence == 0
                    || self
                        .last_recovery_request_sequence
                        .is_some_and(|last| request_sequence <= last)
                {
                    return Err(RejectCode::ReplayedEvent);
                }
                self.last_recovery_request_sequence = Some(request_sequence);
                self.pending_recovery = Some(PendingRecovery {
                    request_sequence,
                    request: recovery,
                });
                Ok(SidecarMessage::QuarantineRecovery(recovery))
            }
            SidecarMessage::EdgeActivated(edge) => Ok(SidecarMessage::EdgeActivated(edge)),
            SidecarMessage::CleanupComplete(cleanup) => {
                validate_cleanup_complete(&cleanup)
                    .map_err(|_| RejectCode::InvalidLeaseTransition)?;
                match cleanup.mode {
                    CleanupMode::Normal if self.pending_recovery.is_some() => {
                        return Err(RejectCode::InvalidLeaseTransition);
                    }
                    CleanupMode::Normal => {}
                    CleanupMode::Recovery => {
                        let pending = self
                            .pending_recovery
                            .ok_or(RejectCode::InvalidLeaseTransition)?;
                        if !cleanup_matches_recovery(&cleanup, pending) {
                            return Err(RejectCode::InvalidLeaseTransition);
                        }
                        self.pending_recovery = None;
                    }
                }
                Ok(SidecarMessage::CleanupComplete(cleanup))
            }
            message => {
                let generation = message_generation(&message);
                let lease = self.lease.ok_or(RejectCode::LeaseNotActive)?;
                if generation < lease.lease.generation {
                    return Err(RejectCode::StaleGeneration);
                }
                if generation > lease.lease.generation {
                    return Err(RejectCode::FutureGeneration);
                }
                let release_all = matches!(message, SidecarMessage::ReleaseAll(_));
                let daemon_command = matches!(message, SidecarMessage::ReturnToLocal(_));
                if lease.lease.state != InputLeaseState::Active && !release_all && !daemon_command {
                    return Err(RejectCode::LeaseNotActive);
                }
                if message_target_device(&message)
                    .is_some_and(|target| target != lease.lease.route_to)
                {
                    return Err(RejectCode::WrongTarget);
                }
                if let Some(event_sequence) = message_event_sequence(&message, request_sequence) {
                    if self
                        .last_event_sequence
                        .is_some_and(|last| event_sequence <= last)
                    {
                        return Err(RejectCode::ReplayedEvent);
                    }
                    self.last_event_sequence = Some(event_sequence);
                }
                Ok(message)
            }
        }
    }

    fn accept_lease(&self, lease: SidecarInputLease) -> Result<(), RejectCode> {
        if lease.lease.generation == 0
            || lease.lease.owner.0 == 0
            || lease.lease.route_to.0 == 0
            || lease.lease.owner == lease.lease.route_to
            || validate_bound_peer(lease.bound_peer).is_err()
        {
            return Err(RejectCode::InvalidLeaseTransition);
        }

        let Some(current) = self.lease else {
            return if lease.lease.state == InputLeaseState::Offered {
                Ok(())
            } else {
                Err(RejectCode::InvalidLeaseTransition)
            };
        };
        if lease.lease.generation <= current.lease.generation {
            return Err(RejectCode::StaleGeneration);
        }
        if current.lease.state != InputLeaseState::Revoked
            && (lease.lease.owner != current.lease.owner
                || lease.lease.route_to != current.lease.route_to
                || lease.bound_peer != current.bound_peer)
        {
            return Err(RejectCode::InvalidLeaseTransition);
        }

        let transition_is_valid = matches!(
            (current.lease.state, lease.lease.state),
            (
                InputLeaseState::Offered,
                InputLeaseState::Active | InputLeaseState::Revoked
            ) | (InputLeaseState::Active, InputLeaseState::Revoked)
                | (InputLeaseState::Revoked, InputLeaseState::Offered)
        );
        if !transition_is_valid {
            return Err(RejectCode::InvalidLeaseTransition);
        }
        Ok(())
    }
}

fn message_generation(message: &SidecarMessage) -> u64 {
    match message {
        SidecarMessage::InputLease(lease) => lease.lease.generation,
        SidecarMessage::Pointer(pointer) => pointer.generation,
        SidecarMessage::Key(key) => key.generation,
        SidecarMessage::RawHidReportBundle(bundle) => bundle.generation,
        SidecarMessage::RelativePointer(pointer) => pointer.generation,
        SidecarMessage::PointerButton(button) => button.generation,
        SidecarMessage::PointerWheel(wheel) => wheel.generation,
        SidecarMessage::KeyboardHid(keyboard) => keyboard.generation,
        SidecarMessage::ReleaseAll(release) => release.generation,
        SidecarMessage::EdgeActivated(edge) => edge.route_generation,
        SidecarMessage::ReturnToLocal(command) => command.generation,
        SidecarMessage::QuarantineRecovery(_) | SidecarMessage::CleanupComplete(_) => 0,
    }
}

fn message_event_sequence(message: &SidecarMessage, request_sequence: u64) -> Option<u64> {
    match message {
        SidecarMessage::Pointer(_)
        | SidecarMessage::Key(_)
        | SidecarMessage::RawHidReportBundle(_) => Some(request_sequence),
        SidecarMessage::RelativePointer(pointer) => Some(pointer.event_sequence),
        SidecarMessage::PointerButton(button) => Some(button.event_sequence),
        SidecarMessage::PointerWheel(wheel) => Some(wheel.event_sequence),
        SidecarMessage::KeyboardHid(keyboard) => Some(keyboard.event_sequence),
        SidecarMessage::ReleaseAll(release) => Some(release.event_sequence),
        SidecarMessage::InputLease(_)
        | SidecarMessage::EdgeActivated(_)
        | SidecarMessage::ReturnToLocal(_)
        | SidecarMessage::QuarantineRecovery(_)
        | SidecarMessage::CleanupComplete(_) => None,
    }
}

fn message_target_device(message: &SidecarMessage) -> Option<DeviceId> {
    match message {
        SidecarMessage::RelativePointer(pointer) => Some(pointer.target_device),
        SidecarMessage::PointerButton(button) => Some(button.target_device),
        SidecarMessage::PointerWheel(wheel) => Some(wheel.target_device),
        SidecarMessage::KeyboardHid(keyboard) => Some(keyboard.target_device),
        SidecarMessage::ReleaseAll(release) => Some(release.target_device),
        SidecarMessage::InputLease(_)
        | SidecarMessage::Pointer(_)
        | SidecarMessage::Key(_)
        | SidecarMessage::RawHidReportBundle(_)
        | SidecarMessage::EdgeActivated(_)
        | SidecarMessage::ReturnToLocal(_)
        | SidecarMessage::QuarantineRecovery(_)
        | SidecarMessage::CleanupComplete(_) => None,
    }
}

/// Encodes and writes one request using a four-byte big-endian length prefix.
///
/// # Errors
///
/// Returns a validation error for an unbounded or malformed message and an I/O
/// error when the complete frame cannot be written.
pub fn write_request(writer: &mut impl Write, request: &SidecarRequest) -> Result<(), CodecError> {
    let mut payload = Vec::new();
    payload.push(SIDECAR_PROTOCOL_VERSION);
    payload.push(message_kind(&request.message));
    push_u64(&mut payload, request.sequence);
    encode_message(&mut payload, &request.message)?;
    write_payload(writer, &payload)
}

/// Reads one request. Clean EOF before a new frame returns `None`.
///
/// # Errors
///
/// Returns an error for malformed, truncated, unsupported, or oversized input,
/// or when the underlying reader fails.
pub fn read_request(reader: &mut impl Read) -> Result<Option<SidecarRequest>, CodecError> {
    let Some(payload) = read_payload(reader)? else {
        return Ok(None);
    };
    let mut cursor = PayloadCursor::new(&payload);
    validate_header(&mut cursor)?;
    let kind = cursor.u8()?;
    let sequence = cursor.u64()?;
    let message = decode_message(kind, &mut cursor)?;
    cursor.finish()?;
    Ok(Some(SidecarRequest { sequence, message }))
}

/// Encodes and writes one response.
///
/// # Errors
///
/// Returns an I/O error when the complete response cannot be written.
pub fn write_response(
    writer: &mut impl Write,
    response: SidecarResponse,
) -> Result<(), CodecError> {
    let mut payload = Vec::with_capacity(12);
    payload.push(SIDECAR_PROTOCOL_VERSION);
    payload.push(KIND_RESPONSE);
    push_u64(&mut payload, response.sequence);
    match response.result {
        Ok(()) => payload.push(0),
        Err(code) => payload.push(code as u8),
    }
    write_payload(writer, &payload)
}

/// Reads one response. Clean EOF before a new frame returns `None`.
///
/// # Errors
///
/// Returns an error for malformed, truncated, unsupported, or oversized input,
/// or when the underlying reader fails.
pub fn read_response(reader: &mut impl Read) -> Result<Option<SidecarResponse>, CodecError> {
    let Some(payload) = read_payload(reader)? else {
        return Ok(None);
    };
    let mut cursor = PayloadCursor::new(&payload);
    validate_header(&mut cursor)?;
    let kind = cursor.u8()?;
    if kind != KIND_RESPONSE {
        return Err(CodecError::UnknownMessageKind(kind));
    }
    let sequence = cursor.u64()?;
    let status = cursor.u8()?;
    cursor.finish()?;
    let result = if status == 0 {
        Ok(())
    } else {
        Err(RejectCode::from_wire(status)?)
    };
    Ok(Some(SidecarResponse { sequence, result }))
}

fn validate_header(cursor: &mut PayloadCursor<'_>) -> Result<(), CodecError> {
    let version = cursor.u8()?;
    if version != SIDECAR_PROTOCOL_VERSION {
        return Err(CodecError::UnsupportedVersion(version));
    }
    Ok(())
}

fn message_kind(message: &SidecarMessage) -> u8 {
    match message {
        SidecarMessage::InputLease(_) => KIND_INPUT_LEASE,
        SidecarMessage::Pointer(_) => KIND_POINTER,
        SidecarMessage::Key(_) => KIND_KEY,
        SidecarMessage::RawHidReportBundle(_) => KIND_RAW_HID_BUNDLE,
        SidecarMessage::RelativePointer(_) => KIND_RELATIVE_POINTER,
        SidecarMessage::PointerButton(_) => KIND_POINTER_BUTTON,
        SidecarMessage::PointerWheel(_) => KIND_POINTER_WHEEL,
        SidecarMessage::KeyboardHid(_) => KIND_KEYBOARD_HID,
        SidecarMessage::ReleaseAll(_) => KIND_RELEASE_ALL,
        SidecarMessage::EdgeActivated(_) => KIND_EDGE_ACTIVATED,
        SidecarMessage::ReturnToLocal(_) => KIND_RETURN_TO_LOCAL,
        SidecarMessage::QuarantineRecovery(_) => KIND_QUARANTINE_RECOVERY,
        SidecarMessage::CleanupComplete(_) => KIND_CLEANUP_COMPLETE,
    }
}

#[allow(clippy::too_many_lines)]
fn encode_message(payload: &mut Vec<u8>, message: &SidecarMessage) -> Result<(), CodecError> {
    match message {
        SidecarMessage::InputLease(sidecar_lease) => {
            let lease = sidecar_lease.lease;
            validate_bound_peer(sidecar_lease.bound_peer)?;
            push_u64(payload, lease.generation);
            push_id(payload, lease.owner);
            push_id(payload, lease.route_to);
            payload.push(match lease.state {
                InputLeaseState::Offered => 1,
                InputLeaseState::Active => 2,
                InputLeaseState::Revoked => 3,
            });
            push_bound_peer(payload, sidecar_lease.bound_peer);
        }
        SidecarMessage::Pointer(pointer) => {
            if !pointer.x_dip.is_finite() || !pointer.y_dip.is_finite() {
                return Err(CodecError::NonFiniteCoordinate);
            }
            push_u64(payload, pointer.generation);
            push_id(payload, pointer.target);
            push_u64(payload, pointer.x_dip.to_bits());
            push_u64(payload, pointer.y_dip.to_bits());
        }
        SidecarMessage::Key(key) => {
            push_u64(payload, key.generation);
            push_id(payload, key.target);
            push_u32(payload, key.hid_usage);
            payload.push(u8::from(key.pressed));
        }
        SidecarMessage::RawHidReportBundle(bundle) => {
            if bundle.reports.len() > MAX_HID_REPORTS {
                return Err(CodecError::TooManyReports {
                    declared: bundle.reports.len(),
                    maximum: MAX_HID_REPORTS,
                });
            }
            push_u64(payload, bundle.generation);
            push_id(payload, bundle.device_id);
            payload.push(bundle.interface);
            push_u16(
                payload,
                u16::try_from(bundle.reports.len())
                    .map_err(|_| CodecError::InvalidPayload("report count overflow"))?,
            );
            for report in &bundle.reports {
                if report.bytes.len() > MAX_HID_REPORT_BYTES {
                    return Err(CodecError::ReportTooLarge {
                        declared: report.bytes.len(),
                        maximum: MAX_HID_REPORT_BYTES,
                    });
                }
                push_u64(payload, report.timestamp_ns);
                push_u16(
                    payload,
                    u16::try_from(report.bytes.len())
                        .map_err(|_| CodecError::InvalidPayload("report size overflow"))?,
                );
                payload.extend_from_slice(&report.bytes);
            }
        }
        SidecarMessage::RelativePointer(pointer) => {
            validate_input_header(
                pointer.generation,
                pointer.target_device,
                pointer.event_sequence,
            )?;
            validate_finite_pair(pointer.delta_x_dip, pointer.delta_y_dip)?;
            validate_apply_deadline(pointer.apply_deadline_monotonic_ns)?;
            push_input_header(
                payload,
                pointer.generation,
                pointer.target_device,
                pointer.event_sequence,
            );
            push_u64(payload, pointer.apply_deadline_monotonic_ns);
            push_u64(payload, pointer.delta_x_dip.to_bits());
            push_u64(payload, pointer.delta_y_dip.to_bits());
        }
        SidecarMessage::PointerButton(button) => {
            validate_input_header(
                button.generation,
                button.target_device,
                button.event_sequence,
            )?;
            validate_apply_deadline(button.apply_deadline_monotonic_ns)?;
            push_input_header(
                payload,
                button.generation,
                button.target_device,
                button.event_sequence,
            );
            push_u64(payload, button.apply_deadline_monotonic_ns);
            payload.push(encode_pointer_button(button.button));
            payload.push(encode_switch_state(button.state));
        }
        SidecarMessage::PointerWheel(wheel) => {
            validate_input_header(wheel.generation, wheel.target_device, wheel.event_sequence)?;
            validate_finite_pair(wheel.vertical_delta_detents, wheel.horizontal_delta_detents)?;
            validate_apply_deadline(wheel.apply_deadline_monotonic_ns)?;
            push_input_header(
                payload,
                wheel.generation,
                wheel.target_device,
                wheel.event_sequence,
            );
            push_u64(payload, wheel.apply_deadline_monotonic_ns);
            push_u64(payload, wheel.vertical_delta_detents.to_bits());
            push_u64(payload, wheel.horizontal_delta_detents.to_bits());
        }
        SidecarMessage::KeyboardHid(keyboard) => {
            validate_input_header(
                keyboard.generation,
                keyboard.target_device,
                keyboard.event_sequence,
            )?;
            if keyboard.usage_page == 0 || keyboard.usage_id == 0 {
                return Err(CodecError::InvalidPayload(
                    "HID usage page and usage ID must be non-zero",
                ));
            }
            validate_apply_deadline(keyboard.apply_deadline_monotonic_ns)?;
            push_input_header(
                payload,
                keyboard.generation,
                keyboard.target_device,
                keyboard.event_sequence,
            );
            push_u64(payload, keyboard.apply_deadline_monotonic_ns);
            push_u16(payload, keyboard.usage_page);
            push_u16(payload, keyboard.usage_id);
            payload.push(encode_switch_state(keyboard.state));
            payload.push(u8::from(keyboard.repeat));
        }
        SidecarMessage::ReleaseAll(release) => {
            validate_input_header(
                release.generation,
                release.target_device,
                release.event_sequence,
            )?;
            push_input_header(
                payload,
                release.generation,
                release.target_device,
                release.event_sequence,
            );
        }
        SidecarMessage::EdgeActivated(edge) => {
            validate_edge_position(edge.edge_position)?;
            if edge.route_generation == 0 || edge.source_display.0 == 0 || edge.route_to.0 == 0 {
                return Err(CodecError::InvalidPayload(
                    "edge activation identifiers must be non-zero",
                ));
            }
            push_u64(payload, edge.route_generation);
            push_id(payload, edge.source_display);
            push_id(payload, edge.route_to);
            payload.push(encode_edge(edge.edge));
            push_u64(payload, edge.edge_position.to_bits());
        }
        SidecarMessage::ReturnToLocal(command) => {
            validate_edge_position(command.edge_position)?;
            if command.generation == 0 || command.target_display.0 == 0 {
                return Err(CodecError::InvalidPayload(
                    "return command identifiers must be non-zero",
                ));
            }
            push_u64(payload, command.generation);
            push_id(payload, command.target_display);
            payload.push(encode_edge(command.edge));
            push_u64(payload, command.edge_position.to_bits());
        }
        SidecarMessage::QuarantineRecovery(recovery) => {
            let marker = recovery.marker.encode()?;
            validate_quarantine_recovery(recovery)?;
            payload.extend_from_slice(&marker[8..]);
            payload.extend_from_slice(&recovery.marker_sha256);
        }
        SidecarMessage::CleanupComplete(cleanup) => encode_cleanup_complete(payload, cleanup)?,
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn decode_message(kind: u8, cursor: &mut PayloadCursor<'_>) -> Result<SidecarMessage, CodecError> {
    match kind {
        KIND_INPUT_LEASE => {
            let generation = cursor.u64()?;
            let owner = cursor.id()?;
            let route_to = cursor.id()?;
            let state = match cursor.u8()? {
                1 => InputLeaseState::Offered,
                2 => InputLeaseState::Active,
                3 => InputLeaseState::Revoked,
                _ => return Err(CodecError::InvalidPayload("unknown input lease state")),
            };
            Ok(SidecarMessage::InputLease(SidecarInputLease {
                lease: InputLease {
                    generation,
                    owner,
                    route_to,
                    state,
                },
                bound_peer: decode_bound_peer(cursor)?,
            }))
        }
        KIND_POINTER => {
            let pointer = PointerInput {
                generation: cursor.u64()?,
                target: cursor.id()?,
                x_dip: f64::from_bits(cursor.u64()?),
                y_dip: f64::from_bits(cursor.u64()?),
            };
            if !pointer.x_dip.is_finite() || !pointer.y_dip.is_finite() {
                return Err(CodecError::NonFiniteCoordinate);
            }
            Ok(SidecarMessage::Pointer(pointer))
        }
        KIND_KEY => {
            let generation = cursor.u64()?;
            let target = cursor.id()?;
            let hid_usage = cursor.u32()?;
            let pressed = match cursor.u8()? {
                0 => false,
                1 => true,
                _ => {
                    return Err(CodecError::InvalidPayload(
                        "key pressed must be zero or one",
                    ));
                }
            };
            Ok(SidecarMessage::Key(KeyInput {
                generation,
                target,
                hid_usage,
                pressed,
            }))
        }
        KIND_RAW_HID_BUNDLE => {
            let generation = cursor.u64()?;
            let device_id = cursor.id()?;
            let interface = cursor.u8()?;
            let report_count = usize::from(cursor.u16()?);
            if report_count > MAX_HID_REPORTS {
                return Err(CodecError::TooManyReports {
                    declared: report_count,
                    maximum: MAX_HID_REPORTS,
                });
            }
            let mut reports = Vec::with_capacity(report_count);
            for _ in 0..report_count {
                let timestamp_ns = cursor.u64()?;
                let report_size = usize::from(cursor.u16()?);
                if report_size > MAX_HID_REPORT_BYTES {
                    return Err(CodecError::ReportTooLarge {
                        declared: report_size,
                        maximum: MAX_HID_REPORT_BYTES,
                    });
                }
                reports.push(RawHidReport {
                    timestamp_ns,
                    bytes: cursor.bytes(report_size)?.to_vec(),
                });
            }
            Ok(SidecarMessage::RawHidReportBundle(RawHidReportBundle {
                generation,
                device_id,
                interface,
                reports,
            }))
        }
        KIND_RELATIVE_POINTER => {
            let (generation, target_device, event_sequence) = decode_input_header(cursor)?;
            let apply_deadline_monotonic_ns = cursor.u64()?;
            validate_apply_deadline(apply_deadline_monotonic_ns)?;
            let motion_x = f64::from_bits(cursor.u64()?);
            let motion_y = f64::from_bits(cursor.u64()?);
            validate_finite_pair(motion_x, motion_y)?;
            Ok(SidecarMessage::RelativePointer(RelativePointerInput {
                generation,
                target_device,
                event_sequence,
                apply_deadline_monotonic_ns,
                delta_x_dip: motion_x,
                delta_y_dip: motion_y,
            }))
        }
        KIND_POINTER_BUTTON => {
            let (generation, target_device, event_sequence) = decode_input_header(cursor)?;
            let apply_deadline_monotonic_ns = cursor.u64()?;
            validate_apply_deadline(apply_deadline_monotonic_ns)?;
            Ok(SidecarMessage::PointerButton(PointerButtonInput {
                generation,
                target_device,
                event_sequence,
                apply_deadline_monotonic_ns,
                button: decode_pointer_button(cursor.u8()?)?,
                state: decode_switch_state(cursor.u8()?)?,
            }))
        }
        KIND_POINTER_WHEEL => {
            let (generation, target_device, event_sequence) = decode_input_header(cursor)?;
            let apply_deadline_monotonic_ns = cursor.u64()?;
            validate_apply_deadline(apply_deadline_monotonic_ns)?;
            let vertical_delta_detents = f64::from_bits(cursor.u64()?);
            let horizontal_delta_detents = f64::from_bits(cursor.u64()?);
            validate_finite_pair(vertical_delta_detents, horizontal_delta_detents)?;
            Ok(SidecarMessage::PointerWheel(PointerWheelInput {
                generation,
                target_device,
                event_sequence,
                apply_deadline_monotonic_ns,
                vertical_delta_detents,
                horizontal_delta_detents,
            }))
        }
        KIND_KEYBOARD_HID => {
            let (generation, target_device, event_sequence) = decode_input_header(cursor)?;
            let apply_deadline_monotonic_ns = cursor.u64()?;
            validate_apply_deadline(apply_deadline_monotonic_ns)?;
            let usage_page = cursor.u16()?;
            let usage_id = cursor.u16()?;
            if usage_page == 0 || usage_id == 0 {
                return Err(CodecError::InvalidPayload(
                    "HID usage page and usage ID must be non-zero",
                ));
            }
            let state = decode_switch_state(cursor.u8()?)?;
            let repeat = decode_bool(cursor.u8()?, "keyboard repeat must be zero or one")?;
            Ok(SidecarMessage::KeyboardHid(KeyboardHidInput {
                generation,
                target_device,
                event_sequence,
                apply_deadline_monotonic_ns,
                usage_page,
                usage_id,
                state,
                repeat,
            }))
        }
        KIND_RELEASE_ALL => {
            let (generation, target_device, event_sequence) = decode_input_header(cursor)?;
            Ok(SidecarMessage::ReleaseAll(ReleaseAllInput {
                generation,
                target_device,
                event_sequence,
            }))
        }
        KIND_EDGE_ACTIVATED => {
            let route_generation = cursor.u64()?;
            let source_display = cursor.id()?;
            let route_to = cursor.id()?;
            let edge = decode_edge(cursor.u8()?)?;
            let edge_position = f64::from_bits(cursor.u64()?);
            validate_edge_position(edge_position)?;
            if route_generation == 0 || source_display.0 == 0 || route_to.0 == 0 {
                return Err(CodecError::InvalidPayload(
                    "edge activation identifiers must be non-zero",
                ));
            }
            Ok(SidecarMessage::EdgeActivated(EdgeActivated {
                route_generation,
                source_display,
                route_to,
                edge,
                edge_position,
            }))
        }
        KIND_RETURN_TO_LOCAL => {
            let generation = cursor.u64()?;
            let target_display = cursor.id()?;
            let edge = decode_edge(cursor.u8()?)?;
            let edge_position = f64::from_bits(cursor.u64()?);
            validate_edge_position(edge_position)?;
            if generation == 0 || target_display.0 == 0 {
                return Err(CodecError::InvalidPayload(
                    "return command identifiers must be non-zero",
                ));
            }
            Ok(SidecarMessage::ReturnToLocal(ReturnToLocal {
                generation,
                target_display,
                edge,
                edge_position,
            }))
        }
        KIND_QUARANTINE_RECOVERY => {
            let body = cursor.bytes(QUARANTINE_RECOVERY_BODY_SIZE)?;
            let mut marker_bytes = [0_u8; DURABLE_QUARANTINE_MARKER_SIZE];
            marker_bytes[..8].copy_from_slice(&DURABLE_QUARANTINE_MARKER_MAGIC);
            marker_bytes[8..].copy_from_slice(&body[..144]);
            let marker = DurableQuarantineMarker::decode(&marker_bytes)?;
            let mut marker_sha256 = [0_u8; 32];
            marker_sha256.copy_from_slice(&body[144..]);
            if marker_sha256 != <[u8; 32]>::from(Sha256::digest(marker_bytes)) {
                return Err(CodecError::InvalidPayload(
                    "quarantine recovery marker SHA-256 does not match",
                ));
            }
            Ok(SidecarMessage::QuarantineRecovery(
                QuarantineRecoveryRequest {
                    marker,
                    marker_sha256,
                },
            ))
        }
        KIND_CLEANUP_COMPLETE => Ok(SidecarMessage::CleanupComplete(decode_cleanup_complete(
            cursor,
        )?)),
        _ => Err(CodecError::UnknownMessageKind(kind)),
    }
}

fn validate_input_header(
    generation: u64,
    target_device: DeviceId,
    event_sequence: u64,
) -> Result<(), CodecError> {
    if generation == 0 || target_device.0 == 0 || event_sequence == 0 {
        return Err(CodecError::InvalidPayload(
            "input generation, target, and event sequence must be non-zero",
        ));
    }
    Ok(())
}

fn validate_apply_deadline(deadline_ns: u64) -> Result<(), CodecError> {
    if deadline_ns == 0 {
        return Err(CodecError::InvalidPayload(
            "captured input apply deadline must be non-zero",
        ));
    }
    Ok(())
}

fn push_input_header(
    payload: &mut Vec<u8>,
    generation: u64,
    target_device: DeviceId,
    event_sequence: u64,
) {
    push_u64(payload, generation);
    push_id(payload, target_device);
    push_u64(payload, event_sequence);
}

fn decode_input_header(cursor: &mut PayloadCursor<'_>) -> Result<(u64, DeviceId, u64), CodecError> {
    let generation = cursor.u64()?;
    let target_device = cursor.id()?;
    let event_sequence = cursor.u64()?;
    validate_input_header(generation, target_device, event_sequence)?;
    Ok((generation, target_device, event_sequence))
}

fn validate_finite_pair(first: f64, second: f64) -> Result<(), CodecError> {
    if !first.is_finite() || !second.is_finite() {
        return Err(CodecError::NonFiniteCoordinate);
    }
    Ok(())
}

fn validate_edge_position(position: f64) -> Result<(), CodecError> {
    if !position.is_finite() || !(0.0..=1.0).contains(&position) {
        return Err(CodecError::InvalidPayload(
            "edge position must be finite and between zero and one",
        ));
    }
    Ok(())
}

const fn encode_pointer_button(button: PointerButton) -> u8 {
    match button {
        PointerButton::Left => 1,
        PointerButton::Middle => 2,
        PointerButton::Right => 3,
        PointerButton::Back => 4,
        PointerButton::Forward => 5,
    }
}

fn decode_pointer_button(value: u8) -> Result<PointerButton, CodecError> {
    match value {
        1 => Ok(PointerButton::Left),
        2 => Ok(PointerButton::Middle),
        3 => Ok(PointerButton::Right),
        4 => Ok(PointerButton::Back),
        5 => Ok(PointerButton::Forward),
        _ => Err(CodecError::InvalidPayload("unknown pointer button")),
    }
}

const fn encode_switch_state(state: InputSwitchState) -> u8 {
    match state {
        InputSwitchState::Pressed => 1,
        InputSwitchState::Released => 2,
    }
}

fn decode_switch_state(value: u8) -> Result<InputSwitchState, CodecError> {
    match value {
        1 => Ok(InputSwitchState::Pressed),
        2 => Ok(InputSwitchState::Released),
        _ => Err(CodecError::InvalidPayload("unknown input switch state")),
    }
}

const fn encode_edge(edge: SidecarEdge) -> u8 {
    match edge {
        SidecarEdge::Left => 1,
        SidecarEdge::Right => 2,
        SidecarEdge::Top => 3,
        SidecarEdge::Bottom => 4,
    }
}

fn decode_edge(value: u8) -> Result<SidecarEdge, CodecError> {
    match value {
        1 => Ok(SidecarEdge::Left),
        2 => Ok(SidecarEdge::Right),
        3 => Ok(SidecarEdge::Top),
        4 => Ok(SidecarEdge::Bottom),
        _ => Err(CodecError::InvalidPayload("unknown display edge")),
    }
}

fn decode_bool(value: u8, error: &'static str) -> Result<bool, CodecError> {
    match value {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(CodecError::InvalidPayload(error)),
    }
}

fn validate_bound_peer(peer: BoundPeerIdentity) -> Result<(), CodecError> {
    let has_nonzero_flowinfo = match peer.address {
        SocketAddr::V4(_) => false,
        SocketAddr::V6(address) => address.flowinfo() != 0,
    };
    if peer.epoch == 0
        || peer.address.port() == 0
        || peer.address.ip().is_unspecified()
        || has_nonzero_flowinfo
    {
        return Err(CodecError::InvalidPayload(
            "bound peer epoch, address, and port must form an exact non-zero identity",
        ));
    }
    Ok(())
}

fn push_bound_peer(payload: &mut Vec<u8>, peer: BoundPeerIdentity) {
    push_u64(payload, peer.epoch);
    match peer.address {
        SocketAddr::V4(address) => {
            payload.push(4);
            push_u16(payload, address.port());
            payload.extend_from_slice(&address.ip().octets());
            payload.extend_from_slice(&[0_u8; 12]);
            push_u32(payload, 0);
        }
        SocketAddr::V6(address) => {
            payload.push(6);
            push_u16(payload, address.port());
            payload.extend_from_slice(&address.ip().octets());
            push_u32(payload, address.scope_id());
        }
    }
}

fn decode_bound_peer(cursor: &mut PayloadCursor<'_>) -> Result<BoundPeerIdentity, CodecError> {
    let epoch = cursor.u64()?;
    let family = cursor.u8()?;
    let port = cursor.u16()?;
    let address = cursor.bytes(16)?;
    let scope_id = cursor.u32()?;
    let socket = match family {
        4 => {
            if address[4..].iter().any(|byte| *byte != 0) || scope_id != 0 {
                return Err(CodecError::InvalidPayload(
                    "IPv4 peer padding and scope must be zero",
                ));
            }
            SocketAddr::V4(SocketAddrV4::new(
                Ipv4Addr::new(address[0], address[1], address[2], address[3]),
                port,
            ))
        }
        6 => {
            let octets: [u8; 16] = address.try_into().map_err(|_| CodecError::FrameTooShort)?;
            SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::from(octets), port, 0, scope_id))
        }
        _ => {
            return Err(CodecError::InvalidPayload(
                "peer address family must be 4 or 6",
            ));
        }
    };
    let peer = BoundPeerIdentity {
        epoch,
        address: socket,
    };
    validate_bound_peer(peer)?;
    Ok(peer)
}

fn encode_socket_identity(bytes: &mut [u8], address: SocketAddr) -> Result<(), CodecError> {
    if bytes.len() != 24 || address.port() == 0 {
        return Err(CodecError::InvalidPayload(
            "marker peer socket storage or port is invalid",
        ));
    }
    match address {
        SocketAddr::V4(address) => {
            bytes[0] = 4;
            bytes[2..4].copy_from_slice(&address.port().to_be_bytes());
            bytes[8..12].copy_from_slice(&address.ip().octets());
        }
        SocketAddr::V6(address) => {
            bytes[0] = 6;
            bytes[2..4].copy_from_slice(&address.port().to_be_bytes());
            bytes[4..8].copy_from_slice(&address.scope_id().to_be_bytes());
            bytes[8..24].copy_from_slice(&address.ip().octets());
        }
    }
    Ok(())
}

fn decode_socket_identity(bytes: &[u8]) -> Result<SocketAddr, CodecError> {
    if bytes.len() != 24 || bytes[1] != 0 {
        return Err(CodecError::InvalidPayload(
            "marker peer socket reserved byte must be zero",
        ));
    }
    let port = u16::from_be_bytes(
        bytes[2..4]
            .try_into()
            .map_err(|_| CodecError::FrameTooShort)?,
    );
    let scope_id = u32::from_be_bytes(
        bytes[4..8]
            .try_into()
            .map_err(|_| CodecError::FrameTooShort)?,
    );
    match bytes[0] {
        4 => {
            if scope_id != 0 || bytes[12..24].iter().any(|byte| *byte != 0) {
                return Err(CodecError::InvalidPayload(
                    "marker IPv4 padding and scope must be zero",
                ));
            }
            Ok(SocketAddr::V4(SocketAddrV4::new(
                Ipv4Addr::new(bytes[8], bytes[9], bytes[10], bytes[11]),
                port,
            )))
        }
        6 => {
            let octets: [u8; 16] = bytes[8..24]
                .try_into()
                .map_err(|_| CodecError::FrameTooShort)?;
            Ok(SocketAddr::V6(SocketAddrV6::new(
                Ipv6Addr::from(octets),
                port,
                0,
                scope_id,
            )))
        }
        _ => Err(CodecError::InvalidPayload(
            "marker peer address family must be 4 or 6",
        )),
    }
}

fn validate_marker(marker: &DurableQuarantineMarker) -> Result<(), CodecError> {
    if marker.source_display.0 == 0
        || marker.target_device.0 == 0
        || marker.owner_device.0 == 0
        || marker.old_daemon_boot_id.0 == 0
        || marker.route_generation == 0
        || marker.active_lease_generation == 0
        || marker.old_daemon_pid == 0
        || marker.old_daemon_start_ticks == 0
        || marker.owner_device == marker.target_device
    {
        return Err(CodecError::InvalidPayload(
            "durable marker identities and generations must be non-zero and distinct",
        ));
    }
    validate_bound_peer(marker.bound_peer)
}

fn validate_quarantine_recovery(recovery: &QuarantineRecoveryRequest) -> Result<(), CodecError> {
    let marker = recovery.marker.encode()?;
    if recovery.marker_sha256 != <[u8; 32]>::from(Sha256::digest(marker)) {
        return Err(CodecError::InvalidPayload(
            "quarantine recovery marker SHA-256 does not match",
        ));
    }
    Ok(())
}

fn read_u64_at(bytes: &[u8], offset: usize) -> Result<u64, CodecError> {
    Ok(u64::from_be_bytes(
        bytes
            .get(offset..offset + 8)
            .ok_or(CodecError::FrameTooShort)?
            .try_into()
            .map_err(|_| CodecError::FrameTooShort)?,
    ))
}

fn read_u128_at(bytes: &[u8], offset: usize) -> Result<u128, CodecError> {
    Ok(u128::from_be_bytes(
        bytes
            .get(offset..offset + 16)
            .ok_or(CodecError::FrameTooShort)?
            .try_into()
            .map_err(|_| CodecError::FrameTooShort)?,
    ))
}

fn validate_cleanup_complete(cleanup: &CleanupComplete) -> Result<(), CodecError> {
    let recovery_sequence_valid = match cleanup.mode {
        CleanupMode::Normal => cleanup.recovery_request_sequence == 0,
        CleanupMode::Recovery => cleanup.recovery_request_sequence != 0,
    };
    let sequence_valid = match cleanup.sequence_disposition {
        SequenceDisposition::Exact => {
            cleanup.marker_last_sequence == cleanup.observed_last_sequence
        }
        SequenceDisposition::ProvenUnobservedReservation => {
            cleanup.observed_last_sequence.checked_add(1) == Some(cleanup.marker_last_sequence)
        }
    };
    let expected_release = cleanup
        .observed_last_sequence
        .checked_add(1)
        .ok_or(CodecError::InvalidPayload("cleanup sequence exhausted"))?;
    let expected_revoke =
        cleanup
            .active_lease_generation
            .checked_add(1)
            .ok_or(CodecError::InvalidPayload(
                "cleanup lease generation exhausted",
            ))?;
    let operation = cleanup.cleanup_operation_id.0;
    if !recovery_sequence_valid
        || cleanup.marker_sha256.iter().all(|byte| *byte == 0)
        || cleanup.cleanup_operation_id.0 == 0
        || cleanup.receipt_issued_at_unix_ms == 0
        || cleanup.receipt_issued_at_unix_ms >= cleanup.receipt_expires_at_unix_ms
        || cleanup.receipt_expires_at_unix_ms - cleanup.receipt_issued_at_unix_ms > 5_000
        || cleanup.source_display.0 == 0
        || cleanup.route_generation == 0
        || cleanup.target_device.0 == 0
        || cleanup.owner_device.0 == 0
        || cleanup.owner_device == cleanup.target_device
        || cleanup.active_lease_generation == 0
        || !sequence_valid
        || cleanup.release_all.generation != cleanup.active_lease_generation
        || cleanup.release_all.target_device != cleanup.target_device
        || cleanup.release_all.event_sequence != expected_release
        || !cleanup.release_all_applied
        || cleanup.revoke_operation_id != cleanup.cleanup_operation_id
        || cleanup.revoke_lease_generation != expected_revoke
        || cleanup.revoke_owner_device != cleanup.owner_device
        || cleanup.revoke_target_device != cleanup.target_device
        || cleanup.revoke_state != InputLeaseState::Revoked
        || !cleanup.revoke_applied
        || operation >> 64 != u128::from(cleanup.bound_peer.epoch)
        || operation & u128::from(u64::MAX) == 0
    {
        return Err(CodecError::InvalidPayload(
            "cleanup completion evidence is inconsistent",
        ));
    }
    validate_bound_peer(cleanup.bound_peer)
}

fn cleanup_matches_recovery(cleanup: &CleanupComplete, pending: PendingRecovery) -> bool {
    let marker = pending.request.marker;
    cleanup.recovery_request_sequence == pending.request_sequence
        && cleanup.marker_sha256 == pending.request.marker_sha256
        && cleanup.source_display == marker.source_display
        && cleanup.route_generation == marker.route_generation
        && cleanup.target_device == marker.target_device
        && cleanup.owner_device == marker.owner_device
        && cleanup.active_lease_generation == marker.active_lease_generation
        && cleanup.marker_last_sequence == marker.last_sequence
        && cleanup.bound_peer == marker.bound_peer
}

fn encode_cleanup_complete(
    payload: &mut Vec<u8>,
    cleanup: &CleanupComplete,
) -> Result<(), CodecError> {
    validate_cleanup_complete(cleanup)?;
    let start = payload.len();
    payload.push(cleanup.mode as u8);
    push_u64(payload, cleanup.recovery_request_sequence);
    payload.extend_from_slice(&cleanup.marker_sha256);
    push_id(payload, cleanup.cleanup_operation_id);
    push_u64(payload, cleanup.receipt_issued_at_unix_ms);
    push_u64(payload, cleanup.receipt_expires_at_unix_ms);
    push_id(payload, cleanup.source_display);
    push_u64(payload, cleanup.route_generation);
    push_id(payload, cleanup.target_device);
    push_id(payload, cleanup.owner_device);
    push_u64(payload, cleanup.active_lease_generation);
    push_u64(payload, cleanup.marker_last_sequence);
    push_u64(payload, cleanup.observed_last_sequence);
    payload.push(cleanup.sequence_disposition as u8);
    push_bound_peer(payload, cleanup.bound_peer);
    payload.push(1);
    push_u64(payload, cleanup.release_all.generation);
    push_id(payload, cleanup.release_all.target_device);
    push_u64(payload, cleanup.release_all.event_sequence);
    payload.push(u8::from(cleanup.release_all_applied));
    push_id(payload, cleanup.revoke_operation_id);
    push_u64(payload, cleanup.revoke_lease_generation);
    push_id(payload, cleanup.revoke_owner_device);
    push_id(payload, cleanup.revoke_target_device);
    payload.push(3);
    payload.push(u8::from(cleanup.revoke_applied));
    debug_assert_eq!(payload.len() - start, CLEANUP_COMPLETE_BODY_SIZE);
    Ok(())
}

fn decode_cleanup_complete(cursor: &mut PayloadCursor<'_>) -> Result<CleanupComplete, CodecError> {
    let body = cursor.bytes(CLEANUP_COMPLETE_BODY_SIZE)?;
    let mut body = PayloadCursor::new(body);
    let mode = match body.u8()? {
        1 => CleanupMode::Normal,
        2 => CleanupMode::Recovery,
        _ => {
            return Err(CodecError::InvalidPayload(
                "unknown cleanup completion mode",
            ));
        }
    };
    let recovery_request_sequence = body.u64()?;
    let marker_sha256 = body
        .bytes(32)?
        .try_into()
        .map_err(|_| CodecError::FrameTooShort)?;
    let cleanup_operation_id = body.id()?;
    let receipt_issued_at_unix_ms = body.u64()?;
    let receipt_expires_at_unix_ms = body.u64()?;
    let source_display = body.id()?;
    let route_generation = body.u64()?;
    let target_device = body.id()?;
    let owner_device = body.id()?;
    let active_lease_generation = body.u64()?;
    let marker_last_sequence = body.u64()?;
    let observed_last_sequence = body.u64()?;
    let sequence_disposition = match body.u8()? {
        1 => SequenceDisposition::Exact,
        2 => SequenceDisposition::ProvenUnobservedReservation,
        _ => return Err(CodecError::InvalidPayload("unknown sequence disposition")),
    };
    let bound_peer = decode_bound_peer(&mut body)?;
    if body.u8()? != 1 {
        return Err(CodecError::InvalidPayload("route-gone proof must be true"));
    }
    let release_all = ReleaseAllInput {
        generation: body.u64()?,
        target_device: body.id()?,
        event_sequence: body.u64()?,
    };
    let release_all_applied =
        decode_bool(body.u8()?, "ReleaseAll cleanup result must be zero or one")?;
    let revoke_operation_id = body.id()?;
    let revoke_lease_generation = body.u64()?;
    let revoke_owner_device = body.id()?;
    let revoke_target_device = body.id()?;
    let revoke_state = match body.u8()? {
        3 => InputLeaseState::Revoked,
        _ => {
            return Err(CodecError::InvalidPayload(
                "cleanup revoke state must be revoked",
            ));
        }
    };
    let revoke_applied = decode_bool(body.u8()?, "revoke result must be zero or one")?;
    body.finish()?;
    let cleanup = CleanupComplete {
        mode,
        recovery_request_sequence,
        marker_sha256,
        cleanup_operation_id,
        receipt_issued_at_unix_ms,
        receipt_expires_at_unix_ms,
        source_display,
        route_generation,
        target_device,
        owner_device,
        active_lease_generation,
        marker_last_sequence,
        observed_last_sequence,
        sequence_disposition,
        bound_peer,
        release_all,
        release_all_applied,
        revoke_operation_id,
        revoke_lease_generation,
        revoke_owner_device,
        revoke_target_device,
        revoke_state,
        revoke_applied,
    };
    validate_cleanup_complete(&cleanup)?;
    Ok(cleanup)
}

fn write_payload(writer: &mut impl Write, payload: &[u8]) -> Result<(), CodecError> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(CodecError::FrameTooLarge {
            declared: payload.len(),
            maximum: MAX_FRAME_BYTES,
        });
    }
    let size = u32::try_from(payload.len())
        .map_err(|_| CodecError::InvalidPayload("frame size overflow"))?;
    writer.write_all(&size.to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(())
}

fn read_payload(reader: &mut impl Read) -> Result<Option<Vec<u8>>, CodecError> {
    let mut prefix = [0_u8; 4];
    let mut read = 0;
    while read < prefix.len() {
        match reader.read(&mut prefix[read..]) {
            Ok(0) if read == 0 => return Ok(None),
            Ok(0) => return Err(CodecError::FrameTooShort),
            Ok(count) => read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(CodecError::Io(error)),
        }
    }
    let declared = usize::try_from(u32::from_be_bytes(prefix))
        .map_err(|_| CodecError::InvalidPayload("frame size conversion"))?;
    if declared > MAX_FRAME_BYTES {
        return Err(CodecError::FrameTooLarge {
            declared,
            maximum: MAX_FRAME_BYTES,
        });
    }
    let mut payload = vec![0; declared];
    reader
        .read_exact(&mut payload)
        .map_err(|error| match error.kind() {
            io::ErrorKind::UnexpectedEof => CodecError::FrameTooShort,
            _ => CodecError::Io(error),
        })?;
    Ok(Some(payload))
}

fn push_u16(bytes: &mut Vec<u8>, value: u16) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

fn push_u32(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

fn push_u64(bytes: &mut Vec<u8>, value: u64) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

fn push_id(bytes: &mut Vec<u8>, value: Id128) {
    bytes.extend_from_slice(&value.0.to_be_bytes());
}

struct PayloadCursor<'a> {
    remaining: &'a [u8],
}

impl<'a> PayloadCursor<'a> {
    const fn new(bytes: &'a [u8]) -> Self {
        Self { remaining: bytes }
    }

    fn bytes(&mut self, length: usize) -> Result<&'a [u8], CodecError> {
        if self.remaining.len() < length {
            return Err(CodecError::FrameTooShort);
        }
        let (value, remaining) = self.remaining.split_at(length);
        self.remaining = remaining;
        Ok(value)
    }

    fn u8(&mut self) -> Result<u8, CodecError> {
        Ok(self.bytes(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, CodecError> {
        let bytes: [u8; 2] = self
            .bytes(2)?
            .try_into()
            .map_err(|_| CodecError::FrameTooShort)?;
        Ok(u16::from_be_bytes(bytes))
    }

    fn u32(&mut self) -> Result<u32, CodecError> {
        let bytes: [u8; 4] = self
            .bytes(4)?
            .try_into()
            .map_err(|_| CodecError::FrameTooShort)?;
        Ok(u32::from_be_bytes(bytes))
    }

    fn u64(&mut self) -> Result<u64, CodecError> {
        let bytes: [u8; 8] = self
            .bytes(8)?
            .try_into()
            .map_err(|_| CodecError::FrameTooShort)?;
        Ok(u64::from_be_bytes(bytes))
    }

    fn id(&mut self) -> Result<Id128, CodecError> {
        let bytes: [u8; 16] = self
            .bytes(16)?
            .try_into()
            .map_err(|_| CodecError::FrameTooShort)?;
        Ok(Id128(u128::from_be_bytes(bytes)))
    }

    fn finish(self) -> Result<(), CodecError> {
        if self.remaining.is_empty() {
            Ok(())
        } else {
            Err(CodecError::InvalidPayload("trailing bytes"))
        }
    }
}

/// A Unix listener whose filesystem entry is owner-readable and owner-writable only.
#[cfg(unix)]
#[derive(Debug)]
pub struct LocalSidecarListener {
    listener: UnixListener,
    path: PathBuf,
    device: u64,
    inode: u64,
}

#[cfg(unix)]
impl LocalSidecarListener {
    /// Binds a new socket without removing or replacing an existing path.
    ///
    /// # Errors
    ///
    /// Returns an I/O error when the path cannot be bound or restricted to
    /// owner-only access.
    pub fn bind(path: impl AsRef<Path>) -> Result<Self, CodecError> {
        let path = path.as_ref();
        let listener = UnixListener::bind(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        let metadata = fs::metadata(path)?;
        Ok(Self {
            listener,
            path: path.to_owned(),
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Accepts one local stream.
    ///
    /// # Errors
    ///
    /// Returns an I/O error when accepting a connection fails.
    pub fn accept(&self) -> Result<UnixStream, CodecError> {
        let (stream, _) = self.listener.accept()?;
        Ok(stream)
    }
}

#[cfg(unix)]
impl Drop for LocalSidecarListener {
    fn drop(&mut self) {
        let still_owned = fs::symlink_metadata(&self.path)
            .is_ok_and(|metadata| metadata.dev() == self.device && metadata.ino() == self.inode);
        if still_owned {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// Reads, validates, dispatches, and acknowledges one request on a Unix stream.
///
/// # Errors
///
/// Returns a codec or I/O error when the request cannot be read or its response
/// cannot be written. Policy and backend rejections are sent as normal responses.
#[cfg(unix)]
pub fn serve_one(
    stream: &mut UnixStream,
    session: &mut SidecarSession,
    mut dispatch: impl FnMut(&SidecarEvent) -> Result<(), RejectCode>,
) -> Result<ServiceOutcome, CodecError> {
    let Some(request) = read_request(stream)? else {
        return Ok(ServiceOutcome::EndOfStream);
    };
    let sequence = request.sequence;
    let previous_session = session.clone();
    match session.accept(request) {
        Ok(event) => match dispatch(&event) {
            Ok(()) => {
                write_response(
                    stream,
                    SidecarResponse {
                        sequence,
                        result: Ok(()),
                    },
                )?;
                Ok(ServiceOutcome::Accepted(Box::new(event)))
            }
            Err(code) => {
                *session = previous_session;
                write_response(
                    stream,
                    SidecarResponse {
                        sequence,
                        result: Err(code),
                    },
                )?;
                Ok(ServiceOutcome::Rejected(code))
            }
        },
        Err(code) => {
            write_response(
                stream,
                SidecarResponse {
                    sequence,
                    result: Err(code),
                },
            )?;
            Ok(ServiceOutcome::Rejected(code))
        }
    }
}
