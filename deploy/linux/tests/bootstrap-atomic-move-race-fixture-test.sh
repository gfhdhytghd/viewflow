#!/usr/bin/env bash

# Offline no-replace move and competing-destination race fixture.

# shellcheck disable=SC1091
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
source "$SCRIPT_DIR/../bootstrap-two-phase-common.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
chmod 0700 "$tmp_dir"
original_dir=$tmp_dir/original
consumed_dir=$tmp_dir/consumed
mkdir -m 0700 "$original_dir" "$consumed_dir"

make_receipt() {
    printf '{"value":"%s"}\n' "$2" >"$1"
    chmod 0600 "$1"
}

source_path=$original_dir/success.json
destination=$consumed_dir/success.json
make_receipt "$source_path" source
expected=$(sha256 "$source_path")
before=$(stat -c '%d:%i:%u:%a:%h' "$source_path")
atomic_move_no_replace 'success fixture' "$source_path" "$destination" "$expected"
[[ ! -e $source_path && $(sha256 "$destination") == "$expected" &&
   $(stat -c '%d:%i:%u:%a:%h' "$destination") == "$before" ]] ||
    die 'successful no-replace move did not preserve exact identity'

source_path=$original_dir/preexisting.json
destination=$consumed_dir/preexisting.json
make_receipt "$source_path" source
make_receipt "$destination" competitor
source_sha=$(sha256 "$source_path")
destination_sha=$(sha256 "$destination")
if (atomic_move_no_replace 'preexisting fixture' "$source_path" "$destination" "$source_sha" >/dev/null 2>&1); then
    die 'preexisting destination was overwritten'
fi
[[ -f $source_path && $(sha256 "$source_path") == "$source_sha" &&
   $(sha256 "$destination") == "$destination_sha" ]] ||
    die 'preexisting destination rejection mutated an artifact'

for iteration in $(seq 1 24); do
    source_path=$original_dir/race-$iteration.json
    competitor=$original_dir/competitor-$iteration.json
    destination=$consumed_dir/race-$iteration.json
    make_receipt "$source_path" "source-$iteration"
    make_receipt "$competitor" "competitor-$iteration"
    source_sha=$(sha256 "$source_path")
    competitor_sha=$(sha256 "$competitor")
    ln -- "$competitor" "$destination" 2>/dev/null &
    racer=$!
    move_ok=0
    if atomic_move_no_replace "race fixture $iteration" "$source_path" "$destination" "$source_sha" \
        >/dev/null 2>&1; then
        move_ok=1
    fi
    wait "$racer" 2>/dev/null || true
    if ((move_ok)); then
        [[ ! -e $source_path && $(sha256 "$destination") == "$source_sha" ]] ||
            die "move winner was overwritten in race $iteration"
    else
        [[ -f $source_path && $(sha256 "$source_path") == "$source_sha" &&
           $(sha256 "$destination") == "$competitor_sha" ]] ||
            die "destination winner or source changed in race $iteration"
    fi
done

printf '%s\n' 'bootstrap atomic no-replace move race fixture tests passed'
