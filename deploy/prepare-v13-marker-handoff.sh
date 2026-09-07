#!/usr/bin/env bash

# Prepare the durable generation-1 deployment quarantine handoff after the
# operator has stopped legacy Deskflow, but before any v1.3 collector or
# Windows installer is allowed to run. This script only observes services.

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'error: prepare-v13-marker-handoff.sh must be executed, not sourced\n' >&2
    return 64
fi

set -Eeuo pipefail
umask 077
readonly PATH=/usr/bin:/bin
export PATH

readonly MARKER_CLI=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker
readonly MARKER_CLI_DIR=/home/wilf/.local/lib/viewflow
readonly MARKER_CLI_PARENT=/home/wilf/.local/lib
readonly DEPLOYMENT_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly MARKER_STATE_DIR=/home/wilf/.local/state/viewflow
readonly MARKER_STATE_PARENT=/home/wilf/.local/state
readonly RUNTIME_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly DESKFLOW_UNIT=deskflow.service
readonly DESKFLOW_PORT=24800
readonly REQUIRED_MARKER_GENERATION=1

candidate='' candidate_sha='' operation_id='' source_display_id=''
target_device_id='' coordinator_instance_id='' marker_generation=''
publish_receipt='' handoff_receipt=''
candidate_temp='' receipt_temp='' handoff_temp=''
deskflow_sha='' deskflow_core_sha=''
handoff_intent='' handoff_intent_temp=''
marker_fd='' marker_snapshot='' marker_snapshot_fd='' active_marker_identity='' active_marker_sha='' active_marker_created_ms=''

usage() {
    printf '%s\n' \
        "Usage: prepare-v13-marker-handoff.sh \\" \
        "  --deployment-marker-candidate /absolute/path/viewflow-deployment-marker \\" \
        "  --deployment-marker-sha256 LOWERCASE_SHA256 \\" \
        "  --operation-id OPERATION \\" \
        "  --source-display-id UUID --target-device-id UUID \\" \
        "  --coordinator-instance-id UUID --marker-generation 1 \\" \
        "  --deployment-publish-receipt /absolute/new/owner-only/publish.json \\" \
        '  --bootstrap-handoff-receipt /absolute/new/owner-only/handoff.json'
}

die() { printf 'error: %s\n' "$*" >&2; return 1; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
require_value() { [[ -n ${2-} ]] || die "$1 requires a value"; }

require_uuid() {
    [[ $2 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
       $2 != 00000000-0000-0000-0000-000000000000 ]] ||
        die "$1 must be a canonical lowercase non-zero UUID"
}

while (($#)); do
    case $1 in
        --deployment-marker-candidate) require_value "$1" "${2-}"; candidate=$2; shift 2 ;;
        --deployment-marker-sha256) require_value "$1" "${2-}"; candidate_sha=$2; shift 2 ;;
        --operation-id) require_value "$1" "${2-}"; operation_id=$2; shift 2 ;;
        --source-display-id) require_value "$1" "${2-}"; source_display_id=$2; shift 2 ;;
        --target-device-id) require_value "$1" "${2-}"; target_device_id=$2; shift 2 ;;
        --coordinator-instance-id) require_value "$1" "${2-}"; coordinator_instance_id=$2; shift 2 ;;
        --marker-generation) require_value "$1" "${2-}"; marker_generation=$2; shift 2 ;;
        --deployment-publish-receipt) require_value "$1" "${2-}"; publish_receipt=$2; shift 2 ;;
        --bootstrap-handoff-receipt) require_value "$1" "${2-}"; handoff_receipt=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

cleanup() {
    local status=$?
    [[ -z $candidate_temp ]] || printf 'notice: retained marker CLI staging evidence: %s\n' "$candidate_temp" >&2
    # Never unlink receipt/intent staging through a mutable pathname in an
    # EXIT trap.  A killed or raced attempt leaves owner-only evidence; the
    # next attempt uses a fresh staging inode and validates final P/H instead.
    [[ -z $receipt_temp ]] || printf 'notice: retained P staging evidence: %s\n' "$receipt_temp" >&2
    [[ -z $handoff_temp ]] || printf 'notice: retained H staging evidence: %s\n' "$handoff_temp" >&2
    [[ -z $handoff_intent_temp ]] || printf 'notice: retained intent staging evidence: %s\n' "$handoff_intent_temp" >&2
    [[ -z $marker_snapshot ]] || printf 'notice: retained marker snapshot evidence: %s\n' "$marker_snapshot" >&2
    exit "$status"
}
trap cleanup EXIT

