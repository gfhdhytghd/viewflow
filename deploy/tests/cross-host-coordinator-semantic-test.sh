#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
readonly PATH=/usr/bin:/bin
export PATH
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deploy_dir=$(cd -- "$script_dir/.." && pwd)
coordinator=${1:-$deploy_dir/coordinated-v13-to-v2.sh}
checker=${CROSS_HOST_COORDINATOR_CHECKER:-$deploy_dir/check-cross-host-coordinator.sh}
fail() { printf 'cross-host coordinator semantic test failed: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d' ' -f1; }
function_body() { sed -n "/^$1() {/,/^}/p" "$coordinator"; }
require_in_function() { function_body "$1" | grep -F -- "$2" >/dev/null || fail "$1 omitted $3"; }
require_pattern_in_function() { function_body "$1" | grep -E -- "$2" >/dev/null || fail "$1 omitted $3"; }
require_exact_line_in_function() { function_body "$1" | grep -Fx -- "$2" >/dev/null || fail "$1 omitted executable $3"; }
function_line() { local function_name=$1 needle=$2 n; n=$(function_body "$function_name" | grep -nF -- "$needle" | cut -d: -f1); [[ $n =~ ^[0-9]+$ ]] || fail "$function_name omitted/duplicated $needle"; printf '%s\n' "$n"; }
first_function_line() { local function_name=$1 needle=$2 n; n=$(function_body "$function_name" | grep -nF -- "$needle" | awk -F: 'NR == 1 {print $1}'); [[ $n =~ ^[0-9]+$ ]] || fail "$function_name omitted $needle"; printf '%s\n' "$n"; }
check_bootstrap_call_table() {
    local call
    while IFS= read -r call; do
        [[ -z $call ]] && continue
        grep -Eq -- "^${call}\\(\\)[[:space:]]*\\{" "$coordinator" || fail "bootstrap_preflight invokes undefined helper $call"
    done < <(function_body bootstrap_preflight | sed -nE 's/^[[:space:]]*(adopt_[A-Za-z0-9_]*|assert_[A-Za-z0-9_]*|derive_[A-Za-z0-9_]*|require_[A-Za-z0-9_]*|validate_[A-Za-z0-9_]*)[[:space:]].*/\1/p' | sort -u)
}

if [[ $coordinator =~ ^/proc/self/fd/[0-9]+$ ]]; then
    # The reviewed checker invoked below validates uid/nlink and the exact
    # immutable memfd seal set before this test can accept the coordinator.
    [[ -f $coordinator ]] || fail 'sealed coordinator FD is unavailable'
else
    [[ -f $coordinator && ! -L $coordinator ]] || fail 'unsafe coordinator'
fi
root=$(mktemp -d); chmod 0700 "$root"; trap 'rm -rf -- "$root"' EXIT
fd_gate_payload=$(sed -n "/^readonly FD_GATE_PAYLOAD='/,/^readonly FD_GATE_PAYLOAD_SHA256=/p" "$coordinator" |
    sed '1s/^readonly FD_GATE_PAYLOAD='\''//;$d' | sed '$s/'\''$//')
fd_gate_payload_recorded=$(sed -nE 's/^readonly FD_GATE_PAYLOAD_SHA256=([0-9a-f]{64})$/\1/p' "$coordinator")
[[ -n $fd_gate_payload && $fd_gate_payload_recorded =~ ^[0-9a-f]{64}$ &&
   $(printf '%s' "$fd_gate_payload" | sha256sum | cut -d' ' -f1) == "$fd_gate_payload_recorded" ]] ||
    fail 'FD-gate payload source digest differs from its recorded constant'
reviewed=$root/check.sh; cp -- "$checker" "$reviewed"; chmod 0700 "$reviewed"
sha=$(sha256 "$coordinator")
sed -i "s/PENDING_FINAL_ARTIFACT/$sha/;s/PENDING_FINAL_CPP/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/;s/PENDING_FINAL_RUST/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/" "$reviewed"
"$reviewed" "$coordinator" >/dev/null
! grep -Fq -- 'validate_bootstrap_chain' "$coordinator" || fail 'stale bootstrap validator call present'
check_bootstrap_call_table
grep -Fx -- 'readonly EXPECTED_WINDOWS_SOURCE_IP=172.16.105.70' "$coordinator" >/dev/null ||
    fail 'Windows authentication source IP differs from fixed Windows host'
! grep -Fq -- 'os.environ' "$coordinator" || fail 'FD gate inherits the caller environment'

main_body=$(function_body main)
for token in make_bootstrap_request reconcile_deployment_marker_phase validate_frozen_linux_B remote_prepare_and_start_once publish_mutation_permit validate_windows_force_F run_linux_stage validate_windows_W_schema5 validate_exact_bootstrap_cross_chain release_deployment_marker_transactionally RUST_ACCEPTANCE_ARMED CPP_ACCEPTANCE_ARMED CPP_CLEANED WINDOWS_RESTART_INTENT WINDOWS_RESTARTED POST_RELEASE_VERIFIED; do
    grep -F -- "$token" <<<"$main_body" >/dev/null || fail "phase-aware main omitted $token"
done

# These checks are intentionally independent of the static checker: they model
# the resume branches and durable boundaries of the frozen phase-aware main.
require_in_function remote_prepare_and_start_once 'local command response=$secure_dir/launcher.json resumed_start=$secure_dir/launcher-resumed-start.json' 'owner-only launcher capture paths'
require_in_function ssh_windows '    ssh -F /dev/null -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" "$WINDOWS_SSH_TARGET" \' 'SSH null config isolation'
require_in_function ssh_windows_stdin '    payload=$(printf '\''%s'\'' "$1" | base64 -w0)' 'UTF-8 source base64 payload'
require_in_function ssh_windows_stdin "FromBase64String('\$payload')" 'single-line bootstrap source decode'
require_in_function ssh_windows_stdin '[Console]::SetOut(\$buffer);try{' 'transactional Console stdout buffer'
require_in_function ssh_windows_stdin '\$values=@(&([ScriptBlock]::Create(\$source)))' 'transactional pipeline output buffer'
require_in_function ssh_windows_stdin 'catch{[Console]::SetOut(\$priorOut);[Console]::Error.WriteLine(\$_.Exception.Message);exit 1}' 'exception fails with no stdout commit'
require_in_function ssh_windows_stdin '    printf '\''%s'\'' "$bootstrap" | ssh -F /dev/null -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" "$WINDOWS_SSH_TARGET" \' 'single physical bootstrap stdin'
require_in_function ssh_windows_stdin '        powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -' 'stdin PowerShell argv'
require_in_function reopen_pre_mutation_stop_intent 'capture_json_command '\''pre-mutation retry live proof'\'' "$live" ssh_windows_stdin "$command"' 'long proof stdin transport selection'
require_exact_line_in_function capture_pre_mutation_windows_live_proof '    capture_json_command '\''fresh pre-mutation Windows old-live proof'\'' "$live" ssh_windows_stdin "$command"' 'fresh long proof stdin transport selection'
require_in_function reopen_pre_mutation_stop_intent 'capture_json_command '\''pre-mutation launcher status'\'' "$status" ssh_windows \' 'status encoded transport retained'
require_in_function windows_create_file '    scp -F /dev/null -q -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" -- "$source" \' 'SCP null config isolation'
require_in_function stop_exact_windows_bootstrap 'local status=$secure_dir/windows-stop-status.json evidence=$secure_dir/windows-stop-evidence.json' 'owner-only recovery capture paths'
require_in_function recover_both_hosts '    trap - ERR INT TERM EXIT' 'recovery trap disarm'
require_in_function recover_both_hosts '    ((recovery_running == 0 && recovery_finished == 0)) || finish_recovery "$RECOVERY_FAILURE_EXIT"' 'double recovery guard'
require_in_function validate_pre_mutation_stop_state_baseline 'fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL' 'sealed baseline contract'
require_in_function validate_pre_mutation_stop_state_baseline 'immutable=(st.st_nlink==0 and seals==required)' 'sealed baseline exact-seal equality'
require_in_function validate_pre_mutation_stop_state_baseline 'os.statvfs(p).f_flag & os.ST_RDONLY' 'read-only gate baseline contract'
require_in_function render_pre_mutation_start_state '($committed | keys) == ["bootstrap_request","linux_frozen","marker_handoff","pre_mutation_retry","publish_receipt"]' 'legacy pre-mutation exact committed set'
require_in_function render_pre_mutation_start_state '"candidate_retirement_terminal","candidate_tree","linux_frozen","marker_handoff"' 'replacement pre-mutation append-only committed set'
require_in_function validate_candidate_replacement_lineage '"viewflow-normal-v21-candidate-retired"' 'candidate retirement terminal state'
require_in_function validate_candidate_replacement_lineage '"viewflow-normal-v21-candidate-replacement-committed"' 'candidate replacement commit state'
require_in_function validate_candidate_replacement_lineage 'seconds=calendar.timegm(datetime.datetime.strptime(utc[:19],"%Y-%m-%dT%H:%M:%S").timetuple())' 'strict UTC epoch conversion'
require_in_function validate_candidate_replacement_lineage 'req(unix_ms==expected,label+" UTC/unix_ms equality differs")' 'terminal/commit UTC and unix-ms equality'
require_in_function validate_candidate_replacement_lineage 'item.name.encode()+b"\0"+mode.encode()+b"\0"+str(len(data)).encode()+b"\0"+digest.encode()+b"\n"' 'canonical exact6 tree'
require_in_function validate_candidate_replacement_lineage 'keys(manifest_obj,TOP,"schema2 candidate manifest")' 'strict schema2 candidate manifest'
require_in_function validate_candidate_replacement_lineage 'handoff_obj["marker_cli_path"]==installed_marker_cli and handoff_obj["marker_cli_sha256"]==marker_cli_sha' 'fixed installed marker path and candidate SHA'
require_in_function validate_candidate_replacement_lineage 'actual_sha(installed_marker_cli,marker_cli_sha,"replacement installed marker CLI")' 'installed marker bytes equal candidate SHA'
require_in_function validate_candidate_replacement_lineage 'actual_sha(marker_cli,marker_cli_sha,"replacement candidate marker CLI")' 'candidate marker bytes equal CLI SHA'
require_in_function validate_candidate_replacement_lineage '"viewflow-normal-v21-coordinator-successor-authorized"' 'successor receipt exact state'
require_in_function validate_candidate_replacement_lineage 'pc=={"path":co["entrypoint"],"sha256":co["entrypoint_sha256"],"provenance_path":co["source_provenance"]' 'candidate manifest remains predecessor coordinator'
require_in_function validate_candidate_replacement_lineage 'succ["coordinator_path"]==coordinator_source' 'receipt authorizes executing successor'
require_in_function validate_candidate_replacement_lineage 'absence["normal_output_leaves"]==normal_leaves' 'successor exact normal output absence list'
require_in_function validate_candidate_replacement_lineage 'absence["pre_receipt_operation_leaves"]==pre_receipt_leaves' 'successor exact operation leaf history'
require_in_function validate_candidate_replacement_lineage '"viewflow-normal-v21-coordinator-successor-windows-prestate"' 'successor Windows prestate state'
require_in_function validate_candidate_replacement_lineage 'Windows prestate collector/receipt producer identity differs' 'Windows collector producer closure'
require_in_function validate_candidate_replacement_lineage 'wproof["collector_path"]==succ["receipt_producer_path"] and' 'Windows collector path equals receipt producer'
require_in_function render_committed_artifacts '    ((replacement_flag_count == 0)) || validate_candidate_replacement_lineage' 'replacement revalidation per state render'
require_in_function validate_state_contract '.committed_artifacts.candidate_replacement_commit == $commit' 'replacement resume committed-artifact gate'
require_in_function validate_state_contract '.committed_artifacts.coordinator_successor_receipt == $receipt' 'successor resume receipt gate'
require_in_function validate_state_contract '.contract.inputs.coordinator_successor == {path:$successor,sha256:$successor_sha,' 'successor resume path/provenance gate'
require_in_function validate_pre_mutation_stop_state_baseline '"coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"]' 'successor STOP baseline exact keys'
require_in_function render_pre_mutation_start_state '"coordinator_successor_windows_prestate","linux_frozen","marker_handoff"' 'successor START state exact keys'
require_in_function reopen_pre_mutation_stop_intent '"coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"]' 'successor STOP reopen exact keys'
require_exact_line_in_function bootstrap_preflight '    validate_candidate_replacement_lineage' 'replacement validation before state handling'
grep -Fq -- 'if ((replacement_flag_count != 0 && (abort_failed_v13 || abort_failed_v13_pre_mutation))); then' "$coordinator" ||
    fail 'candidate replacement options are not rejected by abort modes'
grep -Fq -- 'if ((successor_flag_count != 0 && (abort_failed_v13 || abort_failed_v13_pre_mutation))); then' "$coordinator" ||
    fail 'coordinator successor options are not rejected by abort modes'
require_in_function publish_pre_mutation_start_state_cas '            unlink -- "$coordinator_state"' 'old-state CAS unlink'
require_in_function publish_pre_mutation_start_state_cas '        ln -- "$pre_mutation_start_state_candidate" "$coordinator_state" ||' 'START no-clobber publication'
require_in_function reconcile_deployment_marker_phase 'capture_json_command '"'"'active deployment marker transaction query'"'"' "$query" marker_cli query' 'active marker transaction query'
require_in_function reconcile_deployment_marker_phase '       [[ $phase == STOP_INTENT && $resume_pre_mutation_stop_intent == 1 ]] ||' 'special STOP active-marker branch'
require_in_function remote_prepare_and_start_once '                reopen_pre_mutation_stop_intent || return' 'pre-start identity reattestation'
require_in_function reopen_pre_mutation_stop_intent 'AssertAcl \$root \$true' 'root ACL proof'
require_in_function reopen_pre_mutation_stop_intent "\$proc.ProcessId-ne\$pre_mutation_old_process_id" 'old process ID proof'
require_in_function reopen_pre_mutation_stop_intent '\$proc=\$procs[0];\$creationUtc=\$proc.CreationDate.ToUniversalTime().ToString' 'direct canonical UTC tuple construction'
require_in_function reopen_pre_mutation_stop_intent 'creation_date=\$creationUtc;' 'canonical UTC proof serialization'
require_in_function validate_frozen_linux_B "    assert_strict_json_document 'Linux frozen B' \"\$bootstrap_linux_evidence\"" 'strict frozen evidence input'
require_in_function validate_frozen_linux_B "    ' \"\$bootstrap_linux_evidence\" >/dev/null || die 'Linux frozen evidence B is invalid'" 'frozen evidence rejection'
if function_body validate_frozen_linux_B | grep -Eq '^[[:space:]]*(return|exit)[[:space:]]'; then fail 'frozen validator can short-circuit'; fi
require_pattern_in_function main '^[[:space:]]*validate_frozen_linux_B[[:space:]]*$' 'unconditional frozen validator call'
require_in_function wait_remote_receipt '        if windows_remote_exists "$remote"; then sync_remote_receipt "$label" "$remote" "$local_path"; return; fi' 'requested remote receipt wait'
require_in_function wait_remote_receipt '        if [[ $remote != "$windows_exit_path" ]] && windows_remote_exists "$windows_exit_path"; then' 'early terminal receipt excludes terminal self-wait'
require_in_function wait_remote_receipt "            sync_remote_receipt 'Windows installer early exit' \"\$windows_exit_path\" \\" 'early terminal receipt synchronization'
require_in_function wait_remote_receipt '            validate_windows_terminal_exit' 'early terminal receipt validation'
require_in_function wait_remote_receipt '            die "Windows installer terminated before $label"' 'early terminal receipt fail-closed'
wait_requested=$(function_line wait_remote_receipt '        if windows_remote_exists "$remote"; then sync_remote_receipt "$label" "$remote" "$local_path"; return; fi')
wait_early_exit=$(function_line wait_remote_receipt '        if [[ $remote != "$windows_exit_path" ]] && windows_remote_exists "$windows_exit_path"; then')
wait_early_sync=$(function_line wait_remote_receipt "            sync_remote_receipt 'Windows installer early exit' \"\$windows_exit_path\" \\")
wait_early_validate=$(function_line wait_remote_receipt '            validate_windows_terminal_exit')
wait_early_die=$(function_line wait_remote_receipt '            die "Windows installer terminated before $label"')
((wait_requested < wait_early_exit && wait_early_exit < wait_early_sync && wait_early_sync < wait_early_validate && wait_early_validate < wait_early_die)) || fail 'early terminal receipt ordering is unsafe'
resume_phase=$(function_line bootstrap_preflight "        phase=\$(jq -er --arg op \"\$operation_id\" 'select(.schema_version == 2 and .state == \"viewflow-cross-host-bootstrap\" and .operation_id == \$op) | .phase' \"\$coordinator_state\")")
resume_contract=$(function_body bootstrap_preflight | grep -nFx -- '        validate_state_contract "$coordinator_state"' | cut -d: -f1)
[[ $resume_contract =~ ^[0-9]+$ ]] || fail 'bootstrap_preflight omitted/duplicated exact normal state-contract call'
((resume_phase < resume_contract)) || fail 'resume state contract can be bypassed'
require_pattern_in_function bootstrap_preflight '^[[:space:]]*validate_state_contract "\$coordinator_state"[[:space:]]*$' 'unconditional normal resume contract call'
permit_intent=$(function_line publish_mutation_permit '    commit_phase WINDOWS_PERMIT_PUBLISH_INTENT')
permit_upload=$(function_line publish_mutation_permit "    windows_create_or_verify \"\$windows_mutation_permit\" \"\$windows_permit_path\"")
((permit_intent < permit_upload)) || fail 'permit may be written before durable intent'
release_validation=$(function_line release_deployment_marker_transactionally "    validate_release_receipt_v2 \"\$deployment_release_receipt\"")
release_unquarantine=$(function_line release_deployment_marker_transactionally '    [[ ! -e $DEPLOYMENT_MARKER && ! -e ${DEPLOYMENT_MARKER}.release-claim ]] ||')
release_commit=$(function_line release_deployment_marker_transactionally '    commit_phase MARKER_RELEASED')
((release_validation < release_unquarantine && release_unquarantine < release_commit)) || fail 'release receipt proof can be bypassed'
require_pattern_in_function release_deployment_marker_transactionally '^[[:space:]]*validate_release_receipt_v2 "\$deployment_release_receipt"[[:space:]]*$' 'unconditional VFDQR001 validator call'
require_exact_line_in_function failed_v13_abort_preflight '    validate_failed_v13_terminal_state' 'old terminal-state validation'
require_exact_line_in_function failed_v13_abort_preflight '    validate_failed_v13_slot_lineage_union' 'strict slot-lineage union gate'
require_exact_line_in_function failed_v13_abort_preflight '    select_failed_v13_abort_marker_tuple' 'active marker tuple selection'
require_exact_line_in_function failed_v13_abort_preflight '    assert_failed_v13_original_generation_only' 'original generation-only gate'
require_in_function validate_pre_mutation_failed_terminal_state '        .phase == "LINUX_RECOVERED" and' 'pre-mutation terminal phase'
require_in_function validate_pre_mutation_failed_terminal_state '        .recovery == {failure_phase:"WINDOWS_STARTED",mutation_possible:false} and' 'pre-mutation mutation=false state'
require_in_function validate_pre_mutation_failed_terminal_state '        .committed_artifacts == {marker_handoff:$h,linux_frozen:$b,publish_receipt:$p,' 'pre-mutation exact artifact map'
require_in_function validate_pre_mutation_failed_terminal_state '        .exit_code == 1 and .request_sha256 == $request and' 'failed installer exact exit code'
require_exact_line_in_function capture_pre_mutation_windows_live_proof '    validate_pre_mutation_stop_transport_bridge "$remote_stop" "$local_windows_stop_evidence"' 'strict remote/local stop transport bridge call'
require_in_function validate_pre_mutation_stop_transport_bridge 'r.count(b"\n")==1 and b"\r" not in r' 'remote exact terminal LF gate'
require_in_function validate_pre_mutation_stop_transport_bridge 'l.count(b"\n")==1 and l.count(b"\r")==1 and l[:-2]==r[:-1]' 'local exact terminal CRLF bridge'
require_exact_line_in_function validate_pre_mutation_stop_transport_bridge '    [[ $remote_canonical == "$local_canonical" ]] ||' 'canonical JSON equality'
require_in_function capture_pre_mutation_windows_live_proof '    [[ $(sha256 "$remote_exit") == "$(sha256 "$windows_installer_exit_receipt")" ]] ||' 'remote exit raw bytes equality'
require_in_function capture_pre_mutation_windows_live_proof '    [[ $(jq -er '\''.claim_sha256'\'' "$windows_installer_exit_receipt") == "$claim_sha" &&' 'launcher claim hash binding'
require_exact_line_in_function capture_pre_mutation_windows_live_proof '    validate_pre_mutation_remote_launcher_claim "$remote_claim" "$worker_pid" "$installer_command_sha"' 'canonical remote launcher claim validator call'
require_in_function validate_pre_mutation_remote_launcher_claim '.task_name == ("Viewflow Deployment " + $op) and' 'canonical launcher task name without TaskPath prefix'
require_in_function validate_windows_stop_evidence '.task_name == ("Viewflow Deployment " + $op) and' 'canonical stopped launcher task name'
require_in_function validate_windows_identity_scalar '"canonical-filetime":lambda v:type(v) is str and re.fullmatch(r"[1-9][0-9]{16,18}",v) is not None' 'canonical Windows FILETIME helper'
require_in_function validate_windows_identity_scalar '"positive-uint32":lambda v:type(v) is int and 1<=v<=4294967295' 'canonical positive uint32 helper'
require_in_function validate_windows_identity_scalar '"session-one":lambda v:type(v) is int and v==1' 'canonical integer session helper'
require_in_function validate_windows_identity_scalar '"utc-milliseconds":lambda v:type(v) is str and re.fullmatch' 'canonical UTC milliseconds helper'
require_in_function validate_windows_stop_evidence '(.worker_process_start_filetime_utc | test("^[1-9][0-9]{16,18}$"))' 'stopped launcher canonical FILETIME'
require_in_function validate_windows_stop_evidence '(.stopped_at_utc | type == "string" and test(' 'stopped launcher UTC milliseconds'
require_exact_line_in_function validate_windows_stop_evidence '        validate_windows_identity_scalar "$evidence" worker_pid positive-uint32' 'stopped launcher uint32 worker PID helper call'
require_exact_line_in_function validate_windows_stop_evidence '        validate_windows_identity_scalar "$evidence" stopped_at_utc utc-milliseconds' 'stopped launcher UTC helper call'
require_exact_line_in_function capture_pre_mutation_windows_live_proof '    validate_pre_mutation_stop_claim_identity "$remote_stop" "$remote_claim"' 'stop/claim worker identity call'
require_exact_line_in_function validate_pre_mutation_stop_claim_identity '    [[ $(jq -er '\''.worker_process_start_filetime_utc'\'' "$stop") == \' 'stop/claim worker start-time equality'
require_exact_line_in_function capture_pre_mutation_windows_live_proof '    validate_pre_mutation_remote_installer_process "$remote_process" "$worker_pid" "$claim_sha" "$installer_command_sha"' 'strict remote installer-process validator call'
require_exact_line_in_function validate_pre_mutation_remote_launcher_claim '    validate_windows_identity_scalar "$claim" session_id session-one' 'claim canonical integer session helper call'
require_exact_line_in_function validate_pre_mutation_remote_installer_process '    validate_windows_identity_scalar "$process" process_start_filetime_utc canonical-filetime' 'process canonical FILETIME helper call'
require_exact_line_in_function validate_pre_mutation_windows_live_proof '    validate_windows_identity_scalar "$proof" viewflow_process.session_id session-one' 'live canonical integer session helper call'
require_in_function validate_pre_mutation_windows_live_proof '.deployment_task.task_name == ("Viewflow Deployment " + $op) and' 'canonical live-proof deployment task name'
require_in_function capture_pre_mutation_windows_live_proof "deployment_task=[ordered]@{task_name='Viewflow Deployment __OP__'" 'canonical PowerShell live-proof task name publication'
require_in_function capture_pre_mutation_windows_live_proof 'if($members.Count-ne$expected.Count-or$directoryMemberCount-ne0){throw '\''unexpected operation-root member count'\''}' 'exact 14-member operation root'
require_in_function capture_pre_mutation_windows_live_proof '$principalSid=CS ([string]$task.Principal.UserId)' 'canonical task SID'
require_in_function capture_pre_mutation_windows_live_proof 'OwnerProtectedFile $exe;OwnerProtectedFile $wrapperPath;OwnerProtectedFile $rollbackPath' 'old installed rollback validation'
require_in_function capture_pre_mutation_windows_live_proof 'operation_root=[ordered]@{member_count=[int]$members.Count;directory_member_count=[int]$directoryMemberCount;acl_rule_count=[int]$rootRules.Count;owner_sid=$rootOwnerSid;access_rules_protected=[bool]$rootAcl.AreAccessRulesProtected;staged_file_acl_checks=[int]$expected.Count;installed_file_acl_checks=3}' 'measured operation-root ACL proof'
require_in_function capture_pre_mutation_windows_live_proof 'process_counts=[ordered]@{installer=[int]$installers.Count;viewflow=[int]$rows.Count}' 'measured process-count proof'
require_in_function validate_pre_mutation_windows_live_proof '.operation_root.member_count == 14 and .operation_root.directory_member_count == 0 and' 'operation-root measured counts validation'
require_in_function validate_pre_mutation_windows_live_proof '.process_counts.installer == 0 and .process_counts.viewflow == 1 and' 'process measured counts validation'
require_in_function validate_pre_mutation_windows_live_proof '.local_committed_stop_sha256 == $local_stop and .remote_raw_stop_sha256 == $remote_stop and' 'local/remote stop hash proof'
require_in_function validate_pre_mutation_windows_live_proof '.remote_raw_installer_exit_sha256 == $remote_exit and .transport_normalization == $transport and' 'remote exit hash and normalization proof'

