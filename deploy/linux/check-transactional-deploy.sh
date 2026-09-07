#!/usr/bin/env bash
# shellcheck disable=SC2016

# Static-only audit. It reads deployment sources and never invokes systemctl,
# starts a binary, or touches a deployment marker.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly INSTALLER=${1:-$SCRIPT_DIR/install-viewflow-deskflow.sh}
readonly UNIT_FILE=$SCRIPT_DIR/viewflow-peer.service
readonly DROPIN_FILE=$SCRIPT_DIR/deskflow-viewflow.conf

# The checks below intentionally search for literal shell source fragments.

fail() {
    printf 'static deploy check failed: %s\n' "$*" >&2
    exit 1
}

require_fixed() {
    local text=$1
    local label=$2
    grep -Fq -- "$text" "$INSTALLER" || fail "missing $label"
}

require_regex() {
    local pattern=$1
    local label=$2
    grep -Eq -- "$pattern" "$INSTALLER" || fail "missing $label"
}

phase_line() {
    local phase=$1
    grep -nF -- "# TRANSACTION_PHASE: $phase" "$INSTALLER" | cut -d: -f1
}

[[ -f $INSTALLER ]] || fail "installer not found: $INSTALLER"
[[ -f $UNIT_FILE ]] || fail "unit file not found: $UNIT_FILE"
[[ -f $DROPIN_FILE ]] || fail "Deskflow drop-in not found: $DROPIN_FILE"
bash -n "$INSTALLER"

grep -Fq -- '--quiesce-proof %t/viewflow/deploy-quiesced.json' "$UNIT_FILE" ||
    fail 'unit does not configure the fixed quiescence receipt path'
grep -Fq -- '--quiesce-arm-file %t/viewflow/deploy-quiesce-arm.json' "$UNIT_FILE" ||
    fail 'unit does not configure the fixed quiescence arm path'
grep -Fq -- '--acceptance-socket %t/viewflow/post-release-acceptance.sock' "$UNIT_FILE" ||
    fail 'unit does not configure the fixed post-release acceptance socket'
grep -Fq -- '--acceptance-state-dir /home/wilf/.local/state/viewflow/post-release-acceptance' "$UNIT_FILE" ||
    fail 'unit does not configure the fixed post-release acceptance state directory'
[[ $(grep -Fc -- '--acceptance-socket' "$UNIT_FILE") == 1 &&
   $(grep -Fc -- '--acceptance-state-dir' "$UNIT_FILE") == 1 ]] ||
    fail 'unit must configure each acceptance option exactly once'
if grep -Fq -- 'viewflow-deployment-marker' "$UNIT_FILE"; then
    fail 'viewflow-peer.service must not invoke or own the coordinator-only deployment marker tool'
fi
[[ $(grep -Fxc -- \
    'Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock' \
    "$DROPIN_FILE") == 1 &&
   $(grep -Fc -- 'Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=' "$DROPIN_FILE") == 1 ]] ||
    fail 'shipped Deskflow drop-in does not bind the fixed acceptance socket exactly once'
