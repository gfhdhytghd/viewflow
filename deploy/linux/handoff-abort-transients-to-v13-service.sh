#!/usr/bin/env bash

# Retire an already-verified failed-v1.3 abort terminal transient baseline and
# establish the installed protocol-1.3 Viewflow service boundary.  This script
# never starts Deskflow and never contacts another host.

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'error: handoff-abort-transients-to-v13-service.sh must be executed, not sourced\n' >&2
    return 64
fi

if [[ -n ${LD_PRELOAD-} || -n ${LD_AUDIT-} || -n ${LD_LIBRARY_PATH-} ||
      -n ${BASH_ENV-} || -n ${ENV-} ]]; then
    printf 'error: loader/shell startup environment must be empty; invoke through env -i\n' >&2
    exit 64
fi
unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH BASH_ENV ENV

set -Eeuo pipefail
shopt -s nullglob
umask 077
readonly PATH=/usr/bin:/bin
export PATH

readonly EXPECTED_UID=1000
readonly EXPECTED_HOME=/home/wilf
readonly VIEWFLOW_INSTALLED=/home/wilf/.local/lib/viewflow/viewflowd
readonly VIEWFLOW_UNIT_FILE=/home/wilf/.config/systemd/user/viewflow-peer.service
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly DESKFLOW_UNIT=deskflow.service
readonly VIEWFLOW_PORT=44119
readonly DESKFLOW_PORT=24800
readonly VIEWFLOW_SIDECAR=/run/user/1000/viewflow/deskflow.sock
readonly DEPLOYMENT_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly DEPLOYMENT_ABORT_CLAIM=/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim
readonly DEPLOYMENT_RELEASE_CLAIM=/home/wilf/.local/state/viewflow/deployment-quarantine.v1.release-claim
readonly RUNTIME_QUARANTINE=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
readonly EXPECTED_RECOVERY_V3_TERMINAL_SHA256=f5d5446e51b0d6138352da7c323102baf283df9e63cf7574ab12246708508af3
readonly EXPECTED_RECOVERY_V3_QUERY_SHA256=4f8a7cb2f0f0c4f01397a4eb4b9f0c1350f52607fb07acec763c19593da519a8
readonly EXPECTED_SCHEMA5_ABORT_RECEIPT_SHA256=6cd825cd6003053b3677acc0235933f34e179aba3723a77b14aeada9d1ec3766
readonly EXPECTED_DURABLE_VFDQA_SHA256=c5a4b7b0900f8907087c65724f630b474facd894d4bf23749b562ea7af967b19
readonly EXPECTED_RETIRED_CLAIM_SHA256=a336070106802153c9834154ab493b22a19eeb434ebed1e77000e44aa9ba5000
readonly STOP_TIMEOUT_SECONDS=30
readonly START_TIMEOUT_SECONDS=30
readonly PROTOCOL_13_STARTUP='viewflowd protocol 1.3 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged'
readonly EXPECTED_VIEWFLOW_UNIT_EXECSTART='ExecStart=/home/wilf/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119 --cert /home/wilf/.local/share/viewflow/identity/peer.pem --key /home/wilf/.local/share/viewflow/identity/peer.key --ca /home/wilf/.local/share/viewflow/identity/ca.pem --device-id 00000000000000000000000000000001 --sidecar-socket %t/viewflow/deskflow.sock --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002'
readonly -a EXPECTED_VIEWFLOW_ARGV=(
    /home/wilf/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119
    --cert /home/wilf/.local/share/viewflow/identity/peer.pem
    --key /home/wilf/.local/share/viewflow/identity/peer.key
    --ca /home/wilf/.local/share/viewflow/identity/ca.pem
    --device-id 00000000000000000000000000000001
    --sidecar-socket /run/user/1000/viewflow/deskflow.sock
    --sidecar-peer 172.16.105.70
    --sidecar-target-device 00000000000000000000000000000002
)

operation_id='' terminal_receipt='' terminal_receipt_sha=''
linux_started_receipt='' linux_started_receipt_sha=''
recovery_v3_terminal='' recovery_v3_terminal_sha=''
recovery_v3_query='' recovery_v3_query_sha=''
schema5_abort_receipt='' schema5_abort_receipt_sha=''
durable_vfdqa='' durable_vfdqa_sha=''
retired_claim='' retired_claim_sha=''
installed_viewflow_sha='' installed_viewflow_unit_sha='' handoff_receipt=''
receipt_temp='' persistent_started=0 receipt_published=0
persistent_owned_pid='' persistent_owned_ticks='' persistent_owned_invocation='' persistent_owned_cgroup=''
transition_intent='' transition_intent_sha='' transition_state=''
intent_initial_state='' preintent_partial_adopted=0 adopt_preintent_partial=0
temporary_files=()
persistent_pid='' persistent_ticks='' persistent_invocation='' persistent_cgroup=''
persistent_expected_exec='' persistent_observed_exec='' persistent_cmdline_sha=''
persistent_startup_sha='' persistent_probe_sha='' persistent_probe_port=''
persistent_journal_sha='' persistent_journal_entries='' persistent_journal_start_cursor=''
persistent_journal_start_us='' persistent_journal_end_cursor='' persistent_journal_end_us=''
persistent_sidecar_path='' persistent_sidecar_inode='' persistent_sidecar_owner_pid=''
persistent_sidecar_owner_fd='' persistent_sidecar_listener_count=''
observed_sidecar_path='' observed_sidecar_inode='' observed_sidecar_owner_pid=''
observed_sidecar_owner_fd='' observed_sidecar_listener_count=''

usage() {
    printf '%s\n' \
        'Usage: handoff-abort-transients-to-v13-service.sh \' \
        '  --operation-id OPERATION \' \
        '  --terminal-receipt /absolute/failed-v13-abort-transition.json \' \
        '  --terminal-receipt-sha256 LOWERCASE_SHA256 \' \
        '  --linux-v13-started-receipt /absolute/linux-v13-started.json \' \
        '  --linux-v13-started-receipt-sha256 LOWERCASE_SHA256 \' \
        '  --recovery-v3-terminal /absolute/recovery-v3-terminal.json \' \
        '  --recovery-v3-terminal-sha256 LOWERCASE_SHA256 \' \
        '  --recovery-v3-query /absolute/recovery-v3-query.json \' \
        '  --recovery-v3-query-sha256 LOWERCASE_SHA256 \' \
        '  --schema5-abort-receipt /absolute/schema5-abort-receipt.json \' \
        '  --schema5-abort-receipt-sha256 LOWERCASE_SHA256 \' \
        '  --durable-vfdqa /absolute/content-addressed-vfdqa \' \
        '  --durable-vfdqa-sha256 LOWERCASE_SHA256 \' \
        '  --retired-claim /absolute/content-addressed-vfdqt \' \
        '  --retired-claim-sha256 LOWERCASE_SHA256 \' \
        '  --installed-viewflow-sha256 LOWERCASE_SHA256 \' \
        '  --installed-viewflow-unit-sha256 LOWERCASE_SHA256 \' \
        '  [--adopt-preintent-deskflow-stopped] \' \
        '  --handoff-receipt /absolute/new/owner-only/handoff.json'
}

die() { printf 'error: %s\n' "$*" >&2; return 1; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
require_value() { [[ -n ${2-} ]] || die "$1 requires a value"; }

while (($#)); do
    case $1 in
        --operation-id) require_value "$1" "${2-}"; operation_id=$2; shift 2 ;;
        --terminal-receipt) require_value "$1" "${2-}"; terminal_receipt=$2; shift 2 ;;
        --terminal-receipt-sha256) require_value "$1" "${2-}"; terminal_receipt_sha=$2; shift 2 ;;
        --linux-v13-started-receipt) require_value "$1" "${2-}"; linux_started_receipt=$2; shift 2 ;;
        --linux-v13-started-receipt-sha256) require_value "$1" "${2-}"; linux_started_receipt_sha=$2; shift 2 ;;
        --recovery-v3-terminal) require_value "$1" "${2-}"; recovery_v3_terminal=$2; shift 2 ;;
        --recovery-v3-terminal-sha256) require_value "$1" "${2-}"; recovery_v3_terminal_sha=$2; shift 2 ;;
        --recovery-v3-query) require_value "$1" "${2-}"; recovery_v3_query=$2; shift 2 ;;
        --recovery-v3-query-sha256) require_value "$1" "${2-}"; recovery_v3_query_sha=$2; shift 2 ;;
        --schema5-abort-receipt) require_value "$1" "${2-}"; schema5_abort_receipt=$2; shift 2 ;;
        --schema5-abort-receipt-sha256) require_value "$1" "${2-}"; schema5_abort_receipt_sha=$2; shift 2 ;;
        --durable-vfdqa) require_value "$1" "${2-}"; durable_vfdqa=$2; shift 2 ;;
        --durable-vfdqa-sha256) require_value "$1" "${2-}"; durable_vfdqa_sha=$2; shift 2 ;;
        --retired-claim) require_value "$1" "${2-}"; retired_claim=$2; shift 2 ;;
        --retired-claim-sha256) require_value "$1" "${2-}"; retired_claim_sha=$2; shift 2 ;;
        --installed-viewflow-sha256) require_value "$1" "${2-}"; installed_viewflow_sha=$2; shift 2 ;;
        --installed-viewflow-unit-sha256) require_value "$1" "${2-}"; installed_viewflow_unit_sha=$2; shift 2 ;;
        --adopt-preintent-deskflow-stopped)
            ((adopt_preintent_partial == 0)) || die 'duplicate --adopt-preintent-deskflow-stopped'
            adopt_preintent_partial=1; shift
            ;;
        --handoff-receipt) require_value "$1" "${2-}"; handoff_receipt=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