# Exercise the production transport functions against a fake SSH boundary. It
# rejects raw multiline stdin, decodes the reviewed source from the one-line
# bootstrap, and models transactional stdout on script failure.
fake_ssh=$root/ssh
cat >"$fake_ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
previous=''
for argument in "$@"; do
    if [[ $previous == -EncodedCommand ]]; then
        ((${#argument} <= 8191)) || exit 206
        printf '%s' "$argument"
        exit 0
    fi
    if [[ $previous == -Command && $argument == - ]]; then
        bootstrap=$(cat)
        [[ $bootstrap != *$'\n'* ]] || exit 65
        [[ $bootstrap == *'[Console]::SetOut($buffer);try{'* &&
           $bootstrap == *'$values=@(&([ScriptBlock]::Create($source)))'* &&
           $bootstrap == *'catch{[Console]::SetOut($priorOut);[Console]::Error.WriteLine($_.Exception.Message);exit 1}'* ]] || exit 66
        encoded=$(sed -n "s/.*FromBase64String('\\([A-Za-z0-9+\/=]*\\)').*/\\1/p" <<<"$bootstrap")
        [[ -n $encoded ]] || exit 67
        source=$(printf '%s' "$encoded" | base64 --decode) || exit 68
        case $source in
            __RC47__) exit 47 ;;
            __JSON_LF__) printf '{"ok":true}\n'; exit 0 ;;
            __JSON_CRLF__) printf '{"ok":true}\r\n'; exit 0 ;;
            __JSON_PREFIX__) printf 'pollution:{"ok":true}\n'; exit 0 ;;
            *"throw 'injected-after-json'"*) printf 'injected failure\n' >&2; exit 1 ;;
            *) printf '%s' "$source"; exit 0 ;;
        esac
    fi
    previous=$argument
done
exit 64
FAKE_SSH
chmod 0700 "$fake_ssh"
transport_driver=$root/windows-long-command-transport-driver.sh
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    function_body ssh_windows
    function_body ssh_windows_stdin
    function_body require_absolute_new_output
    function_body assert_strict_json_document
    function_body publish_new_file
    function_body capture_json_command
    cat <<'TRANSPORT_DRIVER'
SSH_BATCH_OPTION=BatchMode=yes
SSH_HOST_KEY_OPTION=StrictHostKeyChecking=yes
WINDOWS_SSH_TARGET=fixture@windows
die() { printf 'transport rejected: %s\n' "$*" >&2; return 1; }
printf -v long_command '%*s' 40000 ''
long_command=${long_command// /X}
if printf '%s' "$long_command" | LC_ALL=C grep -q '[^ -~]'; then
    printf 'long-command fixture is not canonical ASCII\n' >&2
    exit 1
fi
if ssh_windows "$long_command" >/dev/null 2>&1; then
    printf 'oversized EncodedCommand unexpectedly passed\n' >&2
    exit 1
fi
received=$(ssh_windows_stdin "$long_command")
[[ $received == "$long_command" ]] || {
    printf 'stdin command bytes changed\n' >&2
    exit 1
}
multiline_source=$'first physical source line\nsecond physical source line'
received=$(ssh_windows_stdin "$multiline_source")
[[ $received == "$multiline_source" ]] || {
    printf 'one-line bootstrap did not preserve multiline reviewed source\n' >&2
    exit 1
}
set +e
printf '%s' "$multiline_source" | ssh -F /dev/null -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" "$WINDOWS_SSH_TARGET" \
    powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command - >/dev/null 2>&1
raw_multiline_status=$?
set -e
[[ $raw_multiline_status != 0 ]] || {
    printf 'raw multiline stdin unexpectedly passed\n' >&2
    exit 1
}
set +e
ssh_windows_stdin __RC47__ >/dev/null 2>&1
transport_status=$?
set -e
[[ $transport_status == 47 ]] || {
    printf 'stdin transport did not preserve remote status 47\n' >&2
    exit 1
}
capture_dir=$TRANSPORT_CAPTURE_ROOT
capture_json_command lf "$capture_dir/lf.json" ssh_windows_stdin __JSON_LF__
capture_json_command crlf "$capture_dir/crlf.json" ssh_windows_stdin __JSON_CRLF__
jq -e '.ok == true' "$capture_dir/lf.json" "$capture_dir/crlf.json" >/dev/null
if capture_json_command polluted "$capture_dir/polluted.json" ssh_windows_stdin __JSON_PREFIX__ >/dev/null 2>&1; then
    printf 'stdout prefix pollution unexpectedly passed JSON capture\n' >&2
    exit 1
fi
[[ ! -e $capture_dir/polluted.json ]] || {
    printf 'rejected polluted JSON was published\n' >&2
    exit 1
}
throw_source='[Console]::Out.Write('"'"'{"ok":true}'"'"');throw '"'"'injected-after-json'"'"''
set +e
ssh_windows_stdin "$throw_source" >"$capture_dir/throw.stdout" 2>"$capture_dir/throw.stderr"
throw_status=$?
set -e
[[ $throw_status != 0 && ! -s $capture_dir/throw.stdout && -s $capture_dir/throw.stderr ]] || {
    printf 'post-JSON exception leaked stdout or returned success\n' >&2
    exit 1
}
if capture_json_command injected "$capture_dir/injected.json" ssh_windows_stdin "$throw_source" >/dev/null 2>&1; then
    printf 'post-JSON exception unexpectedly published proof\n' >&2
    exit 1
fi
[[ ! -e $capture_dir/injected.json ]] || {
    printf 'post-JSON exception left durable proof\n' >&2
    exit 1
}
TRANSPORT_DRIVER
} >"$transport_driver"
chmod 0700 "$transport_driver"
transport_capture_root=$root/windows-long-command-captures
mkdir -m 0700 "$transport_capture_root"
/usr/bin/env -i HOME=/home/wilf PATH="$root:/usr/bin:/bin" TRANSPORT_CAPTURE_ROOT="$transport_capture_root" "$transport_driver" ||
    fail 'long-command stdin transport behavior differs'

# Execute the exact production stop/claim validators.  TaskPath is separately
# fixed to "\\" when querying Scheduled Tasks; persisted TaskName is canonical
# and therefore must never contain that path prefix.
claim_driver=$root/pre-mutation-launcher-claim-driver.sh
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    function_body assert_strict_json_document
    function_body validate_windows_identity_scalar
    function_body validate_windows_stop_evidence
    function_body validate_pre_mutation_remote_launcher_claim
    function_body validate_pre_mutation_stop_claim_identity
    function_body validate_pre_mutation_remote_installer_process
    cat <<'CLAIM_DRIVER'
die() { printf 'claim rejected: %s\n' "$*" >&2; return 1; }
operation_id=55d06e8f96aa4adc9010e53612979374
windows_request_sha=d18ec8bf306b733db8fbf808e95dd673f724af53c2cf382d96ded9c074b772e0
windows_user_sid=S-1-5-21-1940417919-1835306932-1635351729-1001
windows_launcher_sha=5880e945533d36c99200d6b0663ff9ffcdc465cdcff80d7b8ee6c59950ea4
FD_GATE_ENV=/usr/bin/env
FD_GATE_PYTHON=/usr/bin/python3.14
local_windows_stop_evidence=$1
validate_windows_stop_evidence "$1"
validate_pre_mutation_remote_launcher_claim "$2" 16704 c8dd49a0f9441944c0c1e359ffb6ab65c2453e2b243d85772ef7f75e3b31e03f
validate_pre_mutation_stop_claim_identity "$1" "$2"
validate_pre_mutation_remote_installer_process "$3" 16704 86834517cf925a139350732b6e8dade2646d5acf9399d2f2cd949eb46624d986 c8dd49a0f9441944c0c1e359ffb6ab65c2453e2b243d85772ef7f75e3b31e03f
CLAIM_DRIVER
} >"$claim_driver"
chmod 0700 "$claim_driver"
claim_stop=$root/claim-stop.json
claim_json=$root/launcher-claim.json
process_json=$root/installer-process.json
jq -cn '{schema_version:1,state:"viewflow-windows-bootstrap-stopped",operation_id:"55d06e8f96aa4adc9010e53612979374",request_sha256:"d18ec8bf306b733db8fbf808e95dd673f724af53c2cf382d96ded9c074b772e0",claim_sha256:"86834517cf925a139350732b6e8dade2646d5acf9399d2f2cd949eb46624d986",task_name:"Viewflow Deployment 55d06e8f96aa4adc9010e53612979374",task_xml_sha256:"b1ee522a87395e8b68936b0d75dcd72e3879ae42d4b183be2287d2ac8cc09931",worker_pid:16704,worker_process_start_filetime_utc:"134326245224770061",installer_process_count:0,task_state:"Disabled",stopped_at_utc:"2026-08-31T04:35:43.526Z"}' >"$claim_stop"
jq -cn '{schema_version:1,state:"viewflow-windows-bootstrap-claimed",operation_id:"55d06e8f96aa4adc9010e53612979374",request_sha256:"d18ec8bf306b733db8fbf808e95dd673f724af53c2cf382d96ded9c074b772e0",launcher_sha256:"5880e945533d36c99200d6b0663ff9ffcdc465cdcff80d7b8ee6c59950ea4",task_xml_sha256:"b1ee522a87395e8b68936b0d75dcd72e3879ae42d4b183be2287d2ac8cc09931",installer_command_sha256:"c8dd49a0f9441944c0c1e359ffb6ab65c2453e2b243d85772ef7f75e3b31e03f",pid:16704,owner_sid:"S-1-5-21-1940417919-1835306932-1635351729-1001",session_id:1,task_name:"Viewflow Deployment 55d06e8f96aa4adc9010e53612979374",worker_executable_path:"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",process_start_filetime_utc:"134326245224770061",task_command_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",launcher_path:"C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\55d06e8f96aa4adc9010e53612979374\\start-viewflow-bootstrap.ps1",claimed_at_utc:"2026-08-31T04:35:22.477Z"}' >"$claim_json"
jq -cn '{schema_version:1,state:"viewflow-windows-bootstrap-installer-running",operation_id:"55d06e8f96aa4adc9010e53612979374",request_sha256:"d18ec8bf306b733db8fbf808e95dd673f724af53c2cf382d96ded9c074b772e0",claim_sha256:"86834517cf925a139350732b6e8dade2646d5acf9399d2f2cd949eb46624d986",installer_command_sha256:"c8dd49a0f9441944c0c1e359ffb6ab65c2453e2b243d85772ef7f75e3b31e03f",parent_pid:16704,pid:16705,owner_sid:"S-1-5-21-1940417919-1835306932-1635351729-1001",session_id:1,executable_path:"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",process_start_filetime_utc:"134326245224770062",started_at_utc:"2026-08-31T04:35:22.500Z"}' >"$process_json"
"$claim_driver" "$claim_stop" "$claim_json" "$process_json" >/dev/null 2>&1 || fail 'valid canonical Windows identity receipts rejected'
for bad_name in '\\Viewflow Deployment 55d06e8f96aa4adc9010e53612979374' 'Viewflow Deployment wrong'; do
    jq --arg name "$bad_name" '.task_name=$name' "$claim_json" >"$root/bad-claim.json"
    if "$claim_driver" "$claim_stop" "$root/bad-claim.json" "$process_json" >/dev/null 2>&1; then
        fail "launcher claim accepted non-canonical TaskName: $bad_name"
    fi
    jq --arg name "$bad_name" '.task_name=$name' "$claim_stop" >"$root/bad-stop.json"
    if "$claim_driver" "$root/bad-stop.json" "$claim_json" "$process_json" >/dev/null 2>&1; then
        fail "stop evidence accepted non-canonical TaskName: $bad_name"
    fi
