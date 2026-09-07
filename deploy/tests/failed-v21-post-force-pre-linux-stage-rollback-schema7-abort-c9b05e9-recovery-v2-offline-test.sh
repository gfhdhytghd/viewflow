#!/usr/bin/env bash
set -euo pipefail
root=/home/wilf/data/viewflow
stem=failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2
approval=/home/wilf/.local/state/viewflow/deployments/c9b05e9bea4140d69f9d137a0f992ba0/$stem-execution-approval.json
[[ ! -e $approval && ! -L $approval ]]
bash "$root/deploy/check-$stem.sh"
python3 "$root/deploy/tests/$stem-hermetic.py"
[[ ! -e $approval && ! -L $approval ]]
while IFS= read -r p; do [[ ! -e $p && ! -L $p ]]; done < <(jq -r '.outputs[]' "$root/deploy/$stem-manifest.json")
echo 'c9b05e9 committed-abort recovery-v2 offline no-mutation test passed'
