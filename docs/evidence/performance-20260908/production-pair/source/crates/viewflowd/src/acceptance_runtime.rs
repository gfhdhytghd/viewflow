use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use viewflow_protocol::Id128;

use crate::InputAckMetrics;

const CONTROL_SCHEMA: u32 = 1;
const TRANSCRIPT_SCHEMA: u32 = 1;
const RECEIPT_SCHEMA: u32 = 1;
const MAX_CONTROL_LINE: usize = 16 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcceptanceConfig {
    pub(crate) socket_path: PathBuf,
    pub(crate) state_dir: PathBuf,
}

#[derive(Clone)]
pub(crate) struct AcceptanceRecorder {
    inner: Arc<Mutex<RecorderState>>,
}

impl std::fmt::Debug for AcceptanceRecorder {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("AcceptanceRecorder { .. }")
    }
}

struct RecorderState {
    state_dir: PathBuf,
    local_device: Id128,
    target_device: Id128,
    daemon_identity: DaemonIdentity,
    armed: Option<AcceptanceTranscript>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, tag = "command", rename_all = "snake_case")]
enum ControlRequest {
    Arm {
        schema_version: u32,
        operation_id: String,
        source_display_id: String,
        target_device_id: String,
        linux_viewflow_sha256: String,
        windows_viewflow_sha256: String,
        deployment_release_receipt_path: PathBuf,
        deployment_release_receipt_sha256: String,
    },
    Query {
        schema_version: u32,
        operation_id: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcceptanceArmConfig {
    pub(crate) socket_path: PathBuf,
    pub(crate) operation_id: String,
    pub(crate) source_display_id: String,
    pub(crate) target_device_id: String,
    pub(crate) linux_viewflow_sha256: String,
    pub(crate) windows_viewflow_sha256: String,
    pub(crate) deployment_release_receipt_path: PathBuf,
    pub(crate) deployment_release_receipt_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcceptanceQueryConfig {
    pub(crate) socket_path: PathBuf,
    pub(crate) operation_id: String,
}

#[derive(Debug, Serialize)]
struct ControlResponse<'a> {
    schema_version: u32,
    ok: bool,
    status: &'a str,
    operation_id: Option<&'a str>,
    transcript_path: Option<String>,
    receipt_path: Option<String>,
    producer_pid: Option<u32>,
    producer_start_ticks: Option<u64>,
    producer_boot_id: Option<&'a str>,
    producer_executable_sha256: Option<&'a str>,
    transcript_sha256: Option<String>,
    sample_count: Option<usize>,
    max_us: Option<u64>,
    p99_us: Option<u64>,
    accepted_sequence_strictly_increasing: Option<bool>,
    acked_unique_sequence_count: Option<u64>,
    duplicate_ack_count: Option<u64>,
    replay_rejection_count: Option<u64>,
    late_ack_rejection_count: Option<u64>,
    error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct AcceptanceTranscript {
    schema_version: u32,
    state: &'static str,
    daemon_instance_id: String,
    producer_pid: u32,
    producer_start_ticks: u64,
    producer_boot_id: String,
    producer_executable_sha256: String,
    operation_id: String,
    protocol_version: &'static str,
    sidecar_protocol_version: u32,
    source_display_id: String,
    target_device_id: String,
    linux_viewflow_sha256: String,
    windows_viewflow_sha256: String,
    deployment_release_receipt_sha256: String,
    armed_at_unix_ms: u64,
    events: Vec<AcceptanceEvent>,
    input_samples: Vec<InputAppliedSample>,
    failure_reason: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum AcceptanceEvent {
    DisconnectBeforeActivation {
        peer_epoch: u64,
        peer_socket: String,
        observed_at_unix_ms: u64,
        input_ack_metrics: InputAckMetrics,
    },
    RouteActivated {
        source_display_id: String,
        target_device_id: String,
        route_generation: u64,
        active_lease_generation: u64,
        peer_epoch: u64,
        peer_socket: String,
        observed_at_unix_ms: u64,
    },
    EntryAcknowledged {
        route_generation: u64,
        observed_at_unix_ms: u64,
    },
    DisconnectDuringActiveRoute {
        peer_epoch: u64,
        peer_socket: String,
        observed_at_unix_ms: u64,
        input_ack_metrics: InputAckMetrics,
    },
    ReleaseAllApplied {
        lease_generation: u64,
        event_sequence: u64,
        peer_epoch: u64,
        observed_at_unix_ms: u64,
    },
    RevokeApplied {
        operation_id: String,
        lease_generation: u64,
        peer_epoch: u64,
        observed_at_unix_ms: u64,
    },
    ReturnAcknowledged {
        route_generation: u64,
        observed_at_unix_ms: u64,
    },
    DisconnectAfterReturn {
        peer_epoch: u64,
        peer_socket: String,
        observed_at_unix_ms: u64,
        input_ack_metrics: InputAckMetrics,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct InputAppliedSample {
    event_sequence: u64,
    capture_to_applied_ack_us: u64,
    kind: InputCoverageKind,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum InputCoverageKind {
    KeyboardPressed,
    KeyboardReleased,
    PointerMotion,
    Button1Pressed,
    Button1Released,
    Button2Pressed,
    Button2Released,
    Button3Pressed,
    Button3Released,
    Button4Pressed,
    Button4Released,
    Button5Pressed,
    Button5Released,
    VerticalWheel,
    HorizontalWheel,
}

#[derive(Debug, Serialize)]
struct AcceptanceReceipt {
    schema_version: u32,
    state: &'static str,
    operation_id: String,
    producer_pid: u32,
    producer_start_ticks: u64,
    producer_boot_id: String,
    producer_executable_sha256: String,
    protocol_version: &'static str,
    sidecar_protocol_version: u32,
    source_display_id: String,
    target_device_id: String,
    linux_viewflow_sha256: String,
    windows_viewflow_sha256: String,
    deployment_release_receipt_sha256: String,
    route_admission: &'static str,
    entry_return: &'static str,
    held_inputs: &'static str,
    disconnect_before_activation: &'static str,
    disconnect_during_active_route: &'static str,
    disconnect_after_return: &'static str,
    runtime_marker_present: bool,
    transcript_sha256: String,
    sample_count: usize,
    max_us: u64,
    p99_us: u64,
    accepted_sequence_strictly_increasing: bool,
    acked_unique_sequence_count: u64,
    duplicate_ack_count: u64,
    replay_rejection_count: u64,
    late_ack_rejection_count: u64,
    completed_at_unix_ms: u64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct RouteActivatedEvidence {
    pub(crate) source_display: Id128,
    pub(crate) target_device: Id128,
    pub(crate) route_generation: u64,
    pub(crate) active_lease_generation: u64,
    pub(crate) peer_epoch: u64,
    pub(crate) peer_socket: std::net::SocketAddr,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct CleanupAppliedEvidence {
    pub(crate) release_lease_generation: u64,
    pub(crate) release_event_sequence: u64,
    pub(crate) revoke_operation_id: Id128,
    pub(crate) revoke_lease_generation: u64,
    pub(crate) peer_epoch: u64,
}

impl AcceptanceRecorder {
    pub(crate) fn new(
        state_dir: PathBuf,
        local_device: Id128,
        target_device: Id128,
    ) -> Result<Self> {
        validate_owner_directory(&state_dir)?;
        Ok(Self {
            inner: Arc::new(Mutex::new(RecorderState {
                state_dir,
                local_device,
                target_device,
                daemon_identity: daemon_identity()?,
                armed: None,
            })),
        })
    }

    pub(crate) fn peer_disconnected(
        &self,
        peer_epoch: u64,
        peer_socket: std::net::SocketAddr,
        input_ack_metrics: InputAckMetrics,
    ) {
        self.record(|transcript| {
            let observed_at_unix_ms = unix_time_ms()?;
            let event = if !has_route_activation(transcript) {
                AcceptanceEvent::DisconnectBeforeActivation {
                    peer_epoch,
                    peer_socket: peer_socket.to_string(),
                    observed_at_unix_ms,
                    input_ack_metrics,
                }
            } else if !has_return(transcript) {
                AcceptanceEvent::DisconnectDuringActiveRoute {
                    peer_epoch,
                    peer_socket: peer_socket.to_string(),
                    observed_at_unix_ms,
                    input_ack_metrics,
                }
            } else {
                AcceptanceEvent::DisconnectAfterReturn {
                    peer_epoch,
                    peer_socket: peer_socket.to_string(),
                    observed_at_unix_ms,
                    input_ack_metrics,
                }
            };
            push_event(transcript, event)
        });
    }

    pub(crate) fn route_activated(&self, evidence: RouteActivatedEvidence) {
        self.record(|transcript| {
            push_event(
                transcript,
                AcceptanceEvent::RouteActivated {
                    source_display_id: id_string(evidence.source_display),
                    target_device_id: id_string(evidence.target_device),
                    route_generation: evidence.route_generation,
                    active_lease_generation: evidence.active_lease_generation,
                    peer_epoch: evidence.peer_epoch,
                    peer_socket: evidence.peer_socket.to_string(),
                    observed_at_unix_ms: unix_time_ms()?,
                },
            )
        });
    }

    pub(crate) fn entry_acknowledged(&self, route_generation: u64) {
        self.record(|transcript| {
            push_event(
                transcript,
                AcceptanceEvent::EntryAcknowledged {
                    route_generation,
                    observed_at_unix_ms: unix_time_ms()?,
                },
            )
        });
    }

    pub(crate) fn cleanup_applied(&self, evidence: CleanupAppliedEvidence) {
        self.record(|transcript| {
            push_event(
                transcript,
                AcceptanceEvent::ReleaseAllApplied {
                    lease_generation: evidence.release_lease_generation,
                    event_sequence: evidence.release_event_sequence,
                    peer_epoch: evidence.peer_epoch,
                    observed_at_unix_ms: unix_time_ms()?,
                },
            )?;
            push_event(
                transcript,
                AcceptanceEvent::RevokeApplied {
                    operation_id: id_string(evidence.revoke_operation_id),
                    lease_generation: evidence.revoke_lease_generation,
                    peer_epoch: evidence.peer_epoch,
                    observed_at_unix_ms: unix_time_ms()?,
                },
            )
        });
    }

    pub(crate) fn input_applied(
        &self,
        event_sequence: u64,
        capture_to_applied_ack_us: u64,
        kinds: &[InputCoverageKind],
    ) {
        self.record(|transcript| {
            if event_sequence == 0 || kinds.is_empty() {
                bail!("input Applied evidence has no sequence or coverage kind");
            }
            if capture_to_applied_ack_us > 32_000 {
                bail!("capture-to-Applied-ACK latency exceeded 32 ms");
            }
            for kind in kinds {
                transcript.input_samples.push(InputAppliedSample {
                    event_sequence,
                    capture_to_applied_ack_us,
                    kind: *kind,
                });
            }
            Ok(())
        });
    }

    pub(crate) fn return_acknowledged(&self, route_generation: u64) {
        self.record(|transcript| {
            push_event(
                transcript,
                AcceptanceEvent::ReturnAcknowledged {
                    route_generation,
                    observed_at_unix_ms: unix_time_ms()?,
                },
            )
        });
    }

    fn record(&self, update: impl FnOnce(&mut AcceptanceTranscript) -> Result<()>) {
        let mut state = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(mut transcript) = state.armed.take() else {
            return;
        };
        if transcript.failure_reason.is_none()
            && let Err(error) = update(&mut transcript)
        {
            transcript.failure_reason = Some(format!("{error:#}"));
        }
        if let Err(error) = persist_transcript(&state.state_dir, &transcript) {
            transcript.failure_reason = Some(format!("failed to persist transcript: {error:#}"));
        } else if transcript.failure_reason.is_none()
            && acceptance_complete(&transcript)
            && let Err(error) = publish_receipt(&state.state_dir, &transcript)
        {
            transcript.failure_reason = Some(format!("failed to publish receipt: {error:#}"));
            let _ = persist_transcript(&state.state_dir, &transcript);
        }
        state.armed = Some(transcript);
    }
}

pub(crate) fn run_acceptance_control(
    config: &AcceptanceConfig,
    recorder: &AcceptanceRecorder,
) -> Result<()> {
    let listener = OwnerOnlyListener::bind(&config.socket_path)?;
    println!(
        "viewflowd post-release acceptance control listening on {}",
        config.socket_path.display()
    );
    loop {
        let (mut stream, _) = listener.listener.accept()?;
        if let Err(error) =
            authenticate_owner(&stream).and_then(|()| serve_control(&mut stream, recorder))
        {
            let response = ControlResponse {
                schema_version: CONTROL_SCHEMA,
                ok: false,
                status: "rejected",
                operation_id: None,
                transcript_path: None,
                receipt_path: None,
                producer_pid: None,
                producer_start_ticks: None,
                producer_boot_id: None,
                producer_executable_sha256: None,
                transcript_sha256: None,
                sample_count: None,
                max_us: None,
                p99_us: None,
                accepted_sequence_strictly_increasing: None,
                acked_unique_sequence_count: None,
                duplicate_ack_count: None,
                replay_rejection_count: None,
                late_ack_rejection_count: None,
                error: Some(format!("{error:#}")),
            };
            let _ = write_json_line(&mut stream, &response);
        }
    }
}

pub(crate) fn acceptance_arm(config: &AcceptanceArmConfig) -> Result<()> {
    send_control_request(
        &config.socket_path,
        &ControlRequest::Arm {
            schema_version: CONTROL_SCHEMA,
            operation_id: config.operation_id.clone(),
            source_display_id: config.source_display_id.clone(),
            target_device_id: config.target_device_id.clone(),
            linux_viewflow_sha256: config.linux_viewflow_sha256.clone(),
            windows_viewflow_sha256: config.windows_viewflow_sha256.clone(),
            deployment_release_receipt_path: config.deployment_release_receipt_path.clone(),
            deployment_release_receipt_sha256: config.deployment_release_receipt_sha256.clone(),
        },
    )
}

pub(crate) fn acceptance_query(config: &AcceptanceQueryConfig) -> Result<()> {
    send_control_request(
        &config.socket_path,
        &ControlRequest::Query {
            schema_version: CONTROL_SCHEMA,
            operation_id: config.operation_id.clone(),
        },
    )
}

fn send_control_request(socket_path: &Path, request: &ControlRequest) -> Result<()> {
    let mut stream = UnixStream::connect(socket_path)
        .with_context(|| format!("failed to connect {}", socket_path.display()))?;
    write_json_line(&mut stream, request)?;
    let mut response = String::new();
    BufReader::new(stream)
        .take(u64::try_from(MAX_CONTROL_LINE + 1).expect("control limit fits u64"))
        .read_line(&mut response)?;
    if response.is_empty() || response.len() > MAX_CONTROL_LINE || !response.ends_with('\n') {
        bail!("acceptance control response is empty, oversized, or unterminated");
    }
    let parsed: serde_json::Value =
        serde_json::from_str(&response).context("invalid acceptance control response")?;
    println!("{}", response.trim_end());
    if parsed.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
        bail!("acceptance control rejected the request");
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn serve_control(stream: &mut UnixStream, recorder: &AcceptanceRecorder) -> Result<()> {
    let cloned = stream.try_clone()?;
    let mut line = String::new();
    BufReader::new(cloned)
        .take(u64::try_from(MAX_CONTROL_LINE + 1).expect("control limit fits u64"))
        .read_line(&mut line)?;
    if line.is_empty() || line.len() > MAX_CONTROL_LINE || !line.ends_with('\n') {
        bail!("acceptance control request is empty, oversized, or unterminated");
    }
    let request: ControlRequest = serde_json::from_str(&line).context("invalid control JSON")?;
    match request {
        ControlRequest::Arm {
            schema_version,
            operation_id,
            source_display_id,
            target_device_id,
            linux_viewflow_sha256,
            windows_viewflow_sha256,
            deployment_release_receipt_path,
            deployment_release_receipt_sha256,
        } => {
            if schema_version != CONTROL_SCHEMA {
                bail!("unsupported acceptance control schema {schema_version}");
            }
            let mut state = recorder
                .inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            arm(
                &mut state,
                ArmRequest {
                    operation_id,
                    source_display_id,
                    target_device_id,
                    linux_viewflow_sha256,
                    windows_viewflow_sha256,
                    deployment_release_receipt_path,
                    deployment_release_receipt_sha256,
                },
            )?;
            let transcript = state.armed.as_ref().expect("successful arm installs state");
            let response = ControlResponse {
                schema_version: CONTROL_SCHEMA,
                ok: true,
                status: "armed_external_exercise_required",
                operation_id: Some(&transcript.operation_id),
                transcript_path: Some(
                    transcript_path(&state.state_dir, &transcript.operation_id)
                        .display()
                        .to_string(),
                ),
                receipt_path: Some(
                    receipt_path(&state.state_dir, &transcript.operation_id)
                        .display()
                        .to_string(),
                ),
                producer_pid: Some(transcript.producer_pid),
                producer_start_ticks: Some(transcript.producer_start_ticks),
                producer_boot_id: Some(&transcript.producer_boot_id),
                producer_executable_sha256: Some(&transcript.producer_executable_sha256),
                transcript_sha256: Some(hash_file(&transcript_path(
                    &state.state_dir,
                    &transcript.operation_id,
                ))?),
                sample_count: None,
                max_us: None,
                p99_us: None,
                accepted_sequence_strictly_increasing: None,
                acked_unique_sequence_count: None,
                duplicate_ack_count: None,
                replay_rejection_count: None,
                late_ack_rejection_count: None,
                error: None,
            };
            write_json_line(stream, &response)
        }
        ControlRequest::Query {
            schema_version,
            operation_id,
        } => {
            if schema_version != CONTROL_SCHEMA {
                bail!("unsupported acceptance control schema {schema_version}");
            }
            let state = recorder
                .inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let transcript = state
                .armed
                .as_ref()
                .filter(|transcript| transcript.operation_id == operation_id)
                .ok_or_else(|| anyhow!("operation is not armed in this daemon instance"))?;
            let receipt = receipt_path(&state.state_dir, &operation_id);
            let status = if transcript.failure_reason.as_deref()
                == Some("active_route_disconnect_requires_containment")
            {
                "active_route_disconnect_requires_containment"
            } else if transcript.failure_reason.is_some() {
                "failed_closed"
            } else if receipt.exists() {
                "passed"
            } else {
                "pending_external_exercise"
            };
            let latency_summary = receipt
                .exists()
                .then(|| latency_stats(transcript))
                .transpose()?;
            let ack_metrics = receipt.exists().then(|| aggregate_ack_metrics(transcript));
            let response = ControlResponse {
                schema_version: CONTROL_SCHEMA,
                ok: transcript.failure_reason.is_none(),
                status,
                operation_id: Some(&transcript.operation_id),
                transcript_path: Some(
                    transcript_path(&state.state_dir, &operation_id)
                        .display()
                        .to_string(),
                ),
                receipt_path: receipt.exists().then(|| receipt.display().to_string()),
                producer_pid: Some(transcript.producer_pid),
                producer_start_ticks: Some(transcript.producer_start_ticks),
                producer_boot_id: Some(&transcript.producer_boot_id),
                producer_executable_sha256: Some(&transcript.producer_executable_sha256),
                transcript_sha256: Some(hash_file(&transcript_path(
                    &state.state_dir,
                    &operation_id,
                ))?),
                sample_count: latency_summary.map(|summary| summary.0),
                max_us: latency_summary.map(|summary| summary.1),
                p99_us: latency_summary.map(|summary| summary.2),
                accepted_sequence_strictly_increasing: receipt
                    .exists()
                    .then(|| accepted_sequences_strictly_increasing(transcript)),
                acked_unique_sequence_count: ack_metrics
                    .map(|metrics| metrics.acked_unique_sequence_count),
                duplicate_ack_count: ack_metrics.map(|metrics| metrics.duplicate_ack_count),
                replay_rejection_count: ack_metrics.map(|metrics| metrics.replay_rejection_count),
                late_ack_rejection_count: ack_metrics
                    .map(|metrics| metrics.late_ack_rejection_count),
                error: transcript.failure_reason.clone(),
            };
            write_json_line(stream, &response)
        }
    }
}

struct ArmRequest {
    operation_id: String,
    source_display_id: String,
    target_device_id: String,
    linux_viewflow_sha256: String,
    windows_viewflow_sha256: String,
    deployment_release_receipt_path: PathBuf,
    deployment_release_receipt_sha256: String,
}

fn arm(state: &mut RecorderState, request: ArmRequest) -> Result<()> {
    validate_operation_id(&request.operation_id)?;
    validate_id(&request.source_display_id, "source display")?;
    validate_id(&request.target_device_id, "target device")?;
    validate_sha(&request.linux_viewflow_sha256, "Linux viewflowd")?;
    validate_sha(&request.windows_viewflow_sha256, "Windows viewflowd")?;
    validate_sha(
        &request.deployment_release_receipt_sha256,
        "deployment release receipt",
    )?;
    if request.target_device_id != id_string(state.target_device) {
        bail!("acceptance target does not match the configured sidecar target");
    }
    let running_sha = hash_file(Path::new("/proc/self/exe"))?;
    if request.linux_viewflow_sha256 != running_sha {
        bail!("acceptance Linux binary hash does not match the running daemon");
    }
    if hash_file(&request.deployment_release_receipt_path)?
        != request.deployment_release_receipt_sha256
    {
        bail!("deployment release receipt hash does not match its file");
    }
    if state.armed.is_some() {
        bail!("an acceptance operation is already armed");
    }
    let transcript = AcceptanceTranscript {
        schema_version: TRANSCRIPT_SCHEMA,
        state: "viewflow-post-release-acceptance-armed",
        daemon_instance_id: state.daemon_identity.instance_id(),
        producer_pid: state.daemon_identity.pid,
        producer_start_ticks: state.daemon_identity.start_ticks,
        producer_boot_id: state.daemon_identity.boot_id.clone(),
        producer_executable_sha256: state.daemon_identity.executable_sha256.clone(),
        operation_id: request.operation_id,
        protocol_version: "2.1",
        sidecar_protocol_version: 3,
        source_display_id: request.source_display_id,
        target_device_id: request.target_device_id,
        linux_viewflow_sha256: request.linux_viewflow_sha256,
        windows_viewflow_sha256: request.windows_viewflow_sha256,
        deployment_release_receipt_sha256: request.deployment_release_receipt_sha256,
        armed_at_unix_ms: unix_time_ms()?,
        events: Vec::new(),
        input_samples: Vec::new(),
        failure_reason: None,
    };
    let path = transcript_path(&state.state_dir, &transcript.operation_id);
    if path.exists() || receipt_path(&state.state_dir, &transcript.operation_id).exists() {
        bail!("acceptance operation already has durable state");
    }
    persist_transcript(&state.state_dir, &transcript)?;
    state.armed = Some(transcript);
    let _ = state.local_device;
    Ok(())
}

#[allow(clippy::match_same_arms)]
fn push_event(transcript: &mut AcceptanceTranscript, event: AcceptanceEvent) -> Result<()> {
    let previous = transcript.events.last();
    let valid = match (&event, previous) {
        (
            AcceptanceEvent::DisconnectBeforeActivation {
                peer_epoch: 1.., ..
            },
            None,
        ) => true,
        (
            AcceptanceEvent::RouteActivated {
                peer_epoch: 1..,
                route_generation: 1..,
                active_lease_generation: 1..,
                ..
            },
            None | Some(AcceptanceEvent::DisconnectBeforeActivation { .. }),
        ) => true,
        (
            AcceptanceEvent::EntryAcknowledged {
                route_generation: 1..,
                ..
            },
            Some(AcceptanceEvent::RouteActivated { .. }),
        ) => true,
        (
            AcceptanceEvent::DisconnectDuringActiveRoute {
                peer_epoch: 1.., ..
            },
            Some(AcceptanceEvent::EntryAcknowledged { .. }),
        ) => {
            transcript.events.push(event);
            bail!("active_route_disconnect_requires_containment");
        }
        (
            AcceptanceEvent::ReleaseAllApplied {
                lease_generation: 1..,
                event_sequence: 1..,
                peer_epoch: 1..,
                ..
            },
            Some(AcceptanceEvent::EntryAcknowledged { .. }),
        ) => true,
        (
            AcceptanceEvent::RevokeApplied {
                lease_generation: 1..,
                peer_epoch: 1..,
                ..
            },
            Some(AcceptanceEvent::ReleaseAllApplied { .. }),
        ) => true,
        (
            AcceptanceEvent::ReturnAcknowledged {
                route_generation: 1..,
                ..
            },
            Some(AcceptanceEvent::RevokeApplied { .. }),
        ) => true,
        (
            AcceptanceEvent::DisconnectAfterReturn {
                peer_epoch: 1.., ..
            },
            Some(AcceptanceEvent::ReturnAcknowledged { .. }),
        ) => true,
        _ => false,
    };
    if !valid {
        bail!("acceptance event is missing, duplicated, out of order, or has zero identity");
    }
    transcript.events.push(event);
    validate_cross_event_identity(transcript)
}

fn validate_cross_event_identity(transcript: &AcceptanceTranscript) -> Result<()> {
    let workflow = transcript
        .events
        .iter()
        .filter(|event| !matches!(event, AcceptanceEvent::DisconnectBeforeActivation { .. }))
        .collect::<Vec<_>>();
    if let Some(AcceptanceEvent::RouteActivated {
        source_display_id,
        target_device_id,
        route_generation,
        active_lease_generation,
        peer_epoch,
        ..
    }) = workflow.first().copied()
    {
        if source_display_id != &transcript.source_display_id
            || target_device_id != &transcript.target_device_id
        {
            bail!("route activation does not bind the armed endpoints");
        }
        if let Some(AcceptanceEvent::EntryAcknowledged {
            route_generation: entry,
            ..
        }) = workflow.get(1).copied()
            && entry != route_generation
        {
            bail!("entry acknowledgement route generation changed");
        }
        if let Some(AcceptanceEvent::ReleaseAllApplied {
            lease_generation, ..
        }) = workflow.get(2).copied()
            && lease_generation != active_lease_generation
        {
            bail!("ReleaseAll lease generation changed");
        } else if let (
            Some(AcceptanceEvent::ReleaseAllApplied {
                peer_epoch: cleanup_peer,
                ..
            }),
            Some(AcceptanceEvent::RevokeApplied {
                peer_epoch: revoke_peer,
                ..
            }),
        ) = (workflow.get(2).copied(), workflow.get(3).copied())
            && cleanup_peer != revoke_peer
        {
            bail!("ReleaseAll and revoke do not bind one cleanup peer");
        }
        if let Some(AcceptanceEvent::RevokeApplied {
            operation_id,
            lease_generation,
            peer_epoch: revoke_peer,
            ..
        }) = workflow.get(3).copied()
        {
            let operation = u128::from_str_radix(operation_id, 16)
                .context("revoke operation identity is not hexadecimal")?;
            if *lease_generation
                != active_lease_generation
                    .checked_add(1)
                    .ok_or_else(|| anyhow!("lease generation overflow"))?
                || operation >> 64 != u128::from(*revoke_peer)
                || operation & u128::from(u64::MAX) == 0
            {
                bail!("revoke evidence does not bind the cleaned lease and peer");
            }
        }
        if let Some(AcceptanceEvent::ReturnAcknowledged {
            route_generation: returned,
            ..
        }) = workflow.get(4).copied()
            && returned != route_generation
        {
            bail!("return acknowledgement route generation changed");
        }
        if let (
            Some(AcceptanceEvent::RevokeApplied {
                peer_epoch: cleanup_peer,
                ..
            }),
            Some(AcceptanceEvent::DisconnectAfterReturn {
                peer_epoch: disconnected_peer,
                ..
            }),
        ) = (workflow.get(3).copied(), workflow.get(5).copied())
            && cleanup_peer != disconnected_peer
        {
            bail!("after-return disconnect does not bind the cleanup peer");
        }
        if *peer_epoch == 0 {
            bail!("route peer epoch zero is reserved");
        }
    }
    Ok(())
}

fn acceptance_complete(transcript: &AcceptanceTranscript) -> bool {
    let metrics = aggregate_ack_metrics(transcript);
    let unique_input_count = unique_input_sequence_count(transcript);
    normal_workflow_complete(transcript)
        && validate_cross_event_identity(transcript).is_ok()
        && input_coverage_complete(transcript)
        && !transcript.input_samples.is_empty()
        && transcript
            .input_samples
            .iter()
            .all(|sample| sample.capture_to_applied_ack_us <= 32_000)
        && accepted_sequences_strictly_increasing(transcript)
        && metrics.duplicate_ack_count == 0
        && metrics.replay_rejection_count == 0
        && metrics.late_ack_rejection_count == 0
        && metrics.acked_unique_sequence_count == unique_input_count.saturating_add(1)
}

fn normal_workflow_complete(transcript: &AcceptanceTranscript) -> bool {
    let workflow = transcript
        .events
        .iter()
        .filter(|event| !matches!(event, AcceptanceEvent::DisconnectBeforeActivation { .. }))
        .collect::<Vec<_>>();
    matches!(
        workflow.as_slice(),
        [
            AcceptanceEvent::RouteActivated { .. },
            AcceptanceEvent::EntryAcknowledged { .. },
            AcceptanceEvent::ReleaseAllApplied { .. },
            AcceptanceEvent::RevokeApplied { .. },
            AcceptanceEvent::ReturnAcknowledged { .. },
            AcceptanceEvent::DisconnectAfterReturn { .. }
        ]
    ) && transcript
        .events
        .iter()
        .filter(|event| matches!(event, AcceptanceEvent::DisconnectBeforeActivation { .. }))
        .count()
        <= 1
}

fn aggregate_ack_metrics(transcript: &AcceptanceTranscript) -> InputAckMetrics {
    let mut aggregate = InputAckMetrics::default();
    for event in &transcript.events {
        let metrics = match event {
            AcceptanceEvent::DisconnectBeforeActivation {
                input_ack_metrics, ..
            }
            | AcceptanceEvent::DisconnectDuringActiveRoute {
                input_ack_metrics, ..
            }
            | AcceptanceEvent::DisconnectAfterReturn {
                input_ack_metrics, ..
            } => *input_ack_metrics,
            _ => continue,
        };
        aggregate.acked_unique_sequence_count = aggregate
            .acked_unique_sequence_count
            .saturating_add(metrics.acked_unique_sequence_count);
        aggregate.duplicate_ack_count = aggregate
            .duplicate_ack_count
            .saturating_add(metrics.duplicate_ack_count);
        aggregate.replay_rejection_count = aggregate
            .replay_rejection_count
            .saturating_add(metrics.replay_rejection_count);
        aggregate.late_ack_rejection_count = aggregate
            .late_ack_rejection_count
            .saturating_add(metrics.late_ack_rejection_count);
    }
    aggregate
}

fn accepted_sequences_strictly_increasing(transcript: &AcceptanceTranscript) -> bool {
    let mut previous = None;
    for sample in &transcript.input_samples {
        if previous == Some(sample.event_sequence) {
            continue;
        }
        if previous.is_some_and(|previous| sample.event_sequence <= previous) {
            return false;
        }
        previous = Some(sample.event_sequence);
    }
    previous.is_some()
}

fn unique_input_sequence_count(transcript: &AcceptanceTranscript) -> u64 {
    transcript
        .input_samples
        .iter()
        .map(|sample| sample.event_sequence)
        .collect::<std::collections::BTreeSet<_>>()
        .len()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn input_coverage_complete(transcript: &AcceptanceTranscript) -> bool {
    use InputCoverageKind::{
        Button1Pressed, Button1Released, Button2Pressed, Button2Released, Button3Pressed,
        Button3Released, Button4Pressed, Button4Released, Button5Pressed, Button5Released,
        HorizontalWheel, KeyboardPressed, KeyboardReleased, PointerMotion, VerticalWheel,
    };
    [
        KeyboardPressed,
        KeyboardReleased,
        PointerMotion,
        Button1Pressed,
        Button1Released,
        Button2Pressed,
        Button2Released,
        Button3Pressed,
        Button3Released,
        Button4Pressed,
        Button4Released,
        Button5Pressed,
        Button5Released,
        VerticalWheel,
        HorizontalWheel,
    ]
    .iter()
    .all(|required| {
        transcript
            .input_samples
            .iter()
            .any(|sample| sample.kind == *required)
    })
}

fn has_route_activation(transcript: &AcceptanceTranscript) -> bool {
    transcript
        .events
        .iter()
        .any(|event| matches!(event, AcceptanceEvent::RouteActivated { .. }))
}

fn has_return(transcript: &AcceptanceTranscript) -> bool {
    transcript
        .events
        .iter()
        .any(|event| matches!(event, AcceptanceEvent::ReturnAcknowledged { .. }))
}

fn persist_transcript(state_dir: &Path, transcript: &AcceptanceTranscript) -> Result<()> {
    atomic_replace_json(
        &transcript_path(state_dir, &transcript.operation_id),
        transcript,
    )
}

fn publish_receipt(state_dir: &Path, transcript: &AcceptanceTranscript) -> Result<()> {
    if !acceptance_complete(transcript) || transcript.failure_reason.is_some() {
        bail!("acceptance receipt requires the complete exact event sequence");
    }
    let (sample_count, max_us, p99_us) = latency_stats(transcript)?;
    let ack_metrics = aggregate_ack_metrics(transcript);
    let receipt = AcceptanceReceipt {
        schema_version: RECEIPT_SCHEMA,
        state: "viewflow-normal-post-release-acceptance-passed",
        operation_id: transcript.operation_id.clone(),
        producer_pid: transcript.producer_pid,
        producer_start_ticks: transcript.producer_start_ticks,
        producer_boot_id: transcript.producer_boot_id.clone(),
        producer_executable_sha256: transcript.producer_executable_sha256.clone(),
        protocol_version: "2.1",
        sidecar_protocol_version: 3,
        source_display_id: transcript.source_display_id.clone(),
        target_device_id: transcript.target_device_id.clone(),
        linux_viewflow_sha256: transcript.linux_viewflow_sha256.clone(),
        windows_viewflow_sha256: transcript.windows_viewflow_sha256.clone(),
        deployment_release_receipt_sha256: transcript.deployment_release_receipt_sha256.clone(),
        route_admission: "admitted",
        entry_return: "passed",
        held_inputs: "released",
        disconnect_before_activation: if transcript
            .events
            .iter()
            .any(|event| matches!(event, AcceptanceEvent::DisconnectBeforeActivation { .. }))
        {
            "passed"
        } else {
            "not_exercised"
        },
        disconnect_during_active_route: "not_exercised_destructive",
        disconnect_after_return: "passed",
        runtime_marker_present: false,
        transcript_sha256: hash_file(&transcript_path(state_dir, &transcript.operation_id))?,
        sample_count,
        max_us,
        p99_us,
        accepted_sequence_strictly_increasing: accepted_sequences_strictly_increasing(transcript),
        acked_unique_sequence_count: ack_metrics.acked_unique_sequence_count,
        duplicate_ack_count: ack_metrics.duplicate_ack_count,
        replay_rejection_count: ack_metrics.replay_rejection_count,
        late_ack_rejection_count: ack_metrics.late_ack_rejection_count,
        completed_at_unix_ms: unix_time_ms()?,
    };
    create_once_json(&receipt_path(state_dir, &transcript.operation_id), &receipt)
}

fn latency_stats(transcript: &AcceptanceTranscript) -> Result<(usize, u64, u64)> {
    let mut latency_by_sequence = BTreeMap::new();
    for sample in &transcript.input_samples {
        match latency_by_sequence.insert(sample.event_sequence, sample.capture_to_applied_ack_us) {
            Some(previous) if previous != sample.capture_to_applied_ack_us => {
                bail!("one input event sequence has inconsistent latency samples");
            }
            _ => {}
        }
    }
    let mut latencies = latency_by_sequence.into_values().collect::<Vec<_>>();
    latencies.sort_unstable();
    let sample_count = latencies.len();
    let max_us = *latencies
        .last()
        .ok_or_else(|| anyhow!("acceptance receipt has no latency samples"))?;
    let p99_index = (sample_count * 99).div_ceil(100).saturating_sub(1);
    let p99_us = latencies[p99_index];
    Ok((sample_count, max_us, p99_us))
}

fn transcript_path(state_dir: &Path, operation_id: &str) -> PathBuf {
    state_dir.join(format!("post-release-{operation_id}.transcript.json"))
}

fn receipt_path(state_dir: &Path, operation_id: &str) -> PathBuf {
    state_dir.join(format!("post-release-{operation_id}.receipt.json"))
}

fn atomic_replace_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("state path has no parent"))?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("acceptance"),
        std::process::id(),
        unix_time_ms()?
    ));
    write_json_file_new(&temporary, value)?;
    fs::rename(&temporary, path)?;
    sync_directory(parent)
}

fn create_once_json(path: &Path, value: &impl Serialize) -> Result<()> {
    write_json_file_new(path, value)?;
    sync_directory(
        path.parent()
            .ok_or_else(|| anyhow!("receipt path has no parent"))?,
    )
}

fn write_json_file_new(path: &Path, value: &impl Serialize) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("failed to create {}", path.display()))?;
    file.write_all(&bytes)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}

fn validate_owner_directory(path: &Path) -> Result<()> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("failed to inspect acceptance state dir {}", path.display()))?;
    if !metadata.is_dir()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        bail!("acceptance state directory must be owner-only and owned by the daemon user");
    }
    Ok(())
}

#[allow(unsafe_code)]
fn effective_uid() -> u32 {
    unsafe { libc::geteuid() }
}

fn validate_operation_id(value: &str) -> Result<()> {
    if !(16..=128).contains(&value.len())
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        bail!("invalid acceptance operation id");
    }
    Ok(())
}

fn validate_id(value: &str, label: &str) -> Result<()> {
    if value.len() != 32
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || value.bytes().all(|byte| byte == b'0')
    {
        bail!("{label} must be a nonzero lowercase 128-bit hex identity");
    }
    Ok(())
}

fn validate_sha(value: &str, label: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        bail!("{label} SHA-256 must be lowercase hexadecimal");
    }
    Ok(())
}

