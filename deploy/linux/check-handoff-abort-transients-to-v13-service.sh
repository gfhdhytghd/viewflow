#!/usr/bin/env bash

set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

source_file=${1:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/handoff-abort-transients-to-v13-service.sh"}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_text() { grep -Fq -- "$2" "$1" || die "missing contract text: $2"; }
reject_text() { ! grep -Fq -- "$2" "$1" || die "forbidden contract text: $2"; }
function_body() {
    local name=$1
    awk -v start="${name}() {" '
        $0 == start {inside=1}
        inside {print}
        inside && /^}$/ {exit}
    ' "$source_file"
}
body_line() {
    local body=$1 token=$2
    grep -Fn -- "$token" <<<"$body" | head -n1 | cut -d: -f1 || true
}
require_order() {
    local body=$1 first=$2 second=$3 a b
    a=$(body_line "$body" "$first"); b=$(body_line "$body" "$second")
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $a -lt $b ]] ||
        die "required order missing: $first before $second"
}
require_exact_body_line() {
    local body=$1 line=$2
    [[ $(grep -Fxc -- "$line" <<<"$body") == 1 ]] || die "required executable line missing: $line"
}

[[ -f $source_file && ! -L $source_file ]] || die 'handoff source must be a regular file'
bash -n "$source_file"

for token in LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH BASH_ENV ENV 'readonly PATH=/usr/bin:/bin'; do
    require_text "$source_file" "$token"
done
require_text "$source_file" 'unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH BASH_ENV ENV'
for option in --operation-id --terminal-receipt --terminal-receipt-sha256 \
              --linux-v13-started-receipt --linux-v13-started-receipt-sha256 \
              --recovery-v3-terminal --recovery-v3-terminal-sha256 \
              --recovery-v3-query --recovery-v3-query-sha256 \
              --schema5-abort-receipt --schema5-abort-receipt-sha256 \
              --durable-vfdqa --durable-vfdqa-sha256 \
              --retired-claim --retired-claim-sha256 \
              --installed-viewflow-sha256 --installed-viewflow-unit-sha256 \
              --adopt-preintent-deskflow-stopped --handoff-receipt; do
    require_text "$source_file" "$option"
done
require_text "$source_file" '[[ $operation_id =~ ^[0-9a-f]{32}$ ]]'
[[ $(grep -Fxc -- "intent_initial_state='' preintent_partial_adopted=0 adopt_preintent_partial=0" "$source_file") == 1 ]] ||
    die 'pre-intent partial adoption must default to disabled exactly once'

main_body=$(function_body main)
retire_body=$(function_body retire_transients)
baseline_body=$(function_body validate_live_transient_baseline)
baseline_body+=$'\n'"$(function_body validate_live_viewflow_transient)"
baseline_body+=$'\n'"$(function_body validate_live_deskflow_transient)"
start_body=$(function_body start_and_validate_persistent_viewflow)
journal_body=$(function_body capture_persistent_journal)
publish_body=$(function_body publish_handoff_receipt)
cleanup_body=$(function_body cleanup)
receipt_body=$(function_body validate_handoff_receipt)
preflight_body=$(function_body preflight)
intent_body=$(function_body ensure_transition_intent)
adoption_body=$(function_body assert_preintent_partial_adoption_boundary)
classify_body=$(function_body classify_transition_state)
final_body=$(function_body final_reattest_against_receipt)
sidecar_body=$(function_body inspect_live_viewflow_sidecar)
transient_sidecar_body=$(function_body validate_live_viewflow_transient_sidecar)
persistent_sidecar_body=$(function_body validate_live_persistent_viewflow_sidecar)
capture_sidecar_body=$(function_body capture_persistent_sidecar_identity)
receipt_sidecar_body=$(function_body validate_persistent_sidecar_against_receipt)
lineage_body=$(function_body validate_recovery_v3_lineage)
absence_body=$(function_body assert_quarantine_absent)
bound_body=$(function_body assert_bound_inputs_unchanged)
replay_body=$(function_body replay_committed_handoff)
activation_body=$(function_body establish_persistent_service_activation)
activation_boundary_body=$(function_body validate_persistent_activation_boundary)
atomic_body=$(function_body atomic_publish_noreplace)
deskflow_runtime_body=$(function_body deskflow_runtime_pids)
no_deskflow_body=$(function_body assert_no_deskflow_runtime)
no_deskflow_process_body=$(function_body assert_no_deskflow_process_runtime)
transient_deskflow_zero_body=$(function_body assert_transient_deskflow_zero)
cleanup_capture_body=$(function_body capture_persistent_cleanup_identity)
cleanup_match_body=$(function_body persistent_cleanup_identity_matches)
for item in main_body retire_body baseline_body start_body journal_body publish_body cleanup_body receipt_body preflight_body intent_body adoption_body classify_body final_body sidecar_body transient_sidecar_body persistent_sidecar_body capture_sidecar_body receipt_sidecar_body lineage_body absence_body bound_body replay_body activation_body activation_boundary_body atomic_body deskflow_runtime_body no_deskflow_body no_deskflow_process_body transient_deskflow_zero_body cleanup_capture_body cleanup_match_body; do
    [[ -n ${!item} ]] || die "missing production function: ${item%_body}"
