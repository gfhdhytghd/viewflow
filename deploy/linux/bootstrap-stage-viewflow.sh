#!/usr/bin/env bash

# Phase 1 of the one-time protocol-1.3 -> protocol-2.1 Linux bootstrap.
# Installs only viewflowd, the coordinator marker CLI, and the Viewflow unit.
# Deskflow remains inactive and byte-for-byte unchanged under retained VFDQT001.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bootstrap-two-phase-common.sh"

command=${1-}
[[ $command == stage || $command == query || $command == rollback ]] || {
    printf '%s\n' 'usage: bootstrap-stage-viewflow.sh stage|query|rollback [options]' >&2
    exit 64
}
shift

viewflow_candidate=''
viewflow_sha=''
marker_candidate=''
marker_tool_sha=''
unit_candidate=''
unit_sha=''
operation_id=''
source_display_id=''
target_device_id=''
coordinator_instance_id=''
marker_generation=''
linux_evidence=''
handoff_receipt=''
bootstrap_request=''
prepared_receipt=''
mutation_permit=''
force_envelope=''
publish_receipt=''
windows_viewflow_sha=''
windows_user_sid=''
receipt_output=''
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
        --operation-id) need_value "$1" "${2-}"; operation_id=$2; shift 2 ;;
        --source-display-id) need_value "$1" "${2-}"; source_display_id=$2; shift 2 ;;
        --target-device-id) need_value "$1" "${2-}"; target_device_id=$2; shift 2 ;;
        --coordinator-instance-id) need_value "$1" "${2-}"; coordinator_instance_id=$2; shift 2 ;;
        --marker-generation) need_value "$1" "${2-}"; marker_generation=$2; shift 2 ;;
        --bootstrap-linux-evidence) need_value "$1" "${2-}"; linux_evidence=$2; shift 2 ;;
        --bootstrap-handoff-receipt) need_value "$1" "${2-}"; handoff_receipt=$2; shift 2 ;;
        --windows-bootstrap-request) need_value "$1" "${2-}"; bootstrap_request=$2; shift 2 ;;
        --windows-prepared-receipt) need_value "$1" "${2-}"; prepared_receipt=$2; shift 2 ;;
        --windows-mutation-permit) need_value "$1" "${2-}"; mutation_permit=$2; shift 2 ;;
        --bootstrap-windows-force-receipt|--windows-force-release-envelope)
            need_value "$1" "${2-}"; force_envelope=$2; shift 2 ;;
        --deployment-publish-receipt) need_value "$1" "${2-}"; publish_receipt=$2; shift 2 ;;
        --windows-viewflow-sha256) need_value "$1" "${2-}"; windows_viewflow_sha=${2,,}; shift 2 ;;
        --windows-user-sid) need_value "$1" "${2-}"; windows_user_sid=$2; shift 2 ;;
        --receipt-output) need_value "$1" "${2-}"; receipt_output=$2; shift 2 ;;
        --readiness-timeout-seconds) need_value "$1" "${2-}"; readiness_timeout=$2; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

for value in "$viewflow_candidate" "$viewflow_sha" "$marker_candidate" "$marker_tool_sha" \
    "$unit_candidate" "$unit_sha" "$operation_id" "$source_display_id" "$target_device_id" \
    "$coordinator_instance_id" "$marker_generation" "$linux_evidence" "$handoff_receipt" \
    "$bootstrap_request" "$prepared_receipt" "$mutation_permit" "$force_envelope" \
    "$publish_receipt" "$windows_viewflow_sha" "$windows_user_sid" "$receipt_output"; do
    [[ -n $value ]] || die 'all stage/query/rollback options are mandatory'
