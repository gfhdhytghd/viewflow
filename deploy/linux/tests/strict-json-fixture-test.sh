#!/usr/bin/env bash
# shellcheck disable=SC1090

# Exercise the installer's strict JSON parser without sourcing or running the
# installer. Only the side-effect-free parser function is extracted.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly INSTALLER=$LINUX_DIR/install-viewflow-deskflow.sh

fail() {
    printf 'strict JSON fixture test failed: %s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

readonly HELPER=$tmp_dir/strict-json-helper.sh
awk '
    /^assert_strict_json_document\(\) \{$/ { copying = 1 }
    copying { print }
    copying && /^}$/ { exit }
' "$INSTALLER" >"$HELPER"

grep -Fq 'assert_strict_json_document() {' "$HELPER" ||
    fail 'could not extract assert_strict_json_document'
bash -n "$HELPER"
source "$HELPER"

expect_accepted() {
    local name=$1 path=$2
    if ! assert_strict_json_document "$name" "$path" >/dev/null 2>&1; then
        fail "valid fixture was rejected: $name"
    fi
}

expect_rejected() {
    local name=$1 path=$2
    if assert_strict_json_document "$name" "$path" >/dev/null 2>&1; then
        fail "invalid fixture was accepted: $name"
    fi
}

printf '%s\n' '{"outer":{"inner":1},"items":[true,false,null]}' >"$tmp_dir/valid.json"
printf '%s\n' '{"key":1,"key":2}' >"$tmp_dir/duplicate-top-level.json"
printf '%s\n' '{"nested":{"key":1,"key":2}}' >"$tmp_dir/duplicate-nested.json"
printf '%s\n' '{} {}' >"$tmp_dir/multiple-documents.json"
printf '%s\n' '[{"key":1}]' >"$tmp_dir/top-level-array.json"
printf '{"key":"\377"}\n' >"$tmp_dir/invalid-utf8.json"

expect_accepted valid-object "$tmp_dir/valid.json"
expect_rejected duplicate-top-level-key "$tmp_dir/duplicate-top-level.json"
expect_rejected duplicate-nested-key "$tmp_dir/duplicate-nested.json"
expect_rejected multiple-json-documents "$tmp_dir/multiple-documents.json"
expect_rejected top-level-array "$tmp_dir/top-level-array.json"
expect_rejected invalid-utf8 "$tmp_dir/invalid-utf8.json"

printf 'strict JSON fixture tests passed\n'
