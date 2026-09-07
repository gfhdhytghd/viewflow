#!/usr/bin/env bash
# shellcheck disable=SC2016

# Source-mutation negatives for the normal schema-4 transaction. The installer
# is never executed.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly LINUX_DIR
readonly INSTALLER=$LINUX_DIR/install-viewflow-deskflow.sh
readonly CHECKER=$LINUX_DIR/check-transactional-deploy.sh

fail() {
    printf 'transactional installer static negative test failed: %s\n' "$*" >&2
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
    ' "$INSTALLER" >"$mutant" || fail "mutation target missing: $name"
    ! cmp -s "$INSTALLER" "$mutant" || fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

expect_rejected_pair() {
    local name=$1 from_one=$2 to_one=$3 from_two=$4 to_two=$5 mutant
    mutant=$tmp_dir/$name.sh
    awk -v from_one="$from_one" -v to_one="$to_one" \
        -v from_two="$from_two" -v to_two="$to_two" '
        {
            line = $0
            if (!replaced_one && (position = index(line, from_one)) != 0) {
                line = substr(line, 1, position - 1) to_one \
                    substr(line, position + length(from_one))
                replaced_one = 1
            }
            if (!replaced_two && (position = index(line, from_two)) != 0) {
                line = substr(line, 1, position - 1) to_two \
                    substr(line, position + length(from_two))
                replaced_two = 1
            }
            print line
        }
        END { if (!replaced_one || !replaced_two) exit 42 }
    ' "$INSTALLER" >"$mutant" || fail "mutation target missing: $name"
    ! cmp -s "$INSTALLER" "$mutant" || fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

expect_rejected_occurrence() {
    local name=$1 occurrence=$2 from=$3 to=$4 mutant
    mutant=$tmp_dir/$name.sh
    awk -v target="$occurrence" -v from="$from" -v to="$to" '
        {
            line = $0
            offset = 1
            while ((relative = index(substr(line, offset), from)) != 0) {
                absolute = offset + relative - 1
                count += 1
                if (count == target) {
                    line = substr(line, 1, absolute - 1) to \
                        substr(line, absolute + length(from))
                    replaced = 1
                    break
                }
                offset = absolute + length(from)
            }
            print line
        }
        END { if (!replaced) exit 42 }
    ' "$INSTALLER" >"$mutant" || fail "mutation target missing: $name"
    ! cmp -s "$INSTALLER" "$mutant" || fail "mutation did not change source: $name"
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
    ' "$INSTALLER" >"$mutant" || fail "mutation target missing: $name"
    ! cmp -s "$INSTALLER" "$mutant" || fail "mutation did not change source: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

"$CHECKER" "$INSTALLER" >/dev/null
expect_rejected deployment-marker-tool-fixed-path \
    'readonly DEPLOYMENT_MARKER_TOOL_INSTALLED=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker' \
    'readonly DEPLOYMENT_MARKER_TOOL_INSTALLED=/tmp/viewflow-deployment-marker'
expect_rejected deployment-marker-tool-candidate-option \
    '--deployment-marker-candidate' '--ignored-deployment-marker-candidate'
expect_rejected deployment-marker-tool-sha-option \
    '--deployment-marker-sha256' '--ignored-deployment-marker-sha256'
expect_rejected deployment-marker-tool-metadata \
    '[[ $owner == "$EXPECTED_UID" && $mode == 755 && $links == 1 ]]' \
    '[[ $owner == "$EXPECTED_UID" && $mode -ge 700 && $links -ge 1 ]]'
expect_rejected deployment-marker-tool-process-gate \
    'exact_executable_pids "$DEPLOYMENT_MARKER_TOOL_INSTALLED"' \
    'exact_executable_pids /tmp/unrelated'
expect_rejected deployment-marker-tool-backup \
    'install -m 0755 -- "$DEPLOYMENT_MARKER_TOOL_INSTALLED"' \
    'install -m 0755 -- "$VIEWFLOW_INSTALLED"'
expect_rejected deployment-marker-tool-install \
    'atomic_install "$deployment_marker_tool_candidate"' \
    'atomic_install "$viewflow_candidate"'
expect_rejected deployment-marker-tool-illegal-lifecycle \
    'assert_deployment_marker_tool_stopped' \
    '"$DEPLOYMENT_MARKER_TOOL_INSTALLED" publish'
expect_rejected quarantine-fixed-parent \
    'readonly DESKFLOW_QUARANTINE_PARENT=/home/wilf/.local/state/viewflow' \
    'readonly DESKFLOW_QUARANTINE_PARENT=/tmp'
expect_rejected quarantine-fixed-marker \
    'readonly DESKFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    'readonly DESKFLOW_QUARANTINE_MARKER=/tmp/deskflow-quarantine.v2'
expect_rejected quarantine-fixed-magic \
    'readonly DESKFLOW_QUARANTINE_MAGIC=VFQST002' \
    'readonly DESKFLOW_QUARANTINE_MAGIC=VFDQT001'
expect_rejected deployment-quarantine-fixed-marker \
    'readonly DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' \
    'readonly DEPLOYMENT_QUARANTINE_MARKER=/tmp/deployment-quarantine.v1'
expect_rejected deployment-quarantine-fixed-magic \
    'readonly DEPLOYMENT_QUARANTINE_MAGIC=VFDQT001' \
    'readonly DEPLOYMENT_QUARANTINE_MAGIC=VFQST002'
expect_rejected quarantine-fixed-environment \
    'readonly DESKFLOW_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    'readonly DESKFLOW_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/tmp/deskflow-quarantine.v2'
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
    '[[ -e $DESKFLOW_QUARANTINE_MARKER || -L $DESKFLOW_QUARANTINE_MARKER ]]' \
    '[[ -e $DESKFLOW_QUARANTINE_MARKER ]]'
expect_rejected quarantine-marker-required-error \
    "die 'Deskflow quarantine marker must exist before deployment preflight'" \
    "die 'Deskflow quarantine marker is optional'"
expect_rejected quarantine-marker-regular \
    '[[ -f $DESKFLOW_QUARANTINE_MARKER && ! -L $DESKFLOW_QUARANTINE_MARKER ]]' \
    '[[ -e $DESKFLOW_QUARANTINE_MARKER ]]'
expect_rejected quarantine-marker-mode \
    '[[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 600 &&' \
    '[[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 640 &&'
expect_rejected quarantine-marker-owner \
    '[[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 600 &&' \
    '[[ -n $marker_owner && $marker_mode == 600 &&'
expect_rejected quarantine-marker-link-count \
    '$marker_links == 1 && $marker_size == 152 ]]' \
    '$marker_links -ge 1 && $marker_size == 152 ]]'
expect_rejected quarantine-marker-size \
    '$marker_links == 1 && $marker_size == 152 ]]' \
    '$marker_links == 1 && $marker_size -ge 152 ]]'
expect_rejected quarantine-marker-magic-gate \
    '[[ $marker_magic == "$DESKFLOW_QUARANTINE_MAGIC" ]]' \
    '[[ -n $marker_magic ]]'
expect_rejected deployment-quarantine-dangling-symlink \
    '[[ -e $DEPLOYMENT_QUARANTINE_MARKER || -L $DEPLOYMENT_QUARANTINE_MARKER ]]' \
    '[[ -e $DEPLOYMENT_QUARANTINE_MARKER ]]'
expect_rejected deployment-quarantine-marker-required-error \
    "die 'Viewflow deployment quarantine marker must exist before deployment preflight'" \
    "die 'Viewflow deployment quarantine marker is optional'"
expect_rejected deployment-quarantine-marker-regular \
    '[[ -f $DEPLOYMENT_QUARANTINE_MARKER && ! -L $DEPLOYMENT_QUARANTINE_MARKER ]]' \
    '[[ -e $DEPLOYMENT_QUARANTINE_MARKER ]]'
expect_rejected deployment-quarantine-marker-mode \
    '[[ $deployment_owner == "$EXPECTED_UID" && $deployment_mode == 600 &&' \
    '[[ $deployment_owner == "$EXPECTED_UID" && $deployment_mode == 640 &&'
expect_rejected deployment-quarantine-marker-owner \
    '[[ $deployment_owner == "$EXPECTED_UID" && $deployment_mode == 600 &&' \
    '[[ -n $deployment_owner && $deployment_mode == 600 &&'
expect_rejected deployment-quarantine-marker-link-count \
    '$deployment_links == 1 && $deployment_size == 256 ]]' \
    '$deployment_links -ge 1 && $deployment_size == 256 ]]'
expect_rejected deployment-quarantine-marker-size \
    '$deployment_links == 1 && $deployment_size == 256 ]]' \
    '$deployment_links == 1 && $deployment_size -ge 256 ]]'
expect_rejected deployment-quarantine-marker-magic-gate \
    '[[ $deployment_magic == "$DEPLOYMENT_QUARANTINE_MAGIC" ]]' \
    '[[ -n $deployment_magic ]]'
expect_rejected quarantine-dropin-exact-line \
    'grep -Fxc "$DESKFLOW_QUARANTINE_ENV_LINE" "$path"' \
    'grep -Fq "$DESKFLOW_QUARANTINE_ENV_LINE" "$path"'
expect_rejected deployment-quarantine-dropin-exact-line \
    'grep -Fxc "$DEPLOYMENT_QUARANTINE_ENV_LINE" "$path"' \
    'grep -Fq "$DEPLOYMENT_QUARANTINE_ENV_LINE" "$path"'
expect_rejected quarantine-live-environment \
    '"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_MARKER"' \
    '"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/tmp/deskflow-quarantine.v2"'
expect_rejected_occurrence quarantine-gui-live-environment 1 \
    '"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_MARKER"' \
    '"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/tmp/gui-marker"'
expect_rejected_occurrence quarantine-core-live-environment 2 \
    '"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_MARKER"' \
    '"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/tmp/core-marker"'
expect_rejected_occurrence deployment-quarantine-gui-live-environment 1 \
    '"DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$DEPLOYMENT_QUARANTINE_MARKER"' \
    '"DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/tmp/gui-deployment-marker"'
expect_rejected_occurrence deployment-quarantine-core-live-environment 2 \
    '"DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$DEPLOYMENT_QUARANTINE_MARKER"' \
    '"DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/tmp/core-deployment-marker"'
expect_rejected_occurrence quarantine-candidate-dropin-preflight 1 \
    'assert_quarantine_dropin_contract "$deskflow_dropin_candidate"' \
    'ignored_quarantine_dropin_contract "$deskflow_dropin_candidate"'
expect_rejected_occurrence quarantine-candidate-dropin-commit 2 \
    'assert_quarantine_dropin_contract "$deskflow_dropin_candidate"' \
    'ignored_quarantine_dropin_contract "$deskflow_dropin_candidate"'
for occurrence in 1 2 3 4; do
    expect_rejected_occurrence "quarantine-installed-dropin-$occurrence" "$occurrence" \
        'assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED"' \
        'ignored_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED"'
done
for boundary in commit before-stop-deskflow after-stop-deskflow \
    after-stop-viewflow after-config-install after-reload after-deskflow-readiness \
    rollback-before-stop rollback-before-restore rollback-after-reload rollback-final-proof; do
    expect_rejected_after_anchor "quarantine-boundary-$boundary" \
        "# QUARANTINE_BOUNDARY: $boundary" 'assert_quarantine_storage_unchanged' \
        'true # removed quarantine storage validation'
done
expect_rejected_after_anchor quarantine-preflight-freeze \
    '# QUARANTINE_BOUNDARY: preflight' 'freeze_quarantine_storage' \
    'assert_quarantine_storage'
expect_rejected_occurrence quarantine-marker-identity-global 1 \
    'quarantine_marker_preflight_identity=' \
    'ignored_quarantine_marker_preflight_identity='
expect_rejected_occurrence quarantine-marker-sha-global 1 \
    'quarantine_marker_preflight_sha=' \
    'ignored_quarantine_marker_preflight_sha='
expect_rejected_occurrence deployment-quarantine-marker-identity-global 1 \
    'deployment_quarantine_marker_preflight_identity=' \
    'ignored_deployment_quarantine_marker_preflight_identity='
expect_rejected_occurrence deployment-quarantine-marker-sha-global 1 \
    'deployment_quarantine_marker_preflight_sha=' \
    'ignored_deployment_quarantine_marker_preflight_sha='
expect_rejected quarantine-marker-identity-capture \
    'quarantine_marker_preflight_identity=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")' \
    'quarantine_marker_preflight_identity=ignored'
expect_rejected quarantine-marker-sha-capture \
    'quarantine_marker_preflight_sha=$(sha256 "$DESKFLOW_QUARANTINE_MARKER")' \
    'quarantine_marker_preflight_sha=ignored'
expect_rejected quarantine-marker-pre-hash-inode \
    '[[ $identity_before == "$quarantine_marker_preflight_identity" ]]' \
    '[[ -n $identity_before ]]'
expect_rejected quarantine-marker-byte-hash \
    "assert_hash 'Deskflow quarantine marker' \"\$DESKFLOW_QUARANTINE_MARKER\"" \
    ': # removed quarantine marker hash continuity'
expect_rejected quarantine-marker-post-hash-inode \
    '[[ $identity_after == "$identity_before" ]]' \
    '[[ -n $identity_after ]]'
expect_rejected deployment-quarantine-marker-identity-capture \
    'evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER"' \
    'evidence_identity "$DESKFLOW_QUARANTINE_MARKER"'
expect_rejected deployment-quarantine-marker-sha-capture \
    'deployment_quarantine_marker_preflight_sha=$(sha256 "$DEPLOYMENT_QUARANTINE_MARKER")' \
    'deployment_quarantine_marker_preflight_sha=ignored'
expect_rejected deployment-quarantine-marker-pre-hash-inode \
    '[[ $deployment_identity_before == "$deployment_quarantine_marker_preflight_identity" ]]' \
    '[[ -n $deployment_identity_before ]]'
expect_rejected deployment-quarantine-marker-byte-hash \
    "assert_hash 'Viewflow deployment quarantine marker' \"\$DEPLOYMENT_QUARANTINE_MARKER\"" \
    ': # removed deployment quarantine marker hash continuity'
expect_rejected deployment-quarantine-marker-post-hash-inode \
    '[[ $deployment_identity_after == "$deployment_identity_before" ]]' \
    '[[ -n $deployment_identity_after ]]'
expect_rejected_after_anchor quarantine-marker-delete '# QUARANTINE_BOUNDARY: commit' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; rm -f -- "$DESKFLOW_QUARANTINE_MARKER"'
expect_rejected_after_anchor quarantine-marker-move '# QUARANTINE_BOUNDARY: commit' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; mv -- "$DESKFLOW_QUARANTINE_MARKER" /tmp/quarantine'
expect_rejected_after_anchor quarantine-marker-clear '# QUARANTINE_BOUNDARY: commit' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; : > "$DESKFLOW_QUARANTINE_MARKER"'
expect_rejected_after_anchor deployment-quarantine-marker-delete '# QUARANTINE_BOUNDARY: commit' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; rm -f -- "$DEPLOYMENT_QUARANTINE_MARKER"'
expect_rejected_after_anchor deployment-quarantine-marker-move '# QUARANTINE_BOUNDARY: commit' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; mv -- "$DEPLOYMENT_QUARANTINE_MARKER" /tmp/deployment-quarantine'
expect_rejected_after_anchor deployment-quarantine-marker-clear '# QUARANTINE_BOUNDARY: commit' \
    'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; : > "$DEPLOYMENT_QUARANTINE_MARKER"'
expect_rejected deskflow-provenance-manifest-option \
    '--deskflow-provenance-manifest' \
    '--ignored-deskflow-provenance-manifest'
expect_rejected deskflow-provenance-sha-option \
    '--deskflow-provenance-sha256' \
    '--ignored-deskflow-provenance-sha256'
expect_rejected deskflow-fixed-upstream \
    'readonly REQUIRED_DESKFLOW_UPSTREAM_HEAD=760e3b99b00053647a96b405276bf614bd860075' \
    'readonly REQUIRED_DESKFLOW_UPSTREAM_HEAD=0000000000000000000000000000000000000000'
expect_rejected deskflow-provenance-private-subshell \
    'validate_deskflow_provenance_manifest() (' \
    'validate_deskflow_provenance_manifest() {'
expect_rejected deskflow-provenance-private-directory \
    'validation_dir=$(mktemp -d "${TMPDIR:-/tmp}/viewflow-provenance-validate.XXXXXXXX")' \
    'validation_dir=${TMPDIR:-/tmp}'
expect_rejected deskflow-provenance-private-directory-mode \
    'chmod 0700 "$validation_dir"' \
    'chmod 0755 "$validation_dir"'
expect_rejected deskflow-provenance-private-cleanup \
    'trap cleanup_provenance_validation EXIT' \
    ': # removed private provenance cleanup trap'
expect_rejected deskflow-provenance-private-cleanup-target \
    'rm -rf -- "$validation_dir"' \
    'rm -rf -- "${TMPDIR:-/tmp}"'
expect_rejected deskflow-provenance-private-cleanup-status \
    'exit "$status"' \
    'exit 0'
expect_rejected deskflow-provenance-private-copy-mode \
    'install -m 0400 -- "$path" "$validation_copy"' \
    'install -m 0644 -- "$path" "$validation_copy"'
expect_rejected deskflow-provenance-strict-json \
    "assert_strict_json_document 'Deskflow provenance manifest' \"\$validation_copy\"" \
    ": # removed strict Deskflow provenance JSON validation"
expect_rejected deskflow-provenance-private-jq-input \
    "' \"\$validation_copy\" >/dev/null ||" \
    "' \"\$path\" >/dev/null ||"
expect_rejected deskflow-provenance-top-level-schema \
    '(keys == ["artifacts", "build", "generated_at_utc", "kind", "protocol_version", "schema_version", "sidecar_protocol_version", "source", "upstream"])' \
    '(has("artifacts") and has("source") and has("upstream"))'
expect_rejected deskflow-provenance-schema-kind \
    '.schema_version == 1 and .kind == "viewflow-deskflow-linux-provenance"' \
    '.schema_version >= 1 and (.kind | type == "string")'
expect_rejected deskflow-provenance-protocol-claims \
    '.protocol_version == "2.1" and .sidecar_protocol_version == 3' \
    '(.protocol_version | type == "string") and (.sidecar_protocol_version | type == "number")'
expect_rejected deskflow-provenance-detached-upstream \
    '.upstream.commit == $upstream and .upstream.detached_head == true' \
    '(.upstream.commit | sha256) and (.upstream.detached_head | type == "boolean")'
expect_rejected deskflow-provenance-upstream-argument \
    '--arg upstream "$REQUIRED_DESKFLOW_UPSTREAM_HEAD"' \
    '--arg upstream "$untrusted_upstream_head"'
expect_rejected deskflow-provenance-tracked-count \
    'length == 8 and all(.[]; tracked_entry)' \
    'length >= 8 and all(.[]; tracked_entry)'
expect_rejected deskflow-provenance-critical-count \
    'length == 12 and all(.[]; critical_entry)' \
    'length >= 12 and all(.[]; critical_entry)'
expect_rejected deskflow-provenance-untracked-count \
    'length == 4 and all(.[]; untracked_entry)' \
    'length >= 4 and all(.[]; untracked_entry)'
expect_rejected deskflow-provenance-source-allowlist \
    'src/lib/server/ViewflowSidecarClient.cpp' \
    'src/lib/server/UnreviewedSidecarClient.cpp'
expect_rejected deskflow-provenance-cmake-schema \
    '(.build.cmake | keys == ["cache_sha256", "cache_size_bytes", "executable", "executable_sha256", "verify_globs_sha256", "verify_globs_size_bytes", "version"])' \
    '(.build.cmake | has("cache_sha256") and has("executable"))'
expect_rejected deskflow-provenance-ninja-rules-schema \
    '"pending_rebuild", "rules_file_sha256", "rules_file_size_bytes", "version"' \
    '"pending_rebuild", "version"'
expect_rejected deskflow-provenance-ninja-rules-hash \
    '(.build.ninja.rules_file_sha256 | sha256)' \
    '(.build.ninja.rules_file_sha256 | type == "string")'
expect_rejected deskflow-provenance-ninja-rules-size \
    '(.build.ninja.rules_file_size_bytes | uint53 and . > 0)' \
    '(.build.ninja.rules_file_size_bytes | uint53)'
expect_rejected deskflow-provenance-pending-build \
    '.build.ninja.pending_rebuild == false' \
    '(.build.ninja.pending_rebuild | type == "boolean")'
expect_rejected deskflow-provenance-live-acceptance-build-key \
    '"generator", "live_acceptance", "ninja"' \
    '"generator", "ninja"'
expect_rejected deskflow-provenance-live-acceptance-exact-keys \
    '(keys == ["arm_magic", "core_query", "enabled", "peer_auth", "protocol_version", "receipt_magic", "receipt_size", "sidecar_protocol_version", "socket_kind"])' \
    '(has("enabled") and has("core_query"))'
expect_rejected deskflow-provenance-live-acceptance-enabled \
    '.enabled == true and .socket_kind == "af_unix" and' \
    '(.enabled | type == "boolean") and .socket_kind == "af_unix" and'
expect_rejected deskflow-provenance-live-acceptance-socket-kind \
    '.enabled == true and .socket_kind == "af_unix" and' \
    '.enabled == true and (.socket_kind | type == "string") and'
expect_rejected deskflow-provenance-live-acceptance-peer-auth \
    '.peer_auth == "so_peercred_same_uid" and .arm_magic == "VFARM001" and' \
    '(.peer_auth | type == "string") and .arm_magic == "VFARM001" and'
expect_rejected deskflow-provenance-live-acceptance-arm-magic \
    '.peer_auth == "so_peercred_same_uid" and .arm_magic == "VFARM001" and' \
    '.peer_auth == "so_peercred_same_uid" and (.arm_magic | type == "string") and'
expect_rejected deskflow-provenance-live-acceptance-receipt \
    '.receipt_magic == "VFRCP001" and .receipt_size == 568 and' \
    '(.receipt_magic | type == "string") and (.receipt_size | type == "number") and'
expect_rejected deskflow-provenance-live-acceptance-protocol \
    '.protocol_version == "2.1" and .sidecar_protocol_version == 3 and' \
    '(.protocol_version | type == "string") and (.sidecar_protocol_version | type == "number") and'
expect_rejected deskflow-provenance-live-acceptance-core-query \
    '.core_query == true;' \
    '(.core_query | type == "boolean");'
expect_rejected deskflow-provenance-live-acceptance-application \
    '(.build.live_acceptance | live_acceptance)' \
    '(.build.live_acceptance | type == "object")'
expect_rejected deskflow-provenance-deskflow-hash-binding \
    '.artifacts.deskflow.sha256 == $deskflow_sha' \
    '(.artifacts.deskflow.sha256 | sha256)'
expect_rejected deskflow-provenance-core-hash-binding \
    '.artifacts.deskflow_core.sha256 == $core_sha' \
    '(.artifacts.deskflow_core.sha256 | sha256)'
expect_rejected deskflow-provenance-deskflow-source-path \
    '.artifacts.deskflow.source_path == (.build.directory + "/bin/deskflow")' \
    '(.artifacts.deskflow.source_path | absolute)'
expect_rejected deskflow-provenance-core-source-path \
    '.artifacts.deskflow_core.source_path == (.build.directory + "/bin/deskflow-core")' \
    '(.artifacts.deskflow_core.source_path | absolute)'
expect_rejected deskflow-provenance-deskflow-cli-hash-argument \
    '--arg deskflow_sha "$deskflow_expected_sha"' \
    '--arg deskflow_sha "$untrusted_deskflow_sha"'
expect_rejected deskflow-provenance-core-cli-hash-argument \
    '--arg core_sha "$deskflow_core_expected_sha"' \
    '--arg core_sha "$untrusted_core_sha"'
expect_rejected deskflow-provenance-deskflow-size-binding \
    '[[ $(stat -c '\''%s'\'' -- "$deskflow_candidate") == "$deskflow_size" ]] ||' \
    '[[ -s $deskflow_candidate ]] ||'
