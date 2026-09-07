#![cfg_attr(not(target_os = "linux"), allow(dead_code, unused_imports))]

#[cfg(target_os = "linux")]
mod linux_cli {
    use std::{
        collections::BTreeMap,
        env,
        ffi::OsString,
        fmt,
        fs::File,
        io::{self, Read, Write},
        os::fd::OwnedFd,
        path::{Component, Path, PathBuf},
        process::ExitCode,
        time::{SystemTime, UNIX_EPOCH},
    };

    use rustix::fs::{
        AtFlags, FileType, FlockOperation, Mode, OFlags, RenameFlags, flistxattr, flock, fstat,
        fsync, open, openat, renameat_with, statat, unlinkat,
    };
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use time::{OffsetDateTime, format_description::well_known::Rfc3339};
    use viewflow_deployment_marker::{
        DeploymentMarkerStore, DeploymentQuarantineMarker, LINUX_DEPLOYMENT_MARKER_PARENT,
        LINUX_DEPLOYMENT_MARKER_PATH, MarkerError, MarkerFingerprint, validate_operation_id,
    };

    const EX_USAGE: u8 = 64;
    const EX_DATAERR: u8 = 65;
    const EX_NOINPUT: u8 = 66;
    const EX_SOFTWARE: u8 = 70;
    const EX_CANTCREAT: u8 = 73;
    const EX_IOERR: u8 = 74;
    const EX_NOPERM: u8 = 77;
    const EX_CONFIG: u8 = 78;
    const LOCK_FILE_NAME: &str = ".deployment-quarantine.v1.lock";
    const RELEASE_CLAIM_FILE_NAME: &str = "deployment-quarantine.v1.release-claim";
    const RELEASE_RECEIPT_MAGIC: [u8; 8] = *b"VFDQR001";
    const RELEASE_RECEIPT_SIZE: usize = 352;
    const RELEASE_RECEIPT_PREFIX: &str = ".deployment-quarantine.v1.release-receipt.";
    const RELEASE_RECEIPT_SUFFIX: &str = ".v1";
    const RELEASE_RETIRED_PREFIX: &str = ".deployment-quarantine.v1.release-retired.";
    const ABORT_CLAIM_FILE_NAME: &str = "deployment-quarantine.v1.abort-claim";
    const ABORT_RECEIPT_MAGIC: [u8; 8] = *b"VFDQA001";
    const ABORT_RECEIPT_SIZE: usize = 384;
    const ABORT_RECEIPT_PREFIX: &str = ".deployment-quarantine.v1.abort-receipt.";
    const ABORT_RECEIPT_SUFFIX: &str = ".v1";
    const ABORT_RETIRED_PREFIX: &str = ".deployment-quarantine.v1.abort-retired.";
    const MAX_AUTHORIZATION_SIZE: usize = 65_536;
    const OWNER_MODE: u32 = 0o600;
    const PARENT_MODE: u32 = 0o700;

    #[derive(Clone, Debug, Eq, PartialEq)]
    enum Command {
        Publish(PublishArgs),
        Release(ReleaseArgs),
        Abort(AbortArgs),
        QueryRelease(ReleaseArgs),
        QueryAbort(AbortArgs),
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct PublishArgs {
        operation_id: String,
        source_display_id: [u8; 16],
        target_device_id: [u8; 16],
        coordinator_instance_id: [u8; 16],
        marker_generation: u64,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct ReleaseArgs {
        operation_id: String,
        coordinator_instance_id: [u8; 16],
        marker_generation: u64,
        marker_sha256: [u8; 32],
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct AbortArgs {
        release: ReleaseArgs,
        authorization_path: PathBuf,
        authorization_sha256: [u8; 32],
    }

    #[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
    #[serde(untagged)]
    enum AbortAuthorization {
        RestoredV1(AbortAuthorizationV1),
        PreMutationV2(AbortAuthorizationV2),
        EarlyGateV3(AbortAuthorizationV3),
        PostPermitRollbackV5(AbortAuthorizationV5),
        PostForceRollbackV7(AbortAuthorizationV7),
    }

    #[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    #[allow(clippy::struct_excessive_bools)] // Frozen external receipt uses exact JSON booleans.
    struct AbortAuthorizationV1 {
        schema_version: u8,
        state: String,
        operation_id: String,
        coordinator_instance_id: String,
        marker_generation: String,
        marker_sha256: String,
        authorization_receipt_path: String,
        marker_handoff_receipt_sha256: String,
        deployment_publish_receipt_sha256: String,
        linux_frozen_evidence_sha256: String,
        windows_force_envelope_sha256: String,
        windows_migration_receipt_sha256: String,
        windows_claim_resolution_sha256: String,
        old_linux_viewflowd_sha256: String,
        old_linux_deskflow_sha256: String,
        old_linux_deskflow_core_sha256: String,
        old_windows_viewflowd_sha256: String,
        old_windows_wrapper_sha256: String,
        linux_v13_started_receipt_sha256: String,
        windows_v13_started_receipt_sha256: String,
        authenticated_v13_peer_receipt_sha256: String,
        initial_force_release_executed: bool,
        second_force_release_executed: bool,
        rollback_token_consumed: bool,
        protocol_2_1: bool,
    }

    #[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct AbortAuthorizationV2 {
        schema_version: u8,
        state: String,
        operation_id: String,
        coordinator_instance_id: String,
        marker_generation: String,
        marker_sha256: String,
        authorization_receipt_path: String,
        marker_handoff_receipt_sha256: String,
        deployment_publish_receipt_sha256: String,
        linux_frozen_evidence_sha256: String,
        installer_exit_receipt_sha256: String,
        windows_stop_evidence_sha256: String,
        pre_mutation_retry_receipt_sha256: String,
        windows_live_proof_sha256: String,
        old_linux_viewflowd_sha256: String,
        old_linux_deskflow_sha256: String,
        old_linux_deskflow_core_sha256: String,
        old_windows_viewflowd_sha256: String,
        old_windows_wrapper_sha256: String,
        old_windows_task_xml_sha256: String,
        old_windows_rollback_sha256: String,
        linux_v13_started_receipt_sha256: String,
        windows_v13_started_receipt_sha256: String,
        authenticated_v13_peer_receipt_sha256: String,
        initial_force_release_executed: bool,
        rollback_performed: bool,
        windows_rollback_receipt_sha256: Option<String>,
        protocol_2_1: bool,
    }

    #[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    #[allow(clippy::struct_excessive_bools)] // Frozen external receipt uses exact JSON booleans.
    struct AbortAuthorizationV3 {
        schema_version: u8,
        state: String,
        operation_id: String,
        coordinator_instance_id: String,
        marker_generation: String,
        marker_sha256: String,
        authorization_receipt_path: String,
        coordinator_terminal_state_sha256: String,
        coordinator_failure_phase: Option<String>,
        coordinator_mutation_possible: bool,
        marker_handoff_receipt_sha256: String,
        deployment_publish_receipt_sha256: String,
        linux_frozen_evidence_sha256: String,
        bootstrap_request_sha256: String,
        windows_stop_evidence_sha256: String,
        windows_live_proof_sha256: String,
        old_linux_viewflowd_sha256: String,
        old_linux_deskflow_sha256: String,
        old_linux_deskflow_core_sha256: String,
        old_windows_viewflowd_sha256: String,
        old_windows_wrapper_sha256: String,
        old_windows_task_xml_sha256: String,
        old_windows_rollback_sha256: String,
        linux_v13_started_receipt_sha256: String,
        windows_v13_started_receipt_sha256: String,
        authenticated_v13_peer_receipt_sha256: String,
        windows_bootstrap_worker_created: bool,
        windows_new_operation_root_present: bool,
        windows_new_task_present: bool,
        windows_installer_process_count: u32,
        mutation_permit_published: bool,
        force_release_executed: bool,
        rollback_performed: bool,
        windows_rollback_receipt_sha256: Option<String>,
        initial_force_release_executed: bool,
        linux_deskflow_started: bool,
        input_producer_count: u32,
        protocol_2_1: bool,
    }

    #[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    #[allow(clippy::struct_excessive_bools)] // Frozen external receipt uses exact JSON booleans.
    struct AbortAuthorizationV5 {
        schema_version: u8,
        state: String,
        operation_id: String,
        coordinator_instance_id: String,
        marker_generation: String,
        marker_sha256: String,
        authorization_receipt_path: String,
        coordinator_terminal_state_sha256: String,
        coordinator_failure_phase: String,
        coordinator_mutation_possible: bool,
        schema1_handoff_lineage_receipt_sha256: String,
        marker_handoff_receipt_sha256: String,
        deployment_publish_receipt_sha256: String,
        linux_frozen_evidence_sha256: String,
        bootstrap_request_sha256: String,
        windows_prepared_receipt_sha256: String,
        mutation_permit_receipt_sha256: String,
        installer_exit_receipt_sha256: String,
        windows_stop_evidence_sha256: String,
        recovery_bundle_sha256: String,
        linux_deactivation_proof_sha256: String,
        linux_deactivation_transcript_sha256: String,
        windows_rollback_receipt_sha256: String,
        old_linux_viewflowd_sha256: String,
        old_linux_deskflow_sha256: String,
        old_linux_deskflow_core_sha256: String,
        old_windows_viewflowd_sha256: String,
        old_windows_wrapper_sha256: String,
        linux_v13_started_receipt_sha256: String,
        windows_v13_started_receipt_sha256: String,
        authenticated_v13_peer_receipt_sha256: String,
        mutation_permit_published: bool,
        force_release_executed: bool,
        rollback_performed: bool,
        initial_force_release_executed: bool,
        second_force_release_executed: bool,
        rollback_token_consumed: bool,
        protocol_2_1: bool,
    }

    #[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    #[allow(clippy::struct_excessive_bools)] // Frozen external receipt uses exact JSON booleans.
    struct AbortAuthorizationV7 {
        schema_version: u8,
        state: String,
        operation_id: String,
        coordinator_instance_id: String,
        marker_generation: String,
        marker_sha256: String,
        authorization_receipt_path: String,
        coordinator_terminal_state_sha256: String,
        coordinator_failure_phase: String,
        coordinator_mutation_possible: bool,
        fresh_operation_lineage_receipt_sha256: String,
        marker_handoff_receipt_sha256: String,
        deployment_publish_receipt_sha256: String,
        linux_frozen_evidence_sha256: String,
        bootstrap_request_sha256: String,
        windows_prepared_receipt_sha256: String,
        mutation_permit_receipt_sha256: String,
        windows_force_envelope_sha256: String,
        windows_stop_evidence_sha256: String,
        recovery_bundle_sha256: String,
        linux_deactivation_proof_sha256: String,
        linux_deactivation_transcript_sha256: String,
        windows_rollback_receipt_sha256: String,
        old_linux_viewflowd_sha256: String,
        old_linux_deskflow_sha256: String,
        old_linux_deskflow_core_sha256: String,
        old_windows_viewflowd_sha256: String,
        old_windows_wrapper_sha256: String,
        linux_v13_started_receipt_sha256: String,
        windows_v13_started_receipt_sha256: String,
        authenticated_v13_peer_receipt_sha256: String,
        mutation_permit_published: bool,
        force_release_executed: bool,
        rollback_performed: bool,
        linux_stage_committed: bool,
        windows_install_committed: bool,
        windows_installer_exit_present: bool,
        initial_force_release_executed: bool,
        second_force_release_executed: bool,
        rollback_token_consumed: bool,
        protocol_2_1: bool,
    }

    #[derive(Debug)]
    enum CliError {
        Usage(String),
        Clock(String),
        Marker(MarkerError),
        Output(io::Error),
    }

    impl CliError {
        const fn exit_code(&self) -> u8 {
            match self {
                Self::Usage(_) => EX_USAGE,
                Self::Clock(_) => EX_SOFTWARE,
                Self::Output(_) => EX_IOERR,
                Self::Marker(error) => match error {
                    MarkerError::MarkerMissing => EX_NOINPUT,
                    MarkerError::MarkerAlreadyExists => EX_CANTCREAT,
                    MarkerError::AuthorizationMismatch => EX_NOPERM,
                    MarkerError::PathMustBeAbsolute
                    | MarkerError::UnsafeParent
                    | MarkerError::UnsafeMarker => EX_CONFIG,
                    MarkerError::Io { .. } => EX_IOERR,
                    _ => EX_DATAERR,
                },
            }
        }
    }

    impl fmt::Display for CliError {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            match self {
                Self::Usage(message) | Self::Clock(message) => formatter.write_str(message),
                Self::Marker(error) => write!(formatter, "{error}"),
                Self::Output(error) => write!(formatter, "write strict JSON receipt: {error}"),
            }
        }
    }

    impl From<MarkerError> for CliError {
        fn from(value: MarkerError) -> Self {
            Self::Marker(value)
        }
    }

    pub fn main() -> ExitCode {
        match run(env::args_os().collect()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("viewflow-deployment-marker: {error}");
                ExitCode::from(error.exit_code())
            }
        }
    }

    fn run(arguments: Vec<OsString>) -> Result<(), CliError> {
        let command = parse_command(arguments)?;
        let expected_uid = rustix::process::geteuid().as_raw();
        let store = DeploymentMarkerStore::new(LINUX_DEPLOYMENT_MARKER_PARENT, expected_uid);
        let release_store =
            ReleaseTransactionStore::new(LINUX_DEPLOYMENT_MARKER_PARENT, expected_uid);
        match &command {
            Command::Publish(arguments) => publish(&store, &release_store, arguments),
            Command::Release(arguments) => release(&release_store, arguments),
            Command::Abort(arguments) => abort(&release_store, arguments),
            Command::QueryRelease(arguments) => query_release(&release_store, arguments),
            Command::QueryAbort(arguments) => query_abort(&release_store, arguments),
        }
    }

    fn publish(
        store: &DeploymentMarkerStore,
        release_store: &ReleaseTransactionStore,
        arguments: &PublishArgs,
    ) -> Result<(), CliError> {
        let guard = release_store.lock(FlockOperation::LockExclusive)?;
        guard.require_claim_absent()?;
        let created_at_unix_ms = unix_milliseconds()?;
        let marker = DeploymentQuarantineMarker {
            operation_id: arguments.operation_id.clone(),
            source_display: arguments.source_display_id,
            target_device: arguments.target_device_id,
            coordinator_instance: arguments.coordinator_instance_id,
            created_at_unix_ms,
            generation: arguments.marker_generation,
        };
        let fingerprint = store.publish(&marker)?;
        write_receipt(&publish_receipt(
            arguments,
            &fingerprint,
            created_at_unix_ms,
        )?)
    }

    fn publish_receipt(
        arguments: &PublishArgs,
        fingerprint: &MarkerFingerprint,
        created_at_unix_ms: u64,
    ) -> Result<serde_json::Value, CliError> {
        Ok(json!({
            "schema_version": 1,
            "state": "deployment-quarantine-published",
            "protocol_version": "2.1",
            "operation_id": arguments.operation_id,
            "source_display_id": format_uuid(arguments.source_display_id),
            "target_device_id": format_uuid(arguments.target_device_id),
            "coordinator_instance_id": format_uuid(arguments.coordinator_instance_id),
            "marker_generation": arguments.marker_generation.to_string(),
            "marker_path": LINUX_DEPLOYMENT_MARKER_PATH,
            "marker_sha256": fingerprint.content_sha256_hex(),
            "created_at_unix_ms": created_at_unix_ms.to_string(),
            "created_at_utc": format_unix_milliseconds(created_at_unix_ms)?,
        }))
    }

    fn release(store: &ReleaseTransactionStore, arguments: &ReleaseArgs) -> Result<(), CliError> {
        let committed_at_unix_ms = unix_milliseconds()?;
        let result = store.release(arguments, committed_at_unix_ms, None)?;
        write_receipt(&release_receipt(arguments, &result.proof, result.replayed)?)
    }

    fn release_receipt(
        arguments: &ReleaseArgs,
        proof: &ReleaseProof,
        replayed: bool,
    ) -> Result<serde_json::Value, CliError> {
        Ok(json!({
            "schema_version": 2,
            "state": "deployment-quarantine-released",
            "protocol_version": "2.1",
            "operation_id": arguments.operation_id,
            "source_display_id": format_uuid(proof.marker.source_display),
            "target_device_id": format_uuid(proof.marker.target_device),
            "coordinator_instance_id": format_uuid(arguments.coordinator_instance_id),
            "marker_generation": arguments.marker_generation.to_string(),
            "marker_path": LINUX_DEPLOYMENT_MARKER_PATH,
            "release_claim_path": format!("{LINUX_DEPLOYMENT_MARKER_PARENT}/{RELEASE_CLAIM_FILE_NAME}"),
            "release_receipt_path": format!("{LINUX_DEPLOYMENT_MARKER_PARENT}/{}", receipt_name(&arguments.marker_sha256)),
            "released_marker_sha256": hex_lower(&arguments.marker_sha256),
            "marker_created_at_unix_ms": proof.marker.created_at_unix_ms.to_string(),
            "release_committed_at_unix_ms": proof.committed_at_unix_ms.to_string(),
            "release_committed_at_utc": format_unix_milliseconds(proof.committed_at_unix_ms)?,
            "release_point": "release-claim-unlink-and-parent-directory-fsync",
            "replayed": replayed,
        }))
    }

    fn abort(store: &ReleaseTransactionStore, arguments: &AbortArgs) -> Result<(), CliError> {
        let authorization = load_abort_authorization(arguments)?;
        let committed_at_unix_ms = unix_milliseconds()?;
        let result = store.abort(arguments, committed_at_unix_ms, None)?;
        write_receipt(&abort_receipt(
            arguments,
            &authorization,
            &result.proof,
            result.replayed,
        )?)
    }

