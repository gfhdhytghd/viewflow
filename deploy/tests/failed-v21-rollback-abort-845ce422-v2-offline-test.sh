#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
launcher=$root/deploy/launch-failed-v21-rollback-abort-845ce422-v2.sh
publisher=$root/deploy/publish-failed-v21-rollback-abort-845ce422-v2-approval.py
op=845ce4223e4f426a8a0015d3355595e8

before=$(find /home/wilf/.local/state/viewflow/deployments/$op -maxdepth 1 -name 'failed-v21-rollback-abort-845ce422-v2-*' -printf '%f\n' | sort)
"$launcher" --offline-check
"$publisher" --check-only
after=$(find /home/wilf/.local/state/viewflow/deployments/$op -maxdepth 1 -name 'failed-v21-rollback-abort-845ce422-v2-*' -printf '%f\n' | sort)
[[ $before == "$after" ]]
[[ ! -e /home/wilf/.local/state/viewflow/deployments/$op/failed-v21-rollback-abort-845ce422-v2-execution-approval.json ]]
echo '845ce422 abort v2 offline sealed-chain test passed; no SSH or write'
