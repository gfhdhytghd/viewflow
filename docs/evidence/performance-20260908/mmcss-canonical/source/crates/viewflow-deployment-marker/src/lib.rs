//! Deployment-owned Deskflow quarantine marker contract.
//!
//! This format is deliberately unrelated to Deskflow's `VFQST002` runtime
//! recovery marker.  Deployment code must never publish this marker at the
//! runtime marker path or through the runtime marker environment variable.

use std::{error::Error, fmt};

use sha2::{Digest, Sha256};

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
pub use linux::DeploymentMarkerStore;

pub const DEPLOYMENT_MARKER_MAGIC: [u8; 8] = *b"VFDQT001";
pub const DEPLOYMENT_MARKER_SIZE: usize = 256;
pub const DEPLOYMENT_MARKER_FILE_NAME: &str = "deployment-quarantine.v1";
pub const DEPLOYMENT_MARKER_ENV: &str = "DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER";
pub const LINUX_DEPLOYMENT_MARKER_PARENT: &str = "/home/wilf/.local/state/viewflow";
pub const LINUX_DEPLOYMENT_MARKER_PATH: &str =
    "/home/wilf/.local/state/viewflow/deployment-quarantine.v1";
pub const DESKFLOW_RUNTIME_MARKER_MAGIC: [u8; 8] = *b"VFQST002";
pub const DESKFLOW_RUNTIME_MARKER_SIZE: usize = 152;
pub const DESKFLOW_RUNTIME_MARKER_FILE_NAME: &str = "deskflow-quarantine.v2";

pub const SCHEMA_VERSION: u8 = 1;
pub const STATE_ACTIVE: u8 = 1;
pub const PROTOCOL_MAJOR: u8 = 2;
pub const PROTOCOL_MINOR: u8 = 1;
pub const LIFECYCLE_OWNER_COORDINATOR: u8 = 1;

pub const OPERATION_ID_MAX_LEN: usize = 128;
pub const OPERATION_ID_OFFSET: usize = 16;
pub const SOURCE_DISPLAY_OFFSET: usize = 144;
pub const TARGET_DEVICE_OFFSET: usize = 160;
pub const COORDINATOR_INSTANCE_OFFSET: usize = 176;
pub const CREATED_AT_UNIX_MS_OFFSET: usize = 192;
pub const GENERATION_OFFSET: usize = 200;
pub const RESERVED_OFFSET: usize = 208;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeploymentQuarantineMarker {
    pub operation_id: String,
    pub source_display: [u8; 16],
    pub target_device: [u8; 16],
    pub coordinator_instance: [u8; 16],
    pub created_at_unix_ms: u64,
    pub generation: u64,
}

impl DeploymentQuarantineMarker {
    /// Encode the exact 256-byte v1 wire representation.
    ///
    /// # Errors
    ///
    /// Returns [`MarkerError`] when an identity, timestamp, generation, or
    /// operation ID violates the v1 contract.
    pub fn encode(&self) -> Result<[u8; DEPLOYMENT_MARKER_SIZE], MarkerError> {
        self.validate()?;
        let mut bytes = [0_u8; DEPLOYMENT_MARKER_SIZE];
        bytes[..8].copy_from_slice(&DEPLOYMENT_MARKER_MAGIC);
        bytes[8] = SCHEMA_VERSION;
        bytes[9] = STATE_ACTIVE;
        bytes[10] = PROTOCOL_MAJOR;
        bytes[11] = PROTOCOL_MINOR;
        bytes[12] = LIFECYCLE_OWNER_COORDINATOR;
        bytes[13] =
            u8::try_from(self.operation_id.len()).map_err(|_| MarkerError::InvalidOperationId)?;
        bytes[OPERATION_ID_OFFSET..OPERATION_ID_OFFSET + self.operation_id.len()]
            .copy_from_slice(self.operation_id.as_bytes());
        bytes[SOURCE_DISPLAY_OFFSET..TARGET_DEVICE_OFFSET].copy_from_slice(&self.source_display);
        bytes[TARGET_DEVICE_OFFSET..COORDINATOR_INSTANCE_OFFSET]
            .copy_from_slice(&self.target_device);
        bytes[COORDINATOR_INSTANCE_OFFSET..CREATED_AT_UNIX_MS_OFFSET]
            .copy_from_slice(&self.coordinator_instance);
        bytes[CREATED_AT_UNIX_MS_OFFSET..GENERATION_OFFSET]
            .copy_from_slice(&self.created_at_unix_ms.to_le_bytes());
        bytes[GENERATION_OFFSET..RESERVED_OFFSET].copy_from_slice(&self.generation.to_le_bytes());
        Ok(bytes)
    }

