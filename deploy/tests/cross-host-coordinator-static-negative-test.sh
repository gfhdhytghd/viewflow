#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
readonly PATH=/usr/bin:/bin
export PATH
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deploy_dir=$(cd -- "$script_dir/.." && pwd)
coordinator=${CROSS_HOST_COORDINATOR_SOURCE:-$deploy_dir/coordinated-v13-to-v2.sh}
checker=${CROSS_HOST_COORDINATOR_CHECKER:-$deploy_dir/check-cross-host-coordinator.sh}
semantic_test=${CROSS_HOST_COORDINATOR_SEMANTIC_TEST:-$script_dir/cross-host-coordinator-semantic-test.sh}
fail() { printf 'cross-host coordinator mutation test failed: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d' ' -f1; }
root=$(mktemp -d); chmod 0700 "$root"; trap 'rm -rf -- "$root"' EXIT

check_candidate() {
    local candidate=$1 check=$root/check.sh sha
    cp -- "$checker" "$check"; chmod 0700 "$check"; sha=$(sha256 "$candidate")
    sed -Ei "s/^readonly expected_coordinator_sha256=([0-9a-f]{64}|PENDING_FINAL_ARTIFACT)$/readonly expected_coordinator_sha256=$sha/" "$check"
    "$check" "$candidate" >/dev/null 2>&1
}
check_semantic_reject() {
    local name=$1 candidate=$2 permissive
    permissive=$root/$name-semantic-checker
    # Use /bin/true only for this invocation's copied checker so a semantic
    # rejection proves the semantic body/order checks themselves, not merely
    # the static checker's front-door rejection.
    cp -- /bin/true "$permissive"; chmod 0700 "$permissive"
    if CROSS_HOST_COORDINATOR_CHECKER="$permissive" "$semantic_test" "$candidate" >/dev/null 2>&1; then
        fail "$name semantic mutation accepted"
    fi
}
baseline=$root/baseline.sh; cp -- "$coordinator" "$baseline"
check_candidate "$baseline" || fail 'baseline rejected'
reject() { local name=$1 expression=$2 candidate; candidate=$root/$name.sh; cp -- "$coordinator" "$candidate"; sed -i "$expression" "$candidate"; if check_candidate "$candidate"; then fail "$name mutation accepted"; fi; }

reject handoff_state 's/viewflow-v13-marker-handoff-prepared/viewflow-v13-marker-handoff-ready/g'
reject frozen_state 's/viewflow-v13-bootstrap-frozen/viewflow-v13-bootstrap-running/g'
reject schema5 's/\.schema_version == 5 and \.state == "viewflow-v2-windows-installed"/.schema_version == 2 and .state == "viewflow-v2-windows-installed"/'
reject six_hashes 's/unique | length == 6/unique | length == 5/'
reject raw_force_binding "s/raw_sha=\$(jq -er '\\.raw_force_release_receipt_sha256'/raw_sha=\$(sha256 \"\$windows_force_envelope\"); : \$(jq -er '\\.raw_force_release_receipt_sha256'/"
reject old_executable_binding "s/old_sha=\$(jq -er '\\.old_executable.sha256'/old_sha=\$windows_viewflow_sha; : \$(jq -er '\\.old_executable.sha256'/"
reject dynamic_task_adoption 's/windows_task_xml_sha=$adopted_task/windows_task_xml_sha=$windows_task_xml_override/'
reject replacement_terminal_state 's/viewflow-normal-v21-candidate-retired/viewflow-normal-v21-candidate-ready/'
reject replacement_commit_state 's/viewflow-normal-v21-candidate-replacement-committed/viewflow-normal-v21-candidate-replacement-ready/'
reject replacement_duplicate_json 's/if key in out: die("duplicate JSON key "+repr(key))/if False: die("duplicate JSON key "+repr(key))/'
reject replacement_timestamp_equality 's/req(unix_ms==expected,label+" UTC\/unix_ms equality differs")/req(True,label+" UTC\/unix_ms equality differs")/'
reject replacement_archive_confinement 's#rejected_root+"/v21-operation-"+op+".rejected-"#candidate_root+".rejected-"#'
reject replacement_exact6 's/req(tuple(item.name for item in entries)==EXACT6/req(set(item.name for item in entries).issuperset(EXACT6)/'
reject replacement_tree_delimiter 's/item.name.encode()+b"\\0"+mode.encode()/item.name.encode()+b" " +mode.encode()/'
reject replacement_publish_marker_closure 's/publish_obj\["marker_path"\]==active_marker and publish_obj\["marker_sha256"\]==terminal_fresh\["deployment_marker_sha256"\]/True/'
reject replacement_handoff_publish_closure 's/handoff_obj\["deployment_publish_receipt_path"\]==publish and handoff_obj\["deployment_publish_receipt_sha256"\]==publish_sha/True/'
reject replacement_handoff_installed_marker_path 's/handoff_obj\["marker_cli_path"\]==installed_marker_cli/handoff_obj["marker_cli_path"]==marker_cli/'
reject replacement_installed_marker_hash 's/actual_sha(installed_marker_cli,marker_cli_sha,"replacement installed marker CLI")/True # installed marker hash bypass/'
reject replacement_normal_only 's/replacement_flag_count != 0 && (abort_failed_v13 || abort_failed_v13_pre_mutation)/replacement_flag_count != 0 \&\& false/'
reject successor_normal_only 's/successor_flag_count != 0 && (abort_failed_v13 || abort_failed_v13_pre_mutation)/successor_flag_count != 0 \&\& false/'
reject successor_receipt_state 's/viewflow-normal-v21-coordinator-successor-authorized/viewflow-normal-v21-coordinator-successor-ready/'
reject successor_executing_path 's/succ\["coordinator_path"\]==coordinator_source/True/'
reject successor_normal_output_set 's/absence\["normal_output_leaves"\]==normal_leaves/len(absence["normal_output_leaves"]) > 0/'
reject successor_pre_receipt_set 's/absence\["pre_receipt_operation_leaves"\]==pre_receipt_leaves/len(absence["pre_receipt_operation_leaves"]) > 0/'
reject successor_windows_task_absence 's/wproof\["operation_bound_task_count"\]==0 and wproof\["operation_bound_tasks"\]==\[\]/wproof["operation_bound_task_count"] >= 0/'
reject successor_collector_producer_closure 's/wproof\["collector_path"\]==succ\["receipt_producer_path"\]/True/'
reject successor_committed_receipt 's/\.committed_artifacts\.coordinator_successor_receipt == \$receipt/.committed_artifacts | type == "object"/'
reject replacement_preflight 's/    validate_candidate_replacement_lineage/    : # replacement lineage validation bypassed/'
reject replacement_state_tree 's/candidate_tree_sha256:\$candidate_tree/candidate_tree_sha256:"unbound"/'
reject permit_viewflow 's/linux_viewflowd_sha256:\$viewflow/linux_viewflowd_sha256:$candidate/'
reject permit_marker 's/linux_deployment_marker_sha256:\$marker/linux_deployment_marker_sha256:$candidate/'
reject permit_unit 's/linux_viewflow_unit_sha256:\$unit/linux_viewflow_unit_sha256:$candidate/'
reject permit_publish_intent 's/commit_phase WINDOWS_PERMIT_PUBLISH_INTENT/commit_phase MUTATION_PERMITTED/'
reject linux_id_normalization 's/source_display_id_lower/source_display_id/g'
reject linux_coordinator_normalization 's/coordinator_instance_id_lower/coordinator_instance_id/g'
reject consume_intent 's/consume-intent.json/consume-state.json/g'
reject active_marker_union 's/--active-recovery-marker-publish-receipt/--deployment-publish-receipt/'
reject rollback_intent_phase 's/WINDOWS_ROLLBACK_INTENT) echo 230/WINDOWS_ROLLBACK_PENDING) echo 230/'
reject remote_path_confinement 's/non-canonical operation-root recovery path/untrusted remote recovery path/'
reject resume_start 's/&& \$resume == 0//' 
reject status_reconcile 's/-Mode Status -RequestPath/-Mode Start -RequestPath/'
reject resume_absent_gate 's/viewflow-windows-bootstrap-absent/viewflow-windows-bootstrap-running/g'
reject stop_mode 's/-Mode Stop -RequestPath/-Mode Status -RequestPath/'
reject stop_process_count 's/(\.installer_process_count | type == "number" and \. == floor and \. == 0)/(.installer_process_count | type == "number" and . >= 0)/'
reject stop_task_state 's/\.task_state == "Disabled"/.task_state != "Running"/'
reject durable_magic 's/VFDQR001/VFDQT001/g'
reject durable_size 's/1000:600:1:352/1000:600:1:320/'
reject durable_checksum 's/skip=320 count=32/skip=319 count=32/'
reject recovery_gate 's/readonly WINDOWS_RECOVERY_IMPLEMENTED=1/readonly WINDOWS_RECOVERY_IMPLEMENTED=0/'
reject abort_magic 's/VFDQA001/VFDQX001/g'
reject abort_size 's/1000:600:1:384/1000:600:1:352/'
reject abort_checksum 's/skip=352 count=32/skip=351 count=32/'
reject abort_terminal_phase 's/\.phase == "WINDOWS_ROLLED_BACK"/.phase == "LINUX_RECOVERED"/'
reject abort_marker_tuple_selection 's/    select_failed_v13_abort_marker_tuple/    : # active marker tuple selection removed/'
reject abort_generation2_publish_proof 's/validate_publish_receipt "\$recovery_deployment_publish_receipt" "\$recovery_marker_generation" 0 "\$recovery_operation_id"/published_marker_sha=$(sha256 "$DEPLOYMENT_MARKER")/'
reject abort_old_state_sha 's/\[\[ \$(sha256 "\$path") == "\$old_coordinator_state_sha" \]\]/[[ 1 == 1 ]]/'
reject abort_authorization_force 's/\.initial_force_release_executed == true and \.second_force_release_executed == false/.initial_force_release_executed == true/'
reject abort_authorization_token 's/\.rollback_token_consumed == false and \.protocol_2_1 == false/.rollback_token_consumed == false/'
reject abort_entry_probe_precondition 's/current_v13_peer_probe_sha =~/current_v13_peer_probe_bypassed =~/'
reject deskflow_private_sibling_mount 's/"--tmpfs",staging/"--dir",staging/'
reject deskflow_private_sibling_remount 's/"--remount-ro",staging/"--bind",staging/'
reject deskflow_core_cgroup_hash 's/core_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_core_sha")/core_pid=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")/'
reject deskflow_gui_cgroup_hash 's/deskflow_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_sha")/deskflow_pid=$(exact_executable_pids "$DESKFLOW_INSTALLED")/'
reject deskflow_bwrap_main_identity 's/$(sha256 "\/proc\/$bwrap_pid\/exe") == "$FD_GATE_BWRAP_SHA256"/1 == 1/'
reject deskflow_failed_unit_reset 's/    reset_failed_deskflow_recovery_unit/    : # failed unit reset bypassed/'
reject abort_receipt_validation 's/validate_abort_receipt_v1 "\$deployment_abort_receipt"/: # abort receipt validation removed/'
reject abort_marker_absence 's/\[\[ ! -e \$DEPLOYMENT_MARKER && ! -e \${DEPLOYMENT_MARKER}\.abort-claim && ! -e \${DEPLOYMENT_MARKER}\.release-claim \]\]/[[ ! -e $DEPLOYMENT_MARKER ]]/'
reject abort_before_auth 's/    freeze_authenticated_v13_peer/    : # peer authentication removed/'
reject abort_normal_release_confusion '/^abort_deployment_marker_transactionally() {/,/^}/s/"\$marker_role" "\$marker_executable" "\$marker_executable_sha" abort/"$marker_role" "$marker_executable" "$marker_executable_sha" release/'
reject abort_task_xml_live_check 's/HB \\$xmlBytes/HB ([byte[]]@(0))/'
reject abort_windows_exact_process 's/if(\\$rows\.Count-ne1)/if(\\$rows.Count-lt1)/'
reject release_query 's/marker_cli query/marker_cli publish/'
reject claimed_state 's/deployment-quarantine-release-claimed/deployment-quarantine-active/'
reject pending_state 's/deployment-quarantine-release-committed-pending-release/deployment-quarantine-released/'
reject weak_ssh 's/StrictHostKeyChecking=yes/StrictHostKeyChecking=no/'
reject runtime_mutation '/wait_for_rust_acceptance() {/a\    rm -- "$RUNTIME_MARKER"'
reject recovery_linux_removed 's/rollback_linux_two_phase || finish_recovery "\$RECOVERY_FAILURE_EXIT"/true/'
reject recovery_windows_removed 's/run_windows_rollback || finish_recovery "\$RECOVERY_FAILURE_EXIT"/true/'
reject recovery_completes_release_claim "s/die 'uncertain: failed deployment recovery will not complete a protocol-2.1 release claim'/\"\$MARKER_CLI\" release/"
reject recovery_republish_without_release_proof 's/\[\[ \$state == deployment-quarantine-released \]\] ||/[[ 1 == 1 ]] ||/'
reject recovery_legacy_config_removed 's/                    --bootstrap-v1\.3-legacy-config \\/                    : # legacy config flag removed/'
reject active_disconnect 's/\.disconnect_during_active_route == "not_exercised_destructive"/.disconnect_during_active_route == "passed"/'
reject baseline_path_uses_canonical '/^render_pre_mutation_start_state() {/,/^}/s/"\$pre_mutation_stop_state_baseline_path"/"$coordinator_state"/'
reject baseline_hash_bypass '/^validate_pre_mutation_stop_state_baseline() {/,/^}/s/hashlib.sha256(data)\.hexdigest()==expected/True/'
reject baseline_seal_bypass '/^validate_pre_mutation_stop_state_baseline() {/,/^}/s/seals==required/True/'
reject baseline_readonly_bypass '/^validate_pre_mutation_stop_state_baseline() {/,/^}/s/bool(os.statvfs(p)\.f_flag \& os.ST_RDONLY)/True/'
reject stop_claim_uses_copy '/^publish_pre_mutation_start_state_cas() {/,/^}/s/ln -- "\$coordinator_state" "\$pre_mutation_stop_state_claim"/cp -- "$coordinator_state" "$pre_mutation_stop_state_claim"/'
reject stop_claim_inode_bypass '/^publish_pre_mutation_start_state_cas() {/,/^}/s/\$claim_identity == "\$canonical_identity"/1 == 1/'
reject start_publish_uses_rename '/^publish_pre_mutation_start_state_cas() {/,/^}/s/ln -- "\$pre_mutation_start_state_candidate" "\$coordinator_state"/mv -T -- "$pre_mutation_start_state_candidate" "$coordinator_state"/'
reject canonical_absent_adoption_bypass "s/die 'absent canonical state lacks the exact pre-mutation CAS recovery set'/phase=WINDOWS_START_INTENT/"
reject retry_activation_bypass 's/if ((pre_mutation_retry_active)); then/if true; then/'
reject special_recovery_bypass_removed 's/\&\& \$pre_mutation_retry_active == 0//'
reject marker_installed_nlink_zero '/^assert_marker_cli_identity() {/,/^}/s/1000:755:1/1000:755:0/'
reject marker_wrapper_identity '/^marker_cli() {/,/^}/s/assert_marker_cli_identity || return/: # marker identity bypassed/'
reject marker_direct_path_exec '/^marker_cli() {/,/^}/s#run_pinned_executable marker "\$MARKER_CLI" "\$deployment_marker_sha" "\$@"#"$MARKER_CLI" "$@"#'
reject marker_fd_gate_installed_abort_removed 's/{"abort","publish","query","release"}/{"publish","query","release"}/'
reject fd_gate_payload_digest_stale 's/^readonly FD_GATE_PAYLOAD_SHA256=[0-9a-f]\{64\}$/readonly FD_GATE_PAYLOAD_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'
reject marker_candidate_fd_gate_relaxed_subcommand 's/{"abort","query"}/{"abort","publish","query"}/'
reject marker_fd_gate_sha_pin_omitted '/^marker_cli() {/,/^}/s/run_pinned_executable marker "\$MARKER_CLI" "\$deployment_marker_sha"/run_pinned_executable marker "$MARKER_CLI"/'
reject active_marker_transaction_query '/^reconcile_deployment_marker_phase() {/,/^}/s/capture_json_command '\''active deployment marker transaction query'\''/: # active marker query bypassed/'
reject special_stop_marker_branch '/^reconcile_deployment_marker_phase() {/,/^}/s/\[\[ \$phase == STOP_INTENT \&\& \$resume_pre_mutation_stop_intent == 1 \]\]/[[ false ]]/'
reject permit_marker_recheck '/^publish_mutation_permit() {/,/^}/s/reconcile_deployment_marker_phase/: # marker transaction recheck bypassed/g'
reject stage_marker_recheck '/^main() {/,/^}/s/        reconcile_deployment_marker_phase/        : # stage marker transaction recheck bypassed/g'

# Independent failed-installer/current-baseline abort contract.
function_body() { local function_name=$1 path=$2; sed -n "/^$function_name() {/,/^}/p" "$path"; }
reject_p1_function_contract() {
    local name=$1 function_name=$2 source_anchor=$3 replacement_anchor=$4 expression=$5 candidate before after
    candidate=$root/$name.sh; cp -- "$coordinator" "$candidate"
    before=$(function_body "$function_name" "$candidate" | grep -Fc -- "$source_anchor" || true)
    [[ $before == 1 ]] || fail "$name source replacement count=$before"
    sed -i "$expression" "$candidate"
    after=$(function_body "$function_name" "$candidate" | grep -Fc -- "$source_anchor" || true)
    [[ $after == 0 ]] || fail "$name source replacement count after mutation=$after"
    after=$(function_body "$function_name" "$candidate" | grep -Fc -- "$replacement_anchor" || true)
    [[ $after == 1 ]] || fail "$name replacement count=$after"
    if check_candidate "$candidate"; then fail "$name checker mutation accepted"; fi
    check_semantic_reject "$name" "$candidate"
}
reject_p1_function_contract premutation_terminal_phase_bypass \
    validate_pre_mutation_failed_terminal_state \
    '        .phase == "LINUX_RECOVERED" and' \
    '        .phase == "WINDOWS_ROLLED_BACK" and # P1 wrong terminal branch' \
    '/^validate_pre_mutation_failed_terminal_state() {/,/^}/s/\.phase == "LINUX_RECOVERED" and/.phase == "WINDOWS_ROLLED_BACK" and # P1 wrong terminal branch/'
reject_p1_function_contract premutation_mutation_possible_bypass \
    validate_pre_mutation_failed_terminal_state \
    '        .recovery == {failure_phase:"WINDOWS_STARTED",mutation_possible:false} and' \
    '        .recovery.failure_phase == "WINDOWS_STARTED" and # P1 mutation flag bypass' \
    '/^validate_pre_mutation_failed_terminal_state() {/,/^}/s/\.recovery == {failure_phase:"WINDOWS_STARTED",mutation_possible:false} and/.recovery.failure_phase == "WINDOWS_STARTED" and # P1 mutation flag bypass/'
reject_p1_function_contract premutation_exact_artifact_map_bypass \
    validate_pre_mutation_failed_terminal_state \
    '        .committed_artifacts == {marker_handoff:$h,linux_frozen:$b,publish_receipt:$p,' \
    '        .committed_artifacts.marker_handoff == $h and # P1 exact map bypass' \
    '/^validate_pre_mutation_failed_terminal_state() {/,/^}/s/\.committed_artifacts == {marker_handoff:\$h,linux_frozen:\$b,publish_receipt:\$p,/.committed_artifacts.marker_handoff == $h and # P1 exact map bypass/'
reject_p1_function_contract premutation_exit_code_bypass \
    validate_pre_mutation_failed_terminal_state \
    '        .exit_code == 1 and .request_sha256 == $request and' \
    '        .exit_code >= 1 and .request_sha256 == $request and # P1 exit bypass' \
    '/^validate_pre_mutation_failed_terminal_state() {/,/^}/s/\.exit_code == 1 and \.request_sha256 == \$request and/.exit_code >= 1 and .request_sha256 == $request and # P1 exit bypass/'
reject_p1_function_contract premutation_stop_bridge_call_bypass \
    capture_pre_mutation_windows_live_proof \
    '    validate_pre_mutation_stop_transport_bridge "$remote_stop" "$local_windows_stop_evidence"' \
    '    : # P1 stop transport bridge bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s@^    validate_pre_mutation_stop_transport_bridge "\$remote_stop" "\$local_windows_stop_evidence"$@    : # P1 stop transport bridge bypass@'
reject_p1_function_contract premutation_stop_canonical_bypass \
    validate_pre_mutation_stop_transport_bridge \
    '    [[ $remote_canonical == "$local_canonical" ]] ||' \
    '    [[ -n $remote_canonical ]] || # P1 canonical equality bypass' \
    '/^validate_pre_mutation_stop_transport_bridge() {/,/^}/s@^    \[\[ \$remote_canonical == "\$local_canonical" \]\] ||$@    [[ -n $remote_canonical ]] || # P1 canonical equality bypass@'
reject_p1_function_contract premutation_remote_exit_proof_bypass \
    validate_pre_mutation_windows_live_proof \
    '        .remote_raw_installer_exit_sha256 == $remote_exit and .transport_normalization == $transport and' \
    '        .transport_normalization == $transport and # P1 remote exit proof bypass' \
    '/^validate_pre_mutation_windows_live_proof() {/,/^}/s/\.remote_raw_installer_exit_sha256 == \$remote_exit and \.transport_normalization == \$transport and/.transport_normalization == $transport and # P1 remote exit proof bypass/'
reject_p1_function_contract premutation_remote_exit_bytes_bypass \
    capture_pre_mutation_windows_live_proof \
    '    [[ $(sha256 "$remote_exit") == "$(sha256 "$windows_installer_exit_receipt")" ]] ||' \
    '    [[ -f $remote_exit ]] || # P1 remote exit byte equality bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s@^    \[\[ \$(sha256 "\$remote_exit") == "\$(sha256 "\$windows_installer_exit_receipt")" \]\] ||$@    [[ -f $remote_exit ]] || # P1 remote exit byte equality bypass@'
reject_p1_function_contract premutation_claim_hash_bypass \
    capture_pre_mutation_windows_live_proof \
    '    [[ $(jq -er '\''.claim_sha256'\'' "$windows_installer_exit_receipt") == "$claim_sha" &&' \
    '    [[ true && # P1 launcher claim hash bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s|^    \[\[ \$(jq -er '\''.claim_sha256'\'' "\$windows_installer_exit_receipt") == "\$claim_sha" &&$|    [[ true \&\& # P1 launcher claim hash bypass|'
reject_p1_function_contract premutation_claim_validator_call_bypass \
    capture_pre_mutation_windows_live_proof \
    '    validate_pre_mutation_remote_launcher_claim "$remote_claim" "$worker_pid" "$installer_command_sha"' \
    '    : # P1 canonical launcher claim validation bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s@^    validate_pre_mutation_remote_launcher_claim "\$remote_claim" "\$worker_pid" "\$installer_command_sha"$@    : # P1 canonical launcher claim validation bypass@'
reject_p1_function_contract premutation_claim_task_name_prefix_bypass \
    validate_pre_mutation_remote_launcher_claim \
    '        .task_name == ("Viewflow Deployment " + $op) and' \
    '        .task_name == ("\\Viewflow Deployment " + $op) and # P1 TaskPath prefix accepted' \
    '/^validate_pre_mutation_remote_launcher_claim() {/,/^}/s@^        \.task_name == .*@        .task_name == ("\\\\Viewflow Deployment " + $op) and # P1 TaskPath prefix accepted@'
reject_p1_function_contract premutation_stop_task_name_bypass \
    validate_windows_stop_evidence \
    '            .task_name == ("Viewflow Deployment " + $op) and' \
    '            true and # P1 stopped TaskName binding bypass' \
    '/^validate_windows_stop_evidence() {/,/^}/s@^            \.task_name == .*@            true and # P1 stopped TaskName binding bypass@'
reject_p1_function_contract premutation_stop_start_time_format_bypass \
    validate_windows_stop_evidence \
    '            (.worker_process_start_filetime_utc | test("^[1-9][0-9]{16,18}$")) and' \
    '            (.worker_process_start_filetime_utc | type == "string") and # P1 start-time format bypass' \
    '/^validate_windows_stop_evidence() {/,/^}/s@^            (\.worker_process_start_filetime_utc .*@            (.worker_process_start_filetime_utc | type == "string") and # P1 start-time format bypass@'
reject_p1_function_contract premutation_canonical_filetime_helper_bypass \
    validate_windows_identity_scalar \
    ' "canonical-filetime":lambda v:type(v) is str and re.fullmatch(r"[1-9][0-9]{16,18}",v) is not None,' \
    ' "canonical-filetime":lambda v:type(v) is str, # P1 FILETIME canonicalization bypass' \
    '/^validate_windows_identity_scalar() {/,/^}/s@^ "canonical-filetime":.*@ "canonical-filetime":lambda v:type(v) is str, # P1 FILETIME canonicalization bypass@'
reject_p1_function_contract premutation_uint32_helper_bypass \
    validate_windows_identity_scalar \
    ' "positive-uint32":lambda v:type(v) is int and 1<=v<=4294967295,' \
    ' "positive-uint32":lambda v:isinstance(v,(int,float)) and v>0, # P1 uint32 integer/range bypass' \
    '/^validate_windows_identity_scalar() {/,/^}/s@^ "positive-uint32":.*@ "positive-uint32":lambda v:isinstance(v,(int,float)) and v>0, # P1 uint32 integer/range bypass@'
reject_p1_function_contract premutation_session_integer_helper_bypass \
    validate_windows_identity_scalar \
    ' "session-one":lambda v:type(v) is int and v==1,' \
    ' "session-one":lambda v:v==1, # P1 canonical integer token bypass' \
    '/^validate_windows_identity_scalar() {/,/^}/s@^ "session-one":.*@ "session-one":lambda v:v==1, # P1 canonical integer token bypass@'
reject_p1_function_contract premutation_stop_utc_helper_call_bypass \
    validate_windows_stop_evidence \
    '        validate_windows_identity_scalar "$evidence" stopped_at_utc utc-milliseconds' \
    '        : # P1 stopped UTC milliseconds helper bypass' \
    '/^validate_windows_stop_evidence() {/,/^}/s@^        validate_windows_identity_scalar "\$evidence" stopped_at_utc utc-milliseconds$@        : # P1 stopped UTC milliseconds helper bypass@'
reject_p1_function_contract premutation_stop_claim_identity_call_bypass \
    capture_pre_mutation_windows_live_proof \
    '    validate_pre_mutation_stop_claim_identity "$remote_stop" "$remote_claim"' \
    '    : # P1 stop/claim worker identity bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s@^    validate_pre_mutation_stop_claim_identity "\$remote_stop" "\$remote_claim"$@    : # P1 stop/claim worker identity bypass@'
reject_p1_function_contract premutation_stop_claim_start_time_equality_bypass \
    validate_pre_mutation_stop_claim_identity \
    '    [[ $(jq -er '\''.worker_process_start_filetime_utc'\'' "$stop") == \' \
    '    [[ -n $(jq -er '\''.worker_process_start_filetime_utc'\'' "$stop") ]] || # P1 stop/claim equality bypass' \
    '/^validate_pre_mutation_stop_claim_identity() {/,/^}/c\validate_pre_mutation_stop_claim_identity() {\n    local stop=$1 claim=$2\n    [[ -n $(jq -er '\''.worker_process_start_filetime_utc'\'' "$stop") ]] || # P1 stop/claim equality bypass\n        die '\''stop evidence and remote launcher claim bind different worker process start times'\''\n}'
