#!/usr/bin/env python3
"""Sealed local-only recovery for the committed c9 schema-7 VFDQA abort."""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

OP = "c9b05e9bea4140d69f9d137a0f992ba0"
COORD = "86c03003-2b67-451d-a990-396e1a66b406"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
MARKER_PARENT = "/home/wilf/.local/state/viewflow"
MANIFEST = "/home/wilf/data/viewflow/deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-manifest.json"
SHA = re.compile(r"[0-9a-f]{64}\Z")
RENAME_NOREPLACE = 1
ENV = {"HOME": "/home/wilf", "USER": "wilf", "LOGNAME": "wilf",
       "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}


class GateError(RuntimeError):
    pass


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise GateError("duplicate JSON key: " + key)
        result[key] = value
    return result


def strict_json(raw: bytes, label: str):
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GateError(label + " is not strict UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise GateError(label + " is not one object")
    return value


def exact_keys(value, expected, label):
    if not isinstance(value, dict) or set(value) != set(expected):
        raise GateError(label + " keys differ")


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def stable_read(path: str, expected: str, mode: int, size: int, label: str) -> bytes:
    if not path.startswith("/") or not SHA.fullmatch(expected) or expected == "0" * 64:
        raise GateError(label + " spec is not frozen")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == mode
                and before.st_size == size and identity(before) == identity(named)
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(fd))):
            raise GateError(label + " metadata differs")
        chunks = []
        remaining = size
        while remaining:
            chunk = os.read(fd, min(1 << 20, remaining))
            if not chunk:
                raise GateError(label + " short read")
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if os.read(fd, 1) or identity(os.fstat(fd)) != identity(before) or digest(raw) != expected:
            raise GateError(label + " changed while read")
        return raw
    finally:
        os.close(fd)


def read_spec(spec, label, document=False):
    exact_keys(spec, {"path", "sha256", "mode", "size"}, label + " spec")
    if not (isinstance(spec["mode"], int) and isinstance(spec["size"], int)):
        raise GateError(label + " spec types differ")
    raw = stable_read(spec["path"], spec["sha256"], int(str(spec["mode"]), 8),
                      spec["size"], label)
    return (raw, strict_json(raw, label)) if document else raw


def sealed_read(path: str, expected: str, mode: int, label: str) -> bytes:
    if not re.fullmatch(r"/proc/self/fd/[0-9]+", path) or not SHA.fullmatch(expected):
        raise GateError(label + " sealed specification differs")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        seals = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 0 and stat.S_IMODE(before.st_mode) == mode
                and fcntl.fcntl(fd, fcntl.F_GET_SEALS) == seals):
            raise GateError(label + " is not a sealed memfd")
        raw = os.read(fd, before.st_size + 1)
        if len(raw) != before.st_size or digest(raw) != expected:
            raise GateError(label + " sealed bytes differ")
        return raw
    finally:
        os.close(fd)


def stable_generated_read(path: str, label: str) -> bytes:
    if not path.startswith(str(ROOT) + "/"):
        raise GateError(label + " path is outside operation root")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600
                and identity(before) == identity(named)):
            raise GateError(label + " metadata differs")
        raw = os.read(fd, before.st_size + 1)
        if len(raw) != before.st_size or identity(os.fstat(fd)) != identity(before):
            raise GateError(label + " changed while read")
        return raw
    finally:
        os.close(fd)


