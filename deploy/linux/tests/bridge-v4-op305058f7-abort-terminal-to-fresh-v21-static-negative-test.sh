#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); readonly HERE
LINUX=$(cd -- "$HERE/.." && pwd); readonly LINUX
readonly SOURCE=$LINUX/bridge-v4-op305058f7-abort-terminal-to-fresh-v21.sh
readonly CHECKER=$LINUX/check-bridge-v4-op305058f7-abort-terminal-to-fresh-v21.sh
root=$(mktemp -d --tmpdir viewflow-v4-static-negative.XXXXXX)
trap 'rm -rf -- "$root"' EXIT

"$CHECKER" "$SOURCE" >/dev/null
count=0
reject_replace(){
    local label=$1 old=$2 new=$3 candidate
    candidate=$root/$label.sh
    /usr/bin/python3 -I - "$SOURCE" "$candidate" "$old" "$new" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text();old,new=sys.argv[3:]
if old not in source:raise SystemExit('mutation anchor missing')
Path(sys.argv[2]).write_text(source.replace(old,new))
PY
    chmod 0755 "$candidate"
    if "$CHECKER" "$candidate" >/dev/null 2>&1; then
        printf 'error: checker accepted mutation %s\n' "$label" >&2; exit 1
    fi
    count=$((count+1))
}

reject_replace terminal-state \
  viewflow-failed-pre-mutation-no-retry-vfdqa-abort-terminal \
  viewflow-failed-pre-mutation-retry-vfdqa-abort-terminal
reject_replace successor-lineage-key \
  successor_authorization_consumed \
  successor_authorization_not_consumed
reject_replace authorization-state \
  viewflow-deployment-quarantine-failed-pre-mutation-no-retry-abort-authorized \
  viewflow-deployment-quarantine-failed-pre-mutation-abort-authorized
reject_replace vfdqa-terminal-binding \
  "t['vfdqa_binary_sha256']==vfdqa_sha" \
  "isinstance(t['vfdqa_binary_sha256'],str)"
reject_replace query-replayed "q['replayed'] is not True" "q['replayed'] is False"
reject_replace query-semantic \
  "any(q[name]!=r[name] for name in receipt_keys if name!='replayed')" \
  "False"
reject_replace operation-freeze \
  'readonly V4_OPERATION=305058f7deb84c198bad4103d6c4f946' \
  'readonly V4_OPERATION=00000000000000000000000000000000'
reject_replace operation-binding \
  "[[ \$old_operation == \"\$V4_OPERATION\" ]] || die 'old operation is not the frozen 305058f7 V4 operation'" \
  '[[ $old_operation =~ ^[0-9a-f]{32}$ ]]'
reject_replace terminal-freeze \
  'readonly V4_TERMINAL_SHA=9db787bc1a59b5a8b27e7d72e6d16349295a865b1ed1adef9ea9278a557d9384' \
  'readonly V4_TERMINAL_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace approval-freeze \
  'readonly V4_EXECUTION_APPROVAL_SHA=6fe9f7d76b8a72b491a4f2898fb700a393e28c8826f90f43fb93eede24495b80' \
  'readonly V4_EXECUTION_APPROVAL_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace authorization-freeze \
  'readonly V4_AUTHORIZATION_SHA=dc7ce0350661902f3278b1e1e58ab487bb92d4953276d6160f33edd58a5ce706' \
  'readonly V4_AUTHORIZATION_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace receipt-freeze \
  'readonly V4_ABORT_RECEIPT_SHA=1022759a0e265b7097c602b70c094eb3c8b7301c0d5254f9e6dd0fd859a4b230' \
  'readonly V4_ABORT_RECEIPT_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace query-freeze \
  'readonly V4_ABORT_QUERY_RECEIPT_SHA=785fd373d20154b900a8a8f5b8fc569cb8d3fcf79f001a293cc967f6fe773506' \
  'readonly V4_ABORT_QUERY_RECEIPT_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace vfdqa-freeze \
  'readonly V4_VFDQA_SHA=092d15a05ed77874d942f44f2697043013a1c5f94350de8610dcb4f8f5b63779' \
  'readonly V4_VFDQA_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace terminal-binding \
  '[[ $terminal_sha == "$V4_TERMINAL_SHA" ]]' \
  '[[ $terminal_sha =~ ^[0-9a-f]{64}$ ]]'
reject_replace receipt-chain-binding \
  '[[ $authorization_sha == "$V4_AUTHORIZATION_SHA" && $abort_receipt_sha == "$V4_ABORT_RECEIPT_SHA" &&' \
  '[[ $authorization_sha =~ ^[0-9a-f]{64}$ && $abort_receipt_sha =~ ^[0-9a-f]{64}$ &&'
reject_replace recovery1-approval-path \
  'failed-pre-mutation-abort-305058f7-no-retry-successor1-execution-approval.json' \
  'failed-pre-mutation-abort-305058f7-no-retry-execution-approval.json'
reject_replace v4-cli-freeze \
  'readonly V4_MARKER_CLI_SHA=c237736c4d8d4db6ba6e118ac46dc083bdf3d8ae99a0b08716bc5d3206fc6c57' \
  'readonly V4_MARKER_CLI_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace provenance-freeze \
  'readonly V4_PROVENANCE_SHA=3d14ca07a7706441b461599d77f504085e490c0ce0405fdb513c022f20114533' \
  'readonly V4_PROVENANCE_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace manifest-freeze \
  'readonly V4_MANIFEST_SHA=e2131a99e698a01e96a4796144d17d82405f418f2946b6e271815975d865b35c' \
  'readonly V4_MANIFEST_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace gate-freeze \
  'readonly V4_GATE_SHA=604b513283b3c3a0173985bcdf0e42c3c0106f5f962ad225fa5f4fad6f7ad8ff' \
  'readonly V4_GATE_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace launcher-freeze \
  'readonly V4_LAUNCHER_SHA=6d24410d784393718e039e8c2da6cb096c1ac0be2814c92927c64985e1615527' \
  'readonly V4_LAUNCHER_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace v4-cli-size \
  "p['candidate']['size']==1003088" \
  "p['candidate']['size']>0"