done
for token in 'deskflow-stopped-viewflow-live:1)' 'preintent_partial_adopted=1' \
             'adopt_preintent_partial == 0' 'pre-intent adoption flag cannot be reused'; do
    grep -Fq -- "$token" <<<"$intent_body" || die "pre-intent adoption contract omits $token"
done
for token in 'LoadState' 'not-found' validate_live_viewflow_transient assert_transient_deskflow_zero validate_live_viewflow_transient_sidecar assert_persistent_services_inactive; do
    grep -Fq -- "$token" <<<"$adoption_body" || die "partial adoption boundary omits $token"
done

require_order "$main_body" preflight classify_transition_state
require_order "$main_body" classify_transition_state ensure_transition_intent
require_order "$main_body" ensure_transition_intent retire_transients
require_order "$main_body" retire_transients start_and_validate_persistent_viewflow
require_order "$main_body" start_and_validate_persistent_viewflow publish_handoff_receipt
require_order "$retire_body" 'terminal receipt bytes changed immediately before transient stop' classify_transition_state
require_order "$retire_body" classify_transition_state 'systemctl --user stop "$deskflow_unit"'
require_order "$retire_body" 'systemctl --user stop "$deskflow_unit"' 'systemctl --user stop "$viewflow_unit"'
require_order "$retire_body" 'systemctl --user stop "$viewflow_unit"' wait_transients_retired
require_exact_body_line "$main_body" '    ensure_transition_intent "$transition_state"'
require_exact_body_line "$publish_body" '    final_reattest_against_receipt "$receipt_temp"'
require_exact_body_line "$intent_body" '        atomic_publish_noreplace "$intent_temp" "$transition_intent" ||'
require_exact_body_line "$classify_body" '        validate_live_transient_baseline'
require_exact_body_line "$classify_body" '        validate_live_viewflow_transient'
require_exact_body_line "$classify_body" '        validate_live_viewflow_transient_sidecar'
require_exact_body_line "$classify_body" '        assert_viewflow_transient_unit_zero'
require_exact_body_line "$final_body" '    assert_no_deskflow_process_runtime'
require_exact_body_line "$final_body" '    validate_persistent_sidecar_against_receipt "$receipt"'

for state in both-live deskflow-stopped-viewflow-live both-zero persistent-live; do
    grep -Fq -- "$state" <<<"$classify_body$retire_body" || die "resume state omitted: $state"
done
for token in '"${handoff_receipt}.intent"' 'chmod 0600 "$intent_temp"' \
             'atomic_publish_noreplace "$intent_temp" "$transition_intent"' '1000:600:1' \
             'cmp -s -- "$intent_temp" "$transition_intent"' 'transition_intent_sha=$(sha256'; do
    grep -Fq -- "$token" <<<"$intent_body" || die "durable intent contract omits $token"
