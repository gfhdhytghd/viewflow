#!/usr/bin/env python3
"""Sealed, operation-specific VFDQA abort gate for operation 845ce422.

The gate is deliberately unusable until the manifest's four reviewed coordinator
digests are frozen.  Offline mode performs no systemd, SSH, or marker operation.
Live and execute modes use the exact old Windows task and operation-root census.
"""

from __future__ import annotations

import argparse
import calendar
import ctypes
import fcntl
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

OP = "845ce4223e4f426a8a0015d3355595e8"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
MANIFEST = "/home/wilf/data/viewflow/deploy/failed-v21-rollback-abort-845ce422-v2-manifest.json"
SHA = re.compile(r"[0-9a-f]{64}")
UTC_MS = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})\.([0-9]{3})Z")
PLACEHOLDER = re.compile(r"__[A-Z0-9_]+__")
RENAME_NOREPLACE = 1
RUNTIME_ENV = {
    "HOME": "/home/wilf", "USER": "wilf", "LOGNAME": "wilf",
    "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
    "XDG_RUNTIME_DIR": "/run/user/1000",
    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
}


class GateError(RuntimeError):
    pass


def pairs(items):
    out = {}
    for key, value in items:
        if key in out:
            raise GateError("duplicate JSON key: " + key)
        out[key] = value
    return out


def strict_json(raw: bytes, label: str):
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GateError(label + " is not strict UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise GateError(label + " is not one JSON object")
    return value


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def exact_keys(value, expected, label):
    if set(value) != set(expected):
        raise GateError(label + " keys differ")


def _identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def stable_read(path: str, expected: str, mode: int, label: str) -> bytes:
    if not path.startswith("/") or not SHA.fullmatch(expected) or expected == "0" * 64:
        raise GateError(label + " spec is not frozen")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == mode
                and _identity(before) == _identity(named)
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(fd))):
            raise GateError(label + " metadata differs")
        raw = b""
        while len(raw) < before.st_size:
            chunk = os.read(fd, min(1 << 20, before.st_size - len(raw)))
            if not chunk:
                raise GateError(label + " short read")
            raw += chunk
        if (os.read(fd, 1) or _identity(os.fstat(fd)) != _identity(before)
                or _identity(os.stat(path, follow_symlinks=False)) != _identity(before)
                or digest(raw) != expected):
            raise GateError(label + " identity or SHA-256 changed")
        return raw
    finally:
        os.close(fd)


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
        raw = b""
        while len(raw) < before.st_size:
            raw += os.read(fd, before.st_size - len(raw))
        if os.read(fd, 1) or digest(raw) != expected:
            raise GateError(label + " sealed bytes differ")
        return raw
    finally:
        os.close(fd)


def create_once(path: str, raw: bytes):
    target = Path(path)
    parent = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    temporary = "." + target.name + ".tmp." + str(os.getpid()) + "." + os.urandom(8).hex()
    try:
        pst = os.fstat(parent)
        if not (pst.st_uid == os.geteuid() and stat.S_IMODE(pst.st_mode) == 0o700
                and _identity(pst) == _identity(os.stat(target.parent, follow_symlinks=False))
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(parent))):
            raise GateError("output parent metadata differs")
        try:
            os.stat(target.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise GateError("create-once output already exists: " + path)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                     0o600, dir_fd=parent)
        try:
            view = memoryview(raw)
            while view:
                count = os.write(fd, view)
                if count <= 0:
                    raise GateError("output short write")
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


def validate_marker(raw: bytes, manifest):
    marker = manifest["active_marker"]
    if len(raw) != 256 or raw[:8] != b"VFDQT001" or raw[8:13] != bytes((1, 1, 2, 1, 1)):
        raise GateError("active VFDQT header differs")
    length = raw[13]
    ids = b"".join(uuid.UUID(manifest[key]).bytes for key in
                   ("source_display_id", "target_device_id", "coordinator_instance_id"))
    if (not 16 <= length <= 128 or raw[14:16] != b"\0\0"
            or raw[16:16 + length].decode("ascii", "strict") != OP
            or any(raw[16 + length:144]) or raw[144:192] != ids
            or int.from_bytes(raw[192:200], "little") <= 0
            or int.from_bytes(raw[200:208], "little") != 1 or any(raw[208:])
            or digest(raw) != marker["sha256"]):
        raise GateError("active VFDQT identity differs")


def read_spec(spec, label, document=False):
    exact_keys(spec, {"path", "sha256", "mode"}, label + " spec")
    raw = stable_read(spec["path"], spec["sha256"], int(str(spec["mode"]), 8), label)
    return strict_json(raw, label) if document else raw


