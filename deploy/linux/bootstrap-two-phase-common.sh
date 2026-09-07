#!/usr/bin/env bash

# Shared, side-effect-free validation and durable-publication helpers for the
# one-time Linux protocol-1.3 -> protocol-2.1 bootstrap.  The stage and
# finalize entry points own all service and installed-file mutations.

# shellcheck disable=SC2034

set -Eeuo pipefail

readonly EXPECTED_UID=1000
readonly EXPECTED_HOME=/home/wilf
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly DESKFLOW_UNIT=deskflow.service
readonly VIEWFLOW_INSTALLED=/home/wilf/.local/lib/viewflow/viewflowd
readonly DEPLOYMENT_MARKER_TOOL_INSTALLED=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker
readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly VIEWFLOW_UNIT_INSTALLED=/home/wilf/.config/systemd/user/viewflow-peer.service
readonly DESKFLOW_DROPIN_INSTALLED=/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf
readonly VIEWFLOW_SIDECAR=/run/user/1000/viewflow/deskflow.sock
readonly VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/post-release-acceptance.sock
readonly DESKFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock
readonly VIEWFLOW_ACCEPTANCE_STATE_DIR=/home/wilf/.local/state/viewflow/post-release-acceptance
readonly DEPLOYMENT_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly RUNTIME_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
readonly DEPLOYMENT_MARKER_MAGIC=VFDQT001
readonly VIEWFLOW_PORT=44119
readonly DESKFLOW_PORT=24800
readonly VIEWFLOW_BIND=0.0.0.0:44119
readonly VIEWFLOW_DEVICE=00000000000000000000000000000001
readonly VIEWFLOW_TARGET=00000000000000000000000000000002
readonly VIEWFLOW_PEER=172.16.105.70
readonly EXPECTED_WINDOWS_PEER_IP=172.16.105.70
readonly WINDOWS_EXPECTED_SESSION=1
readonly WINDOWS_EXPECTED_DESKTOP=Default
readonly REQUIRED_PROTOCOL=2.1

die() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

sha256() {
    sha256sum -- "$1" | awk '{print tolower($1)}'
}

require_sha256() {
    local label=$1 value=$2
    [[ $value =~ ^[0-9a-f]{64}$ ]] || die "$label must be exactly 64 lowercase hexadecimal characters"
}

