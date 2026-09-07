#!/usr/bin/env bash

# Phase 2 of the one-time protocol-1.3 -> protocol-2.1 Linux bootstrap.
# Consumes the completed Windows schema-2 receipt chain, installs patched
# Deskflow/core/drop-in, and starts them only while VFDQT001 remains retained.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bootstrap-two-phase-common.sh"

command=${1-}
[[ $command == finalize || $command == query || $command == rollback ]] || {
    printf '%s\n' 'usage: bootstrap-finalize-viewflow-deskflow.sh finalize|query|rollback [options]' >&2
    exit 64
}
shift

viewflow_candidate=''
viewflow_sha=''
marker_candidate=''
marker_tool_sha=''
unit_candidate=''
unit_sha=''
deskflow_candidate=''
deskflow_sha=''
core_candidate=''
core_sha=''
dropin_candidate=''
dropin_sha=''
provenance=''
provenance_sha=''
stage_receipt=''
linux_evidence=''
handoff_receipt=''
bootstrap_request=''
prepared_receipt=''
mutation_permit=''
force_envelope=''
windows_install_receipt=''
publish_receipt=''
operation_id=''
source_display_id=''
target_device_id=''
coordinator_instance_id=''
marker_generation=''
windows_viewflow_sha=''
windows_wrapper_sha=''
windows_task_sha=''
windows_user_sid=''
receipt_output=''
active_recovery_publish_receipt=''
active_recovery_operation_id=''
active_recovery_coordinator_id=''
active_recovery_generation=''
active_recovery_marker_sha=''
readiness_timeout=120

need_value() { [[ -n ${2-} ]] || die "$1 requires a value"; }
while (($#)); do
    case $1 in
        --viewflow-candidate) need_value "$1" "${2-}"; viewflow_candidate=$2; shift 2 ;;
        --viewflow-sha256) need_value "$1" "${2-}"; viewflow_sha=${2,,}; shift 2 ;;
        --deployment-marker-candidate) need_value "$1" "${2-}"; marker_candidate=$2; shift 2 ;;
        --deployment-marker-sha256) need_value "$1" "${2-}"; marker_tool_sha=${2,,}; shift 2 ;;
        --viewflow-unit-candidate) need_value "$1" "${2-}"; unit_candidate=$2; shift 2 ;;
        --viewflow-unit-sha256) need_value "$1" "${2-}"; unit_sha=${2,,}; shift 2 ;;
        --deskflow-candidate) need_value "$1" "${2-}"; deskflow_candidate=$2; shift 2 ;;
        --deskflow-sha256) need_value "$1" "${2-}"; deskflow_sha=${2,,}; shift 2 ;;
        --deskflow-core-candidate) need_value "$1" "${2-}"; core_candidate=$2; shift 2 ;;
        --deskflow-core-sha256) need_value "$1" "${2-}"; core_sha=${2,,}; shift 2 ;;
        --deskflow-dropin-candidate) need_value "$1" "${2-}"; dropin_candidate=$2; shift 2 ;;
        --deskflow-dropin-sha256) need_value "$1" "${2-}"; dropin_sha=${2,,}; shift 2 ;;
        --deskflow-provenance-manifest|--provenance) need_value "$1" "${2-}"; provenance=$2; shift 2 ;;
        --deskflow-provenance-sha256) need_value "$1" "${2-}"; provenance_sha=${2,,}; shift 2 ;;
        --stage-receipt) need_value "$1" "${2-}"; stage_receipt=$2; shift 2 ;;
        --bootstrap-linux-evidence) need_value "$1" "${2-}"; linux_evidence=$2; shift 2 ;;
        --bootstrap-handoff-receipt) need_value "$1" "${2-}"; handoff_receipt=$2; shift 2 ;;
        --windows-bootstrap-request) need_value "$1" "${2-}"; bootstrap_request=$2; shift 2 ;;
        --windows-prepared-receipt) need_value "$1" "${2-}"; prepared_receipt=$2; shift 2 ;;
        --windows-mutation-permit) need_value "$1" "${2-}"; mutation_permit=$2; shift 2 ;;
        --bootstrap-windows-force-receipt|--windows-force-receipt|--windows-force-release-envelope)
            need_value "$1" "${2-}"; force_envelope=$2; shift 2 ;;
        --bootstrap-windows-install-receipt|--windows-install-receipt) need_value "$1" "${2-}"; windows_install_receipt=$2; shift 2 ;;
        --deployment-publish-receipt|--publish-receipt) need_value "$1" "${2-}"; publish_receipt=$2; shift 2 ;;
        --operation-id) need_value "$1" "${2-}"; operation_id=$2; shift 2 ;;
        --source-display-id) need_value "$1" "${2-}"; source_display_id=$2; shift 2 ;;
        --target-device-id) need_value "$1" "${2-}"; target_device_id=$2; shift 2 ;;
        --coordinator-instance-id) need_value "$1" "${2-}"; coordinator_instance_id=$2; shift 2 ;;
        --marker-generation) need_value "$1" "${2-}"; marker_generation=$2; shift 2 ;;
        --windows-viewflow-sha256) need_value "$1" "${2-}"; windows_viewflow_sha=${2,,}; shift 2 ;;
        --windows-wrapper-sha256) need_value "$1" "${2-}"; windows_wrapper_sha=${2,,}; shift 2 ;;
        --windows-task-xml-sha256) need_value "$1" "${2-}"; windows_task_sha=${2,,}; shift 2 ;;
        --windows-user-sid) need_value "$1" "${2-}"; windows_user_sid=$2; shift 2 ;;
        --receipt-output) need_value "$1" "${2-}"; receipt_output=$2; shift 2 ;;
        --active-recovery-marker-publish-receipt)
            need_value "$1" "${2-}"; active_recovery_publish_receipt=$2; shift 2 ;;
        --active-recovery-marker-operation-id)
            need_value "$1" "${2-}"; active_recovery_operation_id=$2; shift 2 ;;
        --active-recovery-marker-coordinator-instance-id)
            need_value "$1" "${2-}"; active_recovery_coordinator_id=$2; shift 2 ;;
        --active-recovery-marker-generation)
            need_value "$1" "${2-}"; active_recovery_generation=$2; shift 2 ;;
        --active-recovery-marker-sha256)
            need_value "$1" "${2-}"; active_recovery_marker_sha=${2,,}; shift 2 ;;
        --readiness-timeout-seconds) need_value "$1" "${2-}"; readiness_timeout=$2; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

