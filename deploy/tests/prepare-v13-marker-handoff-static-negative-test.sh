#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail
readonly PATH=/usr/bin:/bin
export PATH

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deploy_dir=$(cd -- "$script_dir/.." && pwd)
readonly source_script=$deploy_dir/prepare-v13-marker-handoff.sh
readonly checker=$deploy_dir/check-prepare-v13-marker-handoff.sh

fail() { printf 'bootstrap marker handoff mutation test failed: %s\n' "$*" >&2; exit 1; }

test_root=$(mktemp -d)
chmod 0700 "$test_root"
trap 'rm -rf -- "$test_root"' EXIT

VIEWFLOW_SKIP_PREPARE_HANDOFF_SEMANTIC=1 "$checker" "$source_script" >/dev/null ||
    fail 'unmodified handoff helper did not pass'

expect_rejected() {
    local name=$1 candidate=$test_root/$1.sh
    shift
    cp -- "$source_script" "$candidate"
    "$@" "$candidate"
    if VIEWFLOW_SKIP_PREPARE_HANDOFF_SEMANTIC=1 "$checker" "$candidate" >/dev/null 2>&1; then
        fail "$name mutation was accepted"
    fi
}

change_fixed_marker_path() {
    sed -i 's|deployment-quarantine.v1|deployment-quarantine.override|' "$1"
}

allow_generation_two() {
    sed -i 's/readonly REQUIRED_MARKER_GENERATION=1/readonly REQUIRED_MARKER_GENERATION=2/' "$1"
}

remove_no_clobber() {
    sed -i 's/\[\[ ! -e \$DEPLOYMENT_MARKER && ! -L \$DEPLOYMENT_MARKER \]\]/true/' "$1"
}

publish_with_candidate_path() {
    sed -i 's/"\$MARKER_CLI" publish --operation-id/"$candidate" publish --operation-id/' "$1"
}

weaken_marker_metadata() {
    sed -i 's/1000:600:1:256/1000:600:1:0/' "$1"
}

remove_marker_hash_binding() {
    sed -i 's/$(sha256 "\$DEPLOYMENT_MARKER") == "\$marker_sha"/true/' "$1"
}

overwrite_receipt() {
    sed -i 's/ln -- "\$receipt_temp" "\$publish_receipt"/cp -- "$receipt_temp" "$publish_receipt"/' "$1"
}

remove_receipt_directory_sync() {
    sed -i 's/sync -f "$(dirname -- "\$publish_receipt")"/true # receipt directory sync removed/' "$1"
}

remove_candidate_freeze() {
    sed -i 's/\[\[ \$candidate_after == "\$candidate_before" && $(sha256 "\/proc\/\$\$\/fd\/\$candidate_fd") == "\$candidate_sha" \]\]/true/' "$1"
}

control_service() {
    sed -i '/install_and_verify_marker_cli/a systemctl --user stop deskflow.service' "$1"
}

delete_failed_receipt_staging() {
    sed -i 's/if \[\[ -e \$DEPLOYMENT_MARKER && ! -e \$publish_receipt \]\]; then/if false; then/' "$1"
}

weaken_legacy_inactive_gate() {
    sed -i 's/\$active_state == inactive/\$active_state != active/' "$1"
}

allow_runtime_marker() {
    sed -i 's/\[\[ ! -e \$RUNTIME_MARKER && ! -L \$RUNTIME_MARKER \]\]/true/' "$1"
}

allow_tcp_listener() {
    sed -i 's/\$core_count == 0 && \$listener_count == 0/\$core_count == 0 \&\& \$listener_count \< 2/' "$1"
}

overwrite_handoff_receipt() {
    sed -i 's/ln -- "\$handoff_temp" "\$handoff_receipt"/cp -- "$handoff_temp" "$handoff_receipt"/' "$1"
}

weaken_handoff_publish_binding() {
    sed -i 's/\.deployment_publish_receipt_sha256 == \$publish_sha/.deployment_publish_receipt_sha256 | test("^[0-9a-f]{64}$")/' "$1"
}

install_before_freeze() {
    local freeze_line install_line
    freeze_line=$(grep -nFx -- 'assert_legacy_deskflow_frozen' "$1" | head -n1 | cut -d: -f1)
    install_line=$(grep -nFx -- 'install_and_verify_marker_cli' "$1" | cut -d: -f1)
    sed -i "${freeze_line}s/assert_legacy_deskflow_frozen/install_and_verify_marker_cli/;${install_line}s/install_and_verify_marker_cli/assert_legacy_deskflow_frozen/" "$1"
}

expect_rejected fixed_marker_path change_fixed_marker_path
expect_rejected generation_two allow_generation_two
expect_rejected no_clobber remove_no_clobber
expect_rejected candidate_publish publish_with_candidate_path
expect_rejected marker_metadata weaken_marker_metadata
expect_rejected marker_hash remove_marker_hash_binding
expect_rejected overwrite_receipt overwrite_receipt
expect_rejected receipt_dir_sync remove_receipt_directory_sync
expect_rejected candidate_freeze remove_candidate_freeze
expect_rejected service_control control_service
expect_rejected failed_receipt_cleanup delete_failed_receipt_staging
expect_rejected legacy_inactive_gate weaken_legacy_inactive_gate
expect_rejected runtime_marker_absence allow_runtime_marker
expect_rejected tcp_listener_gate allow_tcp_listener
expect_rejected overwrite_handoff overwrite_handoff_receipt
expect_rejected handoff_publish_binding weaken_handoff_publish_binding
expect_rejected install_before_freeze install_before_freeze

printf 'bootstrap marker handoff static mutation tests passed\n'