expect_rejected deskflow-provenance-core-size-binding \
    '[[ $(stat -c '\''%s'\'' -- "$deskflow_core_candidate") == "$core_size" ]] ||' \
    '[[ -s $deskflow_core_candidate ]] ||'
expect_rejected deskflow-provenance-deskflow-build-id \
    '[[ $(elf_build_id "$deskflow_candidate") == "$deskflow_build_id" ]] ||' \
    '[[ -n $(elf_build_id "$deskflow_candidate") ]] ||'
expect_rejected deskflow-provenance-core-build-id \
    '[[ $(elf_build_id "$deskflow_core_candidate") == "$core_build_id" ]] ||' \
    '[[ -n $(elf_build_id "$deskflow_core_candidate") ]] ||'
expect_rejected deskflow-provenance-build-id-syntax \
    '[[ $build_id =~ ^[0-9a-f]+$ ]]' \
    '[[ -n $build_id ]]'
expect_rejected deskflow-provenance-cli-hash-syntax \
    'require_sha256 '\''--deskflow-provenance-sha256'\'' "$deskflow_provenance_expected_sha"' \
    ': # removed provenance SHA-256 syntax validation'
expect_rejected deskflow-provenance-identity-capture \
    'deskflow_provenance_preflight_identity=$(evidence_identity' \
    'deskflow_provenance_preflight_identity=ignored_identity #'