    #[allow(clippy::too_many_lines)] // Exact external receipt branches remain auditable together.
    fn abort_receipt(
        arguments: &AbortArgs,
        authorization: &AbortAuthorization,
        proof: &AbortProof,
        replayed: bool,
    ) -> Result<serde_json::Value, CliError> {
        let common = json!({
            "schema_version": 1,
            "state": "deployment-quarantine-aborted",
            "protocol_version": "1.3",
            "protocol_2_1": false,
            "operation_id": arguments.release.operation_id,
            "source_display_id": format_uuid(proof.marker.source_display),
            "target_device_id": format_uuid(proof.marker.target_device),
            "coordinator_instance_id": format_uuid(arguments.release.coordinator_instance_id),
            "marker_generation": arguments.release.marker_generation.to_string(),
            "marker_path": LINUX_DEPLOYMENT_MARKER_PATH,
            "abort_claim_path": format!("{LINUX_DEPLOYMENT_MARKER_PARENT}/{ABORT_CLAIM_FILE_NAME}"),
            "abort_receipt_path": format!("{LINUX_DEPLOYMENT_MARKER_PARENT}/{}", abort_receipt_name(&arguments.release.marker_sha256, &arguments.authorization_sha256)),
            "abort_authorization_path": arguments.authorization_path.to_string_lossy(),
            "abort_authorization_sha256": hex_lower(&arguments.authorization_sha256),
            "aborted_marker_sha256": hex_lower(&arguments.release.marker_sha256),
            "marker_created_at_unix_ms": proof.marker.created_at_unix_ms.to_string(),
            "abort_committed_at_unix_ms": proof.committed_at_unix_ms.to_string(),
            "abort_committed_at_utc": format_unix_milliseconds(proof.committed_at_unix_ms)?,
            "abort_point": "abort-claim-unlink-and-parent-directory-fsync",
            "deployment_release_claimed": false,
            "replayed": replayed,
        });
        let mut object = common.as_object().cloned().ok_or_else(|| {
            CliError::Output(io::Error::other(
                "abort receipt common value is not an object",
            ))
        })?;
        match authorization {
            AbortAuthorization::RestoredV1(value) => {
                object.insert(
                    "initial_force_release_executed".to_owned(),
                    json!(value.initial_force_release_executed),
                );
                object.insert(
                    "second_force_release_executed".to_owned(),
                    json!(value.second_force_release_executed),
                );
                object.insert(
                    "rollback_token_consumed".to_owned(),
                    json!(value.rollback_token_consumed),
                );
            }
            AbortAuthorization::PreMutationV2(value) => {
                object.insert("schema_version".to_owned(), json!(2));
                object.insert(
                    "initial_force_release_executed".to_owned(),
                    json!(value.initial_force_release_executed),
                );
                object.insert(
                    "rollback_performed".to_owned(),
                    json!(value.rollback_performed),
                );
                object.insert(
                    "windows_rollback_receipt_sha256".to_owned(),
                    serde_json::Value::Null,
                );
            }
            AbortAuthorization::EarlyGateV3(value) => {
                object.insert("schema_version".to_owned(), json!(3));
                object.insert("authorization_state".to_owned(), json!(value.state));
                object.insert(
                    "coordinator_failure_phase".to_owned(),
                    serde_json::Value::Null,
                );
                object.insert(
                    "coordinator_mutation_possible".to_owned(),
                    json!(value.coordinator_mutation_possible),
                );
                for (name, hash) in [
                    (
                        "coordinator_terminal_state_sha256",
                        &value.coordinator_terminal_state_sha256,
                    ),
                    (
                        "marker_handoff_receipt_sha256",
                        &value.marker_handoff_receipt_sha256,
                    ),
                    (
                        "deployment_publish_receipt_sha256",
                        &value.deployment_publish_receipt_sha256,
                    ),
                    (
                        "linux_frozen_evidence_sha256",
                        &value.linux_frozen_evidence_sha256,
                    ),
                    ("bootstrap_request_sha256", &value.bootstrap_request_sha256),
                    (
                        "windows_stop_evidence_sha256",
                        &value.windows_stop_evidence_sha256,
                    ),
                    (
                        "windows_live_proof_sha256",
                        &value.windows_live_proof_sha256,
                    ),
                    (
                        "linux_v13_started_receipt_sha256",
                        &value.linux_v13_started_receipt_sha256,
                    ),
                    (
                        "windows_v13_started_receipt_sha256",
                        &value.windows_v13_started_receipt_sha256,
                    ),
                    (
                        "authenticated_v13_peer_receipt_sha256",
                        &value.authenticated_v13_peer_receipt_sha256,
                    ),
                ] {
                    object.insert(name.to_owned(), json!(hash));
                }
                object.insert(
                    "windows_bootstrap_worker_created".to_owned(),
                    json!(value.windows_bootstrap_worker_created),
                );
                object.insert(
                    "windows_new_operation_root_present".to_owned(),
                    json!(value.windows_new_operation_root_present),
                );
                object.insert(
                    "windows_new_task_present".to_owned(),
                    json!(value.windows_new_task_present),
                );
                object.insert(
                    "windows_installer_process_count".to_owned(),
                    json!(value.windows_installer_process_count),
                );
                object.insert(
                    "mutation_permit_published".to_owned(),
                    json!(value.mutation_permit_published),
                );
                object.insert(
                    "force_release_executed".to_owned(),
                    json!(value.force_release_executed),
                );
                object.insert(
                    "rollback_performed".to_owned(),
                    json!(value.rollback_performed),
                );
                object.insert(
                    "windows_rollback_receipt_sha256".to_owned(),
                    serde_json::Value::Null,
                );
                object.insert(
                    "initial_force_release_executed".to_owned(),
                    json!(value.initial_force_release_executed),
                );
                object.insert(
                    "linux_deskflow_started".to_owned(),
                    json!(value.linux_deskflow_started),
                );
                object.insert(
                    "input_producer_count".to_owned(),
                    json!(value.input_producer_count),
                );
            }
            AbortAuthorization::PostPermitRollbackV5(value) => {
                object.insert("schema_version".to_owned(), json!(5));
                object.insert("authorization_state".to_owned(), json!(value.state));
                object.insert(
                    "abort_point".to_owned(),
                    json!("abort-claim-atomic-retire-and-parent-directory-fsync"),
                );
                object.insert(
                    "coordinator_failure_phase".to_owned(),
                    json!(value.coordinator_failure_phase),
                );
                object.insert(
                    "coordinator_mutation_possible".to_owned(),
                    json!(value.coordinator_mutation_possible),
                );
                for (name, hash) in [
                    (
                        "coordinator_terminal_state_sha256",
                        &value.coordinator_terminal_state_sha256,
                    ),
                    (
                        "schema1_handoff_lineage_receipt_sha256",
                        &value.schema1_handoff_lineage_receipt_sha256,
                    ),
                    (
                        "marker_handoff_receipt_sha256",
                        &value.marker_handoff_receipt_sha256,
                    ),
                    (
                        "deployment_publish_receipt_sha256",
                        &value.deployment_publish_receipt_sha256,
                    ),
                    (
                        "linux_frozen_evidence_sha256",
                        &value.linux_frozen_evidence_sha256,
                    ),
                    ("bootstrap_request_sha256", &value.bootstrap_request_sha256),
                    (
                        "windows_prepared_receipt_sha256",
                        &value.windows_prepared_receipt_sha256,
                    ),
                    (
                        "mutation_permit_receipt_sha256",
                        &value.mutation_permit_receipt_sha256,
                    ),
                    (
                        "installer_exit_receipt_sha256",
                        &value.installer_exit_receipt_sha256,
                    ),
                    (
                        "windows_stop_evidence_sha256",
                        &value.windows_stop_evidence_sha256,
                    ),
                    ("recovery_bundle_sha256", &value.recovery_bundle_sha256),
                    (
                        "linux_deactivation_proof_sha256",
                        &value.linux_deactivation_proof_sha256,
                    ),
                    (
                        "linux_deactivation_transcript_sha256",
                        &value.linux_deactivation_transcript_sha256,
                    ),
                    (
                        "windows_rollback_receipt_sha256",
                        &value.windows_rollback_receipt_sha256,
                    ),
                    (
                        "linux_v13_started_receipt_sha256",
                        &value.linux_v13_started_receipt_sha256,
                    ),
                    (
                        "windows_v13_started_receipt_sha256",
                        &value.windows_v13_started_receipt_sha256,
                    ),
                    (
                        "authenticated_v13_peer_receipt_sha256",
                        &value.authenticated_v13_peer_receipt_sha256,
                    ),
                ] {
                    object.insert(name.to_owned(), json!(hash));
                }
                object.insert(
                    "mutation_permit_published".to_owned(),
                    json!(value.mutation_permit_published),
                );
                object.insert(
                    "force_release_executed".to_owned(),
                    json!(value.force_release_executed),
                );
                object.insert(
                    "rollback_performed".to_owned(),
                    json!(value.rollback_performed),
                );
                object.insert(
                    "initial_force_release_executed".to_owned(),
                    json!(value.initial_force_release_executed),
                );
                object.insert(
                    "second_force_release_executed".to_owned(),
                    json!(value.second_force_release_executed),
                );
                object.insert(
                    "rollback_token_consumed".to_owned(),
                    json!(value.rollback_token_consumed),
                );
            }
            AbortAuthorization::PostForceRollbackV7(value) => {
                object.insert("schema_version".to_owned(), json!(7));
                object.insert("authorization_state".to_owned(), json!(value.state));
                object.insert(
                    "abort_point".to_owned(),
                    json!("abort-claim-atomic-retire-and-parent-directory-fsync"),
                );
                object.insert(
                    "coordinator_failure_phase".to_owned(),
                    json!(value.coordinator_failure_phase),
                );
                object.insert(
                    "coordinator_mutation_possible".to_owned(),
                    json!(value.coordinator_mutation_possible),
                );
                for (name, hash) in [
                    (
                        "coordinator_terminal_state_sha256",
                        &value.coordinator_terminal_state_sha256,
                    ),
                    (
                        "fresh_operation_lineage_receipt_sha256",
                        &value.fresh_operation_lineage_receipt_sha256,
                    ),
                    (
                        "marker_handoff_receipt_sha256",
                        &value.marker_handoff_receipt_sha256,
                    ),
                    (
                        "deployment_publish_receipt_sha256",
                        &value.deployment_publish_receipt_sha256,
                    ),
                    (
                        "linux_frozen_evidence_sha256",
                        &value.linux_frozen_evidence_sha256,
                    ),
                    ("bootstrap_request_sha256", &value.bootstrap_request_sha256),
                    (
                        "windows_prepared_receipt_sha256",
                        &value.windows_prepared_receipt_sha256,
                    ),
                    (
                        "mutation_permit_receipt_sha256",
                        &value.mutation_permit_receipt_sha256,
                    ),
                    (
                        "windows_force_envelope_sha256",
                        &value.windows_force_envelope_sha256,
                    ),
                    (
                        "windows_stop_evidence_sha256",
                        &value.windows_stop_evidence_sha256,
                    ),
                    ("recovery_bundle_sha256", &value.recovery_bundle_sha256),
                    (
                        "linux_deactivation_proof_sha256",
                        &value.linux_deactivation_proof_sha256,
                    ),
                    (
                        "linux_deactivation_transcript_sha256",
                        &value.linux_deactivation_transcript_sha256,
                    ),
                    (
                        "windows_rollback_receipt_sha256",
                        &value.windows_rollback_receipt_sha256,
                    ),
                    (
                        "linux_v13_started_receipt_sha256",
                        &value.linux_v13_started_receipt_sha256,
                    ),
                    (
                        "windows_v13_started_receipt_sha256",
                        &value.windows_v13_started_receipt_sha256,
                    ),
                    (
                        "authenticated_v13_peer_receipt_sha256",
                        &value.authenticated_v13_peer_receipt_sha256,
                    ),
                ] {
                    object.insert(name.to_owned(), json!(hash));
                }
                for (name, flag) in [
                    ("mutation_permit_published", value.mutation_permit_published),
                    ("force_release_executed", value.force_release_executed),
                    ("rollback_performed", value.rollback_performed),
                    ("linux_stage_committed", value.linux_stage_committed),
                    ("windows_install_committed", value.windows_install_committed),
                    (
                        "windows_installer_exit_present",
                        value.windows_installer_exit_present,
                    ),
                    (
                        "initial_force_release_executed",
                        value.initial_force_release_executed,
                    ),
                    (
                        "second_force_release_executed",
                        value.second_force_release_executed,
                    ),
                    ("rollback_token_consumed", value.rollback_token_consumed),
                ] {
                    object.insert(name.to_owned(), json!(flag));
                }
            }
        }
        Ok(serde_json::Value::Object(object))
    }

    fn query_release(
        store: &ReleaseTransactionStore,
        arguments: &ReleaseArgs,
    ) -> Result<(), CliError> {
        let state = store.query(arguments)?;
        let value = match state {
            ReleaseQuery::Active => json!({
                "schema_version": 2,
                "state": "deployment-quarantine-active",
                "protocol_version": "2.1",
                "operation_id": arguments.operation_id,
                "marker_generation": arguments.marker_generation.to_string(),
                "marker_sha256": hex_lower(&arguments.marker_sha256),
            }),
            ReleaseQuery::Claimed => json!({
                "schema_version": 2,
                "state": "deployment-quarantine-release-claimed",
                "protocol_version": "2.1",
                "operation_id": arguments.operation_id,
                "marker_generation": arguments.marker_generation.to_string(),
                "marker_sha256": hex_lower(&arguments.marker_sha256),
            }),
            ReleaseQuery::CommittedPendingRelease(proof) => json!({
                "schema_version": 2,
                "state": "deployment-quarantine-release-committed-pending-release",
                "protocol_version": "2.1",
                "operation_id": arguments.operation_id,
                "marker_generation": arguments.marker_generation.to_string(),
                "marker_sha256": hex_lower(&arguments.marker_sha256),
                "release_committed_at_unix_ms": proof.committed_at_unix_ms.to_string(),
            }),
            ReleaseQuery::Released(proof) => release_receipt(arguments, &proof, true)?,
        };
        write_receipt(&value)
    }

