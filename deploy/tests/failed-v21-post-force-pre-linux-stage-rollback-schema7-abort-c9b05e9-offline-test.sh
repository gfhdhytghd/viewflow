#!/usr/bin/env bash
set -euo pipefail
root=/home/wilf/data/viewflow
stem=failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9
manifest=$root/deploy/$stem-manifest.json
launcher=$root/deploy/launch-$stem.sh
checker=$root/deploy/check-$stem.sh
publisher=$root/deploy/publish-$stem-approval.py
marker=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
before=$(mktemp); after=$(mktemp)
trap 'rm -f -- "$before" "$after"' EXIT

snapshot() {
  stat -c '%n:%d:%i:%f:%u:%g:%h:%s:%Y:%Z' -- "$marker"
  sha256sum -- "$marker" "$(jq -r '.immutable_inputs.coordinator_state.path' "$manifest")"
  systemctl --user show -p ActiveState -p MainPID -- viewflow-peer.service deskflow.service || true
  jq -r '.approval_path,.outputs[]' "$manifest"
}
snapshot >"$before"
while IFS= read -r path; do [[ ! -e $path && ! -L $path ]]; done < <(jq -r '.approval_path,.outputs[]' "$manifest")
"$launcher" --offline-check
"$publisher" --check-only
bash "$checker"
snapshot >"$after"
cmp -s "$before" "$after"
while IFS= read -r path; do [[ ! -e $path && ! -L $path ]]; done < <(jq -r '.approval_path,.outputs[]' "$manifest")
echo 'c9b05e9 schema7 abort offline no-mutation test passed'
