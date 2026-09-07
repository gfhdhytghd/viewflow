#!/usr/bin/env python3
"""Hermetic contract tests for the op442 schema5 abort gate."""

import hashlib
import base64
import gzip
import importlib.util
import json
import os
import pathlib
import tempfile

ROOT = pathlib.Path("/home/wilf/data/viewflow")
GATE_PATH = pathlib.Path(os.environ.get("VF_OP442_GATE",
    ROOT / "deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-gate.py"))
MANIFEST_PATH = pathlib.Path(os.environ.get("VF_OP442_MANIFEST",
    ROOT / "deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-manifest.json"))

spec = importlib.util.spec_from_file_location("op442_gate", GATE_PATH)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
manifest = json.loads(MANIFEST_PATH.read_bytes())


def must_fail(callable_value, label):
    try:
        callable_value()
    except (gate.GateError, OSError, ValueError, gate.subprocess.SubprocessError):
        return
    raise AssertionError(label + " was accepted")


gate.validate_manifest(manifest, True)
assert gate.coordinator_dispatch_required(True, True) is False
must_fail(lambda: gate.coordinator_dispatch_required(True, False),
          "terminal replay without authorization")
assert gate.coordinator_dispatch_required(False, False) is True
assert gate.coordinator_dispatch_required(False, True) is False

linux_unit = {"LoadState": "loaded", "ActiveState": "inactive", "SubState": "dead", "MainPID": "0"}
linux_census = {"schema_version": 1, "state": "viewflow-op442-linux-live-census",
    "operation_id": gate.OP, "marker_present": True, "runtime_marker_present": False,
    "abort_claim_present": False, "release_claim_present": False,
    "viewflow": linux_unit, "deskflow": linux_unit, "viewflow_process_count": 0,
    "marker_cli_process_count": 0, "deskflow_process_count": 0,
    "deskflow_core_process_count": 0, "tcp_24800_listener_count": 0,
    "udp_44119_socket_count": 0}
gate.validate_linux_live_census(linux_census)
linux_mutated = dict(linux_census)
linux_mutated["tcp_24800_listener_count"] = 1
must_fail(lambda: gate.validate_linux_live_census(linux_mutated), "Linux live listener")

windows = manifest["windows_expected"]
windows_census = {"schema_version": 1, "state": "viewflow-op442-windows-live-census",
    "operation_id": gate.OP, "operation_root": windows["operation_root"],
    "old_task_state": windows["old_task_state"],
    "old_task_xml_sha256": windows["old_task_xml_sha256"],
    "deployment_task_state": windows["deployment_task_state"],
    "deployment_task_xml_sha256": windows["deployment_task_xml_sha256"],
    "old_viewflow_process_count": 0, "global_viewflow_process_count": 0,
    "deployment_worker_count": 0,
    "installed": {"viewflowd_sha256": windows["old_binary_sha256"],
        "wrapper_sha256": windows["old_wrapper_sha256"],
        "rollback_sha256": windows["rollback_sha256"]},
    "critical_receipts": windows["critical_receipts"]}
gate.validate_windows_live_census(windows_census, manifest)
for key, replacement in (("old_task_state", "Running"),
                         ("deployment_task_state", "Ready"),
                         ("global_viewflow_process_count", 1)):
    mutated = dict(windows_census)
    mutated[key] = replacement
    must_fail(lambda mutated=mutated: gate.validate_windows_live_census(mutated, manifest),
              "Windows live mutation " + key)

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
    gate.validate_windows_live_census(gate.windows_live_census(manifest), manifest)
finally:
    gate.subprocess.run = real_run
assert observed["command"][:3] == ["/usr/bin/ssh", "-oLogLevel=ERROR", "-oBatchMode=yes"]
assert "wilf@172.16.105.70" in observed["command"]
assert observed["command"][-4:-1] == ["-NoProfile", "-NonInteractive", "-EncodedCommand"]
decoded_bootstrap = base64.b64decode(observed["command"][-1], validate=True).decode("utf-16le")
payload = decoded_bootstrap.split("FromBase64String('", 1)[1].split("')", 1)[0]
decoded_script = gzip.decompress(base64.b64decode(payload, validate=True)).decode("ascii")
assert decoded_script == gate.powershell_live_census(manifest)
assert "Get-ScheduledTask" in decoded_script and "critical_receipts=$receipts" in decoded_script
assert "ReadToEnd" not in decoded_script and "ReadToEnd" not in decoded_bootstrap
assert "GzipStream" in decoded_bootstrap and "ScriptBlock]::Create(" in decoded_bootstrap
assert "[IO.Compression.CompressionMode]::Decompress" in decoded_bootstrap
assert observed["kwargs"]["timeout"] == 120
assert observed["kwargs"]["stdin"] is gate.subprocess.DEVNULL and "input" not in observed["kwargs"]
assert len(observed["command"][-1]) <= 6_800
assert sum(len(item) + 1 for item in observed["command"]) <= 7_000
for receipt in windows["critical_receipts"]:
    assert receipt["name"] in decoded_script and receipt["sha256"] not in decoded_script