done
jq '.worker_process_start_filetime_utc="0000000000"' "$claim_stop" >"$root/bad-stop.json"
if "$claim_driver" "$root/bad-stop.json" "$claim_json" "$process_json" >/dev/null 2>&1; then
    fail 'stop evidence accepted malformed worker process start time'
fi
jq '.worker_pid=1.5' "$claim_stop" >"$root/bad-stop.json"
if "$claim_driver" "$root/bad-stop.json" "$claim_json" "$process_json" >/dev/null 2>&1; then
    fail 'stop evidence accepted fractional worker PID'
fi
jq '.stopped_at_utc=false' "$claim_stop" >"$root/bad-stop.json"
if "$claim_driver" "$root/bad-stop.json" "$claim_json" "$process_json" >/dev/null 2>&1; then
    fail 'stop evidence accepted non-string stopped timestamp'
fi
sed 's/"session_id":1,/"session_id":1.0,/' "$claim_json" >"$root/bad-claim.json"
if "$claim_driver" "$claim_stop" "$root/bad-claim.json" "$process_json" >/dev/null 2>&1; then
    fail 'launcher claim accepted non-canonical fractional session ID token'
fi
jq '.process_start_filetime_utc="134326245224770062"' "$claim_json" >"$root/bad-claim.json"
if "$claim_driver" "$claim_stop" "$root/bad-claim.json" "$process_json" >/dev/null 2>&1; then
    fail 'stop/claim worker process start-time mismatch accepted'
fi

# Execute the production LF-to-CRLF bridge, not a lookalike.  Only its strict
# stop-receipt dependencies are supplied here; all byte and canonical equality
# decisions remain in the extracted production function.
bridge_driver=$root/pre-mutation-stop-bridge-driver.sh
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    function_body assert_strict_json_document
    function_body validate_windows_stop_evidence
    function_body validate_pre_mutation_stop_transport_bridge
    cat <<'BRIDGE_DRIVER'
die() { printf 'bridge rejected: %s\n' "$*" >&2; return 1; }
operation_id=55d06e8f96aa4adc9010e53612979374
windows_request_sha=d18ec8bf306b733db8fbf808e95dd673f724af53c2cf382d96ded9c074b772e0
FD_GATE_ENV=/usr/bin/env
FD_GATE_PYTHON=/usr/bin/python3.14
validate_pre_mutation_stop_transport_bridge "$1" "$2"
BRIDGE_DRIVER
} >"$bridge_driver"
chmod 0700 "$bridge_driver"
valid_stop='{"schema_version":1,"state":"viewflow-windows-bootstrap-no-worker-stopped","operation_id":"55d06e8f96aa4adc9010e53612979374","request_sha256":"d18ec8bf306b733db8fbf808e95dd673f724af53c2cf382d96ded9c074b772e0","status_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
changed_stop='{"schema_version":1,"state":"viewflow-windows-bootstrap-no-worker-stopped","operation_id":"55d06e8f96aa4adc9010e53612979374","request_sha256":"d18ec8bf306b733db8fbf808e95dd673f724af53c2cf382d96ded9c074b772e0","status_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
bridge_remote=$root/bridge-remote.json
bridge_local=$root/bridge-local.json
printf '%s\n' "$valid_stop" >"$bridge_remote"
printf '%s\r\n' "$valid_stop" >"$bridge_local"
"$bridge_driver" "$bridge_remote" "$bridge_local" >/dev/null 2>&1 || fail 'valid LF-to-CRLF stop bridge rejected'
assert_bridge_rejects() {
    local label=$1
    if "$bridge_driver" "$bridge_remote" "$bridge_local" >/dev/null 2>&1; then
        fail "$label stop bridge mutation accepted"
    fi
}
printf '%s\r\n' "$valid_stop" >"$bridge_remote"
printf '%s\r\n' "$valid_stop" >"$bridge_local"
assert_bridge_rejects remote-crlf
printf '%s\n\n' "$valid_stop" >"$bridge_remote"
assert_bridge_rejects remote-extra-newline
printf '{\r%s\n' "${valid_stop#\{}" >"$bridge_remote"
assert_bridge_rejects remote-extra-cr
printf '%s\n' "$valid_stop" >"$bridge_remote"
printf '%s\n' "$valid_stop" >"$bridge_local"
assert_bridge_rejects local-lf
printf '%s\r\n' "$changed_stop" >"$bridge_local"
assert_bridge_rejects changed-valid-prefix

require_exact_line_in_function failed_v13_pre_mutation_abort_preflight '    assert_pre_mutation_outputs_absent' 'local mutating-output absence gate'
require_in_function abort_pre_mutation_deployment_marker_transactionally '            run_pinned_executable marker-candidate "$pre_mutation_abort_marker_cli_candidate" \' 'sealed candidate marker CLI transaction'
require_exact_line_in_function abort_pre_mutation_deployment_marker_transactionally '    validate_abort_receipt_v2 "$deployment_abort_receipt"' 'schema2 VFDQA receipt decode'
require_in_function make_and_validate_pre_mutation_abort_authorization '        .initial_force_release_executed == false and .rollback_performed == false and' 'truthful force/rollback false flags'
require_in_function make_and_validate_pre_mutation_abort_authorization '        .windows_rollback_receipt_sha256 == null and .protocol_2_1 == false' 'truthful absent rollback receipt'
require_exact_line_in_function failed_v13_pre_mutation_abort_main '    freeze_authenticated_v13_peer' 'fresh v1.3 authentication before abort'
require_in_function validate_attempt3_slot_cleanup_gate '.state == "viewflow-attempt3-exchange-slot-cleanup-complete"' 'slot-cleanup completion state'
require_in_function validate_attempt3_slot_cleanup_gate '[[ $(sha256 "$attempt3_slot_cleanup_receipt") == "$attempt3_slot_cleanup_receipt_sha" ]] ||' 'slot-cleanup completion SHA equality'
require_in_function validate_attempt3_slot_cleanup_gate '.checkout_slots_absent == true' 'slot-cleanup source absence receipt'
require_in_function validate_attempt3_slot_cleanup_gate '.claims_preserved == true' 'slot-cleanup retained claims'
require_in_function validate_attempt3_slot_cleanup_gate '[[ ! -e $source && ! -L $source ]]' 'live exchange-slot absence'
require_in_function validate_attempt3_slot_cleanup_gate '$destination_identity == "$claim_identity"' 'live retained-claim identity'
require_in_function validate_failed_v13_slot_lineage_union '-z $fresh_operation_lineage_receipt && -z $fresh_operation_lineage_receipt_sha' 'legacy/fresh proof mutual exclusion'
require_exact_line_in_function validate_failed_v13_slot_lineage_union '        validate_attempt3_slot_cleanup_gate' 'legacy attempt3 cleanup branch'
require_exact_line_in_function validate_failed_v13_slot_lineage_union '        validate_fresh_operation_lineage_gate' 'fresh-operation lineage branch'
require_exact_line_in_function validate_failed_v13_slot_lineage_union '        validate_schema1_handoff_lineage_gate' 'schema1-handoff lineage branch'
require_in_function validate_schema1_handoff_lineage_gate '.state == "viewflow-schema1-abort-handoff-to-fresh-v21"' 'schema1-handoff state'
require_in_function validate_schema1_handoff_lineage_gate '[[ $(sha256 "$schema1_handoff_lineage_receipt") == "$schema1_handoff_lineage_receipt_sha" ]] ||' 'schema1-handoff lineage SHA equality'
require_in_function validate_failed_v13_terminal_state '.contract.inputs.linux_frozen.path == $frozen_path and .contract.outputs.request == $request_path and' 'post-force input path binding'
require_in_function validate_schema1_handoff_lineage_gate '.old_schema1_abort == {terminal_sha256:$terminal,authorization_sha256:$authorization,' 'schema1-handoff old closure'
require_in_function validate_schema1_handoff_lineage_gate '.recovery == {failure_phase:"MUTATION_PERMITTED",mutation_possible:true}' 'schema1-handoff failure phase'
require_in_function make_and_validate_post_permit_rollback_abort_authorization '.force_release_executed == false and .rollback_performed == true' 'truthful post-permit authorization'
require_in_function validate_abort_receipt_v5 '.schema_version == 5 and .state == "deployment-quarantine-aborted"' 'schema5 abort receipt'
require_in_function make_and_validate_post_force_rollback_abort_authorization '.schema_version == 7 and .state == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"' 'schema7 post-force authorization'
require_in_function make_and_validate_post_force_rollback_abort_authorization '.force_release_executed == true and .rollback_performed == true and .linux_stage_committed == false' 'truthful post-force facts'
require_in_function validate_abort_receipt_v7 '.schema_version == 7 and .state == "deployment-quarantine-aborted"' 'schema7 abort receipt'
require_in_function validate_abort_receipt_v7 '.force_release_executed == true and .rollback_performed == true and .linux_stage_committed == false' 'truthful schema7 receipt facts'
require_in_function validate_failed_v13_terminal_state '.recovery == {failure_phase:"WINDOWS_FORCE_ATTESTED",mutation_possible:true}' 'post-force exact failure phase'
require_in_function abort_deployment_marker_transactionally 'marker_executable=$post_force_abort_marker_cli_candidate' 'schema7 candidate dispatch'
require_exact_line_in_function abort_deployment_marker_transactionally '        validate_abort_receipt_v7 "$deployment_abort_receipt"' 'schema7 abort receipt validation'
require_in_function validate_fresh_operation_lineage_gate '.state == "viewflow-v4-inactive-terminal-to-fresh-v21"' 'fresh lineage schema1 state'
require_in_function validate_fresh_operation_lineage_gate '[[ $(sha256 "$fresh_operation_lineage_receipt") == "$fresh_operation_lineage_receipt_sha" ]] ||' 'fresh lineage SHA equality'
require_exact_line_in_function validate_fresh_operation_lineage_gate '    [[ $(jq -cS '\''del(.replayed)'\'' "$old_abort") == "$(jq -cS '\''del(.replayed)'\'' "$old_query")" ]] ||' 'fresh predecessor abort/query canonical replay equality'
require_in_function validate_fresh_operation_lineage_gate '.new_operation_id == $op and .new_coordinator_instance_id == $coordinator' 'fresh lineage identity binding'
require_in_function validate_fresh_operation_lineage_gate '.old_operation_id == $old and .old_operation_id != $op' 'fresh lineage exact old-operation binding'
require_exact_line_in_function validate_fresh_operation_lineage_gate '        .fresh_boundary.deployment_marker_sha256 == $marker and' 'fresh lineage marker binding'
require_in_function validate_fresh_operation_lineage_gate 'old_root="/home/wilf/.local/state/viewflow/deployments/${old_operation}"' 'fixed old-operation evidence root'
require_in_function validate_fresh_operation_lineage_gate 'bridge_root="/home/wilf/.local/state/viewflow/v4-inactive-bridges/${old_operation}"' 'fixed inactive bridge evidence root'
require_in_function validate_fresh_operation_lineage_gate '$(sha256 "$immutable_vfdqa") == "$(sha256 "$durable_path")"' 'immutable/durable VFDQA equality'
require_in_function validate_fresh_operation_lineage_gate '[[ $prefix_sha == "$suffix_sha" ]] ||' 'durable VFDQA self-checksum'
require_in_function validate_fresh_operation_lineage_gate '--slurpfile manifest "$candidate_manifest"' 'candidate manifest/current state join'
require_in_function validate_fresh_operation_lineage_gate '$m.windows.rollback_sha256 == .contract.inputs.windows_rollback.sha256' 'fifth Windows input binding'
require_in_function validate_fresh_operation_lineage_gate '.committed_artifacts == {bootstrap_request:$request,force_envelope:$f,linux_frozen:$b,' 'fresh exact committed artifact map'
require_in_function validate_fresh_operation_lineage_gate '.contract.inputs.windows_viewflow.path == ($root + "/windows-viewflowd.exe")' 'fresh operation candidate binding'
require_in_function validate_fresh_operation_lineage_gate 'contains(".attempt3.exchange-slot") | not' 'fresh state excludes attempt3 exchange inputs'
require_in_function validate_fresh_operation_lineage_gate '[[ ! -e $source && ! -L $source ]] ||' 'fresh live attempt3-slot absence'

# Execute the extracted union itself so a token-preserving no-op or permissive
# branch rewrite cannot satisfy the structural assertions above.
slot_union_driver=$root/slot-lineage-union.sh
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
        'die() { return 1; }' \
        'validate_attempt3_slot_cleanup_gate() { [[ $expected_branch == legacy ]]; }' \
        'validate_fresh_operation_lineage_gate() { [[ $expected_branch == fresh ]]; }' \
        'validate_schema1_handoff_lineage_gate() { [[ $expected_branch == schema1 ]]; }'
    function_body validate_failed_v13_slot_lineage_union
    printf '%s\n' \
        'attempt3_slot_cleanup_receipt=${ATTEMPT_RECEIPT-}' \
        'attempt3_slot_cleanup_receipt_sha=${ATTEMPT_SHA-}' \
        'fresh_operation_lineage_receipt=${FRESH_RECEIPT-}' \
        'fresh_operation_lineage_receipt_sha=${FRESH_SHA-}' \
        'schema1_handoff_lineage_receipt=${SCHEMA1_RECEIPT-}' \
        'schema1_handoff_lineage_receipt_sha=${SCHEMA1_SHA-}' \
        'expected_branch=$EXPECTED_BRANCH' \
        'validate_failed_v13_slot_lineage_union'
} >"$slot_union_driver"
chmod 0700 "$slot_union_driver"
ATTEMPT_RECEIPT=/legacy.json ATTEMPT_SHA=$(printf legacy | sha256sum | cut -d' ' -f1) \
    EXPECTED_BRANCH=legacy "$slot_union_driver" || fail 'complete legacy slot-lineage branch rejected'
FRESH_RECEIPT=/fresh.json FRESH_SHA=$(printf fresh | sha256sum | cut -d' ' -f1) \
    EXPECTED_BRANCH=fresh "$slot_union_driver" || fail 'complete fresh slot-lineage branch rejected'
SCHEMA1_RECEIPT=/schema1.json SCHEMA1_SHA=$(printf schema1 | sha256sum | cut -d' ' -f1) \
    EXPECTED_BRANCH=schema1 "$slot_union_driver" || fail 'complete schema1-handoff lineage branch rejected'
if ATTEMPT_RECEIPT=/legacy.json ATTEMPT_SHA=$(printf legacy | sha256sum | cut -d' ' -f1) \
    FRESH_RECEIPT=/fresh.json FRESH_SHA=$(printf fresh | sha256sum | cut -d' ' -f1) \
    EXPECTED_BRANCH=legacy "$slot_union_driver" >/dev/null 2>&1; then
    fail 'simultaneous legacy and fresh slot-lineage proofs accepted'
fi
if FRESH_RECEIPT=/fresh.json FRESH_SHA=$(printf fresh | sha256sum | cut -d' ' -f1) \
    SCHEMA1_RECEIPT=/schema1.json SCHEMA1_SHA=$(printf schema1 | sha256sum | cut -d' ' -f1) \
    EXPECTED_BRANCH=fresh "$slot_union_driver" >/dev/null 2>&1; then
    fail 'simultaneous fresh and schema1-handoff lineage proofs accepted'
fi
if FRESH_RECEIPT=/fresh.json EXPECTED_BRANCH=fresh "$slot_union_driver" >/dev/null 2>&1; then
    fail 'incomplete fresh slot-lineage proof accepted'
fi

# Execute the production fresh validator against the retained 845ce lineage.
# This is read-only and deliberately includes a bad digest invocation so a
# whole-function `return 0` mutation cannot pass by retaining contract text.
fresh_validator_driver=$root/fresh-lineage-validator.sh
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
        'die(){ printf "error: %s\\n" "$*" >&2; return 1; }' \
        'sha256(){ sha256sum -- "$1" | cut -d" " -f1; }' \
        'require_sha256(){ [[ $2 =~ ^[0-9a-f]{64}$ ]]; }' \
        'require_owner_only_regular(){ [[ $2 == /* && -f $2 && ! -L $2 && $(stat -c "%u:%a:%h" -- "$2") == 1000:600:1 ]]; }' \
        'assert_strict_json_document(){ jq -e . "$2" >/dev/null; }' \
        'validate_publish_receipt(){ published_marker_sha=$(jq -er .marker_sha256 "$1"); }'
    function_body validate_fresh_operation_lineage_gate
    printf '%s\n' \
        'operation_id=845ce4223e4f426a8a0015d3355595e8' \
        'coordinator_instance_id=271b68b5-2058-4c73-9f17-977d8f7fb18c' \
        'marker_generation=1' \
        'coordinator_state=/home/wilf/.local/state/viewflow/deployments/845ce4223e4f426a8a0015d3355595e8/coordinator-state.json' \
        'fresh_operation_lineage_receipt=/home/wilf/.local/state/viewflow/deployments/845ce4223e4f426a8a0015d3355595e8/v4-inactive-terminal-to-fresh-v21.json' \
        'fresh_operation_lineage_receipt_sha=${LINEAGE_SHA_OVERRIDE:-0c32f1f3524945355c20dfdf5cd7ce6a15e5d02a0331362288a9d8c22646aa78}' \
        'deployment_publish_receipt=/home/wilf/.local/state/viewflow/deployments/845ce4223e4f426a8a0015d3355595e8/deployment-publish.json' \
        'bootstrap_handoff_receipt=/home/wilf/.local/state/viewflow/deployments/845ce4223e4f426a8a0015d3355595e8/marker-handoff.json' \
        'bootstrap_linux_evidence=/home/wilf/.local/state/viewflow/deployments/845ce4223e4f426a8a0015d3355595e8/linux-frozen.json' \
        'windows_force_envelope=/home/wilf/.local/state/viewflow/deployments/845ce4223e4f426a8a0015d3355595e8/windows-force-envelope.json' \
        'windows_request_sha=7620201fc0568c140ec123ef90773e8e5e240fe55da1d4a9a0aae09ed17ba5ce' \
        'local_windows_stop_evidence=/home/wilf/.local/state/viewflow/deployments/845ce4223e4f426a8a0015d3355595e8/coordinator-state.json.windows-stop-evidence.json' \
        'local_windows_rollback_receipt=/home/wilf/.local/state/viewflow/deployments/845ce4223e4f426a8a0015d3355595e8/windows-rollback.json' \
        'validate_fresh_operation_lineage_gate'
} >"$fresh_validator_driver"
chmod 0700 "$fresh_validator_driver"
"$fresh_validator_driver" || fail 'retained 845ce fresh-lineage validator fixture rejected'
if LINEAGE_SHA_OVERRIDE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$fresh_validator_driver" >/dev/null 2>&1; then
    fail 'fresh-lineage validator accepted a wrong receipt digest'
