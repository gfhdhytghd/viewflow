#!/usr/bin/env bash
set -Eeuo pipefail
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly LINUX=$(cd -- "$HERE/.." && pwd); readonly SOURCE=$LINUX/bridge-post-vfdqa-tombstone-to-fresh-v21.sh; readonly CHECKER=$LINUX/check-bridge-post-vfdqa-tombstone-to-fresh-v21.sh
temps=(); trap 'rm -f -- "${temps[@]}"' EXIT
bash "$CHECKER" "$SOURCE" >/dev/null
reject(){ local label=$1 from=$2 to=$3 candidate; candidate=$(mktemp --tmpdir viewflow-post-vfdqa-negative.XXXXXX); temps+=("$candidate"); python3 - "$SOURCE" "$candidate" "$from" "$to" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(); old=sys.argv[3]
if s.count(old)<1: raise SystemExit('anchor absent')
pathlib.Path(sys.argv[2]).write_text(s.replace(old,sys.argv[4]))
PY
if bash "$CHECKER" "$candidate" >/dev/null 2>&1; then echo "error: accepted mutation: $label" >&2; exit 1; fi; }
reject_noop(){ local function_name=$1 candidate; candidate=$(mktemp --tmpdir viewflow-post-vfdqa-negative.XXXXXX); temps+=("$candidate"); python3 - "$SOURCE" "$candidate" "$function_name" <<'PY'
import pathlib,re,sys
source,out,name=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3]
text=source.read_text(); match=re.search(rf'(?ms)^{re.escape(name)}\(\)\{{.*?^\}}$',text)
if not match: raise SystemExit('function anchor absent: '+name)
anchors='\n'.join('# '+line for line in match.group(0).splitlines()[1:-1] if line.strip())
out.write_text(text[:match.start()]+name+'(){\n return 0\n'+anchors+'\n}'+text[match.end():])
PY
if bash "$CHECKER" "$candidate" >/dev/null 2>&1; then echo "error: accepted no-op/comment-preserve mutation: $function_name" >&2; exit 1; fi; }
reject incident-state viewflow-post-vfdqa-incident-terminal-reconciliation-required viewflow-normal-terminal
reject tombstone-state INVALID_AUTHZ_PROVENANCE_TOMBSTONE NORMAL_AUTHORIZATION
reject old-auth-role historical-invalidity-proof-only-never-authority historical-authorization
reject vfdqa-magic VFDQA001 VFDQX001
reject raw-state viewflow-windows-ssh-raw-census viewflow-windows-census
reject exact-transport ssh-powershell-encodedcommand-exact-length-raw-files-v2 ssh-powershell-raw-v1
reject upgrade-state viewflow-post-vfdqa-windows-legacy-census-transport-upgrade viewflow-transport-unbound
reject classification-state viewflow-post-vfdqa-windows-legacy-census-stderr-classification viewflow-stderr-unbound
reject fresh-union "if upgrade_sha=='none':" "if False:"
reject fresh-empty-stderr "if stderr or disp['stderr_classification_sha256']!='none'" "if False"
reject upgrade-intent-binding "upgrade['old_intent']=={'path':intent_path,'sha256':sha(intent_bytes)}" "upgrade['old_intent']['path']==intent_path"
reject classification-raw-binding "classification['raw_census_sha256']==raw_expected" "hex64(classification['raw_census_sha256'])"
reject disposition-raw-binding "disp['raw_census_sha256']==raw_expected" "hex64(disp['raw_census_sha256'])"
reject plan-upgrade-binding 'windows_transport_upgrade:{path:$upgrade_path,sha256:$upgrade_sha}' 'windows_transport_upgrade:{path:$upgrade_path}'
reject plan-classification-binding 'windows_stderr_classification:{path:$classification_path,sha256:$classification_sha}' 'windows_stderr_classification:{path:$classification_path}'
reject final-upgrade-binding 'transport_upgrade:{path:$upgrade_path,sha256:$upgrade_sha}' 'transport_upgrade:{path:$upgrade_path}'
reject final-classification-binding 'stderr_classification:{path:$classification_path,sha256:$classification_sha}' 'stderr_classification:{path:$classification_path}'
reject disposition-action "disp['action']=='preserve-and-quarantine-no-mutation'" "disp['action']=='remediate'"
reject windows-ready '.fresh_bridge_ready==false' '.fresh_bridge_ready==true'
reject stop-order 'stop "$du"; systemctl --user stop "$vu"' 'stop "$vu"; systemctl --user stop "$du"'
reject no-replace RENAME_NOREPLACE=1 RENAME_NOREPLACE=0
reject hardlink 'st.st_uid!=1000 or st.st_nlink!=1' 'st.st_uid!=1000'
reject mask "data!=b'/dev/null'" "data!=b'/tmp/not-null'"
reject marker-recovery 'recover_partial_handoff' 'manual_partial_handoff'
reject marker-bytes 'validate_fresh_marker_bytes' 'trust_fresh_marker_bytes'
reject collector-recovery 'recover_frozen_after_collector_stop' 'manual_frozen_after_collector_stop'
reject collector-journal 'collector recovery journal crosses invocation' 'collector recovery journal unchecked'
reject cleanup-resume 'validate_cleanup_proof' 'trust_cleanup_proof'
reject cleanup-cross-hash 'cleanup receipt cross-hash differs' 'cleanup receipt hash unchecked'
reject final-resume 'validate_final_receipt' 'trust_final_receipt'
reject final-cross-hash 'final receipt exact schema/cross-binding differs' 'final receipt schema unchecked'
reject final-boundary viewflow-post-vfdqa-linux-fresh-v21-bootstrap-boundary-ready viewflow-normal-success
reject boot-gate '/proc/sys/kernel/random/boot_id' '/tmp/assume-same-boot'
for function_name in validate_windows_transport validate_plan recover_partial_handoff recover_frozen_after_collector_stop validate_cleanup_proof validate_final_receipt run_prepare_snapshot run_collector_snapshot; do reject_noop "$function_name"; done
printf 'post-VFDQA tombstone static-negative mutations passed\n'