cleanup() {
    local status=$? path
    [[ -z $receipt_temp ]] || rm -f -- "$receipt_temp"
    for path in "${temporary_files[@]}"; do [[ -z $path ]] || rm -f -- "$path"; done
    if ((status != 0 && receipt_published == 0)) && [[ -f $handoff_receipt && ! -L $handoff_receipt ]] &&
       validate_handoff_receipt "$handoff_receipt" >/dev/null 2>&1; then
        # The create-once receipt link is the commit point.  Never roll back a
        # committed service merely because a later fsync/readback was interrupted.
        receipt_published=1
    fi
    if ((status != 0 && persistent_started == 1 && receipt_published == 0)); then
        if persistent_cleanup_identity_matches; then
            systemctl --user stop "$VIEWFLOW_UNIT" >/dev/null 2>&1 || true
        else
            printf 'error: persistent Viewflow cleanup identity changed; refusing to stop a different invocation\n' >&2
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

assert_strict_json_document() {
    local label=$1 path=$2
    jq -s -e 'length == 1 and (.[0] | type == "object")' "$path" >/dev/null ||
        die "$label must contain exactly one JSON object"
    jq --stream -e '
        reduce (inputs | select(length == 2) | .[0] | @json) as $p
            ({}; .[$p] = ((.[$p] // 0) + 1)) |
        all(to_entries[]; .value == 1)
    ' "$path" >/dev/null || die "$label contains duplicate object keys"
}

require_sha256() { [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "$1 must be lowercase SHA-256"; }

atomic_publish_noreplace() {
    local source=$1 destination=$2
    /usr/bin/python3 -I -E - "$source" "$destination" <<'PY'
import ctypes
import errno
import os
import stat
import sys

source, destination = sys.argv[1:]
RENAME_NOREPLACE = 1
source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
source_stat = os.fstat(source_fd)
if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_nlink != 1:
    raise SystemExit(66)
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(-100, os.fsencode(source), -100, os.fsencode(destination), RENAME_NOREPLACE) != 0:
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        raise SystemExit(17)
    raise OSError(error, os.strerror(error), destination)
destination_stat = os.stat(destination, follow_symlinks=False)
identity = lambda item: (item.st_dev, item.st_ino, item.st_uid, stat.S_IMODE(item.st_mode), item.st_nlink, item.st_size)
if identity(destination_stat) != identity(source_stat):
    raise SystemExit(73)
os.fsync(source_fd)
directory_fd = os.open(os.path.dirname(destination), os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
os.fsync(directory_fd)
os.close(directory_fd)
os.close(source_fd)
PY
}

require_owner_only_input() {
    local label=$1 path=$2 expected=$3
    [[ $path == /* && -f $path && ! -L $path && $(stat -c '%u:%a:%h' -- "$path") == 1000:600:1 ]] ||
        die "$label must be an owner-only regular input"
    [[ $(sha256 "$path") == "$expected" ]] || die "$label SHA-256 differs"
    assert_strict_json_document "$label" "$path"
}

require_owner_only_binary_input() {
    local label=$1 path=$2 expected=$3 expected_size=$4 expected_magic=$5
    [[ $path == /* && -f $path && ! -L $path &&
       $(stat -c '%u:%a:%h:%s' -- "$path") == "1000:600:1:$expected_size" ]] ||
        die "$label must be an owner-only regular input of size $expected_size"
    [[ $(sha256 "$path") == "$expected" ]] || die "$label SHA-256 differs"
    [[ $(dd if="$path" bs=1 count=8 status=none) == "$expected_magic" ]] ||
        die "$label magic differs"
}

assert_quarantine_absent() {
    local path
    for path in "$DEPLOYMENT_MARKER" "$DEPLOYMENT_ABORT_CLAIM" "$DEPLOYMENT_RELEASE_CLAIM" "$RUNTIME_QUARANTINE"; do
        [[ ! -e $path && ! -L $path ]] || die "quarantine/claim path must remain absent: $path"
    done
}

validate_recovery_v3_lineage() {
    local marker_query abort_canonical query_canonical
    jq -e --arg op "$operation_id" --arg abort "$schema5_abort_receipt_sha" \
        --arg query "$recovery_v3_query_sha" --arg durable "$durable_vfdqa_sha" \
        --arg retired "$retired_claim_sha" --arg transition "$terminal_receipt_sha" \
        --arg linux "$linux_started_receipt_sha" '
        keys == ["abort_committed_at_unix_ms","approval_sha256","committed_abort_receipt_sha256",
          "committed_v1_output_sha256","coordinator_redispatched","durable_vfdqa_sha256","gate_sha256",
          "launcher_sha256","linux_live_census_sha256","manifest_sha256","marker_absent",
          "marker_query_replayed","operation_id","predecessor_v2_approval_sha256","predecessor_v2_gate_sha256",
          "predecessor_v2_launcher_sha256","predecessor_v2_manifest_sha256","recovery_query_sha256",
          "retired_claim_sha256","schema_version","state","windows_live_census_sha256"] and
        .schema_version == 3 and
        .state == "viewflow-op442-schema5-abort-post-commit-recovery-v3-terminal" and
        .operation_id == $op and .committed_abort_receipt_sha256 == $abort and
        (.committed_v1_output_sha256 | keys) == ["abort_receipt","authenticated_v13_peer","authorization",
          "linux_v13_started","transition","windows_v13_started"] and
        .committed_v1_output_sha256.abort_receipt == $abort and
        .committed_v1_output_sha256.transition == $transition and
        .committed_v1_output_sha256.linux_v13_started == $linux and
        .recovery_query_sha256 == $query and .durable_vfdqa_sha256 == $durable and
        .retired_claim_sha256 == $retired and .marker_absent == true and
        .marker_query_replayed == true and .coordinator_redispatched == false
    ' "$recovery_v3_terminal" >/dev/null || die 'recovery-v3 terminal lineage/binding is invalid'
    jq -e --arg op "$operation_id" --arg abort "$schema5_abort_receipt_sha" \
        --arg durable "$durable_vfdqa" --arg retired "$retired_claim_sha" '
        keys == ["authorization_sha256","committed_abort_receipt_sha256","coordinator_redispatched",
          "marker_query","marker_query_sha256","operation_id","predecessor_v2_approval_sha256",
          "predecessor_v2_gate_sha256","predecessor_v2_launcher_sha256","predecessor_v2_manifest_sha256",
          "schema_version","state"] and .schema_version == 3 and
        .state == "viewflow-op442-schema5-abort-recovery-v3-marker-query-replayed" and
        .operation_id == $op and .committed_abort_receipt_sha256 == $abort and
        .coordinator_redispatched == false and .marker_query.schema_version == 5 and
        .marker_query.state == "deployment-quarantine-aborted" and .marker_query.operation_id == $op and
        .marker_query.replayed == true and .marker_query.abort_receipt_path == $durable and
        .marker_query.aborted_marker_sha256 == $retired and
        .marker_query.marker_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and
        .marker_query.abort_claim_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim"
    ' "$recovery_v3_query" >/dev/null || die 'recovery-v3 query lineage/binding is invalid'
    jq -e --arg op "$operation_id" --arg durable "$durable_vfdqa" --arg retired "$retired_claim_sha" \
        --arg linux "$linux_started_receipt_sha" '
        keys == ["abort_authorization_path","abort_authorization_sha256","abort_claim_path",
          "abort_committed_at_unix_ms","abort_committed_at_utc","abort_point","abort_receipt_path",
          "aborted_marker_sha256","authenticated_v13_peer_receipt_sha256","authorization_state",
          "bootstrap_request_sha256","coordinator_failure_phase","coordinator_instance_id",
          "coordinator_mutation_possible","coordinator_terminal_state_sha256","deployment_publish_receipt_sha256",
          "deployment_release_claimed","force_release_executed","initial_force_release_executed",
          "installer_exit_receipt_sha256","linux_deactivation_proof_sha256","linux_deactivation_transcript_sha256",
          "linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_created_at_unix_ms",
          "marker_generation","marker_handoff_receipt_sha256","marker_path","mutation_permit_published",
          "mutation_permit_receipt_sha256","operation_id","protocol_2_1","protocol_version",
          "recovery_bundle_sha256","replayed","rollback_performed","rollback_token_consumed",
          "schema1_handoff_lineage_receipt_sha256","schema_version","second_force_release_executed",
          "source_display_id","state","target_device_id","windows_prepared_receipt_sha256",
          "windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
        .schema_version == 5 and .state == "deployment-quarantine-aborted" and
        .operation_id == $op and .replayed == false and .protocol_version == "1.3" and
        .protocol_2_1 == false and .rollback_performed == true and .rollback_token_consumed == true and
        .mutation_permit_published == true and .force_release_executed == false and
        .second_force_release_executed == false and .deployment_release_claimed == false and
        .coordinator_failure_phase == "MUTATION_PERMITTED" and .coordinator_mutation_possible == true and
        .linux_v13_started_receipt_sha256 == $linux and .aborted_marker_sha256 == $retired and
        .marker_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and
        .abort_claim_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim" and
        .abort_receipt_path == $durable
    ' "$schema5_abort_receipt" >/dev/null || die 'schema5 abort receipt lineage/binding is invalid'
    abort_canonical=$(jq -cS '.replayed = true' "$schema5_abort_receipt")
    query_canonical=$(jq -cS '.marker_query' "$recovery_v3_query")
    [[ $query_canonical == "$abort_canonical" ]] || die 'recovery-v3 marker query is not an exact schema5 replay'
    jq -e --arg abort "$schema5_abort_receipt_sha" --arg marker "$retired_claim_sha" '
        .deployment_abort_receipt_sha256 == $abort and .deployment_marker_sha256 == $marker
    ' "$terminal_receipt" >/dev/null || die 'transient terminal does not bind the schema5 abort/retired marker'
    assert_quarantine_absent
}

assert_bound_inputs_unchanged() {
    [[ $(sha256 "$terminal_receipt") == "$terminal_receipt_sha" &&
       $(sha256 "$linux_started_receipt") == "$linux_started_receipt_sha" &&
       $(sha256 "$recovery_v3_terminal") == "$recovery_v3_terminal_sha" &&
       $(sha256 "$recovery_v3_query") == "$recovery_v3_query_sha" &&
       $(sha256 "$schema5_abort_receipt") == "$schema5_abort_receipt_sha" &&
       $(sha256 "$durable_vfdqa") == "$durable_vfdqa_sha" &&
       $(sha256 "$retired_claim") == "$retired_claim_sha" ]] ||
        die 'recovery-v3 lineage input bytes changed'
    assert_quarantine_absent
}

require_owner_output_boundary() {
    local parent mode
    [[ $handoff_receipt == /* && ! -L $handoff_receipt ]] ||
        die '--handoff-receipt must be an absolute non-symlink path'
    parent=$(dirname -- "$handoff_receipt")
    [[ -d $parent && ! -L $parent && $(stat -c '%u' -- "$parent") == 1000 ]] ||
        die 'handoff receipt parent must be an owner-1000 real directory'
    mode=$(stat -c '%a' -- "$parent")
    (( (8#$mode & 8#077) == 0 )) || die 'handoff receipt parent must be owner-only'
    if [[ -e $handoff_receipt ]]; then
        [[ -f $handoff_receipt && $(stat -c '%u:%a:%h' -- "$handoff_receipt") == 1000:600:1 ]] ||
            die 'existing handoff receipt is not owner-only/create-once'
    fi
}

unit_property() { systemctl --user show --property "$2" --value "$1"; }

process_start_ticks() {
    local line tail
    IFS= read -r line <"/proc/$1/stat" || return 1
    tail=${line#*) }
    awk '{print $20}' <<<"$tail"
}

process_control_group() {
    awk -F: '$1 == "0" {print $3}' "/proc/$1/cgroup"
}

capture_persistent_cleanup_identity() {
    local pid=$1 ticks=$2 invocation=$3 cgroup=$4
    [[ $pid =~ ^[1-9][0-9]*$ && $ticks =~ ^[1-9][0-9]*$ &&
       $invocation =~ ^[0-9a-f]{32}$ && $cgroup == */"$VIEWFLOW_UNIT" &&
       $(unit_property "$VIEWFLOW_UNIT" ActiveState) == active &&
       $(unit_property "$VIEWFLOW_UNIT" SubState) == running &&
       $(unit_property "$VIEWFLOW_UNIT" MainPID) == "$pid" &&
       $(unit_property "$VIEWFLOW_UNIT" InvocationID) == "$invocation" &&
       $(unit_property "$VIEWFLOW_UNIT" ControlGroup) == "$cgroup" &&
       $(process_start_ticks "$pid") == "$ticks" && $(process_control_group "$pid") == "$cgroup" &&
       $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" ]] ||
        die 'cannot capture exact persistent cleanup ownership identity'
    persistent_owned_pid=$pid
    persistent_owned_ticks=$ticks
    persistent_owned_invocation=$invocation
    persistent_owned_cgroup=$cgroup
}

persistent_cleanup_identity_matches() {
    [[ $persistent_owned_pid =~ ^[1-9][0-9]*$ && $persistent_owned_ticks =~ ^[1-9][0-9]*$ &&
       $persistent_owned_invocation =~ ^[0-9a-f]{32}$ && $persistent_owned_cgroup == */"$VIEWFLOW_UNIT" &&
       $(unit_property "$VIEWFLOW_UNIT" ActiveState 2>/dev/null || true) == active &&
       $(unit_property "$VIEWFLOW_UNIT" SubState 2>/dev/null || true) == running &&
       $(unit_property "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true) == "$persistent_owned_pid" &&
       $(unit_property "$VIEWFLOW_UNIT" InvocationID 2>/dev/null || true) == "$persistent_owned_invocation" &&
       $(unit_property "$VIEWFLOW_UNIT" ControlGroup 2>/dev/null || true) == "$persistent_owned_cgroup" &&
       -e /proc/$persistent_owned_pid/exe &&
       $(process_start_ticks "$persistent_owned_pid" 2>/dev/null || true) == "$persistent_owned_ticks" &&
       $(process_control_group "$persistent_owned_pid" 2>/dev/null || true) == "$persistent_owned_cgroup" &&
       $(sha256 "/proc/$persistent_owned_pid/exe" 2>/dev/null || true) == "$installed_viewflow_sha" ]]
}

exact_executable_pids() {
    local expected=$1 proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
    return 0
}

observed_exec_start_sha() {
    local unit=$1 object_response object_path property_response canonical
    object_response=$(busctl --user --json=short call org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetUnit s "$unit")
    object_path=$(printf '%s\n' "$object_response" | jq -er 'select(.type == "o" and (.data|length) == 1) | .data[0]')
    property_response=$(busctl --user --json=short get-property org.freedesktop.systemd1 \
        "$object_path" org.freedesktop.systemd1.Service ExecStart)
    canonical=$(jq -ceS '
        select(.type == "a(sasbttttuii)" and (.data|length) == 1) |
        .data[0] as $value |
        select(($value|length) == 10 and ($value[0]|type) == "string" and
               ($value[1]|type) == "array" and ($value[2]|type) == "boolean") |
        {argv:$value[1],ignore_errors:$value[2],path:$value[0]}
    ' < <(printf '%s\n' "$property_response"))
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

expected_persistent_exec_start_sha() {
    local canonical
    canonical=$(jq -cnS --arg path "$VIEWFLOW_INSTALLED" --args \
        '{argv:$ARGS.positional,ignore_errors:false,path:$path}' -- "${EXPECTED_VIEWFLOW_ARGV[@]}")
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

expected_persistent_cmdline_sha() {
    printf '%s\0' "${EXPECTED_VIEWFLOW_ARGV[@]}" | sha256sum | awk '{print $1}'
}

assert_unit_identity() {
    local unit=$1 expected_pid=$2 expected_ticks=$3 expected_invocation=$4 expected_cgroup=$5
    [[ $(unit_property "$unit" LoadState) == loaded &&
       $(unit_property "$unit" ActiveState) == active &&
       $(unit_property "$unit" SubState) == running &&
       $(unit_property "$unit" Transient) == yes &&
       $(unit_property "$unit" KillMode) == control-group &&
       $(unit_property "$unit" MainPID) == "$expected_pid" &&
       $(unit_property "$unit" InvocationID) == "$expected_invocation" &&
       $(unit_property "$unit" ControlGroup) == "$expected_cgroup" &&
       $(process_start_ticks "$expected_pid") == "$expected_ticks" &&
       $(process_control_group "$expected_pid") == "$expected_cgroup" ]] ||
        die "transient unit identity differs: $unit"
}

process_descends_from() {
    local child=$1 ancestor=$2 parent line tail
    while [[ $child =~ ^[1-9][0-9]*$ && $child != 1 ]]; do
        [[ $child == "$ancestor" ]] && return 0
        IFS= read -r line <"/proc/$child/stat" 2>/dev/null || break
        tail=${line#*) }
        parent=$(awk '{print $2}' <<<"$tail")
        [[ $parent =~ ^[1-9][0-9]*$ && $parent != "$child" ]] || break
        child=$parent
    done
    return 1
}

validate_terminal_receipts() {
    local expected_keys linux_keys deskflow_unit viewflow_unit
    expected_keys='["abort_authorization_sha256","authenticated_v13_peer_receipt_sha256","bubblewrap_sha256","deployment_abort_receipt_sha256","deployment_marker_sha256","fd_gate_payload_sha256","linux_deskflow_control_group","linux_deskflow_core_executable_sha256","linux_deskflow_core_pid","linux_deskflow_core_runtime_path","linux_deskflow_core_start_ticks","linux_deskflow_exec_start_sha256","linux_deskflow_executable_sha256","linux_deskflow_expected_exec_start_sha256","linux_deskflow_invocation_id","linux_deskflow_main_pid","linux_deskflow_main_start_ticks","linux_deskflow_runtime_path","linux_deskflow_runtime_pid","linux_deskflow_runtime_start_ticks","linux_deskflow_unit","linux_deskflow_unit_state","linux_v13_started_receipt_sha256","linux_viewflow_unit_state","normal_deployment_release","old_coordinator_terminal_state_sha256","operation_id","protocol_2_1","protocol_version","schema_version","sealed_sibling_directory_read_only","state","windows_v13_started_receipt_sha256"]'
    jq -e --arg op "$operation_id" --arg linux "$linux_started_receipt_sha" --argjson keys "$expected_keys" '
        (keys == $keys) and .schema_version == 1 and
        .state == "viewflow-failed-v1.3-bootstrap-abort-terminal" and
        .operation_id == $op and .protocol_version == "1.3" and .protocol_2_1 == false and
        .normal_deployment_release == false and .linux_viewflow_unit_state == "active" and
        .linux_deskflow_unit_state == "active" and .linux_v13_started_receipt_sha256 == $linux and
        .sealed_sibling_directory_read_only == true and
        (.linux_deskflow_unit | test("^deskflow-v13-recovery-[0-9a-f]{32}\\.service$")) and
        (.linux_deskflow_invocation_id | test("^[0-9a-f]{32}$")) and
        (.linux_deskflow_control_group | startswith("/user.slice/user-1000.slice/user@1000.service/app.slice/")) and
        (.linux_deskflow_expected_exec_start_sha256 | test("^[0-9a-f]{64}$")) and
        .linux_deskflow_exec_start_sha256 == .linux_deskflow_expected_exec_start_sha256 and
        all([.linux_deskflow_main_pid,.linux_deskflow_main_start_ticks,.linux_deskflow_runtime_pid,
             .linux_deskflow_runtime_start_ticks,.linux_deskflow_core_pid,.linux_deskflow_core_start_ticks][];
            type == "number" and . == floor and . > 0)
    ' "$terminal_receipt" >/dev/null || die 'abort terminal receipt schema/binding is invalid'
    linux_keys='["control_group","deployment_marker_sha256","exec_start_sha256","expected_exec_start_sha256","fd_gate_payload_sha256","invocation_id","kill_mode","main_pid","operation_id","protocol_version","schema_version","start_ticks","state","transient","unit","unit_active_state","viewflowd_sha256"]'
    jq -e --arg op "$operation_id" --argjson keys "$linux_keys" '
        (keys == $keys) and .schema_version == 1 and
        .state == "viewflow-linux-v1.3-started-under-deployment-quarantine" and
        .operation_id == $op and .protocol_version == "1.3" and .unit_active_state == "active" and
        .transient == true and .kill_mode == "control-group" and
        (.unit | test("^viewflow-v13-recovery-[0-9a-f]{32}\\.service$")) and
        (.invocation_id | test("^[0-9a-f]{32}$")) and
        (.main_pid | type == "number" and . == floor and . > 0) and
        (.start_ticks | type == "number" and . == floor and . > 0) and
        .exec_start_sha256 == .expected_exec_start_sha256
    ' "$linux_started_receipt" >/dev/null || die 'Linux v1.3 transient receipt schema/binding is invalid'
    [[ $(jq -er '.deployment_marker_sha256' "$linux_started_receipt") == $(jq -er '.deployment_marker_sha256' "$terminal_receipt") ]] ||
        die 'terminal and Linux transient receipts bind different marker bytes'
    [[ $(jq -er '.viewflowd_sha256' "$linux_started_receipt") == "$installed_viewflow_sha" ]] ||
        die 'Linux transient receipt does not bind the installed Viewflow SHA'
    deskflow_unit=$(jq -er '.linux_deskflow_unit' "$terminal_receipt")
    viewflow_unit=$(jq -er '.unit' "$linux_started_receipt")
    [[ $deskflow_unit != "$viewflow_unit" ]] || die 'transient unit names collide'
}

write_expected_transition_intent() {
    local destination=$1
    jq -cn --slurpfile terminal "$terminal_receipt" --slurpfile linux "$linux_started_receipt" \
        --arg op "$operation_id" --arg terminal_path "$terminal_receipt" --arg terminal_sha "$terminal_receipt_sha" \
        --arg linux_path "$linux_started_receipt" --arg linux_sha "$linux_started_receipt_sha" \
        --arg recovery_terminal_path "$recovery_v3_terminal" --arg recovery_terminal_sha "$recovery_v3_terminal_sha" \
        --arg recovery_query_path "$recovery_v3_query" --arg recovery_query_sha "$recovery_v3_query_sha" \
        --arg abort_path "$schema5_abort_receipt" --arg abort_sha "$schema5_abort_receipt_sha" \
        --arg vfdqa_path "$durable_vfdqa" --arg vfdqa_sha "$durable_vfdqa_sha" \
        --arg retired_path "$retired_claim" --arg retired_sha "$retired_claim_sha" \
        --arg viewflow_sha "$installed_viewflow_sha" --arg unit_sha "$installed_viewflow_unit_sha" \
        --arg initial_state "$intent_initial_state" --argjson adopted "$preintent_partial_adopted" '
        ($terminal[0]) as $t | ($linux[0]) as $l |
        {schema_version:1,state:"viewflow-abort-transient-retirement-intent",operation_id:$op,
         initial_state:$initial_state,preintent_partial_adopted:($adopted == 1),
         input_bindings:{terminal_receipt_path:$terminal_path,terminal_receipt_sha256:$terminal_sha,
           linux_v13_started_receipt_path:$linux_path,linux_v13_started_receipt_sha256:$linux_sha,
           recovery_v3_terminal_path:$recovery_terminal_path,recovery_v3_terminal_sha256:$recovery_terminal_sha,
           recovery_v3_query_path:$recovery_query_path,recovery_v3_query_sha256:$recovery_query_sha,
           schema5_abort_receipt_path:$abort_path,schema5_abort_receipt_sha256:$abort_sha,
           durable_vfdqa_path:$vfdqa_path,durable_vfdqa_sha256:$vfdqa_sha,
           retired_claim_path:$retired_path,retired_claim_sha256:$retired_sha,
           installed_viewflow_sha256:$viewflow_sha,installed_viewflow_unit_sha256:$unit_sha},
         persistent_start_authorized:true,
         transient_baseline:{viewflow_unit:$l.unit,viewflow_main_pid:$l.main_pid,
           viewflow_start_ticks:$l.start_ticks,viewflow_invocation_id:$l.invocation_id,
           viewflow_control_group:$l.control_group,viewflow_exec_start_sha256:$l.exec_start_sha256,
           deskflow_unit:$t.linux_deskflow_unit,deskflow_main_pid:$t.linux_deskflow_main_pid,
           deskflow_main_start_ticks:$t.linux_deskflow_main_start_ticks,
           deskflow_runtime_pid:$t.linux_deskflow_runtime_pid,
           deskflow_runtime_start_ticks:$t.linux_deskflow_runtime_start_ticks,
           deskflow_core_pid:$t.linux_deskflow_core_pid,
           deskflow_core_start_ticks:$t.linux_deskflow_core_start_ticks,
           deskflow_invocation_id:$t.linux_deskflow_invocation_id,
           deskflow_control_group:$t.linux_deskflow_control_group,
           deskflow_exec_start_sha256:$t.linux_deskflow_exec_start_sha256}}
    ' >"$destination"
}

validate_transition_intent() {
    local candidate=$1 expected
    assert_strict_json_document 'transition intent' "$candidate"
    expected=$(mktemp --tmpdir 'viewflow-v13-handoff-intent-expected.XXXXXX')
    temporary_files+=("$expected")
    write_expected_transition_intent "$expected"
    cmp -s -- "$expected" "$candidate" || die 'transition intent bytes/bindings differ'
}

read_transition_intent_adoption() {
    local candidate=$1
    jq -e '
        keys == ["initial_state","input_bindings","operation_id","persistent_start_authorized","preintent_partial_adopted","schema_version","state","transient_baseline"] and
        .schema_version == 1 and .state == "viewflow-abort-transient-retirement-intent" and
        .persistent_start_authorized == true and
        ((.initial_state == "both-live" and .preintent_partial_adopted == false) or
         (.initial_state == "deskflow-stopped-viewflow-live" and .preintent_partial_adopted == true))
    ' "$candidate" >/dev/null || die 'transition intent adoption envelope is invalid'
    intent_initial_state=$(jq -er '.initial_state' "$candidate")
    if [[ $(jq -er '.preintent_partial_adopted' "$candidate") == true ]]; then
        preintent_partial_adopted=1
    else
        preintent_partial_adopted=0
    fi
}

assert_preintent_partial_adoption_boundary() {
    local deskflow_unit
    deskflow_unit=$(jq -er '.linux_deskflow_unit' "$terminal_receipt")
    [[ $(unit_property "$deskflow_unit" LoadState 2>/dev/null || true) == not-found &&
       $(unit_property "$deskflow_unit" MainPID 2>/dev/null || true) =~ ^(0|)$ ]] ||
        die 'pre-intent partial adoption requires the Deskflow transient unit to be absent'
    validate_live_viewflow_transient
    assert_transient_deskflow_zero
    validate_live_viewflow_transient_sidecar
    assert_persistent_services_inactive
}

ensure_transition_intent() {
    local initial_state=$1 intent_temp
    transition_intent="${handoff_receipt}.intent"
    if [[ -e $transition_intent || -L $transition_intent ]]; then
        ((adopt_preintent_partial == 0)) || die 'pre-intent adoption flag cannot be reused after intent publication'
        [[ -f $transition_intent && ! -L $transition_intent &&
           $(stat -c '%u:%a:%h' -- "$transition_intent") == 1000:600:1 ]] ||
            die 'existing transition intent is not owner-only/create-once'
        assert_strict_json_document 'transition intent' "$transition_intent"
        read_transition_intent_adoption "$transition_intent"
    else
        case $initial_state:$adopt_preintent_partial in
            both-live:0)
                intent_initial_state=both-live
                preintent_partial_adopted=0
                ;;
            deskflow-stopped-viewflow-live:1)
                assert_preintent_partial_adoption_boundary
                intent_initial_state=deskflow-stopped-viewflow-live
                preintent_partial_adopted=1
                ;;
            *) die 'fresh intent requires both-live, or the explicit exact Deskflow-stopped adoption boundary' ;;
        esac
    fi
    intent_temp=$(mktemp --tmpdir="$(dirname -- "$handoff_receipt")" '.viewflow-v13-handoff-intent.XXXXXX')
    temporary_files+=("$intent_temp")
    chmod 0600 "$intent_temp"
    write_expected_transition_intent "$intent_temp"
    validate_transition_intent "$intent_temp"
    if [[ -e $transition_intent || -L $transition_intent ]]; then
        cmp -s -- "$intent_temp" "$transition_intent" || die 'existing transition intent is corrupt or belongs to other parameters'
    else
        sync -f "$intent_temp"
        atomic_publish_noreplace "$intent_temp" "$transition_intent" ||
            die 'transition intent appeared concurrently or atomic publish failed'
        [[ $(stat -c '%u:%a:%h' -- "$transition_intent") == 1000:600:1 ]] ||
            die 'new transition intent is not owner-only/create-once'
    fi
    validate_transition_intent "$transition_intent"
    transition_intent_sha=$(sha256 "$transition_intent")
}

validate_live_viewflow_transient() {
    local viewflow_unit viewflow_pid viewflow_ticks viewflow_invocation viewflow_cgroup viewflow_exec
    viewflow_unit=$(jq -er '.unit' "$linux_started_receipt")
    viewflow_pid=$(jq -er '.main_pid' "$linux_started_receipt")
    viewflow_ticks=$(jq -er '.start_ticks' "$linux_started_receipt")
    viewflow_invocation=$(jq -er '.invocation_id' "$linux_started_receipt")
    viewflow_cgroup=$(jq -er '.control_group' "$linux_started_receipt")
    viewflow_exec=$(jq -er '.exec_start_sha256' "$linux_started_receipt")
    assert_unit_identity "$viewflow_unit" "$viewflow_pid" "$viewflow_ticks" "$viewflow_invocation" "$viewflow_cgroup"
    [[ $(sha256 "/proc/$viewflow_pid/exe") == "$installed_viewflow_sha" &&
       $(observed_exec_start_sha "$viewflow_unit") == "$viewflow_exec" ]] ||
        die 'live Viewflow transient executable/ExecStart differs from receipt'
}

inspect_live_viewflow_sidecar() {
    local viewflow_pid=$1 socket_record socket_flags socket_type socket_state socket_inode
    local fd fd_link owner_fd='' owner_count=0 ss_output ss_record ss_count ss_pid_count
    [[ -S $VIEWFLOW_SIDECAR && ! -L $VIEWFLOW_SIDECAR &&
       $(stat -c '%u:%a:%h:%F' -- "$VIEWFLOW_SIDECAR") == '1000:600:1:socket' ]] ||
        die 'live Viewflow sidecar path identity differs'
    socket_record=$(awk -v path="$VIEWFLOW_SIDECAR" '$8 == path {print $4, $5, $6, $7}' /proc/net/unix)
    [[ $(wc -l <<<"$socket_record") == 1 ]] || die 'live Viewflow sidecar has ambiguous kernel records'
    read -r socket_flags socket_type socket_state socket_inode <<<"$socket_record"
    [[ $socket_flags == 00010000 && $socket_type == 0001 && $socket_state == 01 &&
       $socket_inode =~ ^[1-9][0-9]*$ ]] || die 'live Viewflow sidecar is not an exact listening stream socket'
    for fd in /proc/$viewflow_pid/fd/[0-9]*; do
        [[ -L $fd ]] || continue
        fd_link=$(readlink -- "$fd" 2>/dev/null || true)
        if [[ $fd_link == "socket:[$socket_inode]" ]]; then
            owner_fd=${fd##*/}
            ((owner_count += 1))
        fi
    done
    [[ $owner_count == 1 && $owner_fd =~ ^[0-9]+$ ]] ||
        die 'live Viewflow process does not exclusively own the sidecar socket inode'
    ss_output=$(ss -H -xlpn)
    ss_count=$(awk -v path="$VIEWFLOW_SIDECAR" 'index($0,path) {count++} END {print count+0}' <<<"$ss_output")
    ss_record=$(awk -v path="$VIEWFLOW_SIDECAR" 'index($0,path) {print}' <<<"$ss_output")
    ss_pid_count=$(grep -oE 'pid=[1-9][0-9]*,' <<<"$ss_record" | awk 'END {print NR+0}')
    [[ $ss_count == 1 && $ss_pid_count == 1 && $ss_record == *'LISTEN'* &&
       $ss_record == *"pid=$viewflow_pid,"* && $ss_record == *"fd=$owner_fd)"* ]] ||
        die 'live Viewflow sidecar listener ownership differs'
    observed_sidecar_path=$VIEWFLOW_SIDECAR
    observed_sidecar_inode=$socket_inode
    observed_sidecar_owner_pid=$viewflow_pid
    observed_sidecar_owner_fd=$owner_fd
    observed_sidecar_listener_count=$ss_count
}

validate_live_viewflow_transient_sidecar() {
    local viewflow_pid
    viewflow_pid=$(jq -er '.main_pid' "$linux_started_receipt")
    inspect_live_viewflow_sidecar "$viewflow_pid"
}

validate_live_persistent_viewflow_sidecar() {
    local viewflow_pid
    viewflow_pid=$(unit_property "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true)
    [[ $viewflow_pid =~ ^[1-9][0-9]*$ ]] || die 'persistent Viewflow sidecar has no exact MainPID owner'
    inspect_live_viewflow_sidecar "$viewflow_pid"
}

capture_persistent_sidecar_identity() {
    local viewflow_pid=$1
    inspect_live_viewflow_sidecar "$viewflow_pid"
    persistent_sidecar_path=$observed_sidecar_path
    persistent_sidecar_inode=$observed_sidecar_inode
    persistent_sidecar_owner_pid=$observed_sidecar_owner_pid
    persistent_sidecar_owner_fd=$observed_sidecar_owner_fd
    persistent_sidecar_listener_count=$observed_sidecar_listener_count
}

validate_persistent_sidecar_against_receipt() {
    local receipt=$1 viewflow_pid expected_path expected_inode expected_owner_pid expected_owner_fd expected_count
    viewflow_pid=$(jq -er '.persistent_viewflow.main_pid' "$receipt")
    expected_path=$(jq -er '.persistent_viewflow.sidecar_socket_path' "$receipt")
    expected_inode=$(jq -er '.persistent_viewflow.sidecar_socket_inode' "$receipt")
    expected_owner_pid=$(jq -er '.persistent_viewflow.sidecar_owner_pid' "$receipt")
    expected_owner_fd=$(jq -er '.persistent_viewflow.sidecar_owner_fd' "$receipt")
    expected_count=$(jq -er '.persistent_viewflow.sidecar_listener_count' "$receipt")
    inspect_live_viewflow_sidecar "$viewflow_pid"
    [[ $observed_sidecar_path == "$expected_path" && $observed_sidecar_inode == "$expected_inode" &&
       $observed_sidecar_owner_pid == "$expected_owner_pid" && $observed_sidecar_owner_fd == "$expected_owner_fd" &&
       $observed_sidecar_listener_count == "$expected_count" ]] ||
        die 'persistent Viewflow sidecar identity differs from receipt'
}

validate_live_deskflow_transient() {
    local deskflow_unit main_pid main_ticks runtime_pid runtime_ticks core_pid core_ticks deskflow_cgroup
    local runtime_path core_path
    deskflow_unit=$(jq -er '.linux_deskflow_unit' "$terminal_receipt")
    main_pid=$(jq -er '.linux_deskflow_main_pid' "$terminal_receipt")
    main_ticks=$(jq -er '.linux_deskflow_main_start_ticks' "$terminal_receipt")
    runtime_pid=$(jq -er '.linux_deskflow_runtime_pid' "$terminal_receipt")
    runtime_ticks=$(jq -er '.linux_deskflow_runtime_start_ticks' "$terminal_receipt")
    core_pid=$(jq -er '.linux_deskflow_core_pid' "$terminal_receipt")
    core_ticks=$(jq -er '.linux_deskflow_core_start_ticks' "$terminal_receipt")
    deskflow_cgroup=$(jq -er '.linux_deskflow_control_group' "$terminal_receipt")
    runtime_path=$(jq -er '.linux_deskflow_runtime_path' "$terminal_receipt")
    core_path=$(jq -er '.linux_deskflow_core_runtime_path' "$terminal_receipt")
    assert_unit_identity "$deskflow_unit" "$main_pid" "$main_ticks" \
        "$(jq -er '.linux_deskflow_invocation_id' "$terminal_receipt")" "$deskflow_cgroup"
    [[ $(sha256 "/proc/$main_pid/exe") == "$(jq -er '.bubblewrap_sha256' "$terminal_receipt")" &&
       $(process_start_ticks "$runtime_pid") == "$runtime_ticks" &&
       $(process_start_ticks "$core_pid") == "$core_ticks" &&
       $(process_control_group "$runtime_pid") == "$deskflow_cgroup" &&
       $(process_control_group "$core_pid") == "$deskflow_cgroup" &&
       $(sha256 "/proc/$runtime_pid/exe") == "$(jq -er '.linux_deskflow_executable_sha256' "$terminal_receipt")" &&
       $(sha256 "/proc/$core_pid/exe") == "$(jq -er '.linux_deskflow_core_executable_sha256' "$terminal_receipt")" &&
       $(readlink -- "/proc/$runtime_pid/exe" 2>/dev/null || true) == "$runtime_path (deleted)" &&
       $(readlink -- "/proc/$core_pid/exe" 2>/dev/null || true) == "$core_path (deleted)" &&
       $(observed_exec_start_sha "$deskflow_unit") == "$(jq -er '.linux_deskflow_exec_start_sha256' "$terminal_receipt")" ]] ||
        die 'live Bubblewrap/Deskflow/core transient identity differs from terminal receipt'
    process_descends_from "$runtime_pid" "$main_pid" || die 'Deskflow runtime is not descended from transient MainPID'
    process_descends_from "$core_pid" "$runtime_pid" || die 'deskflow-core is not descended from Deskflow runtime'
}

assert_persistent_services_inactive() {
    [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == inactive &&
       $(unit_property "$VIEWFLOW_UNIT" MainPID) == 0 &&
       $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) == inactive &&
       $(unit_property "$DESKFLOW_UNIT" MainPID) == 0 ]] ||
        die 'persistent services must be inactive before transient retirement'
}

validate_live_transient_baseline() {
    validate_live_viewflow_transient
    validate_live_deskflow_transient
    assert_persistent_services_inactive
}

deskflow_runtime_pids() {
    local proc exe_link exe_sha argv0 process_name deskflow_sha='' core_sha=''
    if [[ -f $terminal_receipt && ! -L $terminal_receipt ]]; then
        deskflow_sha=$(jq -er '.linux_deskflow_executable_sha256' "$terminal_receipt" 2>/dev/null || true)
        core_sha=$(jq -er '.linux_deskflow_core_executable_sha256' "$terminal_receipt" 2>/dev/null || true)
    fi
    for proc in /proc/[0-9]*; do
        [[ -L $proc/exe ]] || continue
        exe_link=$(readlink -- "$proc/exe" 2>/dev/null || true)
        argv0=''; IFS= read -r -d '' argv0 <"$proc/cmdline" 2>/dev/null || true
        process_name=''; IFS= read -r process_name <"$proc/comm" 2>/dev/null || true
        case $exe_link in
            "$DESKFLOW_INSTALLED"|"$DESKFLOW_INSTALLED (deleted)"|"$DESKFLOW_CORE_INSTALLED"|\
            "$DESKFLOW_CORE_INSTALLED (deleted)"|"/tmp/viewflow-deskflow-recovery/deskflow"|\
            "/tmp/viewflow-deskflow-recovery/deskflow (deleted)"|\
            "/tmp/viewflow-deskflow-recovery/deskflow-core"|\
            "/tmp/viewflow-deskflow-recovery/deskflow-core (deleted)")
                printf '%s\n' "${proc##*/}"; continue ;;
        esac
        case $argv0 in
            "$DESKFLOW_INSTALLED"|"$DESKFLOW_CORE_INSTALLED"|"/tmp/viewflow-deskflow-recovery/deskflow"|\
            "/tmp/viewflow-deskflow-recovery/deskflow-core")
                printf '%s\n' "${proc##*/}"; continue ;;
        esac
        if [[ $process_name == deskflow || $process_name == deskflow-core ]] &&
           [[ $deskflow_sha =~ ^[0-9a-f]{64}$ || $core_sha =~ ^[0-9a-f]{64}$ ]]; then
            exe_sha=$(sha256 "$proc/exe" 2>/dev/null || true)
            [[ $exe_sha == "$deskflow_sha" || $exe_sha == "$core_sha" ]] && printf '%s\n' "${proc##*/}"
        fi
    done
    return 0
}

assert_no_deskflow_process_runtime() {
    local deskflow_pids core_pids runtime_pids tcp_count
    deskflow_pids=$(exact_executable_pids "$DESKFLOW_INSTALLED")
    core_pids=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    runtime_pids=$(deskflow_runtime_pids)
    tcp_count=$(ss -H -ltn "sport = :$DESKFLOW_PORT" | awk 'END {print NR + 0}')
    [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) == inactive &&
       $(unit_property "$DESKFLOW_UNIT" MainPID) == 0 && -z $deskflow_pids && -z $core_pids &&
       -z $runtime_pids && $tcp_count == 0 ]] ||
        die 'Deskflow persistent/runtime boundary is not fully inactive'
}

assert_no_deskflow_runtime() {
    assert_no_deskflow_process_runtime
    [[ ! -e $VIEWFLOW_SIDECAR && ! -L $VIEWFLOW_SIDECAR ]] ||
        die 'Deskflow/Viewflow sidecar must be absent at the both-zero boundary'
}

assert_transient_deskflow_zero() {
    local deskflow_unit main_pid runtime_pid core_pid active
    deskflow_unit=$(jq -er '.linux_deskflow_unit' "$terminal_receipt")
    main_pid=$(jq -er '.linux_deskflow_main_pid' "$terminal_receipt")
    runtime_pid=$(jq -er '.linux_deskflow_runtime_pid' "$terminal_receipt")
    core_pid=$(jq -er '.linux_deskflow_core_pid' "$terminal_receipt")
    active=$(systemctl --user is-active "$deskflow_unit" 2>/dev/null || true)
    [[ ! -e /proc/$main_pid && ! -e /proc/$runtime_pid && ! -e /proc/$core_pid &&
       $active != active && $(unit_property "$deskflow_unit" MainPID 2>/dev/null || true) =~ ^(0|)$ ]] ||
        die 'Deskflow transient is neither exact-live nor fully stopped'
    assert_no_deskflow_process_runtime
}

assert_transient_viewflow_zero() {
    local viewflow_pids udp_count
    assert_viewflow_transient_unit_zero
    viewflow_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
    udp_count=$(ss -H -lun "sport = :$VIEWFLOW_PORT" | awk 'END {print NR + 0}')
    [[ -z $viewflow_pids && $udp_count == 0 && ! -e $VIEWFLOW_SIDECAR && ! -L $VIEWFLOW_SIDECAR ]] ||
        die 'Viewflow transient is neither exact-live nor fully stopped'
}

assert_viewflow_transient_unit_zero() {
    local viewflow_unit viewflow_pid active
    viewflow_unit=$(jq -er '.unit' "$linux_started_receipt")
    viewflow_pid=$(jq -er '.main_pid' "$linux_started_receipt")
    active=$(systemctl --user is-active "$viewflow_unit" 2>/dev/null || true)
    [[ ! -e /proc/$viewflow_pid && $active != active &&
       $(unit_property "$viewflow_unit" MainPID 2>/dev/null || true) =~ ^(0|)$ ]] ||
        die 'Viewflow transient unit is not fully retired'
}

classify_transition_state() {
    local viewflow_pid main_pid runtime_pid core_pid
    viewflow_pid=$(jq -er '.main_pid' "$linux_started_receipt")
    main_pid=$(jq -er '.linux_deskflow_main_pid' "$terminal_receipt")
    runtime_pid=$(jq -er '.linux_deskflow_runtime_pid' "$terminal_receipt")
    core_pid=$(jq -er '.linux_deskflow_core_pid' "$terminal_receipt")
    transition_state=''
    if [[ -e /proc/$viewflow_pid && -e /proc/$main_pid && -e /proc/$runtime_pid && -e /proc/$core_pid ]]; then
        validate_live_transient_baseline
        transition_state=both-live
    elif [[ -e /proc/$viewflow_pid && ! -e /proc/$main_pid && ! -e /proc/$runtime_pid && ! -e /proc/$core_pid ]]; then
        validate_live_viewflow_transient
        assert_transient_deskflow_zero
        validate_live_viewflow_transient_sidecar
        assert_persistent_services_inactive
        transition_state=deskflow-stopped-viewflow-live
    elif [[ ! -e /proc/$viewflow_pid && ! -e /proc/$main_pid && ! -e /proc/$runtime_pid && ! -e /proc/$core_pid ]]; then
        assert_viewflow_transient_unit_zero
        assert_transient_deskflow_zero
        if [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active ]]; then
            assert_no_deskflow_process_runtime
            validate_live_persistent_viewflow_sidecar
            transition_state=persistent-live
        else
            assert_transient_viewflow_zero
            assert_no_deskflow_runtime
            assert_persistent_services_inactive
            transition_state=both-zero
        fi
    else
        die 'transient retirement is in an unsupported partial state'
    fi
}

wait_transients_retired() {
    local viewflow_unit=$1 deskflow_unit=$2 viewflow_pid=$3 main_pid=$4 runtime_pid=$5 core_pid=$6
    local deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
    while ((SECONDS < deadline)); do
        if [[ ! -e /proc/$viewflow_pid && ! -e /proc/$main_pid && ! -e /proc/$runtime_pid && ! -e /proc/$core_pid &&
              -z $(exact_executable_pids "$VIEWFLOW_INSTALLED") &&
              $(ss -H -lun "sport = :$VIEWFLOW_PORT" | awk 'END {print NR + 0}') == 0 &&
              $(ss -H -ltn "sport = :$DESKFLOW_PORT" | awk 'END {print NR + 0}') == 0 &&
              ! -e $VIEWFLOW_SIDECAR ]]; then
            assert_no_deskflow_runtime
            systemctl --user reset-failed "$deskflow_unit" >/dev/null 2>&1 || true
            systemctl --user reset-failed "$viewflow_unit" >/dev/null 2>&1 || true
            local unload_deadline=$((SECONDS + 10))
            while ((SECONDS < unload_deadline)); do
                if [[ $(unit_property "$deskflow_unit" LoadState 2>/dev/null || true) == not-found &&
                      $(unit_property "$viewflow_unit" LoadState 2>/dev/null || true) == not-found ]]; then
                    return 0
                fi
                sleep 0.1
            done
            die 'retired transient units did not unload'
        fi
        sleep 0.1
    done
    die 'transient retirement did not reach zero process/port/socket state'
}

retire_transients() {
    local viewflow_unit deskflow_unit viewflow_pid main_pid runtime_pid core_pid
    viewflow_unit=$(jq -er '.unit' "$linux_started_receipt")
    deskflow_unit=$(jq -er '.linux_deskflow_unit' "$terminal_receipt")
    viewflow_pid=$(jq -er '.main_pid' "$linux_started_receipt")
    main_pid=$(jq -er '.linux_deskflow_main_pid' "$terminal_receipt")
    runtime_pid=$(jq -er '.linux_deskflow_runtime_pid' "$terminal_receipt")
    core_pid=$(jq -er '.linux_deskflow_core_pid' "$terminal_receipt")
    [[ $(sha256 "$terminal_receipt") == "$terminal_receipt_sha" &&
       $(sha256 "$linux_started_receipt") == "$linux_started_receipt_sha" &&
       $(sha256 "$transition_intent") == "$transition_intent_sha" ]] ||
        die 'terminal receipt bytes changed immediately before transient stop'
    classify_transition_state
    case $transition_state in
        both-live)
            systemctl --user stop "$deskflow_unit"
            classify_transition_state
            [[ $transition_state == deskflow-stopped-viewflow-live ]] ||
                die 'Deskflow stop did not reach the only supported resume boundary'
            systemctl --user stop "$viewflow_unit"
            ;;
        deskflow-stopped-viewflow-live)
            systemctl --user stop "$viewflow_unit"
            ;;
        both-zero)
            assert_transient_viewflow_zero
            assert_transient_deskflow_zero
            assert_no_deskflow_runtime
            return 0
            ;;
        persistent-live)
            assert_viewflow_transient_unit_zero
            assert_transient_deskflow_zero
            assert_no_deskflow_process_runtime
            validate_live_persistent_viewflow_sidecar
            return 0
            ;;
        *) die 'unsupported transition state before retirement' ;;
    esac
    wait_transients_retired "$viewflow_unit" "$deskflow_unit" "$viewflow_pid" "$main_pid" "$runtime_pid" "$core_pid"
    assert_no_deskflow_runtime
    classify_transition_state
    [[ $transition_state == both-zero ]] || die 'transient retirement did not end at both-zero'
}