expect_rejected deskflow-provenance-preflight-hash \
    '[[ $deskflow_provenance_preflight_sha == "$deskflow_provenance_expected_sha" ]] ||' \
    '[[ -n $deskflow_provenance_preflight_sha ]] ||'
expect_rejected_occurrence deskflow-provenance-private-copy-entry-hash 1 \
    '[[ $(sha256 "$validation_copy") == "$deskflow_provenance_expected_sha" ]] ||' \
    '[[ -s $validation_copy ]] ||'
expect_rejected_occurrence deskflow-provenance-private-copy-exit-hash 2 \
    '[[ $(sha256 "$validation_copy") == "$deskflow_provenance_expected_sha" ]] ||' \
    '[[ -s $validation_copy ]] ||'
expect_rejected_occurrence deskflow-provenance-preflight-validation 1 \
    'validate_deskflow_provenance_manifest "$deskflow_provenance_manifest"' \
    ': # removed preflight provenance validation'
expect_rejected deskflow-provenance-commit-identity \
    "assert_evidence_unchanged 'Deskflow provenance manifest'" \
    "ignored_evidence_unchanged 'Deskflow provenance manifest'"
expect_rejected_occurrence deskflow-provenance-commit-validation 2 \
    'validate_deskflow_provenance_manifest "$deskflow_provenance_manifest"' \
    ': # removed commit-boundary provenance validation'