def create_once(path: str, raw: bytes):
    target = Path(path)
    parent = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    temporary = "." + target.name + ".tmp." + str(os.getpid()) + "." + os.urandom(8).hex()
    try:
        before = os.fstat(parent)
        named = os.stat(target.parent, follow_symlinks=False)
        if not (identity(before) == identity(named) and before.st_uid == os.geteuid()
                and stat.S_IMODE(before.st_mode) == 0o700):
            raise GateError("output parent metadata differs")
        try:
            os.stat(target.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise GateError("create-once output exists")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                     0o600, dir_fd=parent)
        try:
            view = memoryview(raw)
            while view:
                count = os.write(fd, view)
                if count <= 0:
                    raise GateError("create-once short write")
                view = view[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renameat2(parent, os.fsencode(temporary), parent,
                          os.fsencode(target.name), RENAME_NOREPLACE) != 0:
            raise GateError("create-once no-replace publish failed")
        os.fsync(parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def validate_predecessor_approval(raw, manifest):
    value = strict_json(raw, "predecessor approval")
    predecessor = manifest["predecessor"]
    expected = {"approved": True, "approved_at_utc": value.get("approved_at_utc"),
        "coordinator_sha256": "8248f1ce2e6fe8b642f059ab1019314094bb20272a10295875aacf3c93823fe8",
        "coordinator_state_sha256": "066ef1bfa69aa09989204245c16d15c19eb66003a8a715f553c70b76976d7e8f",
        "gate_sha256": predecessor["gate_sha256"],
        "launcher_sha256": predecessor["launcher_sha256"],
        "lineage_sha256": "6cc134872971fd1b25608c53e5e24d27ae5516ca1d457443ddeba91bda9fa982",
        "manifest_sha256": predecessor["manifest"]["sha256"],
        "marker_cli_candidate_sha256": "266e052177aad1189b7a3b86f6e341347867aa1acd07f14dc64054bd4460d8cf",
        "marker_sha256": manifest["marker_sha256"], "operation_id": OP,
        "publication_method": "create-once-no-replace-and-parent-fsync",
        "schema_version": 1,
        "state": "viewflow-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-execution-approved"}
    if value != expected or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",
            str(value.get("approved_at_utc"))):
        raise GateError("predecessor approval differs")


AUTH_KEYS = {"authenticated_v13_peer_receipt_sha256", "authorization_receipt_path",
    "bootstrap_request_sha256", "coordinator_failure_phase", "coordinator_instance_id",
    "coordinator_mutation_possible", "coordinator_terminal_state_sha256",
    "deployment_publish_receipt_sha256", "force_release_executed",
    "fresh_operation_lineage_receipt_sha256", "initial_force_release_executed",
    "linux_deactivation_proof_sha256", "linux_deactivation_transcript_sha256",
    "linux_frozen_evidence_sha256", "linux_stage_committed", "linux_v13_started_receipt_sha256",
    "marker_generation", "marker_handoff_receipt_sha256", "marker_sha256",
    "mutation_permit_published", "mutation_permit_receipt_sha256",
    "old_linux_deskflow_core_sha256", "old_linux_deskflow_sha256", "old_linux_viewflowd_sha256",
    "old_windows_viewflowd_sha256", "old_windows_wrapper_sha256", "operation_id", "protocol_2_1",
    "recovery_bundle_sha256", "rollback_performed", "rollback_token_consumed", "schema_version",
    "second_force_release_executed", "state", "windows_force_envelope_sha256",
    "windows_install_committed", "windows_installer_exit_present", "windows_prepared_receipt_sha256",
    "windows_rollback_receipt_sha256", "windows_stop_evidence_sha256", "windows_v13_started_receipt_sha256"}

RECEIPT_KEYS = (AUTH_KEYS - {"authorization_receipt_path", "marker_sha256",
    "old_linux_deskflow_core_sha256", "old_linux_deskflow_sha256", "old_linux_viewflowd_sha256",
    "old_windows_viewflowd_sha256", "old_windows_wrapper_sha256"}) | {
    "abort_authorization_path", "abort_authorization_sha256",
    "abort_claim_path", "abort_committed_at_unix_ms", "abort_committed_at_utc", "abort_point",
    "abort_receipt_path", "aborted_marker_sha256", "authorization_state",
    "deployment_release_claimed", "marker_created_at_unix_ms", "marker_path", "protocol_version",
    "replayed", "source_display_id", "target_device_id"}


def validate_authorization(value, manifest):
    exact_keys(value, AUTH_KEYS, "authorization")
    committed = manifest["committed"]
    if not (value["schema_version"] == 7
            and value["state"] == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"
            and value["operation_id"] == OP and value["coordinator_instance_id"] == COORD
            and value["marker_sha256"] == manifest["marker_sha256"]
            and value["coordinator_failure_phase"] == "WINDOWS_FORCE_ATTESTED"
            and value["coordinator_mutation_possible"] is True
            and value["force_release_executed"] is True and value["rollback_performed"] is True
            and value["linux_stage_committed"] is False
            and value["windows_install_committed"] is False
            and value["windows_installer_exit_present"] is False
            and value["protocol_2_1"] is False
            and value["linux_v13_started_receipt_sha256"] == committed["linux_v13_started"]["sha256"]
            and value["windows_v13_started_receipt_sha256"] == committed["windows_v13_started"]["sha256"]
            and value["authenticated_v13_peer_receipt_sha256"] == committed["authenticated_v13_peer"]["sha256"]):
        raise GateError("authorization identity/truth differs")
    return value


def validate_receipt(value, manifest, authorization_sha, replayed):
    exact_keys(value, RECEIPT_KEYS, "abort receipt")
    committed = manifest["committed"]
    if not (value["schema_version"] == 7 and value["state"] == "deployment-quarantine-aborted"
            and value["operation_id"] == OP and value["coordinator_instance_id"] == COORD
            and value["abort_authorization_sha256"] == authorization_sha
            and value["aborted_marker_sha256"] == manifest["marker_sha256"]
            and value["replayed"] is replayed and value["protocol_version"] == "1.3"
            and value["protocol_2_1"] is False and value["force_release_executed"] is True
            and value["rollback_performed"] is True and value["linux_stage_committed"] is False
            and value["windows_install_committed"] is False
            and value["windows_installer_exit_present"] is False
            and value["linux_v13_started_receipt_sha256"] == committed["linux_v13_started"]["sha256"]
            and value["windows_v13_started_receipt_sha256"] == committed["windows_v13_started"]["sha256"]
            and value["authenticated_v13_peer_receipt_sha256"] == committed["authenticated_v13_peer"]["sha256"]
            and value["abort_receipt_path"] == manifest["post_abort"]["durable_vfdqa"]["path"]):
        raise GateError("abort receipt identity/truth differs")
    return value


def validate_committed(manifest, documents):
    linux = documents["linux_v13_started"]
    windows = documents["windows_v13_started"]
    peer = documents["authenticated_v13_peer"]
    transition = documents["transition"]
    if not (linux.get("schema_version") == 1
            and linux.get("state") == "viewflow-linux-v1.3-started-under-deployment-quarantine"
            and linux.get("operation_id") == OP and linux.get("protocol_version") == "1.3"
            and windows.get("schema_version") == 1
            and windows.get("state") == "viewflow-windows-v1.3-started-under-deployment-quarantine"
            and windows.get("operation_id") == OP and windows.get("protocol_version") == "1.3"
            and peer.get("schema_version") == 1
            and peer.get("state") == "viewflow-v1.3-peer-authenticated-under-deployment-quarantine"
            and peer.get("operation_id") == OP and peer.get("protocol_2_1") is False
            and peer.get("linux_v13_started_receipt_sha256") == manifest["committed"]["linux_v13_started"]["sha256"]
            and peer.get("windows_v13_started_receipt_sha256") == manifest["committed"]["windows_v13_started"]["sha256"]
            and transition.get("schema_version") == 1
            and transition.get("state") == "viewflow-failed-v1.3-bootstrap-abort-terminal"
            and transition.get("operation_id") == OP and transition.get("protocol_2_1") is False
            and transition.get("normal_deployment_release") is False
            and transition.get("deployment_abort_receipt_sha256") == manifest["committed"]["abort_receipt"]["sha256"]
            and transition.get("abort_authorization_sha256") == manifest["committed"]["authorization"]["sha256"]
            and transition.get("linux_v13_started_receipt_sha256") == manifest["committed"]["linux_v13_started"]["sha256"]
            and transition.get("windows_v13_started_receipt_sha256") == manifest["committed"]["windows_v13_started"]["sha256"]
            and transition.get("authenticated_v13_peer_receipt_sha256") == manifest["committed"]["authenticated_v13_peer"]["sha256"]):
        raise GateError("committed producer output identity differs")
    return {name: manifest["committed"][name]["sha256"] for name in (
        "authorization", "abort_receipt", "transition", "linux_v13_started",
        "windows_v13_started", "authenticated_v13_peer")}


def validate_vfdqa(manifest, receipt, authorization_sha):
    post = manifest["post_abort"]
    raw = read_spec(post["durable_vfdqa"], "durable VFDQA")
    marker = read_spec(post["retired_claim"], "retired marker")
    committed = int.from_bytes(raw[336:344], "little") if len(raw) >= 344 else 0
    if not (raw[:8] == b"VFDQA001" and raw[8:16] == bytes.fromhex("0101010301000000")
            and raw[16:272] == marker and digest(marker) == manifest["marker_sha256"]
            and raw[272:304] == hashlib.sha256(marker).digest()
            and raw[304:336].hex() == authorization_sha
            and committed == int(receipt["abort_committed_at_unix_ms"])
            and raw[344:352] == b"\0" * 8
            and hashlib.sha256(raw[:352]).digest() == raw[352:]
            and digest(raw) == post["durable_vfdqa"]["sha256"]):
        raise GateError("durable VFDQA ABI differs")
    if any(os.path.lexists(path) for path in post["public_absent"]):
        raise GateError("public marker or claim remains")
    return digest(raw), post["retired_claim"]["path"]


def validate_manifest(manifest, allow_approval=False, allow_outputs=False):
    exact_keys(manifest, {"schema_version", "state", "execution_authorized", "operation_id",
        "coordinator_instance_id", "marker_sha256", "predecessor", "committed", "post_abort",
        "marker_cli", "recovery_policy", "approval_path", "outputs", "required_absent"},
        "recovery-v2 manifest")
    if not (manifest["schema_version"] == 2
            and manifest["state"] == "viewflow-c9b05e9-schema7-abort-post-commit-recovery-v2-command-manifest"
            and manifest["execution_authorized"] is False and manifest["operation_id"] == OP
            and manifest["coordinator_instance_id"] == COORD
            and manifest["marker_sha256"] == "9bc030e47e4d148341cf3cf540f318d291614b39769590a1035e2dcbc336f90a"):
        raise GateError("recovery-v2 manifest identity differs")
    if manifest["recovery_policy"] != {"abort_redispatch_forbidden": True,
            "coordinator_dispatch_forbidden": True,
            "local_receipt_reconstruction_enabled": False,
            "only_pinned_marker_query": True}:
        raise GateError("recovery-v2 no-redispatch policy differs")
    predecessor = manifest["predecessor"]
    exact_keys(predecessor, {"manifest", "approval", "gate_sha256", "launcher_sha256"},
               "predecessor")
    predecessor_raw, predecessor_manifest = read_spec(predecessor["manifest"],
                                                       "predecessor manifest", True)
    approval_raw = read_spec(predecessor["approval"], "predecessor approval")
    validate_predecessor_approval(approval_raw, manifest)
    if not (predecessor["gate_sha256"] == "767c82f684c0d26fa1c83d430d1278aa56607c8070ae86944936723414f259af"
            and predecessor["launcher_sha256"] == "f0f00c5dd934b55c1f4f0dfdab672a842cd3a8067faeeb13317266272623bd1d"
            and predecessor_manifest.get("operation_id") == OP
            and predecessor_manifest.get("coordinator_instance_id") == COORD
            and predecessor_manifest.get("active_marker", {}).get("sha256") == manifest["marker_sha256"]
            and predecessor_manifest.get("immutable_inputs", {}).get("marker_cli_candidate") == manifest["marker_cli"]):
        raise GateError("predecessor sealed-set identity differs")
    exact_keys(manifest["committed"], {"authorization", "abort_receipt", "transition",
        "linux_v13_started", "windows_v13_started", "authenticated_v13_peer"}, "committed")
    documents = {}
    raws = {}
    for name, spec in manifest["committed"].items():
        raw, value = read_spec(spec, "committed " + name, True)
        if predecessor_manifest.get("outputs", {}).get(name) != spec["path"]:
            raise GateError("predecessor output path differs: " + name)
        raws[name], documents[name] = raw, value
    authorization_sha = digest(raws["authorization"])
    validated_authorization = validate_authorization(documents["authorization"], manifest)
    validated_receipt = validate_receipt(
        documents["abort_receipt"], manifest, authorization_sha, False)
    committed_hashes = validate_committed(manifest, documents)
    exact_keys(manifest["post_abort"], {"marker_path", "public_absent", "durable_vfdqa",
               "retired_claim"}, "post-abort")
    expected_public = [manifest["post_abort"]["marker_path"],
        manifest["post_abort"]["marker_path"] + ".abort-claim",
        manifest["post_abort"]["marker_path"] + ".release-claim"]
    if (manifest["post_abort"]["marker_path"] != predecessor_manifest["active_marker"]["path"]
            or manifest["post_abort"]["public_absent"] != expected_public):
        raise GateError("post-abort public path contract differs")
    vfdqa_sha, retired_path = validate_vfdqa(
        manifest, documents["abort_receipt"], authorization_sha)
    if not (validated_authorization == documents["authorization"]
            and validated_receipt == documents["abort_receipt"]
            and committed_hashes == {name: manifest["committed"][name]["sha256"]
                for name in ("authorization", "abort_receipt", "transition",
                    "linux_v13_started", "windows_v13_started", "authenticated_v13_peer")}
            and vfdqa_sha == manifest["post_abort"]["durable_vfdqa"]["sha256"]
            and retired_path == manifest["post_abort"]["retired_claim"]["path"]):
        raise GateError("validator proof consumption differs")
    read_spec(manifest["marker_cli"], "marker CLI")
    expected_approval = str(ROOT / "failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-execution-approval.json")
    expected_outputs = {"query": str(ROOT / "failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-query.json"),
        "terminal": str(ROOT / "failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-terminal.json")}
    expected_absent = [predecessor_manifest["outputs"]["abort_query"],
        predecessor_manifest["outputs"]["terminal"], expected_approval,
        expected_outputs["query"], expected_outputs["terminal"]]
    if not (manifest["approval_path"] == expected_approval and manifest["outputs"] == expected_outputs
            and manifest["required_absent"] == expected_absent):
        raise GateError("recovery-v2 output confinement differs")
    for path in expected_absent:
        if allow_approval and path == expected_approval:
            continue
        if allow_outputs and path in expected_outputs.values():
            continue
        if os.path.lexists(path):
            raise GateError("required-absent path exists: " + path)
    return predecessor_manifest, raws, documents


def seal(raw: bytes) -> int:
    fd = os.memfd_create("viewflow-c9-recovery-v2-marker-query", os.MFD_ALLOW_SEALING)
    os.write(fd, raw)
    os.fchmod(fd, 0o700)
    seals = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
    fcntl.fcntl(fd, fcntl.F_ADD_SEALS, seals)
    os.set_inheritable(fd, True)
    return fd


def run_marker_query(manifest, authorization_sha):
    raw = read_spec(manifest["marker_cli"], "marker CLI")
    fd = seal(raw)
    try:
        argv = [f"/proc/self/fd/{fd}", "query", "--operation-id", OP,
            "--coordinator-instance-id", COORD, "--marker-generation", "1",
            "--marker-sha256", manifest["marker_sha256"],
            "--abort-authorization-path", manifest["committed"]["authorization"]["path"],
            "--abort-authorization-sha256", authorization_sha]
        result = subprocess.run(argv, env=ENV, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(fd,), timeout=30)
        if result.returncode or result.stderr:
            raise GateError("sealed marker CLI query failed")
        return result.stdout
    finally:
        os.close(fd)


def query_envelope(manifest, marker_query_raw):
    marker_query = strict_json(marker_query_raw, "marker query")
    return {"schema_version": 2,
        "state": "viewflow-c9b05e9-schema7-abort-recovery-v2-query-committed",
        "operation_id": OP, "coordinator_redispatched": False,
        "marker_abort_redispatched": False, "query_source": "sealed-marker-cli-query",
        "predecessor_approval_sha256": manifest["predecessor"]["approval"]["sha256"],
        "authorization_sha256": manifest["committed"]["authorization"]["sha256"],
        "abort_receipt_sha256": manifest["committed"]["abort_receipt"]["sha256"],
        "durable_vfdqa_sha256": manifest["post_abort"]["durable_vfdqa"]["sha256"],
        "marker_query_sha256": digest(marker_query_raw), "marker_query": marker_query}


def validate_query(manifest, raw):
    value = strict_json(raw, "recovery-v2 query")
    if raw != canonical(value):
        raise GateError("recovery-v2 query is not canonical")
    exact_keys(value, {"schema_version", "state", "operation_id", "coordinator_redispatched",
        "marker_abort_redispatched", "query_source", "predecessor_approval_sha256",
        "authorization_sha256", "abort_receipt_sha256", "durable_vfdqa_sha256",
        "marker_query_sha256", "marker_query"}, "recovery-v2 query")
    marker_raw = canonical(value["marker_query"])
    authorization_sha = manifest["committed"]["authorization"]["sha256"]
    validated_marker = validate_receipt(
        value["marker_query"], manifest, authorization_sha, True)
    if not (validated_marker == value["marker_query"]
            and value == query_envelope(manifest, marker_raw)
            and value["coordinator_redispatched"] is False
            and value["marker_abort_redispatched"] is False):
        raise GateError("recovery-v2 query binding differs")
    return value


def validate_recovery_approval(manifest, raw, manifest_sha, gate_sha, launcher_sha):
    value = strict_json(raw, "recovery-v2 approval")
    expected = {"schema_version": 2,
        "state": "viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved",
        "approved": True, "operation_id": OP, "manifest_sha256": manifest_sha,
        "gate_sha256": gate_sha, "launcher_sha256": launcher_sha,
        "predecessor_approval_sha256": manifest["predecessor"]["approval"]["sha256"],
        "coordinator_dispatch_forbidden": True, "abort_redispatch_forbidden": True,
        "only_pinned_marker_query": True,
        "authorization_sha256": manifest["committed"]["authorization"]["sha256"],
        "abort_receipt_sha256": manifest["committed"]["abort_receipt"]["sha256"],
        "transition_sha256": manifest["committed"]["transition"]["sha256"],
        "linux_v13_started_sha256": manifest["committed"]["linux_v13_started"]["sha256"],
        "windows_v13_started_sha256": manifest["committed"]["windows_v13_started"]["sha256"],
        "authenticated_v13_peer_sha256": manifest["committed"]["authenticated_v13_peer"]["sha256"],
        "durable_vfdqa_sha256": manifest["post_abort"]["durable_vfdqa"]["sha256"],
        "retired_claim_sha256": manifest["post_abort"]["retired_claim"]["sha256"],
        "publication_method": "create-once-no-replace-and-parent-fsync",
        "approved_at_utc": value.get("approved_at_utc")}
    if value != expected or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",
            str(value.get("approved_at_utc"))):
        raise GateError("recovery-v2 approval differs")


