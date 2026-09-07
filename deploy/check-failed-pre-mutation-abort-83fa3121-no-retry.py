#!/usr/bin/env python3
"""Static freeze checker for the operation-83fa no-retry V4 abort."""

import argparse
import ast
import hashlib
import json
import re
import sys
from pathlib import Path

OP = "83fa3121bcb645e5847db05cc8cd5250"
SHA = re.compile(r"[0-9a-f]{64}")


def fail(message):
    raise SystemExit("83fa V4 checker: " + message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assigned_dict(tree, name, label):
    matches = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Dict):
            continue
        if any(isinstance(target, ast.Name) and target.id == name for target in node.targets):
            matches.append(node.value)
    if len(matches) != 1:
        fail(f"{label} assignment count differs")
    result = {}
    for key, value in zip(matches[0].keys, matches[0].values):
        if not isinstance(key, ast.Constant) or not isinstance(key.value, str) or key.value in result:
            fail(f"{label} keys are not exact")
        result[key.value] = value
    return result


def is_empty_global_process_comparison(node):
    if not isinstance(node, ast.Compare) or len(node.ops) != 1 or not isinstance(node.ops[0], ast.Eq):
        return False
    if len(node.comparators) != 1 or not isinstance(node.comparators[0], ast.List):
        return False
    if node.comparators[0].elts:
        return False
    subscript = node.left
    return (isinstance(subscript, ast.Subscript)
            and isinstance(subscript.value, ast.Name)
            and subscript.value.id == "result"
            and isinstance(subscript.slice, ast.Constant)
            and subscript.slice.value == "global_relevant_processes")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="/home/wilf/data/viewflow")
    parser.add_argument("--gate", default="deploy/gate-failed-pre-mutation-abort-83fa3121-no-retry.py")
    parser.add_argument("--manifest", default="deploy/failed-pre-mutation-abort-83fa3121-no-retry-manifest.json")
    parser.add_argument("--launcher", default="deploy/launch-failed-pre-mutation-abort-83fa3121-no-retry.sh")
    args = parser.parse_args()
    root = Path(args.root)
    gate_path = root / args.gate
    manifest_path = root / args.manifest
    launcher_path = root / args.launcher
    gate = gate_path.read_text(encoding="utf-8")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    launcher = launcher_path.read_text(encoding="utf-8")
    baseline = manifest.get("windows_baseline")
    expected_baseline_keys = {
        "ssh_host", "user_sid", "viewflowd_sha256", "wrapper_sha256", "rollback_sha256",
        "old_task_xml_sha256", "old_task_action_sha256", "old_task_principal_sha256",
        "old_peer_pid", "old_peer_parent_pid", "old_peer_start_filetime_utc",
        "old_peer_command_line_sha256", "operation_root", "deployment_task_name",
        "deployment_task_state", "deployment_task_xml_sha256", "deployment_task_live_xml_sha256",
        "global_relevant_processes",
    }
    if not isinstance(baseline, dict) or set(baseline) != expected_baseline_keys:
        fail("Windows baseline schema differs")
    global_processes = baseline["global_relevant_processes"]
    expected_process_keys = {"pid", "parent_pid", "executable_path", "command_line_sha256"}
    if not isinstance(global_processes, list) or not global_processes:
        fail("Windows global process census is not a fixed non-empty list")
    seen_pids = set()
    for process in global_processes:
        if not isinstance(process, dict) or set(process) != expected_process_keys:
            fail("Windows global process census schema differs")
        if (not isinstance(process["pid"], int) or process["pid"] <= 0
                or not isinstance(process["parent_pid"], int) or process["parent_pid"] < 0
                or not isinstance(process["executable_path"], str)
                or not process["executable_path"].startswith("C:\\")
                or not SHA.fullmatch(process["command_line_sha256"])
                or process["pid"] in seen_pids):
            fail("Windows global process census identity differs")
        seen_pids.add(process["pid"])
    tree = ast.parse(gate)
    functions = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    forbidden = {"abort_transaction", "vfdqa_bytes", "validate_vfdqa", "_read_named"}
    if functions & forbidden or "python-replica" in gate:
        fail("Python marker transaction implementation remains")
    required_functions = {"run_sealed_marker_cli", "validate_native_receipt", "authorization",
                          "linux_boundary", "collect_windows", "create_once", "persisted_or_create"}
    required_functions.add("commit_terminal_under_marker_lock")
    if not required_functions <= functions:
        fail("native gate functions differ")
    linux_fn = next((node for node in tree.body
                     if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                     and node.name == "linux_boundary"), None)
    if linux_fn is None or not any(is_empty_global_process_comparison(node)
                                   for node in ast.walk(linux_fn)):
        fail("Linux boundary no longer rejects relevant processes")
    terminal = assigned_dict(tree, "terminal", "terminal")
    expected_terminal_keys = {
        "schema_version", "state", "operation_id", "coordinator_terminal_state_sha256",
        "coordinator_failure_phase", "coordinator_mutation_possible", "authorization_sha256",
        "abort_receipt_sha256", "abort_query_receipt_sha256", "vfdqa_binary_sha256",
        "execution_approval_sha256", "manifest_sha256", "gate_sha256", "launcher_sha256",
        "v4_marker_cli_sha256", "v4_marker_cli_provenance_sha256", "linux_inactive_pre_sha256",
        "windows_old_peer_live_sha256", "linux_inactive_post_sha256",
        "windows_operation_root_inventory_sha256", "windows_old_peer_post_sha256", "marker_absent",
        "abort_claim_absent", "release_claim_absent", "runtime_marker_absent",
        "linux_viewflow_started", "linux_deskflow_started", "input_producer_count",
        "windows_old_peer_unchanged", "windows_operation_root_present",
        "windows_operation_root_unchanged", "windows_deployment_task_state",
        "mutation_outputs_absent", "protocol_2_1",
    }
    if set(terminal) != expected_terminal_keys:
        fail("terminal schema differs")
    expected_terminal_values = {
        "schema_version": 4,
        "state": "viewflow-failed-pre-mutation-no-retry-vfdqa-abort-terminal",
        "coordinator_failure_phase": "WINDOWS_STARTED",
        "coordinator_mutation_possible": False,
        "marker_absent": True,
        "abort_claim_absent": True,
        "release_claim_absent": True,
        "runtime_marker_absent": True,
        "linux_viewflow_started": False,
        "linux_deskflow_started": False,
        "input_producer_count": 0,
        "windows_old_peer_unchanged": True,
        "windows_operation_root_present": True,
        "windows_operation_root_unchanged": True,
        "windows_deployment_task_state": "Disabled",
        "mutation_outputs_absent": True,
        "protocol_2_1": False,
    }
    for key, expected in expected_terminal_values.items():
        value = terminal[key]
        if not isinstance(value, ast.Constant) or value.value != expected:
            fail("terminal critical value differs: " + key)
    task_name = "-TaskName ('Viewflow Deployment '+$op)"
    if gate.count(task_name) != 2 or "-TaskName 'Viewflow Deployment '+$op" in gate:
        fail("PowerShell deployment task-name expression is not PS5.1-safe")
    if "|Sort-Object ProcessId|ForEach-Object" not in gate:
        fail("Windows global process census is not deterministically ordered")
    if "os.fstat(fd) != before" in gate or "os.fstat(fd) != before" in launcher:
        fail("sealed input stability check incorrectly includes mutable atime")
    if ('"global_relevant_processes": baseline["global_relevant_processes"]' not in gate
            or '"global_relevant_processes": [{"pid"' in gate):
        fail("Windows global process census binding differs")
    if '"deployment_task_xml_sha256": baseline["deployment_task_live_xml_sha256"]' not in gate:
        fail("Windows live deployment task XML binding differs")
    abort = gate.find('run_sealed_marker_cli(manifest, "abort"')
    query = gate.find('run_sealed_marker_cli(manifest, "query"')
    if abort < 0 or query <= abort or "F_ADD_SEALS" not in gate or "F_GET_SEALS" not in gate:
        fail("sealed native abort/query ordering differs")
    final_query = gate.rfind('run_sealed_marker_cli(manifest, "query"')
    terminal_commit = gate.rfind("commit_terminal_under_marker_lock(")
    if final_query <= query or terminal_commit <= final_query or 'create_once(outputs["terminal"]' in gate:
        fail("terminal is not committed under the marker transaction lock")
    for option in ("--operation-id", "--coordinator-instance-id", "--marker-generation",
                   "--marker-sha256", "--abort-authorization-path",
                   "--abort-authorization-sha256"):
        if gate.count('"' + option + '"') != 1:
            fail("native marker argv is not exact-once: " + option)
    if "pre_mutation_retry" in gate:
        fail("V4 gate contains a retry field or reference")
    for token in (digest(gate_path), digest(manifest_path), "/usr/bin/python3 -I",
                  "/usr/bin/env -i", "os.memfd_create", "F_ADD_SEALS", "F_GET_SEALS",
                  "stable_read(GATE", "stable_read(MANIFEST", "stable_read(launcher_path"):
        if token not in launcher:
            fail("fixed-binding sealed launcher differs: " + token)
    if "PLACEHOLDER" in launcher or "open_exact(__file__" in gate:
        fail("launcher/gate still permits path execution")
    if not (manifest.get("schema_version") == 4 and manifest.get("execution_authorized") is False
            and manifest.get("operation_id") == OP
            and manifest.get("threat_boundary") == "cooperating-crash-same-uid-concurrency-path-swap-and-non-owner"):
        fail("manifest class differs")
    retry_path = f"/home/wilf/.local/state/viewflow/deployments/{OP}/coordinator-state.json.pre-mutation-retry.json"
    retry_paths = [path for path in manifest["local_required_absent"] if "retry" in path]
    if retry_paths != [retry_path]:
        fail("exact retry absence path differs")
    inventory = manifest["windows_operation_root_inventory"]
    if inventory.get("member_count") != 14 or inventory.get("stable") is not True:
        fail("exact Windows inventory binding differs")
    v4 = manifest["v4_marker_cli"]
    for spec in (v4, v4["provenance"]):
        if not SHA.fullmatch(spec["sha256"]):
            fail("V4 candidate/provenance SHA differs")
    if digest(Path(v4["path"])) != v4["sha256"] or digest(Path(v4["provenance"]["path"])) != v4["provenance"]["sha256"]:
        fail("V4 candidate/provenance bytes differ")
    source = (root / "deploy/rust-marker-no-retry-v4-83fa/src/main.rs").read_text(encoding="utf-8")
    for token in ("NoRetryV4", "deny_unknown_fields", "no_retry_v4_rejects_every_false_claim_class",
                  "no_retry_v4_receipt_keys_are_exact", "no_retry_v4_after_receipt_sync_retains_claim_and_replays",
                  "symlink_hardlink_mode_and_acl_claims_are_never_accepted",
                  "valid_looking_claim_swap_is_rejected_and_never_unlinked",
                  "parent_acl_and_intermediate_symlink_are_rejected",
                  "parent_path_swap_after_lock_is_rejected_before_named_io",
                  "named_file_swap_after_read_is_rejected",
                  "abort_final_identity_swap_never_unlinks_replacement"):
        if token not in source:
            fail("standalone Rust V4 freeze differs: " + token)
    if "build.rs" in (root / "deploy/rust-marker-no-retry-v4-83fa/Cargo.toml").read_text(encoding="utf-8"):
        fail("dynamic build-time source transform returned")
    print("83fa no-retry V4 static freeze checker passed")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        fail(str(error))