    /// Decode and validate the exact v1 representation.
    ///
    /// # Errors
    ///
    /// Returns [`MarkerError`] for any size, magic, version, state, owner,
    /// padding, reserved-byte, or field validation failure.
    pub fn decode(bytes: &[u8]) -> Result<Self, MarkerError> {
        if bytes.len() != DEPLOYMENT_MARKER_SIZE {
            return Err(MarkerError::WrongSize {
                actual: bytes.len(),
            });
        }
        if bytes[..8] != DEPLOYMENT_MARKER_MAGIC {
            return Err(MarkerError::WrongMagic);
        }
        if bytes[8] != SCHEMA_VERSION {
            return Err(MarkerError::UnsupportedSchema(bytes[8]));
        }
        if bytes[9] != STATE_ACTIVE {
            return Err(MarkerError::UnsupportedState(bytes[9]));
        }
        if (bytes[10], bytes[11]) != (PROTOCOL_MAJOR, PROTOCOL_MINOR) {
            return Err(MarkerError::UnsupportedProtocol {
                major: bytes[10],
                minor: bytes[11],
            });
        }
        if bytes[12] != LIFECYCLE_OWNER_COORDINATOR {
            return Err(MarkerError::UnsupportedLifecycleOwner(bytes[12]));
        }
        if bytes[14] != 0 || bytes[15] != 0 || bytes[RESERVED_OFFSET..].iter().any(|b| *b != 0) {
            return Err(MarkerError::ReservedBytesNonZero);
        }

        let operation_len = usize::from(bytes[13]);
        if !(16..=OPERATION_ID_MAX_LEN).contains(&operation_len) {
            return Err(MarkerError::InvalidOperationId);
        }
        let operation_end = OPERATION_ID_OFFSET + operation_len;
        if bytes[operation_end..SOURCE_DISPLAY_OFFSET]
            .iter()
            .any(|b| *b != 0)
        {
            return Err(MarkerError::OperationPaddingNonZero);
        }
        let operation_id = std::str::from_utf8(&bytes[OPERATION_ID_OFFSET..operation_end])
            .map_err(|_| MarkerError::InvalidOperationId)?
            .to_owned();

        let marker = Self {
            operation_id,
            source_display: read_array(bytes, SOURCE_DISPLAY_OFFSET)?,
            target_device: read_array(bytes, TARGET_DEVICE_OFFSET)?,
            coordinator_instance: read_array(bytes, COORDINATOR_INSTANCE_OFFSET)?,
            created_at_unix_ms: u64::from_le_bytes(read_array(bytes, CREATED_AT_UNIX_MS_OFFSET)?),
            generation: u64::from_le_bytes(read_array(bytes, GENERATION_OFFSET)?),
        };
        marker.validate()?;
        Ok(marker)
    }