done
# Operation IDs are durable artifact namespaces, not display labels.  Do not
# normalize this value: an uppercase spelling must not alias a lower-case
# operation directory or receipt chain.
require_uuid32 '--operation-id' "$operation_id"
require_uuid32 '--source-display-id' "$source_display_id"
require_uuid32 '--target-device-id' "$target_device_id"
require_uuid32 '--coordinator-instance-id' "$coordinator_instance_id"
require_u64_decimal '--marker-generation' "$marker_generation"
[[ $marker_generation == 1 ]] || die 'bootstrap stage marker generation must be exactly 1'
require_sha256 '--viewflow-sha256' "$viewflow_sha"
require_sha256 '--deployment-marker-sha256' "$marker_tool_sha"
require_sha256 '--viewflow-unit-sha256' "$unit_sha"
require_sha256 '--windows-viewflow-sha256' "$windows_viewflow_sha"
[[ $windows_user_sid =~ ^S-1-[0-9]+(-[0-9]+)+$ ]] || die 'Windows SID is not canonical'
[[ $readiness_timeout =~ ^[1-9][0-9]*$ && $readiness_timeout -le 300 ]] ||
    die 'readiness timeout must be 1-300 seconds'
[[ $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] ||
    die 'run as uid 1000 with HOME=/home/wilf'
for utility in awk chmod date grep head install jq journalctl ln mkdir mktemp mv python3 \
    readlink rm sed sha256sum ss stat systemctl; do
    command -v "$utility" >/dev/null || die "required command is unavailable: $utility"
done

readonly backup_dir=${receipt_output}.backup
transaction_started=0

assert_source_inputs() {
    assert_candidate_executable 'Viewflow candidate' "$viewflow_candidate" "$viewflow_sha"
    assert_candidate_executable 'deployment marker candidate' "$marker_candidate" "$marker_tool_sha"
    require_absolute_regular 'Viewflow unit candidate' "$unit_candidate"
    assert_hash 'Viewflow unit candidate' "$unit_candidate" "$unit_sha"
    assert_viewflow_unit_contract "$unit_candidate"
    assert_evidence 'Linux frozen evidence' "$linux_evidence"
    assert_evidence 'bootstrap handoff receipt' "$handoff_receipt"
    assert_evidence 'Windows bootstrap request' "$bootstrap_request"
    assert_evidence 'Windows prepared receipt' "$prepared_receipt"
    assert_evidence 'Windows mutation permit' "$mutation_permit"
    assert_evidence 'Windows force-release envelope' "$force_envelope"
    assert_evidence 'deployment publish receipt' "$publish_receipt"
}

validate_input_chain() {
    local old_sha=$1 deskflow_old_sha core_old_sha
    linux_sha=$(sha256 "$linux_evidence")
    handoff_sha=$(sha256 "$handoff_receipt")
    bootstrap_request_sha=$(sha256 "$bootstrap_request")
    prepared_sha=$(sha256 "$prepared_receipt")
    permit_sha=$(sha256 "$mutation_permit")
    force_envelope_sha=$(sha256 "$force_envelope")
    deskflow_old_sha=$(sha256 "$DESKFLOW_INSTALLED")
    core_old_sha=$(sha256 "$DESKFLOW_CORE_INSTALLED")
    validate_linux_frozen_evidence "$linux_evidence" "$operation_id" "$old_sha"
    validate_publish_receipt "$publish_receipt" "$operation_id" "$source_display_id" \
        "$target_device_id" "$coordinator_instance_id" "$marker_generation" "$BOOTSTRAP_MARKER_SHA"
    validate_handoff_receipt "$handoff_receipt" "$publish_receipt" "$operation_id" \
        "$source_display_id" "$target_device_id" "$coordinator_instance_id" "$marker_generation" \
        "$marker_tool_sha" "$deskflow_old_sha" "$core_old_sha"
    validate_bootstrap_request_receipt "$bootstrap_request" "$operation_id" "$handoff_sha" \
        "$linux_sha" "$windows_viewflow_sha" "$windows_user_sid"
    validate_windows_prepared_receipt "$prepared_receipt" "$operation_id" "$bootstrap_request_sha" \
        "$handoff_sha" "$linux_sha" "$windows_viewflow_sha" "$windows_user_sid"
    validate_mutation_permit_receipt "$mutation_permit" "$operation_id" "$coordinator_instance_id" \
        "$bootstrap_request_sha" "$handoff_sha" "$prepared_sha" "$linux_sha" \
        "$windows_viewflow_sha" "$bootstrap_request" "$viewflow_sha" "$marker_tool_sha" "$unit_sha"
    validate_force_envelope_receipt "$force_envelope" "$operation_id" "$bootstrap_request_sha" \
        "$handoff_sha" "$prepared_sha" "$permit_sha" "$linux_sha" "$windows_user_sid"
}

assert_deskflow_preserved_and_stopped() {
    local deskflow_sha=$1 core_sha=$2 dropin_sha=$3
    assert_hash 'preserved Deskflow' "$DESKFLOW_INSTALLED" "$deskflow_sha"
    assert_hash 'preserved deskflow-core' "$DESKFLOW_CORE_INSTALLED" "$core_sha"
    assert_hash 'preserved Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED" "$dropin_sha"
    [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) != active &&
       $(unit_pid "$DESKFLOW_UNIT") == 0 && -z $(exact_executable_pids "$DESKFLOW_INSTALLED") &&
       -z $(exact_executable_pids "$DESKFLOW_CORE_INSTALLED") ]] ||
        die 'Deskflow changed state during bootstrap stage'
    assert_no_listener tcp "$DESKFLOW_PORT"
    [[ ! -e $DESKFLOW_ACCEPTANCE_SOCKET && ! -L $DESKFLOW_ACCEPTANCE_SOCKET ]] ||
        die 'Deskflow acceptance socket exists while Deskflow is inactive'
}