reject_p1_function_contract premutation_process_validator_call_bypass \
    capture_pre_mutation_windows_live_proof \
    '    validate_pre_mutation_remote_installer_process "$remote_process" "$worker_pid" "$claim_sha" "$installer_command_sha"' \
    '    : # P1 remote installer-process validation bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s@^    validate_pre_mutation_remote_installer_process "\$remote_process" "\$worker_pid" "\$claim_sha" "\$installer_command_sha"$@    : # P1 remote installer-process validation bypass@'
reject_p1_function_contract premutation_live_task_name_prefix_bypass \
    validate_pre_mutation_windows_live_proof \
    '        .deployment_task.task_name == ("Viewflow Deployment " + $op) and .deployment_task.state == "Disabled" and' \
    '        .deployment_task.task_name == ("\\Viewflow Deployment " + $op) and .deployment_task.state == "Disabled" and # P1 TaskPath prefix accepted' \
    '/^validate_pre_mutation_windows_live_proof() {/,/^}/s@^        \.deployment_task\.task_name == .*@        .deployment_task.task_name == ("\\\\Viewflow Deployment " + $op) and .deployment_task.state == "Disabled" and # P1 TaskPath prefix accepted@'
reject_p1_function_contract premutation_root_members_bypass \
    capture_pre_mutation_windows_live_proof \
    'if($members.Count-ne$expected.Count-or$directoryMemberCount-ne0){throw '\''unexpected operation-root member count'\''}' \
    'if($false-or$directoryMemberCount-ne0){throw '\''unexpected operation-root member count'\''}' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s/\$members.Count-ne\$expected.Count/\$false/'