    fn query_abort(store: &ReleaseTransactionStore, arguments: &AbortArgs) -> Result<(), CliError> {
        let authorization = load_abort_authorization(arguments)?;
        let state = store.query_abort(arguments)?;
        let value = match state {
            AbortQuery::Active => json!({
                "schema_version": 1,
                "state": "deployment-quarantine-active",
                "protocol_version": "1.3",
                "protocol_2_1": false,
                "operation_id": arguments.release.operation_id,
                "marker_generation": arguments.release.marker_generation.to_string(),
                "marker_sha256": hex_lower(&arguments.release.marker_sha256),
                "abort_authorization_sha256": hex_lower(&arguments.authorization_sha256),
            }),
            AbortQuery::Claimed => json!({
                "schema_version": 1,
                "state": "deployment-quarantine-abort-claimed",
                "protocol_version": "1.3",
                "protocol_2_1": false,
                "operation_id": arguments.release.operation_id,
                "marker_generation": arguments.release.marker_generation.to_string(),
                "marker_sha256": hex_lower(&arguments.release.marker_sha256),
                "abort_authorization_sha256": hex_lower(&arguments.authorization_sha256),
            }),
            AbortQuery::CommittedPendingAbort(proof) => json!({
                "schema_version": 1,
                "state": "deployment-quarantine-abort-committed-pending-abort",
                "protocol_version": "1.3",
                "protocol_2_1": false,
                "operation_id": arguments.release.operation_id,
                "marker_generation": arguments.release.marker_generation.to_string(),
                "marker_sha256": hex_lower(&arguments.release.marker_sha256),
                "abort_authorization_sha256": hex_lower(&arguments.authorization_sha256),
                "abort_committed_at_unix_ms": proof.committed_at_unix_ms.to_string(),
            }),
            AbortQuery::Aborted(proof) => abort_receipt(arguments, &authorization, &proof, true)?,
        };
        write_receipt(&value)
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum ReleaseStopPoint {
        ClaimSync,
        ReceiptSync,
        ClaimRetire,
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum AbortStopPoint {
        ClaimSync,
        ReceiptSync,
        ClaimRetire,
    }

    #[derive(Debug)]
    struct ReleaseResult {
        proof: ReleaseProof,
        replayed: bool,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct ReleaseProof {
        marker: DeploymentQuarantineMarker,
        marker_bytes: [u8; 256],
        marker_sha256: [u8; 32],
        committed_at_unix_ms: u64,
    }

    #[derive(Debug)]
    struct AbortResult {
        proof: AbortProof,
        replayed: bool,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct AbortProof {
        marker: DeploymentQuarantineMarker,
        marker_bytes: [u8; 256],
        marker_sha256: [u8; 32],
        authorization_sha256: [u8; 32],
        committed_at_unix_ms: u64,
    }

    #[derive(Debug, Eq, PartialEq)]
    enum ReleaseQuery {
        Active,
        Claimed,
        CommittedPendingRelease(ReleaseProof),
        Released(ReleaseProof),
    }

    #[derive(Debug, Eq, PartialEq)]
    enum AbortQuery {
        Active,
        Claimed,
        CommittedPendingAbort(AbortProof),
        Aborted(AbortProof),
    }

    #[derive(Clone, Debug)]
    struct ReleaseTransactionStore {
        parent: PathBuf,
        expected_uid: u32,
    }

    impl ReleaseTransactionStore {
        fn new(parent: impl Into<PathBuf>, expected_uid: u32) -> Self {
            Self {
                parent: parent.into(),
                expected_uid,
            }
        }

        fn lock(&self, operation: FlockOperation) -> Result<ReleaseGuard, MarkerError> {
            if !self.parent.is_absolute() {
                return Err(MarkerError::PathMustBeAbsolute);
            }
            let parent = open(
                &self.parent,
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            )
            .map_err(|source| marker_io("open deployment marker parent", source))?;
            validate_directory(&parent, self.expected_uid)?;
            let lock = openat(
                &parent,
                LOCK_FILE_NAME,
                OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::RUSR | Mode::WUSR,
            )
            .map_err(|source| marker_io("open deployment marker transaction lock", source))?;
            validate_owner_file(&lock, self.expected_uid, 0)?;
            flock(&lock, operation)
                .map_err(|source| marker_io("lock deployment marker transaction", source))?;
            validate_named_fd(&parent, LOCK_FILE_NAME, &lock)?;
            Ok(ReleaseGuard {
                parent,
                _lock: lock,
                expected_uid: self.expected_uid,
            })
        }

        fn release(
            &self,
            arguments: &ReleaseArgs,
            committed_at_unix_ms: u64,
            stop_after: Option<ReleaseStopPoint>,
        ) -> Result<ReleaseResult, MarkerError> {
            let guard = self.lock(FlockOperation::LockExclusive)?;
            guard.require_named_absent(ABORT_CLAIM_FILE_NAME)?;
            let receipt_name = receipt_name(&arguments.marker_sha256);
            let retired_name = release_retired_name(&arguments.marker_sha256);
            let mut resumed_claim = false;
            let marker_bytes = match guard.load_marker(&retired_name) {
                Ok(bytes) => {
                    guard.require_named_absent(RELEASE_CLAIM_FILE_NAME)?;
                    validate_authorization(&bytes, arguments)?;
                    resumed_claim = true;
                    bytes
                }
                Err(MarkerError::MarkerMissing) => {
                    match guard.load_marker(RELEASE_CLAIM_FILE_NAME) {
                        Ok(bytes) => {
                            validate_authorization(&bytes, arguments)?;
                            resumed_claim = true;
                            bytes
                        }
                        Err(MarkerError::MarkerMissing) => {
                            match guard.load_marker(
                                viewflow_deployment_marker::DEPLOYMENT_MARKER_FILE_NAME,
                            ) {
                                Ok(bytes) => {
                                    validate_authorization(&bytes, arguments)?;
                                    renameat_with(
                                        &guard.parent,
                                        viewflow_deployment_marker::DEPLOYMENT_MARKER_FILE_NAME,
                                        &guard.parent,
                                        RELEASE_CLAIM_FILE_NAME,
                                        RenameFlags::NOREPLACE,
                                    )
                                    .map_err(|source| {
                                        marker_io(
                                            "atomically claim deployment marker for release",
                                            source,
                                        )
                                    })?;
                                    fsync(&guard.parent).map_err(|source| {
                                        marker_io("sync deployment release claim", source)
                                    })?;
                                    let claimed = guard.load_marker(RELEASE_CLAIM_FILE_NAME)?;
                                    if claimed != bytes {
                                        return Err(MarkerError::AuthorizationMismatch);
                                    }
                                    if stop_after == Some(ReleaseStopPoint::ClaimSync) {
                                        return Err(injected_crash("after durable release claim"));
                                    }
                                    bytes
                                }
                                Err(MarkerError::MarkerMissing) => {
                                    let proof = guard.load_receipt(&receipt_name)?;
                                    validate_proof(&proof, arguments)?;
                                    fsync(&guard.parent).map_err(|source| {
                                        marker_io("sync replayed deployment release point", source)
                                    })?;
                                    return Ok(ReleaseResult {
                                        proof,
                                        replayed: true,
                                    });
                                }
                                Err(error) => return Err(error),
                            }
                        }
                        Err(error) => return Err(error),
                    }
                }
                Err(error) => return Err(error),
            };
            let proof = ReleaseProof::new(marker_bytes, committed_at_unix_ms)?;
            validate_proof(&proof, arguments)?;
            let (proof, receipt_replayed) = guard.commit_receipt(&receipt_name, &proof)?;
            if stop_after == Some(ReleaseStopPoint::ReceiptSync) {
                return Err(injected_crash("after durable release receipt"));
            }
            guard.retire_claim(
                RELEASE_CLAIM_FILE_NAME,
                &retired_name,
                &proof.marker_bytes,
                "release",
                stop_after == Some(ReleaseStopPoint::ClaimRetire),
            )?;
            Ok(ReleaseResult {
                proof,
                replayed: resumed_claim && receipt_replayed,
            })
        }

        fn query(&self, arguments: &ReleaseArgs) -> Result<ReleaseQuery, MarkerError> {
            // Query may need to turn an observed post-crash absence into a
            // durable release point with a parent-directory fsync.
            let guard = self.lock(FlockOperation::LockExclusive)?;
            guard.require_named_absent(ABORT_CLAIM_FILE_NAME)?;
            let receipt_name = receipt_name(&arguments.marker_sha256);
            let retired_name = release_retired_name(&arguments.marker_sha256);
            match guard.load_marker(&retired_name) {
                Ok(bytes) => {
                    guard.require_named_absent(RELEASE_CLAIM_FILE_NAME)?;
                    validate_authorization(&bytes, arguments)?;
                    let proof = guard.load_receipt(&receipt_name)?;
                    validate_proof(&proof, arguments)?;
                    Ok(ReleaseQuery::Released(proof))
                }
                Err(MarkerError::MarkerMissing) => {
                    match guard.load_marker(RELEASE_CLAIM_FILE_NAME) {
                        Ok(bytes) => {
                            validate_authorization(&bytes, arguments)?;
                            match guard.load_receipt(&receipt_name) {
                                Ok(proof) => {
                                    validate_proof(&proof, arguments)?;
                                    Ok(ReleaseQuery::CommittedPendingRelease(proof))
                                }
                                Err(MarkerError::MarkerMissing) => Ok(ReleaseQuery::Claimed),
                                Err(error) => Err(error),
                            }
                        }
                        Err(MarkerError::MarkerMissing) => {
                            match guard.load_marker(
                                viewflow_deployment_marker::DEPLOYMENT_MARKER_FILE_NAME,
                            ) {
                                Ok(bytes) => {
                                    validate_authorization(&bytes, arguments)?;
                                    Ok(ReleaseQuery::Active)
                                }
                                Err(MarkerError::MarkerMissing) => {
                                    let proof = guard.load_receipt(&receipt_name)?;
                                    validate_proof(&proof, arguments)?;
                                    fsync(&guard.parent).map_err(|source| {
                                        marker_io("sync queried deployment release point", source)
                                    })?;
                                    Ok(ReleaseQuery::Released(proof))
                                }
                                Err(error) => Err(error),
                            }
                        }
                        Err(error) => Err(error),
                    }
                }
                Err(error) => Err(error),
            }
        }

        fn abort(
            &self,
            arguments: &AbortArgs,
            committed_at_unix_ms: u64,
            stop_after: Option<AbortStopPoint>,
        ) -> Result<AbortResult, MarkerError> {
            let guard = self.lock(FlockOperation::LockExclusive)?;
            guard.require_named_absent(RELEASE_CLAIM_FILE_NAME)?;
            let receipt_name = abort_receipt_name(
                &arguments.release.marker_sha256,
                &arguments.authorization_sha256,
            );
            let retired_name = abort_retired_name(
                &arguments.release.marker_sha256,
                &arguments.authorization_sha256,
            );
            let mut resumed_claim = false;
            let marker_bytes = match guard.load_marker(&retired_name) {
                Ok(bytes) => {
                    guard.require_named_absent(ABORT_CLAIM_FILE_NAME)?;
                    validate_abort_marker_authorization(&bytes, arguments)?;
                    resumed_claim = true;
                    bytes
                }
                Err(MarkerError::MarkerMissing) => match guard.load_marker(ABORT_CLAIM_FILE_NAME) {
                    Ok(bytes) => {
                        validate_abort_marker_authorization(&bytes, arguments)?;
                        resumed_claim = true;
                        bytes
                    }
                    Err(MarkerError::MarkerMissing) => {
                        match guard
                            .load_marker(viewflow_deployment_marker::DEPLOYMENT_MARKER_FILE_NAME)
                        {
                            Ok(bytes) => {
                                validate_abort_marker_authorization(&bytes, arguments)?;
                                renameat_with(
                                    &guard.parent,
                                    viewflow_deployment_marker::DEPLOYMENT_MARKER_FILE_NAME,
                                    &guard.parent,
                                    ABORT_CLAIM_FILE_NAME,
                                    RenameFlags::NOREPLACE,
                                )
                                .map_err(|source| {
                                    marker_io(
                                        "atomically claim deployment marker for abort",
                                        source,
                                    )
                                })?;
                                fsync(&guard.parent).map_err(|source| {
                                    marker_io("sync deployment abort claim", source)
                                })?;
                                let claimed = guard.load_marker(ABORT_CLAIM_FILE_NAME)?;
                                if claimed != bytes {
                                    return Err(MarkerError::AuthorizationMismatch);
                                }
                                if stop_after == Some(AbortStopPoint::ClaimSync) {
                                    return Err(injected_crash("after durable abort claim"));
                                }
                                bytes
                            }
                            Err(MarkerError::MarkerMissing) => {
                                let proof = guard.load_abort_receipt(&receipt_name)?;
                                validate_abort_proof(&proof, arguments)?;
                                fsync(&guard.parent).map_err(|source| {
                                    marker_io("sync replayed deployment abort point", source)
                                })?;
                                return Ok(AbortResult {
                                    proof,
                                    replayed: true,
                                });
                            }
                            Err(error) => return Err(error),
                        }
                    }
                    Err(error) => return Err(error),
                },
                Err(error) => return Err(error),
            };
            let proof = AbortProof::new(
                marker_bytes,
                arguments.authorization_sha256,
                committed_at_unix_ms,
            )?;
            validate_abort_proof(&proof, arguments)?;
            let (proof, receipt_replayed) = guard.commit_abort_receipt(&receipt_name, &proof)?;
            if stop_after == Some(AbortStopPoint::ReceiptSync) {
                return Err(injected_crash("after durable abort receipt"));
            }
            guard.retire_claim(
                ABORT_CLAIM_FILE_NAME,
                &retired_name,
                &proof.marker_bytes,
                "abort",
                stop_after == Some(AbortStopPoint::ClaimRetire),
            )?;
            Ok(AbortResult {
                proof,
                replayed: resumed_claim && receipt_replayed,
            })
        }

        fn query_abort(&self, arguments: &AbortArgs) -> Result<AbortQuery, MarkerError> {
            let guard = self.lock(FlockOperation::LockExclusive)?;
            guard.require_named_absent(RELEASE_CLAIM_FILE_NAME)?;
            let receipt_name = abort_receipt_name(
                &arguments.release.marker_sha256,
                &arguments.authorization_sha256,
            );
            let retired_name = abort_retired_name(
                &arguments.release.marker_sha256,
                &arguments.authorization_sha256,
            );
            match guard.load_marker(&retired_name) {
                Ok(bytes) => {
                    guard.require_named_absent(ABORT_CLAIM_FILE_NAME)?;
                    validate_abort_marker_authorization(&bytes, arguments)?;
                    let proof = guard.load_abort_receipt(&receipt_name)?;
                    validate_abort_proof(&proof, arguments)?;
                    Ok(AbortQuery::Aborted(proof))
                }
                Err(MarkerError::MarkerMissing) => match guard.load_marker(ABORT_CLAIM_FILE_NAME) {
                    Ok(bytes) => {
                        validate_abort_marker_authorization(&bytes, arguments)?;
                        match guard.load_abort_receipt(&receipt_name) {
                            Ok(proof) => {
                                validate_abort_proof(&proof, arguments)?;
                                Ok(AbortQuery::CommittedPendingAbort(proof))
                            }
                            Err(MarkerError::MarkerMissing) => Ok(AbortQuery::Claimed),
                            Err(error) => Err(error),
                        }
                    }
                    Err(MarkerError::MarkerMissing) => {
                        match guard
                            .load_marker(viewflow_deployment_marker::DEPLOYMENT_MARKER_FILE_NAME)
                        {
                            Ok(bytes) => {
                                validate_abort_marker_authorization(&bytes, arguments)?;
                                Ok(AbortQuery::Active)
                            }
                            Err(MarkerError::MarkerMissing) => {
                                let proof = guard.load_abort_receipt(&receipt_name)?;
                                validate_abort_proof(&proof, arguments)?;
                                fsync(&guard.parent).map_err(|source| {
                                    marker_io("sync queried deployment abort point", source)
                                })?;
                                Ok(AbortQuery::Aborted(proof))
                            }
                            Err(error) => Err(error),
                        }
                    }
                    Err(error) => Err(error),
                },
                Err(error) => Err(error),
            }
        }
    }

    struct ReleaseGuard {
        parent: OwnedFd,
        _lock: OwnedFd,
        expected_uid: u32,
    }

    impl ReleaseGuard {
        fn require_claim_absent(&self) -> Result<(), MarkerError> {
            self.require_named_absent(RELEASE_CLAIM_FILE_NAME)?;
            self.require_named_absent(ABORT_CLAIM_FILE_NAME)
        }

        fn require_named_absent(&self, name: &str) -> Result<(), MarkerError> {
            match self.load_marker(name) {
                Err(MarkerError::MarkerMissing) => Ok(()),
                Ok(_) => Err(MarkerError::MarkerAlreadyExists),
                Err(error) => Err(error),
            }
        }

        fn load_marker(&self, name: &str) -> Result<[u8; 256], MarkerError> {
            let bytes = self.load_exact(name, 256)?;
            let actual = bytes.len();
            bytes
                .try_into()
                .map_err(|_| MarkerError::WrongSize { actual })
        }

        fn load_receipt(&self, name: &str) -> Result<ReleaseProof, MarkerError> {
            ReleaseProof::decode(&self.load_exact(name, RELEASE_RECEIPT_SIZE)?)
        }

        fn load_abort_receipt(&self, name: &str) -> Result<AbortProof, MarkerError> {
            AbortProof::decode(&self.load_exact(name, ABORT_RECEIPT_SIZE)?)
        }

        fn load_exact(&self, name: &str, size: usize) -> Result<Vec<u8>, MarkerError> {
            let fd = match openat(
                &self.parent,
                name,
                OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            ) {
                Ok(fd) => fd,
                Err(source) if source == rustix::io::Errno::NOENT => {
                    return Err(MarkerError::MarkerMissing);
                }
                Err(source) => return Err(marker_io("open deployment transaction file", source)),
            };
            validate_owner_file(&fd, self.expected_uid, size)?;
            validate_named_fd(&self.parent, name, &fd)?;
            let mut bytes = Vec::with_capacity(size + 1);
            File::from(fd)
                .take(u64::try_from(size + 1).expect("transaction file size fits u64"))
                .read_to_end(&mut bytes)
                .map_err(|source| marker_io("read deployment transaction file", source))?;
            if bytes.len() != size {
                return Err(MarkerError::WrongSize {
                    actual: bytes.len(),
                });
            }
            Ok(bytes)
        }

        /// Atomically removes a committed claim from its public claim name, but
        /// deliberately retains the claimed inode as immutable audit evidence.
        /// Linux has no unlink-if-this-inode primitive: unlinking by pathname
        /// after closing a validated fd permits a same-uid dentry swap.  A
        /// NOREPLACE rename followed by validation of the retired name avoids
        /// deleting any replacement and makes crash recovery idempotent.
        fn retire_claim(
            &self,
            claim_name: &str,
            retired_name: &str,
            expected: &[u8; 256],
            transaction: &'static str,
            stop_after_sync: bool,
        ) -> Result<(), MarkerError> {
            self.retire_claim_with_hook(
                claim_name,
                retired_name,
                expected,
                transaction,
                stop_after_sync,
                || Ok(()),
            )
        }

        fn retire_claim_with_hook<F>(
            &self,
            claim_name: &str,
            retired_name: &str,
            expected: &[u8; 256],
            transaction: &'static str,
            stop_after_sync: bool,
            before_rename: F,
        ) -> Result<(), MarkerError>
        where
            F: FnOnce() -> Result<(), MarkerError>,
        {
            match self.load_marker(retired_name) {
                Ok(retired) => {
                    self.require_named_absent(claim_name)?;
                    if retired != *expected {
                        return Err(MarkerError::AuthorizationMismatch);
                    }
                    return Ok(());
                }
                Err(MarkerError::MarkerMissing) => {}
                Err(error) => return Err(error),
            }

            // Unit tests use this exact boundary to model a non-cooperating
            // same-uid writer replacing the source dentry after the caller's
            // authorization read and immediately before renameat2.
            before_rename()?;
            renameat_with(
                &self.parent,
                claim_name,
                &self.parent,
                retired_name,
                RenameFlags::NOREPLACE,
            )
            .map_err(|source| marker_io("atomically retire deployment claim", source))?;
            fsync(&self.parent)
                .map_err(|source| marker_io("sync retired deployment claim", source))?;
            if stop_after_sync {
                return Err(injected_crash(match transaction {
                    "release" => "after durable release claim retirement",
                    "abort" => "after durable abort claim retirement",
                    _ => "after durable deployment claim retirement",
                }));
            }
            let retired = self.load_marker(retired_name)?;
            if retired != *expected {
                return Err(MarkerError::AuthorizationMismatch);
            }
            // A non-cooperating same-uid writer may recreate the public claim
            // after the atomic rename.  Fail closed and retain both dentries;
            // critically, never unlink either path.
            self.require_named_absent(claim_name)?;
            Ok(())
        }

        fn commit_receipt(
            &self,
            name: &str,
            proof: &ReleaseProof,
        ) -> Result<(ReleaseProof, bool), MarkerError> {
            match self.load_receipt(name) {
                Ok(existing) => {
                    if existing.marker_bytes != proof.marker_bytes
                        || existing.marker_sha256 != proof.marker_sha256
                    {
                        return Err(MarkerError::AuthorizationMismatch);
                    }
                    return Ok((existing, true));
                }
                Err(MarkerError::MarkerMissing) => {}
                Err(error) => return Err(error),
            }
            let bytes = proof.encode();
            let temporary_name = format!(
                "{name}.tmp.{}.{}",
                std::process::id(),
                proof.committed_at_unix_ms
            );
            let temporary_fd = openat(
                &self.parent,
                temporary_name.as_str(),
                OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::RUSR | Mode::WUSR,
            )
            .map_err(|source| marker_io("create deployment release receipt staging", source))?;
            let mut temporary = File::from(temporary_fd);
            if let Err(source) = temporary
                .write_all(&bytes)
                .and_then(|()| temporary.sync_all())
            {
                let _ = unlinkat(&self.parent, temporary_name.as_str(), AtFlags::empty());
                return Err(marker_io(
                    "write deployment release receipt staging",
                    source,
                ));
            }
            drop(temporary);
            match renameat_with(
                &self.parent,
                temporary_name.as_str(),
                &self.parent,
                name,
                RenameFlags::NOREPLACE,
            ) {
                Ok(()) => fsync(&self.parent).map_err(|source| {
                    marker_io("sync committed deployment release receipt", source)
                })?,
                Err(source) if source == rustix::io::Errno::EXIST => {
                    let _ = unlinkat(&self.parent, temporary_name.as_str(), AtFlags::empty());
                }
                Err(source) => {
                    let _ = unlinkat(&self.parent, temporary_name.as_str(), AtFlags::empty());
                    return Err(marker_io("commit deployment release receipt", source));
                }
            }
            let committed = self.load_receipt(name)?;
            if committed != *proof {
                return Err(MarkerError::AuthorizationMismatch);
            }
            Ok((committed, false))
        }

        fn commit_abort_receipt(
            &self,
            name: &str,
            proof: &AbortProof,
        ) -> Result<(AbortProof, bool), MarkerError> {
            match self.load_abort_receipt(name) {
                Ok(existing) => {
                    if existing.marker_bytes != proof.marker_bytes
                        || existing.marker_sha256 != proof.marker_sha256
                        || existing.authorization_sha256 != proof.authorization_sha256
                    {
                        return Err(MarkerError::AuthorizationMismatch);
                    }
                    return Ok((existing, true));
                }
                Err(MarkerError::MarkerMissing) => {}
                Err(error) => return Err(error),
            }
            let bytes = proof.encode();
            let temporary_name = format!(
                "{name}.tmp.{}.{}",
                std::process::id(),
                proof.committed_at_unix_ms
            );
            let temporary_fd = openat(
                &self.parent,
                temporary_name.as_str(),
                OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::RUSR | Mode::WUSR,
            )
            .map_err(|source| marker_io("create deployment abort receipt staging", source))?;
            let mut temporary = File::from(temporary_fd);
            if let Err(source) = temporary
                .write_all(&bytes)
                .and_then(|()| temporary.sync_all())
            {
                let _ = unlinkat(&self.parent, temporary_name.as_str(), AtFlags::empty());
                return Err(marker_io("write deployment abort receipt staging", source));
            }
            drop(temporary);
            match renameat_with(
                &self.parent,
                temporary_name.as_str(),
                &self.parent,
                name,
                RenameFlags::NOREPLACE,
            ) {
                Ok(()) => fsync(&self.parent).map_err(|source| {
                    marker_io("sync committed deployment abort receipt", source)
                })?,
                Err(source) if source == rustix::io::Errno::EXIST => {
                    let _ = unlinkat(&self.parent, temporary_name.as_str(), AtFlags::empty());
                }
                Err(source) => {
                    let _ = unlinkat(&self.parent, temporary_name.as_str(), AtFlags::empty());
                    return Err(marker_io("commit deployment abort receipt", source));
                }
            }
            let committed = self.load_abort_receipt(name)?;
            if committed != *proof {
                return Err(MarkerError::AuthorizationMismatch);
            }
            Ok((committed, false))
        }
    }

    impl ReleaseProof {
        fn new(marker_bytes: [u8; 256], committed_at_unix_ms: u64) -> Result<Self, MarkerError> {
            if committed_at_unix_ms == 0 {
                return Err(MarkerError::ZeroCreatedAt);
            }
            let marker = DeploymentQuarantineMarker::decode(&marker_bytes)?;
            let marker_sha256: [u8; 32] = Sha256::digest(marker_bytes).into();
            Ok(Self {
                marker,
                marker_bytes,
                marker_sha256,
                committed_at_unix_ms,
            })
        }

        fn encode(&self) -> [u8; RELEASE_RECEIPT_SIZE] {
            let mut bytes = [0_u8; RELEASE_RECEIPT_SIZE];
            bytes[..8].copy_from_slice(&RELEASE_RECEIPT_MAGIC);
            bytes[8] = 1;
            bytes[9] = 1;
            bytes[10] = 2;
            bytes[11] = 1;
            bytes[12] = 1;
            bytes[16..272].copy_from_slice(&self.marker_bytes);
            bytes[272..304].copy_from_slice(&self.marker_sha256);
            bytes[304..312].copy_from_slice(&self.committed_at_unix_ms.to_le_bytes());
            let receipt_sha256 = Sha256::digest(&bytes[..320]);
            bytes[320..352].copy_from_slice(&receipt_sha256);
            bytes
        }

        fn decode(bytes: &[u8]) -> Result<Self, MarkerError> {
            if bytes.len() != RELEASE_RECEIPT_SIZE {
                return Err(MarkerError::WrongSize {
                    actual: bytes.len(),
                });
            }
            if bytes[..8] != RELEASE_RECEIPT_MAGIC
                || bytes[8] != 1
                || bytes[9] != 1
                || bytes[10] != 2
                || bytes[11] != 1
                || bytes[12] != 1
                || bytes[13..16].iter().any(|byte| *byte != 0)
                || bytes[312..320].iter().any(|byte| *byte != 0)
            {
                return Err(MarkerError::ReservedBytesNonZero);
            }
            if bytes[320..352] != Sha256::digest(&bytes[..320])[..] {
                return Err(MarkerError::AuthorizationMismatch);
            }
            let marker_bytes: [u8; 256] = bytes[16..272]
                .try_into()
                .expect("fixed receipt marker range");
            let marker_sha256: [u8; 32] = bytes[272..304]
                .try_into()
                .expect("fixed receipt hash range");
            if marker_sha256 != <[u8; 32]>::from(Sha256::digest(marker_bytes)) {
                return Err(MarkerError::AuthorizationMismatch);
            }
            let committed_at_unix_ms = u64::from_le_bytes(
                bytes[304..312]
                    .try_into()
                    .expect("fixed receipt timestamp range"),
            );
            Self::new(marker_bytes, committed_at_unix_ms)
        }
    }

    impl AbortProof {
        fn new(
            marker_bytes: [u8; 256],
            authorization_sha256: [u8; 32],
            committed_at_unix_ms: u64,
        ) -> Result<Self, MarkerError> {
            if committed_at_unix_ms == 0 {
                return Err(MarkerError::ZeroCreatedAt);
            }
            let marker = DeploymentQuarantineMarker::decode(&marker_bytes)?;
            let marker_sha256: [u8; 32] = Sha256::digest(marker_bytes).into();
            Ok(Self {
                marker,
                marker_bytes,
                marker_sha256,
                authorization_sha256,
                committed_at_unix_ms,
            })
        }

        fn encode(&self) -> [u8; ABORT_RECEIPT_SIZE] {
            let mut bytes = [0_u8; ABORT_RECEIPT_SIZE];
            bytes[..8].copy_from_slice(&ABORT_RECEIPT_MAGIC);
            bytes[8] = 1;
            bytes[9] = 1;
            bytes[10] = 1;
            bytes[11] = 3;
            bytes[12] = 1;
            bytes[16..272].copy_from_slice(&self.marker_bytes);
            bytes[272..304].copy_from_slice(&self.marker_sha256);
            bytes[304..336].copy_from_slice(&self.authorization_sha256);
            bytes[336..344].copy_from_slice(&self.committed_at_unix_ms.to_le_bytes());
            let receipt_sha256 = Sha256::digest(&bytes[..352]);
            bytes[352..384].copy_from_slice(&receipt_sha256);
            bytes
        }

        fn decode(bytes: &[u8]) -> Result<Self, MarkerError> {
            if bytes.len() != ABORT_RECEIPT_SIZE {
                return Err(MarkerError::WrongSize {
                    actual: bytes.len(),
                });
            }
            if bytes[..8] != ABORT_RECEIPT_MAGIC
                || bytes[8] != 1
                || bytes[9] != 1
                || bytes[10] != 1
                || bytes[11] != 3
                || bytes[12] != 1
                || bytes[13..16].iter().any(|byte| *byte != 0)
                || bytes[344..352].iter().any(|byte| *byte != 0)
            {
                return Err(MarkerError::ReservedBytesNonZero);
            }
            if bytes[352..384] != Sha256::digest(&bytes[..352])[..] {
                return Err(MarkerError::AuthorizationMismatch);
            }
            let marker_bytes: [u8; 256] = bytes[16..272]
                .try_into()
                .expect("fixed abort receipt marker range");
            let marker_sha256: [u8; 32] = bytes[272..304]
                .try_into()
                .expect("fixed abort receipt marker hash range");
            if marker_sha256 != <[u8; 32]>::from(Sha256::digest(marker_bytes)) {
                return Err(MarkerError::AuthorizationMismatch);
            }
            let authorization_sha256 = bytes[304..336]
                .try_into()
                .expect("fixed abort receipt authorization hash range");
            let committed_at_unix_ms = u64::from_le_bytes(
                bytes[336..344]
                    .try_into()
                    .expect("fixed abort receipt timestamp range"),
            );
            Self::new(marker_bytes, authorization_sha256, committed_at_unix_ms)
        }
    }

    fn load_abort_authorization(arguments: &AbortArgs) -> Result<AbortAuthorization, CliError> {
        let path = &arguments.authorization_path;
        if !is_canonical_absolute(path) {
            return Err(usage(
                "--abort-authorization-path must be canonical and absolute",
            ));
        }
        let fd = open(
            path,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|source| CliError::Marker(marker_io("open abort authorization", source)))?;
        validate_owner_file_bounded(&fd, rustix::process::geteuid().as_raw())?;
        let mut bytes = Vec::with_capacity(4096);
        File::from(fd)
            .take(u64::try_from(MAX_AUTHORIZATION_SIZE + 1).expect("authorization bound fits u64"))
            .read_to_end(&mut bytes)
            .map_err(|source| CliError::Marker(marker_io("read abort authorization", source)))?;
        if bytes.is_empty() || bytes.len() > MAX_AUTHORIZATION_SIZE {
            return Err(CliError::Marker(MarkerError::WrongSize {
                actual: bytes.len(),
            }));
        }
        let actual_sha256: [u8; 32] = Sha256::digest(&bytes).into();
        if actual_sha256 != arguments.authorization_sha256 {
            return Err(CliError::Marker(MarkerError::AuthorizationMismatch));
        }
        let authorization: AbortAuthorization = serde_json::from_slice(&bytes)
            .map_err(|_| CliError::Marker(MarkerError::AuthorizationMismatch))?;
        validate_abort_authorization(&authorization, arguments)?;
        Ok(authorization)
    }

    #[allow(clippy::too_many_lines)] // Exact mutually-exclusive frozen authorization schemas.
    fn validate_abort_authorization(
        authorization: &AbortAuthorization,
        arguments: &AbortArgs,
    ) -> Result<(), CliError> {
        let release = &arguments.release;
        let path = arguments.authorization_path.to_string_lossy();
        let common_valid = |schema_version: u8,
                            state: &str,
                            operation_id: &str,
                            coordinator_instance_id: &str,
                            marker_generation: &str,
                            marker_sha256: &str,
                            authorization_receipt_path: &str| {
            schema_version > 0
                && operation_id == release.operation_id
                && parse_uuid(coordinator_instance_id) == Some(release.coordinator_instance_id)
                && marker_generation == release.marker_generation.to_string()
                && marker_sha256 == hex_lower(&release.marker_sha256)
                && authorization_receipt_path == path
                && !state.is_empty()
        };
        let valid = match authorization {
            AbortAuthorization::RestoredV1(value) => {
                let hashes = [
                    &value.marker_handoff_receipt_sha256,
                    &value.deployment_publish_receipt_sha256,
                    &value.linux_frozen_evidence_sha256,
                    &value.windows_force_envelope_sha256,
                    &value.windows_migration_receipt_sha256,
                    &value.windows_claim_resolution_sha256,
                    &value.old_linux_viewflowd_sha256,
                    &value.old_linux_deskflow_sha256,
                    &value.old_linux_deskflow_core_sha256,
                    &value.old_windows_viewflowd_sha256,
                    &value.old_windows_wrapper_sha256,
                    &value.linux_v13_started_receipt_sha256,
                    &value.windows_v13_started_receipt_sha256,
                    &value.authenticated_v13_peer_receipt_sha256,
                ];
                common_valid(
                    value.schema_version,
                    &value.state,
                    &value.operation_id,
                    &value.coordinator_instance_id,
                    &value.marker_generation,
                    &value.marker_sha256,
                    &value.authorization_receipt_path,
                ) && value.schema_version == 1
                    && value.state == "viewflow-deployment-quarantine-abort-authorized"
                    && hashes.iter().all(|value| parse_hash(value).is_ok())
                    && value.initial_force_release_executed
                    && !value.second_force_release_executed
                    && !value.rollback_token_consumed
                    && !value.protocol_2_1
            }
            AbortAuthorization::PreMutationV2(value) => {
                let hashes = [
                    &value.marker_handoff_receipt_sha256,
                    &value.deployment_publish_receipt_sha256,
                    &value.linux_frozen_evidence_sha256,
                    &value.installer_exit_receipt_sha256,
                    &value.windows_stop_evidence_sha256,
                    &value.pre_mutation_retry_receipt_sha256,
                    &value.windows_live_proof_sha256,
                    &value.old_linux_viewflowd_sha256,
                    &value.old_linux_deskflow_sha256,
                    &value.old_linux_deskflow_core_sha256,
                    &value.old_windows_viewflowd_sha256,
                    &value.old_windows_wrapper_sha256,
                    &value.old_windows_task_xml_sha256,
                    &value.old_windows_rollback_sha256,
                    &value.linux_v13_started_receipt_sha256,
                    &value.windows_v13_started_receipt_sha256,
                    &value.authenticated_v13_peer_receipt_sha256,
                ];
                common_valid(
                    value.schema_version,
                    &value.state,
                    &value.operation_id,
                    &value.coordinator_instance_id,
                    &value.marker_generation,
                    &value.marker_sha256,
                    &value.authorization_receipt_path,
                ) && value.schema_version == 2
                    && value.state
                        == "viewflow-deployment-quarantine-failed-pre-mutation-installer-baseline-restored-abort-authorized"
                    && hashes.iter().all(|value| parse_hash(value).is_ok())
                    && !value.initial_force_release_executed
                    && !value.rollback_performed
                    && value.windows_rollback_receipt_sha256.is_none()
                    && !value.protocol_2_1
            }
            AbortAuthorization::EarlyGateV3(value) => {
                let hashes = [
                    &value.coordinator_terminal_state_sha256,
                    &value.marker_handoff_receipt_sha256,
                    &value.deployment_publish_receipt_sha256,
                    &value.linux_frozen_evidence_sha256,
                    &value.bootstrap_request_sha256,
                    &value.windows_stop_evidence_sha256,
                    &value.windows_live_proof_sha256,
                    &value.old_linux_viewflowd_sha256,
                    &value.old_linux_deskflow_sha256,
                    &value.old_linux_deskflow_core_sha256,
                    &value.old_windows_viewflowd_sha256,
                    &value.old_windows_wrapper_sha256,
                    &value.old_windows_task_xml_sha256,
                    &value.old_windows_rollback_sha256,
                    &value.linux_v13_started_receipt_sha256,
                    &value.windows_v13_started_receipt_sha256,
                    &value.authenticated_v13_peer_receipt_sha256,
                ];
                common_valid(
                    value.schema_version,
                    &value.state,
                    &value.operation_id,
                    &value.coordinator_instance_id,
                    &value.marker_generation,
                    &value.marker_sha256,
                    &value.authorization_receipt_path,
                ) && value.schema_version == 3
                    && value.state
                        == "viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized"
                    && hashes.iter().all(|value| {
                        parse_hash(value).is_ok()
                            && value.as_bytes().iter().any(|byte| *byte != b'0')
                    })
                    && value.coordinator_failure_phase.is_none()
                    && !value.coordinator_mutation_possible
                    && !value.windows_bootstrap_worker_created
                    && !value.windows_new_operation_root_present
                    && !value.windows_new_task_present
                    && value.windows_installer_process_count == 0
                    && !value.mutation_permit_published
                    && !value.force_release_executed
                    && !value.rollback_performed
                    && value.windows_rollback_receipt_sha256.is_none()
                    && !value.initial_force_release_executed
                    && !value.linux_deskflow_started
                    && value.input_producer_count == 0
                    && !value.protocol_2_1
            }
            AbortAuthorization::PostPermitRollbackV5(value) => {
                let hashes = [
                    &value.coordinator_terminal_state_sha256,
                    &value.schema1_handoff_lineage_receipt_sha256,
                    &value.marker_handoff_receipt_sha256,
                    &value.deployment_publish_receipt_sha256,
                    &value.linux_frozen_evidence_sha256,
                    &value.bootstrap_request_sha256,
                    &value.windows_prepared_receipt_sha256,
                    &value.mutation_permit_receipt_sha256,
                    &value.installer_exit_receipt_sha256,
                    &value.windows_stop_evidence_sha256,
                    &value.recovery_bundle_sha256,
                    &value.linux_deactivation_proof_sha256,
                    &value.linux_deactivation_transcript_sha256,
                    &value.windows_rollback_receipt_sha256,
                    &value.old_linux_viewflowd_sha256,
                    &value.old_linux_deskflow_sha256,
                    &value.old_linux_deskflow_core_sha256,
                    &value.old_windows_viewflowd_sha256,
                    &value.old_windows_wrapper_sha256,
                    &value.linux_v13_started_receipt_sha256,
                    &value.windows_v13_started_receipt_sha256,
                    &value.authenticated_v13_peer_receipt_sha256,
                ];
                common_valid(
                    value.schema_version,
                    &value.state,
                    &value.operation_id,
                    &value.coordinator_instance_id,
                    &value.marker_generation,
                    &value.marker_sha256,
                    &value.authorization_receipt_path,
                ) && value.schema_version == 5
                    && value.state
                        == "viewflow-deployment-quarantine-post-permit-rollback-abort-authorized"
                    && hashes.iter().all(|value| {
                        parse_hash(value).is_ok()
                            && value.as_bytes().iter().any(|byte| *byte != b'0')
                    })
                    && value.coordinator_failure_phase == "MUTATION_PERMITTED"
                    && value.coordinator_mutation_possible
                    && value.mutation_permit_published
                    && !value.force_release_executed
                    && value.rollback_performed
                    && !value.initial_force_release_executed
                    && !value.second_force_release_executed
                    && value.rollback_token_consumed
                    && !value.protocol_2_1
            }
            AbortAuthorization::PostForceRollbackV7(value) => {
                let hashes = [
                    &value.coordinator_terminal_state_sha256,
                    &value.fresh_operation_lineage_receipt_sha256,
                    &value.marker_handoff_receipt_sha256,
                    &value.deployment_publish_receipt_sha256,
                    &value.linux_frozen_evidence_sha256,
                    &value.bootstrap_request_sha256,
                    &value.windows_prepared_receipt_sha256,
                    &value.mutation_permit_receipt_sha256,
                    &value.windows_force_envelope_sha256,
                    &value.windows_stop_evidence_sha256,
                    &value.recovery_bundle_sha256,
                    &value.linux_deactivation_proof_sha256,
                    &value.linux_deactivation_transcript_sha256,
                    &value.windows_rollback_receipt_sha256,
                    &value.old_linux_viewflowd_sha256,
                    &value.old_linux_deskflow_sha256,
                    &value.old_linux_deskflow_core_sha256,
                    &value.old_windows_viewflowd_sha256,
                    &value.old_windows_wrapper_sha256,
                    &value.linux_v13_started_receipt_sha256,
                    &value.windows_v13_started_receipt_sha256,
                    &value.authenticated_v13_peer_receipt_sha256,
                ];
                common_valid(
                    value.schema_version,
                    &value.state,
                    &value.operation_id,
                    &value.coordinator_instance_id,
                    &value.marker_generation,
                    &value.marker_sha256,
                    &value.authorization_receipt_path,
                ) && value.schema_version == 7
                    && value.state
                        == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"
                    && hashes.iter().all(|value| {
                        parse_hash(value).is_ok()
                            && value.as_bytes().iter().any(|byte| *byte != b'0')
                    })
                    && value.coordinator_failure_phase == "WINDOWS_FORCE_ATTESTED"
                    && value.coordinator_mutation_possible
                    && value.mutation_permit_published
                    && value.force_release_executed
                    && value.rollback_performed
                    && !value.linux_stage_committed
                    && !value.windows_install_committed
                    && !value.windows_installer_exit_present
                    && value.initial_force_release_executed
                    && !value.second_force_release_executed
                    && value.rollback_token_consumed
                    && !value.protocol_2_1
            }
        };
        if valid {
            Ok(())
        } else {
            Err(CliError::Marker(MarkerError::AuthorizationMismatch))
        }
    }

    fn is_canonical_absolute(path: &Path) -> bool {
        path.is_absolute()
            && path
                .components()
                .all(|component| matches!(component, Component::RootDir | Component::Normal(_)))
    }

    fn validate_owner_file_bounded(fd: &OwnedFd, expected_uid: u32) -> Result<(), CliError> {
        let metadata = fstat(fd)
            .map_err(|source| CliError::Marker(marker_io("stat abort authorization", source)))?;
        if FileType::from_raw_mode(metadata.st_mode) != FileType::RegularFile
            || metadata.st_uid != expected_uid
            || metadata.st_mode & 0o777 != OWNER_MODE
            || metadata.st_nlink != 1
            || metadata.st_size <= 0
            || metadata.st_size > i64::try_from(MAX_AUTHORIZATION_SIZE).unwrap()
            || has_access_acl(fd)?
        {
            return Err(CliError::Marker(MarkerError::UnsafeMarker));
        }
        Ok(())
    }

    fn validate_authorization(
        marker_bytes: &[u8; 256],
        arguments: &ReleaseArgs,
    ) -> Result<(), MarkerError> {
        validate_proof(&ReleaseProof::new(*marker_bytes, 1)?, arguments)
    }

    fn validate_proof(proof: &ReleaseProof, arguments: &ReleaseArgs) -> Result<(), MarkerError> {
        if proof.marker.operation_id != arguments.operation_id
            || proof.marker.coordinator_instance != arguments.coordinator_instance_id
            || proof.marker.generation != arguments.marker_generation
            || proof.marker_sha256 != arguments.marker_sha256
        {
            return Err(MarkerError::AuthorizationMismatch);
        }
        Ok(())
    }

    fn validate_abort_marker_authorization(
        marker_bytes: &[u8; 256],
        arguments: &AbortArgs,
    ) -> Result<(), MarkerError> {
        validate_abort_proof(
            &AbortProof::new(*marker_bytes, arguments.authorization_sha256, 1)?,
            arguments,
        )
    }

    fn validate_abort_proof(proof: &AbortProof, arguments: &AbortArgs) -> Result<(), MarkerError> {
        if proof.marker.operation_id != arguments.release.operation_id
            || proof.marker.coordinator_instance != arguments.release.coordinator_instance_id
            || proof.marker.generation != arguments.release.marker_generation
            || proof.marker_sha256 != arguments.release.marker_sha256
            || proof.authorization_sha256 != arguments.authorization_sha256
        {
            return Err(MarkerError::AuthorizationMismatch);
        }
        Ok(())
    }

    fn validate_directory(fd: &OwnedFd, expected_uid: u32) -> Result<(), MarkerError> {
        let metadata =
            fstat(fd).map_err(|source| marker_io("stat deployment marker parent", source))?;
        if FileType::from_raw_mode(metadata.st_mode) != FileType::Directory
            || metadata.st_uid != expected_uid
            || metadata.st_mode & 0o777 != PARENT_MODE
        {
            return Err(MarkerError::UnsafeParent);
        }
        Ok(())
    }

    fn validate_owner_file(
        fd: &OwnedFd,
        expected_uid: u32,
        expected_size: usize,
    ) -> Result<(), MarkerError> {
        let metadata =
            fstat(fd).map_err(|source| marker_io("stat deployment transaction file", source))?;
        if FileType::from_raw_mode(metadata.st_mode) != FileType::RegularFile
            || metadata.st_uid != expected_uid
            || metadata.st_mode & 0o777 != OWNER_MODE
            || metadata.st_nlink != 1
            || metadata.st_size != i64::try_from(expected_size).expect("transaction size fits i64")
            || has_access_acl(fd)?
        {
            return Err(MarkerError::UnsafeMarker);
        }
        Ok(())
    }

    fn has_access_acl(fd: &OwnedFd) -> Result<bool, MarkerError> {
        let mut buffer = Vec::<u8>::with_capacity(65_536);
        let count = flistxattr(fd, &mut buffer)
            .map_err(|source| marker_io("list deployment transaction file ACL", source))?;
        buffer.truncate(count);
        Ok(buffer
            .split(|byte| *byte == 0)
            .any(|name| name == b"system.posix_acl_access"))
    }

    fn validate_named_fd(parent: &OwnedFd, name: &str, fd: &OwnedFd) -> Result<(), MarkerError> {
        let opened = fstat(fd)
            .map_err(|source| marker_io("stat opened deployment transaction file", source))?;
        let named = statat(parent, name, AtFlags::SYMLINK_NOFOLLOW)
            .map_err(|source| marker_io("stat named deployment transaction file", source))?;
        if opened.st_dev != named.st_dev || opened.st_ino != named.st_ino {
            return Err(MarkerError::UnsafeMarker);
        }
        Ok(())
    }

    fn receipt_name(marker_sha256: &[u8; 32]) -> String {
        format!(
            "{RELEASE_RECEIPT_PREFIX}{}{RELEASE_RECEIPT_SUFFIX}",
            hex_lower(marker_sha256)
        )
    }

    fn release_retired_name(marker_sha256: &[u8; 32]) -> String {
        format!(
            "{RELEASE_RETIRED_PREFIX}{}{RELEASE_RECEIPT_SUFFIX}",
            hex_lower(marker_sha256)
        )
    }

    fn abort_receipt_name(marker_sha256: &[u8; 32], authorization_sha256: &[u8; 32]) -> String {
        format!(
            "{ABORT_RECEIPT_PREFIX}{}.{}{ABORT_RECEIPT_SUFFIX}",
            hex_lower(marker_sha256),
            hex_lower(authorization_sha256)
        )
    }

    fn abort_retired_name(marker_sha256: &[u8; 32], authorization_sha256: &[u8; 32]) -> String {
        format!(
            "{ABORT_RETIRED_PREFIX}{}.{}{ABORT_RECEIPT_SUFFIX}",
            hex_lower(marker_sha256),
            hex_lower(authorization_sha256)
        )
    }

    fn marker_io(action: &'static str, source: impl Into<io::Error>) -> MarkerError {
        MarkerError::Io {
            action,
            source: source.into(),
        }
    }

    fn injected_crash(stage: &'static str) -> MarkerError {
        marker_io(stage, io::Error::new(io::ErrorKind::Interrupted, stage))
    }

    fn parse_command(arguments: Vec<OsString>) -> Result<Command, CliError> {
        let mut strings = arguments
            .into_iter()
            .map(|value| {
                value.into_string().map_err(|_| {
                    CliError::Usage("all command arguments must be valid UTF-8".to_owned())
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        if strings.is_empty() {
            return Err(usage("missing argv[0]"));
        }
        strings.remove(0);
        let subcommand = strings
            .first()
            .cloned()
            .ok_or_else(|| usage("missing publish, release, abort, or query subcommand"))?;
        strings.remove(0);
        let mut options = parse_options(&strings)?;

        let operation_id = take_required(&mut options, "--operation-id")?;
        if !validate_operation_id(&operation_id) {
            return Err(usage("--operation-id violates the VFDQT001 contract"));
        }
        let coordinator_instance_id = parse_uuid_option(
            &take_required(&mut options, "--coordinator-instance-id")?,
            "--coordinator-instance-id",
        )?;
        let marker_generation =
            parse_generation(&take_required(&mut options, "--marker-generation")?)?;

        let command = match subcommand.as_str() {
            "publish" => Command::Publish(PublishArgs {
                operation_id,
                source_display_id: parse_uuid_option(
                    &take_required(&mut options, "--source-display-id")?,
                    "--source-display-id",
                )?,
                target_device_id: parse_uuid_option(
                    &take_required(&mut options, "--target-device-id")?,
                    "--target-device-id",
                )?,
                coordinator_instance_id,
                marker_generation,
            }),
            "release" | "abort" | "query" => {
                let release = ReleaseArgs {
                    operation_id,
                    coordinator_instance_id,
                    marker_generation,
                    marker_sha256: parse_hash(&take_required(&mut options, "--marker-sha256")?)?,
                };
                if subcommand == "release" {
                    Command::Release(release)
                } else if subcommand == "abort" {
                    Command::Abort(parse_abort_args(release, &mut options)?)
                } else if options.contains_key("--abort-authorization-path")
                    || options.contains_key("--abort-authorization-sha256")
                {
                    Command::QueryAbort(parse_abort_args(release, &mut options)?)
                } else {
                    Command::QueryRelease(release)
                }
            }
            _ => {
                return Err(usage(
                    "subcommand must be exactly publish, release, abort, or query",
                ));
            }
        };
        if let Some(option) = options.keys().next() {
            return Err(usage(&format!("unexpected option {option}")));
        }
        Ok(command)
    }

    fn parse_abort_args(
        release: ReleaseArgs,
        options: &mut BTreeMap<String, String>,
    ) -> Result<AbortArgs, CliError> {
        let authorization_path =
            PathBuf::from(take_required(options, "--abort-authorization-path")?);
        if !is_canonical_absolute(&authorization_path) {
            return Err(usage(
                "--abort-authorization-path must be canonical and absolute",
            ));
        }
        let authorization_sha256 =
            parse_hash(&take_required(options, "--abort-authorization-sha256")?)?;
        Ok(AbortArgs {
            release,
            authorization_path,
            authorization_sha256,
        })
    }

    fn parse_options(arguments: &[String]) -> Result<BTreeMap<String, String>, CliError> {
        if arguments.len() % 2 != 0 {
            return Err(usage("every option requires exactly one value"));
        }
        let mut options = BTreeMap::new();
        for pair in arguments.chunks_exact(2) {
            if !pair[0].starts_with("--") || pair[0].len() == 2 || pair[1].is_empty() {
                return Err(usage("options must be non-empty --name value pairs"));
            }
            if options.insert(pair[0].clone(), pair[1].clone()).is_some() {
                return Err(usage(&format!("duplicate option {}", pair[0])));
            }
        }
        Ok(options)
    }

    fn take_required(
        options: &mut BTreeMap<String, String>,
        name: &str,
    ) -> Result<String, CliError> {
        options
            .remove(name)
            .ok_or_else(|| usage(&format!("missing required option {name}")))
    }

    fn parse_generation(value: &str) -> Result<u64, CliError> {
        let generation = value
            .parse::<u64>()
            .map_err(|_| usage("--marker-generation must be a decimal u64"))?;
        if generation == 0 || generation.to_string() != value {
            return Err(usage(
                "--marker-generation must be canonical decimal and non-zero",
            ));
        }
        Ok(generation)
    }

    fn parse_uuid_option(value: &str, name: &str) -> Result<[u8; 16], CliError> {
        parse_uuid(value).ok_or_else(|| {
            usage(&format!(
                "{name} must be a canonical lowercase non-zero UUID"
            ))
        })
    }

    fn parse_uuid(value: &str) -> Option<[u8; 16]> {
        if value.len() != 36
            || !value.bytes().enumerate().all(|(index, byte)| match index {
                8 | 13 | 18 | 23 => byte == b'-',
                _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
            })
        {
            return None;
        }
        let mut bytes = [0_u8; 16];
        let mut output_index = 0;
        let mut high_nibble = None;
        for byte in value.bytes().filter(|byte| *byte != b'-') {
            let nibble = match byte {
                b'0'..=b'9' => byte - b'0',
                b'a'..=b'f' => byte - b'a' + 10,
                _ => return None,
            };
            if let Some(high) = high_nibble.take() {
                bytes[output_index] = (high << 4) | nibble;
                output_index += 1;
            } else {
                high_nibble = Some(nibble);
            }
        }
        (output_index == 16 && bytes.iter().any(|byte| *byte != 0)).then_some(bytes)
    }

    fn parse_hash(value: &str) -> Result<[u8; 32], CliError> {
        if value.len() != 64
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(usage(
                "--marker-sha256 must be exactly 64 lowercase hexadecimal characters",
            ));
        }
        let mut bytes = [0_u8; 32];
        for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
            bytes[index] = (hex_nibble(pair[0]) << 4) | hex_nibble(pair[1]);
        }
        Ok(bytes)
    }

    fn hex_nibble(byte: u8) -> u8 {
        match byte {
            b'0'..=b'9' => byte - b'0',
            b'a'..=b'f' => byte - b'a' + 10,
            _ => unreachable!("caller validated lowercase hexadecimal"),
        }
    }

    fn format_uuid(bytes: [u8; 16]) -> String {
        let hex = hex_lower(&bytes);
        format!(
            "{}-{}-{}-{}-{}",
            &hex[..8],
            &hex[8..12],
            &hex[12..16],
            &hex[16..20],
            &hex[20..]
        )
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

    fn unix_milliseconds() -> Result<u64, CliError> {
        let duration = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| CliError::Clock("system clock predates Unix epoch".to_owned()))?;
        let milliseconds = u64::try_from(duration.as_millis()).map_err(|_| {
            CliError::Clock("system clock does not fit u64 milliseconds".to_owned())
        })?;
        if milliseconds == 0 {
            return Err(CliError::Clock(
                "system clock produced forbidden zero timestamp".to_owned(),
            ));
        }
        Ok(milliseconds)
    }

    fn format_unix_milliseconds(milliseconds: u64) -> Result<String, CliError> {
        let nanoseconds = i128::from(milliseconds) * 1_000_000;
        OffsetDateTime::from_unix_timestamp_nanos(nanoseconds)
            .map_err(|error| CliError::Clock(format!("invalid receipt timestamp: {error}")))?
            .format(&Rfc3339)
            .map_err(|error| CliError::Clock(format!("format receipt timestamp: {error}")))
    }

    fn write_receipt(value: &serde_json::Value) -> Result<(), CliError> {
        let stdout = io::stdout();
        let mut output = stdout.lock();
        serde_json::to_writer(&mut output, &value).map_err(|error| {
            CliError::Output(io::Error::other(format!("serialize receipt: {error}")))
        })?;
        output.write_all(b"\n").map_err(CliError::Output)
    }

    fn usage(message: &str) -> CliError {
        CliError::Usage(format!(
            "{message}; usage: viewflow-deployment-marker publish --operation-id ID \
             --source-display-id UUID --target-device-id UUID \
             --coordinator-instance-id UUID --marker-generation N, or \
             viewflow-deployment-marker release --operation-id ID \
             --coordinator-instance-id UUID --marker-generation N --marker-sha256 HEX, or \
             viewflow-deployment-marker abort with the release options plus \
             --abort-authorization-path ABSOLUTE --abort-authorization-sha256 HEX, or \
             viewflow-deployment-marker query with either the release or abort option set"
        ))
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::{
            fs,
            os::unix::fs::{MetadataExt, PermissionsExt, symlink},
            process::Command as ProcessCommand,
        };

        struct TransactionFixture {
            _temporary: tempfile::TempDir,
            store: ReleaseTransactionStore,
            arguments: ReleaseArgs,
            marker_bytes: [u8; 256],
            parent: PathBuf,
        }

        impl TransactionFixture {
            fn new() -> Self {
                let temporary = tempfile::tempdir().unwrap();
                let parent = temporary.path().join("state");
                fs::create_dir(&parent).unwrap();
                fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
                let marker = DeploymentQuarantineMarker {
                    operation_id: "deploy-20260829-0001".to_owned(),
                    source_display: [0x11; 16],
                    target_device: [0x22; 16],
                    coordinator_instance: [0x33; 16],
                    created_at_unix_ms: 1_788_000_000_000,
                    generation: 7,
                };
                let marker_bytes = marker.encode().unwrap();
                let marker_path =
                    parent.join(viewflow_deployment_marker::DEPLOYMENT_MARKER_FILE_NAME);
                fs::write(&marker_path, marker_bytes).unwrap();
                fs::set_permissions(&marker_path, fs::Permissions::from_mode(0o600)).unwrap();
                let arguments = ReleaseArgs {
                    operation_id: marker.operation_id,
                    coordinator_instance_id: marker.coordinator_instance,
                    marker_generation: marker.generation,
                    marker_sha256: Sha256::digest(marker_bytes).into(),
                };
                let uid = fs::metadata(&parent).unwrap().uid();
                let store = ReleaseTransactionStore::new(&parent, uid);
                Self {
                    _temporary: temporary,
                    store,
                    arguments,
                    marker_bytes,
                    parent,
                }
            }

            fn active_path(&self) -> PathBuf {
                self.parent
                    .join(viewflow_deployment_marker::DEPLOYMENT_MARKER_FILE_NAME)
            }

            fn claim_path(&self) -> PathBuf {
                self.parent.join(RELEASE_CLAIM_FILE_NAME)
            }

            fn receipt_path(&self) -> PathBuf {
                self.parent
                    .join(receipt_name(&self.arguments.marker_sha256))
            }

            fn release_retired_path(&self) -> PathBuf {
                self.parent
                    .join(release_retired_name(&self.arguments.marker_sha256))
            }

            fn abort_retired_path(&self, arguments: &AbortArgs) -> PathBuf {
                self.parent.join(abort_retired_name(
                    &arguments.release.marker_sha256,
                    &arguments.authorization_sha256,
                ))
            }
        }

        fn os_args(values: &[&str]) -> Vec<OsString> {
            values.iter().map(OsString::from).collect()
        }

        fn write_abort_authorization(fixture: &TransactionFixture) -> AbortArgs {
            let path = fixture.parent.join("abort-authorization.json");
            let hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            let value = json!({
                "schema_version": 1,
                "state": "viewflow-deployment-quarantine-abort-authorized",
                "operation_id": fixture.arguments.operation_id,
                "coordinator_instance_id": format_uuid(fixture.arguments.coordinator_instance_id),
                "marker_generation": fixture.arguments.marker_generation.to_string(),
                "marker_sha256": hex_lower(&fixture.arguments.marker_sha256),
                "authorization_receipt_path": path.to_string_lossy(),
                "marker_handoff_receipt_sha256": hash,
                "deployment_publish_receipt_sha256": hash,
                "linux_frozen_evidence_sha256": hash,
                "windows_force_envelope_sha256": hash,
                "windows_migration_receipt_sha256": hash,
                "windows_claim_resolution_sha256": hash,
                "old_linux_viewflowd_sha256": hash,
                "old_linux_deskflow_sha256": hash,
                "old_linux_deskflow_core_sha256": hash,
                "old_windows_viewflowd_sha256": hash,
                "old_windows_wrapper_sha256": hash,
                "linux_v13_started_receipt_sha256": hash,
                "windows_v13_started_receipt_sha256": hash,
                "authenticated_v13_peer_receipt_sha256": hash,
                "initial_force_release_executed": true,
                "second_force_release_executed": false,
                "rollback_token_consumed": false,
                "protocol_2_1": false,
            });
            let mut bytes = serde_json::to_vec(&value).unwrap();
            bytes.push(b'\n');
            fs::write(&path, &bytes).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            AbortArgs {
                release: fixture.arguments.clone(),
                authorization_path: path,
                authorization_sha256: Sha256::digest(bytes).into(),
            }
        }

        fn write_pre_mutation_abort_authorization(fixture: &TransactionFixture) -> AbortArgs {
            let path = fixture.parent.join("pre-mutation-abort-authorization.json");
            let hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
            let value = json!({
                "schema_version": 2,
                "state": "viewflow-deployment-quarantine-failed-pre-mutation-installer-baseline-restored-abort-authorized",
                "operation_id": fixture.arguments.operation_id,
                "coordinator_instance_id": format_uuid(fixture.arguments.coordinator_instance_id),
                "marker_generation": fixture.arguments.marker_generation.to_string(),
                "marker_sha256": hex_lower(&fixture.arguments.marker_sha256),
                "authorization_receipt_path": path.to_string_lossy(),
                "marker_handoff_receipt_sha256": hash,
                "deployment_publish_receipt_sha256": hash,
                "linux_frozen_evidence_sha256": hash,
                "installer_exit_receipt_sha256": hash,
                "windows_stop_evidence_sha256": hash,
                "pre_mutation_retry_receipt_sha256": hash,
                "windows_live_proof_sha256": hash,
                "old_linux_viewflowd_sha256": hash,
                "old_linux_deskflow_sha256": hash,
                "old_linux_deskflow_core_sha256": hash,
                "old_windows_viewflowd_sha256": hash,
                "old_windows_wrapper_sha256": hash,
                "old_windows_task_xml_sha256": hash,
                "old_windows_rollback_sha256": hash,
                "linux_v13_started_receipt_sha256": hash,
                "windows_v13_started_receipt_sha256": hash,
                "authenticated_v13_peer_receipt_sha256": hash,
                "initial_force_release_executed": false,
                "rollback_performed": false,
                "windows_rollback_receipt_sha256": null,
                "protocol_2_1": false,
            });
            let mut bytes = serde_json::to_vec(&value).unwrap();
            bytes.push(b'\n');
            fs::write(&path, &bytes).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            AbortArgs {
                release: fixture.arguments.clone(),
                authorization_path: path,
                authorization_sha256: Sha256::digest(bytes).into(),
            }
        }

        fn write_early_gate_abort_authorization(fixture: &TransactionFixture) -> AbortArgs {
            let path = fixture.parent.join("early-gate-abort-authorization.json");
            let hash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
            let value = json!({
                "schema_version": 3,
                "state": "viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized",
                "operation_id": fixture.arguments.operation_id,
                "coordinator_instance_id": format_uuid(fixture.arguments.coordinator_instance_id),
                "marker_generation": fixture.arguments.marker_generation.to_string(),
                "marker_sha256": hex_lower(&fixture.arguments.marker_sha256),
                "authorization_receipt_path": path.to_string_lossy(),
                "coordinator_terminal_state_sha256": hash,
                "coordinator_failure_phase": null,
                "coordinator_mutation_possible": false,
                "marker_handoff_receipt_sha256": hash,
                "deployment_publish_receipt_sha256": hash,
                "linux_frozen_evidence_sha256": hash,
                "bootstrap_request_sha256": hash,
                "windows_stop_evidence_sha256": hash,
                "windows_live_proof_sha256": hash,
                "old_linux_viewflowd_sha256": hash,
                "old_linux_deskflow_sha256": hash,
                "old_linux_deskflow_core_sha256": hash,
                "old_windows_viewflowd_sha256": hash,
                "old_windows_wrapper_sha256": hash,
                "old_windows_task_xml_sha256": hash,
                "old_windows_rollback_sha256": hash,
                "linux_v13_started_receipt_sha256": hash,
                "windows_v13_started_receipt_sha256": hash,
                "authenticated_v13_peer_receipt_sha256": hash,
                "windows_bootstrap_worker_created": false,
                "windows_new_operation_root_present": false,
                "windows_new_task_present": false,
                "windows_installer_process_count": 0,
                "mutation_permit_published": false,
                "force_release_executed": false,
                "rollback_performed": false,
                "windows_rollback_receipt_sha256": null,
                "initial_force_release_executed": false,
                "linux_deskflow_started": false,
                "input_producer_count": 0,
                "protocol_2_1": false,
            });
            let mut bytes = serde_json::to_vec(&value).unwrap();
            bytes.push(b'\n');
            fs::write(&path, &bytes).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            AbortArgs {
                release: fixture.arguments.clone(),
                authorization_path: path,
                authorization_sha256: Sha256::digest(bytes).into(),
            }
        }

        fn write_post_permit_rollback_abort_authorization(
            fixture: &TransactionFixture,
        ) -> AbortArgs {
            let path = fixture
                .parent
                .join("post-permit-rollback-abort-authorization.json");
            let hash = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
            let value = json!({
                "schema_version": 5,
                "state": "viewflow-deployment-quarantine-post-permit-rollback-abort-authorized",
                "operation_id": fixture.arguments.operation_id,
                "coordinator_instance_id": format_uuid(fixture.arguments.coordinator_instance_id),
                "marker_generation": fixture.arguments.marker_generation.to_string(),
                "marker_sha256": hex_lower(&fixture.arguments.marker_sha256),
                "authorization_receipt_path": path.to_string_lossy(),
                "coordinator_terminal_state_sha256": hash,
                "coordinator_failure_phase": "MUTATION_PERMITTED",
                "coordinator_mutation_possible": true,
                "schema1_handoff_lineage_receipt_sha256": hash,
                "marker_handoff_receipt_sha256": hash,
                "deployment_publish_receipt_sha256": hash,
                "linux_frozen_evidence_sha256": hash,
                "bootstrap_request_sha256": hash,
                "windows_prepared_receipt_sha256": hash,
                "mutation_permit_receipt_sha256": hash,
                "installer_exit_receipt_sha256": hash,
                "windows_stop_evidence_sha256": hash,
                "recovery_bundle_sha256": hash,
                "linux_deactivation_proof_sha256": hash,
                "linux_deactivation_transcript_sha256": hash,
                "windows_rollback_receipt_sha256": hash,
                "old_linux_viewflowd_sha256": hash,
                "old_linux_deskflow_sha256": hash,
                "old_linux_deskflow_core_sha256": hash,
                "old_windows_viewflowd_sha256": hash,
                "old_windows_wrapper_sha256": hash,
                "linux_v13_started_receipt_sha256": hash,
                "windows_v13_started_receipt_sha256": hash,
                "authenticated_v13_peer_receipt_sha256": hash,
                "mutation_permit_published": true,
                "force_release_executed": false,
                "rollback_performed": true,
                "initial_force_release_executed": false,
                "second_force_release_executed": false,
                "rollback_token_consumed": true,
                "protocol_2_1": false,
            });
            let mut bytes = serde_json::to_vec(&value).unwrap();
            bytes.push(b'\n');
            fs::write(&path, &bytes).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            AbortArgs {
                release: fixture.arguments.clone(),
                authorization_path: path,
                authorization_sha256: Sha256::digest(bytes).into(),
            }
        }

        fn write_post_force_rollback_abort_authorization(
            fixture: &TransactionFixture,
        ) -> AbortArgs {
            let path = fixture
                .parent
                .join("post-force-rollback-abort-authorization.json");
            let hash = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
            let value = json!({
                "schema_version": 7,
                "state": "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized",
                "operation_id": fixture.arguments.operation_id,
                "coordinator_instance_id": format_uuid(fixture.arguments.coordinator_instance_id),
                "marker_generation": fixture.arguments.marker_generation.to_string(),
                "marker_sha256": hex_lower(&fixture.arguments.marker_sha256),
                "authorization_receipt_path": path.to_string_lossy(),
                "coordinator_terminal_state_sha256": hash,
                "coordinator_failure_phase": "WINDOWS_FORCE_ATTESTED",
                "coordinator_mutation_possible": true,
                "fresh_operation_lineage_receipt_sha256": hash,
                "marker_handoff_receipt_sha256": hash,
                "deployment_publish_receipt_sha256": hash,
                "linux_frozen_evidence_sha256": hash,
                "bootstrap_request_sha256": hash,
                "windows_prepared_receipt_sha256": hash,
                "mutation_permit_receipt_sha256": hash,
                "windows_force_envelope_sha256": hash,
                "windows_stop_evidence_sha256": hash,
                "recovery_bundle_sha256": hash,
                "linux_deactivation_proof_sha256": hash,
                "linux_deactivation_transcript_sha256": hash,
                "windows_rollback_receipt_sha256": hash,
                "old_linux_viewflowd_sha256": hash,
                "old_linux_deskflow_sha256": hash,
                "old_linux_deskflow_core_sha256": hash,
                "old_windows_viewflowd_sha256": hash,
                "old_windows_wrapper_sha256": hash,
                "linux_v13_started_receipt_sha256": hash,
                "windows_v13_started_receipt_sha256": hash,
                "authenticated_v13_peer_receipt_sha256": hash,
                "mutation_permit_published": true,
                "force_release_executed": true,
                "rollback_performed": true,
                "linux_stage_committed": false,
                "windows_install_committed": false,
                "windows_installer_exit_present": false,
                "initial_force_release_executed": true,
                "second_force_release_executed": false,
                "rollback_token_consumed": true,
                "protocol_2_1": false,
            });
            let mut bytes = serde_json::to_vec(&value).unwrap();
            bytes.push(b'\n');
            fs::write(&path, &bytes).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            AbortArgs {
                release: fixture.arguments.clone(),
                authorization_path: path,
                authorization_sha256: Sha256::digest(bytes).into(),
            }
        }

        #[test]
        fn post_permit_rollback_authorization_is_distinct_truthful_and_abi_compatible() {
            let fixture = TransactionFixture::new();
            let arguments = write_post_permit_rollback_abort_authorization(&fixture);
            let authorization = load_abort_authorization(&arguments).unwrap();
            assert!(matches!(
                authorization,
                AbortAuthorization::PostPermitRollbackV5(_)
            ));
            let proof = AbortProof::new(
                fixture.marker_bytes,
                arguments.authorization_sha256,
                1_788_000_000_100,
            )
            .unwrap();
            let encoded = proof.encode();
            assert_eq!(encoded.len(), 384);
            assert_eq!(&encoded[..13], b"VFDQA001\x01\x01\x01\x03\x01");
            assert_eq!(AbortProof::decode(&encoded).unwrap(), proof);
            let receipt = abort_receipt(&arguments, &authorization, &proof, false).unwrap();
            assert_eq!(receipt["schema_version"], 5);
            assert_eq!(
                receipt["authorization_state"],
                "viewflow-deployment-quarantine-post-permit-rollback-abort-authorized"
            );
            assert_eq!(receipt["coordinator_failure_phase"], "MUTATION_PERMITTED");
            assert_eq!(receipt["coordinator_mutation_possible"], true);
            assert_eq!(receipt["mutation_permit_published"], true);
            assert_eq!(receipt["force_release_executed"], false);
            assert_eq!(receipt["rollback_performed"], true);
            assert_eq!(receipt["initial_force_release_executed"], false);
            assert_eq!(receipt["second_force_release_executed"], false);
            assert_eq!(receipt["rollback_token_consumed"], true);
            assert_eq!(
                receipt["abort_point"],
                "abort-claim-atomic-retire-and-parent-directory-fsync"
            );
            for field in [
                "coordinator_terminal_state_sha256",
                "schema1_handoff_lineage_receipt_sha256",
                "marker_handoff_receipt_sha256",
                "deployment_publish_receipt_sha256",
                "linux_frozen_evidence_sha256",
                "bootstrap_request_sha256",
                "windows_prepared_receipt_sha256",
                "mutation_permit_receipt_sha256",
                "installer_exit_receipt_sha256",
                "windows_stop_evidence_sha256",
                "recovery_bundle_sha256",
                "linux_deactivation_proof_sha256",
                "linux_deactivation_transcript_sha256",
                "windows_rollback_receipt_sha256",
                "linux_v13_started_receipt_sha256",
                "windows_v13_started_receipt_sha256",
                "authenticated_v13_peer_receipt_sha256",
            ] {
                assert_eq!(receipt[field], "d".repeat(64), "{field}");
            }
        }

        #[test]
        fn post_force_rollback_v7_is_truthful_distinct_and_abi_compatible() {
            let fixture = TransactionFixture::new();
            let arguments = write_post_force_rollback_abort_authorization(&fixture);
            let authorization = load_abort_authorization(&arguments).unwrap();
            assert!(matches!(
                authorization,
                AbortAuthorization::PostForceRollbackV7(_)
            ));
            let proof = AbortProof::new(
                fixture.marker_bytes,
                arguments.authorization_sha256,
                1_788_000_000_100,
            )
            .unwrap();
            let encoded = proof.encode();
            assert_eq!(encoded.len(), 384);
            assert_eq!(&encoded[..13], b"VFDQA001\x01\x01\x01\x03\x01");
            assert_eq!(AbortProof::decode(&encoded).unwrap(), proof);
            let receipt = abort_receipt(&arguments, &authorization, &proof, false).unwrap();
            assert_eq!(receipt["schema_version"], 7);
            assert_eq!(
                receipt["authorization_state"],
                "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"
            );
            assert_eq!(
                receipt["coordinator_failure_phase"],
                "WINDOWS_FORCE_ATTESTED"
            );
            assert_eq!(receipt["force_release_executed"], true);
            assert_eq!(receipt["rollback_performed"], true);
            assert_eq!(receipt["linux_stage_committed"], false);
            assert_eq!(receipt["windows_install_committed"], false);
            assert_eq!(receipt["windows_installer_exit_present"], false);
            assert_eq!(receipt["initial_force_release_executed"], true);
            assert_eq!(receipt["second_force_release_executed"], false);
            assert_eq!(receipt["rollback_token_consumed"], true);
            for field in [
                "coordinator_terminal_state_sha256",
                "fresh_operation_lineage_receipt_sha256",
                "windows_force_envelope_sha256",
                "windows_rollback_receipt_sha256",
                "authenticated_v13_peer_receipt_sha256",
            ] {
                assert_eq!(receipt[field], "e".repeat(64), "{field}");
            }

            let original = fs::read_to_string(&arguments.authorization_path).unwrap();
            for mutated in [
                original.replace(
                    "\"force_release_executed\":true",
                    "\"force_release_executed\":false",
                ),
                original.replace(
                    "\"linux_stage_committed\":false",
                    "\"linux_stage_committed\":true",
                ),
                original.replace(
                    "\"windows_installer_exit_present\":false",
                    "\"windows_installer_exit_present\":true",
                ),
                original.replacen('{', "{\"unknown\":true,", 1),
            ] {
                fs::write(&arguments.authorization_path, mutated.as_bytes()).unwrap();
                let mut changed = arguments.clone();
                changed.authorization_sha256 = Sha256::digest(mutated.as_bytes()).into();
                assert!(load_abort_authorization(&changed).is_err());
            }
        }

        #[test]
        fn post_permit_rollback_authorization_rejects_unknown_and_false_proofs() {
            let fixture = TransactionFixture::new();
            let arguments = write_post_permit_rollback_abort_authorization(&fixture);
            let original = fs::read_to_string(&arguments.authorization_path).unwrap();
            for changed in [
                original.replacen('{', "{\"unknown\":true,", 1),
                original.replace(
                    "\"rollback_performed\":true",
                    "\"rollback_performed\":false",
                ),
                original.replace(
                    "\"mutation_permit_published\":true",
                    "\"mutation_permit_published\":false",
                ),
                original.replace(
                    "\"force_release_executed\":false",
                    "\"force_release_executed\":true",
                ),
                original.replace(
                    "\"rollback_token_consumed\":true",
                    "\"rollback_token_consumed\":false",
                ),
                original.replace(
                    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                    "0000000000000000000000000000000000000000000000000000000000000000",
                ),
            ] {
                fs::write(&arguments.authorization_path, changed.as_bytes()).unwrap();
                let mut mutated = arguments.clone();
                mutated.authorization_sha256 = Sha256::digest(changed.as_bytes()).into();
                assert!(load_abort_authorization(&mutated).is_err());
            }
        }

        #[test]
        fn post_permit_rollback_abort_replays_exact_durable_vfdqa() {
            let fixture = TransactionFixture::new();
            let arguments = write_post_permit_rollback_abort_authorization(&fixture);
            let authorization = load_abort_authorization(&arguments).unwrap();
            let committed = fixture
                .store
                .abort(&arguments, 1_788_000_000_100, None)
                .unwrap();
            assert!(!committed.replayed);
            let replay = fixture
                .store
                .abort(&arguments, 1_788_000_000_200, None)
                .unwrap();
            assert!(replay.replayed);
            assert_eq!(replay.proof, committed.proof);
            let first = abort_receipt(&arguments, &authorization, &committed.proof, false).unwrap();
            let second = abort_receipt(&arguments, &authorization, &replay.proof, true).unwrap();
            assert_eq!(first["abort_receipt_path"], second["abort_receipt_path"]);
            assert_eq!(
                first["abort_authorization_sha256"],
                second["abort_authorization_sha256"]
            );
            assert_eq!(first["replayed"], false);
            assert_eq!(second["replayed"], true);
        }

        #[test]
        fn publish_cli_is_exact_and_order_independent() {
            let parsed = parse_command(os_args(&[
                "viewflow-deployment-marker",
                "publish",
                "--target-device-id",
                "22222222-2222-2222-2222-222222222222",
                "--operation-id",
                "deploy-20260829-0001",
                "--marker-generation",
                "7",
                "--coordinator-instance-id",
                "33333333-3333-3333-3333-333333333333",
                "--source-display-id",
                "11111111-1111-1111-1111-111111111111",
            ]))
            .unwrap();
            assert!(matches!(
                parsed,
                Command::Publish(PublishArgs {
                    marker_generation: 7,
                    ..
                })
            ));
        }

        #[test]
        fn release_cli_rejects_duplicate_unknown_and_noncanonical_values() {
            let base = [
                "viewflow-deployment-marker",
                "release",
                "--operation-id",
                "deploy-20260829-0001",
                "--coordinator-instance-id",
                "33333333-3333-3333-3333-333333333333",
                "--marker-generation",
                "7",
                "--marker-sha256",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ];
            assert!(matches!(
                parse_command(os_args(&base)),
                Ok(Command::Release(_))
            ));
            let mut query = base;
            query[1] = "query";
            assert!(matches!(
                parse_command(os_args(&query)),
                Ok(Command::QueryRelease(_))
            ));

            let mut duplicate = base.to_vec();
            duplicate.extend(["--marker-generation", "8"]);
            assert!(matches!(
                parse_command(os_args(&duplicate)),
                Err(CliError::Usage(_))
            ));

            let mut unknown = base.to_vec();
            unknown.extend(["--state-directory", "/tmp"]);
            assert!(matches!(
                parse_command(os_args(&unknown)),
                Err(CliError::Usage(_))
            ));

            let mut zero_generation = base;
            zero_generation[7] = "0";
            assert!(matches!(
                parse_command(os_args(&zero_generation)),
                Err(CliError::Usage(_))
            ));
        }

        #[test]
        fn abort_cli_and_abort_query_require_the_exact_authorization_pair() {
            let base = [
                "viewflow-deployment-marker",
                "abort",
                "--operation-id",
                "deploy-20260829-0001",
                "--coordinator-instance-id",
                "33333333-3333-3333-3333-333333333333",
                "--marker-generation",
                "7",
                "--marker-sha256",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "--abort-authorization-path",
                "/tmp/abort-authorization.json",
                "--abort-authorization-sha256",
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            ];
            assert!(matches!(
                parse_command(os_args(&base)),
                Ok(Command::Abort(_))
            ));
            let mut query = base;
            query[1] = "query";
            assert!(matches!(
                parse_command(os_args(&query)),
                Ok(Command::QueryAbort(_))
            ));
            let missing = &base[..base.len() - 2];
            assert!(matches!(
                parse_command(os_args(missing)),
                Err(CliError::Usage(_))
            ));
        }

        #[test]
        fn uuid_and_timestamp_format_are_canonical() {
            let id = parse_uuid("11111111-2222-3333-4444-555555555555").unwrap();
            assert_eq!(format_uuid(id), "11111111-2222-3333-4444-555555555555");
            assert!(parse_uuid("11111111-2222-3333-4444-55555555555A").is_none());
            assert!(parse_uuid("00000000-0000-0000-0000-000000000000").is_none());
            assert_eq!(
                format_unix_milliseconds(1_788_000_000_123).unwrap(),
                "2026-08-29T10:40:00.123Z"
            );
        }

        #[test]
        fn receipt_schemas_have_exact_keys_and_string_encoded_u64s() {
            let publish_arguments = PublishArgs {
                operation_id: "deploy-20260829-0001".to_owned(),
                source_display_id: [0x11; 16],
                target_device_id: [0x22; 16],
                coordinator_instance_id: [0x33; 16],
                marker_generation: u64::MAX,
            };
            let fingerprint = MarkerFingerprint {
                operation_id: publish_arguments.operation_id.clone(),
                coordinator_instance: publish_arguments.coordinator_instance_id,
                generation: publish_arguments.marker_generation,
                content_sha256: [0xaa; 32],
            };
            let published =
                publish_receipt(&publish_arguments, &fingerprint, 1_788_000_000_123).unwrap();
            let published_keys = published
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>();
            assert_eq!(
                published_keys,
                [
                    "coordinator_instance_id",
                    "created_at_unix_ms",
                    "created_at_utc",
                    "marker_generation",
                    "marker_path",
                    "marker_sha256",
                    "operation_id",
                    "protocol_version",
                    "schema_version",
                    "source_display_id",
                    "state",
                    "target_device_id",
                ]
            );
            assert_eq!(published["marker_generation"], u64::MAX.to_string());
            assert_eq!(published["created_at_unix_ms"], "1788000000123");

            let release_arguments = ReleaseArgs {
                operation_id: publish_arguments.operation_id.clone(),
                coordinator_instance_id: publish_arguments.coordinator_instance_id,
                marker_generation: u64::MAX,
                marker_sha256: [0xbb; 32],
            };
            let marker = DeploymentQuarantineMarker {
                operation_id: publish_arguments.operation_id,
                source_display: [0x11; 16],
                target_device: [0x22; 16],
                coordinator_instance: publish_arguments.coordinator_instance_id,
                created_at_unix_ms: 1_788_000_000_000,
                generation: u64::MAX,
            };
            let proof = ReleaseProof::new(marker.encode().unwrap(), 1_788_000_000_123).unwrap();
            let release_arguments = ReleaseArgs {
                marker_sha256: proof.marker_sha256,
                ..release_arguments
            };
            let released = release_receipt(&release_arguments, &proof, false).unwrap();
            let released_keys = released
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>();
            assert_eq!(
                released_keys,
                [
                    "coordinator_instance_id",
                    "marker_created_at_unix_ms",
                    "marker_generation",
                    "marker_path",
                    "operation_id",
                    "protocol_version",
                    "release_claim_path",
                    "release_committed_at_unix_ms",
                    "release_committed_at_utc",
                    "release_point",
                    "release_receipt_path",
                    "released_marker_sha256",
                    "replayed",
                    "schema_version",
                    "source_display_id",
                    "state",
                    "target_device_id",
                ]
            );
            assert_eq!(released["marker_generation"], u64::MAX.to_string());
        }

        #[test]
        fn release_recovers_after_durable_claim_and_replays_exact_receipt() {
            let fixture = TransactionFixture::new();
            assert!(
                fixture
                    .store
                    .release(
                        &fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ClaimSync),
                    )
                    .is_err()
            );
            assert!(!fixture.active_path().exists());
            assert_eq!(
                fs::read(fixture.claim_path()).unwrap(),
                fixture.marker_bytes
            );
            assert_eq!(
                fixture.store.query(&fixture.arguments).unwrap(),
                ReleaseQuery::Claimed
            );

            let mut wrong = fixture.arguments.clone();
            wrong.marker_generation += 1;
            assert!(matches!(
                fixture.store.release(&wrong, 1_788_000_000_200, None),
                Err(MarkerError::AuthorizationMismatch)
            ));
            assert!(fixture.claim_path().exists());

            let completed = fixture
                .store
                .release(&fixture.arguments, 1_788_000_000_300, None)
                .unwrap();
            assert!(!completed.replayed);
            assert!(!fixture.claim_path().exists());
            assert!(fixture.receipt_path().exists());
            assert!(matches!(
                fixture.store.query(&fixture.arguments).unwrap(),
                ReleaseQuery::Released(_)
            ));
            let replay = fixture
                .store
                .release(&fixture.arguments, 1_788_000_000_400, None)
                .unwrap();
            assert!(replay.replayed);
            assert_eq!(replay.proof, completed.proof);
        }

        #[test]
        fn abort_recovers_after_claim_and_replays_without_release_semantics() {
            let fixture = TransactionFixture::new();
            let arguments = write_abort_authorization(&fixture);
            load_abort_authorization(&arguments).unwrap();
            assert!(
                fixture
                    .store
                    .abort(
                        &arguments,
                        1_788_000_000_100,
                        Some(AbortStopPoint::ClaimSync),
                    )
                    .is_err()
            );
            assert!(!fixture.active_path().exists());
            assert_eq!(
                fs::read(fixture.parent.join(ABORT_CLAIM_FILE_NAME)).unwrap(),
                fixture.marker_bytes
            );
            assert_eq!(
                fixture.store.query_abort(&arguments).unwrap(),
                AbortQuery::Claimed
            );
            assert!(matches!(
                fixture.store.query(&fixture.arguments),
                Err(MarkerError::MarkerAlreadyExists)
            ));
            let completed = fixture
                .store
                .abort(&arguments, 1_788_000_000_200, None)
                .unwrap();
            assert!(!completed.replayed);
            assert!(!fixture.parent.join(ABORT_CLAIM_FILE_NAME).exists());
            assert!(matches!(
                fixture.store.query_abort(&arguments).unwrap(),
                AbortQuery::Aborted(_)
            ));
            let replay = fixture
                .store
                .abort(&arguments, 1_788_000_000_300, None)
                .unwrap();
            assert!(replay.replayed);
            assert_eq!(replay.proof, completed.proof);
            let authorization = load_abort_authorization(&arguments).unwrap();
            let json = abort_receipt(&arguments, &authorization, &completed.proof, false).unwrap();
            assert_eq!(json["state"], "deployment-quarantine-aborted");
            assert_eq!(json["protocol_version"], "1.3");
            assert_eq!(json["protocol_2_1"], false);
            assert_eq!(json["deployment_release_claimed"], false);
        }

        #[test]
        fn abort_committed_receipt_and_authorization_mutations_fail_closed() {
            let fixture = TransactionFixture::new();
            let arguments = write_abort_authorization(&fixture);
            assert!(
                fixture
                    .store
                    .abort(
                        &arguments,
                        1_788_000_000_100,
                        Some(AbortStopPoint::ReceiptSync),
                    )
                    .is_err()
            );
            assert!(fixture.parent.join(ABORT_CLAIM_FILE_NAME).exists());
            assert!(matches!(
                fixture.store.query_abort(&arguments).unwrap(),
                AbortQuery::CommittedPendingAbort(_)
            ));
            let receipt_path = fixture.parent.join(abort_receipt_name(
                &arguments.release.marker_sha256,
                &arguments.authorization_sha256,
            ));
            let mut receipt = fs::read(&receipt_path).unwrap();
            receipt[351] = 1;
            fs::write(&receipt_path, receipt).unwrap();
            assert!(
                fixture
                    .store
                    .abort(&arguments, 1_788_000_000_200, None)
                    .is_err()
            );
            assert!(fixture.parent.join(ABORT_CLAIM_FILE_NAME).exists());

            let mut authorization = fs::read(&arguments.authorization_path).unwrap();
            authorization[0] ^= 1;
            fs::write(&arguments.authorization_path, authorization).unwrap();
            assert!(load_abort_authorization(&arguments).is_err());
        }

        #[test]
        fn abort_binary_layout_and_reserved_bytes_are_frozen() {
            let fixture = TransactionFixture::new();
            let arguments = write_abort_authorization(&fixture);
            let proof = AbortProof::new(
                fixture.marker_bytes,
                arguments.authorization_sha256,
                0x0102_0304_0506_0708,
            )
            .unwrap();
            let bytes = proof.encode();
            assert_eq!(&bytes[..8], b"VFDQA001");
            assert_eq!(&bytes[8..13], &[1, 1, 1, 3, 1]);
            assert_eq!(&bytes[16..272], &fixture.marker_bytes);
            assert_eq!(&bytes[272..304], &fixture.arguments.marker_sha256);
            assert_eq!(&bytes[304..336], &arguments.authorization_sha256);
            assert_eq!(&bytes[336..344], &0x0102_0304_0506_0708_u64.to_le_bytes());
            assert!(bytes[13..16].iter().all(|byte| *byte == 0));
            assert!(bytes[344..352].iter().all(|byte| *byte == 0));
            assert_eq!(&bytes[352..384], &Sha256::digest(&bytes[..352])[..]);
            assert_eq!(AbortProof::decode(&bytes).unwrap(), proof);
            for offset in [0, 8, 9, 10, 11, 12, 13, 16, 272, 304, 336, 351, 352, 383] {
                let mut mutated = bytes;
                mutated[offset] ^= 1;
                assert!(AbortProof::decode(&mutated).is_err(), "offset {offset}");
            }
        }

        #[test]
        fn abort_authorization_schema_rejects_unknown_duplicate_and_false_proofs() {
            let fixture = TransactionFixture::new();
            let arguments = write_abort_authorization(&fixture);
            let original = fs::read_to_string(&arguments.authorization_path).unwrap();
            let unknown = original.replacen('{', "{\"unknown\":true,", 1);
            fs::write(&arguments.authorization_path, unknown.as_bytes()).unwrap();
            let mut changed = arguments.clone();
            changed.authorization_sha256 = Sha256::digest(unknown.as_bytes()).into();
            assert!(load_abort_authorization(&changed).is_err());

            let duplicate = original.replacen('{', "{\"schema_version\":1,", 1);
            fs::write(&arguments.authorization_path, duplicate.as_bytes()).unwrap();
            changed.authorization_sha256 = Sha256::digest(duplicate.as_bytes()).into();
            assert!(load_abort_authorization(&changed).is_err());

            let false_protocol =
                original.replace("\"protocol_2_1\":false", "\"protocol_2_1\":true");
            fs::write(&arguments.authorization_path, false_protocol.as_bytes()).unwrap();
            changed.authorization_sha256 = Sha256::digest(false_protocol.as_bytes()).into();
            assert!(load_abort_authorization(&changed).is_err());
        }

        #[test]
        fn pre_mutation_abort_authorization_is_distinct_and_truthful() {
            let fixture = TransactionFixture::new();
            let arguments = write_pre_mutation_abort_authorization(&fixture);
            let authorization = load_abort_authorization(&arguments).unwrap();
            assert!(matches!(
                authorization,
                AbortAuthorization::PreMutationV2(_)
            ));
            let proof = AbortProof::new(
                fixture.marker_bytes,
                arguments.authorization_sha256,
                1_788_000_000_100,
            )
            .unwrap();
            let receipt = abort_receipt(&arguments, &authorization, &proof, false).unwrap();
            assert_eq!(receipt["schema_version"], 2);
            assert_eq!(receipt["initial_force_release_executed"], false);
            assert_eq!(receipt["rollback_performed"], false);
            assert!(receipt["windows_rollback_receipt_sha256"].is_null());
            assert!(receipt.get("second_force_release_executed").is_none());
            assert!(receipt.get("rollback_token_consumed").is_none());
            let keys = receipt
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<std::collections::BTreeSet<_>>();
            let expected = [
                "abort_authorization_path",
                "abort_authorization_sha256",
                "abort_claim_path",
                "abort_committed_at_unix_ms",
                "abort_committed_at_utc",
                "abort_point",
                "abort_receipt_path",
                "aborted_marker_sha256",
                "coordinator_instance_id",
                "deployment_release_claimed",
                "initial_force_release_executed",
                "marker_created_at_unix_ms",
                "marker_generation",
                "marker_path",
                "operation_id",
                "protocol_2_1",
                "protocol_version",
                "replayed",
                "rollback_performed",
                "schema_version",
                "source_display_id",
                "state",
                "target_device_id",
                "windows_rollback_receipt_sha256",
            ]
            .into_iter()
            .collect::<std::collections::BTreeSet<_>>();
            assert_eq!(keys, expected);
        }

        #[test]
        fn early_gate_abort_authorization_is_distinct_and_receipt_bound() {
            let fixture = TransactionFixture::new();
            let arguments = write_early_gate_abort_authorization(&fixture);
            let authorization = load_abort_authorization(&arguments).unwrap();
            assert!(matches!(authorization, AbortAuthorization::EarlyGateV3(_)));
            let proof = AbortProof::new(
                fixture.marker_bytes,
                arguments.authorization_sha256,
                1_788_000_000_100,
            )
            .unwrap();
            let receipt = abort_receipt(&arguments, &authorization, &proof, false).unwrap();
            assert_eq!(receipt["schema_version"], 3);
            assert!(receipt["coordinator_failure_phase"].is_null());
            assert_eq!(receipt["coordinator_mutation_possible"], false);
            assert_eq!(
                receipt["authorization_state"],
                "viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized"
            );
            assert_eq!(receipt["windows_bootstrap_worker_created"], false);
            assert_eq!(receipt["windows_new_operation_root_present"], false);
            assert_eq!(receipt["windows_new_task_present"], false);
            assert_eq!(receipt["windows_installer_process_count"], 0);
            assert_eq!(receipt["mutation_permit_published"], false);
            assert_eq!(receipt["force_release_executed"], false);
            assert_eq!(receipt["rollback_performed"], false);
            assert!(receipt["windows_rollback_receipt_sha256"].is_null());
            assert_eq!(receipt["initial_force_release_executed"], false);
            assert_eq!(receipt["linux_deskflow_started"], false);
            assert_eq!(receipt["input_producer_count"], 0);
            for field in [
                "marker_handoff_receipt_sha256",
                "coordinator_terminal_state_sha256",
                "deployment_publish_receipt_sha256",
                "linux_frozen_evidence_sha256",
                "bootstrap_request_sha256",
                "windows_stop_evidence_sha256",
                "windows_live_proof_sha256",
                "linux_v13_started_receipt_sha256",
                "windows_v13_started_receipt_sha256",
                "authenticated_v13_peer_receipt_sha256",
            ] {
                assert_eq!(receipt[field], "c".repeat(64), "{field}");
            }
        }

        #[test]
        fn early_gate_abort_authorization_rejects_any_positive_producer_claim() {
            let fixture = TransactionFixture::new();
            let arguments = write_early_gate_abort_authorization(&fixture);
            let original = fs::read_to_string(&arguments.authorization_path).unwrap();
            for mutated in [
                original.replace(
                    "\"windows_bootstrap_worker_created\":false",
                    "\"windows_bootstrap_worker_created\":true",
                ),
                original.replace(
                    "\"coordinator_failure_phase\":null",
                    "\"coordinator_failure_phase\":\"WINDOWS_STARTED\"",
                ),
                original.replace(
                    "\"coordinator_mutation_possible\":false",
                    "\"coordinator_mutation_possible\":true",
                ),
                original.replace(
                    "\"windows_new_operation_root_present\":false",
                    "\"windows_new_operation_root_present\":true",
                ),
                original.replace(
                    "\"windows_new_task_present\":false",
                    "\"windows_new_task_present\":true",
                ),
                original.replace(
                    "\"windows_installer_process_count\":0",
                    "\"windows_installer_process_count\":1",
                ),
                original.replace(
                    "\"mutation_permit_published\":false",
                    "\"mutation_permit_published\":true",
                ),
                original.replace(
                    "\"force_release_executed\":false",
                    "\"force_release_executed\":true",
                ),
                original.replace(
                    "\"rollback_performed\":false",
                    "\"rollback_performed\":true",
                ),
                original.replace(
                    "\"initial_force_release_executed\":false",
                    "\"initial_force_release_executed\":true",
                ),
                original.replace(
                    "\"windows_rollback_receipt_sha256\":null",
                    "\"windows_rollback_receipt_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"",
                ),
                original.replace(
                    "\"linux_deskflow_started\":false",
                    "\"linux_deskflow_started\":true",
                ),
                original.replace("\"input_producer_count\":0", "\"input_producer_count\":1"),
                original.replacen('{', "{\"unknown\":true,", 1),
                original.replace(
                    "\"coordinator_terminal_state_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"",
                    "\"coordinator_terminal_state_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"",
                ),
            ] {
                fs::write(&arguments.authorization_path, mutated.as_bytes()).unwrap();
                let mut changed = arguments.clone();
                changed.authorization_sha256 = Sha256::digest(mutated.as_bytes()).into();
                assert!(load_abort_authorization(&changed).is_err());
            }
        }

        #[test]
        fn pre_mutation_abort_authorization_rejects_false_mutation_and_rollback_claims() {
            let fixture = TransactionFixture::new();
            let arguments = write_pre_mutation_abort_authorization(&fixture);
            let original = fs::read_to_string(&arguments.authorization_path).unwrap();
            for mutated in [
                original.replace(
                    "\"initial_force_release_executed\":false",
                    "\"initial_force_release_executed\":true",
                ),
                original.replace("\"rollback_performed\":false", "\"rollback_performed\":true"),
                original.replace(
                    "\"windows_rollback_receipt_sha256\":null",
                    "\"windows_rollback_receipt_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"",
                ),
                original.replacen('{', "{\"unknown\":true,", 1),
            ] {
                fs::write(&arguments.authorization_path, mutated.as_bytes()).unwrap();
                let mut changed = arguments.clone();
                changed.authorization_sha256 = Sha256::digest(mutated.as_bytes()).into();
                assert!(load_abort_authorization(&changed).is_err());
            }
        }

        #[test]
        fn pre_mutation_authorization_rejects_missing_or_mixed_evidence() {
            let fixture = TransactionFixture::new();
            let arguments = write_pre_mutation_abort_authorization(&fixture);
            let original: serde_json::Value =
                serde_json::from_slice(&fs::read(&arguments.authorization_path).unwrap()).unwrap();
            let critical = [
                "marker_handoff_receipt_sha256",
                "deployment_publish_receipt_sha256",
                "linux_frozen_evidence_sha256",
                "installer_exit_receipt_sha256",
                "windows_stop_evidence_sha256",
                "pre_mutation_retry_receipt_sha256",
                "windows_live_proof_sha256",
                "old_linux_viewflowd_sha256",
                "old_linux_deskflow_sha256",
                "old_linux_deskflow_core_sha256",
                "old_windows_viewflowd_sha256",
                "old_windows_wrapper_sha256",
                "old_windows_task_xml_sha256",
                "old_windows_rollback_sha256",
                "linux_v13_started_receipt_sha256",
                "windows_v13_started_receipt_sha256",
                "authenticated_v13_peer_receipt_sha256",
            ];
            for field in critical {
                let mut value = original.clone();
                value.as_object_mut().unwrap().remove(field);
                let mut bytes = serde_json::to_vec(&value).unwrap();
                bytes.push(b'\n');
                fs::write(&arguments.authorization_path, &bytes).unwrap();
                let mut changed = arguments.clone();
                changed.authorization_sha256 = Sha256::digest(&bytes).into();
                assert!(
                    load_abort_authorization(&changed).is_err(),
                    "missing {field}"
                );
            }
            for (field, value) in [
                ("second_force_release_executed", json!(false)),
                ("rollback_token_consumed", json!(false)),
                ("windows_force_envelope_sha256", json!("b".repeat(64))),
                ("windows_migration_receipt_sha256", json!("b".repeat(64))),
            ] {
                let mut mixed = original.clone();
                mixed
                    .as_object_mut()
                    .unwrap()
                    .insert(field.to_owned(), value);
                let mut bytes = serde_json::to_vec(&mixed).unwrap();
                bytes.push(b'\n');
                fs::write(&arguments.authorization_path, &bytes).unwrap();
                let mut changed = arguments.clone();
                changed.authorization_sha256 = Sha256::digest(&bytes).into();
                assert!(load_abort_authorization(&changed).is_err(), "mixed {field}");
            }
        }

        #[test]
        fn pre_mutation_abort_claim_restart_and_replay_are_byte_exact() {
            let fixture = TransactionFixture::new();
            let arguments = write_pre_mutation_abort_authorization(&fixture);
            load_abort_authorization(&arguments).unwrap();
            assert!(
                fixture
                    .store
                    .abort(
                        &arguments,
                        1_788_000_000_100,
                        Some(AbortStopPoint::ClaimSync),
                    )
                    .is_err()
            );
            let completed = fixture
                .store
                .abort(&arguments, 1_788_000_000_200, None)
                .unwrap();
            let durable = fixture.parent.join(abort_receipt_name(
                &arguments.release.marker_sha256,
                &arguments.authorization_sha256,
            ));
            let first_bytes = fs::read(&durable).unwrap();
            let replay = fixture
                .store
                .abort(&arguments, 1_788_000_000_300, None)
                .unwrap();
            assert!(replay.replayed);
            assert_eq!(completed.proof.encode(), replay.proof.encode());
            assert_eq!(first_bytes, fs::read(&durable).unwrap());
            let authorization = load_abort_authorization(&arguments).unwrap();
            let receipt = abort_receipt(&arguments, &authorization, &replay.proof, true).unwrap();
            assert_eq!(receipt["schema_version"], 2);
            assert_eq!(receipt["replayed"], true);
            assert_eq!(receipt["initial_force_release_executed"], false);
            assert_eq!(receipt["rollback_performed"], false);
        }

        #[test]
        fn committed_receipt_never_releases_while_claim_exists() {
            let fixture = TransactionFixture::new();
            assert!(
                fixture
                    .store
                    .release(
                        &fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ReceiptSync),
                    )
                    .is_err()
            );
            assert!(fixture.claim_path().exists());
            assert!(fixture.receipt_path().exists());
            assert!(matches!(
                fixture.store.query(&fixture.arguments).unwrap(),
                ReleaseQuery::CommittedPendingRelease(_)
            ));
            let completed = fixture
                .store
                .release(&fixture.arguments, 1_788_000_000_900, None)
                .unwrap();
            assert!(completed.replayed);
            assert_eq!(completed.proof.committed_at_unix_ms, 1_788_000_000_100);
            assert!(!fixture.claim_path().exists());
        }

        #[test]
        fn receipt_and_claim_mutations_are_retained_fail_closed() {
            let fixture = TransactionFixture::new();
            assert!(
                fixture
                    .store
                    .release(
                        &fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ReceiptSync),
                    )
                    .is_err()
            );
            let mut receipt = fs::read(fixture.receipt_path()).unwrap();
            receipt[319] = 1;
            fs::write(fixture.receipt_path(), receipt).unwrap();
            assert!(
                fixture
                    .store
                    .release(&fixture.arguments, 1_788_000_000_200, None)
                    .is_err()
            );
            assert!(fixture.claim_path().exists());

            fs::remove_file(fixture.receipt_path()).unwrap();
            let mut claim = fs::read(fixture.claim_path()).unwrap();
            claim[255] = 1;
            fs::write(fixture.claim_path(), claim).unwrap();
            assert!(fixture.store.query(&fixture.arguments).is_err());
            assert!(fixture.claim_path().exists());
        }

        #[test]
        fn valid_looking_claim_swap_is_rejected_and_never_unlinked() {
            let fixture = TransactionFixture::new();
            assert!(
                fixture
                    .store
                    .release(
                        &fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ReceiptSync),
                    )
                    .is_err()
            );
            let swapped_marker = DeploymentQuarantineMarker {
                operation_id: fixture.arguments.operation_id.clone(),
                source_display: [0x11; 16],
                target_device: [0x22; 16],
                coordinator_instance: fixture.arguments.coordinator_instance_id,
                created_at_unix_ms: 1_788_000_000_000,
                generation: fixture.arguments.marker_generation + 1,
            }
            .encode()
            .unwrap();
            fs::remove_file(fixture.claim_path()).unwrap();
            fs::write(fixture.claim_path(), swapped_marker).unwrap();
            fs::set_permissions(fixture.claim_path(), fs::Permissions::from_mode(0o600)).unwrap();
            assert!(matches!(
                fixture
                    .store
                    .release(&fixture.arguments, 1_788_000_000_200, None),
                Err(MarkerError::AuthorizationMismatch)
            ));
            assert_eq!(fs::read(fixture.claim_path()).unwrap(), swapped_marker);
        }

        #[test]
        fn release_atomic_retirement_never_deletes_late_claim_replacement() {
            let fixture = TransactionFixture::new();
            assert!(
                fixture
                    .store
                    .release(
                        &fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ClaimRetire),
                    )
                    .is_err()
            );
            assert!(!fixture.claim_path().exists());
            assert_eq!(
                fs::read(fixture.release_retired_path()).unwrap(),
                fixture.marker_bytes
            );
            let replacement = DeploymentQuarantineMarker {
                operation_id: fixture.arguments.operation_id.clone(),
                source_display: [0x11; 16],
                target_device: [0x22; 16],
                coordinator_instance: fixture.arguments.coordinator_instance_id,
                created_at_unix_ms: 1_788_000_000_001,
                generation: fixture.arguments.marker_generation + 1,
            }
            .encode()
            .unwrap();
            fs::write(fixture.claim_path(), replacement).unwrap();
            fs::set_permissions(fixture.claim_path(), fs::Permissions::from_mode(0o600)).unwrap();

            assert!(matches!(
                fixture
                    .store
                    .release(&fixture.arguments, 1_788_000_000_200, None),
                Err(MarkerError::MarkerAlreadyExists)
            ));
            assert_eq!(fs::read(fixture.claim_path()).unwrap(), replacement);
            assert_eq!(
                fs::read(fixture.release_retired_path()).unwrap(),
                fixture.marker_bytes
            );
        }

        #[test]
        fn pre_rename_source_swap_is_retained_and_never_reports_success() {
            let fixture = TransactionFixture::new();
            assert!(
                fixture
                    .store
                    .release(
                        &fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ReceiptSync),
                    )
                    .is_err()
            );
            let replacement = DeploymentQuarantineMarker {
                operation_id: fixture.arguments.operation_id.clone(),
                source_display: [0x11; 16],
                target_device: [0x22; 16],
                coordinator_instance: fixture.arguments.coordinator_instance_id,
                created_at_unix_ms: 1_788_000_000_001,
                generation: fixture.arguments.marker_generation + 1,
            }
            .encode()
            .unwrap();
            let claim_path = fixture.claim_path();
            let retired_path = fixture.release_retired_path();
            let retired_name = release_retired_name(&fixture.arguments.marker_sha256);
            let guard = fixture.store.lock(FlockOperation::LockExclusive).unwrap();
            let result = guard.retire_claim_with_hook(
                RELEASE_CLAIM_FILE_NAME,
                &retired_name,
                &fixture.marker_bytes,
                "release",
                false,
                || {
                    fs::remove_file(&claim_path)
                        .map_err(|source| marker_io("test swap remove", source))?;
                    fs::write(&claim_path, replacement)
                        .map_err(|source| marker_io("test swap write", source))?;
                    fs::set_permissions(&claim_path, fs::Permissions::from_mode(0o600))
                        .map_err(|source| marker_io("test swap mode", source))?;
                    Ok(())
                },
            );
            assert!(matches!(result, Err(MarkerError::AuthorizationMismatch)));
            assert!(!claim_path.exists());
            assert_eq!(fs::read(retired_path).unwrap(), replacement);
        }

        #[test]
        fn abort_atomic_retirement_never_deletes_late_claim_replacement() {
            let fixture = TransactionFixture::new();
            let arguments = write_abort_authorization(&fixture);
            assert!(
                fixture
                    .store
                    .abort(
                        &arguments,
                        1_788_000_000_100,
                        Some(AbortStopPoint::ClaimRetire),
                    )
                    .is_err()
            );
            let claim_path = fixture.parent.join(ABORT_CLAIM_FILE_NAME);
            let retired_path = fixture.abort_retired_path(&arguments);
            assert!(!claim_path.exists());
            assert_eq!(fs::read(&retired_path).unwrap(), fixture.marker_bytes);
            let replacement = DeploymentQuarantineMarker {
                operation_id: fixture.arguments.operation_id.clone(),
                source_display: [0x11; 16],
                target_device: [0x22; 16],
                coordinator_instance: fixture.arguments.coordinator_instance_id,
                created_at_unix_ms: 1_788_000_000_001,
                generation: fixture.arguments.marker_generation + 1,
            }
            .encode()
            .unwrap();
            fs::write(&claim_path, replacement).unwrap();
            fs::set_permissions(&claim_path, fs::Permissions::from_mode(0o600)).unwrap();

            assert!(matches!(
                fixture.store.abort(&arguments, 1_788_000_000_200, None),
                Err(MarkerError::MarkerAlreadyExists)
            ));
            assert_eq!(fs::read(&claim_path).unwrap(), replacement);
            assert_eq!(fs::read(&retired_path).unwrap(), fixture.marker_bytes);
        }

        #[test]
        fn retired_claim_restart_replays_without_path_unlink() {
            let fixture = TransactionFixture::new();
            assert!(
                fixture
                    .store
                    .release(
                        &fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ClaimRetire),
                    )
                    .is_err()
            );
            let replay = fixture
                .store
                .release(&fixture.arguments, 1_788_000_000_200, None)
                .unwrap();
            assert!(replay.replayed);
            assert!(fixture.release_retired_path().exists());
            assert!(matches!(
                fixture.store.query(&fixture.arguments).unwrap(),
                ReleaseQuery::Released(_)
            ));
        }

