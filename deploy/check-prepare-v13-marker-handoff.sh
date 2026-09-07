#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail
readonly PATH=/usr/bin:/bin
export PATH

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly source_script=${1:-$script_dir/prepare-v13-marker-handoff.sh}
readonly semantic_test=$script_dir/tests/prepare-v13-marker-handoff-semantic-test.sh

fail() { printf 'bootstrap marker handoff static check failed: %s\n' "$*" >&2; exit 1; }
require_fixed() { grep -Fq -- "$1" "$snapshot" || fail "missing $2"; }
require_once() {
    local count
    count=$(grep -Fc -- "$1" "$snapshot" || true)
    [[ $count == 1 ]] || fail "$2 count is $count, expected 1"
}
sha256() { sha256sum -- "$1" | awk '{print $1}'; }

[[ -f $source_script && ! -L $source_script ]] || fail 'unsafe handoff source'
snapshot_dir=$(mktemp -d)
chmod 0700 "$snapshot_dir"
trap 'rm -rf -- "$snapshot_dir"' EXIT
snapshot=$snapshot_dir/prepare.sh
before_identity=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$source_script")
before_sha=$(sha256 "$source_script")
cp -- "$source_script" "$snapshot"
chmod 0600 "$snapshot"
[[ $(stat -Lc '%d:%i:%s:%Y:%Z' -- "$source_script") == "$before_identity" &&
   $(sha256 "$source_script") == "$before_sha" && $(sha256 "$snapshot") == "$before_sha" ]] ||
    fail 'handoff source changed while snapshotted'

bash -n "$snapshot"
if command -v shellcheck >/dev/null; then shellcheck "$snapshot"; fi
if grep -Eq -- '(^|[[:space:]])(ssh|scp|sftp|powershell(\.exe)?|taskkill|Stop-ScheduledTask|Start-ScheduledTask|kill|pkill|killall)([[:space:]]|$)' "$snapshot" ||
   grep -Eq -- 'systemctl.*[[:space:]](start|stop|restart|reload|enable|disable|mask|unmask|kill|reset-failed)([[:space:]]|$)' "$snapshot"; then
    fail 'handoff helper attempts to control a service or remote host'
fi
if grep -Eq -- 'StrictHostKeyChecking=(no|accept-new)|UserKnownHostsFile=/dev/null|^[[:space:]]*(eval|source)([[:space:]]|$)|<<-?' "$snapshot"; then
    fail 'dynamic evaluation, sourcing, heredocs, or insecure SSH is forbidden'
fi

require_fixed 'readonly MARKER_CLI=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker' 'fixed installed marker CLI path'
require_fixed 'readonly MARKER_CLI_DIR=/home/wilf/.local/lib/viewflow' 'fixed marker CLI directory'
require_fixed 'readonly MARKER_CLI_PARENT=/home/wilf/.local/lib' 'fixed marker CLI parent'
require_fixed 'readonly DEPLOYMENT_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' 'fixed VFDQT001 path'
require_fixed 'readonly MARKER_STATE_DIR=/home/wilf/.local/state/viewflow' 'fixed marker state directory'
require_fixed 'readonly MARKER_STATE_PARENT=/home/wilf/.local/state' 'fixed marker state parent'
require_fixed 'readonly RUNTIME_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' 'fixed VFQST002 path'
require_fixed 'readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow' 'fixed legacy Deskflow path'
require_fixed 'readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core' 'fixed legacy core path'
require_fixed 'readonly DESKFLOW_UNIT=deskflow.service' 'fixed legacy Deskflow unit'
require_fixed 'readonly DESKFLOW_PORT=24800' 'fixed legacy Deskflow listener'
require_fixed 'readonly REQUIRED_MARKER_GENERATION=1' 'generation-1 handoff discriminator'
for option in --deployment-marker-candidate --deployment-marker-sha256 --operation-id \
    --source-display-id --target-device-id --coordinator-instance-id \
    --marker-generation --deployment-publish-receipt --bootstrap-handoff-receipt; do
    require_fixed "$option" "option $option"
done

require_fixed '[[ ! -e $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER ]]' 'marker no-clobber precondition'
require_fixed '"$MARKER_CLI" publish --operation-id "$operation_id"' 'installed CLI publish invocation'
require_once '"$MARKER_CLI" publish --operation-id "$operation_id"' 'single generation-1 publish invocation'
require_fixed '--source-display-id "$source_display_id" --target-device-id "$target_device_id"' 'source/target publish binding'
require_fixed '--coordinator-instance-id "$coordinator_instance_id"' 'coordinator publish binding'
require_fixed '--marker-generation "$marker_generation" >"$receipt_temp"' 'generation and captured receipt binding'
require_fixed '[[ $marker_generation == "$REQUIRED_MARKER_GENERATION" ]]' 'exact generation-1 validation'
require_fixed '.coordinator_instance_id == $coordinator and .marker_generation == $generation and' 'receipt coordinator/generation validation'
require_fixed '.marker_path == $marker and (.marker_sha256 | test("^[0-9a-f]{64}$"))' 'receipt path/hash validation'
require_fixed '$(stat -c '"'"'%u:%a:%h:%s'"'"' -- "$DEPLOYMENT_MARKER") == 1000:600:1:256' 'owner-only exact marker metadata'
require_fixed '$(dd if="$DEPLOYMENT_MARKER" bs=8 count=1 status=none) == VFDQT001' 'marker magic validation'
require_fixed '$(sha256 "$DEPLOYMENT_MARKER") == "$marker_sha"' 'marker byte hash binding'

