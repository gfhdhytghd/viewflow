use std::{net::SocketAddr, path::PathBuf};

use anyhow::{Result, bail};
use quinn::Connection;
#[cfg(any(windows, test))]
use serde::{Deserialize, Serialize};
use tokio::sync::watch;
use viewflow_protocol::Id128;
#[cfg(any(windows, test))]
use viewflow_protocol::PROTOCOL_VERSION;

use crate::input_runtime::ClockSnapshot;

#[cfg(windows)]
const REQUIRED_WINDOWS_SESSION_ID: u32 = 1;
const MAX_READINESS_PROBE_RTT_NS: u64 = 33_333_334;
const MAX_READINESS_CLOCK_UNCERTAINTY_NS: u64 = 4_000_000;

#[cfg(any(windows, test))]
const READINESS_SCHEMA_VERSION: u32 = 1;
#[cfg(any(windows, test))]
const READINESS_LOCK_STATE: &str = "viewflow-post-mtls-readiness-lock";
#[cfg(any(windows, test))]
const READINESS_RECEIPT_STATE: &str = "viewflow-post-mtls-readiness-established";
#[cfg(any(windows, test))]
const READINESS_RECEIPT_VALIDITY: &str = "while-readiness-lock-is-held";
#[cfg(any(windows, test))]
const COMMIT_REQUEST_SCHEMA_VERSION: u32 = 5;
#[cfg(any(windows, test))]
const COMMIT_REQUEST_STATE: &str = "viewflow-install-commit-request";
#[cfg(any(windows, test))]
const INSTALL_SUCCESS_SCHEMA_VERSION: u32 = 5;
#[cfg(any(windows, test))]
const INSTALL_SUCCESS_STATE: &str = "viewflow-v2-windows-installed";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReadinessCommitConfig {
    pub request: PathBuf,
    pub install_success_receipt: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReadinessConfig {
    pub receipt: PathBuf,
    pub lock: PathBuf,
    pub operation_id: String,
    pub commit: Option<ReadinessCommitConfig>,
}

#[derive(Debug)]
pub(crate) struct ReadinessGuard {
    #[cfg(windows)]
    lock: Option<std::fs::File>,
    #[cfg(windows)]
    lock_path: PathBuf,
    #[cfg(windows)]
    receipt_path: PathBuf,
    #[cfg(windows)]
    binding: ReadinessBinding,
}

#[cfg(any(windows, test))]
#[derive(Clone, Debug, Eq, PartialEq)]
struct ReadinessBinding {
    operation_id: String,
    daemon_pid: u32,
    daemon_process_start_filetime: String,
    daemon_session_id: u32,
    daemon_user_sid: String,
    connection_generation: u64,
    readiness_receipt_sha256: String,
    readiness_lock_sha256: String,
    readiness_established_at_utc: String,
    peer_address: String,
    local_device_id: String,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
enum CommitMode {
    #[serde(rename = "normal-v2")]
    NormalV2,
    #[serde(rename = "bootstrap-v1.3")]
    BootstrapV13,
}

/// A JSON null-or-SHA value whose field itself is still mandatory.  Using an
/// enum instead of `Option<String>` makes serde reject a missing field while
/// preserving the protocol's explicit `null` representation.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Eq, PartialEq)]
enum ExplicitNullableSha256 {
    Null,
    Sha256(String),
}

#[cfg(any(windows, test))]
impl Serialize for ExplicitNullableSha256 {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            Self::Null => serializer.serialize_none(),
            Self::Sha256(value) => serializer.serialize_str(value),
        }
    }
}

#[cfg(any(windows, test))]
impl<'de> Deserialize<'de> for ExplicitNullableSha256 {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct Visitor;

        impl serde::de::Visitor<'_> for Visitor {
            type Value = ExplicitNullableSha256;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("an explicit null or a SHA-256 string")
            }

            fn visit_none<E>(self) -> std::result::Result<Self::Value, E> {
                Ok(ExplicitNullableSha256::Null)
            }

            fn visit_unit<E>(self) -> std::result::Result<Self::Value, E> {
                Ok(ExplicitNullableSha256::Null)
            }

            fn visit_str<E>(self, value: &str) -> std::result::Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(ExplicitNullableSha256::Sha256(value.to_owned()))
            }

            fn visit_string<E>(self, value: String) -> std::result::Result<Self::Value, E> {
                Ok(ExplicitNullableSha256::Sha256(value))
            }
        }

        deserializer.deserialize_any(Visitor)
    }
}

#[cfg(any(windows, test))]
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ReadinessCommitRequest {
    schema_version: u32,
    state: String,
    mode: CommitMode,
    operation_id: String,
    commit_nonce: String,
    daemon_pid: u32,
    daemon_process_start_filetime: String,
    connection_generation: u64,
    readiness_receipt_sha256: String,
    readiness_lock_sha256: String,
    linux_frozen_evidence_sha256: String,
    force_release_receipt_sha256: ExplicitNullableSha256,
    marker_handoff_receipt_sha256: ExplicitNullableSha256,
    windows_prepared_receipt_sha256: ExplicitNullableSha256,
    mutation_permit_sha256: ExplicitNullableSha256,
    linux_stage_receipt_sha256: ExplicitNullableSha256,
    bootstrap_request_sha256: ExplicitNullableSha256,
    old_viewflow_executable_sha256: String,
    new_viewflow_executable_sha256: String,
    installed_wrapper_sha256: String,
    scheduled_task_xml_sha256: String,
    requested_at_utc: String,
}

#[cfg(any(windows, test))]
#[derive(Debug, Serialize)]
struct InstallSuccessReceipt {
    schema_version: u32,
    state: String,
    operation_id: String,
    commit_nonce: String,
    commit_request_sha256: String,
    commit_mode: CommitMode,
    committed_by_daemon: bool,
    linux_frozen_evidence_sha256: String,
    force_release_receipt_sha256: ExplicitNullableSha256,
    marker_handoff_receipt_sha256: ExplicitNullableSha256,
    windows_prepared_receipt_sha256: ExplicitNullableSha256,
    mutation_permit_sha256: ExplicitNullableSha256,
    linux_stage_receipt_sha256: ExplicitNullableSha256,
    bootstrap_request_sha256: ExplicitNullableSha256,
    readiness_receipt_sha256: String,
    readiness_lock_sha256: String,
    readiness_connection_generation: u64,
    readiness_established_at_utc: String,
    old_viewflow_executable_sha256: String,
    new_viewflow_executable_sha256: String,
    installed_wrapper_sha256: String,
    scheduled_task_xml_sha256: String,
    new_process_pid: u32,
    new_process_start_filetime: String,
    new_process_session_id: u32,
    new_process_user_sid: String,
    protocol_version: String,
    peer: String,
    device_id: String,
    completed_at_utc: String,
    committed_at_utc: String,
}

#[cfg(any(windows, test))]
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ReadinessLockPayload {
    schema_version: u32,
    state: String,
    operation_id: String,
    daemon_pid: u32,
    daemon_process_start_filetime: String,
    connection_generation: u64,
}

#[cfg(any(windows, test))]
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ReadinessReceipt {
    schema_version: u32,
    state: String,
    validity: String,
    operation_id: String,
    daemon_executable_sha256: String,
    daemon_pid: u32,
    daemon_process_start_filetime: String,
    daemon_session_id: u32,
    daemon_user_sid: String,
    connection_generation: u64,
    input_backend: String,
    local_device_id: String,
    peer_address: String,
    server_name: String,
    protocol_major: u16,
    protocol_minor: u16,
    probe_round_trip_ns: u64,
    probe_max_round_trip_ns: u64,
    probe_uncertainty_ns: u64,
    probe_max_uncertainty_ns: u64,
    readiness_lock_path: String,
    readiness_lock_sha256: String,
    established_at_utc: String,
}

#[cfg(any(windows, test))]
struct ReadinessReceiptInput<'a> {
    operation_id: &'a str,
    executable_sha256: &'a str,
    pid: u32,
    process_start_filetime: &'a str,
    session_id: u32,
    user_sid: &'a str,
    connection_generation: u64,
    local_device_id: &'a str,
    peer_address: &'a str,
    server_name: &'a str,
    probe_round_trip_ns: u64,
    probe_uncertainty_ns: u64,
    lock_path: &'a str,
    lock_sha256: &'a str,
    established_at_utc: &'a str,
}

