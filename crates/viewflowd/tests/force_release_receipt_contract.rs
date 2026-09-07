use std::{env, fs, path::Path};

use serde::Serialize;
use serde_json::Value;

const PRODUCER_SOURCE: &str = include_str!("../src/bootstrap_runtime.rs");
const OPERATION_ID: &str = "deploy-20260829-abcdef";
const LINUX_EVIDENCE_SHA256: &str =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const TOOL_SHA256: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

#[derive(Serialize)]
struct ContractReceipt<'a> {
    schema_version: u32,
    state: &'static str,
    operation_id: &'a str,
    linux_frozen_evidence_sha256: &'a str,
    tool_executable_sha256: &'a str,
    tool_pid: u32,
    tool_process_start_filetime: String,
    tool_session_id: u32,
    tool_user_sid: &'a str,
    input_desktop: &'a str,
    requested_input_count: u32,
    inserted_input_count: u32,
    verification_stable_ms: u64,
    completed_at_utc: &'a str,
}

fn contract_receipt(completed_at_utc: &str) -> ContractReceipt<'_> {
    ContractReceipt {
        schema_version: 3,
        state: "viewflow-force-release-completed",
        operation_id: OPERATION_ID,
        linux_frozen_evidence_sha256: LINUX_EVIDENCE_SHA256,
        tool_executable_sha256: TOOL_SHA256,
        tool_pid: 42,
        tool_process_start_filetime: u64::MAX.to_string(),
        tool_session_id: 1,
        tool_user_sid: "S-1-5-21-1",
        input_desktop: "Default",
        requested_input_count: 135,
        inserted_input_count: 135,
        verification_stable_ms: 500,
        completed_at_utc,
    }
}

fn producer_receipt_fields() -> Vec<(String, String)> {
    let declaration = "struct ForceReleaseReceipt<'a> {";
    let after_start = PRODUCER_SOURCE
        .split_once(declaration)
        .expect("ForceReleaseReceipt declaration is missing")
        .1;
    let body = after_start
        .split_once("\n}")
        .expect("ForceReleaseReceipt declaration is not closed")
        .0;

    body.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| {
            let line = line
                .strip_suffix(',')
                .expect("receipt field declaration must end in a comma");
            let (name, ty) = line
                .split_once(':')
                .expect("receipt field declaration must contain a colon");
            (name.trim().to_owned(), ty.trim().to_owned())
        })
        .collect()
}

fn assert_producer_contract() {
    let expected = [
        ("schema_version", "u32"),
        ("state", "&'static str"),
        ("operation_id", "&'a str"),
        ("linux_frozen_evidence_sha256", "&'a str"),
        ("tool_executable_sha256", "String"),
        ("tool_pid", "u32"),
        ("tool_process_start_filetime", "String"),
        ("tool_session_id", "u32"),
        ("tool_user_sid", "String"),
        ("input_desktop", "String"),
        ("requested_input_count", "u32"),
        ("inserted_input_count", "u32"),
        ("verification_stable_ms", "u64"),
        ("completed_at_utc", "String"),
    ];
    let expected = expected
        .into_iter()
        .map(|(name, ty)| (name.to_owned(), ty.to_owned()))
        .collect::<Vec<_>>();

    assert_eq!(producer_receipt_fields(), expected);
    for required_source in [
        "const REQUIRED_SESSION_ID: u32 = 1;",
        "const REQUIRED_INPUT_COUNT: u32 = 135;",
        "const VERIFICATION_STABLE: Duration = Duration::from_millis(500);",
        "schema_version: 3,",
        "state: \"viewflow-force-release-completed\",",
        "linux_frozen_evidence_sha256: &config.linux_frozen_evidence_sha256,",
        "tool_process_start_filetime: process_start_filetime.to_string(),",
    ] {
        assert!(
            PRODUCER_SOURCE.contains(required_source),
            "producer contract source is missing: {required_source}"
        );
    }
}

fn assert_exact_fixture_types(value: &Value, completed_at_utc: &str) {
    let object = value
        .as_object()
        .expect("receipt fixture must be an object");
    assert_eq!(object.len(), 14);
    assert_eq!(value["schema_version"], 3);
    assert_eq!(value["state"], "viewflow-force-release-completed");
    assert_eq!(value["operation_id"], OPERATION_ID);
    assert_eq!(value["linux_frozen_evidence_sha256"], LINUX_EVIDENCE_SHA256);
    assert_eq!(value["tool_executable_sha256"], TOOL_SHA256);
    assert_eq!(value["tool_pid"], 42);
    assert!(value["tool_pid"].is_u64());
    assert_eq!(value["tool_process_start_filetime"], u64::MAX.to_string());
    assert!(value["tool_process_start_filetime"].is_string());
    assert_eq!(value["tool_session_id"], 1);
    assert_eq!(value["tool_user_sid"], "S-1-5-21-1");
    assert_eq!(value["input_desktop"], "Default");
    assert_eq!(value["requested_input_count"], 135);
    assert_eq!(value["inserted_input_count"], 135);
    assert_eq!(value["verification_stable_ms"], 500);
    assert_eq!(value["completed_at_utc"], completed_at_utc);
}

#[test]
fn producer_schema_matches_cross_language_contract() {
    assert_producer_contract();
    let timestamp = "2026-08-29T12:34:56.789Z";
    let value = serde_json::to_value(contract_receipt(timestamp)).unwrap();
    assert_exact_fixture_types(&value, timestamp);
}

#[test]
#[ignore = "called by the PS5.1 contract harness to emit a fresh Rust fixture"]
fn emit_force_release_receipt_fixture() {
    assert_producer_contract();
    let output = env::var_os("VIEWFLOW_FORCE_RELEASE_FIXTURE")
        .expect("VIEWFLOW_FORCE_RELEASE_FIXTURE must name the output file");
    let completed_at_utc = env::var("VIEWFLOW_FORCE_RELEASE_COMPLETED_AT_UTC")
        .expect("VIEWFLOW_FORCE_RELEASE_COMPLETED_AT_UTC must be set");
    assert_eq!(completed_at_utc.len(), 24);
    assert!(completed_at_utc.ends_with('Z'));

    let receipt = contract_receipt(&completed_at_utc);
    let value = serde_json::to_value(&receipt).unwrap();
    assert_exact_fixture_types(&value, &completed_at_utc);
    let bytes = serde_json::to_vec_pretty(&receipt).unwrap();
    fs::write(Path::new(&output), bytes).expect("failed to write Rust receipt fixture");
}