expect_rejected exact-protocol \
    '(.protocol_version == $required_protocol)' \
    '(.protocol_version != $required_protocol)'
expect_rejected receipt-schema \
    '(.schema_version == 4)' \
    '(.schema_version == 3)'
expect_rejected revoke-evidence-fields \
    '(.cleanup.lease_revoke | keys == ["ack", "generation", "status"])' \
    '(.cleanup.lease_revoke | keys == ["generation", "status"])'
expect_rejected_pair revoke-ack-exact-fields \
    'keys == ["lease_generation", "operation_id", "owner_device",' \
    'has("lease_generation") and has("operation_id") and has("owner_device") and' \
    '"result", "state", "target_device"]) and' \
    'has("result") and has("state") and has("target_device")) and'
expect_rejected revoke-applied \
    '.cleanup.lease_revoke.status == "applied"' \
    '.cleanup.lease_revoke.status == "transport_confirmed"'
expect_rejected revoke-generation-transition \
    '.cleanup.lease_revoke.generation == (.cleanup.active_lease_generation + 1)' \
    '(.cleanup.lease_revoke.generation | uint53)'
expect_rejected revoke-operation-format \
    'type == "string" and test("^[0-9a-f]{32}$")' \
    'type == "string"'
expect_rejected revoke-operation \
    '.cleanup.lease_revoke.ack.operation_id != "00000000000000000000000000000000"' \
    '(.cleanup.lease_revoke.ack.operation_id | type == "string")'
