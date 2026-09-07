#!/usr/bin/env bash
# shellcheck disable=SC2016 # PowerShell variable names are intentional literals.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
producer="$script_dir/new-viewflow-quiesced-marker.ps1"
fixture="$script_dir/test-quiesced-marker.ps1"
producer_fixture="$script_dir/test-quiesced-marker-producer.ps1"

for path in "$producer" "$fixture" "$producer_fixture"; do
    test -f "$path"
done

require_fixed() {
    local needle=$1 path=${2:-$producer}
    grep -Fq -- "$needle" "$path" || {
        echo "missing required marker contract: $needle" >&2
        exit 1
    }
}

require_fixed '[string]$DaemonExitObservationPath'
require_fixed 'ViewflowMarker.StrictJson'
require_fixed 'new UTF8Encoding(false, true)'
require_fixed 'UTF-8 BOM is not allowed'
require_fixed 'duplicate object property:'
require_fixed 'case-colliding object property:'
require_fixed 'JSON nesting exceeds 128 levels'
require_fixed '[IO.FileShare]::Read'
require_fixed 'GetFileInformationByHandle'
require_fixed 'must have exactly one hard link'
require_fixed 'Assert-NoReparsePathComponents'
require_fixed 'Assert-OwnerOnlyFileSecurity'
require_fixed 'Open-PinnedJsonSnapshot $runtimeReceiptFullPath'
require_fixed 'Open-PinnedJsonSnapshot $exitEvidenceFullPath'
require_fixed 'Open-PinnedJsonSnapshot $exitObservationFullPath'
require_fixed 'Evidence files must not alias:'
require_fixed "'Runtime receipt changed after it was read'"
require_fixed "'Daemon-exit compact evidence changed after it was read'"
require_fixed "'Raw daemon-exit observation changed after it was read'"
require_fixed 'Set-OwnerOnlyFileSecurity $temporary'
require_fixed 'ConvertTo-Json -Depth 64'

require_fixed "schema_version -ne 4"
require_fixed "protocol_version -cne '2.1'"
require_fixed "lease_revoke.status -cne 'applied'"
require_fixed "'Runtime LeaseRevoke Applied ACK'"
require_fixed "'operation_id', 'lease_generation', 'owner_device'"
require_fixed "revokeAck.result -cne 'applied'"
require_fixed "peer_disconnect_status = 'confirmed_by_daemon_exit'"

require_fixed "'active_state', 'boot_id', 'command_outputs', 'daemon_instance_id'"
require_fixed "'runtime_receipt_sha256', 'schema_version', 'sidecar_socket_present', 'state'"
require_fixed "'command_outputs', 'daemon_identity', 'journal_query', 'observed_at_unix_ms'"
require_fixed "'boot_id', 'daemon_instance_id', 'daemon_pid', 'daemon_sha256'"
require_fixed "'entry_count', 'exit_realtime_us', 'first_realtime_us', 'last_realtime_us'"
require_fixed "'_BOOT_ID', '_PID', '_SYSTEMD_INVOCATION_ID'"
require_fixed "'exact_process_count', 'main_pid_zero', 'original_daemon_pid_present'"
require_fixed "'exact_process_pids', 'journal_entries', 'journal_json_sha256'"
require_fixed 'Assert-JsonDeepEqual $Observation.journal_query'
require_fixed 'Assert-JsonDeepEqual $Observation.command_outputs'
require_fixed '$Evidence.observation_sha256 -cne $ObservationSha'
require_fixed '$Evidence.observation_file_name -cne $ObservationName'
require_fixed '[long]$journal.exit_realtime_us -lt $completedMicros'
require_fixed '$commands.journal_entries.Count -ne [long]$journal.entry_count'
require_fixed '$revokeAck.operation_id.Substring(16, 16) -ceq ('"'"'0'"'"' * 16)'
require_fixed "Raw daemon-exit observation aliases artifact:"

if grep -Eq 'function Read-JsonObject|Get-Content.+(runtimeReceipt|exitEvidence|exitObservation)' "$producer"; then
    echo 'producer must parse all evidence from pinned byte snapshots' >&2
    exit 1
fi
if grep -Eq 'release_all_applied|route_revoked\s*=\s*\$true|transport_confirmed|protocol_version\s*=\s*'"'"'2\.0'"'"'' "$producer"; then
    echo 'producer must not accept or synthesize legacy cleanup assertions' >&2
    exit 1
fi

for fixture_case in \
    cleanup-history-boolean-string \
    cleanup-history-missing \
    activated-history-disguised-as-inactive \
    never-activated-disguised-as-active \
    activated-unbound-route-rejected \
    transport-only-revoke-rejected \
    revoke-ack-missing \
    revoke-ack-null \
    revoke-ack-operation \
    revoke-ack-generation \
    revoke-ack-owner \
    revoke-ack-target \
    revoke-ack-state \
    revoke-ack-result; do
    require_fixed "'$fixture_case'" "$fixture"
done

for producer_case in \
    valid-schema4-protocol21-active-route \
    receipt-top-missing compact-top-extra raw-top-case \
    cleanup-nested-missing cleanup-active-lease-generation-not-integer \
    cleanup-last-input-sequence-not-integer cleanup-bound-peer-epoch-not-integer \
    release-ack-nested-extra revoke-ack-nested-missing \
    revoke-ack-operation-low64-zero \
    compact-journal-nested-extra compact-query-nested-missing \
    compact-status-nested-extra compact-commands-nested-missing \
    raw-identity-nested-extra raw-query-nested-missing raw-commands-nested-extra \
    legacy-receipt-schema3 legacy-protocol20 legacy-transport-confirmed-revoke \
    receipt-duplicate-top compact-duplicate-top raw-duplicate-top \
    receipt-duplicate-nested raw-duplicate-object-in-array \
    receipt-escaped-equivalent-key raw-case-collision-key \
    receipt-multiple-documents receipt-top-array receipt-bom raw-invalid-utf8 \
    compact-comment compact-trailing-comma receipt-invalid-number \
    receipt-invalid-escape receipt-lone-surrogate receipt-depth-limit \
    receipt-sha-mismatch raw-sha-mismatch observation-basename-mismatch \
    compact-invocation-query-mismatch raw-query-mismatch raw-command-output-mismatch \
    journal-entry-count-mismatch journal-time-order-mismatch \
    journal-exit-before-completion exit-status-mismatch \
    hardlink-alias-candidate-raw raw-parent-junction-rejected \
    candidate-directory-junction-alias raw-junction-parent-swap; do
    require_fixed "'$producer_case'" "$producer_fixture"
done

require_fixed 'marker.schema_version -ne 4' "$producer_fixture"
require_fixed "marker.protocol_version -cne '2.1'" "$producer_fixture"
require_fixed '@($marker.daemon_exit_evidence.PSObject.Properties).Count -ne 23' "$producer_fixture"
require_fixed "New-Item -ItemType HardLink" "$producer_fixture"
require_fixed "New-Item -ItemType Junction" "$producer_fixture"
require_fixed 'Final raw pathname hash hook is not unique' "$producer_fixture"
require_fixed "'Raw daemon-exit observation changed after it was read'" "$producer_fixture"

echo 'Windows quiesced marker producer static checks passed'
