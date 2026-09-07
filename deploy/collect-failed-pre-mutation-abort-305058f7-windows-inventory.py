#!/usr/bin/env python3
"""Collect the immutable Windows pre-abort boundary for operation 305058f7.

This program is read-only on Windows.  It takes two complete PowerShell 5.1
snapshots in one SSH session, rejects any difference, then publishes the
result locally with create-once/no-replace semantics.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import gzip
import hashlib
import json
import os
import re
import stat
import subprocess
from pathlib import Path

OP = "305058f7deb84c198bad4103d6c4f946"
SID = "S-1-5-21-1940417919-1835306932-1635351729-1001"
SSH_TARGET = "wilf@172.16.105.70"
WINDOWS_ROOT = rf"C:\Users\wilf\AppData\Local\Viewflow\Deployments\{OP}"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
OUTPUT = ROOT / "no-retry-v4-windows-operation-root-inventory.raw.json"
EXPECTED_ORDER = (
    "installer.stderr.log", "installer.stdout.log", "installer-exit.json",
    "install-viewflow.ps1", "launcher-claim.json", "launcher-installer-process.json",
    "launcher-stop-evidence.json", "linux-v13-frozen-evidence.json",
    "marker-handoff-receipt.json", "request.json", "rollback-viewflow.ps1",
    "start-viewflow-bootstrap.ps1", "viewflow-client.ps1", "viewflowd.exe",
)
EXPECTED_NAMES = set(EXPECTED_ORDER)
EXPECTED_ABSENT = {
    "bootstrap-prepared.json", "mutation-permit.json", "raw-force-release.json",
    "force-release-envelope.json", "linux-stage-receipt.json",
    "windows-install-success.json", "readiness.json", "readiness.lock",
    "readiness-commit-request.json", "rollback-manifest.json", "rollback-token.json",
    "recovery-bundle.json", "recovery-force-release.json",
    "windows-rollback-receipt.json", "windows-rollback-dispatch-claim.json",
}
SHA = re.compile(r"[0-9a-f]{64}")


class InventoryError(RuntimeError):
    pass


def pairs(items):
    value = {}
    for key, item in items:
        if key in value:
            raise InventoryError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def strict_json(raw: bytes):
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InventoryError("Windows inventory is not strict UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise InventoryError("Windows inventory must be one JSON object")
    return value


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def exact_keys(value, expected, label):
    if not isinstance(value, dict) or set(value) != set(expected):
        raise InventoryError(f"{label} keys differ")


def powershell_script() -> str:
    absent = ",".join("'" + name.replace("'", "''") + "'" for name in sorted(EXPECTED_ABSENT))
    return rf'''
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=$utf8
function Get-VfHash([byte[]]$b){{$s=[Security.Cryptography.SHA256]::Create();try{{return ([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','').ToLowerInvariant()}}finally{{$s.Dispose()}}}}
function Get-VfFileHash([string]$p){{return Get-VfHash ([IO.File]::ReadAllBytes($p))}}
function Get-VfTextHash([string]$s){{return Get-VfHash ([Text.Encoding]::UTF8.GetBytes($s))}}
function Get-VfTask([string]$n){{
  $t=Get-ScheduledTask -TaskPath '\' -TaskName $n -ErrorAction Stop
  $x=Export-ScheduledTask -TaskPath '\' -TaskName $n -ErrorAction Stop
  $enc=[Text.Encoding]::Unicode;$xb=$enc.GetPreamble()+$enc.GetBytes($x)
  $actions=@($t.Actions|ForEach-Object{{[ordered]@{{execute=[string]$_.Execute;arguments=[string]$_.Arguments;working_directory=[string]$_.WorkingDirectory}}}})
  $principal=[ordered]@{{user_id=[string]$t.Principal.UserId;logon_type=[string]$t.Principal.LogonType;run_level=[string]$t.Principal.RunLevel}}
  [ordered]@{{task_name=$n;task_path='\';state=[string]$t.State;xml_sha256=Get-VfHash $xb;action_sha256=Get-VfTextHash ($actions|ConvertTo-Json -Compress -Depth 5);principal_sha256=Get-VfTextHash ($principal|ConvertTo-Json -Compress -Depth 5)}}
}}
function Get-VfInventory([string]$p){{
  if(-not(Test-Path -LiteralPath $p -PathType Container)){{throw 'root absent'}}
  $acl=Get-Acl -LiteralPath $p
  $members=@(Get-ChildItem -LiteralPath $p -Force|Sort-Object Name|ForEach-Object{{
    $a=Get-Acl -LiteralPath $_.FullName
    [ordered]@{{name=$_.Name;kind=$(if($_.PSIsContainer){{'directory'}}else{{'file'}});length=$(if($_.PSIsContainer){{$null}}else{{[int64]$_.Length}});sha256=$(if($_.PSIsContainer){{$null}}else{{Get-VfFileHash $_.FullName}});attributes=[string]$_.Attributes;owner=[string]$a.Owner;sddl=$a.Sddl;access_rules_protected=[bool]$a.AreAccessRulesProtected}}
  }})
  [ordered]@{{root=$p;root_owner=[string]$acl.Owner;root_sddl=$acl.Sddl;root_access_rules_protected=[bool]$acl.AreAccessRulesProtected;member_count=[int64]$members.Count;members=$members}}
}}
function Get-VfSnapshot{{
  $op='{OP}';$root='{WINDOWS_ROOT}';$all=@(Get-CimInstance Win32_Process)
  $peer=@($all|Where-Object{{[string]$_.ExecutablePath -ieq 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe'}})
  if($peer.Count-ne 1){{throw 'peer count'}};$p=$peer[0];$owner=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
  $workers=@($all|Where-Object{{[string]$_.CommandLine -like ('*'+$op+'*') -and [string]$_.CommandLine -like '*start-viewflow-bootstrap.ps1*'}})
  $installers=@($all|Where-Object{{[string]$_.CommandLine -like ('*'+$op+'*') -and [string]$_.CommandLine -like '*install-viewflow.ps1*'}})
  $relevant=@($all|Where-Object{{([string]$_.Name+' '+[string]$_.ExecutablePath+' '+[string]$_.CommandLine)-match '(?i)viewflow|deskflow'}}|Sort-Object ProcessId|ForEach-Object{{[ordered]@{{pid=[int64]$_.ProcessId;parent_pid=[int64]$_.ParentProcessId;executable_path=[string]$_.ExecutablePath;command_line_sha256=Get-VfTextHash ([string]$_.CommandLine)}}}})
  $present=@();foreach($leaf in @({absent})){{if(Test-Path -LiteralPath (Join-Path $root $leaf)){{$present+=$leaf}}}}
  [ordered]@{{operation_root=Get-VfInventory $root;deployment_task=Get-VfTask ('Viewflow Deployment '+$op);old_peer_task=Get-VfTask 'Viewflow Peer';old_peer=[ordered]@{{pid=[int64]$p.ProcessId;parent_pid=[int64]$p.ParentProcessId;start_filetime_utc=([datetime]$p.CreationDate).ToUniversalTime().ToFileTimeUtc().ToString();session_id=[int64]$p.SessionId;sid=[string]$owner.Sid;command_line_sha256=Get-VfTextHash ([string]$p.CommandLine);viewflowd_sha256=Get-VfFileHash 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe';wrapper_sha256=Get-VfFileHash 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1';rollback_sha256=Get-VfFileHash 'C:\Users\wilf\AppData\Local\Programs\Viewflow\rollback-viewflow.ps1'}};bootstrap_worker_count=[int64]$workers.Count;installer_process_count=[int64]$installers.Count;mutation_outputs_present=@($present|Sort-Object);global_relevant_processes=$relevant}}
}}
$before=Get-VfSnapshot
[Threading.Thread]::Sleep(250)
$after=Get-VfSnapshot
[ordered]@{{schema_version=2;state='viewflow-windows-operation-root-stable-inventory';operation_id='{OP}';stable=[bool](($before|ConvertTo-Json -Compress -Depth 12)-ceq($after|ConvertTo-Json -Compress -Depth 12));before=$before;after=$after}}|ConvertTo-Json -Compress -Depth 12
'''


def encoded_command() -> str:
    packed = base64.b64encode(gzip.compress(powershell_script().encode(), mtime=0)).decode()
    decoder = "$b=[Convert]::FromBase64String('" + packed + "');$m=[IO.MemoryStream]::new($b);$g=[IO.Compression.GzipStream]::new($m,[IO.Compression.CompressionMode]::Decompress);$r=[IO.StreamReader]::new($g,[Text.Encoding]::UTF8);$s=$r.ReadToEnd();$r.Dispose();$g.Dispose();$m.Dispose();&([ScriptBlock]::Create($s))"
    value = base64.b64encode(decoder.encode("utf-16le")).decode()
    if len(value) >= 7500:
        raise InventoryError("PowerShell encoded command is too large")
    return value


def validate_member(member):
    exact_keys(member, {"name", "kind", "length", "sha256", "attributes", "owner", "sddl",
                        "access_rules_protected"}, "operation-root member")
    if (member["name"] not in EXPECTED_NAMES or member["kind"] != "file"
            or not isinstance(member["length"], int) or member["length"] < 0
            or not isinstance(member["sha256"], str) or not SHA.fullmatch(member["sha256"])
            or not isinstance(member["attributes"], str) or "ReparsePoint" in member["attributes"]
            or not isinstance(member["owner"], str) or not member["owner"].lower().endswith("\\wilf")
            or not isinstance(member["sddl"], str) or SID not in member["sddl"]
            or not isinstance(member["access_rules_protected"], bool)):
        raise InventoryError("operation-root member identity/ACL differs")


def validate_task(task, expected_name, expected_state):
    exact_keys(task, {"task_name", "task_path", "state", "xml_sha256", "action_sha256",
                      "principal_sha256"}, "scheduled-task proof")
    if (task["task_name"] != expected_name or task["task_path"] != "\\"
            or task["state"] != expected_state
            or any(not isinstance(task[key], str) or not SHA.fullmatch(task[key])
                   for key in ("xml_sha256", "action_sha256", "principal_sha256"))):
        raise InventoryError("scheduled-task identity differs")


def validate_snapshot(snapshot):
    exact_keys(snapshot, {"operation_root", "deployment_task", "old_peer_task", "old_peer",
                          "bootstrap_worker_count", "installer_process_count",
                          "mutation_outputs_present", "global_relevant_processes"}, "Windows snapshot")
    inventory = snapshot["operation_root"]
    exact_keys(inventory, {"root", "root_owner", "root_sddl", "root_access_rules_protected",
                           "member_count", "members"}, "operation-root inventory")
    if (inventory["root"] != WINDOWS_ROOT or inventory["member_count"] != 14
            or not isinstance(inventory["members"], list) or len(inventory["members"]) != 14
            or inventory["root_access_rules_protected"] is not True
            or not isinstance(inventory["root_owner"], str)
            or not inventory["root_owner"].lower().endswith("\\wilf")
            or not isinstance(inventory["root_sddl"], str) or SID not in inventory["root_sddl"]):
        raise InventoryError("operation-root identity/ACL differs")
    for member in inventory["members"]:
        validate_member(member)
    names = [member["name"] for member in inventory["members"]]
    if names != list(EXPECTED_ORDER) or len(names) != len(set(names)):
        raise InventoryError("operation-root member set/order differs")
    validate_task(snapshot["deployment_task"], "Viewflow Deployment " + OP, "Disabled")
    validate_task(snapshot["old_peer_task"], "Viewflow Peer", "Running")
    peer = snapshot["old_peer"]
    exact_keys(peer, {"pid", "parent_pid", "start_filetime_utc", "session_id", "sid",
                      "command_line_sha256", "viewflowd_sha256", "wrapper_sha256",
                      "rollback_sha256"}, "old-peer proof")
    if (not isinstance(peer["pid"], int) or peer["pid"] <= 0
            or not isinstance(peer["parent_pid"], int) or peer["parent_pid"] <= 0
            or not isinstance(peer["start_filetime_utc"], str) or not peer["start_filetime_utc"].isdigit()
            or peer["session_id"] != 1 or peer["sid"] != SID
            or any(not isinstance(peer[key], str) or not SHA.fullmatch(peer[key]) for key in
                   ("command_line_sha256", "viewflowd_sha256", "wrapper_sha256", "rollback_sha256"))):
        raise InventoryError("old-peer identity differs")
    processes = snapshot["global_relevant_processes"]
    if not isinstance(processes, list) or not processes:
        raise InventoryError("global process census is empty or invalid")
    seen = set()
    for process in processes:
        exact_keys(process, {"pid", "parent_pid", "executable_path", "command_line_sha256"},
                   "global process census member")
        if (not isinstance(process["pid"], int) or process["pid"] <= 0 or process["pid"] in seen
                or not isinstance(process["parent_pid"], int) or process["parent_pid"] < 0
                or not isinstance(process["executable_path"], str)
                or not SHA.fullmatch(process["command_line_sha256"])):
            raise InventoryError("global process census member differs")
        seen.add(process["pid"])
    if ([process["pid"] for process in processes] != sorted(seen)
            or snapshot["bootstrap_worker_count"] != 0 or snapshot["installer_process_count"] != 0
            or snapshot["mutation_outputs_present"] != []):
        raise InventoryError("Windows process/mutation boundary differs")


def validate_document(value):
    exact_keys(value, {"schema_version", "state", "operation_id", "stable", "before", "after"},
               "inventory document")
    if (value["schema_version"] != 2
            or value["state"] != "viewflow-windows-operation-root-stable-inventory"
            or value["operation_id"] != OP or value["stable"] is not True
            or value["before"] != value["after"]):
        raise InventoryError("two-snapshot stability proof differs")
    validate_snapshot(value["before"])
    validate_snapshot(value["after"])


def create_once(data: bytes):
    parent = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    temporary = "." + OUTPUT.name + ".tmp." + str(os.getpid()) + "." + os.urandom(8).hex()
    try:
        before = os.fstat(parent)
        named = os.stat(ROOT, follow_symlinks=False)
        if (not stat.S_ISDIR(before.st_mode) or before.st_uid != os.geteuid()
                or stat.S_IMODE(before.st_mode) != 0o700
                or (before.st_dev, before.st_ino) != (named.st_dev, named.st_ino)
                or any(name in ("system.posix_acl_access", "system.posix_acl_default")
                       for name in os.listxattr(parent))):
            raise InventoryError("output parent identity/ACL differs")
        try:
            os.stat(OUTPUT.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise InventoryError("inventory output already exists")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                     0o600, dir_fd=parent)
        try:
            view = memoryview(data)
            while view:
                count = os.write(fd, view)
                if count <= 0:
                    raise InventoryError("inventory output short write")
                view = view[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renameat2(parent, os.fsencode(temporary), parent, os.fsencode(OUTPUT.name), 1) != 0:
            raise InventoryError("inventory no-replace rename failed")
        os.fsync(parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def main():
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--check-only", action="store_true")
    modes.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    encoded = encoded_command()
    if args.check_only:
        if os.path.lexists(OUTPUT):
            raise InventoryError("inventory output is not fresh")
        print("op305 Windows stable-inventory collector offline contract passed; no SSH or write")
        return
    result = subprocess.run(
        ["/usr/bin/ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
         "-o", "StrictHostKeyChecking=yes", SSH_TARGET, "powershell.exe", "-NoProfile",
         "-NonInteractive", "-EncodedCommand", encoded],
        env={"PATH": "/usr/bin:/bin"}, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=45, check=True,
    )
    value = strict_json(result.stdout.strip() + b"\n")
    validate_document(value)
    create_once(canonical(value))
    print("op305 Windows stable operation-root/old-peer inventory published create-once")


if __name__ == "__main__":
    try:
        main()
    except (InventoryError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("op305 Windows inventory collector: " + str(error), file=os.sys.stderr)
        raise SystemExit(1)
