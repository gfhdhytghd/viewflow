#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

source_file=${1:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper.py}
die() { printf 'runtime helper checker: %s\n' "$*" >&2; exit 1; }
[[ -f $source_file && ! -L $source_file ]] || die 'helper must be a regular non-symlink'
[[ $(stat -c %a -- "$source_file") == 755 ]] || die 'helper mode must be 0755'
python3 -m py_compile "$source_file" || die 'helper does not compile'

need() { grep -F -- "$1" "$source_file" >/dev/null || die "missing contract: $2"; }
reject() { ! grep -E -- "$1" "$source_file" >/dev/null || die "forbidden construct: $2"; }

need 'OPERATION_ID = "2ca3f46635b65615a1cffc1970d73911"' 'fixed operation'
need 'WINDOWS_PID = 22912' 'exact old Windows PID'
need 'WINDOWS_PARENT_PID = 25608' 'exact old Windows parent PID'
need 'WINDOWS_FILETIME = "134326073277429320"' 'exact old Windows FILETIME'
need 'task_xml_sha256' 'task XML binding'
need 'canonical_sha(action)' 'canonical task action binding'
need 'canonical_sha(principal)' 'canonical task principal binding'
need 'command_line_sha256' 'exact command-line binding'
need 'new_operation_root_present' 'new operation root absence'
need 'new_task_present' 'new task absence'
need 'bootstrap_worker_count' 'worker census'
need 'installer_process_count' 'installer census'
need '"/usr/bin/ssh", "-F", "/dev/null"' 'fixed read-only SSH transport'
need '"StrictHostKeyChecking=yes"' 'host-key verification'
need '"/usr/bin/systemd-run", "--user"' 'transient old Viewflow start'
need '"--property=KillMode=control-group"' 'transient cgroup kill boundary'
need 'result.returncode != 0' 'systemd query failure rejection'
need 'set(values) != set(names)' 'complete systemd property set'
need 'allow_not_found' 'Viewflow preflight not-found handling'
need 'result.returncode not in (0, 4)' 'bounded preflight not-found result codes'
need 'XDG_RUNTIME_DIR' 'explicit user runtime directory binding'
need 'DBUS_SESSION_BUS_ADDRESS' 'explicit user bus binding'
need 'def user_bus_env' 'single user bus environment helper'
need 'env=user_bus_env()' 'systemd-run user bus environment'
need 'props["LoadState"] != "loaded"' 'loaded Deskflow unit state'
need 'props["SubState"] != "dead"' 'dead Deskflow unit substate'
need 're.fullmatch(r"0|[1-9][0-9]*", props["MainPID"])' 'strict Deskflow MainPID zero'
need 'props["SubState"] == "running"' 'running active Viewflow transient'
need 'props["Transient"] == "yes"' 'transient unit reattestation'
need 'cmdline(pid) == expected_argv' 'exact Linux argv binding'
need 'linux_process_census' 'all-system Linux process census'
need '_assert_no_unexpected_deskflow_processes' 'unexpected Deskflow process rejection'
need 'DESKFLOW_DISPLAY' 'Deskflow display-name matching'
need 'cmdline_bytes' 'byte-safe Linux cmdline census'
need '_read_process_exe' 'kernel-thread executable handling'
need 're.compile(rb' 'byte-level process field matching'
need 'Get-ViewflowSha256Bytes' 'unique PowerShell byte hash helper'
need 'Get-ViewflowSha256File' 'unique PowerShell file hash helper'
need "\$ProgressPreference='SilentlyContinue'" 'quiet PowerShell output'
need "[Console]::OutputEncoding=\$utf8" 'UTF-8 PowerShell output'
need 'gzip.compress' 'compressed PowerShell transport'
need 'GzipStream' 'PowerShell gzip decoder'
need 'StreamReader' 'PowerShell UTF-8 decoder'
need 'ScriptBlock]::Create' 'PowerShell script block execution'
need 'POWERSHELL_ENCODED_COMMAND_MAX' 'bounded encoded command length'
need 'stdout.decode("utf-8", "strict")' 'strict UTF-8 stdout decoding'
need 'stderr=result.stderr' 'raw stderr on remote command failure'
need 'viewflowd protocol 1.3 serving mTLS QUIC' 'protocol 1.3 startup proof'
need 'viewflowd server authenticated peer' 'fresh authenticated peer proof'
need 'baseline_endpoint is None' 'first authenticated peer probe boundary'
need 'current_endpoint != baseline_endpoint' 'new authenticated endpoint boundary'
need 'current_probes' 'fresh probe collection'
need 'auth_index + 1' 'probe must follow authentication'
need 'windows_before = collect_windows(manifest)' 'Windows before-probe attestation'
need 'windows = reattest_windows(manifest, windows_before)' 'Windows after-probe attestation'
need 'Windows identity changed during fresh probe wait' 'Windows drift rejection during probe wait'
need 'fcntl.F_GET_SEALS' 'sealed manifest verification'
need 'if action == "preflight"' 'inactive preflight branch'
need 'elif action == "start-viewflow"' 'single mutation branch'
need '"pre-abort-reattest", "post-abort-reattest"' 'both stable reattestations'
need '"deskflow_unit_state": "inactive"' 'Deskflow inactive result'
need '"input_producer_count": 0' 'input producer zero result'
need 'viewflowd_process_count' 'all-system Windows viewflowd census'
need 'all-system viewflowd process count differs' 'extra Windows viewflowd rejection'
need 'Get-CimInstance Win32_Process' 'all-system Windows process enumeration'
need "task_state=[string]\$task.State" 'Windows scheduled-task state source'
reject "task_state=\[string\]\\\$info\.State" 'invalid ScheduledTaskInfo state source'

reject 'systemctl[^\n]*(start|restart)[^\n]*deskflow|systemd-run[^\n]*deskflow|Start-ScheduledTask|Register-ScheduledTask|Set-ScheduledTask|Stop-Process|Remove-Item|New-Item' 'Deskflow/Windows mutation'
reject 'StrictHostKeyChecking=no|UserKnownHostsFile=/dev/null' 'SSH trust bypass'

python3 - "$source_file" <<'PY'
import ast,sys
tree=ast.parse(open(sys.argv[1],encoding='utf-8').read())
actions=None
for node in tree.body:
    if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='ACTIONS' for t in node.targets):
        actions=ast.literal_eval(node.value)
assert actions=={'preflight','start-viewflow','windows-v13','authenticated-peer','pre-abort-reattest','post-abort-reattest'}
source=open(sys.argv[1],encoding='utf-8').read();main=source[source.index('def main():'):]
probe=main.index('require_fresh_probe(linux["viewflow_invocation_id"])')
windows=main.index('windows = reattest_windows(manifest, windows_before)')
linux_after=main.index('linux = collect_linux(manifest, active=True)', windows)
assert probe < windows < linux_after
PY
printf 'early bootstrap runtime helper source checker passed\n'