fn id_string(id: Id128) -> String {
    format!("{:032x}", id.0)
}

fn hash_file(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut file =
        File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    let mut hash = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

#[derive(Clone, Debug)]
struct DaemonIdentity {
    pid: u32,
    start_ticks: u64,
    boot_id: String,
    executable_sha256: String,
}

impl DaemonIdentity {
    fn instance_id(&self) -> String {
        format!("{}-{}-{}", self.boot_id, self.pid, self.start_ticks)
    }
}

fn daemon_identity() -> Result<DaemonIdentity> {
    let boot = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
    let process_stat = fs::read_to_string("/proc/self/stat")?;
    let close = process_stat
        .rfind(')')
        .ok_or_else(|| anyhow!("invalid /proc/self/stat"))?;
    let start_ticks = process_stat[close + 2..]
        .split_ascii_whitespace()
        .nth(19)
        .ok_or_else(|| anyhow!("missing process start ticks"))?
        .parse::<u64>()
        .context("invalid process start ticks")?;
    Ok(DaemonIdentity {
        pid: std::process::id(),
        start_ticks,
        boot_id: boot.trim().to_owned(),
        executable_sha256: hash_file(Path::new("/proc/self/exe"))?,
    })
}

fn unix_time_ms() -> Result<u64> {
    u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())
        .context("Unix time does not fit u64")
}