[[ $(grep -Fxc -- \
    'Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    "$DROPIN_FILE") == 1 &&
   $(grep -Fc -- 'Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=' \
    "$DROPIN_FILE") == 1 &&
   $(grep -Fxc -- \
    'Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' \
    "$DROPIN_FILE") == 1 &&
   $(grep -Fc -- 'Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=' \
    "$DROPIN_FILE") == 1 ]] ||
    fail 'shipped Deskflow drop-in does not bind both fixed quarantine markers exactly once'

require_fixed 'readonly VIEWFLOW_INSTALLED=/home/wilf/.local/lib/viewflow/viewflowd' \
    'fixed Viewflow destination'
require_fixed \
    'readonly DEPLOYMENT_MARKER_TOOL_INSTALLED=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker' \
    'fixed deployment marker tool destination'
require_fixed 'readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow' \
    'fixed Deskflow destination'
require_fixed 'readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core' \
    'fixed deskflow-core destination'
require_fixed 'readonly VIEWFLOW_UNIT_INSTALLED=/home/wilf/.config/systemd/user/viewflow-peer.service' \
    'fixed Viewflow unit destination'
require_fixed 'readonly DESKFLOW_DROPIN_INSTALLED=/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf' \
    'fixed Deskflow drop-in destination'
require_fixed 'readonly DESKFLOW_QUARANTINE_PARENT=/home/wilf/.local/state/viewflow' \
    'fixed Deskflow quarantine parent'
require_fixed \
    'readonly DESKFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    'fixed Deskflow quarantine marker'
require_fixed 'readonly DESKFLOW_QUARANTINE_MAGIC=VFQST002' \
    'fixed Deskflow runtime marker magic'
require_fixed \
    'readonly DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' \
    'fixed Viewflow deployment quarantine marker'
require_fixed 'readonly DEPLOYMENT_QUARANTINE_MAGIC=VFDQT001' \
    'fixed deployment marker magic'
require_fixed \
    'readonly DESKFLOW_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    'fixed Deskflow quarantine environment assignment'
require_fixed \
    'readonly DEPLOYMENT_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' \
    'fixed deployment quarantine environment assignment'
require_fixed 'readonly REQUIRED_VIEWFLOW_PROTOCOL=2.1' 'protocol 2.1 gate'
require_fixed 'readonly VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/post-release-acceptance.sock' \
    'fixed Viewflow acceptance socket'
require_fixed 'readonly DESKFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock' \
    'fixed Deskflow acceptance socket'
require_fixed 'readonly VIEWFLOW_ACCEPTANCE_STATE_DIR=/home/wilf/.local/state/viewflow/post-release-acceptance' \
    'fixed acceptance state directory'
require_fixed 'assert_acceptance_state_dir() {' 'acceptance state directory validator'
require_fixed 'ensure_acceptance_state_dir() {' 'acceptance state directory creator'
require_fixed 'mkdir -m 0700 -- "$VIEWFLOW_ACCEPTANCE_STATE_DIR"' \
    'acceptance state directory owner-only creation'
require_fixed '[[ -d $VIEWFLOW_ACCEPTANCE_STATE_DIR && ! -L $VIEWFLOW_ACCEPTANCE_STATE_DIR ]]' \
    'real non-symlink acceptance state directory gate'
require_fixed '[[ $owner == "$EXPECTED_UID" && $mode == 700 ]]' \
    'uid-1000 mode-0700 acceptance state directory gate'
require_fixed 'ensure_acceptance_state_dir' 'preflight acceptance state directory creation or verification'
require_fixed 'assert_viewflow_unit_acceptance_contract() {' \
    'Viewflow unit acceptance contract validator'
require_fixed 'assert_acceptance_runtime_sockets_absent() {' \
    'post-release acceptance socket shutdown validator'
require_fixed 'assert_owner_only_socket' 'owner-only acceptance socket readiness validator'
require_fixed 'process_has_argument "$pid" "$VIEWFLOW_ACCEPTANCE_SOCKET"' \
    'live Viewflow acceptance socket argument check'
require_fixed 'process_has_argument "$pid" "$VIEWFLOW_ACCEPTANCE_STATE_DIR"' \
    'live Viewflow acceptance state-dir argument check'
require_fixed 'process_has_environment "$core_pid"' \
    'Deskflow core environment readiness check'
require_fixed '"DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET"' \
    'live Deskflow acceptance socket environment check'
require_fixed 'assert_acceptance_state_dir || failed=1' \
    'rollback acceptance-state continuity verification'
require_fixed 'assert_acceptance_runtime_sockets_absent || failed=1' \
    'rollback acceptance-socket absence verification'

require_fixed 'assert_quarantine_storage() {' 'Deskflow quarantine storage validator'
require_fixed \
    '[[ -d $DESKFLOW_QUARANTINE_PARENT && ! -L $DESKFLOW_QUARANTINE_PARENT ]]' \
    'real non-symlink quarantine parent gate'
require_fixed "stat -c '%u %a' -- \"\$DESKFLOW_QUARANTINE_PARENT\"" \
    'quarantine parent metadata query'
require_fixed \
    '[[ $parent_owner == "$EXPECTED_UID" && $parent_mode == 700 ]]' \
    'uid-1000 mode-0700 quarantine parent gate'
require_fixed \
    '[[ -e $DESKFLOW_QUARANTINE_MARKER || -L $DESKFLOW_QUARANTINE_MARKER ]]' \
    'mandatory quarantine marker presence including dangling symlinks'
require_fixed \
    "die 'Deskflow quarantine marker must exist before deployment preflight'" \
    'missing durable quarantine marker rejection'
require_fixed \
    '[[ -f $DESKFLOW_QUARANTINE_MARKER && ! -L $DESKFLOW_QUARANTINE_MARKER ]]' \
    'regular non-symlink quarantine marker gate'
require_fixed "stat -c '%u %a %h %s' -- \"\$DESKFLOW_QUARANTINE_MARKER\"" \
    'quarantine marker metadata query'
require_fixed \
    '[[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 600 &&' \
    'uid-1000 mode-0600 quarantine marker gate'
require_fixed '$marker_links == 1 && $marker_size == 152 ]]' \
    'single-link 152-byte runtime quarantine marker gate'
require_fixed '[[ $marker_magic == "$DESKFLOW_QUARANTINE_MAGIC" ]]' \
    'VFQST002 runtime marker magic gate'
require_fixed \
    '[[ -e $DEPLOYMENT_QUARANTINE_MARKER || -L $DEPLOYMENT_QUARANTINE_MARKER ]]' \
    'mandatory deployment quarantine marker presence'
require_fixed \
    "die 'Viewflow deployment quarantine marker must exist before deployment preflight'" \
    'missing deployment quarantine marker rejection'
require_fixed \
    '[[ -f $DEPLOYMENT_QUARANTINE_MARKER && ! -L $DEPLOYMENT_QUARANTINE_MARKER ]]' \
    'regular non-symlink deployment quarantine marker gate'
require_fixed "stat -c '%u %a %h %s' -- \"\$DEPLOYMENT_QUARANTINE_MARKER\"" \
    'deployment quarantine marker metadata query'
require_fixed \
    '[[ $deployment_owner == "$EXPECTED_UID" && $deployment_mode == 600 &&' \
    'uid-1000 mode-0600 deployment quarantine marker gate'
require_fixed '$deployment_links == 1 && $deployment_size == 256 ]]' \
    'single-link 256-byte deployment quarantine marker gate'
require_fixed '[[ $deployment_magic == "$DEPLOYMENT_QUARANTINE_MAGIC" ]]' \
    'VFDQT001 deployment marker magic gate'
require_fixed 'quarantine_marker_preflight_identity=' \
    'frozen quarantine marker inode identity'
require_fixed 'quarantine_marker_preflight_sha=' \
    'frozen quarantine marker byte hash'
require_fixed 'deployment_quarantine_marker_preflight_identity=' \
    'frozen deployment quarantine marker inode identity'
require_fixed 'deployment_quarantine_marker_preflight_sha=' \
    'frozen deployment quarantine marker byte hash'
[[ $(grep -Fxc -- 'quarantine_marker_preflight_identity=' "$INSTALLER") == 1 &&
   $(grep -Fxc -- 'quarantine_marker_preflight_sha=' "$INSTALLER") == 1 &&
   $(grep -Fxc -- 'deployment_quarantine_marker_preflight_identity=' "$INSTALLER") == 1 &&
   $(grep -Fxc -- 'deployment_quarantine_marker_preflight_sha=' "$INSTALLER") == 1 ]] ||
    fail 'both quarantine marker preflight identity globals must be declared exactly once'
require_fixed 'freeze_quarantine_storage() {' \
    'quarantine marker preflight freezer'
require_fixed \
    'quarantine_marker_preflight_identity=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")' \
    'quarantine marker inode capture'
require_fixed \
    'quarantine_marker_preflight_sha=$(sha256 "$DESKFLOW_QUARANTINE_MARKER")' \
    'quarantine marker hash capture'
require_fixed \
    'deployment_quarantine_marker_preflight_identity=$(' \
    'deployment quarantine marker inode capture'
require_fixed \
    'evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER"' \
    'deployment quarantine marker inode capture target'
require_fixed \
    'deployment_quarantine_marker_preflight_sha=$(sha256 "$DEPLOYMENT_QUARANTINE_MARKER")' \
    'deployment quarantine marker hash capture'
require_fixed 'assert_quarantine_storage_unchanged() {' \
    'quarantine marker continuity validator'
require_fixed \
    '[[ -n $quarantine_marker_preflight_identity &&' \
    'frozen runtime quarantine marker identity gate'
require_fixed \
    '$quarantine_marker_preflight_sha =~ ^[0-9a-f]{64}$ &&' \
    'frozen runtime quarantine marker hash gate'
require_fixed \
    '-n $deployment_quarantine_marker_preflight_identity &&' \
    'frozen deployment quarantine marker identity gate'
require_fixed \
    '$deployment_quarantine_marker_preflight_sha =~ ^[0-9a-f]{64}$ ]]' \
    'frozen deployment quarantine marker hash gate'
require_fixed '[[ $identity_before == "$quarantine_marker_preflight_identity" ]]' \
    'quarantine marker pre-hash inode continuity'
require_fixed \
    "assert_hash 'Deskflow quarantine marker' \"\$DESKFLOW_QUARANTINE_MARKER\" \\" \
    'quarantine marker byte-hash continuity'
require_fixed '"$quarantine_marker_preflight_sha"' \
    'quarantine marker frozen byte-hash binding'
require_fixed '[[ $identity_after == "$identity_before" ]]' \
    'quarantine marker post-hash inode continuity'
require_fixed \
    '[[ $deployment_identity_before == "$deployment_quarantine_marker_preflight_identity" ]]' \
    'deployment quarantine marker pre-hash inode continuity'
require_fixed \
    "assert_hash 'Viewflow deployment quarantine marker' \"\$DEPLOYMENT_QUARANTINE_MARKER\" \\" \
    'deployment quarantine marker byte-hash continuity'
require_fixed '"$deployment_quarantine_marker_preflight_sha"' \
    'deployment quarantine marker frozen byte-hash binding'
require_fixed '[[ $deployment_identity_after == "$deployment_identity_before" ]]' \
    'deployment quarantine marker post-hash inode continuity'
require_fixed 'assert_quarantine_dropin_contract() {' \
    'Deskflow quarantine drop-in validator'
require_fixed \
    "grep -Fc 'Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=' \"\$path\"" \
    'single quarantine environment assignment gate'
require_fixed 'grep -Fxc "$DESKFLOW_QUARANTINE_ENV_LINE" "$path"' \
    'exact quarantine environment assignment gate'
require_fixed \
    "grep -Fc 'Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=' \"\$path\"" \
    'single deployment quarantine environment assignment gate'
require_fixed 'grep -Fxc "$DEPLOYMENT_QUARANTINE_ENV_LINE" "$path"' \
    'exact deployment quarantine environment assignment gate'
require_fixed "grep -Fc 'Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=' \"\$path\"" \
    'single Deskflow acceptance environment assignment gate'
require_fixed 'grep -Fxc "Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET" "$path"' \
    'exact Deskflow acceptance environment assignment gate'

for option in \
    --viewflow-candidate --viewflow-sha256 \
    --deployment-marker-candidate --deployment-marker-sha256 \
    --deskflow-candidate --deskflow-sha256 \
    --deskflow-core-candidate --deskflow-core-sha256 \
    --deskflow-provenance-manifest --deskflow-provenance-sha256 \
    --viewflow-unit-candidate --viewflow-unit-sha256 \
    --deskflow-dropin-candidate --deskflow-dropin-sha256 \
    --quiesced-marker --daemon-exit-evidence --daemon-exit-observation \
    --operation-id \
    --bootstrap-linux-evidence --bootstrap-windows-force-receipt \
    --bootstrap-windows-install-receipt --windows-viewflow-sha256 \
    --windows-wrapper-sha256 --windows-task-xml-sha256 --windows-user-sid; do
    require_fixed "$option" "mandatory option $option"
done

require_fixed \
    "die 'single-stage v1.3 bootstrap is disabled; use bootstrap-stage-viewflow.sh then bootstrap-finalize-viewflow-deskflow.sh'" \
    'unconditional legacy single-stage bootstrap rejection'
require_fixed \
    "die 'single-stage v1.3 bootstrap options are disabled'" \
    'normal transaction preflight legacy bootstrap rejection'
require_fixed \
    "die 'normal schema-v4 mode requires quiescence receipt, daemon-exit evidence, and raw observation'" \
    'normal transaction exact schema-v4 evidence requirement'

require_fixed \
    'readonly REQUIRED_DESKFLOW_UPSTREAM_HEAD=760e3b99b00053647a96b405276bf614bd860075' \
    'fixed Deskflow upstream commit'
require_fixed 'validate_deskflow_provenance_manifest() (' \
    'Deskflow provenance manifest validator'
require_fixed \
    'validation_dir=$(mktemp -d "${TMPDIR:-/tmp}/viewflow-provenance-validate.XXXXXXXX")' \
    'private Deskflow provenance validation directory'
require_fixed 'chmod 0700 "$validation_dir"' \
    'owner-only Deskflow provenance validation directory'
require_fixed 'cleanup_provenance_validation() {' \
    'private Deskflow provenance validation cleanup handler'
require_fixed 'local status=$?' \
    'Deskflow provenance cleanup status preservation'
require_fixed 'trap - EXIT HUP INT TERM' \
    'Deskflow provenance cleanup recursion prevention'
require_fixed 'rm -rf -- "$validation_dir"' \
    'private Deskflow provenance validation cleanup target'
require_fixed 'exit "$status"' \
    'Deskflow provenance cleanup status restoration'
require_fixed 'trap cleanup_provenance_validation EXIT' \
    'Deskflow provenance normal cleanup trap'
require_fixed "trap 'exit 129' HUP" 'Deskflow provenance HUP cleanup trap'
require_fixed "trap 'exit 130' INT" 'Deskflow provenance INT cleanup trap'
require_fixed "trap 'exit 143' TERM" 'Deskflow provenance TERM cleanup trap'
require_fixed 'validation_copy=$validation_dir/manifest.json' \
    'fixed private Deskflow provenance validation copy'
require_fixed 'install -m 0400 -- "$path" "$validation_copy"' \
    'read-only private Deskflow provenance manifest staging'
require_fixed '--arg upstream "$REQUIRED_DESKFLOW_UPSTREAM_HEAD"' \
    'Deskflow provenance validator upstream argument binding'
require_fixed '--arg deskflow_sha "$deskflow_expected_sha"' \
    'Deskflow provenance validator Deskflow CLI hash argument'
require_fixed '--arg core_sha "$deskflow_core_expected_sha"' \
    'Deskflow provenance validator deskflow-core CLI hash argument'
require_fixed \
    "assert_strict_json_document 'Deskflow provenance manifest' \"\$validation_copy\"" \
    'Deskflow provenance duplicate-key and single-document rejection'
require_fixed \
    '(keys == ["artifacts", "build", "generated_at_utc", "kind", "protocol_version", "schema_version", "sidecar_protocol_version", "source", "upstream"])' \
    'Deskflow provenance exact top-level fields'
require_fixed \
    '.schema_version == 1 and .kind == "viewflow-deskflow-linux-provenance"' \
    'Deskflow provenance schema and kind'
require_fixed '.protocol_version == "2.1" and .sidecar_protocol_version == 3' \
    'Deskflow provenance exact Viewflow and sidecar protocol claims'
require_fixed '(.upstream | keys == ["commit", "detached_head"])' \
    'Deskflow provenance exact upstream fields'
require_fixed \
    '.upstream.commit == $upstream and .upstream.detached_head == true' \
    'Deskflow provenance fixed detached upstream binding'
require_fixed \
    '(.source | keys == ["critical_files", "modified_tracked_files", "root", "tracked_patch", "untracked_source_files"])' \
    'Deskflow provenance exact source fields'
require_fixed \
    '(keys == ["path", "sha256", "size_bytes", "status"])' \
    'Deskflow provenance exact tracked and critical entry fields'
require_fixed \
    '(keys == ["path", "sha256", "size_bytes"])' \
    'Deskflow provenance exact untracked entry fields'
require_fixed \
    '(.source.tracked_patch | keys == ["sha256", "size_bytes"])' \
    'Deskflow provenance exact tracked patch fields'
require_fixed \
    '(.source.modified_tracked_files | type == "array" and length == 8 and all(.[]; tracked_entry))' \
    'Deskflow provenance exact tracked source count and schema'
require_fixed \
    '(.source.untracked_source_files | type == "array" and length == 4 and all(.[]; untracked_entry))' \
    'Deskflow provenance exact untracked source count and schema'
require_fixed \
    '(.source.critical_files | type == "array" and length == 12 and all(.[]; critical_entry))' \
    'Deskflow provenance critical source schema'
for source_path in \
    src/apps/deskflow-core/deskflow-core.cpp \
    src/lib/arch/unix/ArchMultithreadPosix.cpp \
    src/lib/platform/PortalInputCapture.cpp \
    src/lib/platform/PortalInputCapture.h \
    src/lib/server/CMakeLists.txt \
    src/lib/server/Server.cpp \
    src/lib/server/Server.h \
    src/unittests/server/CMakeLists.txt \
    src/lib/server/ViewflowSidecarClient.cpp \
    src/lib/server/ViewflowSidecarClient.h \
    src/unittests/server/ViewflowSidecarClientTests.cpp \
    src/unittests/server/ViewflowSidecarClientTests.h; do
    require_fixed "\"$source_path\"" \
        "Deskflow provenance source allowlist entry $source_path"
done
require_fixed \
    '(.build | keys == ["build_type", "cmake", "compilers", "directory", "generator", "live_acceptance", "ninja"])' \
    'Deskflow provenance exact build fields'
require_fixed \
    '(.build.cmake | keys == ["cache_sha256", "cache_size_bytes", "executable", "executable_sha256", "verify_globs_sha256", "verify_globs_size_bytes", "version"])' \
    'Deskflow provenance exact CMake fields'
require_fixed \
    '(.build.ninja | keys == ["build_file_sha256", "build_file_size_bytes", "executable", "executable_sha256", "pending_rebuild", "rules_file_sha256", "rules_file_size_bytes", "version"])' \
    'Deskflow provenance exact Ninja fields'
require_fixed '(.build.ninja.rules_file_sha256 | sha256)' \
    'Deskflow provenance Ninja rules file hash'
require_fixed \
    '(.build.ninja.rules_file_size_bytes | uint53 and . > 0)' \
    'Deskflow provenance Ninja rules file size'
require_fixed '(.build.compilers | keys == ["c", "cxx"])' \
    'Deskflow provenance exact compiler identities'
require_fixed \
    'keys == ["executable_sha256", "path", "version"]' \
    'Deskflow provenance exact compiler fields'
require_fixed '.build.ninja.pending_rebuild == false' \
    'Deskflow provenance clean Ninja graph gate'
require_fixed 'def live_acceptance:' \
    'Deskflow provenance live-acceptance predicate'
require_fixed \
    '(keys == ["arm_magic", "core_query", "enabled", "peer_auth", "protocol_version", "receipt_magic", "receipt_size", "sidecar_protocol_version", "socket_kind"])' \
    'Deskflow provenance live-acceptance exact fields'
require_fixed \
    '.enabled == true and .socket_kind == "af_unix" and' \
    'Deskflow provenance enabled AF_UNIX acceptance binding'
require_fixed \
    '.peer_auth == "so_peercred_same_uid" and .arm_magic == "VFARM001" and' \
    'Deskflow provenance peer-auth and arm-magic binding'
require_fixed \
    '.receipt_magic == "VFRCP001" and .receipt_size == 568 and' \
    'Deskflow provenance receipt identity binding'
require_fixed \
    '.protocol_version == "2.1" and .sidecar_protocol_version == 3 and' \
    'Deskflow provenance acceptance protocol binding'
require_fixed '.core_query == true;' \
    'Deskflow provenance compiled-core query binding'
require_fixed '(.build.live_acceptance | live_acceptance)' \
    'Deskflow provenance live-acceptance validator invocation'
require_fixed '(.artifacts | keys == ["deskflow", "deskflow_core"])' \
    'Deskflow provenance exact artifacts'
require_fixed \
    '(keys == ["elf_build_id", "sha256", "size_bytes", "source_path"])' \
    'Deskflow provenance exact artifact fields'
require_fixed '.artifacts.deskflow.sha256 == $deskflow_sha' \
    'Deskflow manifest hash binding to CLI candidate hash'
require_fixed '.artifacts.deskflow_core.sha256 == $core_sha' \
    'deskflow-core manifest hash binding to CLI candidate hash'
require_fixed \
    '.artifacts.deskflow.source_path == (.build.directory + "/bin/deskflow")' \
    'Deskflow artifact path binding to the manifested build directory'
require_fixed \
    '.artifacts.deskflow_core.source_path == (.build.directory + "/bin/deskflow-core")' \
    'deskflow-core artifact path binding to the manifested build directory'
require_fixed \
    '[[ $(stat -c '\''%s'\'' -- "$deskflow_candidate") == "$deskflow_size" ]] ||' \
    'Deskflow artifact size binding'
