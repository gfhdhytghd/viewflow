#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly STAGE=$LINUX_DIR/bootstrap-stage-viewflow.sh
readonly CHECKER=$LINUX_DIR/check-bootstrap-stage-viewflow.sh
readonly COMMON=$LINUX_DIR/bootstrap-two-phase-common.sh

fail() { printf 'bootstrap stage static negative test failed: %s\n' "$*" >&2; exit 1; }
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

expect_rejected() {
    local name=$1 from=$2 to=$3 mutant=$tmp_dir/$1.sh
    awk -v from="$from" -v to="$to" '
        {
            line=$0; result=""
            while ((p=index(line,from)) != 0) {
                result=result substr(line,1,p-1) to
                line=substr(line,p+length(from)); done=1
            }
            print result line
        }
        END { if (!done) exit 42 }
    ' "$STAGE" >"$mutant" || fail "mutation target missing: $name"
    cmp -s "$STAGE" "$mutant" && fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then fail "checker accepted unsafe mutation: $name"; fi
}

expect_common_rejected() {
    local name=$1 from=$2 to=$3 mutant=$tmp_dir/$1-common.sh
    awk -v from="$from" -v to="$to" '
        {
            line=$0; result=""
            while ((p=index(line,from)) != 0) {
                result=result substr(line,1,p-1) to
                line=substr(line,p+length(from)); done=1
            }
            print result line
        }
        END { if (!done) exit 42 }
    ' "$COMMON" >"$mutant" || fail "common mutation target missing: $name"
    cmp -s "$COMMON" "$mutant" && fail "common mutation did not change source: $name"
    if "$CHECKER" "$STAGE" "$mutant" >/dev/null 2>&1; then fail "checker accepted unsafe common mutation: $name"; fi
}

"$CHECKER" "$STAGE" >/dev/null
expect_rejected protocol-21 'protocol_version:"2.1"' 'protocol_version:"1.3"'
expect_rejected marker-absence 'assert_runtime_marker_absent' 'assert_runtime_marker_present'
expect_rejected peer-binding \
    '--arg prefix "viewflowd server authenticated peer $EXPECTED_WINDOWS_PEER_IP:"' \
    '--arg prefix "viewflowd server authenticated peer 172.16.105.71:"'
expect_rejected no-clobber 'publish_no_clobber' 'publish_overwrite'
expect_rejected owner-only 'chmod 0600 "$receipt_temp"' 'chmod 0644 "$receipt_temp"'
expect_rejected marker-generation-one '[[ $marker_generation == 1 ]]' '[[ $marker_generation -ge 1 ]]'
expect_rejected uppercase-source-id 'source_display_id=$2' 'source_display_id=${2,,}'
expect_rejected uppercase-target-id 'target_device_id=$2' 'target_device_id=${2,,}'
expect_rejected uppercase-coordinator-id 'coordinator_instance_id=$2' 'coordinator_instance_id=${2,,}'
expect_rejected operation-id-validator "require_uuid32 '--operation-id' \"\$operation_id\"" \
    "require_id '--operation-id' \"\$operation_id\""
expect_rejected uppercase-operation-id 'operation_id=$2' 'operation_id=${2,,}'
expect_rejected h-chain 'validate_handoff_receipt' 'validate_unbound_handoff_receipt'
expect_rejected request-chain 'validate_bootstrap_request_receipt' 'validate_unbound_bootstrap_request_receipt'
expect_rejected prepared-chain 'validate_windows_prepared_receipt' 'validate_unbound_windows_prepared_receipt'
expect_rejected permit-chain 'validate_mutation_permit_receipt' 'validate_unbound_mutation_permit_receipt'
expect_rejected force-envelope-chain 'validate_force_envelope_receipt' 'validate_unbound_force_envelope_receipt'
expect_rejected permit-viewflow-substitution \
    '"$windows_viewflow_sha" "$bootstrap_request" "$viewflow_sha" "$marker_tool_sha" "$unit_sha"' \
    '"$windows_viewflow_sha" "$bootstrap_request" "$marker_tool_sha" "$marker_tool_sha" "$unit_sha"'
expect_rejected permit-marker-substitution \
    '"$windows_viewflow_sha" "$bootstrap_request" "$viewflow_sha" "$marker_tool_sha" "$unit_sha"' \
    '"$windows_viewflow_sha" "$bootstrap_request" "$viewflow_sha" "$viewflow_sha" "$unit_sha"'
expect_rejected permit-unit-substitution \
    '"$windows_viewflow_sha" "$bootstrap_request" "$viewflow_sha" "$marker_tool_sha" "$unit_sha"' \
    '"$windows_viewflow_sha" "$bootstrap_request" "$viewflow_sha" "$marker_tool_sha" "$viewflow_sha"'
expect_rejected ls-h-substitution \
    'marker_handoff_receipt:$handoff,mutation_permit:$permit,' \
    'marker_handoff_receipt:$prepared,mutation_permit:$permit,'
expect_rejected ls-extra-key \
    'deployment_publish_receipt:$publish}' \
    'deployment_publish_receipt:$publish,unexpected:"x"}'
expect_rejected ls-uppercase-hash \
    'marker_handoff_receipt:$handoff,mutation_permit:$permit,' \
    'marker_handoff_receipt:$HANDOFF,mutation_permit:$permit,'
expect_common_rejected canonical-uuid 'def canonical_uuid:' 'def unchecked_uuid:'
expect_common_rejected hyphenated-uuid 'test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")' 'test("^[0-9a-f]{32}$")'
expect_common_rejected nonzero-uuid '(gsub("-"; "") != "00000000000000000000000000000000")' 'true'
expect_common_rejected source-uuid-compare '((.source_display_id | gsub("-"; "")) == $source)' '(.source_display_id == $source)'
expect_common_rejected permit-coordinator-compare '((.coordinator_instance_id | gsub("-"; "")) == $coordinator)' '(.coordinator_instance_id == $coordinator)'
expect_common_rejected prepared-wrapper-keys '(.wrapper | keys == ["installed_path","sha256","source_path"])' '(.wrapper | type == "object")'
expect_common_rejected prepared-old-task-keys '(.old_task | keys == ["name","state","xml_backup_path","xml_sha256"])' '(.old_task | type == "object")'
expect_rejected stage-runtime-keys '(.runtime | keys == ["authenticated_at_unix_ms","authenticated_peer_ip",' '(.runtime | type == "object") and # '
printf 'bootstrap stage static negative tests passed\n'