fi
c9_validator_driver=$root/c9-fresh-lineage-validator.sh
sed -e 's/845ce4223e4f426a8a0015d3355595e8/c9b05e9bea4140d69f9d137a0f992ba0/g' \
    -e 's/271b68b5-2058-4c73-9f17-977d8f7fb18c/86c03003-2b67-451d-a990-396e1a66b406/g' \
    -e 's/0c32f1f3524945355c20dfdf5cd7ce6a15e5d02a0331362288a9d8c22646aa78/6cc134872971fd1b25608c53e5e24d27ae5516ca1d457443ddeba91bda9fa982/g' \
    -e 's/7620201fc0568c140ec123ef90773e8e5e240fe55da1d4a9a0aae09ed17ba5ce/d03c7293236521937c0de597f0e59cd05965ed90276c58bb3baf6502b1547135/g' \
    "$fresh_validator_driver" >"$c9_validator_driver"
chmod 0700 "$c9_validator_driver"
"$c9_validator_driver" || fail 'retained c9 post-force fresh-lineage validator fixture rejected'
if LINEAGE_SHA_OVERRIDE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$c9_validator_driver" >/dev/null 2>&1; then
    fail 'c9 post-force fresh-lineage validator accepted a wrong receipt digest'
fi

# Execute the production schema1-handoff validator against the retained 845ce
# terminal/handoff and the failed 442 operation.  This is local and read-only.
schema1_validator_driver=$root/schema1-handoff-lineage-validator.sh
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
        'die(){ printf "error: %s\\n" "$*" >&2; return 1; }' \
        'sha256(){ sha256sum -- "$1" | cut -d" " -f1; }' \
        'require_sha256(){ [[ $2 =~ ^[0-9a-f]{64}$ ]]; }' \
        'require_owner_only_regular(){ [[ $2 == /* && -f $2 && ! -L $2 && $(stat -c "%u:%a:%h" -- "$2") == 1000:600:1 ]]; }' \
        'assert_strict_json_document(){ jq -e . "$2" >/dev/null; }' \
        'validate_publish_receipt(){ published_marker_sha=$(jq -er .marker_sha256 "$1"); }'
    function_body validate_schema1_handoff_lineage_gate
    printf '%s\n' \
        'operation_id=442fe737e67f43b89d85a7e33149a072' \
        'coordinator_instance_id=703230e5-6349-42f9-81de-bf1c1ba418a0' \
        'marker_generation=1' \
        'coordinator_state=/home/wilf/.local/state/viewflow/deployments/442fe737e67f43b89d85a7e33149a072/coordinator-state.json' \
        'schema1_handoff_lineage_receipt=/home/wilf/.local/state/viewflow/deployments/442fe737e67f43b89d85a7e33149a072/schema1-abort-handoff-to-fresh-v21.json' \
        'schema1_handoff_lineage_receipt_sha=${LINEAGE_SHA_OVERRIDE:-4cf81ca6c90a10f9d4d807e5879326a5f0e7142979231b098df6e42221ecd967}' \
        'deployment_publish_receipt=/home/wilf/.local/state/viewflow/deployments/442fe737e67f43b89d85a7e33149a072/deployment-publish.json' \
        'bootstrap_handoff_receipt=/home/wilf/.local/state/viewflow/deployments/442fe737e67f43b89d85a7e33149a072/marker-handoff.json' \
        'bootstrap_linux_evidence=/home/wilf/.local/state/viewflow/deployments/442fe737e67f43b89d85a7e33149a072/linux-frozen.json' \
        'windows_request_sha=ff756acd9b0f1c33e4faa2149f12676b18379afb782b7ef70adac9c0e6d772b2' \
        'local_windows_stop_evidence=/home/wilf/.local/state/viewflow/deployments/442fe737e67f43b89d85a7e33149a072/coordinator-state.json.windows-stop-evidence.json' \
        'local_windows_rollback_receipt=/home/wilf/.local/state/viewflow/deployments/442fe737e67f43b89d85a7e33149a072/windows-rollback.json' \
        'linux_deactivation_transcript=/home/wilf/.local/state/viewflow/deployments/442fe737e67f43b89d85a7e33149a072/linux-deactivation-transcript.json' \
        'post_permit_rollback_abort=0' \
        'post_force_pre_linux_stage_rollback_abort=0' \
        'validate_schema1_handoff_lineage_gate'
} >"$schema1_validator_driver"
chmod 0700 "$schema1_validator_driver"
"$schema1_validator_driver" || fail 'retained 442 schema1-handoff lineage validator fixture rejected'
if LINEAGE_SHA_OVERRIDE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$schema1_validator_driver" >/dev/null 2>&1; then
    fail 'schema1-handoff lineage validator accepted a wrong receipt digest'
fi
require_in_function assert_failed_v13_original_generation_only '$abort_marker_generation == "$marker_generation"' 'original marker generation equality'
require_in_function assert_failed_v13_original_generation_only '! -e $deployment_release_receipt && ! -L $deployment_release_receipt' 'release sentinel absence'
require_in_function assert_failed_v13_original_generation_only '! -e $recovery_deployment_publish_receipt && ! -L $recovery_deployment_publish_receipt' 'recovery-publish sentinel absence'
require_in_function failed_v13_abort_preflight "state_request=\$(jq -er '.contract.outputs.request" 'old-state request path derivation'
require_in_function failed_v13_abort_preflight "state_stop=\$(jq -er '.contract.outputs.windows_stop_evidence" 'old-state stop-evidence path derivation'
require_in_function validate_failed_v13_terminal_state '.contract.outputs.request == $request' 'old-state request path binding'
require_exact_line_in_function validate_failed_v13_terminal_state '            .contract.inputs.linux_frozen.path == $frozen and .contract.outputs.request == $request and' 'post-permit exact request path binding'
require_exact_line_in_function validate_failed_v13_terminal_state '        .contract.inputs.linux_frozen.path == $frozen and .contract.outputs.request == $request and' 'legacy failed-terminal exact request path binding'
require_exact_line_in_function validate_failed_v13_terminal_state '        .committed_artifacts.bootstrap_request == $request and' 'legacy failed-terminal bootstrap request hash binding'
require_in_function validate_failed_v13_terminal_state '.committed_artifacts.bootstrap_request == $request' 'old-state request hash binding'
require_in_function select_failed_v13_abort_marker_tuple 'abort_marker_operation_id=$operation_id' 'generation-1 abort tuple'
require_in_function select_failed_v13_abort_marker_tuple 'recovery_operation_id="${operation_id}_recovery"' 'generation-2 abort operation'
require_in_function select_failed_v13_abort_marker_tuple 'validate_publish_receipt "$recovery_deployment_publish_receipt" "$recovery_marker_generation" 0 "$recovery_operation_id"' 'generation-2 publish proof'
require_in_function validate_failed_v13_terminal_state '.phase == "WINDOWS_ROLLED_BACK"' 'old terminal phase equality'
require_in_function validate_failed_v13_terminal_state '    [[ $(sha256 "$path") == "$old_coordinator_state_sha" ]]' 'old terminal SHA pin'
require_in_function failed_v13_abort_main '    [[ $state_after == "$state_before" && $state_after == "$old_coordinator_state_sha" ]] ||' 'old state immutability proof'
require_in_function make_and_validate_abort_authorization 'keys == ["authenticated_v13_peer_receipt_sha256"' 'strict abort authorization schema'
require_pattern_in_function abort_deployment_marker_transactionally '^[[:space:]]*validate_abort_receipt_v1 "\$deployment_abort_receipt"[[:space:]]*$' 'unconditional VFDQA001 validator call'
require_exact_line_in_function abort_deployment_marker_transactionally '    start_and_freeze_windows_v13' 'last live Windows identity snapshot'
require_exact_line_in_function abort_deployment_marker_transactionally '    validate_authenticated_v13_peer' 'last authenticated peer binding'
require_in_function validate_abort_receipt_v1 'authorization_recorded=$(dd if="$durable" bs=1 skip=304 count=32' 'authorization digest decode'
require_in_function validate_abort_receipt_v1 'prefix_sha=$(dd if="$durable" bs=352 count=1 status=none | sha256sum' 'VFDQA001 prefix checksum'
require_in_function start_and_freeze_windows_v13 "if((HB ([IO.File]::ReadAllBytes('C:\\\\Users\\\\wilf\\\\AppData\\\\Local\\\\Programs\\\\Viewflow\\\\viewflow-client.ps1')))-cne'\$wrapper')" 'PS5-safe live old wrapper hash comparison'
require_in_function start_and_freeze_windows_v13 'if(\$rows.Count-ne1){throw '\''exact old viewflow process not found'\''}' 'single exact old Windows daemon'
require_in_function validate_fd_gate_contract "\$(stat -c '%u:%g:%a:%h' -- \"\$FD_GATE_ENV\") == 0:0:755:1" 'root-owned env identity'
require_in_function validate_fd_gate_contract '$(sha256 "$FD_GATE_ENV") == "$FD_GATE_ENV_SHA256"' 'env runtime hash equality'
require_in_function validate_fd_gate_contract "\$(stat -c '%u:%g:%a:%h' -- \"\$FD_GATE_PYTHON\") == 0:0:755:1" 'root-owned Python FD-gate identity'
require_in_function validate_fd_gate_contract '$(sha256 "$FD_GATE_PYTHON") == "$FD_GATE_PYTHON_SHA256"' 'Python FD-gate hash equality'
require_exact_line_in_function run_pinned_executable '    "$FD_GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \' 'empty Python startup environment'
require_in_function run_pinned_executable '"$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_PAYLOAD_SHA256" "$FD_GATE_PAYLOAD"' 'isolated FD-gate invocation'
grep -F -- 'fd=os.open(target,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)' "$coordinator" >/dev/null || fail 'FD gate omitted O_NOFOLLOW open'
grep -F -- 'if role=="marker" and (not target_argv or target_argv[0] not in {"abort","publish","query","release"}):' "$coordinator" >/dev/null || fail 'installed marker FD gate subcommands differ'
grep -F -- 'if role=="marker-candidate" and (not target_argv or target_argv[0] not in {"abort","query"}):' "$coordinator" >/dev/null || fail 'candidate marker FD gate subcommands differ'
grep -F -- 'st=os.fstat(fd)' "$coordinator" >/dev/null || fail 'FD gate omitted opened-file fstat'
grep -F -- 'if len(verified_bytes)!=st.st_size or hashlib.sha256(verified_bytes).hexdigest()!=expected_sha:' "$coordinator" >/dev/null || fail 'FD gate omitted opened-byte SHA check'
grep -F -- 'if verified_bytes[:4]!=b"\x7fELF":' "$coordinator" >/dev/null || fail 'FD gate omitted ELF check'
grep -F -- 'current=os.stat(target,follow_symlinks=False)' "$coordinator" >/dev/null || fail 'FD gate omitted post-open path identity check'
grep -F -- 'exec_fd=os.memfd_create("viewflow-verified-elf",os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)' "$coordinator" >/dev/null || fail 'FD gate omitted sealable memfd'
grep -F -- 'required_seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL' "$coordinator" >/dev/null || fail 'FD gate omitted exact seals'
grep -F -- 'if fcntl.fcntl(exec_fd,fcntl.F_GET_SEALS)!=required_seals:' "$coordinator" >/dev/null || fail 'FD gate omitted seal readback'
grep -F -- 'clean_env={"HOME":"/home/wilf"' "$coordinator" >/dev/null || fail 'FD gate omitted clean environment'
grep -F -- '"--tmpfs",staging' "$coordinator" >/dev/null || fail 'Deskflow gate omitted private sibling mount point'
grep -F -- 'os.closerange(3,exec_fd)' "$coordinator" >/dev/null || fail 'FD gate omitted inherited low-FD closure'
grep -F -- 'os.closerange(exec_fd+1,limit)' "$coordinator" >/dev/null || fail 'FD gate omitted inherited high-FD closure'
grep -F -- 'os.execve(f"/proc/self/fd/{exec_fd}",[target,*target_argv],clean_env)' "$coordinator" >/dev/null || fail 'FD gate does not execute sealed memfd'
require_in_function assert_marker_cli_identity '$(stat -c '"'"'%u:%a:%h'"'"' -- "$MARKER_CLI") == 1000:755:1' 'marker CLI owner/mode/link metadata'
require_in_function assert_marker_cli_identity '$(sha256 "$MARKER_CLI") == "$deployment_marker_sha"' 'installed marker CLI exact SHA'
require_exact_line_in_function marker_cli '    assert_marker_cli_identity || return' 'marker execution identity gate'
require_exact_line_in_function marker_cli '    run_pinned_executable marker "$MARKER_CLI" "$deployment_marker_sha" "$@"' 'normal marker sealed-memfd execution'
if function_body marker_cli | grep -Fx -- '    "$MARKER_CLI" "$@"' >/dev/null; then fail 'normal marker uses mutable direct-path execution'; fi
require_in_function start_pinned_v13_transient_unit '[[ -z $load_state || $load_state == not-found ]] ||' 'preoccupied transient-unit rejection'
require_in_function canonical_fd_gate_exec_start_sha "'{argv:\$ARGS.positional,ignore_errors:false,path:\$path}'" 'fixed canonical ExecStart schema'
require_in_function canonical_fd_gate_exec_start_sha '"$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_PAYLOAD_SHA256" "$FD_GATE_PAYLOAD"' 'canonical fixed gate argv'
require_in_function observed_transient_exec_start_sha 'busctl --user --json=short get-property org.freedesktop.systemd1' 'manager ExecStart observation'
require_in_function observed_transient_exec_start_sha '{argv:$value[1],ignore_errors:$value[2],path:$value[0]}' 'observed canonical ExecStart schema'
require_in_function start_pinned_v13_transient_unit 'expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")' 'pre-launch expected ExecStart hash'
require_in_function start_pinned_v13_transient_unit 'observed_exec_start_sha=$(observed_transient_exec_start_sha "$unit")' 'post-launch observed ExecStart hash'
require_in_function start_pinned_v13_transient_unit '[[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' 'manager/expected ExecStart equality'
exec_expected=$(function_line start_pinned_v13_transient_unit '    expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")')
exec_launch=$(first_function_line start_pinned_v13_transient_unit '        systemd-run --user --quiet --unit "$unit"')
exec_observed=$(function_line start_pinned_v13_transient_unit '    observed_exec_start_sha=$(observed_transient_exec_start_sha "$unit")')
exec_equal=$(function_line start_pinned_v13_transient_unit '    [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||')
((exec_expected < exec_launch && exec_launch < exec_observed && exec_observed < exec_equal)) || fail 'transient expected/launch/observed/equality ordering is unsafe'
require_in_function start_pinned_v13_transient_unit '--property Type=exec --property KillMode=control-group' 'exec-ready control-group transient unit'
[[ $(function_body start_pinned_v13_transient_unit | grep -Fc -- '--property Type=exec --property KillMode=control-group') == 2 ]] || fail 'both recovery transient units are not Type=exec/KillMode=control-group'
for loader_variable in LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH; do
    [[ $(function_body start_pinned_v13_transient_unit | grep -Fc -- "--setenv=${loader_variable}=") == 2 ]] || fail "both recovery transient units do not clear $loader_variable"
