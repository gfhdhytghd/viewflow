#!/usr/bin/env bash

# Pure offline schema-5 W and bootstrap-chain fixture. No runtime state changes.

# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly COMMON=$SCRIPT_DIR/../bootstrap-two-phase-common.sh

fail() { printf 'two-phase receipt fixture failed: %s\n' "$*" >&2; exit 1; }
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
helper=$tmp_dir/validate-w.sh
awk '/^validate_windows_install_receipt\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' \
    "$COMMON" >"$helper"
grep -Fq 'validate_windows_install_receipt() {' "$helper" || fail 'W validator not found'
bash -n "$helper"

assert_evidence() { jq -e 'type == "object"' "$2" >/dev/null; }
die() { printf '%s\n' "$*" >&2; return 1; }
# shellcheck source=/dev/null
source "$helper"

permit_helper=$tmp_dir/validate-permit.sh
awk '/^validate_mutation_permit_receipt\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' \
    "$COMMON" >"$permit_helper"
grep -Fq 'validate_mutation_permit_receipt() {' "$permit_helper" || fail 'permit validator not found'
# shellcheck source=/dev/null
source "$permit_helper"

op=bootstrap-fixture-20260829
linux=$(printf '1%.0s' {1..64})
raw_force=$(printf 'b%.0s' {1..64})
handoff=$(printf '3%.0s' {1..64})
prepared=$(printf '4%.0s' {1..64})
permit=$(printf '5%.0s' {1..64})
stage=$(printf '6%.0s' {1..64})
request=$(printf '7%.0s' {1..64})
windows=$(printf '8%.0s' {1..64})
wrapper=$(printf '9%.0s' {1..64})
task=$(printf 'a%.0s' {1..64})
sid=S-1-5-21-1000
coordinator=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
coordinator_compact=${coordinator//-/}
linux_viewflow=$(printf 'c%.0s' {1..64})
linux_marker=$(printf 'd%.0s' {1..64})
linux_unit=$(printf 'e%.0s' {1..64})
readonly VIEWFLOW_TARGET=00000000000000000000000000000002

jq -cn --arg op "$op" --arg sid "$sid" --arg raw "$raw_force" \
    '{schema_version:1,state:"viewflow-windows-bootstrap-force-release-attested",operation_id:$op,
      user_sid:$sid,bootstrap_request_sha256:("7"*64),marker_handoff_receipt_sha256:("3"*64),
      windows_prepared_receipt_sha256:("4"*64),mutation_permit_sha256:("5"*64),
      linux_frozen_evidence_sha256:("1"*64),raw_force_release_receipt_path:"C:\\Viewflow\\force.json",
      raw_force_release_receipt_sha256:$raw,completed_at_utc:"2026-08-29T12:00:00.000Z"}' \
    >"$tmp_dir/force-envelope.json"
envelope=$(sha256sum "$tmp_dir/force-envelope.json" | awk '{print $1}')
[[ $envelope != "$raw_force" ]] || fail 'raw force SHA must differ from envelope file SHA'

write_valid() {
    jq -cn --arg op "$op" --arg linux "$linux" --arg raw_force "$raw_force" \
        --arg handoff "$handoff" --arg prepared "$prepared" --arg permit "$permit" \
        --arg stage "$stage" --arg request "$request" --arg windows "$windows" \
        --arg wrapper "$wrapper" --arg task "$task" --arg sid "$sid" \
        '{schema_version:5,state:"viewflow-v2-windows-installed",operation_id:$op,
          commit_nonce:("b"*32),commit_request_sha256:("c"*64),commit_mode:"bootstrap-v1.3",
          committed_by_daemon:true,linux_frozen_evidence_sha256:$linux,
          force_release_receipt_sha256:$raw_force,marker_handoff_receipt_sha256:$handoff,
          windows_prepared_receipt_sha256:$prepared,mutation_permit_sha256:$permit,
          linux_stage_receipt_sha256:$stage,bootstrap_request_sha256:$request,
          readiness_receipt_sha256:("d"*64),readiness_lock_sha256:("e"*64),
          readiness_connection_generation:8,readiness_established_at_utc:"2026-08-29T12:00:00.000Z",
          old_viewflow_executable_sha256:("f"*64),new_viewflow_executable_sha256:$windows,
          installed_wrapper_sha256:$wrapper,scheduled_task_xml_sha256:$task,
          new_process_pid:42,new_process_start_filetime:"100",new_process_session_id:1,
          new_process_user_sid:$sid,protocol_version:"2.1",peer:"172.16.105.62:44119",
          device_id:"00000000000000000000000000000002",
          completed_at_utc:"2026-08-29T12:00:01.000Z",committed_at_utc:"2026-08-29T12:00:02.000Z"}' \
        >"$tmp_dir/w.json"
}