expect_rejected revoke-peer-epoch \
    "[[ \${revoke_operation_id:0:16} == \"\$(printf '%016x' \"\$bound_peer_epoch\")\" ]]" \
    '[[ -n $revoke_operation_id ]]'
expect_rejected revoke-generation \
    '.cleanup.lease_revoke.ack.lease_generation == .cleanup.lease_revoke.generation' \
    '(.cleanup.lease_revoke.ack.lease_generation | uint53)'
expect_rejected revoke-owner \
    '.cleanup.lease_revoke.ack.owner_device == $local_device' \
    '(.cleanup.lease_revoke.ack.owner_device | type == "string")'
expect_rejected revoke-target \
    '.cleanup.lease_revoke.ack.target_device == $target' \
    '(.cleanup.lease_revoke.ack.target_device | type == "string")'
expect_rejected revoke-state \
    '.cleanup.lease_revoke.ack.state == "revoked"' \
    '(.cleanup.lease_revoke.ack.state | type == "string")'
expect_rejected revoke-result \
    '.cleanup.lease_revoke.ack.result == "applied"' \
    '(.cleanup.lease_revoke.ack.result | type == "string")'
expect_rejected revoke-bound-peer-epoch \
    '(.cleanup.bound_peer_epoch | uint53 and . > 0)' \
    '(.cleanup.bound_peer_epoch | uint53)'