process_has_argument() {
    grep -Fzx -- "$2" "/proc/$1/cmdline"
}

viewflow_live_snapshot() {
    local expected_pid=${1-} deadline=$((SECONDS + readiness_timeout)) pid exe invocation peer_json
    while ((SECONDS < deadline)); do
        assert_marker_unchanged
        assert_runtime_marker_absent
        if [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active ]]; then
            pid=$(unit_pid "$VIEWFLOW_UNIT" 2>/dev/null || true)
            if [[ $pid =~ ^[1-9][0-9]*$ && -e /proc/$pid/exe ]]; then
                exe=$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)
                invocation=$(systemctl --user show --property InvocationID --value "$VIEWFLOW_UNIT" 2>/dev/null || true)
                peer_json=$(journalctl --user --quiet --no-pager --output=json \
                    "_SYSTEMD_INVOCATION_ID=$invocation" 2>/dev/null | jq -sc \
                    --arg prefix "viewflowd server authenticated peer $EXPECTED_WINDOWS_PEER_IP:" '
                    [.[] | select((.MESSAGE // "") | startswith($prefix))] | last // empty')
                if [[ $exe == "$VIEWFLOW_INSTALLED" && -n $peer_json &&
                      ( -z $expected_pid || $pid == "$expected_pid" ) ]] &&
                    assert_hash 'live staged Viewflow' "/proc/$pid/exe" "$viewflow_sha" &&
                    process_has_argument "$pid" --acceptance-socket &&
                    process_has_argument "$pid" "$VIEWFLOW_ACCEPTANCE_SOCKET" &&
                    process_has_argument "$pid" --acceptance-state-dir &&
                    process_has_argument "$pid" "$VIEWFLOW_ACCEPTANCE_STATE_DIR" &&
                    [[ -S $VIEWFLOW_ACCEPTANCE_SOCKET && ! -L $VIEWFLOW_ACCEPTANCE_SOCKET &&
                       $(stat -c '%u %a' -- "$VIEWFLOW_ACCEPTANCE_SOCKET") == '1000 600' ]] &&
                    [[ -S $VIEWFLOW_SIDECAR && ! -L $VIEWFLOW_SIDECAR &&
                       $(stat -c '%u %a' -- "$VIEWFLOW_SIDECAR") == '1000 600' ]] &&
                    ss -H -lunp "sport = :$VIEWFLOW_PORT" | grep -Fq "pid=$pid,"; then
                    jq -cn --argjson pid "$pid" --argjson ticks "$(process_start_ticks "$pid")" \
                        --arg boot "$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)" \
                        --arg invocation "$invocation" --arg peer "$EXPECTED_WINDOWS_PEER_IP" \
                        --arg message_sha "$(printf '%s' "$peer_json" | sha256sum | awk '{print tolower($1)}')" \
                        --argjson accepted "$(date -u +%s%3N)" \
                        '{pid:$pid,start_ticks:$ticks,boot_id:$boot,invocation_id:$invocation,
                          authenticated_peer_ip:$peer,authenticated_peer_record_sha256:$message_sha,
                          authenticated_at_unix_ms:$accepted}'
                    return 0
                fi
            fi
        fi
        sleep 0.1
    done
    die 'staged Viewflow did not authenticate the expected new Windows 2.1 peer before timeout'
}

validate_backup_manifest() {
    local path=$1
    assert_owner_file 'stage backup manifest' "$path" 600
    assert_strict_json 'stage backup manifest' "$path"
    jq -e --arg op "$operation_id" --arg old_vf "$(sha256 "$backup_dir/viewflowd")" \
        --arg old_marker "$(sha256 "$backup_dir/viewflow-deployment-marker")" \
        --arg old_unit "$(sha256 "$backup_dir/viewflow-peer.service")" \
        --arg deskflow "$(sha256 "$backup_dir/deskflow")" \
        --arg core "$(sha256 "$backup_dir/deskflow-core")" \
        --arg dropin "$(sha256 "$backup_dir/deskflow-viewflow.conf")" '
        (keys == ["artifact_hashes","operation_id","schema_version","state"]) and
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-stage-backup" and
        .operation_id == $op and
        (.artifact_hashes == {old_viewflowd:$old_vf,old_deployment_marker_tool:$old_marker,
                              old_viewflow_unit:$old_unit,preserved_deskflow:$deskflow,
                              preserved_deskflow_core:$core,preserved_deskflow_dropin:$dropin})
    ' "$path" >/dev/null || die 'stage backup manifest is invalid'
}

validate_stage_receipt() {
    local path=$1 live_required=${2:-yes} linux_hash handoff_hash request_hash prepared_hash permit_hash envelope_hash publish_sha manifest_sha
    local old_vf old_marker old_unit deskflow core dropin receipt_pid
    assert_owner_file 'stage receipt' "$path" 600
    assert_strict_json 'stage receipt' "$path"
    linux_hash=$(sha256 "$linux_evidence")
    handoff_hash=$(sha256 "$handoff_receipt")
    request_hash=$(sha256 "$bootstrap_request")
    prepared_hash=$(sha256 "$prepared_receipt")
    permit_hash=$(sha256 "$mutation_permit")
    envelope_hash=$(sha256 "$force_envelope")
    publish_sha=$(sha256 "$publish_receipt")
    validate_backup_manifest "$backup_dir/manifest.json"
    manifest_sha=$(sha256 "$backup_dir/manifest.json")
    old_vf=$(sha256 "$backup_dir/viewflowd")
    old_marker=$(sha256 "$backup_dir/viewflow-deployment-marker")
    old_unit=$(sha256 "$backup_dir/viewflow-peer.service")
    deskflow=$(jq -er '.artifact_hashes.preserved_deskflow' "$backup_dir/manifest.json")
    core=$(jq -er '.artifact_hashes.preserved_deskflow_core' "$backup_dir/manifest.json")
    dropin=$(jq -er '.artifact_hashes.preserved_deskflow_dropin' "$backup_dir/manifest.json")
    jq -e --arg op "$operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg windows "$windows_viewflow_sha" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg marker_path "$DEPLOYMENT_MARKER" \
        --arg marker_id "$BOOTSTRAP_MARKER_IDENTITY" --arg marker_sha "$BOOTSTRAP_MARKER_SHA" \
        --arg linux "$linux_hash" --arg handoff "$handoff_hash" --arg request "$request_hash" \
        --arg prepared "$prepared_hash" --arg permit "$permit_hash" --arg envelope "$envelope_hash" \
        --arg publish "$publish_sha" \
        --arg backup "$backup_dir" --arg manifest "$manifest_sha" --arg old_vf "$old_vf" \
        --arg old_marker "$old_marker" --arg old_unit "$old_unit" --arg new_vf "$viewflow_sha" \
        --arg new_marker "$marker_tool_sha" --arg new_unit "$unit_sha" --arg deskflow "$deskflow" \
        --arg core "$core" --arg dropin "$dropin" --arg peer "$EXPECTED_WINDOWS_PEER_IP" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        (keys == ["artifact_hashes","backup_directory","backup_manifest_sha256","completed_at_unix_ms",
                  "evidence_hashes","freeze_state","marker","operation_id","protocol_version","runtime","schema_version",
                  "source_display_id","state","target_device_id","windows_viewflow_sha256"]) and
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-staged" and
        .operation_id == $op and .protocol_version == "2.1" and .source_display_id == $source and
        .target_device_id == $target and .windows_viewflow_sha256 == $windows and
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
        (.runtime.invocation_id | test("^[0-9a-f]{32}$")) and
        (.completed_at_unix_ms | uint53 and . >= .runtime.authenticated_at_unix_ms)
    ' "$path" >/dev/null || die 'stage receipt is invalid or does not match exact query inputs'
    if [[ $live_required == yes ]]; then
        receipt_pid=$(jq -er '.runtime.pid' "$path")
        viewflow_live_snapshot "$receipt_pid" >/dev/null
        assert_deskflow_preserved_and_stopped "$deskflow" "$core" "$dropin"
    fi
}

