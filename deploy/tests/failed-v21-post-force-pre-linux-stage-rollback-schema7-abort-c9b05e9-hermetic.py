#!/usr/bin/env python3
"""Hermetic contract tests for the c9b05e9 schema7 sealed abort gate."""

import ast
import hashlib
import base64
import gzip
import importlib.util
import json
import os
import pathlib
import sys
import tempfile

ROOT = pathlib.Path("/home/wilf/data/viewflow")
GATE_PATH = pathlib.Path(os.environ.get("VF_C9_SCHEMA7_GATE",
    ROOT / "deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-gate.py"))
MANIFEST_PATH = pathlib.Path(os.environ.get("VF_C9_SCHEMA7_MANIFEST",
    ROOT / "deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-manifest.json"))

spec = importlib.util.spec_from_file_location("c9_schema7_gate", GATE_PATH)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
manifest = json.loads(MANIFEST_PATH.read_bytes())

gate_source = GATE_PATH.read_text(encoding="utf-8")
for producer_state in (
        "viewflow-linux-v1.3-started-under-deployment-quarantine",
        "viewflow-windows-v1.3-started-under-deployment-quarantine",
        "viewflow-v1.3-peer-authenticated-under-deployment-quarantine"):
    assert gate_source.count(producer_state) == 1
for invented_state in ("viewflow-v13-linux-started-frozen",
                       "viewflow-v13-windows-started-frozen",
                       "viewflow-v13-authenticated-peer-validated"):
    assert invented_state not in gate_source
if sys.argv[1:] == ["--producer-states-only"]:
    print("c9b05e9 actual coordinator producer-state contract passed")
    raise SystemExit(0)


def must_fail(callable_value, label):
    try:
        callable_value()
    except (gate.GateError, OSError, ValueError, gate.subprocess.SubprocessError):
        return
    raise AssertionError(label + " was accepted")


def assert_main_post_state_flow():
    """Require the validated post-state result to feed the terminal directly."""
    tree = ast.parse(GATE_PATH.read_text(encoding="utf-8"), filename=str(GATE_PATH))
    mains = [node for node in tree.body if isinstance(node, ast.FunctionDef)
             and node.name == "main"]
    if len(mains) != 1:
        raise AssertionError("gate main definition differs")
    main = mains[0]
    calls = []
    terminals = []
    for index, statement in enumerate(main.body):
        if (isinstance(statement, ast.Assign) and len(statement.targets) == 1
                and isinstance(statement.targets[0], (ast.Tuple, ast.List))
                and len(statement.targets[0].elts) == 2
                and all(isinstance(item, ast.Name) for item in statement.targets[0].elts)
                and [item.id for item in statement.targets[0].elts]
                    == ["vfdqa_sha", "retired"]
                and isinstance(statement.value, ast.Call)
                and isinstance(statement.value.func, ast.Name)
                and statement.value.func.id == "validate_post_state"
                and len(statement.value.args) == 3
                and all(isinstance(item, ast.Name) for item in statement.value.args)
                and [item.id for item in statement.value.args]
                    == ["manifest", "receipt", "auth_sha"]
                and not statement.value.keywords):
            calls.append(index)
        if (isinstance(statement, ast.Assign) and len(statement.targets) == 1
                and isinstance(statement.targets[0], ast.Name)
                and statement.targets[0].id == "terminal"
                and isinstance(statement.value, ast.Dict)):
            mapping = {key.value: value for key, value in
                       zip(statement.value.keys, statement.value.values)
                       if isinstance(key, ast.Constant) and isinstance(key.value, str)}
            if (isinstance(mapping.get("vfdqa_binary_sha256"), ast.Name)
                    and mapping["vfdqa_binary_sha256"].id == "vfdqa_sha"
                    and isinstance(mapping.get("retired_claim_path"), ast.Name)
                    and mapping["retired_claim_path"].id == "retired"):
                terminals.append(index)
    if len(calls) != 1 or len(terminals) != 1 or calls[0] >= terminals[0]:
        raise AssertionError("validated post-state is not the terminal source")
    for statement in main.body[calls[0] + 1:terminals[0]]:
        for node in ast.walk(statement):
            if (isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del))
                    and node.id in {"vfdqa_sha", "retired"}):
                raise AssertionError("validated post-state result is rebound")