for value in "$viewflow_candidate" "$viewflow_sha" "$marker_candidate" "$marker_tool_sha" \
    "$unit_candidate" "$unit_sha" "$deskflow_candidate" "$deskflow_sha" "$core_candidate" \
    "$core_sha" "$dropin_candidate" "$dropin_sha" "$provenance" "$provenance_sha" \
    "$stage_receipt" "$linux_evidence" "$handoff_receipt" "$bootstrap_request" \
    "$prepared_receipt" "$mutation_permit" "$force_envelope" "$windows_install_receipt" \
    "$publish_receipt" "$operation_id" "$source_display_id" "$target_device_id" \
    "$coordinator_instance_id" "$marker_generation" "$windows_viewflow_sha" \
    "$windows_wrapper_sha" "$windows_task_sha" "$windows_user_sid" "$receipt_output"; do
    [[ -n $value ]] || die 'all finalize/query/rollback options are mandatory'
done
# Operation IDs are durable artifact namespaces, not display labels.  Do not
# normalize this value: an uppercase spelling must not alias a lower-case
# operation directory or receipt chain.
require_uuid32 '--operation-id' "$operation_id"
require_uuid32 '--source-display-id' "$source_display_id"
require_uuid32 '--target-device-id' "$target_device_id"
require_uuid32 '--coordinator-instance-id' "$coordinator_instance_id"
require_u64_decimal '--marker-generation' "$marker_generation"
[[ $marker_generation == 1 ]] || die 'bootstrap finalize marker generation must be exactly 1'
for pair in "viewflow:$viewflow_sha" "marker:$marker_tool_sha" "unit:$unit_sha" \
    "deskflow:$deskflow_sha" "core:$core_sha" "dropin:$dropin_sha" "provenance:$provenance_sha" \
    "windows:$windows_viewflow_sha" "wrapper:$windows_wrapper_sha" "task:$windows_task_sha"; do
    require_sha256 "${pair%%:*} SHA-256" "${pair#*:}"
done
[[ $windows_user_sid =~ ^S-1-[0-9]+(-[0-9]+)+$ ]] || die 'Windows SID is not canonical'
[[ $readiness_timeout =~ ^[1-9][0-9]*$ && $readiness_timeout -le 300 ]] ||
    die 'readiness timeout must be 1-300 seconds'
if [[ $command == rollback ]]; then
    for value in "$active_recovery_publish_receipt" "$active_recovery_operation_id" \
        "$active_recovery_coordinator_id" "$active_recovery_generation" "$active_recovery_marker_sha"; do
        [[ -n $value ]] || die 'rollback requires the complete active recovery marker contract'
    done
    require_uuid32 '--active-recovery-marker-operation-id' "$active_recovery_operation_id"
    require_uuid32 '--active-recovery-marker-coordinator-instance-id' "$active_recovery_coordinator_id"
    require_u64_decimal '--active-recovery-marker-generation' "$active_recovery_generation"
    require_sha256 '--active-recovery-marker-sha256' "$active_recovery_marker_sha"
else
    [[ -z $active_recovery_publish_receipt && -z $active_recovery_operation_id &&
       -z $active_recovery_coordinator_id && -z $active_recovery_generation &&
       -z $active_recovery_marker_sha ]] ||
        die 'active recovery marker options are valid only for rollback'
