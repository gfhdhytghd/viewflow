#!/usr/bin/env bash

# Data fixtures for the normal receipt/exit-evidence lowercase SHA-256 contract.

set -euo pipefail

fail() {
    printf 'normal evidence lowercase SHA fixture test failed: %s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

readonly BASELINE=$tmp_dir/baseline.json
readonly MUTANT=$tmp_dir/mutant.json
DAEMON_SHA=$(printf 'a%.0s' {1..64})
RECEIPT_SHA=$(printf 'b%.0s' {1..64})
OBSERVATION_SHA=$(printf 'c%.0s' {1..64})
JOURNAL_SHA=$(printf 'd%.0s' {1..64})
CERT_SHA=$(printf 'e%.0s' {1..64})
KEY_SHA=$(printf 'f%.0s' {1..64})
CA_SHA=$(printf 'c%.0s' {1..64})
readonly DAEMON_SHA RECEIPT_SHA OBSERVATION_SHA JOURNAL_SHA CERT_SHA KEY_SHA CA_SHA

jq -n \
    --arg daemon "$DAEMON_SHA" \
    --arg receipt "$RECEIPT_SHA" \
    --arg observation "$OBSERVATION_SHA" \
    --arg journal "$JOURNAL_SHA" \
    --arg cert "$CERT_SHA" \
    --arg key "$KEY_SHA" \
    --arg ca "$CA_SHA" \
    '{
      receipt: {
        daemon_sha256: $daemon,
        artifact_hashes: {
          linux_viewflowd: $daemon,
          linux_peer_certificate: $cert,
          linux_peer_private_key: $key,
          linux_certificate_authority: $ca
        }
      },
      evidence: {
        runtime_receipt_sha256: $receipt,
        observation_sha256: $observation,
        daemon_sha256: $daemon,
        journal: {slice_sha256: $journal},
        command_outputs: {journal_json_sha256: $journal}
      },
      observation: {
        runtime_receipt_sha256: $receipt,
        daemon_identity: {daemon_sha256: $daemon},
        command_outputs: {journal_json_sha256: $journal}
      }
    }' >"$BASELINE"

validate_fixture() {
    jq -e \
        --arg daemon "$DAEMON_SHA" \
        --arg receipt "$RECEIPT_SHA" \
        --arg observation "$OBSERVATION_SHA" \
        'def sha256: type == "string" and test("^[0-9a-f]{64}$");
         (.receipt.daemon_sha256 | sha256) and
         (.receipt.daemon_sha256 == $daemon) and
         (.receipt.artifact_hashes.linux_viewflowd | sha256) and
         (.receipt.artifact_hashes.linux_viewflowd == $daemon) and
         (.receipt.artifact_hashes.linux_peer_certificate | sha256) and
         (.receipt.artifact_hashes.linux_peer_private_key | sha256) and
         (.receipt.artifact_hashes.linux_certificate_authority | sha256) and
         (.evidence.runtime_receipt_sha256 | sha256) and
         (.evidence.runtime_receipt_sha256 == $receipt) and
         (.evidence.observation_sha256 | sha256) and
         (.evidence.observation_sha256 == $observation) and
         (.evidence.daemon_sha256 | sha256) and
         (.evidence.daemon_sha256 == .receipt.daemon_sha256) and
         (.evidence.journal.slice_sha256 | sha256) and
         (.evidence.command_outputs.journal_json_sha256 | sha256) and
         (.evidence.command_outputs.journal_json_sha256 ==
             .evidence.journal.slice_sha256) and
         (.observation.runtime_receipt_sha256 | sha256) and
         (.observation.runtime_receipt_sha256 == $receipt) and
         (.observation.daemon_identity.daemon_sha256 | sha256) and
         (.observation.daemon_identity.daemon_sha256 == .evidence.daemon_sha256) and
         (.observation.command_outputs.journal_json_sha256 | sha256) and
         (.observation.command_outputs.journal_json_sha256 ==
             .evidence.command_outputs.journal_json_sha256)' \
        "$1" >/dev/null
}

expect_rejected() {
    local name=$1 mutation=$2
    jq "$mutation" "$BASELINE" >"$MUTANT"
    if validate_fixture "$MUTANT"; then
        fail "uppercase SHA mutation was accepted: $name"
    fi
}

validate_fixture "$BASELINE" || fail 'valid lowercase fixture was rejected'

expect_rejected receipt-daemon '.receipt.daemon_sha256 |= ascii_upcase'
expect_rejected receipt-viewflow-artifact \
    '.receipt.artifact_hashes.linux_viewflowd |= ascii_upcase'
expect_rejected receipt-certificate-artifact \
    '.receipt.artifact_hashes.linux_peer_certificate |= ascii_upcase'
expect_rejected receipt-private-key-artifact \
    '.receipt.artifact_hashes.linux_peer_private_key |= ascii_upcase'
expect_rejected receipt-ca-artifact \
    '.receipt.artifact_hashes.linux_certificate_authority |= ascii_upcase'
expect_rejected evidence-receipt '.evidence.runtime_receipt_sha256 |= ascii_upcase'
expect_rejected evidence-observation '.evidence.observation_sha256 |= ascii_upcase'
expect_rejected evidence-daemon '.evidence.daemon_sha256 |= ascii_upcase'
expect_rejected evidence-journal '.evidence.journal.slice_sha256 |= ascii_upcase'
expect_rejected evidence-command-journal \
    '.evidence.command_outputs.journal_json_sha256 |= ascii_upcase'
expect_rejected observation-receipt \
    '.observation.runtime_receipt_sha256 |= ascii_upcase'
expect_rejected observation-daemon \
    '.observation.daemon_identity.daemon_sha256 |= ascii_upcase'
expect_rejected observation-command-journal \
    '.observation.command_outputs.journal_json_sha256 |= ascii_upcase'

printf 'normal evidence lowercase SHA fixture tests passed\n'