done

for token in '.main_pid' '.start_ticks' '.invocation_id' '.control_group' '.exec_start_sha256' \
             '.linux_deskflow_main_pid' '.linux_deskflow_main_start_ticks' \
             '.linux_deskflow_runtime_pid' '.linux_deskflow_runtime_start_ticks' \
             '.linux_deskflow_core_pid' '.linux_deskflow_core_start_ticks' \
             '.linux_deskflow_invocation_id' '.linux_deskflow_control_group' \
             '.linux_deskflow_exec_start_sha256' '.linux_deskflow_executable_sha256' \
             '.linux_deskflow_core_executable_sha256'; do
    grep -Fq -- "$token" <<<"$baseline_body" || die "live baseline omits $token"
done
require_text "$source_file" '"$runtime_path (deleted)"'
require_text "$source_file" '"$core_path (deleted)"'
! grep -Fq -- 'readlink -f' <<<"$baseline_body" || die 'deleted executable identity must not use readlink -f'
require_text "$source_file" 'process_descends_from "$runtime_pid" "$main_pid"'
require_text "$source_file" 'process_descends_from "$core_pid" "$runtime_pid"'

require_order "$start_body" validate_installed_persistent_files validate_persistent_activation_boundary
require_order "$start_body" validate_persistent_activation_boundary establish_persistent_service_activation
for token in 'assert_no_deskflow_process_runtime' 'active)' 'validate_live_persistent_viewflow_sidecar' \
             'inactive)' 'assert_no_deskflow_runtime' 'MainPID'; do
    grep -Fq -- "$token" <<<"$activation_boundary_body" || die "persistent activation boundary omits $token"
done
require_order "$activation_body" 'persistent_state=$(systemctl --user is-active' 'systemctl --user start "$VIEWFLOW_UNIT"'
[[ $(grep -Fxc -- '        persistent_started=1' <<<"$activation_body") == 1 &&
   $(grep -Fxc -- '    persistent_started=1' <<<"$activation_body") == 1 ]] ||
    die 'fresh start and SIGKILL-resume adoption must both own cleanup'
require_order "$start_body" establish_persistent_service_activation 'new persistent invocation did not authenticate/probe the Windows peer'
require_order "$start_body" 'ticks=$(process_start_ticks "$pid")' 'capture_persistent_cleanup_identity "$pid" "$ticks" "$invocation" "$cgroup"'
require_order "$start_body" 'capture_persistent_cleanup_identity "$pid" "$ticks" "$invocation" "$cgroup"' 'expected=$(expected_persistent_exec_start_sha)'
require_order "$start_body" 'new persistent invocation did not authenticate/probe the Windows peer' 'capture_persistent_journal "$journal_file"'
require_order "$start_body" 'capture_persistent_journal "$journal_file"' 'persistent Viewflow identity changed while freezing its journal'
for token in 'MainPID' 'InvocationID' 'ControlGroup' 'process_start_ticks' 'process_control_group' \
             'observed_exec_start_sha' 'expected_persistent_exec_start_sha' 'expected_persistent_cmdline_sha' \
             'exact_executable_pids' 'udp_output' 'startup_count == 1' 'assert_no_deskflow_process_runtime' \
             'capture_persistent_sidecar_identity "$pid"'; do
    grep -Fq -- "$token" <<<"$start_body" || die "persistent identity omits $token"
done

probe_jq_pattern='^viewflowd server peer 172\\.16\\.105\\.70:[1-9][0-9]{0,4} probe=[0-9]+ responder_us=[0-9]+$'
(( $(grep -Fc -- "$probe_jq_pattern" "$source_file") >= 3 )) ||
    die 'persistent journal must decode and finally reattest the exact Windows probe pattern'