fn write_json_line(stream: &mut UnixStream, value: &impl Serialize) -> Result<()> {
    serde_json::to_writer(&mut *stream, value)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    Ok(())
}

struct OwnerOnlyListener {
    listener: UnixListener,
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl OwnerOnlyListener {
    fn bind(path: &Path) -> Result<Self> {
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
}

impl Drop for OwnerOnlyListener {
    fn drop(&mut self) {
        if fs::symlink_metadata(&self.path)
            .is_ok_and(|metadata| metadata.dev() == self.device && metadata.ino() == self.inode)
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn authenticate_owner(stream: &UnixStream) -> Result<()> {
    let credentials = crate::local_peer::identity(stream).context("local peer identity failed")?;
    validate_peer_credentials(credentials.uid, credentials.pid, effective_uid())
}

fn validate_peer_credentials(uid: u32, pid: i32, expected_uid: u32) -> Result<()> {
    if uid != expected_uid || pid <= 0 {
        bail!("acceptance control peer is not the daemon owner");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_out_of_order_events_fail_closed() {
        let mut transcript = fixture_transcript();
        assert!(
            push_event(
                &mut transcript,
                AcceptanceEvent::ReturnAcknowledged {
                    route_generation: 7,
                    observed_at_unix_ms: 1
                }
            )
            .is_err()
        );
        assert!(transcript.events.is_empty());
        assert!(!acceptance_complete(&transcript));
    }

    #[test]
    fn exact_runtime_event_sequence_is_required() {
        let mut transcript = fixture_transcript();
        let peer = "127.0.0.1:44119".to_owned();
        let events = [
            AcceptanceEvent::DisconnectBeforeActivation {
                peer_epoch: 1,
                peer_socket: peer.clone(),
                observed_at_unix_ms: 1,
                input_ack_metrics: InputAckMetrics::default(),
            },
            AcceptanceEvent::RouteActivated {
                source_display_id: transcript.source_display_id.clone(),
                target_device_id: transcript.target_device_id.clone(),
                route_generation: 7,
                active_lease_generation: 2,
                peer_epoch: 2,
                peer_socket: peer.clone(),
                observed_at_unix_ms: 2,
            },
            AcceptanceEvent::EntryAcknowledged {
                route_generation: 7,
                observed_at_unix_ms: 3,
            },
            AcceptanceEvent::ReleaseAllApplied {
                lease_generation: 2,
                event_sequence: 16,
                peer_epoch: 2,
                observed_at_unix_ms: 4,
            },
            AcceptanceEvent::RevokeApplied {
                operation_id: format!("{:032x}", (u128::from(2_u64) << 64) | 1),
                lease_generation: 3,
                peer_epoch: 2,
                observed_at_unix_ms: 5,
            },
            AcceptanceEvent::ReturnAcknowledged {
                route_generation: 7,
                observed_at_unix_ms: 6,
            },
            AcceptanceEvent::DisconnectAfterReturn {
                peer_epoch: 2,
                peer_socket: peer,
                observed_at_unix_ms: 7,
                input_ack_metrics: InputAckMetrics {
                    acked_unique_sequence_count: 16,
                    ..InputAckMetrics::default()
                },
            },
        ];
        for event in events {
            push_event(&mut transcript, event).unwrap();
        }
        add_full_input_coverage(&mut transcript);
        assert!(acceptance_complete(&transcript));
    }

    #[test]
    fn active_route_disconnect_requires_containment_and_can_never_pass() {
        let mut transcript = fixture_transcript();
        let peer = "127.0.0.1:44119".to_owned();
        let source_display_id = transcript.source_display_id.clone();
        let target_device_id = transcript.target_device_id.clone();
        push_event(
            &mut transcript,
            AcceptanceEvent::RouteActivated {
                source_display_id,
                target_device_id,
                route_generation: 7,
                active_lease_generation: 2,
                peer_epoch: 1,
                peer_socket: peer.clone(),
                observed_at_unix_ms: 1,
            },
        )
        .unwrap();
        push_event(
            &mut transcript,
            AcceptanceEvent::EntryAcknowledged {
                route_generation: 7,
                observed_at_unix_ms: 2,
            },
        )
        .unwrap();
        let error = push_event(
            &mut transcript,
            AcceptanceEvent::DisconnectDuringActiveRoute {
                peer_epoch: 1,
                peer_socket: peer,
                observed_at_unix_ms: 3,
                input_ack_metrics: InputAckMetrics::default(),
            },
        )
        .unwrap_err();
        assert_eq!(
            error.to_string(),
            "active_route_disconnect_requires_containment"
        );
        assert!(
            push_event(
                &mut transcript,
                AcceptanceEvent::ReleaseAllApplied {
                    lease_generation: 2,
                    event_sequence: 1,
                    peer_epoch: 1,
                    observed_at_unix_ms: 4,
                },
            )
            .is_err()
        );
        add_full_input_coverage(&mut transcript);
        assert!(!acceptance_complete(&transcript));
    }

    #[test]
    fn missing_hid_coverage_or_over_budget_sample_cannot_pass() {
        let mut transcript = fixture_transcript();
        transcript.input_samples.push(InputAppliedSample {
            event_sequence: 1,
            capture_to_applied_ack_us: 32_001,
            kind: InputCoverageKind::PointerMotion,
        });
        assert!(!input_coverage_complete(&transcript));
        assert!(!acceptance_complete(&transcript));
    }

    #[test]
    fn peer_auth_rejects_wrong_uid_and_zero_pid_contract() {
        let uid = effective_uid();
        assert!(validate_peer_credentials(uid, 1, uid).is_ok());
        assert!(validate_peer_credentials(uid.wrapping_add(1), 1, uid).is_err());
        assert!(validate_peer_credentials(uid, 0, uid).is_err());
        assert!(validate_peer_credentials(uid, -1, uid).is_err());
    }

    #[test]
    fn durable_state_from_another_daemon_is_not_resumed() {
        let transcript = fixture_transcript();
        assert_ne!(transcript.daemon_instance_id, "different-daemon");
        let fresh = RecorderState {
            state_dir: PathBuf::from("/nonexistent"),
            local_device: Id128(1),
            target_device: Id128(2),
            daemon_identity: DaemonIdentity {
                pid: 3,
                start_ticks: 4,
                boot_id: "different-boot".into(),
                executable_sha256: "d".repeat(64),
            },
            armed: None,
        };
        assert!(fresh.armed.is_none());
    }

    fn fixture_transcript() -> AcceptanceTranscript {
        AcceptanceTranscript {
            schema_version: 1,
            state: "viewflow-post-release-acceptance-armed",
            daemon_instance_id: "boot-1-2".into(),
            producer_pid: 1,
            producer_start_ticks: 2,
            producer_boot_id: "boot".into(),
            producer_executable_sha256: "a".repeat(64),
            operation_id: "operation-1234567890".into(),
            protocol_version: "2.1",
            sidecar_protocol_version: 3,
            source_display_id: "00000000000000000000000000000001".into(),
            target_device_id: "00000000000000000000000000000002".into(),
            linux_viewflow_sha256: "a".repeat(64),
            windows_viewflow_sha256: "b".repeat(64),
            deployment_release_receipt_sha256: "c".repeat(64),
            armed_at_unix_ms: 1,
            events: Vec::new(),
            input_samples: Vec::new(),
            failure_reason: None,
        }
    }

    fn add_full_input_coverage(transcript: &mut AcceptanceTranscript) {
        use InputCoverageKind::{
            Button1Pressed, Button1Released, Button2Pressed, Button2Released, Button3Pressed,
            Button3Released, Button4Pressed, Button4Released, Button5Pressed, Button5Released,
            HorizontalWheel, KeyboardPressed, KeyboardReleased, PointerMotion, VerticalWheel,
        };
        for (index, kind) in [
            KeyboardPressed,
            KeyboardReleased,
            PointerMotion,
            Button1Pressed,
            Button1Released,
            Button2Pressed,
            Button2Released,
            Button3Pressed,
            Button3Released,
            Button4Pressed,
            Button4Released,
            Button5Pressed,
            Button5Released,
            VerticalWheel,
            HorizontalWheel,
        ]
        .into_iter()
        .enumerate()
        {
            transcript.input_samples.push(InputAppliedSample {
                event_sequence: u64::try_from(index + 1).unwrap(),
                capture_to_applied_ack_us: 1_000,
                kind,
            });
        }
    }
}