fi
[[ $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] ||
    die 'run as uid 1000 with HOME=/home/wilf'
for utility in awk chmod date grep head install jq journalctl ln mkdir mktemp mv python3 \
    readlink rm sed sha256sum ss stat systemctl; do
    command -v "$utility" >/dev/null || die "required command is unavailable: $utility"
done

readonly backup_dir=${stage_receipt}.backup
readonly consumed_dir=$backup_dir/consumed
readonly consumed_linux=$consumed_dir/viewflow-v13-bootstrap-frozen.json
readonly consumed_force=$consumed_dir/viewflow-force-release-envelope.json
readonly consumed_windows=$consumed_dir/viewflow-v2-windows-installed.json
readonly consume_intent=$backup_dir/consume-intent.json
transaction_started=0
evidence_moved=0
final_committed=0

assert_candidates() {
    assert_candidate_executable 'Viewflow candidate' "$viewflow_candidate" "$viewflow_sha"
    assert_candidate_executable 'deployment marker candidate' "$marker_candidate" "$marker_tool_sha"
    require_absolute_regular 'Viewflow unit candidate' "$unit_candidate"
    assert_hash 'Viewflow unit candidate' "$unit_candidate" "$unit_sha"
    assert_viewflow_unit_contract "$unit_candidate"
    assert_candidate_executable 'Deskflow candidate' "$deskflow_candidate" "$deskflow_sha"
    assert_candidate_executable 'deskflow-core candidate' "$core_candidate" "$core_sha"
    require_absolute_regular 'Deskflow drop-in candidate' "$dropin_candidate"
    assert_hash 'Deskflow drop-in candidate' "$dropin_candidate" "$dropin_sha"
    assert_evidence 'Deskflow provenance manifest' "$provenance"
    assert_hash 'Deskflow provenance manifest' "$provenance" "$provenance_sha"
    "$SCRIPT_DIR/check-deskflow-provenance.sh" --manifest "$provenance" \
        --manifest-sha256 "$provenance_sha" --deskflow-candidate "$deskflow_candidate" \
        --deskflow-sha256 "$deskflow_sha" --deskflow-core-candidate "$core_candidate" \
        --deskflow-core-sha256 "$core_sha" >/dev/null
}

validate_backup_manifest() {
    local path=$1
    assert_owner_file 'stage backup manifest' "$path" 600
    assert_strict_json 'stage backup manifest' "$path"
    for name in viewflowd viewflow-deployment-marker viewflow-peer.service deskflow deskflow-core deskflow-viewflow.conf; do
        require_absolute_regular "stage backup $name" "$backup_dir/$name"
    done
    jq -e --arg op "$operation_id" --arg old_vf "$(sha256 "$backup_dir/viewflowd")" \
        --arg old_marker "$(sha256 "$backup_dir/viewflow-deployment-marker")" \
        --arg old_unit "$(sha256 "$backup_dir/viewflow-peer.service")" \
        --arg deskflow "$(sha256 "$backup_dir/deskflow")" --arg core "$(sha256 "$backup_dir/deskflow-core")" \
        --arg dropin "$(sha256 "$backup_dir/deskflow-viewflow.conf")" '
        (keys == ["artifact_hashes","operation_id","schema_version","state"]) and
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-stage-backup" and
        .operation_id == $op and
        .artifact_hashes == {old_viewflowd:$old_vf,old_deployment_marker_tool:$old_marker,
                             old_viewflow_unit:$old_unit,preserved_deskflow:$deskflow,
                             preserved_deskflow_core:$core,preserved_deskflow_dropin:$dropin}
    ' "$path" >/dev/null || die 'stage backup manifest is invalid'
}

validate_stage_receipt() {
    local path=$1 linux_path=$2 envelope_path=$3 publish_path=$4
    local linux_sha envelope_sha handoff_sha request_sha prepared_sha permit_sha publish_sha manifest_sha
    local marker_mode=${5:-active} expected_marker_identity expected_marker_sha
    assert_owner_file 'stage receipt' "$path" 600
    assert_strict_json 'stage receipt' "$path"
    case $marker_mode in
        active)
            expected_marker_identity=$BOOTSTRAP_MARKER_IDENTITY
            expected_marker_sha=$BOOTSTRAP_MARKER_SHA
            ;;
        historical)
            expected_marker_identity=$(jq -er '.marker.identity |
                select(type == "string" and test("^[0-9]+:[0-9]+:1000:600:1:256$"))' "$path")
            expected_marker_sha=$(jq -er '.deployment_marker_sha256 |
                select(type == "string" and test("^[0-9a-f]{64}$"))' "$handoff_receipt")
            ;;
        *) die 'unsupported stage marker validation mode' ;;
    esac
    validate_backup_manifest "$backup_dir/manifest.json"
    linux_sha=$(sha256 "$linux_path")
    envelope_sha=$(sha256 "$envelope_path")
    handoff_sha=$(sha256 "$handoff_receipt")
    request_sha=$(sha256 "$bootstrap_request")
    prepared_sha=$(sha256 "$prepared_receipt")
    permit_sha=$(sha256 "$mutation_permit")
    publish_sha=$(sha256 "$publish_path")
    manifest_sha=$(sha256 "$backup_dir/manifest.json")
    jq -e --arg op "$operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg windows "$windows_viewflow_sha" --arg linux "$linux_sha" --arg envelope "$envelope_sha" \
        --arg handoff "$handoff_sha" --arg request "$request_sha" --arg prepared "$prepared_sha" --arg permit "$permit_sha" \
        --arg publish "$publish_sha" --arg marker_path "$DEPLOYMENT_MARKER" \
        --arg marker_id "$expected_marker_identity" --arg marker_sha "$expected_marker_sha" \
        --arg coordinator "$coordinator_instance_id" --arg generation "$marker_generation" \
        --arg backup "$backup_dir" --arg manifest "$manifest_sha" --arg old_vf "$(sha256 "$backup_dir/viewflowd")" \
        --arg old_marker "$(sha256 "$backup_dir/viewflow-deployment-marker")" \
        --arg old_unit "$(sha256 "$backup_dir/viewflow-peer.service")" \
        --arg deskflow "$(sha256 "$backup_dir/deskflow")" --arg core "$(sha256 "$backup_dir/deskflow-core")" \
        --arg dropin "$(sha256 "$backup_dir/deskflow-viewflow.conf")" --arg new_vf "$viewflow_sha" \
        --arg new_marker "$marker_tool_sha" --arg new_unit "$unit_sha" --arg peer "$EXPECTED_WINDOWS_PEER_IP" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        (keys == ["artifact_hashes","backup_directory","backup_manifest_sha256","completed_at_unix_ms",
                  "evidence_hashes","freeze_state","marker","operation_id","protocol_version","runtime","schema_version",
                  "source_display_id","state","target_device_id","windows_viewflow_sha256"]) and
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-staged" and .operation_id == $op and
        .protocol_version == "2.1" and .source_display_id == $source and .target_device_id == $target and
        .windows_viewflow_sha256 == $windows and
        .evidence_hashes == {bootstrap_request:$request,linux_frozen_evidence:$linux,
                             marker_handoff_receipt:$handoff,mutation_permit:$permit,
                             windows_force_release_envelope:$envelope,windows_prepared_receipt:$prepared,
                             deployment_publish_receipt:$publish} and
        .freeze_state == {deskflow_unit_active_state:"inactive",deskflow_unit_main_pid:0,
                          deskflow_exact_process_count:0,deskflow_core_exact_process_count:0,
                          deskflow_tcp_listener_count:0,runtime_marker_path:"/home/wilf/.local/state/viewflow/deskflow-quarantine.v2",
                          runtime_marker_present:false} and
        .marker == {path:$marker_path,identity:$marker_id,sha256:$marker_sha,
                    coordinator_instance_id:$coordinator,marker_generation:$generation} and
        .artifact_hashes == {old_viewflowd:$old_vf,old_deployment_marker_tool:$old_marker,
                             old_viewflow_unit:$old_unit,staged_viewflowd:$new_vf,
                             staged_deployment_marker_tool:$new_marker,staged_viewflow_unit:$new_unit,
                             preserved_deskflow:$deskflow,preserved_deskflow_core:$core,
                             preserved_deskflow_dropin:$dropin} and
        .backup_directory == $backup and .backup_manifest_sha256 == $manifest and
        (.runtime | keys == ["authenticated_at_unix_ms","authenticated_peer_ip",
                             "authenticated_peer_record_sha256","boot_id","invocation_id","pid","start_ticks"]) and
        .runtime.authenticated_peer_ip == $peer and (.runtime.authenticated_peer_record_sha256 | hash) and
        (.runtime.pid | uint53 and . > 0) and (.runtime.start_ticks | uint53 and . > 0) and
        (.runtime.authenticated_at_unix_ms | uint53 and . > 0) and
        (.runtime.boot_id | type == "string" and test("^[0-9a-f-]{36}$")) and
        (.runtime.invocation_id | type == "string" and test("^[0-9a-f]{32}$"))
    ' "$path" >/dev/null || die 'stage receipt does not match the exact finalize inputs'
}