#[cfg(any(windows, test))]
fn readiness_receipt(input: &ReadinessReceiptInput<'_>) -> ReadinessReceipt {
    ReadinessReceipt {
        schema_version: READINESS_SCHEMA_VERSION,
        state: READINESS_RECEIPT_STATE.to_owned(),
        validity: READINESS_RECEIPT_VALIDITY.to_owned(),
        operation_id: input.operation_id.to_owned(),
        daemon_executable_sha256: input.executable_sha256.to_owned(),
        daemon_pid: input.pid,
        daemon_process_start_filetime: input.process_start_filetime.to_owned(),
        daemon_session_id: input.session_id,
        daemon_user_sid: input.user_sid.to_owned(),
        connection_generation: input.connection_generation,
        input_backend: "native".to_owned(),
        local_device_id: input.local_device_id.to_owned(),
        peer_address: input.peer_address.to_owned(),
        server_name: input.server_name.to_owned(),
        protocol_major: PROTOCOL_VERSION.major,
        protocol_minor: PROTOCOL_VERSION.minor,
        probe_round_trip_ns: input.probe_round_trip_ns,
        probe_max_round_trip_ns: MAX_READINESS_PROBE_RTT_NS,
        probe_uncertainty_ns: input.probe_uncertainty_ns,
        probe_max_uncertainty_ns: MAX_READINESS_CLOCK_UNCERTAINTY_NS,
        readiness_lock_path: input.lock_path.to_owned(),
        readiness_lock_sha256: input.lock_sha256.to_owned(),
        established_at_utc: input.established_at_utc.to_owned(),
    }
}

#[cfg(any(windows, test))]
fn validate_revoked_evidence(
    operation_id: &str,
    current_pid: u32,
    current_process_start_filetime: &str,
    current_generation: u64,
    expected_lock_path: &str,
    receipt_bytes: Option<&[u8]>,
    lock_bytes: Option<&[u8]>,
) -> Result<()> {
    use sha2::Digest;

    if receipt_bytes.is_none() && lock_bytes.is_none() {
        bail!("revoked readiness validation requires at least one artifact");
    }

    let receipt = receipt_bytes
        .map(|bytes| {
            serde_json::from_slice::<ReadinessReceipt>(bytes)
                .map_err(anyhow::Error::from)
                .and_then(|receipt| {
                    validate_receipt_constants(&receipt)?;
                    validate_stale_identity(
                        "readiness receipt",
                        operation_id,
                        current_pid,
                        current_process_start_filetime,
                        current_generation,
                        &receipt.operation_id,
                        receipt.daemon_pid,
                        &receipt.daemon_process_start_filetime,
                        receipt.connection_generation,
                    )?;
                    if receipt.readiness_lock_path != expected_lock_path {
                        bail!("stale readiness receipt names a different lock path");
                    }
                    Ok(receipt)
                })
        })
        .transpose()?;

    let lock = lock_bytes
        .map(|bytes| {
            serde_json::from_slice::<ReadinessLockPayload>(bytes)
                .map_err(anyhow::Error::from)
                .and_then(|lock| {
                    validate_lock_constants(&lock)?;
                    validate_stale_identity(
                        "readiness lock",
                        operation_id,
                        current_pid,
                        current_process_start_filetime,
                        current_generation,
                        &lock.operation_id,
                        lock.daemon_pid,
                        &lock.daemon_process_start_filetime,
                        lock.connection_generation,
                    )?;
                    Ok(lock)
                })
        })
        .transpose()?;

    if let (Some(receipt), Some(lock), Some(lock_bytes)) = (&receipt, &lock, lock_bytes) {
        if receipt.connection_generation != lock.connection_generation {
            bail!("stale readiness receipt and lock generations differ");
        }
        let lock_sha256 = format!("{:x}", sha2::Sha256::digest(lock_bytes));
        if receipt.readiness_lock_sha256 != lock_sha256 {
            bail!("stale readiness receipt does not hash the exact lock bytes");
        }
    }
    Ok(())
}