validate_w() {
    validate_windows_install_receipt "$tmp_dir/w.json" "$op" "$linux" "$raw_force" \
        "$handoff" "$prepared" "$permit" "$stage" "$request" "$windows" "$wrapper" "$task" "$sid"
}

write_valid
validate_w || fail 'valid schema-5 W rejected'

expect_rejected() {
    local name=$1 filter=$2
    cp -- "$tmp_dir/w.json" "$tmp_dir/base.json"
    jq "$filter" "$tmp_dir/base.json" >"$tmp_dir/w.json"
    if validate_w >/dev/null 2>&1; then fail "mutation accepted: $name"; fi
    mv -- "$tmp_dir/base.json" "$tmp_dir/w.json"
}

expect_rejected legacy-schema '.schema_version = 2'
expect_rejected missing-stage 'del(.linux_stage_receipt_sha256)'
expect_rejected extra-key '.unexpected = true'
expect_rejected uppercase-envelope '.force_release_receipt_sha256 |= ascii_upcase'
expect_rejected envelope-file-sha-substitution ".force_release_receipt_sha256 = \"$envelope\""
expect_rejected wrong-handoff '.marker_handoff_receipt_sha256 = ("0"*64)'
expect_rejected replay-operation '.operation_id = "different-bootstrap-operation"'
expect_rejected duplicate-bootstrap-binding '.bootstrap_request_sha256 = .linux_stage_receipt_sha256'
expect_rejected wrong-candidate '.new_viewflow_executable_sha256 = ("0"*64)'

jq -cn --arg wrapper "$wrapper" --arg rollback "$(printf 'f%.0s' {1..64})" \
    '{wrapper_sha256:$wrapper,rollback_script_sha256:$rollback}' >"$tmp_dir/request.json"
jq -cn --arg op "$op" --arg sid "$sid" --arg coordinator "$coordinator" \
    --arg request "$request" --arg handoff "$handoff" --arg prepared "$prepared" \
    --arg linux "$linux" --arg windows "$windows" --arg wrapper "$wrapper" \
    --arg rollback "$(printf 'f%.0s' {1..64})" --arg vf "$linux_viewflow" \
    --arg marker "$linux_marker" --arg unit "$linux_unit" \
    '{schema_version:1,state:"viewflow-windows-bootstrap-mutation-permitted",operation_id:$op,
      user_sid:$sid,coordinator_instance_id:$coordinator,permit_nonce:("1"*64),
      bootstrap_request_sha256:$request,marker_handoff_receipt_sha256:$handoff,
      windows_prepared_receipt_sha256:$prepared,linux_frozen_evidence_sha256:$linux,
      candidate_sha256:$windows,wrapper_sha256:$wrapper,rollback_script_sha256:$rollback,
      rollback_manifest_sha256:("2"*64),rollback_token_sha256:("3"*64),
      linux_viewflowd_sha256:$vf,linux_deployment_marker_sha256:$marker,
      linux_viewflow_unit_sha256:$unit,issued_at_utc:"2026-08-29T12:00:00.000Z"}' >"$tmp_dir/permit.json"

validate_permit() {
    validate_mutation_permit_receipt "$tmp_dir/permit.json" "$op" "$coordinator_compact" "$request" \
        "$handoff" "$prepared" "$linux" "$windows" "$tmp_dir/request.json" \
        "$linux_viewflow" "$linux_marker" "$linux_unit"
}
validate_permit || fail 'valid permit Linux artifact bindings rejected'

expect_permit_rejected() {
    local name=$1 filter=$2
    cp -- "$tmp_dir/permit.json" "$tmp_dir/base-permit.json"
    jq "$filter" "$tmp_dir/base-permit.json" >"$tmp_dir/permit.json"
    if validate_permit >/dev/null 2>&1; then fail "permit mutation accepted: $name"; fi
    mv -- "$tmp_dir/base-permit.json" "$tmp_dir/permit.json"
}
expect_permit_rejected wrong-linux-viewflow '.linux_viewflowd_sha256 = ("0"*64)'
expect_permit_rejected wrong-linux-marker '.linux_deployment_marker_sha256 = ("0"*64)'
expect_permit_rejected wrong-linux-unit '.linux_viewflow_unit_sha256 = ("0"*64)'
expect_permit_rejected missing-linux-unit 'del(.linux_viewflow_unit_sha256)'
expect_permit_rejected malformed-coordinator '.coordinator_instance_id = ("b"*32)'
expect_permit_rejected wrong-coordinator '.coordinator_instance_id = "cccccccc-cccc-cccc-cccc-cccccccccccc"'

printf 'two-phase schema-5 receipt fixture tests passed\n'