def validate_manifest(value, *, active_marker_required=True):
    exact_keys(value, {"schema_version", "state", "execution_authorized", "operation_id",
                       "coordinator_instance_id", "source_display_id", "target_device_id",
                       "marker_generation", "recovery_marker_generation", "recovery_boundary",
                       "coordinator", "immutable_inputs", "active_marker", "installed_linux",
                       "windows_expected", "required_absent", "approval_path", "outputs", "argv"},
               "manifest")
    if not (value["schema_version"] == 1
            and value["state"] == "viewflow-failed-v21-rollback-abort-845ce422-v2-command-manifest"
            and value["execution_authorized"] is False and value["operation_id"] == OP
            and value["marker_generation"] == "1" and value["recovery_marker_generation"] == "2"
            and value["recovery_boundary"] == "windows-rolled-back-mutation-possible-original-generation-active"):
        raise GateError("manifest identity differs")
    for key in ("coordinator_instance_id", "source_display_id", "target_device_id"):
        if str(uuid.UUID(value[key])) != value[key]:
            raise GateError(key + " is not canonical")
    coordinator = value["coordinator"]
    exact_keys(coordinator, {"path", "sha256", "mode", "checker_path", "checker_sha256",
                             "semantic_test_path", "semantic_test_sha256", "negative_test_path",
                             "negative_test_sha256", "transient_adoption_test_path",
                             "transient_adoption_test_sha256"}, "coordinator")
    for key in ("sha256", "checker_sha256", "semantic_test_sha256", "negative_test_sha256",
                "transient_adoption_test_sha256"):
        if not SHA.fullmatch(str(coordinator[key])) or PLACEHOLDER.fullmatch(str(coordinator[key])):
            raise GateError("manifest is not refrozen: coordinator " + key)
    stable_read(coordinator["path"], coordinator["sha256"], 0o755, "coordinator")
    stable_read(coordinator["checker_path"], coordinator["checker_sha256"], 0o755,
                "coordinator checker")
    stable_read(coordinator["semantic_test_path"], coordinator["semantic_test_sha256"], 0o755,
                "coordinator semantic test")
    stable_read(coordinator["negative_test_path"], coordinator["negative_test_sha256"], 0o755,
                "coordinator negative test")
    stable_read(coordinator["transient_adoption_test_path"],
                coordinator["transient_adoption_test_sha256"], 0o755, "transient adoption test")
    documents = {}
    expected_inputs = {"fresh_lineage", "old_source_validation", "old_abort_terminal",
                       "old_abort_authorization", "old_abort_receipt", "old_abort_query",
                       "old_vfdqa", "old_durable_vfdqa", "bridge_persistent_started",
                       "coordinator_state", "marker_handoff",
                       "deployment_publish", "linux_frozen", "windows_request",
                       "windows_prepared", "mutation_permit", "force_envelope",
                       "windows_stop", "recovery_bundle", "linux_deactivation_transcript",
                       "linux_deactivation", "windows_validation", "windows_rollback",
                       "candidate_manifest"}
    exact_keys(value["immutable_inputs"], expected_inputs, "immutable inputs")
    for name, spec in value["immutable_inputs"].items():
        raw = read_spec(spec, name, False)
        if name in ("linux_deactivation_transcript", "old_vfdqa", "old_durable_vfdqa"):
            documents[name] = raw
        else:
            documents[name] = strict_json(raw, name)
    state = documents["coordinator_state"]
    if not (state.get("schema_version") == 2 and state.get("state") == "viewflow-cross-host-bootstrap"
            and state.get("operation_id") == OP and state.get("phase") == "WINDOWS_ROLLED_BACK"
            and state.get("recovery") == {"failure_phase": "WINDOWS_FORCE_ATTESTED",
                                           "mutation_possible": True}):
        raise GateError("coordinator state is not the frozen rollback boundary")
    lineage = documents["fresh_lineage"]
    if not (lineage.get("schema_version") == 1
            and lineage.get("state") == "viewflow-v4-inactive-terminal-to-fresh-v21"
            and lineage.get("new_operation_id") == OP):
        raise GateError("fresh operation lineage differs")
    old_op = lineage.get("old_operation_id")
    inactive = lineage.get("inactive_source", {})
    persistent = lineage.get("persistent_v13", {})
    expected_old_hashes = {
        "source_validation_sha256": value["immutable_inputs"]["old_source_validation"]["sha256"],
        "terminal_sha256": value["immutable_inputs"]["old_abort_terminal"]["sha256"],
        "authorization_sha256": value["immutable_inputs"]["old_abort_authorization"]["sha256"],
        "abort_receipt_sha256": value["immutable_inputs"]["old_abort_receipt"]["sha256"],
        "abort_query_receipt_sha256": value["immutable_inputs"]["old_abort_query"]["sha256"],
        "vfdqa_sha256": value["immutable_inputs"]["old_vfdqa"]["sha256"],
    }
    if (old_op != "a18635e6e23f4304afaca816333f3455"
            or any(inactive.get(key) != expected for key, expected in expected_old_hashes.items())
            or persistent.get("persistent_started_sha256")
            != value["immutable_inputs"]["bridge_persistent_started"]["sha256"]):
        raise GateError("fresh lineage does not close over real old abort/bridge files")
    for name in ("old_abort_terminal", "old_abort_authorization",
                 "old_abort_receipt", "old_abort_query"):
        if documents[name].get("operation_id") != old_op:
            raise GateError("old abort/bridge document operation differs: " + name)
    if (documents["old_source_validation"].get("old_operation_id") != old_op
            or documents["bridge_persistent_started"].get("operation_id") != OP):
        raise GateError("old source validation or fresh persistent bridge operation differs")
    old_authorization_sha = value["immutable_inputs"]["old_abort_authorization"]["sha256"]
    old_marker_sha = documents["old_abort_authorization"].get("marker_sha256")
    old_vfdqa = documents["old_vfdqa"]
    old_durable_vfdqa = documents["old_durable_vfdqa"]
    if not (isinstance(old_marker_sha, str) and SHA.fullmatch(old_marker_sha)
            and documents["old_abort_receipt"].get("abort_receipt_path")
            == value["immutable_inputs"]["old_durable_vfdqa"]["path"]
            and old_vfdqa == old_durable_vfdqa
            and len(old_vfdqa) == 384 and old_vfdqa[:8] == b"VFDQA001"
            and old_vfdqa[16:24] == b"VFDQT001"
            and digest(old_vfdqa[16:272]) == old_marker_sha
            and old_vfdqa[272:304].hex() == old_marker_sha
            and old_vfdqa[304:336].hex() == old_authorization_sha
            and hashlib.sha256(old_vfdqa[:352]).digest() == old_vfdqa[352:384]):
        raise GateError("real old durable VFDQA closure differs")
    candidate = documents["candidate_manifest"]
    state_inputs = state.get("contract", {}).get("inputs", {})
    windows_candidate = candidate.get("windows", {})
    for manifest_key, state_key in (("viewflowd", "windows_viewflow"),
                                    ("wrapper", "windows_wrapper"),
                                    ("launcher", "windows_launcher"),
                                    ("installer", "windows_installer")):
        state_spec = state_inputs.get(state_key, {})
        if (windows_candidate.get(manifest_key) != state_spec.get("path")
                or windows_candidate.get(manifest_key + "_sha256") != state_spec.get("sha256")):
            raise GateError("candidate manifest/state Windows path closure differs: " + manifest_key)
    rollback_spec = state_inputs.get("windows_rollback", {})
    if windows_candidate.get("rollback_sha256") != rollback_spec.get("sha256"):
        raise GateError("candidate manifest/state rollback closure differs")
    rollback = documents["windows_rollback"]
    if not (rollback.get("operation_id") == OP
            and rollback.get("state") == "viewflow-windows-rollback-completed"):
        raise GateError("Windows rollback proof differs")
    marker = value["active_marker"]
    exact_keys(marker, {"path", "sha256", "mode", "size", "magic"}, "active marker")
    if marker["size"] != 256 or marker["magic"] != "VFDQT001":
        raise GateError("active marker contract differs")
    if active_marker_required:
        validate_marker(stable_read(marker["path"], marker["sha256"], 0o600, "active marker"), value)
    for name, spec in value["installed_linux"].items():
        read_spec(spec, "installed Linux " + name)
    exact_keys(value["installed_linux"], {"viewflowd", "marker_cli", "deskflow",
                                          "deskflow_core", "viewflow_unit", "deskflow_dropin"},
               "installed Linux")
    windows = value["windows_expected"]
    exact_keys(windows, {"ssh_target", "user_sid", "old_task_name", "old_task_pre_state",
                         "old_task_post_state", "old_task_xml_sha256", "old_binary_sha256",
                         "old_wrapper_sha256", "old_rollback_sha256", "deployment_task_name",
                         "deployment_task_state", "deployment_task_xml_sha256", "operation_root",
                         "forbidden_members", "required_members", "exact_members"}, "Windows expected")
    exact_members = windows["exact_members"]
    exact_names = [item.get("name") for item in exact_members] if isinstance(exact_members, list) else []
    if not (windows["ssh_target"] == "wilf@172.16.105.70"
            and windows["old_task_name"] == "\\Viewflow Peer"
            and windows["old_task_pre_state"] == "Ready"
            and windows["old_task_post_state"] == "Running"
            and windows["deployment_task_state"] == "Disabled"
            and windows["deployment_task_name"] == "Viewflow Deployment " + OP
            and windows["operation_root"] == "C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\" + OP
            and len(set(windows["required_members"])) == len(windows["required_members"])
            and len(set(windows["forbidden_members"])) == len(windows["forbidden_members"])
            and set(windows["required_members"]).isdisjoint(windows["forbidden_members"])
            and exact_names == sorted(exact_names) and len(exact_names) == len(set(exact_names))
            and set(windows["required_members"]).issubset(exact_names)
            and set(windows["forbidden_members"]).isdisjoint(exact_names)
            and all(isinstance(item, dict) and set(item) == {"name", "size", "sha256"}
                    and isinstance(item["name"], str) and item["name"]
                    and isinstance(item["size"], int) and item["size"] >= 0
                    and SHA.fullmatch(str(item["sha256"])) for item in exact_members)):
        raise GateError("Windows fixed boundary differs")
    outputs = value["outputs"]
    required_outputs = {"linux_pre", "windows_pre", "authorization", "abort_receipt",
                        "abort_query", "linux_started", "windows_started", "authenticated",
                        "transition", "linux_post", "windows_post", "terminal"}
    exact_keys(outputs, required_outputs, "outputs")
    if len(set(outputs.values())) != len(outputs):
        raise GateError("outputs are not unique")
    for path in outputs.values():
        if not path.startswith(str(ROOT) + "/"):
            raise GateError("output is not operation-local")
    if value["approval_path"] in outputs.values() or not value["approval_path"].startswith(str(ROOT) + "/"):
        raise GateError("approval path differs")
    argv = value["argv"]
    if not (isinstance(argv, list) and argv[0] == coordinator["path"]
            and argv[1] == "--abort-failed-v13"
            and "--fresh-operation-lineage-receipt" in argv
            and "--failed-v13-original-generation-only" in argv):
        raise GateError("abort argv differs")
    for forbidden in ("--release-deployment-marker", "--bootstrap", "--resume"):
        if forbidden in argv:
            raise GateError("abort argv contains forbidden mode")
    if (not isinstance(value["required_absent"], list)
            or len(value["required_absent"]) != len(set(value["required_absent"]))):
        raise GateError("required-absent set differs")
    if active_marker_required:
        for path in value["required_absent"]:
            if os.path.lexists(path):
                raise GateError("required-absent path exists: " + path)
    return documents


