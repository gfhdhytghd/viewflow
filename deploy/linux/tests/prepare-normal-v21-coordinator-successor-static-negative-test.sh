#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
src=$repo/deploy/linux/prepare-normal-v21-coordinator-successor.sh
check=$repo/deploy/linux/check-prepare-normal-v21-coordinator-successor.sh
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
mutate() {
    local name=$1 old=$2 new=$3
    local f=$tmp/$name.sh
    cp -- "$src" "$f"
    python3 - "$f" "$old" "$new" <<'PY'
import sys
p,o,n=sys.argv[1:];s=open(p).read();assert o in s,(p,o);open(p,'w').write(s.replace(o,n,1))
PY
    if "$check" "$f" >/dev/null 2>&1; then echo "checker accepted mutation: $name" >&2; exit 1; fi
}
mutate hostkey 'StrictHostKeyChecking=yes' 'StrictHostKeyChecking=no'
mutate batch 'BatchMode=yes' 'BatchMode=no'
mutate task-export 'Export-ScheduledTask' 'Get-ScheduledTaskInfo'
mutate task-export-catch '$x=Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath;' '$x=""; try{$x=Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath}catch{};'
mutate process-census 'Get-CimInstance Win32_Process' 'Get-Process'
mutate receipt-leaf 'coordinator-successor-receipt.json' 'successor.json'
mutate terminal-leaf 'candidate-retirement-terminal.json' 'retirement-terminal.json'
mutate marker-coord 'data[176:192]==uuid.UUID(COORD).bytes' 'True'
mutate marker-generation 'int.from_bytes(data[200:208],"little")==1' 'True'
mutate alias-kind 'marker-cli-path-alias-same-bytes-v1' 'marker-cli-any-bytes-v1'
mutate release-claim 'deployment-quarantine.v1.release-claim' 'release-claim'
mutate abort-receipt '.deployment-quarantine.v1.abort-receipt.' '.abort-receipt.'
mutate provenance 'successor provenance does not bind coordinator bytes' 'successor metadata differs'
mutate producer-provenance 'successor provenance does not bind receipt producer bytes' 'producer metadata differs'
mutate archive-call 'verify_retired_archive(t)' 'pass # verify retired archive'
mutate intent-close 'intent.get("terminal_receipt")==t' 'True'
mutate tmpfile 'os.O_TMPFILE' 'os.O_CREAT'
mutate linkat 'AT_EMPTY_PATH' 'AT_SYMLINK_FOLLOW'
mutate state-leaf 'coordinator-state.json.recovery-bundle.json' 'coordinator-state.recovery-bundle.json'
mutate backup-leaf 'linux-stage.json.backup' 'linux-stage.backup'
mutate proof-order 'collected=ps_collect()' 'collected={"operation_root_present":False,"operation_bound_tasks":[],"operation_bound_processes":[]}'
mutate execute-fresh 'req(not have_w and not have_r,"execute requires fresh successor outputs")' 'pass # freshness bypass'
mutate resume-state 'req(have_w and not have_r,"resume requires Windows prestate and no receipt")' 'pass # resume bypass'
mutate resume-recheck $'if MODE=="--resume":\n        ps_collect()' $'if MODE=="--resume":\n        pass # remote recheck bypass'
echo 'coordinator successor static negative tests passed'