require_fixed \
    '[[ $(stat -c '\''%s'\'' -- "$deskflow_core_candidate") == "$core_size" ]] ||' \
    'deskflow-core artifact size binding'
require_fixed \
    '[[ $(elf_build_id "$deskflow_candidate") == "$deskflow_build_id" ]] ||' \
    'Deskflow artifact build-ID binding'
require_fixed \
    '[[ $(elf_build_id "$deskflow_core_candidate") == "$core_build_id" ]] ||' \
    'deskflow-core artifact build-ID binding'
require_fixed \
    'deskflow_size=$(jq -er '\''.artifacts.deskflow.size_bytes'\'' "$validation_copy")' \
    'Deskflow artifact manifest size extraction'
require_fixed \
    'deskflow_build_id=$(jq -er '\''.artifacts.deskflow.elf_build_id'\'' "$validation_copy")' \
    'Deskflow artifact manifest build-ID extraction'
require_fixed \
    'core_size=$(jq -er '\''.artifacts.deskflow_core.size_bytes'\'' "$validation_copy")' \
    'deskflow-core artifact manifest size extraction'
require_fixed \
    'core_build_id=$(jq -er '\''.artifacts.deskflow_core.elf_build_id'\'' "$validation_copy")' \
    'deskflow-core artifact manifest build-ID extraction'