require_id() {
    local label=$1 value=$2
    [[ ${#value} -ge 16 && ${#value} -le 128 && $value =~ ^[A-Za-z0-9_-]+$ ]] ||
        die "$label must be 16-128 ASCII letters, digits, hyphens, or underscores"
}

require_uuid32() {
    local label=$1 value=$2
    [[ $value =~ ^[0-9a-f]{32}$ ]] || die "$label must be exactly 32 lowercase hexadecimal characters"
}

require_u64_decimal() {
    local label=$1 value=$2
    [[ $value =~ ^(0|[1-9][0-9]{0,19})$ ]] || die "$label must be a canonical unsigned decimal integer"
    ((${#value} < 20)) ||
        [[ $value == 18446744073709551615 ||
           $(printf '%s\n%s\n' "$value" 18446744073709551615 | LC_ALL=C sort | head -n 1) == "$value" ]] ||
        die "$label exceeds u64"
}

require_absolute_regular() {
    local label=$1 path=$2
    [[ $path == /* && -f $path && ! -L $path ]] || die "$label must be an absolute regular non-symlink file: $path"
}

assert_hash() {
    local label=$1 path=$2 expected=$3 actual
    actual=$(sha256 "$path")
    [[ $actual == "$expected" ]] || die "$label SHA-256 mismatch: expected $expected, got $actual"
}

assert_owner_file() {
    local label=$1 path=$2 mode=${3:-600} owner actual_mode links
    require_absolute_regular "$label" "$path"
    read -r owner actual_mode links < <(stat -c '%u %a %h' -- "$path")
    [[ $owner == "$EXPECTED_UID" && $actual_mode == "$mode" && $links == 1 ]] ||
        die "$label must be uid $EXPECTED_UID, mode $mode, and link count 1"
}

assert_candidate_executable() {
    local label=$1 path=$2 expected=$3 owner mode
    require_absolute_regular "$label" "$path"
    [[ -x $path ]] || die "$label is not executable"
    read -r owner mode < <(stat -c '%u %a' -- "$path")
    [[ $owner == "$EXPECTED_UID" && $mode == 755 ]] ||
        die "$label must be uid $EXPECTED_UID and mode 0755"
    assert_hash "$label" "$path" "$expected"
}

assert_strict_json() {
    local label=$1 path=$2
    python3 - "$label" "$path" <<'PY'
import json
import sys

def unique(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"duplicate key: {key}")
        out[key] = value
    return out

label, path = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as stream:
        value = json.load(stream, object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError("top-level value is not an object")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
    print(f"error: {label} is not one strict JSON object: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

assert_evidence() {
    local label=$1 path=$2
    assert_owner_file "$label" "$path" 600
    assert_strict_json "$label" "$path"
}

assert_owner_directory() {
    local label=$1 path=$2 owner mode
    [[ $path == /* && -d $path && ! -L $path ]] || die "$label must be an absolute real directory"
    read -r owner mode < <(stat -c '%u %a' -- "$path")
    [[ $owner == "$EXPECTED_UID" && $mode == 700 ]] || die "$label must be uid 1000 and mode 0700"
}

require_new_output() {
    local label=$1 path=$2 parent
    [[ $path == /* ]] || die "$label must be absolute"
    [[ ! -e $path && ! -L $path ]] || die "$label already exists: $path"
    parent=$(dirname -- "$path")
    assert_owner_directory "$label parent" "$parent"
}

fsync_file_and_parent() {
    python3 - "$1" <<'PY'
import os
import sys
path = sys.argv[1]
fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    os.fsync(fd)
finally:
    os.close(fd)
parent = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    os.fsync(parent)
finally:
    os.close(parent)
PY
}

fsync_directory() {
    python3 - "$1" <<'PY'
import os
import sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

# Move one owner-only receipt on the same filesystem without ever replacing a
# destination that appears between validation and commit. renameat2 with
# RENAME_NOREPLACE is the linearization point; the post-state must preserve the
# exact inode, bytes, owner, mode, and single-link identity observed beforehand.
atomic_move_no_replace() {
    local label=$1 source=$2 destination=$3 expected_sha=$4 before after
    [[ $source == /* && $destination == /* ]] || { die "$label paths must be absolute"; return 1; }
    require_sha256 "$label expected SHA-256" "$expected_sha" || return 1
    assert_owner_file "$label source" "$source" 600 || return 1
    assert_hash "$label source" "$source" "$expected_sha" || return 1
    [[ ! -e $destination && ! -L $destination ]] || { die "$label destination already exists"; return 1; }
    assert_owner_directory "$label source parent" "$(dirname -- "$source")" || return 1
    assert_owner_directory "$label destination parent" "$(dirname -- "$destination")" || return 1
    [[ $(stat -c '%d' -- "$source") == "$(stat -c '%d' -- "$(dirname -- "$destination")")" ]] || {
        die "$label source and destination must share a filesystem"
        return 1
    }
    before=$(stat -c '%d:%i:%u:%a:%h' -- "$source")
    [[ ${before##*:} == 1 ]] || { die "$label source must have exactly one hard link"; return 1; }
    if ! python3 - "$source" "$destination" <<'PY'
import ctypes
import errno
import os
import sys

source, destination = sys.argv[1:]
source_parent, source_name = os.path.split(source)
destination_parent, destination_name = os.path.split(destination)
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
source_fd = os.open(source_parent, flags)
try:
    destination_fd = os.open(destination_parent, flags)
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                              ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        renameat2.restype = ctypes.c_int
        RENAME_NOREPLACE = 1
        if renameat2(source_fd, os.fsencode(source_name), destination_fd,
                     os.fsencode(destination_name), RENAME_NOREPLACE) != 0:
            error = ctypes.get_errno()
            if error == errno.EEXIST:
                raise RuntimeError("destination appeared before no-replace commit")
            raise OSError(error, os.strerror(error))
    finally:
        os.close(destination_fd)
finally:
    os.close(source_fd)
PY
    then
        die "$label no-replace commit failed"
        return 1
    fi
    [[ ! -e $source && ! -L $source ]] || { die "$label source remains after no-replace commit"; return 1; }
    assert_owner_file "$label destination" "$destination" 600 || return 1
    assert_hash "$label destination" "$destination" "$expected_sha" || return 1
    after=$(stat -c '%d:%i:%u:%a:%h' -- "$destination")
    [[ $after == "$before" && ${after##*:} == 1 ]] || {
        die "$label inode, ownership, mode, or link identity changed"
        return 1
    }
    fsync_file_and_parent "$destination" || return 1
    [[ $(dirname -- "$source") == "$(dirname -- "$destination")" ]] ||
        fsync_directory "$(dirname -- "$source")" || return 1
}

publish_no_clobber() {
    local source=$1 destination=$2 temporary parent
    require_new_output 'receipt output' "$destination"
    parent=$(dirname -- "$destination")
    temporary=$(mktemp --tmpdir="$parent" '.viewflow-bootstrap-receipt.XXXXXXXX')
    chmod 0600 "$temporary"
    install -m 0600 -- "$source" "$temporary"
    fsync_file_and_parent "$temporary"
    if ! ln -- "$temporary" "$destination" 2>/dev/null; then
        rm -f -- "$temporary"
        die 'receipt no-clobber publication failed'
    fi
    rm -f -- "$temporary"
    fsync_file_and_parent "$destination"
    assert_owner_file 'published receipt' "$destination" 600
}

atomic_install() {
    local source=$1 destination=$2 mode=$3 directory temporary
    directory=$(dirname -- "$destination")
    temporary=$(mktemp --tmpdir="$directory" ".$(basename -- "$destination").new.XXXXXXXX")
    if ! install -m "$mode" -- "$source" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -fT -- "$temporary" "$destination"
}

exact_executable_pids() {
    local expected=$1 proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
}

unit_pid() {
    systemctl --user show --property MainPID --value "$1"
}

process_start_ticks() {
    local pid=$1 tail
    tail=$(sed -n 's/^[0-9][0-9]* (.*) //p' "/proc/$pid/stat")
    printf '%s\n' "$tail" | awk '{print $20}'
}

assert_no_listener() {
    local protocol=$1 port=$2 output
    case $protocol in
        udp) output=$(ss -H -lun "sport = :$port") ;;
        tcp) output=$(ss -H -ltn "sport = :$port") ;;
        *) die "unsupported listener protocol $protocol" ;;
    esac
    [[ -z $output ]] || die "unexpected $protocol listener on port $port"
}

wait_stopped() {
    local unit=$1 timeout=$2
    shift 2
    local deadline=$((SECONDS + timeout)) path clear pid
    while ((SECONDS < deadline)); do
        clear=1
        for path in "$@"; do
            [[ -z $(exact_executable_pids "$path") ]] || clear=0
        done
        pid=$(unit_pid "$unit" 2>/dev/null || true)
        if [[ $(systemctl --user is-active "$unit" 2>/dev/null || true) != active && ${pid:-0} == 0 && $clear == 1 ]]; then
            return 0
        fi
        sleep 0.1
    done
    die "$unit did not become inactive"
}

stop_both_units() {
    local timeout=${1:-30} failed=0
    systemctl --user stop "$DESKFLOW_UNIT" >/dev/null 2>&1 || failed=1
    wait_stopped "$DESKFLOW_UNIT" "$timeout" "$DESKFLOW_INSTALLED" "$DESKFLOW_CORE_INSTALLED" || failed=1
    systemctl --user stop "$VIEWFLOW_UNIT" >/dev/null 2>&1 || failed=1
    wait_stopped "$VIEWFLOW_UNIT" "$timeout" "$VIEWFLOW_INSTALLED" || failed=1
    return "$failed"
}

assert_both_units_stopped() {
    [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) != active &&
       $(unit_pid "$VIEWFLOW_UNIT") == 0 && -z $(exact_executable_pids "$VIEWFLOW_INSTALLED") ]] ||
        die 'Viewflow must be inactive with no exact process'
    [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) != active &&
       $(unit_pid "$DESKFLOW_UNIT") == 0 && -z $(exact_executable_pids "$DESKFLOW_INSTALLED") &&
       -z $(exact_executable_pids "$DESKFLOW_CORE_INSTALLED") ]] ||
        die 'Deskflow must be inactive with no exact GUI/core process'
    assert_no_listener udp "$VIEWFLOW_PORT"
    assert_no_listener tcp "$DESKFLOW_PORT"
    [[ ! -e $VIEWFLOW_SIDECAR && ! -L $VIEWFLOW_SIDECAR ]] || die 'sidecar socket remains'
    [[ ! -e $VIEWFLOW_ACCEPTANCE_SOCKET && ! -L $VIEWFLOW_ACCEPTANCE_SOCKET ]] || die 'Viewflow acceptance socket remains'
    [[ ! -e $DESKFLOW_ACCEPTANCE_SOCKET && ! -L $DESKFLOW_ACCEPTANCE_SOCKET ]] || die 'Deskflow acceptance socket remains'
}

assert_runtime_marker_absent() {
    [[ ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]] ||
        die 'legacy bootstrap requires VFQST002 to be wholly absent'
}

assert_deployment_marker() {
    local owner mode links size magic
    [[ -f $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER ]] || die 'VFDQT001 marker is missing or unsafe'
    read -r owner mode links size < <(stat -c '%u %a %h %s' -- "$DEPLOYMENT_MARKER")
    [[ $owner == "$EXPECTED_UID" && $mode == 600 && $links == 1 && $size == 256 ]] ||
        die 'VFDQT001 marker metadata is invalid'
    magic=$(LC_ALL=C head -c 8 -- "$DEPLOYMENT_MARKER")
    [[ $magic == "$DEPLOYMENT_MARKER_MAGIC" ]] || die 'VFDQT001 marker magic is invalid'
}

marker_identity() {
    stat -Lc '%d:%i:%u:%a:%h:%s' -- "$DEPLOYMENT_MARKER"
}

freeze_marker() {
    assert_deployment_marker
    BOOTSTRAP_MARKER_IDENTITY=$(marker_identity)
    BOOTSTRAP_MARKER_SHA=$(sha256 "$DEPLOYMENT_MARKER")
    export BOOTSTRAP_MARKER_IDENTITY BOOTSTRAP_MARKER_SHA
}

assert_marker_unchanged() {
    assert_deployment_marker
    [[ $(marker_identity) == "$BOOTSTRAP_MARKER_IDENTITY" ]] || die 'VFDQT001 marker identity changed'
    assert_hash 'VFDQT001 marker' "$DEPLOYMENT_MARKER" "$BOOTSTRAP_MARKER_SHA"
}

validate_publish_receipt() {
    local path=$1 operation=$2 source=$3 target=$4 coordinator=$5 generation=$6 marker_sha=$7
    assert_evidence 'deployment publish receipt' "$path"
    jq -e --arg op "$operation" --arg source "$source" --arg target "$target" \
        --arg coordinator "$coordinator" --arg generation "$generation" \
        --arg marker "$DEPLOYMENT_MARKER" --arg sha "$marker_sha" '
        def u64: type == "string" and test("^(0|[1-9][0-9]{0,19})$");
        def canonical_uuid:
            type == "string" and
            test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") and
            (gsub("-"; "") != "00000000000000000000000000000000");
        (keys == ["coordinator_instance_id","created_at_unix_ms","created_at_utc",
                  "marker_generation","marker_path","marker_sha256","operation_id",
                  "protocol_version","schema_version","source_display_id","state",
                  "target_device_id"]) and
        .schema_version == 1 and .state == "deployment-quarantine-published" and
        .protocol_version == "2.1" and .operation_id == $op and
        (.source_display_id | canonical_uuid) and
        (.target_device_id | canonical_uuid) and
        (.coordinator_instance_id | canonical_uuid) and
        ((.source_display_id | gsub("-"; "")) == $source) and
        ((.target_device_id | gsub("-"; "")) == $target) and
        ((.coordinator_instance_id | gsub("-"; "")) == $coordinator) and
        .marker_generation == $generation and
        (.marker_generation | u64) and .marker_path == $marker and .marker_sha256 == $sha and
        (.created_at_unix_ms | u64) and
        (.created_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    ' "$path" >/dev/null || die 'deployment publish receipt is invalid'
}

validate_handoff_receipt() {
    local path=$1 publish_path=$2 operation=$3 source=$4 target=$5 coordinator=$6 generation=$7
    local marker_cli_sha=$8 deskflow_sha=$9 core_sha=${10} expected_marker_sha=${11-}
    local publish_sha marker_sha
    publish_sha=$(sha256 "$publish_path")
    if [[ -n $expected_marker_sha ]]; then
        require_sha256 'historical deployment marker SHA-256' "$expected_marker_sha"
        marker_sha=$expected_marker_sha
    else
        marker_sha=$(sha256 "$DEPLOYMENT_MARKER")
    fi
    assert_evidence 'bootstrap handoff receipt' "$path"
    jq -e --arg op "$operation" --arg source "$source" --arg target "$target" \
        --arg coordinator "$coordinator" --arg generation "$generation" \
        --arg cli "$DEPLOYMENT_MARKER_TOOL_INSTALLED" --arg cli_sha "$marker_cli_sha" \
        --arg marker "$DEPLOYMENT_MARKER" --arg marker_sha "$marker_sha" \
        --arg publish "$publish_path" --arg publish_sha "$publish_sha" \
        --arg deskflow "$DESKFLOW_INSTALLED" --arg deskflow_sha "$deskflow_sha" \
        --arg core "$DESKFLOW_CORE_INSTALLED" --arg core_sha "$core_sha" \
        --arg runtime "$RUNTIME_MARKER" --argjson port "$DESKFLOW_PORT" '
        def canonical_uuid:
            type == "string" and
            test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") and
            (gsub("-"; "") != "00000000000000000000000000000000");
        (keys == ["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256",
                  "deployment_publish_receipt_path","deployment_publish_receipt_sha256",
                  "deskflow_core_exact_process_count","deskflow_core_executable_path",
                  "deskflow_core_executable_sha256","deskflow_exact_process_count",
                  "deskflow_executable_path","deskflow_executable_sha256","deskflow_tcp_listener_count",
                  "deskflow_tcp_port","deskflow_unit","deskflow_unit_active_state",
                  "deskflow_unit_main_pid","marker_cli_path","marker_cli_sha256","marker_generation",
                  "observed_at_utc","operation_id","protocol_version","runtime_marker_path",
                  "runtime_marker_present","schema_version","source_display_id","state","target_device_id"]) and
        .schema_version == 1 and .state == "viewflow-v13-marker-handoff-prepared" and
        .protocol_version == "2.1" and .operation_id == $op and
        (.source_display_id | canonical_uuid) and (.target_device_id | canonical_uuid) and
        (.coordinator_instance_id | canonical_uuid) and
        ((.source_display_id | gsub("-"; "")) == $source) and
        ((.target_device_id | gsub("-"; "")) == $target) and
        ((.coordinator_instance_id | gsub("-"; "")) == $coordinator) and
        .marker_generation == $generation and .marker_cli_path == $cli and .marker_cli_sha256 == $cli_sha and
        .deployment_marker_path == $marker and .deployment_marker_sha256 == $marker_sha and
        .deployment_publish_receipt_path == $publish and .deployment_publish_receipt_sha256 == $publish_sha and
        .deskflow_unit == "deskflow.service" and .deskflow_unit_active_state == "inactive" and
        .deskflow_unit_main_pid == 0 and .deskflow_executable_path == $deskflow and
        .deskflow_executable_sha256 == $deskflow_sha and .deskflow_exact_process_count == 0 and
        .deskflow_core_executable_path == $core and .deskflow_core_executable_sha256 == $core_sha and
        .deskflow_core_exact_process_count == 0 and .deskflow_tcp_port == $port and
        .deskflow_tcp_listener_count == 0 and .runtime_marker_path == $runtime and
        .runtime_marker_present == false
    ' "$path" >/dev/null || die 'bootstrap handoff receipt is invalid'
}

validate_bootstrap_request_receipt() {
    local path=$1 operation=$2 handoff_sha=$3 linux_sha=$4 windows_sha=$5 sid=$6
    assert_evidence 'Windows bootstrap request' "$path"
    jq -e --arg op "$operation" --arg handoff "$handoff_sha" --arg linux "$linux_sha" \
        --arg candidate "$windows_sha" --arg sid "$sid" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        (keys == ["candidate_path","candidate_sha256","created_at_utc",
                  "expected_device_id","expected_local_device_id","expected_peer","expected_server_name",
                  "expected_session_id","expected_source_display_id","force_release_envelope_path",
                  "install_success_receipt_path","installer_exit_receipt_path","installer_path","installer_sha256",
                  "launcher_path","launcher_sha256","linux_deactivation_proof_path",
                  "linux_deactivation_transcript_path","linux_frozen_evidence_path",
                  "linux_frozen_evidence_sha256","linux_stage_receipt_path","marker_handoff_receipt_path",
                  "marker_handoff_receipt_sha256","mutation_permit_path","operation_id","prepared_receipt_path",
                  "raw_force_release_receipt_path","readiness_commit_request_path","readiness_lock_path",
                  "readiness_receipt_path","recovery_bundle_path","recovery_force_release_receipt_path",
                  "rollback_manifest_path","rollback_script_path","rollback_script_sha256","rollback_token_path",
                  "schema_version","state","user_sid","wrapper_path","wrapper_sha256"]) and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-requested" and
        .operation_id == $op and .user_sid == $sid and .expected_session_id == 1 and
        .marker_handoff_receipt_sha256 == $handoff and .linux_frozen_evidence_sha256 == $linux and
        .candidate_sha256 == $candidate and (.wrapper_sha256 | hash) and
        (.rollback_script_sha256 | hash) and (.installer_sha256 | hash) and (.launcher_sha256 | hash)
    ' "$path" >/dev/null || die 'Windows bootstrap request binding is invalid'
}

validate_windows_prepared_receipt() {
    local path=$1 operation=$2 request_sha=$3 handoff_sha=$4 linux_sha=$5 windows_sha=$6 sid=$7
    assert_evidence 'Windows bootstrap prepared receipt' "$path"
    jq -e --arg op "$operation" --arg request "$request_sha" --arg handoff "$handoff_sha" \
        --arg linux "$linux_sha" --arg candidate "$windows_sha" --arg sid "$sid" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        (keys == ["bootstrap_request_sha256","candidate","linux_frozen_evidence_sha256",
                  "marker_handoff_receipt","old_executable","old_task","operation_id","outputs",
                  "prepared_at_utc","rollback_authorization","rollback_mode","rollback_script",
                  "schema_version","state","user_sid","wrapper"]) and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-recovery-armed" and
        .rollback_mode == "bootstrap-v1.3" and .operation_id == $op and .user_sid == $sid and
        .bootstrap_request_sha256 == $request and
        (.marker_handoff_receipt | keys == ["path","sha256"]) and
        (.marker_handoff_receipt.path | type == "string" and length > 0) and
        .marker_handoff_receipt.sha256 == $handoff and
        .linux_frozen_evidence_sha256 == $linux and
        (.candidate | keys == ["path","sha256"]) and
        (.candidate.path | type == "string" and length > 0) and .candidate.sha256 == $candidate and
        (.wrapper | keys == ["installed_path","sha256","source_path"]) and
        (.wrapper.source_path | type == "string" and length > 0) and
        (.wrapper.installed_path | type == "string" and length > 0) and (.wrapper.sha256 | hash) and
        (.rollback_script | keys == ["path","sha256"]) and
        (.rollback_script.path | type == "string" and length > 0) and (.rollback_script.sha256 | hash) and
        (.rollback_authorization | keys == ["manifest_path","manifest_sha256","token_path","token_sha256"]) and
        (.rollback_authorization.manifest_path | type == "string" and length > 0) and
        (.rollback_authorization.manifest_sha256 | hash) and
        (.rollback_authorization.token_path | type == "string" and length > 0) and
        (.rollback_authorization.token_sha256 | hash) and
        (.old_task | keys == ["name","state","xml_backup_path","xml_sha256"]) and
        (.old_task.name | type == "string" and length > 0) and .old_task.state == "Running" and
        (.old_task.xml_backup_path | type == "string" and length > 0) and (.old_task.xml_sha256 | hash) and
        (.old_executable | keys == ["owner_sid","path","process_id","process_start_filetime",
                                    "session_id","sha256"]) and
        (.old_executable.path | type == "string" and length > 0) and (.old_executable.sha256 | hash) and
        (.old_executable.process_id | uint53 and . > 0) and
        (.old_executable.process_start_filetime | type == "string" and test("^[1-9][0-9]{0,19}$")) and
        .old_executable.session_id == 1 and .old_executable.owner_sid == $sid and
        (.outputs | keys == ["force_release_envelope_path","force_release_receipt_path",
                             "install_success_receipt_path","installer_exit_receipt_path",
                             "linux_deactivation_proof_path","linux_deactivation_transcript_path",
                             "linux_stage_receipt_path","mutation_permit_path","readiness_commit_request_path",
                             "readiness_lock_path","readiness_receipt_path","recovery_bundle_path",
                             "recovery_force_release_receipt_path"]) and
        all(.outputs[]; type == "string" and length > 0) and
        (.prepared_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    ' "$path" >/dev/null || die 'Windows bootstrap prepared receipt is invalid'
}

validate_mutation_permit_receipt() {
    local path=$1 operation=$2 coordinator=$3 request_sha=$4 handoff_sha=$5 prepared_sha=$6 linux_sha=$7 windows_sha=$8
    local request_path=$9 linux_viewflow_sha=${10} linux_marker_sha=${11} linux_unit_sha=${12}
    assert_evidence 'Windows bootstrap mutation permit' "$path"
    jq -e --arg op "$operation" --arg coordinator "$coordinator" --arg request "$request_sha" --arg handoff "$handoff_sha" \
        --arg prepared "$prepared_sha" --arg linux "$linux_sha" --arg candidate "$windows_sha" \
        --arg wrapper "$(jq -er '.wrapper_sha256' "$request_path")" \
        --arg rollback "$(jq -er '.rollback_script_sha256' "$request_path")" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        # Linux entry points receive the compact UUID form, while the
        # Windows-facing permit carries the canonical hyphenated UUID.
        def canonical_uuid:
            type == "string" and
            test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") and
            (gsub("-"; "") != "00000000000000000000000000000000");
        (keys == ["bootstrap_request_sha256","candidate_sha256","coordinator_instance_id","issued_at_utc",
                  "linux_deployment_marker_sha256","linux_frozen_evidence_sha256",
                  "linux_viewflow_unit_sha256","linux_viewflowd_sha256",
                  "marker_handoff_receipt_sha256","operation_id","permit_nonce",
                  "rollback_manifest_sha256","rollback_script_sha256","rollback_token_sha256",
                  "schema_version","state","user_sid","windows_prepared_receipt_sha256","wrapper_sha256"]) and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-mutation-permitted" and
        .operation_id == $op and
        (.coordinator_instance_id | canonical_uuid) and
        ((.coordinator_instance_id | gsub("-"; "")) == $coordinator) and
        (.permit_nonce | type == "string" and test("^[0-9a-f]{64}$")) and
        .bootstrap_request_sha256 == $request and
        .marker_handoff_receipt_sha256 == $handoff and .windows_prepared_receipt_sha256 == $prepared and
        .linux_frozen_evidence_sha256 == $linux and .candidate_sha256 == $candidate and
        .linux_viewflowd_sha256 == $linux_vf and
        .linux_deployment_marker_sha256 == $linux_marker and
        .linux_viewflow_unit_sha256 == $linux_unit and
        .wrapper_sha256 == $wrapper and .rollback_script_sha256 == $rollback and
        (.rollback_manifest_sha256 | hash) and (.rollback_token_sha256 | hash)
    ' --arg linux_vf "$linux_viewflow_sha" --arg linux_marker "$linux_marker_sha" \
        --arg linux_unit "$linux_unit_sha" "$path" >/dev/null || die 'Windows bootstrap mutation permit is invalid'
}

validate_force_envelope_receipt() {
    local path=$1 operation=$2 request_sha=$3 handoff_sha=$4 prepared_sha=$5 permit_sha=$6 linux_sha=$7 sid=$8
    assert_evidence 'Windows force-release envelope' "$path"
    jq -e --arg op "$operation" --arg request "$request_sha" --arg handoff "$handoff_sha" \
        --arg prepared "$prepared_sha" --arg permit "$permit_sha" --arg linux "$linux_sha" --arg sid "$sid" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        (keys == ["bootstrap_request_sha256","completed_at_utc","linux_frozen_evidence_sha256",
                  "marker_handoff_receipt_sha256","mutation_permit_sha256","operation_id",
                  "raw_force_release_receipt_path","raw_force_release_receipt_sha256","schema_version",
                  "state","user_sid","windows_prepared_receipt_sha256"]) and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-force-release-attested" and
        .operation_id == $op and .user_sid == $sid and .bootstrap_request_sha256 == $request and
        .marker_handoff_receipt_sha256 == $handoff and .windows_prepared_receipt_sha256 == $prepared and
        .mutation_permit_sha256 == $permit and .linux_frozen_evidence_sha256 == $linux and
        (.raw_force_release_receipt_sha256 | hash)
    ' "$path" >/dev/null || die 'Windows force-release envelope is invalid'
}

validate_linux_frozen_evidence() {
    local path=$1 operation=$2 old_sha=$3 boot pid completed
    assert_evidence 'Linux frozen evidence' "$path"
    jq -e --arg op "$operation" --arg sha "$old_sha" --arg exe "$VIEWFLOW_INSTALLED" '
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        (keys == ["completed_at_unix_ms","daemon","journal","operation_id","post_stop",
                  "pre_stop","schema_version","state"]) and
        .schema_version == 1 and .state == "viewflow-v13-bootstrap-frozen" and
        .operation_id == $op and (.completed_at_unix_ms | uint53 and . > 0) and
        (.daemon | keys == ["boot_id","daemon_instance_id","executable","pid","sha256",
                            "start_ticks","systemd_invocation_id"]) and
        .daemon.executable == $exe and .daemon.sha256 == $sha and
        (.daemon.pid | uint53 and . > 0) and (.daemon.start_ticks | uint53 and . > 0) and
        (.daemon.boot_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        .daemon.daemon_instance_id == (.daemon.boot_id + "-" + (.daemon.pid|tostring) + "-" + (.daemon.start_ticks|tostring)) and
        (.daemon.systemd_invocation_id | test("^[0-9a-f]{32}$")) and
        (.journal.slice_sha256 | hash) and (.journal.counts.protocol_1_3_startup == 1) and
        (.pre_stop == {deskflow_unit_active_state:"inactive",deskflow_main_pid:0,
                       deskflow_exact_process_count:0,deskflow_core_exact_process_count:0,
                       deskflow_tcp_24800_listener_count:0}) and
        .post_stop.unit_active_state == "inactive" and .post_stop.main_pid == 0 and
        .post_stop.exact_process_count == 0 and .post_stop.udp_44119_listener_count == 0 and
        .post_stop.sidecar_socket_present == false and
        .post_stop.original_daemon_pid_present == false and
        (.post_stop.command_output_sha256 | hash)
    ' "$path" >/dev/null || die 'Linux frozen evidence is invalid'
    boot=$(jq -er '.daemon.boot_id' "$path")
    pid=$(jq -er '.daemon.pid' "$path")
    [[ $boot == "$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)" ]] || die 'Linux frozen evidence belongs to another boot'
    [[ ! -e /proc/$pid ]] || die 'frozen Linux daemon PID exists again'
    completed=$(jq -er '.completed_at_unix_ms' "$path")
    (( $(date -u +%s) - completed / 1000 <= 1800 )) || die 'Linux frozen evidence is stale'
}

validate_force_receipt() {
    local path=$1 operation=$2 linux_sha=$3 windows_sha=$4 sid=$5
    assert_evidence 'Windows force-release receipt' "$path"
    jq -e --arg op "$operation" --arg linux "$linux_sha" --arg candidate "$windows_sha" \
        --arg sid "$sid" --arg desktop "$WINDOWS_EXPECTED_DESKTOP" \
        --argjson session "$WINDOWS_EXPECTED_SESSION" '
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        (keys == ["completed_at_utc","input_desktop","inserted_input_count",
                  "linux_frozen_evidence_sha256","operation_id","requested_input_count",
                  "schema_version","state","tool_executable_sha256","tool_pid",
                  "tool_process_start_filetime","tool_session_id","tool_user_sid",
                  "verification_stable_ms"]) and
        .schema_version == 3 and .state == "viewflow-force-release-completed" and
        .operation_id == $op and .linux_frozen_evidence_sha256 == $linux and
        .tool_executable_sha256 == $candidate and .tool_user_sid == $sid and
        .tool_session_id == $session and .input_desktop == $desktop and
        .requested_input_count == 135 and .inserted_input_count == 135 and
        .verification_stable_ms == 500 and (.tool_pid | uint53 and . > 0) and
        (.tool_process_start_filetime | type == "string" and test("^[1-9][0-9]{0,19}$")) and
        (.completed_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    ' "$path" >/dev/null || die 'Windows force-release receipt is invalid'
}

validate_windows_install_receipt() {
    local path=$1 operation=$2 linux_sha=$3 raw_force_sha=$4 handoff_sha=$5 prepared_sha=$6
    local permit_sha=$7 stage_sha=$8 request_sha=$9 windows_sha=${10} wrapper_sha=${11} task_sha=${12} sid=${13}
    assert_evidence 'Windows install-success receipt' "$path"
    jq -e --arg op "$operation" --arg linux "$linux_sha" --arg raw_force "$raw_force_sha" \
        --arg handoff "$handoff_sha" --arg prepared "$prepared_sha" --arg permit "$permit_sha" \
        --arg stage "$stage_sha" --arg request "$request_sha" \
        --arg candidate "$windows_sha" --arg wrapper "$wrapper_sha" --arg task "$task_sha" \
        --arg sid "$sid" --arg peer '172.16.105.62:44119' --arg device "$VIEWFLOW_TARGET" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        (keys == ["bootstrap_request_sha256","commit_mode","commit_nonce","commit_request_sha256","committed_at_utc",
                  "committed_by_daemon","completed_at_utc","device_id","force_release_receipt_sha256",
                  "installed_wrapper_sha256","linux_frozen_evidence_sha256","linux_stage_receipt_sha256",
                  "marker_handoff_receipt_sha256","mutation_permit_sha256","new_process_pid",
                  "new_process_session_id","new_process_start_filetime","new_process_user_sid",
                  "new_viewflow_executable_sha256","old_viewflow_executable_sha256","operation_id",
                  "peer","protocol_version","readiness_connection_generation",
                  "readiness_established_at_utc","readiness_lock_sha256","readiness_receipt_sha256",
                  "scheduled_task_xml_sha256","schema_version","state","windows_prepared_receipt_sha256"]) and
        .schema_version == 5 and .state == "viewflow-v2-windows-installed" and
        .operation_id == $op and .commit_mode == "bootstrap-v1.3" and .committed_by_daemon == true and
        (.commit_nonce | type == "string" and test("^[0-9a-f]{32}$")) and
        (.commit_request_sha256 | hash) and .linux_frozen_evidence_sha256 == $linux and
        .force_release_receipt_sha256 == $raw_force and
        .marker_handoff_receipt_sha256 == $handoff and
        .windows_prepared_receipt_sha256 == $prepared and
        .mutation_permit_sha256 == $permit and .linux_stage_receipt_sha256 == $stage and
        .bootstrap_request_sha256 == $request and
        ([.force_release_receipt_sha256,.marker_handoff_receipt_sha256,
          .windows_prepared_receipt_sha256,.mutation_permit_sha256,
          .linux_stage_receipt_sha256,.bootstrap_request_sha256] | unique | length == 6) and
        (.readiness_receipt_sha256 | hash) and
        (.readiness_lock_sha256 | hash) and (.readiness_connection_generation | uint53 and . > 0) and
        .new_viewflow_executable_sha256 == $candidate and .installed_wrapper_sha256 == $wrapper and
        .scheduled_task_xml_sha256 == $task and .new_process_user_sid == $sid and
        .new_process_session_id == 1 and .protocol_version == "2.1" and .peer == $peer and
        .device_id == $device and .readiness_established_at_utc <= .completed_at_utc and
        .completed_at_utc <= .committed_at_utc
    ' "$path" >/dev/null || die 'Windows install-success receipt is invalid'
}

assert_viewflow_unit_contract() {
    local path=$1
    grep -Fqx -- "ExecStart=/home/wilf/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119 --cert /home/wilf/.local/share/viewflow/identity/peer.pem --key /home/wilf/.local/share/viewflow/identity/peer.key --ca /home/wilf/.local/share/viewflow/identity/ca.pem --device-id 00000000000000000000000000000001 --sidecar-socket %t/viewflow/deskflow.sock --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002 --quiesce-proof %t/viewflow/deploy-quiesced.json --quiesce-arm-file %t/viewflow/deploy-quiesce-arm.json --acceptance-socket %t/viewflow/post-release-acceptance.sock --acceptance-state-dir $VIEWFLOW_ACCEPTANCE_STATE_DIR" "$path" ||
        die 'Viewflow unit candidate does not have the exact 2.1 acceptance contract'
}