def terminal_document(manifest, manifest_sha, gate_sha, launcher_sha, approval_sha, query_raw):
    return {"schema_version": 2,
        "state": "viewflow-c9b05e9-schema7-vfdqa-abort-recovery-v2-terminal",
        "operation_id": OP, "manifest_sha256": manifest_sha, "gate_sha256": gate_sha,
        "launcher_sha256": launcher_sha, "approval_sha256": approval_sha,
        "predecessor_approval_sha256": manifest["predecessor"]["approval"]["sha256"],
        "authorization_sha256": manifest["committed"]["authorization"]["sha256"],
        "abort_receipt_sha256": manifest["committed"]["abort_receipt"]["sha256"],
        "transition_sha256": manifest["committed"]["transition"]["sha256"],
        "linux_v13_started_sha256": manifest["committed"]["linux_v13_started"]["sha256"],
        "windows_v13_started_sha256": manifest["committed"]["windows_v13_started"]["sha256"],
        "authenticated_v13_peer_sha256": manifest["committed"]["authenticated_v13_peer"]["sha256"],
        "durable_vfdqa_sha256": manifest["post_abort"]["durable_vfdqa"]["sha256"],
        "retired_claim_sha256": manifest["post_abort"]["retired_claim"]["sha256"],
        "query_sha256": digest(query_raw), "coordinator_redispatched": False,
        "marker_abort_redispatched": False, "marker_absent": True,
        "abort_claim_absent": True, "release_claim_absent": True}