capture_persistent_journal() {
    local destination=$1 probe_line probe_count
    journalctl --user --quiet --no-pager --output=json \
        "_SYSTEMD_INVOCATION_ID=$persistent_invocation" >"$destination"
    [[ -s $destination ]] || die 'persistent Viewflow invocation journal is empty'
    jq -s -e --arg invocation "$persistent_invocation" '
        length > 0 and all(.[]; ._SYSTEMD_INVOCATION_ID == $invocation)
    ' "$destination" >/dev/null || die 'persistent journal slice includes another InvocationID'
    [[ $(jq -sr --arg line "$PROTOCOL_13_STARTUP" '[.[]|select(.MESSAGE == $line)]|length' "$destination") == 1 ]] ||
        die 'persistent journal must contain the exact protocol-1.3 startup line once'
    probe_count=$(jq -sr '[.[]|(.MESSAGE // "")|select(test("^viewflowd server peer 172\\.16\\.105\\.70:[1-9][0-9]{0,4} probe=[0-9]+ responder_us=[0-9]+$"))]|length' "$destination")
    ((probe_count >= 1)) || die 'persistent journal lacks a fresh authenticated Windows probe'
    probe_line=$(jq -sr '[.[]|(.MESSAGE // "")|select(test("^viewflowd server peer 172\\.16\\.105\\.70:[1-9][0-9]{0,4} probe=[0-9]+ responder_us=[0-9]+$"))][-1]' "$destination")
    persistent_probe_port=${probe_line#*172.16.105.70:}; persistent_probe_port=${persistent_probe_port%% *}
    [[ $persistent_probe_port =~ ^[1-9][0-9]*$ && $persistent_probe_port -le 65535 ]] ||
        die 'persistent authenticated peer port is invalid'
    persistent_probe_sha=$(printf '%s' "$probe_line" | sha256sum | awk '{print $1}')
    persistent_journal_sha=$(sha256 "$destination")
    persistent_journal_entries=$(jq -s 'length' "$destination")
    persistent_journal_start_cursor=$(jq -sr '.[0].__CURSOR' "$destination")
    persistent_journal_start_us=$(jq -sr '.[0].__REALTIME_TIMESTAMP' "$destination")
    persistent_journal_end_cursor=$(jq -sr '.[-1].__CURSOR' "$destination")
    persistent_journal_end_us=$(jq -sr '.[-1].__REALTIME_TIMESTAMP' "$destination")
    [[ -n $persistent_journal_start_cursor && $persistent_journal_start_us =~ ^[0-9]+$ &&
       -n $persistent_journal_end_cursor && $persistent_journal_end_us =~ ^[0-9]+$ ]] ||
        die 'persistent journal cursor/time boundary is invalid'
}

validate_installed_persistent_files() {
    [[ -f $VIEWFLOW_INSTALLED && ! -L $VIEWFLOW_INSTALLED &&
       $(stat -c '%u:%a:%h' -- "$VIEWFLOW_INSTALLED") == 1000:755:1 &&
       $(sha256 "$VIEWFLOW_INSTALLED") == "$installed_viewflow_sha" ]] ||
        die 'installed protocol-1.3 Viewflow executable identity differs'
    [[ -f $VIEWFLOW_UNIT_FILE && ! -L $VIEWFLOW_UNIT_FILE &&
       $(stat -c '%u:%h' -- "$VIEWFLOW_UNIT_FILE") == 1000:1 &&
       $(sha256 "$VIEWFLOW_UNIT_FILE") == "$installed_viewflow_unit_sha" &&
       $(grep -Fxc -- "$EXPECTED_VIEWFLOW_UNIT_EXECSTART" "$VIEWFLOW_UNIT_FILE") == 1 &&
       $(grep -Fc 'ExecStart' "$VIEWFLOW_UNIT_FILE") == 1 ]] ||
        die 'installed protocol-1.3 Viewflow unit identity/ExecStart differs'
}

establish_persistent_service_activation() {
    local persistent_state
    persistent_state=$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true)
    if [[ $persistent_state == active ]]; then
        # A SIGKILL after systemd start but before receipt publication leaves
        # the authorized service alive.  The durable transition intent permits
        # adopting only this exact unit/ELF/argv/peer tuple on resume.
        persistent_started=1
        return 0
    fi
    [[ $persistent_state == inactive && $(unit_property "$VIEWFLOW_UNIT" MainPID) == 0 ]] ||
        die 'persistent Viewflow is neither inactive nor an adoptable active instance'
    systemctl --user daemon-reload
    [[ $(sha256 "$VIEWFLOW_INSTALLED") == "$installed_viewflow_sha" &&
       $(sha256 "$VIEWFLOW_UNIT_FILE") == "$installed_viewflow_unit_sha" ]] ||
        die 'installed Viewflow files changed across daemon-reload'
    assert_bound_inputs_unchanged
    systemctl --user start "$VIEWFLOW_UNIT"
    persistent_started=1
}