class ErrorResult:
    returncode = 0
    stderr = b"unexpected remote diagnostic"
    stdout = b""

gate.subprocess.run = lambda *_args, **_kwargs: ErrorResult()
try:
    must_fail(lambda: gate.windows_live_census(manifest), "Windows census stderr")
finally:
    gate.subprocess.run = real_run

class ProgressResult:
    returncode = 0
    stderr = (b"#< CLIXML\r\n"
        b"<Objs xmlns=\"http://schemas.microsoft.com/powershell/2004/04\">"
        b"<Obj S=\"progress\"><MS><S N=\"Activity\">loading</S></MS></Obj></Objs>")
    stdout = Result.stdout

gate.subprocess.run = lambda *_args, **_kwargs: ProgressResult()
try:
    gate.validate_windows_live_census(gate.windows_live_census(manifest), manifest)
finally:
    gate.subprocess.run = real_run

class CliXmlErrorResult:
    returncode = 0
    stderr = (b"#< CLIXML\r\n"
        b"<Objs xmlns=\"http://schemas.microsoft.com/powershell/2004/04\">"
        b"<Obj S=\"progress\"><MS><S S=\"Error\">bad</S></MS></Obj></Objs>")
    stdout = Result.stdout

gate.subprocess.run = lambda *_args, **_kwargs: CliXmlErrorResult()
try:
    must_fail(lambda: gate.windows_live_census(manifest), "Windows census CLIXML error record")
finally:
    gate.subprocess.run = real_run

def timeout_run(command, **kwargs):
    raise gate.subprocess.TimeoutExpired(command, kwargs["timeout"])
gate.subprocess.run = timeout_run
try:
    must_fail(lambda: gate.windows_live_census(manifest), "Windows census timeout")
finally:
    gate.subprocess.run = real_run


# Duplicate-key JSON and the active VFDQT ABI are strict.
must_fail(lambda: gate.strict_json(b'{"schema_version":1,"schema_version":5}', "duplicate"),
          "duplicate JSON key")
marker_spec = manifest["active_marker"]
marker_raw = pathlib.Path(marker_spec["path"]).read_bytes()
gate.validate_marker(marker_raw, manifest)
wrong_generation = bytearray(marker_raw)
wrong_generation[200:208] = (2).to_bytes(8, "little")
must_fail(lambda: gate.validate_marker(bytes(wrong_generation), manifest),
          "wrong marker generation")

# The marker candidate is deliberately an ELF document=False input.  Its exact
# hash and metadata remain mandatory, while treating it as JSON must fail.
candidate = manifest["immutable_inputs"]["marker_cli_candidate"]
raw_candidate = gate.read_spec(candidate, "marker candidate", document=False)
assert raw_candidate[:4] == b"\x7fELF"
must_fail(lambda: gate.read_spec(candidate, "marker candidate", document=True),
          "marker candidate parsed as JSON")
wrong_candidate = dict(candidate)
wrong_candidate["sha256"] = "1" * 64
must_fail(lambda: gate.read_spec(wrong_candidate, "marker candidate", document=False),
          "marker candidate hash bypass")


