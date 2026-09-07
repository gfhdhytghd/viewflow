#!/usr/bin/env bash

# Offline exact-union fixture for pre-release generation 1 and recovery generation 2.

# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
# shellcheck source=../bootstrap-two-phase-common.sh
source "$SCRIPT_DIR/../bootstrap-two-phase-common.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
chmod 0700 "$tmp_dir"
helper=$tmp_dir/active-marker-function.sh
awk '/^validate_active_recovery_marker\(\) \{/{copy=1} /^on_failure\(\) \{/{copy=0} copy{print}' \
    "$SCRIPT_DIR/../bootstrap-finalize-viewflow-deskflow.sh" >"$helper"
grep -Fq 'validate_active_recovery_marker() {' "$helper" || die 'active marker helper extraction failed'
# shellcheck source=/dev/null
source "$helper"

assert_both_units_stopped() { :; }
assert_marker_unchanged() { :; }

operation_id=bootstrap-marker-fixture
recovery_operation_id=recovery-marker-fixture
source_display_id=11111111111111111111111111111111
target_device_id=22222222222222222222222222222222
coordinator_instance_id=33333333333333333333333333333333
recovery_coordinator_id=44444444444444444444444444444444
marker_generation=1
gen1_sha=$(printf 'a%.0s' {1..64})
gen2_sha=$(printf 'b%.0s' {1..64})
stage_receipt=$tmp_dir/stage.json
printf '{"marker":{"sha256":"%s"}}\n' "$gen1_sha" >"$stage_receipt"
chmod 0600 "$stage_receipt"
publish_receipt=$tmp_dir/publish-gen1.json
publish2=$tmp_dir/publish-gen2.json

hyphenate() { sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/' <<<"$1"; }
write_publish() {
    local path=$1 op=$2 coordinator=$3 generation=$4 marker_sha=$5
    jq -cn --arg op "$op" --arg source "$(hyphenate "$source_display_id")" \
        --arg target "$(hyphenate "$target_device_id")" --arg coordinator "$(hyphenate "$coordinator")" \
        --arg generation "$generation" --arg marker "$marker_sha" --arg marker_path "$DEPLOYMENT_MARKER" \
        '{schema_version:1,state:"deployment-quarantine-published",protocol_version:"2.1",
          operation_id:$op,source_display_id:$source,target_device_id:$target,
          coordinator_instance_id:$coordinator,marker_generation:$generation,
          marker_path:$marker_path,marker_sha256:$marker,created_at_unix_ms:"1788019200000",
          created_at_utc:"2026-08-29T12:00:00.000Z"}' >"$path"
    chmod 0600 "$path"
}
write_publish "$publish_receipt" "$operation_id" "$coordinator_instance_id" 1 "$gen1_sha"
write_publish "$publish2" "$recovery_operation_id" "$recovery_coordinator_id" 2 "$gen2_sha"

active_recovery_publish_receipt=$publish_receipt
active_recovery_operation_id=$operation_id
active_recovery_coordinator_id=$coordinator_instance_id
active_recovery_generation=1
active_recovery_marker_sha=$gen1_sha
BOOTSTRAP_MARKER_SHA=$gen1_sha
validate_active_recovery_marker

active_recovery_publish_receipt=$publish2
active_recovery_operation_id=$recovery_operation_id
active_recovery_coordinator_id=$recovery_coordinator_id
active_recovery_generation=2
active_recovery_marker_sha=$gen2_sha
BOOTSTRAP_MARKER_SHA=$gen2_sha
validate_active_recovery_marker

expect_rejected() {
    local name=$1
    if (validate_active_recovery_marker >/dev/null 2>&1); then die "active marker mutation accepted: $name"; fi
}
active_recovery_operation_id=$operation_id
expect_rejected generation2-replayed-bootstrap-operation
active_recovery_operation_id=$recovery_operation_id
active_recovery_generation=3
expect_rejected generation3
active_recovery_generation=2
active_recovery_marker_sha=$gen1_sha
BOOTSTRAP_MARKER_SHA=$gen1_sha
expect_rejected generation2-substituted-generation1-marker
active_recovery_publish_receipt=$publish2
active_recovery_operation_id=$operation_id
active_recovery_coordinator_id=$coordinator_instance_id
active_recovery_generation=1
active_recovery_marker_sha=$gen1_sha
BOOTSTRAP_MARKER_SHA=$gen1_sha
expect_rejected generation1-substituted-publish-receipt

printf '%s\n' 'bootstrap active marker generation fixture tests passed'
