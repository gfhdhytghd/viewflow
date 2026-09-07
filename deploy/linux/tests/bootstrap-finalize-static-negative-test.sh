#!/usr/bin/env bash
# shellcheck disable=SC2016

# Source-mutation negatives for the Linux bootstrap finalizer.  This script
# never executes the finalizer, and therefore cannot mutate deployed state.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly FINALIZER=$LINUX_DIR/bootstrap-finalize-viewflow-deskflow.sh
readonly CHECKER=$LINUX_DIR/check-bootstrap-finalize-viewflow-deskflow.sh
readonly COMMON=$LINUX_DIR/bootstrap-two-phase-common.sh

fail() {
    printf 'bootstrap finalize static negative test failed: %s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

expect_rejected() {
    local name=$1 from=$2 to=$3 mutant
    mutant=$tmp_dir/$name.sh
    awk -v from="$from" -v to="$to" '
        {
            line = $0
            result = ""
            while ((position = index(line, from)) != 0) {
                result = result substr(line, 1, position - 1) to
                line = substr(line, position + length(from))
                replaced = 1
            }
            print result line
        }
        END { if (!replaced) exit 42 }
    ' "$FINALIZER" >"$mutant" || fail "mutation target missing: $name"
    ! cmp -s "$FINALIZER" "$mutant" || fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

expect_common_rejected() {
    local name=$1 from=$2 to=$3 mutant
    mutant=$tmp_dir/$name-common.sh
    awk -v from="$from" -v to="$to" '
        {
            line = $0
            result = ""
            while ((position = index(line, from)) != 0) {
                result = result substr(line, 1, position - 1) to
                line = substr(line, position + length(from))
                replaced = 1
            }
            print result line
        }
        END { if (!replaced) exit 42 }
    ' "$COMMON" >"$mutant" || fail "mutation target missing: $name"
    ! cmp -s "$COMMON" "$mutant" || fail "mutation did not change shared helper: $name"
    if "$CHECKER" "$FINALIZER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe shared-helper mutation: $name"
    fi
}

"$CHECKER" "$FINALIZER" >/dev/null
expect_rejected stage-input --stage-receipt --ignored-stage-receipt
expect_rejected windows-schema5 --windows-install-receipt --ignored-windows-install-receipt
expect_rejected handoff-input --bootstrap-handoff-receipt --ignored-bootstrap-handoff-receipt
expect_rejected request-input --windows-bootstrap-request --ignored-windows-bootstrap-request
expect_rejected prepared-input --windows-prepared-receipt --ignored-windows-prepared-receipt
expect_rejected permit-input --windows-mutation-permit --ignored-windows-mutation-permit
expect_rejected force-envelope-input --windows-force-release-envelope --ignored-windows-force-release-envelope
expect_rejected publish-input --publish-receipt --ignored-publish-receipt
expect_rejected provenance-input --provenance --ignored-provenance
expect_rejected schema-version 'schema_version:1' 'schema_version:2'
expect_rejected stage-state viewflow-linux-bootstrap-staged viewflow-v13-bootstrap-frozen
expect_rejected final-state viewflow-linux-bootstrap-finalized viewflow-v13-bootstrap-frozen
expect_rejected marker-generation-one '[[ $marker_generation == 1 ]]' '[[ $marker_generation -ge 1 ]]'
expect_rejected uppercase-source-id 'source_display_id=$2' 'source_display_id=${2,,}'
expect_rejected uppercase-target-id 'target_device_id=$2' 'target_device_id=${2,,}'
expect_rejected uppercase-coordinator-id 'coordinator_instance_id=$2' 'coordinator_instance_id=${2,,}'
expect_rejected uppercase-active-coordinator-id 'active_recovery_coordinator_id=$2' 'active_recovery_coordinator_id=${2,,}'
expect_rejected operation-id-validator "require_uuid32 '--operation-id' \"\$operation_id\"" \
    "require_id '--operation-id' \"\$operation_id\""
expect_rejected active-operation-id-validator "require_uuid32 '--active-recovery-marker-operation-id' \"\$active_recovery_operation_id\"" \
    "require_id '--active-recovery-marker-operation-id' \"\$active_recovery_operation_id\""
expect_rejected uppercase-operation-id 'operation_id=$2' 'operation_id=${2,,}'
expect_rejected uppercase-active-operation-id 'active_recovery_operation_id=$2' 'active_recovery_operation_id=${2,,}'
expect_rejected marker-freeze freeze_marker freeze_untrusted_marker
expect_rejected frozen-validator validate_linux_frozen_evidence validate_untrusted_linux_evidence
expect_rejected handoff-validator validate_handoff_receipt validate_untrusted_handoff_receipt
expect_rejected prepared-validator validate_windows_prepared_receipt validate_untrusted_prepared_receipt
expect_rejected permit-validator validate_mutation_permit_receipt validate_untrusted_permit_receipt
expect_rejected force-envelope-validator validate_force_envelope_receipt validate_untrusted_envelope_receipt
expect_rejected raw-force-extraction raw_force_sha_from_envelope unsafe_force_sha_from_envelope
expect_rejected stage-freeze '.freeze_state == {deskflow_unit_active_state:"inactive",deskflow_unit_main_pid:0,' '.freeze_state == {deskflow_unit_active_state:"active",deskflow_unit_main_pid:0,'
expect_rejected stage-byte-hash 'sha256 "$stage_receipt"' 'sha256 /tmp/untrusted-stage'
expect_rejected consume-intent-call create_or_validate_consume_intent skip_consume_intent
expect_rejected consume-resume-call complete_evidence_consumption skip_evidence_consumption
expect_rejected consume-intent-state viewflow-linux-bootstrap-consume-intent viewflow-linux-bootstrap-unsafe-intent
expect_rejected consume-intent-move 'atomic_move_no_replace "consume intent artifact $name"' 'mv -- "$original" "$consumed" # unsafe'
expect_rejected restore-intent-move 'atomic_move_no_replace "restore consume intent artifact $name"' 'mv -- "$consumed" "$original" # unsafe'
expect_rejected rollback-historical '"$publish_receipt" historical' '"$publish_receipt" active'
expect_rejected rollback-active-marker validate_active_recovery_marker skip_active_recovery_marker
expect_rejected rollback-gen2-distinct 'active generation-2 recovery marker is not distinct from generation 1' 'active generation-2 marker unchecked'
expect_rejected deskflow-install 'atomic_install "$deskflow_candidate"' 'atomic_install "$viewflow_candidate"'
expect_rejected core-install 'atomic_install "$core_candidate"' 'atomic_install "$viewflow_candidate"'
expect_rejected dropin-install 'atomic_install "$dropin_candidate"' 'atomic_install "$viewflow_candidate"'
expect_rejected both-units-stop 'stop_both_units 30' 'true # no unit stops'
expect_rejected marker-retention 'assert_marker_unchanged || failed=1' 'true || failed=1'
expect_rejected exact-query '[[ $command == query ||' '[[ $command == query_approximate ||'
expect_common_rejected windows-schema5-version '.schema_version == 5 and .state == "viewflow-v2-windows-installed"' '.schema_version == 4 and .state == "viewflow-v2-windows-installed"'
expect_common_rejected windows-schema5-keys '"bootstrap_request_sha256","commit_mode"' '"bootstrap_request_sha256","legacy_commit_mode"'
expect_common_rejected windows-schema5-handoff '.marker_handoff_receipt_sha256 == $handoff' '.marker_handoff_receipt_sha256 == $prepared'
expect_common_rejected windows-schema5-prepared '.windows_prepared_receipt_sha256 == $prepared' '.windows_prepared_receipt_sha256 == $handoff'
expect_common_rejected windows-schema5-permit '.mutation_permit_sha256 == $permit' '.mutation_permit_sha256 == $stage'
expect_common_rejected windows-schema5-stage '.linux_stage_receipt_sha256 == $stage' '.linux_stage_receipt_sha256 == $permit'
expect_common_rejected windows-schema5-request '.bootstrap_request_sha256 == $request' '.bootstrap_request_sha256 == $linux'
expect_common_rejected windows-schema5-unique 'unique | length == 6' 'unique | length == 5'
expect_common_rejected no-replace-flag 'RENAME_NOREPLACE' 'RENAME_REPLACE'
expect_common_rejected prepared-candidate-keys '(.candidate | keys == ["path","sha256"])' '(.candidate | type == "object")'
expect_common_rejected prepared-rollback-auth-keys '(.rollback_authorization | keys == ["manifest_path","manifest_sha256","token_path","token_sha256"])' '(.rollback_authorization | type == "object")'
expect_rejected final-stage-runtime-keys '(.runtime | keys == ["authenticated_at_unix_ms","authenticated_peer_ip",' '(.runtime | type == "object") and # '
expect_rejected final-runtime-keys '(.runtime | keys == ["deskflow_core_pid","deskflow_core_start_ticks","deskflow_pid",' '(.runtime | type == "object") and # '

printf 'bootstrap finalize static negative tests passed\n'