def _systemctl(unit: str):
    result = subprocess.run(["/usr/bin/systemctl", "--user", "show", unit,
                             "--property=LoadState", "--property=ActiveState",
                             "--property=SubState", "--property=MainPID"], env=RUNTIME_ENV,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=15, check=True)
    values = dict(line.split("=", 1) for line in result.stdout.decode().splitlines())
    if set(values) != {"LoadState", "ActiveState", "SubState", "MainPID"}:
        raise GateError("systemd census differs")
    return values


def linux_census(manifest, stage: str):
    return {"schema_version": 1, "state": "viewflow-failed-v21-rollback-abort-linux-" + stage,
            "operation_id": OP, "marker_present": os.path.exists(manifest["active_marker"]["path"]),
            "runtime_marker_present": os.path.exists("/home/wilf/.local/state/viewflow/deskflow-quarantine.v2"),
            "viewflow": _systemctl("viewflow-peer.service"),
            "deskflow": _systemctl("deskflow.service"),
            "viewflow_transient": _systemctl("viewflow-v13-recovery-" + OP + ".service"),
            "deskflow_transient": _systemctl("deskflow-v13-recovery-" + OP + ".service")}


def validate_linux_census(value, stage: str):
    if value.get("runtime_marker_present") is not False:
        raise GateError("runtime marker present at Linux " + stage)
    if stage == "pre":
        if (value.get("marker_present") is not True
                or value["viewflow"].get("ActiveState") != "inactive"
                or value["viewflow"].get("MainPID") != "0"
                or value["deskflow"].get("ActiveState") != "inactive"
                or value["deskflow"].get("MainPID") != "0"
                or value["viewflow_transient"].get("ActiveState") != "inactive"
                or value["deskflow_transient"].get("ActiveState") != "inactive"):
            raise GateError("Linux pre-abort inactive boundary differs")
    elif (value.get("marker_present") is not False
          or value["viewflow_transient"].get("ActiveState") != "active"
          or value["deskflow_transient"].get("ActiveState") != "active"
          or value["viewflow_transient"].get("MainPID") == "0"
          or value["deskflow_transient"].get("MainPID") == "0"):
        raise GateError("Linux post-abort transient v1.3 boundary differs")