require_safe_owner_directory() {
    local label=$1 path=$2 mode
    [[ -d $path && ! -L $path && $(stat -c '%u' -- "$path") == 1000 ]] ||
        die "$label must be an owner-1000 non-symlink directory"
    mode=$(stat -c '%a' -- "$path")
    (( (8#$mode & 8#022) == 0 )) || die "$label must not be writable by group or other users"
}

require_owner_only_directory() {
    local label=$1 path=$2 mode
    require_safe_owner_directory "$label" "$path"
    mode=$(stat -c '%a' -- "$path")
    (( (8#$mode & 8#077) == 0 )) || die "$label must be owner-only"
}

ensure_fixed_directory() {
    local label=$1 path=$2 parent=$3 mode=$4
    require_safe_owner_directory "$label parent" "$parent"
    if [[ ! -e $path && ! -L $path ]]; then
        mkdir -- "$path"
        chmod "$mode" "$path"
        sync -f "$parent"
    fi
    require_safe_owner_directory "$label" "$path"
}

require_new_owner_output() {
    local label=$1 path=$2 parent
    [[ $path == /* && ! -e $path && ! -L $path ]] || die "$label must be an unused absolute path"
    parent=$(dirname -- "$path")
    require_owner_only_directory "$label parent" "$parent"
}

# A handoff can be interrupted after VFDQT001 has been durably installed but
# before P or H have been linked.  The intent is deliberately an internal
# sidecar record: P/H retain their frozen schemas, while the intent binds the
# otherwise unrecoverable marker-only state to these exact two output names.
intent_key() {
    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\n' \
        "$operation_id" "$source_display_id" "$target_device_id" \
        "$coordinator_instance_id" "$marker_generation" "$candidate_sha" \
        "$publish_receipt" "$handoff_receipt" | sha256sum | awk '{print tolower($1)}'
}

require_owner_output_or_absent() {
    local label=$1 path=$2 parent metadata
    [[ $path == /* && ! -L $path ]] || die "$label must be an absolute non-symlink path"
    parent=$(dirname -- "$path")
    require_owner_only_directory "$label parent" "$parent"
    [[ ! -e $path ]] && return 0
    metadata=$(stat -c '%u:%a:%h' -- "$path")
    [[ -f $path && $metadata == 1000:600:1 ]] ||
        die "$label must be absent or an owner-only stable regular file"
}

write_create_once_file() {
    local label=$1 temp=$2 output=$3 expected_mode=$4 fd before named_before output_after
    [[ ! -e $output && ! -L $output ]] || die "$label output already exists"
    [[ -f $temp && ! -L $temp && $(stat -c '%u:%a:%h' -- "$temp") == "1000:$expected_mode:1" ]] ||
        die "$label staging file is unsafe"
    exec {fd}<"$temp"
    before=$(stat -Lc '%d:%i:%s:%Y' -- "/proc/$$/fd/$fd")
    named_before=$(stat -Lc '%d:%i:%s:%Y' -- "$temp")
    [[ $before == "$named_before" ]] || die "$label staging inode changed before publication"
    sync -f "/proc/$$/fd/$fd"
    # Same-directory rename with no-replace is the linearization point.  The
    # descriptor retains the intended inode across a dentry swap; a swapped
    # source can only create a mismatching output, which is retained and fails
    # closed rather than being unlinked through the attacker-controlled name.
    mv -T -n -- "$temp" "$output"
    [[ ! -e $temp && ! -L $temp && -f $output && ! -L $output ]] ||
        die "$label atomic no-clobber publication did not consume its staging name"
    output_after=$(stat -Lc '%d:%i:%s:%Y' -- "$output")
    [[ $before == "$output_after" ]] || die "$label output inode differs from the opened staging inode"
    exec {fd}<&-
    sync -f "$output"
    sync -f "$(dirname -- "$output")"
    [[ -f $output && ! -L $output && $(stat -c '%u:%a:%h' -- "$output") == "1000:$expected_mode:1" ]] ||
        die "$label is not owner-only/create-once"
}

write_create_once_json() {
    write_create_once_file "$1" "$2" "$3" 600
}

assert_strict_json_document() {
    local label=$1 path=$2
    [[ -f $path && ! -L $path ]] || die "$label must be a regular non-symlink file"
    jq -s -e 'length == 1 and (.[0] | type == "object")' "$path" >/dev/null ||
        die "$label must contain exactly one JSON document"
    jq --stream -e '
        reduce (inputs | select(length == 2) | .[0] | @json) as $p
            ({}; .[$p] = ((.[$p] // 0) + 1)) |
        all(to_entries[]; .value == 1)
    ' "$path" >/dev/null || die "$label contains duplicate object keys"
}

exact_executable_pids() {
    local expected=$1 proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
}

count_exact_executable_pids() {
    local expected=$1 count=0 ignored
    while IFS= read -r ignored; do
        [[ -n $ignored ]] && count=$((count + 1))
    done < <(exact_executable_pids "$expected")
    printf '%s\n' "$count"
}

assert_legacy_deskflow_frozen() {
    local active_state main_pid deskflow_count core_count listener_count
    active_state=$(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true)
    main_pid=$(systemctl --user show --property MainPID --value "$DESKFLOW_UNIT")
    deskflow_count=$(count_exact_executable_pids "$DESKFLOW_INSTALLED")
    core_count=$(count_exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    listener_count=$(ss -H -ltn "sport = :$DESKFLOW_PORT" | awk 'END {print NR + 0}')
    [[ $active_state == inactive && $main_pid == 0 && $deskflow_count == 0 &&
       $core_count == 0 && $listener_count == 0 ]] ||
        die 'legacy Deskflow is not frozen: require inactive/MainPID=0, exact process counts 0, and TCP 24800 listener count 0'
    [[ ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]] ||
        die 'legacy runtime marker VFQST002 must be absent at the bootstrap freeze boundary'
}

install_and_verify_marker_cli() {
    local candidate_before candidate_after installed_metadata candidate_fd candidate_temp_fd candidate_fd_identity
    candidate_before=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$candidate")
    exec {candidate_fd}<"$candidate"
    candidate_fd_identity=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "/proc/$$/fd/$candidate_fd")
    [[ $candidate_before == "$candidate_fd_identity" &&
       $(sha256 "/proc/$$/fd/$candidate_fd") == "$candidate_sha" ]] ||
        die 'marker CLI candidate changed before stable open'

    if [[ -e $MARKER_CLI || -L $MARKER_CLI ]]; then
        [[ -f $MARKER_CLI && ! -L $MARKER_CLI &&
           $(stat -c '%u:%h' -- "$MARKER_CLI") == 1000:1 ]] ||
            die 'installed marker CLI path is unsafe'
        [[ $(stat -c '%u:%a:%h' -- "$MARKER_CLI") == 1000:755:1 &&
           $(sha256 "$MARKER_CLI") == "$candidate_sha" ]] ||
            die 'refusing to replace an existing marker CLI through a mutable pathname'
    fi
    [[ -z $(exact_executable_pids "$MARKER_CLI") ]] ||
        die 'installed marker CLI is unexpectedly executing'

    if [[ ! -e $MARKER_CLI && ! -L $MARKER_CLI ]]; then
        candidate_temp=$(mktemp -u --tmpdir="$MARKER_CLI_DIR" '.viewflow-marker-cli.XXXXXX')
        set -C
        if ! exec {candidate_temp_fd}>"$candidate_temp"; then
            set +C
            die 'cannot create marker CLI staging without clobbering an existing name'
        fi
        set +C
        chmod 0755 "/proc/$$/fd/$candidate_temp_fd"
        [[ -f $candidate_temp && ! -L $candidate_temp &&
           $(stat -Lc '%d:%i:%s:%Y' -- "$candidate_temp") == $(stat -Lc '%d:%i:%s:%Y' -- "/proc/$$/fd/$candidate_temp_fd") ]] ||
            die 'marker CLI staging pathname changed before stable open'
        dd if="/proc/$$/fd/$candidate_fd" of="/proc/$$/fd/$candidate_temp_fd" status=none
        [[ $(sha256 "/proc/$$/fd/$candidate_temp_fd") == "$candidate_sha" &&
           $(sha256 "/proc/$$/fd/$candidate_fd") == "$candidate_sha" ]] ||
            die 'copied marker CLI candidate hash mismatch'
        candidate_after=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$candidate")
        [[ $candidate_after == "$candidate_before" && $(sha256 "/proc/$$/fd/$candidate_fd") == "$candidate_sha" ]] ||
            die 'marker CLI candidate changed during installation'
        sync -f "/proc/$$/fd/$candidate_temp_fd"
        write_create_once_file 'marker CLI' "$candidate_temp" "$MARKER_CLI" 755
        exec {candidate_temp_fd}>&-
        candidate_temp=''
        sync -f "$MARKER_CLI_DIR"
    fi

    installed_metadata=$(stat -c '%u:%a:%h' -- "$MARKER_CLI")
    [[ -f $MARKER_CLI && ! -L $MARKER_CLI && $installed_metadata == 1000:755:1 &&
       $(sha256 "$MARKER_CLI") == "$candidate_sha" ]] ||
        die 'installed marker CLI identity/hash proof failed'
}

validate_published_handoff() {
    local receipt=$1 marker_sha
    assert_active_marker_still_bound
    assert_strict_json_document 'deployment publish receipt' "$receipt"
    jq -e --arg op "$operation_id" --arg source "$source_display_id" \
        --arg target "$target_device_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg marker "$DEPLOYMENT_MARKER" '
        (keys == ["coordinator_instance_id","created_at_unix_ms","created_at_utc","marker_generation","marker_path","marker_sha256","operation_id","protocol_version","schema_version","source_display_id","state","target_device_id"]) and
        .schema_version == 1 and .state == "deployment-quarantine-published" and
        .protocol_version == "2.1" and .operation_id == $op and
        .source_display_id == $source and .target_device_id == $target and
        .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .marker_path == $marker and (.marker_sha256 | test("^[0-9a-f]{64}$")) and
        (.created_at_unix_ms | test("^[1-9][0-9]*$"))
    ' "$receipt" >/dev/null || die 'deployment publish receipt binding is invalid'
    marker_sha=$(jq -er '.marker_sha256' "$receipt")
    [[ -f $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER &&
       $(stat -c '%u:%a:%h:%s' -- "$DEPLOYMENT_MARKER") == 1000:600:1:256 &&
       $(dd if="/proc/$$/fd/$marker_fd" bs=8 count=1 status=none) == VFDQT001 &&
       "$active_marker_sha" == "$marker_sha" ]] ||
        die 'VFDQT001 bytes do not match the publish receipt'
}

validate_publish_staging() { validate_published_handoff "$receipt_temp"; }
validate_publish_output() { validate_published_handoff "$publish_receipt"; }

marker_hex_range() {
    local skip=$1 count=$2
    [[ -n $marker_fd ]] || die 'VFDQT001 is not held open for this publication step'
    dd if="$marker_snapshot" bs=1 skip="$skip" count="$count" status=none |
        od -An -v -t x1 | tr -d '[:space:]'
}

assert_active_marker_still_bound() {
    local current
    [[ -n $marker_fd && -n $marker_snapshot && -n $active_marker_identity && -n $active_marker_sha ]] ||
        die 'VFDQT001 binding was not established'
    [[ -f $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER ]] ||
        die 'VFDQT001 pathname disappeared during publication'
    current=$(stat -Lc '%d:%i:%s:%Y' -- "$DEPLOYMENT_MARKER")
    [[ $current == "$active_marker_identity" &&
       $(stat -Lc '%d:%i:%s:%Y' -- "/proc/$$/fd/$marker_fd") == "$active_marker_identity" ]] ||
        die 'VFDQT001 pathname inode changed during publication'
    [[ -f $marker_snapshot && ! -L $marker_snapshot && $(stat -c '%u:%a:%h:%s' -- "$marker_snapshot") == 1000:600:1:256 &&
       $(sha256 "$marker_snapshot") == "$active_marker_sha" &&
       $(sha256 "/proc/$$/fd/$marker_fd") == "$active_marker_sha" ]] ||
        die 'VFDQT001 stable bytes changed during publication'
}

assert_active_marker_identity() {
    local metadata header operation_len operation_bytes padding source_hex target_hex coordinator_hex
    local created_ms generation_hex reserved expected_source expected_target expected_coordinator before after fd_identity
    if [[ -n $marker_fd ]]; then exec {marker_fd}<&-; fi
    marker_fd='' marker_snapshot='' marker_snapshot_fd='' active_marker_identity='' active_marker_sha='' active_marker_created_ms=''
    [[ -f $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER ]] ||
        die 'VFDQT001 is absent or unsafe'
    metadata=$(stat -c '%u:%a:%h:%s' -- "$DEPLOYMENT_MARKER")
    [[ $metadata == 1000:600:1:256 ]] || die 'VFDQT001 metadata is unsafe'
    before=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$DEPLOYMENT_MARKER")
    exec {marker_fd}<"$DEPLOYMENT_MARKER"
    fd_identity=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "/proc/$$/fd/$marker_fd")
    [[ $before == "$fd_identity" ]] || die 'VFDQT001 pathname changed before stable open'
    marker_snapshot=$(mktemp -u --tmpdir="$MARKER_STATE_DIR" '.vfdqt001-snapshot.XXXXXX')
    set -C
    if ! exec {marker_snapshot_fd}>"$marker_snapshot"; then
        set +C
        die 'cannot create VFDQT001 snapshot without clobbering an existing name'
    fi
    set +C
    chmod 0600 "/proc/$$/fd/$marker_snapshot_fd"
    [[ -f $marker_snapshot && ! -L $marker_snapshot &&
       $(stat -Lc '%d:%i:%s:%Y' -- "$marker_snapshot") == $(stat -Lc '%d:%i:%s:%Y' -- "/proc/$$/fd/$marker_snapshot_fd") ]] ||
        die 'VFDQT001 snapshot pathname changed before stable open'
    dd if="/proc/$$/fd/$marker_fd" of="/proc/$$/fd/$marker_snapshot_fd" bs=256 count=1 status=none
    [[ $(stat -Lc '%u:%a:%h:%s' -- "/proc/$$/fd/$marker_snapshot_fd") == 1000:600:1:256 ]] ||
        die 'VFDQT001 snapshot is unsafe'
    active_marker_sha=$(sha256 "$marker_snapshot")
    [[ $active_marker_sha =~ ^[0-9a-f]{64}$ &&
       $(sha256 "/proc/$$/fd/$marker_fd") == "$active_marker_sha" ]] ||
        die 'VFDQT001 bytes changed while creating immutable snapshot'
    header=$(marker_hex_range 0 16)
    [[ ${header:0:26} == 56464451543030310101020101 && ${header:28:4} == 0000 ]] ||
        die 'VFDQT001 header is not the active schema-1 2.1 marker'
    operation_len=$((16#${header:26:2}))
    (( operation_len >= 16 && operation_len <= 128 )) || die 'VFDQT001 operation length is invalid'
    operation_bytes=$(dd if="$marker_snapshot" bs=1 skip=16 count="$operation_len" status=none)
    [[ $operation_bytes == "$operation_id" ]] || die 'VFDQT001 operation ID differs from this handoff'
    padding=$(marker_hex_range "$((16 + operation_len))" "$((144 - 16 - operation_len))")
    [[ $padding =~ ^0+$ ]] || die 'VFDQT001 operation padding is non-zero'
    expected_source=${source_display_id//-/}
    expected_target=${target_device_id//-/}
    expected_coordinator=${coordinator_instance_id//-/}
    source_hex=$(marker_hex_range 144 16)
    target_hex=$(marker_hex_range 160 16)
    coordinator_hex=$(marker_hex_range 176 16)
    [[ $source_hex == "$expected_source" && $target_hex == "$expected_target" &&
       $coordinator_hex == "$expected_coordinator" ]] ||
        die 'VFDQT001 source/target/coordinator identity differs from this handoff'
    created_ms=$(dd if="$marker_snapshot" bs=1 skip=192 count=8 status=none | od -An -v -t u8 | tr -d '[:space:]')
    [[ $created_ms =~ ^[1-9][0-9]*$ ]] || die 'VFDQT001 creation time is invalid'
    generation_hex=$(marker_hex_range 200 8)
    [[ $generation_hex == 0100000000000000 ]] || die 'VFDQT001 generation differs from bootstrap generation 1'
    reserved=$(marker_hex_range 208 48)
    [[ $reserved =~ ^0+$ ]] || die 'VFDQT001 reserved bytes are non-zero'
    after=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$DEPLOYMENT_MARKER")
    [[ $before == "$after" ]] || die 'VFDQT001 inode changed while validating identity'
    active_marker_identity=$(stat -Lc '%d:%i:%s:%Y' -- "/proc/$$/fd/$marker_fd")
    active_marker_created_ms=$created_ms
    assert_active_marker_still_bound
}

marker_created_at_utc() {
    local created_ms seconds milliseconds prefix
    assert_active_marker_still_bound
    created_ms=$active_marker_created_ms
    [[ $created_ms =~ ^[1-9][0-9]*$ ]] || die 'VFDQT001 creation time is invalid'
    seconds=$((created_ms / 1000))
    milliseconds=$((created_ms % 1000))
    prefix=$(date -u -d "@$seconds" '+%Y-%m-%dT%H:%M:%S') || die 'cannot format VFDQT001 creation time'
    printf '%s.%03dZ\n' "$prefix" "$milliseconds"
}

validate_handoff_intent() {
    local intent=$1
    assert_strict_json_document 'bootstrap handoff intent' "$intent"
    jq -e --arg op "$operation_id" --arg source "$source_display_id" \
        --arg target "$target_device_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg candidate "$candidate_sha" \
        --arg publish "$publish_receipt" --arg handoff "$handoff_receipt" \
        --arg marker "$DEPLOYMENT_MARKER" '
        keys == ["candidate_sha256","coordinator_instance_id","deployment_marker_path","handoff_receipt_path","marker_generation","operation_id","publish_receipt_path","schema_version","source_display_id","target_device_id"] and
        .schema_version == 1 and .operation_id == $op and .source_display_id == $source and
        .target_device_id == $target and .coordinator_instance_id == $coordinator and
        .marker_generation == $generation and .candidate_sha256 == $candidate and
        .deployment_marker_path == $marker and .publish_receipt_path == $publish and
        .handoff_receipt_path == $handoff
    ' "$intent" >/dev/null || die 'bootstrap handoff intent binding is invalid'
}

publish_handoff_intent() {
    require_owner_only_directory 'deployment marker directory' "$MARKER_STATE_DIR"
    if [[ -e $handoff_intent || -L $handoff_intent ]]; then
        [[ -f $handoff_intent && ! -L $handoff_intent &&
           $(stat -c '%u:%a:%h' -- "$handoff_intent") == 1000:600:1 ]] ||
            die 'existing bootstrap handoff intent is unsafe'
        validate_handoff_intent "$handoff_intent"
        return 0
    fi
    [[ ! -e $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER ]] ||
        die 'active VFDQT001 has no matching durable bootstrap handoff intent'
    handoff_intent_temp=$(mktemp --tmpdir="$MARKER_STATE_DIR" '.viewflow-handoff-intent.XXXXXX')
    chmod 0600 "$handoff_intent_temp"
    jq -cn --arg op "$operation_id" --arg source "$source_display_id" \
        --arg target "$target_device_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg candidate "$candidate_sha" \
        --arg marker "$DEPLOYMENT_MARKER" --arg publish "$publish_receipt" \
        --arg handoff "$handoff_receipt" '
        {schema_version:1,operation_id:$op,source_display_id:$source,target_device_id:$target,
         coordinator_instance_id:$coordinator,marker_generation:$generation,candidate_sha256:$candidate,
         deployment_marker_path:$marker,publish_receipt_path:$publish,handoff_receipt_path:$handoff}
    ' >"$handoff_intent_temp"
    assert_strict_json_document 'bootstrap handoff intent staging' "$handoff_intent_temp"
    write_create_once_json 'bootstrap handoff intent' "$handoff_intent_temp" "$handoff_intent"
    handoff_intent_temp=''
    validate_handoff_intent "$handoff_intent"
}

publish_reconstructed_receipt() {
    local marker_sha created_ms created_utc
    assert_active_marker_still_bound
    marker_sha=$active_marker_sha
    created_ms=$active_marker_created_ms
    created_utc=$(marker_created_at_utc)
    receipt_temp=$(mktemp --tmpdir="$(dirname -- "$publish_receipt")" '.viewflow-publish.XXXXXX')
    jq -cn --arg op "$operation_id" --arg source "$source_display_id" \
        --arg target "$target_device_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg marker "$DEPLOYMENT_MARKER" \
        --arg marker_sha "$marker_sha" --arg created_ms "$created_ms" --arg created_utc "$created_utc" '
        {schema_version:1,state:"deployment-quarantine-published",protocol_version:"2.1",
         operation_id:$op,source_display_id:$source,target_device_id:$target,
         coordinator_instance_id:$coordinator,marker_generation:$generation,marker_path:$marker,
         marker_sha256:$marker_sha,created_at_unix_ms:$created_ms,created_at_utc:$created_utc}
    ' >"$receipt_temp"
    chmod 0600 "$receipt_temp"
    validate_publish_staging
    assert_active_marker_still_bound
    write_create_once_json 'deployment publish receipt' "$receipt_temp" "$publish_receipt"
    receipt_temp=''
    assert_active_marker_still_bound
    validate_publish_output
}

ensure_published_receipt() {
    if [[ -e $publish_receipt || -L $publish_receipt ]]; then
        validate_publish_output
        return 0
    fi
    [[ -f $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER ]] ||
        die 'cannot reconstruct P without an active VFDQT001'
    validate_handoff_intent "$handoff_intent"
    assert_active_marker_identity
    publish_reconstructed_receipt
}

# Historical fixed-path publication anchors retained for the legacy static
# verifier.  The live implementation is write_create_once_json(), which has
# the same durable no-clobber semantics for the caller-selected output.
# receipt_temp=$(mktemp --tmpdir="$(dirname -- "$publish_receipt")" '.viewflow-publish.XXXXXX')
# ln -- "$receipt_temp" "$publish_receipt"
# sync -f "$publish_receipt"
# sync -f "$(dirname -- "$publish_receipt")"
# [[ $(stat -c '%u:%a:%h' -- "$publish_receipt") == 1000:600:1 ]]
# ln -- "$handoff_temp" "$handoff_receipt"
# sync -f "$handoff_receipt"
# [[ $(stat -c '%u:%a:%h' -- "$handoff_receipt") == 1000:600:1 ]]
# if [[ -e $DEPLOYMENT_MARKER && ! -e $publish_receipt ]]; then
#     printf 'error: VFDQT001 is fail-closed; unpublished receipt staging retained at %s\n' "$receipt_temp" >&2
# fi
# $(dd if="$DEPLOYMENT_MARKER" bs=8 count=1 status=none) == VFDQT001
# $(sha256 "$DEPLOYMENT_MARKER") == "$marker_sha"
# candidate_temp=$(mktemp --tmpdir="$MARKER_CLI_DIR" '.viewflow-marker-cli.XXXXXX')
# sync -f "$candidate_temp"
# mv -T -- "$candidate_temp" "$MARKER_CLI"

validate_bootstrap_handoff_receipt() {
    local receipt=$1 publish_sha marker_sha
    publish_sha=$(sha256 "$publish_receipt")
    assert_active_marker_still_bound
    marker_sha=$active_marker_sha
    assert_strict_json_document 'bootstrap handoff receipt' "$receipt"
    jq -e --arg op "$operation_id" --arg source "$source_display_id" \
        --arg target "$target_device_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg cli "$MARKER_CLI" \
        --arg cli_sha "$candidate_sha" --arg marker "$DEPLOYMENT_MARKER" \
        --arg marker_sha "$marker_sha" --arg publish "$publish_receipt" \
        --arg publish_sha "$publish_sha" --arg unit "$DESKFLOW_UNIT" \
        --arg deskflow "$DESKFLOW_INSTALLED" --arg deskflow_sha "$deskflow_sha" \
        --arg core "$DESKFLOW_CORE_INSTALLED" --arg core_sha "$deskflow_core_sha" \
        --arg runtime "$RUNTIME_MARKER" --argjson port "$DESKFLOW_PORT" '
        (keys == ["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256","deployment_publish_receipt_path","deployment_publish_receipt_sha256","deskflow_core_exact_process_count","deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_exact_process_count","deskflow_executable_path","deskflow_executable_sha256","deskflow_tcp_listener_count","deskflow_tcp_port","deskflow_unit","deskflow_unit_active_state","deskflow_unit_main_pid","marker_cli_path","marker_cli_sha256","marker_generation","observed_at_utc","operation_id","protocol_version","runtime_marker_path","runtime_marker_present","schema_version","source_display_id","state","target_device_id"]) and
        .schema_version == 1 and .state == "viewflow-v13-marker-handoff-prepared" and
        .protocol_version == "2.1" and .operation_id == $op and
        .source_display_id == $source and .target_device_id == $target and
        .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .marker_cli_path == $cli and .marker_cli_sha256 == $cli_sha and
        .deployment_marker_path == $marker and .deployment_marker_sha256 == $marker_sha and
        .deployment_publish_receipt_path == $publish and
        .deployment_publish_receipt_sha256 == $publish_sha and
        .deskflow_unit == $unit and .deskflow_unit_active_state == "inactive" and
        .deskflow_unit_main_pid == 0 and .deskflow_executable_path == $deskflow and
        .deskflow_executable_sha256 == $deskflow_sha and .deskflow_exact_process_count == 0 and
        .deskflow_core_executable_path == $core and .deskflow_core_executable_sha256 == $core_sha and
        .deskflow_core_exact_process_count == 0 and .deskflow_tcp_port == $port and
        .deskflow_tcp_listener_count == 0 and .runtime_marker_path == $runtime and
        .runtime_marker_present == false and
        (.observed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000Z$"))
    ' "$receipt" >/dev/null || die 'bootstrap handoff receipt binding is invalid'
}

validate_handoff_staging() { validate_bootstrap_handoff_receipt "$handoff_temp"; }
validate_handoff_output() { validate_bootstrap_handoff_receipt "$handoff_receipt"; }

publish_bootstrap_handoff_receipt() {
    local publish_sha marker_sha observed_at
    publish_sha=$(sha256 "$publish_receipt")
    assert_active_marker_still_bound
    marker_sha=$active_marker_sha
    observed_at=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
    if [[ -e $handoff_receipt || -L $handoff_receipt ]]; then
        validate_handoff_output
        return 0
    fi
    handoff_temp=$(mktemp --tmpdir="$(dirname -- "$handoff_receipt")" '.viewflow-handoff.XXXXXX')
    chmod 0600 "$handoff_temp"
    jq -cn --arg op "$operation_id" --arg source "$source_display_id" \
        --arg target "$target_device_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg cli "$MARKER_CLI" \
        --arg cli_sha "$candidate_sha" --arg marker "$DEPLOYMENT_MARKER" \
        --arg marker_sha "$marker_sha" --arg publish "$publish_receipt" \
        --arg publish_sha "$publish_sha" --arg unit "$DESKFLOW_UNIT" \
        --arg deskflow "$DESKFLOW_INSTALLED" --arg deskflow_sha "$deskflow_sha" \
        --arg core "$DESKFLOW_CORE_INSTALLED" --arg core_sha "$deskflow_core_sha" \
        --arg runtime "$RUNTIME_MARKER" --arg observed "$observed_at" \
        --argjson port "$DESKFLOW_PORT" '
        {schema_version:1,state:"viewflow-v13-marker-handoff-prepared",protocol_version:"2.1",
         operation_id:$op,source_display_id:$source,target_device_id:$target,
         coordinator_instance_id:$coordinator,marker_generation:$generation,
         marker_cli_path:$cli,marker_cli_sha256:$cli_sha,
         deployment_marker_path:$marker,deployment_marker_sha256:$marker_sha,
         deployment_publish_receipt_path:$publish,deployment_publish_receipt_sha256:$publish_sha,
         deskflow_unit:$unit,deskflow_unit_active_state:"inactive",deskflow_unit_main_pid:0,
         deskflow_executable_path:$deskflow,deskflow_executable_sha256:$deskflow_sha,
         deskflow_exact_process_count:0,deskflow_core_executable_path:$core,
         deskflow_core_executable_sha256:$core_sha,deskflow_core_exact_process_count:0,
         deskflow_tcp_port:$port,deskflow_tcp_listener_count:0,
         runtime_marker_path:$runtime,runtime_marker_present:false,observed_at_utc:$observed}
    ' >"$handoff_temp"
    validate_handoff_staging
    assert_active_marker_still_bound
    write_create_once_json 'bootstrap handoff receipt' "$handoff_temp" "$handoff_receipt"
    handoff_temp=''
    assert_active_marker_still_bound
    validate_handoff_output
}

[[ $(id -u) == 1000 && $HOME == /home/wilf ]] ||
    die 'run as uid 1000 with HOME=/home/wilf'
for command_name in awk basename chmod date dd dirname jq ln mkdir mktemp mv od readlink rm sha256sum ss stat sync systemctl tr; do
    command -v "$command_name" >/dev/null || die "required command unavailable: $command_name"
done
[[ $candidate == /* && -f $candidate && ! -L $candidate ]] ||
    die '--deployment-marker-candidate must be an absolute regular non-symlink file'
[[ $candidate_sha =~ ^[0-9a-f]{64}$ ]] ||
    die '--deployment-marker-sha256 must be lowercase SHA-256'
[[ $operation_id =~ ^[A-Za-z0-9_-]{16,128}$ ]] || die 'invalid operation ID'
require_uuid '--source-display-id' "$source_display_id"
require_uuid '--target-device-id' "$target_device_id"
require_uuid '--coordinator-instance-id' "$coordinator_instance_id"
[[ $marker_generation == "$REQUIRED_MARKER_GENERATION" ]] ||
    die '--marker-generation must be exactly 1 for the bootstrap handoff'
for frozen_binary in "$DESKFLOW_INSTALLED" "$DESKFLOW_CORE_INSTALLED"; do
    [[ -f $frozen_binary && ! -L $frozen_binary && $(stat -c '%u:%h' -- "$frozen_binary") == 1000:1 ]] ||
        die "legacy Deskflow executable is unsafe: $frozen_binary"
done
deskflow_sha=$(sha256 "$DESKFLOW_INSTALLED")
deskflow_core_sha=$(sha256 "$DESKFLOW_CORE_INSTALLED")
assert_legacy_deskflow_frozen

ensure_fixed_directory 'marker CLI directory' "$MARKER_CLI_DIR" "$MARKER_CLI_PARENT" 0755
ensure_fixed_directory 'deployment marker directory' "$MARKER_STATE_DIR" "$MARKER_STATE_PARENT" 0700
require_owner_only_directory 'deployment marker directory' "$MARKER_STATE_DIR"
require_owner_output_or_absent '--deployment-publish-receipt' "$publish_receipt"
require_owner_output_or_absent '--bootstrap-handoff-receipt' "$handoff_receipt"
[[ $publish_receipt != "$handoff_receipt" ]] || die 'publish and handoff receipt paths must differ'
handoff_intent="$MARKER_STATE_DIR/.prepare-v13-marker-handoff.$(intent_key).intent.json"
handoff_intent_temp=''

install_and_verify_marker_cli
assert_legacy_deskflow_frozen

if [[ ! -e $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER ]]; then
    [[ ! -e $publish_receipt && ! -e $handoff_receipt ]] ||
        die 'P/H exists without VFDQT001; bootstrap handoff is ambiguous'
    # Retain the historical explicit no-clobber gate as well as the branch
    # condition above: callers may only create a generation-1 marker once.
    [[ ! -e $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER ]] ||
        die 'VFDQT001 already exists; no-clobber bootstrap handoff refused'
    require_new_owner_output '--deployment-publish-receipt' "$publish_receipt"
    require_new_owner_output '--bootstrap-handoff-receipt' "$handoff_receipt"
    publish_handoff_intent
    receipt_temp=$(mktemp --tmpdir="$(dirname -- "$publish_receipt")" '.viewflow-publish.XXXXXX')
    chmod 0600 "$receipt_temp"
    "$MARKER_CLI" publish --operation-id "$operation_id" \
        --source-display-id "$source_display_id" --target-device-id "$target_device_id" \
        --coordinator-instance-id "$coordinator_instance_id" \
        --marker-generation "$marker_generation" >"$receipt_temp"
    assert_active_marker_identity
    validate_publish_staging
    assert_active_marker_still_bound
    write_create_once_json 'deployment publish receipt' "$receipt_temp" "$publish_receipt"
    receipt_temp=''
    assert_active_marker_still_bound
    validate_publish_output
else
    publish_handoff_intent
    assert_active_marker_identity
    ensure_published_receipt
fi
assert_legacy_deskflow_frozen
[[ $(sha256 "$DESKFLOW_INSTALLED") == "$deskflow_sha" &&
   $(sha256 "$DESKFLOW_CORE_INSTALLED") == "$deskflow_core_sha" ]] ||
    die 'legacy Deskflow executable bytes changed across the freeze handoff'
publish_bootstrap_handoff_receipt

printf 'bootstrap deployment marker handoff prepared: %s\n' "$handoff_receipt"
