#!/usr/bin/env python3
"""Post-commit recovery gate for the op442 schema-5 VFDQA abort.

The predecessor coordinator has already committed the abort and must never be
dispatched again.  This gate only replays the marker query, persists a v3 query
envelope, and commits a v3 terminal which attributes the mutation to the exact
successor-v2 approval and sealed set.
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
import xml.etree.ElementTree as ET
from pathlib import Path

OP = "442fe737e67f43b89d85a7e33149a072"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
MANIFEST = "/home/wilf/data/viewflow/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-manifest.json"
MARKER_PARENT = "/home/wilf/.local/state/viewflow"
SHA = re.compile(r"[0-9a-f]{64}\Z")
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


def read_spec(spec, label, document=False):
    exact_keys(spec, {"path", "sha256", "mode", "size"}, label + " spec")
    if not (isinstance(spec["mode"], int) and isinstance(spec["size"], int)):
        raise GateError(label + " spec types differ")
    raw = stable_read(spec["path"], spec["sha256"], int(str(spec["mode"]), 8),
                      spec["size"], label)
    return strict_json(raw, label) if document else raw


def create_once(path: str, raw: bytes):
    target = Path(path)
    parent = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    temporary = "." + target.name + ".tmp." + str(os.getpid()) + "." + os.urandom(8).hex()
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


def load_predecessor(manifest):
    predecessor = manifest["predecessor_v2"]
    gate_raw = read_spec(predecessor["gate"], "predecessor v2 gate")
    namespace = {"__name__": "op442_predecessor_v2", "__file__": predecessor["gate"]["path"]}
    exec(compile(gate_raw, predecessor["gate"]["path"], "exec"), namespace)
    return namespace


def validate_manifest(manifest, allow_approval=False, allow_recovery_outputs=False):
    exact_keys(manifest, {"schema_version", "state", "execution_authorized", "operation_id",
        "predecessor_v2", "committed_v1_outputs", "post_abort", "windows_live",
        "approval_path", "outputs", "required_absent"}, "recovery-v3 manifest")
    if not (manifest["schema_version"] == 3
            and manifest["state"] == "viewflow-op442-schema5-abort-post-commit-recovery-v3-command-manifest"
            and manifest["execution_authorized"] is False and manifest["operation_id"] == OP):
        raise GateError("recovery-v3 manifest identity differs")
    exact_keys(manifest["predecessor_v2"], {"manifest", "gate", "launcher", "approval"},
               "predecessor v2")
    v2_raw = read_spec(manifest["predecessor_v2"]["manifest"], "predecessor v2 manifest")
    v2_manifest = strict_json(v2_raw, "predecessor v2 manifest")
    read_spec(manifest["predecessor_v2"]["launcher"], "predecessor v2 launcher")
    approval_raw = read_spec(manifest["predecessor_v2"]["approval"], "predecessor v2 approval")
    predecessor = load_predecessor(manifest)
    predecessor["validate_manifest"](v2_manifest, False, True)
    predecessor["validate_approval"](v2_manifest, approval_raw,
        manifest["predecessor_v2"]["manifest"]["sha256"],
        manifest["predecessor_v2"]["gate"]["sha256"],
        manifest["predecessor_v2"]["launcher"]["sha256"])
    exact_keys(manifest["committed_v1_outputs"], {"authorization", "abort_receipt",
        "transition", "linux_v13_started", "windows_v13_started",
        "authenticated_v13_peer"}, "committed v1 outputs")
    documents = {}
    for name, spec in manifest["committed_v1_outputs"].items():
        if spec["path"] != v2_manifest["outputs"][name]:
            raise GateError("committed v1 output path differs: " + name)
        documents[name] = read_spec(spec, "committed v1 " + name, True)
    authorization_raw = read_spec(manifest["committed_v1_outputs"]["authorization"],
                                  "committed v1 authorization")
    receipt_raw = read_spec(manifest["committed_v1_outputs"]["abort_receipt"],
                            "committed v1 abort receipt")
    authorization_sha = digest(authorization_raw)
    receipt = predecessor["validate_receipt"](receipt_raw, v2_manifest, authorization_sha, False)
    predecessor["validate_authorization"](authorization_raw, v2_manifest)
    linux_started = documents["linux_v13_started"]
    windows_started = documents["windows_v13_started"]
    authenticated = documents["authenticated_v13_peer"]
    transition = documents["transition"]
    if not (linux_started.get("schema_version") == 1
            and linux_started.get("state")
                == "viewflow-linux-v1.3-started-under-deployment-quarantine"
            and linux_started.get("operation_id") == OP
            and windows_started.get("schema_version") == 1
            and windows_started.get("state")
                == "viewflow-windows-v1.3-started-under-deployment-quarantine"
            and windows_started.get("operation_id") == OP
            and authenticated.get("schema_version") == 1
            and authenticated.get("state")
                == "viewflow-v1.3-peer-authenticated-under-deployment-quarantine"
            and authenticated.get("operation_id") == OP
            and authenticated.get("linux_v13_started_receipt_sha256")
                == manifest["committed_v1_outputs"]["linux_v13_started"]["sha256"]
            and authenticated.get("windows_v13_started_receipt_sha256")
                == manifest["committed_v1_outputs"]["windows_v13_started"]["sha256"]
            and receipt.get("linux_v13_started_receipt_sha256")
                == manifest["committed_v1_outputs"]["linux_v13_started"]["sha256"]
            and receipt.get("windows_v13_started_receipt_sha256")
                == manifest["committed_v1_outputs"]["windows_v13_started"]["sha256"]
            and receipt.get("authenticated_v13_peer_receipt_sha256")
                == manifest["committed_v1_outputs"]["authenticated_v13_peer"]["sha256"]
            and transition.get("schema_version") == 1
            and transition.get("state") == "viewflow-failed-v1.3-bootstrap-abort-terminal"
            and transition.get("operation_id") == OP
            and transition.get("deployment_abort_receipt_sha256")
                == manifest["committed_v1_outputs"]["abort_receipt"]["sha256"]
            and transition.get("abort_authorization_sha256") == authorization_sha
            and transition.get("normal_deployment_release") is False
            and transition.get("protocol_2_1") is False):
        raise GateError("committed v1 output lineage differs")
    vfdqa_sha, retired = predecessor["validate_post_state"](
        v2_manifest, receipt, authorization_sha)
    post = manifest["post_abort"]
    exact_keys(post, {"marker_path", "public_absent", "durable_vfdqa", "retired_claim"},
               "post-abort evidence")
    durable_raw = read_spec(post["durable_vfdqa"], "durable VFDQA")
    retired_raw = read_spec(post["retired_claim"], "retired claim")
    expected_public = [post["marker_path"], post["marker_path"] + ".abort-claim",
                       post["marker_path"] + ".release-claim"]
    if not (post["marker_path"] == v2_manifest["active_marker"]["path"]
            and post["public_absent"] == expected_public
            and digest(durable_raw) == vfdqa_sha
            and post["retired_claim"]["path"] == retired
            and digest(retired_raw) == v2_manifest["active_marker"]["sha256"]
            and all(not os.path.lexists(path) for path in expected_public)):
        raise GateError("post-abort durable state differs")
    exact_keys(manifest["outputs"], {"query", "terminal"}, "recovery-v3 outputs")
    expected_outputs = {
        "query": str(ROOT / "schema5-abort-442fe737-recovery-v3-query.json"),
        "terminal": str(ROOT / "schema5-abort-442fe737-recovery-v3-terminal.json")}
    expected_approval = str(ROOT / "schema5-abort-442fe737-recovery-v3-execution-approval.json")
    expected_absent = [v2_manifest["outputs"]["abort_query"], v2_manifest["outputs"]["terminal"],
                       expected_approval, expected_outputs["query"], expected_outputs["terminal"]]
    if not (manifest["outputs"] == expected_outputs and manifest["approval_path"] == expected_approval
            and manifest["required_absent"] == expected_absent
            and len(expected_absent) == len(set(expected_absent))):
        raise GateError("recovery-v3 output confinement differs")
    for path in expected_absent:
        if allow_approval and path == expected_approval:
            continue
        if allow_recovery_outputs and path in expected_outputs.values():
            continue
        if os.path.lexists(path):
            raise GateError("recovery-v3 required-absent path exists: " + path)
    windows = manifest["windows_live"]
    exact_keys(windows, {"ssh_target", "old_binary_path", "old_wrapper_path",
        "deployment_task_name", "deployment_task_state", "deployment_task_xml_sha256"},
        "Windows live specification")
    if not (windows["ssh_target"] == "wilf@172.16.105.70"
            and windows["deployment_task_name"] == "Viewflow Deployment " + OP
            and windows["deployment_task_state"] == "Disabled"
            and SHA.fullmatch(windows["deployment_task_xml_sha256"])):
        raise GateError("Windows live specification differs")
    return predecessor, v2_manifest, documents, receipt_raw, receipt


def systemd_state(unit: str):
    result = subprocess.run(["/usr/bin/systemctl", "--user", "show", unit,
        "--property=LoadState", "--property=ActiveState", "--property=SubState",
        "--property=MainPID", "--property=InvocationID", "--property=ControlGroup"],
        env=ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=15, check=True)
    values = dict(line.split("=", 1) for line in result.stdout.decode().splitlines())
    if set(values) != {"LoadState", "ActiveState", "SubState", "MainPID",
                       "InvocationID", "ControlGroup"}:
        raise GateError("systemd census keys differ")
    return values


def proc_start_ticks(pid: int) -> int:
    raw = Path(f"/proc/{pid}/stat").read_text()
    end = raw.rfind(")")
    if end < 0:
        raise GateError("process stat differs")
    fields = raw[end + 2:].split()
    if len(fields) < 20:
        raise GateError("process stat is short")
    return int(fields[19])


def proc_exe_sha(pid: int) -> str:
    fd = os.open(f"/proc/{pid}/exe", os.O_RDONLY | os.O_CLOEXEC)
    try:
        sha = hashlib.sha256()
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            sha.update(chunk)
        return sha.hexdigest()
    finally:
        os.close(fd)


def proc_cgroup(pid: int) -> str:
    rows = Path(f"/proc/{pid}/cgroup").read_text().splitlines()
    if len(rows) != 1 or not rows[0].startswith("0::"):
        raise GateError("process cgroup differs")
    return rows[0][3:]


def socket_owner_pids(port: int, tcp: bool):
    command = ["/usr/bin/ss", "-H", "-ltnp" if tcp else "-lunp", "sport", "=", f":{port}"]
    result = subprocess.run(command, env=ENV, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=15, check=True)
    return sorted({int(value) for value in re.findall(rb"pid=([0-9]+)", result.stdout)})


def linux_live_census(documents):
    linux = documents["linux_v13_started"]
    transition = documents["transition"]
    viewflow = systemd_state(linux["unit"])
    deskflow = systemd_state(transition["linux_deskflow_unit"])
    installed_viewflow = systemd_state("viewflow-peer.service")
    installed_deskflow = systemd_state("deskflow.service")
    pids = {"viewflow": int(linux["main_pid"]),
            "deskflow_main": int(transition["linux_deskflow_main_pid"]),
            "deskflow_runtime": int(transition["linux_deskflow_runtime_pid"]),
            "deskflow_core": int(transition["linux_deskflow_core_pid"])}
    return {"schema_version": 1, "state": "viewflow-op442-recovery-v3-linux-live",
        "operation_id": OP, "viewflow_unit": viewflow, "deskflow_unit": deskflow,
        "installed_viewflow_unit": installed_viewflow,
        "installed_deskflow_unit": installed_deskflow,
        "process_start_ticks": {name: proc_start_ticks(pid) for name, pid in pids.items()},
        "process_executable_sha256": {name: proc_exe_sha(pid) for name, pid in pids.items()},
        "process_cgroup": {name: proc_cgroup(pid) for name, pid in pids.items()},
        "udp_44119_owner_pids": socket_owner_pids(44119, False),
        "tcp_24800_owner_pids": socket_owner_pids(24800, True)}


def validate_linux_live(value, documents):
    linux = documents["linux_v13_started"]
    transition = documents["transition"]
    expected_ticks = {"viewflow": int(linux["start_ticks"]),
        "deskflow_main": int(transition["linux_deskflow_main_start_ticks"]),
        "deskflow_runtime": int(transition["linux_deskflow_runtime_start_ticks"]),
        "deskflow_core": int(transition["linux_deskflow_core_start_ticks"])}
    expected_sha = {"viewflow": linux["viewflowd_sha256"],
        "deskflow_main": transition["bubblewrap_sha256"],
        "deskflow_runtime": transition["linux_deskflow_executable_sha256"],
        "deskflow_core": transition["linux_deskflow_core_executable_sha256"]}
    expected_cgroup = {"viewflow": linux["control_group"],
        "deskflow_main": transition["linux_deskflow_control_group"],
        "deskflow_runtime": transition["linux_deskflow_control_group"],
        "deskflow_core": transition["linux_deskflow_control_group"]}
    for name in ("viewflow_unit", "deskflow_unit"):
        unit = value[name]
        if not (unit["LoadState"] == "loaded" and unit["ActiveState"] == "active"
                and unit["SubState"] == "running"):
            raise GateError("transient Linux recovery unit differs")
    if not (value["viewflow_unit"]["MainPID"] == str(linux["main_pid"])
            and value["viewflow_unit"]["InvocationID"] == linux["invocation_id"]
            and value["viewflow_unit"]["ControlGroup"] == linux["control_group"]
            and value["deskflow_unit"]["MainPID"] == str(transition["linux_deskflow_main_pid"])
            and value["deskflow_unit"]["InvocationID"] == transition["linux_deskflow_invocation_id"]
            and value["deskflow_unit"]["ControlGroup"] == transition["linux_deskflow_control_group"]
            and all(value[name]["ActiveState"] == "inactive" and value[name]["MainPID"] == "0"
                    for name in ("installed_viewflow_unit", "installed_deskflow_unit"))
            and value["process_start_ticks"] == expected_ticks
            and value["process_executable_sha256"] == expected_sha
            and value["process_cgroup"] == expected_cgroup
            and value["udp_44119_owner_pids"] == [int(linux["main_pid"])]
            and value["tcp_24800_owner_pids"] == [int(transition["linux_deskflow_core_pid"])]):
        raise GateError("Linux post-abort live identity differs")


def powershell_census(manifest, documents):
    windows = manifest["windows_live"]
    receipt = documents["windows_v13_started"]
    template = r'''$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function HB([byte[]]$b){$s=[Security.Cryptography.SHA256]::Create();try{(([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','')).ToLowerInvariant()}finally{$s.Dispose()}}
$enc=New-Object Text.UnicodeEncoding($false,$true);function TH($name){$xml=Export-ScheduledTask -TaskPath '\' -TaskName $name;$pre=$enc.GetPreamble();$body=$enc.GetBytes($xml);$all=New-Object byte[] ($pre.Length+$body.Length);[Array]::Copy($pre,0,$all,0,$pre.Length);[Array]::Copy($body,0,$all,$pre.Length,$body.Length);HB $all}
$old=Get-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer' -ErrorAction Stop;$deployment=Get-ScheduledTask -TaskPath '\' -TaskName '__DEPLOYMENT_TASK__' -ErrorAction Stop;$exe='__EXE__';$wrapper='__WRAPPER__'
$all=@(Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'");$rows=@($all|Where-Object{$_.ExecutablePath-and[IO.Path]::GetFullPath($_.ExecutablePath)-ceq$exe});if($rows.Count-ne1){throw 'exact viewflow process count differs'};$p=$rows[0];$sid=(Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid;$allProcesses=@(Get-CimInstance Win32_Process);$workers=@($allProcesses|Where-Object{$_.CommandLine-and$_.CommandLine-like'*__OP__*'-and($_.CommandLine-like'*install-viewflow.ps1*'-or$_.CommandLine-like'*start-viewflow-bootstrap.ps1*')});$readerToken='Read'+'ToEnd';$stdinReaders=@($allProcesses|Where-Object{$_.CommandLine-and$_.CommandLine-like('*'+$readerToken+'*')})
[ordered]@{schema_version=1;state='viewflow-op442-recovery-v3-windows-live';operation_id='__OP__';task_state=[string]$old.State;task_xml_sha256=(TH 'Viewflow Peer');deployment_task_state=[string]$deployment.State;deployment_task_xml_sha256=(TH '__DEPLOYMENT_TASK__');viewflowd_sha256=(HB ([IO.File]::ReadAllBytes($exe)));wrapper_sha256=(HB ([IO.File]::ReadAllBytes($wrapper)));pid=[int]$p.ProcessId;process_start_filetime_utc=[string]($p.CreationDate.ToFileTimeUtc());session_id=[int]$p.SessionId;user_sid=[string]$sid;global_viewflow_process_count=[int]$all.Count;deployment_worker_count=[int]$workers.Count;stdin_reader_count=[int]$stdinReaders.Count}|ConvertTo-Json -Compress
'''
    replacements = {"__DEPLOYMENT_TASK__": windows["deployment_task_name"],
        "__EXE__": windows["old_binary_path"], "__WRAPPER__": windows["old_wrapper_path"],
        "__OP__": OP}
    for key, replacement in replacements.items():
        template = template.replace(key, replacement)
    if not template.isascii() or receipt["task_name"] != "\\Viewflow Peer":
        raise GateError("Windows recovery census template differs")
    return template


def validate_progress_stderr(raw: bytes):
    if not raw:
        return
    try:
        text = raw.decode("gbk", "strict").replace("\r\n", "\n")
        if not text.startswith("#< CLIXML\n"):
            raise GateError("Windows recovery stderr is not CLIXML")
        root = ET.fromstring(text[len("#< CLIXML\n"):])
    except (UnicodeDecodeError, ET.ParseError) as error:
        raise GateError("Windows recovery stderr is not progress CLIXML") from error
    namespace = "{http://schemas.microsoft.com/powershell/2004/04}"
    children = list(root)
    if (root.tag != namespace + "Objs" or not children
            or any(child.tag != namespace + "Obj" or child.attrib.get("S") != "progress"
                   for child in children)
            or any(element.attrib.get("S") == "Error" for element in root.iter())):
        raise GateError("Windows recovery stderr contains non-progress record")


def windows_live_census(manifest, documents):
    script = powershell_census(manifest, documents)
    payload = base64.b64encode(gzip.compress(script.encode("ascii"), compresslevel=9,
                                             mtime=0)).decode("ascii")
    bootstrap = ("$i=[IO.MemoryStream]::new([Convert]::FromBase64String('" + payload + "'));"
        "$o=[IO.MemoryStream]::new();$g=[IO.Compression.GzipStream]::new($i,[IO.Compression.CompressionMode]::Decompress);"
        "$g.CopyTo($o);&([ScriptBlock]::Create([Text.Encoding]::ASCII.GetString($o.ToArray())))")
    encoded = base64.b64encode(bootstrap.encode("utf-16le")).decode("ascii")
    command = ["/usr/bin/ssh", "-oLogLevel=ERROR", "-oBatchMode=yes", "-oConnectTimeout=10",
        "-oStrictHostKeyChecking=yes", manifest["windows_live"]["ssh_target"],
        "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]
    if len(encoded) > 6_800 or sum(len(item) + 1 for item in command) > 7_000:
        raise GateError("Windows recovery EncodedCommand exceeds safety bound")
    result = subprocess.run(command, env=ENV, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if result.returncode != 0:
        raise GateError("Windows recovery readonly census failed")
    validate_progress_stderr(result.stderr)
    return strict_json(result.stdout.replace(b"\r\n", b"\n"), "Windows recovery census")


def validate_windows_live(value, manifest, documents):
    exact_keys(value, {"schema_version", "state", "operation_id", "task_state",
        "task_xml_sha256", "deployment_task_state", "deployment_task_xml_sha256",
        "viewflowd_sha256", "wrapper_sha256", "pid", "process_start_filetime_utc",
        "session_id", "user_sid", "global_viewflow_process_count",
        "deployment_worker_count", "stdin_reader_count"}, "Windows recovery census")
    receipt = documents["windows_v13_started"]
    windows = manifest["windows_live"]
    if not (value["schema_version"] == 1
            and value["state"] == "viewflow-op442-recovery-v3-windows-live"
            and value["operation_id"] == OP and value["task_state"] == "Running"
            and value["task_xml_sha256"] == receipt["task_xml_sha256"]
            and value["deployment_task_state"] == windows["deployment_task_state"]
            and value["deployment_task_xml_sha256"] == windows["deployment_task_xml_sha256"]
            and value["viewflowd_sha256"] == receipt["viewflowd_sha256"]
            and value["wrapper_sha256"] == receipt["wrapper_sha256"]
            and value["pid"] == receipt["pid"]
            and value["process_start_filetime_utc"] == receipt["process_start_filetime_utc"]
            and value["session_id"] == receipt["session_id"]
            and value["user_sid"] == receipt["user_sid"]
            and value["global_viewflow_process_count"] == 1
            and value["deployment_worker_count"] == 0 and value["stdin_reader_count"] == 0):
        raise GateError("Windows post-abort live identity differs")


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def validate_recovery_approval(manifest, raw, manifest_sha, gate_sha, launcher_sha):
    value = strict_json(raw, "recovery-v3 approval")
    expected = {"schema_version": 3,
        "state": "viewflow-op442-schema5-abort-recovery-v3-execution-approved",
        "approved": True, "operation_id": OP, "manifest_sha256": manifest_sha,
        "gate_sha256": gate_sha, "launcher_sha256": launcher_sha,
        "predecessor_v2_approval_sha256": manifest["predecessor_v2"]["approval"]["sha256"],
        "publication_method": "create-once-no-replace-and-parent-fsync",
        "approved_at_utc": value.get("approved_at_utc")}
    if value != expected or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",
            str(value.get("approved_at_utc"))):
        raise GateError("recovery-v3 approval differs")


def query_envelope(manifest, marker_query_raw):
    return {"schema_version": 3,
        "state": "viewflow-op442-schema5-abort-recovery-v3-marker-query-replayed",
        "operation_id": OP, "coordinator_redispatched": False,
        "predecessor_v2_manifest_sha256": manifest["predecessor_v2"]["manifest"]["sha256"],
        "predecessor_v2_gate_sha256": manifest["predecessor_v2"]["gate"]["sha256"],
        "predecessor_v2_launcher_sha256": manifest["predecessor_v2"]["launcher"]["sha256"],
        "predecessor_v2_approval_sha256": manifest["predecessor_v2"]["approval"]["sha256"],
        "authorization_sha256": manifest["committed_v1_outputs"]["authorization"]["sha256"],
        "committed_abort_receipt_sha256": manifest["committed_v1_outputs"]["abort_receipt"]["sha256"],
        "marker_query_sha256": digest(marker_query_raw),
        "marker_query": strict_json(marker_query_raw, "schema5 replay query")}


def validate_query_envelope(manifest, predecessor, v2_manifest, envelope_raw):
    envelope = strict_json(envelope_raw, "recovery-v3 query envelope")
    if envelope_raw != canonical(envelope):
        raise GateError("recovery-v3 query envelope is not canonical")
    marker_query_raw = canonical(envelope.get("marker_query"))
    authorization_sha = manifest["committed_v1_outputs"]["authorization"]["sha256"]
    try:
        predecessor["validate_receipt"](
            marker_query_raw, v2_manifest, authorization_sha, True)
    except predecessor["GateError"] as error:
        raise GateError("recovery-v3 nested marker query is not a schema5 replay receipt") from error
    if envelope != query_envelope(manifest, marker_query_raw):
        raise GateError("recovery-v3 query envelope differs")
    return envelope, marker_query_raw


def recovery_stage(query_exists: bool, terminal_exists: bool) -> str:
    if terminal_exists and not query_exists:
        raise GateError("recovery-v3 terminal exists without its exact query")
    if terminal_exists:
        return "terminal-replay"
    if query_exists:
        return "partial-query"
    return "fresh-query"


def terminal_document(manifest, manifest_sha, gate_sha, launcher_sha, approval_sha,
                      receipt_raw, receipt, envelope_raw, linux_sha, windows_sha):
    return {"schema_version": 3,
        "state": "viewflow-op442-schema5-abort-post-commit-recovery-v3-terminal",
        "operation_id": OP, "coordinator_redispatched": False,
        "marker_query_replayed": True, "marker_absent": True,
        "manifest_sha256": manifest_sha, "gate_sha256": gate_sha,
        "launcher_sha256": launcher_sha, "approval_sha256": approval_sha,
        "predecessor_v2_manifest_sha256": manifest["predecessor_v2"]["manifest"]["sha256"],
        "predecessor_v2_gate_sha256": manifest["predecessor_v2"]["gate"]["sha256"],
        "predecessor_v2_launcher_sha256": manifest["predecessor_v2"]["launcher"]["sha256"],
        "predecessor_v2_approval_sha256": manifest["predecessor_v2"]["approval"]["sha256"],
        "committed_v1_output_sha256": {name: spec["sha256"]
            for name, spec in manifest["committed_v1_outputs"].items()},
        "durable_vfdqa_sha256": manifest["post_abort"]["durable_vfdqa"]["sha256"],
        "retired_claim_sha256": manifest["post_abort"]["retired_claim"]["sha256"],
        "recovery_query_sha256": digest(envelope_raw),
        "committed_abort_receipt_sha256": digest(receipt_raw),
        "linux_live_census_sha256": linux_sha, "windows_live_census_sha256": windows_sha,
        "abort_committed_at_unix_ms": receipt["abort_committed_at_unix_ms"]}


def validate_terminal(manifest, raw, manifest_sha, gate_sha, launcher_sha, approval_sha,
                      receipt_raw, receipt, envelope_raw, expected_live=None):
    value = strict_json(raw, "recovery-v3 terminal")
    if raw != canonical(value):
        raise GateError("recovery-v3 terminal is not canonical")
    linux_sha = value.get("linux_live_census_sha256")
    windows_sha = value.get("windows_live_census_sha256")
    if not (isinstance(linux_sha, str) and SHA.fullmatch(linux_sha)
            and isinstance(windows_sha, str) and SHA.fullmatch(windows_sha)):
        raise GateError("recovery-v3 terminal live census hashes differ")
    expected = terminal_document(manifest, manifest_sha, gate_sha, launcher_sha,
        approval_sha, receipt_raw, receipt, envelope_raw, linux_sha, windows_sha)
    if value != expected or (expected_live is not None
            and (linux_sha, windows_sha) != expected_live):
        raise GateError("recovery-v3 terminal binding differs")
    return value


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
    manifest = strict_json(sealed_read(args.manifest, args.manifest_sha256, 0o600,
                                       "recovery-v3 manifest"), "recovery-v3 manifest")
    predecessor, v2_manifest, documents, receipt_raw, receipt = validate_manifest(
        manifest, args.execute or args.resume, args.resume)
    sealed_read(__file__, args.gate_sha256, 0o700, "recovery-v3 gate")
    sealed_read(args.launcher_sealed_fd, args.launcher_sha256, 0o700, "recovery-v3 launcher")
    if args.offline_check:
        print("442fe737 schema5 abort recovery-v3 offline contract passed; no SSH or mutation")
        return
    if args.live_check_only:
        linux = linux_live_census(documents)
        validate_linux_live(linux, documents)
        windows = windows_live_census(manifest, documents)
        validate_windows_live(windows, manifest, documents)
        print("442fe737 schema5 abort recovery-v3 cross-host readonly boundary passed; no mutation")
        return
    if not SHA.fullmatch(args.approval_sha256):
        raise GateError("recovery-v3 execute/resume requires approval SHA-256")
    approval_raw = stable_read(manifest["approval_path"], args.approval_sha256, 0o600,
                               os.stat(manifest["approval_path"]).st_size,
                               "recovery-v3 execution approval")
    validate_recovery_approval(manifest, approval_raw, args.manifest_sha256,
                               args.gate_sha256, args.launcher_sha256)
    query_path = manifest["outputs"]["query"]
    query_exists = os.path.lexists(query_path)
    terminal_path = manifest["outputs"]["terminal"]
    terminal_exists = os.path.lexists(terminal_path)
    stage = recovery_stage(query_exists, terminal_exists)
    if stage == "terminal-replay":
        envelope_raw = stable_generated_read(query_path, "persisted recovery-v3 query")
        validate_query_envelope(manifest, predecessor, v2_manifest, envelope_raw)
        terminal_raw = stable_generated_read(terminal_path, "persisted recovery-v3 terminal")
        validate_terminal(manifest, terminal_raw, args.manifest_sha256, args.gate_sha256,
            args.launcher_sha256, args.approval_sha256, receipt_raw, receipt, envelope_raw)
        print("442fe737 schema5 abort recovery-v3 terminal reattested after handoff; no live census or dispatch")
        return
    linux = linux_live_census(documents)
    validate_linux_live(linux, documents)
    windows = windows_live_census(manifest, documents)
    validate_windows_live(windows, manifest, documents)
    if stage == "partial-query":
        envelope_raw = stable_generated_read(query_path, "persisted recovery-v3 query")
    else:
        authorization_sha = manifest["committed_v1_outputs"]["authorization"]["sha256"]
        marker_query_raw = predecessor["run_query"](v2_manifest, authorization_sha)
        envelope = query_envelope(manifest, marker_query_raw)
        envelope_raw = canonical(envelope)
    envelope, marker_query_raw = validate_query_envelope(
        manifest, predecessor, v2_manifest, envelope_raw)
    if not query_exists:
        create_once(query_path, envelope_raw)
    linux_sha = digest(canonical(linux))
    windows_sha = digest(canonical(windows))
    terminal = terminal_document(manifest, args.manifest_sha256, args.gate_sha256,
        args.launcher_sha256, args.approval_sha256, receipt_raw, receipt, envelope_raw,
        linux_sha, windows_sha)
    terminal_raw = canonical(terminal)
    validate_terminal(manifest, terminal_raw, args.manifest_sha256, args.gate_sha256,
        args.launcher_sha256, args.approval_sha256, receipt_raw, receipt, envelope_raw,
        (linux_sha, windows_sha))
    create_once(terminal_path, terminal_raw)
    print("442fe737 schema5 abort recovery-v3 terminal committed; no coordinator dispatch")


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("442fe737 schema5 abort recovery-v3 gate: " + str(error), file=sys.stderr)
        raise SystemExit(1)