def powershell_census(manifest, expected_old_state: str, expected_old_count: int) -> str:
    w = manifest["windows_expected"]
    template = r'''$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function HB([byte[]]$b){$s=[Security.Cryptography.SHA256]::Create();try{(([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','')).ToLowerInvariant()}finally{$s.Dispose()}}
$root='__ROOT__'; $sid='__SID__'; $rootItem=Get-Item -LiteralPath $root -Force -ErrorAction Stop
if(-not$rootItem.PSIsContainer-or($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or[IO.Path]::GetFullPath($rootItem.FullName)-cne[IO.Path]::GetFullPath($root)){throw 'operation root identity differs'}
$rootAcl=Get-Acl -LiteralPath $root -ErrorAction Stop;try{$rootOwner=([Security.Principal.SecurityIdentifier]::new($rootAcl.Owner)).Value}catch{$rootOwner=([Security.Principal.NTAccount]::new($rootAcl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value}
if($rootOwner-cne$sid-or-not$rootAcl.AreAccessRulesProtected){throw 'operation root owner/protection differs'}
$old=Get-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer' -ErrorAction Stop
$new=Get-ScheduledTask -TaskPath '\' -TaskName '__NEW_TASK__' -ErrorAction Stop
$enc=New-Object Text.UnicodeEncoding($false,$true)
function TH($name){$xml=Export-ScheduledTask -TaskPath '\' -TaskName $name;$pre=$enc.GetPreamble();$body=$enc.GetBytes($xml);$all=New-Object byte[] ($pre.Length+$body.Length);[Array]::Copy($pre,0,$all,0,$pre.Length);[Array]::Copy($body,0,$all,$pre.Length,$body.Length);HB $all}
if([string]$old.State-cne'__OLD_STATE__' -or [string]$new.State-cne'Disabled'){throw 'task state differs'}
if((TH 'Viewflow Peer')-cne'__OLD_XML__' -or (TH '__NEW_TASK__')-cne'__NEW_XML__'){throw 'task XML differs'}
$exe='C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe';$wrapper='C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1';$rollback='C:\Users\wilf\AppData\Local\Programs\Viewflow\rollback-viewflow.ps1'
if((HB ([IO.File]::ReadAllBytes($exe)))-cne'__EXE__' -or (HB ([IO.File]::ReadAllBytes($wrapper)))-cne'__WRAPPER__' -or (HB ([IO.File]::ReadAllBytes($rollback)))-cne'__ROLLBACK__'){throw 'installed identity differs'}
$allViewflow=@(Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'");$rows=@($allViewflow|Where-Object{$_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath)-ceq$exe})
$workers=@(Get-CimInstance Win32_Process|Where-Object{$_.CommandLine -and ($_.CommandLine-like'*__OP__*') -and ($_.CommandLine-like'*install-viewflow.ps1*' -or $_.CommandLine-like'*start-viewflow-bootstrap.ps1*')})
if($rows.Count-ne__COUNT__-or$allViewflow.Count-ne__COUNT__-or$workers.Count-ne0){throw 'old peer/global deployment process count differs'}
$items=@(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop);$members=@();foreach($item in $items){if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'unsafe operation-root member'};$members+=([ordered]@{name=$item.Name;size=[long]$item.Length;sha256=(HB ([IO.File]::ReadAllBytes($item.FullName)))})};$members=@($members|Sort-Object name)
$names=@($members|ForEach-Object{$_.name});foreach($name in @(__REQUIRED__)){if($names-cnotcontains$name){throw 'required operation-root member absent'}};foreach($name in @(__FORBIDDEN__)){if($names-ccontains$name){throw 'forbidden mutation output present'}}
$expected=@((ConvertFrom-Json -InputObject '__EXACT__'));if($members.Count-ne$expected.Count){throw 'operation-root exact member count differs'};foreach($want in $expected){$got=@($members|Where-Object{$_.name-ceq$want.name});if($got.Count-ne1-or[long]$got[0].size-ne[long]$want.size-or$got[0].sha256-cne$want.sha256){throw 'operation-root exact member identity differs'}}
[ordered]@{schema_version=1;state='viewflow-failed-v21-rollback-abort-windows-census';operation_id='__OP__';operation_root=$root;operation_root_members=$members;old_task_state=[string]$old.State;old_task_xml_sha256=(TH 'Viewflow Peer');old_process_count=[int]$rows.Count;global_viewflow_process_count=[int]$allViewflow.Count;deployment_worker_count=[int]$workers.Count;deployment_task_state=[string]$new.State;deployment_task_xml_sha256=(TH '__NEW_TASK__');installed=[ordered]@{viewflowd_sha256=(HB ([IO.File]::ReadAllBytes($exe)));wrapper_sha256=(HB ([IO.File]::ReadAllBytes($wrapper)));rollback_sha256=(HB ([IO.File]::ReadAllBytes($rollback)))}}|ConvertTo-Json -Compress -Depth 6
'''
    quoted = lambda values: ",".join("'" + item.replace("'", "''") + "'" for item in values)
    replacements = {"__ROOT__": w["operation_root"], "__SID__": w["user_sid"],
                    "__NEW_TASK__": w["deployment_task_name"], "__OLD_STATE__": expected_old_state,
                    "__OLD_XML__": w["old_task_xml_sha256"], "__NEW_XML__": w["deployment_task_xml_sha256"],
                    "__EXE__": w["old_binary_sha256"], "__WRAPPER__": w["old_wrapper_sha256"],
                    "__ROLLBACK__": w["old_rollback_sha256"], "__COUNT__": str(expected_old_count),
                    "__REQUIRED__": quoted(w["required_members"]),
                    "__FORBIDDEN__": quoted(w["forbidden_members"]),
                    "__EXACT__": json.dumps(w["exact_members"], sort_keys=True,
                                             separators=(",", ":")).replace("'", "''"),
                    "__OP__": OP}
    for key, replacement in replacements.items():
        template = template.replace(key, replacement)
    return template


def windows_census(manifest, state: str, count: int):
    command = ["/usr/bin/ssh", "-o", "LogLevel=ERROR", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
               "-o", "StrictHostKeyChecking=yes", manifest["windows_expected"]["ssh_target"],
               "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
               '"& ([ScriptBlock]::Create([Console]::In.ReadToEnd()))"']
    script_text = powershell_census(manifest, state, count)
    if not script_text.isascii():
        raise GateError("Windows census script is not ASCII")
    script = script_text.encode("ascii")
    result = subprocess.run(command, env={"HOME": "/home/wilf", "PATH": "/usr/bin:/bin",
                                         "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"},
                            input=script, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=45)
    if result.returncode != 0 or result.stderr:
        raise GateError("Windows census failed")
    value = strict_json(result.stdout.replace(b"\r\n", b"\n"), "Windows census")
    members = value.get("operation_root_members")
    if not isinstance(members, list):
        raise GateError("Windows census operation-root members absent")
    value["operation_root_members"] = sorted(members, key=lambda item: item.get("name", "")
                                              if isinstance(item, dict) else "")
    return value


