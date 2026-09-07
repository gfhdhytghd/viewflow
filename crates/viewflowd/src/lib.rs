use std::{
    collections::BTreeMap,
    error::Error,
    fmt,
    future::Future,
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use prost::Message;
use quinn::{Connection, Endpoint, Incoming};
use serde::Serialize;
#[cfg(unix)]
use sha2::{Digest, Sha256};
use tokio::{
    sync::{Notify, mpsc, oneshot, watch},
    task::JoinHandle,
    time::{sleep, sleep_until, timeout},
};
use viewflow_protocol::{
    ClockSyncReply, DomainControl, Id128, InputAppliedAck, InputAppliedResult, InputEvent,
    InputLeaseRevoke, InputLeaseRevokedAck, InputLeaseRevokedResult, InputLeaseState,
    PROTOCOL_VERSION, wire,
};
#[cfg(test)]
use viewflow_transport::receive_control_sequenced;
use viewflow_transport::{
    BlobChunk, ClockEstimate, ControlSequencer, PeerIdentity, ReliablePayload, build_client_config,
    build_server_config, receive_reliable, send_control,
};

#[cfg(unix)]
mod acceptance_runtime;
pub mod alpha_reference;
pub mod atlas_clock;
#[cfg(target_os = "linux")]
mod atlas_cursor_handoff;
mod atlas_cursor_receiver;
pub mod atlas_feedback;
#[cfg(target_os = "linux")]
pub mod atlas_input_policy;
pub mod atlas_input_recovery;
pub mod atlas_peer;
pub mod atlas_pointer;
pub mod atlas_presenter;
pub mod atlas_presenter_child;
pub mod atlas_preview_input;
pub mod atlas_receiver_presenter;
pub mod atlas_runtime;
pub mod atlas_session;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod atlas_source;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
mod atlas_source_input;
#[cfg(windows)]
mod bootstrap_runtime;
pub mod clipboard_runtime;
mod clock_retention;
pub mod desktop_config;
pub mod desktop_pointer;
#[cfg(target_os = "linux")]
pub mod desktop_probe;
mod desktop_receiver_state;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod desktop_source;
mod file_transfer;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod gpu_atlas_capture;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod gpu_atlas_device;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod gpu_atlas_sender;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod gpu_atlas_session;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod gpu_atlas_warmup;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod gpu_compatible_encoder;
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
pub mod gpu_nvenc_runtime;
pub mod gpu_presenter_pipe;
pub mod hyprcapture_gpu_release;
#[cfg(target_os = "linux")]
pub mod hyprcapture_gpu_socket;
pub mod hyprcapture_gpu_wire;
#[cfg(target_os = "linux")]
pub mod hyprcapture_runtime;
#[cfg(unix)]
mod local_peer;
pub mod shared_control;
mod window_icon;
mod window_forwarded_preview;
#[cfg(not(target_os = "linux"))]
pub mod hyprcapture_runtime {
    //! Platform stub: HyprCapture is a Linux Hyprland plugin.
    use std::time::Duration;

    use anyhow::{Result, bail};
    use bytes::Bytes;

    #[derive(Clone, Debug)]
    pub struct CapturedRawFrame {
        pub payload: Bytes,
        pub logical_width: f64,
        pub logical_height: f64,
        pub capture_elapsed: Duration,
    }

    pub async fn capture_window(
        _window_address: &str,
        _max_pixel_bytes: usize,
        _timeout: Duration,
    ) -> Result<CapturedRawFrame> {
        bail!("HyprCapture window capture is only available on Linux")
    }
}
#[cfg(any(windows, all(target_os = "linux", feature = "native-nvenc")))]
pub mod coded_peer;
#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
pub mod compatible_encoder;
#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
pub mod encoded_media;
pub mod hyprcapture_control;
#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
pub mod hyprcapture_encoder;
#[cfg(target_os = "linux")]
pub mod hyprcapture_socket;
pub mod hyprcapture_stream;
mod input_runtime;
pub mod media_runtime;
#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
pub mod nvenc_runtime;
pub mod pixel_runtime;
pub mod raw_session;
mod readiness_runtime;
#[cfg(unix)]
mod sidecar_runtime;
#[cfg(target_os = "linux")]
pub mod window_input_runtime;
pub mod window_preview_input;

#[cfg(unix)]
use acceptance_runtime::{
    AcceptanceArmConfig, AcceptanceQueryConfig, acceptance_arm, acceptance_query,
};
#[cfg(unix)]
use acceptance_runtime::{AcceptanceConfig, AcceptanceRecorder, run_acceptance_control};
#[cfg(windows)]
use bootstrap_runtime::{ForceReleaseInputConfig, force_release_input};
#[cfg(any(unix, test))]
use input_runtime::input_lease_revoke_payload;
use input_runtime::{
    ClockSnapshot, InputBackendMode, InputReceiver, InputScript, ensure_backend_available,
    input_applied_ack_payload, input_event_payload, input_lease_revoked_ack_payload,
};
use readiness_runtime::{
    ReadinessCommitConfig, ReadinessConfig, establish_readiness, try_commit_readiness,
    validate_readiness_startup,
};
#[cfg(unix)]
use sidecar_runtime::{
    ArmQuiesceConfig, ProducerPeerRegistry, SidecarProducerConfig, arm_quiescence,
    run_sidecar_producer,
};

pub const USAGE: &str = "Viewflow authenticated QUIC peer health check

Usage:
  viewflowd serve --bind <IP:PORT> --cert <PEM> --key <PEM> --ca <PEM> [options]
  viewflowd connect --peer <IP:PORT> --server-name <TLS_NAME> --cert <PEM> --key <PEM> --ca <PEM> [options]
  viewflowd arm-quiesce --arm-file <PATH> --operation-id <ID> --daemon-pid <PID>
  viewflowd trigger-quiesce --sidecar-socket <PATH>
  viewflowd acceptance-arm --acceptance-socket <PATH> --operation-id <ID> --source-display-id <ID> --target-device-id <ID> --linux-viewflow-sha256 <LOWER64> --windows-viewflow-sha256 <LOWER64> --deployment-release-receipt <PATH> --deployment-release-receipt-sha256 <LOWER64>
  viewflowd acceptance-query --acceptance-socket <PATH> --operation-id <ID>
  viewflowd force-release-input --receipt <PATH> --operation-id <ID> --linux-evidence-sha256 <LOWER64>  (Windows only)

Serve options:
  --input-script <PATH>            Send one validated smoke-input script once
  --input-script-peer <IP>         Only send the script to this peer address
  --sidecar-socket <PATH>          Owner-only Deskflow sidecar Unix socket
  --sidecar-peer <IP>              Authenticated peer IP for sidecar input
  --sidecar-target-device <ID>     Remote device receiving sidecar input
  --quiesce-proof <PATH>           Structured deployment receipt output
  --quiesce-arm-file <PATH>        One-shot owner-only deployment arm file
  --acceptance-socket <PATH>       Owner-only post-release acceptance control socket
  --acceptance-state-dir <PATH>    Owner-only durable acceptance evidence directory

Common options:
  --probe-interval-ms <MS>         Delay between successful probes (default: 1000)
  --probe-timeout-ms <MS>          Per-probe timeout (default: 3000)
  --input-backend <MODE>           disabled (default) or native (Windows only)
  --device-id <32_HEX_DIGITS>      Stable local device identity (required for native)

Connect options:
  --bind <IP:PORT>                 Local UDP address (default: 0.0.0.0:0)
  --reconnect-delay-ms <MS>        Initial reconnect delay (default: 250)
  --max-reconnect-delay-ms <MS>    Reconnect delay ceiling (default: 5000)
  --readiness-receipt <PATH>       Create-once post-mTLS deployment receipt (Windows only)
  --readiness-lock <PATH>          Connection-lifetime readiness witness (Windows only)
  --readiness-commit-request <PATH> Strict installer-to-daemon commit request (Windows only)
  --install-success-receipt <PATH> Daemon-authored create-once install result (Windows only)
  --operation-id <ID>              Deployment operation bound into readiness evidence

This peer uses its own UDP port and does not stop, replace, or reconfigure Deskflow.";

const DEFAULT_CLIENT_BIND: &str = "0.0.0.0:0";
const DEFAULT_PROBE_INTERVAL_MS: u64 = 1_000;
const DEFAULT_PROBE_TIMEOUT_MS: u64 = 3_000;
const DEFAULT_RECONNECT_DELAY_MS: u64 = 250;
const DEFAULT_MAX_RECONNECT_DELAY_MS: u64 = 5_000;
// Keep the receiver acknowledgement inside the producer transaction budget.
// The enclosing sidecar call is capped at 32 ms, just under two 60 Hz frames.
const INPUT_APPLIED_TIMEOUT: Duration = Duration::from_millis(24);
const INPUT_ACK_TOMBSTONE_TTL: Duration = Duration::from_secs(5);
const MAX_INPUT_ACK_TOMBSTONES: usize = 256;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IdentityPaths {
    pub certificate: PathBuf,
    pub private_key: PathBuf,
    pub certificate_authority: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServeConfig {
    pub bind: SocketAddr,
    pub identity: IdentityPaths,
    pub probe_interval: Duration,
    pub probe_timeout: Duration,
    pub input_backend: InputBackendMode,
    pub device_id: Option<Id128>,
    pub input_script: Option<PathBuf>,
    pub input_script_peer: Option<IpAddr>,
    pub sidecar_socket: Option<PathBuf>,
    pub sidecar_peer: Option<IpAddr>,
    pub sidecar_target_device: Option<Id128>,
    /// When configured, a Deskflow sidecar disconnect becomes a one-way
    /// deployment quiesce boundary. The daemon cleans the route, fences the
    /// peer, writes a structured receipt, and exits.
    pub quiesce_proof: Option<PathBuf>,
    pub quiesce_arm_file: Option<PathBuf>,
    #[cfg(unix)]
    pub acceptance: Option<AcceptanceConfig>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConnectConfig {
    pub bind: SocketAddr,
    pub peer: SocketAddr,
    pub server_name: String,
    pub identity: IdentityPaths,
    pub probe_interval: Duration,
    pub probe_timeout: Duration,
    pub reconnect_delay: Duration,
    pub max_reconnect_delay: Duration,
    pub input_backend: InputBackendMode,
    pub device_id: Option<Id128>,
    pub readiness: Option<ReadinessConfig>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    Serve(ServeConfig),
    Connect(ConnectConfig),
    #[cfg(unix)]
    ArmQuiesce(ArmQuiesceConfig),
    #[cfg(unix)]
    TriggerQuiesce(PathBuf),
    #[cfg(unix)]
    AcceptanceArm(AcceptanceArmConfig),
    #[cfg(unix)]
    AcceptanceQuery(AcceptanceQueryConfig),
    #[cfg(windows)]
    ForceReleaseInput(ForceReleaseInputConfig),
}

/// Parses the dependency-free CLI used on Linux and Windows peers.
///
/// # Errors
///
/// Rejects missing, duplicate, unknown, or invalid options.
#[allow(clippy::too_many_lines)]
pub fn parse_args<I, S>(arguments: I) -> Result<Command>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut arguments = arguments.into_iter().map(Into::into);
    let mode = arguments
        .next()
        .ok_or_else(|| anyhow!("missing command: expected serve or connect"))?;
    let options = parse_options(arguments)?;
    match mode.as_str() {
        "serve" | "connect" => {
            let identity = IdentityPaths {
                certificate: required_path(&options, "cert")?,
                private_key: required_path(&options, "key")?,
                certificate_authority: required_path(&options, "ca")?,
            };
            if mode == "serve" {
                Ok(Command::Serve(parse_serve_config(&options, identity)?))
            } else {
                Ok(Command::Connect(parse_connect_config(&options, identity)?))
            }
        }
        #[cfg(unix)]
        "arm-quiesce" => Ok(Command::ArmQuiesce(parse_arm_quiesce_config(&options)?)),
        #[cfg(unix)]
        "trigger-quiesce" => {
            reject_unknown(&options, &["sidecar-socket"])?;
            Ok(Command::TriggerQuiesce(required_path(
                &options,
                "sidecar-socket",
            )?))
        }
        #[cfg(unix)]
        "acceptance-arm" => {
            reject_unknown(
                &options,
                &[
                    "acceptance-socket",
                    "operation-id",
                    "source-display-id",
                    "target-device-id",
                    "linux-viewflow-sha256",
                    "windows-viewflow-sha256",
                    "deployment-release-receipt",
                    "deployment-release-receipt-sha256",
                ],
            )?;
            let operation_id = required(&options, "operation-id")?.to_owned();
            validate_operation_id(&operation_id)?;
            let source_display_id = required_lower_id(&options, "source-display-id")?;
            let target_device_id = required_lower_id(&options, "target-device-id")?;
            let linux_viewflow_sha256 = required(&options, "linux-viewflow-sha256")?.to_owned();
            validate_lower_sha256(&linux_viewflow_sha256, "--linux-viewflow-sha256")?;
            let windows_viewflow_sha256 = required(&options, "windows-viewflow-sha256")?.to_owned();
            validate_lower_sha256(&windows_viewflow_sha256, "--windows-viewflow-sha256")?;
            let deployment_release_receipt_sha256 =
                required(&options, "deployment-release-receipt-sha256")?.to_owned();
            validate_lower_sha256(
                &deployment_release_receipt_sha256,
                "--deployment-release-receipt-sha256",
            )?;
            Ok(Command::AcceptanceArm(AcceptanceArmConfig {
                socket_path: required_path(&options, "acceptance-socket")?,
                operation_id,
                source_display_id,
                target_device_id,
                linux_viewflow_sha256,
                windows_viewflow_sha256,
                deployment_release_receipt_path: required_path(
                    &options,
                    "deployment-release-receipt",
                )?,
                deployment_release_receipt_sha256,
            }))
        }
        #[cfg(unix)]
        "acceptance-query" => {
            reject_unknown(&options, &["acceptance-socket", "operation-id"])?;
            let operation_id = required(&options, "operation-id")?.to_owned();
            validate_operation_id(&operation_id)?;
            Ok(Command::AcceptanceQuery(AcceptanceQueryConfig {
                socket_path: required_path(&options, "acceptance-socket")?,
                operation_id,
            }))
        }
        #[cfg(not(unix))]
        "acceptance-arm" | "acceptance-query" => {
            bail!("post-release acceptance control is only available on Unix")
        }
        #[cfg(windows)]
        "force-release-input" => {
            reject_unknown(
                &options,
                &["receipt", "operation-id", "linux-evidence-sha256"],
            )?;
            let operation_id = required(&options, "operation-id")?.to_owned();
            validate_operation_id(&operation_id)?;
            let linux_frozen_evidence_sha256 =
                required(&options, "linux-evidence-sha256")?.to_owned();
            validate_lower_sha256(&linux_frozen_evidence_sha256, "--linux-evidence-sha256")?;
            Ok(Command::ForceReleaseInput(ForceReleaseInputConfig {
                receipt: required_path(&options, "receipt")?,
                operation_id,
                linux_frozen_evidence_sha256,
            }))
        }
        #[cfg(not(windows))]
        "force-release-input" => bail!("force-release-input is only available on Windows"),
        _ => bail!("unknown command {mode:?}: expected serve, connect, or arm-quiesce"),
    }
}

fn parse_serve_config(
    options: &BTreeMap<String, String>,
    identity: IdentityPaths,
) -> Result<ServeConfig> {
    reject_unknown(
        options,
        &[
            "bind",
            "cert",
            "key",
            "ca",
            "probe-interval-ms",
            "probe-timeout-ms",
            "input-backend",
            "device-id",
            "input-script",
            "input-script-peer",
            "sidecar-socket",
            "sidecar-peer",
            "sidecar-target-device",
            "quiesce-proof",
            "quiesce-arm-file",
            "acceptance-socket",
            "acceptance-state-dir",
        ],
    )?;
    let input_script = options.get("input-script").map(PathBuf::from);
    let input_script_peer = options
        .get("input-script-peer")
        .map(|value| {
            value
                .parse::<IpAddr>()
                .context("invalid --input-script-peer")
        })
        .transpose()?;
    if input_script.is_some() != input_script_peer.is_some() {
        bail!("--input-script and --input-script-peer must be provided together");
    }
    let (sidecar_socket, sidecar_peer, sidecar_target_device, device_id) =
        serve_sidecar_options(options, input_script.as_deref())?;
    let quiesce_proof = options.get("quiesce-proof").map(PathBuf::from);
    let quiesce_arm_file = options.get("quiesce-arm-file").map(PathBuf::from);
    if quiesce_proof.is_some() != quiesce_arm_file.is_some() {
        bail!("--quiesce-proof and --quiesce-arm-file must be provided together");
    }
    if quiesce_proof.is_some() && sidecar_socket.is_none() {
        bail!("quiescence output requires --sidecar-socket");
    }
    #[cfg(not(unix))]
    if options.contains_key("acceptance-socket") || options.contains_key("acceptance-state-dir") {
        bail!("post-release acceptance serve options are only available on Unix");
    }
    #[cfg(unix)]
    let acceptance_socket = options.get("acceptance-socket").map(PathBuf::from);
    #[cfg(unix)]
    let acceptance_state_dir = options.get("acceptance-state-dir").map(PathBuf::from);
    #[cfg(unix)]
    if acceptance_socket.is_some() != acceptance_state_dir.is_some() {
        bail!("--acceptance-socket and --acceptance-state-dir must be provided together");
    }
    #[cfg(unix)]
    if acceptance_socket.is_some() && sidecar_socket.is_none() {
        bail!("post-release acceptance control requires --sidecar-socket");
    }
    #[cfg(unix)]
    let acceptance = acceptance_socket.map(|socket_path| AcceptanceConfig {
        socket_path,
        state_dir: acceptance_state_dir.expect("paired acceptance option exists"),
    });
    Ok(ServeConfig {
        bind: required_socket(options, "bind")?,
        identity,
        probe_interval: duration_option(options, "probe-interval-ms", DEFAULT_PROBE_INTERVAL_MS)?,
        probe_timeout: duration_option(options, "probe-timeout-ms", DEFAULT_PROBE_TIMEOUT_MS)?,
        input_backend: input_backend_option(options)?,
        device_id,
        input_script,
        input_script_peer,
        sidecar_socket,
        sidecar_peer,
        sidecar_target_device,
        quiesce_proof,
        quiesce_arm_file,
        #[cfg(unix)]
        acceptance,
    })
}

#[cfg(unix)]
fn parse_arm_quiesce_config(options: &BTreeMap<String, String>) -> Result<ArmQuiesceConfig> {
    reject_unknown(options, &["arm-file", "operation-id", "daemon-pid"])?;
    let operation_id = required(options, "operation-id")?.to_owned();
    validate_operation_id(&operation_id)?;
    let daemon_pid = required(options, "daemon-pid")?
        .parse::<u32>()
        .context("invalid --daemon-pid")?;
    if daemon_pid == 0 {
        bail!("--daemon-pid must be greater than zero");
    }
    Ok(ArmQuiesceConfig {
        arm_file: required_path(options, "arm-file")?,
        operation_id,
        daemon_pid,
    })
}

fn validate_operation_id(operation_id: &str) -> Result<()> {
    if !(16..=128).contains(&operation_id.len())
        || !operation_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        bail!("--operation-id must be 16-128 ASCII letters, digits, '-' or '_'");
    }
    Ok(())
}

fn validate_lower_sha256(value: &str, option: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        bail!("{option} must be exactly 64 lowercase hexadecimal characters");
    }
    Ok(())
}

fn required_lower_id(options: &BTreeMap<String, String>, name: &str) -> Result<String> {
    let value = required(options, name)?;
    let parsed = parse_device_id(value)?;
    Ok(format!("{:032x}", parsed.0))
}