    fn validate(&self) -> Result<(), MarkerError> {
        if !validate_operation_id(&self.operation_id) {
            return Err(MarkerError::InvalidOperationId);
        }
        if all_zero(&self.source_display) {
            return Err(MarkerError::ZeroSourceDisplay);
        }
        if all_zero(&self.target_device) {
            return Err(MarkerError::ZeroTargetDevice);
        }
        if all_zero(&self.coordinator_instance) {
            return Err(MarkerError::ZeroCoordinatorInstance);
        }
        if self.created_at_unix_ms == 0 {
            return Err(MarkerError::ZeroCreatedAt);
        }
        if self.generation == 0 {
            return Err(MarkerError::ZeroGeneration);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MarkerFingerprint {
    pub operation_id: String,
    pub coordinator_instance: [u8; 16],
    pub generation: u64,
    pub content_sha256: [u8; 32],
}

impl MarkerFingerprint {
    #[must_use]
    pub fn content_sha256_hex(&self) -> String {
        hex_lower(&self.content_sha256)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LoadedDeploymentMarker {
    pub marker: DeploymentQuarantineMarker,
    pub fingerprint: MarkerFingerprint,
}

#[derive(Debug)]
pub enum MarkerError {
    WrongSize {
        actual: usize,
    },
    WrongMagic,
    UnsupportedSchema(u8),
    UnsupportedState(u8),
    UnsupportedProtocol {
        major: u8,
        minor: u8,
    },
    UnsupportedLifecycleOwner(u8),
    ReservedBytesNonZero,
    OperationPaddingNonZero,
    InvalidOperationId,
    ZeroSourceDisplay,
    ZeroTargetDevice,
    ZeroCoordinatorInstance,
    ZeroCreatedAt,
    ZeroGeneration,
    PathMustBeAbsolute,
    UnsafeParent,
    UnsafeMarker,
    MarkerMissing,
    MarkerAlreadyExists,
    AuthorizationMismatch,
    Io {
        action: &'static str,
        source: std::io::Error,
    },
}

impl fmt::Display for MarkerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WrongSize { actual } => write!(
                formatter,
                "deployment marker must be exactly {DEPLOYMENT_MARKER_SIZE} bytes, got {actual}"
            ),
            Self::WrongMagic => formatter.write_str("deployment marker magic is not VFDQT001"),
            Self::UnsupportedSchema(value) => {
                write!(formatter, "unsupported deployment marker schema {value}")
            }
            Self::UnsupportedState(value) => {
                write!(formatter, "unsupported deployment marker state {value}")
            }
            Self::UnsupportedProtocol { major, minor } => {
                write!(formatter, "unsupported deployment protocol {major}.{minor}")
            }
            Self::UnsupportedLifecycleOwner(value) => {
                write!(formatter, "unsupported deployment lifecycle owner {value}")
            }
            Self::ReservedBytesNonZero => {
                formatter.write_str("deployment marker reserved bytes must be zero")
            }
            Self::OperationPaddingNonZero => {
                formatter.write_str("deployment operation ID padding must be zero")
            }
            Self::InvalidOperationId => formatter.write_str("invalid deployment operation ID"),
            Self::ZeroSourceDisplay => formatter.write_str("source display must be non-zero"),
            Self::ZeroTargetDevice => formatter.write_str("target device must be non-zero"),
            Self::ZeroCoordinatorInstance => {
                formatter.write_str("coordinator instance must be non-zero")
            }
            Self::ZeroCreatedAt => formatter.write_str("creation timestamp must be non-zero"),
            Self::ZeroGeneration => formatter.write_str("generation must be non-zero"),
            Self::PathMustBeAbsolute => formatter.write_str("marker parent path must be absolute"),
            Self::UnsafeParent => formatter.write_str("marker parent metadata is unsafe"),
            Self::UnsafeMarker => formatter.write_str("marker file metadata is unsafe"),
            Self::MarkerMissing => formatter.write_str("deployment marker is missing"),
            Self::MarkerAlreadyExists => formatter.write_str("deployment marker already exists"),
            Self::AuthorizationMismatch => {
                formatter.write_str("deployment marker release authorization mismatch")
            }
            Self::Io { action, source } => write!(formatter, "{action}: {source}"),
        }
    }
}

impl Error for MarkerError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

pub(crate) fn fingerprint(marker: &DeploymentQuarantineMarker, bytes: &[u8]) -> MarkerFingerprint {
    MarkerFingerprint {
        operation_id: marker.operation_id.clone(),
        coordinator_instance: marker.coordinator_instance,
        generation: marker.generation,
        content_sha256: Sha256::digest(bytes).into(),
    }
}

/// Return whether `value` is an exact deployment marker operation ID.
#[must_use]
pub fn validate_operation_id(value: &str) -> bool {
    (16..=OPERATION_ID_MAX_LEN).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

fn all_zero(value: &[u8; 16]) -> bool {
    value.iter().all(|byte| *byte == 0)
}

fn read_array<const N: usize>(bytes: &[u8], offset: usize) -> Result<[u8; N], MarkerError> {
    bytes
        .get(offset..offset.saturating_add(N))
        .and_then(|slice| slice.try_into().ok())
        .ok_or(MarkerError::WrongSize {
            actual: bytes.len(),
        })
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(char::from(HEX[usize::from(byte >> 4)]));
        output.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    output
}