validate_prearm_chain() {
    local linux_path=$1 envelope_path=$2 linux_sha handoff_sha request_sha prepared_sha permit_sha historical_marker_sha
    linux_sha=$(sha256 "$linux_path")
    handoff_sha=$(sha256 "$handoff_receipt")
    request_sha=$(sha256 "$bootstrap_request")
    prepared_sha=$(sha256 "$prepared_receipt")
    permit_sha=$(sha256 "$mutation_permit")
    historical_marker_sha=$(jq -er '.marker.sha256 |
        select(type == "string" and test("^[0-9a-f]{64}$"))' "$stage_receipt")
    validate_publish_receipt "$publish_receipt" "$operation_id" "$source_display_id" "$target_device_id" \
        "$coordinator_instance_id" "$marker_generation" "$historical_marker_sha"
    validate_handoff_receipt "$handoff_receipt" "$publish_receipt" "$operation_id" \
        "$source_display_id" "$target_device_id" "$coordinator_instance_id" "$marker_generation" \
        "$marker_tool_sha" "$(sha256 "$backup_dir/deskflow")" "$(sha256 "$backup_dir/deskflow-core")" \
        "$historical_marker_sha"
    validate_bootstrap_request_receipt "$bootstrap_request" "$operation_id" "$handoff_sha" \
        "$linux_sha" "$windows_viewflow_sha" "$windows_user_sid"
    validate_windows_prepared_receipt "$prepared_receipt" "$operation_id" "$request_sha" \
        "$handoff_sha" "$linux_sha" "$windows_viewflow_sha" "$windows_user_sid"
    validate_mutation_permit_receipt "$mutation_permit" "$operation_id" "$coordinator_instance_id" \
        "$request_sha" "$handoff_sha" "$prepared_sha" "$linux_sha" "$windows_viewflow_sha" \
        "$bootstrap_request" "$viewflow_sha" "$marker_tool_sha" "$unit_sha"
    validate_force_envelope_receipt "$envelope_path" "$operation_id" "$request_sha" "$handoff_sha" \
        "$prepared_sha" "$permit_sha" "$linux_sha" "$windows_user_sid"
}

raw_force_sha_from_envelope() {
    jq -er '.raw_force_release_receipt_sha256 |
        select(type == "string" and test("^[0-9a-f]{64}$"))' "$1"
}

assert_staged_viewflow_live() {
    local receipt_pid pid invocation peer_count
    receipt_pid=$(jq -er '.runtime.pid' "$stage_receipt")
    pid=$(unit_pid "$VIEWFLOW_UNIT")
    [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active &&
       $pid == "$receipt_pid" && $(readlink -f -- "/proc/$pid/exe") == "$VIEWFLOW_INSTALLED" ]] ||
        die 'staged Viewflow live identity changed'
    assert_hash 'live staged Viewflow' "/proc/$pid/exe" "$viewflow_sha"
    invocation=$(systemctl --user show --property InvocationID --value "$VIEWFLOW_UNIT")
    [[ $invocation == "$(jq -er '.runtime.invocation_id' "$stage_receipt")" ]] ||
        die 'staged Viewflow invocation changed'
    peer_count=$(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
        grep -Ec "^viewflowd server authenticated peer ${EXPECTED_WINDOWS_PEER_IP//./\\.}:")
    ((peer_count > 0)) || die 'staged Viewflow has no exact Windows authenticated-peer proof'
    [[ -S $VIEWFLOW_ACCEPTANCE_SOCKET && $(stat -c '%u %a' -- "$VIEWFLOW_ACCEPTANCE_SOCKET") == '1000 600' ]] ||
        die 'staged Viewflow acceptance socket is not owner-only'
    ss -H -lunp "sport = :$VIEWFLOW_PORT" | grep -Fq "pid=$pid," || die 'staged Viewflow UDP listener identity changed'
}

assert_deskflow_inactive_with_old_bytes() {
    assert_hash 'pre-finalize Deskflow' "$DESKFLOW_INSTALLED" "$(sha256 "$backup_dir/deskflow")"
    assert_hash 'pre-finalize deskflow-core' "$DESKFLOW_CORE_INSTALLED" "$(sha256 "$backup_dir/deskflow-core")"
    assert_hash 'pre-finalize Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED" "$(sha256 "$backup_dir/deskflow-viewflow.conf")"
    [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) != active &&
       $(unit_pid "$DESKFLOW_UNIT") == 0 && -z $(exact_executable_pids "$DESKFLOW_INSTALLED") &&
       -z $(exact_executable_pids "$DESKFLOW_CORE_INSTALLED") ]] || die 'Deskflow must remain inactive before finalize'
    assert_no_listener tcp "$DESKFLOW_PORT"
}

restore_all_old_files() {
    local failed=0
    stop_both_units 30 || failed=1
    assert_marker_unchanged || return 1
    validate_backup_manifest "$backup_dir/manifest.json" || return 1
    atomic_install "$backup_dir/viewflowd" "$VIEWFLOW_INSTALLED" 0755 || failed=1
    atomic_install "$backup_dir/viewflow-deployment-marker" "$DEPLOYMENT_MARKER_TOOL_INSTALLED" 0755 || failed=1
    atomic_install "$backup_dir/viewflow-peer.service" "$VIEWFLOW_UNIT_INSTALLED" 0644 || failed=1
    atomic_install "$backup_dir/deskflow" "$DESKFLOW_INSTALLED" 0755 || failed=1
    atomic_install "$backup_dir/deskflow-core" "$DESKFLOW_CORE_INSTALLED" 0755 || failed=1
    atomic_install "$backup_dir/deskflow-viewflow.conf" "$DESKFLOW_DROPIN_INSTALLED" 0644 || failed=1
    systemctl --user daemon-reload || failed=1
    stop_both_units 30 || failed=1
    assert_marker_unchanged || failed=1
    return "$failed"
}

restore_consumed_evidence() {
    local failed=0 name original consumed current expected
    if [[ -e $consume_intent || -L $consume_intent ]]; then
        validate_consume_intent "$consume_intent" || return 1
        for name in linux_frozen_evidence windows_force_release_envelope windows_install_receipt; do
            current=$(resolve_intent_artifact "$name") || return 1
            original=$(jq -er --arg name "$name" '.artifacts[$name].original_path' "$consume_intent") || return 1
            consumed=$(jq -er --arg name "$name" '.artifacts[$name].consumed_path' "$consume_intent") || return 1
            expected=$(jq -er --arg name "$name" '.artifacts[$name].sha256' "$consume_intent") || return 1
            if [[ $current == "$consumed" ]]; then
                atomic_move_no_replace "restore consume intent artifact $name" \
                    "$consumed" "$original" "$expected" || failed=1
                ((failed)) || assert_hash "restored consume intent artifact $name" "$original" "$expected" || failed=1
            fi
        done
        return "$failed"
    fi
    [[ ! -e $consumed_linux && ! -L $consumed_linux &&
       ! -e $consumed_force && ! -L $consumed_force &&
       ! -e $consumed_windows && ! -L $consumed_windows ]] ||
        die 'consumed evidence exists without a durable consume intent'
    return "$failed"
}

validate_consume_intent() {
    local path=$1
    assert_owner_file 'bootstrap consume intent' "$path" 600 || return 1
    assert_strict_json 'bootstrap consume intent' "$path" || return 1
    jq -e --arg op "$operation_id" --arg stage "$(sha256 "$stage_receipt")" \
        --arg linux_original "$linux_evidence" --arg linux_consumed "$consumed_linux" \
        --arg force_original "$force_envelope" --arg force_consumed "$consumed_force" \
        --arg windows_original "$windows_install_receipt" --arg windows_consumed "$consumed_windows" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        def artifact:
            (keys == ["consumed_path","original_path","sha256"]) and
            (.original_path | type == "string" and startswith("/")) and
            (.consumed_path | type == "string" and startswith("/")) and
            (.sha256 | hash);
        (keys == ["artifacts","created_at_unix_ms","operation_id","schema_version",
                  "stage_receipt_sha256","state"]) and
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-consume-intent" and
        .operation_id == $op and .stage_receipt_sha256 == $stage and
        (.created_at_unix_ms | type == "number" and . == floor and . > 0) and
        (.artifacts | keys == ["linux_frozen_evidence","windows_force_release_envelope",
                              "windows_install_receipt"]) and
        all(.artifacts[]; artifact) and
        .artifacts.linux_frozen_evidence.original_path == $linux_original and
        .artifacts.linux_frozen_evidence.consumed_path == $linux_consumed and
        .artifacts.windows_force_release_envelope.original_path == $force_original and
        .artifacts.windows_force_release_envelope.consumed_path == $force_consumed and
        .artifacts.windows_install_receipt.original_path == $windows_original and
        .artifacts.windows_install_receipt.consumed_path == $windows_consumed
    ' "$path" >/dev/null || die 'bootstrap consume intent is invalid'
}