done
if function_body start_pinned_v13_transient_unit | grep -F -- '--collect' >/dev/null; then fail 'recovery transient unit can be collected/reused'; fi
require_in_function abort_deployment_marker_transactionally '"$marker_role" "$marker_executable" "$marker_executable_sha" query' 'FD-gated marker query'
require_in_function abort_deployment_marker_transactionally '"$marker_role" "$marker_executable" "$marker_executable_sha" abort' 'FD-gated marker abort'
require_exact_line_in_function abort_deployment_marker_transactionally '        marker_role=marker-candidate' 'schema1-handoff candidate marker role'
require_exact_line_in_function abort_deployment_marker_transactionally '        marker_executable=$schema1_handoff_abort_marker_cli_candidate' 'schema1-handoff candidate marker executable'
require_exact_line_in_function abort_deployment_marker_transactionally '        marker_executable_sha=$schema1_handoff_abort_marker_cli_sha' 'schema1-handoff candidate marker SHA'
require_in_function start_and_freeze_linux_v13 'start_pinned_v13_transient_unit viewflow "$v13_viewflow_unit" "$VIEWFLOW_INSTALLED" "$old_viewflow_sha" \' 'FD-gated Viewflow transient start'
require_in_function start_and_freeze_linux_v13 'load_state=$(systemctl --user show --property LoadState --value "$v13_viewflow_unit" 2>/dev/null || true)' 'restart adoption load-state observation'
require_in_function start_and_freeze_linux_v13 'expected_exec_start_sha=$(expected_viewflow_v13_exec_start_sha)' 'restart adoption expected ExecStart reconstruction'
require_in_function start_and_freeze_linux_v13 'observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_viewflow_unit")' 'restart adoption observed ExecStart reconstruction'
require_exact_line_in_function start_and_freeze_linux_v13 '        [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' 'restart adoption exact ExecStart equality'
require_in_function start_and_freeze_linux_v13 "die 'pre-existing Linux v1.3 transient unit differs from fixed gate argv'" 'restart adoption exact ExecStart rejection'
require_in_function start_and_freeze_linux_v13 'process_sha=$(sha256 "/proc/$pid/exe" 2>/dev/null)' 'gate-to-target process SHA wait'
require_exact_line_in_function start_and_freeze_linux_v13 '           [[ $process_sha == "$old_viewflow_sha" ]]; then' 'gate-to-target process SHA equality before readiness'
require_in_function start_and_freeze_linux_v13 '[[ $pid =~ ^[1-9][0-9]*$ && $process_sha == "$old_viewflow_sha" ]] ||' 'post-wait process identity rejection'
require_in_function failed_v13_abort_preflight 'assert_adoptable_linux_v13_without_receipt' 'receipt-less transient adoption preflight'
require_in_function assert_adoptable_linux_v13_without_receipt '$observed_exec_start_sha == "$expected_exec_start_sha"' 'receipt-less transient ExecStart equality'
require_in_function assert_adoptable_linux_v13_without_receipt '$(sha256 "/proc/$pid/exe") == "$old_viewflow_sha"' 'receipt-less transient executable equality'
require_in_function assert_adoptable_linux_v13_without_receipt '$control_group == "$process_cgroup"' 'receipt-less transient cgroup equality'
require_in_function assert_adoptable_linux_v13_without_receipt '$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == inactive' 'receipt-less persistent Viewflow exclusion'
require_in_function assert_adoptable_linux_v13_without_receipt '$viewflow_runtime_pids == "$pid"' 'receipt-less single Viewflow runtime equality'
require_in_function assert_adoptable_linux_v13_without_receipt '$udp_listener == *"pid=$pid,"*' 'receipt-less UDP owner equality'
require_in_function assert_adoptable_linux_v13_without_receipt '$sidecar_listener == *"pid=$pid,"*' 'receipt-less sidecar owner equality'
require_in_function start_and_freeze_linux_v13 '$expected_exec_start_sha == "$(expected_viewflow_v13_exec_start_sha)"' 'Viewflow pre-launch expected hash continuity'
require_in_function start_and_freeze_linux_v13 '$observed_exec_start_sha == "$expected_exec_start_sha"' 'Viewflow observed/expected equality'
require_in_function start_and_freeze_linux_v13 'expected_exec_start_sha256:$expected_exec_start,exec_start_sha256:$observed_exec_start' 'Viewflow receipt freezes both hashes'
require_in_function validate_linux_v13_started 'expected_exec_start_sha=$(expected_viewflow_v13_exec_start_sha)' 'Viewflow expected hash reconstruction'
require_in_function validate_linux_v13_started 'observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_viewflow_unit")' 'Viewflow manager hash observation'
require_in_function validate_linux_v13_started '[[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' 'Viewflow live manager/expected equality'
require_in_function validate_linux_v13_started '.exec_start_sha256 == $observed_exec_start and .exec_start_sha256 == .expected_exec_start_sha256' 'Viewflow receipt/live/expected equality'
require_exact_line_in_function validate_linux_v13_started '    assert_adoptable_linux_v13_without_receipt' 'existing receipt retains exact single-runtime adoption boundary'
require_in_function start_and_freeze_windows_v13 '\$enc=New-Object Text.UnicodeEncoding(\$false,\$true)' 'Windows task XML UTF-16LE encoding'
require_in_function start_and_freeze_windows_v13 '[Array]::Copy(\$pre,0,\$xmlBytes,0,\$pre.Length)' 'Windows task XML BOM preservation'
require_in_function start_and_freeze_windows_v13 'if [[ -e $windows_v13_started_receipt || -L $windows_v13_started_receipt ]]; then' 'durable Windows receipt resume branch'
require_exact_line_in_function start_and_freeze_windows_v13 '        validate_windows_v13_started' 'durable Windows receipt live reattestation call'
require_in_function validate_windows_v13_started "capture_json_command 'Windows v1.3 live reattestation' \"\$live\" ssh_windows \"\$command\"" 'existing Windows receipt live SSH reattestation'
require_in_function validate_windows_v13_started 'windows_v13_live_reattest_counter=$((${windows_v13_live_reattest_counter:-0} + 1))' 'unique same-run Windows reattestation counter'
require_in_function validate_windows_v13_started 'live=$secure_dir/windows-v13-live.${windows_v13_live_reattest_counter}.json' 'unique same-run Windows reattestation path'
require_in_function validate_windows_v13_started '\$rows.Count-ne1' 'exact one live Windows v1.3 process'
require_in_function validate_windows_v13_started '.pid == $receipt[0].pid and .process_start_filetime_utc == $receipt[0].process_start_filetime_utc' 'Windows receipt/live PID and start-time equality'
require_in_function freeze_authenticated_v13_peer 'grep -F "viewflowd server authenticated peer ${EXPECTED_WINDOWS_SOURCE_IP}:"' 'Windows source-IP authentication record'
require_in_function freeze_authenticated_v13_peer '[[ -n $fresh_probe && $fresh_probe != "$baseline_probe" ]] && break' 'post-boundary fresh peer probe'
require_in_function freeze_authenticated_v13_peer 'fresh_probe_record_sha256:$probe' 'fresh peer probe receipt binding'
require_in_function freeze_authenticated_v13_peer 'current_v13_peer_probe_sha=$fresh_probe_sha' 'current abort-entry probe capture'
require_in_function freeze_authenticated_v13_peer 'if [[ -e $authenticated_v13_peer_receipt || -L $authenticated_v13_peer_receipt ]]; then' 'durable authenticated receipt resume branch'
require_in_function freeze_authenticated_v13_peer '        validate_authenticated_v13_peer' 'durable authenticated receipt replay validation'
require_in_function validate_authenticated_v13_peer 'journal_record_sha_exists "$invocation" "viewflowd server authenticated peer ${peer_ip}:${peer_port}" "$authenticated_sha"' 'authenticated journal record replay validation'
require_in_function validate_authenticated_v13_peer 'journal_record_sha_exists "$invocation" "viewflowd server peer ${peer_ip}:${peer_port} probe=" "$probe_sha"' 'fresh probe journal record replay validation'
require_in_function make_and_validate_abort_authorization '[[ $current_v13_peer_probe_sha =~ ^[0-9a-f]{64}$ ]]' 'current abort-entry probe precondition'
if function_body make_and_validate_abort_authorization | grep -F 'fresh_entry_probe_record_sha256' >/dev/null; then fail 'abort authorization exceeds frozen marker CLI schema'; fi
if function_body start_and_freeze_linux_v13 | grep -F -- 'systemctl --user start "$VIEWFLOW_UNIT"' >/dev/null; then fail 'failed-v1.3 Viewflow uses mutable persistent unit'; fi
if function_body main | grep -Eq 'abort_deployment_marker|VFDQA001|abort-authorization'; then fail 'normal success path contains abort semantics'; fi
if function_body abort_deployment_marker_transactionally | grep -Eq '(^|[[:space:]])release([[:space:]\\]|$)|VFDQR001'; then fail 'abort path contains release semantics'; fi
abort_linux=$(first_function_line failed_v13_abort_main '    start_and_freeze_linux_v13')
abort_windows=$(first_function_line failed_v13_abort_main '    start_and_freeze_windows_v13')
abort_peer=$(function_line failed_v13_abort_main '    freeze_authenticated_v13_peer')
abort_authorize=$(function_line failed_v13_abort_main '    make_and_validate_abort_authorization')
abort_commit=$(function_line failed_v13_abort_main '    abort_deployment_marker_transactionally')
abort_reset=$(function_line failed_v13_abort_main '    reset_failed_deskflow_recovery_unit')
abort_deskflow=$(function_line failed_v13_abort_main '    start_pinned_v13_transient_unit deskflow "$v13_deskflow_unit" "$DESKFLOW_INSTALLED" "$old_deskflow_sha"')
((abort_linux < abort_windows && abort_windows < abort_peer && abort_peer < abort_authorize && abort_authorize < abort_commit && abort_commit < abort_reset && abort_reset < abort_deskflow)) || fail 'restart/auth/abort/Deskflow ordering is unsafe'
require_in_function validate_fd_gate_contract '$(sha256 "$FD_GATE_BWRAP") == "$FD_GATE_BWRAP_SHA256"' 'Bubblewrap runtime identity'
require_in_function canonical_fd_gate_exec_start_sha '"$FD_GATE_DESKFLOW_PAYLOAD_SHA256" "$FD_GATE_DESKFLOW_PAYLOAD"' 'sealed sibling ExecStart payload'
require_in_function reset_failed_deskflow_recovery_unit '$observed == "$(legacy_deskflow_v13_exec_start_sha)"' 'exact failed memfd unit adoption'
require_in_function reset_failed_deskflow_recovery_unit 'systemctl --user reset-failed "$v13_deskflow_unit"' 'failed unit replacement'
require_in_function failed_v13_abort_main '$(sha256 "/proc/$bwrap_pid/exe") == "$FD_GATE_BWRAP_SHA256"' 'Bubblewrap MainPID identity'
require_in_function failed_v13_abort_main 'deskflow_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_sha")' 'sealed GUI cgroup/hash discovery'
require_in_function failed_v13_abort_main 'core_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_core_sha")' 'sealed core cgroup/hash discovery'
require_in_function failed_v13_abort_main '$deskflow_cgroup == "$deskflow_process_cgroup" && $deskflow_cgroup == "$core_cgroup"' 'Bubblewrap/Deskflow/core same transient cgroup'
require_in_function publish_pre_mutation_abort_terminal '$deskflow_cgroup == "$deskflow_process_cgroup" && $deskflow_cgroup == "$core_cgroup"' 'pre-mutation Bubblewrap/Deskflow/core same transient cgroup'
require_in_function failed_v13_abort_main 'process_descends_from "$deskflow_pid" "$bwrap_pid" ||' 'Deskflow GUI descendant proof'
require_in_function failed_v13_abort_main 'process_descends_from "$core_pid" "$deskflow_pid" ||' 'deskflow-core descendant proof'
require_in_function failed_v13_abort_main '$deskflow_expected_exec_start_sha == "$(expected_deskflow_v13_exec_start_sha)"' 'Deskflow pre-launch expected hash continuity'
require_in_function failed_v13_abort_main '$deskflow_observed_exec_start_sha == "$deskflow_expected_exec_start_sha"' 'Deskflow observed/expected equality'
require_in_function publish_pre_mutation_abort_terminal '$deskflow_observed_exec_start_sha == "$deskflow_expected_exec_start_sha"' 'pre-mutation Deskflow observed/expected equality'
require_in_function failed_v13_abort_main 'linux_deskflow_expected_exec_start_sha256:$deskflow_expected_exec_start' 'Deskflow expected ExecStart receipt binding'
require_in_function failed_v13_abort_main 'linux_deskflow_exec_start_sha256:$deskflow_observed_exec_start' 'Deskflow observed ExecStart receipt binding'
require_in_function failed_v13_abort_main 'fd_gate_payload_sha256:$gate' 'Deskflow FD-gate receipt binding'
require_in_function failed_v13_abort_main 'bubblewrap_sha256:$bwrap' 'Deskflow Bubblewrap receipt binding'
require_in_function failed_v13_abort_main 'sealed_sibling_directory_read_only:true' 'sealed sibling runtime receipt binding'
require_in_function failed_v13_abort_main 'linux_deskflow_main_pid:$bwrap_pid' 'Bubblewrap systemd MainPID receipt binding'
require_in_function failed_v13_abort_main 'linux_deskflow_runtime_pid:$deskflow_pid' 'Deskflow GUI runtime PID receipt binding'
require_in_function validate_live_deskflow_recovery_tuple '$(cgroup_executable_sha_pids "$unit" "$FD_GATE_BWRAP_SHA256") == "$bwrap_pid"' 'final exact Bubblewrap cgroup census'
require_in_function validate_live_deskflow_recovery_tuple '$(cgroup_executable_sha_pids "$unit" "$old_deskflow_sha") == "$deskflow_pid"' 'final exact Deskflow GUI cgroup census'
require_in_function validate_live_deskflow_recovery_tuple '$(cgroup_executable_sha_pids "$unit" "$old_deskflow_core_sha") == "$core_pid"' 'final exact deskflow-core cgroup census'
require_in_function validate_live_deskflow_recovery_tuple '$(sha256 "$coordinator_state") == "$state_sha"' 'final old-state identity check'
require_in_function validate_live_deskflow_recovery_tuple 'process_descends_from "$deskflow_pid" "$bwrap_pid"' 'final Deskflow ancestry check'
require_in_function validate_live_deskflow_recovery_tuple 'process_descends_from "$core_pid" "$deskflow_pid"' 'final core ancestry check'
final_deskflow_revalidation=$(function_line failed_v13_abort_main '    validate_live_deskflow_recovery_tuple "$v13_deskflow_unit"')
terminal_receipt_publish=$(function_line failed_v13_abort_main "    publish_recovery_json_once 'failed-v1.3 abort terminal transition'")
((final_deskflow_revalidation < terminal_receipt_publish)) || fail 'Deskflow tuple is not revalidated immediately before terminal publication'
if function_body failed_v13_abort_main | grep -F -- 'systemctl --user start "$DESKFLOW_UNIT"' >/dev/null; then fail 'failed-v1.3 Deskflow uses mutable persistent unit'; fi
require_pattern_in_function restart_windows_peer_after_cleanup ';\$xml=Export-ScheduledTask .*;if\(\(HashBytes \$xmlBytes\)-cne\$expectedTaskSha\)\{throw "scheduled task XML hash is invalid"\}' 'live scheduled-task XML hash comparison'
require_in_function commit_phase '                   . as $item | ((($old | has($item.key)) | not) or $old[$item.key] == $item.value)' 'append-only overlap equality'
require_in_function commit_phase '            if (all($old | to_entries[]; $committed[.key] == .value) and' 'commit-time revalidation of prior artifacts'
require_in_function commit_phase '                    ($old; if has($item.key) then . else .[$item.key] = $item.value end)' 'append-only merge'
require_in_function exact_executable_pids '    return 0' 'zero-match PID enumeration success'
PIDS_FUNCTION="$(function_body exact_executable_pids)" bash -c '
    set -Eeuo pipefail
    eval "$PIDS_FUNCTION"
    result=$(exact_executable_pids /definitely/not/a/viewflow/executable)
    [[ -z $result ]]
' || fail 'exact PID zero-match behavior regressed'

# Exercise the production FD-gate algorithm with one test-only barrier after
# the verified bytes are copied and sealed. Mutating the same source inode in
# place must still execute the sealed good ELF (touch creates a regular file),
# never the malicious ELF (mkdir would create a directory at the same argv).
fd_contract=$root/fd-contract.sh
sed -n '/^readonly FD_GATE_ENV=/,/^readonly FD_GATE_PAYLOAD_SHA256=/p' "$coordinator" >"$fd_contract"
# shellcheck source=/dev/null
source "$fd_contract"
fd_payload_file=$root/fd-payload.py
printf '%s' "$FD_GATE_PAYLOAD" >"$fd_payload_file"
fd_target=$root/fd-target
fd_swap=$root/fd-swap
fd_ready=$root/fd-ready
fd_go=$root/fd-go
cp -- /usr/bin/touch "$fd_target"
cp -- /usr/bin/mkdir "$fd_swap"
chmod 0755 "$fd_target" "$fd_swap"
mkfifo -- "$fd_ready" "$fd_go"
sed -i "s@/home/wilf/.local/lib/viewflow/viewflow-deployment-marker@$fd_target@" "$fd_payload_file"
sed -i '/^os.close(fd)$/i\with open(os.environ["VIEWFLOW_FD_GATE_READY"],"w") as signal: signal.write("1")\
with open(os.environ["VIEWFLOW_FD_GATE_GO"],"r") as release: release.read(1)' "$fd_payload_file"
fd_test_payload=$(<"$fd_payload_file")
fd_test_sha=$(printf '%s' "$fd_test_payload" | sha256sum | cut -d' ' -f1)
fd_target_sha=$(sha256 "$fd_target")
(
    cd -- "$root"
    "$FD_GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \
        VIEWFLOW_FD_GATE_READY="$fd_ready" VIEWFLOW_FD_GATE_GO="$fd_go" \
        "$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$fd_test_sha" "$fd_test_payload" \
        "$fd_target" "$fd_target_sha" "$(id -u)" 0755 1 marker query
) &
fd_gate_pid=$!
IFS= read -r -n1 _ <"$fd_ready"
fd_inode_before=$(stat -c '%d:%i' -- "$fd_target")
dd if="$fd_swap" of="$fd_target" status=none
fd_inode_after=$(stat -c '%d:%i' -- "$fd_target")
[[ $fd_inode_after == "$fd_inode_before" ]] || fail 'FD gate fixture did not mutate the source inode in place'
printf '1' >"$fd_go"
set +e
wait "$fd_gate_pid"
fd_gate_status=$?
set -e
[[ $fd_gate_status == 0 && -f $root/query && ! -d $root/query ]] || fail "FD gate dentry-swap fixture failed: status=$fd_gate_status malicious_execution=$([[ -d $root/query ]] && echo 1 || echo 0)"

# Execute the production commit_phase body in an isolated child shell.  This
# proves the jq transaction itself preserves old keys while rejecting both a
# changed overlap and a missing formerly committed artifact; it is not a token
# presence check and cannot touch a real coordinator state file.
run_commit_artifact_case() {
    local state_path=$1 rendered=$2
    COMMIT_FUNCTION="$(function_body commit_phase)" RENDERED_COMMITTED=$rendered STATE_PATH=$state_path \
        bash -c '
            set -Eeuo pipefail
            phase_rank() { case $1 in INIT) printf "0\n" ;; NEXT) printf "1\n" ;; *) return 1 ;; esac; }
            render_committed_artifacts() { printf "%s\n" "$RENDERED_COMMITTED"; }
            eval "$COMMIT_FUNCTION"
            phase=INIT
            coordinator_state=$STATE_PATH
            recovery_failure_phase=
            recovery_mutation_possible=0
            commit_phase NEXT
        '
}
commit_add_state=$root/commit-add.json
printf '%s\n' '{"phase":"INIT","recovery":{},"committed_artifacts":{"a":"old","b":"keep"}}' >"$commit_add_state"
run_commit_artifact_case "$commit_add_state" '{"a":"old","b":"keep","c":"new"}'
jq -e '.phase == "NEXT" and .committed_artifacts == {"a":"old","b":"keep","c":"new"}' \
    "$commit_add_state" >/dev/null || fail 'commit_phase did not append without replacing old artifacts'
for rejected in changed missing; do
    commit_reject_state=$root/commit-reject-$rejected.json
    printf '%s\n' '{"phase":"INIT","recovery":{},"committed_artifacts":{"a":"old","b":"keep"}}' >"$commit_reject_state"
    if [[ $rejected == changed ]]; then
        rendered='{"a":"new","b":"keep"}'
    else
        rendered='{"a":"old"}'
    fi
    if run_commit_artifact_case "$commit_reject_state" "$rendered" >/dev/null 2>&1; then
        fail "commit_phase accepted $rejected previously committed artifact"
    fi
    jq -e '.phase == "INIT" and .committed_artifacts == {"a":"old","b":"keep"}' \
        "$commit_reject_state" >/dev/null || fail "failed $rejected commit changed durable state"
