#!/usr/bin/env bash

# Offline canonical-UUID fixture for the real marker publish/H receipt shape.

# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly COMMON=$SCRIPT_DIR/../bootstrap-two-phase-common.sh
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() { printf 'bootstrap H/publish UUID fixture failed: %s\n' "$*" >&2; exit 1; }
extract_function() {
    local name=$1 output=$2
    awk -v signature="$name() {" '$0 == signature {copy=1} copy {print} copy && /^}$/ {exit}' \
        "$COMMON" >"$output"
    grep -Fq "$name() {" "$output" || fail "missing validator: $name"
}
extract_function validate_publish_receipt "$tmp_dir/publish-validator.sh"
extract_function validate_handoff_receipt "$tmp_dir/h-validator.sh"

sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
assert_evidence() { jq -e 'type == "object"' "$2" >/dev/null; }
die() { printf '%s\n' "$*" >&2; return 1; }
# shellcheck source=/dev/null
source "$tmp_dir/publish-validator.sh"
# shellcheck source=/dev/null
source "$tmp_dir/h-validator.sh"

DEPLOYMENT_MARKER=$tmp_dir/deployment-quarantine.v1
DEPLOYMENT_MARKER_TOOL_INSTALLED=$tmp_dir/viewflow-deployment-marker
DESKFLOW_INSTALLED=$tmp_dir/deskflow
DESKFLOW_CORE_INSTALLED=$tmp_dir/deskflow-core
RUNTIME_MARKER=$tmp_dir/deskflow-quarantine.v2
DESKFLOW_PORT=24800
printf VFDQT001 >"$DEPLOYMENT_MARKER"
dd if=/dev/zero bs=248 count=1 status=none >>"$DEPLOYMENT_MARKER"

operation=bootstrap-uuid-fixture-20260829
source32=00000000000000000000000000000101
target32=00000000000000000000000000000002
coordinator32=123456789abcdef01111222233334444
source_uuid=00000000-0000-0000-0000-000000000101
target_uuid=00000000-0000-0000-0000-000000000002
coordinator_uuid=12345678-9abc-def0-1111-222233334444
generation=1
marker_sha=$(sha256 "$DEPLOYMENT_MARKER")
cli_sha=$(printf 'a%.0s' {1..64})
deskflow_sha=$(printf 'b%.0s' {1..64})
core_sha=$(printf 'c%.0s' {1..64})
publish=$tmp_dir/publish.json
handoff=$tmp_dir/h.json

write_publish() {
    jq -cn --arg op "$operation" --arg source "$source_uuid" --arg target "$target_uuid" \
        --arg coordinator "$coordinator_uuid" --arg generation "$generation" \
        --arg marker "$DEPLOYMENT_MARKER" --arg sha "$marker_sha" \
        '{schema_version:1,state:"deployment-quarantine-published",protocol_version:"2.1",
          operation_id:$op,source_display_id:$source,target_device_id:$target,
          coordinator_instance_id:$coordinator,marker_generation:$generation,
          marker_path:$marker,marker_sha256:$sha,created_at_unix_ms:"1788048000000",
          created_at_utc:"2026-08-29T20:00:00.000Z"}' >"$publish"
}
write_handoff() {
    jq -cn --arg op "$operation" --arg source "$source_uuid" --arg target "$target_uuid" \
        --arg coordinator "$coordinator_uuid" --arg generation "$generation" \
        --arg cli "$DEPLOYMENT_MARKER_TOOL_INSTALLED" --arg cli_sha "$cli_sha" \
        --arg marker "$DEPLOYMENT_MARKER" --arg marker_sha "$marker_sha" \
        --arg publish "$publish" --arg publish_sha "$(sha256 "$publish")" \
        --arg deskflow "$DESKFLOW_INSTALLED" --arg deskflow_sha "$deskflow_sha" \
        --arg core "$DESKFLOW_CORE_INSTALLED" --arg core_sha "$core_sha" --arg runtime "$RUNTIME_MARKER" \
        '{schema_version:1,state:"viewflow-v13-marker-handoff-prepared",protocol_version:"2.1",
          operation_id:$op,source_display_id:$source,target_device_id:$target,
          coordinator_instance_id:$coordinator,marker_generation:$generation,
          marker_cli_path:$cli,marker_cli_sha256:$cli_sha,deployment_marker_path:$marker,
          deployment_marker_sha256:$marker_sha,deployment_publish_receipt_path:$publish,
          deployment_publish_receipt_sha256:$publish_sha,deskflow_unit:"deskflow.service",
          deskflow_unit_active_state:"inactive",deskflow_unit_main_pid:0,
          deskflow_executable_path:$deskflow,deskflow_executable_sha256:$deskflow_sha,
          deskflow_exact_process_count:0,deskflow_core_executable_path:$core,
          deskflow_core_executable_sha256:$core_sha,deskflow_core_exact_process_count:0,
          deskflow_tcp_port:24800,deskflow_tcp_listener_count:0,runtime_marker_path:$runtime,
          runtime_marker_present:false,observed_at_utc:"2026-08-29T20:00:01.000Z"}' >"$handoff"
}

validate_publish() {
    validate_publish_receipt "$publish" "$operation" "$source32" "$target32" \
        "$coordinator32" "$generation" "$marker_sha"
}
validate_h() {
    validate_handoff_receipt "$handoff" "$publish" "$operation" "$source32" "$target32" \
        "$coordinator32" "$generation" "$cli_sha" "$deskflow_sha" "$core_sha"
}

write_publish
write_handoff
validate_publish || fail 'canonical publish receipt rejected'
validate_h || fail 'canonical H receipt rejected'

expect_publish_rejected() {
    local name=$1 filter=$2
    cp -- "$publish" "$tmp_dir/publish-base.json"
    jq "$filter" "$tmp_dir/publish-base.json" >"$publish"
    if validate_publish >/dev/null 2>&1; then fail "publish mutation accepted: $name"; fi
    mv -- "$tmp_dir/publish-base.json" "$publish"
}
expect_h_rejected() {
    local name=$1 filter=$2
    cp -- "$handoff" "$tmp_dir/h-base.json"
    jq "$filter" "$tmp_dir/h-base.json" >"$handoff"
    if validate_h >/dev/null 2>&1; then fail "H mutation accepted: $name"; fi
    mv -- "$tmp_dir/h-base.json" "$handoff"
}

expect_publish_rejected noncanonical-source '.source_display_id |= gsub("-"; "")'
expect_publish_rejected uppercase-coordinator '.coordinator_instance_id |= ascii_upcase'
expect_publish_rejected zero-coordinator '.coordinator_instance_id = "00000000-0000-0000-0000-000000000000"'
expect_publish_rejected mismatched-source '.source_display_id = "00000000-0000-0000-0000-000000000102"'
expect_h_rejected noncanonical-target '.target_device_id |= gsub("-"; "")'
expect_h_rejected zero-source '.source_display_id = "00000000-0000-0000-0000-000000000000"'
expect_h_rejected extra-field '.unexpected = true'

printf 'bootstrap H/publish canonical UUID fixtures passed\n'
