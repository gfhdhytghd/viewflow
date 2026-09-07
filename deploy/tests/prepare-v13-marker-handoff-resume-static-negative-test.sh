#!/usr/bin/env bash

set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deploy_dir=$(cd -- "$script_dir/.." && pwd)
readonly source_script=$deploy_dir/prepare-v13-marker-handoff.sh
readonly checker=$deploy_dir/check-prepare-v13-marker-handoff-resume.sh

fail() { printf 'prepare handoff resumability mutation test failed: %s\n' "$*" >&2; exit 1; }
root=$(mktemp -d)
chmod 0700 "$root"
trap 'rm -rf -- "$root"' EXIT

VIEWFLOW_SKIP_PREPARE_HANDOFF_RESUME_FIXTURE=1 "$checker" "$source_script" >/dev/null ||
    fail 'unmodified helper did not pass resumability checker'

expect_rejected() {
    local name=$1 candidate=$root/$1.sh
    shift
    cp -- "$source_script" "$candidate"
    "$@" "$candidate"
    if VIEWFLOW_SKIP_PREPARE_HANDOFF_RESUME_FIXTURE=1 "$checker" "$candidate" >/dev/null 2>&1; then
        fail "$name mutation was accepted"
    fi
}

drop_intent_before_marker() {
    sed -i '0,/^    publish_handoff_intent$/s//    : # intent omitted/' "$1"
}
drop_marker_identity() {
    sed -i 's/^    assert_active_marker_identity$/    : # identity omitted/' "$1"
}
drop_marker_generation_bytes() {
    sed -i 's/\[\[ \$generation_hex == 0100000000000000 \]\]/true/' "$1"
}
overwrite_final_output() {
    sed -i 's/mv -T -n -- "\$temp" "\$output"/cp -- "\$temp" "\$output"/' "$1"
}
drop_open_inode_check() {
    sed -i 's/output inode differs from the opened staging inode/output inode identity bypassed/' "$1"
}
allow_marker_without_intent() {
    sed -i "s/die 'active VFDQT001 has no matching durable bootstrap handoff intent'/: # permit ambiguous marker/" "$1"
}
drop_reconstruction() {
    sed -i 's/^    publish_reconstructed_receipt$/    : # no P reconstruction/' "$1"
}
drop_initial_marker_decode() {
    local line
    line=$(grep -nFx -- '    assert_active_marker_identity' "$1" | sed -n '2p' | cut -d: -f1)
    [[ $line =~ ^[0-9]+$ ]]
    sed -i "${line}s/assert_active_marker_identity/: # first-publish decode omitted/" "$1"
}
weaken_intent_topology() {
    sed -i 's/\.target_device_id == \$target and \.coordinator_instance_id == \$coordinator and/true and/' "$1"
}

expect_rejected intent_before_marker drop_intent_before_marker
expect_rejected marker_identity drop_marker_identity
expect_rejected marker_generation_bytes drop_marker_generation_bytes
expect_rejected final_noclobber overwrite_final_output
expect_rejected opened_inode_check drop_open_inode_check
expect_rejected marker_without_intent allow_marker_without_intent
expect_rejected reconstruction drop_reconstruction
expect_rejected initial_marker_decode drop_initial_marker_decode
expect_rejected intent_topology weaken_intent_topology

printf 'prepare marker handoff resumability static mutation tests passed\n'
