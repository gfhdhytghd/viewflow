#!/usr/bin/env bash
# shellcheck disable=SC2016

# Static-only contract audit for the second (Linux) half of the one-time
# protocol-1.3 bootstrap.  The optional path exists solely for mutation tests.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly FINALIZER=${1:-$SCRIPT_DIR/bootstrap-finalize-viewflow-deskflow.sh}
# The optional helper path is used only by the source-mutation negative suite.
readonly COMMON=${2:-$SCRIPT_DIR/bootstrap-two-phase-common.sh}

fail() {
    printf 'bootstrap finalize static check failed: %s\n' "$*" >&2
    exit 1
}

require_fixed() {
    grep -Fq -- "$1" "$FINALIZER" || fail "missing $2"
}

require_regex() {
    grep -Eq -- "$1" "$FINALIZER" || fail "missing $2"
}

require_common() {
    grep -Fq -- "$1" "$COMMON" || fail "missing shared helper contract: $2"
}

require_windows_receipt_common() {
    grep -Fq -- "$1" <<<"$windows_receipt_helper" ||
        fail "missing Windows install receipt contract: $2"
}

line_of() {
    grep -nF -- "$1" "$FINALIZER" | head -1 | cut -d: -f1
}

[[ -f $FINALIZER ]] || fail "finalizer not found: $FINALIZER"
[[ -f $COMMON ]] || fail "shared helper not found: $COMMON"
bash -n "$FINALIZER"
bash -n "$COMMON"
windows_receipt_helper=$(awk '
    /^validate_windows_install_receipt\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$COMMON")
[[ -n $windows_receipt_helper ]] || fail 'Windows install receipt helper is missing'
require_fixed 'source "$SCRIPT_DIR/bootstrap-two-phase-common.sh"' 'shared bootstrap helper'

# Inputs: the handoff/frozen/prepared/permit chain plus the exact Windows
# schema-5 receipt. Candidate and provenance inputs are deliberately
# explicit: a finalizer must never discover a replacement from PATH or cwd.
require_fixed 'stage_receipt' 'stage receipt input'
require_fixed 'windows_install_receipt' 'Windows schema-5 receipt input'
require_fixed 'handoff_receipt' 'marker handoff receipt input'
require_fixed 'bootstrap_request' 'Windows bootstrap request input'
require_fixed 'prepared_receipt' 'Windows prepared receipt input'
require_fixed 'mutation_permit' 'Windows mutation permit input'
require_fixed 'force_envelope' 'Windows force-release envelope input'
require_fixed 'publish_receipt' 'marker publish receipt input'
require_fixed 'provenance' 'provenance input'
require_fixed '--stage-receipt' 'stage receipt option'
require_fixed '--windows-install-receipt' 'Windows schema-5 receipt option'
require_fixed '--bootstrap-handoff-receipt' 'marker handoff receipt option'
require_fixed '--windows-bootstrap-request' 'Windows bootstrap request option'
require_fixed '--windows-prepared-receipt' 'Windows prepared receipt option'
require_fixed '--windows-mutation-permit' 'Windows mutation permit option'
require_fixed '--windows-force-release-envelope' 'Windows force envelope option'
require_fixed '--publish-receipt' 'marker publish receipt option'
require_fixed '--provenance' 'provenance option'
for option in \
    --viewflow-candidate --viewflow-sha256 \
    --deskflow-candidate --deskflow-sha256 \
    --deskflow-core-candidate --deskflow-core-sha256 \
    --viewflow-unit-candidate --viewflow-unit-sha256 \
    --deskflow-dropin-candidate --deskflow-dropin-sha256; do
    require_fixed "$option" "explicit candidate/provenance input $option"
done

require_fixed 'schema_version:1' 'schema-1 final receipt validation'
require_fixed 'viewflow-linux-bootstrap-staged' 'Linux stage receipt state validation'
require_fixed 'viewflow-linux-bootstrap-finalized' 'Linux final receipt state validation'
require_fixed '[[ $marker_generation == 1 ]]' 'one-time bootstrap generation-1 gate'
require_fixed 'source_display_id=$2' 'source ID validated before any normalization'
require_fixed 'target_device_id=$2' 'target ID validated before any normalization'
require_fixed 'coordinator_instance_id=$2' 'coordinator ID validated before any normalization'
require_fixed 'active_recovery_coordinator_id=$2' 'active coordinator ID validated before any normalization'
require_fixed "require_uuid32 '--operation-id' \"\$operation_id\"" 'canonical lowercase operation ID gate'
require_fixed "require_uuid32 '--active-recovery-marker-operation-id' \"\$active_recovery_operation_id\"" \
    'canonical lowercase active recovery operation ID gate'
if grep -Eq '(source_display_id|target_device_id|coordinator_instance_id|active_recovery_coordinator_id)=\$\{2,,\}' "$FINALIZER"; then
    fail 'finalizer must reject rather than lowercase uppercase ID arguments'
fi
if grep -Eq '(operation_id|active_recovery_operation_id)=\$\{2,,\}' "$FINALIZER"; then
    fail 'finalizer must reject rather than lowercase uppercase operation IDs'
fi
require_fixed 'validate_linux_frozen_evidence' 'Linux frozen receipt validator call'
require_fixed 'validate_handoff_receipt' 'marker handoff receipt validator call'
require_fixed 'validate_bootstrap_request_receipt' 'Windows bootstrap request validator call'
require_fixed 'validate_windows_prepared_receipt' 'Windows prepared receipt validator call'
require_fixed 'validate_mutation_permit_receipt' 'Windows mutation permit validator call'
require_fixed 'validate_force_envelope_receipt' 'Windows force envelope validator call'
require_fixed 'validate_windows_install_receipt' 'Windows schema-5 receipt validator call'
require_fixed 'validate_publish_receipt' 'publish receipt validator call'
require_fixed 'sha256 "$stage_receipt"' 'stage receipt exact-byte hash'
require_fixed 'windows_sha=$(sha256 "$windows_path")' 'Windows install receipt exact-byte hash'
require_fixed 'sha256 "$handoff_receipt"' 'handoff receipt exact-byte hash'
require_fixed 'sha256 "$bootstrap_request"' 'bootstrap request exact-byte hash'
require_fixed 'sha256 "$prepared_receipt"' 'prepared receipt exact-byte hash'
require_fixed 'sha256 "$mutation_permit"' 'mutation permit exact-byte hash'
require_fixed 'sha256 "$force_envelope"' 'Windows force envelope exact-byte hash'
require_fixed 'raw_force_sha_from_envelope' 'strict raw force SHA extraction from envelope'
require_fixed 'sha256 "$publish_receipt"' 'publish receipt exact-byte hash'
require_common 'DEPLOYMENT_MARKER_MAGIC=VFDQT001' 'VFDQT001 marker magic'
require_common 'require_sha256() {' 'lowercase SHA-256 validator'
require_windows_receipt_common '.schema_version == 5 and .state == "viewflow-v2-windows-installed"' \
    'Windows install receipt schema-5 contract'
require_windows_receipt_common '(keys == ["bootstrap_request_sha256","commit_mode","commit_nonce","commit_request_sha256","committed_at_utc",' \
    'Windows schema-5 exact key set'
for binding in \
    'force_release_receipt_sha256:raw_force' \
    'marker_handoff_receipt_sha256:handoff' \
    'windows_prepared_receipt_sha256:prepared' \
    'mutation_permit_sha256:permit' \
    'linux_stage_receipt_sha256:stage' \
    'bootstrap_request_sha256:request'; do
    field=${binding%%:*}
    expected=${binding#*:}
    require_windows_receipt_common ".$field == \$$expected" \
        "Windows schema-5 $field binding"
done
require_windows_receipt_common '[.force_release_receipt_sha256,.marker_handoff_receipt_sha256,' \
    'Windows schema-5 six-hash uniqueness set'
require_windows_receipt_common '.linux_stage_receipt_sha256,.bootstrap_request_sha256] | unique | length == 6' \
    'Windows schema-5 six-hash uniqueness check'
require_common '.linux_viewflowd_sha256 == $linux_vf' 'permit Linux Viewflow SHA binding'
require_common '.linux_deployment_marker_sha256 == $linux_marker' 'permit Linux marker-tool SHA binding'
require_common '.linux_viewflow_unit_sha256 == $linux_unit' 'permit Linux unit SHA binding'
require_common '(.marker_handoff_receipt | keys == ["path","sha256"])' 'P marker handoff exact nested keys'
require_common '(.candidate | keys == ["path","sha256"])' 'P candidate exact nested keys'
require_common '(.wrapper | keys == ["installed_path","sha256","source_path"])' 'P wrapper exact nested keys'
require_common '(.rollback_authorization | keys == ["manifest_path","manifest_sha256","token_path","token_sha256"])' \
    'P rollback authorization exact nested keys'
require_fixed 'evidence_hashes == {bootstrap_request:$request,linux_frozen_evidence:$linux,' \
    'stage exact evidence-hash chain'
require_fixed 'marker_handoff_receipt:$handoff,mutation_permit:$permit,' \
    'stage handoff/permit chain'
require_fixed 'windows_force_release_envelope:$envelope,windows_prepared_receipt:$prepared,' \
    'stage envelope/prepared chain'
require_fixed '.freeze_state == {deskflow_unit_active_state:"inactive",deskflow_unit_main_pid:0,' \
    'stage exact frozen Deskflow state'

# Finalization is the sole Linux owner of moving the frozen Linux and both
# Windows receipts. It durably publishes an exact intent before converging any
# crash subset to the three consumed paths.
require_fixed '# TRANSACTION_PHASE: BOOTSTRAP_FINALIZE_CONSUME_L_F_W' \
    'explicit L/F/W consumption phase'
consume_phase=$(awk '/TRANSACTION_PHASE: BOOTSTRAP_FINALIZE_CONSUME_L_F_W/{on=1; next} /TRANSACTION_PHASE: BOOTSTRAP_FINALIZE_INSTALL_DESKFLOW/{on=0} on' "$FINALIZER")
grep -Fq -- 'create_or_validate_consume_intent' <<<"$consume_phase" ||
    fail 'missing durable consume intent before L/F/W moves'
grep -Fq -- 'complete_evidence_consumption' <<<"$consume_phase" ||
    fail 'missing crash-resumable evidence consumption'
require_fixed 'readonly consume_intent=$backup_dir/consume-intent.json' 'fixed adjacent consume-intent path'
require_fixed 'viewflow-linux-bootstrap-consume-intent' 'consume-intent state'
require_fixed '(keys == ["artifacts","created_at_unix_ms","operation_id","schema_version",' \
    'consume-intent exact top-level key set'
require_fixed '(keys == ["consumed_path","original_path","sha256"])' \
    'consume-intent exact artifact key set'
require_fixed 'validate_consumption_subset' 'arbitrary exact consumption-subset validator'
require_fixed 'resolve_intent_artifact' 'exact original/consumed resolver'
require_common 'atomic_move_no_replace() {' 'kernel no-replace move helper'
require_common 'renameat2(source_fd' 'renameat2 no-replace linearization point'
require_common 'RENAME_NOREPLACE' 'explicit no-replace flag'
require_fixed 'atomic_move_no_replace "consume intent artifact $name"' 'intent-directed no-replace consumption'
require_fixed 'atomic_move_no_replace "restore consume intent artifact $name"' 'intent-directed no-replace restoration'
require_common 'fsync_file_and_parent "$destination"' 'moved evidence durability'
if grep -Eq '^[[:space:]]*mv -- "\$(publish_receipt|provenance)"' "$FINALIZER"; then
    fail 'publish receipt or provenance must not be consumed by receipt move'
fi

# Replacement scope is the patched Deskflow pair and the shipped drop-in in
# addition to Viewflow.  Require explicit installation calls rather than a
# broad directory copy.
require_fixed 'atomic_install "$deskflow_candidate"' 'patched Deskflow installation'
require_fixed 'atomic_install "$core_candidate"' 'patched deskflow-core installation'
require_fixed 'atomic_install "$dropin_candidate"' 'Deskflow drop-in installation'
require_fixed 'systemctl --user daemon-reload' 'unit reload after drop-in installation'

# VFDQT001 remains present through startup.  This command must only contain
# fail-closed containment, never a release/unlink route.
require_fixed 'freeze_marker' 'marker validation before mutation'
require_fixed 'systemctl --user start "$DESKFLOW_UNIT"' 'Deskflow start'
marker_line=$(line_of 'assert_marker_unchanged')
deskflow_start_line=$(line_of 'systemctl --user start "$DESKFLOW_UNIT"')
[[ $marker_line =~ ^[0-9]+$ && $deskflow_start_line =~ ^[0-9]+$ &&
   $marker_line -lt $deskflow_start_line ]] || fail 'marker must be retained and checked before Deskflow starts'
if grep -Eq '(release|unlink|rm)[^\n]*(DEPLOYMENT_QUARANTINE_MARKER|deployment-quarantine)' "$FINALIZER"; then
    fail 'finalizer must not release or remove VFDQT001'
fi

# Any failure returns the staged baseline (six old installed artifacts) and
# leaves both Linux units inactive while preserving the marker.
require_fixed 'restore_all_old_files' 'failure restoration routine'
require_fixed 'atomic_install "$backup_dir/viewflowd"' 'old Viewflow restoration'
require_fixed 'atomic_install "$backup_dir/viewflow-deployment-marker"' 'old marker-tool restoration'
require_fixed 'atomic_install "$backup_dir/viewflow-peer.service"' 'old Viewflow unit restoration'
require_fixed 'atomic_install "$backup_dir/deskflow"' 'old Deskflow restoration'
require_fixed 'atomic_install "$backup_dir/deskflow-core"' 'old deskflow-core restoration'
require_fixed 'atomic_install "$backup_dir/deskflow-viewflow.conf"' 'old Deskflow drop-in restoration'
require_fixed 'stop_both_units 30' 'failure stop of both Linux units'
require_fixed 'assert_marker_unchanged || failed=1' 'failure marker-retention check'

# Rollback must explicitly validate either the original generation-1 active
# marker or a distinct generation-2 recovery marker, while H/Ls remain bound
# to the historical generation-1 marker bytes.
for option in --active-recovery-marker-publish-receipt \
    --active-recovery-marker-operation-id \
    --active-recovery-marker-coordinator-instance-id \
    --active-recovery-marker-generation \
    --active-recovery-marker-sha256; do
    require_fixed "$option" "explicit rollback current-marker option $option"
done
require_fixed 'validate_stage_receipt "$stage_receipt" "$rollback_linux" "$rollback_force" "$publish_receipt" historical' \
    'rollback historical generation-1 stage validation'
require_fixed 'validate_active_recovery_marker' 'rollback current-marker validation'
require_fixed 'active generation-1 publish receipt is not the original publish receipt' \
    'exact generation-1 publish replay'
require_fixed 'active generation-2 recovery marker is not distinct from generation 1' \
    'distinct generation-2 recovery marker'
require_fixed 'assert_both_units_stopped' 'rollback inactive-unit gate'
require_fixed '(.runtime | keys == ["authenticated_at_unix_ms","authenticated_peer_ip",' \
    'Ls runtime exact nested key set in finalizer'
require_fixed '(.runtime | keys == ["deskflow_core_pid","deskflow_core_start_ticks","deskflow_pid",' \
    'Lf runtime exact nested key set'

# Publication is query-backed and atomic/no-clobber.  A normal overwrite redirection
# would permit replay of an old operation receipt.
require_fixed '[[ $command == query ||' 'exact/idempotent receipt query branch'
require_fixed 'operation_id' 'operation-bound output'
require_fixed 'publish_no_clobber' 'atomic receipt publication helper call'
require_common 'ln -- "$temporary" "$destination"' 'atomic receipt no-clobber link publication'
if grep -Eq '>[[:space:]]*"?\$output_receipt"?' "$FINALIZER"; then
    fail 'receipt publication may not overwrite with shell redirection'
fi

printf 'bootstrap finalize static checks passed\n'