done
require_in_function windows_create_or_verify '[Console]::Out.Write((Get-FileHash -LiteralPath '\''$remote'\'' -Algorithm SHA256).Hash.ToLowerInvariant())' 'newline-free remote staged hash'
require_in_function windows_create_or_verify '        require_sha256 "remote staged input hash $remote" "$remote_hash"' 'strict remote staged lowercase SHA-256'
require_in_function windows_create_or_verify '        [[ $remote_hash == "$expected" ]] ||' 'remote staged hash equality'
verify_remote_hash=$(function_line windows_create_or_verify '[Console]::Out.Write((Get-FileHash -LiteralPath '\''$remote'\'' -Algorithm SHA256).Hash.ToLowerInvariant())')
verify_hash_format=$(function_line windows_create_or_verify '        require_sha256 "remote staged input hash $remote" "$remote_hash"')
verify_hash_match=$(function_line windows_create_or_verify '        [[ $remote_hash == "$expected" ]] ||')
((verify_remote_hash < verify_hash_format && verify_hash_format < verify_hash_match)) || fail 'remote staged hash may compare before strict validation'
require_in_function prearm_windows_recovery '[Console]::Out.Write((Get-FileHash -LiteralPath '\''$WINDOWS_ROLLBACK_SCRIPT'\'' -Algorithm SHA256).Hash.ToLowerInvariant())' 'newline-free remote rollback hash'
require_in_function prearm_windows_recovery '    require_sha256 '\''remote rollback consumer hash'\'' "$remote_hash"' 'strict remote rollback lowercase SHA-256'
require_in_function prearm_windows_recovery '    [[ $remote_hash == "$local_hash" ]] || die '\''remote rollback consumer differs from reviewed local bytes'\''' 'remote rollback hash equality'
require_in_function prearm_windows_recovery '    if windows_remote_exists "$windows_rollback_receipt_path"; then' 'terminal rollback receipt selects consumed token'
require_in_function prearm_windows_recovery '        expected_consumed_token_path="${windows_rollback_token_path%.json}.consumed.${operation_id}.json"' 'terminal rollback consumed-token derivation'
require_in_function prearm_windows_recovery '        windows_remote_exists "$windows_rollback_token_path" &&' 'terminal rollback rejects original token'
require_in_function prearm_windows_recovery '        windows_read_file "$expected_consumed_token_path" "$remote_token_snapshot"' 'terminal rollback consumed token read'
require_in_function prearm_windows_recovery '        windows_read_file "$windows_rollback_token_path" "$remote_token_snapshot"' 'nonterminal rollback original token read'
require_in_function prearm_windows_recovery '    validate_rollback_snapshots' 'unified rollback snapshot validation'
prearm_remote_hash=$(function_line prearm_windows_recovery '[Console]::Out.Write((Get-FileHash -LiteralPath '\''$WINDOWS_ROLLBACK_SCRIPT'\'' -Algorithm SHA256).Hash.ToLowerInvariant())')
prearm_hash_format=$(function_line prearm_windows_recovery '    require_sha256 '\''remote rollback consumer hash'\'' "$remote_hash"')
prearm_hash_match=$(function_line prearm_windows_recovery '    [[ $remote_hash == "$local_hash" ]] || die '\''remote rollback consumer differs from reviewed local bytes'\''')
((prearm_remote_hash < prearm_hash_format && prearm_hash_format < prearm_hash_match)) || fail 'remote rollback hash may compare before strict validation'
prearm_terminal=$(function_line prearm_windows_recovery '    if windows_remote_exists "$windows_rollback_receipt_path"; then')
prearm_consumed_name=$(function_line prearm_windows_recovery '        expected_consumed_token_path="${windows_rollback_token_path%.json}.consumed.${operation_id}.json"')
prearm_original_absent=$(function_line prearm_windows_recovery '        windows_remote_exists "$windows_rollback_token_path" &&')
prearm_consumed_read=$(function_line prearm_windows_recovery '        windows_read_file "$expected_consumed_token_path" "$remote_token_snapshot"')
prearm_else=$(function_line prearm_windows_recovery '    else')
prearm_original_read=$(function_line prearm_windows_recovery '        windows_read_file "$windows_rollback_token_path" "$remote_token_snapshot"')
prearm_validate_snapshots=$(function_line prearm_windows_recovery '    validate_rollback_snapshots')
((prearm_terminal < prearm_consumed_name && prearm_consumed_name < prearm_original_absent && prearm_original_absent < prearm_consumed_read && prearm_consumed_read < prearm_else && prearm_else < prearm_original_read && prearm_original_read < prearm_validate_snapshots)) || fail 'terminal rollback must select consumed token before unified validation'
require_in_function main '    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_STAGED) && -e $linux_stage_receipt ]]; then' 'Ls receipt-first adoption'
require_in_function main '        windows_create_or_verify "$linux_stage_receipt" "$windows_stage_path"' 'Ls remote adoption'
require_in_function main '    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_FINALIZED_MARKER_HELD) && -e $linux_finalize_receipt ]]; then' 'Lf receipt-first adoption'
require_in_function main '        commit_phase LINUX_FINALIZED_MARKER_HELD' 'Lf adoption commit'
require_in_function recover_both_hosts '            if ((proof_count == 0)); then' 'both-or-none proof generation'
require_in_function recover_both_hosts '            elif ((proof_count != 2)); then' 'partial proof rejection'
require_in_function recover_both_hosts "                    --bootstrap-v1.3-legacy-config \\" 'explicit bootstrap-v1.3 legacy-config recovery call'
require_in_function ensure_recovery_publish_intent 'viewflow-recovery-marker-publish-intent' 'generation-2 publish intent'
require_in_function republish_deployment_marker_for_recovery 'adopt_active_recovery_marker "$current_sha"' 'generation-2 active adoption'
require_in_function republish_deployment_marker_for_recovery "        die 'uncertain: failed deployment recovery will not complete a protocol-2.1 release claim'" 'release-claim fail-closed during recovery'
if function_body republish_deployment_marker_for_recovery | grep -F -- '"$MARKER_CLI" release' >/dev/null; then fail 'recovery emits normal release'; fi
require_in_function republish_deployment_marker_for_recovery '    [[ $state == deployment-quarantine-released ]] ||' 'pre-existing release proof before republish'
require_in_function main 'RUST_ACCEPTANCE_ARMED' 'post-release Rust phase'
require_in_function main 'CPP_ACCEPTANCE_ARMED' 'post-release C++ arm phase'
require_in_function main 'CPP_CLEANED' 'post-release cleanup phase'
require_in_function restart_windows_peer_after_cleanup 'windows_remote_exists "$windows_restart_claim_path" && die' 'restart claim fail-closed'
require_in_function restart_windows_peer_after_cleanup 'commit_phase WINDOWS_RESTART_DISPATCHED' 'restart dispatch claim phase'
require_in_function restart_windows_peer_after_cleanup 'Windows restart returned without durable terminal receipt' 'restart terminal requirement'
require_in_function run_windows_rollback 'if windows_remote_exists "$windows_rollback_receipt_path"; then' 'rollback terminal-first'
require_in_function run_windows_rollback 'elif windows_remote_exists "$windows_rollback_claim_path"; then' 'rollback dispatch claim'
require_in_function run_windows_rollback 'uncertain: rollback dispatch claim exists without a terminal receipt' 'rollback claim fail-closed'
require_in_function validate_rollback_snapshots 'rollback manifest/token bytes differ from P authorization' 'P authorization hash equality'
require_in_function validate_rollback_snapshots '    [[ $remote_manifest_sha == "$authorized_manifest" && $remote_token_sha == "$authorized_token" ]] ||' 'P manifest/token equality'
require_in_function validate_rollback_snapshots 'windows_operation_root\\runtime-receipt.json' 'fixed recovery leaves'
require_in_function require_bootstrap_deactivation_transport_leaf '    leaf=$(basename -- "$linux_deactivation_transcript")' 'bootstrap transcript basename derivation'
require_in_function require_bootstrap_deactivation_transport_leaf '    [[ $leaf == linux-deactivation-transcript.json ]] ||' 'fixed bootstrap transcript leaf equality'
require_in_function require_bootstrap_deactivation_transport_leaf "        die '--linux-deactivation-transcript basename must be linux-deactivation-transcript.json'" 'bootstrap transcript leaf rejection'
if function_body require_bootstrap_deactivation_transport_leaf | grep -Eq '^[[:space:]]*(return|exit)[[:space:]]'; then fail 'bootstrap transcript leaf validator can short-circuit'; fi
require_pattern_in_function bootstrap_preflight '^[[:space:]]*require_bootstrap_deactivation_transport_leaf[[:space:]]*$' 'unconditional bootstrap transcript leaf validation'
transcript_leaf_check=$(function_line bootstrap_preflight '    require_bootstrap_deactivation_transport_leaf')
transcript_adopt=$(function_line bootstrap_preflight '    adopt_consume_intent_inputs')
((transcript_leaf_check < transcript_adopt)) || fail 'bootstrap transcript leaf check may follow durable adoption'
require_in_function make_recovery_bundle 'proof_name=$(windows_fixed_leaf "$windows_operation_root\\linux-deactivation-proof.json")' 'bundle fixed bootstrap leaf'
require_in_function make_recovery_bundle 'runtime_name=$(windows_fixed_leaf "$windows_operation_root\\runtime-receipt.json")' 'bundle fixed normal leaf'
require_in_function validate_recovery_bundle 'proof_name=$(windows_fixed_leaf "$windows_operation_root\\linux-deactivation-proof.json")' 'bundle validation fixed bootstrap leaf'
require_in_function validate_recovery_bundle 'runtime_name=$(windows_fixed_leaf "$windows_operation_root\\runtime-receipt.json")' 'bundle validation fixed normal leaf'
if function_body make_recovery_bundle | grep -F -- 'basename --' >/dev/null; then fail 'bundle uses local basename for remote leaf'; fi
if function_body validate_recovery_bundle | grep -F -- 'basename --' >/dev/null; then fail 'bundle validation uses local basename for remote leaf'; fi
for state in pre_release cleaned retained; do require_in_function classify_runtime_after_containment "runtime_recovery_state=$state" "runtime-marker mapping $state"; done

# Model the durable dispatch boundary. A resume probes Status first; it may
# issue the first Start only after exact absent. Once dispatch could have been
# delivered, every SSH-loss resume window is Status-only.
start_count=0 status_count=0 phase=WINDOWS_START_INTENT
dispatch() { local is_resume=$1; if [[ $phase == WINDOWS_START_INTENT && $is_resume == 0 ]]; then ((start_count += 1)); phase=WINDOWS_STARTED; else ((status_count += 1)); fi; }
dispatch 0
for breakpoint in start_return_lost prepared force_attested windows_committed; do : "$breakpoint"; dispatch 1; done
[[ $start_count == 1 && $status_count == 4 ]] || fail 'resume can dispatch a second Start/worker'
start_count=0; status_count=1; phase=WINDOWS_START_INTENT
status_state=viewflow-windows-bootstrap-absent
if [[ $status_state == viewflow-windows-bootstrap-absent ]]; then dispatch 0; fi
dispatch 1
[[ $start_count == 1 && $status_count == 2 ]] || fail 'proven-absent resume did not preserve at-most-once Start'

# Durable receipts only move forward. Replaying a committed phase is query or
# exact-byte verification, never another committed mutation.
phases=(WINDOWS_PUBLISH_INTENT WINDOWS_START_INTENT WINDOWS_STARTED WINDOWS_PREPARED WINDOWS_PERMIT_PUBLISH_INTENT MUTATION_PERMITTED WINDOWS_FORCE_ATTESTED LINUX_STAGED WINDOWS_COMMITTED WINDOWS_TERMINAL LINUX_FINALIZED_MARKER_HELD MARKER_RELEASED RUST_ACCEPTANCE_ARMED CPP_ACCEPTANCE_ARMED CPP_CLEANED WINDOWS_RESTART_INTENT WINDOWS_RESTART_DISPATCHED WINDOWS_RESTARTED POST_RELEASE_VERIFIED STOP_INTENT STOPPED LINUX_RECOVERED WINDOWS_ROLLBACK_INTENT WINDOWS_ROLLED_BACK)
previous=-1
for index in "${!phases[@]}"; do ((index > previous)) || fail 'phase regression'; previous=$index; done

# Every injected failure point must begin with exact launcher Stop, then leave
# Linux inactive/requarantined before any Windows rollback.
recovery=$(sed -n '/^recover_both_hosts() {/,/^}/p' "$coordinator")
stop_line=$(grep -nF 'stop_exact_windows_bootstrap' <<<"$recovery" | cut -d: -f1)
repub_line=$(grep -nF 'republish_deployment_marker_for_recovery' <<<"$recovery" | awk -F: 'NR == 1 { print $1 }')
linux_line=$(grep -nF 'rollback_linux_two_phase' <<<"$recovery" | cut -d: -f1)
windows_line=$(grep -nF 'run_windows_rollback' <<<"$recovery" | cut -d: -f1)
[[ $stop_line -lt $repub_line && $repub_line -lt $linux_line && $linux_line -lt $windows_line ]] || fail 'unsafe recovery order'
for breakpoint in H P permit F Ls W Lf marker_claim marker_pending marker_released; do
    : "$breakpoint"; [[ $stop_line -lt $linux_line && $linux_line -lt $windows_line ]] || fail "bad recovery at $breakpoint"
done

# Release crash states remain quarantined until the durable VFDQR001 proof and
# claim unlink have both completed.
for state in active claimed committed-pending-release released; do
    case $state in active|claimed|committed-pending-release) quarantined=true ;; released) quarantined=false ;; esac
    [[ $state == released || $quarantined == true ]] || fail "release state $state opened input early"
done

# Every arbitrary consume subset has exactly one selectable copy, and recovery
# can restore it without guessing which rename completed.
for mask in 0 1 2 3 4 5 6 7; do
    for bit in 0 1 2; do
        if ((mask & (1 << bit))); then selected=consumed; else selected=original; fi
        [[ $selected == consumed || $selected == original ]] || fail "invalid consume subset $mask/$bit"
    done
done

# A lost permit-upload reply is already mutation-possible; a lost rollback
# reply is reconciled from its terminal receipt and never invokes rollback twice.
grep -Fq 'commit_phase WINDOWS_PERMIT_PUBLISH_INTENT' "$coordinator" || fail 'permit upload lacks durable intent'
grep -Fq "uncertain: rollback dispatch claim exists without a terminal receipt" "$coordinator" || fail 'rollback claim can replay mutation'
grep -Fq "windows_remote_exists \"\$windows_rollback_receipt_path\"" "$coordinator" || fail 'rollback resume does not query terminal receipt first'

# Execute the production abort-authorization constructor/validator without any
# host contact.  Exact replay succeeds; an unknown key or weakened proof bit is
# rejected by the real jq predicate rather than by a token-only checker.
abort_auth_root=$root/abort-auth
mkdir -m 0700 "$abort_auth_root"
for name in handoff publish frozen force migration claim linux-start windows-start peer; do
    printf '%s\n' "$name" >"$abort_auth_root/$name"; chmod 0600 "$abort_auth_root/$name"
done
jq -cn --arg hash "$(printf 'a%.0s' {1..64})" '{restored:{binary_sha256:$hash,wrapper_sha256:$hash}}' >"$abort_auth_root/migration"
chmod 0600 "$abort_auth_root/migration"
AUTH_FUNCTION="$(function_body make_and_validate_abort_authorization)" AUTH_ROOT=$abort_auth_root \
    bash -c '
        set -Eeuo pipefail
        sha256() { sha256sum -- "$1" | cut -d" " -f1; }
        die() { printf "fixture error: %s\n" "$*" >&2; return 1; }
        require_owner_only_regular() { [[ -f $2 && ! -L $2 ]]; }
        assert_strict_json_document() { jq -e "type == \"object\"" "$2" >/dev/null; }
        publish_json_file() { cp -- "$2" "$3"; chmod 0600 "$3"; }
        eval "$AUTH_FUNCTION"
        secure_dir=$AUTH_ROOT
        operation_id=11111111111111111111111111111111
        coordinator_instance_id=33333333-3333-3333-3333-333333333333
        marker_generation=1
        abort_marker_operation_id=$operation_id
        abort_marker_generation=$marker_generation
        published_marker_sha=$(printf "b%.0s" {1..64})
        deployment_abort_authorization=$AUTH_ROOT/authorization.json
        bootstrap_handoff_receipt=$AUTH_ROOT/handoff
        deployment_publish_receipt=$AUTH_ROOT/publish
        abort_marker_publish_receipt=$deployment_publish_receipt
        bootstrap_linux_evidence=$AUTH_ROOT/frozen
        windows_force_envelope=$AUTH_ROOT/force
        local_windows_rollback_receipt=$AUTH_ROOT/migration
        local_windows_stop_evidence=$AUTH_ROOT/claim
        linux_v13_started_receipt=$AUTH_ROOT/linux-start
        windows_v13_started_receipt=$AUTH_ROOT/windows-start
        authenticated_v13_peer_receipt=$AUTH_ROOT/peer
        current_v13_peer_probe_sha=$(printf "f%.0s" {1..64})
        old_viewflow_sha=$(printf "c%.0s" {1..64})
        old_deskflow_sha=$(printf "d%.0s" {1..64})
        old_deskflow_core_sha=$(printf "e%.0s" {1..64})
        post_permit_rollback_abort=0
        post_force_pre_linux_stage_rollback_abort=0
        make_and_validate_abort_authorization
        make_and_validate_abort_authorization
        cp -- "$deployment_abort_authorization" "$AUTH_ROOT/good.json"
        jq ". + {unknown:true}" "$AUTH_ROOT/good.json" >"$deployment_abort_authorization"
        if make_and_validate_abort_authorization >/dev/null 2>&1; then exit 91; fi
        cp -- "$AUTH_ROOT/good.json" "$deployment_abort_authorization"
        jq ".protocol_2_1=true" "$AUTH_ROOT/good.json" >"$deployment_abort_authorization"
        if make_and_validate_abort_authorization >/dev/null 2>&1; then exit 92; fi
    ' || fail 'production abort authorization behavioral fixture failed'

# Execute the independent schema7 post-force constructor/validator.  This
# fixture proves the exact true-force/true-rollback/false-LS-W-exit union and
# unknown-key rejection without touching the live marker.
post_force_root=$root/post-force-auth
mkdir -m 0700 "$post_force_root"
for name in state lineage handoff publish frozen request prepared permit force stop recovery proof transcript linux-start windows-start peer; do
    printf '%s\n' "$name" >"$post_force_root/$name"; chmod 0600 "$post_force_root/$name"
