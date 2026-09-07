#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
readonly SOURCE=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bridge-abort-terminal-to-fresh-v21.sh}
fail() { printf 'error: bridge checker: %s\n' "$*" >&2; exit 1; }
fixed() { grep -Fq -- "$1" "$SOURCE" || fail "missing $2"; }
line_of() { grep -nF -- "$1" "$SOURCE" | tail -n1 | cut -d: -f1; }
[[ -f $SOURCE && ! -L $SOURCE ]] || fail 'source must be a regular non-symlink file'
bash -n "$SOURCE"

fixed 'if [[ -n ${LD_PRELOAD-} || -n ${LD_AUDIT-} || -n ${LD_LIBRARY_PATH-}' 'loader environment rejection'
fixed 'readonly PATH=/usr/bin:/bin' 'fixed PATH'
fixed 'umask 077' 'owner-only umask'
fixed 'bridge_root == /home/wilf/.local/state/viewflow/bridges/$old_operation' 'fixed bridge namespace'
fixed 'fresh_operation_root==("/home/wilf/.local/state/viewflow/deployments/"+.new_operation_id)' 'fresh root binding'
fixed 'new_operation_id!=$old' 'old operation non-reuse gate'
fixed '.new_coordinator_instance_id!=$old_coordinator' 'old coordinator non-reuse gate'
fixed 'uuidgen | tr' 'fresh UUID generation'

fixed 'VFDQA001' 'VFDQA magic validation'
fixed 'b[8:13]!=bytes((1,1,1,3,1))' 'VFDQA schema/protocol/owner validation'
fixed 'hashlib.sha256(marker).hexdigest()!=sys.argv[3]' 'embedded marker hash validation'
fixed 'marker[16:16+len(op)]!=op' 'embedded marker operation binding'
fixed 'marker[144:160]!=uuid.UUID("00000000-0000-0000-0000-000000000101").bytes' 'embedded marker source binding'
fixed 'marker[176:192]!=uuid.UUID(sys.argv[6]).bytes' 'embedded marker coordinator binding'
fixed 'b[304:336].hex()!=sys.argv[4]' 'authorization hash validation'
fixed 'hashlib.sha256(b[:352]).digest()!=b[352:384]' 'VFDQA checksum validation'
fixed '.schema_version == 2 and .state == "viewflow-failed-pre-mutation-installer-baseline-restored-abort-terminal"' 'terminal schema2 gate'
fixed '.initial_force_release_executed == false' 'truthful no-force gate'
fixed '.rollback_performed == false' 'truthful no-rollback gate'
fixed '.windows_rollback_receipt_sha256 == null' 'null rollback receipt gate'
fixed 'keys == ["abort_authorization_sha256"' 'exact terminal keys'
fixed 'keys == ["authenticated_v13_peer_receipt_sha256","authorization_receipt_path"' 'exact authorization keys'
fixed 'keys == ["control_group","deployment_marker_sha256"' 'exact Linux start keys'

fixed '$(observed_exec_start_sha "$vf_unit") == "$(jq -er '\''.exec_start_sha256' 'Viewflow ExecStart binding'
fixed '$(observed_exec_start_sha "$df_unit") == "$(jq -er '\''.linux_deskflow_exec_start_sha256' 'Deskflow ExecStart binding'
fixed '$(process_ticks "$df_main") == "$(jq -er '\''.linux_deskflow_main_start_ticks' 'supervisor start-ticks binding'
fixed '$(process_ticks "$df_gui") == "$(jq -er '\''.linux_deskflow_runtime_start_ticks' 'GUI start-ticks binding'
fixed '$(process_ticks "$df_core") == "$(jq -er '\''.linux_deskflow_core_start_ticks' 'core start-ticks binding'
fixed '$(sha256 "/proc/$df_main/exe") == "$bwrap_sha"' 'Bubblewrap executable binding'
fixed '$(sha256 "/proc/$df_gui/exe") == "$(jq -er '\''.linux_deskflow_executable_sha256' 'Deskflow executable binding'
fixed '$(sha256 "/proc/$df_core/exe") == "$(jq -er '\''.linux_deskflow_core_executable_sha256' 'core executable binding'

fixed '--viewflow-acceptance-query status' 'sidecar-3 status query'
fixed '--viewflow-acceptance-query arm' 'sidecar-3 acceptance arm'
fixed '--viewflow-acceptance-query cleanup' 'ReleaseAll cleanup query'
fixed '(.runtime_marker_present|type=="boolean") and .receipt_available==false' 'stale cleanup receipt rejection'
fixed 'keys==["acceptance_status","acceptance_status_sha256","operation_id","pressed_state","schema_version","state"]' 'strict no-route cleanup wrapper'
fixed 'keys==["cleanup_receipt","cleanup_receipt_sha256","operation_id","pressed_state","schema_version","state"]' 'strict release cleanup wrapper'
fixed 'pressed_state:"released"' 'released pressed-state proof'
fixed 'pressed_state:"no-active-route"' 'no-active-route proof'
fixed '.cleanup_complete_mode=="normal"' 'normal cleanup mode'
fixed '.acknowledged==true' 'acknowledged cleanup gate'
fixed '.runtime_marker_released==true' 'runtime marker release gate'
fixed '.coordinator_operation_id_sha256==$op_sha' 'cleanup coordinator hash binding'
fixed '${cleanup_id:0:16} == "$(printf '\''%016x'\'' "$epoch")"' 'cleanup epoch binding'
fixed '(.tombstone_sha256|test("^[0-9a-f]{64}$"))' 'cleanup tombstone hash gate'
fixed '.source_display_id=="00000000000000000000000000000101"' 'source binding'
fixed '.target_device_id=="00000000000000000000000000000002"' 'target binding'

