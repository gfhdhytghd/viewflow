#!/usr/bin/env bash
# shellcheck disable=SC2016

# Static-only audit for the normal protocol-2.1 daemon-exit producer.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly COLLECTOR=${1:-$SCRIPT_DIR/collect-viewflow-daemon-exit-evidence.sh}

fail() {
    printf 'daemon exit collector static check failed: %s\n' "$*" >&2
    exit 1
}

require_fixed() {
    grep -Fq -- "$1" "$COLLECTOR" || fail "missing $2"
}

[[ -f $COLLECTOR ]] || fail "collector not found: $COLLECTOR"
bash -n "$COLLECTOR"

require_fixed '--runtime-receipt' 'runtime receipt input'
require_fixed '--observation-output' 'raw observation sidecar output'
require_fixed '--evidence-output' 'consumer evidence output'
require_fixed '(keys == ["artifact_hashes", "boot_id", "cleanup", "completed_at_unix_ms",' \
    'exact schema-4 receipt field set'
require_fixed '(.schema_version == 4)' 'schema-4 receipt gate'
require_fixed '(.state == "viewflow-input-quiesced")' 'normal receipt state gate'
require_fixed '(.operation_id == $operation_id)' 'operation binding'
require_fixed '(.protocol_version == "2.1")' 'exact protocol-2.1 binding'
require_fixed '(.cleanup.release_all | keys == ["ack", "status"])' \
    'exact ReleaseAll evidence fields'
require_fixed '(.cleanup.lease_revoke | keys == ["ack", "generation", "status"])' \
    'exact lease revoke evidence fields'
require_fixed '.cleanup.release_all.status == "applied"' 'ReleaseAll Applied result'
require_fixed '.cleanup.lease_revoke.status == "applied"' 'lease revoke Applied result'
require_fixed '.cleanup.lease_revoke.ack.operation_id' 'revoke ACK operation identity'
require_fixed '.cleanup.lease_revoke.ack.operation_id != "00000000000000000000000000000000"' \
    'revoke ACK nonzero operation identity'
require_fixed '[[ ${revoke_operation_id:0:16} == "$(printf '"'"'%016x'"'"' "$bound_peer_epoch")" ]]' \
    'revoke ACK peer epoch binding'
require_fixed '[[ ${revoke_operation_id:16:16} != 0000000000000000 ]]' \
    'revoke ACK nonzero operation nonce'
require_fixed '.cleanup.lease_revoke.ack.lease_generation == .cleanup.lease_revoke.generation' \
    'revoke ACK generation binding'
require_fixed '.cleanup.lease_revoke.ack.owner_device == $local_device' \
    'revoke ACK owner binding'
require_fixed '.cleanup.lease_revoke.ack.target_device == $target' \
    'revoke ACK target binding'
require_fixed '.cleanup.lease_revoke.ack.state == "revoked"' 'revoke ACK state'
require_fixed '.cleanup.lease_revoke.ack.result == "applied"' 'revoke ACK result'
require_fixed '.cleanup.lease_revoke.ack == null' 'inactive cleanup has no revoke ACK'
require_fixed '.cleanup.source_display == $source_display' 'source display identity'
require_fixed '(.cleanup.route_generation | uint53 and . > 0)' 'route generation identity'
require_fixed '(.daemon_instance_id == ((.boot_id)' 'receipt instance identity correlation'
require_fixed 'def sha256: type == "string" and test("^[0-9a-f]{64}$");' \
    'lowercase SHA-256 predicate'
require_fixed '(.daemon_sha256 | sha256)' 'receipt daemon lowercase hash gate'
require_fixed '(.daemon_sha256 == $daemon_sha)' 'receipt daemon hash binding'
require_fixed '(.artifact_hashes.linux_viewflowd | sha256)' \
    'receipt artifact lowercase hash gate'
require_fixed '(.artifact_hashes.linux_viewflowd == $daemon_sha)' \
    'receipt artifact hash binding'
require_fixed '(.artifact_hashes | keys == ["linux_certificate_authority",' \
    'exact receipt artifact hash field set'
require_fixed '(.artifact_hashes.linux_peer_certificate | sha256)' \
    'receipt certificate lowercase hash gate'
require_fixed '(.artifact_hashes.linux_peer_private_key | sha256)' \
    'receipt private-key lowercase hash gate'
