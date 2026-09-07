#!/usr/bin/env bash
# Static companion for the crash-resumable P/H publication protocol.

set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly source_script=${1:-$script_dir/prepare-v13-marker-handoff.sh}
readonly fixture=$script_dir/tests/prepare-v13-marker-handoff-resume-hermetic-test.sh

fail() { printf 'prepare handoff resumability check failed: %s\n' "$*" >&2; exit 1; }
need() { grep -Fq -- "$1" "$snapshot" || fail "missing $2"; }
one() {
    local count
    count=$(grep -Fxc -- "$1" "$snapshot" || true)
    [[ $count == 1 ]] || fail "$2 count is $count, expected 1"
}

[[ -f $source_script && ! -L $source_script ]] || fail 'unsafe source helper'
snapshot_dir=$(mktemp -d)
chmod 0700 "$snapshot_dir"
trap 'rm -rf -- "$snapshot_dir"' EXIT
snapshot=$snapshot_dir/prepare.sh
before=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$source_script")
before_sha=$(sha256sum -- "$source_script" | awk '{print $1}')
cp -- "$source_script" "$snapshot"
chmod 0600 "$snapshot"
[[ $(stat -Lc '%d:%i:%s:%Y:%Z' -- "$source_script") == "$before" &&
   $(sha256sum -- "$source_script" | awk '{print $1}') == "$before_sha" ]] || fail 'source changed while snapshotted'

bash -n "$snapshot"
if command -v shellcheck >/dev/null; then shellcheck --severity=error "$snapshot"; fi

for name in intent_key require_owner_output_or_absent write_create_once_json \
    marker_hex_range assert_active_marker_identity marker_created_at_utc validate_handoff_intent \
    publish_handoff_intent publish_reconstructed_receipt ensure_published_receipt; do
    one "$name() {" "single $name definition"
done

need 'handoff_intent="$MARKER_STATE_DIR/.prepare-v13-marker-handoff.$(intent_key).intent.json"' 'deterministic intent path'
need 'handoff_intent_temp=$(mktemp --tmpdir="$MARKER_STATE_DIR"' 'fresh intent staging inode'
need 'active VFDQT001 has no matching durable bootstrap handoff intent' 'marker-only ambiguity rejection'
need 'validate_handoff_intent "$handoff_intent"' 'intent identity validation'
need 'keys == ["candidate_sha256","coordinator_instance_id","deployment_marker_path","handoff_receipt_path","marker_generation","operation_id","publish_receipt_path","schema_version","source_display_id","target_device_id"]' 'exact internal intent schema'
need '.operation_id == $op and .source_display_id == $source and' 'intent operation/source binding'
need '.target_device_id == $target and .coordinator_instance_id == $coordinator and' 'intent target/coordinator binding'
need '.marker_generation == $generation and .candidate_sha256 == $candidate and' 'intent generation/candidate binding'
need '.deployment_marker_path == $marker and .publish_receipt_path == $publish and' 'intent marker/P path binding'
need '.handoff_receipt_path == $handoff' 'intent H path binding'

need '[[ $metadata == 1000:600:1:256 ]] || die' 'exact marker metadata gate'
need '[[ ${header:0:26} == 56464451543030310101020101 && ${header:28:4} == 0000 ]]' 'marker header gate'
need '[[ $operation_bytes == "$operation_id" ]]' 'marker operation binding'
need 'VFDQT001 source/target/coordinator identity differs from this handoff' 'marker topology identity gate'
need '[[ $generation_hex == 0100000000000000 ]]' 'marker generation bytes gate'
need '[[ $reserved =~ ^0+$ ]]' 'marker reserved-byte gate'
need "[[ \$before == \"\$after\" ]] || die 'VFDQT001 inode changed while validating identity'" 'stable marker inode gate'
marker_identity_calls=$(grep -Fxc -- '    assert_active_marker_identity' "$snapshot" || true)
(( marker_identity_calls >= 2 )) || fail 'active-marker identity validation is not required on both replay paths'

need 'exec {fd}<"$temp"' 'opened staging descriptor'
need "before=\$(stat -Lc '%d:%i:%s:%Y' -- \"/proc/\$\$/fd/\$fd\")" 'descriptor inode identity'
need 'mv -T -n -- "$temp" "$output"' 'atomic no-replace final publication'
need 'output inode differs from the opened staging inode' 'dentry-swap detection'
need 'sync -f "$output"' 'output durability sync'
need 'sync -f "$(dirname -- "$output")"' 'parent durability sync'
need 'retained P staging evidence' 'P temp retention after interruption'
need 'retained H staging evidence' 'H temp retention after interruption'
need 'retained intent staging evidence' 'intent temp retention after interruption'
need 'publish_reconstructed_receipt' 'marker-to-P reconstruction'
need 'ensure_published_receipt' 'P replay helper'
one '    publish_reconstructed_receipt' 'single marker-to-P reconstruction call'

intent_line=$(grep -nFx -- '    publish_handoff_intent' "$snapshot" | head -n1 | cut -d: -f1)
publish_line=$(grep -nF -- '"$MARKER_CLI" publish --operation-id "$operation_id"' "$snapshot" | tail -n1 | cut -d: -f1)
[[ $intent_line =~ ^[0-9]+$ && $publish_line =~ ^[0-9]+$ && $intent_line -lt $publish_line ]] ||
    fail 'intent is not durably published before marker creation'
first_marker_identity_line=$(awk -v start="$publish_line" 'NR > start && $0 == "    assert_active_marker_identity" { print NR; exit }' "$snapshot")
first_publish_validation_line=$(awk -v start="$publish_line" 'NR > start && $0 == "    validate_publish_staging" { print NR; exit }' "$snapshot")
[[ $first_marker_identity_line =~ ^[0-9]+$ && $first_publish_validation_line =~ ^[0-9]+$ &&
   $publish_line -lt $first_marker_identity_line && $first_marker_identity_line -lt $first_publish_validation_line ]] ||
    fail 'newly published VFDQT001 is not fully decoded before P publication'

[[ $(stat -Lc '%d:%i:%s:%Y:%Z' -- "$source_script") == "$before" &&
   $(sha256sum -- "$source_script" | awk '{print $1}') == "$before_sha" ]] || fail 'source changed during audit'
if [[ ${VIEWFLOW_SKIP_PREPARE_HANDOFF_RESUME_FIXTURE:-0} != 1 ]]; then
    "$fixture" "$source_script" >/dev/null
fi
printf 'prepare marker handoff resumability check passed\n'
