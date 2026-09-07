#!/usr/bin/env bash
# shellcheck disable=SC2016

# Mutation tests only; the collector itself is never executed.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly COLLECTOR=$LINUX_DIR/collect-viewflow-daemon-exit-evidence.sh
readonly CHECKER=$LINUX_DIR/check-daemon-exit-evidence-collector.sh

fail() {
    printf 'daemon exit collector static negative test failed: %s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

expect_rejected() {
    local name=$1 from=$2 to=$3 mutant
    mutant=$tmp_dir/$name.sh
    cp -- "$COLLECTOR" "$mutant"
    MUTATE_FROM=$from MUTATE_TO=$to perl -0pi -e \
        's/\Q$ENV{MUTATE_FROM}\E/$ENV{MUTATE_TO}/' "$mutant"
    ! cmp -s "$COLLECTOR" "$mutant" || fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

"$CHECKER" "$COLLECTOR" >/dev/null
expect_rejected receipt-schema '(.schema_version == 4)' '(.schema_version == 3)'
expect_rejected receipt-state 'viewflow-input-quiesced' 'viewflow-v13-bootstrap-frozen'
expect_rejected operation-binding '(.operation_id == $operation_id)' '(.operation_id != $operation_id)'
expect_rejected protocol-binding '(.protocol_version == "2.1")' '(.protocol_version == "2.0")'
expect_rejected revoke-evidence-fields \
    '(.cleanup.lease_revoke | keys == ["ack", "generation", "status"])' \
    '(.cleanup.lease_revoke | keys == ["generation", "status"])'
expect_rejected revoke-applied '.cleanup.lease_revoke.status == "applied"' \
    '.cleanup.lease_revoke.status == "transport_confirmed"'
expect_rejected revoke-operation \
    '.cleanup.lease_revoke.ack.operation_id != "00000000000000000000000000000000"' \
    '(.cleanup.lease_revoke.ack.operation_id | type == "string")'
expect_rejected revoke-peer-epoch \
    '[[ ${revoke_operation_id:0:16} == "$(printf '"'"'%016x'"'"' "$bound_peer_epoch")" ]]' \
    '[[ -n $revoke_operation_id ]]'
expect_rejected revoke-operation-nonce \
    '[[ ${revoke_operation_id:16:16} != 0000000000000000 ]]' \
    '[[ ${#revoke_operation_id} == 32 ]]'
expect_rejected revoke-generation \
    '.cleanup.lease_revoke.ack.lease_generation == .cleanup.lease_revoke.generation' \
    '(.cleanup.lease_revoke.ack.lease_generation | uint53)'
expect_rejected revoke-owner '.cleanup.lease_revoke.ack.owner_device == $local_device' \
    '(.cleanup.lease_revoke.ack.owner_device | type == "string")'
expect_rejected revoke-target '.cleanup.lease_revoke.ack.target_device == $target' \
    '(.cleanup.lease_revoke.ack.target_device | type == "string")'
expect_rejected revoke-state '.cleanup.lease_revoke.ack.state == "revoked"' \
    '(.cleanup.lease_revoke.ack.state | type == "string")'
expect_rejected revoke-result '.cleanup.lease_revoke.ack.result == "applied"' \
    '(.cleanup.lease_revoke.ack.result | type == "string")'
expect_rejected inactive-revoke-ack '.cleanup.lease_revoke.ack == null' 'true'
expect_rejected route-source-display '.cleanup.source_display == $source_display' \
    '(.cleanup.source_display | type == "string")'
expect_rejected route-generation '(.cleanup.route_generation | uint53 and . > 0)' \
    '(.cleanup.route_generation | uint53)'
expect_rejected daemon-hash '(.daemon_sha256 == $daemon_sha)' \
    '((.daemon_sha256 | ascii_downcase) == $daemon_sha)'
expect_rejected artifact-hash '(.artifact_hashes.linux_viewflowd == $daemon_sha)' \
    '((.artifact_hashes.linux_viewflowd | ascii_downcase) == $daemon_sha)'
expect_rejected certificate-hash '(.artifact_hashes.linux_peer_certificate | sha256)' \
    '(.artifact_hashes.linux_peer_certificate | type == "string")'
expect_rejected private-key-hash '(.artifact_hashes.linux_peer_private_key | sha256)' \
    '(.artifact_hashes.linux_peer_private_key | type == "string")'
expect_rejected ca-hash '(.artifact_hashes.linux_certificate_authority | sha256)' \
    '(.artifact_hashes.linux_certificate_authority | type == "string")'
expect_rejected invocation-format '[[ $invocation_id =~ ^[0-9a-f]{32}$ ]]' \
    '[[ -n $invocation_id ]]'
expect_rejected startup-count '[[ $startup_count == 1 && $exit_count == 1 ]]' \
    '[[ $startup_count -ge 0 && $exit_count -ge 0 ]]'
expect_rejected stopped-state '[[ $active_state == inactive && $main_pid == 0 ]]' \
    '[[ -n $active_state ]]'
expect_rejected pid-absence '[[ ! -e /proc/$daemon_pid ]]' '[[ -e /proc/$daemon_pid ]]'
expect_rejected teardown-counts \
    'exact_process_count == 0 && $udp_listener_count == 0 && $socket_present == false' \
    'exact_process_count -ge 0 && $udp_listener_count -ge 0 && -n $socket_present'
expect_rejected receipt-race '[[ $receipt_sha_after == "$receipt_sha" ]]' \
    '[[ -n $receipt_sha_after ]]'
expect_rejected strict-json 'validate_strict_json_document "$path"' ': "$path"'
expect_rejected unique-invocation 'if length == 1 then .[0]' 'if length >= 1 then .[0]'
expect_rejected observation-hash 'observation_sha=$(sha256 "$observation_temp")' \
    'observation_sha=unverified'
expect_rejected observation-no-clobber 'ln -- "$observation_temp" "$observation_output"' \
    'cp -- "$observation_temp" "$observation_output"'
expect_rejected evidence-no-clobber 'ln -- "$evidence_temp" "$evidence_output"' \
    'cp -- "$evidence_temp" "$evidence_output"'

printf 'normal daemon exit collector static negative tests passed\n'