def validate_windows_census(value, manifest, state: str, count: int):
    expected_keys = {"schema_version", "state", "operation_id", "operation_root",
                     "operation_root_members", "old_task_state", "old_task_xml_sha256",
                     "old_process_count", "global_viewflow_process_count",
                     "deployment_worker_count", "deployment_task_state",
                     "deployment_task_xml_sha256", "installed"}
    exact_keys(value, expected_keys, "Windows census")
    w = manifest["windows_expected"]
    members = value["operation_root_members"]
    names = [item.get("name") for item in members] if isinstance(members, list) else []
    if not (value["schema_version"] == 1
            and value["state"] == "viewflow-failed-v21-rollback-abort-windows-census"
            and value["operation_id"] == OP and value["operation_root"] == w["operation_root"]
            and value["old_task_state"] == state
            and value["old_task_xml_sha256"] == w["old_task_xml_sha256"]
            and value["old_process_count"] == count
            and value["global_viewflow_process_count"] == count
            and value["deployment_worker_count"] == 0
            and value["deployment_task_state"] == "Disabled"
            and value["deployment_task_xml_sha256"] == w["deployment_task_xml_sha256"]
            and value["installed"] == {"viewflowd_sha256": w["old_binary_sha256"],
                                        "wrapper_sha256": w["old_wrapper_sha256"],
                                        "rollback_sha256": w["old_rollback_sha256"]}
            and names == sorted(names) and len(names) == len(set(names))
            and members == w["exact_members"]
            and all(isinstance(item, dict) and set(item) == {"name", "size", "sha256"}
                    and isinstance(item["size"], int) and item["size"] >= 0
                    and SHA.fullmatch(str(item["sha256"])) for item in members)):
        raise GateError("Windows census fixed boundary differs")


def validate_approval(manifest, raw: bytes, manifest_sha: str, gate_sha: str, launcher_sha: str):
    value = strict_json(raw, "execution approval")
    expected = {"schema_version": 1,
                "state": "viewflow-failed-v21-rollback-abort-845ce422-v2-execution-approved",
                "approved": True, "operation_id": OP, "manifest_sha256": manifest_sha,
                "gate_sha256": gate_sha, "launcher_sha256": launcher_sha,
                "coordinator_sha256": manifest["coordinator"]["sha256"],
                "coordinator_state_sha256": manifest["immutable_inputs"]["coordinator_state"]["sha256"],
                "lineage_sha256": manifest["immutable_inputs"]["fresh_lineage"]["sha256"],
                "marker_sha256": manifest["active_marker"]["sha256"],
                "publication_method": "create-once-no-replace-and-parent-fsync",
                "approved_at_utc": value.get("approved_at_utc")}
    if value != expected or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z", str(value.get("approved_at_utc"))):
        raise GateError("execution approval differs")


def seal(data: bytes, name: str, mode: int) -> int:
    fd = os.memfd_create(name, os.MFD_ALLOW_SEALING)
    view = memoryview(data)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise GateError("sealed memfd short write")
        view = view[count:]
    os.fchmod(fd, mode)
    flags = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
    fcntl.fcntl(fd, fcntl.F_ADD_SEALS, flags); os.set_inheritable(fd, True)
    return fd


def run_coordinator(manifest):
    spec = manifest["coordinator"]
    raw = stable_read(spec["path"], spec["sha256"], 0o755, "coordinator execution image")
    fd = seal(raw, "viewflow-coordinator-845ce422", 0o700)
    try:
        argv = [f"/proc/self/fd/{fd}", *manifest["argv"][1:]]
        result = subprocess.run(argv, env=RUNTIME_ENV, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                pass_fds=(fd,), timeout=900)
        if result.returncode != 0:
            raise GateError("sealed coordinator failed rc=" + str(result.returncode))
    finally:
        os.close(fd)


def run_marker_query(manifest, authorization_sha: str) -> bytes:
    spec = manifest["installed_linux"]["marker_cli"]
    raw = stable_read(spec["path"], spec["sha256"], 0o755, "installed marker query CLI")
    fd = seal(raw, "viewflow-marker-query-845ce422", 0o700)
    try:
        argv = [f"/proc/self/fd/{fd}", "query", "--operation-id", OP,
                "--coordinator-instance-id", manifest["coordinator_instance_id"],
                "--marker-generation", "1", "--marker-sha256", manifest["active_marker"]["sha256"],
                "--abort-authorization-path", manifest["outputs"]["authorization"],
                "--abort-authorization-sha256", authorization_sha]
        result = subprocess.run(argv, env=RUNTIME_ENV, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                pass_fds=(fd,), timeout=30)
        if result.returncode != 0 or result.stderr:
            raise GateError("sealed marker query failed rc=" + str(result.returncode))
        strict_json(result.stdout, "native marker query")
        return result.stdout
    finally:
        os.close(fd)


def validate_coordinator_outputs(manifest):
    expected = {
        "linux_started": "viewflow-linux-v1.3-started-under-deployment-quarantine",
        "windows_started": "viewflow-windows-v1.3-started-under-deployment-quarantine",
        "authenticated": "viewflow-v1.3-peer-authenticated-under-deployment-quarantine",
        "transition": "viewflow-failed-v1.3-bootstrap-abort-terminal",
    }
    hashes = {}
    for name, state in expected.items():
        value, raw = persisted(manifest["outputs"][name], "coordinator " + name)
        if not (value.get("schema_version") == 1 and value.get("state") == state
                and value.get("operation_id") == OP):
            raise GateError("coordinator output differs: " + name)
        hashes[name] = digest(raw)
    transition, _ = persisted(manifest["outputs"]["transition"], "coordinator transition")
    if not (transition.get("protocol_version") == "1.3"
            and transition.get("protocol_2_1") is False
            and transition.get("normal_deployment_release") is False
            and transition.get("old_coordinator_terminal_state_sha256")
            == manifest["immutable_inputs"]["coordinator_state"]["sha256"]
            and transition.get("deployment_marker_sha256") == manifest["active_marker"]["sha256"]):
        raise GateError("coordinator terminal transition binding differs")
    return hashes