require_fixed "' \"\$validation_copy\" >/dev/null ||" \
    'Deskflow provenance jq validation of the private copy'
require_fixed 'readelf -n -- "$path"' 'ELF build-ID extraction with readelf'
require_fixed '[[ $build_id =~ ^[0-9a-f]+$ ]]' \
    'lowercase ELF build-ID syntax gate'
require_fixed \
    'require_sha256 '\''--deskflow-provenance-sha256'\'' "$deskflow_provenance_expected_sha"' \
    'Deskflow provenance CLI hash syntax gate'
require_fixed \
    'deskflow_provenance_preflight_identity=$(evidence_identity' \
    'Deskflow provenance preflight file identity capture'
require_fixed \
    'deskflow_provenance_preflight_sha=$(sha256 "$deskflow_provenance_manifest")' \
    'Deskflow provenance preflight byte hash capture'
require_fixed \
    '[[ $deskflow_provenance_preflight_sha == "$deskflow_provenance_expected_sha" ]] ||' \
    'Deskflow provenance preflight hash binding'
require_fixed \
    "assert_evidence_unchanged 'Deskflow provenance manifest'" \
    'Deskflow provenance commit-boundary identity and hash gate'

mapfile -t staged_manifest_hash_lines < <(
    grep -nF -- \
        '[[ $(sha256 "$validation_copy") == "$deskflow_provenance_expected_sha" ]] ||' \
        "$INSTALLER" | cut -d: -f1
)
[[ ${#staged_manifest_hash_lines[@]} == 2 ]] ||
    fail 'private Deskflow provenance copy must be hash-checked before and after validation'
provenance_validator_line=$(
    grep -nF -- 'validate_deskflow_provenance_manifest() (' "$INSTALLER" | cut -d: -f1
)
provenance_private_dir_line=$(
    grep -nF -- 'validation_dir=$(mktemp -d' "$INSTALLER" | cut -d: -f1
)
provenance_private_install_line=$(
    grep -nF -- 'install -m 0400 -- "$path" "$validation_copy"' \
        "$INSTALLER" | cut -d: -f1
)
provenance_private_parse_line=$(
    grep -nF -- \
        "assert_strict_json_document 'Deskflow provenance manifest' \"\$validation_copy\"" \
        "$INSTALLER" | cut -d: -f1
)
evidence_identity_line=$(grep -nF -- 'evidence_identity() {' "$INSTALLER" | cut -d: -f1)
[[ $provenance_validator_line =~ ^[0-9]+$ &&
   $provenance_private_dir_line =~ ^[0-9]+$ &&
   $provenance_private_install_line =~ ^[0-9]+$ &&
   $provenance_private_parse_line =~ ^[0-9]+$ &&
   $evidence_identity_line =~ ^[0-9]+$ ]] ||
    fail 'private Deskflow provenance validation boundaries are missing or duplicated'
((provenance_validator_line < provenance_private_dir_line &&
  provenance_private_dir_line < provenance_private_install_line &&
  provenance_private_install_line < staged_manifest_hash_lines[0] &&
  staged_manifest_hash_lines[0] < provenance_private_parse_line &&
  provenance_private_parse_line < staged_manifest_hash_lines[1] &&
  staged_manifest_hash_lines[1] < evidence_identity_line)) ||
    fail 'private Deskflow provenance staging and hash checks are out of order'

mapfile -t provenance_validation_lines < <(
    grep -nF -- \
        'validate_deskflow_provenance_manifest "$deskflow_provenance_manifest"' \
        "$INSTALLER" | cut -d: -f1
)
[[ ${#provenance_validation_lines[@]} == 2 ]] ||
    fail 'Deskflow provenance must be validated exactly at preflight and commit boundary'
preflight_line=$(grep -nF -- 'preflight() {' "$INSTALLER" | cut -d: -f1)
transaction_line=$(grep -nF -- 'deploy_transaction() {' "$INSTALLER" | cut -d: -f1)
provenance_commit_guard_line=$(
    grep -nF -- "assert_evidence_unchanged 'Deskflow provenance manifest'" \
        "$INSTALLER" | cut -d: -f1
)
[[ $preflight_line =~ ^[0-9]+$ && $transaction_line =~ ^[0-9]+$ &&
   $provenance_commit_guard_line =~ ^[0-9]+$ ]] ||
    fail 'Deskflow provenance validation boundaries are missing or duplicated'
((preflight_line < provenance_validation_lines[0] &&
  provenance_validation_lines[0] < transaction_line &&
  transaction_line < provenance_commit_guard_line &&
  provenance_commit_guard_line < provenance_validation_lines[1])) ||
    fail 'Deskflow provenance validation is not ordered at both transaction boundaries'

require_fixed '(.schema_version == 4)' 'receipt schema validation'
require_fixed 'assert_strict_json_document' 'single-document duplicate-key JSON rejection'
require_fixed '(keys == ["artifact_hashes", "boot_id", "cleanup", "completed_at_unix_ms",' \
    'normal receipt exact top-level fields'
require_fixed 'def sha256: type == "string" and test("^[0-9a-f]{64}$");' \
    'lowercase SHA-256 predicate'
require_fixed '(.daemon_sha256 | sha256)' 'receipt lowercase daemon hash gate'
require_fixed '(.daemon_sha256 == $viewflow_sha)' \
    'receipt binding to the exited daemon hash'
require_fixed '(.operation_id == $operation_id)' 'receipt binding to this deployment operation'
require_fixed 'def uint53:' 'strict JSON integer predicate'
require_fixed '. == floor and . >= 0 and . <= 9007199254740991' 'safe integer domain'
require_fixed '(.daemon_start_ticks | uint53 and . > 0)' 'daemon start-time identity'
require_fixed '.boot_id | type == "string"' 'boot identity'
require_fixed '(.protocol_version == $required_protocol)' 'exact receipt protocol gate'
require_fixed '(.completed_at_unix_ms | uint53 and . > 0)' 'integer completion timestamp'
require_fixed 'uint53 and . > 0 and . < 9007199254740991' \
    'overflow-safe lease generation'
require_fixed 'uint53 and . < 9007199254740991' 'overflow-safe input sequence'
require_fixed '.cleanup.release_all.status == "applied"' 'ReleaseAll Applied evidence'
require_fixed \
    'keys == ["event_sequence", "lease_generation", "result",' \
    'ReleaseAll ACK exact evidence fields prefix'
require_fixed '"target_device"]) and' \
    'ReleaseAll ACK exact evidence fields suffix'
require_fixed \
    '.cleanup.release_all.ack.lease_generation == .cleanup.active_lease_generation' \
    'ReleaseAll ACK generation identity'
require_fixed '.cleanup.release_all.ack.target_device == $target' \
    'ReleaseAll ACK target identity'
require_fixed '.cleanup.release_all.ack.event_sequence ==' 'ReleaseAll ACK sequence binding'
require_fixed '(.cleanup.lease_revoke | keys == ["ack", "generation", "status"])' \
    'lease revoke exact evidence fields'
require_fixed 'keys == ["lease_generation", "operation_id", "owner_device",' \
    'lease revoke ACK exact evidence fields prefix'
require_fixed '"result", "state", "target_device"]) and' \
    'lease revoke ACK exact evidence fields suffix'
require_fixed '.cleanup.lease_revoke.status == "applied"' \
    'lease revoke Applied evidence'
require_fixed \
    '.cleanup.lease_revoke.generation == (.cleanup.active_lease_generation + 1)' \
    'lease revoke generation transition identity'
require_fixed 'type == "string" and test("^[0-9a-f]{32}$")' \
    'lease revoke ACK lowercase operation-id format'
require_fixed '.cleanup.lease_revoke.ack.operation_id' \
    'lease revoke ACK operation identity'
require_fixed \
    '.cleanup.lease_revoke.ack.operation_id != "00000000000000000000000000000000"' \
    'lease revoke ACK nonzero operation identity'
require_fixed "[[ \${revoke_operation_id:0:16} == \"\$(printf '%016x' \"\$bound_peer_epoch\")\" ]]" \
    'lease revoke ACK peer epoch binding'
require_fixed '.cleanup.lease_revoke.ack.lease_generation == .cleanup.lease_revoke.generation' \
    'lease revoke ACK generation binding'
require_fixed '.cleanup.lease_revoke.ack.owner_device == $local_device' \
    'lease revoke ACK owner binding'
require_fixed '.cleanup.lease_revoke.ack.target_device == $target' \
    'lease revoke ACK target binding'
require_fixed '.cleanup.lease_revoke.ack.state == "revoked"' \
    'lease revoke ACK terminal state'
require_fixed '.cleanup.lease_revoke.ack.result == "applied"' \
    'lease revoke ACK result'
require_fixed '(.cleanup.bound_peer_epoch | uint53 and . > 0)' \
    'lease revoke ACK nonzero bound peer epoch'
require_fixed '(.cleanup.bound_peer_epoch | uint53 and . > 0)' \
    'lease revoke ACK positive bound peer epoch'
require_regex \
    '^[[:space:]]+\.cleanup\.lease_revoke\.ack\.operation_id\[0:16\] ==$' \
    'lease revoke ACK operation peer-epoch half'
require_regex '^[[:space:]]+\(\.cleanup\.bound_peer_epoch \| hex16\) and$' \
    'lease revoke ACK operation peer-epoch value'
require_regex \
    '^[[:space:]]+\.cleanup\.lease_revoke\.ack\.operation_id\[16:32\] !=$' \
    'lease revoke ACK operation nonzero counter half'
require_regex '^[[:space:]]+"0000000000000000" and$' \
    'lease revoke ACK operation nonzero counter value'
require_fixed '(.cleanup.bound_peer_socket | type == "string")' \
    'lease revoke ACK bound peer socket identity'
require_fixed '$socket_parts[0] == $peer' \
    'lease revoke ACK bound peer address identity'
require_fixed '.cleanup.lease_revoke.ack == null' \
    'inactive route rejects revoke ACK evidence'
require_fixed '.cleanup.source_display == $source_display' \
    'active route source display binding'
require_fixed '(.cleanup.route_generation | uint53 and . > 0)' \
    'active route generation binding'
if grep -Fq 'not_required_no_bound_peer' "$INSTALLER"; then
    fail 'active unbound route must not bypass ReleaseAll Applied evidence'
fi
require_fixed '.route_status == "removed"' 'route removal evidence'
require_fixed '.peer_disconnect_status == "initiated_before_daemon_exit"' \
    'daemon-exit disconnect evidence'
require_fixed '.daemon_exit_required == true' 'required daemon exit'
require_fixed '.sidecar_session_disconnected == true' 'sidecar disconnect evidence'
for artifact in \
    linux_viewflowd linux_peer_certificate linux_peer_private_key linux_certificate_authority; do
    require_fixed ".artifact_hashes.$artifact" "runtime artifact hash $artifact"
done
require_fixed '[[ ! -e /proc/$daemon_pid ]]' 'receipt daemon exit confirmation'
require_fixed '[[ $boot_id == "$(tr -d' 'current-boot binding'
require_fixed 'assert_evidence_unchanged' 'commit-boundary evidence identity and hash check'
require_fixed 'assert_evidence_on_backup_filesystem' 'same-filesystem evidence consumption gate'
require_fixed "mv -T -- \"\$quiesced_marker\" \"\$backup_dir/quiesced-marker.json\"" \
    'single-use marker consumption'
require_fixed 'mv -T -- "$daemon_exit_evidence" "$backup_dir/viewflow-daemon-exited.json"' \
    'single-use normal daemon-exit evidence consumption'
require_fixed 'mv -T -- "$daemon_exit_observation"' \
    'single-use normal daemon-exit observation consumption'
require_fixed 'receipt_sha=$(sha256 "$receipt_path")' \
    'runtime receipt byte hash recomputation'
require_fixed 'observation_sha=$(sha256 "$observation_path")' \
    'daemon-exit observation byte hash recomputation'
require_fixed '(.runtime_receipt_sha256 | sha256)' \
    'daemon-exit receipt lowercase hash gate'
require_fixed '(.runtime_receipt_sha256 == $receipt_sha)' \
    'daemon-exit evidence binding to runtime receipt bytes'
require_fixed '(.observation_sha256 | sha256)' \
    'daemon-exit observation lowercase hash gate'
require_fixed '(.observation_sha256 == $observation_sha)' \
    'daemon-exit evidence binding to raw observation bytes'
require_fixed '(.command_outputs.journal_json_sha256 | sha256)' \
    'daemon-exit journal command lowercase hash gate'
require_fixed '(.command_outputs.journal_json_sha256 == .journal.slice_sha256)' \
    'daemon-exit journal hash binding'
require_fixed '"journal_json_sha256", "journal_selected_invocation_id",' \
    'normal daemon-exit recovered invocation command field'
require_fixed '(.command_outputs.journal_selected_invocation_id == .invocation_id)' \
    'normal daemon-exit journal-selected invocation binding'
require_fixed '(.command_outputs.systemctl_invocation_id == "") or' \
    'inactive systemd InvocationID empty-value allowance'
require_fixed 'validate_daemon_exit_bundle \
            "$backup_dir/quiesced-marker.json"' \
    'post-consumption normal bundle validation from backup'
require_regex '^[[:space:]]*validate_daemon_exit_bundle[[:space:]]*\\$' \
    'exact normal bundle validation call'
require_fixed 'assert_evidence_unchanged '\
"'consumed daemon-exit evidence'" \
    'post-consumption daemon-exit evidence identity and hash check'
require_fixed 'assert_evidence_unchanged '\
"'consumed daemon-exit raw observation'" \
    'post-consumption raw observation identity and hash check'
for boundary in \
    normal-before-consumption normal-after-consumption \
    bootstrap-before-consumption bootstrap-after-consumption; do
    require_fixed "assert_old_runtime_stopped # $boundary" \
        "live stopped-state recheck at $boundary"
done
if grep -Fq 'ascii_downcase' "$INSTALLER"; then
    fail 'installer normalizes evidence hashes instead of requiring lowercase originals'
fi
require_fixed 'mv -T -- "$bootstrap_linux_evidence"' 'Linux bootstrap evidence consumption'
require_fixed 'mv -T -- "$bootstrap_windows_force_receipt"' 'Windows force receipt consumption'
require_fixed 'mv -T -- "$bootstrap_windows_install_receipt"' 'Windows install receipt consumption'
require_fixed '(.tool_user_sid == $expected_sid)' 'force receipt expected SID binding'
require_fixed '(.new_process_user_sid == $expected_sid)' 'install receipt expected SID binding'
require_fixed '"linux_frozen_evidence_sha256", "operation_id"' \
    'force receipt canonical Linux evidence hash field'
require_fixed '"installed_wrapper_sha256", "linux_frozen_evidence_sha256"' \
    'install receipt canonical Linux evidence hash field'
[[ $(grep -Fc -- '(.linux_frozen_evidence_sha256 == $linux_sha)' "$INSTALLER") == 2 ]] ||
    fail 'both Windows receipts must bind to the actual Linux frozen evidence hash'
require_fixed '(.verification_stable_ms | uint53 and . == 500)' \
    'exact frozen force-release verification duration'
require_fixed '(.tool_executable_sha256 == $candidate_sha)' \
    'exact lowercase Windows force executable hash binding'
require_fixed '(.force_release_receipt_sha256 == $force_sha)' \
    'exact lowercase force receipt byte hash binding'
require_fixed '(.new_viewflow_executable_sha256 == $candidate_sha)' \
    'exact lowercase Windows installed executable hash binding'
require_fixed '(.installed_wrapper_sha256 == $wrapper_sha)' \
    'expected Windows wrapper hash binding'
require_fixed '(.scheduled_task_xml_sha256 == $task_xml_sha)' \
    'expected Windows task XML hash binding'
require_fixed 'validate_bootstrap_bundle' 'post-consumption bootstrap bundle validation'
require_fixed '(.journal.query_boot_id == (.daemon.boot_id | gsub("-"; "")))' \
    'normalized bootstrap journal boot ID schema binding'
require_fixed '"_BOOT_ID=$journal_boot_id"' 'normalized bootstrap journal replay query'
require_fixed '((force_epoch <= install_epoch))' \
    'same-host Windows receipt completion ordering'
if grep -Fq 'linux_epoch <= force_epoch + 30' "$INSTALLER"; then
    fail 'Windows force-release may not precede Linux frozen evidence'
fi

require_fixed 'install -m 0755 -- "$VIEWFLOW_INSTALLED" "$backup_dir/viewflowd"' \
    'Viewflow backup'
require_fixed 'install -m 0755 -- "$DEPLOYMENT_MARKER_TOOL_INSTALLED"' \
    'deployment marker tool backup'
require_fixed '"$backup_dir/viewflow-deployment-marker"' \
    'fixed deployment marker tool backup name'
require_fixed 'install -m 0755 -- "$DESKFLOW_INSTALLED" "$backup_dir/deskflow"' \
    'Deskflow backup'
require_fixed 'install -m 0755 -- "$DESKFLOW_CORE_INSTALLED" "$backup_dir/deskflow-core"' \
    'deskflow-core backup'
require_fixed 'install -m 0644 -- "$VIEWFLOW_UNIT_INSTALLED" "$backup_dir/viewflow-peer.service"' \
    'Viewflow unit backup'
require_fixed 'install -m 0644 -- "$DESKFLOW_DROPIN_INSTALLED" "$backup_dir/deskflow-viewflow.conf"' \
    'Deskflow drop-in backup'
require_fixed 'restore_runtime_files || failed=1' 'automatic file rollback'
require_fixed 'atomic_install "$backup_dir/viewflow-deployment-marker"' \
    'deployment marker tool rollback source'
require_fixed '"$DEPLOYMENT_MARKER_TOOL_INSTALLED" 0755 || failed=1' \
    'deployment marker tool rollback destination and mode'
require_fixed 'atomic_install "$backup_dir/viewflow-peer.service" "$VIEWFLOW_UNIT_INSTALLED" 0644' \
    'Viewflow unit rollback'
require_fixed 'atomic_install "$backup_dir/deskflow-viewflow.conf" "$DESKFLOW_DROPIN_INSTALLED" 0644' \
    'Deskflow drop-in rollback'
require_fixed 'systemctl --user daemon-reload || failed=1' 'rollback daemon reload'
require_fixed 'assert_loaded_unit_configuration || failed=1' 'rollback loaded-config verification'
require_fixed 'atomic_install "$viewflow_unit_candidate" "$VIEWFLOW_UNIT_INSTALLED" 0644' \
    'Viewflow unit candidate install'
require_fixed 'atomic_install "$deskflow_dropin_candidate" "$DESKFLOW_DROPIN_INSTALLED" 0644' \
    'Deskflow drop-in candidate install'
require_fixed 'atomic_install "$deployment_marker_tool_candidate"' \
    'deployment marker tool candidate install source'
require_fixed '"$DEPLOYMENT_MARKER_TOOL_INSTALLED" 0755' \
    'deployment marker tool candidate install destination and mode'
require_fixed 'assert_executable_artifact_metadata() {' \
    'deployment marker executable metadata validator'
require_fixed "stat -c '%u %a %h' -- \"\$path\"" \
    'deployment marker owner mode and link metadata query'
require_fixed '[[ $owner == "$EXPECTED_UID" && $mode == 755 && $links == 1 ]]' \
    'deployment marker exact uid mode and link gate'
require_fixed 'assert_hash '\''deployment marker tool candidate'\''' \
    'deployment marker candidate hash gate'
require_fixed 'assert_hash '\''installed deployment marker tool candidate'\''' \
    'installed deployment marker candidate hash gate'
require_fixed 'assert_hash '\''rollback deployment marker tool'\''' \
    'rolled-back deployment marker hash gate'
require_fixed 'assert_deployment_marker_tool_stopped() {' \
    'deployment marker exact-process quiescence validator'
require_fixed 'exact_executable_pids "$DEPLOYMENT_MARKER_TOOL_INSTALLED"' \
    'deployment marker exact executable process lookup'
require_fixed 'assert_deployment_marker_tool_stopped || return 1' \
    'deployment marker rollback overwrite guard'
require_fixed 'FragmentPath' 'Viewflow loaded fragment verification'
require_fixed 'DropInPaths' 'Deskflow loaded drop-in verification'
require_fixed 'assert_loaded_unit_configuration' 'post-reload loaded-config verification'
require_fixed "automatic rollback completed with both units inactive" \
    'fail-closed rollback state'
require_fixed 'cross-host protocol compatibility must be confirmed' \
    'manual recovery warning'

require_fixed 'systemctl --user is-active' 'systemd active-state checks'
require_fixed 'systemctl --user show --property MainPID' 'systemd MainPID checks'
require_fixed 'readlink -f -- "/proc/$pid/exe"' 'running executable identity checks'
require_fixed 'exact_pids == "$pid"' 'single Viewflow process check'
require_fixed 'deskflow_pids == "$pid"' 'single Deskflow GUI process check'
require_fixed 'core_pids == "$core_pid"' 'single deskflow-core process check'
require_fixed 'assert_sidecar_socket' 'owner-only sidecar readiness check'
require_fixed 'assert_socket_owned_by_pid udp "$VIEWFLOW_PORT" "$pid"' \
    'Viewflow UDP ownership check'
require_fixed 'assert_socket_owned_by_pid tcp "$DESKFLOW_PORT" "$core_pid"' \
    'Deskflow TCP ownership check'
require_fixed 'invocation_has_protocol_log "$invocation_id" "$expected_protocol"' \
    'per-invocation protocol log check'
require_fixed 'invocation_has_authenticated_health "$invocation_id"' \
    'per-invocation authenticated peer health check'
require_fixed 'process_has_argument "$pid" --quiesce-proof' 'quiescence receipt CLI identity'
require_fixed 'process_has_argument "$pid" --quiesce-arm-file' 'quiescence arm CLI identity'
require_fixed 'process_has_environment "$pid" "DESKFLOW_VIEWFLOW_SCREEN=$DESKFLOW_SCREEN"' \
    'Deskflow route environment check'
require_fixed \
    '"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_MARKER"' \
    'live Deskflow quarantine environment check'
[[ $(grep -Fc -- \
    '"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_MARKER"' \
    "$INSTALLER") == 2 ]] ||
    fail 'both Deskflow GUI and core processes must expose the quarantine marker environment'
require_fixed \
    '"DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$DEPLOYMENT_QUARANTINE_MARKER"' \
    'live deployment quarantine environment check'
[[ $(grep -Fc -- \
    '"DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$DEPLOYMENT_QUARANTINE_MARKER"' \
    "$INSTALLER") == 2 ]] ||
    fail 'both Deskflow GUI and core processes must expose the deployment quarantine marker environment'

assert_quarantine_boundary() {
    local boundary=$1 expected=$2 line actual
    line=$(grep -nF -- "# QUARANTINE_BOUNDARY: $boundary" "$INSTALLER" | cut -d: -f1)
    [[ $line =~ ^[0-9]+$ ]] || fail "missing or duplicate quarantine boundary: $boundary"
    actual=$(sed -n "$((line + 1))p" "$INSTALLER")
    [[ $actual == "$expected" ]] ||
        fail "unexpected quarantine validation at boundary $boundary"
}

assert_quarantine_boundary preflight '    freeze_quarantine_storage'
assert_quarantine_boundary commit '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary before-stop-deskflow '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary after-stop-deskflow '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary after-stop-viewflow '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary after-config-install '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary after-reload '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary after-deskflow-readiness '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary rollback-before-stop \
    '    assert_quarantine_storage_unchanged || failed=1'
assert_quarantine_boundary rollback-before-restore \
    '    assert_quarantine_storage_unchanged || return 1'
assert_quarantine_boundary rollback-after-reload \
    '    assert_quarantine_storage_unchanged || failed=1'
assert_quarantine_boundary rollback-final-proof \
    '    assert_quarantine_storage_unchanged || failed=1'
require_fixed 'assert_quarantine_dropin_contract "$deskflow_dropin_candidate"' \
    'candidate quarantine drop-in validation'
require_fixed 'assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED"' \
    'installed and restored quarantine drop-in validation'
[[ $(grep -Fc -- \
    'assert_quarantine_dropin_contract "$deskflow_dropin_candidate"' \
    "$INSTALLER") == 2 ]] ||
    fail 'candidate quarantine drop-in must be validated at preflight and commit boundaries'
[[ $(grep -Fc -- \
    'assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED"' \
    "$INSTALLER") == 4 ]] ||
    fail 'installed quarantine drop-in must be validated before backup, at commit, after install, and after restore'

mapfile -t phases < <(
    for phase in \
        consume-single-use-quiescence-evidence \
        stop-deskflow-before-viewflow \
        stop-viewflow \
        install-viewflow-v2 \
        install-deployment-marker-tool \
        install-runtime-unit-configuration \
        reload-runtime-unit-configuration \
        start-and-prove-viewflow-v2 \
        install-patched-deskflow \
        start-and-prove-patched-deskflow; do
        line=$(phase_line "$phase")
        [[ $line =~ ^[0-9]+$ ]] || fail "missing or duplicate transaction phase: $phase"
        printf '%s\n' "$line"
    done
)
[[ ${#phases[@]} == 10 ]] || fail 'one or more transaction phases are missing or duplicated'
for ((index = 1; index < ${#phases[@]}; index++)); do
    ((phases[index - 1] < phases[index])) || fail 'transaction phases are out of order'
done

require_regex "trap 'handle_failure .* ERR" 'ERR rollback trap'
[[ $(grep -Ec 'rm[[:space:]]+-rf' "$INSTALLER") == 1 ]] ||
    fail 'installer contains an unexpected recursive removal'
if grep -Eq 'kill[[:space:]]+-9|pkill|killall|systemctl[[:space:]]+--user[[:space:]]+restart' \
    "$INSTALLER"; then
    fail 'installer contains a force-kill or restart shortcut'
fi
if grep -Eq \
    '((DEPLOYMENT_MARKER_TOOL_INSTALLED|/home/wilf/\.local/lib/viewflow/viewflow-deployment-marker).*\b(publish|release)\b|\b(publish|release)\b.*(DEPLOYMENT_MARKER_TOOL_INSTALLED|/home/wilf/\.local/lib/viewflow/viewflow-deployment-marker))' \
    "$INSTALLER"; then
    fail 'installer must never publish or release deployment quarantine'
fi
if grep -Eq \
    '(^|[;&|[:space:]])(rm|unlink|mv|truncate|shred|touch|install|cp|dd|tee|chmod|chown|chgrp)([[:space:]]|$)[^#]*(DESKFLOW_QUARANTINE_MARKER|DEPLOYMENT_QUARANTINE_MARKER|deskflow-quarantine\.v2|deployment-quarantine\.v1)' \
    "$INSTALLER"; then
    fail 'installer may validate but must not mutate the durable quarantine marker'
fi
if grep -Eq \
    '>[>]?[[:space:]]*"?(\$\{?(DESKFLOW_QUARANTINE_MARKER|DEPLOYMENT_QUARANTINE_MARKER)|/home/wilf/\.local/state/viewflow/(deskflow-quarantine\.v2|deployment-quarantine\.v1))' \
    "$INSTALLER"; then
    fail 'installer may not redirect output into the durable quarantine marker'
fi
if grep -Eq \
    '(^|[;&|[:space:]])(rm|unlink|mv|truncate|shred|touch|install|cp|dd|tee|chmod|chown|chgrp)([[:space:]]|$)[^#]*(VIEWFLOW_ACCEPTANCE_STATE_DIR|post-release-acceptance)' \
    "$INSTALLER"; then
    fail 'installer must not mutate post-release acceptance evidence storage'
fi
if grep -Eq \
    '>[>]?[[:space:]]*"?(\$\{?VIEWFLOW_ACCEPTANCE_STATE_DIR|/home/wilf/\.local/state/viewflow/post-release-acceptance)' \
    "$INSTALLER"; then
    fail 'installer may not redirect output into post-release acceptance evidence storage'
fi
if grep -Eq \
    '(^|[;&|[:space:]])(rm|unlink|mv|truncate|shred|touch|install|cp|dd|tee|mkdir|chmod|chown|chgrp)([[:space:]]|$)[^#]*DESKFLOW_QUARANTINE_PARENT' \
    "$INSTALLER"; then
    fail 'installer must not mutate durable quarantine storage'
fi

printf 'transactional Linux deployment static checks passed\n'
