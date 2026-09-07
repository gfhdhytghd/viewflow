#!/usr/bin/env bash

# Deterministically place a competing receipt after the intent resolver has
# selected its source path.  Both consume and restore must fail closed and
# preserve the competitor; this catches a resolver -> plain mv TOCTOU.

# shellcheck disable=SC1091,SC2034,SC2329
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly COMMON="$LINUX_DIR/bootstrap-two-phase-common.sh"
readonly FINALIZER="$LINUX_DIR/bootstrap-finalize-viewflow-deskflow.sh"

fail() { printf 'bootstrap evidence-consumption race fixture failed: %s\n' "$*" >&2; exit 1; }

extract_function() {
    local name=$1 output=$2
    awk -v signature="$name() {" '$0 == signature {copy=1} copy {print} copy && /^}$/ {exit}' \
        "$FINALIZER" >"$output"
    grep -Fqx -- "$name() {" "$output" || fail "missing finalizer function: $name"
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
chmod 0700 "$tmp_dir"

# shellcheck source=/dev/null
source "$COMMON"
extract_function complete_evidence_consumption "$tmp_dir/complete.sh"
extract_function restore_consumed_evidence "$tmp_dir/restore.sh"
# shellcheck source=/dev/null
source "$tmp_dir/complete.sh"
# shellcheck source=/dev/null
source "$tmp_dir/restore.sh"

make_receipt() {
    printf '{"receipt":"%s"}\n' "$2" >"$1"
    chmod 0600 "$1"
}

write_intent() {
    local state=$1
    jq -cn --arg linux_original "$linux_evidence" --arg linux_consumed "$consumed_linux" \
        --arg force_original "$force_envelope" --arg force_consumed "$consumed_force" \
        --arg windows_original "$windows_install_receipt" --arg windows_consumed "$consumed_windows" \
        --arg linux_sha "$(sha256 "$linux_evidence" 2>/dev/null || sha256 "$consumed_linux")" \
        --arg force_sha "$(sha256 "$force_envelope" 2>/dev/null || sha256 "$consumed_force")" \
        --arg windows_sha "$(sha256 "$windows_install_receipt" 2>/dev/null || sha256 "$consumed_windows")" \
        --arg state "$state" '
        {schema_version:1,state:$state,operation_id:"00000000000000000000000000000001",
         stage_receipt_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         created_at_unix_ms:1,
         artifacts:{linux_frozen_evidence:{original_path:$linux_original,consumed_path:$linux_consumed,sha256:$linux_sha},
                    windows_force_release_envelope:{original_path:$force_original,consumed_path:$force_consumed,sha256:$force_sha},
                    windows_install_receipt:{original_path:$windows_original,consumed_path:$windows_consumed,sha256:$windows_sha}}}' \
        >"$consume_intent"
    chmod 0600 "$consume_intent"
}

setup_paths() {
    local root=$1
    mkdir -m 0700 "$root"
    mkdir -m 0700 "$root/original" "$root/consumed"
    linux_evidence=$root/original/linux.json
    force_envelope=$root/original/force.json
    windows_install_receipt=$root/original/windows.json
    consumed_dir=$root/consumed
    consumed_linux=$consumed_dir/linux.json
    consumed_force=$consumed_dir/force.json
    consumed_windows=$consumed_dir/windows.json
    consume_intent=$root/consume-intent.json
}

# This mock injects a same-filesystem competing destination immediately after
# the resolver has picked the source.  File creation in a command-substitution
# subshell persists, so the following move observes the exact race.
inject_name=''
inject_destination=''
competitor=''
injected=0
validate_consume_intent() { :; }
resolve_intent_artifact() {
    local name=$1 current
    if [[ $name == linux_frozen_evidence ]]; then
        current=$(jq -er '.artifacts.linux_frozen_evidence.original_path' "$consume_intent")
    else
        current=$(jq -er --arg name "$name" '.artifacts[$name].original_path' "$consume_intent")
    fi
    if [[ $name == "$inject_name" && $injected == 0 ]]; then
        ln -- "$competitor" "$inject_destination"
        injected=1
    fi
    printf '%s\n' "$current"
}

setup_paths "$tmp_dir/consume"
make_receipt "$linux_evidence" source
make_receipt "$force_envelope" force
make_receipt "$windows_install_receipt" windows
write_intent viewflow-linux-bootstrap-consume-intent
competitor=$tmp_dir/consume/competitor.json
make_receipt "$competitor" competitor
source_sha=$(sha256 "$linux_evidence")
competitor_sha=$(sha256 "$competitor")
inject_name=linux_frozen_evidence
inject_destination=$consumed_linux
injected=0
if (complete_evidence_consumption >/dev/null 2>&1); then
    fail 'consume accepted a destination created after resolution'
fi
[[ -f $linux_evidence && $(sha256 "$linux_evidence") == "$source_sha" &&
   -f $consumed_linux && $(sha256 "$consumed_linux") == "$competitor_sha" ]] ||
    fail 'consume race overwrote or removed an artifact'

setup_paths "$tmp_dir/restore"
mkdir -p "$consumed_dir"
make_receipt "$consumed_linux" source
make_receipt "$consumed_force" force
make_receipt "$consumed_windows" windows
# write_intent hashes the consumed paths when originals are absent.
write_intent viewflow-linux-bootstrap-consume-intent
competitor=$tmp_dir/restore/competitor.json
make_receipt "$competitor" competitor
source_sha=$(sha256 "$consumed_linux")
competitor_sha=$(sha256 "$competitor")
inject_name=linux_frozen_evidence
inject_destination=$linux_evidence
injected=0

# Restore's resolver reports the consumed path.  Keep the injection timing
# identical to the consume case while making its expected source explicit.
resolve_intent_artifact() {
    local name=$1 current
    current=$(jq -er --arg name "$name" '.artifacts[$name].consumed_path' "$consume_intent")
    if [[ $name == "$inject_name" && $injected == 0 ]]; then
        ln -- "$competitor" "$inject_destination"
        injected=1
    fi
    printf '%s\n' "$current"
}
if (restore_consumed_evidence >/dev/null 2>&1); then
    fail 'restore accepted a destination created after resolution'
fi
[[ -f $consumed_linux && $(sha256 "$consumed_linux") == "$source_sha" &&
   -f $linux_evidence && $(sha256 "$linux_evidence") == "$competitor_sha" ]] ||
    fail 'restore race overwrote or removed an artifact'

printf '%s\n' 'bootstrap evidence-consumption deterministic race fixture tests passed'