validate_persistent_activation_boundary() {
    local persistent_state
    persistent_state=$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true)
    assert_no_deskflow_process_runtime
    case $persistent_state in
        active)
            validate_live_persistent_viewflow_sidecar
            ;;
        inactive)
            [[ $(unit_property "$VIEWFLOW_UNIT" MainPID) == 0 ]] ||
                die 'inactive persistent Viewflow retains a MainPID'
            assert_no_deskflow_runtime
            ;;
        *) die 'persistent Viewflow activation boundary is neither inactive nor exact-live' ;;
    esac
}

start_and_validate_persistent_viewflow() {
    local deadline pid=0 invocation cgroup ticks observed expected cmdline_sha udp_output startup_count startup_sha
    local journal_file probe_deadline probe_line
    validate_installed_persistent_files
    assert_bound_inputs_unchanged
    validate_persistent_activation_boundary
    establish_persistent_service_activation
    deadline=$((SECONDS + START_TIMEOUT_SECONDS))
    while ((SECONDS < deadline)); do
        pid=$(unit_property "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true)
        if [[ $pid =~ ^[1-9][0-9]*$ && -e /proc/$pid/exe &&
              $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" ]]; then
            break
        fi
        pid=0
        sleep 0.1
    done
    [[ $pid =~ ^[1-9][0-9]*$ ]] || die 'persistent protocol-1.3 Viewflow did not start'
    invocation=$(unit_property "$VIEWFLOW_UNIT" InvocationID)
    cgroup=$(unit_property "$VIEWFLOW_UNIT" ControlGroup)
    ticks=$(process_start_ticks "$pid")
    capture_persistent_cleanup_identity "$pid" "$ticks" "$invocation" "$cgroup"
    expected=$(expected_persistent_exec_start_sha)
    observed=$(observed_exec_start_sha "$VIEWFLOW_UNIT")
    cmdline_sha=$(sha256 "/proc/$pid/cmdline")
    udp_output=$(ss -H -lunp "sport = :$VIEWFLOW_PORT")
    probe_deadline=$((SECONDS + START_TIMEOUT_SECONDS)); probe_line=''
    while ((SECONDS < probe_deadline)); do
        probe_line=$(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
            grep -E '^viewflowd server peer 172\.16\.105\.70:[1-9][0-9]{0,4} probe=[0-9]+ responder_us=[0-9]+$' |
            tail -n1 || true)
        [[ -n $probe_line ]] && break
        sleep 0.2
    done
    [[ -n $probe_line ]] || die 'new persistent invocation did not authenticate/probe the Windows peer'
    startup_count=$(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" | grep -Fxc -- "$PROTOCOL_13_STARTUP" || true)
    startup_sha=$(printf '%s' "$PROTOCOL_13_STARTUP" | sha256sum | awk '{print $1}')
    [[ $(unit_property "$VIEWFLOW_UNIT" LoadState) == loaded &&
       $(unit_property "$VIEWFLOW_UNIT" ActiveState) == active &&
       $(unit_property "$VIEWFLOW_UNIT" SubState) == running &&
       $(unit_property "$VIEWFLOW_UNIT" MainPID) == "$pid" &&
       $invocation =~ ^[0-9a-f]{32}$ &&
       $cgroup == */"$VIEWFLOW_UNIT" && $(process_control_group "$pid") == "$cgroup" &&
       $ticks =~ ^[1-9][0-9]*$ && $observed == "$expected" &&
       $cmdline_sha == "$(expected_persistent_cmdline_sha)" &&
       $(exact_executable_pids "$VIEWFLOW_INSTALLED") == "$pid" &&
       $(printf '%s\n' "$udp_output" | awk 'NF {count++} END {print count + 0}') == 1 &&
       $udp_output == *"pid=$pid,"* && $startup_count == 1 ]] ||
        die 'persistent protocol-1.3 Viewflow live identity/readiness differs'
    assert_no_deskflow_process_runtime
    capture_persistent_sidecar_identity "$pid"
    assert_bound_inputs_unchanged
    persistent_pid=$pid; persistent_ticks=$ticks; persistent_invocation=$invocation
    persistent_cgroup=$cgroup; persistent_expected_exec=$expected; persistent_observed_exec=$observed
    persistent_cmdline_sha=$cmdline_sha; persistent_startup_sha=$startup_sha
    journal_file=$(mktemp --tmpdir 'viewflow-v13-handoff-journal.XXXXXX')
    temporary_files+=("$journal_file")
    capture_persistent_journal "$journal_file"
    [[ $(unit_property "$VIEWFLOW_UNIT" MainPID) == "$persistent_pid" &&
       $(unit_property "$VIEWFLOW_UNIT" InvocationID) == "$persistent_invocation" &&
       $(process_start_ticks "$persistent_pid") == "$persistent_ticks" &&
       $(sha256 "/proc/$persistent_pid/exe") == "$installed_viewflow_sha" ]] ||
        die 'persistent Viewflow identity changed while freezing its journal'
}

validate_handoff_receipt() {
    local path=$1
    assert_strict_json_document 'handoff receipt' "$path"
    jq -e --arg op "$operation_id" --arg terminal "$terminal_receipt" --arg terminal_sha "$terminal_receipt_sha" \
        --arg linux "$linux_started_receipt" --arg linux_sha "$linux_started_receipt_sha" \
        --arg recovery_terminal "$recovery_v3_terminal" --arg recovery_terminal_sha "$recovery_v3_terminal_sha" \
        --arg recovery_query "$recovery_v3_query" --arg recovery_query_sha "$recovery_v3_query_sha" \
        --arg abort_receipt "$schema5_abort_receipt" --arg abort_receipt_sha "$schema5_abort_receipt_sha" \
        --arg vfdqa "$durable_vfdqa" --arg vfdqa_sha "$durable_vfdqa_sha" \
        --arg retired "$retired_claim" --arg retired_sha "$retired_claim_sha" \
        --arg viewflow "$VIEWFLOW_INSTALLED" --arg viewflow_sha "$installed_viewflow_sha" \
        --arg unit_file "$VIEWFLOW_UNIT_FILE" --arg unit_sha "$installed_viewflow_unit_sha" \
        --arg intent "$transition_intent" --arg intent_sha "$transition_intent_sha" \
        --arg initial_state "$intent_initial_state" --argjson adopted "$preintent_partial_adopted" \
        --arg unit "$VIEWFLOW_UNIT" --arg deskflow "$DESKFLOW_UNIT" --arg sidecar "$VIEWFLOW_SIDECAR" '
        keys == ["completed_at_utc","deskflow","initial_state","linux_v13_started_receipt_path","linux_v13_started_receipt_sha256","operation_id","persistent_viewflow","post_transient_stop","preintent_partial_adopted","quarantine_absence","recovery_v3_lineage","schema_version","state","terminal_receipt_path","terminal_receipt_sha256","transition_intent_path","transition_intent_sha256"] and
        .schema_version == 1 and .state == "viewflow-abort-transients-handed-off-to-persistent-v13" and
        .initial_state == $initial_state and .preintent_partial_adopted == ($adopted == 1) and
        .operation_id == $op and .terminal_receipt_path == $terminal and .terminal_receipt_sha256 == $terminal_sha and
        .linux_v13_started_receipt_path == $linux and .linux_v13_started_receipt_sha256 == $linux_sha and
        .transition_intent_path == $intent and .transition_intent_sha256 == $intent_sha and
        .recovery_v3_lineage == {terminal_path:$recovery_terminal,terminal_sha256:$recovery_terminal_sha,
          query_path:$recovery_query,query_sha256:$recovery_query_sha,
          schema5_abort_receipt_path:$abort_receipt,schema5_abort_receipt_sha256:$abort_receipt_sha,
          durable_vfdqa_path:$vfdqa,durable_vfdqa_sha256:$vfdqa_sha,
          retired_claim_path:$retired,retired_claim_sha256:$retired_sha} and
        .quarantine_absence == {deployment_marker_present:false,abort_claim_present:false,
          release_claim_present:false,runtime_marker_present:false} and
        .post_transient_stop == {viewflow_exact_process_count:0,deskflow_exact_process_count:0,
          deskflow_core_exact_process_count:0,udp_44119_listener_count:0,tcp_24800_listener_count:0,
          sidecar_socket_present:false} and
        (.persistent_viewflow | keys) == ["authenticated_peer_ip","authenticated_peer_port","authenticated_probe_record_sha256","cmdline_sha256","control_group","executable_path","executable_sha256","expected_exec_start_sha256","invocation_id","journal_end_cursor","journal_end_realtime_timestamp_us","journal_entry_count","journal_invocation_id","journal_slice_sha256","journal_start_cursor","journal_start_realtime_timestamp_us","main_pid","observed_exec_start_sha256","protocol_startup_record_sha256","sidecar_listener_count","sidecar_owner_fd","sidecar_owner_pid","sidecar_socket_inode","sidecar_socket_path","start_ticks","udp_44119_listener_count","unit","unit_active_state","unit_file_path","unit_file_sha256"] and
        .persistent_viewflow.unit == $unit and .persistent_viewflow.unit_active_state == "active" and
        .persistent_viewflow.executable_path == $viewflow and .persistent_viewflow.executable_sha256 == $viewflow_sha and
        .persistent_viewflow.unit_file_path == $unit_file and .persistent_viewflow.unit_file_sha256 == $unit_sha and
        .persistent_viewflow.expected_exec_start_sha256 == .persistent_viewflow.observed_exec_start_sha256 and
        (.persistent_viewflow.main_pid | type == "number" and . == floor and . > 0) and
        (.persistent_viewflow.start_ticks | type == "number" and . == floor and . > 0) and
        (.persistent_viewflow.invocation_id | test("^[0-9a-f]{32}$")) and
        .persistent_viewflow.sidecar_socket_path == $sidecar and
        (.persistent_viewflow.sidecar_socket_inode | type == "number" and . == floor and . > 0) and
        .persistent_viewflow.sidecar_owner_pid == .persistent_viewflow.main_pid and
        (.persistent_viewflow.sidecar_owner_fd | type == "number" and . == floor and . >= 0) and
        .persistent_viewflow.sidecar_listener_count == 1 and
        .persistent_viewflow.journal_invocation_id == .persistent_viewflow.invocation_id and
        .persistent_viewflow.authenticated_peer_ip == "172.16.105.70" and
        (.persistent_viewflow.authenticated_peer_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
        (.persistent_viewflow.journal_entry_count | type == "number" and . == floor and . >= 2) and
        (.persistent_viewflow.journal_start_realtime_timestamp_us | type == "number" and . == floor and . > 0) and
        (.persistent_viewflow.journal_end_realtime_timestamp_us as $journal_end_us |
         .persistent_viewflow.journal_start_realtime_timestamp_us as $journal_start_us |
         ($journal_end_us | type == "number" and . == floor and . > 0) and
         ($journal_start_us | type == "number" and . == floor and . > 0) and
         $journal_end_us >= $journal_start_us) and
        (.persistent_viewflow.journal_slice_sha256 | test("^[0-9a-f]{64}$")) and
        (.persistent_viewflow.authenticated_probe_record_sha256 | test("^[0-9a-f]{64}$")) and
        .persistent_viewflow.udp_44119_listener_count == 1 and
        .deskflow == {unit:$deskflow,unit_active_state:"inactive",main_pid:0,
          exact_process_count:0,core_exact_process_count:0,tcp_24800_listener_count:0,started_by_handoff:false} and
        (.completed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000Z$"))
    ' "$path" >/dev/null || die 'handoff receipt schema/binding is invalid'
}

final_reattest_against_receipt() {
    local receipt=$1 pid ticks invocation cgroup expected observed cmdline udp_output current_journal
    local startup_count probe_match=0 probe_sha message
    pid=$(jq -er '.persistent_viewflow.main_pid' "$receipt")
    ticks=$(jq -er '.persistent_viewflow.start_ticks' "$receipt")
    invocation=$(jq -er '.persistent_viewflow.invocation_id' "$receipt")
    cgroup=$(jq -er '.persistent_viewflow.control_group' "$receipt")
    expected=$(jq -er '.persistent_viewflow.expected_exec_start_sha256' "$receipt")
    observed=$(observed_exec_start_sha "$VIEWFLOW_UNIT")
    cmdline=$(sha256 "/proc/$pid/cmdline")
    udp_output=$(ss -H -lunp "sport = :$VIEWFLOW_PORT")
    assert_bound_inputs_unchanged
    [[ $(sha256 "$transition_intent") == "$transition_intent_sha" &&
       $(sha256 "$VIEWFLOW_INSTALLED") == "$installed_viewflow_sha" &&
       $(sha256 "$VIEWFLOW_UNIT_FILE") == "$installed_viewflow_unit_sha" &&
       $(unit_property "$VIEWFLOW_UNIT" LoadState) == loaded &&
       $(unit_property "$VIEWFLOW_UNIT" ActiveState) == active &&
       $(unit_property "$VIEWFLOW_UNIT" SubState) == running &&
       $(unit_property "$VIEWFLOW_UNIT" MainPID) == "$pid" &&
       $(unit_property "$VIEWFLOW_UNIT" InvocationID) == "$invocation" &&
       $(unit_property "$VIEWFLOW_UNIT" ControlGroup) == "$cgroup" &&
       $(process_start_ticks "$pid") == "$ticks" && $(process_control_group "$pid") == "$cgroup" &&
       $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" &&
       $observed == "$expected" && $observed == "$(jq -er '.persistent_viewflow.observed_exec_start_sha256' "$receipt")" &&
       $cmdline == "$(jq -er '.persistent_viewflow.cmdline_sha256' "$receipt")" &&
       $(exact_executable_pids "$VIEWFLOW_INSTALLED") == "$pid" &&
       $(printf '%s\n' "$udp_output" | awk 'NF {count++} END {print count + 0}') == 1 &&
       $udp_output == *"pid=$pid,"* ]] || die 'final persistent identity reattestation differs from receipt'
    assert_no_deskflow_process_runtime
    validate_persistent_sidecar_against_receipt "$receipt"
    current_journal=$(mktemp --tmpdir 'viewflow-v13-handoff-final-journal.XXXXXX')
    temporary_files+=("$current_journal")
    journalctl --user --quiet --no-pager --output=json "_SYSTEMD_INVOCATION_ID=$invocation" >"$current_journal"
    jq -s -e --arg invocation "$invocation" 'length > 0 and all(.[]; ._SYSTEMD_INVOCATION_ID == $invocation)' \
        "$current_journal" >/dev/null || die 'final journal reattestation crossed InvocationID'
    startup_count=$(jq -sr --arg line "$PROTOCOL_13_STARTUP" '[.[]|select(.MESSAGE == $line)]|length' "$current_journal")
    [[ $startup_count == 1 ]] || die 'final journal reattestation lost the exact startup record'
    probe_sha=$(jq -er '.persistent_viewflow.authenticated_probe_record_sha256' "$receipt")
    while IFS= read -r message; do
        [[ $(printf '%s' "$message" | sha256sum | awk '{print $1}') == "$probe_sha" ]] && probe_match=1
    done < <(jq -r '.MESSAGE // empty | select(test("^viewflowd server peer 172\\.16\\.105\\.70:[1-9][0-9]{0,4} probe=[0-9]+ responder_us=[0-9]+$"))' "$current_journal")
    ((probe_match == 1)) || die 'final journal reattestation lost the receipt-bound authenticated probe'
}

publish_handoff_receipt() {
    local completed journal_file
    completed=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
    journal_file=$(mktemp --tmpdir 'viewflow-v13-handoff-publish-journal.XXXXXX')
    temporary_files+=("$journal_file")
    capture_persistent_journal "$journal_file"
    receipt_temp=$(mktemp --tmpdir="$(dirname -- "$handoff_receipt")" '.viewflow-v13-handoff.XXXXXX')
    chmod 0600 "$receipt_temp"
    jq -cn --arg op "$operation_id" --arg terminal "$terminal_receipt" --arg terminal_sha "$terminal_receipt_sha" \
        --arg linux "$linux_started_receipt" --arg linux_sha "$linux_started_receipt_sha" \
        --arg recovery_terminal "$recovery_v3_terminal" --arg recovery_terminal_sha "$recovery_v3_terminal_sha" \
        --arg recovery_query "$recovery_v3_query" --arg recovery_query_sha "$recovery_v3_query_sha" \
        --arg abort_receipt "$schema5_abort_receipt" --arg abort_receipt_sha "$schema5_abort_receipt_sha" \
        --arg vfdqa "$durable_vfdqa" --arg vfdqa_sha "$durable_vfdqa_sha" \
        --arg retired "$retired_claim" --arg retired_sha "$retired_claim_sha" \
        --arg viewflow "$VIEWFLOW_INSTALLED" --arg viewflow_sha "$installed_viewflow_sha" \
        --arg unit_file "$VIEWFLOW_UNIT_FILE" --arg unit_sha "$installed_viewflow_unit_sha" \
        --arg unit "$VIEWFLOW_UNIT" --arg deskflow "$DESKFLOW_UNIT" --arg invocation "$persistent_invocation" \
        --arg intent "$transition_intent" --arg intent_sha "$transition_intent_sha" \
        --arg initial_state "$intent_initial_state" --argjson adopted "$preintent_partial_adopted" \
        --arg cgroup "$persistent_cgroup" --arg expected "$persistent_expected_exec" --arg observed "$persistent_observed_exec" \
        --arg cmdline "$persistent_cmdline_sha" --arg startup "$persistent_startup_sha" \
        --arg sidecar_path "$persistent_sidecar_path" --argjson sidecar_inode "$persistent_sidecar_inode" \
        --argjson sidecar_owner_pid "$persistent_sidecar_owner_pid" --argjson sidecar_owner_fd "$persistent_sidecar_owner_fd" \
        --argjson sidecar_count "$persistent_sidecar_listener_count" \
        --arg probe "$persistent_probe_sha" --arg journal "$persistent_journal_sha" \
        --arg start_cursor "$persistent_journal_start_cursor" --arg end_cursor "$persistent_journal_end_cursor" \
        --arg completed "$completed" --argjson peer_port "$persistent_probe_port" \
        --argjson journal_entries "$persistent_journal_entries" \
        --argjson journal_start_us "$persistent_journal_start_us" --argjson journal_end_us "$persistent_journal_end_us" \
        --argjson pid "$persistent_pid" --argjson ticks "$persistent_ticks" '
        {schema_version:1,state:"viewflow-abort-transients-handed-off-to-persistent-v13",operation_id:$op,
         initial_state:$initial_state,preintent_partial_adopted:($adopted == 1),
         terminal_receipt_path:$terminal,terminal_receipt_sha256:$terminal_sha,
         linux_v13_started_receipt_path:$linux,linux_v13_started_receipt_sha256:$linux_sha,
         transition_intent_path:$intent,transition_intent_sha256:$intent_sha,
         recovery_v3_lineage:{terminal_path:$recovery_terminal,terminal_sha256:$recovery_terminal_sha,
           query_path:$recovery_query,query_sha256:$recovery_query_sha,
           schema5_abort_receipt_path:$abort_receipt,schema5_abort_receipt_sha256:$abort_receipt_sha,
           durable_vfdqa_path:$vfdqa,durable_vfdqa_sha256:$vfdqa_sha,
           retired_claim_path:$retired,retired_claim_sha256:$retired_sha},
         quarantine_absence:{deployment_marker_present:false,abort_claim_present:false,
           release_claim_present:false,runtime_marker_present:false},
         post_transient_stop:{viewflow_exact_process_count:0,deskflow_exact_process_count:0,
           deskflow_core_exact_process_count:0,udp_44119_listener_count:0,tcp_24800_listener_count:0,
           sidecar_socket_present:false},
         persistent_viewflow:{unit:$unit,unit_active_state:"active",unit_file_path:$unit_file,
           unit_file_sha256:$unit_sha,executable_path:$viewflow,executable_sha256:$viewflow_sha,
           main_pid:$pid,start_ticks:$ticks,invocation_id:$invocation,control_group:$cgroup,
           expected_exec_start_sha256:$expected,observed_exec_start_sha256:$observed,
           sidecar_socket_path:$sidecar_path,sidecar_socket_inode:$sidecar_inode,
           sidecar_owner_pid:$sidecar_owner_pid,sidecar_owner_fd:$sidecar_owner_fd,
           sidecar_listener_count:$sidecar_count,
           cmdline_sha256:$cmdline,udp_44119_listener_count:1,protocol_startup_record_sha256:$startup,
           authenticated_peer_ip:"172.16.105.70",authenticated_peer_port:$peer_port,
           authenticated_probe_record_sha256:$probe,journal_invocation_id:$invocation,
           journal_slice_sha256:$journal,journal_entry_count:$journal_entries,
           journal_start_cursor:$start_cursor,journal_start_realtime_timestamp_us:$journal_start_us,
           journal_end_cursor:$end_cursor,journal_end_realtime_timestamp_us:$journal_end_us},
         deskflow:{unit:$deskflow,unit_active_state:"inactive",main_pid:0,exact_process_count:0,
           core_exact_process_count:0,tcp_24800_listener_count:0,started_by_handoff:false},
         completed_at_utc:$completed}
    ' >"$receipt_temp"
    validate_handoff_receipt "$receipt_temp"
    sync -f "$receipt_temp"
    final_reattest_against_receipt "$receipt_temp"
    atomic_publish_noreplace "$receipt_temp" "$handoff_receipt" ||
        die 'handoff receipt appeared concurrently or atomic publish failed'
    receipt_published=1
    receipt_temp=''
    [[ $(stat -c '%u:%a:%h' -- "$handoff_receipt") == 1000:600:1 ]] ||
        die 'handoff receipt is not owner-only/create-once'
    validate_handoff_receipt "$handoff_receipt"
}

preflight() {
    local command_name
    [[ $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] ||
        die 'run as uid 1000 with HOME=/home/wilf'
    for command_name in awk busctl chmod cmp date dd dirname grep jq journalctl mktemp python3 readlink rm sed sha256sum sleep ss stat sync systemctl; do
        command -v "$command_name" >/dev/null || die "required command unavailable: $command_name"
    done
    [[ $operation_id =~ ^[0-9a-f]{32}$ ]] || die 'operation ID must be 32 lowercase hexadecimal characters'
    require_sha256 '--terminal-receipt-sha256' "$terminal_receipt_sha"
    require_sha256 '--linux-v13-started-receipt-sha256' "$linux_started_receipt_sha"
    require_sha256 '--recovery-v3-terminal-sha256' "$recovery_v3_terminal_sha"
    require_sha256 '--recovery-v3-query-sha256' "$recovery_v3_query_sha"
    require_sha256 '--schema5-abort-receipt-sha256' "$schema5_abort_receipt_sha"
    require_sha256 '--durable-vfdqa-sha256' "$durable_vfdqa_sha"
    require_sha256 '--retired-claim-sha256' "$retired_claim_sha"
    require_sha256 '--installed-viewflow-sha256' "$installed_viewflow_sha"
    require_sha256 '--installed-viewflow-unit-sha256' "$installed_viewflow_unit_sha"
    [[ $recovery_v3_terminal_sha == "$EXPECTED_RECOVERY_V3_TERMINAL_SHA256" &&
       $recovery_v3_query_sha == "$EXPECTED_RECOVERY_V3_QUERY_SHA256" &&
       $schema5_abort_receipt_sha == "$EXPECTED_SCHEMA5_ABORT_RECEIPT_SHA256" &&
       $durable_vfdqa_sha == "$EXPECTED_DURABLE_VFDQA_SHA256" &&
       $retired_claim_sha == "$EXPECTED_RETIRED_CLAIM_SHA256" ]] ||
        die 'handoff inputs do not identify the frozen recovery-v3/schema5 abort lineage'
    require_owner_only_input 'terminal receipt' "$terminal_receipt" "$terminal_receipt_sha"
    require_owner_only_input 'Linux v1.3 started receipt' "$linux_started_receipt" "$linux_started_receipt_sha"
    require_owner_only_input 'recovery-v3 terminal' "$recovery_v3_terminal" "$recovery_v3_terminal_sha"
    require_owner_only_input 'recovery-v3 query' "$recovery_v3_query" "$recovery_v3_query_sha"
    require_owner_only_input 'schema5 abort receipt' "$schema5_abort_receipt" "$schema5_abort_receipt_sha"
    require_owner_only_binary_input 'durable VFDQA' "$durable_vfdqa" "$durable_vfdqa_sha" 384 VFDQA001
    require_owner_only_binary_input 'retired VFDQT claim' "$retired_claim" "$retired_claim_sha" 256 VFDQT001
    require_owner_output_boundary
    validate_terminal_receipts
    validate_recovery_v3_lineage
    validate_installed_persistent_files
}

replay_committed_handoff() {
    transition_intent="${handoff_receipt}.intent"
    [[ -f $transition_intent && ! -L $transition_intent &&
       $(stat -c '%u:%a:%h' -- "$transition_intent") == 1000:600:1 ]] ||
        die 'committed handoff is missing its owner-only transition intent'
    assert_strict_json_document 'transition intent' "$transition_intent"
    read_transition_intent_adoption "$transition_intent"
    validate_transition_intent "$transition_intent"
    transition_intent_sha=$(sha256 "$transition_intent")
    validate_handoff_receipt "$handoff_receipt"
    final_reattest_against_receipt "$handoff_receipt"
    assert_bound_inputs_unchanged
    receipt_published=1
    printf 'abort transient handoff receipt replayed; no service mutation: %s\n' "$handoff_receipt"
}

main() {
    preflight
    if [[ -e $handoff_receipt ]]; then
        replay_committed_handoff
        return 0
    fi
    classify_transition_state
    ensure_transition_intent "$transition_state"
    classify_transition_state
    retire_transients
    start_and_validate_persistent_viewflow
    publish_handoff_receipt
    printf 'abort transient baseline handed off to installed protocol-1.3 Viewflow: %s\n' "$handoff_receipt"
}

main