create_or_validate_consume_intent() {
    local temp
    if [[ -e $consume_intent || -L $consume_intent ]]; then
        validate_consume_intent "$consume_intent"
        return
    fi
    assert_evidence 'Linux frozen evidence before consume intent' "$linux_evidence"
    assert_evidence 'Windows force envelope before consume intent' "$force_envelope"
    assert_evidence 'Windows install receipt before consume intent' "$windows_install_receipt"
    [[ ! -e $consumed_linux && ! -L $consumed_linux &&
       ! -e $consumed_force && ! -L $consumed_force &&
       ! -e $consumed_windows && ! -L $consumed_windows ]] ||
        die 'consumed evidence exists without a durable consume intent'
    temp=$(mktemp --tmpdir="$backup_dir" '.consume-intent.XXXXXXXX')
    chmod 0600 "$temp"
    jq -cn --arg op "$operation_id" --arg stage "$(sha256 "$stage_receipt")" \
        --arg linux_original "$linux_evidence" --arg linux_consumed "$consumed_linux" \
        --arg linux_sha "$(sha256 "$linux_evidence")" \
        --arg force_original "$force_envelope" --arg force_consumed "$consumed_force" \
        --arg force_sha "$(sha256 "$force_envelope")" \
        --arg windows_original "$windows_install_receipt" --arg windows_consumed "$consumed_windows" \
        --arg windows_sha "$(sha256 "$windows_install_receipt")" \
        --argjson created "$(date -u +%s%3N)" \
        '{schema_version:1,state:"viewflow-linux-bootstrap-consume-intent",operation_id:$op,
          stage_receipt_sha256:$stage,created_at_unix_ms:$created,
          artifacts:{linux_frozen_evidence:{original_path:$linux_original,consumed_path:$linux_consumed,sha256:$linux_sha},
                     windows_force_release_envelope:{original_path:$force_original,consumed_path:$force_consumed,sha256:$force_sha},
                     windows_install_receipt:{original_path:$windows_original,consumed_path:$windows_consumed,sha256:$windows_sha}}}' >"$temp"
    publish_no_clobber "$temp" "$consume_intent"
    rm -f -- "$temp"
    validate_consume_intent "$consume_intent"
}

resolve_intent_artifact() {
    local name=$1 original consumed expected original_present=0 consumed_present=0
    original=$(jq -er --arg name "$name" '.artifacts[$name].original_path' "$consume_intent")
    consumed=$(jq -er --arg name "$name" '.artifacts[$name].consumed_path' "$consume_intent")
    expected=$(jq -er --arg name "$name" '.artifacts[$name].sha256' "$consume_intent")
    [[ -e $original || -L $original ]] && original_present=1
    [[ -e $consumed || -L $consumed ]] && consumed_present=1
    ((original_present + consumed_present == 1)) || {
        die "consume intent artifact $name must exist at exactly one exact path"
        return 1
    }
    if ((original_present)); then
        assert_owner_file "consume intent original $name" "$original" 600 || return 1
        assert_hash "consume intent original $name" "$original" "$expected" || return 1
        printf '%s\n' "$original"
    else
        assert_owner_file "consume intent consumed $name" "$consumed" 600 || return 1
        assert_hash "consume intent consumed $name" "$consumed" "$expected" || return 1
        printf '%s\n' "$consumed"
    fi
}

validate_consumption_subset() {
    validate_consume_intent "$consume_intent" || return 1
    resolve_intent_artifact linux_frozen_evidence >/dev/null || return 1
    resolve_intent_artifact windows_force_release_envelope >/dev/null || return 1
    resolve_intent_artifact windows_install_receipt >/dev/null || return 1
}

complete_evidence_consumption() {
    local name original consumed current
    mkdir -p -- "$consumed_dir"
    chmod 0700 -- "$consumed_dir"
    assert_owner_directory 'consumed evidence directory' "$consumed_dir"
    for name in linux_frozen_evidence windows_force_release_envelope windows_install_receipt; do
        current=$(resolve_intent_artifact "$name")
        original=$(jq -er --arg name "$name" '.artifacts[$name].original_path' "$consume_intent")
        consumed=$(jq -er --arg name "$name" '.artifacts[$name].consumed_path' "$consume_intent")
        if [[ $current == "$original" ]]; then
            atomic_move_no_replace "consume intent artifact $name" \
                "$original" "$consumed" \
                "$(jq -er --arg name "$name" '.artifacts[$name].sha256' "$consume_intent")"
        fi
    done
    [[ $(resolve_intent_artifact linux_frozen_evidence) == "$consumed_linux" &&
       $(resolve_intent_artifact windows_force_release_envelope) == "$consumed_force" &&
       $(resolve_intent_artifact windows_install_receipt) == "$consumed_windows" ]] ||
        die 'consume intent did not converge to all consumed paths'
}

validate_all_consumed() {
    validate_consumption_subset
    [[ $(resolve_intent_artifact linux_frozen_evidence) == "$consumed_linux" &&
       $(resolve_intent_artifact windows_force_release_envelope) == "$consumed_force" &&
       $(resolve_intent_artifact windows_install_receipt) == "$consumed_windows" ]] ||
        die 'final receipt requires all three evidence artifacts at their consumed paths'
}

find_core_pid() {
    local gui_pid=$1 candidate ppid
    for candidate in $(exact_executable_pids "$DESKFLOW_CORE_INSTALLED"); do
        ppid=$(awk '/^PPid:/ {print $2}' "/proc/$candidate/status")
        [[ $ppid == "$gui_pid" ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

process_has_environment() {
    grep -Fzx -- "$2" "/proc/$1/environ"
}

wait_deskflow_ready_under_marker() {
    local deadline=$((SECONDS + readiness_timeout)) gui core
    while ((SECONDS < deadline)); do
        assert_marker_unchanged
        assert_runtime_marker_absent
        if [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) == active ]]; then
            gui=$(unit_pid "$DESKFLOW_UNIT" 2>/dev/null || true)
            core=$(find_core_pid "$gui" 2>/dev/null || true)
            if [[ $gui =~ ^[1-9][0-9]*$ && $core =~ ^[1-9][0-9]*$ ]] &&
                assert_hash 'live Deskflow' "/proc/$gui/exe" "$deskflow_sha" &&
                assert_hash 'live deskflow-core' "/proc/$core/exe" "$core_sha" &&
                process_has_environment "$gui" "DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$DEPLOYMENT_MARKER" &&
                process_has_environment "$core" "DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$DEPLOYMENT_MARKER" &&
                process_has_environment "$core" "DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET" &&
                [[ -S $DESKFLOW_ACCEPTANCE_SOCKET && ! -L $DESKFLOW_ACCEPTANCE_SOCKET &&
                   $(stat -c '%u %a' -- "$DESKFLOW_ACCEPTANCE_SOCKET") == '1000 600' ]] &&
                ss -H -ltnp "sport = :$DESKFLOW_PORT" | grep -Fq "pid=$core,"; then
                jq -cn --argjson viewflow_pid "$(unit_pid "$VIEWFLOW_UNIT")" \
                    --argjson viewflow_ticks "$(process_start_ticks "$(unit_pid "$VIEWFLOW_UNIT")")" \
                    --arg viewflow_invocation "$(systemctl --user show --property InvocationID --value "$VIEWFLOW_UNIT")" \
                    --argjson deskflow_pid "$gui" --argjson deskflow_ticks "$(process_start_ticks "$gui")" \
                    --argjson core_pid "$core" --argjson core_ticks "$(process_start_ticks "$core")" \
                    '{viewflow_pid:$viewflow_pid,viewflow_start_ticks:$viewflow_ticks,
                      viewflow_invocation_id:$viewflow_invocation,deskflow_pid:$deskflow_pid,
                      deskflow_start_ticks:$deskflow_ticks,deskflow_core_pid:$core_pid,
                      deskflow_core_start_ticks:$core_ticks}'
                return 0
            fi
        fi
        sleep 0.1
    done
    die 'patched Deskflow/core did not become ready under retained VFDQT001'
}