reject_p1_function_contract premutation_principal_sid_bypass \
    capture_pre_mutation_windows_live_proof \
    '$principalSid=CS ([string]$task.Principal.UserId)' \
    '$principalSid=[string]$task.Principal.UserId # P1 SID canonicalization bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s/\$principalSid=CS (\[string\]\$task.Principal.UserId)/$principalSid=[string]$task.Principal.UserId # P1 SID canonicalization bypass/'
reject_p1_function_contract premutation_installed_rollback_bypass \
    capture_pre_mutation_windows_live_proof \
    'OwnerProtectedFile $exe;OwnerProtectedFile $wrapperPath;OwnerProtectedFile $rollbackPath' \
    'OwnerProtectedFile $exe;OwnerProtectedFile $wrapperPath # P1 rollback validation bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s/OwnerProtectedFile \$exe;OwnerProtectedFile \$wrapperPath;OwnerProtectedFile \$rollbackPath/OwnerProtectedFile $exe;OwnerProtectedFile $wrapperPath # P1 rollback validation bypass/'
reject_p1_function_contract premutation_local_absence_call_bypass \
    failed_v13_pre_mutation_abort_preflight \
    '    assert_pre_mutation_outputs_absent' \
    '    : # P1 local output absence bypass' \
    '/^failed_v13_pre_mutation_abort_preflight() {/,/^}/s/^    assert_pre_mutation_outputs_absent$/    : # P1 local output absence bypass/'
reject_p1_function_contract premutation_candidate_abort_bypass \
    abort_pre_mutation_deployment_marker_transactionally \
    '            run_pinned_executable marker-candidate "$pre_mutation_abort_marker_cli_candidate" \' \
    '            run_pinned_executable marker "$MARKER_CLI" \' \
    '/^abort_pre_mutation_deployment_marker_transactionally() {/,/^}/s/run_pinned_executable marker-candidate "\$pre_mutation_abort_marker_cli_candidate"/run_pinned_executable marker "$MARKER_CLI"/'
reject_p1_function_contract premutation_abort_receipt_decode_bypass \
    abort_pre_mutation_deployment_marker_transactionally \
    '    validate_abort_receipt_v2 "$deployment_abort_receipt"' \
    '    : # P1 schema2 VFDQA decode bypass' \
    '/^abort_pre_mutation_deployment_marker_transactionally() {/,/^}/s/^    validate_abort_receipt_v2 "\$deployment_abort_receipt"$/    : # P1 schema2 VFDQA decode bypass/'
reject_p1_function_contract premutation_authorization_false_claim_bypass \
    make_and_validate_pre_mutation_abort_authorization \
    '        .initial_force_release_executed == false and .rollback_performed == false and' \
    '        .rollback_performed == false and # P1 force-release false claim bypass' \
    '/^make_and_validate_pre_mutation_abort_authorization() {/,/^}/s/\.initial_force_release_executed == false and \.rollback_performed == false and/.rollback_performed == false and # P1 force-release false claim bypass/'
reject_p1_function_contract premutation_authorization_null_rollback_bypass \
    make_and_validate_pre_mutation_abort_authorization \
    '        .windows_rollback_receipt_sha256 == null and .protocol_2_1 == false' \
    '        .protocol_2_1 == false # P1 rollback receipt null bypass' \
    '/^make_and_validate_pre_mutation_abort_authorization() {/,/^}/s/\.windows_rollback_receipt_sha256 == null and \.protocol_2_1 == false/.protocol_2_1 == false # P1 rollback receipt null bypass/'
reject_p1_function_contract premutation_fresh_peer_bypass \
    failed_v13_pre_mutation_abort_main \
    '    freeze_authenticated_v13_peer' \
    '    : # P1 fresh peer authentication bypass' \
    '/^failed_v13_pre_mutation_abort_main() {/,/^}/s/^    freeze_authenticated_v13_peer$/    : # P1 fresh peer authentication bypass/'

# These are static publication/transport contracts.  They must reject a
# mutation even when the independent resume model is deliberately bypassing
# the static checker, because it does not model filesystem or cmd.exe parsing.
function_body() { local function_name=$1 path=$2; sed -n "/^$function_name() {/,/^}/p" "$path"; }
reject_static_function_contract() {
    local name=$1 function_name=$2 source_anchor=$3 replacement_anchor=$4 expression=$5 candidate before after
    candidate=$root/$name.sh; cp -- "$coordinator" "$candidate"
    before=$(function_body "$function_name" "$candidate" | grep -Fc -- "$source_anchor" || true)
    [[ $before == 1 ]] || fail "$name source replacement count=$before"
    sed -i "$expression" "$candidate"
    after=$(function_body "$function_name" "$candidate" | grep -Fc -- "$source_anchor" || true)
    [[ $after == 0 ]] || fail "$name source replacement count after mutation=$after"
    after=$(function_body "$function_name" "$candidate" | grep -Fc -- "$replacement_anchor" || true)
    [[ $after == 1 ]] || fail "$name replacement count=$after"
    if check_candidate "$candidate"; then fail "$name checker mutation accepted"; fi
}

reject_static_function_contract publish_json_cross_filesystem_temp \
    publish_json_file \
    '    temp=$(mktemp --tmpdir="$(dirname -- "$destination")" '\''.viewflow-publish.XXXXXX'\'')' \
    '    temp=$(mktemp --tmpdir="$secure_dir" '\''.viewflow-publish.XXXXXX'\'')' \
    '/^publish_json_file() {/,/^}/s|temp=$(mktemp --tmpdir="$(dirname -- "$destination")" '\''.viewflow-publish.XXXXXX'\'')|temp=$(mktemp --tmpdir="$secure_dir" '\''.viewflow-publish.XXXXXX'\'')|'
reject_static_function_contract exact_pid_zero_match \
    exact_executable_pids \
    '    return 0' \
    '    : # zero-match returns prior test status' \
    '/^exact_executable_pids() {/,/^}/s|    return 0|    : # zero-match returns prior test status|'
reject_static_function_contract publish_json_without_dd_copy \
    publish_json_file \
    '    dd if="$source" of="$temp" status=none' \
    '    cp -- "$source" "$temp"' \
    '/^publish_json_file() {/,/^}/s|dd if="$source" of="$temp" status=none|cp -- "$source" "$temp"|'
reject_static_function_contract publish_json_without_temp_sync \
    publish_json_file \
    '    sync -f "$temp"' \
    '    : # temp sync omitted' \
    '/^publish_json_file() {/,/^}/s|sync -f "$temp"|: # temp sync omitted|'
reject_static_function_contract publish_uses_rename_not_hardlink \
    publish_new_file \
    'ln -- "$1" "$2";' \
    'mv -T -- "$1" "$2";' \
    '/^publish_new_file() {/,/^}/s|ln -- "$1" "$2";|mv -T -- "$1" "$2";|'
reject_static_function_contract operation_root_uses_cmd_pipe \
    remote_prepare_and_start_once \
    '[void]' \
    '|Out-Null' \
    '/^remote_prepare_and_start_once() {/,/^}/s@\[void\]@|Out-Null@'
reject_static_function_contract ssh_windows_not_utf16le_encoded \
    ssh_windows \
    'iconv -f UTF-8 -t UTF-16LE' \
    'iconv -f UTF-8 -t UTF-8' \
    '/^ssh_windows() {/,/^}/s@iconv -f UTF-8 -t UTF-16LE@iconv -f UTF-8 -t UTF-8@'
reject_static_function_contract ssh_windows_uses_unsafe_command \
    ssh_windows \
    '-EncodedCommand "$encoded"' \
    '-Command "$1"' \
    '/^ssh_windows() {/,/^}/s@-EncodedCommand "$encoded"@-Command "$1"@'
reject_static_function_contract ssh_windows_uses_system_config \
    ssh_windows \
    'ssh -F /dev/null' \
    'ssh -F /etc/ssh/ssh_config' \
    '/^ssh_windows() {/,/^}/s@ssh -F /dev/null@ssh -F /etc/ssh/ssh_config@'
reject_static_function_contract scp_uses_system_config \
    windows_create_file \
    'scp -F /dev/null' \
    'scp -F /etc/ssh/ssh_config' \
    '/^windows_create_file() {/,/^}/s@scp -F /dev/null@scp -F /etc/ssh/ssh_config@'
reject_static_function_contract stdin_transport_adds_newline \
    ssh_windows_stdin \
    'payload=$(printf '\''%s'\'' "$1" | base64 -w0)' \
    'payload=$(printf '\''%s'\'' "${1}x" | base64 -w0)' \
    '/^ssh_windows_stdin() {/,/^}/s@payload=$(printf '\''%s'\'' "$1" | base64 -w0)@payload=$(printf '\''%s'\'' "${1}x" | base64 -w0)@'
reject_static_function_contract stdin_transport_uses_system_config \
    ssh_windows_stdin \
    'ssh -F /dev/null' \
    'ssh -F /etc/ssh/ssh_config' \
    '/^ssh_windows_stdin() {/,/^}/s@ssh -F /dev/null@ssh -F /etc/ssh/ssh_config@'
reject_static_function_contract stdin_transport_not_command_dash \
    ssh_windows_stdin \
    '-Command -' \
    '-Command "$1"' \
    '/^ssh_windows_stdin() {/,/^}/s@-Command -@-Command "$1"@'
reject_static_function_contract stdin_transport_sends_raw_multiline_source \
    ssh_windows_stdin \
    'printf '\''%s'\'' "$bootstrap" | ssh -F /dev/null' \
    'printf '\''%s'\'' "$1" | ssh -F /dev/null' \
    '/^ssh_windows_stdin() {/,/^}/s@printf '\''%s'\'' "$bootstrap" | ssh -F /dev/null@printf '\''%s'\'' "$1" | ssh -F /dev/null@'
reject_static_function_contract stdin_transport_does_not_buffer_console_stdout \
    ssh_windows_stdin \
    '[Console]::SetOut(\$buffer);try{' \
    'try{' \
    '/^ssh_windows_stdin() {/,/^}/s@\[Console\]::SetOut(\\$buffer);try{@try{@'
reject_static_function_contract stdin_transport_commits_exception_stdout \
    ssh_windows_stdin \
    'catch{[Console]::SetOut(\$priorOut);[Console]::Error.WriteLine(\$_.Exception.Message);exit 1}' \
    'catch{[Console]::SetOut(\$priorOut);[Console]::Out.Write(\$buffer.ToString());exit 0}' \
    '/^ssh_windows_stdin() {/,/^}/s@catch{\[Console\]::SetOut(\\$priorOut);\[Console\]::Error.WriteLine(\\$_.Exception.Message);exit 1}@catch{[Console]::SetOut(\\$priorOut);[Console]::Out.Write(\\$buffer.ToString());exit 0}@'