fn parse_connect_config(
    options: &BTreeMap<String, String>,
    identity: IdentityPaths,
) -> Result<ConnectConfig> {
    reject_unknown(
        options,
        &[
            "bind",
            "peer",
            "server-name",
            "cert",
            "key",
            "ca",
            "probe-interval-ms",
            "probe-timeout-ms",
            "reconnect-delay-ms",
            "max-reconnect-delay-ms",
            "input-backend",
            "device-id",
            "readiness-receipt",
            "readiness-lock",
            "readiness-commit-request",
            "install-success-receipt",
            "operation-id",
        ],
    )?;
    let reconnect_delay =
        duration_option(options, "reconnect-delay-ms", DEFAULT_RECONNECT_DELAY_MS)?;
    let max_reconnect_delay = duration_option(
        options,
        "max-reconnect-delay-ms",
        DEFAULT_MAX_RECONNECT_DELAY_MS,
    )?;
    if reconnect_delay > max_reconnect_delay {
        bail!("--reconnect-delay-ms must not exceed --max-reconnect-delay-ms");
    }
    let input_backend = input_backend_option(options)?;
    let device_id = device_id_option(options)?;
    let readiness = parse_readiness_config(options, input_backend, device_id)?;
    Ok(ConnectConfig {
        bind: socket_option(options, "bind", DEFAULT_CLIENT_BIND)?,
        peer: required_socket(options, "peer")?,
        server_name: required(options, "server-name")?.to_owned(),
        identity,
        probe_interval: duration_option(options, "probe-interval-ms", DEFAULT_PROBE_INTERVAL_MS)?,
        probe_timeout: duration_option(options, "probe-timeout-ms", DEFAULT_PROBE_TIMEOUT_MS)?,
        reconnect_delay,
        max_reconnect_delay,
        input_backend,
        device_id,
        readiness,
    })
}

fn parse_readiness_config(
    options: &BTreeMap<String, String>,
    input_backend: InputBackendMode,
    device_id: Option<Id128>,
) -> Result<Option<ReadinessConfig>> {
    let receipt = options.get("readiness-receipt").map(PathBuf::from);
    let lock = options.get("readiness-lock").map(PathBuf::from);
    let operation_id = options.get("operation-id").cloned();
    let commit_request = options.get("readiness-commit-request").map(PathBuf::from);
    let install_success_receipt = options.get("install-success-receipt").map(PathBuf::from);
    if commit_request.is_some() != install_success_receipt.is_some() {
        bail!("--readiness-commit-request and --install-success-receipt must be provided together");
    }
    let count = usize::from(receipt.is_some())
        + usize::from(lock.is_some())
        + usize::from(operation_id.is_some());
    if count == 0 {
        if commit_request.is_some() {
            bail!("readiness commit paths require the post-mTLS readiness option group");
        }
        return Ok(None);
    }
    if count != 3 {
        bail!(
            "--readiness-receipt, --readiness-lock, and --operation-id must be provided together"
        );
    }
    if input_backend != InputBackendMode::Native || device_id.is_none() {
        bail!("post-mTLS readiness requires --input-backend native and --device-id");
    }
    let operation_id = operation_id.expect("option count proves operation-id exists");
    validate_operation_id(&operation_id)?;
    let receipt = receipt.expect("option count proves receipt exists");
    let lock = lock.expect("option count proves lock exists");
    if receipt == lock {
        bail!("--readiness-receipt and --readiness-lock must name different files");
    }
    let commit = commit_request.map(|request| ReadinessCommitConfig {
        request,
        install_success_receipt: install_success_receipt
            .expect("paired commit option proves install-success path exists"),
    });
    if let Some(commit) = &commit {
        let mut paths = [
            &receipt,
            &lock,
            &commit.request,
            &commit.install_success_receipt,
        ];
        paths.sort();
        if paths.windows(2).any(|pair| pair[0] == pair[1]) {
            bail!("readiness evidence and commit paths must name four different files");
        }
    }
    Ok(Some(ReadinessConfig {
        receipt,
        lock,
        operation_id,
        commit,
    }))
}

type ServeSidecarOptions = (
    Option<PathBuf>,
    Option<IpAddr>,
    Option<Id128>,
    Option<Id128>,
);

fn serve_sidecar_options(
    options: &BTreeMap<String, String>,
    input_script: Option<&Path>,
) -> Result<ServeSidecarOptions> {
    let socket = options.get("sidecar-socket").map(PathBuf::from);
    let peer = options
        .get("sidecar-peer")
        .map(|value| value.parse::<IpAddr>().context("invalid --sidecar-peer"))
        .transpose()?;
    let target = options
        .get("sidecar-target-device")
        .map(|value| parse_device_id(value))
        .transpose()?;
    let option_count =
        usize::from(socket.is_some()) + usize::from(peer.is_some()) + usize::from(target.is_some());
    if option_count != 0 && option_count != 3 {
        bail!(
            "--sidecar-socket, --sidecar-peer, and --sidecar-target-device must be provided \
             together"
        );
    }
    if socket.is_some() && input_script.is_some() {
        bail!("--sidecar-socket and --input-script are mutually exclusive");
    }
    let device_id = device_id_option(options)?;
    if socket.is_some() && device_id.is_none() {
        bail!("--sidecar-socket requires --device-id");
    }
    Ok((socket, peer, target, device_id))
}

fn input_backend_option(options: &BTreeMap<String, String>) -> Result<InputBackendMode> {
    options
        .get("input-backend")
        .map_or(Ok(InputBackendMode::Disabled), |value| value.parse())
}

fn ensure_local_input_identity(mode: InputBackendMode, device_id: Option<Id128>) -> Result<()> {
    if mode == InputBackendMode::Native && device_id.is_none() {
        bail!("--input-backend native requires --device-id");
    }
    Ok(())
}

fn device_id_option(options: &BTreeMap<String, String>) -> Result<Option<Id128>> {
    options
        .get("device-id")
        .map(|value| parse_device_id(value))
        .transpose()
}

fn parse_device_id(value: &str) -> Result<Id128> {
    let digits = value.strip_prefix("0x").unwrap_or(value);
    if digits.len() != 32 || !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("--device-id must contain exactly 32 hexadecimal digits");
    }
    let id = u128::from_str_radix(digits, 16).context("invalid --device-id")?;
    if id == 0 {
        bail!("--device-id zero is reserved");
    }
    Ok(Id128(id))
}

fn parse_options<I>(mut arguments: I) -> Result<BTreeMap<String, String>>
where
    I: Iterator<Item = String>,
{
    let mut options = BTreeMap::new();
    while let Some(option) = arguments.next() {
        let name = option
            .strip_prefix("--")
            .filter(|name| !name.is_empty())
            .ok_or_else(|| anyhow!("expected --option, got {option:?}"))?;
        let value = arguments
            .next()
            .ok_or_else(|| anyhow!("missing value for --{name}"))?;
        if value.starts_with("--") {
            bail!("missing value for --{name}");
        }
        if options.insert(name.to_owned(), value).is_some() {
            bail!("duplicate option --{name}");
        }
    }
    Ok(options)
}

fn required<'a>(options: &'a BTreeMap<String, String>, name: &str) -> Result<&'a str> {
    options
        .get(name)
        .map(String::as_str)
        .ok_or_else(|| anyhow!("missing required option --{name}"))
}

fn required_path(options: &BTreeMap<String, String>, name: &str) -> Result<PathBuf> {
    Ok(PathBuf::from(required(options, name)?))
}

fn required_socket(options: &BTreeMap<String, String>, name: &str) -> Result<SocketAddr> {
    required(options, name)?
        .parse()
        .with_context(|| format!("invalid socket address for --{name}"))
}

fn socket_option(
    options: &BTreeMap<String, String>,
    name: &str,
    default: &str,
) -> Result<SocketAddr> {
    options
        .get(name)
        .map_or(default, String::as_str)
        .parse()
        .with_context(|| format!("invalid socket address for --{name}"))
}

fn duration_option(
    options: &BTreeMap<String, String>,
    name: &str,
    default_milliseconds: u64,
) -> Result<Duration> {
    let milliseconds = options
        .get(name)
        .map_or(Ok(default_milliseconds), |value| {
            value
                .parse::<u64>()
                .with_context(|| format!("invalid integer for --{name}"))
        })?;
    if milliseconds == 0 {
        bail!("--{name} must be greater than zero");
    }
    Ok(Duration::from_millis(milliseconds))
}