validate_final_receipt() {
    local path=$1 linux_path=$2 force_path=$3 windows_path=$4
    local linux_sha envelope_sha windows_sha stage_sha publish_sha handoff_sha request_sha prepared_sha permit_sha
    assert_owner_file 'final receipt' "$path" 600
    assert_strict_json 'final receipt' "$path"
    linux_sha=$(sha256 "$linux_path"); envelope_sha=$(sha256 "$force_path"); windows_sha=$(sha256 "$windows_path")
    stage_sha=$(sha256 "$stage_receipt"); publish_sha=$(sha256 "$publish_receipt")
    handoff_sha=$(sha256 "$handoff_receipt"); request_sha=$(sha256 "$bootstrap_request")
    prepared_sha=$(sha256 "$prepared_receipt"); permit_sha=$(sha256 "$mutation_permit")
    jq -e --arg op "$operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg stage "$stage_sha" --arg linux "$linux_sha" --arg envelope "$envelope_sha" --arg windows "$windows_sha" \
        --arg handoff "$handoff_sha" --arg request "$request_sha" --arg prepared "$prepared_sha" --arg permit "$permit_sha" \
        --arg publish "$publish_sha" --arg provenance "$provenance_sha" \
        --arg marker "$(jq -er '.marker.sha256' "$stage_receipt")" \
        --arg vf "$viewflow_sha" --arg marker_tool "$marker_tool_sha" --arg unit "$unit_sha" \
        --arg deskflow "$deskflow_sha" --arg core "$core_sha" --arg dropin "$dropin_sha" \
        --arg consumed_linux "$consumed_linux" --arg consumed_force "$consumed_force" --arg consumed_windows "$consumed_windows" '
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        (keys == ["artifact_hashes","completed_at_unix_ms","consumed_evidence","evidence_hashes","marker_sha256",
                  "operation_id","protocol_version","provenance_sha256","runtime","schema_version",
                  "source_display_id","stage_receipt_sha256","state","target_device_id"]) and
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-finalized" and .operation_id == $op and
        .protocol_version == "2.1" and .source_display_id == $source and .target_device_id == $target and
        .stage_receipt_sha256 == $stage and .provenance_sha256 == $provenance and .marker_sha256 == $marker and
        .evidence_hashes == {bootstrap_request:$request,linux_frozen_evidence:$linux,
                             marker_handoff_receipt:$handoff,mutation_permit:$permit,
                             windows_force_release_envelope:$envelope,windows_install_receipt:$windows,
                             windows_prepared_receipt:$prepared,deployment_publish_receipt:$publish} and
        .consumed_evidence == {linux_frozen_evidence:$consumed_linux,
                               windows_force_release_envelope:$consumed_force,
                               windows_install_receipt:$consumed_windows} and
        .artifact_hashes == {viewflowd:$vf,deployment_marker_tool:$marker_tool,viewflow_unit:$unit,
                             deskflow:$deskflow,deskflow_core:$core,deskflow_dropin:$dropin} and
        (.runtime | keys == ["deskflow_core_pid","deskflow_core_start_ticks","deskflow_pid",
                             "deskflow_start_ticks","viewflow_invocation_id","viewflow_pid",
                             "viewflow_start_ticks"]) and
        (.runtime.viewflow_pid | uint53 and . > 0) and (.runtime.deskflow_pid | uint53 and . > 0) and
        (.runtime.deskflow_core_pid | uint53 and . > 0) and
        (.runtime.viewflow_start_ticks | uint53 and . > 0) and
        (.runtime.deskflow_start_ticks | uint53 and . > 0) and
        (.runtime.deskflow_core_start_ticks | uint53 and . > 0) and
        (.runtime.viewflow_invocation_id | type == "string" and test("^[0-9a-f]{32}$")) and
        (.completed_at_unix_ms | uint53 and . > 0)
    ' "$path" >/dev/null || die 'final receipt is invalid or does not match the exact query inputs'
    assert_marker_unchanged
    assert_hash 'final Viewflow' "$VIEWFLOW_INSTALLED" "$viewflow_sha"
    assert_hash 'final marker CLI' "$DEPLOYMENT_MARKER_TOOL_INSTALLED" "$marker_tool_sha"
    assert_hash 'final Viewflow unit' "$VIEWFLOW_UNIT_INSTALLED" "$unit_sha"
    assert_hash 'final Deskflow' "$DESKFLOW_INSTALLED" "$deskflow_sha"
    assert_hash 'final deskflow-core' "$DESKFLOW_CORE_INSTALLED" "$core_sha"
    assert_hash 'final Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED" "$dropin_sha"
}

validate_active_recovery_marker() {
    local stage_marker_sha active_publish_sha original_publish_sha
    assert_evidence 'active recovery marker publish receipt' "$active_recovery_publish_receipt" || return 1
    assert_both_units_stopped || return 1
    stage_marker_sha=$(jq -er '.marker.sha256' "$stage_receipt")
    [[ $active_recovery_marker_sha == "$BOOTSTRAP_MARKER_SHA" ]] || {
        die 'active recovery marker SHA does not match current VFDQT001 bytes'
        return 1
    }
    if [[ $active_recovery_generation == "$marker_generation" ]]; then
        [[ $active_recovery_operation_id == "$operation_id" &&
           $active_recovery_coordinator_id == "$coordinator_instance_id" &&
           $active_recovery_marker_sha == "$stage_marker_sha" ]] ||
            { die 'active generation-1 marker contract does not match the original bootstrap chain'; return 1; }
        active_publish_sha=$(sha256 "$active_recovery_publish_receipt")
        original_publish_sha=$(sha256 "$publish_receipt")
        [[ $active_publish_sha == "$original_publish_sha" ]] ||
            { die 'active generation-1 publish receipt is not the original publish receipt'; return 1; }
    elif [[ $active_recovery_generation == 2 ]]; then
        [[ $active_recovery_operation_id != "$operation_id" &&
           $active_recovery_marker_sha != "$stage_marker_sha" ]] ||
            { die 'active generation-2 recovery marker is not distinct from generation 1'; return 1; }
    else
        die 'active marker generation is neither the original generation nor recovery generation 2'
        return 1
    fi
    validate_publish_receipt "$active_recovery_publish_receipt" \
        "$active_recovery_operation_id" "$source_display_id" "$target_device_id" \
        "$active_recovery_coordinator_id" "$active_recovery_generation" \
        "$active_recovery_marker_sha" || return 1
    assert_marker_unchanged || return 1
}