make_backup() {
    require_new_output 'stage receipt' "$receipt_output"
    [[ ! -e $backup_dir && ! -L $backup_dir ]] || die 'stage backup directory already exists'
    mkdir -m 0700 -- "$backup_dir"
    assert_owner_directory 'stage backup directory' "$backup_dir"
    install -m 0755 -- "$VIEWFLOW_INSTALLED" "$backup_dir/viewflowd"
    install -m 0755 -- "$DEPLOYMENT_MARKER_TOOL_INSTALLED" "$backup_dir/viewflow-deployment-marker"
    install -m 0644 -- "$VIEWFLOW_UNIT_INSTALLED" "$backup_dir/viewflow-peer.service"
    install -m 0755 -- "$DESKFLOW_INSTALLED" "$backup_dir/deskflow"
    install -m 0755 -- "$DESKFLOW_CORE_INSTALLED" "$backup_dir/deskflow-core"
    install -m 0644 -- "$DESKFLOW_DROPIN_INSTALLED" "$backup_dir/deskflow-viewflow.conf"
    local temp=$backup_dir/.manifest.tmp
    jq -cn --arg op "$operation_id" --arg old_vf "$(sha256 "$backup_dir/viewflowd")" \
        --arg old_marker "$(sha256 "$backup_dir/viewflow-deployment-marker")" \
        --arg old_unit "$(sha256 "$backup_dir/viewflow-peer.service")" \
        --arg deskflow "$(sha256 "$backup_dir/deskflow")" --arg core "$(sha256 "$backup_dir/deskflow-core")" \
        --arg dropin "$(sha256 "$backup_dir/deskflow-viewflow.conf")" \
        '{schema_version:1,state:"viewflow-linux-bootstrap-stage-backup",operation_id:$op,
          artifact_hashes:{old_viewflowd:$old_vf,old_deployment_marker_tool:$old_marker,
                           old_viewflow_unit:$old_unit,preserved_deskflow:$deskflow,
                           preserved_deskflow_core:$core,preserved_deskflow_dropin:$dropin}}' >"$temp"
    chmod 0600 "$temp"
    mv -- "$temp" "$backup_dir/manifest.json"
    fsync_file_and_parent "$backup_dir/manifest.json"
    validate_backup_manifest "$backup_dir/manifest.json"
}

