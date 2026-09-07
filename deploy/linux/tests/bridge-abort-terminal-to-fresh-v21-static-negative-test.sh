#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2155
set -Eeuo pipefail
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly LINUX=$(cd -- "$HERE/.." && pwd)
readonly SOURCE=$LINUX/bridge-abort-terminal-to-fresh-v21.sh
readonly CHECKER=$LINUX/check-bridge-abort-terminal-to-fresh-v21.sh
temporary=()
cleanup() { local p; for p in "${temporary[@]}"; do rm -f -- "$p"; done; }
trap cleanup EXIT
bash "$CHECKER" "$SOURCE" >/dev/null
mutate_rejected() {
    local label=$1 from=$2 to=$3 candidate
    candidate=$(mktemp --tmpdir 'viewflow-bridge-negative.XXXXXX'); temporary+=("$candidate")
    python3 - "$SOURCE" "$candidate" "$from" "$to" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(); old=sys.argv[3]
if s.count(old)!=1: raise SystemExit("mutation anchor not exact-once")
pathlib.Path(sys.argv[2]).write_text(s.replace(old,sys.argv[4],1))
PY
    chmod +x "$candidate"
    if bash "$CHECKER" "$candidate" >/dev/null 2>&1; then printf 'error: accepted mutation: %s\n' "$label" >&2; exit 1; fi
}
mutate_rejected vfdqa-magic VFDQA001 VFDQX001
mutate_rejected vfdqa-protocol 'bytes((1,1,1,3,1))' 'bytes((1,1,2,1,1))'
mutate_rejected terminal-schema 'schema_version == 2 and .state' 'schema_version >= 1 and .state'
mutate_rejected rollback-truth '.rollback_performed == false' '.rollback_performed | type == "boolean"'
mutate_rejected release-all-query '--viewflow-acceptance-query cleanup' '--viewflow-acceptance-query status'
mutate_rejected stale-cleanup-receipt '.receipt_available==false' '(.receipt_available|type=="boolean")'
mutate_rejected cleanup-ack '.acknowledged==true' '(.acknowledged|type=="boolean")'
mutate_rejected stop-order 'stop "$df_unit"; systemctl --user stop "$vf_unit"' 'stop "$vf_unit"; systemctl --user stop "$df_unit"'
mutate_rejected no-replace 'RENAME_NOREPLACE=1' 'RENAME_NOREPLACE=0'
mutate_rejected config-owner 'st.st_uid!=1000 or st.st_nlink!=1' 'st.st_nlink!=1'
mutate_rejected backup-traversal 'os.path.isabs(leaf) or os.path.basename(leaf)!=leaf' 'os.path.basename(leaf)!=leaf'
mutate_rejected backup-dir-prevalidation 'if [[ ! -e $backup_dir && ! -L $backup_dir ]]; then' 'if [[ ! -e $backup_dir ]]; then'
mutate_rejected operation-reuse 'new_operation_id!=$old' '(.new_operation_id|length)==32'
mutate_rejected coordinator-reuse '.new_coordinator_instance_id!=$old_coordinator' '(.new_coordinator_instance_id|length)==36'
mutate_rejected cleanup-epoch '${cleanup_id:0:16} == "$(printf '\''%016x'\'' "$epoch")"' '${cleanup_id:0:16} != 0000000000000000'
mutate_rejected handoff-keys 'keys==["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256"' '([.coordinator_instance_id]|length)==1 and ["deployment_marker_path","deployment_marker_sha256"'
mutate_rejected frozen-intent '.daemon.pid==$intent[0].daemon_pid' '(.daemon.pid|type)=="number"'
mutate_rejected frozen-current-boot 'fresh Linux frozen evidence belongs to another boot' 'fresh Linux frozen evidence boot unchecked'
mutate_rejected collector-recovery 'recover_frozen_after_collector_stop "$collector_intent"' 'manual_frozen_after_collector_stop "$collector_intent"'
mutate_rejected marker-recovery '        recover_partial_handoff' '        manual_partial_handoff'
mutate_rejected final-replay-validation 'then validate_final_receipt; return; fi' 'then return; fi # final receipt unchecked'
printf 'abort-terminal to fresh-v2.1 bridge negative mutations passed\n'