on_failure() {
    local status=$1 command_text=$2
    trap - ERR INT TERM
    set +e
    printf 'finalize failed (%s): %s\n' "$status" "$command_text" >&2
    if ((transaction_started && ! final_committed)); then
        restore_all_old_files || exit 70
        ((evidence_moved)) && restore_consumed_evidence || true
        printf '%s\n' 'finalize rollback restored all old files with both Linux units inactive and VFDQT001 retained' >&2
    fi
    exit "$status"
}
trap 'on_failure $? "$BASH_COMMAND"' ERR
trap 'on_failure 130 signal-INT' INT
trap 'on_failure 143 signal-TERM' TERM

assert_candidates
freeze_marker
if [[ $command == rollback ]]; then
    assert_both_units_stopped
else
    assert_runtime_marker_absent
fi

if [[ $command == rollback ]]; then
    if [[ -e $consume_intent || -L $consume_intent ]]; then
        validate_consumption_subset
        rollback_linux=$(resolve_intent_artifact linux_frozen_evidence)
        rollback_force=$(resolve_intent_artifact windows_force_release_envelope)
        rollback_windows=$(resolve_intent_artifact windows_install_receipt)
        evidence_moved=1
    else
        rollback_linux=$linux_evidence
        rollback_force=$force_envelope
        rollback_windows=$windows_install_receipt
        assert_evidence 'Linux frozen evidence' "$rollback_linux"
        assert_evidence 'Windows force-release envelope' "$rollback_force"
        assert_evidence 'Windows install-success receipt' "$rollback_windows"
        [[ ! -e $consumed_linux && ! -L $consumed_linux &&
           ! -e $consumed_force && ! -L $consumed_force &&
           ! -e $consumed_windows && ! -L $consumed_windows ]] ||
            die 'consumed evidence exists without a durable consume intent'
    fi
    validate_stage_receipt "$stage_receipt" "$rollback_linux" "$rollback_force" "$publish_receipt" historical
    validate_prearm_chain "$rollback_linux" "$rollback_force"
    validate_windows_install_receipt "$rollback_windows" "$operation_id" "$(sha256 "$rollback_linux")" \
        "$(raw_force_sha_from_envelope "$rollback_force")" "$(sha256 "$handoff_receipt")" "$(sha256 "$prepared_receipt")" \
        "$(sha256 "$mutation_permit")" "$(sha256 "$stage_receipt")" "$(sha256 "$bootstrap_request")" \
        "$windows_viewflow_sha" "$windows_wrapper_sha" "$windows_task_sha" "$windows_user_sid"
    if [[ -e $receipt_output || -L $receipt_output ]]; then
        validate_final_receipt "$receipt_output" "$rollback_linux" "$rollback_force" "$rollback_windows"
    fi
    validate_active_recovery_marker
    restore_all_old_files
    restore_consumed_evidence
    assert_marker_unchanged
    printf '{"schema_version":1,"state":"viewflow-linux-bootstrap-final-rolled-back","operation_id":"%s"}\n' "$operation_id"
    exit 0
fi

if [[ $command == query && ! -e $receipt_output && ! -L $receipt_output ]]; then
    [[ -e $consume_intent || -L $consume_intent ]] ||
        die 'neither final receipt nor durable consume intent exists'
    validate_consumption_subset
    query_linux=$(resolve_intent_artifact linux_frozen_evidence)
    query_force=$(resolve_intent_artifact windows_force_release_envelope)
    query_windows=$(resolve_intent_artifact windows_install_receipt)
    validate_stage_receipt "$stage_receipt" "$query_linux" "$query_force" "$publish_receipt"
    validate_prearm_chain "$query_linux" "$query_force"
    validate_windows_install_receipt "$query_windows" "$operation_id" "$(sha256 "$query_linux")" \
        "$(raw_force_sha_from_envelope "$query_force")" "$(sha256 "$handoff_receipt")" \
        "$(sha256 "$prepared_receipt")" "$(sha256 "$mutation_permit")" "$(sha256 "$stage_receipt")" \
        "$(sha256 "$bootstrap_request")" "$windows_viewflow_sha" "$windows_wrapper_sha" \
        "$windows_task_sha" "$windows_user_sid"
    dd if="$consume_intent" status=none
    exit 0
fi

if [[ $command == query || ( $command == finalize && ( -e $receipt_output || -L $receipt_output ) ) ]]; then
    [[ -f $receipt_output && ! -L $receipt_output ]] || die 'final receipt path is unsafe'
    validate_all_consumed
    validate_stage_receipt "$stage_receipt" "$consumed_linux" "$consumed_force" "$publish_receipt"
    validate_prearm_chain "$consumed_linux" "$consumed_force"
    validate_windows_install_receipt "$consumed_windows" "$operation_id" "$(sha256 "$consumed_linux")" \
        "$(raw_force_sha_from_envelope "$consumed_force")" "$(sha256 "$handoff_receipt")" "$(sha256 "$prepared_receipt")" \
        "$(sha256 "$mutation_permit")" "$(sha256 "$stage_receipt")" "$(sha256 "$bootstrap_request")" \
        "$windows_viewflow_sha" "$windows_wrapper_sha" "$windows_task_sha" "$windows_user_sid"
    validate_final_receipt "$receipt_output" "$consumed_linux" "$consumed_force" "$consumed_windows"
    dd if="$receipt_output" status=none
    exit 0
fi

assert_evidence 'bootstrap handoff receipt' "$handoff_receipt"
assert_evidence 'Windows bootstrap request' "$bootstrap_request"
assert_evidence 'Windows prepared receipt' "$prepared_receipt"
assert_evidence 'Windows mutation permit' "$mutation_permit"
assert_evidence 'deployment publish receipt' "$publish_receipt"
if [[ -e $consume_intent || -L $consume_intent ]]; then
    validate_consumption_subset
    active_linux=$(resolve_intent_artifact linux_frozen_evidence)
    active_force=$(resolve_intent_artifact windows_force_release_envelope)
    active_windows=$(resolve_intent_artifact windows_install_receipt)
    evidence_moved=1