require_text "$source_file" '^viewflowd server peer 172\.16\.105\.70:[1-9][0-9]{0,4} probe=[0-9]+ responder_us=[0-9]+$'
for token in '_SYSTEMD_INVOCATION_ID' '__CURSOR' '__REALTIME_TIMESTAMP' 'persistent_journal_sha' \
             'persistent_probe_sha' 'persistent_probe_port'; do
    grep -Fq -- "$token" <<<"$journal_body" || die "journal freeze omits $token"
done

require_order "$publish_body" 'validate_handoff_receipt "$receipt_temp"' 'sync -f "$receipt_temp"'
require_order "$publish_body" 'sync -f "$receipt_temp"' 'final_reattest_against_receipt "$receipt_temp"'
require_order "$publish_body" 'final_reattest_against_receipt "$receipt_temp"' 'atomic_publish_noreplace "$receipt_temp" "$handoff_receipt"'
require_order "$publish_body" 'atomic_publish_noreplace "$receipt_temp" "$handoff_receipt"' 'receipt_published=1'
require_order "$publish_body" 'receipt_published=1' '1000:600:1'
require_text "$source_file" 'keys == ["completed_at_utc","deskflow","initial_state","linux_v13_started_receipt_path","linux_v13_started_receipt_sha256","operation_id","persistent_viewflow","post_transient_stop","preintent_partial_adopted","quarantine_absence","recovery_v3_lineage","schema_version","state","terminal_receipt_path","terminal_receipt_sha256","transition_intent_path","transition_intent_sha256"]'
for field in journal_invocation_id journal_slice_sha256 journal_entry_count journal_start_cursor \
             journal_start_realtime_timestamp_us journal_end_cursor journal_end_realtime_timestamp_us \
             authenticated_peer_ip authenticated_peer_port authenticated_probe_record_sha256 started_by_handoff \
             sidecar_socket_path sidecar_socket_inode sidecar_owner_pid sidecar_owner_fd sidecar_listener_count; do
    grep -Fq -- "$field" <<<"$receipt_body" || die "handoff receipt schema omits $field"
done
grep -Fq -- '.persistent_viewflow.journal_end_realtime_timestamp_us as $journal_end_us' <<<"$receipt_body" ||
    die 'receipt validator must bind journal end timestamp before scalar comparison'
grep -Fq -- '$journal_end_us >= $journal_start_us' <<<"$receipt_body" ||
    die 'receipt validator must compare bound journal timestamps'
for token in MainPID InvocationID ControlGroup process_start_ticks process_control_group \
             '/proc/$pid/exe' observed_exec_start_sha cmdline exact_executable_pids udp_output \
             assert_no_deskflow_process_runtime validate_persistent_sidecar_against_receipt \
             _SYSTEMD_INVOCATION_ID authenticated_probe_record_sha256; do
    grep -Fq -- "$token" <<<"$final_body" || die "final pre-link reattestation omits $token"
done

grep -Fq -- 'persistent_started == 1 && receipt_published == 0' <<<"$cleanup_body" ||
    die 'cleanup does not own partial persistent start'
grep -Fq -- 'systemctl --user stop "$VIEWFLOW_UNIT"' <<<"$cleanup_body" ||
    die 'cleanup does not stop an unpublished persistent service'
require_order "$cleanup_body" persistent_cleanup_identity_matches 'systemctl --user stop "$VIEWFLOW_UNIT"'
grep -Fq -- 'refusing to stop a different invocation' <<<"$cleanup_body" ||
    die 'cleanup does not fail closed on an ownership mismatch'
grep -Fq -- 'validate_handoff_receipt "$handoff_receipt"' <<<"$cleanup_body" ||
    die 'cleanup does not recognize an already-linearized valid receipt'
grep -Fq -- 'validate_installed_persistent_files' <<<"$preflight_body" ||
    die 'installed persistent files are not preflighted before transient mutation'

