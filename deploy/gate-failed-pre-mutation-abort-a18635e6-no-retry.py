#!/usr/bin/env python3
"""Operation a186 truthful no-retry V4 abort gate.

The only marker mutation is performed by the reviewed standalone Rust V4
candidate through a sealed executable fd.  This gate never starts
Viewflow/Deskflow and never mutates the Windows host.
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
import time
import uuid
from pathlib import Path

OP = "a18635e6e23f4304afaca816333f3455"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
MANIFEST_PATH = "/home/wilf/data/viewflow/deploy/failed-pre-mutation-abort-a18635e6-no-retry-manifest.json"
LAUNCHER_PATH = "/home/wilf/data/viewflow/deploy/launch-failed-pre-mutation-abort-a18635e6-no-retry.sh"
GENERIC_CORE = "/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort.py"
GENERIC_CORE_SHA = "feb107342827abc813f5262829a77ddecb6ca1cc19e30cde2710dff540ce87f6"
RENAME_NOREPLACE = 1
SHA = re.compile(r"[0-9a-f]{64}")
UTC_MS = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z")


class GateError(RuntimeError):
    pass


def pairs(items):
    value = {}
    for key, item in items:
        if key in value:
            raise GateError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def strict_json(data: bytes, label: str):
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GateError(f"{label} is not strict UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise GateError(f"{label} must be one JSON object")
    return value


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def exact_keys(value, expected, label):
    if set(value) != set(expected):
        raise GateError(f"{label} keys differ")


def open_exact(path: str, expected_sha: str, mode: int, label: str) -> bytes:
    if not SHA.fullmatch(expected_sha) or expected_sha == "0" * 64 or not path.startswith("/"):
        raise GateError(f"{label} spec is invalid")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == mode
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(fd))):
            raise GateError(f"{label} owner/mode/link/ACL differs")
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(1 << 20, before.st_size - len(data)))
            if not chunk:
                raise GateError(f"{label} short read")
            data += chunk
        if os.read(fd, 1):
            raise GateError(f"{label} grew while read")
        after = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid,
                                 item.st_gid, item.st_nlink, item.st_size,
                                 item.st_mtime_ns, item.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(named) or sha(data) != expected_sha:
            raise GateError(f"{label} identity or SHA-256 changed")
        return data
    finally:
        os.close(fd)


def open_owned(path: str, mode: int, label: str) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == mode
                and before.st_size >= 0
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(fd))):
            raise GateError(f"{label} owner/mode/link/ACL differs")
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(1 << 20, before.st_size - len(data)))
            if not chunk:
                raise GateError(f"{label} short read")
            data += chunk
        if os.read(fd, 1):
            raise GateError(f"{label} grew while read")
        after = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid,
                                 item.st_gid, item.st_nlink, item.st_size,
                                 item.st_mtime_ns, item.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(named):
            raise GateError(f"{label} identity changed")
        return data
    finally:
        os.close(fd)


def open_sealed(path: str, expected_sha: str, mode: int, label: str) -> bytes:
    if not re.fullmatch(r"/proc/self/fd/[0-9]+", path) or not SHA.fullmatch(expected_sha):
        raise GateError(f"{label} sealed-fd specification differs")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        required = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 0 and stat.S_IMODE(before.st_mode) == mode
                and fcntl.fcntl(fd, fcntl.F_GET_SEALS) == required):
            raise GateError(f"{label} sealed-fd metadata differs")
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(1 << 20, before.st_size - len(data)))
            if not chunk:
                raise GateError(f"{label} sealed-fd short read")
            data += chunk
        identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid,
                                 item.st_gid, item.st_nlink, item.st_size,
                                 item.st_mtime_ns, item.st_ctime_ns)
        if os.read(fd, 1) or identity(os.fstat(fd)) != identity(before) or sha(data) != expected_sha:
            raise GateError(f"{label} sealed-fd bytes differ")
        return data
    finally:
        os.close(fd)


def read_spec(spec, label, *, document=False):
    exact_keys(spec, {"path", "sha256", "mode"}, f"{label} spec")
    data = open_exact(spec["path"], spec["sha256"], int(str(spec["mode"]), 8), label)
    return strict_json(data, label) if document else data


def load_reviewed_core():
    data = open_exact(GENERIC_CORE, GENERIC_CORE_SHA, 0o755, "reviewed transaction core")
    namespace = {"__name__": "viewflow_no_retry_reviewed_core", "__file__": GENERIC_CORE}
    exec(compile(data, GENERIC_CORE, "exec"), namespace, namespace)
    return namespace


def validate_marker_bytes(raw: bytes, manifest, label: str):
    if len(raw) != 256 or raw[:8] != b"VFDQT001" or raw[8:13] != bytes((1, 1, 2, 1, 1)):
        raise GateError(f"{label} VFDQT header differs")
    length = raw[13]
    if not 16 <= length <= 128 or raw[14:16] != b"\0\0" or any(raw[16 + length:144]):
        raise GateError(f"{label} VFDQT operation field differs")
    if raw[16:16 + length].decode("ascii", "strict") != OP:
        raise GateError(f"{label} VFDQT operation differs")
    expected_ids = b"".join(uuid.UUID(manifest[name]).bytes for name in
                            ("source_display_id", "target_device_id", "coordinator_instance_id"))
    created = int.from_bytes(raw[192:200], "little")
    generation = int.from_bytes(raw[200:208], "little")
    if (raw[144:192] != expected_ids or created <= 0 or generation != 1
            or any(raw[208:256]) or sha(raw) != manifest["marker"]["sha256"]):
        raise GateError(f"{label} VFDQT identity/generation/reserved/hash differs")
    return created


def validate_manifest(manifest, *, allow_transaction_recovery=False):
    exact_keys(manifest, {"schema_version", "state", "execution_authorized", "operation_id",
                          "coordinator_instance_id", "source_display_id", "target_device_id",
                          "marker_generation", "threat_boundary", "terminal_inputs", "marker",
                          "reviewed_marker_cli", "v4_marker_cli", "installed_linux", "windows_baseline",
                          "windows_operation_root_inventory",
                          "remote_mutation_outputs_required_absent", "local_required_absent",
                          "approval_path", "outputs"}, "manifest")
    baseline = manifest["windows_baseline"]
    exact_keys(baseline, {"ssh_host", "user_sid", "viewflowd_sha256", "wrapper_sha256",
                          "rollback_sha256", "old_task_xml_sha256", "old_task_action_sha256",
                          "old_task_principal_sha256", "old_peer_pid", "old_peer_parent_pid",
                          "old_peer_start_filetime_utc", "old_peer_command_line_sha256",
                          "operation_root", "deployment_task_name", "deployment_task_state",
                          "deployment_task_xml_sha256", "deployment_task_live_xml_sha256",
                          "global_relevant_processes"},
               "Windows baseline")
    global_processes = baseline["global_relevant_processes"]
    if not isinstance(global_processes, list) or not global_processes:
        raise GateError("Windows global process census is not a fixed non-empty list")
    global_process_keys = {"pid", "parent_pid", "executable_path", "command_line_sha256"}
    pids = []
    for process in global_processes:
        exact_keys(process, global_process_keys, "Windows global process census member")
        if (not isinstance(process["pid"], int) or process["pid"] <= 0
                or not isinstance(process["parent_pid"], int) or process["parent_pid"] < 0
                or not isinstance(process["executable_path"], str)
                or not process["executable_path"].startswith("C:\\")
                or not SHA.fullmatch(process["command_line_sha256"])
                or process["pid"] in pids):
            raise GateError("Windows global process census member identity differs")
        pids.append(process["pid"])
    if not (manifest["schema_version"] == 4
            and manifest["state"] == "viewflow-failed-pre-mutation-no-retry-abort-command-manifest"
            and manifest["execution_authorized"] is False and manifest["operation_id"] == OP
            and manifest["marker_generation"] == "1"
            and manifest["threat_boundary"] == "cooperating-crash-same-uid-concurrency-path-swap-and-non-owner"):
        raise GateError("manifest class differs")
    for name in ("coordinator_instance_id", "source_display_id", "target_device_id"):
        if str(uuid.UUID(manifest[name])) != manifest[name]:
            raise GateError(f"manifest {name} is not canonical")
    expected_inputs = {"coordinator_state", "marker_handoff", "linux_frozen",
                       "deployment_publish", "bootstrap_request", "installer_exit", "windows_stop"}
    exact_keys(manifest["terminal_inputs"], expected_inputs, "terminal inputs")
    docs = {name: read_spec(spec, name, document=True)
            for name, spec in manifest["terminal_inputs"].items()}
    state = docs["coordinator_state"]
    expected_committed = {
        "marker_handoff": manifest["terminal_inputs"]["marker_handoff"]["sha256"],
        "linux_frozen": manifest["terminal_inputs"]["linux_frozen"]["sha256"],
        "publish_receipt": manifest["terminal_inputs"]["deployment_publish"]["sha256"],
        "bootstrap_request": manifest["terminal_inputs"]["bootstrap_request"]["sha256"],
        "windows_exit": manifest["terminal_inputs"]["installer_exit"]["sha256"],
        "windows_stop_evidence": manifest["terminal_inputs"]["windows_stop"]["sha256"],
    }
    exact_keys(state, {"schema_version", "state", "operation_id", "phase", "recovery",
                       "committed_artifacts", "contract"}, "coordinator state")
    if b"retry" in canonical(state).lower():
        raise GateError("coordinator state contains a retry key, field, or reference")
    if not (state["schema_version"] == 2 and state["state"] == "viewflow-cross-host-bootstrap"
            and state["operation_id"] == OP and state["phase"] == "LINUX_RECOVERED"
            and state["recovery"] == {"failure_phase": "WINDOWS_STARTED", "mutation_possible": False}
            and state["committed_artifacts"] == expected_committed):
        raise GateError("coordinator state is not the exact no-retry terminal")
    contract = state["contract"]
    identity = contract.get("identity", {})
    if not (identity.get("coordinator_instance_id") == manifest["coordinator_instance_id"]
            and identity.get("source_display_id") == manifest["source_display_id"]
            and identity.get("target_device_id") == manifest["target_device_id"]
            and identity.get("marker_generation") == "1"
            and identity.get("windows_task_xml_sha256_override") == ""):
        raise GateError("coordinator identity differs")
    for key, artifact in (("marker_handoff", "marker_handoff"), ("linux_frozen", "linux_frozen"),
                          ("publish_receipt", "deployment_publish")):
        spec = manifest["terminal_inputs"][artifact]
        if contract["inputs"].get(key) != {"path": spec["path"], "sha256": spec["sha256"]}:
            raise GateError(f"coordinator input differs: {key}")
    if (contract["outputs"].get("request") != manifest["terminal_inputs"]["bootstrap_request"]["path"]
            or contract["outputs"].get("windows_exit") != manifest["terminal_inputs"]["installer_exit"]["path"]
            or contract["outputs"].get("windows_stop_evidence") != manifest["terminal_inputs"]["windows_stop"]["path"]):
        raise GateError("coordinator committed output paths differ")
    stop = docs["windows_stop"]
    expected_stop = {"schema_version": 1, "state": "viewflow-windows-bootstrap-stopped",
                     "operation_id": OP,
                     "request_sha256": manifest["terminal_inputs"]["bootstrap_request"]["sha256"],
                     "claim_sha256": "c2b61c20b7ae9c5d60673778f63ae2ae77a58a874f28d99c02a0e17f0c2fecfa",
                     "task_name": "Viewflow Deployment " + OP,
                     "task_xml_sha256": manifest["windows_baseline"]["deployment_task_xml_sha256"],
                     "worker_pid": 15508,
                     "worker_process_start_filetime_utc": "134329703452838931",
                     "installer_process_count": 0, "task_state": "Disabled",
                     "stopped_at_utc": "2026-09-04T04:39:20.552Z"}
    if stop != expected_stop:
        raise GateError("Windows stop evidence differs")
    exit_doc = docs["installer_exit"]
    if not (exit_doc.get("schema_version") == 1
            and exit_doc.get("state") == "viewflow-windows-bootstrap-failed"
            and exit_doc.get("operation_id") == OP and exit_doc.get("exit_code") == 1
            and exit_doc.get("request_sha256") == expected_stop["request_sha256"]
            and exit_doc.get("claim_sha256") == expected_stop["claim_sha256"]):
        raise GateError("installer exit evidence differs")
    handoff, frozen, publish = docs["marker_handoff"], docs["linux_frozen"], docs["deployment_publish"]
    if not (handoff.get("state") == "viewflow-v13-marker-handoff-prepared"
            and handoff.get("operation_id") == OP and handoff.get("deskflow_unit_active_state") == "inactive"
            and handoff.get("deskflow_exact_process_count") == 0
            and handoff.get("deskflow_core_exact_process_count") == 0
            and handoff.get("runtime_marker_present") is False):
        raise GateError("marker handoff does not prove the inactive Deskflow boundary")
    if not (frozen.get("state") == "viewflow-v13-bootstrap-frozen" and frozen.get("operation_id") == OP
            and frozen.get("post_stop", {}).get("unit_active_state") == "inactive"
            and frozen.get("post_stop", {}).get("main_pid") == 0
            and frozen.get("post_stop", {}).get("exact_process_count") == 0):
        raise GateError("Linux frozen evidence does not prove Viewflow inactive")
    if not (publish.get("state") == "deployment-quarantine-published"
            and publish.get("protocol_version") == "2.1" and publish.get("operation_id") == OP
            and publish.get("marker_sha256") == manifest["marker"]["sha256"]):
        raise GateError("deployment publish receipt differs")
    try:
        marker = read_spec(manifest["marker"], "active VFDQT")
    except FileNotFoundError:
        if not allow_transaction_recovery:
            raise GateError("active VFDQT is absent outside execute/recovery")
        marker = None
    if marker is not None:
        validate_marker_bytes(marker, manifest, "active marker")
    reviewed = manifest["reviewed_marker_cli"]
    exact_keys(reviewed, {"path", "sha256", "mode", "reviewed_build_manifest", "role"},
               "reviewed marker CLI")
    if reviewed["role"] != "reviewed-format-and-transaction-contract-anchor-not-executed-because-v4-is-unsupported":
        raise GateError("reviewed marker CLI role is not explicit")
    read_spec({key: reviewed[key] for key in ("path", "sha256", "mode")},
              "reviewed 8d marker CLI")
    reviewed_build = read_spec(reviewed["reviewed_build_manifest"],
                               "reviewed 8d marker CLI provenance", document=True)
    if not (reviewed_build.get("state") == "viewflow-deployment-marker-reviewed-build"
            and reviewed_build.get("candidate") == {"path": reviewed["path"],
                                                      "sha256": reviewed["sha256"],
                                                      "mode": reviewed["mode"]}):
        raise GateError("reviewed 8d marker CLI provenance identity differs")
    v4 = manifest["v4_marker_cli"]
    exact_keys(v4, {"path", "sha256", "mode", "provenance", "role"}, "V4 marker CLI")
    if v4["role"] != "sealed-fd-native-v4-abort-and-query-only":
        raise GateError("V4 marker CLI role differs")
    read_spec({key: v4[key] for key in ("path", "sha256", "mode")}, "V4 marker CLI")
    provenance = read_spec(v4["provenance"], "V4 marker CLI provenance", document=True)
    if not (provenance.get("state") == "viewflow-no-retry-v4-marker-candidate-provenance"
            and provenance.get("operation_id") == OP
            and provenance.get("candidate", {}).get("sha256") == v4["sha256"]):
        raise GateError("V4 marker CLI provenance differs")
    exact_keys(provenance, {"schema_version", "state", "operation_id", "built_at_utc", "target",
                            "toolchain", "base", "standalone", "verification", "candidate"},
               "V4 marker CLI provenance")
    exact_keys(provenance["toolchain"], {"rustc", "rustc_commit", "llvm", "cargo"},
               "V4 marker toolchain")
    exact_keys(provenance["base"], {"main_path", "main_sha256", "lib_path", "lib_sha256",
                                    "cargo_toml_path", "cargo_toml_sha256",
                                    "workspace_cargo_toml_sha256", "workspace_cargo_lock_sha256"},
               "V4 marker base provenance")
    exact_keys(provenance["standalone"], {"source_path", "source_sha256", "cargo_toml_path",
                                          "cargo_toml_sha256", "cargo_lock_path", "cargo_lock_sha256",
                                          "unified_patch_path", "unified_patch_sha256"},
               "V4 marker standalone provenance")
    exact_keys(provenance["verification"], {"cargo_fmt_check", "cargo_test",
                                            "cargo_clippy_all_targets_deny_warnings",
                                            "release_build", "required_v4_tests"},
               "V4 marker verification provenance")
    exact_keys(provenance["candidate"], {"path", "sha256", "build_id", "owner_uid",
                                         "owner_gid", "mode", "link_count", "size"},
               "V4 marker candidate provenance")
    repository = "/home/wilf/data/viewflow/"
    source_pairs = [
        (provenance["base"]["main_path"], provenance["base"]["main_sha256"]),
        (provenance["base"]["lib_path"], provenance["base"]["lib_sha256"]),
        (provenance["base"]["cargo_toml_path"], provenance["base"]["cargo_toml_sha256"]),
        ("Cargo.toml", provenance["base"]["workspace_cargo_toml_sha256"]),
        ("Cargo.lock", provenance["base"]["workspace_cargo_lock_sha256"]),
        (provenance["standalone"]["source_path"], provenance["standalone"]["source_sha256"]),
        (provenance["standalone"]["cargo_toml_path"], provenance["standalone"]["cargo_toml_sha256"]),
        (provenance["standalone"]["cargo_lock_path"], provenance["standalone"]["cargo_lock_sha256"]),
        (provenance["standalone"]["unified_patch_path"], provenance["standalone"]["unified_patch_sha256"]),
    ]
    for relative, digest in source_pairs:
        if relative.startswith("/") or ".." in Path(relative).parts:
            raise GateError("V4 marker provenance source path differs")
        open_exact(repository + relative, digest, 0o644, "V4 marker provenance source")
    candidate_image = open_exact(v4["path"], v4["sha256"], 0o700, "V4 marker CLI candidate")
    candidate_stat = os.stat(v4["path"], follow_symlinks=False)
    candidate = provenance["candidate"]
    if not (candidate["path"] == v4["path"] and candidate["sha256"] == v4["sha256"]
            and candidate["owner_uid"] == os.geteuid() and candidate["owner_gid"] == os.getegid()
            and candidate["mode"] == "0700" and candidate["link_count"] == 1
            and candidate["size"] == len(candidate_image) == candidate_stat.st_size
            and candidate_image.startswith(b"\x7fELF")):
        raise GateError("V4 marker candidate native identity differs")
    inventory_spec = manifest["windows_operation_root_inventory"]
    exact_keys(inventory_spec, {"path", "sha256", "mode", "member_count", "stable"},
               "Windows operation-root inventory spec")
    inventory = read_spec({key: inventory_spec[key] for key in ("path", "sha256", "mode")},
                          "Windows operation-root inventory", document=True)
    if not (inventory.get("schema_version") == 1
            and inventory.get("state") == "viewflow-windows-operation-root-stable-inventory"
            and inventory.get("operation_id") == OP and inventory.get("stable") is True
            and inventory.get("before") == inventory.get("after")
            and inventory.get("before", {}).get("member_count") == 14
            and len(inventory.get("before", {}).get("members", [])) == 14
            and inventory_spec["member_count"] == 14 and inventory_spec["stable"] is True):
        raise GateError("Windows operation-root inventory is not exact and stable")
    member_keys = {"name", "kind", "length", "sha256", "attributes", "owner", "sddl",
                   "access_rules_protected"}
    names = []
    for member in inventory["before"]["members"]:
        exact_keys(member, member_keys, "Windows operation-root inventory member")
        if member["kind"] != "file" or not SHA.fullmatch(member["sha256"]):
            raise GateError("Windows operation-root member identity differs")
        names.append(member["name"])
    expected_inventory_names = {
        "installer.stderr.log", "installer.stdout.log", "installer-exit.json",
        "install-viewflow.ps1", "launcher-claim.json", "launcher-installer-process.json",
        "launcher-stop-evidence.json", "linux-v13-frozen-evidence.json",
        "marker-handoff-receipt.json", "request.json", "rollback-viewflow.ps1",
        "start-viewflow-bootstrap.ps1", "viewflow-client.ps1", "viewflowd.exe"
    }
    if set(names) != expected_inventory_names or len(names) != 14:
        raise GateError("Windows operation-root inventory names differ")
    for name, spec in manifest["installed_linux"].items():
        read_spec(spec, f"installed Linux {name}")
    outputs = manifest["outputs"]
    exact_keys(outputs, {"linux_inactive_pre", "windows_live", "authorization", "abort_receipt",
                         "abort_query_receipt",
                         "linux_inactive_post", "windows_live_post", "terminal"}, "outputs")
    if len(set(outputs.values())) != len(outputs) or any(not path.startswith(str(ROOT) + "/") for path in outputs.values()):
        raise GateError("output paths are not unique operation-local paths")
    if (not isinstance(manifest["local_required_absent"], list)
            or not isinstance(manifest["remote_mutation_outputs_required_absent"], list)
            or len(set(manifest["local_required_absent"])) != len(manifest["local_required_absent"])
            or len(set(manifest["remote_mutation_outputs_required_absent"])) != len(manifest["remote_mutation_outputs_required_absent"])):
        raise GateError("required-absent lists differ")
    return docs, marker


def systemctl(unit: str):
    env = {"PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": f"/run/user/{os.getuid()}",
           "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{os.getuid()}/bus"}
    result = subprocess.run(["/usr/bin/systemctl", "--user", "show", unit,
                             "--property=LoadState", "--property=ActiveState",
                             "--property=SubState", "--property=MainPID"], env=env,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=10)
    text = result.stdout.decode("utf-8", "strict")
    values = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    if set(values) != {"LoadState", "ActiveState", "SubState", "MainPID"}:
        raise GateError(f"systemd properties differ: {unit}")
    return values


def exact_pids(path: str):
    expected = os.path.realpath(path)
    result = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            if os.path.realpath(f"/proc/{name}/exe") == expected:
                result.append(int(name))
        except OSError:
            pass
    return sorted(result)


def global_process_census(manifest):
    known = {spec["sha256"] for spec in manifest["installed_linux"].values()
             if spec["path"].endswith(("viewflowd", "deskflow", "deskflow-core"))}
    known.add(manifest["v4_marker_cli"]["sha256"])
    found = []
    hash_cache = {}
    for name in os.listdir(b"/proc"):
        if not name.isdigit() or int(name) == os.getpid():
            continue
        root = b"/proc/" + name
        try:
            executable = os.readlink(root + b"/exe")
            with open(root + b"/cmdline", "rb", buffering=0) as stream:
                command = stream.read(1 << 20)
            executable_hash = None
            fd = os.open(root + b"/exe", os.O_RDONLY | os.O_CLOEXEC)
            try:
                metadata = os.fstat(fd)
                cache_key = (metadata.st_dev, metadata.st_ino, metadata.st_size,
                             metadata.st_mtime_ns, metadata.st_ctime_ns)
                executable_hash = hash_cache.get(cache_key)
                if executable_hash is None:
                    digest = hashlib.sha256()
                    while True:
                        chunk = os.read(fd, 1 << 20)
                        if not chunk:
                            break
                        digest.update(chunk)
                    executable_hash = digest.hexdigest()
                    hash_cache[cache_key] = executable_hash
            finally:
                os.close(fd)
        except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
            continue
        tokens = [part.rsplit(b"/", 1)[-1].lower() for part in command.split(b"\0") if part]
        basename = executable.rsplit(b"/", 1)[-1].lower()
        relevant = (executable_hash in known or b"viewflow" in basename or b"deskflow" in basename
                    or any(b"viewflow" in token or b"deskflow" in token for token in tokens))
        if relevant:
            found.append({"pid": int(name), "executable_hex": executable.hex(),
                          "executable_sha256": executable_hash,
                          "command_line_sha256": sha(command)})
    return sorted(found, key=lambda item: item["pid"])


def listener_count(kind: str, needle: str):
    result = subprocess.run(["/usr/bin/ss", "-H", "-l", kind], env={"PATH": "/usr/bin:/bin"},
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=True, timeout=10)
    return sum(1 for line in result.stdout.decode("utf-8", "strict").splitlines() if needle in line)


def linux_boundary(manifest):
    vf, df = systemctl("viewflow-peer.service"), systemctl("deskflow.service")
    transient = systemctl("viewflow-v13-no-retry-abort-" + OP + ".service")
    installed = manifest["installed_linux"]
    result = {
        "viewflow_unit_state": vf["ActiveState"], "viewflow_main_pid": int(vf["MainPID"] or "0"),
        "deskflow_unit_state": df["ActiveState"], "deskflow_main_pid": int(df["MainPID"] or "0"),
        "operation_transient_load_state": transient["LoadState"],
        "operation_transient_state": transient["ActiveState"],
        "operation_transient_main_pid": int(transient["MainPID"] or "0"),
        "viewflow_process_count": len(exact_pids(installed["viewflowd"]["path"])),
        "deskflow_process_count": len(exact_pids(installed["deskflow"]["path"])),
        "deskflow_core_process_count": len(exact_pids(installed["deskflow_core"]["path"])),
        "udp_44119_listener_count": listener_count("-unp", ":44119"),
        "tcp_24800_listener_count": listener_count("-tnp", ":24800"),
        "sidecar_socket_present": os.path.lexists(f"/run/user/{os.getuid()}/viewflow/deskflow.sock"),
        "runtime_marker_present": os.path.lexists("/home/wilf/.local/state/viewflow/deskflow-quarantine.v2"),
        "global_relevant_processes": global_process_census(manifest),
    }
    if not (result["viewflow_unit_state"] == "inactive" and result["viewflow_main_pid"] == 0
            and result["deskflow_unit_state"] == "inactive" and result["deskflow_main_pid"] == 0
            and result["operation_transient_load_state"] in ("not-found", "loaded")
            and result["operation_transient_state"] == "inactive"
            and result["operation_transient_main_pid"] == 0
            and result["viewflow_process_count"] == result["deskflow_process_count"] == result["deskflow_core_process_count"] == 0
            and result["udp_44119_listener_count"] == result["tcp_24800_listener_count"] == 0
            and not result["sidecar_socket_present"] and not result["runtime_marker_present"]
            and result["global_relevant_processes"] == []):
        raise GateError("Linux inactive boundary differs")
    return result


def powershell_script(manifest):
    base = manifest["windows_baseline"]
    absent = ",".join("'" + name.replace("'", "''") + "'" for name in manifest["remote_mutation_outputs_required_absent"])
    return rf'''
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$utf8=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=$utf8;$OutputEncoding=$utf8
function Get-VfHash([byte[]]$b){{$s=[Security.Cryptography.SHA256]::Create();try{{return ([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','').ToLowerInvariant()}}finally{{$s.Dispose()}}}}
function Get-VfFileHash([string]$p){{return Get-VfHash ([IO.File]::ReadAllBytes($p))}}
function Get-VfInventory([string]$p){{
  $acl=Get-Acl -LiteralPath $p
  $members=@(Get-ChildItem -LiteralPath $p -Force|Sort-Object Name|ForEach-Object{{
    $a=Get-Acl -LiteralPath $_.FullName
    [ordered]@{{name=$_.Name;kind=$(if($_.PSIsContainer){{'directory'}}else{{'file'}});length=$(if($_.PSIsContainer){{$null}}else{{[int64]$_.Length}});sha256=$(if($_.PSIsContainer){{$null}}else{{Get-VfFileHash $_.FullName}});attributes=[string]$_.Attributes;owner=[string]$a.Owner;sddl=$a.Sddl;access_rules_protected=[bool]$a.AreAccessRulesProtected}}
  }})
  [ordered]@{{root=$p;root_owner=[string]$acl.Owner;root_sddl=$acl.Sddl;root_access_rules_protected=[bool]$acl.AreAccessRulesProtected;member_count=[int64]$members.Count;members=$members}}
}}
$op='{OP}';$root='{base['operation_root']}';$all=@(Get-CimInstance Win32_Process)
$peer=@($all|Where-Object{{[string]$_.ExecutablePath -ieq 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe'}})
if($peer.Count-ne 1){{throw 'old peer process count differs'}};$p=$peer[0];$owner=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
$old=Get-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer' -ErrorAction Stop;$oldXml=Export-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer';$enc=[Text.Encoding]::Unicode;$oldBytes=$enc.GetPreamble()+$enc.GetBytes($oldXml)
$dep=Get-ScheduledTask -TaskPath '\' -TaskName ('Viewflow Deployment '+$op) -ErrorAction Stop;$depXml=Export-ScheduledTask -TaskPath '\' -TaskName ('Viewflow Deployment '+$op);$depBytes=$enc.GetPreamble()+$enc.GetBytes($depXml)
$workers=@($all|Where-Object{{[string]$_.CommandLine -like ('*'+$op+'*') -and [string]$_.CommandLine -like '*start-viewflow-bootstrap.ps1*'}})
$installers=@($all|Where-Object{{[string]$_.CommandLine -like ('*'+$op+'*') -and [string]$_.CommandLine -like '*install-viewflow.ps1*'}})
$relevant=@($all|Where-Object{{([string]$_.Name+' '+[string]$_.ExecutablePath+' '+[string]$_.CommandLine)-match '(?i)viewflow|deskflow'}}|Sort-Object ProcessId|ForEach-Object{{[ordered]@{{pid=[int64]$_.ProcessId;parent_pid=[int64]$_.ParentProcessId;executable_path=[string]$_.ExecutablePath;command_line_sha256=Get-VfHash ([Text.Encoding]::UTF8.GetBytes([string]$_.CommandLine))}}}})
$missing=@();foreach($leaf in @({absent})){{if(Test-Path -LiteralPath (Join-Path $root $leaf)){{$missing+=$leaf}}}}
[ordered]@{{old_peer_pid=[int64]$p.ProcessId;old_peer_parent_pid=[int64]$p.ParentProcessId;old_peer_start_filetime_utc=([datetime]$p.CreationDate).ToUniversalTime().ToFileTimeUtc().ToString();old_peer_session_id=[int64]$p.SessionId;old_peer_sid=[string]$owner.Sid;old_peer_command_line_sha256=Get-VfHash ([Text.Encoding]::UTF8.GetBytes([string]$p.CommandLine));old_peer_viewflowd_sha256=Get-VfFileHash 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe';old_peer_wrapper_sha256=Get-VfFileHash 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1';old_peer_rollback_sha256=Get-VfFileHash 'C:\Users\wilf\AppData\Local\Programs\Viewflow\rollback-viewflow.ps1';old_task_state=[string]$old.State;old_task_xml_sha256=Get-VfHash $oldBytes;operation_root_present=[bool](Test-Path -LiteralPath $root);deployment_task_state=[string]$dep.State;deployment_task_xml_sha256=Get-VfHash $depBytes;bootstrap_worker_count=[int64]$workers.Count;installer_process_count=[int64]$installers.Count;mutation_output_present_count=[int64]$missing.Count;global_relevant_processes=$relevant;operation_root_inventory=Get-VfInventory $root}}|ConvertTo-Json -Compress -Depth 8
'''


def collect_windows(manifest):
    script = powershell_script(manifest)
    packed = base64.b64encode(gzip.compress(script.encode(), mtime=0)).decode()
    decoder = "$b=[Convert]::FromBase64String('" + packed + "');$m=[IO.MemoryStream]::new($b);$g=[IO.Compression.GzipStream]::new($m,[IO.Compression.CompressionMode]::Decompress);$r=[IO.StreamReader]::new($g,[Text.Encoding]::UTF8);$s=$r.ReadToEnd();$r.Dispose();$g.Dispose();$m.Dispose();&([ScriptBlock]::Create($s))"
    encoded = base64.b64encode(decoder.encode("utf-16le")).decode()
    if len(encoded) >= 7500:
        raise GateError("Windows proof command is too large")
    result = subprocess.run(["/usr/bin/ssh", "-F", "/dev/null", "-o", "BatchMode=yes",
                             "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5",
                             "-o", "ServerAliveCountMax=1", "-o", "StrictHostKeyChecking=yes",
                             manifest["windows_baseline"]["ssh_host"], "powershell.exe", "-NoProfile",
                             "-NonInteractive", "-EncodedCommand", encoded],
                            env={"PATH": "/usr/bin:/bin"}, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=True)
    value = strict_json(result.stdout.strip() + b"\n", "Windows live proof")
    baseline = manifest["windows_baseline"]
    expected = {
        "old_peer_pid": baseline["old_peer_pid"], "old_peer_parent_pid": baseline["old_peer_parent_pid"],
        "old_peer_start_filetime_utc": baseline["old_peer_start_filetime_utc"], "old_peer_session_id": 1,
        "old_peer_sid": baseline["user_sid"], "old_peer_command_line_sha256": baseline["old_peer_command_line_sha256"],
        "old_peer_viewflowd_sha256": baseline["viewflowd_sha256"], "old_peer_wrapper_sha256": baseline["wrapper_sha256"],
        "old_peer_rollback_sha256": baseline["rollback_sha256"], "old_task_state": "Running",
        "old_task_xml_sha256": baseline["old_task_xml_sha256"], "operation_root_present": True,
        "deployment_task_state": "Disabled", "deployment_task_xml_sha256": baseline["deployment_task_live_xml_sha256"],
        "bootstrap_worker_count": 0, "installer_process_count": 0, "mutation_output_present_count": 0,
        "global_relevant_processes": baseline["global_relevant_processes"],
        "operation_root_inventory": read_spec(
            {key: manifest["windows_operation_root_inventory"][key]
             for key in ("path", "sha256", "mode")},
            "Windows operation-root inventory", document=True)["before"],
    }
    if value != expected:
        raise GateError("Windows old-peer/disabled-task/no-mutation boundary differs")
    return value


def proof(state: str, boundary, manifest):
    return {"schema_version": 4, "state": state, "operation_id": OP,
            "marker_sha256": manifest["marker"]["sha256"], "observed_at_unix_ms": str(int(time.time() * 1000)),
            "boundary": boundary}


def create_once(path: str, data: bytes):
    target = Path(path)
    if not target.is_absolute() or target.name in ("", ".", ".."):
        raise GateError("output path is not canonical absolute")
    parent = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    tmp = "." + target.name + ".tmp." + str(os.getpid()) + "." + os.urandom(12).hex()
    try:
        pst = os.fstat(parent)
        named_parent = os.stat(target.parent, follow_symlinks=False)
        parent_identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid,
                                        item.st_gid, item.st_nlink, item.st_ctime_ns)
        if (parent_identity(pst) != parent_identity(named_parent)
                or pst.st_uid != os.geteuid() or stat.S_IMODE(pst.st_mode) & 0o077
                or any(name in ("system.posix_acl_access", "system.posix_acl_default")
                       for name in os.listxattr(parent))):
            raise GateError("output parent is not owner-only")
        try:
            fd_existing = os.open(target.name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                                  dir_fd=parent)
        except FileNotFoundError:
            existing = None
        else:
            try:
                before = os.fstat(fd_existing)
                named = os.stat(target.name, dir_fd=parent, follow_symlinks=False)
                if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                        and stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1
                        and before.st_size == len(data)
                        and (before.st_dev, before.st_ino) == (named.st_dev, named.st_ino)
                        and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                                    for name in os.listxattr(fd_existing))):
                    raise GateError("existing output metadata differs")
                existing = os.read(fd_existing, len(data) + 1)
                if os.fstat(fd_existing) != before:
                    raise GateError("existing output changed while read")
            finally:
                os.close(fd_existing)
        if existing is not None:
            if existing != data:
                raise GateError("existing output differs")
            if (parent_identity(os.fstat(parent))
                    != parent_identity(os.stat(target.parent, follow_symlinks=False))
                    or any(name in ("system.posix_acl_access", "system.posix_acl_default")
                           for name in os.listxattr(parent))):
                raise GateError("existing output parent identity/ACL changed")
            return
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600, dir_fd=parent)
        try:
            if any(name in ("system.posix_acl_access", "system.posix_acl_default")
                   for name in os.listxattr(fd)):
                raise GateError("output staging file ACL differs")
            view = memoryview(data)
            while view:
                count = os.write(fd, view)
                if count <= 0:
                    raise GateError("output short write")
                view = view[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renameat2(parent, os.fsencode(tmp), parent, os.fsencode(target.name), RENAME_NOREPLACE) != 0:
            error = ctypes.get_errno()
            if error != 17:
                raise GateError(f"output no-replace rename failed: errno {error}")
        os.fsync(parent)
        if parent_identity(os.fstat(parent)) != parent_identity(os.stat(target.parent, follow_symlinks=False)):
            raise GateError("output parent identity changed")
        fd_readback = os.open(target.name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                              dir_fd=parent)
        try:
            readback_stat = os.fstat(fd_readback)
            named = os.stat(target.name, dir_fd=parent, follow_symlinks=False)
            readback = os.read(fd_readback, len(data) + 1)
            if not (stat.S_ISREG(readback_stat.st_mode) and readback_stat.st_uid == os.geteuid()
                    and stat.S_IMODE(readback_stat.st_mode) == 0o600 and readback_stat.st_nlink == 1
                    and (readback_stat.st_dev, readback_stat.st_ino) == (named.st_dev, named.st_ino)
                    and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                                for name in os.listxattr(fd_readback))):
                raise GateError("output readback identity differs")
        finally:
            os.close(fd_readback)
        if readback != data:
            raise GateError("output readback differs")
    finally:
        try:
            os.unlink(tmp, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def persisted_or_create(path: str, state: str, boundary, manifest):
    if os.path.lexists(path):
        raw = open_owned(path, 0o600, "persisted proof")
        if open_exact(path, sha(raw), 0o600, "persisted proof pathname recheck") != raw:
            raise GateError("persisted proof pathname/hash changed")
        value = strict_json(raw, "persisted proof")
        if value.get("state") != state or value.get("boundary") != boundary:
            raise GateError("persisted proof boundary differs")
        return value, raw
    value = proof(state, boundary, manifest)
    raw = canonical(value)
    create_once(path, raw)
    return value, raw


def authorization(manifest, linux_raw: bytes, windows_raw: bytes):
    inputs = manifest["terminal_inputs"]
    baseline = manifest["windows_baseline"]
    return {
        "schema_version": 4,
        "state": "viewflow-deployment-quarantine-failed-pre-mutation-no-retry-abort-authorized",
        "operation_id": OP, "coordinator_instance_id": manifest["coordinator_instance_id"],
        "marker_generation": "1", "marker_sha256": manifest["marker"]["sha256"],
        "authorization_receipt_path": manifest["outputs"]["authorization"],
        "coordinator_terminal_state_sha256": inputs["coordinator_state"]["sha256"],
        "coordinator_failure_phase": "WINDOWS_STARTED", "coordinator_mutation_possible": False,
        "marker_handoff_receipt_sha256": inputs["marker_handoff"]["sha256"],
        "linux_frozen_evidence_sha256": inputs["linux_frozen"]["sha256"],
        "deployment_publish_receipt_sha256": inputs["deployment_publish"]["sha256"],
        "bootstrap_request_sha256": inputs["bootstrap_request"]["sha256"],
        "installer_exit_receipt_sha256": inputs["installer_exit"]["sha256"],
        "windows_stop_evidence_sha256": inputs["windows_stop"]["sha256"],
        "linux_inactive_proof_sha256": sha(linux_raw), "windows_old_peer_live_proof_sha256": sha(windows_raw),
        "windows_operation_root_inventory_sha256": manifest["windows_operation_root_inventory"]["sha256"],
        "old_linux_viewflowd_sha256": manifest["installed_linux"]["viewflowd"]["sha256"],
        "old_linux_deskflow_sha256": manifest["installed_linux"]["deskflow"]["sha256"],
        "old_linux_deskflow_core_sha256": manifest["installed_linux"]["deskflow_core"]["sha256"],
        "old_windows_viewflowd_sha256": baseline["viewflowd_sha256"],
        "old_windows_wrapper_sha256": baseline["wrapper_sha256"],
        "old_windows_task_xml_sha256": baseline["old_task_xml_sha256"],
        "old_windows_rollback_sha256": baseline["rollback_sha256"],
        "windows_operation_root_present": True, "windows_deployment_task_present": True,
        "windows_deployment_task_state": "Disabled", "windows_bootstrap_worker_count": 0,
        "windows_installer_process_count": 0, "mutation_outputs_absent": True,
        "linux_viewflow_started": False, "linux_deskflow_started": False, "input_producer_count": 0,
        "initial_force_release_executed": False, "rollback_performed": False,
        "windows_rollback_receipt_sha256": None, "protocol_2_1": False,
    }


def marker_cli_args(manifest, auth_sha: str):
    return ["--operation-id", OP,
            "--coordinator-instance-id", manifest["coordinator_instance_id"],
            "--marker-generation", "1", "--marker-sha256", manifest["marker"]["sha256"],
            "--abort-authorization-path", manifest["outputs"]["authorization"],
            "--abort-authorization-sha256", auth_sha]


def run_sealed_marker_cli(manifest, subcommand: str, auth_sha: str) -> bytes:
    spec = manifest["v4_marker_cli"]
    image = open_exact(spec["path"], spec["sha256"], int(str(spec["mode"]), 8),
                       "V4 marker CLI candidate")
    flags = os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING
    fd = os.memfd_create("viewflow-v4-marker-a186", flags)
    try:
        view = memoryview(image)
        while view:
            count = os.write(fd, view)
            if count <= 0:
                raise GateError("sealed marker CLI short write")
            view = view[count:]
        os.fchmod(fd, 0o700)
        seals = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, seals)
        if fcntl.fcntl(fd, fcntl.F_GET_SEALS) != seals:
            raise GateError("marker CLI memfd seals differ")
        result = subprocess.run([f"/proc/self/fd/{fd}", subcommand,
                                 *marker_cli_args(manifest, auth_sha)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, pass_fds=(fd,), timeout=20)
        if result.returncode != 0 or result.stderr:
            raise GateError(f"native V4 marker CLI {subcommand} failed rc={result.returncode}")
        strict_json(result.stdout, f"native V4 marker CLI {subcommand} receipt")
        return result.stdout
    finally:
        os.close(fd)


def validate_native_receipt(raw: bytes, manifest, auth, auth_sha: str, *, require_replay: bool):
    value = strict_json(raw, "native V4 abort receipt")
    expected_keys = {
        "abort_authorization_path", "abort_authorization_sha256", "abort_claim_path",
        "abort_committed_at_unix_ms", "abort_committed_at_utc", "abort_point",
        "abort_receipt_path", "aborted_marker_sha256", "authorization_state",
        "bootstrap_request_sha256", "coordinator_failure_phase", "coordinator_instance_id",
        "coordinator_mutation_possible", "coordinator_terminal_state_sha256",
        "deployment_publish_receipt_sha256", "deployment_release_claimed",
        "initial_force_release_executed", "input_producer_count", "installer_exit_receipt_sha256",
        "linux_deskflow_started", "linux_frozen_evidence_sha256", "linux_inactive_proof_sha256",
        "linux_viewflow_started", "marker_created_at_unix_ms", "marker_generation",
        "marker_handoff_receipt_sha256", "marker_path", "mutation_outputs_absent",
        "old_linux_deskflow_core_sha256", "old_linux_deskflow_sha256",
        "old_linux_viewflowd_sha256", "old_windows_rollback_sha256",
        "old_windows_task_xml_sha256", "old_windows_viewflowd_sha256",
        "old_windows_wrapper_sha256", "operation_id", "protocol_2_1", "protocol_version",
        "replayed", "rollback_performed", "schema_version", "source_display_id", "state",
        "target_device_id", "windows_bootstrap_worker_count",
        "windows_deployment_task_present", "windows_deployment_task_state",
        "windows_installer_process_count", "windows_old_peer_live_proof_sha256",
        "windows_operation_root_inventory_sha256", "windows_operation_root_present",
        "windows_rollback_receipt_sha256", "windows_stop_evidence_sha256"
    }
    exact_keys(value, expected_keys, "native V4 abort receipt")
    copied = {
        "coordinator_terminal_state_sha256", "marker_handoff_receipt_sha256",
        "deployment_publish_receipt_sha256", "linux_frozen_evidence_sha256",
        "bootstrap_request_sha256", "installer_exit_receipt_sha256",
        "windows_stop_evidence_sha256", "linux_inactive_proof_sha256",
        "windows_old_peer_live_proof_sha256", "windows_operation_root_inventory_sha256",
        "old_linux_viewflowd_sha256", "old_linux_deskflow_sha256",
        "old_linux_deskflow_core_sha256", "old_windows_viewflowd_sha256",
        "old_windows_wrapper_sha256", "old_windows_task_xml_sha256",
        "old_windows_rollback_sha256", "coordinator_failure_phase",
        "coordinator_mutation_possible", "windows_operation_root_present",
        "windows_deployment_task_present", "windows_deployment_task_state",
        "windows_bootstrap_worker_count", "windows_installer_process_count",
        "mutation_outputs_absent", "linux_viewflow_started", "linux_deskflow_started",
        "input_producer_count", "initial_force_release_executed", "rollback_performed",
        "windows_rollback_receipt_sha256", "protocol_2_1"
    }
    if any(value[key] != auth[key] for key in copied):
        raise GateError("native V4 receipt does not bind authorization")
    expected_durable = ("/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt."
                        + manifest["marker"]["sha256"] + "." + auth_sha + ".v1")
    expected_marker = "/home/wilf/.local/state/viewflow/deployment-quarantine.v1"
    expected_claim = "/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim"
    if not (value["schema_version"] == 4 and value["state"] == "deployment-quarantine-aborted"
            and value["authorization_state"] == auth["state"]
            and value["operation_id"] == OP
            and value["coordinator_instance_id"] == manifest["coordinator_instance_id"]
            and value["marker_generation"] == "1"
            and value["aborted_marker_sha256"] == manifest["marker"]["sha256"]
            and value["source_display_id"] == manifest["source_display_id"]
            and value["target_device_id"] == manifest["target_device_id"]
            and value["marker_path"] == expected_marker
            and value["abort_claim_path"] == expected_claim
            and value["abort_receipt_path"] == expected_durable
            and value["abort_authorization_path"] == manifest["outputs"]["authorization"]
            and value["abort_authorization_sha256"] == auth_sha
            and value["protocol_version"] == "1.3"
            and value["deployment_release_claimed"] is False
            and value["abort_point"] == "abort-claim-unlink-and-parent-directory-fsync"
            and isinstance(value["marker_created_at_unix_ms"], str)
            and value["marker_created_at_unix_ms"].isdigit()
            and int(value["marker_created_at_unix_ms"]) > 0
            and isinstance(value["abort_committed_at_unix_ms"], str)
            and value["abort_committed_at_unix_ms"].isdigit()
            and int(value["abort_committed_at_unix_ms"]) >= int(value["marker_created_at_unix_ms"])
            and isinstance(value["abort_committed_at_utc"], str)
            and UTC_MS.fullmatch(value["abort_committed_at_utc"])
            and value["replayed"] is require_replay):
        raise GateError("native V4 abort receipt identity differs")
    return value


def inspect_durable_abort_proof(path: str, manifest, auth_sha: str):
    raw = open_owned(path, 0o600, "durable native VFDQA proof")
    if open_exact(path, sha(raw), 0o600, "durable native VFDQA proof pathname recheck") != raw:
        raise GateError("durable native VFDQA proof changed")
    if (len(raw) != 384 or raw[:8] != b"VFDQA001" or raw[8:13] != bytes((1, 1, 1, 3, 1))
            or any(raw[13:16]) or sha(raw[16:272]) != manifest["marker"]["sha256"]
            or raw[272:304] != hashlib.sha256(raw[16:272]).digest()
            or raw[304:336].hex() != auth_sha or int.from_bytes(raw[336:344], "little") <= 0
            or any(raw[344:352]) or raw[352:384] != hashlib.sha256(raw[:352]).digest()):
        raise GateError("durable native VFDQA proof layout differs")
    validate_marker_bytes(raw[16:272], manifest, "durable native VFDQA marker")
    return raw


def read_named_owned(parent_fd: int, name: str, expected: bytes, label: str):
    fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        before = os.fstat(fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, before.st_size - len(data))
            if not chunk:
                raise GateError(f"{label} short read")
            data += chunk
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1
                and (before.st_dev, before.st_ino) == (named.st_dev, named.st_ino)
                and os.fstat(fd) == before and data == expected
                and not any(item in ("system.posix_acl_access", "system.posix_acl_default")
                            for item in os.listxattr(fd))):
            raise GateError(f"{label} identity/bytes differ")
    finally:
        os.close(fd)


def commit_terminal_under_marker_lock(durable_path: str, durable_raw: bytes,
                                      terminal_path: str, terminal_raw: bytes,
                                      *, marker_parent="/home/wilf/.local/state/viewflow",
                                      locked_hook=None):
    parent = os.open(marker_parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    lock = None
    try:
        before = os.fstat(parent)
        named = os.stat(marker_parent, follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid,
                                 item.st_gid, item.st_nlink, item.st_ctime_ns)
        if not (identity(before) == identity(named) and before.st_uid == os.geteuid()
                and stat.S_IMODE(before.st_mode) == 0o700
                and not any(item in ("system.posix_acl_access", "system.posix_acl_default")
                            for item in os.listxattr(parent))):
            raise GateError("marker parent identity/ACL differs at terminal commit")
        lock = os.open(".deployment-quarantine.v1.lock",
                       os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent)
        lock_stat = os.fstat(lock)
        lock_named = os.stat(".deployment-quarantine.v1.lock", dir_fd=parent,
                             follow_symlinks=False)
        if not (stat.S_ISREG(lock_stat.st_mode) and lock_stat.st_uid == os.geteuid()
                and stat.S_IMODE(lock_stat.st_mode) == 0o600 and lock_stat.st_nlink == 1
                and lock_stat.st_size == 0
                and (lock_stat.st_dev, lock_stat.st_ino) == (lock_named.st_dev, lock_named.st_ino)
                and not any(item in ("system.posix_acl_access", "system.posix_acl_default")
                            for item in os.listxattr(lock))):
            raise GateError("marker transaction lock identity/ACL differs")
        fcntl.flock(lock, fcntl.LOCK_EX)
        durable_name = Path(durable_path).name
        if str(Path(durable_path).parent) != marker_parent:
            raise GateError("durable VFDQA parent differs")

        def validate_locked_state():
            for name in ("deployment-quarantine.v1", "deployment-quarantine.v1.abort-claim",
                         "deployment-quarantine.v1.release-claim"):
                try:
                    os.stat(name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                raise GateError("marker/claim appeared before terminal commit: " + name)
            read_named_owned(parent, durable_name, durable_raw, "locked durable VFDQA")
            if (identity(os.fstat(parent)) != identity(os.stat(marker_parent, follow_symlinks=False))
                    or (os.fstat(lock).st_dev, os.fstat(lock).st_ino)
                    != (os.stat(".deployment-quarantine.v1.lock", dir_fd=parent,
                                follow_symlinks=False).st_dev,
                        os.stat(".deployment-quarantine.v1.lock", dir_fd=parent,
                                follow_symlinks=False).st_ino)):
                raise GateError("marker parent/lock changed during terminal commit")

        validate_locked_state()
        if locked_hook is not None:
            locked_hook()
        create_once(terminal_path, terminal_raw)
        validate_locked_state()
    finally:
        if lock is not None:
            os.close(lock)
        os.close(parent)


def validate_approval(manifest, approval_sha: str, gate_sha: str, launcher_sha: str, manifest_sha: str):
    raw = open_exact(manifest["approval_path"], approval_sha, 0o600, "execution approval")
    value = strict_json(raw, "execution approval")
    expected = {"schema_version": 4, "state": "viewflow-failed-pre-mutation-no-retry-abort-execution-approved",
                "approved": True, "operation_id": OP, "manifest_sha256": manifest_sha,
                "gate_sha256": gate_sha, "launcher_sha256": launcher_sha,
                "coordinator_state_sha256": manifest["terminal_inputs"]["coordinator_state"]["sha256"],
                "marker_sha256": manifest["marker"]["sha256"],
                "v4_marker_cli_sha256": manifest["v4_marker_cli"]["sha256"],
                "v4_marker_cli_provenance_sha256": manifest["v4_marker_cli"]["provenance"]["sha256"],
                "transaction_implementation": "sealed-fd-native-rust-v4-abort-then-query",
                "approved_at_utc": value.get("approved_at_utc")}
    if value != expected or not isinstance(value["approved_at_utc"], str) or not UTC_MS.fullmatch(value["approved_at_utc"]):
        raise GateError("execution approval differs")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default=MANIFEST_PATH)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--gate-sha256", required=True)
    parser.add_argument("--launcher-sha256", required=True)
    parser.add_argument("--launcher-sealed-fd", required=True)
    parser.add_argument("--approval-sha256", default="")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--offline-check", action="store_true")
    modes.add_argument("--live-check-only", action="store_true")
    modes.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    manifest_raw = open_sealed(args.manifest, args.manifest_sha256, 0o600, "command manifest")
    manifest = strict_json(manifest_raw, "command manifest")
    validate_manifest(manifest, allow_transaction_recovery=args.execute)
    if not SHA.fullmatch(args.gate_sha256) or not SHA.fullmatch(args.launcher_sha256):
        raise GateError("code SHA-256 argument differs")
    open_sealed(__file__, args.gate_sha256, 0o700, "V4 gate")
    open_sealed(args.launcher_sealed_fd, args.launcher_sha256, 0o700, "V4 launcher")
    terminal_exists = os.path.lexists(manifest["outputs"]["terminal"])
    if not terminal_exists:
        for path in manifest["local_required_absent"]:
            if args.execute and path.endswith("deployment-quarantine.v1.abort-claim"):
                continue
            if os.path.lexists(path):
                raise GateError(f"local required-absent path exists: {path}")
    if args.offline_check:
        if os.path.lexists(manifest["approval_path"]):
            raise GateError("approval already exists during offline review")
        if any(os.path.lexists(path) for path in manifest["outputs"].values()):
            raise GateError("fresh V4 output already exists during offline review")
        print("a186 no-retry V4 offline input/code/transaction contract passed; no SSH or mutation")
        return
    linux = linux_boundary(manifest)
    windows = collect_windows(manifest)
    if args.live_check_only:
        print("a186 no-retry V4 live boundary passed; Linux inactive and Windows old Peer unchanged; no mutation")
        return
    if not args.approval_sha256 or not SHA.fullmatch(args.approval_sha256):
        raise GateError("execute requires an approval SHA-256")
    validate_approval(manifest, args.approval_sha256, args.gate_sha256,
                      args.launcher_sha256, args.manifest_sha256)
    outputs = manifest["outputs"]
    _, linux_raw = persisted_or_create(outputs["linux_inactive_pre"],
                                       "viewflow-no-retry-v4-linux-inactive-pre", linux, manifest)
    _, windows_raw = persisted_or_create(outputs["windows_live"],
                                         "viewflow-no-retry-v4-windows-old-peer-live", windows, manifest)
    auth = authorization(manifest, linux_raw, windows_raw); auth_raw = canonical(auth)
    create_once(outputs["authorization"], auth_raw); auth_sha = sha(auth_raw)
    if linux_boundary(manifest) != linux or collect_windows(manifest) != windows:
        raise GateError("pre-abort Linux/Windows stable boundary changed")
    native_abort_raw = run_sealed_marker_cli(manifest, "abort", auth_sha)
    native_abort = validate_native_receipt(native_abort_raw, manifest, auth, auth_sha,
                                           require_replay=strict_json(native_abort_raw, "abort")["replayed"])
    if os.path.lexists(outputs["abort_receipt"]):
        receipt_raw = open_owned(outputs["abort_receipt"], 0o600, "persisted native abort receipt")
        persisted = validate_native_receipt(receipt_raw, manifest, auth, auth_sha,
                                            require_replay=strict_json(receipt_raw, "persisted abort")["replayed"])
        for key in set(persisted) - {"replayed"}:
            if persisted[key] != native_abort[key]:
                raise GateError("native abort replay differs from persisted receipt")
    else:
        receipt_raw = native_abort_raw
        create_once(outputs["abort_receipt"], receipt_raw)
    native_query_raw = run_sealed_marker_cli(manifest, "query", auth_sha)
    native_query = validate_native_receipt(native_query_raw, manifest, auth, auth_sha,
                                           require_replay=True)
    for key in set(native_query) - {"replayed"}:
        if native_query[key] != native_abort[key]:
            raise GateError("native abort query differs from abort receipt")
    create_once(outputs["abort_query_receipt"], native_query_raw)
    durable_raw = inspect_durable_abort_proof(native_query["abort_receipt_path"], manifest, auth_sha)
    if int.from_bytes(durable_raw[336:344], "little") != int(native_query["abort_committed_at_unix_ms"]):
        raise GateError("durable native VFDQA timestamp differs from native query")
    post_linux = linux_boundary(manifest); post_windows = collect_windows(manifest)
    if post_linux != linux or post_windows != windows:
        raise GateError("post-abort Linux/Windows boundary changed")
    _, post_linux_raw = persisted_or_create(outputs["linux_inactive_post"],
                                            "viewflow-no-retry-v4-linux-inactive-post", post_linux, manifest)
    _, post_windows_raw = persisted_or_create(outputs["windows_live_post"],
                                              "viewflow-no-retry-v4-windows-old-peer-post", post_windows, manifest)
    final_query_raw = run_sealed_marker_cli(manifest, "query", auth_sha)
    final_query = validate_native_receipt(final_query_raw, manifest, auth, auth_sha,
                                          require_replay=True)
    if final_query_raw != native_query_raw or final_query != native_query:
        raise GateError("terminal-adjacent native abort query differs")
    final_durable_raw = inspect_durable_abort_proof(final_query["abort_receipt_path"], manifest,
                                                    auth_sha)
    if final_durable_raw != durable_raw:
        raise GateError("terminal-adjacent durable VFDQA differs")
    terminal = {"schema_version": 4, "state": "viewflow-failed-pre-mutation-no-retry-vfdqa-abort-terminal",
                "operation_id": OP, "coordinator_terminal_state_sha256": manifest["terminal_inputs"]["coordinator_state"]["sha256"],
                "coordinator_failure_phase": "WINDOWS_STARTED", "coordinator_mutation_possible": False,
                "authorization_sha256": auth_sha, "abort_receipt_sha256": sha(receipt_raw),
                "abort_query_receipt_sha256": sha(final_query_raw),
                "vfdqa_binary_sha256": sha(final_durable_raw),
                "execution_approval_sha256": args.approval_sha256,
                "manifest_sha256": args.manifest_sha256,
                "gate_sha256": args.gate_sha256,
                "launcher_sha256": args.launcher_sha256,
                "v4_marker_cli_sha256": manifest["v4_marker_cli"]["sha256"],
                "v4_marker_cli_provenance_sha256": manifest["v4_marker_cli"]["provenance"]["sha256"],
                "linux_inactive_pre_sha256": sha(linux_raw),
                "windows_old_peer_live_sha256": sha(windows_raw), "linux_inactive_post_sha256": sha(post_linux_raw),
                "windows_operation_root_inventory_sha256": manifest["windows_operation_root_inventory"]["sha256"],
                "windows_old_peer_post_sha256": sha(post_windows_raw), "marker_absent": True,
                "abort_claim_absent": True, "release_claim_absent": True, "runtime_marker_absent": True,
                "linux_viewflow_started": False, "linux_deskflow_started": False,
                "input_producer_count": 0,
                "windows_old_peer_unchanged": True, "windows_operation_root_present": True,
                "windows_operation_root_unchanged": True,
                "windows_deployment_task_state": "Disabled", "mutation_outputs_absent": True,
                "protocol_2_1": False}
    commit_terminal_under_marker_lock(final_query["abort_receipt_path"], final_durable_raw,
                                      outputs["terminal"], canonical(terminal))
    print("a186 no-retry V4 VFDQA abort committed; Linux stayed inactive and Windows old Peer stayed unchanged")


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"a186 no-retry V4 gate: {error}", file=sys.stderr)
        raise SystemExit(1)
