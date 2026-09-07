#!/usr/bin/env bash

# Observe the normal protocol-2.1 daemon's self-termination after it wrote a
# schema-4 quiescence receipt. This producer never starts, stops, or replaces a
# service. It publishes a raw observation sidecar and a compact consumer-facing
# evidence document, both create-once and owner-only.

set -Eeuo pipefail
shopt -s nullglob
umask 077

readonly EXPECTED_UID=1000
readonly EXPECTED_HOME=/home/wilf
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly VIEWFLOW_INSTALLED=/home/wilf/.local/lib/viewflow/viewflowd
readonly VIEWFLOW_PORT=44119
readonly VIEWFLOW_SIDECAR=/run/user/1000/viewflow/deskflow.sock
readonly VIEWFLOW_DEVICE=00000000000000000000000000000001
readonly VIEWFLOW_PEER=172.16.105.70
readonly VIEWFLOW_TARGET=00000000000000000000000000000002
readonly DESKFLOW_SOURCE=00000000000000000000000000000101
readonly PROTOCOL_21_STARTUP='viewflowd protocol 2.1 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged'
readonly QUIESCENCE_EXIT='viewflowd deployment quiescence receipt written; daemon exiting'

runtime_receipt=
operation_id=
daemon_expected_sha=
evidence_output=
observation_output=
maximum_receipt_age_seconds=300
temporary_files=()

usage() {
    cat <<'EOF'
Usage:
  collect-viewflow-daemon-exit-evidence.sh \
    --runtime-receipt /absolute/path/viewflow-quiesced.json \
    --operation-id <matching 16-128 character operation ID> \
    --daemon-sha256 <exact installed daemon SHA-256> \
    --observation-output /absolute/new/path/daemon-exit-observation.json \
    --evidence-output /absolute/new/path/daemon-exit-evidence.json \
    [--maximum-receipt-age-seconds 300]

The daemon must already have exited normally. This command only observes the
stopped unit, process/listener/socket absence, and the exact invocation journal.
It does not stop, start, restart, install, or replace anything.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

cleanup() {
    local path
    for path in "${temporary_files[@]}"; do
        [[ -n $path ]] && rm -f -- "$path"
    done
}

trap cleanup EXIT

require_value() {
    [[ -n ${2-} ]] || die "$1 requires a value"
}

while (($#)); do
    case $1 in
        --runtime-receipt)
            require_value "$1" "${2-}"
            runtime_receipt=$2
            shift 2
            ;;
        --operation-id)
            require_value "$1" "${2-}"
            operation_id=$2
            shift 2
            ;;
        --daemon-sha256)
            require_value "$1" "${2-}"
            daemon_expected_sha=${2,,}
            shift 2
            ;;
        --evidence-output)
            require_value "$1" "${2-}"
            evidence_output=$2
            shift 2
            ;;
        --observation-output)
            require_value "$1" "${2-}"
            observation_output=$2
            shift 2
            ;;
        --maximum-receipt-age-seconds)
            require_value "$1" "${2-}"
            maximum_receipt_age_seconds=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

sha256() {
    sha256sum -- "$1" | awk '{print tolower($1)}'
}

unit_property() {
    systemctl --user show --property "$2" --value "$1"
}

exact_executable_pids() {
    local expected=$1 proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
}