fixed 'systemctl --user stop "$df_unit"; systemctl --user stop "$vf_unit"' 'ordered transient stop'
fixed 'transients_zero && return' 'zero replay adoption'
fixed '-z $(ss -H -lun "sport = :44119")' 'UDP zero gate'
fixed '-z $(ss -H -ltn "sport = :24800")' 'TCP zero gate'
fixed '! -e $SIDECAR_SOCKET' 'sidecar zero gate'
fixed '-z $(unit_prop "$vf_unit" ControlGroup' 'Viewflow cgroup zero gate'
fixed '-z $(unit_prop "$df_unit" ControlGroup' 'Deskflow cgroup zero gate'

fixed 'runtime-config-relocation-intent' 'durable config intent'
fixed 'if [[ ! -e $backup_dir && ! -L $backup_dir ]]; then' 'backup directory symlink prevalidation'
fixed 'st.st_uid!=1000 or st.st_nlink!=1' 'config owner/link-count gate'
fixed 'target!="/dev/null" or stat.S_IMODE(st.st_mode)!=0o777' 'exact mask gate'
fixed '[.entries[].backup_leaf]==["0-deskflow.service","1-viewflow-peer.service","2-deskflow.service"' 'exact backup leaves'
fixed 'os.path.isabs(leaf) or os.path.basename(leaf)!=leaf' 'backup traversal rejection'
fixed 'libc.renameat2' 'no-replace rename syscall'
fixed 'RENAME_NOREPLACE=1' 'no-replace flag'
fixed 'if os.path.lexists(source) and os.path.lexists(dest)' 'dual-name fail-closed gate'
fixed 'os.fsync(fd)' 'config parent fsync'
fixed 'runtime_config_relocation:{intent_sha256:$config,backups:$backups}' 'backup binding'

fixed '        recover_partial_handoff' 'marker-publication crash recovery call'
fixed 'validate_fresh_marker_bytes' 'partial marker byte decode'
fixed 'recover_frozen_after_collector_stop "$collector_intent"' 'collector post-stop crash recovery call'
fixed 'collector-intent.json' 'pre-stop collector intent'
fixed 'journal crosses the frozen invocation' 'exact recovered journal gate'
fixed '/usr/bin/bash "$prepare_script"' 'prepare semantic entrypoint'
fixed '/usr/bin/bash "$collector_script"' 'collector semantic entrypoint'
fixed 'deployment-quarantine-published' 'fresh publish receipt'
fixed 'viewflow-v13-marker-handoff-prepared' 'fresh H receipt'
fixed 'keys==["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256"' 'strict H keys'
fixed 'viewflow-v13-bootstrap-frozen' 'fresh B receipt'
fixed 'keys==["completed_at_unix_ms","daemon","journal","operation_id","post_stop","pre_stop","schema_version","state"]' 'strict B keys'
fixed 'keys==["boot_id","daemon_pid","daemon_sha256","daemon_start_ticks","invocation_id","operation_id","schema_version","state"]' 'strict collector intent keys'
fixed '.daemon.pid==$intent[0].daemon_pid' 'B collector-intent identity binding'
fixed 'fresh Linux frozen evidence belongs to another boot' 'current-boot B gate'
fixed 'age >= 0 && age <= 1800' 'fresh B age gate'
fixed 'viewflow-fresh-v21-bootstrap-boundary-ready' 'bridge terminal receipt'
fixed 'keys==["fresh_boundary","marker_generation","new_coordinator_instance_id","new_operation_id","old_abort","old_operation_id","retirement","runtime_config_relocation","schema_version","state"]' 'strict final receipt keys'
fixed 'if [[ -e $final_receipt || -L $final_receipt ]]; then validate_final_receipt; return; fi' 'final receipt replay validation'

fixed 'ln -- "$source" "$destination"' 'create-once publication'
fixed 'sync -f "$destination"; sync -f "$parent"' 'file/parent fsync'
fixed '$(stat -c '\''%u:%a:%h'\'' -- "$destination") == 1000:600:1' 'published metadata gate'
fixed 'strict_json "$terminal"; strict_json "$authorization"' 'strict input JSON'

cleanup_line=$(line_of '    ensure_cleanup_proof')
stop_line=$(line_of '    retire_transients')
config_line=$(line_of '    relocate_runtime_config')
handoff_line=$(line_of '    prepare_fresh_handoff')
freeze_line=$(line_of '    freeze_persistent_v13')
[[ $cleanup_line -lt $stop_line && $stop_line -lt $config_line && $config_line -lt $handoff_line && $handoff_line -lt $freeze_line ]] ||
    fail 'main transaction ordering changed'
if grep -Eq 'ssh|scp|sftp|Get-ScheduledTask' "$SOURCE"; then fail 'bridge must not contact Windows'; fi
if grep -Eq 'rm[[:space:]].*(user\.control|zz-direct-deskflow)' "$SOURCE"; then fail 'runtime config must be relocated'; fi
printf 'abort-terminal to fresh-v2.1 bridge static checker passed\n'