require_fixed 'active_state=$(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true)' 'read-only Deskflow active-state observation'
require_fixed 'main_pid=$(systemctl --user show --property MainPID --value "$DESKFLOW_UNIT")' 'read-only Deskflow MainPID observation'
require_fixed 'deskflow_count=$(count_exact_executable_pids "$DESKFLOW_INSTALLED")' 'legacy Deskflow exact process count'
require_fixed 'core_count=$(count_exact_executable_pids "$DESKFLOW_CORE_INSTALLED")' 'legacy core exact process count'
require_fixed 'listener_count=$(ss -H -ltn "sport = :$DESKFLOW_PORT" | awk '"'"'END {print NR + 0}'"'"')' 'TCP 24800 listener count'
require_fixed '[[ $active_state == inactive && $main_pid == 0 && $deskflow_count == 0 &&' 'inactive/MainPID/process freeze predicate'
require_fixed '$core_count == 0 && $listener_count == 0 ]]' 'core/listener freeze predicate'
require_fixed '[[ ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]]' 'legacy VFQST002 absence gate'
require_once 'assert_legacy_deskflow_frozen() {' 'single legacy freeze observer definition'
freeze_count=$(grep -Fc -- 'assert_legacy_deskflow_frozen' "$snapshot" || true)
[[ $freeze_count == 4 ]] || fail "legacy freeze observer token count is $freeze_count, expected definition plus 3 gates"
first_freeze_line=$(grep -nFx -- 'assert_legacy_deskflow_frozen' "$snapshot" | head -n1 | cut -d: -f1)
directory_prepare_line=$(grep -nF -- "ensure_fixed_directory 'marker CLI directory'" "$snapshot" | cut -d: -f1)
install_cli_line=$(grep -nFx -- 'install_and_verify_marker_cli' "$snapshot" | cut -d: -f1)
publish_marker_line=$(grep -nF -- '"$MARKER_CLI" publish --operation-id "$operation_id"' "$snapshot" | cut -d: -f1)
last_freeze_line=$(grep -nFx -- 'assert_legacy_deskflow_frozen' "$snapshot" | tail -n1 | cut -d: -f1)
publish_handoff_line=$(grep -nFx -- 'publish_bootstrap_handoff_receipt' "$snapshot" | cut -d: -f1)
for ordered_line in "$first_freeze_line" "$directory_prepare_line" "$install_cli_line" \
    "$publish_marker_line" "$last_freeze_line" "$publish_handoff_line"; do
    [[ $ordered_line =~ ^[0-9]+$ ]] || fail 'missing or duplicate freeze/publication ordering token'
done
((first_freeze_line < directory_prepare_line && directory_prepare_line < install_cli_line &&
  install_cli_line < publish_marker_line && publish_marker_line < last_freeze_line &&
  last_freeze_line < publish_handoff_line)) || fail 'legacy freeze does not enclose every handoff mutation'

require_fixed 'candidate_before=$(stat -Lc '"'"'%d:%i:%s:%Y:%Z'"'"' -- "$candidate")' 'candidate identity freeze start'
require_fixed '[[ $candidate_after == "$candidate_before" && $(sha256 "/proc/$$/fd/$candidate_fd") == "$candidate_sha" ]]' 'candidate identity/hash freeze end'
require_fixed '[[ -z $(exact_executable_pids "$MARKER_CLI") ]]' 'installed CLI execution exclusion'
require_fixed 'candidate_temp=$(mktemp --tmpdir="$MARKER_CLI_DIR"' 'same-directory CLI staging'
require_fixed 'sync -f "$candidate_temp"' 'CLI bytes durability'
require_fixed 'mv -T -- "$candidate_temp" "$MARKER_CLI"' 'atomic fixed-path CLI installation'
require_fixed 'sync -f "$MARKER_CLI_DIR"' 'CLI directory durability'
require_fixed 'installed_metadata=$(stat -c '"'"'%u:%a:%h'"'"' -- "$MARKER_CLI")' 'CLI installed metadata gate'
require_fixed '$(sha256 "$MARKER_CLI") == "$candidate_sha"' 'installed CLI exact hash proof'