else
    active_linux=$linux_evidence
    active_force=$force_envelope
    active_windows=$windows_install_receipt
    assert_evidence 'Linux frozen evidence' "$active_linux"
    assert_evidence 'Windows force-release envelope' "$active_force"
    assert_evidence 'Windows install-success receipt' "$active_windows"
fi
validate_stage_receipt "$stage_receipt" "$active_linux" "$active_force" "$publish_receipt"
linux_sha=$(sha256 "$active_linux")
validate_linux_frozen_evidence "$active_linux" "$operation_id" "$(sha256 "$backup_dir/viewflowd")"
validate_prearm_chain "$active_linux" "$active_force"
validate_windows_install_receipt "$active_windows" "$operation_id" "$linux_sha" "$(raw_force_sha_from_envelope "$active_force")" \
    "$(sha256 "$handoff_receipt")" "$(sha256 "$prepared_receipt")" "$(sha256 "$mutation_permit")" \
    "$(sha256 "$stage_receipt")" "$(sha256 "$bootstrap_request")" "$windows_viewflow_sha" \
    "$windows_wrapper_sha" "$windows_task_sha" "$windows_user_sid"
assert_staged_viewflow_live
assert_deskflow_inactive_with_old_bytes
require_new_output 'final receipt' "$receipt_output"
[[ $(stat -c '%d' -- "$active_linux") == "$(stat -c '%d' -- "$backup_dir")" &&
   $(stat -c '%d' -- "$active_force") == "$(stat -c '%d' -- "$backup_dir")" &&
   $(stat -c '%d' -- "$active_windows") == "$(stat -c '%d' -- "$backup_dir")" ]] ||
    die 'L/F/W must be on the stage-backup filesystem for atomic consumption'

transaction_started=1
# TRANSACTION_PHASE: BOOTSTRAP_FINALIZE_CONSUME_L_F_W
create_or_validate_consume_intent
evidence_moved=1
complete_evidence_consumption
validate_stage_receipt "$stage_receipt" "$consumed_linux" "$consumed_force" "$publish_receipt"
validate_prearm_chain "$consumed_linux" "$consumed_force"
validate_windows_install_receipt "$consumed_windows" "$operation_id" "$(sha256 "$consumed_linux")" \
    "$(raw_force_sha_from_envelope "$consumed_force")" "$(sha256 "$handoff_receipt")" "$(sha256 "$prepared_receipt")" \
    "$(sha256 "$mutation_permit")" "$(sha256 "$stage_receipt")" "$(sha256 "$bootstrap_request")" \
    "$windows_viewflow_sha" "$windows_wrapper_sha" "$windows_task_sha" "$windows_user_sid"
assert_marker_unchanged

# TRANSACTION_PHASE: BOOTSTRAP_FINALIZE_INSTALL_DESKFLOW
atomic_install "$deskflow_candidate" "$DESKFLOW_INSTALLED" 0755
atomic_install "$core_candidate" "$DESKFLOW_CORE_INSTALLED" 0755
atomic_install "$dropin_candidate" "$DESKFLOW_DROPIN_INSTALLED" 0644
assert_hash 'installed Deskflow' "$DESKFLOW_INSTALLED" "$deskflow_sha"
assert_hash 'installed deskflow-core' "$DESKFLOW_CORE_INSTALLED" "$core_sha"
assert_hash 'installed Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED" "$dropin_sha"
assert_hash 'unchanged staged Viewflow' "$VIEWFLOW_INSTALLED" "$viewflow_sha"
assert_hash 'unchanged staged marker CLI' "$DEPLOYMENT_MARKER_TOOL_INSTALLED" "$marker_tool_sha"
assert_hash 'unchanged staged Viewflow unit' "$VIEWFLOW_UNIT_INSTALLED" "$unit_sha"
assert_marker_unchanged
assert_runtime_marker_absent
systemctl --user daemon-reload

# TRANSACTION_PHASE: BOOTSTRAP_FINALIZE_START_DESKFLOW_UNDER_RETAINED_MARKER
systemctl --user start "$DESKFLOW_UNIT"
runtime_json=$(wait_deskflow_ready_under_marker)
readonly runtime_json
assert_marker_unchanged

receipt_temp=$(mktemp --tmpdir="$(dirname -- "$receipt_output")" '.viewflow-final.XXXXXXXX')
chmod 0600 "$receipt_temp"
jq -cn --arg op "$operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
    --arg stage "$(sha256 "$stage_receipt")" --arg linux "$(sha256 "$consumed_linux")" \
    --arg envelope "$(sha256 "$consumed_force")" --arg windows "$(sha256 "$consumed_windows")" \
    --arg handoff "$(sha256 "$handoff_receipt")" --arg request "$(sha256 "$bootstrap_request")" \
    --arg prepared "$(sha256 "$prepared_receipt")" --arg permit "$(sha256 "$mutation_permit")" \
    --arg publish "$(sha256 "$publish_receipt")" --arg provenance "$provenance_sha" \
    --arg marker "$BOOTSTRAP_MARKER_SHA" --arg vf "$viewflow_sha" --arg marker_tool "$marker_tool_sha" \
    --arg unit "$unit_sha" --arg deskflow "$deskflow_sha" --arg core "$core_sha" --arg dropin "$dropin_sha" \
    --arg consumed_linux "$consumed_linux" --arg consumed_force "$consumed_force" \
    --arg consumed_windows "$consumed_windows" --argjson runtime "$runtime_json" \
    --argjson completed "$(date -u +%s%3N)" \
    '{schema_version:1,state:"viewflow-linux-bootstrap-finalized",operation_id:$op,
      protocol_version:"2.1",source_display_id:$source,target_device_id:$target,
      stage_receipt_sha256:$stage,
      evidence_hashes:{bootstrap_request:$request,linux_frozen_evidence:$linux,
                       marker_handoff_receipt:$handoff,mutation_permit:$permit,
                       windows_force_release_envelope:$envelope,windows_install_receipt:$windows,
                       windows_prepared_receipt:$prepared,deployment_publish_receipt:$publish},
      consumed_evidence:{linux_frozen_evidence:$consumed_linux,
                         windows_force_release_envelope:$consumed_force,
                         windows_install_receipt:$consumed_windows},
      provenance_sha256:$provenance,marker_sha256:$marker,
      artifact_hashes:{viewflowd:$vf,deployment_marker_tool:$marker_tool,viewflow_unit:$unit,
                       deskflow:$deskflow,deskflow_core:$core,deskflow_dropin:$dropin},
      runtime:$runtime,completed_at_unix_ms:$completed}' >"$receipt_temp"
assert_marker_unchanged
publish_no_clobber "$receipt_temp" "$receipt_output"
rm -f -- "$receipt_temp"
validate_final_receipt "$receipt_output" "$consumed_linux" "$consumed_force" "$consumed_windows"
final_committed=1
transaction_started=0
dd if="$receipt_output" status=none
