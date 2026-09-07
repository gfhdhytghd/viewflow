#!/usr/bin/env bash

# Offline fixtures for the standalone deactivation proof/transcript consumer.
# This test never invokes the deactivator or systemctl.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly CHECKER=$LINUX_DIR/check-deactivate-viewflow-deskflow.sh

fail() {
    printf 'Linux deactivation artifact fixture test failed: %s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
readonly sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
readonly base_dir=$tmp_dir/base
mkdir -m 0700 -- "$base_dir"
readonly base_transcript=$base_dir/transcript.txt
readonly base_proof=$base_dir/proof.json

printf '%s\n' \
    'deskflow_systemctl_is_active=inactive' \
    'runtime_marker_state=retained' \
    'deskflow_systemctl_main_pid=0' \
    'deskflow_exact_pids=' \
    'deskflow_core_exact_pids=' \
    'tcp_24800_listeners=' \
    'viewflow_systemctl_is_active=inactive' \
    'viewflow_systemctl_main_pid=0' \
    'viewflow_exact_pids=' \
    'deployment_marker_tool_exact_pids=' \
    'udp_44119_listeners=' \
    'sidecar_socket_present=false' \
    'daemon_reload_completed=true' \
    'viewflow_fragment_path=/home/wilf/.config/systemd/user/viewflow-peer.service' \
    'deskflow_dropin_paths=/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf' \
    "viewflow_sha256=$sha" \
    "deployment_marker_tool_sha256=$sha" \
    "deskflow_sha256=$sha" \
    "deskflow_core_sha256=$sha" \
    "viewflow_unit_sha256=$sha" \
    "deskflow_dropin_sha256=$sha" >"$base_transcript"
chmod 0600 -- "$base_transcript"
transcript_sha=$(sha256sum -- "$base_transcript" | awk '{print tolower($1)}')

jq -n --arg sha "$sha" --arg transcript_sha "$transcript_sha" \
    '{schema_version: 3, state: "viewflow-linux-deactivated",
      operation_id: "deactivate-fixture-0001",
      identity: {uid: 1000, home: "/home/wilf",
                 boot_id: "12345678-1234-1234-1234-123456789abc"},
      installed_artifacts: {
        viewflowd: {path: "/home/wilf/.local/lib/viewflow/viewflowd", sha256: $sha},
        deployment_marker_tool: {path: "/home/wilf/.local/lib/viewflow/viewflow-deployment-marker", sha256: $sha},
        deskflow: {path: "/home/wilf/.local/lib/deskflow-scale-fix/deskflow", sha256: $sha},
        deskflow_core: {path: "/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core", sha256: $sha},
        viewflow_unit: {path: "/home/wilf/.config/systemd/user/viewflow-peer.service", sha256: $sha},
        deskflow_dropin: {path: "/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf", sha256: $sha}},
      loaded_configuration: {
        daemon_reload_completed: true,
        viewflow_fragment_path: "/home/wilf/.config/systemd/user/viewflow-peer.service",
        deskflow_dropin_paths: "/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf"},
      stopped_runtime: {
        deployment_marker_tool: {exact_process_count: 0},
        deskflow: {unit_active_state: "inactive", main_pid: 0,
                   exact_process_count: 0, core_exact_process_count: 0,
                   tcp_24800_listener_count: 0},
        viewflow: {unit_active_state: "inactive", main_pid: 0,
                   exact_process_count: 0, udp_44119_listener_count: 0,
                   sidecar_socket_present: false}},
      observation: {
        command_output_format: "key=value newline-delimited UTF-8 in displayed order",
        command_output_file_name: "transcript.txt",
        command_output_sha256: $transcript_sha,
        completed_at_unix_ms: 1788012345678}}' >"$base_proof"
chmod 0600 -- "$base_proof"

"$CHECKER" --proof "$base_proof" --transcript "$base_transcript" >/dev/null ||
    fail 'valid artifact pair was rejected'

make_case() {
    local name=$1
    local directory=$tmp_dir/$name
    mkdir -m 0700 -- "$directory"
    cp -- "$base_proof" "$directory/proof.json"
    cp -- "$base_transcript" "$directory/transcript.txt"
    chmod 0600 -- "$directory/proof.json" "$directory/transcript.txt"
    printf '%s\n' "$directory"
}

expect_rejected() {
    local name=$1 directory=$2
    if "$CHECKER" --proof "$directory/proof.json" \
        --transcript "$directory/transcript.txt" >/dev/null 2>&1; then
        fail "invalid artifact pair was accepted: $name"
    fi
}

case_dir=$(make_case tampered-raw-bytes)
printf 'unexpected=content\n' >>"$case_dir/transcript.txt"
expect_rejected tampered-raw-bytes "$case_dir"