restore_stage_backup() {
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
    assert_runtime_marker_absent || failed=1
    return "$failed"
}

on_failure() {
    local status=$1 command_text=$2
    trap - ERR INT TERM
    set +e
    printf 'stage failed (%s): %s\n' "$status" "$command_text" >&2
    if ((transaction_started)); then
        restore_stage_backup || exit 70
        printf '%s\n' 'stage rollback restored old files with both Linux units inactive and VFDQT001 retained' >&2
    fi
    exit "$status"
}
trap 'on_failure $? "$BASH_COMMAND"' ERR
trap 'on_failure 130 signal-INT' INT
trap 'on_failure 143 signal-TERM' TERM

assert_source_inputs
freeze_marker
assert_runtime_marker_absent

if [[ $command == query ]]; then
    [[ -f $receipt_output && ! -L $receipt_output ]] || die 'stage receipt is absent'
    old_viewflow_sha=$(sha256 "$backup_dir/viewflowd")
    validate_input_chain "$old_viewflow_sha"
    validate_stage_receipt "$receipt_output" yes
    dd if="$receipt_output" status=none
    exit 0
fi

if [[ $command == rollback ]]; then
    if [[ -e $receipt_output || -L $receipt_output ]]; then
        validate_stage_receipt "$receipt_output" no
    else
        validate_backup_manifest "$backup_dir/manifest.json"
        old_viewflow_sha=$(sha256 "$backup_dir/viewflowd")
        validate_input_chain "$old_viewflow_sha" >/dev/null
    fi
    restore_stage_backup
    printf '{"schema_version":1,"state":"viewflow-linux-bootstrap-stage-rolled-back","operation_id":"%s"}\n' "$operation_id"
    exit 0