def validate_terminal(manifest, raw, manifest_sha, gate_sha, launcher_sha, approval_sha, query_raw):
    value = strict_json(raw, "recovery-v2 terminal")
    if raw != canonical(value) or value != terminal_document(
            manifest, manifest_sha, gate_sha, launcher_sha, approval_sha, query_raw):
        raise GateError("recovery-v2 terminal differs")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default=MANIFEST)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--gate-sha256", required=True)
    parser.add_argument("--launcher-sha256", required=True)
    parser.add_argument("--launcher-sealed-fd", required=True)
    parser.add_argument("--approval-sha256", default="")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--offline-check", action="store_true")
    modes.add_argument("--execute", action="store_true")
    modes.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    manifest = strict_json(sealed_read(args.manifest, args.manifest_sha256, 0o600, "manifest"),
                           "manifest")
    query_exists = os.path.lexists(manifest.get("outputs", {}).get("query", ""))
    terminal_exists = os.path.lexists(manifest.get("outputs", {}).get("terminal", ""))
    predecessor_manifest, raws, documents = validate_manifest(
        manifest, args.execute or args.resume, args.resume or terminal_exists or query_exists)
    sealed_read(__file__, args.gate_sha256, 0o700, "gate")
    sealed_read(args.launcher_sealed_fd, args.launcher_sha256, 0o700, "launcher")
    if args.offline_check:
        print("c9b05e9 recovery-v2 offline committed-abort contract passed; no mutation")
        return
    if not SHA.fullmatch(args.approval_sha256):
        raise GateError("execute/resume requires fresh recovery-v2 approval SHA")
    approval_spec = os.stat(manifest["approval_path"], follow_symlinks=False)
    approval_raw = stable_read(manifest["approval_path"], args.approval_sha256, 0o600,
                               approval_spec.st_size, "recovery-v2 approval")
    validate_recovery_approval(manifest, approval_raw, args.manifest_sha256,
                               args.gate_sha256, args.launcher_sha256)
    if terminal_exists and not query_exists:
        raise GateError("terminal exists without recovery-v2 query")
    if query_exists:
        query_raw = stable_generated_read(manifest["outputs"]["query"], "recovery-v2 query")
        validate_query(manifest, query_raw)
    else:
        marker_query_raw = run_marker_query(manifest, digest(raws["authorization"]))
        marker_query = strict_json(marker_query_raw, "marker query")
        validate_receipt(marker_query, manifest, digest(raws["authorization"]), True)
        query_raw = canonical(query_envelope(manifest, canonical(marker_query)))
        validate_query(manifest, query_raw)
        create_once(manifest["outputs"]["query"], query_raw)
    terminal_raw = canonical(terminal_document(manifest, args.manifest_sha256,
        args.gate_sha256, args.launcher_sha256, args.approval_sha256, query_raw))
    if terminal_exists:
        existing = stable_generated_read(manifest["outputs"]["terminal"], "recovery-v2 terminal")
        validate_terminal(manifest, existing, args.manifest_sha256, args.gate_sha256,
                          args.launcher_sha256, args.approval_sha256, query_raw)
        print("c9b05e9 recovery-v2 terminal reattested; no redispatch")
        return
    validate_terminal(manifest, terminal_raw, args.manifest_sha256, args.gate_sha256,
                      args.launcher_sha256, args.approval_sha256, query_raw)
    create_once(manifest["outputs"]["terminal"], terminal_raw)
    print("c9b05e9 recovery-v2 terminal committed; no coordinator or abort redispatch")


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("c9b05e9 recovery-v2 gate: " + str(error), file=sys.stderr)
        raise SystemExit(1)