require_fixed '(.artifact_hashes.linux_certificate_authority | sha256)' \
    'receipt CA lowercase hash gate'
require_fixed 'receipt_sha=$(sha256 "$runtime_receipt")' 'runtime receipt byte hash'
require_fixed '[[ $receipt_sha_after == "$receipt_sha" ]]' 'runtime receipt race bracket'
require_fixed 'validate_strict_json_document "$path"' 'single duplicate-free receipt parser'
require_fixed 'raise ValueError(f"duplicate JSON key: {key}")' 'duplicate-key rejection'
require_fixed 'if text[end:].strip():' 'trailing JSON document rejection'
require_fixed 'discover_invocation_from_pid_boot "$daemon_pid" "$journal_boot_id"' \
    'PID/boot journal invocation discovery'
require_fixed '"_PID=$daemon_pid" "_BOOT_ID=$journal_boot_id"' \
    'PID/boot discovery query'
require_fixed 'if length == 1 then .[0]' 'unique qualifying invocation gate'
require_fixed '[[ $invocation_id =~ ^[0-9a-f]{32}$ ]]' '32-hex InvocationID gate'
require_fixed '[[ -z $unit_invocation_property || $unit_invocation_property == "$invocation_id" ]]' \
    'optional remaining unit property correlation'
require_fixed 'capture_exact_journal "$invocation_id" "$daemon_pid" "$journal_boot_id"' \
    'journal invocation/PID/boot capture'
require_fixed '._SYSTEMD_INVOCATION_ID == $invocation' 'journal invocation validation'
require_fixed '._PID == $pid and ._BOOT_ID == $boot_id' 'journal PID/boot validation'
require_fixed '[[ $startup_count == 1 && $exit_count == 1 ]]' 'exact terminal message counts'
require_fixed 'viewflowd protocol 2.1 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged' \
    'exact protocol-2.1 startup message'
require_fixed 'viewflowd deployment quiescence receipt written; daemon exiting' \
    'exact normal exit message'
require_fixed '[[ $active_state == inactive && $main_pid == 0 ]]' 'inactive/MainPID zero proof'
require_fixed '[[ ! -e /proc/$daemon_pid ]]' 'original PID absence proof'
require_fixed 'exact_process_count == 0 && $udp_listener_count == 0 && $socket_present == false' \
    'process/listener/socket teardown proof'
require_fixed "--arg state 'viewflow-daemon-exit-observation'" 'raw sidecar schema namespace'
require_fixed "--arg state 'viewflow-daemon-exited'" 'exit evidence schema namespace'
require_fixed 'journal_entries: $journal_entries' 'embedded raw journal output'
require_fixed '--slurpfile journal_entries "$journal_file"' 'bounded raw journal loading'
require_fixed 'observation_sha=$(sha256 "$observation_temp")' 'raw observation byte hash'
require_fixed 'observation_sha256: $observation_sha256' 'observation hash publication'
require_fixed 'runtime_receipt_sha256: $runtime_receipt_sha256' 'receipt hash publication'
require_fixed 'ln -- "$observation_temp" "$observation_output"' 'no-clobber sidecar publication'
require_fixed 'ln -- "$evidence_temp" "$evidence_output"' 'no-clobber evidence publication'
require_fixed 'EXPECTED_UID:600' 'owner-only published mode gate'

observation_line=$(grep -nF 'ln -- "$observation_temp" "$observation_output"' "$COLLECTOR" | cut -d: -f1)
evidence_line=$(grep -nF 'ln -- "$evidence_temp" "$evidence_output"' "$COLLECTOR" | cut -d: -f1)
[[ $observation_line =~ ^[0-9]+$ && $evidence_line =~ ^[0-9]+$ &&
   $observation_line -lt $evidence_line ]] || fail 'sidecar/evidence publication order is invalid'

if grep -Eq 'systemctl[[:space:]]+--user[[:space:]]+(start|stop|restart)|kill[[:space:]]|pkill|killall' \
    "$COLLECTOR"; then
    fail 'collector contains a live service/process mutation'
fi
if grep -Fq 'viewflow-v13-bootstrap' "$COLLECTOR"; then
    fail 'bootstrap schema leaked into the normal exit producer'
fi
if grep -Fq 'ascii_downcase' "$COLLECTOR"; then
    fail 'collector normalizes evidence hashes instead of requiring lowercase originals'
fi

printf 'normal daemon exit collector static checks passed\n'