reject_replace v4-cli-build-id \
  "p['candidate']['build_id']=='6b116abd3f6f7b33cf84deb1e404056741388685'" \
  "isinstance(p['candidate']['build_id'],str)"
reject_replace v4-frozen-source-binding \
  "p['frozen_source_root']==os.path.dirname(v4_cli_path)+'/frozen-source'" \
  'isinstance(p["frozen_source_root"],str)'
reject_replace marker-freeze \
  'readonly REVIEWED_MARKER_SHA=e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5' \
  'readonly REVIEWED_MARKER_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace marker-provenance-freeze \
  'readonly REVIEWED_MARKER_PROVENANCE_SHA=a0066c600c7f7a72292f7347eafaa702448ad216f7b91a081810876c684b19e8' \
  'readonly REVIEWED_MARKER_PROVENANCE_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace marker-main-source-freeze \
  'readonly REVIEWED_MARKER_MAIN_SOURCE_SHA=bb1a46ece72340ba85037180fd8ddebdf8d0d208458bf66a02b9e2a89378017b' \
  'readonly REVIEWED_MARKER_MAIN_SOURCE_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace marker-lib-source-freeze \
  'readonly REVIEWED_MARKER_LIB_SOURCE_SHA=d7d6fee074c3a58b257f31dd95831de55243cd9b407d020c9bb8f9a3c7524d4a' \
  'readonly REVIEWED_MARKER_LIB_SOURCE_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace marker-linux-source-freeze \
  'readonly REVIEWED_MARKER_LINUX_SOURCE_SHA=57b5b73aa63c12e95a9dec9f8c380b5927a3ac97eccac61ec4be8881843fb664' \
  'readonly REVIEWED_MARKER_LINUX_SOURCE_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace nofollow 'os.O_NOFOLLOW' '0 # O_NOFOLLOW removed'
reject_replace source-seal 'F_ADD_SEALS' 'F_GET_SEALS'
reject_replace no-replace renameat2 renameat
reject_replace locker-exec 'exec /usr/bin/env -i' '/usr/bin/env -i'
reject_replace execution-approval-binding \
  "t['execution_approval_sha256']==approval_sha" \
  "isinstance(t['execution_approval_sha256'],str)"
reject_replace abort-utc-fraction-width \
  '([0-9]{1,3})Z' \
  '([0-9]{3})Z'
reject_replace abort-utc-millisecond-binding \
  "utc_ms(value['abort_committed_at_utc'],label)!=int(value['abort_committed_at_unix_ms'])" \
  'False'
reject_replace manifest-binding "t['manifest_sha256']==manifest_sha" "isinstance(t['manifest_sha256'],str)"
reject_replace gate-binding "t['gate_sha256']==gate_sha" "isinstance(t['gate_sha256'],str)"
reject_replace launcher-binding "t['launcher_sha256']==launcher_sha" "isinstance(t['launcher_sha256'],str)"
reject_replace census 'assert_process_census "$allowed_pid"' ': # global census removed'
reject_replace killmode \
  '$(unit_prop "$VIEWFLOW_UNIT" KillMode) == control-group && $(unit_prop "$VIEWFLOW_UNIT" Restart) == on-failure' \
  '$(unit_prop "$VIEWFLOW_UNIT" KillMode) == process && $(unit_prop "$VIEWFLOW_UNIT" Restart) == on-failure'
reject_replace restart 'Restart) == on-failure' 'Restart) == always'
reject_replace prepare-cli '--deployment-marker-candidate "$marker_candidate"' '--marker "$marker_candidate"'
reject_replace collector-cli '--daemon-pid "$(jq -er' '--pid "$(jq -er'
reject_replace plan-operation-distinct \
  '.state=="viewflow-v4-inactive-terminal-to-fresh-v21-plan" and .old_operation_id==$old and
      (.new_operation_id|test("^[0-9a-f]{32}$")) and .new_operation_id!=$old' \
  '.state=="viewflow-v4-inactive-terminal-to-fresh-v21-plan" and .old_operation_id==$old and true'
reject_replace plan-coordinator-distinct \
  '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and .new_coordinator_instance_id!=$old_coord' \
  '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and true'
reject_replace fresh-root-create \
  'mkdir -- "$fresh_root"; chmod 0700 "$fresh_root"; sync -f "$DEPLOYMENTS"' \
  ': # fresh operation root creation removed'
reject_replace fresh-root-verify \
  "safe_owner_dir 'fresh operation root' \"\$fresh_root\"" \
  ': # fresh operation root verification removed'
reject_replace source-intent inactive_source_sha256 old_stopped_sha256
reject_replace final-inactive linux_initially_inactive:true linux_initially_inactive:false
reject_replace final-windows \
  'linux_initially_inactive:true,windows_old_peer_unchanged:true' \
  'linux_initially_inactive:true,windows_old_peer_unchanged:false'

printf 'V4 inactive-terminal static-negative test passed (%d mutations)\n' "$count"
