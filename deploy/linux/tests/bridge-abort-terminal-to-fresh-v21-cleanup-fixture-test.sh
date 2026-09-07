#!/usr/bin/env bash
# shellcheck disable=SC2155
set -Eeuo pipefail
umask 077
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SOURCE=$(cd -- "$HERE/.." && pwd)/bridge-abort-terminal-to-fresh-v21.sh
root=$(mktemp -d --tmpdir 'viewflow-bridge-cleanup.XXXXXX')
trap 'rm -rf -- "$root"' EXIT

die() { return 1; }
new_operation=11111111111111111111111111111111
terminal=$root/terminal.json
linux_started=$root/linux.json
core=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
marker=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq -cn --arg core "$core" --arg marker "$marker" \
  '{linux_deskflow_core_executable_sha256:$core,linux_deskflow_core_pid:12,linux_deskflow_core_start_ticks:34,
    deployment_marker_sha256:$marker}' >"$terminal"
jq -cn '{main_pid:56,start_ticks:78}' >"$linux_started"

# Execute the production validator function, not a duplicated jq model.
eval "$(awk '/^validate_cleanup_receipt\(\)/,/^}/ {print}' "$SOURCE")"
boot=$(tr -d -- '-' </proc/sys/kernel/random/boot_id)
op_sha=$(printf '%s' "$new_operation" | sha256sum | awk '{print $1}')
valid=$root/valid.json
jq -cn --arg op "$new_operation" --arg op_sha "$op_sha" --arg marker "$marker" --arg core "$core" --arg boot "$boot" '
 {acknowledged:true,active_lease_generation:6,bound_peer_address:"00000000000000000000ffffac106946",
  bound_peer_epoch:7,bound_peer_family:4,bound_peer_port:50000,bound_peer_scope_id:0,
  cleanup_complete_body_size:277,cleanup_complete_mode:"normal",cleanup_operation_id:"00000000000000070000000000000001",
  cleanup_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",completed_at_unix_ms:1,
  coordinator_operation_id:$op,coordinator_operation_id_sha256:$op_sha,core_boot_id:$boot,
  core_executable_sha256:$core,core_pid:12,core_start_ticks:34,daemon_boot_id:$boot,daemon_pid:56,daemon_start_ticks:78,
  deployment_marker_bound:true,deployment_marker_sha256:$marker,marker_last_sequence:5,
  owner_device_id:"00000000000000000000000000000002",protocol_version:"2.1",route_generation:4,
  runtime_marker_magic:"VFQST002",runtime_marker_path:"/home/wilf/.local/state/viewflow/deskflow-quarantine.v2",
  runtime_marker_released:true,runtime_marker_sha256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  runtime_marker_size:152,schema_version:1,sidecar_protocol_version:3,
  source_display_id:"00000000000000000000000000000101",state:"deskflow-runtime-cleanup-evidence",
  target_device_id:"00000000000000000000000000000002",tombstone_magic:"VFACK001",
  tombstone_sha256:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",tombstone_size:72}' >"$valid"
validate_cleanup_receipt "$valid"

reject() {
    local label=$1 filter=$2 bad
    bad=$root/$label.json
    jq "$filter" "$valid" >"$bad"
    if (validate_cleanup_receipt "$bad") >/dev/null 2>&1; then
        printf 'error: cleanup validator accepted %s\n' "$label" >&2
        exit 1
    fi
}
reject coordinator-hash '.coordinator_operation_id_sha256=("0"*64)'
reject cleanup-epoch '.cleanup_operation_id="00000000000000080000000000000001"'
reject zero-cleanup-id '.cleanup_operation_id=("0"*32)'
reject tombstone-hash '.tombstone_sha256="short"'
reject marker-sequence '.marker_last_sequence=-1'
reject peer-family '.bound_peer_family=6'
reject daemon-boot '.daemon_boot_id=("0"*32)'
printf 'abort-terminal to fresh-v2.1 cleanup semantic fixture passed\n'