validate_private_file() {
    local label=$1 path=$2 owner mode
    [[ $path == /* && -f $path && ! -L $path ]] ||
        die "$label must be an absolute regular non-symlink file"
    owner=$(stat -c '%u' -- "$path")
    mode=$(stat -c '%a' -- "$path")
    [[ $owner == "$EXPECTED_UID" && $mode == 600 ]] ||
        die "$label must be owned by uid $EXPECTED_UID with mode 0600"
}

validate_new_private_output() {
    local label=$1 path=$2 parent owner mode
    [[ $path == /* ]] || die "$label must be an absolute path"
    [[ ! -e $path && ! -L $path ]] || die "$label already exists; evidence is one-shot"
    parent=$(dirname -- "$path")
    [[ -d $parent && ! -L $parent ]] || die "$label parent must be a real directory"
    owner=$(stat -c '%u' -- "$parent")
    mode=$(stat -c '%a' -- "$parent")
    [[ $owner == "$EXPECTED_UID" ]] || die "$label parent must be owned by uid $EXPECTED_UID"
    (( (8#$mode & 8#077) == 0 )) ||
        die "$label parent must not be accessible by group or other users"
}

preflight() {
    [[ $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] ||
        die "run as uid $EXPECTED_UID with HOME=$EXPECTED_HOME"
    for command in awk basename chmod date dirname jq journalctl ln mktemp python3 readlink sha256sum ss stat systemctl; do
        command -v "$command" >/dev/null || die "required command is unavailable: $command"
    done
    [[ ${#operation_id} -ge 16 && ${#operation_id} -le 128 &&
       $operation_id =~ ^[A-Za-z0-9_-]+$ ]] ||
        die 'operation ID must be 16-128 ASCII letters, digits, hyphens, or underscores'
    [[ $daemon_expected_sha =~ ^[0-9a-f]{64}$ ]] ||
        die '--daemon-sha256 must be exactly 64 hexadecimal characters'
    [[ $maximum_receipt_age_seconds =~ ^[1-9][0-9]*$ &&
       $maximum_receipt_age_seconds -le 3600 ]] ||
        die '--maximum-receipt-age-seconds must be an integer from 1 through 3600'
    validate_private_file 'runtime receipt' "$runtime_receipt"
    validate_new_private_output 'observation output' "$observation_output"
    validate_new_private_output 'evidence output' "$evidence_output"
    [[ $observation_output != "$evidence_output" ]] ||
        die 'observation and evidence outputs must be different paths'
}

validate_strict_json_document() {
    local path=$1
    python3 - "$path" <<'PY'
import json
import pathlib
import sys

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
decoder = json.JSONDecoder(object_pairs_hook=reject_duplicates)
start = len(text) - len(text.lstrip())
try:
    _, end = decoder.raw_decode(text, start)
except (json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"invalid strict JSON document: {error}")
if text[end:].strip():
    raise SystemExit("invalid strict JSON document: trailing content")
PY
}

validate_runtime_receipt() {
    local path=$1 now completed_at_ms age receipt_pid receipt_ticks receipt_boot
    local receipt_instance receipt_sha current_boot installed_sha revoke_operation_id bound_peer_epoch
    validate_strict_json_document "$path" ||
        die 'runtime receipt is not a single duplicate-free JSON document'
    jq -e \
        --arg operation_id "$operation_id" \
        --arg daemon_sha "$daemon_expected_sha" \
        --arg peer "$VIEWFLOW_PEER" \
        --arg local_device "$VIEWFLOW_DEVICE" \
        --arg target "$VIEWFLOW_TARGET" \
        --arg source_display "$DESKFLOW_SOURCE" \
        'def uint53:
             type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
         def sha256: type == "string" and test("^[0-9a-f]{64}$");
         (keys == ["artifact_hashes", "boot_id", "cleanup", "completed_at_unix_ms",
                   "daemon_exit_required", "daemon_instance_id", "daemon_pid",
                   "daemon_sha256", "daemon_start_ticks", "local_device",
                   "operation_id", "peer_disconnect_status", "protocol_version",
                   "route_status", "schema_version", "sidecar_session_disconnected",
                   "state", "target_device"]) and
         (.schema_version == 4) and
         (.state == "viewflow-input-quiesced") and
         (.operation_id == $operation_id) and
         (.daemon_pid | uint53 and . > 0) and
         (.daemon_start_ticks | uint53 and . > 0) and
         (.boot_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
         (.daemon_instance_id == ((.boot_id) + "-" + (.daemon_pid | tostring) + "-" + (.daemon_start_ticks | tostring))) and
         (.daemon_sha256 | sha256) and
         (.daemon_sha256 == $daemon_sha) and
         (.protocol_version == "2.1") and
         (.local_device == $local_device) and
         (.target_device == $target) and
         (.route_status == "removed") and
         (.peer_disconnect_status == "initiated_before_daemon_exit") and
         (.daemon_exit_required == true) and
         (.sidecar_session_disconnected == true) and
         (.artifact_hashes | keys == ["linux_certificate_authority",
                                      "linux_peer_certificate",
                                      "linux_peer_private_key", "linux_viewflowd"]) and
         (.artifact_hashes.linux_viewflowd | sha256) and
         (.artifact_hashes.linux_viewflowd == $daemon_sha) and
         (.artifact_hashes.linux_peer_certificate | sha256) and
         (.artifact_hashes.linux_peer_private_key | sha256) and
         (.artifact_hashes.linux_certificate_authority | sha256) and
         (.cleanup | keys == ["active_lease_generation", "bound_peer_epoch",
                              "bound_peer_socket", "last_input_sequence",
                              "lease_revoke", "release_all", "route_ever_activated",
                              "route_generation", "route_was_active",
                              "source_display"]) and
         (.cleanup.release_all | keys == ["ack", "status"]) and
         (.cleanup.lease_revoke | keys == ["ack", "generation", "status"]) and
         (.cleanup.route_ever_activated | type == "boolean") and
         (.cleanup.route_was_active | type == "boolean") and
         (if .cleanup.route_was_active == false then
              .cleanup.route_ever_activated == false and
              .cleanup.source_display == null and
              .cleanup.route_generation == null and
              .cleanup.active_lease_generation == null and
              .cleanup.last_input_sequence == null and
              .cleanup.release_all.status == "not_required_no_active_route" and
              .cleanup.release_all.ack == null and
              .cleanup.lease_revoke.status == "not_required_no_active_route" and
              .cleanup.lease_revoke.generation == null and
              .cleanup.lease_revoke.ack == null and
              .cleanup.bound_peer_epoch == null and
              .cleanup.bound_peer_socket == null
          else
              .cleanup.route_ever_activated == true and
              .cleanup.source_display == $source_display and
              (.cleanup.route_generation | uint53 and . > 0) and
              (.cleanup.active_lease_generation |
                  uint53 and . > 0 and . < 9007199254740991) and
              (.cleanup.last_input_sequence | uint53 and . < 9007199254740991) and
              .cleanup.release_all.status == "applied" and
              (.cleanup.release_all.ack |
                  keys == ["event_sequence", "lease_generation", "result",
                           "target_device"]) and
              .cleanup.release_all.ack.result == "applied" and
              .cleanup.release_all.ack.lease_generation == .cleanup.active_lease_generation and
              .cleanup.release_all.ack.target_device == $target and
              .cleanup.release_all.ack.event_sequence == (.cleanup.last_input_sequence + 1) and
              .cleanup.lease_revoke.status == "applied" and
              .cleanup.lease_revoke.generation == (.cleanup.active_lease_generation + 1) and
              (.cleanup.lease_revoke.ack |
                  keys == ["lease_generation", "operation_id", "owner_device",
                           "result", "state", "target_device"]) and
              (.cleanup.lease_revoke.ack.operation_id |
                  type == "string" and test("^[0-9a-f]{32}$")) and
              .cleanup.lease_revoke.ack.operation_id != "00000000000000000000000000000000" and
              (.cleanup.lease_revoke.ack.lease_generation | uint53) and
              .cleanup.lease_revoke.ack.lease_generation == .cleanup.lease_revoke.generation and
              .cleanup.lease_revoke.ack.owner_device == $local_device and
              .cleanup.lease_revoke.ack.target_device == $target and
              .cleanup.lease_revoke.ack.state == "revoked" and
              .cleanup.lease_revoke.ack.result == "applied" and
              (.cleanup.bound_peer_epoch | uint53 and . > 0) and
              (.cleanup.bound_peer_socket | type == "string") and
              ((.cleanup.bound_peer_socket | split(":")) as $socket_parts |
                  ($socket_parts | length) == 2 and
                  $socket_parts[0] == $peer and
                  ($socket_parts[1] | test("^[0-9]+$") and
                      (tonumber >= 1 and tonumber <= 65535)))
          end) and
         (.completed_at_unix_ms | uint53 and . > 0)' \
        "$path" >/dev/null ||
        die 'runtime receipt schema, operation, daemon identity, hash, or protocol is invalid'

    if [[ $(jq -r '.cleanup.route_was_active' "$path") == true ]]; then
        revoke_operation_id=$(jq -er '.cleanup.lease_revoke.ack.operation_id' "$path")
        bound_peer_epoch=$(jq -er '.cleanup.bound_peer_epoch' "$path")
        [[ ${revoke_operation_id:0:16} == "$(printf '%016x' "$bound_peer_epoch")" ]] ||
            die 'runtime receipt revoke operation does not bind the exact peer epoch'
        [[ ${revoke_operation_id:16:16} != 0000000000000000 ]] ||
            die 'runtime receipt revoke operation nonce must be nonzero'
    fi

    receipt_pid=$(jq -er '.daemon_pid' "$path")
    receipt_ticks=$(jq -er '.daemon_start_ticks' "$path")
    receipt_boot=$(jq -er '.boot_id' "$path")
    receipt_instance=$(jq -er '.daemon_instance_id' "$path")
    receipt_sha=$(jq -er \
        '.daemon_sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$path")
    [[ $receipt_instance == "$receipt_boot-$receipt_pid-$receipt_ticks" ]] ||
        die 'runtime receipt daemon_instance_id does not match PID/start/boot identity'
    [[ $receipt_sha == "$daemon_expected_sha" ]] || die 'runtime receipt daemon hash mismatch'
    current_boot=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)
    [[ $receipt_boot == "$current_boot" ]] || die 'runtime receipt belongs to another boot'
    installed_sha=$(sha256 "$VIEWFLOW_INSTALLED")
    [[ $installed_sha == "$daemon_expected_sha" ]] ||
        die 'installed daemon changed before exit evidence collection'
    [[ ! -e /proc/$receipt_pid ]] || die 'runtime receipt daemon PID still exists'

    completed_at_ms=$(jq -er '.completed_at_unix_ms' "$path")
    now=$(date -u +%s)
    age=$((now - completed_at_ms / 1000))
    ((age >= -5 && age <= maximum_receipt_age_seconds)) ||
        die 'runtime receipt is stale or from the future'
}

capture_exact_journal() {
    local invocation_id=$1 daemon_pid=$2 journal_boot_id=$3 destination=$4
    journalctl --user --quiet --no-pager --output=json \
        "_SYSTEMD_INVOCATION_ID=$invocation_id" "_PID=$daemon_pid" \
        "_BOOT_ID=$journal_boot_id" >"$destination"
    [[ -s $destination ]] || die 'exact daemon invocation has no journal entries'
    jq -s -e \
        'length > 0 and all(.[];
            ._SYSTEMD_INVOCATION_ID == $invocation and
            ._PID == $pid and ._BOOT_ID == $boot_id)' \
        --arg invocation "$invocation_id" --arg pid "$daemon_pid" \
        --arg boot_id "$journal_boot_id" "$destination" >/dev/null ||
        die 'journal slice is not exclusively bound to invocation, PID, and boot'
}

discover_invocation_from_pid_boot() {
    local daemon_pid=$1 journal_boot_id=$2 completed_at_ms=$3 destination=$4
    journalctl --user --quiet --no-pager --output=json \
        "_PID=$daemon_pid" "_BOOT_ID=$journal_boot_id" >"$destination"
    [[ -s $destination ]] || die 'receipt PID and boot have no journal entries'
    jq -s -e \
        'length > 0 and all(.[]; ._PID == $pid and ._BOOT_ID == $boot_id)' \
        --arg pid "$daemon_pid" --arg boot_id "$journal_boot_id" \
        "$destination" >/dev/null ||
        die 'PID/boot discovery journal contains an out-of-scope entry'
    jq -sr \
        --arg startup "$PROTOCOL_21_STARTUP" \
        --arg exit "$QUIESCENCE_EXIT" \
        --argjson completed_us "$((completed_at_ms * 1000))" \
        '[group_by(._SYSTEMD_INVOCATION_ID)[] |
          select((.[0]._SYSTEMD_INVOCATION_ID // "") | test("^[0-9a-f]{32}$")) |
          select([.[] | select((.MESSAGE // "") == $startup)] | length == 1) |
          select([.[] | select((.MESSAGE // "") == $exit and
                               (.__REALTIME_TIMESTAMP | tonumber) >= $completed_us)] |
                 length == 1) |
          .[0]._SYSTEMD_INVOCATION_ID] |
         if length == 1 then .[0]
         else error("normal exit journal must identify exactly one invocation")
         end' "$destination"
}

collect_evidence() {
    local receipt_sha receipt_sha_after daemon_pid daemon_start_ticks boot_id daemon_instance_id
    local invocation_id unit_invocation_property journal_boot_id active_state main_pid exact_pids udp_output
    local exact_process_count udp_listener_count socket_present observed_at_ms completed_at_ms
    local discovery_journal_file journal_file observation_temp evidence_temp journal_sha journal_entry_count
    local startup_count exit_count first_realtime_us last_realtime_us exit_realtime_us
    local observation_sha output_parent observation_parent

    preflight
    validate_runtime_receipt "$runtime_receipt"
    receipt_sha=$(sha256 "$runtime_receipt")
    daemon_pid=$(jq -er '.daemon_pid' "$runtime_receipt")
    daemon_start_ticks=$(jq -er '.daemon_start_ticks' "$runtime_receipt")
    boot_id=$(jq -er '.boot_id' "$runtime_receipt")
    daemon_instance_id=$(jq -er '.daemon_instance_id' "$runtime_receipt")
    completed_at_ms=$(jq -er '.completed_at_unix_ms' "$runtime_receipt")

    active_state=$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true)
    main_pid=$(unit_property "$VIEWFLOW_UNIT" MainPID)
    unit_invocation_property=$(unit_property "$VIEWFLOW_UNIT" InvocationID)
    [[ $active_state == inactive && $main_pid == 0 ]] ||
        die "$VIEWFLOW_UNIT must be inactive with MainPID=0"
    [[ ! -e /proc/$daemon_pid ]] || die 'original daemon PID is still present'

    exact_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
    exact_process_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$exact_pids")
    udp_output=$(ss -H -lun "sport = :$VIEWFLOW_PORT")
    udp_listener_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$udp_output")
    if [[ -e $VIEWFLOW_SIDECAR || -L $VIEWFLOW_SIDECAR ]]; then
        socket_present=true
    else
        socket_present=false
    fi
    [[ $exact_process_count == 0 && $udp_listener_count == 0 && $socket_present == false ]] ||
        die 'daemon process, UDP listener, or sidecar socket remains present'

    output_parent=$(dirname -- "$evidence_output")
    observation_parent=$(dirname -- "$observation_output")
    discovery_journal_file=$(mktemp --tmpdir="$observation_parent" .viewflow-exit-discovery.XXXXXX)
    journal_file=$(mktemp --tmpdir="$observation_parent" .viewflow-exit-journal.XXXXXX)
    observation_temp=$(mktemp --tmpdir="$observation_parent" .viewflow-exit-observation.XXXXXX)
    evidence_temp=$(mktemp --tmpdir="$output_parent" .viewflow-exit-evidence.XXXXXX)
    temporary_files+=("$discovery_journal_file" "$journal_file" "$observation_temp" "$evidence_temp")
    chmod 0600 -- "$discovery_journal_file" "$journal_file" "$observation_temp" "$evidence_temp"

    journal_boot_id=${boot_id//-/}
    invocation_id=$(discover_invocation_from_pid_boot "$daemon_pid" "$journal_boot_id" \
        "$completed_at_ms" "$discovery_journal_file")
    [[ $invocation_id =~ ^[0-9a-f]{32}$ ]] ||
        die 'journal-selected systemd InvocationID is invalid'
    [[ -z $unit_invocation_property || $unit_invocation_property == "$invocation_id" ]] ||
        die 'remaining unit InvocationID property disagrees with the exact journal invocation'
    capture_exact_journal "$invocation_id" "$daemon_pid" "$journal_boot_id" "$journal_file"
    journal_sha=$(sha256 "$journal_file")
    journal_entry_count=$(jq -s 'length' "$journal_file")
    startup_count=$(jq -s --arg message "$PROTOCOL_21_STARTUP" \
        '[.[] | select((.MESSAGE // "") == $message)] | length' "$journal_file")
    exit_count=$(jq -s --arg message "$QUIESCENCE_EXIT" \
        '[.[] | select((.MESSAGE // "") == $message)] | length' "$journal_file")
    [[ $startup_count == 1 && $exit_count == 1 ]] ||
        die 'journal must contain exactly one protocol-2.1 startup and one quiescence exit line'
    first_realtime_us=$(jq -sr 'map(.__REALTIME_TIMESTAMP | tonumber) | min' "$journal_file")
    last_realtime_us=$(jq -sr 'map(.__REALTIME_TIMESTAMP | tonumber) | max' "$journal_file")
    exit_realtime_us=$(jq -sr --arg message "$QUIESCENCE_EXIT" \
        '[.[] | select((.MESSAGE // "") == $message) | .__REALTIME_TIMESTAMP | tonumber] | .[0]' \
        "$journal_file")
    completed_at_ms=$(jq -er '.completed_at_unix_ms' "$runtime_receipt")
    ((exit_realtime_us >= completed_at_ms * 1000)) ||
        die 'journal exit line predates runtime receipt completion'

    # Re-bracket all live observations and the immutable receipt after journal capture.
    [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == inactive &&
       $(unit_property "$VIEWFLOW_UNIT" MainPID) == 0 &&
       ( -z $(unit_property "$VIEWFLOW_UNIT" InvocationID) ||
         $(unit_property "$VIEWFLOW_UNIT" InvocationID) == "$invocation_id" ) &&
       ! -e /proc/$daemon_pid &&
       -z $(exact_executable_pids "$VIEWFLOW_INSTALLED") &&
       -z $(ss -H -lun "sport = :$VIEWFLOW_PORT") &&
       ! -e $VIEWFLOW_SIDECAR && ! -L $VIEWFLOW_SIDECAR ]] ||
        die 'daemon exit state changed during evidence collection'
    receipt_sha_after=$(sha256 "$runtime_receipt")
    [[ $receipt_sha_after == "$receipt_sha" ]] || die 'runtime receipt changed during collection'
    observed_at_ms=$(( $(date -u +%s%N) / 1000000 ))
    ((observed_at_ms >= completed_at_ms)) || die 'exit observation predates receipt completion'

    jq -S -c -n \
        --arg state 'viewflow-daemon-exit-observation' \
        --arg operation_id "$operation_id" --arg runtime_receipt_sha256 "$receipt_sha" \
        --arg daemon_instance_id "$daemon_instance_id" --argjson daemon_pid "$daemon_pid" \
        --argjson daemon_start_ticks "$daemon_start_ticks" --arg boot_id "$boot_id" \
        --arg daemon_sha256 "$daemon_expected_sha" --arg invocation_id "$invocation_id" \
        --arg unit_invocation_property "$unit_invocation_property" \
        --arg unit "$VIEWFLOW_UNIT" --arg active_state "$active_state" \
        --arg main_pid "$main_pid" --arg exact_process_pids "$exact_pids" \
        --arg udp_listener_output "$udp_output" --arg sidecar_lstat 'absent' \
        --arg journal_sha256 "$journal_sha" --arg journal_query_invocation "$invocation_id" \
        --arg journal_query_pid "$daemon_pid" --arg journal_query_boot "$journal_boot_id" \
        --slurpfile journal_entries "$journal_file" \
        --argjson observed_at_unix_ms "$observed_at_ms" \
        '{schema_version: 1, state: $state, operation_id: $operation_id,
          runtime_receipt_sha256: $runtime_receipt_sha256,
          daemon_identity: {daemon_instance_id: $daemon_instance_id, daemon_pid: $daemon_pid,
                            daemon_start_ticks: $daemon_start_ticks, boot_id: $boot_id,
                            daemon_sha256: $daemon_sha256, invocation_id: $invocation_id},
          journal_query: {_SYSTEMD_INVOCATION_ID: $journal_query_invocation,
                          _PID: $journal_query_pid, _BOOT_ID: $journal_query_boot},
          command_outputs: {systemctl_is_active: $active_state, systemctl_main_pid: $main_pid,
                            systemctl_invocation_id: $unit_invocation_property,
                            journal_selected_invocation_id: $invocation_id,
                            original_daemon_pid_present: "false",
                            exact_process_pids: $exact_process_pids,
                            udp_listener_output: $udp_listener_output,
                            sidecar_socket_lstat: $sidecar_lstat,
                            journal_json_sha256: $journal_sha256,
                            journal_entries: $journal_entries},
          observed_at_unix_ms: $observed_at_unix_ms}' \
        >"$observation_temp"
    observation_sha=$(sha256 "$observation_temp")

    jq -S -n \
        --arg state 'viewflow-daemon-exited' --arg operation_id "$operation_id" \
        --arg runtime_receipt_sha256 "$receipt_sha" \
        --arg observation_file_name "$(basename -- "$observation_output")" \
        --arg observation_sha256 "$observation_sha" \
        --arg daemon_instance_id "$daemon_instance_id" --argjson daemon_pid "$daemon_pid" \
        --argjson daemon_start_ticks "$daemon_start_ticks" --arg boot_id "$boot_id" \
        --arg daemon_sha256 "$daemon_expected_sha" --arg invocation_id "$invocation_id" \
        --arg unit_invocation_property "$unit_invocation_property" \
        --arg protocol_version '2.1' --arg unit "$VIEWFLOW_UNIT" \
        --arg active_state "$active_state" --argjson main_pid "$main_pid" \
        --argjson exact_process_count "$exact_process_count" \
        --argjson udp_listener_count "$udp_listener_count" \
        --arg journal_sha256 "$journal_sha" --arg journal_query_invocation "$invocation_id" \
        --arg journal_query_pid "$daemon_pid" --arg journal_query_boot "$journal_boot_id" \
        --argjson journal_entry_count "$journal_entry_count" \
        --argjson startup_count "$startup_count" --argjson exit_count "$exit_count" \
        --argjson first_realtime_us "$first_realtime_us" \
        --argjson last_realtime_us "$last_realtime_us" \
        --argjson exit_realtime_us "$exit_realtime_us" \
        --arg systemctl_is_active "$active_state" --arg systemctl_main_pid "$main_pid" \
        --arg exact_process_pids "$exact_pids" --arg udp_listener_output "$udp_output" \
        --slurpfile journal_entries "$journal_file" \
        --argjson observed_at_unix_ms "$observed_at_ms" \
        '{schema_version: 1, state: $state, operation_id: $operation_id,
          runtime_receipt_sha256: $runtime_receipt_sha256,
          observation_file_name: $observation_file_name,
          daemon_instance_id: $daemon_instance_id, daemon_pid: $daemon_pid,
          daemon_start_ticks: $daemon_start_ticks, boot_id: $boot_id,
          daemon_sha256: $daemon_sha256, invocation_id: $invocation_id,
          protocol_version: $protocol_version, unit: $unit,
          journal: {query: {_SYSTEMD_INVOCATION_ID: $journal_query_invocation,
                            _PID: $journal_query_pid, _BOOT_ID: $journal_query_boot},
                    entry_count: $journal_entry_count, startup_count: $startup_count,
                    quiescence_exit_count: $exit_count, slice_sha256: $journal_sha256,
                    first_realtime_us: $first_realtime_us,
                    last_realtime_us: $last_realtime_us,
                    exit_realtime_us: $exit_realtime_us},
          active_state: $active_state, main_pid: $main_pid,
          exact_process_count: $exact_process_count,
          udp_listener_count: $udp_listener_count, sidecar_socket_present: false,
          exit_status: {unit_inactive: true, main_pid_zero: true,
                        original_daemon_pid_present: false, exact_process_count: $exact_process_count,
                        udp_listener_count: $udp_listener_count, sidecar_socket_present: false},
          command_outputs: {systemctl_is_active: $systemctl_is_active,
                            systemctl_main_pid: $systemctl_main_pid,
                            systemctl_invocation_id: $unit_invocation_property,
                            journal_selected_invocation_id: $invocation_id,
                            original_daemon_pid_present: "false",
                            exact_process_pids: $exact_process_pids,
                            udp_listener_output: $udp_listener_output,
                            sidecar_socket_lstat: "absent",
                            journal_json_sha256: $journal_sha256,
                            journal_entries: $journal_entries},
          observation_sha256: $observation_sha256,
          observed_at_unix_ms: $observed_at_unix_ms}' \
        >"$evidence_temp"

    # Hard-link publication is atomic and refuses to replace an existing name.
    ln -- "$observation_temp" "$observation_output" || die 'observation output appeared concurrently'
    ln -- "$evidence_temp" "$evidence_output" || die 'evidence output appeared concurrently'
    [[ $(stat -c '%u:%a' -- "$observation_output") == "$EXPECTED_UID:600" &&
       $(stat -c '%u:%a' -- "$evidence_output") == "$EXPECTED_UID:600" ]] ||
        die 'published evidence ownership or mode is invalid'
    [[ $(sha256 "$observation_output") == "$observation_sha" ]] ||
        die 'published observation sidecar hash mismatch'
    printf 'created Viewflow daemon exit evidence for operation %s\n' "$operation_id"
}

collect_evidence
