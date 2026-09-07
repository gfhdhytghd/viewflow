#!/usr/bin/env bash

# The two command-line entry points must reject an uppercase operation ID
# before accepting any artifact path.  This is intentionally a parser-level
# fixture: operation IDs name durable receipt namespaces and cannot be aliases.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly STAGE=$LINUX_DIR/bootstrap-stage-viewflow.sh
readonly FINALIZE=$LINUX_DIR/bootstrap-finalize-viewflow-deskflow.sh

fail() { printf 'bootstrap operation-id CLI fixture failed: %s\n' "$*" >&2; exit 1; }
readonly UPPER_OP=ABCDEF0123456789ABCDEF0123456789
readonly LOWER_ID=00000000000000000000000000000001
SHA=$(printf 'a%.0s' {1..64})
readonly SHA

expect_uppercase_rejected() {
    local name=$1 script=$2; shift 2
    local output status
    set +e
    output=$("$script" "$@" 2>&1)
    status=$?
    set -e
    ((status != 0)) || fail "$name accepted uppercase operation ID"
    grep -Fq -- '--operation-id must be exactly 32 lowercase hexadecimal characters' <<<"$output" ||
        fail "$name did not reject uppercase operation ID directly: $output"
}

expect_uppercase_rejected stage "$STAGE" query \
    --viewflow-candidate /tmp/viewflowd --viewflow-sha256 "$SHA" \
    --deployment-marker-candidate /tmp/viewflow-marker --deployment-marker-sha256 "$SHA" \
    --viewflow-unit-candidate /tmp/viewflow.service --viewflow-unit-sha256 "$SHA" \
    --operation-id "$UPPER_OP" --source-display-id "$LOWER_ID" --target-device-id "$LOWER_ID" \
    --coordinator-instance-id "$LOWER_ID" --marker-generation 1 \
    --bootstrap-linux-evidence /tmp/linux.json --bootstrap-handoff-receipt /tmp/handoff.json \
    --windows-bootstrap-request /tmp/request.json --windows-prepared-receipt /tmp/prepared.json \
    --windows-mutation-permit /tmp/permit.json --windows-force-release-envelope /tmp/force.json \
    --deployment-publish-receipt /tmp/publish.json --windows-viewflow-sha256 "$SHA" \
    --windows-user-sid S-1-5-21-1 --receipt-output /tmp/stage-receipt.json

expect_uppercase_rejected finalize "$FINALIZE" query \
    --viewflow-candidate /tmp/viewflowd --viewflow-sha256 "$SHA" \
    --deployment-marker-candidate /tmp/viewflow-marker --deployment-marker-sha256 "$SHA" \
    --viewflow-unit-candidate /tmp/viewflow.service --viewflow-unit-sha256 "$SHA" \
    --deskflow-candidate /tmp/deskflow --deskflow-sha256 "$SHA" \
    --deskflow-core-candidate /tmp/deskflow-core --deskflow-core-sha256 "$SHA" \
    --deskflow-dropin-candidate /tmp/viewflow.conf --deskflow-dropin-sha256 "$SHA" \
    --provenance /tmp/provenance.json --deskflow-provenance-sha256 "$SHA" \
    --stage-receipt /tmp/stage.json --bootstrap-linux-evidence /tmp/linux.json \
    --bootstrap-handoff-receipt /tmp/handoff.json --windows-bootstrap-request /tmp/request.json \
    --windows-prepared-receipt /tmp/prepared.json --windows-mutation-permit /tmp/permit.json \
    --windows-force-release-envelope /tmp/force.json --windows-install-receipt /tmp/windows.json \
    --deployment-publish-receipt /tmp/publish.json --operation-id "$UPPER_OP" \
    --source-display-id "$LOWER_ID" --target-device-id "$LOWER_ID" \
    --coordinator-instance-id "$LOWER_ID" --marker-generation 1 --windows-viewflow-sha256 "$SHA" \
    --windows-wrapper-sha256 "$SHA" --windows-task-xml-sha256 "$SHA" \
    --windows-user-sid S-1-5-21-1 --receipt-output /tmp/final-receipt.json

printf '%s\n' 'bootstrap operation-id CLI fixture tests passed'
