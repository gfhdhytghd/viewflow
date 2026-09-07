#!/usr/bin/env bash

# Offline exact nested-key fixture for Windows bootstrap prepared receipt P.

# shellcheck disable=SC1091
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
source "$SCRIPT_DIR/../bootstrap-two-phase-common.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
path=$tmp_dir/P.json
op=bootstrap-prepared-fixture
sid=S-1-5-21-1000
request=$(printf '1%.0s' {1..64})
handoff=$(printf '2%.0s' {1..64})
linux=$(printf '3%.0s' {1..64})
candidate=$(printf '4%.0s' {1..64})
hash=$(printf 'a%.0s' {1..64})

write_valid() {
    jq -cn --arg op "$op" --arg sid "$sid" --arg request "$request" --arg handoff "$handoff" \
        --arg linux "$linux" --arg candidate "$candidate" --arg hash "$hash" '
        {schema_version:1,state:"viewflow-windows-bootstrap-recovery-armed",rollback_mode:"bootstrap-v1.3",
         operation_id:$op,user_sid:$sid,bootstrap_request_sha256:$request,
         marker_handoff_receipt:{path:"C:\\Viewflow\\H.json",sha256:$handoff},
         linux_frozen_evidence_sha256:$linux,candidate:{path:"C:\\Viewflow\\viewflowd.exe",sha256:$candidate},
         wrapper:{source_path:"C:\\Viewflow\\wrapper.ps1",installed_path:"C:\\Viewflow\\installed.ps1",sha256:$hash},
         rollback_script:{path:"C:\\Viewflow\\rollback.ps1",sha256:$hash},
         rollback_authorization:{manifest_path:"C:\\Viewflow\\manifest.json",manifest_sha256:$hash,
                                 token_path:"C:\\Viewflow\\token.json",token_sha256:$hash},
         old_task:{name:"\\Viewflow Peer",state:"Running",xml_backup_path:"C:\\Viewflow\\task.xml",xml_sha256:$hash},
         old_executable:{path:"C:\\Viewflow\\old.exe",sha256:$hash,process_id:42,
                         process_start_filetime:"100",session_id:1,owner_sid:$sid},
         outputs:{mutation_permit_path:"C:\\Viewflow\\permit.json",force_release_receipt_path:"C:\\Viewflow\\F.json",
                  force_release_envelope_path:"C:\\Viewflow\\Fe.json",linux_stage_receipt_path:"C:\\Viewflow\\Ls.json",
                  readiness_receipt_path:"C:\\Viewflow\\R.json",readiness_lock_path:"C:\\Viewflow\\lock.json",
                  readiness_commit_request_path:"C:\\Viewflow\\commit.json",install_success_receipt_path:"C:\\Viewflow\\W.json",
                  recovery_bundle_path:"C:\\Viewflow\\bundle.json",linux_deactivation_proof_path:"C:\\Viewflow\\proof.json",
                  linux_deactivation_transcript_path:"C:\\Viewflow\\transcript.json",
                  recovery_force_release_receipt_path:"C:\\Viewflow\\RF.json",installer_exit_receipt_path:"C:\\Viewflow\\exit.json"},
         prepared_at_utc:"2026-08-29T12:00:00.000Z"}' >"$path"
    chmod 0600 "$path"
}

validate() {
    validate_windows_prepared_receipt "$path" "$op" "$request" "$handoff" "$linux" "$candidate" "$sid"
}
write_valid
validate

expect_rejected() {
    local name=$1 filter=$2
    cp -- "$path" "$tmp_dir/base.json"
    jq "$filter" "$tmp_dir/base.json" >"$path"
    chmod 0600 "$path"
    if (validate >/dev/null 2>&1); then die "prepared nested mutation accepted: $name"; fi
    mv -- "$tmp_dir/base.json" "$path"
}

expect_rejected marker-extra '.marker_handoff_receipt.extra = true'
expect_rejected candidate-missing 'del(.candidate.path)'
expect_rejected wrapper-extra '.wrapper.extra = true'
expect_rejected rollback-script-extra '.rollback_script.extra = true'
expect_rejected rollback-auth-missing 'del(.rollback_authorization.token_path)'
expect_rejected old-task-extra '.old_task.extra = true'
expect_rejected old-executable-extra '.old_executable.extra = true'
expect_rejected outputs-extra '.outputs.extra = "C:\\Viewflow\\extra"'
expect_rejected uppercase-nested-hash '.wrapper.sha256 |= ascii_upcase'

printf '%s\n' 'bootstrap prepared nested schema fixture tests passed'