#[cfg(any(windows, test))]
#[allow(clippy::too_many_arguments)]
fn validate_stale_identity(
    artifact: &str,
    operation_id: &str,
    current_pid: u32,
    current_process_start_filetime: &str,
    current_generation: u64,
    artifact_operation_id: &str,
    artifact_pid: u32,
    artifact_process_start_filetime: &str,
    artifact_generation: u64,
) -> Result<()> {
    if artifact_operation_id != operation_id
        || artifact_pid != current_pid
        || artifact_process_start_filetime != current_process_start_filetime
    {
        bail!("{artifact} does not belong to this daemon process instance and operation");
    }
    if artifact_generation == 0 || artifact_generation >= current_generation {
        bail!(
            "{artifact} generation {artifact_generation} is not older than current generation {current_generation}"
        );
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn validate_lock_constants(lock: &ReadinessLockPayload) -> Result<()> {
    if lock.schema_version != READINESS_SCHEMA_VERSION || lock.state != READINESS_LOCK_STATE {
        bail!("stale readiness lock has an unsupported schema or state");
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn validate_receipt_constants(receipt: &ReadinessReceipt) -> Result<()> {
    if receipt.schema_version != READINESS_SCHEMA_VERSION
        || receipt.state != READINESS_RECEIPT_STATE
        || receipt.validity != READINESS_RECEIPT_VALIDITY
        || receipt.input_backend != "native"
        || receipt.protocol_major != PROTOCOL_VERSION.major
        || receipt.protocol_minor != PROTOCOL_VERSION.minor
        || receipt.probe_max_round_trip_ns != MAX_READINESS_PROBE_RTT_NS
        || receipt.probe_max_uncertainty_ns != MAX_READINESS_CLOCK_UNCERTAINTY_NS
        || receipt.probe_round_trip_ns > receipt.probe_max_round_trip_ns
        || receipt.probe_uncertainty_ns > receipt.probe_max_uncertainty_ns
        || receipt.daemon_session_id != 1
        || !receipt.daemon_user_sid.starts_with("S-")
        || !is_lower_hex(&receipt.daemon_executable_sha256, 64)
        || !is_lower_hex(&receipt.local_device_id, 32)
        || !is_lower_hex(&receipt.readiness_lock_sha256, 64)
        || receipt.server_name.is_empty()
        || receipt.peer_address.is_empty()
        || receipt.established_at_utc.len() != 24
        || !receipt.established_at_utc.ends_with('Z')
    {
        bail!("stale readiness receipt has unsupported or non-qualifying semantics");
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn is_lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(any(windows, test))]
fn is_canonical_utc_millis(value: &str) -> bool {
    if value.len() != 24 || !value.ends_with('Z') {
        return false;
    }
    value.bytes().enumerate().all(|(index, byte)| match index {
        4 | 7 => byte == b'-',
        10 => byte == b'T',
        13 | 16 => byte == b':',
        19 => byte == b'.',
        23 => byte == b'Z',
        _ => byte.is_ascii_digit(),
    })
}

#[cfg(any(windows, test))]
fn validate_mode_sha256_bindings(request: &ReadinessCommitRequest) -> Result<()> {
    let bootstrap_bindings = [
        &request.force_release_receipt_sha256,
        &request.marker_handoff_receipt_sha256,
        &request.windows_prepared_receipt_sha256,
        &request.mutation_permit_sha256,
        &request.linux_stage_receipt_sha256,
        &request.bootstrap_request_sha256,
    ];
    match request.mode {
        CommitMode::NormalV2
            if bootstrap_bindings
                .iter()
                .all(|binding| matches!(binding, ExplicitNullableSha256::Null)) =>
        {
            Ok(())
        }
        CommitMode::BootstrapV13 => {
            let hashes = bootstrap_bindings
                .iter()
                .map(|binding| match binding {
                    ExplicitNullableSha256::Sha256(hash) if is_lower_hex(hash, 64) => Ok(hash),
                    _ => Err(anyhow::anyhow!(
                        "bootstrap-v1.3 commit request requires lowercase SHA-256 bootstrap evidence hashes"
                    )),
                })
                .collect::<Result<Vec<_>>>()?;
            let unique = hashes
                .iter()
                .copied()
                .collect::<std::collections::BTreeSet<_>>();
            if unique.len() != hashes.len() {
                bail!("bootstrap-v1.3 evidence hashes must not substitute for one another");
            }
            Ok(())
        }
        CommitMode::NormalV2 => {
            bail!("normal-v2 commit request must use null bootstrap evidence hashes")
        }
    }
}

#[cfg(any(windows, test))]
fn validate_commit_linearization_preconditions(
    guard_held: bool,
    connection_close_reason: Option<&str>,
) -> Result<()> {
    if !guard_held {
        bail!("readiness lock guard was revoked before install commit");
    }
    if let Some(reason) = connection_close_reason {
        bail!("connection closed before install commit linearization: {reason}");
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn validate_commit_request(
    request: &ReadinessCommitRequest,
    binding: &ReadinessBinding,
) -> Result<()> {
    if request.schema_version != COMMIT_REQUEST_SCHEMA_VERSION
        || request.state != COMMIT_REQUEST_STATE
    {
        bail!("install commit request has an unsupported schema or state");
    }
    if request.operation_id != binding.operation_id
        || request.daemon_pid != binding.daemon_pid
        || request.daemon_process_start_filetime != binding.daemon_process_start_filetime
        || request.connection_generation != binding.connection_generation
        || request.readiness_receipt_sha256 != binding.readiness_receipt_sha256
        || request.readiness_lock_sha256 != binding.readiness_lock_sha256
    {
        bail!("install commit request does not bind the live readiness generation");
    }
    if !is_lower_hex(&request.commit_nonce, 32)
        || !is_lower_hex(&request.readiness_receipt_sha256, 64)
        || !is_lower_hex(&request.readiness_lock_sha256, 64)
        || !is_lower_hex(&request.linux_frozen_evidence_sha256, 64)
        || !is_lower_hex(&request.old_viewflow_executable_sha256, 64)
        || !is_lower_hex(&request.new_viewflow_executable_sha256, 64)
        || !is_lower_hex(&request.installed_wrapper_sha256, 64)
        || !is_lower_hex(&request.scheduled_task_xml_sha256, 64)
        || !is_canonical_utc_millis(&request.requested_at_utc)
    {
        bail!("install commit request contains a malformed nonce, hash, or timestamp");
    }
    validate_mode_sha256_bindings(request)?;
    Ok(())
}

#[cfg(any(windows, test))]
fn install_success_receipt(
    request: ReadinessCommitRequest,
    request_sha256: String,
    binding: &ReadinessBinding,
    committed_at_utc: String,
) -> InstallSuccessReceipt {
    InstallSuccessReceipt {
        schema_version: INSTALL_SUCCESS_SCHEMA_VERSION,
        state: INSTALL_SUCCESS_STATE.to_owned(),
        operation_id: request.operation_id,
        commit_nonce: request.commit_nonce,
        commit_request_sha256: request_sha256,
        commit_mode: request.mode,
        committed_by_daemon: true,
        linux_frozen_evidence_sha256: request.linux_frozen_evidence_sha256,
        force_release_receipt_sha256: request.force_release_receipt_sha256,
        marker_handoff_receipt_sha256: request.marker_handoff_receipt_sha256,
        windows_prepared_receipt_sha256: request.windows_prepared_receipt_sha256,
        mutation_permit_sha256: request.mutation_permit_sha256,
        linux_stage_receipt_sha256: request.linux_stage_receipt_sha256,
        bootstrap_request_sha256: request.bootstrap_request_sha256,
        readiness_receipt_sha256: request.readiness_receipt_sha256,
        readiness_lock_sha256: request.readiness_lock_sha256,
        readiness_connection_generation: request.connection_generation,
        readiness_established_at_utc: binding.readiness_established_at_utc.clone(),
        old_viewflow_executable_sha256: request.old_viewflow_executable_sha256,
        new_viewflow_executable_sha256: request.new_viewflow_executable_sha256,
        installed_wrapper_sha256: request.installed_wrapper_sha256,
        scheduled_task_xml_sha256: request.scheduled_task_xml_sha256,
        new_process_pid: binding.daemon_pid,
        new_process_start_filetime: binding.daemon_process_start_filetime.clone(),
        new_process_session_id: binding.daemon_session_id,
        new_process_user_sid: binding.daemon_user_sid.clone(),
        protocol_version: format!("{}.{}", PROTOCOL_VERSION.major, PROTOCOL_VERSION.minor),
        peer: binding.peer_address.clone(),
        device_id: binding.local_device_id.clone(),
        completed_at_utc: committed_at_utc.clone(),
        committed_at_utc,
    }
}

/// Rejects stale or non-Windows readiness targets before opening the endpoint.
pub(crate) fn validate_readiness_startup(config: Option<&ReadinessConfig>) -> Result<()> {
    let Some(config) = config else {
        return Ok(());
    };
    #[cfg(not(windows))]
    {
        let _ = config;
        bail!("post-mTLS readiness evidence is only available on Windows");
    }
    #[cfg(windows)]
    {
        windows::validate_new_artifact_path(&config.receipt, "readiness receipt")?;
        windows::validate_new_artifact_path(&config.lock, "readiness lock")?;
        if let Some(commit) = &config.commit {
            windows::validate_new_artifact_path(&commit.request, "readiness commit request")?;
            windows::validate_new_artifact_path(
                &commit.install_success_receipt,
                "install-success receipt",
            )?;
        }
        Ok(())
    }
}

/// Consumes a complete request, if present, and synchronously commits the
/// daemon-authored install-success receipt while the readiness guard is held.
/// There are deliberately no await points in this function.
pub(crate) fn try_commit_readiness(
    connection: &Connection,
    config: &ReadinessConfig,
    guard: &ReadinessGuard,
) -> Result<bool> {
    let Some(commit) = &config.commit else {
        return Ok(false);
    };
    #[cfg(not(windows))]
    {
        let _ = (connection, commit, guard);
        bail!("readiness commit is only available on Windows");
    }
    #[cfg(windows)]
    {
        windows::try_commit(connection, commit, guard)
    }
}

/// Waits for the first completed bidirectional clock probe. That probe can only
/// complete after mTLS, the control writer, the client receiver, and the native
/// input receiver have all been initialized by `run_client_connection`.
pub(crate) async fn establish_readiness(
    config: Option<ReadinessConfig>,
    mut snapshots: watch::Receiver<Option<ClockSnapshot>>,
    peer_address: SocketAddr,
    server_name: String,
    device_id: Option<Id128>,
    connection_generation: u64,
) -> Result<ReadinessGuard> {
    let Some(config) = config else {
        return std::future::pending().await;
    };
    let snapshot = wait_for_first_snapshot(&mut snapshots).await?;
    let Some(device_id) = device_id else {
        bail!("post-mTLS readiness lost its required local device identity");
    };
    #[cfg(not(windows))]
    {
        let _ = (
            config,
            snapshot,
            peer_address,
            server_name,
            device_id,
            connection_generation,
        );
        bail!("post-mTLS readiness evidence is only available on Windows");
    }
    #[cfg(windows)]
    {
        windows::publish(
            &config,
            snapshot,
            peer_address,
            &server_name,
            device_id,
            connection_generation,
        )
    }
}

async fn wait_for_first_snapshot(
    snapshots: &mut watch::Receiver<Option<ClockSnapshot>>,
) -> Result<ClockSnapshot> {
    loop {
        if let Some(snapshot) = *snapshots.borrow()
            && snapshot.estimate.network_round_trip_ns <= MAX_READINESS_PROBE_RTT_NS
            && snapshot.estimate.uncertainty_ns <= MAX_READINESS_CLOCK_UNCERTAINTY_NS
        {
            return Ok(snapshot);
        }
        snapshots
            .changed()
            .await
            .map_err(|_| anyhow::anyhow!("clock probe loop stopped before readiness"))?;
    }
}

#[cfg(windows)]
mod windows {
    #![allow(unsafe_code)]

    use std::{
        ffi::{OsStr, c_void},
        fs::File,
        io::{BufReader, Read, Write},
        mem::size_of,
        os::windows::{ffi::OsStrExt, io::AsRawHandle, io::FromRawHandle},
        path::{Component, Path},
        ptr::null_mut,
    };

    use anyhow::{Context, Result, anyhow, bail};
    use quinn::Connection;
    use serde::Serialize;
    use sha2::{Digest, Sha256};
    use viewflow_protocol::Id128;
    use windows_sys::Win32::{
        Foundation::{
            CloseHandle, ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, FILETIME, GENERIC_READ,
            GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE, LocalFree, SYSTEMTIME,
        },
        Security::{
            Authorization::{
                ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
                SDDL_REVISION_1,
            },
            GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY,
            TOKEN_USER, TokenUser,
        },
        Storage::FileSystem::{
            CREATE_NEW, CreateFileW, DELETE, FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_REPARSE_POINT,
            FILE_ATTRIBUTE_TAG_INFO, FILE_DISPOSITION_INFO, FILE_FLAG_OPEN_REPARSE_POINT,
            FILE_SHARE_READ, FILE_STANDARD_INFO, FileAttributeTagInfo, FileDispositionInfo,
            FileStandardInfo, GetFileInformationByHandleEx, MOVEFILE_WRITE_THROUGH, MoveFileExW,
            OPEN_EXISTING, SetFileInformationByHandle,
        },
        System::{
            RemoteDesktop::ProcessIdToSessionId,
            SystemInformation::GetSystemTime,
            Threading::{
                GetCurrentProcess, GetCurrentProcessId, GetProcessTimes, OpenProcessToken,
            },
        },
    };

    use super::{
        READINESS_LOCK_STATE, READINESS_SCHEMA_VERSION, REQUIRED_WINDOWS_SESSION_ID,
        ReadinessBinding, ReadinessCommitConfig, ReadinessCommitRequest, ReadinessConfig,
        ReadinessGuard, ReadinessLockPayload, ReadinessReceiptInput, install_success_receipt,
        readiness_receipt, validate_commit_linearization_preconditions, validate_commit_request,
        validate_revoked_evidence,
    };
    use crate::input_runtime::ClockSnapshot;

    pub(super) fn validate_new_artifact_path(path: &Path, name: &str) -> Result<()> {
        if !path.is_absolute() || path.file_name().is_none() {
            bail!("{name} must be an absolute file path: {}", path.display());
        }
        if path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
        {
            bail!("{name} must not contain '.' or '..': {}", path.display());
        }
        match path.symlink_metadata() {
            Ok(_) => bail!("{name} already exists: {}", path.display()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| format!("failed to inspect {name}"));
            }
        }
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .ok_or_else(|| anyhow!("{name} has no parent directory"))?;
        if !parent
            .metadata()
            .with_context(|| format!("failed to inspect {name} parent {}", parent.display()))?
            .is_dir()
        {
            bail!("{name} parent is not a directory: {}", parent.display());
        }
        Ok(())
    }

    pub(super) fn publish(
        config: &ReadinessConfig,
        snapshot: ClockSnapshot,
        peer_address: std::net::SocketAddr,
        server_name: &str,
        device_id: Id128,
        connection_generation: u64,
    ) -> Result<ReadinessGuard> {
        let pid = current_pid();
        let session_id = current_session_id(pid)?;
        if session_id != REQUIRED_WINDOWS_SESSION_ID {
            bail!(
                "post-mTLS readiness requires Windows Session {REQUIRED_WINDOWS_SESSION_ID}; current session is {session_id}"
            );
        }
        let process_start_filetime = current_process_start_filetime()?.to_string();
        let user_sid = current_user_sid()?;
        let executable = std::env::current_exe().context("failed to locate running viewflowd")?;
        let executable_sha256 = sha256_path(&executable)?;
        let local_device_id = format!("{:032x}", device_id.0);
        let peer_address = peer_address.to_string();
        let lock_path = config
            .lock
            .to_str()
            .ok_or_else(|| anyhow!("readiness lock path is not valid Unicode"))?;
        clear_revoked_previous_generation(
            config,
            pid,
            &process_start_filetime,
            connection_generation,
            lock_path,
        )?;
        validate_new_artifact_path(&config.receipt, "readiness receipt")?;
        validate_new_artifact_path(&config.lock, "readiness lock")?;
        let established_at_utc = completed_at_utc();
        let lock_payload = ReadinessLockPayload {
            schema_version: READINESS_SCHEMA_VERSION,
            state: READINESS_LOCK_STATE.to_owned(),
            operation_id: config.operation_id.clone(),
            daemon_pid: pid,
            daemon_process_start_filetime: process_start_filetime.clone(),
            connection_generation,
        };
        let mut lock_bytes = serde_json::to_vec_pretty(&lock_payload)
            .context("failed to serialize readiness lock")?;
        lock_bytes.push(b'\n');
        let lock_sha256 = format!("{:x}", Sha256::digest(&lock_bytes));
        let lock = create_live_lock(&config.lock, &user_sid, &lock_bytes)?;

        let receipt = readiness_receipt(&ReadinessReceiptInput {
            operation_id: &config.operation_id,
            executable_sha256: &executable_sha256,
            pid,
            process_start_filetime: &process_start_filetime,
            session_id,
            user_sid: &user_sid,
            connection_generation,
            local_device_id: &local_device_id,
            peer_address: &peer_address,
            server_name,
            probe_round_trip_ns: snapshot.estimate.network_round_trip_ns,
            probe_uncertainty_ns: snapshot.estimate.uncertainty_ns,
            lock_path,
            lock_sha256: &lock_sha256,
            established_at_utc: &established_at_utc,
        });
        let receipt_bytes = json_bytes(&receipt, "post-mTLS readiness receipt")?;
        let receipt_sha256 = format!("{:x}", Sha256::digest(&receipt_bytes));
        if let Err(error) = write_owner_only_bytes(
            &config.receipt,
            &user_sid,
            &receipt_bytes,
            "readiness receipt",
            "readiness.tmp",
            || Ok(()),
        ) {
            drop(lock);
            let _ = std::fs::remove_file(&config.lock);
            return Err(error);
        }
        let guard = ReadinessGuard {
            lock: Some(lock),
            lock_path: config.lock.clone(),
            receipt_path: config.receipt.clone(),
            binding: ReadinessBinding {
                operation_id: config.operation_id.clone(),
                daemon_pid: pid,
                daemon_process_start_filetime: process_start_filetime,
                daemon_session_id: session_id,
                daemon_user_sid: user_sid,
                connection_generation,
                readiness_receipt_sha256: receipt_sha256,
                readiness_lock_sha256: lock_sha256,
                readiness_established_at_utc: established_at_utc,
                peer_address: peer_address.clone(),
                local_device_id,
            },
        };
        println!(
            "viewflowd client post-mTLS readiness established peer={peer_address} operation_id={} receipt={} lock={}",
            config.operation_id,
            config.receipt.display(),
            config.lock.display()
        );
        Ok(guard)
    }

    pub(super) fn try_commit(
        connection: &Connection,
        config: &ReadinessCommitConfig,
        guard: &ReadinessGuard,
    ) -> Result<bool> {
        if let Some(reason) = connection.close_reason() {
            bail!("connection closed before install commit request: {reason}");
        }
        let Some(request_file) = open_optional_commit_request(&config.request)? else {
            return Ok(false);
        };
        let request_bytes = read_claimed_artifact(&request_file, "readiness commit request")?;
        let request: ReadinessCommitRequest = serde_json::from_slice(&request_bytes)
            .context("readiness commit request is not strict schema-5 JSON")?;
        validate_commit_request(&request, &guard.binding)?;
        let request_sha256 = format!("{:x}", Sha256::digest(&request_bytes));
        let committed_at_utc = completed_at_utc();
        let success =
            install_success_receipt(request, request_sha256, &guard.binding, committed_at_utc);
        let success_bytes = json_bytes(&success, "install-success receipt")?;
        write_owner_only_bytes(
            &config.install_success_receipt,
            &guard.binding.daemon_user_sid,
            &success_bytes,
            "install-success receipt",
            "commit.tmp",
            || {
                let close_reason = connection.close_reason().map(|reason| reason.to_string());
                validate_commit_linearization_preconditions(
                    guard.lock.is_some(),
                    close_reason.as_deref(),
                )
            },
        )?;
        drop(request_file);
        println!(
            "viewflowd committed authenticated install success operation_id={} receipt={}",
            guard.binding.operation_id,
            config.install_success_receipt.display()
        );
        Ok(true)
    }

    fn clear_revoked_previous_generation(
        config: &ReadinessConfig,
        pid: u32,
        process_start_filetime: &str,
        connection_generation: u64,
        lock_path: &str,
    ) -> Result<()> {
        let receipt = claim_optional_artifact(&config.receipt, "stale readiness receipt")?;
        let lock = claim_optional_artifact(&config.lock, "stale readiness lock")?;
        if receipt.is_none() && lock.is_none() {
            return Ok(());
        }
        let receipt_bytes = receipt
            .as_ref()
            .map(|file| read_claimed_artifact(file, "stale readiness receipt"))
            .transpose()?;
        let lock_bytes = lock
            .as_ref()
            .map(|file| read_claimed_artifact(file, "stale readiness lock"))
            .transpose()?;
        validate_revoked_evidence(
            &config.operation_id,
            pid,
            process_start_filetime,
            connection_generation,
            lock_path,
            receipt_bytes.as_deref(),
            lock_bytes.as_deref(),
        )
        .context("refusing to remove untrusted readiness artifacts")?;
        if let Some(receipt) = &receipt {
            mark_delete_on_close(receipt, "stale readiness receipt")?;
        }
        if let Some(lock) = &lock {
            mark_delete_on_close(lock, "stale readiness lock")?;
        }
        drop(receipt);
        drop(lock);
        Ok(())
    }

    fn claim_optional_artifact(path: &Path, name: &str) -> Result<Option<File>> {
        let wide_path = wide_null(path.as_os_str());
        // SAFETY: path remains live for the call. Share mode zero is the
        // cleanup proof: a still-held readiness lock cannot be claimed.
        let handle = unsafe {
            CreateFileW(
                wide_path.as_ptr(),
                GENERIC_READ | GENERIC_WRITE | DELETE,
                0,
                null_mut(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            let error = std::io::Error::last_os_error();
            if matches!(
                error.raw_os_error().map(|code| code as u32),
                Some(ERROR_FILE_NOT_FOUND) | Some(ERROR_PATH_NOT_FOUND)
            ) {
                return Ok(None);
            }
            return Err(error).with_context(|| {
                format!(
                    "{name} is still held or cannot be claimed for cleanup: {}",
                    path.display()
                )
            });
        }
        // SAFETY: the opened handle is owned and compatible with File.
        Ok(Some(unsafe { File::from_raw_handle(handle) }))
    }

    fn open_optional_commit_request(path: &Path) -> Result<Option<File>> {
        let wide_path = wide_null(path.as_os_str());
        // SAFETY: path remains live for the call. Share mode zero pins the
        // exact request bytes through the success-receipt linearization point.
        let handle = unsafe {
            CreateFileW(
                wide_path.as_ptr(),
                GENERIC_READ,
                0,
                null_mut(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            let error = std::io::Error::last_os_error();
            if matches!(
                error.raw_os_error().map(|code| code as u32),
                Some(ERROR_FILE_NOT_FOUND) | Some(ERROR_PATH_NOT_FOUND)
            ) {
                return Ok(None);
            }
            return Err(error).with_context(|| {
                format!(
                    "readiness commit request cannot be exclusively pinned: {}",
                    path.display()
                )
            });
        }
        // SAFETY: the opened handle is owned and compatible with File.
        Ok(Some(unsafe { File::from_raw_handle(handle) }))
    }

    fn read_claimed_artifact(file: &File, name: &str) -> Result<Vec<u8>> {
        const MAX_ARTIFACT_BYTES: i64 = 64 * 1024;

        let handle = file.as_raw_handle();
        let mut attributes = FILE_ATTRIBUTE_TAG_INFO::default();
        // SAFETY: file handle is live and the output buffer is writable.
        if unsafe {
            GetFileInformationByHandleEx(
                handle,
                FileAttributeTagInfo,
                (&raw mut attributes).cast(),
                u32::try_from(size_of::<FILE_ATTRIBUTE_TAG_INFO>()).unwrap(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("failed to inspect {name} attributes"));
        }
        if attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            bail!("{name} must not be a reparse point");
        }

        let mut standard = FILE_STANDARD_INFO::default();
        // SAFETY: file handle is live and the output buffer is writable.
        if unsafe {
            GetFileInformationByHandleEx(
                handle,
                FileStandardInfo,
                (&raw mut standard).cast(),
                u32::try_from(size_of::<FILE_STANDARD_INFO>()).unwrap(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("failed to inspect {name} size"));
        }
        if standard.Directory || standard.DeletePending {
            bail!("{name} is a directory or already pending deletion");
        }
        if !(0..=MAX_ARTIFACT_BYTES).contains(&standard.EndOfFile) {
            bail!("{name} exceeds the 64 KiB evidence limit");
        }
        let mut bytes = Vec::with_capacity(usize::try_from(standard.EndOfFile).unwrap());
        let mut reader = file;
        reader
            .read_to_end(&mut bytes)
            .with_context(|| format!("failed to read {name} through its claimed handle"))?;
        if i64::try_from(bytes.len()).unwrap_or(i64::MAX) != standard.EndOfFile {
            bail!("{name} size changed while it was exclusively claimed");
        }
        Ok(bytes)
    }

    fn mark_delete_on_close(file: &File, name: &str) -> Result<()> {
        let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
        // SAFETY: file handle is live and disposition points to initialized
        // storage for the duration of the call.
        if unsafe {
            SetFileInformationByHandle(
                file.as_raw_handle(),
                FileDispositionInfo,
                (&raw const disposition).cast(),
                u32::try_from(size_of::<FILE_DISPOSITION_INFO>()).unwrap(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("failed to mark {name} for deletion"));
        }
        Ok(())
    }

    fn create_live_lock(path: &Path, sid: &str, bytes: &[u8]) -> Result<File> {
        let descriptor = SecurityDescriptor::for_sid(sid)?;
        let mut file = create_owner_only_new_file(
            path,
            descriptor.0,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ,
        )
        .with_context(|| format!("failed to create readiness lock {}", path.display()))?;
        let result = (|| -> Result<()> {
            file.write_all(bytes)
                .with_context(|| format!("failed to write readiness lock {}", path.display()))?;
            file.sync_all()
                .with_context(|| format!("failed to flush readiness lock {}", path.display()))?;
            Ok(())
        })();
        if let Err(error) = result {
            drop(file);
            let _ = std::fs::remove_file(path);
            return Err(error);
        }
        Ok(file)
    }

    fn json_bytes<T: Serialize>(value: &T, name: &str) -> Result<Vec<u8>> {
        let mut bytes = serde_json::to_vec_pretty(value)
            .with_context(|| format!("failed to serialize {name}"))?;
        bytes.push(b'\n');
        Ok(bytes)
    }

    fn write_owner_only_bytes(
        path: &Path,
        sid: &str,
        bytes: &[u8],
        name: &str,
        temporary_suffix: &str,
        before_move: impl FnOnce() -> Result<()>,
    ) -> Result<()> {
        validate_new_artifact_path(path, name)?;
        let descriptor = SecurityDescriptor::for_sid(sid)?;
        let parent = path.parent().expect("validated absolute path has a parent");
        let leaf = path
            .file_name()
            .expect("validated path has a file name")
            .to_string_lossy();
        let (temporary, mut file) = (0..64_u32)
            .find_map(|attempt| {
                let candidate = parent.join(format!(
                    ".{leaf}.{}.{attempt}.{temporary_suffix}",
                    current_pid()
                ));
                match create_owner_only_new_file(&candidate, descriptor.0, GENERIC_WRITE, 0) {
                    Ok(file) => Some(Ok((candidate, file))),
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => None,
                    Err(error) => Some(Err(error)),
                }
            })
            .transpose()
            .context("failed to create owner-only temporary readiness receipt")?
            .ok_or_else(|| anyhow!("could not allocate a temporary readiness receipt"))?;
        let result = (|| -> Result<()> {
            file.write_all(bytes)
                .with_context(|| format!("failed to write {}", temporary.display()))?;
            file.sync_all()
                .with_context(|| format!("failed to flush {}", temporary.display()))?;
            drop(file);
            before_move()?;
            move_without_replace(&temporary, path, name)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result
    }

    fn create_owner_only_new_file(
        path: &Path,
        descriptor: PSECURITY_DESCRIPTOR,
        access: u32,
        sharing: u32,
    ) -> std::io::Result<File> {
        let wide_path = wide_null(path.as_os_str());
        let attributes = SECURITY_ATTRIBUTES {
            nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>()).unwrap(),
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        // SAFETY: path and descriptor remain live for the call. A successful
        // handle is uniquely transferred into File.
        let handle = unsafe {
            CreateFileW(
                wide_path.as_ptr(),
                access,
                sharing,
                &attributes,
                CREATE_NEW,
                FILE_ATTRIBUTE_NORMAL,
                null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: the new handle is owned and compatible with File.
        Ok(unsafe { File::from_raw_handle(handle) })
    }

    fn move_without_replace(source: &Path, destination: &Path, name: &str) -> Result<()> {
        let source = wide_null(source.as_os_str());
        let destination = wide_null(destination.as_os_str());
        // SAFETY: both UTF-16 paths remain live and no replace flag is supplied.
        if unsafe {
            MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                MOVEFILE_WRITE_THROUGH,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("failed to publish {name} without replacement"));
        }
        Ok(())
    }

    fn current_pid() -> u32 {
        // SAFETY: GetCurrentProcessId has no preconditions.
        unsafe { GetCurrentProcessId() }
    }

    fn current_session_id(pid: u32) -> Result<u32> {
        let mut session_id = 0;
        // SAFETY: session_id is writable.
        if unsafe { ProcessIdToSessionId(pid, &mut session_id) } == 0 {
            return Err(std::io::Error::last_os_error()).context("ProcessIdToSessionId failed");
        }
        Ok(session_id)
    }

    fn current_process_start_filetime() -> Result<u64> {
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        // SAFETY: the pseudo process handle is valid and outputs are writable.
        if unsafe {
            GetProcessTimes(
                GetCurrentProcess(),
                &mut creation,
                &mut exit,
                &mut kernel,
                &mut user,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error()).context("GetProcessTimes failed");
        }
        Ok((u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime))
    }

    fn current_user_sid() -> Result<String> {
        let mut token = null_mut();
        // SAFETY: token is writable and process pseudo handle is valid.
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
            return Err(std::io::Error::last_os_error()).context("OpenProcessToken failed");
        }
        let token = OwnedHandle(token);
        let mut required = 0;
        // SAFETY: documented size query form.
        unsafe { GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut required) };
        if required < u32::try_from(size_of::<TOKEN_USER>()).unwrap() {
            bail!("GetTokenInformation returned an invalid TokenUser size");
        }
        let word_size = size_of::<usize>();
        let words = usize::try_from(required)
            .context("TokenUser size does not fit usize")?
            .div_ceil(word_size);
        let mut buffer = vec![0_usize; words];
        // SAFETY: aligned buffer contains at least required bytes.
        if unsafe {
            GetTokenInformation(
                token.0,
                TokenUser,
                buffer.as_mut_ptr().cast(),
                required,
                &mut required,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error()).context("GetTokenInformation failed");
        }
        // SAFETY: TokenUser initialized at aligned buffer start.
        let sid = unsafe { (*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid };
        let mut sid_string = null_mut();
        // SAFETY: sid is valid and output is LocalAlloc-owned.
        if unsafe { ConvertSidToStringSidW(sid, &mut sid_string) } == 0 {
            return Err(std::io::Error::last_os_error()).context("ConvertSidToStringSidW failed");
        }
        let sid_string = LocalAllocation(sid_string.cast());
        wide_ptr_to_string(sid_string.0.cast())
    }

    fn sha256_path(path: &Path) -> Result<String> {
        let file =
            File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
        let mut reader = BufReader::new(file);
        let mut digest = Sha256::new();
        let mut buffer = [0_u8; 64 * 1024];
        loop {
            let count = reader
                .read(&mut buffer)
                .with_context(|| format!("failed to read {}", path.display()))?;
            if count == 0 {
                break;
            }
            digest.update(&buffer[..count]);
        }
        Ok(format!("{:x}", digest.finalize()))
    }

    fn completed_at_utc() -> String {
        let mut now = SYSTEMTIME::default();
        // SAFETY: now is writable and GetSystemTime has no failure mode.
        unsafe { GetSystemTime(&mut now) };
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
            now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds
        )
    }

    struct SecurityDescriptor(PSECURITY_DESCRIPTOR);

    impl SecurityDescriptor {
        fn for_sid(sid: &str) -> Result<Self> {
            let sddl = wide_null(OsStr::new(&format!("O:{sid}D:P(A;;FA;;;{sid})")));
            let mut descriptor = null_mut();
            // SAFETY: SDDL is null-terminated and output receives LocalAlloc memory.
            if unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    null_mut(),
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error())
                    .context("failed to create owner-only readiness ACL");
            }
            Ok(Self(descriptor))
        }
    }

    impl Drop for SecurityDescriptor {
        fn drop(&mut self) {
            // SAFETY: descriptor is LocalAlloc-owned and freed once.
            unsafe { LocalFree(self.0.cast()) };
        }
    }

    struct OwnedHandle(HANDLE);

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            // SAFETY: token handle is owned and closed once.
            unsafe { CloseHandle(self.0) };
        }
    }

    struct LocalAllocation(*mut c_void);

    impl Drop for LocalAllocation {
        fn drop(&mut self) {
            // SAFETY: allocation came from LocalAlloc and is freed once.
            unsafe { LocalFree(self.0) };
        }
    }

    fn wide_null(value: &OsStr) -> Vec<u16> {
        value.encode_wide().chain(Some(0)).collect()
    }

    fn wide_ptr_to_string(pointer: *const u16) -> Result<String> {
        if pointer.is_null() {
            bail!("Windows returned a null UTF-16 string");
        }
        let mut length = 0;
        // SAFETY: caller owns a valid null-terminated Windows string.
        unsafe {
            while *pointer.add(length) != 0 {
                length += 1;
            }
            Ok(String::from_utf16(std::slice::from_raw_parts(
                pointer, length,
            ))?)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn fixture_directory(name: &str) -> std::path::PathBuf {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            std::env::temp_dir().join(format!(
                "viewflow-readiness-{name}-{}-{nonce}",
                current_pid()
            ))
        }

        #[test]
        fn install_success_replay_cannot_replace_linearized_receipt() {
            let directory = fixture_directory("replay");
            std::fs::create_dir(&directory).unwrap();
            let destination = directory.join("install-success.json");
            let sid = current_user_sid().unwrap();
            write_owner_only_bytes(
                &destination,
                &sid,
                b"first\n",
                "install-success receipt",
                "commit.tmp",
                || Ok(()),
            )
            .unwrap();
            assert!(
                write_owner_only_bytes(
                    &destination,
                    &sid,
                    b"replay\n",
                    "install-success receipt",
                    "commit.tmp",
                    || Ok(()),
                )
                .is_err()
            );
            assert_eq!(std::fs::read(&destination).unwrap(), b"first\n");
            std::fs::remove_file(destination).unwrap();
            std::fs::remove_dir(directory).unwrap();
        }

        #[test]
        fn disconnect_before_move_publishes_no_install_success_ack() {
            let directory = fixture_directory("disconnect");
            std::fs::create_dir(&directory).unwrap();
            let destination = directory.join("install-success.json");
            let sid = current_user_sid().unwrap();
            assert!(
                write_owner_only_bytes(
                    &destination,
                    &sid,
                    b"must-not-publish\n",
                    "install-success receipt",
                    "commit.tmp",
                    || bail!("connection closed before install commit linearization"),
                )
                .is_err()
            );
            assert!(!destination.exists());
            assert_eq!(std::fs::read_dir(&directory).unwrap().count(), 0);
            std::fs::remove_dir(directory).unwrap();
        }
    }
}

#[cfg(windows)]
impl Drop for ReadinessGuard {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.receipt_path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            eprintln!(
                "viewflowd failed to remove revoked readiness receipt {}: {error}",
                self.receipt_path.display()
            );
        }
        drop(self.lock.take());
        if let Err(error) = std::fs::remove_file(&self.lock_path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            eprintln!(
                "viewflowd failed to remove revoked readiness lock {}: {error}",
                self.lock_path.display()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use serde_json::Value;
    use sha2::Digest;

    use super::{
        CommitMode, ExplicitNullableSha256, ReadinessBinding, ReadinessCommitRequest,
        ReadinessLockPayload, ReadinessReceipt, ReadinessReceiptInput, install_success_receipt,
        readiness_receipt, validate_commit_linearization_preconditions, validate_commit_request,
        validate_revoked_evidence,
    };

    fn keys(value: &Value) -> BTreeSet<String> {
        value
            .as_object()
            .expect("fixture must be an object")
            .keys()
            .cloned()
            .collect()
    }

    fn commit_binding() -> ReadinessBinding {
        ReadinessBinding {
            operation_id: "deploy-20260829-readiness".into(),
            daemon_pid: 42,
            daemon_process_start_filetime: "100".into(),
            daemon_session_id: 1,
            daemon_user_sid: "S-1-5-21-1".into(),
            connection_generation: 7,
            readiness_receipt_sha256: "a".repeat(64),
            readiness_lock_sha256: "b".repeat(64),
            readiness_established_at_utc: "2026-08-29T12:34:56.789Z".into(),
            peer_address: "172.16.105.62:44119".into(),
            local_device_id: "00000000000000000000000000000002".into(),
        }
    }

    fn commit_request(mode: CommitMode) -> ReadinessCommitRequest {
        let binding = commit_binding();
        ReadinessCommitRequest {
            schema_version: 5,
            state: "viewflow-install-commit-request".into(),
            mode,
            operation_id: binding.operation_id,
            commit_nonce: "c".repeat(32),
            daemon_pid: binding.daemon_pid,
            daemon_process_start_filetime: binding.daemon_process_start_filetime,
            connection_generation: binding.connection_generation,
            readiness_receipt_sha256: binding.readiness_receipt_sha256,
            readiness_lock_sha256: binding.readiness_lock_sha256,
            linux_frozen_evidence_sha256: "d".repeat(64),
            force_release_receipt_sha256: mode_binding(mode, 'e'),
            marker_handoff_receipt_sha256: mode_binding(mode, '4'),
            windows_prepared_receipt_sha256: mode_binding(mode, '5'),
            mutation_permit_sha256: mode_binding(mode, '6'),
            linux_stage_receipt_sha256: mode_binding(mode, '7'),
            bootstrap_request_sha256: mode_binding(mode, '8'),
            old_viewflow_executable_sha256: "f".repeat(64),
            new_viewflow_executable_sha256: "1".repeat(64),
            installed_wrapper_sha256: "2".repeat(64),
            scheduled_task_xml_sha256: "3".repeat(64),
            requested_at_utc: "2026-08-29T12:35:00.123Z".into(),
        }
    }

    fn mode_binding(mode: CommitMode, digit: char) -> ExplicitNullableSha256 {
        match mode {
            CommitMode::NormalV2 => ExplicitNullableSha256::Null,
            CommitMode::BootstrapV13 => {
                ExplicitNullableSha256::Sha256(digit.to_string().repeat(64))
            }
        }
    }

    #[test]
    fn install_commit_request_has_exact_strict_schema_and_mode_semantics() {
        let binding = commit_binding();
        for mode in [CommitMode::NormalV2, CommitMode::BootstrapV13] {
            let request = commit_request(mode);
            validate_commit_request(&request, &binding).unwrap();
            let bytes = serde_json::to_vec(&request).unwrap();
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(
                keys(&value),
                [
                    "schema_version",
                    "state",
                    "mode",
                    "operation_id",
                    "commit_nonce",
                    "daemon_pid",
                    "daemon_process_start_filetime",
                    "connection_generation",
                    "readiness_receipt_sha256",
                    "readiness_lock_sha256",
                    "linux_frozen_evidence_sha256",
                    "force_release_receipt_sha256",
                    "marker_handoff_receipt_sha256",
                    "windows_prepared_receipt_sha256",
                    "mutation_permit_sha256",
                    "linux_stage_receipt_sha256",
                    "bootstrap_request_sha256",
                    "old_viewflow_executable_sha256",
                    "new_viewflow_executable_sha256",
                    "installed_wrapper_sha256",
                    "scheduled_task_xml_sha256",
                    "requested_at_utc",
                ]
                .into_iter()
                .map(str::to_owned)
                .collect()
            );
            let mut extended = value;
            extended["unexpected"] = Value::Bool(true);
            assert!(
                serde_json::from_value::<ReadinessCommitRequest>(extended).is_err(),
                "unknown request fields must fail closed"
            );
        }

        let mut normal = commit_request(CommitMode::NormalV2);
        normal.force_release_receipt_sha256 = ExplicitNullableSha256::Sha256("e".repeat(64));
        assert!(validate_commit_request(&normal, &binding).is_err());
        let mut bootstrap = commit_request(CommitMode::BootstrapV13);
        bootstrap.force_release_receipt_sha256 = ExplicitNullableSha256::Null;
        assert!(validate_commit_request(&bootstrap, &binding).is_err());
    }

    #[test]
    fn bootstrap_bindings_require_exact_fields_lower_hex_and_no_substitution() {
        let binding = commit_binding();
        let normal_value = serde_json::to_value(commit_request(CommitMode::NormalV2)).unwrap();
        for field in [
            "force_release_receipt_sha256",
            "marker_handoff_receipt_sha256",
            "windows_prepared_receipt_sha256",
            "mutation_permit_sha256",
            "linux_stage_receipt_sha256",
            "bootstrap_request_sha256",
        ] {
            assert!(
                normal_value[field].is_null(),
                "normal-v2 {field} must be null"
            );
            let mut missing = normal_value.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(
                serde_json::from_value::<ReadinessCommitRequest>(missing).is_err(),
                "missing exact-schema field {field} must fail closed"
            );
        }

        let bootstrap = commit_request(CommitMode::BootstrapV13);
        let mut uppercase = serde_json::to_value(&bootstrap).unwrap();
        uppercase["linux_stage_receipt_sha256"] = Value::String("A".repeat(64));
        let uppercase: ReadinessCommitRequest = serde_json::from_value(uppercase).unwrap();
        assert!(validate_commit_request(&uppercase, &binding).is_err());

        let mut substituted = commit_request(CommitMode::BootstrapV13);
        substituted.linux_stage_receipt_sha256 = substituted.marker_handoff_receipt_sha256.clone();
        assert!(validate_commit_request(&substituted, &binding).is_err());

        let mut renamed = serde_json::to_value(bootstrap).unwrap();
        let stage = renamed
            .as_object_mut()
            .unwrap()
            .remove("linux_stage_receipt_sha256")
            .unwrap();
        renamed
            .as_object_mut()
            .unwrap()
            .insert("linux_stage_receipt_hash".into(), stage);
        assert!(serde_json::from_value::<ReadinessCommitRequest>(renamed).is_err());
    }

    #[test]
    fn commit_request_hash_binds_exact_bootstrap_field_assignment() {
        let original = commit_request(CommitMode::BootstrapV13);
        let original_bytes = serde_json::to_vec(&original).unwrap();
        let original_sha = format!("{:x}", sha2::Sha256::digest(&original_bytes));

        let mut reassigned = commit_request(CommitMode::BootstrapV13);
        std::mem::swap(
            &mut reassigned.marker_handoff_receipt_sha256,
            &mut reassigned.linux_stage_receipt_sha256,
        );
        let reassigned_bytes = serde_json::to_vec(&reassigned).unwrap();
        let reassigned_sha = format!("{:x}", sha2::Sha256::digest(&reassigned_bytes));
        assert_ne!(original_sha, reassigned_sha);

        let success = install_success_receipt(
            original,
            original_sha.clone(),
            &commit_binding(),
            "2026-08-29T12:35:01.456Z".into(),
        );
        assert_eq!(success.commit_request_sha256, original_sha);
    }

    #[test]
    fn commit_linearization_rejects_revoked_guard_or_disconnect() {
        validate_commit_linearization_preconditions(true, None).unwrap();
        assert!(validate_commit_linearization_preconditions(false, None).is_err());
        assert!(
            validate_commit_linearization_preconditions(true, Some("peer disconnected")).is_err()
        );
        assert!(
            validate_commit_linearization_preconditions(false, Some("peer disconnected")).is_err()
        );
    }

    #[test]
    fn install_commit_request_must_bind_the_live_guard_identity() {
        let binding = commit_binding();
        let mut request = commit_request(CommitMode::NormalV2);
        request.connection_generation += 1;
        assert!(validate_commit_request(&request, &binding).is_err());

        let mut request = commit_request(CommitMode::NormalV2);
        request.readiness_lock_sha256 = "0".repeat(64);
        assert!(validate_commit_request(&request, &binding).is_err());

        let mut request = commit_request(CommitMode::NormalV2);
        request.commit_nonce = "C".repeat(32);
        assert!(validate_commit_request(&request, &binding).is_err());
    }

    #[test]
    fn daemon_install_success_receipt_has_exact_schema_five_bootstrap_bindings() {
        let binding = commit_binding();
        let success = install_success_receipt(
            commit_request(CommitMode::BootstrapV13),
            "4".repeat(64),
            &binding,
            "2026-08-29T12:35:01.456Z".into(),
        );
        let value = serde_json::to_value(success).unwrap();
        assert_eq!(
            keys(&value),
            [
                "schema_version",
                "state",
                "operation_id",
                "commit_nonce",
                "commit_request_sha256",
                "commit_mode",
                "committed_by_daemon",
                "linux_frozen_evidence_sha256",
                "force_release_receipt_sha256",
                "marker_handoff_receipt_sha256",
                "windows_prepared_receipt_sha256",
                "mutation_permit_sha256",
                "linux_stage_receipt_sha256",
                "bootstrap_request_sha256",
                "readiness_receipt_sha256",
                "readiness_lock_sha256",
                "readiness_connection_generation",
                "readiness_established_at_utc",
                "old_viewflow_executable_sha256",
                "new_viewflow_executable_sha256",
                "installed_wrapper_sha256",
                "scheduled_task_xml_sha256",
                "new_process_pid",
                "new_process_start_filetime",
                "new_process_session_id",
                "new_process_user_sid",
                "protocol_version",
                "peer",
                "device_id",
                "completed_at_utc",
                "committed_at_utc",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect()
        );
        assert_eq!(value["schema_version"], 5);
        assert_eq!(value["state"], "viewflow-v2-windows-installed");
        assert_eq!(value["commit_mode"], "bootstrap-v1.3");
        assert_eq!(value["committed_by_daemon"], true);
        assert_eq!(value["commit_request_sha256"], "4".repeat(64));
        assert_eq!(value["marker_handoff_receipt_sha256"], "4".repeat(64));
        assert_eq!(value["windows_prepared_receipt_sha256"], "5".repeat(64));
        assert_eq!(value["mutation_permit_sha256"], "6".repeat(64));
        assert_eq!(value["linux_stage_receipt_sha256"], "7".repeat(64));
        assert_eq!(value["bootstrap_request_sha256"], "8".repeat(64));
        assert_eq!(value["readiness_connection_generation"], 7);
        assert_eq!(value["new_process_pid"], 42);
        assert_eq!(value["new_process_start_filetime"], "100");
        assert_eq!(value["protocol_version"], "2.1");
        assert_eq!(value["completed_at_utc"], value["committed_at_utc"]);

        let normal = serde_json::to_value(install_success_receipt(
            commit_request(CommitMode::NormalV2),
            "9".repeat(64),
            &binding,
            "2026-08-29T12:35:02.456Z".into(),
        ))
        .unwrap();
        assert_eq!(keys(&normal), keys(&value));
        for field in [
            "force_release_receipt_sha256",
            "marker_handoff_receipt_sha256",
            "windows_prepared_receipt_sha256",
            "mutation_permit_sha256",
            "linux_stage_receipt_sha256",
            "bootstrap_request_sha256",
        ] {
            assert!(normal[field].is_null(), "normal-v2 W {field} must be null");
        }
    }

    #[test]
    fn readiness_receipt_has_exact_strict_schema() {
        let receipt = readiness_receipt(&ReadinessReceiptInput {
            operation_id: "deploy-20260829-readiness",
            executable_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            pid: 42,
            process_start_filetime: "18446744073709551615",
            session_id: 1,
            user_sid: "S-1-5-21-1",
            connection_generation: 7,
            local_device_id: "00000000000000000000000000000002",
            peer_address: "172.16.105.62:44119",
            server_name: "viewflow-linux",
            probe_round_trip_ns: 1_000_000,
            probe_uncertainty_ns: 500_000,
            lock_path: r"C:\ProgramData\Viewflow\ready.lock",
            lock_sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            established_at_utc: "2026-08-29T12:34:56.789Z",
        });
        let value = serde_json::to_value(receipt).unwrap();
        assert_eq!(
            keys(&value),
            [
                "connection_generation",
                "daemon_executable_sha256",
                "daemon_pid",
                "daemon_process_start_filetime",
                "daemon_session_id",
                "daemon_user_sid",
                "established_at_utc",
                "input_backend",
                "local_device_id",
                "operation_id",
                "peer_address",
                "probe_round_trip_ns",
                "probe_max_round_trip_ns",
                "probe_uncertainty_ns",
                "probe_max_uncertainty_ns",
                "protocol_major",
                "protocol_minor",
                "readiness_lock_path",
                "readiness_lock_sha256",
                "schema_version",
                "server_name",
                "state",
                "validity",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect()
        );
        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["state"], "viewflow-post-mtls-readiness-established");
        assert_eq!(value["validity"], "while-readiness-lock-is-held");
        assert_eq!(value["operation_id"], "deploy-20260829-readiness");
        assert_eq!(
            value["daemon_executable_sha256"],
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        );
        assert_eq!(value["daemon_pid"], 42);
        assert_eq!(value["input_backend"], "native");
        assert_eq!(value["daemon_process_start_filetime"], u64::MAX.to_string());
        assert!(value["daemon_process_start_filetime"].is_string());
        assert_eq!(value["daemon_session_id"], 1);
        assert_eq!(value["daemon_user_sid"], "S-1-5-21-1");
        assert_eq!(value["connection_generation"], 7);
        assert_eq!(value["local_device_id"], "00000000000000000000000000000002");
        assert_eq!(value["peer_address"], "172.16.105.62:44119");
        assert_eq!(value["server_name"], "viewflow-linux");
        assert_eq!(value["protocol_major"], 2);
        assert_eq!(value["protocol_minor"], 1);
        assert_eq!(value["probe_round_trip_ns"], 1_000_000);
        assert_eq!(value["probe_max_round_trip_ns"], 33_333_334);
        assert_eq!(value["probe_uncertainty_ns"], 500_000);
        assert_eq!(value["probe_max_uncertainty_ns"], 4_000_000);
        assert_eq!(
            value["readiness_lock_path"],
            r"C:\ProgramData\Viewflow\ready.lock"
        );
        assert_eq!(
            value["readiness_lock_sha256"],
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        );
        assert_eq!(value["established_at_utc"], "2026-08-29T12:34:56.789Z");
    }

    #[test]
    fn readiness_lock_payload_has_exact_identity_binding() {
        let value = serde_json::to_value(ReadinessLockPayload {
            schema_version: 1,
            state: "viewflow-post-mtls-readiness-lock".into(),
            operation_id: "deploy-20260829-readiness".into(),
            daemon_pid: 42,
            daemon_process_start_filetime: "100".into(),
            connection_generation: 7,
        })
        .unwrap();
        assert_eq!(
            keys(&value),
            [
                "daemon_pid",
                "daemon_process_start_filetime",
                "connection_generation",
                "operation_id",
                "schema_version",
                "state",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect()
        );
        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["state"], "viewflow-post-mtls-readiness-lock");
        assert_eq!(value["operation_id"], "deploy-20260829-readiness");
        assert_eq!(value["daemon_pid"], 42);
        assert_eq!(value["daemon_process_start_filetime"], "100");
        assert!(value["daemon_process_start_filetime"].is_string());
        assert_eq!(value["connection_generation"], 7);
    }

    fn evidence_fixture(
        pid: u32,
        process_start_filetime: &str,
        generation: u64,
    ) -> (Vec<u8>, Vec<u8>) {
        let lock = ReadinessLockPayload {
            schema_version: 1,
            state: "viewflow-post-mtls-readiness-lock".into(),
            operation_id: "deploy-20260829-readiness".into(),
            daemon_pid: pid,
            daemon_process_start_filetime: process_start_filetime.into(),
            connection_generation: generation,
        };
        let mut lock_bytes = serde_json::to_vec_pretty(&lock).unwrap();
        lock_bytes.push(b'\n');
        let receipt = readiness_receipt(&ReadinessReceiptInput {
            operation_id: "deploy-20260829-readiness",
            executable_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            pid,
            process_start_filetime,
            session_id: 1,
            user_sid: "S-1-5-21-1",
            connection_generation: generation,
            local_device_id: "00000000000000000000000000000002",
            peer_address: "172.16.105.62:44119",
            server_name: "viewflow-linux",
            probe_round_trip_ns: 1_000_000,
            probe_uncertainty_ns: 500_000,
            lock_path: r"C:\ProgramData\Viewflow\ready.lock",
            lock_sha256: &format!("{:x}", sha2::Sha256::digest(&lock_bytes)),
            established_at_utc: "2026-08-29T12:34:56.789Z",
        });
        let mut receipt_bytes = serde_json::to_vec_pretty(&receipt).unwrap();
        receipt_bytes.push(b'\n');
        (receipt_bytes, lock_bytes)
    }

    fn validate_fixture(
        current_pid: u32,
        current_process_start_filetime: &str,
        current_generation: u64,
        receipt_bytes: Option<&[u8]>,
        lock_bytes: Option<&[u8]>,
    ) -> anyhow::Result<()> {
        validate_revoked_evidence(
            "deploy-20260829-readiness",
            current_pid,
            current_process_start_filetime,
            current_generation,
            r"C:\ProgramData\Viewflow\ready.lock",
            receipt_bytes,
            lock_bytes,
        )
    }

    #[test]
    fn previous_generation_from_same_process_can_be_reclaimed() {
        let (receipt, lock) = evidence_fixture(42, "100", 7);
        validate_fixture(42, "100", 8, Some(&receipt), Some(&lock)).unwrap();
        validate_fixture(42, "100", 8, Some(&receipt), None).unwrap();
        validate_fixture(42, "100", 8, None, Some(&lock)).unwrap();
    }

    #[test]
    fn different_process_identity_cannot_be_reclaimed() {
        let (receipt, lock) = evidence_fixture(42, "100", 7);
        assert!(validate_fixture(43, "100", 8, Some(&receipt), Some(&lock)).is_err());
        assert!(validate_fixture(42, "101", 8, Some(&receipt), Some(&lock)).is_err());

        let mut receipt_value: serde_json::Value = serde_json::from_slice(&receipt).unwrap();
        receipt_value["operation_id"] = serde_json::Value::String("different-operation".into());
        let modified_receipt = serde_json::to_vec(&receipt_value).unwrap();
        assert!(validate_fixture(42, "100", 8, Some(&modified_receipt), Some(&lock)).is_err());
    }

    #[test]
    fn current_or_future_generation_cannot_be_reclaimed() {
        let (receipt, lock) = evidence_fixture(42, "100", 7);
        assert!(validate_fixture(42, "100", 7, Some(&receipt), Some(&lock)).is_err());
        assert!(validate_fixture(42, "100", 6, Some(&receipt), Some(&lock)).is_err());

        let (zero_receipt, zero_lock) = evidence_fixture(42, "100", 0);
        assert!(validate_fixture(42, "100", 8, Some(&zero_receipt), Some(&zero_lock)).is_err());
    }

    #[test]
    fn mismatched_or_modified_artifacts_cannot_be_reclaimed() {
        let (receipt, lock) = evidence_fixture(42, "100", 7);
        let (_, newer_lock) = evidence_fixture(42, "100", 6);
        assert!(validate_fixture(42, "100", 8, Some(&receipt), Some(&newer_lock)).is_err());

        let mut receipt_value: serde_json::Value = serde_json::from_slice(&receipt).unwrap();
        receipt_value["readiness_lock_sha256"] = serde_json::Value::String("0".repeat(64));
        let modified_receipt = serde_json::to_vec(&receipt_value).unwrap();
        assert!(validate_fixture(42, "100", 8, Some(&modified_receipt), Some(&lock)).is_err());
    }

    #[test]
    fn malformed_or_extended_json_cannot_be_reclaimed() {
        let (receipt, lock) = evidence_fixture(42, "100", 7);
        assert!(validate_fixture(42, "100", 8, Some(b"{"), Some(&lock)).is_err());

        let mut receipt_value: serde_json::Value = serde_json::from_slice(&receipt).unwrap();
        receipt_value["unexpected"] = serde_json::Value::Bool(true);
        let extended_receipt = serde_json::to_vec(&receipt_value).unwrap();
        assert!(validate_fixture(42, "100", 8, Some(&extended_receipt), Some(&lock)).is_err());

        let mut lock_value: serde_json::Value = serde_json::from_slice(&lock).unwrap();
        lock_value["unexpected"] = serde_json::Value::Bool(true);
        let extended_lock = serde_json::to_vec(&lock_value).unwrap();
        assert!(validate_fixture(42, "100", 8, Some(&receipt), Some(&extended_lock)).is_err());
    }

    #[test]
    fn non_qualifying_receipt_cannot_be_reclaimed() {
        let (receipt, lock) = evidence_fixture(42, "100", 7);
        let mut parsed: ReadinessReceipt = serde_json::from_slice(&receipt).unwrap();
        parsed.probe_round_trip_ns = parsed.probe_max_round_trip_ns + 1;
        let modified = serde_json::to_vec(&parsed).unwrap();
        assert!(validate_fixture(42, "100", 8, Some(&modified), Some(&lock)).is_err());

        let mut parsed: ReadinessReceipt = serde_json::from_slice(&receipt).unwrap();
        parsed.daemon_session_id = 2;
        let modified = serde_json::to_vec(&parsed).unwrap();
        assert!(validate_fixture(42, "100", 8, Some(&modified), Some(&lock)).is_err());
    }
}