def exercise_validate_post_state():
    """Build an exact VFDQA/retired pair and require the real validator result."""
    marker_raw = pathlib.Path(manifest["active_marker"]["path"]).read_bytes()
    authorization_sha = "2" * 64
    committed = 2000
    with tempfile.TemporaryDirectory(prefix="viewflow-c9-schema7-post-state-") as temporary:
        parent = pathlib.Path(temporary)
        local_manifest = json.loads(json.dumps(manifest))
        local_manifest["active_marker"]["path"] = str(parent / "deployment-quarantine.v1")
        marker_sha = local_manifest["active_marker"]["sha256"]
        durable = parent / (".deployment-quarantine.v1.abort-receipt."
                            + marker_sha + "." + authorization_sha + ".v1")
        retired = parent / (".deployment-quarantine.v1.abort-retired."
                            + marker_sha + "." + authorization_sha + ".v1")
        prefix = (b"VFDQA001" + bytes.fromhex("0101010301000000") + marker_raw
                  + hashlib.sha256(marker_raw).digest()
                  + bytes.fromhex(authorization_sha)
                  + committed.to_bytes(8, "little") + b"\0" * 8)
        durable_raw = prefix + hashlib.sha256(prefix).digest()
        assert len(durable_raw) == 384
        durable.write_bytes(durable_raw)
        retired.write_bytes(marker_raw)
        os.chmod(durable, 0o600)
        os.chmod(retired, 0o600)
        receipt_value = {"abort_committed_at_unix_ms": str(committed),
                         "abort_receipt_path": str(durable)}
        old_parent = gate.MARKER_PARENT
        gate.MARKER_PARENT = str(parent)
        try:
            observed_sha, observed_retired = gate.validate_post_state(
                local_manifest, receipt_value, authorization_sha)
            assert observed_sha == hashlib.sha256(durable_raw).hexdigest()
            assert observed_retired == str(retired)
            corrupted = bytearray(durable_raw)
            corrupted[350] ^= 1
            durable.write_bytes(corrupted)
            must_fail(lambda: gate.validate_post_state(
                local_manifest, receipt_value, authorization_sha),
                "forged durable VFDQA")
            durable.write_bytes(durable_raw)
            public_claim = pathlib.Path(local_manifest["active_marker"]["path"] + ".abort-claim")
            public_claim.write_bytes(b"")
            must_fail(lambda: gate.validate_post_state(
                local_manifest, receipt_value, authorization_sha),
                "remaining public abort claim")
        finally:
            gate.MARKER_PARENT = old_parent


assert_main_post_state_flow()
exercise_validate_post_state()

if sys.argv[1:] == ["--post-state-only"]:
    print("c9b05e9 schema7 post-state execution contract passed")
    raise SystemExit(0)
if sys.argv[1:]:
    raise SystemExit("usage: hermetic.py [--post-state-only]")


gate.validate_manifest(manifest, True, False)

# Offline/live modes require the approval to remain absent.  Execute
# and resume may exempt only that exact path; every other fresh output remains
# in the absence gate while the active marker is present.
real_lexists = gate.os.path.lexists
approval_path = manifest["approval_path"]
first_output = next(iter(manifest["outputs"].values()))
gate.os.path.lexists = lambda path: path == approval_path or real_lexists(path)
try:
    gate.validate_manifest(manifest, True, True)
    must_fail(lambda: gate.validate_manifest(manifest, True, False),
              "offline manifest with successor approval present")
finally:
    gate.os.path.lexists = real_lexists
