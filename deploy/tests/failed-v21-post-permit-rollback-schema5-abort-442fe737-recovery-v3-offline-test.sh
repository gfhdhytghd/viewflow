#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
manifest=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-manifest.json
launcher=$root/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh
publisher=$root/deploy/publish-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-approval.py
checker=$root/deploy/check-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh
before=$(mktemp)
after=$before.after
trap 'rm -f -- "$before" "$after"' EXIT

snapshot() {
  jq -r '.predecessor_v2[].path,.committed_v1_outputs[].path,
    .post_abort.durable_vfdqa.path,.post_abort.retired_claim.path' "$manifest" |
    while IFS= read -r path; do stat -c '%n:%d:%i:%f:%u:%g:%h:%s:%Y:%Z' "$path"; sha256sum "$path"; done
  jq -r '.post_abort.public_absent[],.required_absent[]' "$manifest" |
    while IFS= read -r path; do
      if [[ -e $path || -L $path ]]; then echo "PRESENT:$path"; else echo "ABSENT:$path"; fi
    done
  systemctl --user show -p ActiveState -p MainPID -- \
    viewflow-v13-recovery-442fe737e67f43b89d85a7e33149a072.service \
    deskflow-v13-recovery-442fe737e67f43b89d85a7e33149a072.service
}

snapshot >"$before"
! grep -Fq 'PRESENT:' "$before"
"$launcher" --offline-check
"$publisher" --check-only
bash "$checker"
snapshot >"$after"
cmp -s "$before" "$after"
! grep -Fq 'PRESENT:' "$after"
echo '442fe737 schema5 abort recovery-v3 offline no-mutation test passed'
