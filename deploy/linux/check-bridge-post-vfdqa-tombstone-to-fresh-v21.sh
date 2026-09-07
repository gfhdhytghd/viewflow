#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
readonly SOURCE=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bridge-post-vfdqa-tombstone-to-fresh-v21.sh}
fail(){ printf 'error: post-VFDQA bridge checker: %s\n' "$*" >&2; exit 1; }
fixed(){ awk -v token="$1" '!/^[[:space:]]*#/&&index($0,token){found=1} END{exit !found}' "$SOURCE" || fail "missing $2"; }
line(){ awk '!/^[[:space:]]*#/{print NR ":" $0}' "$SOURCE" | grep -F -- "$1" | tail -n1 | cut -d: -f1; }
body_fixed(){
 local function_name=$1 token=$2 label=$3
 awk -v start="${function_name}(){" -v token="$token" 'index($0,start)==1{inside=1} inside&&!/^[[:space:]]*#/&&index($0,token){found=1} inside&&/^}$/{exit} END{exit !found}' "$SOURCE" || fail "missing executable $label in $function_name"
}
body_not_noop(){
 local function_name=$1
 if awk -v start="${function_name}(){" 'index($0,start)==1{inside=1} inside&&!/^[[:space:]]*#/&&$0~/^[[:space:]]*return[[:space:]]+0([[:space:];]|$)/{found=1} inside&&/^}$/{exit} END{exit !found}' "$SOURCE"; then fail "$function_name can return success without validation"; fi
}
[[ -f $SOURCE && ! -L $SOURCE ]] || fail 'source must be regular non-symlink'; bash -n "$SOURCE"
fixed 'viewflow-post-vfdqa-incident-terminal-reconciliation-required' 'incident state'
fixed 'INVALID_AUTHZ_PROVENANCE_TOMBSTONE' 'tombstone state'
fixed '.abort_physically_committed==true' 'incident physical-abort key'
fixed '.physical_abort_committed==true' 'tombstone physical-abort key'
fixed 'historical-invalidity-proof-only-never-authority' 'old authorization non-authority'
fixed 'VFDQA001' '384-byte VFDQA validation'; fixed 'len(b)!=384' 'VFDQA size'; fixed 'hashlib.sha256(b[:352]).digest()!=b[352:384]' 'VFDQA checksum'
fixed 'viewflow-post-vfdqa-replay6-reconciliation-manifest' 'reconciliation manifest'
fixed 'viewflow-post-vfdqa-windows-census' 'Windows census'; fixed 'CURRENT_RUNTIME_REATTESTED' 'Linux inventory'
fixed 'viewflow-windows-ssh-raw-census' 'raw Windows census'; fixed 'viewflow-post-vfdqa-windows-legacy-disposition' 'Windows disposition'
fixed '$bridge_root/evidence/windows-ssh-raw-census.json' 'fixed raw census path'; fixed '$bridge_root/evidence/windows-legacy-disposition.json' 'fixed disposition path'
fixed '$bridge_root/evidence/windows-legacy-census-transport-upgrade.v1.json' 'fixed transport-upgrade path'
fixed '$bridge_root/evidence/windows-legacy-census-stderr-classification.v1.json' 'fixed stderr-classification path'
fixed 'viewflow-post-vfdqa-windows-legacy-census-transport-upgrade' 'transport-upgrade schema'
fixed 'viewflow-post-vfdqa-windows-legacy-census-stderr-classification' 'stderr-classification schema'
fixed 'ssh-powershell-encodedcommand-exact-length-raw-files-v2' 'exact-length transport'
fixed "if upgrade_sha=='none':" 'fresh/upgraded evidence union'
fixed "if stderr or disp['stderr_classification_sha256']!='none'" 'fresh empty-stderr/no-classification binding'
fixed "upgrade['old_intent']=={'path':intent_path,'sha256':sha(intent_bytes)}" 'upgrade-to-intent binding'
fixed "classification['raw_census_sha256']==raw_expected" 'classification-to-raw binding'
fixed "disp['raw_census_sha256']==raw_expected" 'disposition-to-raw binding'
fixed 'windows_transport_upgrade:{path:$upgrade_path,sha256:$upgrade_sha}' 'plan transport-upgrade binding'
fixed 'windows_stderr_classification:{path:$classification_path,sha256:$classification_sha}' 'plan stderr-classification binding'
fixed 'transport_upgrade:{path:$upgrade_path,sha256:$upgrade_sha}' 'final transport-upgrade binding'
fixed 'stderr_classification:{path:$classification_path,sha256:$classification_sha}' 'final stderr-classification binding'
fixed "disp['action']=='preserve-and-quarantine-no-mutation'" 'no-mutation disposition'; fixed '.fresh_bridge_ready==false' 'Windows not-ready boundary'
fixed 'uuidgen | tr -d' 'fresh operation ID'; fixed 'new_operation_id!=$old' 'operation non-reuse'; fixed 'new_coordinator_instance_id' 'fresh coordinator'
fixed 'viewflow-post-vfdqa-tombstone-to-fresh-v21-transition-plan' 'immutable plan'
fixed 'process_ticks' 'PID ticks'; fixed 'InvocationID' 'invocation'; fixed 'cgroup PID-set drifted' 'cgroup set'; fixed '/proc/$pid/exe' 'executable binding'
body_fixed validate_live_tuple '/proc/sys/kernel/random/boot_id' 'current boot-ID gate'
fixed '--viewflow-acceptance-query status' 'sidecar status'; fixed '--viewflow-acceptance-query arm' 'sidecar arm'; fixed '--viewflow-acceptance-query cleanup' 'cleanup receipt'
fixed 'ReleaseAll Applied' 'release-all'; fixed 'no-active-route' 'no-route'; fixed 'VFQST002' 'runtime marker zero'
fixed 'systemctl --user stop "$du"; systemctl --user stop "$vu"' 'Deskflow-first retirement'
fixed "sport = :44119" 'UDP listener zero'; fixed "sport = :24800" 'TCP listener zero'; fixed '! -e $SIDECAR_SOCKET' 'socket zero'
fixed 'CONFIG_PATHS=(' 'five config inputs'; fixed 'RENAME_NOREPLACE=1' 'no-replace rename'; fixed 'os.path.lexists(src) and os.path.lexists(dst)' 'partial move dual-name rejection'
fixed 'st.st_uid!=1000 or st.st_nlink!=1' 'owner/link gate'; fixed "data!=b'/dev/null'" 'exact mask gate'; fixed 'os.fsync(fd)' 'fsync'
fixed 'os.O_NOFOLLOW' 'nofollow'; fixed 's.st_nlink==1' 'receipt single-link'; fixed 'create-once receipt exists' 'create-once'
fixed 'viewflow-v13-marker-handoff-prepared' 'fresh H'; fixed 'viewflow-v13-bootstrap-frozen' 'fresh B'
fixed 'snapshot_source' 'sealed execution snapshots'; fixed 'source_dev' 'source inode binding'; fixed 'source_mode' 'source mode binding'; fixed 'snapshot_sha256' 'snapshot hash binding'
body_fixed safe_source '8#022' 'non-writable source mode gate'
body_fixed run_prepare_snapshot "os.execve('/usr/bin/bash'" 'verified-fd prepare execution'
body_fixed run_prepare_snapshot "os.O_NOFOLLOW" 'nofollow prepare snapshot open'
body_fixed run_collector_snapshot "os.execve('/usr/bin/bash'" 'verified-fd collector execution'
body_fixed run_collector_snapshot "os.O_NOFOLLOW" 'nofollow collector snapshot open'
body_fixed validate_plan '.new_operation_id!=$old' 'fresh operation rejection'
body_fixed validate_plan '.new_coordinator_instance_id!=$oldc' 'fresh coordinator rejection'
body_fixed validate_plan 'source_ino:$mi' 'original source inode validation'
body_fixed validate_windows_transport "exact(raw,['schema_version','state','operation_id'" 'raw exact schema validation'
body_fixed validate_windows_transport "exact(upgrade,['schema_version','state','old_operation_id'" 'upgrade exact schema validation'
body_fixed validate_windows_transport "exact(classification,['schema_version','state','old_operation_id'" 'classification exact schema validation'
body_fixed validate_windows_transport "exact(disp,['schema_version','state','old_operation_id'" 'disposition exact schema validation'
fixed 'recover_partial_handoff' 'marker/H crash recovery'; body_fixed recover_partial_handoff 'validate_fresh_marker_bytes' 'exact marker recovery gate'
fixed 'recover_frozen_after_collector_stop' 'collector-stop/B crash recovery'; body_fixed recover_frozen_after_collector_stop 'collector recovery journal crosses invocation' 'same invocation journal gate'
fixed 'validate_cleanup_proof' 'cleanup resume deep validation'; body_fixed validate_cleanup_proof 'cleanup receipt cross-hash differs' 'cleanup nested cross-hash'
fixed 'validate_final_receipt' 'final resume deep validation'; body_fixed validate_final_receipt 'final receipt exact schema/cross-binding differs' 'final exact keys and hashes'
for function_name in validate_windows_transport validate_plan recover_partial_handoff recover_frozen_after_collector_stop validate_cleanup_proof validate_final_receipt run_prepare_snapshot run_collector_snapshot; do body_not_noop "$function_name"; done
fixed 'viewflow-post-vfdqa-linux-fresh-v21-bootstrap-boundary-ready' 'Linux-only final boundary'
cleanup=$(line 'make_plan; ensure_cleanup'); stop=$(line 'retire_transients; relocate_config'); fresh=$(line 'relocate_config; fresh_chain'); final=$(line 'fresh_chain; publish_final')
[[ $cleanup -eq $stop && $stop -eq $fresh && $fresh -eq $final ]] || fail 'main ordering anchor changed'
if grep -Eq '(^|[;&|])[[:space:]]*(/usr/bin/)?(ssh|scp|sftp)[[:space:]]|Get-ScheduledTask' "$SOURCE"; then fail 'bridge must not contact Windows'; fi
if grep -Fq 'bridge-abort-terminal-to-fresh-v21.sh' "$SOURCE"; then fail 'bridge must remain independent'; fi
printf 'post-VFDQA tombstone to fresh-v2.1 bridge checker passed\n'