fn reject_unknown(options: &BTreeMap<String, String>, allowed: &[&str]) -> Result<()> {
    if let Some(name) = options
        .keys()
        .find(|name| !allowed.contains(&name.as_str()))
    {
        bail!("unknown option --{name}");
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct ProcessClock {
    origin: Instant,
}

impl ProcessClock {
    fn new() -> Self {
        Self {
            origin: Instant::now(),
        }
    }

    fn now_ns(&self) -> u64 {
        u64::try_from(self.origin.elapsed().as_nanos()).unwrap_or(u64::MAX)
    }
}

/// Runs the selected peer role until it is stopped externally.
///
/// # Errors
///
/// Returns identity, socket, TLS, and endpoint failures. Client session errors
/// are logged and retried with a bounded exponential delay.
pub async fn run(command: Command) -> Result<()> {
    match command {
        Command::Serve(config) => run_server(config).await,
        Command::Connect(config) => run_client(config).await,
        #[cfg(unix)]
        Command::ArmQuiesce(config) => arm_quiescence(&config),
        #[cfg(unix)]
        Command::TriggerQuiesce(socket) => {
            use std::net::Shutdown;
            use std::os::unix::net::UnixStream;
            let stream = UnixStream::connect(&socket)
                .with_context(|| format!("failed to connect {}", socket.display()))?;
            stream
                .shutdown(Shutdown::Both)
                .with_context(|| format!("failed to close {}", socket.display()))?;
            Ok(())
        }
        #[cfg(unix)]
        Command::AcceptanceArm(config) => acceptance_arm(&config),
        #[cfg(unix)]
        Command::AcceptanceQuery(config) => acceptance_query(&config),
        #[cfg(windows)]
        Command::ForceReleaseInput(config) => force_release_input(&config),
    }
}

fn load_identity(paths: &IdentityPaths) -> Result<PeerIdentity> {
    let certificate = read_file(&paths.certificate)?;
    let private_key = read_file(&paths.private_key)?;
    let certificate_authority = read_file(&paths.certificate_authority)?;
    PeerIdentity::from_pem(&certificate, &private_key, &certificate_authority)
        .map_err(|error| anyhow!("invalid peer identity: {error}"))
}

fn read_file(path: &Path) -> Result<Vec<u8>> {
    std::fs::read(path).with_context(|| format!("failed to read {}", path.display()))
}

#[cfg(unix)]
fn sha256_file(path: &Path) -> Result<String> {
    let bytes = read_file(path)?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

#[cfg(unix)]
pub(crate) fn sha256_file_handle(file: &mut std::fs::File) -> Result<String> {
    use std::io::Read;

    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 8 * 1024];
    loop {
        let read = file.read(&mut buffer).context("failed to hash open file")?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

#[cfg(unix)]
fn running_executable_sha256() -> Result<String> {
    let mut executable = std::fs::File::open("/proc/self/exe")
        .context("failed to open running viewflowd executable")?;
    let metadata = executable
        .metadata()
        .context("failed to inspect running viewflowd executable")?;
    if !metadata.is_file() {
        bail!("running viewflowd executable is not a regular file");
    }
    sha256_file_handle(&mut executable)
}

#[cfg(unix)]
fn quiescence_artifact_hashes(config: &ServeConfig) -> Result<BTreeMap<String, String>> {
    let mut hashes = BTreeMap::new();
    hashes.insert("linux_viewflowd".into(), running_executable_sha256()?);
    hashes.insert(
        "linux_peer_certificate".into(),
        sha256_file(&config.identity.certificate)?,
    );
    hashes.insert(
        "linux_peer_private_key".into(),
        sha256_file(&config.identity.private_key)?,
    );
    hashes.insert(
        "linux_certificate_authority".into(),
        sha256_file(&config.identity.certificate_authority)?,
    );
    Ok(hashes)
}

#[allow(clippy::too_many_lines)]
async fn run_server(config: ServeConfig) -> Result<()> {
    ensure_backend_available(config.input_backend)?;
    ensure_local_input_identity(config.input_backend, config.device_id)?;
    #[cfg(not(unix))]
    if config.sidecar_socket.is_some() {
        bail!("--sidecar-socket is only available on Unix");
    }
    let input_script = config
        .input_script
        .as_deref()
        .map(InputScript::from_path)
        .transpose()?
        .map(Arc::new);
    let identity = load_identity(&config.identity)?;
    let server_config = build_server_config(&identity)
        .map_err(|error| anyhow!("invalid QUIC server identity: {error}"))?;
    let endpoint = Endpoint::server(server_config, config.bind)
        .with_context(|| format!("failed to bind QUIC server to {}", config.bind))?;
    let local_address = endpoint
        .local_addr()
        .context("failed to read local QUIC address")?;
    println!(
        "viewflowd protocol {}.{} serving mTLS QUIC on {local_address}; Deskflow unchanged",
        PROTOCOL_VERSION.major, PROTOCOL_VERSION.minor
    );
    let clock = ProcessClock::new();
    let script_claimed = Arc::new(AtomicBool::new(false));

    #[cfg(unix)]
    let acceptance_recorder = match (
        config.acceptance.as_ref(),
        config.device_id,
        config.sidecar_target_device,
    ) {
        (Some(acceptance), Some(local_device), Some(target_device)) => Some(
            AcceptanceRecorder::new(acceptance.state_dir.clone(), local_device, target_device)?,
        ),
        (None, _, _) => None,
        _ => unreachable!("acceptance CLI validation requires sidecar identities"),
    };

    #[cfg(unix)]
    let mut acceptance_task = config.acceptance.clone().map(|acceptance| {
        let recorder = acceptance_recorder
            .clone()
            .expect("configured acceptance has a recorder");
        tokio::task::spawn_blocking(move || run_acceptance_control(&acceptance, &recorder))
    });

    #[cfg(unix)]
    let (producer_registry, mut producer_task) = match (
        config.sidecar_socket.clone(),
        config.device_id,
        config.sidecar_target_device,
    ) {
        (Some(socket_path), Some(local_device), Some(target_device)) => {
            let (registry, peers) =
                ProducerPeerRegistry::new_with_acceptance(acceptance_recorder.clone());
            let task = tokio::spawn(run_sidecar_producer(
                SidecarProducerConfig {
                    socket_path,
                    local_device,
                    target_device,
                    clock: clock.clone(),
                    quiesce_proof: config.quiesce_proof.clone(),
                    quiesce_arm_file: config.quiesce_arm_file.clone(),
                    artifact_hashes: quiescence_artifact_hashes(&config)?,
                    acceptance: acceptance_recorder.clone(),
                },
                peers,
            ));
            (Some(registry), Some(task))
        }
        (None, _, _) => (None, None),
        _ => unreachable!("sidecar CLI validation requires all producer options"),
    };

    loop {
        #[cfg(unix)]
        let incoming = tokio::select! {
            incoming = endpoint.accept() => incoming,
            result = wait_for_sidecar_task(&mut producer_task) => return result,
            result = wait_for_acceptance_task(&mut acceptance_task) => return result,
        };
        #[cfg(not(unix))]
        let incoming = endpoint.accept().await;
        let Some(incoming) = incoming else {
            return Ok(());
        };
        let clock = clock.clone();
        let peer_config = IncomingPeerConfig {
            probe_interval: config.probe_interval,
            probe_timeout: config.probe_timeout,
            input_backend: config.input_backend,
            device_id: config.device_id,
            input_script: input_script.clone(),
            input_script_peer: config.input_script_peer,
            script_claimed: script_claimed.clone(),
            #[cfg(unix)]
            producer_registry: producer_registry.clone(),
            #[cfg(unix)]
            producer_peer: config.sidecar_peer,
        };
        tokio::spawn(async move {
            if let Err(error) = handle_incoming(incoming, clock, peer_config).await {
                eprintln!("viewflowd server peer ended: {error:#}");
            }
        });
    }
}

#[cfg(unix)]
async fn wait_for_acceptance_task(task: &mut Option<JoinHandle<Result<()>>>) -> Result<()> {
    match task {
        Some(task) => task
            .await
            .context("post-release acceptance control task failed")?,
        None => std::future::pending().await,
    }
}

#[cfg(unix)]
async fn wait_for_sidecar_task(task: &mut Option<JoinHandle<Result<()>>>) -> Result<()> {
    match task {
        Some(task) => task.await.context("input sidecar task failed")?,
        None => std::future::pending().await,
    }
}

async fn handle_incoming(
    incoming: Incoming,
    clock: ProcessClock,
    config: IncomingPeerConfig,
) -> Result<()> {
    let attempted_peer = incoming.remote_address();
    let connection = incoming
        .await
        .with_context(|| format!("mTLS handshake failed for {attempted_peer}"))?;
    println!(
        "viewflowd server authenticated peer {}",
        connection.remote_address()
    );
    let input_script = if config
        .input_script_peer
        .is_some_and(|expected| expected != connection.remote_address().ip())
    {
        None
    } else {
        config.input_script
    };
    #[cfg(unix)]
    let producer_registry = if config
        .producer_peer
        .is_some_and(|expected| expected == connection.remote_address().ip())
    {
        config.producer_registry
    } else {
        None
    };
    handle_server_connection(
        &connection,
        &clock,
        config.probe_interval,
        config.probe_timeout,
        config.input_backend,
        config.device_id,
        input_script,
        &config.script_claimed,
        #[cfg(unix)]
        producer_registry,
    )
    .await
}

struct OutboundControl {
    payload: wire::control_envelope::Payload,
    sent: Option<oneshot::Sender<std::result::Result<(), OutboundSendError>>>,
    input_gate: Option<InputSendGate>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct OutboundSendError(String);

impl fmt::Display for OutboundSendError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "delivery unknown: {}", self.0)
    }
}

#[derive(Debug)]
struct InputSendCancellation {
    cancelled: AtomicBool,
    notify: Notify,
}

#[derive(Clone, Debug)]
struct InputSendGate {
    deadline: tokio::time::Instant,
    cancellation: Arc<InputSendCancellation>,
}

impl InputSendGate {
    fn new(deadline: tokio::time::Instant) -> Self {
        Self {
            deadline,
            cancellation: Arc::new(InputSendCancellation {
                cancelled: AtomicBool::new(false),
                notify: Notify::new(),
            }),
        }
    }

    fn cancel(&self) {
        self.cancellation.cancelled.store(true, Ordering::Release);
        self.cancellation.notify.notify_waiters();
    }

    fn is_cancelled(&self) -> bool {
        self.cancellation.cancelled.load(Ordering::Acquire)
    }

    async fn cancelled(&self) {
        loop {
            let notified = self.cancellation.notify.notified();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

struct InputSendCancelGuard {
    gate: InputSendGate,
    armed: bool,
}

impl InputSendCancelGuard {
    fn new(gate: InputSendGate) -> Self {
        Self { gate, armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for InputSendCancelGuard {
    fn drop(&mut self) {
        if self.armed {
            self.gate.cancel();
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct InputAckKey {
    lease_generation: u64,
    target_device: Id128,
    event_sequence: u64,
}

impl From<&InputEvent> for InputAckKey {
    fn from(event: &InputEvent) -> Self {
        Self {
            lease_generation: event.lease_generation,
            target_device: event.target_device,
            event_sequence: event.sequence,
        }
    }
}

impl From<&InputAppliedAck> for InputAckKey {
    fn from(ack: &InputAppliedAck) -> Self {
        Self {
            lease_generation: ack.lease_generation,
            target_device: ack.target_device,
            event_sequence: ack.event_sequence,
        }
    }
}

type InputAckSender = oneshot::Sender<std::result::Result<InputAppliedResult, String>>;

struct PendingInputAckEntry {
    sender: InputAckSender,
    deadline: tokio::time::Instant,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum InputAckTerminal {
    RemoteAck(InputAppliedResult),
    DeadlineExpired,
    DeliveryUnknown,
    Disconnected,
}

#[derive(Clone, Debug)]
struct InputAckTombstone {
    terminal: InputAckTerminal,
    expires_at: Instant,
}

#[derive(Default)]
struct InputAckState {
    pending: BTreeMap<InputAckKey, PendingInputAckEntry>,
    tombstones: BTreeMap<InputAckKey, InputAckTombstone>,
    disconnected: Option<String>,
    metrics: InputAckMetrics,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize)]
#[allow(clippy::struct_field_names)]
pub(crate) struct InputAckMetrics {
    pub(crate) acked_unique_sequence_count: u64,
    pub(crate) duplicate_ack_count: u64,
    pub(crate) replay_rejection_count: u64,
    pub(crate) late_ack_rejection_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum InputAckResolution {
    Delivered,
    Late(InputAckTerminal),
    Unmatched,
}

#[derive(Clone, Default)]
struct InputAckRegistry {
    state: Arc<Mutex<InputAckState>>,
}

impl InputAckRegistry {
    fn register(
        &self,
        key: InputAckKey,
        deadline: tokio::time::Instant,
    ) -> Result<PendingInputAck, InputDeliveryError> {
        let (sender, receiver) = oneshot::channel();
        let mut state = self.lock();
        Self::prune_tombstones(&mut state, Instant::now());
        if tokio::time::Instant::now() >= deadline {
            return Err(InputDeliveryError::DefinitelyNotSent(
                "input deadline expired before acknowledgment registration".into(),
            ));
        }
        if let Some(reason) = &state.disconnected {
            return Err(InputDeliveryError::DefinitelyNotSent(reason.clone()));
        }
        if state.pending.contains_key(&key) || state.tombstones.contains_key(&key) {
            return Err(InputDeliveryError::DuplicateIdentity);
        }
        state
            .pending
            .insert(key, PendingInputAckEntry { sender, deadline });
        drop(state);
        Ok(PendingInputAck {
            key,
            registry: self.clone(),
            receiver,
            may_have_been_sent: false,
        })
    }

    fn resolve(&self, ack: InputAppliedAck) -> InputAckResolution {
        self.resolve_at(ack, tokio::time::Instant::now())
    }

    fn resolve_at(
        &self,
        ack: InputAppliedAck,
        received_at: tokio::time::Instant,
    ) -> InputAckResolution {
        let key = InputAckKey::from(&ack);
        let mut state = self.lock();
        let now = Instant::now();
        Self::prune_tombstones(&mut state, now);
        if let Some(entry) = state.pending.remove(&key) {
            if received_at >= entry.deadline {
                state.metrics.late_ack_rejection_count =
                    state.metrics.late_ack_rejection_count.saturating_add(1);
                Self::insert_tombstone(&mut state, key, InputAckTerminal::DeadlineExpired, now);
                drop(state);
                let _ = entry.sender.send(Err(
                    "input acknowledgment arrived after its absolute deadline".into(),
                ));
                return InputAckResolution::Late(InputAckTerminal::DeadlineExpired);
            }
            Self::insert_tombstone(
                &mut state,
                key,
                InputAckTerminal::RemoteAck(ack.result),
                now,
            );
            state.metrics.acked_unique_sequence_count =
                state.metrics.acked_unique_sequence_count.saturating_add(1);
            drop(state);
            if entry.sender.send(Ok(ack.result)).is_ok() {
                InputAckResolution::Delivered
            } else {
                InputAckResolution::Late(InputAckTerminal::RemoteAck(ack.result))
            }
        } else if let Some(tombstone) = state.tombstones.get(&key) {
            let terminal = tombstone.terminal.clone();
            match terminal {
                InputAckTerminal::RemoteAck(_) => {
                    state.metrics.duplicate_ack_count =
                        state.metrics.duplicate_ack_count.saturating_add(1);
                }
                _ => {
                    state.metrics.late_ack_rejection_count =
                        state.metrics.late_ack_rejection_count.saturating_add(1);
                }
            }
            InputAckResolution::Late(terminal)
        } else {
            state.metrics.replay_rejection_count =
                state.metrics.replay_rejection_count.saturating_add(1);
            InputAckResolution::Unmatched
        }
    }

    fn metrics(&self) -> InputAckMetrics {
        self.lock().metrics
    }

    fn disconnect(&self, reason: impl Into<String>) {
        let reason = reason.into();
        let mut state = self.lock();
        if state.disconnected.is_some() {
            return;
        }
        state.disconnected = Some(reason.clone());
        let pending = std::mem::take(&mut state.pending);
        let now = Instant::now();
        for key in pending.keys().copied() {
            Self::insert_tombstone(&mut state, key, InputAckTerminal::Disconnected, now);
        }
        drop(state);
        for entry in pending.into_values() {
            let _ = entry.sender.send(Err(reason.clone()));
        }
    }

    fn remove_pending(&self, key: InputAckKey) {
        self.lock().pending.remove(&key);
    }

    fn transition_pending(&self, key: InputAckKey, terminal: InputAckTerminal) -> bool {
        let mut state = self.lock();
        let now = Instant::now();
        Self::prune_tombstones(&mut state, now);
        let transitioned = state.pending.remove(&key).is_some();
        if transitioned {
            Self::insert_tombstone(&mut state, key, terminal, now);
        }
        transitioned
    }

    fn insert_tombstone(
        state: &mut InputAckState,
        key: InputAckKey,
        terminal: InputAckTerminal,
        now: Instant,
    ) {
        if state.tombstones.len() >= MAX_INPUT_ACK_TOMBSTONES
            && !state.tombstones.contains_key(&key)
            && let Some(oldest) = state
                .tombstones
                .iter()
                .min_by_key(|(_, tombstone)| tombstone.expires_at)
                .map(|(key, _)| *key)
        {
            state.tombstones.remove(&oldest);
        }
        state.tombstones.insert(
            key,
            InputAckTombstone {
                terminal,
                expires_at: now + INPUT_ACK_TOMBSTONE_TTL,
            },
        );
    }

    fn prune_tombstones(state: &mut InputAckState, now: Instant) {
        state
            .tombstones
            .retain(|_, tombstone| tombstone.expires_at > now);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, InputAckState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

struct PendingInputAck {
    key: InputAckKey,
    registry: InputAckRegistry,
    receiver: oneshot::Receiver<std::result::Result<InputAppliedResult, String>>,
    may_have_been_sent: bool,
}

impl PendingInputAck {
    async fn wait_until(
        &mut self,
        deadline: tokio::time::Instant,
    ) -> std::result::Result<InputAppliedResult, InputDeliveryError> {
        tokio::select! {
            biased;
            () = sleep_until(deadline) => self.deadline_expired_or_receive().await,
            result = &mut self.receiver => Self::map_result(result),
        }
    }

    async fn deadline_expired_or_receive(
        &mut self,
    ) -> std::result::Result<InputAppliedResult, InputDeliveryError> {
        if self
            .registry
            .transition_pending(self.key, InputAckTerminal::DeadlineExpired)
        {
            Err(InputDeliveryError::DeliveryUnknown(
                "total delivery deadline expired without an applied acknowledgment".into(),
            ))
        } else {
            Self::map_result((&mut self.receiver).await)
        }
    }

    async fn mark_uncertain_or_receive(
        &mut self,
        reason: String,
    ) -> std::result::Result<InputAppliedResult, InputDeliveryError> {
        if self
            .registry
            .transition_pending(self.key, InputAckTerminal::DeliveryUnknown)
        {
            Err(InputDeliveryError::DeliveryUnknown(reason))
        } else {
            Self::map_result((&mut self.receiver).await)
        }
    }

    fn map_result(
        result: std::result::Result<
            std::result::Result<InputAppliedResult, String>,
            oneshot::error::RecvError,
        >,
    ) -> std::result::Result<InputAppliedResult, InputDeliveryError> {
        result
            .map_err(|_| {
                InputDeliveryError::DeliveryUnknown(
                    "input acknowledgment dispatcher stopped after queueing".into(),
                )
            })?
            .map_err(InputDeliveryError::DeliveryUnknown)
    }
}

impl Drop for PendingInputAck {
    fn drop(&mut self) {
        if self.may_have_been_sent {
            self.registry
                .transition_pending(self.key, InputAckTerminal::DeliveryUnknown);
        } else {
            self.registry.remove_pending(self.key);
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct LeaseRevokeAckKey {
    operation_id: Id128,
    lease_generation: u64,
    owner_device: Id128,
    target_device: Id128,
    state: InputLeaseState,
}

impl From<&InputLeaseRevoke> for LeaseRevokeAckKey {
    fn from(revoke: &InputLeaseRevoke) -> Self {
        Self {
            operation_id: revoke.operation_id,
            lease_generation: revoke.lease_generation,
            owner_device: revoke.owner_device,
            target_device: revoke.target_device,
            state: revoke.state,
        }
    }
}

impl From<&InputLeaseRevokedAck> for LeaseRevokeAckKey {
    fn from(ack: &InputLeaseRevokedAck) -> Self {
        Self {
            operation_id: ack.operation_id,
            lease_generation: ack.lease_generation,
            owner_device: ack.owner_device,
            target_device: ack.target_device,
            state: ack.state,
        }
    }
}

type LeaseRevokeAckSender = oneshot::Sender<std::result::Result<InputLeaseRevokedAck, String>>;

struct PendingLeaseRevokeAckEntry {
    sender: LeaseRevokeAckSender,
    deadline: tokio::time::Instant,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum LeaseRevokeAckTerminal {
    RemoteAck(InputLeaseRevokedResult),
    DeadlineExpired,
    DeliveryUnknown,
    Disconnected,
}

#[derive(Clone, Debug)]
struct LeaseRevokeAckTombstone {
    terminal: LeaseRevokeAckTerminal,
    expires_at: Instant,
}

#[derive(Default)]
struct LeaseRevokeAckState {
    pending: BTreeMap<LeaseRevokeAckKey, PendingLeaseRevokeAckEntry>,
    tombstones: BTreeMap<LeaseRevokeAckKey, LeaseRevokeAckTombstone>,
    disconnected: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum LeaseRevokeAckResolution {
    Delivered,
    Late(LeaseRevokeAckTerminal),
    IdentityMismatch,
    Unmatched,
}

#[derive(Clone, Default)]
struct LeaseRevokeAckRegistry {
    state: Arc<Mutex<LeaseRevokeAckState>>,
}

impl LeaseRevokeAckRegistry {
    fn register(
        &self,
        key: LeaseRevokeAckKey,
        deadline: tokio::time::Instant,
    ) -> Result<PendingLeaseRevokeAck, LeaseRevokeDeliveryError> {
        let (sender, receiver) = oneshot::channel();
        let mut state = self.lock();
        Self::prune_tombstones(&mut state, Instant::now());
        if tokio::time::Instant::now() >= deadline {
            return Err(LeaseRevokeDeliveryError::DefinitelyNotSent(
                "lease revoke deadline expired before acknowledgment registration".into(),
            ));
        }
        if let Some(reason) = &state.disconnected {
            return Err(LeaseRevokeDeliveryError::DefinitelyNotSent(reason.clone()));
        }
        if state.pending.contains_key(&key) || state.tombstones.contains_key(&key) {
            return Err(LeaseRevokeDeliveryError::DuplicateIdentity);
        }
        state
            .pending
            .insert(key, PendingLeaseRevokeAckEntry { sender, deadline });
        drop(state);
        Ok(PendingLeaseRevokeAck {
            key,
            registry: self.clone(),
            receiver,
            may_have_been_sent: false,
        })
    }

    fn resolve(&self, ack: InputLeaseRevokedAck) -> LeaseRevokeAckResolution {
        self.resolve_at(ack, tokio::time::Instant::now())
    }

    fn resolve_at(
        &self,
        ack: InputLeaseRevokedAck,
        received_at: tokio::time::Instant,
    ) -> LeaseRevokeAckResolution {
        let key = LeaseRevokeAckKey::from(&ack);
        let mut state = self.lock();
        let now = Instant::now();
        Self::prune_tombstones(&mut state, now);
        if let Some(entry) = state.pending.remove(&key) {
            if received_at >= entry.deadline {
                Self::insert_tombstone(
                    &mut state,
                    key,
                    LeaseRevokeAckTerminal::DeadlineExpired,
                    now,
                );
                drop(state);
                let _ = entry.sender.send(Err(
                    "lease revoke acknowledgment arrived after its absolute deadline".into(),
                ));
                return LeaseRevokeAckResolution::Late(LeaseRevokeAckTerminal::DeadlineExpired);
            }
            Self::insert_tombstone(
                &mut state,
                key,
                LeaseRevokeAckTerminal::RemoteAck(ack.result),
                now,
            );
            drop(state);
            if entry.sender.send(Ok(ack)).is_ok() {
                LeaseRevokeAckResolution::Delivered
            } else {
                LeaseRevokeAckResolution::Late(LeaseRevokeAckTerminal::RemoteAck(ack.result))
            }
        } else if let Some(tombstone) = state.tombstones.get(&key) {
            LeaseRevokeAckResolution::Late(tombstone.terminal.clone())
        } else if !state.pending.is_empty() {
            LeaseRevokeAckResolution::IdentityMismatch
        } else {
            LeaseRevokeAckResolution::Unmatched
        }
    }

    fn disconnect(&self, reason: impl Into<String>) {
        let reason = reason.into();
        let mut state = self.lock();
        if state.disconnected.is_some() {
            return;
        }
        state.disconnected = Some(reason.clone());
        let pending = std::mem::take(&mut state.pending);
        let now = Instant::now();
        for key in pending.keys().copied() {
            Self::insert_tombstone(&mut state, key, LeaseRevokeAckTerminal::Disconnected, now);
        }
        drop(state);
        for entry in pending.into_values() {
            let _ = entry.sender.send(Err(reason.clone()));
        }
    }

    fn remove_pending(&self, key: LeaseRevokeAckKey) {
        self.lock().pending.remove(&key);
    }

    fn transition_pending(&self, key: LeaseRevokeAckKey, terminal: LeaseRevokeAckTerminal) -> bool {
        let mut state = self.lock();
        let now = Instant::now();
        Self::prune_tombstones(&mut state, now);
        let transitioned = state.pending.remove(&key).is_some();
        if transitioned {
            Self::insert_tombstone(&mut state, key, terminal, now);
        }
        transitioned
    }

    fn insert_tombstone(
        state: &mut LeaseRevokeAckState,
        key: LeaseRevokeAckKey,
        terminal: LeaseRevokeAckTerminal,
        now: Instant,
    ) {
        if state.tombstones.len() >= MAX_INPUT_ACK_TOMBSTONES
            && !state.tombstones.contains_key(&key)
            && let Some(oldest) = state
                .tombstones
                .iter()
                .min_by_key(|(_, tombstone)| tombstone.expires_at)
                .map(|(key, _)| *key)
        {
            state.tombstones.remove(&oldest);
        }
        state.tombstones.insert(
            key,
            LeaseRevokeAckTombstone {
                terminal,
                expires_at: now + INPUT_ACK_TOMBSTONE_TTL,
            },
        );
    }

    fn prune_tombstones(state: &mut LeaseRevokeAckState, now: Instant) {
        state
            .tombstones
            .retain(|_, tombstone| tombstone.expires_at > now);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, LeaseRevokeAckState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

struct PendingLeaseRevokeAck {
    key: LeaseRevokeAckKey,
    registry: LeaseRevokeAckRegistry,
    receiver: oneshot::Receiver<std::result::Result<InputLeaseRevokedAck, String>>,
    may_have_been_sent: bool,
}

impl PendingLeaseRevokeAck {
    async fn wait_until(
        &mut self,
        deadline: tokio::time::Instant,
    ) -> std::result::Result<InputLeaseRevokedAck, LeaseRevokeDeliveryError> {
        tokio::select! {
            biased;
            () = sleep_until(deadline) => self.deadline_expired_or_receive().await,
            result = &mut self.receiver => Self::map_result(result),
        }
    }

    async fn deadline_expired_or_receive(
        &mut self,
    ) -> std::result::Result<InputLeaseRevokedAck, LeaseRevokeDeliveryError> {
        if self
            .registry
            .transition_pending(self.key, LeaseRevokeAckTerminal::DeadlineExpired)
        {
            Err(LeaseRevokeDeliveryError::DeliveryUnknown(
                "total lease revoke deadline expired without an applied acknowledgment".into(),
            ))
        } else {
            Self::map_result((&mut self.receiver).await)
        }
    }

    async fn mark_uncertain_or_receive(
        &mut self,
        reason: String,
    ) -> std::result::Result<InputLeaseRevokedAck, LeaseRevokeDeliveryError> {
        if self
            .registry
            .transition_pending(self.key, LeaseRevokeAckTerminal::DeliveryUnknown)
        {
            Err(LeaseRevokeDeliveryError::DeliveryUnknown(reason))
        } else {
            Self::map_result((&mut self.receiver).await)
        }
    }

    fn map_result(
        result: std::result::Result<
            std::result::Result<InputLeaseRevokedAck, String>,
            oneshot::error::RecvError,
        >,
    ) -> std::result::Result<InputLeaseRevokedAck, LeaseRevokeDeliveryError> {
        result
            .map_err(|_| {
                LeaseRevokeDeliveryError::DeliveryUnknown(
                    "lease revoke acknowledgment dispatcher stopped after queueing".into(),
                )
            })?
            .map_err(LeaseRevokeDeliveryError::DeliveryUnknown)
    }
}

impl Drop for PendingLeaseRevokeAck {
    fn drop(&mut self) {
        if self.may_have_been_sent {
            self.registry
                .transition_pending(self.key, LeaseRevokeAckTerminal::DeliveryUnknown);
        } else {
            self.registry.remove_pending(self.key);
        }
    }
}

#[derive(Clone)]
struct OutboundSender {
    controls: mpsc::Sender<OutboundControl>,
    input_acks: InputAckRegistry,
    lease_revoke_acks: LeaseRevokeAckRegistry,
    connection: Option<Connection>,
    #[cfg(test)]
    auto_ack_input: bool,
    #[cfg(test)]
    auto_ack_lease_revoke: bool,
}

impl OutboundSender {
    #[cfg(test)]
    fn new(controls: mpsc::Sender<OutboundControl>) -> Self {
        Self {
            controls,
            input_acks: InputAckRegistry::default(),
            lease_revoke_acks: LeaseRevokeAckRegistry::default(),
            connection: None,
            #[cfg(test)]
            auto_ack_input: false,
            #[cfg(test)]
            auto_ack_lease_revoke: false,
        }
    }

    fn new_connected(controls: mpsc::Sender<OutboundControl>, connection: Connection) -> Self {
        Self {
            controls,
            input_acks: InputAckRegistry::default(),
            lease_revoke_acks: LeaseRevokeAckRegistry::default(),
            connection: Some(connection),
            #[cfg(test)]
            auto_ack_input: false,
            #[cfg(test)]
            auto_ack_lease_revoke: false,
        }
    }

    pub(crate) fn abort_peer(&self, reason: &str) {
        self.input_acks.disconnect(reason);
        self.lease_revoke_acks.disconnect(reason);
        if let Some(connection) = &self.connection {
            connection.close(0_u32.into(), reason.as_bytes());
        }
    }

    pub(crate) fn input_ack_metrics(&self) -> InputAckMetrics {
        self.input_acks.metrics()
    }
}

#[cfg(test)]
impl From<mpsc::Sender<OutboundControl>> for OutboundSender {
    fn from(controls: mpsc::Sender<OutboundControl>) -> Self {
        Self {
            controls,
            input_acks: InputAckRegistry::default(),
            lease_revoke_acks: LeaseRevokeAckRegistry::default(),
            connection: None,
            auto_ack_input: true,
            auto_ack_lease_revoke: true,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum InputDeliveryError {
    DefinitelyNotSent(String),
    DeliveryUnknown(String),
    Rejected(InputAppliedResult),
    DuplicateIdentity,
}

impl InputDeliveryError {
    #[cfg(any(unix, test))]
    pub(crate) const fn is_safe_to_retry(&self) -> bool {
        matches!(self, Self::DefinitelyNotSent(_))
    }

    #[cfg(unix)]
    pub(crate) const fn is_connection_failure(&self) -> bool {
        self.is_safe_to_retry()
    }
}

impl fmt::Display for InputDeliveryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DefinitelyNotSent(reason) => {
                write!(formatter, "input was definitely not sent: {reason}")
            }
            Self::DeliveryUnknown(reason) => {
                write!(formatter, "input delivery is unknown: {reason}")
            }
            Self::Rejected(result) => write!(formatter, "remote input rejected: {result:?}"),
            Self::DuplicateIdentity => {
                formatter.write_str("this input identity is pending or was recently completed")
            }
        }
    }
}

impl Error for InputDeliveryError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum LeaseRevokeDeliveryError {
    DefinitelyNotSent(String),
    DeliveryUnknown(String),
    DuplicateIdentity,
}

impl fmt::Display for LeaseRevokeDeliveryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DefinitelyNotSent(reason) => {
                write!(formatter, "lease revoke was definitely not sent: {reason}")
            }
            Self::DeliveryUnknown(reason) => {
                write!(formatter, "lease revoke delivery is unknown: {reason}")
            }
            Self::DuplicateIdentity => formatter
                .write_str("this lease revoke identity is pending or was recently completed"),
        }
    }
}

impl Error for LeaseRevokeDeliveryError {}

#[derive(Clone)]
struct IncomingPeerConfig {
    probe_interval: Duration,
    probe_timeout: Duration,
    input_backend: InputBackendMode,
    device_id: Option<Id128>,
    input_script: Option<Arc<InputScript>>,
    input_script_peer: Option<IpAddr>,
    script_claimed: Arc<AtomicBool>,
    #[cfg(unix)]
    producer_registry: Option<ProducerPeerRegistry>,
    #[cfg(unix)]
    producer_peer: Option<IpAddr>,
}

#[allow(clippy::too_many_arguments)]
async fn handle_server_connection(
    connection: &Connection,
    clock: &ProcessClock,
    probe_interval: Duration,
    probe_timeout: Duration,
    input_backend: InputBackendMode,
    device_id: Option<Id128>,
    input_script: Option<Arc<InputScript>>,
    script_claimed: &AtomicBool,
    #[cfg(unix)] producer_registry: Option<ProducerPeerRegistry>,
) -> Result<()> {
    let (outbound_controls, outbound_rx) = mpsc::channel(256);
    let outbound = OutboundSender::new_connected(outbound_controls, connection.clone());
    let (clock_replies, clock_reply_rx) = mpsc::channel(4);
    let (clock_snapshots, clock_snapshot_rx) = watch::channel(None);
    let mut writer = spawn_control_writer(connection.clone(), outbound_rx);
    #[cfg(unix)]
    let _producer_registration = producer_registry
        .map(|registry| registry.register(connection.remote_address(), outbound.clone()));
    let mut input = InputReceiver::new(input_backend, device_id)?;
    let mut probe = tokio::spawn(run_probe_loop(
        "server",
        connection.clone(),
        probe_interval,
        probe_timeout,
        clock.clone(),
        outbound.clone(),
        clock_reply_rx,
        clock_snapshots,
    ));
    if let Some(script) = input_script
        && claim_input_script_for_daemon_lifetime(script_claimed)
    {
        queue_input_script(&outbound, &script, connection.remote_address(), clock).await?;
    }

    let result = {
        let receiver = handle_server_receiver(
            connection,
            clock,
            &mut input,
            outbound.clone(),
            clock_replies,
            clock_snapshot_rx,
            #[cfg(target_os = "linux")]
            None,
            None,
        );
        tokio::pin!(receiver);
        tokio::select! {
            result = &mut receiver => result,
            result = &mut writer => flatten_writer_result(result),
            result = &mut probe => result.context("clock probe task failed")?,
        }
    };
    outbound
        .input_acks
        .disconnect(format!("peer {} disconnected", connection.remote_address()));
    outbound.abort_peer("viewflow server peer handler ended");
    writer.abort();
    probe.abort();
    finish_with_input_release("server", connection.remote_address(), result, &mut input)
}

#[allow(clippy::too_many_lines, clippy::too_many_arguments)]
async fn handle_server_receiver(
    connection: &Connection,
    clock: &ProcessClock,
    input: &mut InputReceiver,
    outbound: OutboundSender,
    clock_replies: mpsc::Sender<ClockReplyDispatch>,
    clock_snapshot: watch::Receiver<Option<ClockSnapshot>>,
    #[cfg(target_os = "linux")] mut window_input: Option<
        window_input_runtime::RoutedWindowInput<'_>,
    >,
    mut window_preview: Option<window_preview_input::WindowPreviewInput>,
) -> Result<()> {
    let mut incoming_sequence = ControlSequencer::default();
    let mut inbound_file_transfer = None;
    loop {
        let incoming = receive_shared_peer_payload(
            connection,
            &mut incoming_sequence,
            &outbound,
            #[cfg(target_os = "linux")]
            &mut window_input,
            &mut window_preview,
            &clock_snapshot,
        )
        .await?;
        let t1_receive_ns = clock.now_ns();
        match incoming {
            #[cfg(target_os = "linux")]
            PeerPayload::Control(DomainControl::WindowInputRelease(window)) if window_input.is_some() => {
                window_input.as_mut().expect("source route checked").release_window_input(connection, window).await?;
            }
            #[cfg(target_os = "linux")]
            PeerPayload::Control(DomainControl::DesktopWindowMove(movement))
                if window_input.is_some() =>
            {
                let ack = window_input
                    .as_mut()
                    .expect("source route checked")
                    .desktop_move(connection, movement)
                    .await?;
                queue_control(
                    &outbound,
                    wire::control_envelope::Payload::DesktopWindowMoveAck(ack.into()),
                )
                .await?;
            }
            #[cfg(target_os = "linux")]
            PeerPayload::Control(DomainControl::AtlasWindowSelection(selection))
                if window_input.is_some() =>
            {
                window_input
                    .as_mut()
                    .expect("source route checked")
                    .select_atlas(selection)?;
            }
            PeerPayload::Control(DomainControl::ClockSyncReply(reply)) => {
                dispatch_clock_reply(&clock_replies, reply).await?;
            }
            PeerPayload::Control(DomainControl::ClockSyncProbe(probe)) => {
                let t2_send_ns = clock.now_ns();
                queue_control(
                    &outbound,
                    wire::control_envelope::Payload::ClockSyncReply(wire::ClockSyncReply {
                        probe_id: probe.probe_id,
                        t0_send_ns: probe.t0_send_ns,
                        t1_receive_ns,
                        t2_send_ns,
                    }),
                )
                .await
                .context("control writer stopped before clock reply")?;
                println!(
                    "viewflowd server peer {} probe={} responder_us={}",
                    connection.remote_address(),
                    probe.probe_id,
                    t2_send_ns.saturating_sub(t1_receive_ns) / 1_000
                );
            }
            PeerPayload::Control(DomainControl::InputLease(lease)) => {
                input.apply_lease(lease)?;
                println!(
                    "viewflowd server peer {} input_lease_generation={} state={:?}",
                    connection.remote_address(),
                    lease.generation,
                    lease.state
                );
            }
            PeerPayload::Control(DomainControl::InputLeaseRevoke(revoke)) => {
                acknowledge_lease_revoke(
                    &outbound,
                    connection.remote_address(),
                    "server",
                    input,
                    revoke,
                )
                .await?;
            }
            PeerPayload::Control(DomainControl::InputEvent(event)) => {
                let snapshot = *clock_snapshot.borrow();
                let local_now_ns = clock.now_ns();
                acknowledge_input_result(
                    &outbound,
                    connection.remote_address(),
                    "server",
                    input,
                    event,
                    snapshot,
                    local_now_ns,
                )
                .await?;
            }
            PeerPayload::Control(DomainControl::InputAppliedAck(ack)) => {
                log_input_ack_resolution(
                    "server",
                    connection.remote_address(),
                    ack,
                    outbound.input_acks.resolve(ack),
                );
            }
            PeerPayload::Control(DomainControl::InputLeaseRevokedAck(ack)) => {
                handle_lease_revoke_ack(&outbound, connection.remote_address(), "server", ack)?;
            }
            PeerPayload::Control(DomainControl::FileDragOffer(offer)) => {
                accept_inbound_file_drag(&outbound, &mut inbound_file_transfer, offer).await?;
            }
            PeerPayload::Control(DomainControl::FileDragComplete(completion))
                if matches!(
                    completion.status,
                    viewflow_protocol::DragCompletionStatus::Cancelled
                        | viewflow_protocol::DragCompletionStatus::Failed
                ) =>
            {
                cancel_inbound_file_drag(&mut inbound_file_transfer, &completion)?;
            }
            PeerPayload::Control(
                DomainControl::WindowPointerMotion(_)
                | DomainControl::WindowPointerButton(_)
                | DomainControl::WindowPointerWheel(_)
                | DomainControl::WindowKeyboardEvent(_)
                | DomainControl::WindowKeyboardAck(_)
                | DomainControl::WindowKeyboardAuthorization(_)
                | DomainControl::AtlasWindowSelection(_),
            ) => {
                bail!("window-scoped input runtime is not enabled on this connection");
            }
            PeerPayload::Control(other) => {
                eprintln!(
                    "viewflowd server peer {} ignored non-health control {other:?}",
                    connection.remote_address()
                );
            }
            PeerPayload::Blob(chunk) => {
                push_inbound_file_drag(&outbound, &mut inbound_file_transfer, &chunk).await?;
            }
        }
    }
}

enum PeerPayload {
    Control(DomainControl),
    Blob(BlobChunk),
}

async fn receive_peer_payload(
    connection: &Connection,
    sequencer: &mut ControlSequencer,
) -> Result<PeerPayload> {
    match receive_reliable(connection).await? {
        ReliablePayload::BlobChunk(chunk) => Ok(PeerPayload::Blob(chunk)),
        ReliablePayload::Control(bytes) => {
            let envelope =
                wire::ControlEnvelope::decode(bytes).context("decode control envelope")?;
            sequencer
                .accept(envelope.sequence)
                .map_err(|error| anyhow!("control sequence: {error}"))?;
            Ok(PeerPayload::Control(
                DomainControl::try_from(envelope)
                    .map_err(|error| anyhow!("invalid control: {error:?}"))?,
            ))
        }
    }
}

/// The only reliable reader for this connection. Keep a partially read record
/// alive while servicing the native window route; ticks must not restart reads.
#[allow(clippy::too_many_lines)] // Keep the sole reader and pending-read cancellation scope together.
async fn receive_shared_peer_payload(
    connection: &Connection,
    sequencer: &mut ControlSequencer,
    outbound: &OutboundSender,
    #[cfg(target_os = "linux")] window_input: &mut Option<
        window_input_runtime::RoutedWindowInput<'_>,
    >,
    preview: &mut Option<window_preview_input::WindowPreviewInput>,
    clock: &watch::Receiver<Option<ClockSnapshot>>,
) -> Result<PeerPayload> {
    loop {
        #[cfg(target_os = "linux")]
        let source_active = window_input.is_some();
        #[cfg(not(target_os = "linux"))]
        let source_active = false;
        if !source_active && preview.is_none() {
            return receive_peer_payload(connection, sequencer).await;
        }
        maintain_window_routes(
            connection,
            outbound,
            #[cfg(target_os = "linux")]
            window_input,
            preview,
            clock,
        )
        .await?;
        let receive = receive_peer_payload(connection, sequencer);
        tokio::pin!(receive);
        let incoming = loop {
            tokio::select! {
                result = &mut receive => break result?,
                () = sleep(Duration::from_millis(1)) => {
                    maintain_window_routes(connection, outbound,
                        #[cfg(target_os = "linux")] window_input,
                        preview, clock).await?;
                },
            }
        };
        match incoming {
            #[cfg(target_os = "linux")]
            PeerPayload::Control(DomainControl::WindowPointerMotion(motion))
                if window_input.is_some() =>
            {
                let ack = window_input
                    .as_mut()
                    .expect("source route checked")
                    .deliver(connection, motion)
                    .await?;
                timeout(
                    Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
                    shared_control::send_bounded_control(
                        outbound,
                        wire::control_envelope::Payload::WindowPointerAck(ack.into()),
                        tokio::time::Instant::now()
                            + Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
                    ),
                )
                .await
                .context("window acknowledgement writer timed out")??;
            }
            PeerPayload::Control(DomainControl::WindowPointerAuthorization(authorization))
                if preview.is_some() =>
            {
                preview
                    .as_mut()
                    .expect("preview route checked")
                    .authorize(authorization)?;
            }
            PeerPayload::Control(DomainControl::WindowPointerAck(ack)) if preview.is_some() => {
                preview
                    .as_mut()
                    .expect("preview route checked")
                    .acknowledge(ack)?;
            }
            PeerPayload::Control(DomainControl::WindowKeyboardAuthorization(auth))
                if preview.is_some() =>
            {
                preview
                    .as_mut()
                    .expect("preview route checked")
                    .authorize_keyboard(auth)?;
            }
            PeerPayload::Control(DomainControl::WindowKeyboardAck(ack)) if preview.is_some() => {
                preview
                    .as_mut()
                    .expect("preview route checked")
                    .acknowledge_keyboard(ack)?;
            }
            #[cfg(target_os = "linux")]
            PeerPayload::Control(DomainControl::WindowPointerButton(button))
                if window_input.is_some() =>
            {
                let ack = window_input
                    .as_mut()
                    .expect("source route checked")
                    .deliver_button(connection, button)
                    .await?;
                timeout(
                    Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
                    shared_control::send_bounded_control(
                        outbound,
                        wire::control_envelope::Payload::WindowPointerAck(ack.into()),
                        tokio::time::Instant::now()
                            + Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
                    ),
                )
                .await
                .context("window button acknowledgement writer timed out")??;
            }
            PeerPayload::Control(DomainControl::WindowPointerButton(_)) => {
                bail!("window-scoped button runtime is not enabled on this connection");
            }
            #[cfg(target_os = "linux")]
            PeerPayload::Control(DomainControl::WindowPointerWheel(wheel))
                if window_input.is_some() =>
            {
                let ack = window_input
                    .as_mut()
                    .expect("source route checked")
                    .deliver_wheel(connection, wheel)
                    .await?;
                timeout(
                    Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
                    shared_control::send_bounded_control(
                        outbound,
                        wire::control_envelope::Payload::WindowPointerAck(ack.into()),
                        tokio::time::Instant::now()
                            + Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
                    ),
                )
                .await
                .context("window wheel acknowledgement writer timed out")??;
            }
            PeerPayload::Control(DomainControl::WindowPointerWheel(_)) => {
                bail!("window-scoped wheel runtime is not enabled on this connection");
            }
            #[cfg(target_os = "linux")]
            PeerPayload::Control(DomainControl::WindowKeyboardEvent(event))
                if window_input.is_some() =>
            {
                let ack = window_input
                    .as_mut()
                    .expect("source route checked")
                    .deliver_key(connection, event)
                    .await?;
                timeout(
                    Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
                    shared_control::send_bounded_control(
                        outbound,
                        wire::control_envelope::Payload::WindowKeyboardAck(ack.into()),
                        tokio::time::Instant::now()
                            + Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
                    ),
                )
                .await
                .context("window keyboard acknowledgement writer timed out")??;
            }
            PeerPayload::Control(
                DomainControl::WindowKeyboardEvent(_)
                | DomainControl::WindowKeyboardAck(_)
                | DomainControl::WindowKeyboardAuthorization(_),
            ) => {
                bail!("window-scoped keyboard runtime is not enabled on this connection");
            }
            other => return Ok(other),
        }
    }
}

async fn maintain_window_routes(
    connection: &Connection,
    outbound: &OutboundSender,
    #[cfg(target_os = "linux")] source: &mut Option<window_input_runtime::RoutedWindowInput<'_>>,
    preview: &mut Option<window_preview_input::WindowPreviewInput>,
    clock: &watch::Receiver<Option<ClockSnapshot>>,
) -> Result<()> {
    #[cfg(not(target_os = "linux"))]
    let _ = connection;
    #[cfg(target_os = "linux")]
    if let Some(source) = source {
        source.maintain(connection).await?;
        announce_window_authorization(source, outbound).await?;
    }
    if let Some(preview) = preview {
        if clock.has_changed().is_err() {
            bail!("preview clock owner disappeared");
        }
        let snapshot = *clock.borrow();
        preview.pump(snapshot, outbound).await?;
    }
    Ok(())
}

#[cfg(target_os = "linux")]
async fn announce_window_authorization(
    route: &mut window_input_runtime::RoutedWindowInput<'_>,
    outbound: &OutboundSender,
) -> Result<()> {
    if let Some(authorization) = route.keyboard_announcement()? {
        timeout(
            Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
            shared_control::send_bounded_control(
                outbound,
                wire::control_envelope::Payload::WindowKeyboardAuthorization(authorization.into()),
                tokio::time::Instant::now()
                    + Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
            ),
        )
        .await
        .context("keyboard authorization writer timed out")??;
    }
    if let Some(authorization) = route.announcement()? {
        timeout(
            Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
            shared_control::send_bounded_control(
                outbound,
                wire::control_envelope::Payload::WindowPointerAuthorization(authorization.into()),
                tokio::time::Instant::now()
                    + Duration::from_nanos(input_runtime::INPUT_OPERATION_TIMEOUT_NS),
            ),
        )
        .await
        .context("window authorization writer timed out")??;
    }
    Ok(())
}

struct WindowConnectionTasks {
    writer: Option<JoinHandle<Result<()>>>,
    probe: JoinHandle<Result<()>>,
    outbound: OutboundSender,
}

impl Drop for WindowConnectionTasks {
    fn drop(&mut self) {
        self.outbound.abort_peer("window dispatcher ended");
        if let Some(writer) = &self.writer {
            writer.abort();
        }
        self.probe.abort();
    }
}

async fn wait_control_writer(
    writer: &mut Option<JoinHandle<Result<()>>>,
) -> std::result::Result<Result<()>, tokio::task::JoinError> {
    match writer {
        Some(writer) => writer.await,
        None => std::future::pending().await,
    }
}

async fn serve_window_preview_connection(
    connection: &Connection,
    origin: Instant,
    preview: window_preview_input::WindowPreviewInput,
) -> Result<()> {
    let recovery_unconfirmed = preview.recovery_unconfirmed();
    let (controls, receive) = mpsc::channel(256);
    let outbound = OutboundSender::new_connected(controls, connection.clone());
    let (replies, reply_rx) = mpsc::channel(4);
    let (snapshots, snapshot_rx) = watch::channel(None);
    let clock = ProcessClock { origin };
    let mut tasks = WindowConnectionTasks {
        writer: Some(spawn_control_writer(connection.clone(), receive)),
        probe: tokio::spawn(run_probe_loop(
            "window-preview",
            connection.clone(),
            Duration::from_millis(250),
            Duration::from_millis(250),
            clock.clone(),
            outbound.clone(),
            reply_rx,
            snapshots,
        )),
        outbound: outbound.clone(),
    };
    let mut input = InputReceiver::new(InputBackendMode::Disabled, None)?;
    let receiver = handle_client_receiver(
        connection,
        &clock,
        &mut input,
        outbound,
        replies,
        snapshot_rx,
        #[cfg(target_os = "linux")]
        None,
        Some(preview),
    );
    tokio::pin!(receiver);
    tokio::select! {
        biased;
        result = &mut tasks.probe => guard_liveness_recovery(result.context("preview clock task failed")?, &recovery_unconfirmed),
        result = &mut receiver => result,
        result = wait_control_writer(&mut tasks.writer) => flatten_writer_result(result),
    }
}

/// Source-authorized entry into the same dispatcher used by the CLI server.
/// Clock probes share the reader/writer with input; general device input stays off.
#[cfg(target_os = "linux")]
async fn serve_authorized_window_connection(
    connection: &Connection,
    origin: Instant,
    session: window_input_runtime::WindowInputSession,
    presentations: watch::Receiver<viewflow_core::PresentedInputGeometry>,
    authorizations: Option<watch::Receiver<window_input_runtime::AuthorizedWindow>>,
    routing: window_input_runtime::WindowInputRouting,
    metadata: impl FnMut(Vec<u8>) -> Result<()> + Send,
) -> Result<()> {
    let recovery_unconfirmed = session.recovery_unconfirmed();
    let (outbound, writer) = if let Some(shared) = routing.shared {
        anyhow::ensure!(
            shared.belongs_to(connection),
            "input shared writer belongs to another connection"
        );
        (shared.outbound(), None)
    } else {
        let (controls, receive) = mpsc::channel(256);
        (
            OutboundSender::new_connected(controls, connection.clone()),
            Some(spawn_control_writer(connection.clone(), receive)),
        )
    };
    let (replies, reply_rx) = mpsc::channel(4);
    let (snapshots, snapshot_rx) = watch::channel(None);
    let clock = ProcessClock { origin };
    let mut route = window_input_runtime::RoutedWindowInput::new(
        session,
        snapshot_rx.clone(),
        presentations,
        authorizations,
        routing.allow_switching,
        metadata,
    );
    route.attach_selections(routing.selections);
    route.attach_desktop_moves(routing.desktop_moves);
    let mut guard = WindowConnectionTasks {
        writer,
        probe: tokio::spawn(run_probe_loop(
            "window-source",
            connection.clone(),
            Duration::from_millis(250),
            Duration::from_millis(250),
            clock.clone(),
            outbound.clone(),
            reply_rx,
            snapshots,
        )),
        outbound: outbound.clone(),
    };
    let mut input = InputReceiver::new(InputBackendMode::Disabled, None)?;
    let receiver = handle_server_receiver(
        connection,
        &clock,
        &mut input,
        outbound,
        replies,
        snapshot_rx,
        Some(route),
        None,
    );
    tokio::pin!(receiver);
    let result = tokio::select! {
        biased;
        result = &mut guard.probe => guard_liveness_recovery(result.context("window clock probe task failed")?, &recovery_unconfirmed),
        result = &mut receiver => result,
        result = wait_control_writer(&mut guard.writer) => flatten_writer_result(result),
    };
    if let Err(error) = &result {
        eprintln!("window-input dispatcher failed: {error:#}");
    }
    result
}

fn wire_id(id: Id128) -> wire::Id128 {
    wire::Id128 {
        high: (id.0 >> 64) as u64,
        low: u64::try_from(id.0 & u128::from(u64::MAX)).unwrap_or_default(),
    }
}

fn file_drag_complete_payload(
    completion: viewflow_protocol::DragComplete,
) -> wire::control_envelope::Payload {
    wire::control_envelope::Payload::FileDragComplete(wire::FileDragComplete {
        offer_id: Some(wire_id(completion.offer_id)),
        status: match completion.status {
            viewflow_protocol::DragCompletionStatus::Completed => 1,
            viewflow_protocol::DragCompletionStatus::Cancelled => 2,
            viewflow_protocol::DragCompletionStatus::Failed => 3,
        },
        error_message: completion.error_message,
        generation: completion.generation,
        item_results: completion
            .item_results
            .into_iter()
            .map(|item| wire::FileDragItemResult {
                item_index: item.item_index,
                bytes_received: item.bytes_received,
                content_sha256: item.content_hash.map(|hash| hash.to_vec()),
            })
            .collect(),
    })
}

async fn accept_inbound_file_drag(
    outbound: &OutboundSender,
    inbound: &mut Option<file_transfer::InboundFileTransfer>,
    offer: viewflow_protocol::DragOffer,
) -> Result<()> {
    if inbound.is_some() {
        bail!("file drag offer rejected: another transfer is still retained");
    }
    let mut accepted =
        file_transfer::InboundFileTransfer::accept(&std::env::temp_dir(), 1, offer.clone())
            .map_err(|error| anyhow!("file drag offer rejected: {error:?}"))?;
    let destination_token = accepted.root.display().to_string();
    let immediate_completion = accepted
        .completion_if_ready()
        .map_err(|error| anyhow!("file drag completion rejected: {error:?}"))?;
    *inbound = Some(accepted);
    queue_control(
        outbound,
        wire::control_envelope::Payload::FileDragAccept(wire::FileDragAccept {
            offer_id: Some(wire_id(offer.id)),
            operation: match offer.operation {
                viewflow_protocol::DragOperation::Copy => 1,
                viewflow_protocol::DragOperation::Move => 2,
            },
            destination_token,
            generation: offer.generation,
        }),
    )
    .await?;
    if let Some(completion) = immediate_completion {
        queue_control(outbound, file_drag_complete_payload(completion)).await?;
    }
    Ok(())
}

fn cancel_inbound_file_drag(
    inbound: &mut Option<file_transfer::InboundFileTransfer>,
    completion: &viewflow_protocol::DragComplete,
) -> Result<()> {
    let matches = inbound
        .as_ref()
        .is_some_and(|transfer| transfer.matches(completion.offer_id, completion.generation));
    if !matches {
        bail!("file drag cancellation refers to no active transfer");
    }
    *inbound = None;
    Ok(())
}

async fn push_inbound_file_drag(
    outbound: &OutboundSender,
    inbound: &mut Option<file_transfer::InboundFileTransfer>,
    chunk: &BlobChunk,
) -> Result<()> {
    let transfer = inbound
        .as_mut()
        .ok_or_else(|| anyhow!("file drag chunk arrived without an active offer"))?;
    if let Some(completion) = transfer
        .push(chunk)
        .map_err(|error| anyhow!("file drag chunk rejected: {error:?}"))?
    {
        queue_control(outbound, file_drag_complete_payload(completion)).await?;
    }
    Ok(())
}

fn spawn_control_writer(
    connection: Connection,
    outbound: mpsc::Receiver<OutboundControl>,
) -> JoinHandle<Result<()>> {
    tokio::spawn(control_writer(connection, outbound))
}

async fn control_writer(
    connection: Connection,
    mut outbound: mpsc::Receiver<OutboundControl>,
) -> Result<()> {
    let mut sequence = 1_u64;
    while let Some(outbound) = outbound.recv().await {
        let message = envelope(sequence, outbound.payload);
        let send_result = send_outbound_control(&connection, &message, outbound.input_gate).await;
        if let Some(sent) = outbound.sent {
            let confirmation = send_result.clone();
            let _ = sent.send(confirmation);
        }
        send_result.map_err(|error| anyhow!(error))?;
        sequence = sequence
            .checked_add(1)
            .ok_or_else(|| anyhow!("outgoing control sequence exhausted"))?;
    }
    Ok(())
}

async fn send_outbound_control(
    connection: &Connection,
    message: &wire::ControlEnvelope,
    input_gate: Option<InputSendGate>,
) -> std::result::Result<(), OutboundSendError> {
    let Some(input_gate) = input_gate else {
        return send_control(connection, message)
            .await
            .map_err(|error| OutboundSendError(error.to_string()));
    };
    match run_input_send_until(&input_gate, send_control(connection, message)).await {
        InputSendOutcome::Cancelled => Err(OutboundSendError(
            "input was cancelled while the QUIC send outcome was unknown".into(),
        )),
        InputSendOutcome::DeadlineExpired => Err(OutboundSendError(
            "input QUIC send exceeded its absolute delivery deadline".into(),
        )),
        InputSendOutcome::Completed(result) => {
            result.map_err(|error| OutboundSendError(error.to_string()))
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InputSendOutcome<T> {
    Completed(T),
    Cancelled,
    DeadlineExpired,
}

async fn run_input_send_until<F, T>(gate: &InputSendGate, send: F) -> InputSendOutcome<T>
where
    F: Future<Output = T>,
{
    if gate.is_cancelled() {
        return InputSendOutcome::Cancelled;
    }
    if tokio::time::Instant::now() >= gate.deadline {
        return InputSendOutcome::DeadlineExpired;
    }
    tokio::pin!(send);
    let deadline_guarded_send = std::future::poll_fn(|context| {
        if tokio::time::Instant::now() >= gate.deadline {
            return std::task::Poll::Ready(InputSendOutcome::DeadlineExpired);
        }
        match send.as_mut().poll(context) {
            std::task::Poll::Ready(result) => {
                if tokio::time::Instant::now() >= gate.deadline {
                    std::task::Poll::Ready(InputSendOutcome::DeadlineExpired)
                } else {
                    std::task::Poll::Ready(InputSendOutcome::Completed(result))
                }
            }
            std::task::Poll::Pending => std::task::Poll::Pending,
        }
    });
    tokio::select! {
        biased;
        () = gate.cancelled() => InputSendOutcome::Cancelled,
        () = sleep_until(gate.deadline) => InputSendOutcome::DeadlineExpired,
        outcome = deadline_guarded_send => outcome,
    }
}

async fn run_until_deadline<F, T>(deadline: tokio::time::Instant, future: F) -> Option<T>
where
    F: Future<Output = T>,
{
    if tokio::time::Instant::now() >= deadline {
        return None;
    }
    tokio::select! {
        biased;
        () = sleep_until(deadline) => None,
        result = future => {
            (tokio::time::Instant::now() < deadline).then_some(result)
        }
    }
}

fn claim_input_script_for_daemon_lifetime(claimed: &AtomicBool) -> bool {
    claimed
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
}

async fn queue_input_script(
    outbound: &OutboundSender,
    script: &InputScript,
    peer: SocketAddr,
    clock: &ProcessClock,
) -> Result<()> {
    let payloads = script.payloads()?;
    let count = payloads.len();
    for payload in payloads {
        match payload {
            wire::control_envelope::Payload::InputEvent(event) => {
                let mut event = InputEvent::try_from(event)
                    .map_err(|error| anyhow!("invalid generated input event: {error:?}"))?;
                let deadline = tokio::time::Instant::now() + INPUT_APPLIED_TIMEOUT;
                let sender_now_ns = clock.now_ns();
                event.sender_not_after_ns =
                    if matches!(event.event, viewflow_protocol::InputEventKind::ReleaseAll) {
                        0
                    } else {
                        sender_now_ns.saturating_add(
                            u64::try_from(INPUT_APPLIED_TIMEOUT.as_nanos()).unwrap_or(u64::MAX),
                        )
                    };
                send_input_confirmed_until(outbound, event, deadline).await?;
            }
            payload => send_control_confirmed(outbound, payload).await?,
        }
    }
    println!(
        "viewflowd server peer {peer} input_script_sent={count} transport_confirmed=true replay=false"
    );
    Ok(())
}

async fn queue_control(
    outbound: &OutboundSender,
    payload: wire::control_envelope::Payload,
) -> Result<()> {
    outbound
        .controls
        .send(OutboundControl {
            payload,
            sent: None,
            input_gate: None,
        })
        .await
        .context("control writer stopped")
}

pub(crate) async fn send_control_confirmed(
    outbound: &OutboundSender,
    payload: wire::control_envelope::Payload,
) -> Result<()> {
    let (sent, confirmation) = oneshot::channel();
    outbound
        .controls
        .send(OutboundControl {
            payload,
            sent: Some(sent),
            input_gate: None,
        })
        .await
        .context("control writer stopped while queueing confirmed control")?;
    confirmation
        .await
        .context("control writer stopped before confirming control send")?
        .map_err(|error| anyhow!(error))
}

#[cfg(any(unix, test))]
pub(crate) async fn send_input_confirmed(
    outbound: &OutboundSender,
    event: InputEvent,
) -> std::result::Result<(), InputDeliveryError> {
    send_input_confirmed_until(
        outbound,
        event,
        tokio::time::Instant::now() + INPUT_APPLIED_TIMEOUT,
    )
    .await
}

#[cfg(test)]
async fn send_input_confirmed_with_timeout(
    outbound: &OutboundSender,
    event: InputEvent,
    operation_timeout: Duration,
) -> std::result::Result<(), InputDeliveryError> {
    let deadline = tokio::time::Instant::now() + operation_timeout;
    send_input_confirmed_until(outbound, event, deadline).await
}

pub(crate) async fn send_input_confirmed_until(
    outbound: &OutboundSender,
    event: InputEvent,
    deadline: tokio::time::Instant,
) -> std::result::Result<(), InputDeliveryError> {
    let send_gate = InputSendGate::new(deadline);
    let mut cancel_guard = InputSendCancelGuard::new(send_gate.clone());
    let mut pending = outbound
        .input_acks
        .register(InputAckKey::from(&event), deadline)?;
    let (sent, confirmation) = oneshot::channel();
    let queue_result = run_until_deadline(
        deadline,
        outbound.controls.send(OutboundControl {
            payload: input_event_payload(event),
            sent: Some(sent),
            input_gate: Some(send_gate.clone()),
        }),
    )
    .await;
    match queue_result {
        Some(Ok(())) => pending.may_have_been_sent = true,
        Some(Err(_)) => {
            return Err(InputDeliveryError::DefinitelyNotSent(
                "control writer stopped before the input entered its queue".into(),
            ));
        }
        None => {
            return Err(InputDeliveryError::DefinitelyNotSent(
                "delivery deadline expired before the input entered the writer queue".into(),
            ));
        }
    }

    let confirmation = run_until_deadline(deadline, confirmation).await;
    match confirmation {
        Some(Ok(Ok(()))) => cancel_guard.disarm(),
        Some(Ok(Err(reason))) => {
            let result = pending
                .mark_uncertain_or_receive(format!(
                    "control writer failed after queueing: {reason}"
                ))
                .await?;
            cancel_guard.disarm();
            return classify_input_result(result);
        }
        Some(Err(_)) => {
            let result = pending
                .mark_uncertain_or_receive(
                    "control writer stopped after the input entered its queue".into(),
                )
                .await?;
            cancel_guard.disarm();
            return classify_input_result(result);
        }
        None => {
            let result = pending.deadline_expired_or_receive().await?;
            cancel_guard.disarm();
            return classify_input_result(result);
        }
    }
    #[cfg(test)]
    if outbound.auto_ack_input {
        return Ok(());
    }
    let result = pending.wait_until(deadline).await?;
    classify_input_result(result)
}

#[cfg(any(unix, test))]
pub(crate) async fn send_lease_revoke_confirmed_until(
    outbound: &OutboundSender,
    revoke: InputLeaseRevoke,
    deadline: tokio::time::Instant,
) -> std::result::Result<InputLeaseRevokedAck, LeaseRevokeDeliveryError> {
    let send_gate = InputSendGate::new(deadline);
    let mut cancel_guard = InputSendCancelGuard::new(send_gate.clone());
    let key = LeaseRevokeAckKey::from(&revoke);
    let mut pending = outbound.lease_revoke_acks.register(key, deadline)?;
    let (sent, confirmation) = oneshot::channel();
    let queue_result = run_until_deadline(
        deadline,
        outbound.controls.send(OutboundControl {
            payload: input_lease_revoke_payload(revoke),
            sent: Some(sent),
            input_gate: Some(send_gate.clone()),
        }),
    )
    .await;
    match queue_result {
        Some(Ok(())) => pending.may_have_been_sent = true,
        Some(Err(_)) => {
            return Err(LeaseRevokeDeliveryError::DefinitelyNotSent(
                "control writer stopped before the lease revoke entered its queue".into(),
            ));
        }
        None => {
            return Err(LeaseRevokeDeliveryError::DefinitelyNotSent(
                "lease revoke deadline expired before entering the writer queue".into(),
            ));
        }
    }

    let confirmation = run_until_deadline(deadline, confirmation).await;
    match confirmation {
        Some(Ok(Ok(()))) => cancel_guard.disarm(),
        Some(Ok(Err(reason))) => {
            let ack = pending
                .mark_uncertain_or_receive(format!(
                    "control writer failed after queueing lease revoke: {reason}"
                ))
                .await?;
            cancel_guard.disarm();
            return Ok(ack);
        }
        Some(Err(_)) => {
            let ack = pending
                .mark_uncertain_or_receive(
                    "control writer stopped after the lease revoke entered its queue".into(),
                )
                .await?;
            cancel_guard.disarm();
            return Ok(ack);
        }
        None => {
            let ack = pending.deadline_expired_or_receive().await?;
            cancel_guard.disarm();
            return Ok(ack);
        }
    }

    #[cfg(test)]
    if outbound.auto_ack_lease_revoke {
        let ack = InputLeaseRevokedAck {
            operation_id: revoke.operation_id,
            lease_generation: revoke.lease_generation,
            owner_device: revoke.owner_device,
            target_device: revoke.target_device,
            state: revoke.state,
            result: InputLeaseRevokedResult::Applied,
        };
        debug_assert_eq!(
            outbound.lease_revoke_acks.resolve(ack),
            LeaseRevokeAckResolution::Delivered
        );
    }
    let ack = pending.wait_until(deadline).await?;
    Ok(ack)
}

fn classify_input_result(
    result: InputAppliedResult,
) -> std::result::Result<(), InputDeliveryError> {
    match result {
        InputAppliedResult::Applied => Ok(()),
        rejected => Err(InputDeliveryError::Rejected(rejected)),
    }
}

fn flatten_writer_result(result: Result<Result<()>, tokio::task::JoinError>) -> Result<()> {
    result.context("control writer task failed")?
}

async fn run_client(config: ConnectConfig) -> Result<()> {
    ensure_backend_available(config.input_backend)?;
    ensure_local_input_identity(config.input_backend, config.device_id)?;
    validate_readiness_startup(config.readiness.as_ref())?;
    let identity = load_identity(&config.identity)?;
    let mut endpoint = Endpoint::client(config.bind)
        .with_context(|| format!("failed to bind QUIC client to {}", config.bind))?;
    let client_config = build_client_config(&identity)
        .map_err(|error| anyhow!("invalid QUIC client identity: {error}"))?;
    endpoint.set_default_client_config(client_config);
    println!(
        "viewflowd protocol {}.{} connecting from {} to {} as {:?}; Deskflow unchanged",
        PROTOCOL_VERSION.major,
        PROTOCOL_VERSION.minor,
        endpoint
            .local_addr()
            .context("failed to read local QUIC address")?,
        config.peer,
        config.server_name
    );
    let clock = ProcessClock::new();
    let mut consecutive_failures = 0_u32;
    let mut connection_generation = 1_u64;
    let mut readiness_commit_completed = false;

    loop {
        let result = connect_once(
            &endpoint,
            &config,
            &clock,
            connection_generation,
            &mut readiness_commit_completed,
        )
        .await;
        connection_generation = connection_generation
            .checked_add(1)
            .ok_or_else(|| anyhow!("client connection generation exhausted"))?;
        match result {
            Ok(()) => consecutive_failures = 0,
            Err(error) => {
                consecutive_failures = consecutive_failures.saturating_add(1);
                let delay = reconnect_delay(
                    config.reconnect_delay,
                    config.max_reconnect_delay,
                    consecutive_failures,
                );
                eprintln!(
                    "viewflowd client peer {} disconnected: {error:#}; retrying in {} ms",
                    config.peer,
                    delay.as_millis()
                );
                sleep(delay).await;
            }
        }
    }
}

async fn connect_once(
    endpoint: &Endpoint,
    config: &ConnectConfig,
    clock: &ProcessClock,
    connection_generation: u64,
    readiness_commit_completed: &mut bool,
) -> Result<()> {
    let connecting = endpoint
        .connect(config.peer, &config.server_name)
        .with_context(|| format!("cannot start connection to {}", config.peer))?;
    let connection = connecting
        .await
        .with_context(|| format!("mTLS connection to {} failed", config.peer))?;
    println!(
        "viewflowd client authenticated peer {}",
        connection.remote_address()
    );
    run_client_connection(
        &connection,
        config,
        clock,
        connection_generation,
        readiness_commit_completed,
    )
    .await
}

async fn run_client_connection(
    connection: &Connection,
    config: &ConnectConfig,
    clock: &ProcessClock,
    connection_generation: u64,
    readiness_commit_completed: &mut bool,
) -> Result<()> {
    let (outbound_controls, outbound_rx) = mpsc::channel(256);
    let outbound = OutboundSender::new_connected(outbound_controls, connection.clone());
    let (clock_replies, clock_reply_rx) = mpsc::channel(4);
    let (clock_snapshots, clock_snapshot_rx) = watch::channel(None);
    let mut writer = spawn_control_writer(connection.clone(), outbound_rx);
    let mut input = InputReceiver::new(config.input_backend, config.device_id)?;
    let readiness = establish_readiness(
        config.readiness.clone(),
        clock_snapshot_rx.clone(),
        connection.remote_address(),
        config.server_name.clone(),
        config.device_id,
        connection_generation,
    );
    tokio::pin!(readiness);
    let mut readiness_guard = None;
    let commit_enabled = config
        .readiness
        .as_ref()
        .and_then(|readiness| readiness.commit.as_ref())
        .is_some();
    let mut commit_poll = tokio::time::interval(Duration::from_millis(10));
    commit_poll.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut probe = tokio::spawn(run_probe_loop(
        "client",
        connection.clone(),
        config.probe_interval,
        config.probe_timeout,
        clock.clone(),
        outbound.clone(),
        clock_reply_rx,
        clock_snapshots,
    ));
    let result = {
        let receiver = handle_client_receiver(
            connection,
            clock,
            &mut input,
            outbound.clone(),
            clock_replies,
            clock_snapshot_rx,
            #[cfg(target_os = "linux")]
            None,
            None,
        );
        tokio::pin!(receiver);
        loop {
            tokio::select! {
                biased;
                reason = connection.closed() => {
                    break Err(anyhow!("connection closed: {reason}"));
                }
                result = &mut receiver => break result,
                result = &mut writer => break flatten_writer_result(result),
                result = &mut probe => break result.context("clock probe task failed")?,
                established = &mut readiness, if readiness_guard.is_none() => {
                    match established {
                        Ok(guard) => readiness_guard = Some(guard),
                        Err(error) => break Err(error),
                    }
                }
                _ = commit_poll.tick(), if commit_enabled
                    && readiness_guard.is_some()
                    && !*readiness_commit_completed =>
                {
                    let readiness_config = config
                        .readiness
                        .as_ref()
                        .expect("commit requires readiness config");
                    let guard = readiness_guard
                        .as_ref()
                        .expect("commit polling requires readiness guard");
                    match try_commit_readiness(connection, readiness_config, guard) {
                        Ok(true) => *readiness_commit_completed = true,
                        Ok(false) => {}
                        Err(error) => break Err(error),
                    }
                }
            }
        }
    };
    // The lock is the live half of the evidence. Revoke it before any slower
    // input cleanup so a disconnected transport cannot appear ready.
    #[cfg(windows)]
    drop(readiness_guard);
    outbound
        .input_acks
        .disconnect(format!("peer {} disconnected", connection.remote_address()));
    outbound.abort_peer("viewflow client peer handler ended");
    writer.abort();
    probe.abort();
    finish_with_input_release("client", connection.remote_address(), result, &mut input)
}

#[allow(clippy::too_many_lines, clippy::too_many_arguments)]
async fn handle_client_receiver(
    connection: &Connection,
    clock: &ProcessClock,
    input: &mut InputReceiver,
    outbound: OutboundSender,
    clock_replies: mpsc::Sender<ClockReplyDispatch>,
    clock_snapshot: watch::Receiver<Option<ClockSnapshot>>,
    #[cfg(target_os = "linux")] mut window_input: Option<
        window_input_runtime::RoutedWindowInput<'_>,
    >,
    mut window_preview: Option<window_preview_input::WindowPreviewInput>,
) -> Result<()> {
    let mut incoming_sequence = ControlSequencer::default();
    let mut inbound_file_transfer = None;
    loop {
        let incoming = receive_shared_peer_payload(
            connection,
            &mut incoming_sequence,
            &outbound,
            #[cfg(target_os = "linux")]
            &mut window_input,
            &mut window_preview,
            &clock_snapshot,
        )
        .await?;
        let t1_receive_ns = clock.now_ns();
        match incoming {
            PeerPayload::Control(DomainControl::ClockSyncReply(reply)) => {
                dispatch_clock_reply(&clock_replies, reply).await?;
            }
            PeerPayload::Control(DomainControl::ClockSyncProbe(probe)) => {
                let t2_send_ns = clock.now_ns();
                queue_control(
                    &outbound,
                    wire::control_envelope::Payload::ClockSyncReply(wire::ClockSyncReply {
                        probe_id: probe.probe_id,
                        t0_send_ns: probe.t0_send_ns,
                        t1_receive_ns,
                        t2_send_ns,
                    }),
                )
                .await
                .context("control writer stopped before clock reply")?;
            }
            PeerPayload::Control(DomainControl::InputLease(lease)) => {
                input.apply_lease(lease)?;
                println!(
                    "viewflowd client peer {} input_lease_generation={} state={:?}",
                    connection.remote_address(),
                    lease.generation,
                    lease.state
                );
            }
            PeerPayload::Control(DomainControl::InputLeaseRevoke(revoke)) => {
                acknowledge_lease_revoke(
                    &outbound,
                    connection.remote_address(),
                    "client",
                    input,
                    revoke,
                )
                .await?;
            }
            PeerPayload::Control(DomainControl::InputEvent(event)) => {
                let snapshot = *clock_snapshot.borrow();
                let local_now_ns = clock.now_ns();
                acknowledge_input_result(
                    &outbound,
                    connection.remote_address(),
                    "client",
                    input,
                    event,
                    snapshot,
                    local_now_ns,
                )
                .await?;
            }
            PeerPayload::Control(DomainControl::InputAppliedAck(ack)) => {
                log_input_ack_resolution(
                    "client",
                    connection.remote_address(),
                    ack,
                    outbound.input_acks.resolve(ack),
                );
            }
            PeerPayload::Control(DomainControl::InputLeaseRevokedAck(ack)) => {
                handle_lease_revoke_ack(&outbound, connection.remote_address(), "client", ack)?;
            }
            PeerPayload::Control(DomainControl::FileDragOffer(offer)) => {
                accept_inbound_file_drag(&outbound, &mut inbound_file_transfer, offer).await?;
            }
            PeerPayload::Control(DomainControl::FileDragComplete(completion))
                if matches!(
                    completion.status,
                    viewflow_protocol::DragCompletionStatus::Cancelled
                        | viewflow_protocol::DragCompletionStatus::Failed
                ) =>
            {
                cancel_inbound_file_drag(&mut inbound_file_transfer, &completion)?;
            }
            PeerPayload::Control(
                DomainControl::WindowPointerMotion(_)
                | DomainControl::WindowPointerButton(_)
                | DomainControl::WindowPointerWheel(_)
                | DomainControl::WindowKeyboardEvent(_)
                | DomainControl::WindowKeyboardAck(_)
                | DomainControl::WindowKeyboardAuthorization(_)
                | DomainControl::AtlasWindowSelection(_),
            ) => {
                bail!("window-scoped input runtime is not enabled on this connection");
            }
            PeerPayload::Control(other) => {
                eprintln!(
                    "viewflowd client peer {} ignored control {other:?}",
                    connection.remote_address()
                );
            }
            PeerPayload::Blob(chunk) => {
                push_inbound_file_drag(&outbound, &mut inbound_file_transfer, &chunk).await?;
            }
        }
    }
}

async fn acknowledge_lease_revoke(
    outbound: &OutboundSender,
    peer: SocketAddr,
    role: &str,
    input: &mut InputReceiver,
    revoke: InputLeaseRevoke,
) -> Result<()> {
    let ack = input
        .apply_lease_revoke(revoke)
        .context("refusing to acknowledge an unapplied input lease revoke")?;
    queue_control(outbound, input_lease_revoked_ack_payload(ack))
        .await
        .context("control writer stopped before lease revoke applied acknowledgment")?;
    println!(
        "viewflowd {role} peer {peer} lease_revoke_operation={:032x} \
         lease_generation={} owner={:032x} target={:032x} state=revoked applied=true",
        revoke.operation_id.0,
        revoke.lease_generation,
        revoke.owner_device.0,
        revoke.target_device.0
    );
    Ok(())
}

fn handle_lease_revoke_ack(
    outbound: &OutboundSender,
    peer: SocketAddr,
    role: &str,
    ack: InputLeaseRevokedAck,
) -> Result<()> {
    match outbound.lease_revoke_acks.resolve(ack) {
        LeaseRevokeAckResolution::Delivered => Ok(()),
        resolution => {
            outbound.abort_peer("invalid, late, or replayed lease revoke acknowledgment");
            bail!(
                "viewflowd {role} peer {peer} rejected lease revoke acknowledgment \
                 operation={:032x} generation={} owner={:032x} target={:032x} \
                 state={:?} result={:?} resolution={resolution:?}",
                ack.operation_id.0,
                ack.lease_generation,
                ack.owner_device.0,
                ack.target_device.0,
                ack.state,
                ack.result
            )
        }
    }
}

fn log_input_ack_resolution(
    role: &str,
    peer: SocketAddr,
    ack: InputAppliedAck,
    resolution: InputAckResolution,
) {
    match resolution {
        InputAckResolution::Delivered => {}
        InputAckResolution::Late(terminal) => eprintln!(
            "viewflowd {role} peer {peer} late input acknowledgment \
             lease_generation={} event_sequence={} target={:032x} result={:?} \
             prior_terminal={terminal:?}",
            ack.lease_generation, ack.event_sequence, ack.target_device.0, ack.result
        ),
        InputAckResolution::Unmatched => eprintln!(
            "viewflowd {role} peer {peer} ignored unmatched input acknowledgment \
             lease_generation={} event_sequence={} target={:032x}",
            ack.lease_generation, ack.event_sequence, ack.target_device.0
        ),
    }
}

async fn acknowledge_input_result(
    outbound: &OutboundSender,
    peer: SocketAddr,
    role: &str,
    input: &mut InputReceiver,
    event: InputEvent,
    clock: Option<ClockSnapshot>,
    local_now_ns: u64,
) -> Result<()> {
    let result = match input.apply_event(&event, clock, local_now_ns) {
        Ok(()) => InputAppliedResult::Applied,
        Err(error) => error.result(),
    };
    queue_control(outbound, input_applied_ack_payload(&event, result))
        .await
        .context("control writer stopped before input acknowledgment")?;
    if result == InputAppliedResult::Applied {
        println!(
            "viewflowd {role} peer {peer} input_event_sequence={} lease_generation={} \
             target={:032x} applied=true kind={:?}",
            event.sequence, event.lease_generation, event.target_device.0, event.event
        );
    } else {
        eprintln!(
            "viewflowd {role} peer {peer} input_event_sequence={} lease_generation={} \
             target={:032x} applied=false result={result:?}",
            event.sequence, event.lease_generation, event.target_device.0
        );
    }
    Ok(())
}

fn finish_with_input_release(
    role: &str,
    peer: SocketAddr,
    result: Result<()>,
    input: &mut InputReceiver,
) -> Result<()> {
    let release = input
        .release_all()
        .context("failed to release remote input state");
    match result {
        Err(error) => {
            if let Err(release_error) = release {
                eprintln!(
                    "viewflowd {role} peer {peer} release-all after disconnect failed: \
                     {release_error:#}"
                );
            }
            Err(error)
        }
        Ok(()) => release,
    }
}

struct ClockReplyDispatch {
    reply: ClockSyncReply,
    processed: oneshot::Sender<std::result::Result<(), String>>,
}

async fn dispatch_clock_reply(
    clock_replies: &mpsc::Sender<ClockReplyDispatch>,
    reply: ClockSyncReply,
) -> Result<()> {
    let (processed, completion) = oneshot::channel();
    clock_replies
        .send(ClockReplyDispatch { reply, processed })
        .await
        .context("clock probe loop stopped before receiving its reply")?;
    match completion.await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(reason)) => bail!("clock probe rejected its reply: {reason}"),
        Err(_) => bail!("clock probe loop stopped before publishing its snapshot"),
    }
}

#[derive(Debug)]
pub(crate) struct PeerLivenessTimeout {
    pub(crate) probe_id: u64,
}

impl std::fmt::Display for PeerLivenessTimeout {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "clock probe {} timed out", self.probe_id)
    }
}

impl std::error::Error for PeerLivenessTimeout {}

#[derive(Debug)]
pub(crate) struct InputRecoveryUnconfirmed;
impl std::fmt::Display for InputRecoveryUnconfirmed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("input operation remains unconfirmed; automatic recovery forbidden")
    }
}
impl std::error::Error for InputRecoveryUnconfirmed {}

fn guard_liveness_recovery(
    result: Result<()>,
    unconfirmed: &std::sync::atomic::AtomicBool,
) -> Result<()> {
    if result
        .as_ref()
        .is_err_and(anyhow::Error::is::<PeerLivenessTimeout>)
        && unconfirmed.load(std::sync::atomic::Ordering::Acquire)
    {
        result.context(InputRecoveryUnconfirmed)
    } else {
        result
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_probe_loop(
    role: &'static str,
    connection: Connection,
    probe_interval: Duration,
    probe_timeout: Duration,
    clock: ProcessClock,
    outbound: OutboundSender,
    mut replies: mpsc::Receiver<ClockReplyDispatch>,
    snapshots: watch::Sender<Option<ClockSnapshot>>,
) -> Result<()> {
    let mut probe_id = 1_u64;
    let mut clock_guard = clock_retention::ClockRetention::default();
    loop {
        let t0_send_ns = clock.now_ns();
        queue_control(
            &outbound,
            wire::control_envelope::Payload::ClockSyncProbe(wire::ClockSyncProbe {
                probe_id,
                t0_send_ns,
            }),
        )
        .await
        .context("control writer stopped before clock probe")?;
        let reply_deadline = tokio::time::Instant::now() + probe_timeout;
        let dispatch = loop {
            match tokio::time::timeout_at(reply_deadline, replies.recv()).await {
                Ok(Some(dispatch)) if dispatch.reply.probe_id < probe_id => {
                    // A previous probe may arrive after its watchdog. Release
                    // the ordered receiver and continue waiting for this one.
                    let _ = dispatch.processed.send(Ok(()));
                }
                Ok(Some(dispatch)) => break Some(dispatch),
                Ok(None) => bail!("clock reply dispatcher stopped"),
                Err(_) => {
                    if let Some(reason) = connection.close_reason() {
                        bail!("clock connection ended: {reason}");
                    }
                    snapshots.send_replace(None);
                    eprintln!("viewflowd {role} clock probe {probe_id} delayed; resynchronizing");
                    break None;
                }
            }
        };
        let Some(dispatch) = dispatch else {
            probe_id = probe_id.checked_add(1)
                .ok_or_else(|| anyhow!("clock probe identifier exhausted"))?;
            sleep(probe_interval).await;
            continue;
        };
        let t3_receive_ns = clock.now_ns();
        let snapshot =
            match clock_snapshot_from_reply(dispatch.reply, probe_id, t0_send_ns, t3_receive_ns) {
                Ok(snapshot) => snapshot,
                Err(error) => {
                    let _ = dispatch.processed.send(Err(error.to_string()));
                    return Err(error);
                }
            };
        let active = match clock_guard.observe(
            snapshot,
            t0_send_ns,
            dispatch.reply.t1_receive_ns,
            dispatch.reply.t2_send_ns,
        ) {
            Ok(active) => active,
            Err(error) => {
                snapshots.send_replace(None);
                let _ = dispatch.processed.send(Err(error.to_string()));
                return Err(error);
            }
        };
        snapshots.send_replace(active);
        let _ = dispatch.processed.send(Ok(()));
        println!(
            "viewflowd {role} peer {} probe={} rtt_us={} offset_us={} uncertainty_us={} clock_decision={} active_age_us={}",
            connection.remote_address(),
            probe_id,
            snapshot.estimate.network_round_trip_ns / 1_000,
            snapshot.estimate.remote_offset_ns / 1_000,
            snapshot.estimate.uncertainty_ns / 1_000,
            match active {
                Some(active) if active == snapshot => "accepted",
                Some(_) => "retained",
                None => "unusable",
            },
            active.map_or(0, |active| (t3_receive_ns - active.measured_at_local_ns)
                / 1_000)
        );

        probe_id = probe_id
            .checked_add(1)
            .ok_or_else(|| anyhow!("clock probe identifier exhausted"))?;
        sleep(probe_interval).await;
    }
}

fn clock_snapshot_from_reply(
    reply: ClockSyncReply,
    expected_probe_id: u64,
    expected_t0_ns: u64,
    t3_receive_ns: u64,
) -> Result<ClockSnapshot> {
    if reply.probe_id != expected_probe_id || reply.t0_send_ns != expected_t0_ns {
        bail!(
            "clock reply mismatch: expected probe {expected_probe_id} at {expected_t0_ns}, got probe {} at {}",
            reply.probe_id,
            reply.t0_send_ns
        );
    }
    let estimate = ClockEstimate::from_exchange(
        reply.t0_send_ns,
        reply.t1_receive_ns,
        reply.t2_send_ns,
        t3_receive_ns,
    )?;
    Ok(ClockSnapshot {
        estimate,
        measured_at_local_ns: t3_receive_ns,
    })
}

fn envelope(sequence: u64, payload: wire::control_envelope::Payload) -> wire::ControlEnvelope {
    wire::ControlEnvelope {
        protocol_major: u32::from(PROTOCOL_VERSION.major),
        protocol_minor: u32::from(PROTOCOL_VERSION.minor),
        sequence,
        payload: Some(payload),
    }
}

fn reconnect_delay(base: Duration, maximum: Duration, failure_count: u32) -> Duration {
    let exponent = failure_count.saturating_sub(1).min(31);
    base.saturating_mul(1_u32 << exponent).min(maximum)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_CERTIFICATE: &[u8] =
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem");
    const TEST_PRIVATE_KEY: &[u8] =
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.key");
    const TEST_CERTIFICATE_AUTHORITY: &[u8] =
        include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem");

    fn test_identity() -> PeerIdentity {
        PeerIdentity::from_pem(
            TEST_CERTIFICATE,
            TEST_PRIVATE_KEY,
            TEST_CERTIFICATE_AUTHORITY,
        )
        .unwrap()
    }

    fn test_lease_payload(
        generation: u64,
        state: viewflow_protocol::InputLeaseState,
    ) -> wire::control_envelope::Payload {
        input_runtime::input_lease_payload(viewflow_protocol::InputLease {
            generation,
            owner: Id128(1),
            route_to: Id128(2),
            state,
        })
    }

    fn test_motion_event(sender_not_after_ns: u64) -> InputEvent {
        InputEvent {
            lease_generation: 2,
            target_device: Id128(2),
            sequence: 1,
            sender_not_after_ns,
            event: viewflow_protocol::InputEventKind::PointerMotion(
                viewflow_protocol::RelativePointerMotion {
                    delta_x_dip: 1.0,
                    delta_y_dip: 0.0,
                },
            ),
        }
    }

    #[test]
    fn input_script_claim_is_sticky_for_the_daemon_lifetime() {
        let claimed = AtomicBool::new(false);

        assert!(claim_input_script_for_daemon_lifetime(&claimed));
        assert!(claimed.load(Ordering::Acquire));
        assert!(!claim_input_script_for_daemon_lifetime(&claimed));
    }

    #[test]
    fn parses_server_options() {
        let command = parse_args([
            "serve",
            "--bind",
            "127.0.0.1:41000",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
        ])
        .unwrap();
        assert_eq!(
            command,
            Command::Serve(ServeConfig {
                bind: "127.0.0.1:41000".parse().unwrap(),
                identity: IdentityPaths {
                    certificate: "peer.pem".into(),
                    private_key: "peer.key".into(),
                    certificate_authority: "ca.pem".into(),
                },
                probe_interval: Duration::from_secs(1),
                probe_timeout: Duration::from_secs(3),
                input_backend: InputBackendMode::Disabled,
                device_id: None,
                input_script: None,
                input_script_peer: None,
                sidecar_socket: None,
                sidecar_peer: None,
                sidecar_target_device: None,
                quiesce_proof: None,
                quiesce_arm_file: None,
                #[cfg(unix)]
                acceptance: None,
            })
        );
    }

    #[cfg(unix)]
    #[test]
    fn parses_quiescence_arm_without_tls_identity() {
        let command = parse_args([
            "arm-quiesce",
            "--arm-file",
            "/run/user/1000/viewflow/quiesce.arm",
            "--operation-id",
            "deploy-20260829-abcdef",
            "--daemon-pid",
            "1234",
        ])
        .unwrap();
        assert_eq!(
            command,
            Command::ArmQuiesce(ArmQuiesceConfig {
                arm_file: "/run/user/1000/viewflow/quiesce.arm".into(),
                operation_id: "deploy-20260829-abcdef".into(),
                daemon_pid: 1234,
            })
        );
        assert!(
            parse_args([
                "arm-quiesce",
                "--arm-file",
                "/tmp/arm",
                "--operation-id",
                "too-short",
                "--daemon-pid",
                "1234",
            ])
            .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn parses_post_release_acceptance_live_control_commands() {
        let sha_a = "a".repeat(64);
        let sha_b = "b".repeat(64);
        let sha_c = "c".repeat(64);
        let arm = parse_args([
            "acceptance-arm",
            "--acceptance-socket",
            "/run/user/1000/viewflow/acceptance.sock",
            "--operation-id",
            "deploy-20260829-abcdef",
            "--source-display-id",
            "00000000000000000000000000000001",
            "--target-device-id",
            "00000000000000000000000000000002",
            "--linux-viewflow-sha256",
            &sha_a,
            "--windows-viewflow-sha256",
            &sha_b,
            "--deployment-release-receipt",
            "/run/user/1000/viewflow/release.json",
            "--deployment-release-receipt-sha256",
            &sha_c,
        ])
        .unwrap();
        assert!(matches!(arm, Command::AcceptanceArm(_)));

        let query = parse_args([
            "acceptance-query",
            "--acceptance-socket",
            "/run/user/1000/viewflow/acceptance.sock",
            "--operation-id",
            "deploy-20260829-abcdef",
        ])
        .unwrap();
        assert!(matches!(query, Command::AcceptanceQuery(_)));
    }

    #[cfg(windows)]
    #[test]
    fn parses_force_release_input_without_tls_identity() {
        let linux_frozen_evidence_sha256 =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let command = parse_args([
            "force-release-input",
            "--receipt",
            r"C:\ProgramData\Viewflow\force-release.json",
            "--operation-id",
            "deploy-20260829-abcdef",
            "--linux-evidence-sha256",
            linux_frozen_evidence_sha256,
        ])
        .unwrap();
        assert_eq!(
            command,
            Command::ForceReleaseInput(ForceReleaseInputConfig {
                receipt: r"C:\ProgramData\Viewflow\force-release.json".into(),
                operation_id: "deploy-20260829-abcdef".into(),
                linux_frozen_evidence_sha256: linux_frozen_evidence_sha256.into(),
            })
        );

        for invalid in [
            vec![
                "force-release-input",
                "--operation-id",
                "deploy-20260829-abcdef",
                "--linux-evidence-sha256",
                linux_frozen_evidence_sha256,
            ],
            vec![
                "force-release-input",
                "--receipt",
                "receipt.json",
                "--operation-id",
                "too-short",
                "--linux-evidence-sha256",
                linux_frozen_evidence_sha256,
            ],
            vec![
                "force-release-input",
                "--receipt",
                "receipt.json",
                "--operation-id",
                "deploy-20260829-abcdef",
                "--linux-evidence-sha256",
                linux_frozen_evidence_sha256,
                "--unknown",
                "value",
            ],
            vec![
                "force-release-input",
                "--receipt",
                "receipt.json",
                "--operation-id",
                "deploy-20260829-abcdef",
            ],
            vec![
                "force-release-input",
                "--receipt",
                "receipt.json",
                "--operation-id",
                "deploy-20260829-abcdef",
                "--linux-evidence-sha256",
                "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            ],
        ] {
            assert!(parse_args(invalid).is_err());
        }
    }

    #[test]
    fn lower_sha256_requires_exact_lowercase_ascii_hex() {
        let valid = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assert!(validate_lower_sha256(valid, "--test-sha256").is_ok());

        for invalid in [
            "",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeF",
        ] {
            assert!(validate_lower_sha256(invalid, "--test-sha256").is_err());
        }
    }

    #[cfg(not(windows))]
    #[test]
    fn force_release_input_is_explicitly_rejected_off_windows() {
        let error = parse_args([
            "force-release-input",
            "--receipt",
            "/tmp/receipt.json",
            "--operation-id",
            "deploy-20260829-abcdef",
        ])
        .unwrap_err();
        assert!(error.to_string().contains("only available on Windows"));
    }

    #[cfg(unix)]
    #[test]
    fn quiescence_output_requires_arm_and_sidecar() {
        let base = [
            "serve",
            "--bind",
            "127.0.0.1:41000",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
            "--quiesce-proof",
            "/tmp/proof.json",
        ];
        assert!(parse_args(base).is_err());
    }

    #[test]
    fn parses_client_defaults_and_overrides() {
        let command = parse_args([
            "connect",
            "--peer",
            "192.0.2.8:41000",
            "--server-name",
            "windows.example",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
            "--probe-interval-ms",
            "25",
        ])
        .unwrap();
        let Command::Connect(config) = command else {
            panic!("expected connect command");
        };
        assert_eq!(config.bind, "0.0.0.0:0".parse().unwrap());
        assert_eq!(config.peer, "192.0.2.8:41000".parse().unwrap());
        assert_eq!(config.server_name, "windows.example");
        assert_eq!(config.probe_interval, Duration::from_millis(25));
        assert_eq!(config.probe_timeout, Duration::from_secs(3));
        assert_eq!(config.max_reconnect_delay, Duration::from_secs(5));
        assert_eq!(config.input_backend, InputBackendMode::Disabled);
        assert_eq!(config.device_id, None);
    }

    #[test]
    fn readiness_options_are_atomic_and_require_native_input_identity() {
        let base = [
            "connect",
            "--peer",
            "192.0.2.8:41000",
            "--server-name",
            "windows.example",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
            "--input-backend",
            "native",
            "--device-id",
            "00000000000000000000000000000002",
        ];
        let mut complete = base.to_vec();
        complete.extend([
            "--readiness-receipt",
            "ready.json",
            "--readiness-lock",
            "ready.lock",
            "--operation-id",
            "deploy-20260829-readiness",
        ]);
        let Command::Connect(config) = parse_args(complete).unwrap() else {
            panic!("expected connect config");
        };
        assert_eq!(
            config.readiness,
            Some(ReadinessConfig {
                receipt: "ready.json".into(),
                lock: "ready.lock".into(),
                operation_id: "deploy-20260829-readiness".into(),
                commit: None,
            })
        );

        let mut incomplete = base.to_vec();
        incomplete.extend([
            "--readiness-receipt",
            "ready.json",
            "--operation-id",
            "deploy-20260829-readiness",
        ]);
        assert!(parse_args(incomplete).is_err());

        let mut duplicate_path = base.to_vec();
        duplicate_path.extend([
            "--readiness-receipt",
            "ready.json",
            "--readiness-lock",
            "ready.json",
            "--operation-id",
            "deploy-20260829-readiness",
        ]);
        assert!(parse_args(duplicate_path).is_err());

        let mut no_native_identity = vec![
            "connect",
            "--peer",
            "192.0.2.8:41000",
            "--server-name",
            "windows.example",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
        ];
        no_native_identity.extend([
            "--readiness-receipt",
            "ready.json",
            "--readiness-lock",
            "ready.lock",
            "--operation-id",
            "deploy-20260829-readiness",
        ]);
        assert!(parse_args(no_native_identity).is_err());
    }

    #[test]
    fn readiness_commit_paths_are_atomic_and_bound_to_readiness() {
        let complete = [
            "connect",
            "--peer",
            "192.0.2.8:41000",
            "--server-name",
            "windows.example",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
            "--input-backend",
            "native",
            "--device-id",
            "00000000000000000000000000000002",
            "--readiness-receipt",
            "ready.json",
            "--readiness-lock",
            "ready.lock",
            "--readiness-commit-request",
            "commit-request.json",
            "--install-success-receipt",
            "install-success.json",
            "--operation-id",
            "deploy-20260829-readiness",
        ];
        let Command::Connect(config) = parse_args(complete).unwrap() else {
            panic!("expected connect config");
        };
        assert_eq!(
            config.readiness.unwrap().commit,
            Some(ReadinessCommitConfig {
                request: "commit-request.json".into(),
                install_success_receipt: "install-success.json".into(),
            })
        );

        let without_success = complete.into_iter().filter(|value| {
            !matches!(*value, "--install-success-receipt" | "install-success.json")
        });
        assert!(parse_args(without_success).is_err());

        let commit_without_readiness = [
            "connect",
            "--peer",
            "192.0.2.8:41000",
            "--server-name",
            "windows.example",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
            "--readiness-commit-request",
            "commit-request.json",
            "--install-success-receipt",
            "install-success.json",
        ];
        assert!(parse_args(commit_without_readiness).is_err());
    }

    #[test]
    fn parses_and_requires_scoped_input_identity_options() {
        let device = parse_device_id("00000000000000000000000000000002").unwrap();
        assert_eq!(device, Id128(2));
        assert!(parse_device_id("0").is_err());
        assert!(ensure_local_input_identity(InputBackendMode::Native, None).is_err());
        assert!(ensure_local_input_identity(InputBackendMode::Native, Some(device)).is_ok());

        let command = parse_args([
            "serve",
            "--bind",
            "127.0.0.1:41000",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
            "--input-script",
            "input.txt",
        ]);
        assert!(command.is_err());

        let sidecar = parse_args([
            "serve",
            "--bind",
            "127.0.0.1:41000",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
            "--device-id",
            "00000000000000000000000000000001",
            "--sidecar-socket",
            "/run/user/1000/viewflow/deskflow.sock",
            "--sidecar-peer",
            "192.0.2.8",
            "--sidecar-target-device",
            "00000000000000000000000000000002",
        ])
        .unwrap();
        let Command::Serve(sidecar) = sidecar else {
            panic!("expected serve config");
        };
        assert_eq!(sidecar.device_id, Some(Id128(1)));
        assert_eq!(sidecar.sidecar_target_device, Some(Id128(2)));
        assert_eq!(sidecar.sidecar_peer, Some("192.0.2.8".parse().unwrap()));

        assert!(
            parse_args([
                "serve",
                "--bind",
                "127.0.0.1:41000",
                "--cert",
                "peer.pem",
                "--key",
                "peer.key",
                "--ca",
                "ca.pem",
                "--sidecar-socket",
                "/tmp/incomplete.sock",
            ])
            .is_err()
        );
    }

    #[test]
    fn rejects_unknown_duplicate_and_invalid_timing_options() {
        let common = [
            "--peer",
            "127.0.0.1:41000",
            "--server-name",
            "localhost",
            "--cert",
            "peer.pem",
            "--key",
            "peer.key",
            "--ca",
            "ca.pem",
        ];
        let mut unknown = vec!["connect"];
        unknown.extend(common);
        unknown.extend(["--unexpected", "value"]);
        assert!(parse_args(unknown).is_err());

        assert!(
            parse_args([
                "serve",
                "--bind",
                "127.0.0.1:1",
                "--bind",
                "127.0.0.1:2",
                "--cert",
                "c",
                "--key",
                "k",
                "--ca",
                "a",
            ])
            .is_err()
        );

        let mut invalid = vec!["connect"];
        invalid.extend(common);
        invalid.extend(["--probe-timeout-ms", "0"]);
        assert!(parse_args(invalid).is_err());
    }

    #[test]
    fn clock_reply_snapshot_maps_both_offset_directions_and_checks_identity_boundaries() {
        let ahead = clock_snapshot_from_reply(
            ClockSyncReply {
                probe_id: 7,
                t0_send_ns: 100,
                t1_receive_ns: 115,
                t2_send_ns: 117,
            },
            7,
            100,
            108,
        )
        .unwrap();
        assert_eq!(ahead.estimate.remote_offset_ns, 12);
        assert_eq!(ahead.estimate.network_round_trip_ns, 6);
        assert_eq!(ahead.measured_at_local_ns, 108);

        let behind = clock_snapshot_from_reply(
            ClockSyncReply {
                probe_id: 8,
                t0_send_ns: 100,
                t1_receive_ns: 95,
                t2_send_ns: 97,
            },
            8,
            100,
            108,
        )
        .unwrap();
        assert_eq!(behind.estimate.remote_offset_ns, -8);
        assert_eq!(behind.estimate.network_round_trip_ns, 6);
        assert_eq!(behind.measured_at_local_ns, 108);

        for (expected_probe_id, expected_t0_ns) in [(9, 100), (8, 101)] {
            assert!(
                clock_snapshot_from_reply(
                    ClockSyncReply {
                        probe_id: 8,
                        t0_send_ns: 100,
                        t1_receive_ns: 101,
                        t2_send_ns: 102,
                    },
                    expected_probe_id,
                    expected_t0_ns,
                    103,
                )
                .is_err()
            );
        }
    }

    #[tokio::test]
    async fn persistent_client_reconnects_and_restarts_control_sequence() {
        let server = Endpoint::server(
            build_server_config(&test_identity()).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let fixtures =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../viewflow-transport/tests/fixtures");
        let config = ConnectConfig {
            bind: "127.0.0.1:0".parse().unwrap(),
            peer: server.local_addr().unwrap(),
            server_name: "localhost".into(),
            identity: IdentityPaths {
                certificate: fixtures.join("peer.pem"),
                private_key: fixtures.join("peer.key"),
                certificate_authority: fixtures.join("ca.pem"),
            },
            probe_interval: Duration::from_secs(1),
            probe_timeout: Duration::from_secs(1),
            reconnect_delay: Duration::from_millis(10),
            max_reconnect_delay: Duration::from_millis(20),
            input_backend: InputBackendMode::Disabled,
            device_id: None,
            readiness: None,
        };
        let exercise = async {
            let mut previous_connection = None;
            let mut client_address = None;
            for _ in 0..2 {
                let connection = server.accept().await.unwrap().await.unwrap();
                assert_ne!(previous_connection, Some(connection.stable_id()));
                previous_connection = Some(connection.stable_id());
                if let Some(address) = client_address {
                    assert_eq!(address, connection.remote_address());
                }
                client_address = Some(connection.remote_address());
                // A fresh sequencer must accept the first control on each new
                // authenticated connection. Do not reuse old clock evidence.
                let mut sequence = ControlSequencer::default();
                let control = receive_control_sequenced(&connection, &mut sequence)
                    .await
                    .unwrap();
                assert_eq!(control.sequence, 1);
                assert!(matches!(
                    DomainControl::try_from(control).unwrap(),
                    DomainControl::ClockSyncProbe(_)
                ));
                connection.close(0_u32.into(), b"reconnect test");
            }
        };
        tokio::time::timeout(Duration::from_secs(10), async {
            tokio::select! {
                result = run_client(config) => panic!("persistent client stopped: {result:?}"),
                () = exercise => {}
            }
        })
        .await
        .expect("same client must authenticate twice without a restart");
    }

    #[tokio::test]
    async fn server_receiver_publishes_clock_snapshot_before_following_input() {
        let server = Endpoint::server(
            build_server_config(&test_identity()).unwrap(),
            "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
        )
        .unwrap();
        let server_address = server.local_addr().unwrap();
        let server_task = tokio::spawn(async move {
            let incoming = server.accept().await.unwrap();
            let connection = incoming.await.unwrap();
            let clock = ProcessClock::new();
            let script_claimed = AtomicBool::new(false);
            handle_server_connection(
                &connection,
                &clock,
                Duration::from_secs(1),
                Duration::from_secs(1),
                InputBackendMode::Disabled,
                Some(Id128(2)),
                None,
                &script_claimed,
                #[cfg(unix)]
                None,
            )
            .await
        });

        let mut client = Endpoint::client("127.0.0.1:0".parse::<SocketAddr>().unwrap()).unwrap();
        client.set_default_client_config(build_client_config(&test_identity()).unwrap());
        let connection = client
            .connect(server_address, "localhost")
            .unwrap()
            .await
            .unwrap();
        let peer_clock = ProcessClock::new();
        let mut incoming_sequence = ControlSequencer::default();
        let incoming = receive_control_sequenced(&connection, &mut incoming_sequence)
            .await
            .unwrap();
        let DomainControl::ClockSyncProbe(probe) = DomainControl::try_from(incoming).unwrap()
        else {
            panic!("server must probe its peer before accepting freshness-gated input");
        };
        let t1_receive_ns = peer_clock.now_ns();
        let t2_send_ns = peer_clock.now_ns();
        send_control(
            &connection,
            &envelope(
                1,
                wire::control_envelope::Payload::ClockSyncReply(wire::ClockSyncReply {
                    probe_id: probe.probe_id,
                    t0_send_ns: probe.t0_send_ns,
                    t1_receive_ns,
                    t2_send_ns,
                }),
            ),
        )
        .await
        .unwrap();
        send_control(
            &connection,
            &envelope(
                2,
                test_lease_payload(1, viewflow_protocol::InputLeaseState::Offered),
            ),
        )
        .await
        .unwrap();
        send_control(
            &connection,
            &envelope(
                3,
                test_lease_payload(2, viewflow_protocol::InputLeaseState::Active),
            ),
        )
        .await
        .unwrap();
        let event = test_motion_event(peer_clock.now_ns().saturating_add(30_000_000));
        send_control(&connection, &envelope(4, input_event_payload(event)))
            .await
            .unwrap();

        let ack = timeout(Duration::from_secs(1), async {
            loop {
                let incoming = receive_control_sequenced(&connection, &mut incoming_sequence)
                    .await
                    .unwrap();
                if let DomainControl::InputAppliedAck(ack) =
                    DomainControl::try_from(incoming).unwrap()
                {
                    break ack;
                }
            }
        })
        .await
        .expect("server must acknowledge input within the probe timeout");
        assert_eq!(ack.event_sequence, event.sequence);
        assert_eq!(ack.result, InputAppliedResult::Applied);

        connection.close(0_u32.into(), b"test complete");
        let _ = timeout(Duration::from_secs(1), server_task)
            .await
            .expect("server connection handler must stop after peer close")
            .expect("server connection task must not panic");
    }

    #[test]
    fn reconnect_backoff_is_exponential_and_capped() {
        let base = Duration::from_millis(250);
        let maximum = Duration::from_secs(2);
        assert_eq!(reconnect_delay(base, maximum, 1), base);
        assert_eq!(
            reconnect_delay(base, maximum, 2),
            Duration::from_millis(500)
        );
        assert_eq!(reconnect_delay(base, maximum, 4), maximum);
        assert_eq!(reconnect_delay(base, maximum, 40), maximum);
    }

    fn acknowledged_event() -> InputEvent {
        InputEvent {
            lease_generation: 7,
            target_device: Id128(2),
            sequence: 11,
            sender_not_after_ns: 0,
            event: viewflow_protocol::InputEventKind::ReleaseAll,
        }
    }

    fn acknowledged_revoke() -> InputLeaseRevoke {
        InputLeaseRevoke {
            operation_id: Id128(0x4000_0000_0000_0001),
            lease_generation: 8,
            owner_device: Id128(1),
            target_device: Id128(2),
            state: InputLeaseState::Revoked,
        }
    }

    fn applied_revoke_ack(revoke: InputLeaseRevoke) -> InputLeaseRevokedAck {
        InputLeaseRevokedAck {
            operation_id: revoke.operation_id,
            lease_generation: revoke.lease_generation,
            owner_device: revoke.owner_device,
            target_device: revoke.target_device,
            state: revoke.state,
            result: InputLeaseRevokedResult::Applied,
        }
    }

    async fn receive_and_confirm_local_send(
        received: &mut mpsc::Receiver<OutboundControl>,
    ) -> wire::InputEvent {
        let control = received.recv().await.expect("input event must be queued");
        control
            .sent
            .expect("input send requests local transport confirmation")
            .send(Ok(()))
            .expect("input sender must still wait for confirmation");
        let wire::control_envelope::Payload::InputEvent(event) = control.payload else {
            panic!("expected an input event");
        };
        event
    }

    #[tokio::test]
    async fn input_success_waits_for_exact_remote_event_identity() {
        let (controls, mut received) = mpsc::channel(4);
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move { send_input_confirmed(&outbound, event).await })
        };
        let wire_event = receive_and_confirm_local_send(&mut received).await;
        assert_eq!(wire_event.lease_generation, event.lease_generation);
        assert_eq!(wire_event.event_sequence, event.sequence);

        for wrong in [
            InputAppliedAck {
                target_device: Id128(3),
                ..applied_ack(event)
            },
            InputAppliedAck {
                lease_generation: 8,
                ..applied_ack(event)
            },
            InputAppliedAck {
                event_sequence: 12,
                ..applied_ack(event)
            },
        ] {
            assert_eq!(
                outbound.input_acks.resolve(wrong),
                InputAckResolution::Unmatched
            );
        }
        assert!(!sender.is_finished());
        assert_eq!(
            outbound.input_acks.resolve(applied_ack(event)),
            InputAckResolution::Delivered
        );
        assert_eq!(sender.await.unwrap(), Ok(()));
    }

    #[tokio::test]
    async fn remote_injection_failure_is_stable_and_not_transport_success() {
        let (controls, mut received) = mpsc::channel(4);
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move { send_input_confirmed(&outbound, event).await })
        };
        receive_and_confirm_local_send(&mut received).await;
        assert_eq!(
            outbound.input_acks.resolve(InputAppliedAck {
                result: InputAppliedResult::InjectionFailed,
                ..applied_ack(event)
            }),
            InputAckResolution::Delivered
        );
        assert_eq!(
            sender.await.unwrap(),
            Err(InputDeliveryError::Rejected(
                InputAppliedResult::InjectionFailed
            ))
        );
    }

    #[tokio::test]
    async fn connection_loss_wakes_pending_input_and_timeout_is_bounded() {
        let (controls, mut received) = mpsc::channel(4);
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move { send_input_confirmed(&outbound, event).await })
        };
        receive_and_confirm_local_send(&mut received).await;
        outbound.input_acks.disconnect("test disconnect");
        assert_eq!(
            sender.await.unwrap(),
            Err(InputDeliveryError::DeliveryUnknown(
                "test disconnect".into()
            ))
        );

        let (controls, mut received) = mpsc::channel(4);
        let outbound = OutboundSender::new(controls);
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move { send_input_confirmed(&outbound, event).await })
        };
        receive_and_confirm_local_send(&mut received).await;
        assert!(matches!(
            sender.await.unwrap(),
            Err(InputDeliveryError::DeliveryUnknown(_))
        ));
        assert!(outbound.input_acks.lock().pending.is_empty());
    }

    #[tokio::test]
    async fn writer_queue_congestion_spends_the_total_budget_without_sending() {
        let (controls, _received) = mpsc::channel(1);
        controls
            .try_send(OutboundControl {
                payload: input_event_payload(acknowledged_event()),
                sent: None,
                input_gate: None,
            })
            .unwrap();
        let outbound = OutboundSender::new(controls);
        let started = tokio::time::Instant::now();
        let error = send_input_confirmed_with_timeout(
            &outbound,
            acknowledged_event(),
            Duration::from_millis(10),
        )
        .await
        .unwrap_err();
        assert!(error.is_safe_to_retry());
        assert!(matches!(error, InputDeliveryError::DefinitelyNotSent(_)));
        assert!(started.elapsed() >= Duration::from_millis(8));
        let state = outbound.input_acks.lock();
        assert!(state.pending.is_empty());
        assert!(state.tombstones.is_empty());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn expired_queue_deadline_wins_when_capacity_becomes_ready_same_turn() {
        let (controls, mut received) = mpsc::channel(1);
        controls
            .try_send(OutboundControl {
                payload: input_event_payload(acknowledged_event()),
                sent: None,
                input_gate: None,
            })
            .unwrap();
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let deadline = tokio::time::Instant::now() + Duration::from_millis(5);
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(
                async move { send_input_confirmed_until(&outbound, event, deadline).await },
            )
        };
        tokio::task::yield_now().await;
        std::thread::sleep(Duration::from_millis(10));
        let _occupied = received.recv().await.unwrap();
        assert!(matches!(
            sender.await.unwrap(),
            Err(InputDeliveryError::DefinitelyNotSent(_))
        ));
        let stale = received.try_recv().unwrap();
        assert!(stale.input_gate.unwrap().is_cancelled());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn expired_writer_deadline_beats_a_simultaneously_ready_send() {
        let gate = InputSendGate::new(tokio::time::Instant::now() - Duration::from_millis(1));
        let send_polled = std::cell::Cell::new(false);
        assert_eq!(
            run_input_send_until(&gate, async {
                send_polled.set(true);
                "sent"
            })
            .await,
            InputSendOutcome::DeadlineExpired
        );
        assert!(!send_polled.get(), "expired send future must not be polled");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn writer_rechecks_deadline_after_send_future_completes() {
        let gate = InputSendGate::new(tokio::time::Instant::now() + Duration::from_millis(5));
        let outcome = run_input_send_until(&gate, async {
            std::thread::sleep(Duration::from_millis(10));
            "sent"
        })
        .await;
        assert_eq!(outcome, InputSendOutcome::DeadlineExpired);
    }

    #[tokio::test]
    async fn applied_ack_wins_the_deadline_boundary_before_writer_confirmation() {
        let (controls, mut received) = mpsc::channel(1);
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move {
                send_input_confirmed_with_timeout(&outbound, event, Duration::from_millis(10)).await
            })
        };
        let control = received.recv().await.unwrap();
        let gate = control.input_gate.clone().unwrap();
        assert_eq!(
            outbound.input_acks.resolve(applied_ack(event)),
            InputAckResolution::Delivered
        );
        assert_eq!(sender.await.unwrap(), Ok(()));
        assert!(!gate.is_cancelled());
        drop(control);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ack_linearized_before_deadline_still_succeeds_after_waiter_delay() {
        let registry = InputAckRegistry::default();
        let event = acknowledged_event();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        let mut pending = registry
            .register(InputAckKey::from(&event), deadline)
            .unwrap();
        pending.may_have_been_sent = true;
        assert_eq!(
            registry.resolve_at(applied_ack(event), deadline - Duration::from_nanos(1)),
            InputAckResolution::Delivered
        );
        assert_eq!(
            pending.deadline_expired_or_receive().await,
            Ok(InputAppliedResult::Applied)
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ack_at_an_expired_deadline_is_late_and_never_applied() {
        let registry = InputAckRegistry::default();
        let event = acknowledged_event();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        let mut pending = registry
            .register(InputAckKey::from(&event), deadline)
            .unwrap();
        pending.may_have_been_sent = true;
        assert_eq!(
            registry.resolve_at(applied_ack(event), deadline),
            InputAckResolution::Late(InputAckTerminal::DeadlineExpired)
        );
        assert!(matches!(
            pending.wait_until(deadline).await,
            Err(InputDeliveryError::DeliveryUnknown(_))
        ));
        assert_eq!(
            registry.resolve(applied_ack(event)),
            InputAckResolution::Late(InputAckTerminal::DeadlineExpired)
        );
    }

    #[tokio::test]
    async fn lease_revoke_registry_requires_exact_identity_and_preserves_replay_tombstone() {
        let registry = LeaseRevokeAckRegistry::default();
        let revoke = acknowledged_revoke();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        let mut pending = registry
            .register(LeaseRevokeAckKey::from(&revoke), deadline)
            .unwrap();
        pending.may_have_been_sent = true;

        for wrong in [
            InputLeaseRevokedAck {
                operation_id: Id128(revoke.operation_id.0 + 1),
                ..applied_revoke_ack(revoke)
            },
            InputLeaseRevokedAck {
                lease_generation: revoke.lease_generation + 1,
                ..applied_revoke_ack(revoke)
            },
            InputLeaseRevokedAck {
                owner_device: Id128(revoke.owner_device.0 + 1),
                ..applied_revoke_ack(revoke)
            },
            InputLeaseRevokedAck {
                target_device: Id128(revoke.target_device.0 + 1),
                ..applied_revoke_ack(revoke)
            },
            InputLeaseRevokedAck {
                state: InputLeaseState::Active,
                ..applied_revoke_ack(revoke)
            },
        ] {
            assert_eq!(
                registry.resolve(wrong),
                LeaseRevokeAckResolution::IdentityMismatch
            );
            assert_eq!(registry.lock().pending.len(), 1);
        }
        assert_eq!(
            registry.resolve(applied_revoke_ack(revoke)),
            LeaseRevokeAckResolution::Delivered
        );
        assert_eq!(
            pending.wait_until(deadline).await,
            Ok(applied_revoke_ack(revoke))
        );
        assert_eq!(
            registry.resolve(applied_revoke_ack(revoke)),
            LeaseRevokeAckResolution::Late(LeaseRevokeAckTerminal::RemoteAck(
                InputLeaseRevokedResult::Applied
            ))
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn lease_revoke_registry_rejects_ack_after_deadline_as_late() {
        let registry = LeaseRevokeAckRegistry::default();
        let revoke = acknowledged_revoke();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        let mut pending = registry
            .register(LeaseRevokeAckKey::from(&revoke), deadline)
            .unwrap();
        pending.may_have_been_sent = true;

        assert_eq!(
            registry.resolve_at(
                applied_revoke_ack(revoke),
                deadline + Duration::from_nanos(1),
            ),
            LeaseRevokeAckResolution::Late(LeaseRevokeAckTerminal::DeadlineExpired)
        );
        assert!(matches!(
            pending.wait_until(deadline).await,
            Err(LeaseRevokeDeliveryError::DeliveryUnknown(_))
        ));
        assert_eq!(
            registry.resolve(applied_revoke_ack(revoke)),
            LeaseRevokeAckResolution::Late(LeaseRevokeAckTerminal::DeadlineExpired)
        );
    }

    #[tokio::test]
    async fn lease_revoke_registry_dropped_ack_times_out_and_stays_failed_closed() {
        let registry = LeaseRevokeAckRegistry::default();
        let revoke = acknowledged_revoke();
        let deadline = tokio::time::Instant::now() + Duration::from_millis(10);
        let mut pending = registry
            .register(LeaseRevokeAckKey::from(&revoke), deadline)
            .unwrap();
        pending.may_have_been_sent = true;

        assert!(matches!(
            pending.wait_until(deadline).await,
            Err(LeaseRevokeDeliveryError::DeliveryUnknown(_))
        ));
        assert_eq!(
            registry.resolve(applied_revoke_ack(revoke)),
            LeaseRevokeAckResolution::Late(LeaseRevokeAckTerminal::DeadlineExpired)
        );
        assert!(registry.lock().pending.is_empty());
    }

    #[tokio::test]
    async fn old_connection_lease_revoke_ack_cannot_satisfy_new_connection_pending() {
        let (old_controls, _old_received) = mpsc::channel(1);
        let old_outbound = OutboundSender::new(old_controls);
        let (new_controls, mut new_received) = mpsc::channel(1);
        let new_outbound = OutboundSender::new(new_controls);
        let revoke = acknowledged_revoke();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);

        let mut old_pending = old_outbound
            .lease_revoke_acks
            .register(LeaseRevokeAckKey::from(&revoke), deadline)
            .unwrap();
        old_pending.may_have_been_sent = true;
        let new_sender = {
            let outbound = new_outbound.clone();
            tokio::spawn(async move {
                send_lease_revoke_confirmed_until(&outbound, revoke, deadline).await
            })
        };
        let control = new_received.recv().await.expect("revoke must be queued");
        control
            .sent
            .expect("revoke must request transport confirmation")
            .send(Ok(()))
            .expect("sender must still be waiting for remote applied ACK");

        assert_eq!(
            old_outbound
                .lease_revoke_acks
                .resolve(applied_revoke_ack(revoke)),
            LeaseRevokeAckResolution::Delivered
        );
        assert_eq!(
            old_pending.wait_until(deadline).await,
            Ok(applied_revoke_ack(revoke))
        );
        assert!(!new_sender.is_finished());
        assert_eq!(new_outbound.lease_revoke_acks.lock().pending.len(), 1);
        assert_eq!(
            new_outbound
                .lease_revoke_acks
                .resolve(applied_revoke_ack(revoke)),
            LeaseRevokeAckResolution::Delivered
        );
        assert_eq!(new_sender.await.unwrap(), Ok(applied_revoke_ack(revoke)));
    }

    #[tokio::test]
    async fn lease_revoke_transport_success_without_remote_ack_is_not_success() {
        let (controls, mut received) = mpsc::channel(1);
        let outbound = OutboundSender::new(controls);
        let revoke = acknowledged_revoke();
        let deadline = tokio::time::Instant::now() + Duration::from_millis(10);
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move {
                send_lease_revoke_confirmed_until(&outbound, revoke, deadline).await
            })
        };
        let control = received.recv().await.expect("revoke must be queued");
        control
            .sent
            .expect("revoke must request transport confirmation")
            .send(Ok(()))
            .expect("sender must still be waiting for remote applied ACK");

        assert!(matches!(
            sender.await.unwrap(),
            Err(LeaseRevokeDeliveryError::DeliveryUnknown(_))
        ));
        assert_eq!(
            outbound
                .lease_revoke_acks
                .resolve(applied_revoke_ack(revoke)),
            LeaseRevokeAckResolution::Late(LeaseRevokeAckTerminal::DeadlineExpired)
        );
    }

    #[tokio::test]
    async fn lease_revoke_disconnect_wakes_waiter_and_retains_tombstone() {
        let registry = LeaseRevokeAckRegistry::default();
        let revoke = acknowledged_revoke();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        let mut pending = registry
            .register(LeaseRevokeAckKey::from(&revoke), deadline)
            .unwrap();
        pending.may_have_been_sent = true;
        registry.disconnect("test revoke disconnect");

        assert_eq!(
            pending.wait_until(deadline).await,
            Err(LeaseRevokeDeliveryError::DeliveryUnknown(
                "test revoke disconnect".into()
            ))
        );
        assert_eq!(
            registry.resolve(applied_revoke_ack(revoke)),
            LeaseRevokeAckResolution::Late(LeaseRevokeAckTerminal::Disconnected)
        );
    }

    #[tokio::test]
    async fn unapplied_lease_revoke_never_queues_an_ack() {
        let (controls, mut received) = mpsc::channel(1);
        let outbound = OutboundSender::new(controls);
        let mut input = InputReceiver::new(InputBackendMode::Disabled, Some(Id128(2))).unwrap();

        let error = acknowledge_lease_revoke(
            &outbound,
            "127.0.0.1:41000".parse().unwrap(),
            "test",
            &mut input,
            acknowledged_revoke(),
        )
        .await
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("refusing to acknowledge an unapplied input lease revoke")
        );
        assert!(received.try_recv().is_err());
    }

    #[tokio::test]
    async fn abort_peer_disconnects_registry_before_connection_close() {
        let (controls, _received) = mpsc::channel(1);
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        let mut pending = outbound
            .input_acks
            .register(InputAckKey::from(&event), deadline)
            .unwrap();
        pending.may_have_been_sent = true;
        outbound.abort_peer("test delivery unknown");
        assert_eq!(
            pending.wait_until(deadline).await,
            Err(InputDeliveryError::DeliveryUnknown(
                "test delivery unknown".into()
            ))
        );
        assert!(matches!(
            outbound
                .input_acks
                .register(InputAckKey::from(&event), deadline),
            Err(InputDeliveryError::DefinitelyNotSent(reason))
                if reason == "test delivery unknown"
        ));
    }

    #[tokio::test]
    async fn writer_confirmation_deadline_cancels_the_queued_send_gate() {
        let (controls, mut received) = mpsc::channel(1);
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move {
                send_input_confirmed_with_timeout(&outbound, event, Duration::from_millis(10)).await
            })
        };
        let control = received.recv().await.unwrap();
        let gate = control.input_gate.clone().unwrap();
        assert!(matches!(
            sender.await.unwrap(),
            Err(InputDeliveryError::DeliveryUnknown(_))
        ));
        assert!(gate.is_cancelled());
        assert!(tokio::time::Instant::now() >= gate.deadline);
        drop(control);
    }

    #[tokio::test]
    async fn failure_after_queueing_is_unknown_and_same_identity_cannot_be_resent() {
        let (controls, mut received) = mpsc::channel(2);
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move { send_input_confirmed(&outbound, event).await })
        };
        let control = received.recv().await.unwrap();
        control
            .sent
            .unwrap()
            .send(Err(OutboundSendError(
                "connection closed after remote apply".into(),
            )))
            .unwrap();
        let error = sender.await.unwrap().unwrap_err();
        assert!(matches!(error, InputDeliveryError::DeliveryUnknown(_)));
        assert!(!error.is_safe_to_retry());
        assert_eq!(
            outbound.input_acks.resolve(applied_ack(event)),
            InputAckResolution::Late(InputAckTerminal::DeliveryUnknown)
        );
        assert_eq!(
            send_input_confirmed(&outbound, event).await,
            Err(InputDeliveryError::DuplicateIdentity)
        );
        assert!(received.try_recv().is_err());
    }

    #[tokio::test]
    async fn timed_out_input_keeps_a_bounded_late_ack_tombstone() {
        let (controls, mut received) = mpsc::channel(2);
        let outbound = OutboundSender::new(controls);
        let event = acknowledged_event();
        let sender = {
            let outbound = outbound.clone();
            tokio::spawn(async move {
                send_input_confirmed_with_timeout(&outbound, event, Duration::from_millis(10)).await
            })
        };
        receive_and_confirm_local_send(&mut received).await;
        assert!(matches!(
            sender.await.unwrap(),
            Err(InputDeliveryError::DeliveryUnknown(_))
        ));
        assert_eq!(
            outbound.input_acks.resolve(applied_ack(event)),
            InputAckResolution::Late(InputAckTerminal::DeadlineExpired)
        );
        assert!(outbound.input_acks.lock().tombstones.len() <= MAX_INPUT_ACK_TOMBSTONES);
        assert_eq!(
            send_input_confirmed(&outbound, event).await,
            Err(InputDeliveryError::DuplicateIdentity)
        );
        assert!(received.try_recv().is_err());
    }

    #[test]
    fn tombstone_capacity_evicts_oldest_completed_input_identity() {
        let registry = InputAckRegistry::default();
        let mut event = acknowledged_event();
        for sequence in 1..=(MAX_INPUT_ACK_TOMBSTONES as u64 + 1) {
            event.sequence = sequence;
            let _pending = registry
                .register(
                    InputAckKey::from(&event),
                    tokio::time::Instant::now() + Duration::from_secs(1),
                )
                .unwrap();
            assert_eq!(
                registry.resolve(applied_ack(event)),
                InputAckResolution::Delivered
            );
        }
        assert_eq!(registry.lock().tombstones.len(), MAX_INPUT_ACK_TOMBSTONES);
        event.sequence = 1;
        assert_eq!(
            registry.resolve(applied_ack(event)),
            InputAckResolution::Unmatched
        );
        event.sequence = MAX_INPUT_ACK_TOMBSTONES as u64 + 1;
        assert_eq!(
            registry.resolve(applied_ack(event)),
            InputAckResolution::Late(InputAckTerminal::RemoteAck(InputAppliedResult::Applied))
        );
    }

    fn applied_ack(event: InputEvent) -> InputAppliedAck {
        InputAppliedAck {
            lease_generation: event.lease_generation,
            target_device: event.target_device,
            event_sequence: event.sequence,
            result: InputAppliedResult::Applied,
        }
    }
}