fi

if [[ -e $receipt_output || -L $receipt_output ]]; then
    old_viewflow_sha=$(sha256 "$backup_dir/viewflowd")
    validate_input_chain "$old_viewflow_sha"
    validate_stage_receipt "$receipt_output" yes
    dd if="$receipt_output" status=none
    exit 0
fi

assert_both_units_stopped
old_viewflow_sha=$(sha256 "$VIEWFLOW_INSTALLED")
readonly old_viewflow_sha
validate_input_chain "$old_viewflow_sha"
readonly linux_sha handoff_sha bootstrap_request_sha prepared_sha permit_sha force_envelope_sha
assert_marker_unchanged
assert_runtime_marker_absent
make_backup
transaction_started=1

# TRANSACTION_PHASE: BOOTSTRAP_STAGE_INSTALL_VIEWFLOW_ONLY
atomic_install "$viewflow_candidate" "$VIEWFLOW_INSTALLED" 0755
atomic_install "$marker_candidate" "$DEPLOYMENT_MARKER_TOOL_INSTALLED" 0755
atomic_install "$unit_candidate" "$VIEWFLOW_UNIT_INSTALLED" 0644
assert_hash 'installed staged Viewflow' "$VIEWFLOW_INSTALLED" "$viewflow_sha"
assert_hash 'installed staged marker CLI' "$DEPLOYMENT_MARKER_TOOL_INSTALLED" "$marker_tool_sha"
assert_hash 'installed staged Viewflow unit' "$VIEWFLOW_UNIT_INSTALLED" "$unit_sha"
assert_marker_unchanged
assert_runtime_marker_absent
systemctl --user daemon-reload

