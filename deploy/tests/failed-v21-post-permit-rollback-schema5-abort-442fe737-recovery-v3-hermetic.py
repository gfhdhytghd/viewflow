#!/usr/bin/env python3
"""Hermetic contract checks for op442 post-commit recovery v3."""

import base64
import gzip
import hashlib
import importlib.util
import json
import os
import pathlib
import tempfile

ROOT = pathlib.Path("/home/wilf/data/viewflow")
GATE = pathlib.Path(os.environ.get("VF_OP442_RECOVERY_V3_GATE",
    ROOT / "deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-gate.py"))
MANIFEST = pathlib.Path(os.environ.get("VF_OP442_RECOVERY_V3_MANIFEST",
    ROOT / "deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-manifest.json"))
spec = importlib.util.spec_from_file_location("op442_recovery_v3", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
manifest = json.loads(MANIFEST.read_bytes())


def must_fail(callable_value, label):
    try:
        callable_value()
    except (gate.GateError, OSError, ValueError, gate.subprocess.SubprocessError,
            KeyError, TypeError):
        return
    raise AssertionError(label + " was accepted")


predecessor, v2_manifest, documents, receipt_raw, receipt = gate.validate_manifest(manifest)
assert "run_coordinator" not in GATE.read_text()
assert manifest["predecessor_v2"]["approval"]["sha256"] == \
    hashlib.sha256(pathlib.Path(manifest["predecessor_v2"]["approval"]["path"]).read_bytes()).hexdigest()
assert manifest["post_abort"]["durable_vfdqa"]["sha256"] == \
    hashlib.sha256(pathlib.Path(manifest["post_abort"]["durable_vfdqa"]["path"]).read_bytes()).hexdigest()
assert receipt["replayed"] is False

# Only the exact recovery-v3 approval may be present for first execution; the
# old v1 query/terminal and the two new recovery outputs remain fresh.
real_lexists = gate.os.path.lexists
approval = manifest["approval_path"]
gate.os.path.lexists = lambda path: path == approval or real_lexists(path)
try:
    gate.validate_manifest(manifest, True, False)
    must_fail(lambda: gate.validate_manifest(manifest, False, False),
              "recovery-v3 offline approval presence")
finally:
    gate.os.path.lexists = real_lexists
query_path = manifest["outputs"]["query"]
gate.os.path.lexists = lambda path: path in (approval, query_path) or real_lexists(path)
try:
    must_fail(lambda: gate.validate_manifest(manifest, True, False),
              "first recovery execution with existing query")
    gate.validate_manifest(manifest, True, True)
finally:
    gate.os.path.lexists = real_lexists

# The predecessor-v2 approval cannot authorize recovery-v3.
old_approval = pathlib.Path(manifest["predecessor_v2"]["approval"]["path"]).read_bytes()
must_fail(lambda: gate.validate_recovery_approval(manifest, old_approval,
    manifest["predecessor_v2"]["manifest"]["sha256"],
    manifest["predecessor_v2"]["gate"]["sha256"],
    manifest["predecessor_v2"]["launcher"]["sha256"]), "predecessor approval reuse")
valid_manifest_sha = "6" * 64
valid_gate_sha = "7" * 64
valid_launcher_sha = "8" * 64
valid_approval = gate.canonical({"schema_version": 3,
    "state": "viewflow-op442-schema5-abort-recovery-v3-execution-approved",
    "approved": True, "operation_id": gate.OP, "manifest_sha256": valid_manifest_sha,
    "gate_sha256": valid_gate_sha, "launcher_sha256": valid_launcher_sha,
    "predecessor_v2_approval_sha256": manifest["predecessor_v2"]["approval"]["sha256"],
    "publication_method": "create-once-no-replace-and-parent-fsync",
    "approved_at_utc": "2026-09-04T10:00:00.000Z"})
gate.validate_recovery_approval(manifest, valid_approval, valid_manifest_sha,
                                valid_gate_sha, valid_launcher_sha)

# Construct a deterministic Linux live result without touching systemd.
linux = documents["linux_v13_started"]
transition = documents["transition"]
active_viewflow = {"LoadState": "loaded", "ActiveState": "active", "SubState": "running",
    "MainPID": str(linux["main_pid"]), "InvocationID": linux["invocation_id"],
    "ControlGroup": linux["control_group"]}
active_deskflow = {"LoadState": "loaded", "ActiveState": "active", "SubState": "running",
    "MainPID": str(transition["linux_deskflow_main_pid"]),
    "InvocationID": transition["linux_deskflow_invocation_id"],
    "ControlGroup": transition["linux_deskflow_control_group"]}
inactive = {"LoadState": "loaded", "ActiveState": "inactive", "SubState": "dead",
    "MainPID": "0", "InvocationID": "ignored", "ControlGroup": ""}
linux_census = {"schema_version": 1, "state": "viewflow-op442-recovery-v3-linux-live",
    "operation_id": gate.OP, "viewflow_unit": active_viewflow, "deskflow_unit": active_deskflow,
    "installed_viewflow_unit": inactive, "installed_deskflow_unit": inactive,
    "process_start_ticks": {"viewflow": int(linux["start_ticks"]),
        "deskflow_main": int(transition["linux_deskflow_main_start_ticks"]),
        "deskflow_runtime": int(transition["linux_deskflow_runtime_start_ticks"]),
        "deskflow_core": int(transition["linux_deskflow_core_start_ticks"])},
    "process_executable_sha256": {"viewflow": linux["viewflowd_sha256"],
        "deskflow_main": transition["bubblewrap_sha256"],
        "deskflow_runtime": transition["linux_deskflow_executable_sha256"],
        "deskflow_core": transition["linux_deskflow_core_executable_sha256"]},
    "process_cgroup": {"viewflow": linux["control_group"],
        "deskflow_main": transition["linux_deskflow_control_group"],
        "deskflow_runtime": transition["linux_deskflow_control_group"],
        "deskflow_core": transition["linux_deskflow_control_group"]},
    "udp_44119_owner_pids": [int(linux["main_pid"])],
    "tcp_24800_owner_pids": [int(transition["linux_deskflow_core_pid"])]}
gate.validate_linux_live(linux_census, documents)
mutated_linux = dict(linux_census)
mutated_linux["tcp_24800_owner_pids"] = []
must_fail(lambda: gate.validate_linux_live(mutated_linux, documents), "missing Deskflow listener")

windows_receipt = documents["windows_v13_started"]
windows = manifest["windows_live"]
windows_census = {"schema_version": 1, "state": "viewflow-op442-recovery-v3-windows-live",
    "operation_id": gate.OP, "task_state": "Running",
    "task_xml_sha256": windows_receipt["task_xml_sha256"],
    "deployment_task_state": windows["deployment_task_state"],
    "deployment_task_xml_sha256": windows["deployment_task_xml_sha256"],
    "viewflowd_sha256": windows_receipt["viewflowd_sha256"],
    "wrapper_sha256": windows_receipt["wrapper_sha256"], "pid": windows_receipt["pid"],
    "process_start_filetime_utc": windows_receipt["process_start_filetime_utc"],
    "session_id": windows_receipt["session_id"], "user_sid": windows_receipt["user_sid"],
    "global_viewflow_process_count": 1, "deployment_worker_count": 0,
    "stdin_reader_count": 0}
gate.validate_windows_live(windows_census, manifest, documents)
mutated_windows = dict(windows_census)
mutated_windows["pid"] += 1
must_fail(lambda: gate.validate_windows_live(mutated_windows, manifest, documents),
          "Windows PID drift")
worker_windows = dict(windows_census)
worker_windows["deployment_worker_count"] = 1
must_fail(lambda: gate.validate_windows_live(worker_windows, manifest, documents),
          "Windows deployment worker remains")

class Result:
    returncode = 0
    stderr = b""
    stdout = (json.dumps(windows_census, sort_keys=True, separators=(",", ":")) + "\r\n").encode()

observed = {}
real_run = gate.subprocess.run
def fake_run(command, **kwargs):
    observed["command"] = command
    observed["kwargs"] = kwargs
    return Result()
gate.subprocess.run = fake_run
try:
    gate.validate_windows_live(gate.windows_live_census(manifest, documents), manifest, documents)
finally:
    gate.subprocess.run = real_run
assert observed["command"][-4:-1] == ["-NoProfile", "-NonInteractive", "-EncodedCommand"]
bootstrap = base64.b64decode(observed["command"][-1], validate=True).decode("utf-16le")
payload = bootstrap.split("FromBase64String('", 1)[1].split("')", 1)[0]
script = gzip.decompress(base64.b64decode(payload, validate=True)).decode("ascii")
assert script == gate.powershell_census(manifest, documents)
assert "ReadToEnd" not in bootstrap and "ReadToEnd" not in script
assert "stdin_reader_count" in script and "deployment_worker_count" in script
assert "[IO.Compression.CompressionMode]::Decompress" in bootstrap
assert observed["kwargs"]["stdin"] is gate.subprocess.DEVNULL
assert observed["kwargs"]["timeout"] == 120
assert len(observed["command"][-1]) <= 6_800
assert sum(len(item) + 1 for item in observed["command"]) <= 7_000

class ErrorResult:
    returncode = 1
    stderr = b"failed"
    stdout = b""
gate.subprocess.run = lambda *_args, **_kwargs: ErrorResult()
try:
    must_fail(lambda: gate.windows_live_census(manifest, documents), "Windows command error")
finally:
    gate.subprocess.run = real_run

marker_query = dict(receipt)
marker_query["replayed"] = True
marker_query_raw = gate.canonical(marker_query)
envelope = gate.query_envelope(manifest, marker_query_raw)
assert envelope["coordinator_redispatched"] is False
assert envelope["predecessor_v2_approval_sha256"] == manifest["predecessor_v2"]["approval"]["sha256"]
envelope_raw = gate.canonical(envelope)
validated_envelope, validated_marker = gate.validate_query_envelope(
    manifest, predecessor, v2_manifest, envelope_raw)
assert validated_envelope == envelope and validated_marker == marker_query_raw
wrong_query = dict(envelope)
wrong_query["coordinator_redispatched"] = True
assert wrong_query != gate.query_envelope(manifest, marker_query_raw)
forged_envelope = json.loads(envelope_raw)
forged_envelope["marker_query"]["schema_version"] = 999
forged_envelope["marker_query_sha256"] = gate.digest(
    gate.canonical(forged_envelope["marker_query"]))
must_fail(lambda: gate.validate_query_envelope(manifest, predecessor, v2_manifest,
    gate.canonical(forged_envelope)), "forged persisted marker query schema")
noncanonical_envelope = (json.dumps(envelope, indent=2, sort_keys=True) + "\n").encode()
must_fail(lambda: gate.validate_query_envelope(manifest, predecessor, v2_manifest,
    noncanonical_envelope), "noncanonical persisted query envelope")
assert gate.recovery_stage(False, False) == "fresh-query"
assert gate.recovery_stage(True, False) == "partial-query"
assert gate.recovery_stage(True, True) == "terminal-replay"
must_fail(lambda: gate.recovery_stage(False, True), "terminal replay missing exact query")

# A complete terminal remains verifiable after transient services are handed
# off: immutable evidence, the canonical persisted query, and the terminal are
# sufficient, and no new live census is required.
handoff_linux_sha = "9" * 64
handoff_windows_sha = "a" * 64
terminal = gate.terminal_document(manifest, valid_manifest_sha, valid_gate_sha,
    valid_launcher_sha, "b" * 64, receipt_raw, receipt, envelope_raw,
    handoff_linux_sha, handoff_windows_sha)
terminal_raw = gate.canonical(terminal)
gate.validate_terminal(manifest, terminal_raw, valid_manifest_sha, valid_gate_sha,
    valid_launcher_sha, "b" * 64, receipt_raw, receipt, envelope_raw,
    (handoff_linux_sha, handoff_windows_sha))
gate.validate_terminal(manifest, terminal_raw, valid_manifest_sha, valid_gate_sha,
    valid_launcher_sha, "b" * 64, receipt_raw, receipt, envelope_raw)
forged_terminal = dict(terminal)
forged_terminal["recovery_query_sha256"] = "c" * 64
must_fail(lambda: gate.validate_terminal(manifest, gate.canonical(forged_terminal),
    valid_manifest_sha, valid_gate_sha, valid_launcher_sha, "b" * 64,
    receipt_raw, receipt, envelope_raw), "forged terminal query binding")

with tempfile.TemporaryDirectory(prefix="viewflow-op442-recovery-v3-") as temporary:
    operation_root = pathlib.Path(temporary)
    os.chmod(operation_root, 0o700)
    old_root = gate.ROOT
    gate.ROOT = operation_root
    try:
        output = operation_root / "query.json"
        gate.create_once(str(output), b"first\n")
        must_fail(lambda: gate.create_once(str(output), b"second\n"), "create-once overwrite")
        assert output.read_bytes() == b"first\n"
        persisted = operation_root / "persisted-query.json"
        gate.create_once(str(persisted), envelope_raw)
        persisted_raw = gate.stable_generated_read(str(persisted), "partial-resume query")
        resumed_envelope, resumed_marker = gate.validate_query_envelope(
            manifest, predecessor, v2_manifest, persisted_raw)
        assert resumed_envelope == envelope and resumed_marker == marker_query_raw
    finally:
        gate.ROOT = old_root

print("442fe737 schema5 abort recovery-v3 hermetic tests passed")
