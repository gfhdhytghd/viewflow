#!/usr/bin/env python3
"""Hermetic unit tests for the 845ce422 gate; never invokes SSH/systemd."""

import hashlib
import importlib.util
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
GATE = Path(os.environ.get("VF_ABORT_GATE",
                           "/home/wilf/data/viewflow/deploy/failed-v21-rollback-abort-845ce422-gate.py"))
spec = importlib.util.spec_from_file_location("abort845gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def marker(manifest):
    raw = bytearray(256)
    raw[:13] = b"VFDQT001" + bytes((1, 1, 2, 1, 1))
    raw[13] = len(gate.OP); raw[16:16 + len(gate.OP)] = gate.OP.encode()
    import uuid
    raw[144:192] = b"".join(uuid.UUID(manifest[key]).bytes for key in
                              ("source_display_id", "target_device_id", "coordinator_instance_id"))
    raw[192:200] = (123456789).to_bytes(8, "little")
    raw[200:208] = (1).to_bytes(8, "little")
    return bytes(raw)


def abort_receipt(manifest, auth_sha, *, replayed, marker_parent="/home/wilf/.local/state/viewflow",
                  committed_ms=123456790):
    marker_sha = manifest["active_marker"]["sha256"]
    return {
        "abort_authorization_path": manifest["outputs"]["authorization"],
        "abort_authorization_sha256": auth_sha,
        "abort_claim_path": manifest["active_marker"]["path"] + ".abort-claim",
        "abort_committed_at_unix_ms": str(committed_ms),
        "abort_committed_at_utc": "1970-01-02T10:17:36.790Z",
        "abort_point": "abort-claim-unlink-and-parent-directory-fsync",
        "abort_receipt_path": gate.durable_vfdqa_path(marker_sha, auth_sha, marker_parent),
        "aborted_marker_sha256": marker_sha,
        "coordinator_instance_id": manifest["coordinator_instance_id"],
        "deployment_release_claimed": False,
        "initial_force_release_executed": True,
        "marker_created_at_unix_ms": "123456789",
        "marker_generation": "1", "marker_path": manifest["active_marker"]["path"],
        "operation_id": gate.OP, "protocol_2_1": False, "protocol_version": "1.3",
        "replayed": replayed, "rollback_token_consumed": False, "schema_version": 1,
        "second_force_release_executed": False,
        "source_display_id": manifest["source_display_id"], "state": "deployment-quarantine-aborted",
        "target_device_id": manifest["target_device_id"]}


def main():
    check(gate.active_marker_must_exist(False, False, True) is True,
          "execute incorrectly bypassed active marker")
    check(gate.active_marker_must_exist(True, False, True) is False,
          "resume could not enter post-durable query recovery")
    check(gate.active_marker_must_exist(True, False, False) is True,
          "fresh resume incorrectly bypassed active marker")
    try:
        gate.strict_json(b'{"a":1,"a":2}', "duplicate fixture")
    except gate.GateError:
        pass
    else:
        raise AssertionError("duplicate JSON key accepted")

    manifest = {"source_display_id": "00000000-0000-0000-0000-000000000101",
                "target_device_id": "00000000-0000-0000-0000-000000000002",
                "coordinator_instance_id": "271b68b5-2058-4c73-9f17-977d8f7fb18c",
                "active_marker": {"path": "/home/wilf/.local/state/viewflow/deployment-quarantine.v1"},
                "outputs": {"authorization": "/tmp/authorization.json"}}
    raw_marker = marker(manifest)
    manifest["active_marker"]["sha256"] = hashlib.sha256(raw_marker).hexdigest()
    gate.validate_marker(raw_marker, manifest)
    damaged = bytearray(raw_marker); damaged[200] = 2
    try:
        gate.validate_marker(bytes(damaged), manifest)
    except gate.GateError:
        pass
    else:
        raise AssertionError("wrong marker generation accepted")

    census_manifest = {"windows_expected": {
        "ssh_target": "wilf@172.16.105.70",
        "operation_root": "C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\" + gate.OP,
        "user_sid": "S-1-5-21-1-2-3-1001", "deployment_task_name": "Viewflow Deployment " + gate.OP,
        "old_task_xml_sha256": "1" * 64, "deployment_task_xml_sha256": "2" * 64,
        "old_binary_sha256": "3" * 64, "old_wrapper_sha256": "4" * 64,
        "old_rollback_sha256": "5" * 64, "required_members": ["request.json"],
        "forbidden_members": ["windows-install-success.json"],
        "exact_members": [{"name": "request.json", "size": 7, "sha256": "6" * 64}]}}
    ps_pre = gate.powershell_census(census_manifest, "Ready", 0)
    ps_post = gate.powershell_census(census_manifest, "Running", 1)
    for token in ("Ready", "Disabled", gate.OP, "request.json", "windows-install-success.json"):
        check(token in ps_pre, "pre census lost binding " + token)
    check("Running" in ps_post and "$rows.Count-ne1" in ps_post,
          "post census lost running/one-process binding")

    captured = []
    real_run = gate.subprocess.run
    class Result:
        returncode = 0
        stdout = b'{"operation_root_members":[]}\r\n'
        stderr = b""
    try:
        def fake_run(argv, **kwargs):
            captured.append((argv, kwargs))
            return Result()
        gate.subprocess.run = fake_run
        gate.windows_census(census_manifest, "Ready", 0)
        argv, kwargs = captured[-1]
        check(argv[-5:] == ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                             '"& ([ScriptBlock]::Create([Console]::In.ReadToEnd()))"'],
              "Windows census did not use fixed PowerShell stdin argv")
        check("-EncodedCommand" not in argv and max(map(len, argv)) < 256,
              "long Windows census payload leaked into SSH argv")
        expected_input = ps_pre.encode("ascii")
        check(kwargs.get("input") == expected_input and len(expected_input) > 4096,
              "long Windows census script was not transmitted through stdin")
        check(kwargs["input"].isascii(), "Windows census stdin is not ASCII")
        check(b"$ProgressPreference='SilentlyContinue'" in kwargs["input"]
              and argv[1:3] == ["-o", "LogLevel=ERROR"],
              "Windows census progress/PQ-warning suppression differs")

        class StderrResult(Result):
            stderr = b"business diagnostic"
        gate.subprocess.run = lambda _argv, **_kwargs: StderrResult()
        try:
            gate.windows_census(census_manifest, "Ready", 0)
        except gate.GateError:
            pass
        else:
            raise AssertionError("Windows census accepted nonempty business stderr")
    finally:
        gate.subprocess.run = real_run

    exact_census = {"schema_version": 1,
                    "state": "viewflow-failed-v21-rollback-abort-windows-census",
                    "operation_id": gate.OP,
                    "operation_root": census_manifest["windows_expected"]["operation_root"],
                    "operation_root_members": census_manifest["windows_expected"]["exact_members"],
                    "old_task_state": "Ready", "old_task_xml_sha256": "1" * 64,
                    "old_process_count": 0, "global_viewflow_process_count": 0,
                    "deployment_worker_count": 0, "deployment_task_state": "Disabled",
                    "deployment_task_xml_sha256": "2" * 64,
                    "installed": {"viewflowd_sha256": "3" * 64,
                                  "wrapper_sha256": "4" * 64,
                                  "rollback_sha256": "5" * 64}}
    gate.validate_windows_census(exact_census, census_manifest, "Ready", 0)
    extra_census = dict(exact_census)
    extra_census["operation_root_members"] = exact_census["operation_root_members"] + [
        {"name": "unexpected.json", "size": 1, "sha256": "7" * 64}]
    try:
        gate.validate_windows_census(extra_census, census_manifest, "Ready", 0)
    except gate.GateError:
        pass
    else:
        raise AssertionError("unknown Windows operation-root member accepted")

    with tempfile.TemporaryDirectory() as temporary:
        os.chmod(temporary, 0o700)
        output = str(Path(temporary) / "proof.json")
        gate.create_once(output, b"{}\n")
        check(Path(output).read_bytes() == b"{}\n", "create-once bytes differ")
        try:
            gate.create_once(output, b'{"changed":true}\n')
        except gate.GateError:
            pass
        else:
            raise AssertionError("create-once replaced existing output")

        auth_sha = "a" * 64; marker_sha = manifest["active_marker"]["sha256"]
        receipt = abort_receipt(manifest, auth_sha, replayed=False,
                                marker_parent=temporary)
        # Full schema and UTC/unix-ms binding is independently strict.
        production_receipt = abort_receipt(manifest, auth_sha, replayed=False)
        gate.validate_abort_receipt(gate.canonical(production_receipt), manifest, auth_sha,
                                    require_replay=False)
        changed_receipt = dict(production_receipt); changed_receipt["extra"] = True
        try:
            gate.validate_abort_receipt(gate.canonical(changed_receipt), manifest, auth_sha,
                                        require_replay=False)
        except gate.GateError:
            pass
        else:
            raise AssertionError("unknown schema1 abort receipt key accepted")

        durable = bytearray(384)
        durable[:8] = b"VFDQA001"; durable[8:16] = bytes.fromhex("0101010301000000")
        durable[16:272] = raw_marker
        durable[272:304] = hashlib.sha256(raw_marker).digest()
        durable[304:336] = bytes.fromhex(auth_sha)
        durable[336:344] = (123456790).to_bytes(8, "little")
        durable[352:384] = hashlib.sha256(durable[:352]).digest()
        dpath = Path(receipt["abort_receipt_path"])
        dpath.write_bytes(durable); os.chmod(dpath, 0o600)
        gate.validate_vfdqa(str(dpath), manifest, auth_sha, receipt, marker_parent=temporary)
        for offset, label in ((8, "VFDQA ABI header"), (336, "VFDQA commit time"),
                              (344, "VFDQA reserved bytes")):
            damaged = bytearray(durable); damaged[offset] ^= 1
            damaged[352:384] = hashlib.sha256(damaged[:352]).digest()
            dpath.write_bytes(damaged)
            try:
                gate.validate_vfdqa(str(dpath), manifest, auth_sha, receipt,
                                    marker_parent=temporary)
            except gate.GateError:
                pass
            else:
                raise AssertionError(label + " mutation accepted")
        dpath.write_bytes(durable)

        lock = Path(temporary) / ".deployment-quarantine.v1.lock"
        lock.write_bytes(b""); os.chmod(lock, 0o600)
        terminal_parent = Path(temporary) / "terminal-parent"
        terminal_parent.mkdir(mode=0o700)
        terminal = terminal_parent / "terminal.json"
        tx_manifest = {"outputs": {"terminal": str(terminal)}}
        gate.terminal_commit(tx_manifest, b'{"terminal":true}\n', str(dpath), bytes(durable),
                             marker_parent=temporary)
        check(terminal.read_bytes() == b'{"terminal":true}\n', "locked terminal commit failed")
        terminal.unlink()

        def swap_durable():
            old = Path(temporary) / "old-durable"
            dpath.rename(old)
            dpath.write_bytes(durable); os.chmod(dpath, 0o600)
        try:
            gate.terminal_commit(tx_manifest, b'{"terminal":true}\n', str(dpath), bytes(durable),
                                 marker_parent=temporary, locked_hook=swap_durable)
        except gate.GateError:
            pass
        else:
            raise AssertionError("locked durable pathname swap accepted")
        check(not terminal.exists(), "terminal published after locked dentry swap")

    # Durable/query recovery is a real control-flow gate: existing authorization plus
    # missing local receipt must query and persist, and must never invoke coordinator.
    with tempfile.TemporaryDirectory() as temporary:
        os.chmod(temporary, 0o700)
        auth_path = str(Path(temporary) / "authorization.json")
        local_receipt = str(Path(temporary) / "receipt.json")
        auth_raw = b'{"authorization":true}\n'
        Path(auth_path).write_bytes(auth_raw); os.chmod(auth_path, 0o600)
        recovery_manifest = dict(manifest)
        recovery_manifest["outputs"] = {"authorization": auth_path,
                                          "abort_receipt": local_receipt}
        recovery_receipt = abort_receipt(recovery_manifest, hashlib.sha256(auth_raw).hexdigest(),
                                         replayed=True)
        recovery_raw = gate.canonical(recovery_receipt)
        originals = (gate.run_coordinator, gate.run_marker_query, gate.validate_vfdqa)
        calls = {"query": 0, "coordinator": 0}
        try:
            def forbidden_coordinator(_manifest):
                calls["coordinator"] += 1
                raise AssertionError("coordinator redispatched across durable recovery")
            def fake_query(_manifest, _sha):
                calls["query"] += 1
                return recovery_raw
            gate.run_coordinator = forbidden_coordinator
            gate.run_marker_query = fake_query
            gate.validate_vfdqa = lambda *_args, **_kwargs: b"durable"
            recovered = gate.ensure_abort_receipt(recovery_manifest, marker_parent=temporary)
            check(recovered[0]["replayed"] is True and Path(local_receipt).read_bytes() == recovery_raw,
                  "sealed marker query recovery did not persist local receipt")
            check(calls == {"query": 1, "coordinator": 0},
                  "durable recovery redispatched coordinator")
        finally:
            gate.run_coordinator, gate.run_marker_query, gate.validate_vfdqa = originals

    approval_manifest = {"coordinator": {"sha256": "1" * 64},
                         "immutable_inputs": {"coordinator_state": {"sha256": "2" * 64},
                                              "fresh_lineage": {"sha256": "3" * 64}},
                         "active_marker": {"sha256": "4" * 64}}
    approval = {"schema_version": 1,
                "state": "viewflow-failed-v21-rollback-abort-845ce422-execution-approved",
                "approved": True, "operation_id": gate.OP, "manifest_sha256": "5" * 64,
                "gate_sha256": "6" * 64, "launcher_sha256": "7" * 64,
                "coordinator_sha256": "1" * 64, "coordinator_state_sha256": "2" * 64,
                "lineage_sha256": "3" * 64, "marker_sha256": "4" * 64,
                "publication_method": "create-once-no-replace-and-parent-fsync",
                "approved_at_utc": "2026-09-04T12:00:00.000Z"}
    gate.validate_approval(approval_manifest, gate.canonical(approval), "5" * 64, "6" * 64, "7" * 64)
    approval["operation_id"] = "0" * 32
    try:
        gate.validate_approval(approval_manifest, gate.canonical(approval), "5" * 64,
                               "6" * 64, "7" * 64)
    except gate.GateError:
        pass
    else:
        raise AssertionError("approval reuse across operation accepted")
    print("845ce422 abort hermetic tests passed")


if __name__ == "__main__":
    main()