reject_static_function_contract pre_mutation_live_proof_uses_encoded_transport \
    reopen_pre_mutation_stop_intent \
    'capture_json_command '\''pre-mutation retry live proof'\'' "$live" ssh_windows_stdin "$command"' \
    'capture_json_command '\''pre-mutation retry live proof'\'' "$live" ssh_windows "$command"' \
    '/^reopen_pre_mutation_stop_intent() {/,/^}/s@capture_json_command '\''pre-mutation retry live proof'\'' "$live" ssh_windows_stdin "$command"@capture_json_command '\''pre-mutation retry live proof'\'' "$live" ssh_windows "$command"@'
reject_p1_function_contract pre_mutation_fresh_live_proof_uses_encoded_transport \
    capture_pre_mutation_windows_live_proof \
    '    capture_json_command '\''fresh pre-mutation Windows old-live proof'\'' "$live" ssh_windows_stdin "$command"' \
    '    capture_json_command '\''fresh pre-mutation Windows old-live proof'\'' "$live" ssh_windows "$command" # P1 command-length bypass' \
    '/^capture_pre_mutation_windows_live_proof() {/,/^}/s@^    capture_json_command '\''fresh pre-mutation Windows old-live proof'\'' "\$live" ssh_windows_stdin "\$command"$@    capture_json_command '\''fresh pre-mutation Windows old-live proof'\'' "$live" ssh_windows "$command" # P1 command-length bypass@'
reject_static_function_contract bootstrap_preflight_lacks_iconv \
    bootstrap_preflight \
    '    for label in base64 bash date dd iconv jq journalctl ln mktemp mv od python3 readlink scp sha256sum ssh ss stat sync systemctl unlink; do' \
    '    for label in base64 bash date dd jq journalctl ln mktemp mv od python3 readlink scp sha256sum ssh ss stat sync systemctl unlink; do' \
    '/^bootstrap_preflight() {/,/^}/s@for label in base64 bash date dd iconv jq journalctl ln mktemp mv od python3 readlink scp sha256sum ssh ss stat sync systemctl unlink; do@for label in base64 bash date dd jq journalctl ln mktemp mv od python3 readlink scp sha256sum ssh ss stat sync systemctl unlink; do@'
reject_static_function_contract bootstrap_preflight_lacks_scp \
    bootstrap_preflight \
    'readlink scp sha256sum' \
    'readlink sha256sum' \
    '/^bootstrap_preflight() {/,/^}/s@readlink scp sha256sum@readlink sha256sum@'
reject_static_function_contract windows_read_file_appends_newline \
    windows_read_file \
    '[Console]::Out.Write' \
    '[Console]::WriteLine' \
    '/^windows_read_file() {/,/^}/s@\[Console\]::Out\.Write@\[Console\]::WriteLine@'
reject_static_function_contract windows_read_file_accepts_noncanonical_base64 \
    windows_read_file \
    '    [[ $encoded =~' \
    '    : # canonical Base64 validation bypass' \
    '/^windows_read_file() {/,/^}/s@^    \[\[ \$encoded =~.*$@    : # canonical Base64 validation bypass@'
reject_static_function_contract windows_read_file_skips_canonical_reencode \
    windows_read_file \
    '    canonical=$(base64 -w0 -- "$temp")' \
    '    canonical=$encoded # canonical Base64 re-encode bypass' \
    '/^windows_read_file() {/,/^}/s@canonical=$(base64 -w0 -- "$temp")@canonical=$encoded # canonical Base64 re-encode bypass@'
reject_static_function_contract windows_verify_hash_appends_newline \
    windows_create_or_verify \
    '[Console]::Out.Write' \
    '[Console]::WriteLine' \
    '/^windows_create_or_verify() {/,/^}/s@\[Console\]::Out\.Write@\[Console\]::WriteLine@'
reject_static_function_contract windows_verify_hash_skips_strict_format \
    windows_create_or_verify \
    '        require_sha256 "remote staged input hash $remote" "$remote_hash"' \
    '        : # remote staged hash validation bypass' \
    '/^windows_create_or_verify() {/,/^}/s|        require_sha256 "remote staged input hash $remote" "$remote_hash"|        : # remote staged hash validation bypass|'
reject_static_function_contract prearm_hash_appends_newline \
    prearm_windows_recovery \
    '[Console]::Out.Write' \
    '[Console]::WriteLine' \
    '/^prearm_windows_recovery() {/,/^}/s@\[Console\]::Out\.Write@\[Console\]::WriteLine@'
reject_static_function_contract prearm_hash_skips_strict_format \
    prearm_windows_recovery \
    '    require_sha256 '\''remote rollback consumer hash'\'' "$remote_hash"' \
    '    : # remote rollback hash validation bypass' \
    '/^prearm_windows_recovery() {/,/^}/s|    require_sha256 '\''remote rollback consumer hash'\'' "$remote_hash"|    : # remote rollback hash validation bypass|'
reject_static_function_contract prearm_terminal_reads_original_token \
    prearm_windows_recovery \
    '        windows_read_file "$expected_consumed_token_path" "$remote_token_snapshot"' \
    '        windows_read_file "$windows_rollback_token_path" "$remote_token_snapshot" # P0 terminal original-token bypass' \
    '/^prearm_windows_recovery() {/,/^}/s|        windows_read_file "\$expected_consumed_token_path" "\$remote_token_snapshot"|        windows_read_file "$windows_rollback_token_path" "$remote_token_snapshot" # P0 terminal original-token bypass|'
reject_static_function_contract prearm_terminal_allows_original_token \
    prearm_windows_recovery \
    '        windows_remote_exists "$windows_rollback_token_path" &&' \
    '        : # P0 terminal original-token coexistence bypass' \
    '/^prearm_windows_recovery() {/,/^}/s|        windows_remote_exists "\$windows_rollback_token_path" &&|        : # P0 terminal original-token coexistence bypass|'
reject_static_function_contract prearm_skips_unified_snapshot_validation \
    prearm_windows_recovery \
    '    validate_rollback_snapshots' \
    '    : # P0 unified rollback snapshot validation bypass' \
    '/^prearm_windows_recovery() {/,/^}/s|    validate_rollback_snapshots|    : # P0 unified rollback snapshot validation bypass|'
reject_static_function_contract mutation_possible_uses_argjson \
    commit_phase \
    '--arg mutation "$recovery_mutation_possible"' \
    '--argjson mutation "$recovery_mutation_possible"' \
    '/^commit_phase() {/,/^}/s@--arg mutation "$recovery_mutation_possible"@--argjson mutation "$recovery_mutation_possible"@'
reject_static_function_contract mutation_possible_new_state_is_string \
    commit_phase \
    'mutation_possible:($mutation == "1" or $mutation == "true")' \
    'mutation_possible:$mutation' \
    '/^commit_phase() {/,/^}/s@mutation_possible:($mutation == "1" or $mutation == "true")@mutation_possible:$mutation@'
reject_static_function_contract mutation_possible_existing_state_is_string \
    commit_phase \
    '.recovery.mutation_possible = ($mutation == "1" or $mutation == "true")' \
    '.recovery.mutation_possible = $mutation' \
    '/^commit_phase() {/,/^}/s@\.recovery\.mutation_possible = (\$mutation == "1" or \$mutation == "true")@.recovery.mutation_possible = $mutation@'
reject_static_function_contract recovery_mutation_read_is_relocated \
    recover_both_hosts \
    '        recovery_mutation_possible=$(jq -r '\''.recovery.mutation_possible'\'' "$coordinator_state")' \
    '        recovery_mutation_possible=$(jq -r '\''.recovery.mutation_possible_text'\'' "$coordinator_state")' \
    '/^recover_both_hosts() {/,/^}/s@\.recovery\.mutation_possible@.recovery.mutation_possible_text@'
reject_static_function_contract recovery_mutation_rejects_numeric_true \
    recover_both_hosts \
    '            true|1) recovery_mutation_possible=1 ;;' \
    '            true) recovery_mutation_possible=1 ;;' \
    '/^recover_both_hosts() {/,/^}/s@true|1) recovery_mutation_possible=1 ;;@true) recovery_mutation_possible=1 ;;@'
reject_static_function_contract recovery_mutation_rejects_numeric_false \
    recover_both_hosts \
    '            false|0) recovery_mutation_possible=0 ;;' \
    '            false) recovery_mutation_possible=0 ;;' \
    '/^recover_both_hosts() {/,/^}/s@false|0) recovery_mutation_possible=0 ;;@false) recovery_mutation_possible=0 ;;@'

# P1 mutation corpus. Every mutation first proves its replacement anchor is
# unique, then requires both the checker and the independent semantic guards
# to reject the candidate. Several retain stale proof text deliberately.
reject_p1() {
    local name=$1 source_anchor=$2 replacement_anchor=$3 expression=$4 candidate before after
    candidate=$root/$name.sh; cp -- "$coordinator" "$candidate"
    before=$(grep -Fc -- "$source_anchor" "$candidate" || true)
    [[ $before == 1 ]] || fail "$name source replacement count=$before"
    sed -i "$expression" "$candidate"
    after=$(grep -Fc -- "$source_anchor" "$candidate" || true)
    [[ $after == 0 ]] || fail "$name source replacement count after mutation=$after"
    after=$(grep -Fc -- "$replacement_anchor" "$candidate" || true)
    [[ $after == 1 ]] || fail "$name replacement count=$after"
    if check_candidate "$candidate"; then fail "$name checker mutation accepted"; fi
    check_semantic_reject "$name" "$candidate"
}
reject_p1_function_contract() {
    local name=$1 function_name=$2 source_anchor=$3 replacement_anchor=$4 expression=$5 candidate before after
    candidate=$root/$name.sh; cp -- "$coordinator" "$candidate"
    before=$(function_body "$function_name" "$candidate" | grep -Fc -- "$source_anchor" || true)
    [[ $before == 1 ]] || fail "$name source replacement count=$before"
    sed -i "$expression" "$candidate"
    after=$(function_body "$function_name" "$candidate" | grep -Fc -- "$source_anchor" || true)
    [[ $after == 0 ]] || fail "$name source replacement count after mutation=$after"
    after=$(function_body "$function_name" "$candidate" | grep -Fc -- "$replacement_anchor" || true)
    [[ $after == 1 ]] || fail "$name replacement count=$after"
    if check_candidate "$candidate"; then fail "$name checker mutation accepted"; fi
    check_semantic_reject "$name" "$candidate"
}
reject_p1_function_contract successor_stop_baseline_exact_set_removed \
    validate_pre_mutation_stop_state_baseline \
    '                                           "coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"]))' \
    '                                           "linux_frozen","marker_handoff","publish_receipt"]))' \
    '/^validate_pre_mutation_stop_state_baseline() {/,/^}/s/"coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"/"linux_frozen","marker_handoff","publish_receipt"/'
reject_p1_function_contract successor_reopen_exact_set_removed \
    reopen_pre_mutation_stop_intent \
    '                                               "coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"]))' \
    '                                               "linux_frozen","marker_handoff","publish_receipt"]))' \
    '/^reopen_pre_mutation_stop_intent() {/,/^}/s/"coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"/"linux_frozen","marker_handoff","publish_receipt"/'
reject_p1_exact_function_contract() {
    local name=$1 function_name=$2 source_anchor=$3 replacement_anchor=$4 expression=$5 candidate before after
    candidate=$root/$name.sh; cp -- "$coordinator" "$candidate"
    before=$(function_body "$function_name" "$candidate" | grep -Fxc -- "$source_anchor" || true)
    [[ $before == 1 ]] || fail "$name source replacement count=$before"
    sed -i "$expression" "$candidate"
    after=$(function_body "$function_name" "$candidate" | grep -Fxc -- "$source_anchor" || true)
    [[ $after == 0 ]] || fail "$name source replacement count after mutation=$after"
    after=$(function_body "$function_name" "$candidate" | grep -Fxc -- "$replacement_anchor" || true)
    [[ $after == 1 ]] || fail "$name replacement count=$after"
    if check_candidate "$candidate"; then fail "$name checker mutation accepted"; fi
    check_semantic_reject "$name" "$candidate"
}

reject_p1 frozen_validation_bypass \
    '    assert_strict_json_document '\''Linux frozen B'\'' "$bootstrap_linux_evidence"' \
    '    return 0 # P1 frozen validation bypass' \
    's|    assert_strict_json_document '\''Linux frozen B'\'' "$bootstrap_linux_evidence"|    return 0 # P1 frozen validation bypass|'
reject_p1 frozen_function_replaced_with_noop \
    '    assert_strict_json_document '\''Linux frozen B'\'' "$bootstrap_linux_evidence"' \
    'validate_frozen_linux_B() { return 0; } # P1 complete validator bypass' \
    '/^validate_frozen_linux_B() {/,/^}/c\validate_frozen_linux_B() { return 0; } # P1 complete validator bypass'
reject_p1 bootstrap_contract_bypass \
    '        validate_state_contract "$coordinator_state"' \
    '        : # validate_state_contract P1 bypass' \
    's|        validate_state_contract "$coordinator_state"|        : # validate_state_contract P1 bypass|'
reject_p1 release_receipt_bypass \
    '    validate_release_receipt_v2 "$deployment_release_receipt"' \
    '    : # validate_release_receipt_v2 P1 bypass' \
    's|    validate_release_receipt_v2 "$deployment_release_receipt"|    : # validate_release_receipt_v2 P1 bypass|'