# TRANSACTION_PHASE: BOOTSTRAP_STAGE_START_VIEWFLOW_AND_MEET_WINDOWS
systemctl --user start "$VIEWFLOW_UNIT"
runtime_json=$(viewflow_live_snapshot)
readonly runtime_json
deskflow_sha=$(jq -er '.artifact_hashes.preserved_deskflow' "$backup_dir/manifest.json")
core_sha=$(jq -er '.artifact_hashes.preserved_deskflow_core' "$backup_dir/manifest.json")
dropin_sha=$(jq -er '.artifact_hashes.preserved_deskflow_dropin' "$backup_dir/manifest.json")
assert_deskflow_preserved_and_stopped "$deskflow_sha" "$core_sha" "$dropin_sha"
assert_marker_unchanged

receipt_temp=$(mktemp --tmpdir="$(dirname -- "$receipt_output")" '.viewflow-stage.XXXXXXXX')
chmod 0600 "$receipt_temp"
jq -cn --arg op "$operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
    --arg windows "$windows_viewflow_sha" --arg linux "$linux_sha" --arg handoff "$handoff_sha" \
    --arg request "$bootstrap_request_sha" --arg prepared "$prepared_sha" --arg permit "$permit_sha" \
    --arg envelope "$force_envelope_sha" --arg publish "$(sha256 "$publish_receipt")" --arg marker_path "$DEPLOYMENT_MARKER" \
    --arg marker_id "$BOOTSTRAP_MARKER_IDENTITY" --arg marker_sha "$BOOTSTRAP_MARKER_SHA" \
    --arg coordinator "$coordinator_instance_id" --arg generation "$marker_generation" \
    --arg old_vf "$(sha256 "$backup_dir/viewflowd")" \
    --arg old_marker "$(sha256 "$backup_dir/viewflow-deployment-marker")" \
    --arg old_unit "$(sha256 "$backup_dir/viewflow-peer.service")" \
    --arg new_vf "$viewflow_sha" --arg new_marker "$marker_tool_sha" --arg new_unit "$unit_sha" \
    --arg deskflow "$deskflow_sha" --arg core "$core_sha" --arg dropin "$dropin_sha" \
    --arg backup "$backup_dir" --arg manifest "$(sha256 "$backup_dir/manifest.json")" \
    --argjson runtime "$runtime_json" --argjson completed "$(date -u +%s%3N)" \
    '{schema_version:1,state:"viewflow-linux-bootstrap-staged",operation_id:$op,
      protocol_version:"2.1",source_display_id:$source,target_device_id:$target,
      windows_viewflow_sha256:$windows,
      evidence_hashes:{bootstrap_request:$request,linux_frozen_evidence:$linux,
                       marker_handoff_receipt:$handoff,mutation_permit:$permit,
                       windows_force_release_envelope:$envelope,windows_prepared_receipt:$prepared,
                       deployment_publish_receipt:$publish},
      freeze_state:{deskflow_unit_active_state:"inactive",deskflow_unit_main_pid:0,
                    deskflow_exact_process_count:0,deskflow_core_exact_process_count:0,
                    deskflow_tcp_listener_count:0,runtime_marker_path:"/home/wilf/.local/state/viewflow/deskflow-quarantine.v2",
                    runtime_marker_present:false},
      marker:{path:$marker_path,identity:$marker_id,sha256:$marker_sha,
              coordinator_instance_id:$coordinator,marker_generation:$generation},
      artifact_hashes:{old_viewflowd:$old_vf,old_deployment_marker_tool:$old_marker,
                       old_viewflow_unit:$old_unit,staged_viewflowd:$new_vf,
                       staged_deployment_marker_tool:$new_marker,staged_viewflow_unit:$new_unit,
                       preserved_deskflow:$deskflow,preserved_deskflow_core:$core,
                       preserved_deskflow_dropin:$dropin},
      backup_directory:$backup,backup_manifest_sha256:$manifest,runtime:$runtime,
      completed_at_unix_ms:$completed}' >"$receipt_temp"
assert_marker_unchanged
publish_no_clobber "$receipt_temp" "$receipt_output"
rm -f -- "$receipt_temp"
validate_stage_receipt "$receipt_output" yes
transaction_started=0
dd if="$receipt_output" status=none