def durable_vfdqa_path(marker_sha: str, authorization_sha: str,
                       marker_parent="/home/wilf/.local/state/viewflow") -> str:
    if not (SHA.fullmatch(marker_sha) and SHA.fullmatch(authorization_sha)):
        raise GateError("durable VFDQA content address differs")
    return (marker_parent + "/.deployment-quarantine.v1.abort-receipt."
            + marker_sha + "." + authorization_sha + ".v1")


def utc_unix_ms(value: str) -> int:
    match = UTC_MS.fullmatch(value) if isinstance(value, str) else None
    if match is None:
        raise GateError("abort receipt UTC is not canonical millisecond UTC")
    try:
        return calendar.timegm(time.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")) * 1000 + int(match.group(2))
    except (OverflowError, ValueError) as error:
        raise GateError("abort receipt UTC is invalid") from error


def validate_abort_receipt(raw: bytes, manifest, authorization_sha: str,
                           *, require_replay: bool):
    value = strict_json(raw, "native schema1 VFDQA abort receipt")
    exact_keys(value, [
        "abort_authorization_path", "abort_authorization_sha256", "abort_claim_path",
        "abort_committed_at_unix_ms", "abort_committed_at_utc", "abort_point",
        "abort_receipt_path", "aborted_marker_sha256", "coordinator_instance_id",
        "deployment_release_claimed", "initial_force_release_executed",
        "marker_created_at_unix_ms", "marker_generation", "marker_path", "operation_id",
        "protocol_2_1", "protocol_version", "replayed", "rollback_token_consumed",
        "schema_version", "second_force_release_executed", "source_display_id", "state",
        "target_device_id"], "native schema1 VFDQA abort receipt")
    marker_sha = manifest["active_marker"]["sha256"]
    expected_durable = durable_vfdqa_path(marker_sha, authorization_sha)
    commit_ms = value.get("abort_committed_at_unix_ms")
    marker_ms = value.get("marker_created_at_unix_ms")
    if not (value.get("schema_version") == 1
            and value.get("state") == "deployment-quarantine-aborted"
            and value.get("operation_id") == OP
            and value.get("coordinator_instance_id") == manifest["coordinator_instance_id"]
            and value.get("marker_generation") == "1"
            and value.get("source_display_id") == manifest["source_display_id"]
            and value.get("target_device_id") == manifest["target_device_id"]
            and value.get("marker_path") == manifest["active_marker"]["path"]
            and value.get("abort_claim_path") == manifest["active_marker"]["path"] + ".abort-claim"
            and value.get("abort_receipt_path") == expected_durable
            and value.get("abort_authorization_path") == manifest["outputs"]["authorization"]
            and value.get("abort_authorization_sha256") == authorization_sha
            and value.get("aborted_marker_sha256") == marker_sha
            and value.get("protocol_version") == "1.3" and value.get("protocol_2_1") is False
            and value.get("deployment_release_claimed") is False
            and value.get("initial_force_release_executed") is True
            and value.get("second_force_release_executed") is False
            and value.get("rollback_token_consumed") is False
            and value.get("abort_point") == "abort-claim-unlink-and-parent-directory-fsync"
            and isinstance(marker_ms, str) and marker_ms.isdigit() and int(marker_ms) > 0
            and isinstance(commit_ms, str) and commit_ms.isdigit()
            and int(commit_ms) >= int(marker_ms)
            and utc_unix_ms(value.get("abort_committed_at_utc")) == int(commit_ms)
            and value.get("replayed") is require_replay):
        raise GateError("native schema1 VFDQA abort receipt identity differs")
    return value


def validate_vfdqa(path: str, manifest, authorization_sha: str, receipt,
                   *, marker_parent="/home/wilf/.local/state/viewflow") -> bytes:
    marker_sha = manifest["active_marker"]["sha256"]
    expected_path = durable_vfdqa_path(marker_sha, authorization_sha, marker_parent)
    if path != expected_path or receipt.get("abort_receipt_path") != expected_path:
        raise GateError("durable VFDQA path is not canonical content-addressed path")
    raw = stable_read(path, digest(Path(path).read_bytes()), 0o600, "durable VFDQA")
    committed_ms = int.from_bytes(raw[336:344], "little") if len(raw) >= 344 else 0
    if not (len(raw) == 384 and raw[:8] == b"VFDQA001"
            and raw[8:16] == bytes.fromhex("0101010301000000")
            and digest(raw[16:272]) == marker_sha
            and raw[272:304] == hashlib.sha256(raw[16:272]).digest()
            and raw[304:336].hex() == authorization_sha
            and committed_ms > 0
            and committed_ms == int(receipt["abort_committed_at_unix_ms"])
            and utc_unix_ms(receipt["abort_committed_at_utc"]) == committed_ms
            and raw[344:352] == b"\0" * 8
            and raw[352:384] == hashlib.sha256(raw[:352]).digest()):
        raise GateError("durable VFDQA ABI or receipt binding differs")
    validate_marker(raw[16:272], manifest)
    return raw


def persisted(path: str, label: str):
    raw = Path(path).read_bytes()
    return strict_json(stable_read(path, digest(raw), 0o600, label), label), raw


def read_named_owned(parent_fd: int, name: str, expected: bytes, label: str):
    fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        before = os.fstat(fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, before.st_size - len(data))
            if not chunk:
                raise GateError(label + " short read")
            data += chunk
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1
                and (before.st_dev, before.st_ino) == (named.st_dev, named.st_ino)
                and os.fstat(fd) == before and data == expected
                and not any(item in ("system.posix_acl_access", "system.posix_acl_default")
                            for item in os.listxattr(fd))):
            raise GateError(label + " identity/bytes differ")
        return _identity(before)
    finally:
        os.close(fd)