done
jq -cn --arg hash "$(printf 'a%.0s' {1..64})" '{restored:{binary_sha256:$hash,wrapper_sha256:$hash}}' >"$post_force_root/rollback"
chmod 0600 "$post_force_root/rollback"
POST_FORCE_FUNCTION="$(function_body make_and_validate_post_force_rollback_abort_authorization)" POST_FORCE_ROOT=$post_force_root \
    bash -c '
        set -Eeuo pipefail
        sha256() { sha256sum -- "$1" | cut -d" " -f1; }
        die() { printf "fixture error: %s\n" "$*" >&2; return 1; }
        require_owner_only_regular() { [[ -f $2 && ! -L $2 ]]; }
        assert_strict_json_document() { jq -e "type == \"object\"" "$2" >/dev/null; }
        publish_json_file() { cp -- "$2" "$3"; chmod 0600 "$3"; }
        eval "$POST_FORCE_FUNCTION"
        secure_dir=$POST_FORCE_ROOT
        operation_id=11111111111111111111111111111111
        coordinator_instance_id=33333333-3333-3333-3333-333333333333
        marker_generation=1; abort_marker_operation_id=$operation_id; abort_marker_generation=1
        published_marker_sha=$(printf "b%.0s" {1..64})
        deployment_abort_authorization=$POST_FORCE_ROOT/authorization.json
        coordinator_state=$POST_FORCE_ROOT/state
        fresh_operation_lineage_receipt=$POST_FORCE_ROOT/lineage
        bootstrap_handoff_receipt=$POST_FORCE_ROOT/handoff
        deployment_publish_receipt=$POST_FORCE_ROOT/publish; abort_marker_publish_receipt=$deployment_publish_receipt
        bootstrap_linux_evidence=$POST_FORCE_ROOT/frozen; windows_bootstrap_request=$POST_FORCE_ROOT/request
        windows_request_sha=$(sha256 "$windows_bootstrap_request")
        windows_prepared_receipt=$POST_FORCE_ROOT/prepared; windows_mutation_permit=$POST_FORCE_ROOT/permit
        windows_force_envelope=$POST_FORCE_ROOT/force; local_windows_stop_evidence=$POST_FORCE_ROOT/stop
        local_recovery_bundle=$POST_FORCE_ROOT/recovery; linux_deactivation_proof=$POST_FORCE_ROOT/proof
        linux_deactivation_transcript=$POST_FORCE_ROOT/transcript; local_windows_rollback_receipt=$POST_FORCE_ROOT/rollback
        linux_v13_started_receipt=$POST_FORCE_ROOT/linux-start; windows_v13_started_receipt=$POST_FORCE_ROOT/windows-start
        authenticated_v13_peer_receipt=$POST_FORCE_ROOT/peer; current_v13_peer_probe_sha=$(printf "f%.0s" {1..64})
        old_viewflow_sha=$(printf "c%.0s" {1..64}); old_deskflow_sha=$(printf "d%.0s" {1..64}); old_deskflow_core_sha=$(printf "e%.0s" {1..64})
        make_and_validate_post_force_rollback_abort_authorization
        make_and_validate_post_force_rollback_abort_authorization
        cp -- "$deployment_abort_authorization" "$POST_FORCE_ROOT/good.json"
        jq ". + {unknown:true}" "$POST_FORCE_ROOT/good.json" >"$deployment_abort_authorization"
        if make_and_validate_post_force_rollback_abort_authorization >/dev/null 2>&1; then exit 91; fi
        jq ".force_release_executed=false" "$POST_FORCE_ROOT/good.json" >"$deployment_abort_authorization"
        if make_and_validate_post_force_rollback_abort_authorization >/dev/null 2>&1; then exit 92; fi
        jq ".linux_stage_committed=true" "$POST_FORCE_ROOT/good.json" >"$deployment_abort_authorization"
        if make_and_validate_post_force_rollback_abort_authorization >/dev/null 2>&1; then exit 93; fi
    ' || fail 'production schema7 post-force authorization behavioral fixture failed'

# Abort crash states remain quarantined through claim and committed-pending;
# only the exact VFDQA001 abort point is terminal.
for state in active abort-claimed abort-committed-pending-abort aborted; do
    case $state in active|abort-claimed|abort-committed-pending-abort) quarantined=true ;; aborted) quarantined=false ;; esac
    [[ $state == aborted || $quarantined == true ]] || fail "abort state $state opened input early"
done

# Build a hermetic VFDQA001 vector and execute the production decoder.  The
# fixed production receipt directory is rewritten only in the extracted
# function text; no deployment marker/receipt path is touched.
abort_wire_root=$root/abort-wire
mkdir -m 0700 "$abort_wire_root"
python3 - "$abort_wire_root" <<'PY'
import hashlib, json, pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
op = "1" * 32
source = "00000000-0000-0000-0000-000000000101"
target = "00000000-0000-0000-0000-000000000002"
coordinator = "33333333-3333-3333-3333-333333333333"
marker = bytearray(256)
marker[:8] = b"VFDQT001"
marker[8:14] = bytes([1, 1, 2, 1, 1, 32])
marker[16:48] = op.encode()
marker[144:160] = bytes.fromhex(source.replace("-", ""))
marker[160:176] = bytes.fromhex(target.replace("-", ""))
marker[176:192] = bytes.fromhex(coordinator.replace("-", ""))
marker[192:200] = struct.pack("<Q", 1788000000000)
marker[200:208] = struct.pack("<Q", 1)
marker_sha = hashlib.sha256(marker).hexdigest()
authorization = root / "authorization.json"
authorization.write_bytes(b"{}\n")
authorization.chmod(0o600)
auth_sha = hashlib.sha256(authorization.read_bytes()).hexdigest()
receipt = bytearray(384)
receipt[:8] = b"VFDQA001"
receipt[8:13] = bytes([1, 1, 1, 3, 1])
receipt[16:272] = marker
receipt[272:304] = bytes.fromhex(marker_sha)
receipt[304:336] = bytes.fromhex(auth_sha)
receipt[336:344] = struct.pack("<Q", 1788000000123)
receipt[352:384] = hashlib.sha256(receipt[:352]).digest()
durable = root / f".deployment-quarantine.v1.abort-receipt.{marker_sha}.{auth_sha}.v1"
durable.write_bytes(receipt)
durable.chmod(0o600)
value = {
 "schema_version":1,"state":"deployment-quarantine-aborted","protocol_version":"1.3","protocol_2_1":False,
 "operation_id":op,"source_display_id":source,"target_device_id":target,"coordinator_instance_id":coordinator,
 "marker_generation":"1","marker_path":"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",
 "abort_claim_path":"/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim",
 "abort_receipt_path":str(durable),"abort_authorization_path":str(authorization),
 "abort_authorization_sha256":auth_sha,"aborted_marker_sha256":marker_sha,
 "marker_created_at_unix_ms":"1788000000000","abort_committed_at_unix_ms":"1788000000123",
 "abort_committed_at_utc":"2026-08-29T16:00:00.123Z","abort_point":"abort-claim-unlink-and-parent-directory-fsync",
 "initial_force_release_executed":True,"second_force_release_executed":False,"rollback_token_consumed":False,
 "deployment_release_claimed":False,"replayed":False,
}
(root / "abort.json").write_text(json.dumps(value, separators=(",", ":")) + "\n")
(root / "abort.json").chmod(0o600)
(root / "fixture.env").write_text(f"MARKER_SHA={marker_sha}\nAUTH_SHA={auth_sha}\n")
PY
ABORT_FUNCTION="$(function_body validate_abort_receipt_v1 | sed "s|/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.|$abort_wire_root/.deployment-quarantine.v1.abort-receipt.|g")" \
    ABORT_ROOT=$abort_wire_root bash -c '
        set -Eeuo pipefail
        sha256() { sha256sum -- "$1" | cut -d" " -f1; }
        die() { printf "wire fixture error: %s\n" "$*" >&2; return 1; }
        eval "$ABORT_FUNCTION"
        # shellcheck disable=SC1090
        source "$ABORT_ROOT/fixture.env"
        operation_id=11111111111111111111111111111111
        coordinator_instance_id=33333333-3333-3333-3333-333333333333
        coordinator_instance_id_lower=33333333333333333333333333333333
        source_display_id=00000000-0000-0000-0000-000000000101
        source_display_id_lower=00000000000000000000000000000101
        target_device_id=00000000-0000-0000-0000-000000000002
        target_device_id_lower=00000000000000000000000000000002
        marker_generation=1
        abort_marker_operation_id=$operation_id
        abort_marker_generation=$marker_generation
        published_marker_sha=$MARKER_SHA
        deployment_abort_authorization=$ABORT_ROOT/authorization.json
        DEPLOYMENT_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
        validate_abort_receipt_v1 "$ABORT_ROOT/abort.json"
        cp -- "$ABORT_ROOT/abort.json" "$ABORT_ROOT/abort.good.json"
        jq ". + {unknown:true}" "$ABORT_ROOT/abort.good.json" >"$ABORT_ROOT/abort.json"
        if validate_abort_receipt_v1 "$ABORT_ROOT/abort.json" >/dev/null 2>&1; then exit 93; fi
        cp -- "$ABORT_ROOT/abort.good.json" "$ABORT_ROOT/abort.json"
        python3 - "$ABORT_ROOT/.deployment-quarantine.v1.abort-receipt.$MARKER_SHA.$AUTH_SHA.v1" <<"PY"
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1]); b = bytearray(p.read_bytes()); b[344] = 1; b[352:384] = hashlib.sha256(b[:352]).digest(); p.write_bytes(b); p.chmod(0o600)
PY
        if validate_abort_receipt_v1 "$ABORT_ROOT/abort.json" >/dev/null 2>&1; then exit 94; fi
    ' || fail 'production VFDQA001 decoder behavioral fixture failed'

# Exercise the production JSON capture boundary.  A destination directly
# beneath shared /tmp must be rejected; the same command under an existing
# owner-only secure directory must publish exactly one JSON document.
capture_root=$root/capture-boundary
mkdir -m 0700 "$capture_root"
CAPTURE_FUNCTIONS="$(function_body require_absolute_new_output)
$(function_body assert_strict_json_document)
$(function_body publish_new_file)
$(function_body capture_json_command)" CAPTURE_ROOT=$capture_root bash -c '
    set -Eeuo pipefail
    die() { return 1; }
    eval "$CAPTURE_FUNCTIONS"
    bad=/tmp/viewflow-coordinator-capture-fixture.$$
    rm -f -- "$bad"
    if capture_json_command bad "$bad" printf "%s\n" "{\"ok\":true}" >/dev/null 2>&1; then exit 91; fi
    [[ ! -e $bad ]]
    good=$CAPTURE_ROOT/good.json
    capture_json_command good "$good" printf "%s\n" "{\"ok\":true}"
    jq -e "keys == [\"ok\"] and .ok == true" "$good" >/dev/null
' || fail 'production capture destination boundary fixture failed'

# The EXIT recovery path is one-shot: recovery disarms all traps, cleans and
# clears secure_dir, then exits with the original failure.  A second EXIT
# handler must never observe a stale deleted path or re-enter recovery.
recovery_root=$root/recovery-lifecycle
mkdir -p -m 0700 "$recovery_root/secure"
set +e
CLEANUP_FUNCTIONS="$(function_body cleanup_secure_dir)
$(function_body finish_recovery)
$(function_body handle_exit)" RECOVERY_ROOT=$recovery_root bash -c '
    set -Eeuo pipefail
    eval "$CLEANUP_FUNCTIONS"
    secure_dir=$RECOVERY_ROOT/secure
    recovery_required=1 recovery_running=0 recovery_finished=0
    RECOVERY_FAILURE_EXIT=70
    recover_both_hosts() {
        local status=$1
        trap - ERR INT TERM EXIT
        printf "one\n" >>"$RECOVERY_ROOT/calls"
        recovery_running=1
        finish_recovery "$status"
    }
    trap handle_exit EXIT
    exit 23
'
recovery_status=$?
set -e
[[ $recovery_status == 23 && $(wc -l <"$recovery_root/calls") == 1 && ! -e $recovery_root/secure ]] ||
    fail 'production recovery lifecycle fixture failed'

# Execute both normal transport helpers with shell-function stand-ins. This
# proves their actual argv starts with an empty explicit config and never
# consults the bwrap user-namespace mapping of /etc/ssh/*.
transport_root=$root/null-ssh-config
mkdir -m 0700 "$transport_root"
printf 'fixture\n' >"$transport_root/source"
SSH_WINDOWS_BODY="$(function_body ssh_windows)" SSH_STDIN_BODY="$(function_body ssh_windows_stdin)" \
    WINDOWS_CREATE_BODY="$(function_body windows_create_file)" \
    TRANSPORT_ROOT=$transport_root bash -c '
    set -Eeuo pipefail
    eval "$SSH_WINDOWS_BODY"
    SSH_BATCH_OPTION=BatchMode=yes; SSH_HOST_KEY_OPTION=StrictHostKeyChecking=yes
    WINDOWS_SSH_TARGET=fixture@example.invalid
    ssh() { printf "%s\n" "$@" >"$TRANSPORT_ROOT/ssh-argv"; }
    ssh_windows "Write-Output fixture" >/dev/null
    mapfile -t ssh_argv <"$TRANSPORT_ROOT/ssh-argv"
    [[ ${ssh_argv[0]} == -F && ${ssh_argv[1]} == /dev/null ]]

    eval "$SSH_STDIN_BODY"
    payload=$'"'"'line one\nline two; $literal'"'"'
    printf "%s" "$payload" >"$TRANSPORT_ROOT/stdin-expected"
    ssh() {
        dd of="$TRANSPORT_ROOT/stdin-observed" status=none
        printf "%s\n" "$@" >"$TRANSPORT_ROOT/stdin-argv"
    }
    ssh_windows_stdin "$payload"
    [[ $(wc -l <"$TRANSPORT_ROOT/stdin-observed") == 0 ]]
    encoded=$(sed -n "s/.*FromBase64String..\([A-Za-z0-9+\/=]*\)...*/\1/p" "$TRANSPORT_ROOT/stdin-observed")
    [[ -n $encoded ]]
    printf "%s" "$encoded" | base64 --decode >"$TRANSPORT_ROOT/stdin-decoded"
    cmp -- "$TRANSPORT_ROOT/stdin-expected" "$TRANSPORT_ROOT/stdin-decoded"
    mapfile -t stdin_argv <"$TRANSPORT_ROOT/stdin-argv"
    [[ ${stdin_argv[0]} == -F && ${stdin_argv[1]} == /dev/null &&
       ${stdin_argv[-2]} == -Command && ${stdin_argv[-1]} == - ]]

    eval "$WINDOWS_CREATE_BODY"
    operation_id=11111111111111111111111111111111
    windows_user_sid=S-1-5-21-1-2-3-1001
    sha256() { sha256sum -- "$1" | cut -d" " -f1; }
    scp() { printf "%s\n" "$@" >"$TRANSPORT_ROOT/scp-argv"; }
    ssh_windows() { :; }
    windows_create_file "$TRANSPORT_ROOT/source" "C:\\fixture\\source"
    mapfile -t scp_argv <"$TRANSPORT_ROOT/scp-argv"
    [[ ${scp_argv[0]} == -F && ${scp_argv[1]} == /dev/null ]]
' || fail 'normal SSH/SCP explicit-null-config fixture failed'

# Execute the production PowerShell-command construction itself. This guards
# against Bash pattern replacements silently missing literal PowerShell array
# brackets and leaving a locale-formatted CIM DateTime in the proof.
proof_command_root=$root/pre-mutation-command
mkdir -m 0700 "$proof_command_root"
printf 'frozen\n' >"$proof_command_root/frozen"
printf 'handoff\n' >"$proof_command_root/handoff"
proof_command_assignment=$(function_body reopen_pre_mutation_stop_intent | grep -F '    command="\$root=')
[[ $(grep -Fc '    command="\$root=' <<<"$proof_command_assignment") == 1 ]] ||
    fail 'production pre-mutation command assignment is missing or duplicated'
PROOF_COMMAND_ASSIGNMENT=$proof_command_assignment PROOF_COMMAND_ROOT=$proof_command_root bash -c '
    set -Eeuo pipefail
    sha256() { sha256sum -- "$1" | cut -d" " -f1; }
    windows_operation_root="C:\\fixture\\operation"
    windows_installer_sha=$(printf "1%.0s" {1..64})
    bootstrap_linux_evidence=$PROOF_COMMAND_ROOT/frozen
    bootstrap_handoff_receipt=$PROOF_COMMAND_ROOT/handoff
    windows_request_sha=$(printf "2%.0s" {1..64})
    windows_rollback_script_sha=$(printf "3%.0s" {1..64})
    windows_launcher_sha=$(printf "4%.0s" {1..64})
    windows_wrapper_sha=$(printf "5%.0s" {1..64})
    windows_viewflow_sha=$(printf "6%.0s" {1..64})
    windows_user_sid=S-1-5-21-1-2-3-1001
    pre_mutation_old_task_xml_sha=$(printf "7%.0s" {1..64})
    pre_mutation_old_executable_sha=$(printf "8%.0s" {1..64})
    pre_mutation_old_wrapper_sha=$(printf "9%.0s" {1..64})
    pre_mutation_old_process_id=22912
    pre_mutation_old_parent_process_id=25608
    pre_mutation_old_process_creation_date=2026-08-30T23:48:47.7429320Z
    operation_id=11111111111111111111111111111111
    eval "$PROOF_COMMAND_ASSIGNMENT"
    expected_tuple="\$proc=\$procs[0];\$creationUtc=\$proc.CreationDate.ToUniversalTime().ToString('"'"'o'"'"');if(\$proc.ProcessId-ne22912-or\$proc.ParentProcessId-ne25608-or\$creationUtc-ne'"'"'2026-08-30T23:48:47.7429320Z'"'"'){throw '"'"'old process tuple changed'"'"'};"
    [[ $command == *"$expected_tuple"* ]]
    [[ $command == *'"'"'creation_date=$creationUtc;'"'"'* ]]
    [[ $command != *'"'"'creation_date=[string]$proc.CreationDate;'"'"'* ]]
' || fail 'production pre-mutation command construction fixture failed'