expect_rejected revoke-operation-peer-epoch \
    '.cleanup.lease_revoke.ack.operation_id[0:16] ==' \
    'true or .cleanup.lease_revoke.ack.operation_id[0:16] =='
expect_rejected revoke-operation-counter-nonzero \
    '.cleanup.lease_revoke.ack.operation_id[16:32] !=' \
    'true or .cleanup.lease_revoke.ack.operation_id[16:32] !='
expect_rejected revoke-bound-peer-socket \
    '(.cleanup.bound_peer_socket | type == "string")' \
    'true'
expect_rejected revoke-bound-peer-address \
    '$socket_parts[0] == $peer' \
    '($socket_parts[0] | type == "string")'
expect_rejected release-ack-exact-fields \
    'keys == ["event_sequence", "lease_generation", "result",' \
    'has("event_sequence") and has("lease_generation") and has("result") and'
expect_rejected release-ack-generation \
    '.cleanup.release_all.ack.lease_generation == .cleanup.active_lease_generation' \
    '(.cleanup.release_all.ack.lease_generation | uint53)'
expect_rejected release-ack-target \
    '.cleanup.release_all.ack.target_device == $target' \
    '(.cleanup.release_all.ack.target_device | type == "string")'
expect_rejected inactive-revoke-ack \
    '.cleanup.lease_revoke.ack == null' \
    'true'