require_fixed 'ensure_fixed_directory '"'"'marker CLI directory'"'"' "$MARKER_CLI_DIR" "$MARKER_CLI_PARENT" 0755' 'safe fixed CLI directory preparation'
require_fixed 'ensure_fixed_directory '"'"'deployment marker directory'"'"' "$MARKER_STATE_DIR" "$MARKER_STATE_PARENT" 0700' 'safe fixed state directory preparation'
require_fixed 'require_owner_only_directory '"'"'deployment marker directory'"'"' "$MARKER_STATE_DIR"' 'owner-only state directory proof'
require_fixed 'require_new_owner_output '"'"'--deployment-publish-receipt'"'"' "$publish_receipt"' 'unused owner-only receipt destination'
require_fixed 'if [[ -e $DEPLOYMENT_MARKER && ! -e $publish_receipt ]]; then' 'fail-closed unpublished receipt retention'
require_fixed 'unpublished receipt staging retained at %s' 'actionable retained receipt diagnostic'
require_fixed 'receipt_temp=$(mktemp --tmpdir="$(dirname -- "$publish_receipt")"' 'same-directory receipt staging'
require_fixed 'chmod 0600 "$receipt_temp"' 'receipt owner-only staging'
require_fixed 'ln -- "$receipt_temp" "$publish_receipt"' 'create-once receipt publication'
require_fixed 'sync -f "$publish_receipt"' 'receipt bytes durability'
require_fixed 'sync -f "$(dirname -- "$publish_receipt")"' 'receipt directory durability'
require_fixed '$(stat -c '"'"'%u:%a:%h'"'"' -- "$publish_receipt") == 1000:600:1' 'owner-only create-once receipt proof'
require_once 'validate_published_handoff "$receipt_temp"' 'pre-publication handoff validation'
require_once 'validate_published_handoff "$publish_receipt"' 'post-publication handoff validation'

require_fixed 'require_new_owner_output '"'"'--bootstrap-handoff-receipt'"'"' "$handoff_receipt"' 'unused owner-only H receipt destination'
require_fixed '[[ $publish_receipt != "$handoff_receipt" ]]' 'distinct publish/H receipt paths'
require_fixed 'state:"viewflow-v13-marker-handoff-prepared"' 'H receipt state discriminator'
require_fixed '.deployment_publish_receipt_sha256 == $publish_sha' 'H-to-publish receipt byte binding'
require_fixed '.deskflow_unit_active_state == "inactive"' 'H inactive state binding'
require_fixed '.deskflow_unit_main_pid == 0' 'H MainPID-zero binding'
require_fixed '.deskflow_exact_process_count == 0' 'H Deskflow process-zero binding'
require_fixed '.deskflow_core_exact_process_count == 0' 'H core process-zero binding'
require_fixed '.deskflow_tcp_listener_count == 0' 'H listener-zero binding'
require_fixed '.runtime_marker_present == false' 'H VFQST002-absent binding'
require_fixed 'ln -- "$handoff_temp" "$handoff_receipt"' 'create-once H receipt publication'
require_fixed 'sync -f "$handoff_receipt"' 'H receipt bytes durability'
require_fixed '$(stat -c '"'"'%u:%a:%h'"'"' -- "$handoff_receipt") == 1000:600:1' 'owner-only create-once H receipt proof'
require_once 'validate_bootstrap_handoff_receipt "$handoff_temp"' 'pre-publication H validation'
require_once 'validate_bootstrap_handoff_receipt "$handoff_receipt"' 'post-publication H validation'
handoff_publish_count=$(grep -xc -- 'publish_bootstrap_handoff_receipt' "$snapshot" || true)
[[ $handoff_publish_count == 1 ]] || fail "H publication call count is $handoff_publish_count, expected 1"

for function_name in cleanup require_safe_owner_directory require_owner_only_directory ensure_fixed_directory require_new_owner_output \
    assert_strict_json_document exact_executable_pids count_exact_executable_pids assert_legacy_deskflow_frozen install_and_verify_marker_cli \
    validate_published_handoff validate_bootstrap_handoff_receipt publish_bootstrap_handoff_receipt; do
    definition_count=$(grep -Fxc -- "$function_name() {" "$snapshot" || true)
    [[ $definition_count == 1 ]] || fail "single $function_name definition count is $definition_count, expected 1"
done
require_once 'trap cleanup EXIT' 'single cleanup trap'

[[ $(stat -Lc '%d:%i:%s:%Y:%Z' -- "$source_script") == "$before_identity" &&
   $(sha256 "$source_script") == "$before_sha" ]] || fail 'handoff source changed during audit'

[[ -x $semantic_test ]] || fail 'semantic test is not executable'
if [[ ${VIEWFLOW_SKIP_PREPARE_HANDOFF_SEMANTIC:-0} != 1 ]]; then
    "$semantic_test" "$source_script" >/dev/null
fi

printf 'bootstrap marker handoff static check passed\n'