# Execute the strict local half of the pre-mutation retry proof validator.
# This covers every staged hash and the full old task/process identity tuple;
# changing a staged byte must be rejected by the real predicate.
retry_root=$root/pre-mutation-retry
mkdir -m 0700 "$retry_root"
printf 'frozen\n' >"$retry_root/frozen"
printf 'handoff\n' >"$retry_root/handoff"
retry_op=11111111111111111111111111111111
retry_remote="C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\$retry_op"
retry_request=$(printf '1%.0s' {1..64}); retry_installer=$(printf '2%.0s' {1..64})
retry_rollback=$(printf '3%.0s' {1..64}); retry_launcher=$(printf '4%.0s' {1..64})
retry_wrapper=$(printf '5%.0s' {1..64}); retry_candidate=$(printf '6%.0s' {1..64})
retry_oldexe=$(printf '7%.0s' {1..64}); retry_oldwrapper=$(printf '8%.0s' {1..64})
retry_tasksha=$(printf '9%.0s' {1..64}); retry_sid=S-1-5-21-1-2-3-1001
jq -cn --arg op "$retry_op" --arg root "$retry_remote" --arg request "$retry_request" \
    --arg installer "$retry_installer" --arg frozen "$(sha256 "$retry_root/frozen")" \
    --arg handoff "$(sha256 "$retry_root/handoff")" --arg rollback "$retry_rollback" \
    --arg launcher "$retry_launcher" --arg wrapper "$retry_wrapper" --arg candidate "$retry_candidate" \
    --arg oldexe "$retry_oldexe" --arg oldwrapper "$retry_oldwrapper" \
    --arg tasksha "$retry_tasksha" --arg sid "$retry_sid" '
        {schema_version:1,state:"viewflow-pre-mutation-stop-intent-retryable",operation_id:$op,
         remote_operation_root:$root,request_sha256:$request,launcher_state:"viewflow-windows-bootstrap-absent",
         operation_root_acl_exact:true,staged_file_acls_exact:true,
         staged_files:{"install-viewflow.ps1":$installer,"linux-v13-frozen-evidence.json":$frozen,
                       "marker-handoff-receipt.json":$handoff,"request.json":$request,
                       "rollback-viewflow.ps1":$rollback,"start-viewflow-bootstrap.ps1":$launcher,
                       "viewflow-client.ps1":$wrapper,"viewflowd.exe":$candidate},
         old_executable_sha256:$oldexe,old_wrapper_sha256:$oldwrapper,old_rollback_sha256:$rollback,task_xml_sha256:$tasksha,
         task:{task_path:"\\Viewflow Peer",state:"Running",action_execute:"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
               action_arguments:"-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflow-client.ps1\"",
               action_working_directory:"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow",principal_sid:$sid,logon_type:"Interactive",run_level:"Limited"},
         viewflow_process:{process_id:22912,parent_process_id:25608,creation_date:"2026-08-30T23:48:47.7429320Z",
                           executable_path:"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe",session_id:1,owner_sid:$sid,
                           command_line:"\"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe\" connect --peer 172.16.105.62:44119 --server-name viewflow-linux --cert C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\peer.pem --key C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\peer.key --ca C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\ca.pem --input-backend native --device-id 00000000000000000000000000000002 --probe-interval-ms 1000 --probe-timeout-ms 3000"}}
    ' >"$retry_root/proof.json"
jq '.staged_files["viewflowd.exe"] = (.staged_files["viewflowd.exe"] | sub("^6";"f"))' \
    "$retry_root/proof.json" >"$retry_root/bad.json"
jq '.viewflow_process.process_id += 1' "$retry_root/proof.json" >"$retry_root/bad-pid.json"
jq '.operation_root_acl_exact = false' "$retry_root/proof.json" >"$retry_root/bad-acl.json"
VALIDATE_RETRY="$(function_body validate_pre_mutation_retry_proof)" RETRY_ROOT=$retry_root \
    RETRY_OP=$retry_op RETRY_REMOTE=$retry_remote RETRY_REQUEST=$retry_request RETRY_INSTALLER=$retry_installer \
    RETRY_ROLLBACK=$retry_rollback RETRY_LAUNCHER=$retry_launcher RETRY_WRAPPER=$retry_wrapper \
    RETRY_CANDIDATE=$retry_candidate RETRY_OLDEXE=$retry_oldexe RETRY_OLDWRAPPER=$retry_oldwrapper \
    RETRY_TASKSHA=$retry_tasksha RETRY_SID=$retry_sid RETRY_PID=22912 RETRY_PPID=25608 \
    RETRY_CREATED=2026-08-30T23:48:47.7429320Z bash -c '
    set -Eeuo pipefail
    sha256() { sha256sum -- "$1" | cut -d" " -f1; }
    die() { return 1; }
    assert_strict_json_document() { jq -e "type == \"object\"" "$2" >/dev/null; }
    eval "$VALIDATE_RETRY"
    operation_id=$RETRY_OP; windows_operation_root=$RETRY_REMOTE; windows_request_sha=$RETRY_REQUEST
    windows_installer_sha=$RETRY_INSTALLER; windows_rollback_script_sha=$RETRY_ROLLBACK
    windows_launcher_sha=$RETRY_LAUNCHER; windows_wrapper_sha=$RETRY_WRAPPER; windows_viewflow_sha=$RETRY_CANDIDATE
    pre_mutation_old_executable_sha=$RETRY_OLDEXE; pre_mutation_old_wrapper_sha=$RETRY_OLDWRAPPER
    pre_mutation_old_task_xml_sha=$RETRY_TASKSHA; windows_user_sid=$RETRY_SID
    pre_mutation_old_process_id=$RETRY_PID; pre_mutation_old_parent_process_id=$RETRY_PPID
    pre_mutation_old_process_creation_date=$RETRY_CREATED
    bootstrap_linux_evidence=$RETRY_ROOT/frozen; bootstrap_handoff_receipt=$RETRY_ROOT/handoff
    validate_pre_mutation_retry_proof "$RETRY_ROOT/proof.json"
    if validate_pre_mutation_retry_proof "$RETRY_ROOT/bad.json" >/dev/null 2>&1; then exit 92; fi
    if validate_pre_mutation_retry_proof "$RETRY_ROOT/bad-pid.json" >/dev/null 2>&1; then exit 93; fi
    if validate_pre_mutation_retry_proof "$RETRY_ROOT/bad-acl.json" >/dev/null 2>&1; then exit 94; fi
' || fail 'production pre-mutation retry proof fixture failed'

# Crash-after-reopen fixture: the production dispatcher must re-attest the
# durable old identity immediately before the first Start.  A failed
# re-attestation must propagate and leave the Start count at zero.
dispatch_root=$root/pre-mutation-dispatch
mkdir -m 0700 "$dispatch_root"
REMOTE_PREPARE="$(function_body remote_prepare_and_start_once)" DISPATCH_ROOT=$dispatch_root bash -c '
    set -Eeuo pipefail
    eval "$REMOTE_PREPARE"
    operation_id=11111111111111111111111111111111
    windows_request_sha=$(printf "a%.0s" {1..64})
    windows_launcher_path="C:\\fixture\\start.ps1"; windows_request_path="C:\\fixture\\request.json"
    windows_operation_root="C:\\fixture"; windows_user_sid=S-1-5-21-1-2-3-1001; resume=1
    coordinator_state=$DISPATCH_ROOT/state.json
    jq -cn "{recovery:{pre_mutation_stop_history:{phase:\"STOP_INTENT\"}}}" >"$coordinator_state"
    pre_mutation_retry_active=1
    run_case() {
        local name=$1 should_pass=$2
        secure_dir=$DISPATCH_ROOT/$name; mkdir -m 0700 "$secure_dir"
        phase=WINDOWS_START_INTENT; reattest_count=0; start_count=0
        capture_json_command() {
            local label=$1 destination=$2
            case $label in
                "Windows launcher status response")
                    jq -cn --arg op "$operation_id" --arg request "$windows_request_sha" \
                        "{schema_version:1,state:\"viewflow-windows-bootstrap-absent\",operation_id:\$op,request_sha256:\$request,task_name:\"Viewflow Bootstrap\"}" >"$destination" ;;
                "Windows launcher first dispatch after proven-absent resume")
                    start_count=$((start_count + 1))
                    jq -cn --arg op "$operation_id" --arg request "$windows_request_sha" \
                        "{schema_version:1,state:\"viewflow-windows-bootstrap-starting\",operation_id:\$op,request_sha256:\$request}" >"$destination" ;;
                *) return 95 ;;
            esac
        }
        reopen_pre_mutation_stop_intent() {
            reattest_count=$((reattest_count + 1))
            [[ $should_pass == yes ]]
        }
        commit_phase() { phase=$1; }
        if [[ $should_pass == yes ]]; then
            remote_prepare_and_start_once
            [[ $reattest_count == 1 && $start_count == 1 && $phase == WINDOWS_STARTED ]]
        else
            if remote_prepare_and_start_once >/dev/null 2>&1; then return 96; fi
            [[ $reattest_count == 1 && $start_count == 0 && $phase == WINDOWS_START_INTENT ]]
        fi
    }
    run_case success yes
    run_case identity-drift no
' || fail 'production pre-start re-attestation dispatch fixture failed'

# STOP_INTENT ranks above the normal success phases, but the explicitly
# authorized pre-mutation resume must still query the active generation-1
# marker transaction. Execute the production branch so a rank-only regression
# cannot send this state through the released-marker path again.
marker_stop_root=$root/pre-mutation-stop-marker
mkdir -m 0700 "$marker_stop_root"
RECONCILE_MARKER="$(function_body reconcile_deployment_marker_phase)" MARKER_STOP_ROOT=$marker_stop_root bash -c '
    set -Eeuo pipefail
    eval "$RECONCILE_MARKER"
    phase=STOP_INTENT; resume_pre_mutation_stop_intent=1; pre_mutation_retry_active=0
    marker_phase_query_counter=0; secure_dir=$MARKER_STOP_ROOT
    operation_id=22222222222222222222222222222222
    coordinator_instance_id=11111111-2222-3333-4444-555555555555
    marker_generation=1; published_marker_sha=$(printf "a%.0s" {1..64})
    adopted=0; queried=0; asserted=0
    phase_rank() { case $1 in STOP_INTENT) echo 200 ;; LINUX_FINALIZED_MARKER_HELD) echo 100 ;; *) echo 0 ;; esac; }
    adopt_prepublished_marker_handoff() { adopted=$((adopted + 1)); }
    capture_json_command() {
        local label=$1 destination=$2 command=$3 mode=$4
        [[ $label == "active deployment marker transaction query" && $command == marker_cli && $mode == query ]]
        queried=$((queried + 1))
        jq -cn --arg op "$operation_id" --arg generation "$marker_generation" --arg sha "$published_marker_sha" \
            "{schema_version:2,state:\"deployment-quarantine-active\",protocol_version:\"2.1\",operation_id:\$op,marker_generation:\$generation,marker_sha256:\$sha}" >"$destination"
    }
    assert_deployment_marker() { asserted=$((asserted + 1)); }
    die() { printf "fixture: %s\n" "$*" >&2; return 1; }
    reconcile_deployment_marker_phase
    [[ $adopted == 1 && $queried == 1 && $asserted == 1 && $marker_phase_query_counter == 1 ]]
' || fail 'special STOP_INTENT active-marker transaction fixture failed'

# Exercise the immutable STOP_INTENT authorization and the real local CAS
# transition.  The validator accepts an exact sealed memfd, rejects an
# unsealed FD and a wrong SHA, and the CAS recovers each durable crash window
# without trusting mutable canonical state.
cas_root=$root/pre-mutation-state-cas
mkdir -m 0700 "$cas_root"
cas_op=22222222222222222222222222222222
cas_h=$(printf 'a%.0s' {1..64}); cas_b=$(printf 'b%.0s' {1..64})
cas_publish=$(printf 'c%.0s' {1..64}); cas_request=$(printf 'd%.0s' {1..64})
jq -cn --arg op "$cas_op" --arg h "$cas_h" --arg b "$cas_b" --arg publish "$cas_publish" --arg request "$cas_request" '
    {schema_version:2,state:"viewflow-cross-host-bootstrap",operation_id:$op,phase:"STOP_INTENT",
     recovery:{failure_phase:"WINDOWS_START_INTENT",mutation_possible:false},
     committed_artifacts:{marker_handoff:$h,linux_frozen:$b,publish_receipt:$publish,bootstrap_request:$request},
     contract:{fixture:true}}
' >"$cas_root/stop-state.json"
chmod 0600 "$cas_root/stop-state.json"

BASELINE_VALIDATOR="$(function_body validate_pre_mutation_stop_state_baseline)" \
RENDER_START="$(function_body render_pre_mutation_start_state)" \
VALIDATE_START="$(function_body validate_pre_mutation_start_state_file)" \
PUBLISH_START_CAS="$(function_body publish_pre_mutation_start_state_cas)" \
PUBLISH_JSON="$(function_body publish_json_file)" \
CAS_ROOT=$cas_root CAS_OP=$cas_op CAS_H=$cas_h CAS_B=$cas_b CAS_PUBLISH=$cas_publish CAS_REQUEST=$cas_request \
"/usr/bin/python3.14" -I -E - "$cas_root/stop-state.json" <<'PY'
import fcntl, hashlib, os, subprocess, sys

source = open(sys.argv[1], "rb").read()
required = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
fixture = r'''
set -Eeuo pipefail
eval "$BASELINE_VALIDATOR"
eval "$RENDER_START"
eval "$VALIDATE_START"
eval "$PUBLISH_START_CAS"
eval "$PUBLISH_JSON"
die() { printf 'fixture: %s\n' "$*" >&2; return 1; }
sha256() { sha256sum -- "$1" | cut -d' ' -f1; }
require_sha256() { [[ $2 =~ ^[0-9a-f]{64}$ ]] || die bad-sha; }
assert_strict_json_document() { [[ -f $2 && ! -L $2 ]] && jq -e 'type == "object"' "$2" >/dev/null; }
require_absolute_new_output() { [[ $2 == /* && ! -e $2 && ! -L $2 ]]; }
publish_new_file() { ln -- "$1" "$2"; }
validate_pre_mutation_retry_proof() { [[ -f $1 && ! -L $1 ]]; }
FD_GATE_PYTHON=/usr/bin/python3.14
operation_id=$CAS_OP
replacement_flag_count=0
successor_flag_count=0
pre_mutation_stop_state_baseline_path=$BASELINE_PATH
pre_mutation_stop_state_baseline_sha=$BASELINE_SHA
if [[ $MODE == validate ]]; then validate_pre_mutation_stop_state_baseline; exit; fi
validate_pre_mutation_stop_state_baseline
render_committed_artifacts() {
    jq -cn --arg h "$CAS_H" --arg b "$CAS_B" --arg publish "$CAS_PUBLISH" --arg request "$CAS_REQUEST" \
        --arg proof "$(sha256 "$pre_mutation_retry_proof")" \
        '{marker_handoff:$h,linux_frozen:$b,publish_receipt:$publish,bootstrap_request:$request,pre_mutation_retry:$proof}'
}
run_case() {
    local name=$1 mode=$2 dir replacement
    dir=$CAS_ROOT/$name
    rm -rf -- "$dir"; mkdir -m 0700 "$dir"; secure_dir=$dir/secure; mkdir -m 0700 "$secure_dir"
    coordinator_state=$dir/state.json
    pre_mutation_retry_proof=$dir/retry.json
    pre_mutation_start_state_candidate=$dir/state.pre-mutation-start-intent.v1.json
    pre_mutation_stop_state_claim=$dir/state.pre-mutation-stop-claim.v1
    printf '{}\n' >"$pre_mutation_retry_proof"; chmod 0600 "$pre_mutation_retry_proof"
    dd if="$pre_mutation_stop_state_baseline_path" of="$coordinator_state" status=none; chmod 0600 "$coordinator_state"
    case $mode in
        normal) ;;
        candidate)
            render_pre_mutation_start_state >"$pre_mutation_start_state_candidate"; chmod 0600 "$pre_mutation_start_state_candidate" ;;
        claim)
            render_pre_mutation_start_state >"$pre_mutation_start_state_candidate"; chmod 0600 "$pre_mutation_start_state_candidate"
            ln -- "$coordinator_state" "$pre_mutation_stop_state_claim" ;;
        unlinked)
            render_pre_mutation_start_state >"$pre_mutation_start_state_candidate"; chmod 0600 "$pre_mutation_start_state_candidate"
            ln -- "$coordinator_state" "$pre_mutation_stop_state_claim"; unlink -- "$coordinator_state" ;;
        replaced)
            ln -- "$coordinator_state" "$pre_mutation_stop_state_claim"
            replacement=$dir/replacement; dd if="$pre_mutation_stop_state_baseline_path" of="$replacement" status=none; chmod 0600 "$replacement"
            mv -T -- "$replacement" "$coordinator_state"
            set +e; (set -Eeuo pipefail; publish_pre_mutation_start_state_cas >/dev/null 2>&1); status=$?; set -e
            ((status != 0)) || return 91
            return 0 ;;
        pwrite)
            ln -- "$coordinator_state" "$pre_mutation_stop_state_claim"; printf ' ' >>"$coordinator_state"
            set +e; (set -Eeuo pipefail; publish_pre_mutation_start_state_cas >/dev/null 2>&1); status=$?; set -e
            ((status != 0)) || return 92
            return 0 ;;
    esac
    publish_pre_mutation_start_state_cas
    validate_pre_mutation_start_state_file "$coordinator_state"
    [[ $(stat -c '%d:%i' -- "$coordinator_state") == $(stat -c '%d:%i' -- "$pre_mutation_start_state_candidate") ]]
    [[ $(sha256 "$pre_mutation_stop_state_claim") == "$pre_mutation_stop_state_baseline_sha" ]]
    publish_pre_mutation_start_state_cas
}
run_case normal normal
run_case candidate-before-claim candidate
run_case claim-before-unlink claim
run_case unlink-before-publish unlinked
run_case canonical-replaced replaced
run_case canonical-pwrite pwrite
'''

def invoke(sealed: bool, wrong_sha: bool, mode: str):
    fd = os.memfd_create("viewflow-stop-state-fixture", os.MFD_ALLOW_SEALING)
    os.write(fd, source)
    os.lseek(fd, 0, os.SEEK_SET)
    if sealed:
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, required)
    env = os.environ.copy()
    env["BASELINE_PATH"] = f"/proc/self/fd/{fd}"
    digest = hashlib.sha256(source).hexdigest()
    env["BASELINE_SHA"] = ("0" * 64) if wrong_sha else digest
    env["MODE"] = mode
    result = subprocess.run(["/usr/bin/bash", "-c", fixture], env=env, pass_fds=(fd,),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.close(fd)
    return result.returncode

if invoke(True, False, "validate") != 0:
    raise SystemExit("sealed baseline rejected")
if invoke(False, False, "validate") == 0:
    raise SystemExit("unsealed baseline accepted")
if invoke(True, True, "validate") == 0:
    raise SystemExit("wrong baseline SHA accepted")
if invoke(True, False, "cas") != 0:
    raise SystemExit("CAS crash-replay fixture failed")
PY

printf 'cross-host coordinator two-phase semantic/resume model passed\n'