reject_p1 restart_task_xml_hash_bypass \
    ';if((HashBytes $xmlBytes)-cne$expectedTaskSha){throw "scheduled task XML hash is invalid"}' \
    ';# if((HashBytes $xmlBytes)-cne$expectedTaskSha){throw "scheduled task XML hash is invalid"}' \
    's|;if((HashBytes \$xmlBytes)-cne\$expectedTaskSha){throw "scheduled task XML hash is invalid"}|;# if((HashBytes $xmlBytes)-cne$expectedTaskSha){throw "scheduled task XML hash is invalid"}|'
reject_p1 committed_artifact_prior_revalidation_bypass \
    '            if (all($old | to_entries[]; $committed[.key] == .value) and' \
    '            if (true and # P1 prior artifact revalidation bypass' \
    's@            if (all(\$old | to_entries\[\]; \$committed\[\.key\] == \.value) and@            if (true and # P1 prior artifact revalidation bypass@'
reject_p1 abort_marker_tuple_call_bypass \
    '    select_failed_v13_abort_marker_tuple' \
    '    : # select_failed_v13_abort_marker_tuple P1 call bypass' \
    's|^    select_failed_v13_abort_marker_tuple$|    : # select_failed_v13_abort_marker_tuple P1 call bypass|'
reject_p1_function_contract abort_slot_lineage_union_call_bypass \
    failed_v13_abort_preflight \
    '    validate_failed_v13_slot_lineage_union' \
    '    : # validate_failed_v13_slot_lineage_union P1 call bypass' \
    '/^failed_v13_abort_preflight() {/,/^}/s|^    validate_failed_v13_slot_lineage_union$|    : # validate_failed_v13_slot_lineage_union P1 call bypass|'
reject_p1_function_contract abort_original_generation_call_bypass \
    failed_v13_abort_preflight \
    '    assert_failed_v13_original_generation_only' \
    '    : # assert_failed_v13_original_generation_only P1 call bypass' \
    '/^failed_v13_abort_preflight() {/,/^}/s|^    assert_failed_v13_original_generation_only$|    : # assert_failed_v13_original_generation_only P1 call bypass|'
reject_p1 abort_slot_cleanup_hash_bypass \
    '    [[ $(sha256 "$attempt3_slot_cleanup_receipt") == "$attempt3_slot_cleanup_receipt_sha" ]] ||' \
    '    [[ 1 == 1 ]] || # P1 cleanup SHA bypass' \
    's@    \[\[ \$(sha256 "\$attempt3_slot_cleanup_receipt") == "\$attempt3_slot_cleanup_receipt_sha" \]\] ||@    [[ 1 == 1 ]] || # P1 cleanup SHA bypass@'
reject_p1 abort_slot_cleanup_state_bypass \
    '        .schema_version == 1 and .state == "viewflow-attempt3-exchange-slot-cleanup-complete" and' \
    '        .schema_version == 1 and true and # P1 cleanup state bypass' \
    's|        \.schema_version == 1 and \.state == "viewflow-attempt3-exchange-slot-cleanup-complete" and|        .schema_version == 1 and true and # P1 cleanup state bypass|'
reject_p1 abort_slot_cleanup_source_receipt_bypass \
    '        .checkout_slots_absent == true and .archived_slots_verified == true and' \
    '        .archived_slots_verified == true and # P1 source absence receipt bypass' \
    's|        \.checkout_slots_absent == true and \.archived_slots_verified == true and|        .archived_slots_verified == true and # P1 source absence receipt bypass|'
reject_p1 abort_slot_cleanup_claim_receipt_bypass \
    '        .future_sources_verified == true and .claims_preserved == true' \
    '        .future_sources_verified == true # P1 claims-preserved receipt bypass' \
    's|        \.future_sources_verified == true and \.claims_preserved == true|        .future_sources_verified == true # P1 claims-preserved receipt bypass|'
reject_p1 abort_slot_cleanup_live_source_bypass \
    '        [[ ! -e $source && ! -L $source ]] || die "attempt3 checkout exchange slot $index reappeared"' \
    '        : # P1 live source absence bypass' \
    's@        \[\[ ! -e \$source && ! -L \$source \]\] || die "attempt3 checkout exchange slot \$index reappeared"@        : # P1 live source absence bypass@'
reject_p1 abort_slot_cleanup_live_claim_bypass \
    '        [[ $destination_identity == "$claim_identity" && $destination_identity == 1000:2:* &&' \
    '        [[ $destination_identity == 1000:2:* && # P1 claim identity bypass' \
    's|        \[\[ \$destination_identity == "\$claim_identity" && \$destination_identity == 1000:2:\* &&|        [[ $destination_identity == 1000:2:* \&\& # P1 claim identity bypass|'
reject_p1 abort_slot_lineage_union_relaxed \
    '           -z $fresh_operation_lineage_receipt && -z $fresh_operation_lineage_receipt_sha &&' \
    '           true ]] || # P1 simultaneous proof branches accepted' \
    's@           -z \$fresh_operation_lineage_receipt && -z \$fresh_operation_lineage_receipt_sha &&@           true ]] || # P1 simultaneous proof branches accepted@'
reject_p1_function_contract abort_fresh_lineage_hash_bypass \
    validate_fresh_operation_lineage_gate \
    '    [[ $(sha256 "$fresh_operation_lineage_receipt") == "$fresh_operation_lineage_receipt_sha" ]] ||' \
    '    [[ 1 == 1 ]] || # P1 fresh lineage SHA bypass' \
    's@    \[\[ \$(sha256 "\$fresh_operation_lineage_receipt") == "\$fresh_operation_lineage_receipt_sha" \]\] ||@    [[ 1 == 1 ]] || # P1 fresh lineage SHA bypass@'
reject_p1_function_contract abort_fresh_validator_whole_noop \
    validate_fresh_operation_lineage_gate \
    '    [[ $(sha256 "$fresh_operation_lineage_receipt") == "$fresh_operation_lineage_receipt_sha" ]] ||' \
    'validate_fresh_operation_lineage_gate() { return 0; } # P1 whole fresh validator bypass' \
    '/^validate_fresh_operation_lineage_gate() {/,/^}/c\validate_fresh_operation_lineage_gate() { return 0; } # P1 whole fresh validator bypass'
reject_p1_function_contract abort_fresh_validator_call_noop \
    validate_failed_v13_slot_lineage_union \
    '        validate_fresh_operation_lineage_gate' \
    '        : # validate_fresh_operation_lineage_gate P1 call bypass' \
    '/^validate_failed_v13_slot_lineage_union() {/,/^}/s|^        validate_fresh_operation_lineage_gate$|        : # validate_fresh_operation_lineage_gate P1 call bypass|'
reject_p1 abort_fresh_lineage_state_bypass \
    '        .schema_version == 1 and .state == "viewflow-v4-inactive-terminal-to-fresh-v21" and' \
    '        .schema_version == 1 and true and # P1 fresh lineage state bypass' \
    's|        \.schema_version == 1 and \.state == "viewflow-v4-inactive-terminal-to-fresh-v21" and|        .schema_version == 1 and true and # P1 fresh lineage state bypass|'
reject_p1 abort_fresh_lineage_identity_bypass \
    '        .new_operation_id == $op and .new_coordinator_instance_id == $coordinator and' \
    '        .new_operation_id == $op and true and # P1 fresh coordinator binding bypass' \
    's|        \.new_operation_id == \$op and \.new_coordinator_instance_id == \$coordinator and|        .new_operation_id == $op and true and # P1 fresh coordinator binding bypass|'
reject_p1_function_contract abort_fresh_old_operation_binding_bypass \
    validate_fresh_operation_lineage_gate \
    '        .old_operation_id == $old and .old_operation_id != $op and' \
    '        (.old_operation_id | test("^[0-9a-f]{32}$")) and .old_operation_id != $op and # P1 old operation evidence binding bypass' \
    '/^validate_fresh_operation_lineage_gate() {/,/^}/s@        \.old_operation_id == \$old and \.old_operation_id != \$op and@        (.old_operation_id | test("^[0-9a-f]{32}$")) and .old_operation_id != $op and # P1 old operation evidence binding bypass@'
reject_p1_function_contract abort_fresh_predecessor_replay_equality_bypass \
    validate_fresh_operation_lineage_gate \
    '    [[ $(jq -cS '\''del(.replayed)'\'' "$old_abort") == "$(jq -cS '\''del(.replayed)'\'' "$old_query")" ]] ||' \
    '    [[ 1 == 1 ]] || # P1 predecessor abort/query replay equality bypass' \
    '/^validate_fresh_operation_lineage_gate() {/,/^}/s@^    \[\[ \$(jq -cS '\''del(\.replayed)'\'' "\$old_abort") == "\$(jq -cS '\''del(\.replayed)'\'' "\$old_query")" \]\] ||$@    [[ 1 == 1 ]] || # P1 predecessor abort/query replay equality bypass@'
reject_p1 abort_fresh_lineage_marker_bypass \
    '        .fresh_boundary.deployment_marker_sha256 == $marker and' \
    '        true and # P1 fresh marker binding bypass' \
    's|        \.fresh_boundary\.deployment_marker_sha256 == \$marker and|        true and # P1 fresh marker binding bypass|'
reject_p1 abort_fresh_committed_map_bypass \
    '        .committed_artifacts == {bootstrap_request:$request,force_envelope:$f,linux_frozen:$b,' \
    '        (.committed_artifacts | type) == "object" and # P1 fresh exact committed map bypass' \
    's@        \.committed_artifacts == {bootstrap_request:\$request,force_envelope:\$f,linux_frozen:\$b,@        (.committed_artifacts | type) == "object" and # P1 fresh exact committed map bypass@'
reject_p1 abort_fresh_candidate_path_bypass \
    '        .contract.inputs.windows_viewflow.path == ($root + "/windows-viewflowd.exe") and' \
    '        (.contract.inputs.windows_viewflow.path | startswith("/")) and # P1 fresh candidate path bypass' \
    's@        \.contract\.inputs\.windows_viewflow\.path == (\$root + "/windows-viewflowd.exe") and@        (.contract.inputs.windows_viewflow.path | startswith("/")) and # P1 fresh candidate path bypass@'
reject_p1 abort_fresh_exchange_input_bypass \
    '            startswith("/") and (contains(".attempt3.exchange-slot") | not)) and' \
    '            startswith("/")) and # P1 fresh exchange input bypass' \
    's@            startswith("/") and (contains("\.attempt3\.exchange-slot") | not)) and@            startswith("/")) and # P1 fresh exchange input bypass@'
reject_p1 abort_fresh_live_slot_bypass \
    '        [[ ! -e $source && ! -L $source ]] || die "fresh operation unexpectedly owns an attempt3 exchange slot: $slot_stem"' \
    '        : # P1 fresh live slot absence bypass' \
    's@        \[\[ ! -e \$source && ! -L \$source \]\] || die "fresh operation unexpectedly owns an attempt3 exchange slot: \$slot_stem"@        : # P1 fresh live slot absence bypass@'
reject_p1_function_contract abort_schema1_handoff_hash_bypass \
    validate_schema1_handoff_lineage_gate \
    '    [[ $(sha256 "$schema1_handoff_lineage_receipt") == "$schema1_handoff_lineage_receipt_sha" ]] ||' \
    '    [[ 1 == 1 ]] || # P1 schema1-handoff SHA bypass' \
    's@    \[\[ \$(sha256 "\$schema1_handoff_lineage_receipt") == "\$schema1_handoff_lineage_receipt_sha" \]\] ||@    [[ 1 == 1 ]] || # P1 schema1-handoff SHA bypass@'
reject_p1_function_contract abort_schema1_handoff_validator_noop \
    validate_schema1_handoff_lineage_gate \
    '    [[ $(sha256 "$schema1_handoff_lineage_receipt") == "$schema1_handoff_lineage_receipt_sha" ]] ||' \
    'validate_schema1_handoff_lineage_gate() { return 0; } # P1 whole schema1-handoff bypass' \
    '/^validate_schema1_handoff_lineage_gate() {/,/^}/c\validate_schema1_handoff_lineage_gate() { return 0; } # P1 whole schema1-handoff bypass'
reject_p1_function_contract abort_schema1_handoff_call_noop \
    validate_failed_v13_slot_lineage_union \
    '        validate_schema1_handoff_lineage_gate' \
    '        : # P1 schema1-handoff call bypass' \
    '/^validate_failed_v13_slot_lineage_union() {/,/^}/s|^        validate_schema1_handoff_lineage_gate$|        : # P1 schema1-handoff call bypass|'
reject_p1_function_contract abort_schema1_handoff_failure_phase_bypass \
    validate_schema1_handoff_lineage_gate \
    '        .recovery == {failure_phase:"MUTATION_PERMITTED",mutation_possible:true} and' \
    '        .recovery.mutation_possible == true and # P1 failure phase bypass' \
    '/^validate_schema1_handoff_lineage_gate() {/,/^}/s|        \.recovery == {failure_phase:"MUTATION_PERMITTED",mutation_possible:true} and|        .recovery.mutation_possible == true and # P1 failure phase bypass|'
reject_p1 abort_schema5_force_truth_bypass \
    '        .mutation_permit_published == true and .force_release_executed == false and .rollback_performed == true and' \
    '        .mutation_permit_published == true and true and .rollback_performed == true and # P1 force truth bypass' \
    's|        \.mutation_permit_published == true and \.force_release_executed == false and \.rollback_performed == true and|        .mutation_permit_published == true and true and .rollback_performed == true and # P1 force truth bypass|'