for binding in \
    'f5d5446e51b0d6138352da7c323102baf283df9e63cf7574ab12246708508af3' \
    '4f8a7cb2f0f0c4f01397a4eb4b9f0c1350f52607fb07acec763c19593da519a8' \
    '6cd825cd6003053b3677acc0235933f34e179aba3723a77b14aeada9d1ec3766' \
    'c5a4b7b0900f8907087c65724f630b474facd894d4bf23749b562ea7af967b19' \
    'a336070106802153c9834154ab493b22a19eeb434ebed1e77000e44aa9ba5000'; do
    require_text "$source_file" "$binding"
done
for token in 'viewflow-op442-schema5-abort-post-commit-recovery-v3-terminal' \
             'viewflow-op442-schema5-abort-recovery-v3-marker-query-replayed' \
             'deployment-quarantine-aborted' '.marker_query.replayed == true' \
             'abort_canonical=$(jq -cS '\''.replayed = true'\'''; do
    grep -Fq -- "$token" <<<"$lineage_body" || die "recovery-v3 lineage omits $token"
done
for path in deployment-quarantine.v1 deployment-quarantine.v1.abort-claim \
            deployment-quarantine.v1.release-claim deskflow-quarantine.v2; do
    require_text "$source_file" "$path"
done
grep -Fq -- '[[ ! -e $path && ! -L $path ]]' <<<"$absence_body" ||
    die 'absence gate does not reject regular files and symlinks'
require_order "$main_body" preflight 'if [[ -e $handoff_receipt ]]'
require_order "$main_body" 'if [[ -e $handoff_receipt ]]' replay_committed_handoff
require_order "$main_body" replay_committed_handoff classify_transition_state
for token in validate_transition_intent validate_handoff_receipt final_reattest_against_receipt \
             assert_bound_inputs_unchanged 'receipt_published=1'; do
    grep -Fq -- "$token" <<<"$replay_body" || die "committed replay omits $token"
done
grep -Fq -- 'persistent_start_authorized:true' "$source_file" ||
    die 'durable transition intent does not authorize exact persistent start/adoption'
for token in recovery_v3_terminal_sha recovery_v3_query_sha schema5_abort_receipt_sha durable_vfdqa_sha retired_claim_sha; do
    grep -Fq -- "$token" <<<"$bound_body" || die "bound input recheck omits $token"
done
for token in 'libc.renameat2' 'ctypes.c_uint' 'RENAME_NOREPLACE' 'os.fsync(source_fd)' \
             'os.O_DIRECTORY' 'os.fsync(directory_fd)' 'follow_symlinks=False' 'source_stat.st_nlink != 1'; do
    grep -Fq -- "$token" <<<"$atomic_body" || die "atomic no-replace publisher omits $token"
done
[[ $(grep -Fxc -- 'RENAME_NOREPLACE = 1' <<<"$atomic_body") == 1 ]] ||
    die 'atomic publisher does not use the no-replace flag exactly once'
reject_text "$source_file" 'ln -- "$receipt_temp" "$handoff_receipt"'
reject_text "$source_file" 'ln -- "$intent_temp" "$transition_intent"'
for token in '/proc/[0-9]*' 'linux_deskflow_executable_sha256' 'linux_deskflow_core_executable_sha256' \
             '"$DESKFLOW_INSTALLED (deleted)"' '/tmp/viewflow-deskflow-recovery/deskflow (deleted)' \
             "IFS= read -r -d ''" '"$proc/comm"' 'process_name == deskflow' 'sha256 "$proc/exe"'; do
    grep -Fq -- "$token" <<<"$deskflow_runtime_body" || die "Deskflow deleted/replaced ELF census omits $token"
done
grep -Fq -- '[[ -L $proc/exe ]] || continue' <<<"$deskflow_runtime_body" ||
    die 'Deskflow deleted-ELF census incorrectly requires a live executable target'
grep -Fq -- 'runtime_pids=$(deskflow_runtime_pids)' <<<"$no_deskflow_process_body" ||
    die 'Deskflow process-only zero boundary omits runtime census'
for token in '! -e $VIEWFLOW_SIDECAR' '! -L $VIEWFLOW_SIDECAR'; do
    grep -Fq -- "$token" <<<"$no_deskflow_body" || die "full Deskflow zero boundary omits $token"