expect_rejected route-source-display \
    '.cleanup.source_display == $source_display' \
    '(.cleanup.source_display | type == "string")'
expect_rejected route-generation \
    '(.cleanup.route_generation | uint53 and . > 0)' \
    '(.cleanup.route_generation | uint53)'
expect_rejected integer-domain \
    '. == floor and . >= 0 and . <= 9007199254740991' \
    'type == "number"'
expect_rejected viewflow-unit-install \
    'atomic_install "$viewflow_unit_candidate" "$VIEWFLOW_UNIT_INSTALLED" 0644' \
    'true # removed Viewflow unit install'
expect_rejected deskflow-dropin-install \
    'atomic_install "$deskflow_dropin_candidate" "$DESKFLOW_DROPIN_INSTALLED" 0644' \
    'true # removed Deskflow drop-in install'
expect_rejected config-reload \
    'systemctl --user daemon-reload' \
    'true # removed daemon reload'
expect_rejected loaded-fragment-check \
    'fragment=$(systemctl --user show --property FragmentPath --value "$VIEWFLOW_UNIT")' \
    'fragment=$VIEWFLOW_UNIT_INSTALLED'
expect_rejected loaded-dropin-check \
    'dropins=$(systemctl --user show --property DropInPaths --value "$DESKFLOW_UNIT")' \
    'dropins=$DESKFLOW_DROPIN_INSTALLED'
expect_rejected viewflow-unit-rollback \
    'atomic_install "$backup_dir/viewflow-peer.service" "$VIEWFLOW_UNIT_INSTALLED" 0644' \
    'true # removed Viewflow unit rollback'
expect_rejected deskflow-dropin-rollback \
    'atomic_install "$backup_dir/deskflow-viewflow.conf" "$DESKFLOW_DROPIN_INSTALLED" 0644' \
    'true # removed Deskflow drop-in rollback'
expect_rejected strict-json \
    'assert_strict_json_document' \
    'ignored_strict_json_document'
expect_rejected evidence-identity \
    'assert_evidence_unchanged' \
    'ignored_evidence_unchanged'
expect_rejected same-filesystem \
    'assert_evidence_on_backup_filesystem' \
    'ignored_evidence_on_backup_filesystem'
expect_rejected atomic-marker-consumption \
    'mv -T -- "$quiesced_marker" "$backup_dir/quiesced-marker.json"' \
    'mv -- "$quiesced_marker" "$backup_dir/quiesced-marker.json"'
expect_rejected daemon-exit-evidence-consumption \
    'mv -T -- "$daemon_exit_evidence" "$backup_dir/viewflow-daemon-exited.json"' \
    'cp -- "$daemon_exit_evidence" "$backup_dir/viewflow-daemon-exited.json"'
expect_rejected daemon-exit-observation-consumption \
    'mv -T -- "$daemon_exit_observation"' \
    'mv -- "$daemon_exit_observation"'
expect_rejected runtime-receipt-hash-binding \
    '(.runtime_receipt_sha256 == $receipt_sha)' \
    '((.runtime_receipt_sha256 | ascii_downcase) == $receipt_sha)'
expect_rejected raw-observation-hash-binding \
    '(.observation_sha256 == $observation_sha)' \
    '((.observation_sha256 | ascii_downcase) == $observation_sha)'
expect_rejected daemon-hash-binding \
    '(.daemon_sha256 == $viewflow_sha)' \
    '((.daemon_sha256 | ascii_downcase) == $viewflow_sha)'
expect_rejected journal-hash-binding \
    '(.command_outputs.journal_json_sha256 == .journal.slice_sha256)' \
    '((.command_outputs.journal_json_sha256 | ascii_downcase) == (.journal.slice_sha256 | ascii_downcase))'
