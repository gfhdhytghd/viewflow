#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); readonly HERE
LINUX=$(cd -- "$HERE/.." && pwd); readonly LINUX
readonly SOURCE=$LINUX/bridge-v4-inactive-terminal-to-fresh-v21.sh
readonly CHECKER=$LINUX/check-bridge-v4-inactive-terminal-to-fresh-v21.sh
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
Path(sys.argv[2]).write_text(source.replace(old,new,1))
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
  'readonly V4_OPERATION=83fa3121bcb645e5847db05cc8cd5250' \
  'readonly V4_OPERATION=00000000000000000000000000000000'
reject_replace v4-cli-freeze \
  'readonly V4_MARKER_CLI_SHA=c237736c4d8d4db6ba6e118ac46dc083bdf3d8ae99a0b08716bc5d3206fc6c57' \
  'readonly V4_MARKER_CLI_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace provenance-freeze \
  'readonly V4_PROVENANCE_SHA=f3023dd53acade01874af56a22fda0be126fd3bdb8160d9a471cc17cd320b7bd' \
  'readonly V4_PROVENANCE_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace manifest-freeze \
  'readonly V4_MANIFEST_SHA=8a13bf6f5df4fb6cc6fb36e4a0d7a6be65d787a358a0259d360862e8ac62cf11' \
  'readonly V4_MANIFEST_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace gate-freeze \
  'readonly V4_GATE_SHA=e2c0f4a2968bfb9f23fe224d1f9ec815c22ce1bb953151a55c4d44c166087a29' \
  'readonly V4_GATE_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace launcher-freeze \
  'readonly V4_LAUNCHER_SHA=a23dba7212fab71b50d9d4508d2ee1e834af87495a65bcae059b0a4208fcd9d1' \
  'readonly V4_LAUNCHER_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace v4-cli-size \
  "p['candidate']['size']==1003088" \
  "p['candidate']['size']>0"
reject_replace v4-cli-build-id \
  "p['candidate']['build_id']=='6b116abd3f6f7b33cf84deb1e404056741388685'" \
  "isinstance(p['candidate']['build_id'],str)"
reject_replace marker-freeze \
  'readonly REVIEWED_MARKER_SHA=8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54' \
  'readonly REVIEWED_MARKER_SHA=0000000000000000000000000000000000000000000000000000000000000000'
reject_replace nofollow 'os.O_NOFOLLOW' '0 # O_NOFOLLOW removed'
reject_replace source-seal 'F_ADD_SEALS' 'F_GET_SEALS'
reject_replace no-replace renameat2 renameat
reject_replace locker-exec 'exec /usr/bin/env -i' '/usr/bin/env -i'
reject_replace execution-approval-binding \
  "t['execution_approval_sha256']==approval_sha" \
  "isinstance(t['execution_approval_sha256'],str)"
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