def terminal_commit(manifest, terminal_raw: bytes, durable_path: str, durable_raw: bytes,
                    *, marker_parent="/home/wilf/.local/state/viewflow", locked_hook=None):
    parent = os.open(marker_parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    lock = None
    try:
        parent_before = os.fstat(parent)
        parent_named = os.stat(marker_parent, follow_symlinks=False)
        parent_identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid,
                                        item.st_gid, item.st_nlink, item.st_ctime_ns)
        if not (parent_identity(parent_before) == parent_identity(parent_named)
                and parent_before.st_uid == os.geteuid()
                and stat.S_IMODE(parent_before.st_mode) == 0o700
                and not any(item in ("system.posix_acl_access", "system.posix_acl_default")
                            for item in os.listxattr(parent))):
            raise GateError("marker parent identity/ACL differs at terminal commit")
        lock = os.open(".deployment-quarantine.v1.lock",
                       os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent)
        lock_before = os.fstat(lock)
        lock_named = os.stat(".deployment-quarantine.v1.lock", dir_fd=parent,
                             follow_symlinks=False)
        if not (stat.S_ISREG(lock_before.st_mode) and lock_before.st_uid == os.geteuid()
                and stat.S_IMODE(lock_before.st_mode) == 0o600 and lock_before.st_nlink == 1
                and lock_before.st_size == 0
                and (lock_before.st_dev, lock_before.st_ino) == (lock_named.st_dev, lock_named.st_ino)
                and not any(item in ("system.posix_acl_access", "system.posix_acl_default")
                            for item in os.listxattr(lock))):
            raise GateError("marker transaction lock identity/ACL differs")
        fcntl.flock(lock, fcntl.LOCK_EX)
        durable_name = Path(durable_path).name
        if str(Path(durable_path).parent) != marker_parent:
            raise GateError("durable VFDQA parent differs")
        durable_identity = None

        def validate_locked_state():
            nonlocal durable_identity
            for leaf in ("deployment-quarantine.v1", "deployment-quarantine.v1.abort-claim",
                         "deployment-quarantine.v1.release-claim", "deskflow-quarantine.v2"):
                try:
                    os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                raise GateError("marker or claim exists at terminal commit: " + leaf)
            observed_durable = read_named_owned(parent, durable_name, durable_raw,
                                                "locked durable VFDQA")
            if durable_identity is None:
                durable_identity = observed_durable
            elif observed_durable != durable_identity:
                raise GateError("locked durable VFDQA pathname identity changed")
            current_lock = os.fstat(lock)
            named_lock = os.stat(".deployment-quarantine.v1.lock", dir_fd=parent,
                                 follow_symlinks=False)
            if (parent_identity(os.fstat(parent))
                    != parent_identity(os.stat(marker_parent, follow_symlinks=False))
                    or (current_lock.st_dev, current_lock.st_ino)
                    != (named_lock.st_dev, named_lock.st_ino)
                    or current_lock != lock_before):
                raise GateError("marker parent/lock changed during terminal commit")

        validate_locked_state()
        if locked_hook is not None:
            locked_hook()
            validate_locked_state()
        create_once(manifest["outputs"]["terminal"], terminal_raw)
        validate_locked_state()
    finally:
        if lock is not None:
            os.close(lock)
        os.close(parent)