reject_p1 abort_schema5_candidate_dispatch_bypass \
    '        marker_executable=$schema1_handoff_abort_marker_cli_candidate' \
    '        marker_executable=$MARKER_CLI # P1 new schema executed by old installed marker' \
    's|        marker_executable=\$schema1_handoff_abort_marker_cli_candidate|        marker_executable=$MARKER_CLI # P1 new schema executed by old installed marker|'
reject_p1_function_contract abort_schema7_authorization_truth_bypass \
    make_and_validate_post_force_rollback_abort_authorization \
    '        .force_release_executed == true and .rollback_performed == true and .linux_stage_committed == false and' \
    '        true and .rollback_performed == true and .linux_stage_committed == false and # P1 post-force truth bypass' \
    '/^make_and_validate_post_force_rollback_abort_authorization() {/,/^}/s|^        \.force_release_executed == true and \.rollback_performed == true and \.linux_stage_committed == false and$|        true and .rollback_performed == true and .linux_stage_committed == false and # P1 post-force truth bypass|'
reject_p1_function_contract abort_schema7_receipt_truth_bypass \
    validate_abort_receipt_v7 \
    '        .force_release_executed == true and .rollback_performed == true and .linux_stage_committed == false and' \
    '        true and .rollback_performed == true and .linux_stage_committed == false and # P1 receipt truth bypass' \
    '/^validate_abort_receipt_v7() {/,/^}/s|^        \.force_release_executed == true and \.rollback_performed == true and \.linux_stage_committed == false and$|        true and .rollback_performed == true and .linux_stage_committed == false and # P1 receipt truth bypass|'
reject_p1_function_contract abort_schema7_failure_phase_bypass \
    validate_failed_v13_terminal_state \
    '            .phase == "WINDOWS_ROLLED_BACK" and .recovery == {failure_phase:"WINDOWS_FORCE_ATTESTED",mutation_possible:true} and' \
    '            .phase == "WINDOWS_ROLLED_BACK" and .recovery.mutation_possible == true and # P1 post-force phase bypass' \
    '/^validate_failed_v13_terminal_state() {/,/^}/s|^            \.phase == "WINDOWS_ROLLED_BACK" and \.recovery == {failure_phase:"WINDOWS_FORCE_ATTESTED",mutation_possible:true} and$|            .phase == "WINDOWS_ROLLED_BACK" and .recovery.mutation_possible == true and # P1 post-force phase bypass|'
reject_p1 abort_schema7_candidate_dispatch_bypass \
    '        marker_executable=$post_force_abort_marker_cli_candidate' \
    '        marker_executable=$MARKER_CLI # P1 schema7 executed by old installed marker' \
    's|        marker_executable=\$post_force_abort_marker_cli_candidate|        marker_executable=$MARKER_CLI # P1 schema7 executed by old installed marker|'
reject_p1 abort_schema7_receipt_validator_bypass \
    '        validate_abort_receipt_v7 "$deployment_abort_receipt"' \
    '        : # P1 schema7 receipt validator bypass' \
    's|        validate_abort_receipt_v7 "\$deployment_abort_receipt"|        : # P1 schema7 receipt validator bypass|'
reject_p1 abort_original_generation_equality_bypass \
    '    [[ $abort_marker_operation_id == "$operation_id" && $abort_marker_generation == "$marker_generation" &&' \
    '    [[ $abort_marker_operation_id == "$operation_id" && true && # P1 original generation bypass' \
    's|    \[\[ \$abort_marker_operation_id == "\$operation_id" && \$abort_marker_generation == "\$marker_generation" &&|    [[ $abort_marker_operation_id == "$operation_id" \&\& true \&\& # P1 original generation bypass|'
reject_p1 abort_release_sentinel_bypass \
    '    [[ ! -e $deployment_release_receipt && ! -L $deployment_release_receipt &&' \
    '    [[ true && # P1 release sentinel bypass' \
    's|    \[\[ ! -e \$deployment_release_receipt && ! -L \$deployment_release_receipt &&|    [[ true \&\& # P1 release sentinel bypass|'
reject_p1 abort_recovery_publish_sentinel_bypass \
    '       ! -e $recovery_deployment_publish_receipt && ! -L $recovery_deployment_publish_receipt ]] ||' \
    '       true ]] || # P1 recovery-publish sentinel bypass' \
    's@       ! -e \$recovery_deployment_publish_receipt && ! -L \$recovery_deployment_publish_receipt \]\] ||@       true ]] || # P1 recovery-publish sentinel bypass@'
reject_p1_function_contract abort_terminal_validation_call_bypass \
    failed_v13_abort_preflight \
    '    validate_failed_v13_terminal_state' \
    '    : # validate_failed_v13_terminal_state P1 call bypass' \
    '/^failed_v13_abort_preflight() {/,/^}/s|^    validate_failed_v13_terminal_state$|    : # validate_failed_v13_terminal_state P1 call bypass|'
reject_p1_function_contract abort_request_path_derivation_bypass \
    failed_v13_abort_preflight \
    '    state_request=$(jq -er '\''.contract.outputs.request | select(type == "string" and startswith("/"))'\'' "$coordinator_state")' \
    '    state_request=$windows_bootstrap_request # P1 immutable-state derivation bypass' \
    '/^failed_v13_abort_preflight() {/,/^}/s|^    state_request=.*$|    state_request=$windows_bootstrap_request # P1 immutable-state derivation bypass|'
reject_p1_function_contract abort_stop_path_derivation_bypass \
    failed_v13_abort_preflight \
    '    state_stop=$(jq -er '\''.contract.outputs.windows_stop_evidence | select(type == "string" and startswith("/"))'\'' "$coordinator_state")' \
    '    state_stop=$local_windows_stop_evidence # P1 immutable-state derivation bypass' \
    '/^failed_v13_abort_preflight() {/,/^}/s|^    state_stop=.*$|    state_stop=$local_windows_stop_evidence # P1 immutable-state derivation bypass|'
reject_p1_exact_function_contract abort_request_path_binding_bypass \
    validate_failed_v13_terminal_state \
    '        .contract.inputs.linux_frozen.path == $frozen and .contract.outputs.request == $request and' \
    '        .contract.inputs.linux_frozen.path == $frozen and true and # P1 request path binding bypass' \
    '/^validate_failed_v13_terminal_state() {/,/^}/s|^        \.contract\.inputs\.linux_frozen\.path == \$frozen and \.contract\.outputs\.request == \$request and$|        .contract.inputs.linux_frozen.path == $frozen and true and # P1 request path binding bypass|'
reject_p1 abort_request_hash_binding_bypass \
    '        .committed_artifacts.bootstrap_request == $request and' \
    '        true and # P1 request hash binding bypass' \
    's|        \.committed_artifacts\.bootstrap_request == \$request and|        true and # P1 request hash binding bypass|'
reject_p1 abort_live_wrapper_hash_bypass \
    "if((HB ([IO.File]::ReadAllBytes('C:\\\\Users\\\\wilf\\\\AppData\\\\Local\\\\Programs\\\\Viewflow\\\\viewflow-client.ps1')))-cne'\$wrapper'){throw 'old wrapper hash differs'}" \
    "if(\$false){throw 'old wrapper hash differs'} # P1 live wrapper hash bypass" \
    "/old wrapper hash differs/s@if((HB .*){throw 'old wrapper hash differs'}@if(\$false){throw 'old wrapper hash differs'} # P1 live wrapper hash bypass@"
reject_p1_function_contract abort_last_windows_snapshot_bypass \
    abort_deployment_marker_transactionally \
    '    start_and_freeze_windows_v13' \
    '    : # start_and_freeze_windows_v13 P1 last-live-snapshot bypass' \
    '/^abort_deployment_marker_transactionally() {/,/^}/s|^    start_and_freeze_windows_v13$|    : # start_and_freeze_windows_v13 P1 last-live-snapshot bypass|'
reject_p1 fd_gate_nofollow_bypass \
    'fd=os.open(target,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)' \
    'fd=os.open(target,os.O_RDONLY|os.O_CLOEXEC) # P1 O_NOFOLLOW bypass' \
    's@fd=os.open(target,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)@fd=os.open(target,os.O_RDONLY|os.O_CLOEXEC) # P1 O_NOFOLLOW bypass@'
reject_p1 fd_gate_path_exec_bypass \
    'os.execve(f"/proc/self/fd/{exec_fd}",[target,*target_argv],clean_env)' \
    'os.execve(target,[target,*target_argv],clean_env) # P1 mutable path exec' \
    's|os.execve(f"/proc/self/fd/{exec_fd}",\[target,\*target_argv\],clean_env)|os.execve(target,[target,*target_argv],clean_env) # P1 mutable path exec|'
reject_p1 fd_gate_generic_inherited_environment \
    'if role=="deskflow":' \
    'clean_env.update(os.environ) # P1 inherited generic gate environment' \
    's|^if role=="deskflow":$|clean_env.update(os.environ) # P1 inherited generic gate environment\nif (role=="deskflow"):\n    pass|'
reject_p1 fd_gate_deskflow_inherited_environment \
    'argv=[bwrap,"--bind","/","/","--tmpfs","/tmp"' \
    'clean_env.update(os.environ) # P1 inherited Deskflow gate environment' \
    's|^argv=\[bwrap,"--bind","/","/","--tmpfs","/tmp"|clean_env.update(os.environ) # P1 inherited Deskflow gate environment\nargv=list([bwrap,"--bind","/","/","--tmpfs","/tmp"|'
reject_p1_function_contract fd_gate_dirty_python_startup \
    run_pinned_executable \
    '    "$FD_GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \' \
    '    "$FD_GATE_PYTHON" \ # P1 inherited dynamic-loader environment' \
    '/^run_pinned_executable() {/,/^}/s|    "$FD_GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \\|    "$FD_GATE_PYTHON" \\ # P1 inherited dynamic-loader environment|'
reject_p1 fd_gate_unsealable_memfd \
    'exec_fd=os.memfd_create("viewflow-verified-elf",os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)' \
    'exec_fd=os.memfd_create("viewflow-verified-elf",os.MFD_CLOEXEC) # P0 unsealable memfd' \
    's@exec_fd=os.memfd_create("viewflow-verified-elf",os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)@exec_fd=os.memfd_create("viewflow-verified-elf",os.MFD_CLOEXEC) # P0 unsealable memfd@'
reject_p1 fd_gate_write_seal_removed \
    'required_seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL' \
    'required_seals=fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL # P0 writable memfd' \
    's@required_seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL@required_seals=fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL # P0 writable memfd@'
reject_p1 fd_gate_seal_readback_bypass \
    'if fcntl.fcntl(exec_fd,fcntl.F_GET_SEALS)!=required_seals:' \
    'if False: # P0 seal readback bypass' \
    's@if fcntl.fcntl(exec_fd,fcntl.F_GET_SEALS)!=required_seals:@if False: # P0 seal readback bypass@'
reject transient_ld_preload_clear_bypass '0,/--setenv=LD_PRELOAD= --setenv=LD_AUDIT= --setenv=LD_LIBRARY_PATH=/s//--setenv=LD_AUDIT= --setenv=LD_LIBRARY_PATH=/'
reject_p1_function_contract exec_start_observed_argv_bypass \
    observed_transient_exec_start_sha \
    '        {argv:$value[1],ignore_errors:$value[2],path:$value[0]}' \
    '        {argv:[],ignore_errors:$value[2],path:$value[0]} # P1 observed argv bypass' \
    '/^observed_transient_exec_start_sha() {/,/^}/s|        {argv:\$value\[1\],ignore_errors:\$value\[2\],path:\$value\[0\]}|        {argv:[],ignore_errors:$value[2],path:$value[0]} # P1 observed argv bypass|'
reject_p1_function_contract exec_start_launch_equality_bypass \
    start_pinned_v13_transient_unit \
    '    [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' \
    '    [[ 1 == 1 ]] || # P1 manager ExecStart equality bypass' \
    '/^start_pinned_v13_transient_unit() {/,/^}/s@    \[\[ \$observed_exec_start_sha == "\$expected_exec_start_sha" \]\] ||@    [[ 1 == 1 ]] || # P1 manager ExecStart equality bypass@'
reject_p1_function_contract exec_start_validator_equality_bypass \
    validate_linux_v13_started \
    '    [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' \
    '    [[ 1 == 1 ]] || # P1 validator ExecStart equality bypass' \
    '/^validate_linux_v13_started() {/,/^}/s@    \[\[ \$observed_exec_start_sha == "\$expected_exec_start_sha" \]\] ||@    [[ 1 == 1 ]] || # P1 validator ExecStart equality bypass@'
reject_p1_function_contract receipt_validator_adoption_boundary_bypass \
    validate_linux_v13_started \
    '    assert_adoptable_linux_v13_without_receipt' \
    '    : # P1 existing receipt skips exact single-runtime adoption boundary' \
    '/^validate_linux_v13_started() {/,/^}/s@    assert_adoptable_linux_v13_without_receipt@    : # P1 existing receipt skips exact single-runtime adoption boundary@'
