#!/usr/bin/env python3
"""Operation-specific, fail-closed runtime attestation for the 2ca3 early gate.

The coordinator executes this file and the manifest from sealed memfds.  The
only mutating action is ``start-viewflow``; it creates one transient unit for
the already-installed protocol-1.3 daemon.  Deskflow is never started.
"""

from __future__ import annotations

import base64
import fcntl
import gzip
import hashlib
import json
import os
import re
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path


OPERATION_ID = "2ca3f46635b65615a1cffc1970d73911"
WINDOWS_HOST = "wilf@172.16.105.70"
WINDOWS_SOURCE_IP = "172.16.105.70"
WINDOWS_PID = 22912
WINDOWS_PARENT_PID = 25608
WINDOWS_FILETIME = "134326073277429320"
WINDOWS_SID = "S-1-5-21-1940417919-1835306932-1635351729-1001"
WINDOWS_EXE = r"C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe"
WINDOWS_WRAPPER = r"C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1"
WINDOWS_ROLLBACK = r"C:\Users\wilf\AppData\Local\Programs\Viewflow\rollback-viewflow.ps1"
WINDOWS_ROOT = "C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\" + OPERATION_ID
WINDOWS_COMMAND = (
    r'"C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe" connect '
    r"--peer 172.16.105.62:44119 --server-name viewflow-linux "
    r"--cert C:\Users\wilf\AppData\Local\Programs\Viewflow\identity\peer.pem "
    r"--key C:\Users\wilf\AppData\Local\Programs\Viewflow\identity\peer.key "
    r"--ca C:\Users\wilf\AppData\Local\Programs\Viewflow\identity\ca.pem "
    r"--input-backend native --device-id 00000000000000000000000000000002 "
    r"--probe-interval-ms 1000 --probe-timeout-ms 3000"
)
TASK_ACTION = {
    "execute": r"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe",
    "arguments": (
        r'-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File '
        r'"C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1"'
    ),
    "working_directory": r"C:\Users\wilf\AppData\Local\Programs\Viewflow",
}
TASK_PRINCIPAL = {"user_id": "wilf", "logon_type": "Interactive", "run_level": "Limited"}
ACTIONS = {
    "preflight", "start-viewflow", "windows-v13", "authenticated-peer",
    "pre-abort-reattest", "post-abort-reattest",
}
SEALS = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
SHA = re.compile(r"[0-9a-f]{64}")
INVOCATION = re.compile(r"[0-9a-f]{32}")
DESKFLOW_DISPLAY = re.compile(rb"(?i)(?<![a-z0-9_])deskflow(?:-core)?(?![a-z0-9_])")
POWERSHELL_ENCODED_COMMAND_MAX = 7500


class HelperError(RuntimeError):
    pass


class _UnreadableField:
    pass


UNREADABLE = _UnreadableField()


def user_bus_env():
    runtime_dir = f"/run/user/{os.getuid()}"
    return {
        "PATH": "/usr/bin:/bin",
        "XDG_RUNTIME_DIR": runtime_dir,
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime_dir}/bus",
    }


