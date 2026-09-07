#!/usr/bin/env python3
"""Sealed gate for the honest schema-7 abort of operation c9b05e9.

Offline mode validates only immutable local evidence.  Execute/resume remain
approval-gated and delegate all host mutation and live peer attestation to the
sealed coordinator; this gate never fabricates attempt3 cleanup evidence.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import fcntl
import gzip
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

OP = "c9b05e9bea4140d69f9d137a0f992ba0"
OLD_OP = "305058f7deb84c198bad4103d6c4f946"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
MANIFEST = "/home/wilf/data/viewflow/deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-manifest.json"
MARKER_PARENT = "/home/wilf/.local/state/viewflow"
HEX = re.compile(r"[0-9a-f]{64}\Z")
RENAME_NOREPLACE = 1
ENV = {"HOME": "/home/wilf", "USER": "wilf", "LOGNAME": "wilf",
       "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
       "XDG_RUNTIME_DIR": "/run/user/1000",
       "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"}


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


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def stable_read(path: str, expected: str, mode: int, size: int, label: str) -> bytes:
    if not path.startswith("/") or not HEX.fullmatch(expected) or expected == "0" * 64:
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
        raw = b""
        while len(raw) < size:
            chunk = os.read(fd, min(1 << 20, size - len(raw)))
            if not chunk:
                raise GateError(label + " short read")
            raw += chunk
        if os.read(fd, 1) or identity(os.fstat(fd)) != identity(before) or digest(raw) != expected:
            raise GateError(label + " changed while read")
        return raw
    finally:
        os.close(fd)


def stable_generated_read(path: str, label: str) -> bytes:
    if not (path.startswith(str(ROOT) + "/")
            or path.startswith(MARKER_PARENT + "/.deployment-quarantine.v1.")):
        raise GateError(label + " path is outside the operation root")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600
                and identity(before) == identity(named)):
            raise GateError(label + " metadata differs")
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks)
        if identity(os.fstat(fd)) != identity(before):
            raise GateError(label + " changed while read")
        return raw
    finally:
        os.close(fd)


def sealed_read(path: str, expected: str, mode: int, label: str) -> bytes:
    if not re.fullmatch(r"/proc/self/fd/[0-9]+", path) or not HEX.fullmatch(expected):
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


def read_spec(spec, label, document=True):
    exact_keys(spec, {"path", "sha256", "mode", "size"}, label + " spec")
    if not all(isinstance(spec[key], int) for key in ("mode", "size")):
        raise GateError(label + " metadata types differ")
    raw = stable_read(spec["path"], spec["sha256"], int(str(spec["mode"]), 8),
                      spec["size"], label)
    return strict_json(raw, label) if document else raw


def create_once(path: str, raw: bytes):
    target = Path(path)
    parent = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    temporary = "." + target.name + ".tmp." + str(os.getpid())
    try:
        pst = os.fstat(parent)
        if pst.st_uid != os.geteuid() or stat.S_IMODE(pst.st_mode) != 0o700:
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
                written = os.write(fd, view)
                if written <= 0:
                    raise GateError("create-once short write")
                view = view[written:]
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


def validate_marker(raw: bytes, manifest):
    if not (len(raw) == 256 and raw[:8] == b"VFDQT001"
            and raw[8:13] == bytes((1, 1, 2, 1, 1))):
        raise GateError("active VFDQT header differs")
    length = raw[13]
    ids = b"".join(uuid.UUID(manifest[key]).bytes for key in
                   ("source_display_id", "target_device_id", "coordinator_instance_id"))
    if (not 16 <= length <= 128 or raw[14:16] != b"\0\0"
            or raw[16:16 + length].decode("ascii", "strict") != OP
            or any(raw[16 + length:144]) or raw[144:192] != ids
            or int.from_bytes(raw[192:200], "little") <= 0
            or int.from_bytes(raw[200:208], "little") != 1 or any(raw[208:])
            or digest(raw) != manifest["active_marker"]["sha256"]):
        raise GateError("active VFDQT identity differs")


def argv_map(argv):
    if not (isinstance(argv, list) and all(isinstance(item, str) for item in argv)
            and argv[:2] == ["/home/wilf/data/viewflow/deploy/coordinated-v13-to-v2.sh",
                             "--abort-failed-v13"]):
        raise GateError("coordinator argv prefix differs")
    result = {"--abort-failed-v13": True}
    index = 2
    while index < len(argv):
        key = argv[index]
        if key == "--failed-v13-original-generation-only":
            if key in result:
                raise GateError("duplicate coordinator flag")
            result[key] = True
            index += 1
            continue
        if not key.startswith("--") or index + 1 >= len(argv) or key in result:
            raise GateError("coordinator argv is not exact option/value pairs")
        result[key] = argv[index + 1]
        index += 2
    return result


def validate_manifest(value, active_marker_required=True, execution_approval_may_exist=False):
    exact_keys(value, {"schema_version", "state", "execution_authorized", "operation_id",
                       "old_operation_id", "coordinator_instance_id", "source_display_id",
                       "target_device_id", "marker_generation", "recovery_marker_generation",
                       "recovery_boundary", "coordinator", "immutable_inputs", "active_marker",
                       "installed_linux", "windows_expected", "required_absent",
                       "approval_path", "outputs", "post_state_contract", "argv"},
               "manifest")
    if not (value["schema_version"] == 1
            and value["state"] == "viewflow-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-command-manifest"
            and value["execution_authorized"] is False and value["operation_id"] == OP
            and value["old_operation_id"] == OLD_OP and value["marker_generation"] == "1"
            and value["recovery_marker_generation"] == "2"
            and value["recovery_boundary"] == {"phase": "WINDOWS_ROLLED_BACK",
                "failure_phase": "WINDOWS_FORCE_ATTESTED", "mutation_possible": True,
                "force_release_executed": True, "rollback_performed": True,
                "linux_stage_committed": False, "windows_install_committed": False,
                "windows_installer_exit_present": False}):
        raise GateError("manifest identity or truthful rollback boundary differs")
    coordinator = value["coordinator"]
    exact_keys(coordinator, {"path", "sha256", "mode", "size", "checker_path",
                             "checker_sha256", "checker_size", "semantic_test_path",
                             "semantic_test_sha256", "semantic_test_size",
                             "negative_test_path", "negative_test_sha256", "negative_test_size"},
               "coordinator")
    stable_read(coordinator["path"], coordinator["sha256"], 0o755,
                coordinator["size"], "coordinator")
    for stem in ("checker", "semantic_test", "negative_test"):
        path = coordinator[stem + "_path"]
        stable_read(path, coordinator[stem + "_sha256"], 0o755,
                    coordinator[stem + "_size"], stem)
    expected_inputs = {"fresh_lineage", "coordinator_state", "marker_handoff",
        "deployment_publish", "linux_frozen", "windows_request", "windows_prepared",
        "mutation_permit", "force_envelope", "windows_stop", "recovery_bundle",
        "linux_deactivation", "linux_deactivation_transcript", "windows_rollback",
        "first_candidate_commit", "marker_cli_candidate",
        "marker_cli_provenance"}
    exact_keys(value["immutable_inputs"], expected_inputs, "immutable inputs")
    documents = {}
    for name, spec in value["immutable_inputs"].items():
        documents[name] = read_spec(spec, name,
            name not in {"linux_deactivation_transcript", "marker_cli_candidate"})
    state = documents["coordinator_state"]
    committed = state.get("committed_artifacts", {})
    expected_committed = {"marker_handoff": "marker_handoff", "linux_frozen": "linux_frozen",
        "publish_receipt": "deployment_publish", "bootstrap_request": "windows_request",
        "windows_prepared": "windows_prepared", "mutation_permit": "mutation_permit",
        "force_envelope": "force_envelope", "windows_stop_evidence": "windows_stop",
        "recovery_bundle": "recovery_bundle", "windows_rollback": "windows_rollback"}
    if not (state.get("operation_id") == OP and state.get("phase") == "WINDOWS_ROLLED_BACK"
            and state.get("recovery") == {"failure_phase": "WINDOWS_FORCE_ATTESTED",
                                           "mutation_possible": True}
            and committed == {key: value["immutable_inputs"][name]["sha256"]
                              for key, name in expected_committed.items()}):
        raise GateError("coordinator terminal state differs")
    lineage = documents["fresh_lineage"]
    if not (lineage.get("schema_version") == 1
            and lineage.get("state") == "viewflow-v4-inactive-terminal-to-fresh-v21"
            and lineage.get("old_operation_id") == OLD_OP
            and lineage.get("new_operation_id") == OP
            and lineage.get("new_coordinator_instance_id") == value["coordinator_instance_id"]
            and lineage.get("marker_generation") == "1"
            and lineage.get("fresh_boundary") == {
                "protocol_version": "2.1",
                "marker_handoff_sha256": value["immutable_inputs"]["marker_handoff"]["sha256"],
                "deployment_publish_sha256": value["immutable_inputs"]["deployment_publish"]["sha256"],
                "linux_frozen_sha256": value["immutable_inputs"]["linux_frozen"]["sha256"],
                "deployment_marker_sha256": value["active_marker"]["sha256"]}
            and lineage.get("inactive_source", {}).get("windows_old_peer_unchanged") is True
            and lineage.get("inactive_source", {}).get("linux_initially_inactive") is True
            and lineage.get("persistent_v13", {}).get("stopped_by_collector") is True):
        raise GateError("fresh-operation lineage differs")
    provenance = documents["marker_cli_provenance"]
    candidate_spec = value["immutable_inputs"]["marker_cli_candidate"]
    exact_keys(provenance.get("candidate"), {"elf_build_id", "link_count", "mode",
        "owner_uid", "path", "sha256", "size"}, "marker candidate provenance")
    exact_keys(provenance.get("source_sha256"), {"Cargo.lock", "Cargo.toml",
        "crates/viewflow-deployment-marker/Cargo.toml",
        "crates/viewflow-deployment-marker/src/lib.rs",
        "crates/viewflow-deployment-marker/src/main.rs"}, "marker source provenance")
    if not (provenance.get("schema_version") == 1
            and provenance.get("state") == "viewflow-deployment-marker-schema7-locked-offline-candidate-built"
            and provenance.get("operation_id") == OP
            and provenance.get("candidate", {}).get("path") == candidate_spec["path"]
            and provenance.get("candidate", {}).get("sha256") == candidate_spec["sha256"]
            and provenance.get("candidate", {}).get("owner_uid") == 1000
            and provenance.get("candidate", {}).get("mode") == "0755"
            and provenance.get("candidate", {}).get("link_count") == 1
            and provenance.get("candidate", {}).get("size") == candidate_spec["size"]
            and provenance.get("source_sha256") == {
                "Cargo.lock": "fb4345d3841478564c12168203f212b8ee5b660a4f453ac5afce7597a7076c3a",
                "Cargo.toml": "1492ea7e52c7240123fd7ed06bc5cea5b7f177fab76ae63e90ce0a3da2338016",
                "crates/viewflow-deployment-marker/Cargo.toml": "9bc7fee8bfea25d82c2de491280b8ea3572b34cb7760de7d5301f4f2516ac28b",
                "crates/viewflow-deployment-marker/src/lib.rs": "d7d6fee074c3a58b257f31dd95831de55243cd9b407d020c9bb8f9a3c7524d4a",
                "crates/viewflow-deployment-marker/src/main.rs": "7eceaa92bbb17dd087659ab10a9894a62cb55d023e4a0f53eb3b79b47e852de0"}
            and provenance.get("contract", {}).get("authorization_schema_version") == 7
            and provenance.get("contract", {}).get("authorization_state")
                == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"
            and provenance.get("contract", {}).get("force_release_executed") is True
            and provenance.get("contract", {}).get("initial_force_release_executed") is True
            and provenance.get("contract", {}).get("rollback_performed") is True
            and provenance.get("contract", {}).get("linux_stage_committed") is False
            and provenance.get("contract", {}).get("windows_install_committed") is False
            and provenance.get("contract", {}).get("windows_installer_exit_present") is False
            and provenance.get("contract", {}).get("rollback_token_consumed") is True
            and provenance.get("contract", {}).get("protocol_2_1") is False
            and provenance.get("contract", {}).get("abort_point")
                == "abort-claim-atomic-retire-and-parent-directory-fsync"):
        raise GateError("marker schema7 candidate provenance differs")
    first = documents["first_candidate_commit"]
    if not (first.get("schema_version") == 1
            and first.get("state") == "viewflow-normal-v21-first-candidate-committed"
            and first.get("operation_id") == OP
            and first.get("coordinator_instance_id") == value["coordinator_instance_id"]
            and first.get("bridge_final_sha256") == value["immutable_inputs"]["fresh_lineage"]["sha256"]
            and first.get("fresh_boundary") == lineage.get("fresh_boundary")):
        raise GateError("first-candidate commit lineage differs")
    marker = value["active_marker"]
    exact_keys(marker, {"path", "sha256", "mode", "size", "magic"}, "active marker")
    if active_marker_required:
        validate_marker(stable_read(marker["path"], marker["sha256"], 0o600, 256,
                                    "active marker"), value)
    exact_keys(value["installed_linux"], {"viewflowd", "marker_cli", "deskflow",
               "deskflow_core", "viewflow_unit", "deskflow_dropin"}, "installed Linux")
    for name, spec in value["installed_linux"].items():
        read_spec(spec, "installed Linux " + name, False)
    windows = value["windows_expected"]
    exact_keys(windows, {"ssh_target", "user_sid", "old_task_name", "old_task_state",
        "old_task_xml_sha256", "old_binary_path", "old_binary_sha256", "old_wrapper_path",
        "old_wrapper_sha256", "rollback_path", "rollback_sha256", "deployment_task_name",
        "deployment_task_state", "deployment_task_claimed_pre_disable_xml_sha256",
        "deployment_task_xml_sha256", "operation_root",
        "old_viewflow_process_count", "global_viewflow_process_count",
        "deployment_worker_count", "critical_receipts"}, "Windows expected")
    receipts = windows["critical_receipts"]
    names = [item.get("name") for item in receipts] if isinstance(receipts, list) else []
    rollback_document = documents["windows_rollback"]
    stop_document = documents["windows_stop"]
    exact_keys(stop_document, {"schema_version", "state", "operation_id", "request_sha256",
        "claim_sha256", "task_name", "task_xml_sha256", "worker_pid",
        "worker_process_start_filetime_utc", "installer_process_count", "task_state",
        "stopped_at_utc"}, "Windows stop evidence")
    expected_receipts = [
        {"name": "bootstrap-prepared.json", "sha256": value["immutable_inputs"]["windows_prepared"]["sha256"]},
        {"name": "force-release-envelope.json", "sha256": value["immutable_inputs"]["force_envelope"]["sha256"]},
        {"name": "linux-deactivation-proof.json", "sha256": value["immutable_inputs"]["linux_deactivation"]["sha256"]},
        {"name": "linux-deactivation-transcript.json", "sha256": value["immutable_inputs"]["linux_deactivation_transcript"]["sha256"]},
        {"name": "marker-handoff-receipt.json", "sha256": value["immutable_inputs"]["marker_handoff"]["sha256"]},
        {"name": "mutation-permit.json", "sha256": value["immutable_inputs"]["mutation_permit"]["sha256"]},
        {"name": "recovery-bundle.json", "sha256": value["immutable_inputs"]["recovery_bundle"]["sha256"]},
        {"name": "recovery-force-release.json", "sha256": rollback_document.get("recovery_force_release_receipt_sha256")},
        {"name": "request.json", "sha256": value["immutable_inputs"]["windows_request"]["sha256"]},
        {"name": "rollback-manifest.json", "sha256": rollback_document.get("manifest_sha256")},
        {"name": "rollback-token.consumed." + OP + ".json", "sha256": rollback_document.get("token_sha256")},
    ]
    if not (windows["ssh_target"] == "wilf@172.16.105.70"
            and windows["user_sid"] == "S-1-5-21-1940417919-1835306932-1635351729-1001"
            and windows["old_task_name"] == "\\Viewflow Peer"
            and windows["old_task_state"] == "Ready"
            and windows["deployment_task_name"] == "Viewflow Deployment " + OP
            and windows["deployment_task_state"] == "Disabled"
            and windows["deployment_task_claimed_pre_disable_xml_sha256"]
                == "d4cc1972a562c2a18c8a1995a23b70ac32369d42021898a7a2b06f4e72c5372c"
            and windows["deployment_task_xml_sha256"]
                == "f247c5766e1e5011816510d5b52174574e482aab0cee15f5db06de675bacbbd2"
            and windows["deployment_task_xml_sha256"]
                != windows["deployment_task_claimed_pre_disable_xml_sha256"]
            and stop_document.get("schema_version") == 1
            and stop_document.get("state") == "viewflow-windows-bootstrap-stopped"
            and stop_document.get("operation_id") == OP
            and stop_document.get("request_sha256")
                == value["immutable_inputs"]["windows_request"]["sha256"]
            and stop_document.get("task_name") == windows["deployment_task_name"]
            and stop_document.get("task_xml_sha256")
                == windows["deployment_task_claimed_pre_disable_xml_sha256"]
            and stop_document.get("task_state") == "Disabled"
            and stop_document.get("installer_process_count") == 0
            and windows["operation_root"]
                == "C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\" + OP
            and windows["old_viewflow_process_count"] == 0
            and windows["global_viewflow_process_count"] == 0
            and windows["deployment_worker_count"] == 0
            and receipts == expected_receipts
            and names == sorted(names) and len(names) == len(set(names))
            and all(isinstance(item, dict) and set(item) == {"name", "sha256"}
                    and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", str(item["name"]))
                    and HEX.fullmatch(str(item["sha256"])) for item in receipts)
            and all(HEX.fullmatch(str(windows[key])) for key in
                    ("old_task_xml_sha256", "old_binary_sha256", "old_wrapper_sha256",
                     "rollback_sha256", "deployment_task_claimed_pre_disable_xml_sha256",
                     "deployment_task_xml_sha256"))):
        raise GateError("Windows fixed recovery boundary differs")
    outputs = value["outputs"]
    exact_keys(outputs, {"authorization", "abort_receipt", "abort_query", "linux_v13_started",
                         "windows_v13_started", "authenticated_v13_peer", "transition", "terminal"},
               "outputs")
    if len(set(outputs.values())) != len(outputs) or any(
            not path.startswith(str(ROOT) + "/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-")
            for path in outputs.values()):
        raise GateError("output path confinement differs")
    if value["post_state_contract"] != {
            "abi_magic": "VFDQA001", "abi_size": 384,
            "durable_kind": "abort-receipt", "retired_kind": "abort-retired",
            "terminal_retired_field": "retired_claim_path",
            "terminal_sha256_field": "vfdqa_binary_sha256",
            "validator": "validate_post_state"}:
        raise GateError("post-state validation contract differs")
    options = argv_map(value["argv"])
    exact_keys(options, {"--abort-failed-v13", "--fresh-operation-lineage-receipt",
        "--fresh-operation-lineage-receipt-sha256",
        "--post-force-abort-marker-cli-candidate",
        "--post-force-abort-marker-cli-sha256", "--failed-v13-original-generation-only",
        "--operation-id", "--coordinator-instance-id", "--marker-generation",
        "--recovery-marker-generation", "--source-display-id", "--target-device-id",
        "--old-coordinator-state-sha256", "--coordinator-state",
        "--bootstrap-handoff-receipt", "--deployment-publish-receipt",
        "--recovery-deployment-publish-receipt", "--deployment-release-receipt",
        "--bootstrap-linux-evidence", "--windows-bootstrap-request",
        "--windows-prepared-receipt", "--windows-mutation-permit",
        "--windows-force-release-envelope", "--local-windows-rollback-receipt",
        "--linux-deactivation-transcript",
        "--linux-deactivation-proof", "--windows-user-sid", "--windows-task-xml-sha256",
        "--deployment-abort-authorization", "--deployment-abort-receipt",
        "--failed-v13-abort-transition-receipt", "--linux-v13-started-receipt",
        "--windows-v13-started-receipt", "--authenticated-v13-peer-receipt"},
        "coordinator argv options")
    required = {"--fresh-operation-lineage-receipt": value["immutable_inputs"]["fresh_lineage"]["path"],
        "--fresh-operation-lineage-receipt-sha256": value["immutable_inputs"]["fresh_lineage"]["sha256"],
        "--post-force-abort-marker-cli-candidate": candidate_spec["path"],
        "--post-force-abort-marker-cli-sha256": candidate_spec["sha256"],
        "--old-coordinator-state-sha256": value["immutable_inputs"]["coordinator_state"]["sha256"],
        "--operation-id": OP, "--coordinator-instance-id": value["coordinator_instance_id"],
        "--marker-generation": "1", "--recovery-marker-generation": "2",
        "--deployment-abort-authorization": outputs["authorization"],
        "--deployment-abort-receipt": outputs["abort_receipt"],
        "--failed-v13-abort-transition-receipt": outputs["transition"]}
    if any(options.get(key) != expected for key, expected in required.items()):
        raise GateError("coordinator argv binding differs")
    if options.get("--failed-v13-original-generation-only") is not True:
        raise GateError("original generation-only flag absent")
    if any(item in options for item in ("--resume", "--release-deployment-marker", "--bootstrap")):
        raise GateError("manifest contains forbidden coordinator mode")
    expected_absent = [
        MARKER_PARENT + "/deskflow-quarantine.v2",
        MARKER_PARENT + "/deployment-quarantine.v1.abort-claim",
        MARKER_PARENT + "/deployment-quarantine.v1.release-claim",
        str(ROOT / "linux-stage.json"), str(ROOT / "windows-install.json"),
        str(ROOT / "windows-installer-exit.json"), str(ROOT / "readiness.json"),
        str(ROOT / "readiness.lock"), str(ROOT / "readiness-commit-request.json"),
        str(ROOT / "deployment-release.json"),
        str(ROOT / "recovery-deployment-publish.json"),
        *outputs.values(), value["approval_path"]]
    if (value["required_absent"] != expected_absent
            or len(value["required_absent"]) != len(set(value["required_absent"]))):
        raise GateError("required-absent list differs")
    if active_marker_required:
        for path in value["required_absent"]:
            if execution_approval_may_exist and path == value["approval_path"]:
                continue
            if os.path.lexists(path):
                raise GateError("required-absent path exists: " + path)
    return documents


def systemd_state(unit: str):
    result = subprocess.run(["/usr/bin/systemctl", "--user", "show", unit,
        "--property=LoadState", "--property=ActiveState", "--property=SubState",
        "--property=MainPID"], env=ENV, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=True)
    values = dict(line.split("=", 1) for line in result.stdout.decode().splitlines())
    if set(values) != {"LoadState", "ActiveState", "SubState", "MainPID"}:
        raise GateError("systemd census keys differ")
    return values


def exact_process_count(path: str) -> int:
    count = 0
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if os.readlink(entry / "exe") == path:
                count += 1
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    return count


def socket_count(port: int, tcp: bool) -> int:
    count = 0
    for leaf in (("tcp", "tcp6") if tcp else ("udp", "udp6")):
        with open("/proc/net/" + leaf, encoding="ascii") as source:
            next(source)
            for line in source:
                fields = line.split()
                local_port = int(fields[1].rsplit(":", 1)[1], 16)
                if local_port == port and (not tcp or fields[3] == "0A"):
                    count += 1
    return count


def linux_live_census(manifest):
    installed = manifest["installed_linux"]
    return {"schema_version": 1, "state": "viewflow-c9b05e9-linux-live-census",
        "operation_id": OP,
        "marker_present": os.path.lexists(manifest["active_marker"]["path"]),
        "runtime_marker_present": os.path.lexists(
            "/home/wilf/.local/state/viewflow/deskflow-quarantine.v2"),
        "abort_claim_present": os.path.lexists(manifest["active_marker"]["path"] + ".abort-claim"),
        "release_claim_present": os.path.lexists(manifest["active_marker"]["path"] + ".release-claim"),
        "viewflow": systemd_state("viewflow-peer.service"),
        "deskflow": systemd_state("deskflow.service"),
        "viewflow_process_count": exact_process_count(installed["viewflowd"]["path"]),
        "marker_cli_process_count": exact_process_count(installed["marker_cli"]["path"]),
        "deskflow_process_count": exact_process_count(installed["deskflow"]["path"]),
        "deskflow_core_process_count": exact_process_count(installed["deskflow_core"]["path"]),
        "tcp_24800_listener_count": socket_count(24800, True),
        "udp_44119_socket_count": socket_count(44119, False)}


def validate_linux_live_census(value):
    exact_keys(value, {"schema_version", "state", "operation_id", "marker_present",
        "runtime_marker_present", "abort_claim_present", "release_claim_present",
        "viewflow", "deskflow", "viewflow_process_count", "marker_cli_process_count",
        "deskflow_process_count", "deskflow_core_process_count",
        "tcp_24800_listener_count", "udp_44119_socket_count"}, "Linux live census")
    if not (value["schema_version"] == 1 and value["state"] == "viewflow-c9b05e9-linux-live-census"
            and value["operation_id"] == OP and value["marker_present"] is True
            and value["runtime_marker_present"] is False
            and value["abort_claim_present"] is False and value["release_claim_present"] is False
            and value["viewflow"].get("ActiveState") == "inactive"
            and value["viewflow"].get("MainPID") == "0"
            and value["deskflow"].get("ActiveState") == "inactive"
            and value["deskflow"].get("MainPID") == "0"
            and all(value[key] == 0 for key in ("viewflow_process_count",
                "marker_cli_process_count", "deskflow_process_count",
                "deskflow_core_process_count", "tcp_24800_listener_count",
                "udp_44119_socket_count"))):
        raise GateError("Linux exact inactive recovery boundary differs")


def powershell_live_census(manifest) -> str:
    windows = manifest["windows_expected"]
    template = r'''$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function HB([byte[]]$b){$s=[Security.Cryptography.SHA256]::Create();try{(([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','')).ToLowerInvariant()}finally{$s.Dispose()}}
$root='__ROOT__';$rootItem=Get-Item -LiteralPath $root -Force -ErrorAction Stop
if(-not$rootItem.PSIsContainer-or($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or[IO.Path]::GetFullPath($rootItem.FullName)-cne[IO.Path]::GetFullPath($root)){throw 'operation root identity differs'}
$old=Get-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer' -ErrorAction Stop;$deployment=Get-ScheduledTask -TaskPath '\' -TaskName '__DEPLOYMENT_TASK__' -ErrorAction Stop
$enc=New-Object Text.UnicodeEncoding($false,$true);function TH($name){$xml=Export-ScheduledTask -TaskPath '\' -TaskName $name;$pre=$enc.GetPreamble();$body=$enc.GetBytes($xml);$all=New-Object byte[] ($pre.Length+$body.Length);[Array]::Copy($pre,0,$all,0,$pre.Length);[Array]::Copy($body,0,$all,$pre.Length,$body.Length);HB $all}
$exe='__EXE__';$wrapper='__WRAPPER__';$rollback='__ROLLBACK__'
$allViewflow=@(Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'");$oldRows=@($allViewflow|Where-Object{$_.ExecutablePath-and[IO.Path]::GetFullPath($_.ExecutablePath)-ceq$exe});$workers=@(Get-CimInstance Win32_Process|Where-Object{$_.CommandLine-and$_.CommandLine-like'*__OP__*'-and($_.CommandLine-like'*install-viewflow.ps1*'-or$_.CommandLine-like'*start-viewflow-bootstrap.ps1*')})
$expected=@((ConvertFrom-Json -InputObject '__RECEIPT_NAMES__'));$receipts=@();foreach($name in $expected){$path=Join-Path $root ([string]$name);$item=Get-Item -LiteralPath $path -Force -ErrorAction Stop;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'unsafe critical receipt'};$receipts+=([ordered]@{name=[string]$name;sha256=(HB ([IO.File]::ReadAllBytes($item.FullName)))})};$receipts=@($receipts|Sort-Object {[string]$_['name']})
[ordered]@{schema_version=1;state='viewflow-c9b05e9-windows-live-census';operation_id='__OP__';operation_root=$root;old_task_state=[string]$old.State;old_task_xml_sha256=(TH 'Viewflow Peer');deployment_task_state=[string]$deployment.State;deployment_task_xml_sha256=(TH '__DEPLOYMENT_TASK__');old_viewflow_process_count=[int]$oldRows.Count;global_viewflow_process_count=[int]$allViewflow.Count;deployment_worker_count=[int]$workers.Count;installed=[ordered]@{viewflowd_sha256=(HB ([IO.File]::ReadAllBytes($exe)));wrapper_sha256=(HB ([IO.File]::ReadAllBytes($wrapper)));rollback_sha256=(HB ([IO.File]::ReadAllBytes($rollback)))};critical_receipts=$receipts}|ConvertTo-Json -Compress -Depth 6
'''
    replacements = {"__ROOT__": windows["operation_root"], "__DEPLOYMENT_TASK__": windows["deployment_task_name"],
        "__EXE__": windows["old_binary_path"], "__WRAPPER__": windows["old_wrapper_path"],
        "__ROLLBACK__": windows["rollback_path"], "__OP__": OP,
        "__RECEIPT_NAMES__": json.dumps([item["name"] for item in windows["critical_receipts"]],
                                         separators=(",", ":")).replace("'", "''")}
    for key, replacement in replacements.items():
        template = template.replace(key, replacement)
    if not template.isascii():
        raise GateError("Windows census script is not ASCII")
    return template


def windows_live_census(manifest):
    script = powershell_live_census(manifest)
    compressed = gzip.compress(script.encode("ascii"), compresslevel=9, mtime=0)
    payload = base64.b64encode(compressed).decode("ascii")
    bootstrap = ("$i=[IO.MemoryStream]::new([Convert]::FromBase64String('" + payload + "'));"
        "$o=[IO.MemoryStream]::new();$g=[IO.Compression.GzipStream]::new($i,[IO.Compression.CompressionMode]::Decompress);"
        "$g.CopyTo($o);&([ScriptBlock]::Create([Text.Encoding]::ASCII.GetString($o.ToArray())))")
    if not bootstrap.isascii():
        raise GateError("Windows compressed census bootstrap is not ASCII")
    encoded = base64.b64encode(bootstrap.encode("utf-16le")).decode("ascii")
    command = ["/usr/bin/ssh", "-oLogLevel=ERROR", "-oBatchMode=yes",
        "-oConnectTimeout=10", "-oStrictHostKeyChecking=yes",
        manifest["windows_expected"]["ssh_target"], "powershell.exe", "-NoProfile",
        "-NonInteractive", "-EncodedCommand", encoded]
    if len(encoded) > 6_800 or sum(len(item) + 1 for item in command) > 7_000:
        raise GateError("Windows EncodedCommand exceeds the reviewed argv safety bound")
    result = subprocess.run(command, env={"HOME": "/home/wilf", "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if result.returncode != 0:
        raise GateError("Windows readonly census failed")
    validate_powershell_progress_stderr(result.stderr)
    return strict_json(result.stdout.replace(b"\r\n", b"\n"), "Windows live census")


def validate_powershell_progress_stderr(raw: bytes):
    if not raw:
        return
    try:
        text = raw.decode("gbk", "strict").replace("\r\n", "\n")
        prefix = "#< CLIXML\n"
        if not text.startswith(prefix):
            raise GateError("Windows census stderr is not CLIXML")
        root = ET.fromstring(text[len(prefix):])
    except (UnicodeDecodeError, ET.ParseError) as error:
        raise GateError("Windows census stderr is not valid progress CLIXML") from error
    namespace = "{http://schemas.microsoft.com/powershell/2004/04}"
    children = list(root)
    if (root.tag != namespace + "Objs" or not children
            or any(child.tag != namespace + "Obj" or child.attrib.get("S") != "progress"
                   for child in children)
            or any(element.attrib.get("S") == "Error" for element in root.iter())):
        raise GateError("Windows census stderr contains a non-progress record")


def validate_windows_live_census(value, manifest):
    exact_keys(value, {"schema_version", "state", "operation_id", "operation_root",
        "old_task_state", "old_task_xml_sha256", "deployment_task_state",
        "deployment_task_xml_sha256", "old_viewflow_process_count",
        "global_viewflow_process_count", "deployment_worker_count", "installed",
        "critical_receipts"}, "Windows live census")
    windows = manifest["windows_expected"]
    if not (value["schema_version"] == 1 and value["state"] == "viewflow-c9b05e9-windows-live-census"
            and value["operation_id"] == OP and value["operation_root"] == windows["operation_root"]
            and value["old_task_state"] == windows["old_task_state"]
            and value["old_task_xml_sha256"] == windows["old_task_xml_sha256"]
            and value["deployment_task_state"] == windows["deployment_task_state"]
            and value["deployment_task_xml_sha256"] == windows["deployment_task_xml_sha256"]
            and value["old_viewflow_process_count"] == windows["old_viewflow_process_count"]
            and value["global_viewflow_process_count"] == windows["global_viewflow_process_count"]
            and value["deployment_worker_count"] == windows["deployment_worker_count"]
            and value["installed"] == {"viewflowd_sha256": windows["old_binary_sha256"],
                "wrapper_sha256": windows["old_wrapper_sha256"],
                "rollback_sha256": windows["rollback_sha256"]}
            and value["critical_receipts"] == windows["critical_receipts"]):
        raise GateError("Windows exact readonly recovery boundary differs")


def seal(raw: bytes, name: str) -> int:
    fd = os.memfd_create(name, os.MFD_ALLOW_SEALING)
    view = memoryview(raw)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            os.close(fd)
            raise GateError("sealed executable short write")
        view = view[written:]
    os.fchmod(fd, 0o700)
    seals = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
    fcntl.fcntl(fd, fcntl.F_ADD_SEALS, seals)
    os.set_inheritable(fd, True)
    return fd


def run_coordinator(manifest):
    spec = manifest["coordinator"]
    raw = stable_read(spec["path"], spec["sha256"], 0o755, spec["size"], "coordinator")
    fd = seal(raw, "viewflow-schema7-abort-coordinator-c9b05e9")
    try:
        argv = [f"/proc/self/fd/{fd}", *manifest["argv"][1:]]
        result = subprocess.run(argv, env=ENV, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                pass_fds=(fd,), timeout=900)
        if result.returncode != 0:
            raise GateError("sealed coordinator failed rc=" + str(result.returncode))
    finally:
        os.close(fd)


def run_query(manifest, authorization_sha):
    spec = manifest["immutable_inputs"]["marker_cli_candidate"]
    raw = stable_read(spec["path"], spec["sha256"], 0o755, spec["size"], "marker candidate")
    fd = seal(raw, "viewflow-schema7-marker-query-c9b05e9")
    try:
        argv = [f"/proc/self/fd/{fd}", "query", "--operation-id", OP,
                "--coordinator-instance-id", manifest["coordinator_instance_id"],
                "--marker-generation", "1", "--marker-sha256", manifest["active_marker"]["sha256"],
                "--abort-authorization-path", manifest["outputs"]["authorization"],
                "--abort-authorization-sha256", authorization_sha]
        result = subprocess.run(argv, env=ENV, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                pass_fds=(fd,), timeout=30)
        if result.returncode != 0 or result.stderr:
            raise GateError("sealed schema7 marker query failed")
        strict_json(result.stdout, "schema7 abort query")
        return result.stdout
    finally:
        os.close(fd)


def validate_authorization(raw: bytes, manifest):
    value = strict_json(raw, "schema7 authorization")
    exact_keys(value, {"authenticated_v13_peer_receipt_sha256", "authorization_receipt_path",
        "bootstrap_request_sha256", "coordinator_failure_phase", "coordinator_instance_id",
        "coordinator_mutation_possible", "coordinator_terminal_state_sha256",
        "deployment_publish_receipt_sha256", "force_release_executed",
        "fresh_operation_lineage_receipt_sha256", "initial_force_release_executed",
        "linux_deactivation_proof_sha256", "linux_deactivation_transcript_sha256",
        "linux_frozen_evidence_sha256", "linux_stage_committed", "linux_v13_started_receipt_sha256",
        "marker_generation", "marker_handoff_receipt_sha256", "marker_sha256",
        "mutation_permit_published", "mutation_permit_receipt_sha256",
        "old_linux_deskflow_core_sha256", "old_linux_deskflow_sha256",
        "old_linux_viewflowd_sha256", "old_windows_viewflowd_sha256",
        "old_windows_wrapper_sha256", "operation_id", "protocol_2_1",
        "recovery_bundle_sha256", "rollback_performed", "rollback_token_consumed",
        "schema_version", "second_force_release_executed", "state",
        "windows_force_envelope_sha256", "windows_install_committed",
        "windows_installer_exit_present", "windows_prepared_receipt_sha256",
        "windows_rollback_receipt_sha256", "windows_stop_evidence_sha256",
        "windows_v13_started_receipt_sha256"}, "schema7 authorization")
    inputs = manifest["immutable_inputs"]
    bindings = {
        "coordinator_terminal_state_sha256": "coordinator_state",
        "fresh_operation_lineage_receipt_sha256": "fresh_lineage",
        "marker_handoff_receipt_sha256": "marker_handoff",
        "deployment_publish_receipt_sha256": "deployment_publish",
        "linux_frozen_evidence_sha256": "linux_frozen",
        "bootstrap_request_sha256": "windows_request",
        "windows_prepared_receipt_sha256": "windows_prepared",
        "mutation_permit_receipt_sha256": "mutation_permit",
        "windows_force_envelope_sha256": "force_envelope",
        "windows_stop_evidence_sha256": "windows_stop",
        "recovery_bundle_sha256": "recovery_bundle",
        "linux_deactivation_proof_sha256": "linux_deactivation",
        "linux_deactivation_transcript_sha256": "linux_deactivation_transcript",
        "windows_rollback_receipt_sha256": "windows_rollback",
    }
    if not (value.get("schema_version") == 7
            and value.get("state") == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"
            and value.get("operation_id") == OP
            and value.get("coordinator_instance_id") == manifest["coordinator_instance_id"]
            and value.get("marker_generation") == "1"
            and value.get("marker_sha256") == manifest["active_marker"]["sha256"]
            and value.get("authorization_receipt_path") == manifest["outputs"]["authorization"]
            and value.get("coordinator_failure_phase") == "WINDOWS_FORCE_ATTESTED"
            and value.get("coordinator_mutation_possible") is True
            and value.get("mutation_permit_published") is True
            and value.get("force_release_executed") is True
            and value.get("rollback_performed") is True
            and value.get("linux_stage_committed") is False
            and value.get("windows_install_committed") is False
            and value.get("windows_installer_exit_present") is False
            and value.get("initial_force_release_executed") is True
            and value.get("second_force_release_executed") is False
            and value.get("rollback_token_consumed") is True
            and value.get("protocol_2_1") is False
            and value.get("old_linux_viewflowd_sha256") == manifest["installed_linux"]["viewflowd"]["sha256"]
            and value.get("old_linux_deskflow_sha256") == manifest["installed_linux"]["deskflow"]["sha256"]
            and value.get("old_linux_deskflow_core_sha256") == manifest["installed_linux"]["deskflow_core"]["sha256"]
            and value.get("old_windows_viewflowd_sha256") == manifest["windows_expected"]["old_binary_sha256"]
            and value.get("old_windows_wrapper_sha256") == manifest["windows_expected"]["old_wrapper_sha256"]
            and all(value.get(field) == inputs[name]["sha256"]
                    for field, name in bindings.items())):
        raise GateError("schema7 authorization truth/binding differs")
    return value


def validate_receipt(raw: bytes, manifest, authorization_sha: str, replayed: bool):
    value = strict_json(raw, "schema7 abort receipt")
    exact_keys(value, {"abort_authorization_path", "abort_authorization_sha256",
        "abort_claim_path", "abort_committed_at_unix_ms", "abort_committed_at_utc",
        "abort_point", "abort_receipt_path", "aborted_marker_sha256",
        "authenticated_v13_peer_receipt_sha256", "authorization_state",
        "bootstrap_request_sha256", "coordinator_failure_phase", "coordinator_instance_id",
        "coordinator_mutation_possible", "coordinator_terminal_state_sha256",
        "deployment_publish_receipt_sha256", "deployment_release_claimed",
        "force_release_executed", "fresh_operation_lineage_receipt_sha256",
        "initial_force_release_executed", "linux_deactivation_proof_sha256",
        "linux_deactivation_transcript_sha256", "linux_frozen_evidence_sha256",
        "linux_stage_committed", "linux_v13_started_receipt_sha256", "marker_created_at_unix_ms",
        "marker_generation", "marker_handoff_receipt_sha256", "marker_path",
        "mutation_permit_published", "mutation_permit_receipt_sha256", "operation_id",
        "protocol_2_1", "protocol_version", "recovery_bundle_sha256", "replayed",
        "rollback_performed", "rollback_token_consumed", "schema_version",
        "second_force_release_executed", "source_display_id", "state", "target_device_id",
        "windows_force_envelope_sha256", "windows_install_committed",
        "windows_installer_exit_present", "windows_prepared_receipt_sha256", "windows_rollback_receipt_sha256",
        "windows_stop_evidence_sha256", "windows_v13_started_receipt_sha256"},
        "schema7 abort receipt")
    inputs = manifest["immutable_inputs"]
    outputs = manifest["outputs"]
    expected_hashes = {
        "coordinator_terminal_state_sha256": "coordinator_state",
        "fresh_operation_lineage_receipt_sha256": "fresh_lineage",
        "marker_handoff_receipt_sha256": "marker_handoff",
        "deployment_publish_receipt_sha256": "deployment_publish",
        "linux_frozen_evidence_sha256": "linux_frozen",
        "bootstrap_request_sha256": "windows_request",
        "windows_prepared_receipt_sha256": "windows_prepared",
        "mutation_permit_receipt_sha256": "mutation_permit",
        "windows_force_envelope_sha256": "force_envelope",
        "windows_stop_evidence_sha256": "windows_stop",
        "recovery_bundle_sha256": "recovery_bundle",
        "linux_deactivation_proof_sha256": "linux_deactivation",
        "linux_deactivation_transcript_sha256": "linux_deactivation_transcript",
        "windows_rollback_receipt_sha256": "windows_rollback",
    }
    expected_durable = (f"{MARKER_PARENT}/.deployment-quarantine.v1.abort-receipt."
                        f"{manifest['active_marker']['sha256']}.{authorization_sha}.v1")
    if not (value.get("schema_version") == 7 and value.get("state") == "deployment-quarantine-aborted"
            and value.get("authorization_state") == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"
            and value.get("operation_id") == OP and value.get("marker_generation") == "1"
            and value.get("aborted_marker_sha256") == manifest["active_marker"]["sha256"]
            and value.get("abort_authorization_sha256") == authorization_sha
            and value.get("abort_authorization_path") == outputs["authorization"]
            and value.get("abort_receipt_path") == expected_durable
            and value.get("marker_path") == manifest["active_marker"]["path"]
            and value.get("abort_claim_path") == manifest["active_marker"]["path"] + ".abort-claim"
            and value.get("source_display_id") == manifest["source_display_id"]
            and value.get("target_device_id") == manifest["target_device_id"]
            and value.get("coordinator_instance_id") == manifest["coordinator_instance_id"]
            and value.get("protocol_version") == "1.3"
            and value.get("deployment_release_claimed") is False
            and value.get("coordinator_failure_phase") == "WINDOWS_FORCE_ATTESTED"
            and value.get("coordinator_mutation_possible") is True
            and value.get("mutation_permit_published") is True
            and value.get("force_release_executed") is True
            and value.get("rollback_performed") is True
            and value.get("linux_stage_committed") is False
            and value.get("windows_install_committed") is False
            and value.get("windows_installer_exit_present") is False
            and value.get("initial_force_release_executed") is True
            and value.get("second_force_release_executed") is False
            and value.get("rollback_token_consumed") is True
            and value.get("protocol_2_1") is False and value.get("replayed") is replayed
            and all(value.get(field) == inputs[name]["sha256"]
                    for field, name in expected_hashes.items())
            and isinstance(value.get("marker_created_at_unix_ms"), str)
            and value["marker_created_at_unix_ms"].isdigit()
            and int(value["marker_created_at_unix_ms"]) > 0
            and isinstance(value.get("abort_committed_at_unix_ms"), str)
            and value["abort_committed_at_unix_ms"].isdigit()
            and int(value["abort_committed_at_unix_ms"])
                >= int(value["marker_created_at_unix_ms"])
            and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",
                             str(value.get("abort_committed_at_utc")))
            and value.get("abort_point") == "abort-claim-atomic-retire-and-parent-directory-fsync"):
        raise GateError("schema7 abort receipt truth/binding differs")
    return value


def validate_coordinator_outputs(manifest, receipt):
    states = {
        "linux_v13_started": "viewflow-linux-v1.3-started-under-deployment-quarantine",
        "windows_v13_started": "viewflow-windows-v1.3-started-under-deployment-quarantine",
        "authenticated_v13_peer": "viewflow-v1.3-peer-authenticated-under-deployment-quarantine",
    }
    receipt_fields = {
        "linux_v13_started": "linux_v13_started_receipt_sha256",
        "windows_v13_started": "windows_v13_started_receipt_sha256",
        "authenticated_v13_peer": "authenticated_v13_peer_receipt_sha256",
    }
    hashes = {}
    for name, expected_state in states.items():
        raw = stable_generated_read(manifest["outputs"][name], "coordinator " + name)
        value = strict_json(raw, "coordinator " + name)
        if not (value.get("schema_version") == 1 and value.get("state") == expected_state
                and value.get("operation_id") == OP
                and receipt.get(receipt_fields[name]) == digest(raw)):
            raise GateError("coordinator output binding differs: " + name)
        hashes[name] = digest(raw)
    transition_raw = stable_generated_read(manifest["outputs"]["transition"],
                                           "coordinator transition")
    transition = strict_json(transition_raw, "coordinator transition")
    if not (transition.get("schema_version") == 1 and transition.get("operation_id") == OP
            and transition.get("protocol_2_1") is False
            and transition.get("normal_deployment_release") is False
            and transition.get("old_coordinator_terminal_state_sha256")
                == manifest["immutable_inputs"]["coordinator_state"]["sha256"]
            and transition.get("deployment_marker_sha256") == manifest["active_marker"]["sha256"]):
        raise GateError("coordinator transition binding differs")
    hashes["transition"] = digest(transition_raw)
    return hashes


def validate_post_state(manifest, receipt, authorization_sha):
    marker_sha = manifest["active_marker"]["sha256"]
    durable = f"{MARKER_PARENT}/.deployment-quarantine.v1.abort-receipt.{marker_sha}.{authorization_sha}.v1"
    retired = f"{MARKER_PARENT}/.deployment-quarantine.v1.abort-retired.{marker_sha}.{authorization_sha}.v1"
    raw = stable_generated_read(durable, "durable VFDQA")
    committed = int.from_bytes(raw[336:344], "little") if len(raw) >= 344 else 0
    if not (len(raw) == 384 and raw[:8] == b"VFDQA001"
            and raw[8:16] == bytes.fromhex("0101010301000000")
            and digest(raw[16:272]) == marker_sha
            and raw[272:304] == hashlib.sha256(raw[16:272]).digest()
            and hashlib.sha256(raw[:352]).digest() == raw[352:]
            and raw[304:336].hex() == authorization_sha
            and committed > 0 and committed == int(receipt["abort_committed_at_unix_ms"])
            and raw[344:352] == b"\0" * 8 and receipt.get("abort_receipt_path") == durable):
        raise GateError("durable VFDQA ABI differs")
    marker_raw = stable_read(retired, marker_sha, 0o600, 256, "retired abort claim")
    validate_marker(marker_raw, manifest)
    for path in (manifest["active_marker"]["path"],
                 manifest["active_marker"]["path"] + ".abort-claim",
                 manifest["active_marker"]["path"] + ".release-claim"):
        if os.path.lexists(path):
            raise GateError("public marker/claim remains after abort")
    return digest(raw), retired


def validate_approval(manifest, raw, manifest_sha, gate_sha, launcher_sha):
    value = strict_json(raw, "execution approval")
    expected = {"schema_version": 1,
        "state": "viewflow-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-execution-approved",
        "approved": True, "operation_id": OP, "manifest_sha256": manifest_sha,
        "gate_sha256": gate_sha, "launcher_sha256": launcher_sha,
        "coordinator_sha256": manifest["coordinator"]["sha256"],
        "coordinator_state_sha256": manifest["immutable_inputs"]["coordinator_state"]["sha256"],
        "lineage_sha256": manifest["immutable_inputs"]["fresh_lineage"]["sha256"],
        "marker_sha256": manifest["active_marker"]["sha256"],
        "marker_cli_candidate_sha256": manifest["immutable_inputs"]["marker_cli_candidate"]["sha256"],
        "publication_method": "create-once-no-replace-and-parent-fsync",
        "approved_at_utc": value.get("approved_at_utc")}
    if value != expected or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",
            str(value.get("approved_at_utc"))):
        raise GateError("execution approval differs")


def coordinator_dispatch_required(terminal_exists: bool, authorization_exists: bool) -> bool:
    if terminal_exists:
        if not authorization_exists:
            raise GateError("terminal replay is missing its authorization; redispatch forbidden")
        return False
    return not authorization_exists


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
    modes.add_argument("--live-check-only", action="store_true")
    modes.add_argument("--execute", action="store_true")
    modes.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    manifest_raw = sealed_read(args.manifest, args.manifest_sha256, 0o600, "manifest")
    manifest = strict_json(manifest_raw, "manifest")
    raw_outputs = manifest.get("outputs", {})
    terminal_exists = os.path.lexists(raw_outputs.get("terminal", ""))
    recovery_exists = any(os.path.lexists(raw_outputs.get(name, ""))
                          for name in ("abort_receipt", "abort_query", "terminal"))
    authorization_exists = os.path.lexists(raw_outputs.get("authorization", ""))
    active_required = not (args.resume and (recovery_exists or
        (authorization_exists and not os.path.lexists(
            manifest.get("active_marker", {}).get("path", "")))))
    validate_manifest(manifest, active_required, args.execute or args.resume)
    sealed_read(__file__, args.gate_sha256, 0o700, "gate")
    sealed_read(args.launcher_sealed_fd, args.launcher_sha256, 0o700, "launcher")
    if args.offline_check:
        print("c9b05e9 schema7 abort offline contract passed; no SSH or mutation")
        return
    if args.live_check_only:
        linux = linux_live_census(manifest)
        validate_linux_live_census(linux)
        windows = windows_live_census(manifest)
        validate_windows_live_census(windows, manifest)
        print("c9b05e9 schema7 abort cross-host readonly boundary passed; no mutation")
        return
    if not HEX.fullmatch(args.approval_sha256):
        raise GateError("execute/resume requires fresh approval SHA-256")
    approval = stable_read(manifest["approval_path"], args.approval_sha256, 0o600,
                           os.stat(manifest["approval_path"]).st_size, "execution approval")
    validate_approval(manifest, approval, args.manifest_sha256, args.gate_sha256,
                      args.launcher_sha256)
    if coordinator_dispatch_required(terminal_exists, authorization_exists):
        run_coordinator(manifest)
    auth_raw = stable_generated_read(manifest["outputs"]["authorization"],
                                     "schema7 authorization")
    validate_authorization(auth_raw, manifest)
    auth_sha = digest(auth_raw)
    durable_path = (f"{MARKER_PARENT}/.deployment-quarantine.v1.abort-receipt."
                    f"{manifest['active_marker']['sha256']}.{auth_sha}.v1")
    retired_path = (f"{MARKER_PARENT}/.deployment-quarantine.v1.abort-retired."
                    f"{manifest['active_marker']['sha256']}.{auth_sha}.v1")
    if terminal_exists and not os.path.lexists(manifest["outputs"]["abort_receipt"]):
        raise GateError("terminal replay is missing its abort receipt; redispatch forbidden")
    if not terminal_exists and not os.path.lexists(manifest["outputs"]["abort_receipt"]) and not (
            os.path.lexists(durable_path) and os.path.lexists(retired_path)):
        run_coordinator(manifest)
    if terminal_exists:
        if not os.path.lexists(manifest["outputs"]["abort_query"]):
            raise GateError("terminal replay is missing its abort query; redispatch forbidden")
        query_raw = stable_generated_read(manifest["outputs"]["abort_query"],
                                          "persisted schema7 abort query")
    else:
        query_raw = run_query(manifest, auth_sha)
    query = validate_receipt(query_raw, manifest, auth_sha, True)
    if os.path.lexists(manifest["outputs"]["abort_receipt"]):
        receipt_raw = stable_generated_read(manifest["outputs"]["abort_receipt"],
                                            "schema7 abort receipt")
        receipt = validate_receipt(receipt_raw, manifest, auth_sha, False)
    else:
        replay_value = dict(query)
        replay_value["replayed"] = False
        receipt_raw = (json.dumps(replay_value, sort_keys=True,
                                  separators=(",", ":")) + "\n").encode()
        create_once(manifest["outputs"]["abort_receipt"], receipt_raw)
        receipt = validate_receipt(receipt_raw, manifest, auth_sha, False)
    if {key: value for key, value in receipt.items() if key != "replayed"} != {
            key: value for key, value in query.items() if key != "replayed"}:
        raise GateError("schema7 abort query differs from committed receipt")
    coordinator_hashes = validate_coordinator_outputs(manifest, receipt)
    if not os.path.lexists(manifest["outputs"]["abort_query"]):
        create_once(manifest["outputs"]["abort_query"], query_raw)
    elif stable_generated_read(manifest["outputs"]["abort_query"],
                               "persisted schema7 abort query") != query_raw:
        raise GateError("persisted schema7 abort query differs")
    vfdqa_sha, retired = validate_post_state(manifest, receipt, auth_sha)
    terminal = {"schema_version": 1,
        "state": "viewflow-failed-v21-post-force-pre-linux-stage-rollback-schema7-vfdqa-abort-terminal",
        "operation_id": OP, "old_operation_id": OLD_OP, "protocol_2_1": False,
        "force_release_executed": True, "rollback_performed": True,
        "linux_stage_committed": False, "windows_install_committed": False,
        "windows_installer_exit_present": False,
        "manifest_sha256": args.manifest_sha256, "gate_sha256": args.gate_sha256,
        "launcher_sha256": args.launcher_sha256, "approval_sha256": args.approval_sha256,
        "coordinator_sha256": manifest["coordinator"]["sha256"],
        "coordinator_state_sha256": manifest["immutable_inputs"]["coordinator_state"]["sha256"],
        "fresh_operation_lineage_sha256": manifest["immutable_inputs"]["fresh_lineage"]["sha256"],
        "marker_cli_candidate_sha256": manifest["immutable_inputs"]["marker_cli_candidate"]["sha256"],
        "authorization_sha256": auth_sha, "abort_receipt_sha256": digest(receipt_raw),
        "abort_query_sha256": digest(query_raw), "vfdqa_binary_sha256": vfdqa_sha,
        "coordinator_output_sha256": coordinator_hashes,
        "retired_claim_path": retired, "marker_absent": True,
        "public_abort_claim_absent": True, "public_release_claim_absent": True}
    terminal_raw = (json.dumps(terminal, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if terminal_exists:
        existing = stable_generated_read(manifest["outputs"]["terminal"],
                                         "schema7 abort terminal")
        if existing != terminal_raw:
            raise GateError("existing terminal differs")
        print("c9b05e9 schema7 VFDQA abort terminal reattested; no redispatch")
    else:
        create_once(manifest["outputs"]["terminal"], terminal_raw)
        print("c9b05e9 schema7 VFDQA abort terminal committed")


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("c9b05e9 schema7 abort gate: " + str(error), file=sys.stderr)
        raise SystemExit(1)