reject_p1_function_contract windows_v13_task_xml_encoding_bypass \
    start_and_freeze_windows_v13 \
    '\$enc=New-Object Text.UnicodeEncoding(\$false,\$true)' \
    '\$enc=New-Object Text.UTF8Encoding(\$false) # P1 task XML hash encoding mismatch' \
    '/^start_and_freeze_windows_v13() {/,/^}/s@\\\$enc=New-Object Text.UnicodeEncoding(\\\$false,\\\$true)@\\$enc=New-Object Text.UTF8Encoding(\\$false) # P1 task XML hash encoding mismatch@'
reject_p1 windows_auth_source_ip_confusion \
    'readonly EXPECTED_WINDOWS_SOURCE_IP=172.16.105.70' \
    'readonly EXPECTED_WINDOWS_SOURCE_IP=172.16.105.62 # P1 Linux target confused with Windows source' \
    's@readonly EXPECTED_WINDOWS_SOURCE_IP=172.16.105.70@readonly EXPECTED_WINDOWS_SOURCE_IP=172.16.105.62 # P1 Linux target confused with Windows source@'
reject_p1_function_contract windows_fresh_probe_bypass \
    freeze_authenticated_v13_peer \
    '        [[ -n $fresh_probe && $fresh_probe != "$baseline_probe" ]] && break' \
    '        [[ -n $fresh_probe ]] && break # P1 pre-boundary probe replay' \
    '/^freeze_authenticated_v13_peer() {/,/^}/s@        \[\[ -n \$fresh_probe && \$fresh_probe != "\$baseline_probe" \]\] && break@        [[ -n $fresh_probe ]] \&\& break # P1 pre-boundary probe replay@'
reject_p1_function_contract windows_auth_receipt_resume_republish \
    freeze_authenticated_v13_peer \
    '    if [[ -e $authenticated_v13_peer_receipt || -L $authenticated_v13_peer_receipt ]]; then' \
    '    if false; then # P1 resume regenerates a different immutable probe receipt' \
    '/^freeze_authenticated_v13_peer() {/,/^}/s@    if \[\[ -e \$authenticated_v13_peer_receipt || -L \$authenticated_v13_peer_receipt \]\]; then@    if false; then # P1 resume regenerates a different immutable probe receipt@'
reject_p1_function_contract windows_live_reattest_bypass \
    validate_windows_v13_started \
    '    capture_json_command '\''Windows v1.3 live reattestation'\'' "$live" ssh_windows "$command"' \
    '    : # P1 existing Windows receipt skips live SSH reattestation' \
    '/^validate_windows_v13_started() {/,/^}/s@    capture_json_command '\''Windows v1.3 live reattestation'\'' "\$live" ssh_windows "\$command"@    : # P1 existing Windows receipt skips live SSH reattestation@'
reject_p1_function_contract windows_live_reattest_path_reuse \
    validate_windows_v13_started \
    '    live=$secure_dir/windows-v13-live.${windows_v13_live_reattest_counter}.json' \
    '    live=$secure_dir/windows-v13-live.json # P1 same-run reattestation output reused' \
    '/^validate_windows_v13_started() {/,/^}/s@    live=\$secure_dir/windows-v13-live\.\${windows_v13_live_reattest_counter}\.json@    live=$secure_dir/windows-v13-live.json # P1 same-run reattestation output reused@'
reject_p1_function_contract windows_receipt_resume_republish \
    start_and_freeze_windows_v13 \
    '    if [[ -e $windows_v13_started_receipt || -L $windows_v13_started_receipt ]]; then' \
    '    if false; then # P1 same-run Windows receipt candidate is republished' \
    '/^start_and_freeze_windows_v13() {/,/^}/s@    if \[\[ -e \$windows_v13_started_receipt || -L \$windows_v13_started_receipt \]\]; then@    if false; then # P1 same-run Windows receipt candidate is republished@'
reject_p1 exec_start_receipt_equality_bypass \
    '        .exec_start_sha256 == $observed_exec_start and .exec_start_sha256 == .expected_exec_start_sha256 and' \
    '        .exec_start_sha256 == $observed_exec_start and true and # P1 receipt expected equality bypass' \
    's|        \.exec_start_sha256 == \$observed_exec_start and \.exec_start_sha256 == \.expected_exec_start_sha256 and|        .exec_start_sha256 == $observed_exec_start and true and # P1 receipt expected equality bypass|'
reject_p1_function_contract exec_start_deskflow_equality_bypass \
    failed_v13_abort_main \
    '       $deskflow_observed_exec_start_sha == "$deskflow_expected_exec_start_sha" ]] ||' \
    '       true ]] || # P1 Deskflow manager ExecStart equality bypass' \
    '/^failed_v13_abort_main() {/,/^}/s@       \$deskflow_observed_exec_start_sha == "\$deskflow_expected_exec_start_sha" \]\] ||@       true ]] || # P1 Deskflow manager ExecStart equality bypass@'
reject_p1_function_contract premutation_exec_start_deskflow_equality_bypass \
    publish_pre_mutation_abort_terminal \
    '       $deskflow_observed_exec_start_sha == "$deskflow_expected_exec_start_sha" ]] ||' \
    '       true ]] || # P1 pre-mutation Deskflow manager ExecStart equality bypass' \
    '/^publish_pre_mutation_abort_terminal() {/,/^}/s@       \$deskflow_observed_exec_start_sha == "\$deskflow_expected_exec_start_sha" \]\] ||@       true ]] || # P1 pre-mutation Deskflow manager ExecStart equality bypass@'

# Expected ExecStart must be frozen before either transient launch. Moving the
# sole assignment below the branch must fail both static and semantic ordering.
exec_order_candidate=$root/exec_start_expected_after_launch.sh
cp -- "$coordinator" "$exec_order_candidate"
[[ $(grep -Fc -- '    expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")' "$exec_order_candidate" || true) == 1 ]] || fail 'ExecStart order source anchor is not unique'
sed -i 's|    expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")|    : # P1 expected ExecStart moved after launch|' "$exec_order_candidate"
sed -i '/    observed_exec_start_sha=$(observed_transient_exec_start_sha "$unit")/i\    expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")' "$exec_order_candidate"
[[ $(grep -Fc -- '    expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")' "$exec_order_candidate" || true) == 1 ]] || fail 'ExecStart order replacement count differs'
if check_candidate "$exec_order_candidate"; then fail 'exec_start_expected_after_launch checker mutation accepted'; fi
check_semantic_reject exec_start_expected_after_launch "$exec_order_candidate"
reject_p1_function_contract marker_abort_fd_gate_bypass \
    abort_deployment_marker_transactionally \
    '            "$marker_role" "$marker_executable" "$marker_executable_sha" abort \' \
    '            "$marker_executable" abort \ # P1 mutable marker path' \
    '/^abort_deployment_marker_transactionally() {/,/^}/s|            "$marker_role" "$marker_executable" "$marker_executable_sha" abort \\|            "$marker_executable" abort \\ # P1 mutable marker path|'
reject_p1_function_contract transient_preoccupied_bypass \
    start_pinned_v13_transient_unit \
    '    [[ -z $load_state || $load_state == not-found ]] || die "transient recovery unit is preoccupied: $unit"' \
    '    : # P1 preoccupied transient-unit bypass' \
    '/^start_pinned_v13_transient_unit() {/,/^}/s@    \[\[ -z \$load_state || \$load_state == not-found \]\] || die "transient recovery unit is preoccupied: \$unit"@    : # P1 preoccupied transient-unit bypass@'
reject_p1_function_contract transient_adoption_exec_start_bypass \
    start_and_freeze_linux_v13 \
    '        [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' \
    '        [[ 1 == 1 ]] || # P1 inherited transient ExecStart bypass' \
    '/^start_and_freeze_linux_v13() {/,/^}/s@        \[\[ \$observed_exec_start_sha == "\$expected_exec_start_sha" \]\] ||@        [[ 1 == 1 ]] || # P1 inherited transient ExecStart bypass@'
reject_p1_function_contract transient_gate_exec_wait_bypass \
    start_and_freeze_linux_v13 \
    '           [[ $process_sha == "$old_viewflow_sha" ]]; then' \
    '           [[ $pid =~ ^[1-9][0-9]*$ ]]; then # P1 gate PID accepted before target exec' \
    '/^start_and_freeze_linux_v13() {/,/^}/s@           \[\[ \$process_sha == "\$old_viewflow_sha" \]\]; then@           [[ $pid =~ ^[1-9][0-9]*$ ]]; then # P1 gate PID accepted before target exec@'
reject_p1_function_contract receiptless_transient_adoption_bypass \
    assert_adoptable_linux_v13_without_receipt \
    '       $observed_exec_start_sha == "$expected_exec_start_sha" &&' \
    '       true && # P1 receipt-less transient ExecStart bypass' \
    '/^assert_adoptable_linux_v13_without_receipt() {/,/^}/s@       \$observed_exec_start_sha == "\$expected_exec_start_sha" &&@       true \&\& # P1 receipt-less transient ExecStart bypass@'
reject transient_type_exec_bypass '0,/--property Type=exec --property KillMode=control-group/s//--property Type=simple --property KillMode=control-group/'
reject transient_kill_mode_bypass '0,/--property Type=exec --property KillMode=control-group/s//--property Type=exec --property KillMode=process/'
reject_p1_function_contract viewflow_transient_bypass \
    start_and_freeze_linux_v13 \
    '        start_pinned_v13_transient_unit viewflow "$v13_viewflow_unit" "$VIEWFLOW_INSTALLED" "$old_viewflow_sha" \' \
    '        systemctl --user start "$VIEWFLOW_UNIT" # P1 mutable persistent-unit start' \
    '/^start_and_freeze_linux_v13() {/,/^}/s|        start_pinned_v13_transient_unit viewflow "$v13_viewflow_unit" "$VIEWFLOW_INSTALLED" "$old_viewflow_sha" \\|        systemctl --user start "$VIEWFLOW_UNIT" # P1 mutable persistent-unit start|'
reject_p1_function_contract deskflow_transient_bypass \
    failed_v13_abort_main \
    '    start_pinned_v13_transient_unit deskflow "$v13_deskflow_unit" "$DESKFLOW_INSTALLED" "$old_deskflow_sha"' \
    '    systemctl --user start "$DESKFLOW_UNIT" # P1 mutable persistent-unit start' \
    '/^failed_v13_abort_main() {/,/^}/s|    start_pinned_v13_transient_unit deskflow "$v13_deskflow_unit" "$DESKFLOW_INSTALLED" "$old_deskflow_sha"|    systemctl --user start "$DESKFLOW_UNIT" # P1 mutable persistent-unit start|'
reject_p1_function_contract deskflow_final_revalidation_bypass \
    failed_v13_abort_main \
    '    validate_live_deskflow_recovery_tuple "$v13_deskflow_unit" "$bwrap_pid" "$bwrap_ticks" \' \
    '    true \' \
    '/^failed_v13_abort_main() {/,/^}/s|^    validate_live_deskflow_recovery_tuple "$v13_deskflow_unit" "$bwrap_pid" "$bwrap_ticks" \\$|    true \\|'
reject_p1_function_contract deskflow_core_cgroup_bypass \
    failed_v13_abort_main \
    '       $deskflow_cgroup == "$deskflow_process_cgroup" && $deskflow_cgroup == "$core_cgroup" &&' \
    '       true && $deskflow_cgroup == */"${v13_deskflow_unit}" && # P1 core cgroup bypass' \
    '/^failed_v13_abort_main() {/,/^}/s|       \$deskflow_cgroup == "\$deskflow_process_cgroup" && \$deskflow_cgroup == "\$core_cgroup" &&|       true \&\& $deskflow_cgroup == */"${v13_deskflow_unit}" \&\& # P1 core cgroup bypass|'
reject_p1_function_contract premutation_deskflow_core_cgroup_bypass \
    publish_pre_mutation_abort_terminal \
    '       $deskflow_cgroup == "$deskflow_process_cgroup" && $deskflow_cgroup == "$core_cgroup" &&' \
    '       true && $deskflow_cgroup == */"${v13_deskflow_unit}" && # P1 pre-mutation core cgroup bypass' \
    '/^publish_pre_mutation_abort_terminal() {/,/^}/s|       \$deskflow_cgroup == "\$deskflow_process_cgroup" && \$deskflow_cgroup == "\$core_cgroup" &&|       true \&\& $deskflow_cgroup == */"${v13_deskflow_unit}" \&\& # P1 pre-mutation core cgroup bypass|'
reject_p1 deskflow_gui_descendant_bypass \
    '    process_descends_from "$deskflow_pid" "$bwrap_pid" || die '\''Deskflow GUI is not descended from the pinned Bubblewrap MainPID'\''' \
    '    : # P1 Deskflow GUI descendant bypass' \
    's@    process_descends_from "$deskflow_pid" "$bwrap_pid" || die '\''Deskflow GUI is not descended from the pinned Bubblewrap MainPID'\''@    : # P1 Deskflow GUI descendant bypass@'
reject_p1 deskflow_core_descendant_bypass \
    '    process_descends_from "$core_pid" "$deskflow_pid" || die '\''deskflow-core is not descended from the pinned Deskflow GUI'\''' \
    '    : # P1 deskflow-core descendant bypass' \
    's@    process_descends_from "$core_pid" "$deskflow_pid" || die '\''deskflow-core is not descended from the pinned Deskflow GUI'\''@    : # P1 deskflow-core descendant bypass@'