def current_marker_durable_names(marker_sha: str,
                                 marker_parent="/home/wilf/.local/state/viewflow"):
    prefix = ".deployment-quarantine.v1.abort-receipt." + marker_sha + "."
    parent = os.open(marker_parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        return sorted(name for name in os.listdir(parent)
                      if name.startswith(prefix) and name.endswith(".v1"))
    finally:
        os.close(parent)


def ensure_abort_receipt(manifest, *, marker_parent="/home/wilf/.local/state/viewflow"):
    """Resolve the abort receipt without ever replaying an uncertain durable mutation."""
    outputs = manifest["outputs"]
    if os.path.lexists(outputs["abort_receipt"]):
        receipt, receipt_raw = persisted(outputs["abort_receipt"], "local abort receipt")
        authorization, authorization_raw = persisted(outputs["authorization"], "abort authorization")
        auth_sha = digest(authorization_raw)
        if not isinstance(receipt.get("replayed"), bool):
            raise GateError("local abort receipt replay disposition differs")
        validate_abort_receipt(receipt_raw, manifest, auth_sha,
                               require_replay=receipt["replayed"])
        return receipt, receipt_raw, authorization, authorization_raw

    if os.path.lexists(outputs["authorization"]):
        authorization, authorization_raw = persisted(outputs["authorization"], "abort authorization")
        auth_sha = digest(authorization_raw)
        # An authorization with no local receipt is an uncertain mutation boundary.  Query
        # the native durable transaction; never redispatch the coordinator abort here.
        query_raw = run_marker_query(manifest, auth_sha)
        receipt = validate_abort_receipt(query_raw, manifest, auth_sha, require_replay=True)
        validate_vfdqa(receipt["abort_receipt_path"], manifest, auth_sha, receipt,
                       marker_parent=marker_parent)
        create_once(outputs["abort_receipt"], query_raw)
        return receipt, query_raw, authorization, authorization_raw

    candidates = current_marker_durable_names(manifest["active_marker"]["sha256"], marker_parent)
    if candidates:
        raise GateError("durable VFDQA exists without bound authorization; coordinator redispatch forbidden")
    run_coordinator(manifest)
    receipt, receipt_raw = persisted(outputs["abort_receipt"], "local abort receipt")
    authorization, authorization_raw = persisted(outputs["authorization"], "abort authorization")
    auth_sha = digest(authorization_raw)
    validate_abort_receipt(receipt_raw, manifest, auth_sha, require_replay=False)
    return receipt, receipt_raw, authorization, authorization_raw


def active_marker_must_exist(is_resume: bool, terminal_exists: bool,
                             recovery_artifact_exists: bool) -> bool:
    return not terminal_exists and not (is_resume and recovery_artifact_exists)


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
    recovery_artifact_exists = (os.path.lexists(raw_outputs.get("authorization", ""))
                                or os.path.lexists(raw_outputs.get("abort_receipt", "")))
    active_marker_required = active_marker_must_exist(args.resume, terminal_exists,
                                                      recovery_artifact_exists)
    validate_manifest(manifest, active_marker_required=active_marker_required)
    sealed_read(__file__, args.gate_sha256, 0o700, "gate")
    sealed_read(args.launcher_sealed_fd, args.launcher_sha256, 0o700, "launcher")
    if args.offline_check:
        if os.path.lexists(manifest["approval_path"]):
            raise GateError("fresh approval path already exists")
        if any(os.path.lexists(path) for path in manifest["outputs"].values()):
            raise GateError("fresh abort output already exists")
        print("845ce422 abort offline contract passed; no SSH or mutation")
        return
    if args.live_check_only or args.execute:
        pre_linux = linux_census(manifest, "pre")
        validate_linux_census(pre_linux, "pre")
        pre_windows = windows_census(manifest, "Ready", 0)
        validate_windows_census(pre_windows, manifest, "Ready", 0)
    else:
        if not (os.path.lexists(manifest["outputs"]["linux_pre"])
                and os.path.lexists(manifest["outputs"]["windows_pre"])):
            raise GateError("resume requires both persisted pre-boundary proofs")
        pre_linux, _ = persisted(manifest["outputs"]["linux_pre"], "saved Linux pre")
        pre_windows, _ = persisted(manifest["outputs"]["windows_pre"], "saved Windows pre")
        validate_linux_census(pre_linux, "pre")
        validate_windows_census(pre_windows, manifest, "Ready", 0)
    if args.live_check_only:
        print("845ce422 abort live boundary passed; no persisted output or mutation")
        return
    if not SHA.fullmatch(args.approval_sha256):
        raise GateError("execute/resume requires fresh approval SHA-256")
    approval_raw = stable_read(manifest["approval_path"], args.approval_sha256, 0o600,
                               "execution approval")
    validate_approval(manifest, approval_raw, args.manifest_sha256,
                      args.gate_sha256, args.launcher_sha256)
    outputs = manifest["outputs"]
    if args.execute and not os.path.lexists(outputs["linux_pre"]):
        create_once(outputs["linux_pre"], canonical(pre_linux))
        create_once(outputs["windows_pre"], canonical(pre_windows))
    elif args.execute:
        saved_linux, _ = persisted(outputs["linux_pre"], "saved Linux pre")
        saved_windows, _ = persisted(outputs["windows_pre"], "saved Windows pre")
        if saved_linux != pre_linux or saved_windows != pre_windows:
            raise GateError("resume pre-boundary differs")
    # Once the durable abort receipt exists, never redispatch the coordinator abort.
    receipt, receipt_raw, authorization, authorization_raw = ensure_abort_receipt(manifest)
    auth_sha = digest(authorization_raw)
    validate_abort_receipt(receipt_raw, manifest, auth_sha,
                           require_replay=receipt["replayed"])
    durable_path = receipt.get("abort_receipt_path")
    if not isinstance(durable_path, str):
        raise GateError("durable VFDQA path absent")
    durable_raw = validate_vfdqa(durable_path, manifest, auth_sha, receipt)
    query_raw = run_marker_query(manifest, auth_sha)
    query = validate_abort_receipt(query_raw, manifest, auth_sha, require_replay=True)
    if set(query) != set(receipt):
        raise GateError("native marker query schema differs")
    for key in set(receipt) - {"replayed"}:
        if query[key] != receipt[key]:
            raise GateError("native marker query differs from coordinator abort receipt")
    if not os.path.lexists(outputs["abort_query"]):
        create_once(outputs["abort_query"], query_raw)
    coordinator_outputs = validate_coordinator_outputs(manifest)
    post_linux = linux_census(manifest, "post")
    validate_linux_census(post_linux, "post")
    post_windows = windows_census(manifest, "Running", 1)
    validate_windows_census(post_windows, manifest, "Running", 1)
    if pre_windows["operation_root_members"] != post_windows["operation_root_members"]:
        raise GateError("Windows operation root changed across abort")
    if post_windows["deployment_task_state"] != "Disabled":
        raise GateError("Windows deployment task changed across abort")
    if not os.path.lexists(outputs["linux_post"]):
        create_once(outputs["linux_post"], canonical(post_linux))
        create_once(outputs["windows_post"], canonical(post_windows))
    terminal = {"schema_version": 1,
                "state": "viewflow-failed-v21-rollback-vfdqa-abort-terminal",
                "operation_id": OP, "protocol_2_1": False,
                "manifest_sha256": args.manifest_sha256, "gate_sha256": args.gate_sha256,
                "launcher_sha256": args.launcher_sha256,
                "execution_approval_sha256": args.approval_sha256,
                "coordinator_sha256": manifest["coordinator"]["sha256"],
                "coordinator_state_sha256": manifest["immutable_inputs"]["coordinator_state"]["sha256"],
                "fresh_lineage_sha256": manifest["immutable_inputs"]["fresh_lineage"]["sha256"],
                "authorization_sha256": auth_sha, "abort_receipt_sha256": digest(receipt_raw),
                "abort_query_sha256": digest(query_raw),
                "linux_v13_started_sha256": coordinator_outputs["linux_started"],
                "windows_v13_started_sha256": coordinator_outputs["windows_started"],
                "authenticated_v13_peer_sha256": coordinator_outputs["authenticated"],
                "coordinator_transition_sha256": coordinator_outputs["transition"],
                "vfdqa_binary_sha256": digest(durable_raw),
                "linux_pre_sha256": digest(canonical(pre_linux)),
                "windows_pre_sha256": digest(canonical(pre_windows)),
                "linux_post_sha256": digest(canonical(post_linux)),
                "windows_post_sha256": digest(canonical(post_windows)),
                "old_windows_peer_started": True, "old_windows_peer_process_count": 1,
                "windows_operation_root_unchanged": True,
                "windows_deployment_task_state": "Disabled", "marker_absent": True,
                "abort_claim_absent": True, "release_claim_absent": True,
                "runtime_marker_absent": True}
    terminal_raw = canonical(terminal)
    if terminal_exists:
        existing_terminal = stable_read(outputs["terminal"], digest(Path(outputs["terminal"]).read_bytes()),
                                        0o600, "existing abort terminal")
        if existing_terminal != terminal_raw:
            raise GateError("existing terminal differs from current reattested boundary")
        print("845ce422 schema1 VFDQA abort terminal reattested; no redispatch")
    else:
        terminal_commit(manifest, terminal_raw, durable_path, durable_raw)
        print("845ce422 schema1 VFDQA abort terminal committed")


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("845ce422 abort gate: " + str(error), file=sys.stderr)
        raise SystemExit(1)