done
grep -Fq -- 'assert_no_deskflow_process_runtime' <<<"$transient_deskflow_zero_body" ||
    die 'Deskflow-stopped transient state does not use the process-only zero boundary'
! grep -Fq -- 'VIEWFLOW_SIDECAR' <<<"$transient_deskflow_zero_body$no_deskflow_process_body" ||
    die 'process-only Deskflow zero boundary incorrectly forbids the live Viewflow sidecar'
for token in '-S $VIEWFLOW_SIDECAR' '! -L $VIEWFLOW_SIDECAR' "1000:600:1:socket" \
             '/proc/net/unix' '00010000' '0001' 'socket:[$socket_inode]' \
             '/proc/$viewflow_pid/fd/[0-9]*' 'ss -H -xlpn' 'ss_pid_count == 1' \
             'pid=$viewflow_pid,' 'fd=$owner_fd)'; do
    grep -Fq -- "$token" <<<"$sidecar_body" || die "live transient sidecar ownership omits $token"
done
[[ $(grep -Fxc -- '            assert_no_deskflow_runtime' <<<"$classify_body") == 1 ]] ||
    die 'sidecar absence must be required only for the both-zero classification'
require_exact_body_line "$classify_body" '            assert_no_deskflow_process_runtime'
require_exact_body_line "$classify_body" '            validate_live_persistent_viewflow_sidecar'
grep -Fq -- '            assert_no_deskflow_runtime' <<<"$retire_body" ||
    die 'both-zero retirement does not require sidecar absence'
require_exact_body_line "$retire_body" '            assert_no_deskflow_process_runtime'
require_exact_body_line "$retire_body" '            validate_live_persistent_viewflow_sidecar'
for token in 'unit_property "$VIEWFLOW_UNIT" MainPID' 'inspect_live_viewflow_sidecar "$viewflow_pid"'; do
    grep -Fq -- "$token" <<<"$persistent_sidecar_body" || die "persistent-live sidecar validation omits $token"
done
for token in persistent_sidecar_path persistent_sidecar_inode persistent_sidecar_owner_pid \
             persistent_sidecar_owner_fd persistent_sidecar_listener_count; do
    grep -Fq -- "$token" <<<"$capture_sidecar_body$publish_body" || die "persistent sidecar receipt capture omits $token"
done
for token in sidecar_socket_path sidecar_socket_inode sidecar_owner_pid sidecar_owner_fd sidecar_listener_count \
             'inspect_live_viewflow_sidecar "$viewflow_pid"' observed_sidecar_path observed_sidecar_inode \
             observed_sidecar_owner_pid observed_sidecar_owner_fd observed_sidecar_listener_count; do
    grep -Fq -- "$token" <<<"$receipt_sidecar_body" || die "receipt replay sidecar reattestation omits $token"
done
for token in persistent_owned_pid persistent_owned_ticks persistent_owned_invocation persistent_owned_cgroup \
             ActiveState SubState MainPID InvocationID ControlGroup process_start_ticks process_control_group \
             '/proc/$persistent_owned_pid/exe' installed_viewflow_sha; do
    grep -Fq -- "$token" <<<"$cleanup_capture_body$cleanup_match_body" ||
        die "cleanup ownership tuple omits $token"
done
grep -Fq -- "persistent_owned_pid='' persistent_owned_ticks='' persistent_owned_invocation='' persistent_owned_cgroup=''" "$source_file" ||
    die 'cleanup ownership tuple does not default to unowned'
grep -Fq -- '$(unit_property "$VIEWFLOW_UNIT" InvocationID 2>/dev/null || true) == "$persistent_owned_invocation"' <<<"$cleanup_match_body" ||
    die 'cleanup stop gate does not compare the live and owned InvocationID'
reject_text "$source_file" 'systemctl --user start "$DESKFLOW_UNIT"'

printf 'handoff static contract: PASS\n'