# Reproduce the reported wholesale replacement exactly.  The current checker
# and independent semantic test must both reject losing the explicit
# append-only merge, even though commit-time guards also reject missing or
# changed prior artifacts.
wholesale_candidate=$root/committed_artifact_wholesale_replace.sh
cp -- "$coordinator" "$wholesale_candidate"
wholesale_merge='                .committed_artifacts = reduce ($committed | to_entries[]) as $item'
wholesale_tail='                    ($old; if has($item.key) then . else .[$item.key] = $item.value end) |'
[[ $(grep -Fc -- "$wholesale_merge" "$wholesale_candidate" || true) == 1 ]] || fail 'wholesale replacement merge anchor is not unique'
[[ $(grep -Fc -- "$wholesale_tail" "$wholesale_candidate" || true) == 1 ]] || fail 'wholesale replacement tail anchor is not unique'
sed -i '/^                    (\$old; if has(\$item.key) then \. else \.\[\$item.key\] = \$item.value end) |$/d' "$wholesale_candidate"
sed -i 's@^                \.committed_artifacts = reduce (\$committed | to_entries\[\]) as \$item$@                .committed_artifacts = $committed |@' "$wholesale_candidate"
[[ $(grep -Fc -- '                .committed_artifacts = $committed |' "$wholesale_candidate" || true) == 1 ]] || fail 'wholesale replacement mutation was not applied exactly once'
if check_candidate "$wholesale_candidate"; then fail 'committed_artifact_wholesale_replace checker mutation accepted'; fi
check_semantic_reject committed_artifact_wholesale_replace "$wholesale_candidate"

# The permit intent must be durable before the remote write. Replace the one
# original intent with a unique placeholder, then append one moved intent.
permit_candidate=$root/permit_intent_moved_after_upload.sh; cp -- "$coordinator" "$permit_candidate"
permit_before=$(grep -Fc '    commit_phase WINDOWS_PERMIT_PUBLISH_INTENT' "$permit_candidate" || true)
[[ $permit_before == 1 ]] || fail "permit_intent_moved_after_upload source replacement count=$permit_before"
sed -i 's|    commit_phase WINDOWS_PERMIT_PUBLISH_INTENT|    : # P1 moved permit intent|' "$permit_candidate"
sed -i '/    windows_create_or_verify "$windows_mutation_permit" "$windows_permit_path"/a\    commit_phase WINDOWS_PERMIT_PUBLISH_INTENT' "$permit_candidate"
permit_after=$(grep -Fc '    commit_phase WINDOWS_PERMIT_PUBLISH_INTENT' "$permit_candidate" || true)
[[ $permit_after == 1 ]] || fail "permit_intent_moved_after_upload replacement count=$permit_after"
grep -Fq '    : # P1 moved permit intent' "$permit_candidate" || fail 'permit_intent_moved_after_upload replacement marker missing'
if check_candidate "$permit_candidate"; then fail 'permit_intent_moved_after_upload checker mutation accepted'; fi
check_semantic_reject permit_intent_moved_after_upload "$permit_candidate"

# Frozen phase-aware P0 contracts.  Keep these mutations narrow and counted so
# a future coordinator reshuffle cannot silently turn a no-op substitution into
# passing test coverage.
reject_contract() {
    local name=$1 source_anchor=$2 replacement_anchor=$3 expression=$4 candidate before after
    candidate=$root/$name.sh; cp -- "$coordinator" "$candidate"
    before=$(grep -Fc -- "$source_anchor" "$candidate" || true)
    [[ $before == 1 ]] || fail "$name source replacement count=$before"
    sed -i "$expression" "$candidate"
    after=$(grep -Fc -- "$source_anchor" "$candidate" || true)
    [[ $after == 0 ]] || fail "$name source replacement count after mutation=$after"
    after=$(grep -Fc -- "$replacement_anchor" "$candidate" || true)
    [[ $after == 1 ]] || fail "$name replacement count=$after"
    if check_candidate "$candidate"; then fail "$name checker mutation accepted"; fi
    check_semantic_reject "$name" "$candidate"
}

reject_contract append_only_overlap_equality \
    '$old[$item.key] == $item.value' \
    'true # P0 overlap bypass' \
    's|\$old\[\$item.key\] == \$item.value|true # P0 overlap bypass|'
reject_contract stage_receipt_first_adoption \
    '    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_STAGED) && -e $linux_stage_receipt ]]; then' \
    '    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_STAGED) && -e $windows_mutation_permit ]]; then' \
    '/LINUX_STAGED.*linux_stage_receipt/s/\$linux_stage_receipt/\$windows_mutation_permit/'
reject_contract finalize_receipt_first_adoption \
    '    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_FINALIZED_MARKER_HELD) && -e $linux_finalize_receipt ]]; then' \
    '    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_FINALIZED_MARKER_HELD) && -e $windows_mutation_permit ]]; then' \
    '/LINUX_FINALIZED_MARKER_HELD.*linux_finalize_receipt/s/\$linux_finalize_receipt/\$windows_mutation_permit/'
reject_contract partial_recovery_proof_rejected \
    '            elif ((proof_count != 2)); then' \
    '            elif ((proof_count == 1)); then' \
    's|            elif ((proof_count != 2)); then|            elif ((proof_count == 1)); then|'
reject_contract recovery_marker_active_adoption \
    '            if [[ ! -e $recovery_deployment_publish_receipt ]]; then adopt_active_recovery_marker "$current_sha"; fi' \
    '            if [[ ! -e $recovery_deployment_publish_receipt ]]; then :; fi' \
    's|            if \[\[ ! -e \$recovery_deployment_publish_receipt \]\]; then adopt_active_recovery_marker "\$current_sha"; fi|            if [[ ! -e $recovery_deployment_publish_receipt ]]; then :; fi|'
reject_contract restart_claim_fail_closed \
    '    windows_remote_exists "$windows_restart_claim_path" && die '\''uncertain: Windows restart claim exists without terminal receipt'\''' \
    '    : # P0 restart claim bypass' \
    's|    windows_remote_exists "\$windows_restart_claim_path" && die '\''uncertain: Windows restart claim exists without terminal receipt'\''|    : # P0 restart claim bypass|'
reject_contract early_exit_wait_self_recurses \
    '        if [[ $remote != "$windows_exit_path" ]] && windows_remote_exists "$windows_exit_path"; then' \
    '        if windows_remote_exists "$windows_exit_path"; then # P0 terminal self-wait recursion' \
    's|        if \[\[ \$remote != "\$windows_exit_path" \]\] && windows_remote_exists "\$windows_exit_path"; then|        if windows_remote_exists "$windows_exit_path"; then # P0 terminal self-wait recursion|'
reject_contract early_exit_receipt_not_synced \
    "            sync_remote_receipt 'Windows installer early exit'" \
    '            : # P0 early terminal sync bypass' \
    "s|            sync_remote_receipt 'Windows installer early exit'|            : # P0 early terminal sync bypass|"
reject_contract early_exit_receipt_not_validated \
    '            validate_windows_terminal_exit' \
    '            : # P0 early terminal validation bypass' \
    's|            validate_windows_terminal_exit|            : # P0 early terminal validation bypass|'
reject_static_function_contract rollback_terminal_first \
    run_windows_rollback \
    '    if windows_remote_exists "$windows_rollback_receipt_path"; then' \
    '    if false; then # P0 terminal query bypass' \
    's|    if windows_remote_exists "\$windows_rollback_receipt_path"; then|    if false; then # P0 terminal query bypass|'
reject_contract prepared_authorization_hashes \
    '    [[ $remote_manifest_sha == "$authorized_manifest" && $remote_token_sha == "$authorized_token" ]] ||' \
    '    [[ 1 == 1 ]] || # P0 prepared authorization bypass' \
    's@    \[\[ \$remote_manifest_sha == "\$authorized_manifest" && \$remote_token_sha == "\$authorized_token" \]\] ||@    [[ 1 == 1 ]] || # P0 prepared authorization bypass@'
reject_contract runtime_marker_mapping \
    '    runtime_recovery_state=retained' \
    '    runtime_recovery_state=unknown # P0 retained mapping bypass' \
    's|    runtime_recovery_state=retained|    runtime_recovery_state=unknown # P0 retained mapping bypass|'
reject_contract bootstrap_unknown_helper \
    '        validate_state_contract "$coordinator_state"' \
    '    validate_unknown_bootstrap_call' \
    's|        validate_state_contract "$coordinator_state"|    validate_unknown_bootstrap_call|'
reject_contract bundle_uses_local_basename \
    '        runtime_name=$(windows_fixed_leaf "$windows_operation_root\\runtime-receipt.json")' \
    '        runtime_name=$(basename -- "$normal_runtime_receipt")' \
    '/^        runtime_name=.*runtime-receipt.json/s@.*@        runtime_name=$(basename -- "$normal_runtime_receipt")@'

# bootstrap-v1.3 copies the transcript under a fixed Windows leaf. A local
# .transcript output must fail before any durable adoption or mutation.
reject_contract bootstrap_transcript_leaf_accepts_dot_transcript \
    '    [[ $leaf == linux-deactivation-transcript.json ]] ||' \
    '    [[ $leaf == linux-deactivation-transcript.json || $leaf == linux-deactivation.transcript ]] ||' \
    '/^require_bootstrap_deactivation_transport_leaf() {/,/^}/s@\[\[ \$leaf == linux-deactivation-transcript\.json \]\] ||@[[ $leaf == linux-deactivation-transcript.json || $leaf == linux-deactivation.transcript ]] ||@'
reject_contract bootstrap_transcript_leaf_validator_removed \
    '    require_bootstrap_deactivation_transport_leaf' \
    '    : # bootstrap transcript leaf validation bypass' \
    '/^bootstrap_preflight() {/,/^}/s|    require_bootstrap_deactivation_transport_leaf|    : # bootstrap transcript leaf validation bypass|'

reject_contract launcher_capture_shared_tmp \
    'local command response=$secure_dir/launcher.json resumed_start=$secure_dir/launcher-resumed-start.json' \
    'local command response=$(mktemp) resumed_start=$secure_dir/launcher-resumed-start.json' \
    '/^remote_prepare_and_start_once() {/,/^}/s|response=\$secure_dir/launcher.json|response=$(mktemp)|'
reject_contract recovery_status_capture_shared_tmp \
    'local status=$secure_dir/windows-stop-status.json evidence=$secure_dir/windows-stop-evidence.json' \
    'local status=$(mktemp) evidence=$secure_dir/windows-stop-evidence.json' \
    '/^stop_exact_windows_bootstrap() {/,/^}/s|status=\$secure_dir/windows-stop-status.json|status=$(mktemp)|'
reject_static_function_contract recovery_traps_not_disarmed \
    recover_both_hosts \
    '    trap - ERR INT TERM EXIT' \
    '    : # recovery trap disarm bypassed' \
    '/^recover_both_hosts() {/,/^}/s|    trap - ERR INT TERM EXIT|    : # recovery trap disarm bypassed|'
reject_contract recovery_double_entry_allowed \
    '    ((recovery_running == 0 && recovery_finished == 0)) || finish_recovery "$RECOVERY_FAILURE_EXIT"' \
    '    ((recovery_running == 0)) || finish_recovery "$RECOVERY_FAILURE_EXIT"' \
    '/^recover_both_hosts() {/,/^}/s|recovery_running == 0 && recovery_finished == 0|recovery_running == 0|'
reject_contract pre_mutation_exact_committed_set \
    '              ($committed | keys) == ["bootstrap_request","linux_frozen","marker_handoff","pre_mutation_retry","publish_receipt"]) or' \
    '              ($committed | type) == "object") or # P1 stray artifact accepted' \
    '/^render_pre_mutation_start_state() {/,/^}/s@              (\$committed | keys) == \["bootstrap_request","linux_frozen","marker_handoff","pre_mutation_retry","publish_receipt"\]) or@              ($committed | type) == "object") or # P1 stray artifact accepted@'
reject_contract pre_start_retry_reattest_removed \
    '                reopen_pre_mutation_stop_intent || return' \
    '                : # pre-start identity reattestation bypassed' \
    '/^remote_prepare_and_start_once() {/,/^}/s@                reopen_pre_mutation_stop_intent || return@                : # pre-start identity reattestation bypassed@'
reject_contract pre_mutation_root_acl_removed \
    'AssertAcl \$root \$true' \
    ': # root ACL bypass' \
    '/^reopen_pre_mutation_stop_intent() {/,/^}/s|AssertAcl \\$root \\$true|: # root ACL bypass|'
reject_contract pre_mutation_process_id_removed \
    "\$proc.ProcessId-ne\$pre_mutation_old_process_id" \
    '1-ne1 # process ID bypass' \
    '/^reopen_pre_mutation_stop_intent() {/,/^}/s|\\$proc.ProcessId-ne\$pre_mutation_old_process_id|1-ne1 # process ID bypass|'
reject_contract pre_mutation_creation_tuple_gate_removed \
    "\$creationUtc-ne'\$pre_mutation_old_process_creation_date'" \
    '1-ne1 # process creation bypass' \
    "/^reopen_pre_mutation_stop_intent() {/,/^}/s|\\\$creationUtc-ne'\$pre_mutation_old_process_creation_date'|1-ne1 # process creation bypass|"
reject_contract pre_mutation_localized_creation_output \
    'creation_date=\$creationUtc;' \
    'creation_date=[string]\$proc.CreationDate;' \
    '/^reopen_pre_mutation_stop_intent() {/,/^}/s|creation_date=\\$creationUtc;|creation_date=[string]\\$proc.CreationDate;|'

printf 'cross-host coordinator two-phase mutation tests passed\n'
