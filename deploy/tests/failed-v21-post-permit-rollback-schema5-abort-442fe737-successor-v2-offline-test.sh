#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
launcher=$root/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2.sh
checker=$root/deploy/check-failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2.sh
publisher=$root/deploy/publish-failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2-approval.py
manifest=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2-manifest.json
marker=/home/wilf/.local/state/viewflow/deployment-quarantine.v1

snapshot=$(mktemp)
trap 'rm -f -- "$snapshot" "$snapshot.after"' EXIT
{
  stat -c '%n:%d:%i:%f:%u:%g:%h:%s:%Y:%Z' -- "$marker"
  sha256sum -- "$marker" "$(jq -r '.immutable_inputs.coordinator_state.path' "$manifest")"
  sha256sum -- "$(jq -r '.failed_attempt_v1.approval.path' "$manifest")"
  systemctl --user show -p ActiveState -p MainPID -- viewflow-peer.service deskflow.service || true
  for name in approval_path; do jq -r ".$name" "$manifest"; done
  jq -r '.outputs[]' "$manifest"
} >"$snapshot"

while IFS= read -r path; do [[ ! -e $path && ! -L $path ]]; done < <(tail -n 9 "$snapshot")
"$launcher" --offline-check
"$publisher" --check-only
bash "$checker"

{
  stat -c '%n:%d:%i:%f:%u:%g:%h:%s:%Y:%Z' -- "$marker"
  sha256sum -- "$marker" "$(jq -r '.immutable_inputs.coordinator_state.path' "$manifest")"
  sha256sum -- "$(jq -r '.failed_attempt_v1.approval.path' "$manifest")"
  systemctl --user show -p ActiveState -p MainPID -- viewflow-peer.service deskflow.service || true
  for name in approval_path; do jq -r ".$name" "$manifest"; done
  jq -r '.outputs[]' "$manifest"
} >"$snapshot.after"
cmp -s "$snapshot" "$snapshot.after"
while IFS= read -r path; do [[ ! -e $path && ! -L $path ]]; done < <(tail -n 9 "$snapshot.after")

echo '442fe737 schema5 abort successor-v2 offline no-mutation test passed'