def receipt(replayed):
    inputs = manifest["immutable_inputs"]
    values = {
        "abort_authorization_path": manifest["outputs"]["authorization"],
        "abort_authorization_sha256": "2" * 64,
        "abort_claim_path": manifest["active_marker"]["path"] + ".abort-claim",
        "abort_committed_at_unix_ms": "2000", "abort_committed_at_utc": "1970-01-01T00:00:02.000Z",
        "abort_point": "abort-claim-atomic-retire-and-parent-directory-fsync",
        "abort_receipt_path": "/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt."
            + manifest["active_marker"]["sha256"] + "." + "2" * 64 + ".v1",
        "aborted_marker_sha256": manifest["active_marker"]["sha256"],
        "authenticated_v13_peer_receipt_sha256": "3" * 64,
        "authorization_state": "viewflow-deployment-quarantine-post-permit-rollback-abort-authorized",
        "bootstrap_request_sha256": inputs["windows_request"]["sha256"],
        "coordinator_failure_phase": "MUTATION_PERMITTED",
        "coordinator_instance_id": manifest["coordinator_instance_id"],
        "coordinator_mutation_possible": True,
        "coordinator_terminal_state_sha256": inputs["coordinator_state"]["sha256"],
        "deployment_publish_receipt_sha256": inputs["deployment_publish"]["sha256"],
        "deployment_release_claimed": False, "force_release_executed": False,
        "initial_force_release_executed": False,
        "installer_exit_receipt_sha256": inputs["installer_exit"]["sha256"],
        "linux_deactivation_proof_sha256": inputs["linux_deactivation"]["sha256"],
        "linux_deactivation_transcript_sha256": inputs["linux_deactivation_transcript"]["sha256"],
        "linux_frozen_evidence_sha256": inputs["linux_frozen"]["sha256"],
        "linux_v13_started_receipt_sha256": "4" * 64,
        "marker_created_at_unix_ms": "1000", "marker_generation": "1",
        "marker_handoff_receipt_sha256": inputs["marker_handoff"]["sha256"],
        "marker_path": manifest["active_marker"]["path"], "mutation_permit_published": True,
        "mutation_permit_receipt_sha256": inputs["mutation_permit"]["sha256"],
        "operation_id": gate.OP, "protocol_2_1": False, "protocol_version": "1.3",
        "recovery_bundle_sha256": inputs["recovery_bundle"]["sha256"], "replayed": replayed,
        "rollback_performed": True, "rollback_token_consumed": True,
        "schema1_handoff_lineage_receipt_sha256": inputs["schema1_handoff_lineage"]["sha256"],
        "schema_version": 5, "second_force_release_executed": False,
        "source_display_id": manifest["source_display_id"], "state": "deployment-quarantine-aborted",
        "target_device_id": manifest["target_device_id"],
        "windows_prepared_receipt_sha256": inputs["windows_prepared"]["sha256"],
        "windows_rollback_receipt_sha256": inputs["windows_rollback"]["sha256"],
        "windows_stop_evidence_sha256": inputs["windows_stop"]["sha256"],
        "windows_v13_started_receipt_sha256": "5" * 64,
    }
    return values


# Bind dynamic attestation hashes to arbitrary SHA values for this isolated
# schema test; immutable transaction hashes are exact manifest values.
base = receipt(False)
raw = (json.dumps(base, sort_keys=True, separators=(",", ":")) + "\n").encode()
gate.validate_receipt(raw, manifest, "2" * 64, False)
for key, replacement in (("force_release_executed", True),
                         ("rollback_performed", False),
                         ("coordinator_mutation_possible", False),
                         ("schema_version", 4)):
    mutated = dict(base)
    mutated[key] = replacement
    encoded = (json.dumps(mutated, sort_keys=True, separators=(",", ":")) + "\n").encode()
    must_fail(lambda encoded=encoded: gate.validate_receipt(encoded, manifest, "2" * 64, False),
              "receipt mutation " + key)
unknown = dict(base)
unknown["extra"] = "forbidden"
encoded_unknown = (json.dumps(unknown, sort_keys=True, separators=(",", ":")) + "\n").encode()
must_fail(lambda: gate.validate_receipt(encoded_unknown, manifest, "2" * 64, False),
          "unknown schema5 receipt key")

# Create-once publication is no-clobber and leaves the first bytes intact.
with tempfile.TemporaryDirectory(prefix="viewflow-op442-hermetic-") as temporary:
    operation_root = pathlib.Path(temporary)
    os.chmod(operation_root, 0o700)
    old_root = gate.ROOT
    gate.ROOT = operation_root
    try:
        output = operation_root / "fixture.json"
        gate.create_once(str(output), b"first\n")
        must_fail(lambda: gate.create_once(str(output), b"second\n"), "create-once replay")
        assert output.read_bytes() == b"first\n"
    finally:
        gate.ROOT = old_root

print("442fe737 schema5 abort hermetic contract tests passed")