case_dir=$(make_case wrong-proof-hash)
jq '.observation.command_output_sha256 = ("0" * 64)' "$case_dir/proof.json" \
    >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected wrong-proof-hash "$case_dir"

case_dir=$(make_case wrong-basename)
jq '.observation.command_output_file_name = "other.txt"' "$case_dir/proof.json" \
    >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected wrong-basename "$case_dir"

case_dir=$(make_case semantic-transcript-mismatch)
sed -i 's/deskflow_systemctl_is_active=inactive/deskflow_systemctl_is_active=active/' \
    "$case_dir/transcript.txt"
changed_sha=$(sha256sum -- "$case_dir/transcript.txt" | awk '{print tolower($1)}')
jq --arg sha "$changed_sha" '.observation.command_output_sha256 = $sha' \
    "$case_dir/proof.json" >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected semantic-transcript-mismatch "$case_dir"

case_dir=$(make_case absent-runtime-marker-state)
sed -i 's/runtime_marker_state=retained/runtime_marker_state=absent/' \
    "$case_dir/transcript.txt"
changed_sha=$(sha256sum -- "$case_dir/transcript.txt" | awk '{print tolower($1)}')
jq --arg sha "$changed_sha" '.observation.command_output_sha256 = $sha' \
    "$case_dir/proof.json" >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
"$CHECKER" --proof "$case_dir/proof.json" \
    --transcript "$case_dir/transcript.txt" >/dev/null ||
    fail 'valid absent runtime marker state was rejected'

case_dir=$(make_case unknown-runtime-marker-state)
sed -i 's/runtime_marker_state=retained/runtime_marker_state=unknown/' \
    "$case_dir/transcript.txt"
changed_sha=$(sha256sum -- "$case_dir/transcript.txt" | awk '{print tolower($1)}')
jq --arg sha "$changed_sha" '.observation.command_output_sha256 = $sha' \
    "$case_dir/proof.json" >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected unknown-runtime-marker-state "$case_dir"

case_dir=$(make_case missing-runtime-marker-state)
sed -i '/^runtime_marker_state=/d' "$case_dir/transcript.txt"
changed_sha=$(sha256sum -- "$case_dir/transcript.txt" | awk '{print tolower($1)}')
jq --arg sha "$changed_sha" '.observation.command_output_sha256 = $sha' \
    "$case_dir/proof.json" >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected missing-runtime-marker-state "$case_dir"

case_dir=$(make_case duplicate-top-level-key)
sed -i '1s/{/{"schema_version":2,/' "$case_dir/proof.json"
expect_rejected duplicate-top-level-key "$case_dir"

case_dir=$(make_case duplicate-nested-key)
sed -i 's/"uid": 1000,/"uid": 1000, "uid": 1000,/' "$case_dir/proof.json"
expect_rejected duplicate-nested-key "$case_dir"

case_dir=$(make_case multiple-json-documents)
printf '{}\n' >>"$case_dir/proof.json"
expect_rejected multiple-json-documents "$case_dir"

case_dir=$(make_case top-level-array)
sed -i '1s/^/[/' "$case_dir/proof.json"
printf ']\n' >>"$case_dir/proof.json"
expect_rejected top-level-array "$case_dir"

case_dir=$(make_case invalid-utf8)
printf '\377\n' >>"$case_dir/proof.json"
expect_rejected invalid-utf8 "$case_dir"

case_dir=$(make_case extra-proof-key)
jq '.unexpected = true' "$case_dir/proof.json" >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected extra-proof-key "$case_dir"

case_dir=$(make_case deployment-marker-process-active)
jq '.stopped_runtime.deployment_marker_tool.exact_process_count = 1' \
    "$case_dir/proof.json" >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected deployment-marker-process-active "$case_dir"

case_dir=$(make_case deployment-marker-process-boolean)
jq '.stopped_runtime.deployment_marker_tool.exact_process_count = false' \
    "$case_dir/proof.json" >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected deployment-marker-process-boolean "$case_dir"

case_dir=$(make_case deployment-marker-path-wrong)
jq '.installed_artifacts.deployment_marker_tool.path = "/tmp/viewflow-deployment-marker"' \
    "$case_dir/proof.json" >"$case_dir/proof.new"
mv -fT -- "$case_dir/proof.new" "$case_dir/proof.json"
chmod 0600 -- "$case_dir/proof.json"
expect_rejected deployment-marker-path-wrong "$case_dir"

case_dir=$(make_case wrong-mode)
chmod 0644 -- "$case_dir/transcript.txt"
expect_rejected wrong-mode "$case_dir"

case_dir=$(make_case symlink-transcript)
mv -- "$case_dir/transcript.txt" "$case_dir/transcript.real"
ln -s -- transcript.real "$case_dir/transcript.txt"
expect_rejected symlink-transcript "$case_dir"

printf 'standalone Linux deactivation artifact fixture tests passed\n'
