#!/usr/bin/env bash

# Offline durable consume-intent subset/replay fixture. No service state changes.

# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
# shellcheck source=../bootstrap-two-phase-common.sh
source "$SCRIPT_DIR/../bootstrap-two-phase-common.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
chmod 0700 "$tmp_dir"
helper=$tmp_dir/consume-functions.sh
awk '/^restore_consumed_evidence\(\) \{/{copy=1} /^validate_consume_intent\(\) \{/{copy=0} copy{print}' \
    "$SCRIPT_DIR/../bootstrap-finalize-viewflow-deskflow.sh" >"$helper"
awk '/^validate_consume_intent\(\) \{/{copy=1} /^find_core_pid\(\) \{/{copy=0} copy{print}' \
    "$SCRIPT_DIR/../bootstrap-finalize-viewflow-deskflow.sh" >>"$helper"
grep -Fq 'validate_all_consumed() {' "$helper" || die 'consume helper extraction failed'
# shellcheck source=/dev/null
source "$helper"

operation_id=bootstrap-consume-fixture
stage_receipt=$tmp_dir/stage.json
printf '%s\n' '{"stage":1}' >"$stage_receipt"
chmod 0600 "$stage_receipt"
backup_dir=${stage_receipt}.backup
consumed_dir=$backup_dir/consumed
consume_intent=$backup_dir/consume-intent.json
linux_evidence=$tmp_dir/linux.json
force_envelope=$tmp_dir/force.json
windows_install_receipt=$tmp_dir/windows.json
consumed_linux=$consumed_dir/viewflow-v13-bootstrap-frozen.json
consumed_force=$consumed_dir/viewflow-force-release-envelope.json
consumed_windows=$consumed_dir/viewflow-v2-windows-installed.json
mkdir -m 0700 "$backup_dir"
for path in "$linux_evidence" "$force_envelope" "$windows_install_receipt"; do
    printf '{"path":"%s"}\n' "$path" >"$path"
    chmod 0600 "$path"
done

create_or_validate_consume_intent
intent_sha=$(sha256 "$consume_intent")
create_or_validate_consume_intent
[[ $(sha256 "$consume_intent") == "$intent_sha" ]] || die 'exact intent replay changed bytes'

originals=("$linux_evidence" "$force_envelope" "$windows_install_receipt")
consumed=("$consumed_linux" "$consumed_force" "$consumed_windows")
for mask in 0 1 2 3 4 5 6 7; do
    mkdir -p "$consumed_dir"
    chmod 0700 "$consumed_dir"
    for index in 0 1 2; do
        if (((mask >> index) & 1)); then
            [[ -e ${consumed[$index]} ]] || mv -- "${originals[$index]}" "${consumed[$index]}"
        else
            [[ -e ${originals[$index]} ]] || mv -- "${consumed[$index]}" "${originals[$index]}"
        fi
    done
    validate_consumption_subset
done

# Missing, duplicate-path, and byte-substitution states must fail closed.
mv -- "$consumed_windows" "$tmp_dir/held-windows"
if (validate_consumption_subset >/dev/null 2>&1); then die 'missing subset artifact accepted'; fi
mv -- "$tmp_dir/held-windows" "$consumed_windows"
cp -- "$consumed_force" "$force_envelope"
chmod 0600 "$force_envelope"
if (validate_consumption_subset >/dev/null 2>&1); then die 'artifact at both exact paths accepted'; fi
rm -f -- "$force_envelope"
cp -- "$consumed_linux" "$tmp_dir/good-linux"
printf '%s\n' '{"substituted":true}' >"$consumed_linux"
chmod 0600 "$consumed_linux"
if (validate_consumption_subset >/dev/null 2>&1); then die 'artifact byte substitution accepted'; fi
mv -- "$tmp_dir/good-linux" "$consumed_linux"

complete_evidence_consumption
validate_all_consumed
restore_consumed_evidence
for path in "${originals[@]}"; do [[ -f $path ]] || die "restore omitted $path"; done
validate_consumption_subset

printf '%s\n' 'bootstrap consume-intent subset fixture tests passed'
