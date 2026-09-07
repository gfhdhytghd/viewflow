#!/usr/bin/env bash

# One-time evidence producer for an installed protocol-1.3 Linux peer that has
# must be frozen and stopped before the cross-host bootstrap continues. This is
# intentionally not a schema-v3 quiescence or remote-release producer.

set -Eeuo pipefail
shopt -s nullglob

readonly EXPECTED_UID=1000
readonly EXPECTED_HOME=/home/wilf
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly DESKFLOW_UNIT=deskflow.service
readonly VIEWFLOW_INSTALLED=/home/wilf/.local/lib/viewflow/viewflowd
readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly VIEWFLOW_PORT=44119
readonly DESKFLOW_PORT=24800
readonly VIEWFLOW_SIDECAR=/run/user/1000/viewflow/deskflow.sock
readonly STOP_TIMEOUT_SECONDS=30
readonly PROTOCOL_13_STARTUP='viewflowd protocol 1.3 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged'

daemon_pid=
daemon_expected_sha=
evidence_output=
operation_id=
temporary_files=()

usage() {
    cat <<'EOF'
Usage:
  collect-viewflow-v13-bootstrap-evidence.sh \
    --daemon-pid <exact current MainPID> \
    --daemon-sha256 <exact running executable SHA-256> \
    --operation-id <unique 16-128 character bootstrap operation ID> \
    --evidence-output /absolute/new/path/viewflow-v13-bootstrap-frozen.json

This one-time command records all lease/input/activation and cleanup/release
counts, freezes admission by requiring Deskflow fully stopped, then stops the
exact protocol-1.3 Viewflow invocation. Non-zero counts do not prove cleanup;
a later bootstrap consumer must always require the independent Windows Session
1 force-release receipt. It never starts, installs, or replaces a binary.
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
        --daemon-pid)
            require_value "$1" "${2-}"
            daemon_pid=$2
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
        --operation-id)
            require_value "$1" "${2-}"
            operation_id=$2
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

exact_executable_pids() {
    local expected=$1 proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
    return 0
}

proc_start_ticks() {
    local pid=$1
    sed -E 's/^[0-9]+ \(.*\) //' "/proc/$pid/stat" | awk '{print $20}'
}

unit_property() {
    systemctl --user show --property "$2" --value "$1"
}

journal_count() {
    local journal_file=$1 expression=$2
    jq -s --arg expression "$expression" \
        '[.[] | (.MESSAGE // "") | select(test($expression))] | length' \
        "$journal_file"
}

capture_invocation_journal() {
    local invocation_id=$1 pid=$2 boot_id=$3 destination=$4 journal_boot_id
    journal_boot_id=${boot_id//-/}
    journalctl --user --quiet --no-pager --output=json \
        "_SYSTEMD_INVOCATION_ID=$invocation_id" "_PID=$pid" "_BOOT_ID=$journal_boot_id" \
        >"$destination"
    [[ -s $destination ]] || die 'no journal entries exist for the exact daemon invocation'
    jq -s -e \
        'length > 0 and all(.[];
            ._SYSTEMD_INVOCATION_ID == $invocation and
            ._PID == $pid and ._BOOT_ID == $boot_id)' \
        --arg invocation "$invocation_id" --arg pid "$pid" --arg boot_id "$journal_boot_id" \
        "$destination" >/dev/null ||
        die 'journal slice is not bound exclusively to the exact daemon invocation, PID, and boot'
}

wait_for_stopped_state() {
    local expected_pid=$1 deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
    local state main_pid exact_pids udp_output
    while ((SECONDS < deadline)); do
        state=$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true)
        main_pid=$(unit_property "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true)
        exact_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
        udp_output=$(ss -H -lun "sport = :$VIEWFLOW_PORT")
        if [[ $state == inactive && ${main_pid:-0} == 0 && ! -e /proc/$expected_pid &&
              -z $exact_pids && -z $udp_output && ! -e $VIEWFLOW_SIDECAR ]]; then
            return 0
        fi
        sleep 0.1
    done
    die 'old Viewflow daemon did not reach the required fully stopped state'
}