gate.os.path.lexists = lambda path: path in (approval_path, first_output) or real_lexists(path)
try:
    must_fail(lambda: gate.validate_manifest(manifest, True, True),
              "execute manifest with non-approval output present")
finally:
    gate.os.path.lexists = real_lexists

assert gate.coordinator_dispatch_required(True, True) is False
must_fail(lambda: gate.coordinator_dispatch_required(True, False),
          "terminal replay without authorization")
assert gate.coordinator_dispatch_required(False, False) is True
assert gate.coordinator_dispatch_required(False, True) is False

linux_unit = {"LoadState": "loaded", "ActiveState": "inactive", "SubState": "dead", "MainPID": "0"}
linux_census = {"schema_version": 1, "state": "viewflow-c9b05e9-linux-live-census",
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
assert windows["deployment_task_state"] == "Disabled"
assert windows["deployment_task_claimed_pre_disable_xml_sha256"] \
    == "d4cc1972a562c2a18c8a1995a23b70ac32369d42021898a7a2b06f4e72c5372c"
assert windows["deployment_task_xml_sha256"] \
    == "f247c5766e1e5011816510d5b52174574e482aab0cee15f5db06de675bacbbd2"
assert windows["deployment_task_xml_sha256"] \
    != windows["deployment_task_claimed_pre_disable_xml_sha256"]
windows_census = {"schema_version": 1, "state": "viewflow-c9b05e9-windows-live-census",
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
                         ("deployment_task_xml_sha256",
                          windows["deployment_task_claimed_pre_disable_xml_sha256"]),
                         ("global_viewflow_process_count", 1)):
    mutated = dict(windows_census)
    mutated[key] = replacement
    must_fail(lambda mutated=mutated: gate.validate_windows_live_census(mutated, manifest),
              "Windows live mutation " + key)

for key, replacement in (
        ("deployment_task_xml_sha256", "6" * 64),
        ("deployment_task_claimed_pre_disable_xml_sha256", "7" * 64)):
    mutated_manifest = json.loads(json.dumps(manifest))
    mutated_manifest["windows_expected"][key] = replacement
    must_fail(lambda mutated_manifest=mutated_manifest: gate.validate_manifest(
        mutated_manifest, True, False), "Windows XML boundary mutation " + key)

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
        "authorization_state": "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized",
        "bootstrap_request_sha256": inputs["windows_request"]["sha256"],
        "coordinator_failure_phase": "WINDOWS_FORCE_ATTESTED",
        "coordinator_instance_id": manifest["coordinator_instance_id"],
        "coordinator_mutation_possible": True,
        "coordinator_terminal_state_sha256": inputs["coordinator_state"]["sha256"],
        "deployment_publish_receipt_sha256": inputs["deployment_publish"]["sha256"],
        "deployment_release_claimed": False, "force_release_executed": True,
        "fresh_operation_lineage_receipt_sha256": inputs["fresh_lineage"]["sha256"],
        "initial_force_release_executed": True,
        "linux_deactivation_proof_sha256": inputs["linux_deactivation"]["sha256"],
        "linux_deactivation_transcript_sha256": inputs["linux_deactivation_transcript"]["sha256"],
        "linux_frozen_evidence_sha256": inputs["linux_frozen"]["sha256"],
        "linux_stage_committed": False,
        "linux_v13_started_receipt_sha256": "4" * 64,
        "marker_created_at_unix_ms": "1000", "marker_generation": "1",
        "marker_handoff_receipt_sha256": inputs["marker_handoff"]["sha256"],
        "marker_path": manifest["active_marker"]["path"], "mutation_permit_published": True,
        "mutation_permit_receipt_sha256": inputs["mutation_permit"]["sha256"],
        "operation_id": gate.OP, "protocol_2_1": False, "protocol_version": "1.3",
        "recovery_bundle_sha256": inputs["recovery_bundle"]["sha256"], "replayed": replayed,
        "rollback_performed": True, "rollback_token_consumed": True,
        "schema_version": 7, "second_force_release_executed": False,
        "source_display_id": manifest["source_display_id"], "state": "deployment-quarantine-aborted",
        "target_device_id": manifest["target_device_id"],
        "windows_force_envelope_sha256": inputs["force_envelope"]["sha256"],
        "windows_install_committed": False, "windows_installer_exit_present": False,
        "windows_prepared_receipt_sha256": inputs["windows_prepared"]["sha256"],
        "windows_rollback_receipt_sha256": inputs["windows_rollback"]["sha256"],
        "windows_stop_evidence_sha256": inputs["windows_stop"]["sha256"],
        "windows_v13_started_receipt_sha256": "5" * 64,
    }
    return values