def pairs(items):
    value = {}
    for key, item in items:
        if key in value:
            raise HelperError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def strict_json(data: bytes, label: str):
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HelperError(f"{label} is not strict UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise HelperError(f"{label} must be one object")
    return value


def canonical_sha(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def file_sha(path: str) -> str:
    digest = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise HelperError(f"not a regular file: {path}")
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(fd)
        current = os.stat(path, follow_symlinks=False)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
        ) or (after.st_dev, after.st_ino, after.st_size) != (
            current.st_dev, current.st_ino, current.st_size
        ):
            raise HelperError(f"file identity changed: {path}")
    finally:
        os.close(fd)
    return digest.hexdigest()


def run(command, *, timeout=15, check=True, env=None) -> str:
    command_env = env if env is not None else {"PATH": "/usr/bin:/bin"}
    result = subprocess.run(
        command, env=command_env, check=check, timeout=timeout,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        # Keep arbitrary remote stderr bytes out of local text decoding and
        # diagnostics; the nonzero status is the fail-closed signal.
        raise subprocess.CalledProcessError(result.returncode, command, output=result.stdout, stderr=result.stderr)
    try:
        return result.stdout.decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise HelperError(f"command stdout is not strict UTF-8: {command[0]}") from error


def systemd_properties(unit: str, *, allow_not_found: bool = False):
    names = ("LoadState", "ActiveState", "SubState", "MainPID", "InvocationID", "ControlGroup", "Transient", "KillMode")
    result = subprocess.run(
        ["/usr/bin/systemctl", "--user", "show", unit, *(f"--property={name}" for name in names)],
        env=user_bus_env(), stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
    )
    try:
        stdout = result.stdout.decode("utf-8", "strict") if isinstance(result.stdout, bytes) else result.stdout
    except UnicodeDecodeError as error:
        raise HelperError(f"systemd property stdout is not strict UTF-8 for {unit}") from error
    if not isinstance(stdout, str):
        raise HelperError(f"systemd property stdout is invalid for {unit}")
    values = {}
    for line in stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    if set(values) != set(names):
        raise HelperError(f"unexpected systemd properties for {unit}")
    if values["LoadState"] == "not-found":
        if not allow_not_found or result.returncode not in (0, 4):
            raise HelperError(f"systemd not-found result code differs for {unit}")
    elif result.returncode != 0:
        raise HelperError(f"systemd property query failed for {unit}")
    return {name: values.get(name, "") for name in names}


def exact_executable_pids(path: str):
    expected = os.path.realpath(path)
    found = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            if os.path.realpath(f"/proc/{name}/exe") == expected:
                found.append(int(name))
        except OSError:
            continue
    return sorted(found)


def _proc_is_gone(pid: int) -> bool:
    try:
        os.stat(f"/proc/{pid}")
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return False


def _read_process_field(pid: int, reader, label: str, *, allow_unreadable: bool = False):
    try:
        return reader()
    except (OSError, UnicodeError) as error:
        if _proc_is_gone(pid):
            return None
        if allow_unreadable:
            return UNREADABLE
        raise HelperError(f"process {pid} {label} is unreadable") from error


def _read_process_exe(pid: int):
    try:
        return os.path.realpath(os.readlink(os.fsencode(f"/proc/{pid}/exe")))
    except FileNotFoundError:
        if _proc_is_gone(pid):
            return None
        # Kernel threads legitimately have no executable symlink.
        return b""
    except (OSError, UnicodeError) as error:
        if _proc_is_gone(pid):
            return None
        return UNREADABLE


def cmdline_bytes(pid: int):
    raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    if not raw:
        return []
    return raw.rstrip(b"\0").split(b"\0")


def linux_process_census():
    """Return an all-process view used to reject hidden Deskflow instances."""
    census = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        comm = _read_process_field(
            pid, lambda: Path(f"/proc/{pid}/comm").read_bytes().rstrip(b"\n"),
            "comm",
        )
        if comm is None:
            continue
        exe = _read_process_exe(pid)
        if exe is None:
            continue
        exe_unreadable = exe is UNREADABLE
        if exe_unreadable:
            exe = b""
        argv = _read_process_field(
            pid, lambda: cmdline_bytes(pid), "cmdline", allow_unreadable=True,
        )
        if argv is None:
            continue
        argv_unreadable = argv is UNREADABLE
        if argv_unreadable:
            argv = []
        census.append({
            "pid": pid,
            "comm": comm,
            "exe": exe,
            "basename": os.path.basename(exe),
            "cmdline": argv,
            "complete": not (exe_unreadable or argv_unreadable),
        })
    return census


def _process_displays_deskflow(process):
    fields = [process.get("comm", b""), process.get("exe", b""), process.get("basename", b"")]
    argv = process.get("cmdline", ())
    fields.extend(argv if isinstance(argv, (list, tuple)) else [argv])
    return any(
        DESKFLOW_DISPLAY.search(field if isinstance(field, bytes) else str(field).encode("utf-8"))
        for field in fields
    )


def _assert_no_unexpected_deskflow_processes(
    manifest, *, allowed_viewflow_pid=None, allowed_viewflow_argv=None,
):
    allowed_exe = os.fsencode(os.path.realpath(manifest["installed"]["viewflowd"]["path"]))
    unexpected = []
    for process in linux_process_census():
        if not _process_displays_deskflow(process):
            continue
        if not process.get("complete", True):
            raise HelperError(
                f"Deskflow candidate process {process.get('pid', 'unknown')} census is incomplete"
            )
        argv = process.get("cmdline", ())
        if not isinstance(argv, (list, tuple)):
            argv = [argv]
        actual_argv = [arg if isinstance(arg, bytes) else str(arg).encode("utf-8") for arg in argv]
        process_exe = process.get("exe", b"")
        if not isinstance(process_exe, bytes):
            process_exe = os.fsencode(os.path.realpath(str(process_exe)))
        expected_argv = [os.fsencode(str(arg)) for arg in (allowed_viewflow_argv or ())]
        if (
            allowed_viewflow_pid is not None
            and process.get("pid") == allowed_viewflow_pid
            and process_exe == allowed_exe
            and actual_argv == expected_argv
        ):
            continue
        unexpected.append(process.get("pid", "unknown"))
    if unexpected:
        raise HelperError(
            "unexpected Deskflow process census: " + ",".join(map(str, unexpected))
        )


def start_ticks(pid: int) -> int:
    raw = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    close = raw.rfind(")")
    if close < 0:
        raise HelperError("process stat comm terminator is absent")
    fields = raw[close + 2:].split()
    value = int(fields[19])
    if value <= 0:
        raise HelperError("process start ticks are invalid")
    return value


def cmdline(pid: int):
    raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    return [part.decode("utf-8", "strict") for part in raw.rstrip(b"\0").split(b"\0")]


def listener_count(kind: str, needle: str) -> int:
    command = ["/usr/bin/ss", "-H", "-l", kind]
    output = run(command)
    return sum(1 for line in output.splitlines() if needle in line)


def viewflow_argv(manifest):
    executable = manifest["installed"]["viewflowd"]["path"]
    runtime = f"/run/user/{os.getuid()}/viewflow/deskflow.sock"
    return [
        executable, "serve", "--bind", "0.0.0.0:44119",
        "--cert", "/home/wilf/.local/share/viewflow/identity/peer.pem",
        "--key", "/home/wilf/.local/share/viewflow/identity/peer.key",
        "--ca", "/home/wilf/.local/share/viewflow/identity/ca.pem",
        "--device-id", "00000000000000000000000000000001",
        "--sidecar-socket", runtime, "--sidecar-peer", "172.16.105.70",
        "--sidecar-target-device", "00000000000000000000000000000002",
    ]


def assert_manifest(manifest):
    if manifest.get("operation_id") != OPERATION_ID:
        raise HelperError("operation ID differs")
    if manifest.get("identity", {}).get("marker_generation") != "1":
        raise HelperError("marker generation differs")
    if manifest.get("execution", {}).get("viewflow_unit") != f"viewflow-v13-early-{OPERATION_ID}.service":
        raise HelperError("transient unit name differs")
    if manifest.get("windows_baseline", {}).get("user_sid") != WINDOWS_SID:
        raise HelperError("Windows SID baseline differs")
    if manifest["windows_baseline"].get("new_operation_root_path") != WINDOWS_ROOT:
        raise HelperError("Windows operation-root baseline differs")


def assert_deskflow_zero(manifest, *, allowed_viewflow_pid=None, allowed_viewflow_argv=None):
    props = systemd_properties("deskflow.service")
    if props["LoadState"] != "loaded" or props["ActiveState"] != "inactive" or props["SubState"] != "dead":
        raise HelperError("Deskflow unit state is not an explicit inactive/dead state")
    if not re.fullmatch(r"0|[1-9][0-9]*", props["MainPID"]):
        raise HelperError("Deskflow MainPID is invalid")
    main_pid = int(props["MainPID"])
    gui = exact_executable_pids(manifest["installed"]["deskflow"]["path"])
    core = exact_executable_pids(manifest["installed"]["deskflow_core"]["path"])
    tcp = listener_count("-tnp", ":24800")
    runtime_marker = os.path.lexists(manifest["execution"]["runtime_marker_path"])
    _assert_no_unexpected_deskflow_processes(
        manifest,
        allowed_viewflow_pid=allowed_viewflow_pid,
        allowed_viewflow_argv=allowed_viewflow_argv,
    )
    if main_pid != 0 or gui or core or tcp != 0 or runtime_marker:
        raise HelperError("Deskflow/input boundary is not zero")
    return {
        "deskflow_unit_state": "inactive", "deskflow_unit_main_pid": 0,
        "deskflow_process_count": 0, "deskflow_core_process_count": 0,
        "deskflow_tcp_listener_count": 0, "runtime_marker_present": False,
        "input_producer_count": 0,
    }


def assert_installed(manifest):
    for name, spec in manifest["installed"].items():
        if file_sha(spec["path"]) != spec["sha256"]:
            raise HelperError(f"installed {name} SHA-256 differs")


def collect_linux(manifest, *, active: bool):
    assert_installed(manifest)
    unit = manifest["execution"]["viewflow_unit"]
    props = systemd_properties(unit, allow_not_found=not active)
    allowed_pid = None
    if active:
        try:
            candidate_pid = int(props["MainPID"] or "0")
        except ValueError as error:
            raise HelperError("Viewflow MainPID is invalid") from error
        if candidate_pid > 0:
            allowed_pid = candidate_pid
    zero = assert_deskflow_zero(
        manifest,
        allowed_viewflow_pid=allowed_pid,
        allowed_viewflow_argv=viewflow_argv(manifest) if allowed_pid is not None else None,
    )
    pids = exact_executable_pids(manifest["installed"]["viewflowd"]["path"])
    udp = listener_count("-unp", ":44119")
    sidecar = listener_count("-xnp", f"/run/user/{os.getuid()}/viewflow/deskflow.sock")
    if not active:
        if (
            props["LoadState"] not in ("not-found", "loaded")
            or props["ActiveState"] != "inactive" or props["SubState"] != "dead"
            or not re.fullmatch(r"0|[1-9][0-9]*", props["MainPID"])
            or int(props["MainPID"]) != 0 or pids or udp or sidecar
        ):
            raise HelperError("initial Viewflow boundary is not zero")
        return {
            "viewflow_unit": unit, "viewflow_unit_state": "inactive", "viewflow_main_pid": 0,
            "viewflow_start_ticks": 0, "viewflow_invocation_id": "", "viewflow_control_group": "",
            "viewflow_exec_start_sha256": None, "viewflowd_sha256": manifest["installed"]["viewflowd"]["sha256"],
            "viewflow_process_count": 0, "viewflow_udp_listener_count": 0,
            "viewflow_sidecar_listener_count": 0, **zero,
        }
    if not re.fullmatch(r"[1-9][0-9]*", props["MainPID"]):
        raise HelperError("Viewflow MainPID is invalid")
    pid = int(props["MainPID"])
    expected_argv = viewflow_argv(manifest)
    control_group = props["ControlGroup"]
    process_cgroup = next((line.split(":", 2)[2] for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines()
                           if line.startswith("0::")), "")
    if not (
        props["LoadState"] == "loaded" and props["ActiveState"] == "active"
        and props["SubState"] == "running" and props["Transient"] == "yes"
        and props["KillMode"] == "control-group" and props["InvocationID"]
        and INVOCATION.fullmatch(props["InvocationID"]) and pids == [pid]
        and cmdline(pid) == expected_argv and control_group == process_cgroup
        and control_group.endswith("/" + unit) and udp == 1 and sidecar == 1
    ):
        raise HelperError("active Viewflow transient identity differs")
    journal = run(["/usr/bin/journalctl", "--user", "--quiet", "--output", "cat",
                   f"_SYSTEMD_INVOCATION_ID={props['InvocationID']}"])
    if "viewflowd protocol 1.3 serving mTLS QUIC" not in journal:
        raise HelperError("protocol-1.3 startup proof is absent")
    return {
        "viewflow_unit": unit, "viewflow_unit_state": "active", "viewflow_main_pid": pid,
        "viewflow_start_ticks": start_ticks(pid), "viewflow_invocation_id": props["InvocationID"],
        "viewflow_control_group": control_group,
        "viewflow_exec_start_sha256": canonical_sha(expected_argv),
        "viewflowd_sha256": manifest["installed"]["viewflowd"]["sha256"],
        "viewflow_process_count": 1, "viewflow_udp_listener_count": 1,
        "viewflow_sidecar_listener_count": 1, **zero,
    }


def start_viewflow(manifest):
    collect_linux(manifest, active=False)
    unit = manifest["execution"]["viewflow_unit"]
    command = [
        "/usr/bin/systemd-run", "--user", f"--unit={unit}", "--collect", "--quiet",
        "--property=Type=simple", "--property=KillMode=control-group", "--property=Restart=no",
        "--property=NoNewPrivileges=yes", "--property=PrivateTmp=yes",
        "--property=RuntimeDirectory=viewflow", "--property=RuntimeDirectoryMode=0700", "--",
        *viewflow_argv(manifest),
    ]
    run(command, timeout=20, env=user_bus_env())
    deadline = time.monotonic() + 30
    last_error = None
    while time.monotonic() < deadline:
        try:
            return collect_linux(manifest, active=True)
        except (HelperError, OSError, subprocess.SubprocessError) as error:
            last_error = error
            time.sleep(0.1)
    raise HelperError(f"Viewflow transient did not reach exact live boundary: {last_error}")


def require_fresh_probe(invocation: str):
    def records():
        text = run(["/usr/bin/journalctl", "--user", "--quiet", "--output", "cat",
                    f"_SYSTEMD_INVOCATION_ID={invocation}"])
        lines = text.splitlines()
        auth = [(index, line) for index, line in enumerate(lines)
                if "viewflowd server authenticated peer " in line]
        if not auth:
            return None, []
        auth_index, auth_line = auth[-1]
        endpoint = auth_line.split("authenticated peer ", 1)[1]
        if not re.fullmatch(re.escape(WINDOWS_SOURCE_IP) + r":[1-9][0-9]{0,4}", endpoint):
            raise HelperError("authenticated peer endpoint differs")
        probes = [line for line in lines[auth_index + 1:]
                  if f"viewflowd server peer {endpoint} probe=" in line]
        return endpoint, probes
    baseline_endpoint, baseline_probes = records()
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        current_endpoint, current_probes = records()
        if current_endpoint is not None and current_probes:
            if baseline_endpoint is None or current_endpoint != baseline_endpoint:
                return
            if any(probe not in baseline_probes for probe in current_probes):
                return
        time.sleep(0.2)
    raise HelperError("fresh authenticated Windows probe was not observed")


def powershell_census_script() -> str:
    script = r'''
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$utf8=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=$utf8;$OutputEncoding=$utf8
function Get-ViewflowSha256Bytes([byte[]]$b){$s=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','').ToLowerInvariant()}finally{$s.Dispose()}}
function Get-ViewflowSha256File([string]$p){return Get-ViewflowSha256Bytes ([IO.File]::ReadAllBytes($p))}
$op='2ca3f46635b65615a1cffc1970d73911'
$root='C:\Users\wilf\AppData\Local\Viewflow\Deployments\'+$op
$task=Get-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer' -ErrorAction Stop
$info=Get-ScheduledTaskInfo -TaskPath '\' -TaskName 'Viewflow Peer' -ErrorAction Stop
$xml=Export-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer'
$enc=[Text.Encoding]::Unicode;$xmlBytes=$enc.GetPreamble()+$enc.GetBytes($xml)
$actions=@($task.Actions);if($actions.Count -ne 1){throw 'old task action count differs'}
$a=$actions[0]
$all=@(Get-CimInstance Win32_Process)
$procs=@($all|Where-Object{
  [string]$_.Name -match '(?i)(^|[\\/])viewflowd(?:\.exe)?$' -or
  [string]$_.ExecutablePath -match '(?i)(^|[\\/])viewflowd(?:\.exe)?$' -or
  [string]$_.CommandLine -match '(?i)(^|[\\/"''\s:=])viewflowd(?:\.exe)?($|[\\/"''\s:=])'
})
if($procs.Count -ne 1){throw 'all-system viewflowd process count differs'}
$p=$procs[0]
if(-not ([string]$p.ExecutablePath -ieq 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe')){throw 'viewflowd executable path differs'}
$owner=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
$created=([datetime]$p.CreationDate).ToUniversalTime().ToFileTimeUtc().ToString()
$workers=@($all|Where-Object{$_.CommandLine -like ('*'+$op+'*') -and $_.CommandLine -like '*start-viewflow-bootstrap.ps1*'})
$installers=@($all|Where-Object{$_.CommandLine -like ('*'+$op+'*') -and $_.CommandLine -like '*install-viewflow.ps1*'})
$newTask=@(Get-ScheduledTask -TaskPath '\' -TaskName ('Viewflow Deployment '+$op) -ErrorAction SilentlyContinue)
[ordered]@{
 task_state=[string]$task.State;task_xml_sha256=Get-ViewflowSha256Bytes $xmlBytes
 action_execute=[string]$a.Execute;action_arguments=[string]$a.Arguments;action_working_directory=[string]$a.WorkingDirectory
 principal_user_id=[string]$task.Principal.UserId;principal_logon_type=[string]$task.Principal.LogonType;principal_run_level=[string]$task.Principal.RunLevel
 viewflowd_sha256=Get-ViewflowSha256File 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe'
 wrapper_sha256=Get-ViewflowSha256File 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1'
 rollback_sha256=Get-ViewflowSha256File 'C:\Users\wilf\AppData\Local\Programs\Viewflow\rollback-viewflow.ps1'
 pid=[int64]$p.ProcessId;parent_pid=[int64]$p.ParentProcessId;process_start_filetime_utc=$created
 session_id=[int64]$p.SessionId;user_sid=[string]$owner.Sid;executable_path=[string]$p.ExecutablePath;command_line=[string]$p.CommandLine
 new_operation_root_present=[bool](Test-Path -LiteralPath $root);new_task_present=[bool]($newTask.Count -ne 0)
 viewflowd_process_count=[int64]$procs.Count;bootstrap_worker_count=[int64]$workers.Count;installer_process_count=[int64]$installers.Count
} | ConvertTo-Json -Compress -Depth 4
'''
    return script


def powershell_encoded_command(script: str) -> str:
    compressed = gzip.compress(script.encode("utf-8"), mtime=0)
    payload = base64.b64encode(compressed).decode("ascii")
    decoder = (
        "$b=[Convert]::FromBase64String('" + payload + "');"
        "$i=[IO.MemoryStream]::new($b);"
        "$g=[IO.Compression.GzipStream]::new($i,[IO.Compression.CompressionMode]::Decompress);"
        "$r=[IO.StreamReader]::new($g,[Text.Encoding]::UTF8);"
        "$s=$r.ReadToEnd();$r.Dispose();$g.Dispose();$i.Dispose();"
        "&([ScriptBlock]::Create($s))"
    )
    encoded = base64.b64encode(decoder.encode("utf-16le")).decode("ascii")
    if len(encoded) >= POWERSHELL_ENCODED_COMMAND_MAX:
        raise HelperError("encoded PowerShell census command exceeds safe length")
    return encoded


def powershell_census() -> str:
    script = powershell_census_script()
    encoded = powershell_encoded_command(script)
    command = [
        "/usr/bin/ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "-o", "StrictHostKeyChecking=yes",
        WINDOWS_HOST, "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded,
    ]
    return run(command, timeout=30)


def collect_windows(manifest):
    raw = strict_json(powershell_census().encode(), "Windows census")
    expected_keys = {
        "task_state", "task_xml_sha256", "action_execute", "action_arguments", "action_working_directory",
        "principal_user_id", "principal_logon_type", "principal_run_level", "viewflowd_sha256",
        "wrapper_sha256", "rollback_sha256", "pid", "parent_pid", "process_start_filetime_utc",
        "session_id", "user_sid", "executable_path", "command_line", "new_operation_root_present",
        "new_task_present", "viewflowd_process_count", "bootstrap_worker_count", "installer_process_count",
    }
    if set(raw) != expected_keys:
        raise HelperError("Windows census keys differ")
    action = {"execute": raw["action_execute"], "arguments": raw["action_arguments"],
              "working_directory": raw["action_working_directory"]}
    principal = {"user_id": raw["principal_user_id"], "logon_type": raw["principal_logon_type"],
                 "run_level": raw["principal_run_level"]}
    baseline = manifest["windows_baseline"]
    expected = {
        "task_state": "Running", "task_xml_sha256": baseline["task_xml_sha256"],
        "viewflowd_sha256": baseline["viewflowd_sha256"], "wrapper_sha256": baseline["wrapper_sha256"],
        "rollback_sha256": baseline["rollback_sha256"], "pid": WINDOWS_PID,
        "parent_pid": WINDOWS_PARENT_PID, "process_start_filetime_utc": WINDOWS_FILETIME,
        "session_id": 1, "user_sid": WINDOWS_SID, "executable_path": WINDOWS_EXE,
        "command_line": WINDOWS_COMMAND, "new_operation_root_present": False,
        "new_task_present": False, "viewflowd_process_count": 1,
        "bootstrap_worker_count": 0, "installer_process_count": 0,
    }
    if any(raw.get(key) != value for key, value in expected.items()):
        raise HelperError("Windows old-peer exact identity differs")
    if action != TASK_ACTION or principal != TASK_PRINCIPAL:
        raise HelperError("Windows task action/principal differs")
    if canonical_sha(action) != baseline["task_action_sha256"] or canonical_sha(principal) != baseline["task_principal_sha256"]:
        raise HelperError("Windows canonical task hashes differ")
    if hashlib.sha256(raw["command_line"].encode()).hexdigest() != baseline["command_line_sha256"]:
        raise HelperError("Windows command-line hash differs")
    return {
        "task_path": "\\", "task_name": "Viewflow Peer", "task_state": "Running",
        "task_xml_sha256": raw["task_xml_sha256"], "task_action_sha256": canonical_sha(action),
        "task_principal_sha256": canonical_sha(principal),
        "request_sha256": manifest["artifacts"]["bootstrap_request"]["sha256"],
        "viewflowd_sha256": raw["viewflowd_sha256"], "wrapper_sha256": raw["wrapper_sha256"],
        "rollback_sha256": raw["rollback_sha256"], "pid": raw["pid"], "parent_pid": raw["parent_pid"],
        "process_start_filetime_utc": raw["process_start_filetime_utc"], "session_id": 1,
        "user_sid": WINDOWS_SID, "executable_path": WINDOWS_EXE,
        "command_line_sha256": baseline["command_line_sha256"],
        "new_operation_root_path": WINDOWS_ROOT, "new_operation_root_present": False,
        "new_task_path": "\\", "new_task_name": "Viewflow Deployment " + OPERATION_ID,
        "new_task_present": False, "viewflowd_process_count": raw["viewflowd_process_count"],
        "bootstrap_worker_created": False, "installer_process_count": 0,
        "mutation_permit_published": False, "initial_force_release_executed": False,
        "force_release_executed": False, "rollback_performed": False,
        "windows_rollback_receipt_sha256": None, "protocol_2_1": False,
    }


def reattest_windows(manifest, before):
    after = collect_windows(manifest)
    if after != before:
        raise HelperError("Windows identity changed during fresh probe wait")
    return after


def snapshot(action, manifest, linux, windows):
    return {
        "schema_version": 1, "state": "viewflow-early-gate-" + action,
        "operation_id": OPERATION_ID, "marker_sha256": manifest["marker"]["sha256"],
        "marker_generation": "1", "linux": linux, "windows": windows,
    }


def read_sealed_manifest(path: str):
    match = re.fullmatch(r"/proc/self/fd/([0-9]+)", path)
    if not match:
        raise HelperError("manifest must be supplied by inherited sealed FD")
    fd = int(match.group(1))
    if fcntl.fcntl(fd, fcntl.F_GET_SEALS) != SEALS:
        raise HelperError("manifest FD seals differ")
    os.lseek(fd, 0, os.SEEK_SET)
    data = b""
    while True:
        chunk = os.read(fd, 1 << 20)
        if not chunk:
            break
        data += chunk
    return strict_json(data, "sealed manifest")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ACTIONS:
        raise HelperError("usage: helper ACTION /proc/self/fd/N")
    action = sys.argv[1]
    manifest = read_sealed_manifest(sys.argv[2])
    assert_manifest(manifest)
    windows_before = collect_windows(manifest)
    windows = windows_before
    if action == "preflight":
        linux = collect_linux(manifest, active=False)
    elif action == "start-viewflow":
        linux = start_viewflow(manifest)
    else:
        linux = collect_linux(manifest, active=True)
        if action in {"authenticated-peer", "pre-abort-reattest", "post-abort-reattest"}:
            require_fresh_probe(linux["viewflow_invocation_id"])
            windows = reattest_windows(manifest, windows_before)
            linux = collect_linux(manifest, active=True)
    print(json.dumps(snapshot(action, manifest, linux, windows), sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except (HelperError, OSError, ValueError, subprocess.SubprocessError, socket.error) as error:
        print(f"early bootstrap runtime helper: {error}", file=sys.stderr)
        raise SystemExit(1)