preflight() {
    local output_parent output_mode
    [[ $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] ||
        die "run as uid $EXPECTED_UID with HOME=$EXPECTED_HOME"
    for command in awk date grep jq journalctl ln mktemp readlink sed sha256sum ss stat systemctl; do
        command -v "$command" >/dev/null || die "required command is unavailable: $command"
    done
    [[ $daemon_pid =~ ^[1-9][0-9]*$ ]] || die '--daemon-pid must be a positive integer'
    [[ $daemon_expected_sha =~ ^[0-9a-f]{64}$ ]] ||
        die '--daemon-sha256 must be exactly 64 hexadecimal characters'
    [[ ${#operation_id} -ge 16 && ${#operation_id} -le 128 &&
       $operation_id =~ ^[A-Za-z0-9_-]+$ ]] ||
        die 'operation ID must be 16-128 ASCII letters, digits, hyphens, or underscores'
    [[ $evidence_output == /* ]] || die '--evidence-output must be an absolute path'
    [[ ! -e $evidence_output && ! -L $evidence_output ]] ||
        die 'evidence output already exists; bootstrap evidence is one-shot'
    output_parent=$(dirname -- "$evidence_output")
    [[ -d $output_parent && ! -L $output_parent ]] ||
        die 'evidence output parent must be a real directory'
    [[ $(stat -c '%u' -- "$output_parent") == "$EXPECTED_UID" ]] ||
        die "evidence output parent must be owned by uid $EXPECTED_UID"
    output_mode=$(stat -c '%a' -- "$output_parent")
    (( (8#$output_mode & 8#077) == 0 )) ||
        die 'evidence output parent must not be accessible by group or other users'
}

collect_evidence() {
    local main_pid invocation_id daemon_exe daemon_sha start_ticks boot_id journal_boot_id exact_pids
    local journal_file transcript_file output_temp
    local startup_count lease_offered_count input_event_count sidecar_activation_count
    local cleanup_release_error_count journal_start_cursor journal_start_us
    local startup_cursor startup_us journal_end_cursor journal_end_us journal_entries
    local journal_sha unit_state post_main_pid post_exact_pids udp_output socket_present
    local transcript_sha completed_at_ms deskflow_pids deskflow_core_pids
    local deskflow_state deskflow_main_pid deskflow_tcp_output

    preflight

    [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active ]] ||
        die "$VIEWFLOW_UNIT must be active before collecting bootstrap evidence"
    main_pid=$(unit_property "$VIEWFLOW_UNIT" MainPID)
    [[ $main_pid == "$daemon_pid" ]] || die 'supplied daemon PID does not match systemd MainPID'
    invocation_id=$(unit_property "$VIEWFLOW_UNIT" InvocationID)
    [[ $invocation_id =~ ^[0-9a-f]{32}$ ]] || die 'systemd InvocationID is invalid'
    [[ -e /proc/$daemon_pid/exe ]] || die 'exact daemon PID is no longer running'
    daemon_exe=$(readlink -f -- "/proc/$daemon_pid/exe")
    [[ $daemon_exe == "$VIEWFLOW_INSTALLED" ]] || die 'daemon executable path is unexpected'
    exact_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
    [[ $exact_pids == "$daemon_pid" ]] || die 'installed Viewflow executable must have one exact PID'
    start_ticks=$(proc_start_ticks "$daemon_pid")
    [[ $start_ticks =~ ^[1-9][0-9]*$ ]] || die 'daemon start ticks are invalid'
    boot_id=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)
    [[ $boot_id =~ ^[0-9a-f]{8}-[0-9a-f-]{27,}$ ]] || die 'Linux boot ID is invalid'
    journal_boot_id=${boot_id//-/}
    daemon_sha=$(sha256 "/proc/$daemon_pid/exe")
    [[ $daemon_sha == "$daemon_expected_sha" ]] || die 'running daemon SHA-256 mismatch'

    # A bootstrap claim is valid only if Deskflow was already stopped. This
    # collector never stops Deskflow on the operator's behalf.
    deskflow_pids=$(exact_executable_pids "$DESKFLOW_INSTALLED")
    deskflow_core_pids=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    deskflow_state=$(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true)
    deskflow_main_pid=$(unit_property "$DESKFLOW_UNIT" MainPID 2>/dev/null || true)
    deskflow_tcp_output=$(ss -H -ltn "sport = :$DESKFLOW_PORT")
    [[ $deskflow_state == inactive && ${deskflow_main_pid:-0} == 0 &&
       -z $deskflow_pids && -z $deskflow_core_pids && -z $deskflow_tcp_output ]] ||
        die 'Deskflow must be inactive with MainPID, exact processes, and TCP listener all zero'

    journal_file=$(mktemp --tmpdir "viewflow-v13-journal.XXXXXX")
    temporary_files+=("$journal_file")
    capture_invocation_journal "$invocation_id" "$daemon_pid" "$boot_id" "$journal_file"
    startup_count=$(journal_count "$journal_file" '^viewflowd protocol 1\.3 serving mTLS QUIC on 0\.0\.0\.0:44119; Deskflow unchanged$')
    [[ $startup_count == 1 ]] || die 'exact protocol 1.3 startup line must occur once'

    # The pre-stop snapshot prevents stopping a daemon whose already-visible
    # invocation evidence is unsafe. The final snapshot below is authoritative.
    lease_offered_count=$(journal_count "$journal_file" 'lease_offered=')
    input_event_count=$(journal_count "$journal_file" 'input_event_sequence=')
    sidecar_activation_count=$(journal_count "$journal_file" 'input sidecar activation')
    cleanup_release_error_count=$(journal_count "$journal_file" '(?i)(((cleanup|release[-_ ]?all|releaseall).*(failed|error|not confirmed|timed out|rejected))|((failed|error).*(cleanup|release[-_ ]?all|releaseall)))')
    [[ $(unit_property "$VIEWFLOW_UNIT" MainPID) == "$daemon_pid" &&
       $(unit_property "$VIEWFLOW_UNIT" InvocationID) == "$invocation_id" &&
       $(proc_start_ticks "$daemon_pid") == "$start_ticks" &&
       $(tr -d '\r\n' </proc/sys/kernel/random/boot_id) == "$boot_id" &&
       $(sha256 "/proc/$daemon_pid/exe") == "$daemon_sha" ]] ||
        die 'daemon identity changed between capture and stop boundary'

    systemctl --user stop "$VIEWFLOW_UNIT"
    wait_for_stopped_state "$daemon_pid"

    # Re-read the now-terminal invocation so shutdown errors cannot race the
    # activity inventory.
    capture_invocation_journal "$invocation_id" "$daemon_pid" "$boot_id" "$journal_file"
    startup_count=$(journal_count "$journal_file" '^viewflowd protocol 1\.3 serving mTLS QUIC on 0\.0\.0\.0:44119; Deskflow unchanged$')
    lease_offered_count=$(journal_count "$journal_file" 'lease_offered=')
    input_event_count=$(journal_count "$journal_file" 'input_event_sequence=')
    sidecar_activation_count=$(journal_count "$journal_file" 'input sidecar activation')
    cleanup_release_error_count=$(journal_count "$journal_file" '(?i)(((cleanup|release[-_ ]?all|releaseall).*(failed|error|not confirmed|timed out|rejected))|((failed|error).*(cleanup|release[-_ ]?all|releaseall)))')
    [[ $startup_count == 1 ]] ||
        die 'terminal old invocation lost its exact protocol-1.3 startup evidence'

    journal_entries=$(jq -s 'length' "$journal_file")
    journal_start_cursor=$(jq -sr '.[0].__CURSOR' "$journal_file")
    journal_start_us=$(jq -sr '.[0].__REALTIME_TIMESTAMP' "$journal_file")
    startup_cursor=$(jq -sr --arg line "$PROTOCOL_13_STARTUP" \
        '[.[] | select(.MESSAGE == $line)][0].__CURSOR' "$journal_file")
    startup_us=$(jq -sr --arg line "$PROTOCOL_13_STARTUP" \
        '[.[] | select(.MESSAGE == $line)][0].__REALTIME_TIMESTAMP' "$journal_file")
    journal_end_cursor=$(jq -sr '.[-1].__CURSOR' "$journal_file")
    journal_end_us=$(jq -sr '.[-1].__REALTIME_TIMESTAMP' "$journal_file")
    [[ -n $journal_start_cursor && $journal_start_us =~ ^[0-9]+$ &&
       -n $startup_cursor && $startup_us =~ ^[0-9]+$ &&
       -n $journal_end_cursor && $journal_end_us =~ ^[0-9]+$ ]] ||
        die 'journal cursor or timestamp evidence is invalid'
    journal_sha=$(sha256 "$journal_file")

    unit_state=$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true)
    post_main_pid=$(unit_property "$VIEWFLOW_UNIT" MainPID)
    post_exact_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
    udp_output=$(ss -H -lun "sport = :$VIEWFLOW_PORT")
    [[ -e $VIEWFLOW_SIDECAR ]] && socket_present=true || socket_present=false
    [[ $unit_state == inactive && $post_main_pid == 0 && -z $post_exact_pids &&
       -z $udp_output && $socket_present == false && ! -e /proc/$daemon_pid ]] ||
        die 'post-stop command evidence changed after the stop wait'

    transcript_file=$(mktemp --tmpdir "viewflow-v13-stop.XXXXXX")
    temporary_files+=("$transcript_file")
    {
        printf 'systemctl_is_active=%s\n' "$unit_state"
        printf 'systemctl_main_pid=%s\n' "$post_main_pid"
        printf 'exact_viewflow_pids=%s\n' "$post_exact_pids"
        printf 'udp_44119_listeners=%s\n' "$udp_output"
        printf 'sidecar_socket_present=%s\n' "$socket_present"
        printf 'original_daemon_pid_present=%s\n' "$( [[ -e /proc/$daemon_pid ]] && printf true || printf false )"
    } >"$transcript_file"
    transcript_sha=$(sha256 "$transcript_file")
    completed_at_ms=$(($(date -u +%s%N) / 1000000))

    output_temp=$(mktemp --tmpdir="$(dirname -- "$evidence_output")" \
        '.viewflow-v13-bootstrap.XXXXXX')
    temporary_files+=("$output_temp")
    chmod 0600 "$output_temp"
    jq -n \
        --arg state 'viewflow-v13-bootstrap-frozen' \
        --arg operation_id "$operation_id" \
        --argjson daemon_pid "$daemon_pid" --argjson daemon_start_ticks "$start_ticks" \
        --arg boot_id "$boot_id" --arg journal_boot_id "$journal_boot_id" \
        --arg daemon_sha256 "$daemon_sha" \
        --arg daemon_executable "$daemon_exe" --arg invocation_id "$invocation_id" \
        --arg daemon_instance_id "$boot_id-$daemon_pid-$start_ticks" \
        --arg journal_start_cursor "$journal_start_cursor" \
        --argjson journal_start_us "$journal_start_us" \
        --arg startup_cursor "$startup_cursor" --argjson startup_us "$startup_us" \
        --arg journal_end_cursor "$journal_end_cursor" --argjson journal_end_us "$journal_end_us" \
        --argjson journal_entries "$journal_entries" --arg journal_sha256 "$journal_sha" \
        --argjson startup_count "$startup_count" \
        --argjson lease_offered_count "$lease_offered_count" \
        --argjson input_event_count "$input_event_count" \
        --argjson sidecar_activation_count "$sidecar_activation_count" \
        --argjson cleanup_release_error_count "$cleanup_release_error_count" \
        --arg unit_state "$unit_state" --argjson main_pid "$post_main_pid" \
        --arg exact_process_output "$post_exact_pids" --arg udp_output "$udp_output" \
        --arg socket_present "$socket_present" \
        --arg command_output_sha256 "$transcript_sha" \
        --argjson completed_at_unix_ms "$completed_at_ms" \
        '{schema_version: 1, state: $state, operation_id: $operation_id,
          daemon: {pid: $daemon_pid, start_ticks: $daemon_start_ticks, boot_id: $boot_id,
                   daemon_instance_id: $daemon_instance_id,
                   sha256: $daemon_sha256, executable: $daemon_executable,
                   systemd_invocation_id: $invocation_id},
          journal: {query_boot_id: $journal_boot_id, query_pid: ($daemon_pid | tostring),
                    query_systemd_invocation_id: $invocation_id,
                    start_cursor: $journal_start_cursor,
                    start_realtime_timestamp_us: $journal_start_us,
                    protocol_startup_cursor: $startup_cursor,
                    protocol_startup_realtime_timestamp_us: $startup_us,
                    end_cursor: $journal_end_cursor,
                    end_realtime_timestamp_us: $journal_end_us,
                    entry_count: $journal_entries, slice_sha256: $journal_sha256,
                    counts: {protocol_1_3_startup: $startup_count,
                             lease_offered: $lease_offered_count,
                             input_event: $input_event_count,
                             input_sidecar_activation: $sidecar_activation_count,
                             cleanup_or_release_error: $cleanup_release_error_count}},
          pre_stop: {deskflow_unit_active_state: "inactive", deskflow_main_pid: 0,
                     deskflow_exact_process_count: 0, deskflow_core_exact_process_count: 0,
                     deskflow_tcp_24800_listener_count: 0},
          post_stop: {unit_active_state: $unit_state, main_pid: $main_pid,
                      exact_process_count: 0, udp_44119_listener_count: 0,
                      sidecar_socket_present: false, original_daemon_pid_present: false,
                      command_outputs: {systemctl_is_active: $unit_state,
                                        systemctl_main_pid: ($main_pid | tostring),
                                        exact_viewflow_pids: $exact_process_output,
                                        udp_44119_listeners: $udp_output,
                                        sidecar_socket_present: $socket_present,
                                        original_daemon_pid_present: "false"},
                      command_output_format: "key=value newline-delimited UTF-8 in displayed order",
                      command_output_sha256: $command_output_sha256},
          completed_at_unix_ms: $completed_at_unix_ms}' >"$output_temp"
    [[ $(stat -c '%a' -- "$output_temp") == 600 ]] || die 'temporary evidence mode is not 0600'
    ln -- "$output_temp" "$evidence_output" || die 'evidence output appeared concurrently'
    rm -f -- "$output_temp"
    printf 'protocol-1.3 bootstrap evidence written: %s\n' "$evidence_output"
}

collect_evidence