# Bind dynamic attestation hashes to arbitrary SHA values for this isolated
# schema test; immutable transaction hashes are exact manifest values.
base = receipt(False)
authorization = {key: value for key, value in base.items() if key not in {
    "abort_authorization_path", "abort_authorization_sha256", "abort_claim_path",
    "abort_committed_at_unix_ms", "abort_committed_at_utc", "abort_point",
    "abort_receipt_path", "aborted_marker_sha256", "authorization_state",
    "deployment_release_claimed", "marker_created_at_unix_ms", "marker_path",
    "protocol_version", "replayed", "source_display_id", "target_device_id"}}
authorization.update({
    "authorization_receipt_path": manifest["outputs"]["authorization"],
    "marker_sha256": manifest["active_marker"]["sha256"],
    "old_linux_viewflowd_sha256": manifest["installed_linux"]["viewflowd"]["sha256"],
    "old_linux_deskflow_sha256": manifest["installed_linux"]["deskflow"]["sha256"],
    "old_linux_deskflow_core_sha256": manifest["installed_linux"]["deskflow_core"]["sha256"],
    "old_windows_viewflowd_sha256": manifest["windows_expected"]["old_binary_sha256"],
    "old_windows_wrapper_sha256": manifest["windows_expected"]["old_wrapper_sha256"],
    "state": "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"})
authorization_raw = (json.dumps(authorization, sort_keys=True, separators=(",", ":")) + "\n").encode()
gate.validate_authorization(authorization_raw, manifest)
for key, replacement in (("force_release_executed", False),
                         ("linux_stage_committed", True),
                         ("old_windows_viewflowd_sha256", "9" * 64)):
    mutated = dict(authorization); mutated[key] = replacement
    encoded = (json.dumps(mutated, sort_keys=True, separators=(",", ":")) + "\n").encode()
    must_fail(lambda encoded=encoded: gate.validate_authorization(encoded, manifest),
              "authorization mutation " + key)

raw = (json.dumps(base, sort_keys=True, separators=(",", ":")) + "\n").encode()
gate.validate_receipt(raw, manifest, "2" * 64, False)
for key, replacement in (("force_release_executed", False),
                         ("rollback_performed", False),
                         ("coordinator_mutation_possible", False),
                         ("linux_stage_committed", True),
                         ("windows_install_committed", True),
                         ("windows_installer_exit_present", True),
                         ("schema_version", 5)):
    mutated = dict(base)
    mutated[key] = replacement
    encoded = (json.dumps(mutated, sort_keys=True, separators=(",", ":")) + "\n").encode()
    must_fail(lambda encoded=encoded: gate.validate_receipt(encoded, manifest, "2" * 64, False),
              "receipt mutation " + key)
unknown = dict(base)
unknown["extra"] = "forbidden"
encoded_unknown = (json.dumps(unknown, sort_keys=True, separators=(",", ":")) + "\n").encode()
must_fail(lambda: gate.validate_receipt(encoded_unknown, manifest, "2" * 64, False),
          "unknown schema7 receipt key")

# Create-once publication is no-clobber and leaves the first bytes intact.
with tempfile.TemporaryDirectory(prefix="viewflow-c9-schema7-hermetic-") as temporary:
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

print("c9b05e9 schema7 abort hermetic contract tests passed")
