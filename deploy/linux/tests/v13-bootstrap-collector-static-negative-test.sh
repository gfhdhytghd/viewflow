#!/usr/bin/env bash
# shellcheck disable=SC2016

# Mutation tests for the static bootstrap collector contract. The collector is
# never executed, so this test cannot stop a service.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly COLLECTOR=$LINUX_DIR/collect-viewflow-v13-bootstrap-evidence.sh
readonly CHECKER=$LINUX_DIR/check-v13-bootstrap-collector.sh

fail() {
    printf 'v1.3 bootstrap static negative test failed: %s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

expect_rejected() {
    local name=$1 from=$2 to=$3 mutant
    mutant=$tmp_dir/$name.sh
    cp -- "$COLLECTOR" "$mutant"
    sed -i "s|$from|$to|" "$mutant"
    ! cmp -s "$COLLECTOR" "$mutant" || fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

"$CHECKER" "$COLLECTOR" >/dev/null
expect_rejected schema-version 'schema_version: 1' 'schema_version: 3'
expect_rejected state-name 'viewflow-v13-bootstrap-frozen' 'viewflow-input-quiesced'
expect_rejected pid-binding 'main_pid == "$daemon_pid"' 'main_pid != "$daemon_pid"'
expect_rejected daemon-hash 'daemon_sha == "$daemon_expected_sha"' 'daemon_sha != "$daemon_expected_sha"'
expect_rejected startup-count 'startup_count == 1' 'startup_count -ge 0'
expect_rejected lease-count "journal_count \"\$journal_file\" 'lease_offered='" \
    "journal_count \"\$journal_file\" 'lease_missing='"
expect_rejected input-count "journal_count \"\$journal_file\" 'input_event_sequence='" \
    "journal_count \"\$journal_file\" 'input_missing='"
expect_rejected activation-count "journal_count \"\$journal_file\" 'input sidecar activation'" \
    "journal_count \"\$journal_file\" 'activation missing'"
expect_rejected cleanup-count 'cleanup_or_release_error: $cleanup_release_error_count' \
    'cleanup_or_release_error: 0'
expect_rejected deskflow-processes '-z $deskflow_pids && -z $deskflow_core_pids' \
    '-n $deskflow_pids && -z $deskflow_core_pids'
expect_rejected old-pid-exit '! -e /proc/$expected_pid' '-e /proc/$expected_pid'
expect_rejected journal-hash 'journal_sha=$(sha256 "$journal_file")' 'journal_sha=unverified'
expect_rejected command-hash 'transcript_sha=$(sha256 "$transcript_file")' 'transcript_sha=unverified'
expect_rejected journal-boot-query '"_BOOT_ID=$journal_boot_id"' '"_BOOT_ID=$boot_id"'
expect_rejected zero-match-return '    return 0' '    : # removed zero-match success return'

printf 'protocol-1.3 bootstrap collector static negative tests passed\n'
