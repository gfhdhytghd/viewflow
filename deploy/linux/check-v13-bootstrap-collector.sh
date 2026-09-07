#!/usr/bin/env bash
# shellcheck disable=SC2016

# Static-only contract audit for the one-time protocol-1.3 evidence producer.
# An optional path is accepted solely for the mutation tests below.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly COLLECTOR=${1:-$SCRIPT_DIR/collect-viewflow-v13-bootstrap-evidence.sh}

fail() {
    printf 'v1.3 bootstrap collector static check failed: %s\n' "$*" >&2
    exit 1
}

require_fixed() {
    grep -Fq -- "$1" "$COLLECTOR" || fail "missing $2"
}

require_regex() {
    grep -Eq -- "$1" "$COLLECTOR" || fail "missing $2"
}

require_exact_pid_helper_return() {
    awk '
        $0 == "exact_executable_pids() {" { inside=1; next }
        inside && $0 == "    return 0" { found=1 }
        inside && $0 == "proc_start_ticks() {" { boundary=1; exit }
        END { exit !(inside && found && boundary) }
    ' "$COLLECTOR" || fail 'zero-match-safe exact executable PID helper'
}

[[ -f $COLLECTOR ]] || fail "collector not found: $COLLECTOR"
bash -n "$COLLECTOR"

require_fixed "'{schema_version: 1, state: \$state, operation_id: \$operation_id," \
    'dedicated schema-1 output'
require_fixed "--arg state 'viewflow-v13-bootstrap-frozen'" 'dedicated bootstrap state'
require_fixed '--operation-id' 'operation binding'
require_fixed '[[ $main_pid == "$daemon_pid" ]]' 'exact systemd MainPID binding'
require_fixed '[[ $exact_pids == "$daemon_pid" ]]' 'single exact executable PID binding'
require_exact_pid_helper_return
require_fixed 'start_ticks=$(proc_start_ticks "$daemon_pid")' 'process start-ticks evidence'
require_fixed "boot_id=\$(tr -d '\\r\\n' </proc/sys/kernel/random/boot_id)" 'boot ID evidence'
require_fixed 'daemon_sha=$(sha256 "/proc/$daemon_pid/exe")' 'running executable hash evidence'
require_fixed '[[ $daemon_sha == "$daemon_expected_sha" ]]' 'operator-provided hash binding'
require_fixed 'invocation_id=$(unit_property "$VIEWFLOW_UNIT" InvocationID)' \
    'systemd invocation identity'
require_fixed '._SYSTEMD_INVOCATION_ID == $invocation' 'exclusive invocation journal validation'
require_fixed '._PID == $pid and ._BOOT_ID == $boot_id' 'journal PID and boot binding'
require_fixed 'journal_boot_id=${boot_id//-/}' 'journal boot ID normalization'
require_fixed '"_BOOT_ID=$journal_boot_id"' 'normalized journal boot ID query'
require_fixed '--arg boot_id "$journal_boot_id"' 'normalized journal boot ID comparison'
require_fixed 'query_boot_id: $journal_boot_id' 'normalized journal boot ID publication'
require_fixed 'daemon identity changed between capture and stop boundary' 'pre-stop identity bracket'
require_fixed "'^viewflowd protocol 1\\.3 serving mTLS QUIC on 0\\.0\\.0\\.0:44119; Deskflow unchanged\$'" \
    'exact protocol-1.3 startup line'
require_fixed "journal_count \"\$journal_file\" 'lease_offered='" 'lease-offer count'
require_fixed "journal_count \"\$journal_file\" 'input_event_sequence='" 'input-event count'
require_fixed "journal_count \"\$journal_file\" 'input sidecar activation'" \
    'input-sidecar activation count'
require_fixed 'startup_count == 1' 'single startup-line gate'
require_fixed 'lease_offered: $lease_offered_count' 'lease count publication'
require_fixed 'input_event: $input_event_count' 'input count publication'
require_fixed 'input_sidecar_activation: $sidecar_activation_count' 'activation count publication'
require_fixed 'cleanup_or_release_error: $cleanup_release_error_count' 'error count publication'
if grep -Eq '(lease_offered_count|input_event_count|sidecar_activation_count|cleanup_release_error_count)[[:space:]]*==[[:space:]]*0' \
    "$COLLECTOR"; then
    fail 'activity counts must be recorded, not used as a false remote-release gate'
fi
if grep -Fq '"_BOOT_ID=$boot_id"' "$COLLECTOR"; then
    fail 'hyphenated /proc boot ID is used directly in a journal query'
fi

require_fixed 'deskflow_state == inactive' 'Deskflow inactive gate'
require_fixed 'deskflow_main_pid:-0} == 0' 'Deskflow MainPID zero gate'
require_fixed '-z $deskflow_pids && -z $deskflow_core_pids' 'Deskflow exact-process zero gate'
require_fixed '-z $deskflow_tcp_output' 'Deskflow listener zero gate'

require_fixed 'systemctl --user stop "$VIEWFLOW_UNIT"' 'old daemon graceful stop'
require_fixed 'state == inactive && ${main_pid:-0} == 0' 'Viewflow inactive/MainPID zero gate'
require_fixed '! -e /proc/$expected_pid' 'exact original PID exit gate'
require_fixed '-z $exact_pids && -z $udp_output && ! -e $VIEWFLOW_SIDECAR' \
    'process/listener/socket absence gate'
require_fixed 'capture_invocation_journal "$invocation_id" "$daemon_pid" "$boot_id" "$journal_file"' \
    'post-stop terminal journal recapture'
require_fixed 'journal_start_cursor' 'journal start cursor evidence'
require_fixed 'journal_start_us' 'journal start timestamp evidence'
require_fixed 'journal_end_cursor' 'terminal journal cursor evidence'
require_fixed 'journal_sha=$(sha256 "$journal_file")' 'raw journal output hash'
require_fixed 'transcript_sha=$(sha256 "$transcript_file")' 'post-stop command-output hash'
require_fixed 'ln -- "$output_temp" "$evidence_output"' 'atomic no-clobber publication'
require_fixed '[[ $(stat -c ' '0600 evidence mode gate'

stop_line=$(grep -nF 'systemctl --user stop "$VIEWFLOW_UNIT"' "$COLLECTOR" | cut -d: -f1)
final_journal_line=$(grep -nF 'capture_invocation_journal "$invocation_id" "$daemon_pid" "$boot_id" "$journal_file"' \
    "$COLLECTOR" | tail -1 | cut -d: -f1)
publish_line=$(grep -nF 'ln -- "$output_temp" "$evidence_output"' "$COLLECTOR" | cut -d: -f1)
[[ $stop_line =~ ^[0-9]+$ && $final_journal_line =~ ^[0-9]+$ &&
   $publish_line =~ ^[0-9]+$ && $stop_line -lt $final_journal_line &&
   $final_journal_line -lt $publish_line ]] || fail 'stop/journal/publication phases are out of order'

if grep -Fq 'schema_version: 3' "$COLLECTOR" ||
   grep -Fq 'viewflow-input-quiesced' "$COLLECTOR"; then
    fail 'schema-3 receipt semantics leaked into the bootstrap collector'
fi
if grep -Eq 'kill[[:space:]]+-9|pkill|killall|systemctl[[:space:]]+--user[[:space:]]+(start|restart)' \
    "$COLLECTOR"; then
    fail 'collector contains force-kill or service-start behavior'
fi

printf 'protocol-1.3 bootstrap collector static checks passed\n'