expect_rejected journal-selected-invocation-binding \
    '(.command_outputs.journal_selected_invocation_id == .invocation_id)' \
    '(.command_outputs.journal_selected_invocation_id | type == "string")'
expect_rejected inactive-invocation-property \
    '(.command_outputs.systemctl_invocation_id == "") or' \
    '(.command_outputs.systemctl_invocation_id == .invocation_id) or'
expect_rejected post-consumption-normal-validation \
    'validate_daemon_exit_bundle' \
    'ignored_validate_daemon_exit_bundle'
expect_rejected normal-pre-consumption-live-recheck \
    'assert_old_runtime_stopped # normal-before-consumption' \
    'true # removed normal-before-consumption live recheck'
expect_rejected normal-post-consumption-live-recheck \
    'assert_old_runtime_stopped # normal-after-consumption' \
    'true # removed normal-after-consumption live recheck'
expect_rejected bootstrap-pre-consumption-live-recheck \
    'assert_old_runtime_stopped # bootstrap-before-consumption' \
    'true # removed bootstrap-before-consumption live recheck'
expect_rejected bootstrap-post-consumption-live-recheck \
    'assert_old_runtime_stopped # bootstrap-after-consumption' \
    'true # removed bootstrap-after-consumption live recheck'
expect_rejected windows-sid-binding \
    '(.tool_user_sid == $expected_sid)' \
    '(.tool_user_sid | type == "string")'
expect_rejected windows-linux-evidence-binding \
    '(.linux_frozen_evidence_sha256 == $linux_sha)' \
    '(.linux_frozen_evidence_sha256 | type == "string")'
expect_rejected force-receipt-linux-evidence-key \
    '"linux_frozen_evidence_sha256", "operation_id"' \
    '"operation_id"'
expect_rejected install-receipt-linux-evidence-key \
    '"installed_wrapper_sha256", "linux_frozen_evidence_sha256"' \
    '"installed_wrapper_sha256"'
expect_rejected exact-force-release-stability \
    '(.verification_stable_ms | uint53 and . == 500)' \
    '(.verification_stable_ms | uint53 and . >= 500)'
expect_rejected force-executable-lowercase-hash \
    '(.tool_executable_sha256 == $candidate_sha)' \
    '((.tool_executable_sha256 | ascii_downcase) == $candidate_sha)'
expect_rejected force-receipt-lowercase-hash \
    '(.force_release_receipt_sha256 == $force_sha)' \
    '((.force_release_receipt_sha256 | ascii_downcase) == $force_sha)'
expect_rejected installed-executable-lowercase-hash \
    '(.new_viewflow_executable_sha256 == $candidate_sha)' \
    '((.new_viewflow_executable_sha256 | ascii_downcase) == $candidate_sha)'
expect_rejected windows-wrapper-binding \
    '(.installed_wrapper_sha256 == $wrapper_sha)' \
    '(.installed_wrapper_sha256 | sha256)'
expect_rejected windows-task-binding \
    '(.scheduled_task_xml_sha256 == $task_xml_sha)' \
    '(.scheduled_task_xml_sha256 | sha256)'
expect_rejected bootstrap-completion-order \
    'force_epoch <= install_epoch' \
    'install_epoch <= force_epoch'
expect_rejected legacy-single-stage-bootstrap-rejection \
    "die 'single-stage v1.3 bootstrap is disabled; use bootstrap-stage-viewflow.sh then bootstrap-finalize-viewflow-deskflow.sh'" \
    "true # unsafe legacy single-stage bootstrap re-enabled"
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
expect_rejected acceptance-state-dir-creation \
    'mkdir -m 0700 -- "$VIEWFLOW_ACCEPTANCE_STATE_DIR"' \
    'mkdir -m 0755 -- "$VIEWFLOW_ACCEPTANCE_STATE_DIR"'
expect_rejected acceptance-unit-contract \
    'assert_viewflow_unit_acceptance_contract() {' \
    'ignored_viewflow_unit_acceptance_contract() {'
expect_rejected acceptance-live-viewflow-argument \
    'process_has_argument "$pid" "$VIEWFLOW_ACCEPTANCE_SOCKET"' \
    'process_has_argument "$pid" /tmp/acceptance.sock'
expect_rejected acceptance-live-state-argument \
    'process_has_argument "$pid" "$VIEWFLOW_ACCEPTANCE_STATE_DIR"' \
    'process_has_argument "$pid" /tmp/post-release-acceptance'
expect_rejected acceptance-live-deskflow-environment \
    '"DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET"' \
    '"DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=/tmp/deskflow-acceptance.sock"'
expect_rejected_after_anchor acceptance-state-dir-delete \
    '# QUARANTINE_BOUNDARY: commit' 'assert_quarantine_storage_unchanged' \
    'assert_quarantine_storage_unchanged; rm -rf -- "$VIEWFLOW_ACCEPTANCE_STATE_DIR"'

printf 'transactional installer static negative tests passed\n'