        #[test]
        fn receipt_no_clobber_rejects_symlink_and_hardlink_destinations() {
            let symlink_fixture = TransactionFixture::new();
            assert!(
                symlink_fixture
                    .store
                    .release(
                        &symlink_fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ClaimSync),
                    )
                    .is_err()
            );
            fs::write(symlink_fixture.parent.join("outside-receipt"), [0_u8; 352]).unwrap();
            symlink(
                symlink_fixture.parent.join("outside-receipt"),
                symlink_fixture.receipt_path(),
            )
            .unwrap();
            assert!(
                symlink_fixture
                    .store
                    .release(&symlink_fixture.arguments, 1_788_000_000_200, None)
                    .is_err()
            );
            assert!(symlink_fixture.claim_path().exists());

            let hardlink_fixture = TransactionFixture::new();
            assert!(
                hardlink_fixture
                    .store
                    .release(
                        &hardlink_fixture.arguments,
                        1_788_000_000_100,
                        Some(ReleaseStopPoint::ReceiptSync),
                    )
                    .is_err()
            );
            fs::hard_link(
                hardlink_fixture.receipt_path(),
                hardlink_fixture.parent.join("receipt-alias"),
            )
            .unwrap();
            assert!(
                hardlink_fixture
                    .store
                    .release(&hardlink_fixture.arguments, 1_788_000_000_200, None)
                    .is_err()
            );
            assert!(hardlink_fixture.claim_path().exists());
        }

        #[test]
        fn binary_receipt_layout_and_reserved_bytes_are_frozen() {
            let fixture = TransactionFixture::new();
            let proof = ReleaseProof::new(fixture.marker_bytes, 0x0102_0304_0506_0708).unwrap();
            let bytes = proof.encode();
            assert_eq!(&bytes[..8], b"VFDQR001");
            assert_eq!(&bytes[8..13], &[1, 1, 2, 1, 1]);
            assert_eq!(&bytes[16..272], &fixture.marker_bytes);
            assert_eq!(&bytes[272..304], &fixture.arguments.marker_sha256);
            assert_eq!(&bytes[304..312], &0x0102_0304_0506_0708_u64.to_le_bytes());
            assert!(bytes[13..16].iter().all(|byte| *byte == 0));
            assert!(bytes[312..320].iter().all(|byte| *byte == 0));
            assert_eq!(&bytes[320..352], &Sha256::digest(&bytes[..320])[..]);
            assert_eq!(ReleaseProof::decode(&bytes).unwrap(), proof);

            for offset in [0, 8, 9, 10, 11, 12, 13, 16, 272, 304, 319, 320, 351] {
                let mut mutated = bytes;
                mutated[offset] ^= 1;
                assert!(ReleaseProof::decode(&mutated).is_err(), "offset {offset}");
            }
        }

        #[test]
        fn symlink_hardlink_mode_and_acl_claims_are_never_accepted() {
            let symlink_fixture = TransactionFixture::new();
            fs::rename(
                symlink_fixture.active_path(),
                symlink_fixture.parent.join("outside"),
            )
            .unwrap();
            symlink(
                symlink_fixture.parent.join("outside"),
                symlink_fixture.claim_path(),
            )
            .unwrap();
            assert!(
                symlink_fixture
                    .store
                    .query(&symlink_fixture.arguments)
                    .is_err()
            );

            let hardlink_fixture = TransactionFixture::new();
            fs::rename(
                hardlink_fixture.active_path(),
                hardlink_fixture.claim_path(),
            )
            .unwrap();
            fs::hard_link(
                hardlink_fixture.claim_path(),
                hardlink_fixture.parent.join("claim-alias"),
            )
            .unwrap();
            assert!(
                hardlink_fixture
                    .store
                    .query(&hardlink_fixture.arguments)
                    .is_err()
            );

            let mode_fixture = TransactionFixture::new();
            fs::rename(mode_fixture.active_path(), mode_fixture.claim_path()).unwrap();
            fs::set_permissions(mode_fixture.claim_path(), fs::Permissions::from_mode(0o640))
                .unwrap();
            assert!(mode_fixture.store.query(&mode_fixture.arguments).is_err());

            let acl_fixture = TransactionFixture::new();
            fs::rename(acl_fixture.active_path(), acl_fixture.claim_path()).unwrap();
            let status = ProcessCommand::new("setfacl")
                .args(["-m", "u:65534:r--"])
                .arg(acl_fixture.claim_path())
                .status()
                .expect("setfacl is required by the Linux release contract test");
            assert!(status.success());
            assert!(acl_fixture.store.query(&acl_fixture.arguments).is_err());
        }

        #[test]
        fn unsafe_or_swapped_lock_is_rejected_without_touching_active() {
            let fixture = TransactionFixture::new();
            let lock_path = fixture.parent.join(LOCK_FILE_NAME);
            fs::write(&lock_path, []).unwrap();
            fs::set_permissions(&lock_path, fs::Permissions::from_mode(0o600)).unwrap();
            fs::hard_link(&lock_path, fixture.parent.join("lock-alias")).unwrap();
            assert!(fixture.store.query(&fixture.arguments).is_err());
            assert_eq!(
                fs::read(fixture.active_path()).unwrap(),
                fixture.marker_bytes
            );
        }
    }
}

#[cfg(target_os = "linux")]
fn main() -> std::process::ExitCode {
    linux_cli::main()
}

#[cfg(not(target_os = "linux"))]
fn main() -> std::process::ExitCode {
    eprintln!("viewflow-deployment-marker: Linux production marker storage is unavailable");
    std::process::ExitCode::from(69)
}
