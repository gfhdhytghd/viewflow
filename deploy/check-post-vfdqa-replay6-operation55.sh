#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
readonly SOURCE=${1:-/home/wilf/data/viewflow/deploy/reconcile-post-vfdqa-replay6-operation55.sh}
die(){ printf 'post-VFDQA checker: %s\n' "$*" >&2; exit 1; }
[[ -f $SOURCE && ! -L $SOURCE ]] || die 'source missing or symlinked'
bash -n "$SOURCE"
required=(
  'VFDQA_COMMITTED' 'AUTHZ_PROVENANCE_INVALID' 'TERMINAL_ABSENT' 'CURRENT_RUNTIME_REATTESTED'
  'WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION' 'normal_success_terminal:false'
  'fresh_bridge_ready:false' 'old_authorization_retroactively_validated:false'
  'stdin-base64-single-scriptblock-stop-on-error-v1' 'ScriptBlock]::Create'
  'catch{[Console]::Error.WriteLine' 'exit 1};exit 0' 'StrictHostKeyChecking=yes'
  'validate_vfdqa' 'validate_live_runtime' 'observed_exec_start_sha' 'process_ticks'
  'publish_once' 'os.link(src,dst,follow_symlinks=False)' 'os.O_DIRECTORY' 'os.fsync(dfd)'
  'read_all(fd,size)' 'os.unlink(src); source_removed=True; os.fsync(dfd)' 'if created and not source_removed:'
  'source_now.st_nlink==2' 'peer=os.lstat(peers[0]); current=os.lstat(dst)' 'peer.st_nlink==2 and'
  'recover_interrupted_publish' 'linux_runtime_inventory_sha256'
  'fresh Windows census differs from durable census' 'fresh Linux runtime census differs from durable census'
  'validate_adopted' 'validate_abort_state'
  'validate_live_runtime; capture_live_runtime'
)
for token in "${required[@]}"; do grep -F -- "$token" "$SOURCE" >/dev/null || die "missing contract token: $token"; done
! grep -F 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -' "$SOURCE" >/dev/null || die 'unsafe PowerShell -Command - transport returned'
! grep -E 'fresh_bridge_ready[=:]true|normal_success_terminal[=:]true|old_authorization_retroactively_validated[=:]true' "$SOURCE" >/dev/null || die 'unsafe success promotion present'
printf 'post-VFDQA replay6 source checker passed\n'
