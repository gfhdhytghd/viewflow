#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329

# Exercise the production quarantine storage functions against a temporary
# filesystem. No service or installed path is touched.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly INSTALLER=$SCRIPT_DIR/../install-viewflow-deskflow.sh

fail() {
    printf 'quarantine storage fixture test failed: %s\n' "$*" >&2
    exit 1
}

# Production helpers report contract failures through die(). Terminate only the
# rejection subshell so a negative fixture can continue with the next case.
die() {
    printf 'expected quarantine storage rejection: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    local name=$1
    awk -v signature="$name() {" '
        $0 == signature { copying = 1 }
        copying { print }
        copying && $0 == "}" { exit }
    ' "$INSTALLER"
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -m 0700 -- "$tmp_dir/state"
EXPECTED_UID=$(id -u)
STAT_BIN=$(command -v stat)
readonly STAT_BIN
mock_parent_uid=
readonly DESKFLOW_QUARANTINE_PARENT=$tmp_dir/state/viewflow
readonly DESKFLOW_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_PARENT/deskflow-quarantine.v2
readonly DESKFLOW_QUARANTINE_MAGIC=VFQST002
readonly DEPLOYMENT_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_PARENT/deployment-quarantine.v1
readonly DEPLOYMENT_QUARANTINE_MAGIC=VFDQT001
quarantine_marker_preflight_identity=
quarantine_marker_preflight_sha=
deployment_quarantine_marker_preflight_identity=
deployment_quarantine_marker_preflight_sha=

stat() {
    if [[ -n $mock_parent_uid && ${1-} == -c && ${2-} == '%u %a' &&
          ${3-} == -- && ${4-} == "$DESKFLOW_QUARANTINE_PARENT" ]]; then
        printf '%s 700\n' "$mock_parent_uid"
        return 0
    fi
    command "$STAT_BIN" "$@"
}

eval "$(extract_function sha256)"
eval "$(extract_function assert_hash)"
eval "$(extract_function assert_quarantine_storage)"
eval "$(extract_function evidence_identity)"
eval "$(extract_function freeze_quarantine_storage)"
eval "$(extract_function assert_quarantine_storage_unchanged)"

expect_rejected() {
    local label=$1
    if (assert_quarantine_storage) >/dev/null 2>&1; then
        fail "accepted invalid storage: $label"
    fi
}

expect_unchanged_rejected() {
    local label=$1
    if (assert_quarantine_storage_unchanged) >/dev/null 2>&1; then
        fail "accepted changed quarantine storage: $label"
    fi
}

create_marker() {
    local path=$1 size=$2 magic=$3
    printf '%s' "$magic" >"$path"
    truncate -s "$size" "$path"
    chmod 0600 "$path"
}

restore_marker_contents() {
    local path=$1 size=$2 magic=$3
    printf '%s' "$magic" >"$path"
    truncate -s "$size" "$path"
}

exercise_frozen_marker() {
    local label=$1 path=$2 size=$3 magic=$4 replacement

    printf x | dd of="$path" bs=1 seek=8 conv=notrunc status=none
    expect_unchanged_rejected "$label same-inode content change"
    restore_marker_contents "$path" "$size" "$magic"
    assert_quarantine_storage_unchanged

    replacement=$tmp_dir/${label// /-}-replacement
    create_marker "$replacement" "$size" "$magic"
    mv -T -- "$replacement" "$path"
    expect_unchanged_rejected "$label same-content inode replacement"
    freeze_quarantine_storage
}

exercise_storage_marker() {
    local label=$1 path=$2 size=$3 magic=$4 hardlink=$5

    chmod 0640 "$path"
    expect_rejected "$label mode 0640"
    chmod 0600 "$path"

    truncate -s "$((size - 1))" "$path"
    expect_rejected "$label size $((size - 1))"
    restore_marker_contents "$path" "$size" "$magic"

    ln "$path" "$hardlink"
    expect_rejected "$label hard link count 2"
    rm -f -- "$hardlink"

    rm -f -- "$path"
    ln -s /dev/null "$path"
    expect_rejected "$label symlink"
    rm -f -- "$path"
    create_marker "$path" "$size" "$magic"

    rm -f -- "$path"
    expect_rejected "$label missing"
    create_marker "$path" "$size" "$magic"
}

mkdir -m 0700 -- "$DESKFLOW_QUARANTINE_PARENT"
[[ -d $DESKFLOW_QUARANTINE_PARENT && ! -L $DESKFLOW_QUARANTINE_PARENT ]] ||
    fail 'fixture did not create a real quarantine parent'
[[ $(stat -c '%u:%a' -- "$DESKFLOW_QUARANTINE_PARENT") == "$EXPECTED_UID:700" ]] ||
    fail 'fixture did not create exact owner/mode metadata'

expect_rejected 'both mandatory markers missing'

create_marker "$DESKFLOW_QUARANTINE_MARKER" 152 "$DESKFLOW_QUARANTINE_MAGIC"
expect_rejected 'deployment marker missing'
create_marker "$DEPLOYMENT_QUARANTINE_MARKER" 256 "$DEPLOYMENT_QUARANTINE_MAGIC"
assert_quarantine_storage

printf 'VFDQT001' | dd of="$DESKFLOW_QUARANTINE_MARKER" bs=1 conv=notrunc status=none
expect_rejected 'Deskflow marker with deployment magic'
restore_marker_contents "$DESKFLOW_QUARANTINE_MARKER" 152 "$DESKFLOW_QUARANTINE_MAGIC"
printf 'VFQST002' | dd of="$DEPLOYMENT_QUARANTINE_MARKER" bs=1 conv=notrunc status=none
expect_rejected 'deployment marker with runtime magic'
restore_marker_contents "$DEPLOYMENT_QUARANTINE_MARKER" 256 "$DEPLOYMENT_QUARANTINE_MAGIC"
assert_quarantine_storage

chmod 0750 "$DESKFLOW_QUARANTINE_PARENT"
expect_rejected 'parent mode 0750'
[[ $(stat -c '%a' -- "$DESKFLOW_QUARANTINE_PARENT") == 750 ]] ||
    fail 'storage validator changed an existing parent'
chmod 0700 "$DESKFLOW_QUARANTINE_PARENT"

mock_parent_uid=$((EXPECTED_UID + 1))
if (assert_quarantine_storage) >/dev/null 2>&1; then
    fail 'accepted parent owned by a different uid'
fi
mock_parent_uid=

freeze_quarantine_storage
assert_quarantine_storage_unchanged

exercise_frozen_marker 'Deskflow marker' "$DESKFLOW_QUARANTINE_MARKER" 152 \
    "$DESKFLOW_QUARANTINE_MAGIC"
exercise_frozen_marker 'deployment marker' "$DEPLOYMENT_QUARANTINE_MARKER" 256 \
    "$DEPLOYMENT_QUARANTINE_MAGIC"

exercise_storage_marker \
    'Deskflow marker' "$DESKFLOW_QUARANTINE_MARKER" 152 \
    "$DESKFLOW_QUARANTINE_MAGIC" "$tmp_dir/deskflow-hardlink"
exercise_storage_marker \
    'deployment marker' "$DEPLOYMENT_QUARANTINE_MARKER" 256 \
    "$DEPLOYMENT_QUARANTINE_MAGIC" "$tmp_dir/deployment-hardlink"

freeze_quarantine_storage
assert_quarantine_storage_unchanged

rm -f -- "$DESKFLOW_QUARANTINE_MARKER" "$DEPLOYMENT_QUARANTINE_MARKER"
rmdir "$DESKFLOW_QUARANTINE_PARENT"
ln -s "$tmp_dir" "$DESKFLOW_QUARANTINE_PARENT"
expect_rejected 'parent symlink'

printf 'quarantine storage fixture tests passed\n'
