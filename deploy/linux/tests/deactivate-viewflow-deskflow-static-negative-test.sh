#!/usr/bin/env bash
# shellcheck disable=SC2016

# Source-mutation and isolated path-rewritten runtime negatives for the
# standalone Linux deactivation contract. The installed/live paths are never
# used by a runtime fixture.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly DEACTIVATOR=$LINUX_DIR/deactivate-viewflow-deskflow.sh
readonly CHECKER=$LINUX_DIR/check-deactivate-viewflow-deskflow.sh

fail() {
    printf 'Linux deactivation static negative test failed: %s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

expect_rejected() {
    local name=$1 from=$2 to=$3 mutant
    mutant=$tmp_dir/$name.sh
    awk -v from="$from" -v to="$to" '
        {
            line = $0
            result = ""
            while ((position = index(line, from)) != 0) {
                result = result substr(line, 1, position - 1) to
                line = substr(line, position + length(from))
                replaced = 1
            }
            print result line
        }
        END { if (!replaced) exit 42 }
    ' "$DEACTIVATOR" >"$mutant" || fail "mutation target missing: $name"
    ! cmp -s "$DEACTIVATOR" "$mutant" || fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

expect_rejected_after_anchor() {
    local name=$1 anchor=$2 from=$3 to=$4 mutant
    mutant=$tmp_dir/$name.sh
    awk -v anchor="$anchor" -v from="$from" -v to="$to" '
        {
            line = $0
            if (armed && (position = index(line, from)) != 0) {
                line = substr(line, 1, position - 1) to \
                    substr(line, position + length(from))
                replaced = 1
                armed = 0
            }
            if (index($0, anchor) != 0) armed = 1
            print line
        }
        END { if (!replaced) exit 42 }
    ' "$DEACTIVATOR" >"$mutant" || fail "mutation target missing: $name"
    ! cmp -s "$DEACTIVATOR" "$mutant" || fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

expect_cli_rejected() {
    local name=$1 expected=$2 output
    shift 2
    if output=$("$DEACTIVATOR" "$@" 2>&1); then
        fail "deactivator accepted invalid CLI: $name"
    fi
    grep -Fq -- "$expected" <<<"$output" ||
        fail "deactivator returned the wrong CLI error: $name"
}

"$CHECKER" "$DEACTIVATOR" >/dev/null
expect_cli_rejected runtime-marker-state-missing-value \
    '--runtime-marker-state requires a value' --runtime-marker-state
expect_cli_rejected runtime-marker-state-unknown \
    '--runtime-marker-state must be retained or absent' \
    --runtime-marker-state unknown
expect_cli_rejected legacy-config-duplicate \
    '--bootstrap-v1.3-legacy-config may be supplied only once' \
    --bootstrap-v1.3-legacy-config --bootstrap-v1.3-legacy-config
expect_rejected runtime-marker-state-default \
    'runtime_marker_state=retained' 'runtime_marker_state=absent'
expect_rejected runtime-marker-state-enum \
    'retained|absent)' 'retained|absent|unknown)'
expect_rejected legacy-config-flag \
    '--bootstrap-v1.3-legacy-config' '--bootstrap-v13-legacy-config'
expect_rejected legacy-config-runtime-marker-gate \
    '[[ $runtime_marker_state == absent ]] ||' '[[ true ]] ||'
expect_rejected legacy-config-dropin-line-count \
    '$(wc -l <"$path") == 5' '$(wc -l <"$path") -ge 5'
expect_rejected legacy-config-dropin-route \
    'LEGACY_V13_DROPIN_ROUTE=' 'LEGACY_V13_DROPIN_ROUTE=ignored'
expect_rejected legacy-config-unit-execstart \
    'LEGACY_V13_VIEWFLOW_EXECSTART=' 'LEGACY_V13_VIEWFLOW_EXECSTART=ignored'
expect_rejected legacy-config-v2-option-rejection \
    "for option in --quiesce-proof --quiesce-arm-file --acceptance-socket \\" \
    'for option in --quiesce-proof --quiesce-arm-file; do'
expect_rejected deployment-marker-tool-fixed-path \
    'readonly DEPLOYMENT_MARKER_TOOL_INSTALLED=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker' \
    'readonly DEPLOYMENT_MARKER_TOOL_INSTALLED=/tmp/viewflow-deployment-marker'
expect_rejected deployment-marker-tool-sha-option \
    '--deployment-marker-sha256' '--ignored-deployment-marker-sha256'
expect_rejected deployment-marker-tool-hash \
    "assert_hash 'installed deployment marker tool'" \
    ': # removed deployment marker tool hash validation'
expect_rejected deployment-marker-tool-metadata \
    "stat -c '%u:%a:%h' -- \"\$DEPLOYMENT_MARKER_TOOL_INSTALLED\"" \
    "stat -c '%u:%a' -- \"\$DEPLOYMENT_MARKER_TOOL_INSTALLED\""
expect_rejected deployment-marker-tool-process-gate \
    'exact_executable_pids "$DEPLOYMENT_MARKER_TOOL_INSTALLED"' \
    'exact_executable_pids /tmp/unrelated'
expect_rejected deployment-marker-tool-illegal-lifecycle \
    'assert_deployment_marker_tool_stopped' \
    '"$DEPLOYMENT_MARKER_TOOL_INSTALLED" release'
expect_rejected quarantine-fixed-parent \
    'readonly DESKFLOW_QUARANTINE_PARENT=/home/wilf/.local/state/viewflow' \
    'readonly DESKFLOW_QUARANTINE_PARENT=/tmp'
expect_rejected quarantine-fixed-marker \
    'readonly DESKFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    'readonly DESKFLOW_QUARANTINE_MARKER=/tmp/deskflow-quarantine.v2'
expect_rejected quarantine-runtime-size \
    'readonly DESKFLOW_QUARANTINE_SIZE=152' \
    'readonly DESKFLOW_QUARANTINE_SIZE=151'
expect_rejected quarantine-runtime-magic \
    'readonly DESKFLOW_QUARANTINE_MAGIC=VFQST002' \
    'readonly DESKFLOW_QUARANTINE_MAGIC=VFDQT001'
expect_rejected quarantine-fixed-environment \
    'readonly DESKFLOW_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    'readonly DESKFLOW_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/tmp/deskflow-quarantine.v2'
expect_rejected deployment-quarantine-fixed-marker \
    'readonly DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' \
    'readonly DEPLOYMENT_QUARANTINE_MARKER=/tmp/deployment-quarantine.v1'
expect_rejected deployment-quarantine-size \
    'readonly DEPLOYMENT_QUARANTINE_SIZE=256' \
    'readonly DEPLOYMENT_QUARANTINE_SIZE=255'
expect_rejected deployment-quarantine-magic \
    'readonly DEPLOYMENT_QUARANTINE_MAGIC=VFDQT001' \
    'readonly DEPLOYMENT_QUARANTINE_MAGIC=VFQST002'
expect_rejected deployment-quarantine-fixed-environment \
    'readonly DEPLOYMENT_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' \
    'readonly DEPLOYMENT_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/tmp/deployment-quarantine.v1'
expect_rejected quarantine-parent-symlink \
    '[[ -d $DESKFLOW_QUARANTINE_PARENT && ! -L $DESKFLOW_QUARANTINE_PARENT ]]' \
    '[[ -d $DESKFLOW_QUARANTINE_PARENT ]]'
expect_rejected quarantine-parent-mode \
    '[[ $parent_owner == "$EXPECTED_UID" && $parent_mode == 700 ]]' \
    '[[ $parent_owner == "$EXPECTED_UID" && $parent_mode == 770 ]]'
expect_rejected quarantine-parent-owner \
    '[[ $parent_owner == "$EXPECTED_UID" && $parent_mode == 700 ]]' \
    '[[ -n $parent_owner && $parent_mode == 700 ]]'
expect_rejected quarantine-dangling-symlink \
    '[[ -e $path || -L $path ]]' \
    '[[ -e $path ]]'
expect_rejected quarantine-marker-regular \
    '[[ -f $path && ! -L $path ]]' \
    '[[ -e $path ]]'
expect_rejected quarantine-marker-mode \
    '[[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 600 &&' \
    '[[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 640 &&'
expect_rejected quarantine-marker-owner \
    '[[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 600 &&' \
    '[[ -n $marker_owner && $marker_mode == 600 &&'
expect_rejected quarantine-marker-link-count \
    '$marker_links == 1 && $marker_size == "$expected_size" ]]' \
    '$marker_links -ge 1 && $marker_size == "$expected_size" ]]'
expect_rejected quarantine-marker-size \
    '$marker_links == 1 && $marker_size == "$expected_size" ]]' \
    '$marker_links == 1 && $marker_size -ge "$expected_size" ]]'
expect_rejected quarantine-marker-magic-gate \
    '[[ $marker_magic == "$expected_magic" ]]' \
    '[[ -n $marker_magic ]]'
expect_rejected quarantine-runtime-validation \
    '"$DESKFLOW_QUARANTINE_MARKER" "$DESKFLOW_QUARANTINE_SIZE"' \
    '"$DESKFLOW_QUARANTINE_MARKER" "151"'
expect_rejected quarantine-runtime-absent-presence-gate \
    '[[ ! -e $DESKFLOW_QUARANTINE_MARKER &&' \
    '[[ true &&'
expect_rejected quarantine-runtime-absent-symlink-gate \
    '! -L $DESKFLOW_QUARANTINE_MARKER ]]' \
    '-n $DESKFLOW_QUARANTINE_MARKER ]]'
expect_rejected deployment-quarantine-validation \
    '"$DEPLOYMENT_QUARANTINE_MARKER" "$DEPLOYMENT_QUARANTINE_SIZE"' \
    '"$DEPLOYMENT_QUARANTINE_MARKER" "255"'
expect_rejected quarantine-dropin-count \
    "grep -Fc 'Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=' \"\$path\"" \
    "grep -Fq 'Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=' \"\$path\""
expect_rejected quarantine-dropin-exact-line \
    'grep -Fxc "$DESKFLOW_QUARANTINE_ENV_LINE" "$path"' \
    'grep -Fq "$DESKFLOW_QUARANTINE_ENV_LINE" "$path"'
expect_rejected deployment-quarantine-dropin-count \
    "grep -Fc 'Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=' \"\$path\"" \
    "grep -Fq 'Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=' \"\$path\""
expect_rejected deployment-quarantine-dropin-exact-line \
    'grep -Fxc "$DEPLOYMENT_QUARANTINE_ENV_LINE" "$path"' \
    'grep -Fq "$DEPLOYMENT_QUARANTINE_ENV_LINE" "$path"'
expect_rejected quarantine-installed-dropin-validation \
    'assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED"' \
    'ignored_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED"'
expect_rejected_after_anchor quarantine-preflight-freeze \
    '# QUARANTINE_BOUNDARY: preflight' 'freeze_quarantine_storage' \
    'assert_quarantine_storage'
for boundary in before-shutdown after-stop-deskflow after-stop-viewflow \
    after-reload proof-observation proof-commit proof-publication; do
    expect_rejected_after_anchor "quarantine-boundary-$boundary" \
        "# QUARANTINE_BOUNDARY: $boundary" 'assert_quarantine_storage_unchanged' \
        'true # removed quarantine storage continuity validation'
done
for global in deskflow_quarantine_preflight_identity deskflow_quarantine_preflight_sha \
    deployment_quarantine_preflight_identity deployment_quarantine_preflight_sha; do
    expect_rejected "quarantine-global-$global" "$global=" "ignored_$global="
done
expect_rejected quarantine-runtime-identity-capture \
    'deskflow_quarantine_preflight_identity=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")' \
    'deskflow_quarantine_preflight_identity=ignored'
expect_rejected quarantine-runtime-sha-capture \
    'deskflow_quarantine_preflight_sha=$(sha256 "$DESKFLOW_QUARANTINE_MARKER")' \
    'deskflow_quarantine_preflight_sha=ignored'
expect_rejected quarantine-runtime-absence-freeze \
    'deskflow_quarantine_preflight_identity=absent' \
    'deskflow_quarantine_preflight_identity=ignored'
expect_rejected quarantine-runtime-absence-sentinel \
    'deskflow_quarantine_preflight_sha=absent' \
    'deskflow_quarantine_preflight_sha=ignored'
expect_rejected quarantine-runtime-absence-continuity \
    '[[ $deskflow_quarantine_preflight_identity == absent &&' \
    '[[ -n $deskflow_quarantine_preflight_identity &&'
expect_rejected deployment-quarantine-identity-capture \
    'deployment_quarantine_preflight_identity=$(evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER")' \
    'deployment_quarantine_preflight_identity=ignored'
expect_rejected deployment-quarantine-sha-capture \
    'deployment_quarantine_preflight_sha=$(sha256 "$DEPLOYMENT_QUARANTINE_MARKER")' \
    'deployment_quarantine_preflight_sha=ignored'
expect_rejected quarantine-runtime-pre-hash-inode \
    '[[ $deskflow_identity_before == "$deskflow_quarantine_preflight_identity" ]]' \
    '[[ -n $deskflow_identity_before ]]'
expect_rejected quarantine-runtime-byte-hash \
    "assert_hash 'Deskflow runtime quarantine marker' \"\$DESKFLOW_QUARANTINE_MARKER\"" \
    ': # removed Deskflow runtime quarantine hash continuity'
expect_rejected quarantine-runtime-post-hash-inode \
    '[[ $deskflow_identity_after == "$deskflow_identity_before" ]]' \
    '[[ -n $deskflow_identity_after ]]'
expect_rejected deployment-quarantine-pre-hash-inode \
    '[[ $deployment_identity_before == "$deployment_quarantine_preflight_identity" ]]' \
    '[[ -n $deployment_identity_before ]]'
expect_rejected deployment-quarantine-byte-hash \
    "assert_hash 'deployment quarantine marker' \"\$DEPLOYMENT_QUARANTINE_MARKER\"" \
    ': # removed deployment quarantine hash continuity'
expect_rejected deployment-quarantine-post-hash-inode \
    '[[ $deployment_identity_after == "$deployment_identity_before" ]]' \
    '[[ -n $deployment_identity_after ]]'
expect_rejected_after_anchor quarantine-marker-delete '# QUARANTINE_BOUNDARY: before-shutdown' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; rm -f -- "$DESKFLOW_QUARANTINE_MARKER"'
expect_rejected_after_anchor quarantine-marker-move '# QUARANTINE_BOUNDARY: before-shutdown' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; mv -- "$DESKFLOW_QUARANTINE_MARKER" /tmp/quarantine'
expect_rejected_after_anchor quarantine-marker-clear '# QUARANTINE_BOUNDARY: before-shutdown' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; : > "$DESKFLOW_QUARANTINE_MARKER"'
expect_rejected_after_anchor deployment-quarantine-marker-delete \
    '# QUARANTINE_BOUNDARY: before-shutdown' 'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; rm -f -- "$DEPLOYMENT_QUARANTINE_MARKER"'
expect_rejected_after_anchor deployment-quarantine-marker-move \
    '# QUARANTINE_BOUNDARY: before-shutdown' 'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; mv -- "$DEPLOYMENT_QUARANTINE_MARKER" /tmp/quarantine'
expect_rejected_after_anchor deployment-quarantine-marker-clear \
    '# QUARANTINE_BOUNDARY: before-shutdown' 'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; : > "$DEPLOYMENT_QUARANTINE_MARKER"'
expect_rejected fixed-home 'readonly EXPECTED_HOME=/home/wilf' 'readonly EXPECTED_HOME=/tmp'
expect_rejected initial-hash-gate '    assert_installed_hashes' \
    '    true # removed installed hash gates'
expect_rejected initial-loaded-config-gate '    assert_loaded_unit_configuration' \
    '    true # removed loaded configuration gates'
expect_rejected viewflow-hash \
    'assert_hash '\''installed Viewflow'\'' "$VIEWFLOW_INSTALLED" "$viewflow_expected_sha"' \
    'true # removed installed Viewflow hash check'
expect_rejected deskflow-core-hash \
    'assert_hash '\''installed deskflow-core'\'' "$DESKFLOW_CORE_INSTALLED"' \
    'true # removed installed deskflow-core hash check'
expect_rejected viewflow-unit-hash \
    'assert_hash '\''installed Viewflow unit'\'' "$VIEWFLOW_UNIT_INSTALLED"' \
    'true # removed installed Viewflow unit hash check'
expect_rejected fragment-path \
    'fragment=$(unit_property "$VIEWFLOW_UNIT" FragmentPath)' \
    'fragment=$VIEWFLOW_UNIT_INSTALLED'
expect_rejected dropin-path \
    'dropins=$(unit_property "$DESKFLOW_UNIT" DropInPaths)' \
    'dropins=$DESKFLOW_DROPIN_INSTALLED'
expect_rejected stop-order \
    '# DEACTIVATION_PHASE: stop-deskflow-before-viewflow' \
    '# DEACTIVATION_PHASE: stop-viewflow-early'
expect_rejected deskflow-inactive \
    'state == inactive && ${main_pid:-0} == 0 && -z $deskflow_pids' \
    'state != inactive && ${main_pid:-0} == 0 && -z $deskflow_pids'
expect_rejected tcp-absence '-z $core_pids && -z $tcp_output' \
    '-z $core_pids && -n $tcp_output'
expect_rejected viewflow-inactive \
    'state == inactive && ${main_pid:-0} == 0 && -z $viewflow_pids' \
    'state != inactive && ${main_pid:-0} == 0 && -z $viewflow_pids'
expect_rejected sidecar-absence '-z $udp_output && ! -e $VIEWFLOW_SIDECAR' \
    '-z $udp_output && -e $VIEWFLOW_SIDECAR'
expect_rejected daemon-reload 'systemctl --user daemon-reload' \
    'true # removed daemon reload'
expect_rejected proof-state 'viewflow-linux-deactivated' 'viewflow-linux-active'
expect_rejected proof-schema '{schema_version: 3, state:' \
    '{schema_version: 2, state:'
expect_rejected proof-deployment-marker-artifact \
    'deployment_marker_tool: {path: $marker_tool_path, sha256: $marker_tool_sha}' \
    'deployment_marker_tool: {path: $marker_tool_path, sha256: "unverified"}'
expect_rejected proof-deployment-marker-process \
    'deployment_marker_tool: {exact_process_count: 0}' \
    'deployment_marker_tool: {exact_process_count: 1}'
expect_rejected transcript-deployment-marker-process \
    'deployment_marker_tool_exact_pids=%s' \
    'deployment_marker_tool_process_omitted=%s'
expect_rejected transcript-runtime-marker-state \
    'runtime_marker_state=%s' 'runtime_marker_state_omitted=%s'
expect_rejected transcript-no-clobber 'ln -- "$transcript_temp" "$transcript_output"' \
    'cp -- "$transcript_temp" "$transcript_output"'
expect_rejected transcript-published-hash \
    'published_transcript_sha=$(sha256 "$transcript_output")' \
    'published_transcript_sha=$transcript_sha'
expect_rejected transcript-hash-binding \
    '[[ $published_transcript_sha == "$transcript_sha" ]]' \
    '[[ -n $published_transcript_sha ]]'
expect_rejected proof-uses-published-transcript-hash \
    '--arg transcript_sha "$published_transcript_sha"' \
    '--arg transcript_sha "$transcript_sha"'
expect_rejected transcript-name-proof \
    'command_output_file_name: $transcript_file_name' \
    'command_output_file_name: "unverified"'
expect_rejected proof-hash 'command_output_sha256: $transcript_sha' \
    'command_output_sha256: "unverified"'
expect_rejected daemon-reload-proof 'daemon_reload_completed: true' \
    'daemon_reload_completed: false'
expect_rejected no-clobber 'ln -- "$proof_temp" "$proof_output"' \
    'cp -- "$proof_temp" "$proof_output"'
expect_rejected proof-publication-tracking \
    'proof_linked=1' 'proof_linked=0'
expect_rejected proof-publication-race-cleanup \
    'if ((proof_linked && !proof_published)); then' \
    'if ((proof_published)); then'
expect_rejected transcript-boundary-recheck \
    '[[ $(sha256 "$transcript_output") == "$published_transcript_sha" ]]' \
    '[[ -f $transcript_output ]]'
expect_rejected acceptance-viewflow-socket \
    'readonly VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/post-release-acceptance.sock' \
    'readonly VIEWFLOW_ACCEPTANCE_SOCKET=/tmp/acceptance.sock'
expect_rejected acceptance-deskflow-socket \
    'readonly DESKFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock' \
    'readonly DESKFLOW_ACCEPTANCE_SOCKET=/tmp/deskflow-acceptance.sock'
expect_rejected acceptance-state-dir \
    'readonly VIEWFLOW_ACCEPTANCE_STATE_DIR=/home/wilf/.local/state/viewflow/post-release-acceptance' \
    'readonly VIEWFLOW_ACCEPTANCE_STATE_DIR=/tmp/post-release-acceptance'
expect_rejected acceptance-state-dir-symlink \
    '[[ -d $VIEWFLOW_ACCEPTANCE_STATE_DIR && ! -L $VIEWFLOW_ACCEPTANCE_STATE_DIR ]]' \
    '[[ -d $VIEWFLOW_ACCEPTANCE_STATE_DIR ]]'
expect_rejected acceptance-state-dir-mode \
    '[[ $owner == "$EXPECTED_UID" && $mode == 700 ]]' \
    '[[ $owner == "$EXPECTED_UID" && $mode == 755 ]]'
expect_rejected acceptance-runtime-socket-stop \
    'assert_acceptance_runtime_sockets_absent() {' \
    'ignored_acceptance_runtime_sockets_absent() {'
expect_rejected acceptance-unit-contract \
    'assert_viewflow_unit_acceptance_contract() {' \
    'ignored_viewflow_unit_acceptance_contract() {'
expect_rejected acceptance-live-deskflow-environment \
    'Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET' \
    'Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=/tmp/deskflow-acceptance.sock'
expect_rejected_after_anchor acceptance-receipt-delete \
    '# QUARANTINE_BOUNDARY: before-shutdown' 'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; rm -rf -- "$VIEWFLOW_ACCEPTANCE_STATE_DIR"'

write_exact_marker() {
    local path=$1 magic=$2 size=$3 remainder
    remainder=$((size - ${#magic}))
    (umask 077; { printf '%s' "$magic"; head -c "$remainder" /dev/zero; } >"$path")
    chmod 0600 -- "$path"
}

rewrite_fixture_paths() {
    local destination=$1 fixture_root=$2 final_command=$3
    sed \
        -e "s|/home/wilf|$fixture_root/home/wilf|g" \
        -e "s|/run/user/1000|$fixture_root/run/user/1000|g" \
        -e "\$s|^deactivate_runtime\$|$final_command|" \
        "$DEACTIVATOR" >"$destination"
    chmod 0700 -- "$destination"
}

runtime_root=$tmp_dir/runtime-marker-state
runtime_home=$runtime_root/home/wilf
runtime_quarantine=$runtime_home/.local/state/viewflow
mkdir -p -- "$runtime_quarantine"
chmod 0700 -- "$runtime_quarantine"
write_exact_marker "$runtime_quarantine/deployment-quarantine.v1" VFDQT001 256
freeze_fixture=$runtime_root/deactivate-freeze-fixture.sh
rewrite_fixture_paths "$freeze_fixture" "$runtime_root" freeze_quarantine_storage

HOME=$runtime_home "$freeze_fixture" --runtime-marker-state absent >/dev/null ||
    fail 'valid absent runtime marker state was rejected by the freezer'
write_exact_marker "$runtime_quarantine/deskflow-quarantine.v2" VFQST002 152
if HOME=$runtime_home "$freeze_fixture" --runtime-marker-state absent \
    >"$runtime_root/absent-present.out" 2>&1; then
    fail 'absent runtime marker state accepted a present marker'
fi
grep -Fq 'must remain completely absent' "$runtime_root/absent-present.out" ||
    fail 'absent runtime marker presence returned the wrong error'
rm -f -- "$runtime_quarantine/deskflow-quarantine.v2"
if HOME=$runtime_home "$freeze_fixture" --runtime-marker-state retained \
    >"$runtime_root/retained-missing.out" 2>&1; then
    fail 'retained runtime marker state accepted a missing marker'
fi
grep -Fq 'must exist before deactivation preflight' "$runtime_root/retained-missing.out" ||
    fail 'retained runtime marker absence returned the wrong error'
ln -s -- missing-target "$runtime_quarantine/deskflow-quarantine.v2"
if HOME=$runtime_home "$freeze_fixture" --runtime-marker-state absent \
    >"$runtime_root/absent-symlink.out" 2>&1; then
    fail 'absent runtime marker state accepted a dangling symlink'
fi
rm -f -- "$runtime_quarantine/deskflow-quarantine.v2"
write_exact_marker "$runtime_quarantine/deskflow-quarantine.v2" VFQST002 152
HOME=$runtime_home "$freeze_fixture" --runtime-marker-state retained >/dev/null ||
    fail 'valid retained runtime marker state was rejected by the freezer'

publication_root=$tmp_dir/publication-race
publication_home=$publication_root/home/wilf
publication_quarantine=$publication_home/.local/state/viewflow
publication_acceptance=$publication_quarantine/post-release-acceptance
publication_output=$publication_root/output
publication_fake_bin=$publication_root/fake-bin
mkdir -p -- "$publication_quarantine" "$publication_acceptance" \
    "$publication_output" "$publication_fake_bin"
chmod 0700 -- "$publication_quarantine" "$publication_acceptance" \
    "$publication_output" "$publication_fake_bin"
mkdir -p -- "$publication_home/.local/lib/viewflow" \
    "$publication_home/.local/lib/deskflow-scale-fix" \
    "$publication_home/.config/systemd/user/deskflow.service.d"
write_exact_marker "$publication_quarantine/deployment-quarantine.v1" VFDQT001 256

publication_viewflow=$publication_home/.local/lib/viewflow/viewflowd
publication_marker_tool=$publication_home/.local/lib/viewflow/viewflow-deployment-marker
publication_deskflow=$publication_home/.local/lib/deskflow-scale-fix/deskflow
publication_core=$publication_home/.local/lib/deskflow-scale-fix/deskflow-core
publication_unit=$publication_home/.config/systemd/user/viewflow-peer.service
publication_dropin=$publication_home/.config/systemd/user/deskflow.service.d/viewflow.conf
for artifact in "$publication_viewflow" "$publication_marker_tool" \
    "$publication_deskflow" "$publication_core"; do
    printf 'fixture executable: %s\n' "$artifact" >"$artifact"
    chmod 0755 -- "$artifact"
done
printf '%s\n' \
    '[Unit]' \
    '[Service]' \
    "ExecStart=$publication_viewflow serve --bind 0.0.0.0:44119 --cert $publication_home/.local/share/viewflow/identity/peer.pem --key $publication_home/.local/share/viewflow/identity/peer.key --ca $publication_home/.local/share/viewflow/identity/ca.pem --device-id 00000000000000000000000000000001 --sidecar-socket %t/viewflow/deskflow.sock --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002 --quiesce-proof %t/viewflow/deploy-quiesced.json --quiesce-arm-file %t/viewflow/deploy-quiesce-arm.json --acceptance-socket %t/viewflow/post-release-acceptance.sock --acceptance-state-dir $publication_acceptance" \
    >"$publication_unit"
printf '%s\n' \
    '[Service]' \
    "Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=$publication_quarantine/deskflow-quarantine.v2" \
    "Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$publication_quarantine/deployment-quarantine.v1" \
    "Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$publication_root/run/user/1000/viewflow/deskflow-acceptance.sock" \
    >"$publication_dropin"
chmod 0644 -- "$publication_unit" "$publication_dropin"

cat >"$publication_fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1-} == --user && ${2-} == show && ${3-} == --property ]]; then
    case ${4-} in
        FragmentPath) printf '%s\n' "$TEST_VIEWFLOW_UNIT" ;;
        DropInPaths) printf '%s\n' "$TEST_DESKFLOW_DROPIN" ;;
        MainPID) printf '0\n' ;;
        *) exit 2 ;;
    esac
elif [[ ${1-} == --user && ${2-} == is-active ]]; then
    printf 'inactive\n'
elif [[ ${1-} == --user && (${2-} == stop || ${2-} == daemon-reload) ]]; then
    :
else
    exit 2
fi
EOF
cat >"$publication_fake_bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$publication_fake_bin/ln" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/ln "$@"
destination=${!#}
if [[ $destination == "$TEST_PROOF_OUTPUT" ]]; then
    (umask 077; { printf 'VFQST002'; head -c 144 /dev/zero; } >"$TEST_RUNTIME_MARKER")
    chmod 0600 -- "$TEST_RUNTIME_MARKER"
fi
EOF
chmod 0755 -- "$publication_fake_bin/systemctl" "$publication_fake_bin/ss" \
    "$publication_fake_bin/ln"

publication_fixture=$publication_root/deactivate-publication-fixture.sh
rewrite_fixture_paths "$publication_fixture" "$publication_root" deactivate_runtime
publication_proof=$publication_output/proof.json
publication_transcript=$publication_output/transcript.txt
export TEST_VIEWFLOW_UNIT=$publication_unit
export TEST_DESKFLOW_DROPIN=$publication_dropin
export TEST_PROOF_OUTPUT=$publication_proof
export TEST_RUNTIME_MARKER=$publication_quarantine/deskflow-quarantine.v2
hash_of() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
if PATH=$publication_fake_bin:/usr/bin:/bin HOME=$publication_home \
    "$publication_fixture" \
    --viewflow-sha256 "$(hash_of "$publication_viewflow")" \
    --deployment-marker-sha256 "$(hash_of "$publication_marker_tool")" \
    --deskflow-sha256 "$(hash_of "$publication_deskflow")" \
    --deskflow-core-sha256 "$(hash_of "$publication_core")" \
    --viewflow-unit-sha256 "$(hash_of "$publication_unit")" \
    --deskflow-dropin-sha256 "$(hash_of "$publication_dropin")" \
    --runtime-marker-state absent \
    --operation-id publication-race-0001 \
    --transcript-output "$publication_transcript" \
    --proof-output "$publication_proof" \
    >"$publication_root/run.out" 2>&1; then
    fail 'proof publication race was accepted'
fi
grep -Fq 'must remain completely absent' "$publication_root/run.out" ||
    fail 'proof publication race returned the wrong error'
[[ ! -e $publication_proof && ! -L $publication_proof ]] ||
    fail 'failed proof publication race left a proof artifact'
[[ ! -e $publication_transcript && ! -L $publication_transcript ]] ||
    fail 'failed proof publication race left a transcript artifact'

printf 'standalone Linux deactivation static negative tests passed\n'
