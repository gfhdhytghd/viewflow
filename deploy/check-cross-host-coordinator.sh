#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
readonly PATH=/usr/bin:/bin
export PATH
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly coordinator_source=${1:-$script_dir/coordinated-v13-to-v2.sh}
readonly expected_coordinator_sha256=8248f1ce2e6fe8b642f059ab1019314094bb20272a10295875aacf3c93823fe8
readonly sealed_fd_python=/usr/bin/python3.14
readonly sealed_fd_python_sha256=d78f9cf7178ecff09963551399855543c297f37ac207e626228bfe43cb26a70c
readonly reviewed_deskflow_acceptance_producer_sha256=666b46c165d7df9dbc3ce739bcfe4937698ec76149c024f5e17d8ad0b0475912
readonly reviewed_viewflow_acceptance_recorder_sha256=62f29f7f19e2bc2fa867c5a283bbea4d7585e226c21ace75ed3522fac753f4e4
fail() { printf 'cross-host coordinator static check failed: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | awk '{print $1}'; }
need() { grep -Fq -- "$1" "$coordinator" || fail "missing $2"; }
once() { local n; n=$(grep -Fc -- "$1" "$coordinator" || true); [[ $n == 1 ]] || fail "$2 count=$n"; }
line() { local n; n=$(grep -nF -- "$1" "$coordinator" | cut -d: -f1); [[ $n =~ ^[0-9]+$ ]] || fail "missing/duplicate order anchor $1"; printf '%s\n' "$n"; }
function_body() { sed -n "/^$1() {/,/^}/p" "$coordinator"; }
need_in_function() { function_body "$1" | grep -F -- "$2" >/dev/null || fail "$1 missing $3"; }
need_pattern_in_function() { function_body "$1" | grep -E -- "$2" >/dev/null || fail "$1 missing $3"; }
need_exact_line_in_function() { function_body "$1" | grep -Fx -- "$2" >/dev/null || fail "$1 missing executable $3"; }
function_line() { local function_name=$1 needle=$2 n; n=$(function_body "$function_name" | grep -nF -- "$needle" | cut -d: -f1); [[ $n =~ ^[0-9]+$ ]] || fail "$function_name missing/duplicate order anchor $needle"; printf '%s\n' "$n"; }
first_function_line() { local function_name=$1 needle=$2 n; n=$(function_body "$function_name" | grep -nF -- "$needle" | awk -F: 'NR == 1 { print $1 }'); [[ $n =~ ^[0-9]+$ ]] || fail "$function_name missing order anchor $needle"; printf '%s\n' "$n"; }
check_bootstrap_call_table() {
    local call
    # bootstrap_preflight only directly invokes helper families below.  Keep the
    # table definition-derived so an undefined validator cannot hide in a
    # syntactically valid preflight body.
    while IFS= read -r call; do
        [[ -z $call ]] && continue
        grep -Eq -- "^${call}\\(\\)[[:space:]]*\\{" "$coordinator" || fail "bootstrap_preflight calls undefined helper $call"
    done < <(function_body bootstrap_preflight | sed -nE 's/^[[:space:]]*(adopt_[A-Za-z0-9_]*|assert_[A-Za-z0-9_]*|derive_[A-Za-z0-9_]*|require_[A-Za-z0-9_]*|validate_[A-Za-z0-9_]*)[[:space:]].*/\1/p' | sort -u)
}
if [[ $coordinator_source =~ ^/proc/self/fd/([0-9]+)$ ]]; then
    sealed_fd=${BASH_REMATCH[1]}
    [[ -f $coordinator_source && $(stat -Lc '%u:%h' -- "$coordinator_source") == 1000:0 ]] ||
        fail 'unsafe sealed coordinator source metadata'
    [[ $(stat -c '%u:%g:%a:%h' -- "$sealed_fd_python") == 0:0:755:1 &&
       $(sha256 "$sealed_fd_python") == "$sealed_fd_python_sha256" ]] ||
        fail 'sealed-FD validator runtime differs'
    "$sealed_fd_python" -I -E -c 'import fcntl,os,stat,sys
fd=int(sys.argv[1]);st=os.fstat(fd)
required=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
raise SystemExit(0 if stat.S_ISREG(st.st_mode) and st.st_uid==1000 and st.st_nlink==0 and fcntl.fcntl(fd,fcntl.F_GET_SEALS)==required else 1)' "$sealed_fd" || fail 'coordinator source FD is not exact sealed memfd'
else
    [[ -f $coordinator_source && ! -L $coordinator_source ]] || fail 'unsafe coordinator source'
fi
tmp=$(mktemp -d); chmod 0700 "$tmp"; trap 'rm -rf -- "$tmp"' EXIT
coordinator=$tmp/coordinator.sh; cp -- "$coordinator_source" "$coordinator"; chmod 0600 "$coordinator"
bash -n "$coordinator"
fd_gate_payload=$(sed -n "/^readonly FD_GATE_PAYLOAD='/,/^readonly FD_GATE_PAYLOAD_SHA256=/p" "$coordinator" |
    sed '1s/^readonly FD_GATE_PAYLOAD='\''//;$d' | sed '$s/'\''$//')
fd_gate_payload_recorded=$(sed -nE 's/^readonly FD_GATE_PAYLOAD_SHA256=([0-9a-f]{64})$/\1/p' "$coordinator")
[[ -n $fd_gate_payload && $fd_gate_payload_recorded =~ ^[0-9a-f]{64}$ &&
   $(printf '%s' "$fd_gate_payload" | sha256sum | cut -d' ' -f1) == "$fd_gate_payload_recorded" ]] ||
    fail 'FD-gate payload source digest differs from its recorded constant'
if grep -Eq -- 'StrictHostKeyChecking=(no|accept-new)|UserKnownHostsFile=/dev/null|^[[:space:]]*(eval|source)([[:space:]]|$)|pkill|killall|kill[[:space:]]+-9' "$coordinator"; then fail 'unsafe shell/SSH construct'; fi
heredoc_lines=$(grep -Ec '<<-?' "$coordinator" || true)
quoted_probe_heredocs=$(grep -Fc "    read -r -d '' command <<'POWERSHELL' || true" "$coordinator" || true)
quoted_replacement_heredocs=$(grep -Fc "<<'PY'" "$coordinator" || true)
[[ $heredoc_lines == 3 && $quoted_probe_heredocs == 1 && $quoted_replacement_heredocs == 1 ]] || fail 'unexpected or unquoted heredoc construct'
if grep -Fq -- '|Out-Null' "$coordinator"; then fail 'cmd.exe-visible PowerShell Out-Null pipe present'; fi
if grep -Fq -- 'powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$1"' "$coordinator"; then fail 'unsafe cmd.exe-visible PowerShell -Command transport present'; fi
if grep -Fq -- '[Console]::In.ReadToEnd()' "$coordinator"; then fail 'Windows OpenSSH upload relies on an EOF-sensitive PowerShell read'; fi
if grep -Fq -- 'os.environ' "$coordinator"; then fail 'FD gate inherits the caller environment'; fi
if grep -Fq -- '--argjson mutation "$recovery_mutation_possible"' "$coordinator"; then fail 'recovery mutation_possible is not serialized through a JSON boolean expression'; fi
[[ $expected_coordinator_sha256 =~ ^[0-9a-f]{64}$ ]] || fail 'coordinator pin remains PENDING'
[[ $reviewed_deskflow_acceptance_producer_sha256 =~ ^[0-9a-f]{64}$ ]] || fail 'C++ pin remains PENDING'
[[ $reviewed_viewflow_acceptance_recorder_sha256 =~ ^[0-9a-f]{64}$ ]] || fail 'Rust pin remains PENDING'
[[ $(sha256 "$coordinator") == "$expected_coordinator_sha256" ]] || fail 'coordinator SHA pin mismatch'
! grep -Fq -- 'validate_bootstrap_chain' "$coordinator" || fail 'stale undefined validate_bootstrap_chain call present'
check_bootstrap_call_table
need 'readonly WINDOWS_SSH_TARGET=wilf@172.16.105.70' 'fixed Windows host'
need 'readonly EXPECTED_WINDOWS_PEER=172.16.105.62:44119' 'fixed Linux server endpoint for Windows client'
need 'readonly EXPECTED_WINDOWS_SOURCE_IP=172.16.105.70' 'fixed Windows source IP for Linux authentication'
need 'readonly SSH_BATCH_OPTION=BatchMode=yes' 'batch SSH'; need 'readonly SSH_HOST_KEY_OPTION=StrictHostKeyChecking=yes' 'strict host key'
need 'deployment-quarantine.v1' 'VFDQT001 marker'; need 'deskflow-quarantine.v2' 'VFQST002 marker'
need 'VFDQR001' 'VFDQR001 durable receipt magic'; need '1000:600:1:352' 'VFDQR001 metadata'
need 'bs=320 count=1' 'VFDQR001 prefix checksum'; need 'skip=320 count=32' 'VFDQR001 suffix checksum'
need 'readonly WINDOWS_RECOVERY_IMPLEMENTED=1' 'completed failed-v1.3 recovery gate'
need 'readonly FD_GATE_ENV=/usr/bin/env' 'fixed clean-environment runtime'
need 'readonly FD_GATE_ENV_SHA256=08392d72874da4f88c619ee717f2b4a5f28ba0534ff8cf1083fb2edc37d6475f' 'clean-environment runtime pin'
need 'readonly FD_GATE_PYTHON=/usr/bin/python3.14' 'fixed root-owned FD-gate runtime'
need 'readonly FD_GATE_PYTHON_SHA256=d78f9cf7178ecff09963551399855543c297f37ac207e626228bfe43cb26a70c' 'FD-gate runtime pin'
need 'readonly FD_GATE_LOADER_SHA256=0e3301c81b854c06500628ffd7a1968869e5a377d83a84e0726b33371d8f1eed' 'FD-gate loader pin'
need 'readonly FD_GATE_PAYLOAD_SHA256=' 'FD-gate payload pin'
need 'VFDQA001' 'VFDQA001 durable abort receipt magic'; need '1000:600:1:384' 'VFDQA001 metadata'
need 'bs=352 count=1' 'VFDQA001 prefix checksum'; need 'skip=352 count=32' 'VFDQA001 suffix checksum'
if grep -Eq -- '(rm|unlink|mv|install|cp|truncate)[^\n]*\$RUNTIME_MARKER|dd[^\n]*of="?\$RUNTIME_MARKER' "$coordinator"; then fail 'coordinator mutates VFQST002'; fi
for option in --bootstrap-handoff-receipt --windows-bootstrap-request --windows-prepared-receipt --windows-mutation-permit --windows-force-release-envelope --linux-stage-receipt --linux-finalize-receipt --windows-installer-exit-receipt --coordinator-state --windows-viewflow-candidate --windows-wrapper-candidate --windows-launcher-candidate --windows-launcher-sha256 --windows-installer-candidate --windows-installer-sha256 --windows-rollback-script-sha256 --bootstrap-timeout-seconds --resume --resume-pre-mutation-stop-intent --pre-mutation-stop-state-baseline-path --pre-mutation-stop-state-baseline-sha256 --pre-mutation-old-executable-sha256 --pre-mutation-old-wrapper-sha256 --pre-mutation-old-task-xml-sha256 --pre-mutation-old-process-id --pre-mutation-old-parent-process-id --pre-mutation-old-process-creation-date --candidate-retirement-terminal --candidate-retirement-terminal-sha256 --candidate-replacement-commit --candidate-replacement-commit-sha256 --abort-failed-v13 --abort-failed-v13-pre-mutation --pre-mutation-abort-marker-cli-candidate --pre-mutation-abort-marker-cli-sha256 --pre-mutation-windows-live-proof --attempt3-slot-cleanup-receipt --attempt3-slot-cleanup-receipt-sha256 --fresh-operation-lineage-receipt --fresh-operation-lineage-receipt-sha256 --schema1-handoff-lineage-receipt --schema1-handoff-lineage-receipt-sha256 --schema1-handoff-abort-marker-cli-candidate --schema1-handoff-abort-marker-cli-sha256 --post-force-abort-marker-cli-candidate --post-force-abort-marker-cli-sha256 --failed-v13-original-generation-only --old-coordinator-state-sha256 --deployment-abort-authorization --deployment-abort-receipt --failed-v13-abort-transition-receipt --linux-v13-started-receipt --windows-v13-started-receipt --authenticated-v13-peer-receipt; do need "$option" "option $option"; done
need 'candidate replacement options must be supplied all-or-none' 'replacement all-or-none gate'
need 'candidate replacement options are valid only for the normal coordinator path' 'replacement abort rejection'
need 'if ((replacement_flag_count != 0 && (abort_failed_v13 || abort_failed_v13_pre_mutation))); then' 'replacement abort-mode predicate'
need '--coordinator-successor-receipt)' 'coordinator successor receipt option'
need '--coordinator-successor-receipt-sha256)' 'coordinator successor SHA option'
need 'coordinator successor options must be supplied all-or-none' 'successor all-or-none gate'
need 'coordinator successor options are valid only for the normal coordinator path' 'successor abort rejection'
need 'if ((successor_flag_count != 0 && (abort_failed_v13 || abort_failed_v13_pre_mutation))); then' 'successor abort-mode predicate'
need 'coordinator successor receipt exists but its two options are missing' 'successor evidence presence gate'
need_in_function validate_candidate_replacement_lineage 'os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW' 'strict nofollow descriptor read'
need_in_function validate_candidate_replacement_lineage 'if key in out: die("duplicate JSON key "+repr(key))' 'duplicate-key rejection'
need_in_function validate_candidate_replacement_lineage 'before.st_uid==owner' 'uid 1000 metadata gate'
need_in_function validate_candidate_replacement_lineage 'before.st_nlink==links' 'single-link evidence gate'
need_in_function validate_candidate_replacement_lineage 'seconds=calendar.timegm(datetime.datetime.strptime(utc[:19],"%Y-%m-%dT%H:%M:%S").timetuple())' 'stdlib UTC epoch conversion'
need_in_function validate_candidate_replacement_lineage 'req(unix_ms==expected,label+" UTC/unix_ms equality differs")' 'exact UTC/unix-ms equality gate'
need_in_function validate_candidate_replacement_lineage '"viewflow-normal-v21-candidate-retired"' 'retirement terminal state'
need_in_function validate_candidate_replacement_lineage '"viewflow-normal-v21-candidate-replacement-committed"' 'replacement commit state'
need_in_function validate_candidate_replacement_lineage 'archive=rejected_root+"/v21-operation-"+op+".rejected-"+old["manifest_sha256"]' 'fixed rejected archive path'
need_in_function validate_candidate_replacement_lineage 'item.name.encode()+b"\0"+mode.encode()+b"\0"+str(len(data)).encode()+b"\0"+digest.encode()+b"\n"' 'canonical exact6 tree algorithm'
need_in_function validate_candidate_replacement_lineage 'req(tuple(item.name for item in entries)==EXACT6,label+" is not exact6")' 'exact6 membership gate'
need_in_function validate_candidate_replacement_lineage 'keys(manifest_obj,TOP,"schema2 candidate manifest")' 'schema2 candidate manifest exact ordered keys'
need_in_function validate_candidate_replacement_lineage 'keys(manifest_obj["candidate_replacement"]' 'manifest replacement lineage schema'
need_in_function validate_candidate_replacement_lineage 'replacement publish active-marker closure differs' 'strict publish/active-marker closure'
need_in_function validate_candidate_replacement_lineage 'publish_obj["marker_path"]==active_marker and publish_obj["marker_sha256"]==terminal_fresh["deployment_marker_sha256"]' 'publish marker path/hash binding'
need_in_function validate_candidate_replacement_lineage 'replacement P-H marker closure differs' 'strict publish/handoff closure'
need_in_function validate_candidate_replacement_lineage 'handoff_obj["deployment_publish_receipt_path"]==publish and handoff_obj["deployment_publish_receipt_sha256"]==publish_sha' 'handoff publish binding'
need_in_function validate_candidate_replacement_lineage 'handoff_obj["marker_cli_path"]==installed_marker_cli and handoff_obj["marker_cli_sha256"]==marker_cli_sha' 'handoff fixed installed marker CLI binding'
need_in_function validate_candidate_replacement_lineage 'actual_sha(installed_marker_cli,marker_cli_sha,"replacement installed marker CLI")' 'installed marker CLI byte binding'
need_in_function validate_candidate_replacement_lineage 'actual_sha(marker_cli,marker_cli_sha,"replacement candidate marker CLI")' 'candidate marker CLI byte binding'
need_in_function validate_candidate_replacement_lineage '"viewflow-normal-v21-coordinator-successor-authorized"' 'successor receipt state'
need_in_function validate_candidate_replacement_lineage 'keys(successor_obj,["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms","created_at_utc"' 'successor receipt ordered root schema'
need_in_function validate_candidate_replacement_lineage 'pc=={"path":co["entrypoint"],"sha256":co["entrypoint_sha256"],"provenance_path":co["source_provenance"]' 'manifest predecessor coordinator binding'
need_in_function validate_candidate_replacement_lineage 'succ["coordinator_path"]==coordinator_source' 'executing successor coordinator binding'
need_in_function validate_candidate_replacement_lineage 'actual_sha(succ["provenance_path"],succ["provenance_sha256"],"successor provenance")' 'successor provenance byte binding'
need_in_function validate_candidate_replacement_lineage '"marker-cli-path-alias-same-bytes-v1"' 'narrow marker alias kind'
need_in_function validate_candidate_replacement_lineage 'absence["normal_output_leaves"]==normal_leaves' 'exact normal output absence list'
need_in_function validate_candidate_replacement_lineage 'absence["pre_receipt_operation_leaves"]==pre_receipt_leaves' 'exact pre-receipt operation list'
need_in_function validate_candidate_replacement_lineage '"viewflow-normal-v21-coordinator-successor-windows-prestate"' 'successor Windows prestate state'
need_in_function validate_candidate_replacement_lineage 'wproof["operation_bound_task_count"]==0 and wproof["operation_bound_tasks"]==[]' 'Windows task absence'
need_in_function validate_candidate_replacement_lineage 'wproof["operation_bound_process_count"]==0 and wproof["operation_bound_processes"]==[]' 'Windows process absence'
need_in_function validate_candidate_replacement_lineage 'Windows prestate collector/receipt producer identity differs' 'collector producer identity'
need_in_function validate_candidate_replacement_lineage 'wproof["collector_path"]==succ["receipt_producer_path"] and' 'collector path equals receipt producer path'
need_in_function validate_candidate_replacement_lineage 'replacement frozen operation boundary differs' 'strict frozen evidence closure'
need_in_function validate_candidate_replacement_lineage 'candidate Linux Rust "+stem+" CLI differs' 'Linux Rust CLI binding'
need_in_function validate_candidate_replacement_lineage 'candidate Deskflow "+stem+" CLI differs' 'Deskflow CLI binding'
need_in_function validate_candidate_replacement_lineage 'candidate Windows "+stem+" CLI differs' 'Windows CLI binding'
need_in_function validate_candidate_replacement_lineage 'candidate coordinator entrypoint differs' 'coordinator path binding'
need_in_function render_committed_artifacts '    ((replacement_flag_count == 0)) || validate_candidate_replacement_lineage' 'replacement revalidation before every render'
need_in_function render_state 'candidate_retirement_terminal:{path:$candidate_retirement,sha256:$candidate_retirement_sha}' 'replacement terminal state input'
need_in_function render_state 'candidate_replacement_commit:{path:$candidate_replacement,sha256:$candidate_replacement_sha}' 'replacement commit state input'
need_in_function render_state 'candidate_manifest:{path:$candidate_manifest,sha256:$candidate_manifest_sha}' 'current manifest state input'
need_in_function render_state 'candidate_tree_sha256:$candidate_tree' 'current tree state input'
need_in_function validate_state_contract '.committed_artifacts.candidate_tree == $tree' 'replacement committed artifacts exact gate'
need_in_function validate_state_contract '.committed_artifacts.coordinator_successor_receipt == $receipt' 'successor receipt committed artifact gate'
need_in_function validate_state_contract '.committed_artifacts.coordinator_successor_windows_prestate == $windows' 'successor Windows prestate committed artifact gate'
need_in_function render_state 'coordinator_successor_receipt:{path:$successor_receipt,sha256:$successor_receipt_sha}' 'successor receipt state input'
need_in_function render_state 'coordinator_predecessor:{path:$predecessor_path,sha256:$predecessor_sha,' 'predecessor coordinator state input'
need_in_function render_state 'coordinator_successor:{path:$successor_path,sha256:$successor_sha,' 'successor coordinator state input'
need_in_function validate_pre_mutation_stop_state_baseline '"coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"]' 'successor sealed STOP exact committed set'
need_in_function render_pre_mutation_start_state '"coordinator_successor_windows_prestate","linux_frozen","marker_handoff"' 'successor START exact committed set'
need_in_function reopen_pre_mutation_stop_intent '"coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"]' 'successor reopen exact committed set'
need_exact_line_in_function bootstrap_preflight '    validate_candidate_replacement_lineage' 'pre-state replacement validation'
need 'viewflow-v13-marker-handoff-prepared' 'H'; need 'viewflow-v13-bootstrap-frozen' 'B'; need 'viewflow-windows-bootstrap-requested' 'request'
need 'viewflow-windows-bootstrap-recovery-armed' 'P'; need 'viewflow-windows-bootstrap-mutation-permitted' 'permit'
need 'linux_viewflowd_sha256:$viewflow' 'permit Linux viewflow'; need 'linux_deployment_marker_sha256:$marker' 'permit marker'; need 'linux_viewflow_unit_sha256:$unit' 'permit unit'
need 'viewflow-windows-bootstrap-force-release-attested' 'F'; need '"$linux_stage" stage' 'Ls producer'; need '"$linux_finalize" finalize' 'Lf producer'
need '.schema_version == 5 and .state == "viewflow-v2-windows-installed"' 'schema5 W'; need 'unique | length == 6' 'six distinct W hashes'
need 'viewflow-windows-bootstrap-succeeded' 'exit success'; need 'viewflow-windows-bootstrap-failed' 'exit failure'; need 'viewflow-linux-bootstrap-finalized' 'Lf'
need 'viewflow-cross-host-bootstrap-bound' 'exact cross-host chain'; need 'windows_installer_exit_receipt_sha256:$exit' 'exit-to-Lf cross binding'
need 'schema_version:2,state:"viewflow-cross-host-bootstrap"' 'schema2 frozen coordinator state'
need 'committed_artifacts:$committed' 'durable committed artifact hashes'; need 'validate_state_contract' 'resume contract equality'
need 'WINDOWS_PERMIT_PUBLISH_INTENT' 'durable permit publish intent'; need 'commit_phase WINDOWS_PERMIT_PUBLISH_INTENT' 'permit intent before upload'
need "raw_sha=\$(jq -er '.raw_force_release_receipt_sha256'" 'W binds raw force receipt SHA'
need 'old_sha=$(jq -er '\''.old_executable.sha256' 'W binds prepared old executable'
need 'windows_task_xml_override=$windows_task_xml_sha' 'optional task XML override'; need 'windows_task_xml_sha=$adopted_task' 'dynamic task XML adoption'
need 'validate_operation_readiness_chain' 'operation-root readiness chain'; need 'windows_commit_request_path=' 'fixed commit request path'
need 'source-display-id "$source_display_id_lower"' 'Linux source ID normalization'; need 'coordinator-instance-id "$coordinator_instance_id_lower"' 'Linux coordinator ID normalization'
need 'consume-intent.json' 'arbitrary finalize consume recovery'; need '--active-recovery-marker-publish-receipt' 'active marker rollback union'
need 'STOP_INTENT) echo 200' 'durable stop intent'; need 'WINDOWS_ROLLBACK_INTENT) echo 230' 'durable Windows rollback intent'
need 'windows_rollback_receipt_path="$windows_operation_root' 'fixed remote rollback receipt'; need 'non-canonical operation-root recovery path' 'P remote path confinement'
need_in_function require_bootstrap_deactivation_transport_leaf '    leaf=$(basename -- "$linux_deactivation_transcript")' 'bootstrap transcript basename derivation'
need_in_function require_bootstrap_deactivation_transport_leaf '    [[ $leaf == linux-deactivation-transcript.json ]] ||' 'fixed bootstrap transcript leaf equality'
need_in_function require_bootstrap_deactivation_transport_leaf "        die '--linux-deactivation-transcript basename must be linux-deactivation-transcript.json'" 'bootstrap transcript leaf rejection'
if function_body require_bootstrap_deactivation_transport_leaf | grep -Eq '^[[:space:]]*(return|exit)[[:space:]]'; then fail 'bootstrap transcript leaf validator can short-circuit'; fi
need_pattern_in_function bootstrap_preflight '^[[:space:]]*require_bootstrap_deactivation_transport_leaf[[:space:]]*$' 'unconditional bootstrap transcript leaf validation'
transcript_leaf_check=$(function_line bootstrap_preflight '    require_bootstrap_deactivation_transport_leaf')
transcript_adopt=$(function_line bootstrap_preflight '    adopt_consume_intent_inputs')
((transcript_leaf_check < transcript_adopt)) || fail 'bootstrap transcript leaf is not rejected before durable input adoption'
need 'release_deployment_marker_transactionally' 'transactional release'; need 'marker_cli query' 'gated release query'
once "capture_json_command 'deployment release receipt'" 'single normal release transaction'; need 'deployment-quarantine-release-claimed' 'claimed state'; need 'deployment-quarantine-release-committed-pending-release' 'pending state'
need_exact_line_in_function main '        release_deployment_marker_transactionally' 'normal success release call'
if function_body main | grep -Eq 'abort_deployment_marker|VFDQA001|abort-authorization'; then fail 'normal 2.1 success path contains failed-v1.3 abort semantics'; fi
need_exact_line_in_function failed_v13_abort_preflight '    validate_failed_v13_terminal_state' 'immutable old terminal-state validation'
need_exact_line_in_function failed_v13_abort_preflight '    validate_failed_v13_slot_lineage_union' 'strict slot-lineage union gate'
need_exact_line_in_function failed_v13_abort_preflight '    select_failed_v13_abort_marker_tuple' 'active abort marker tuple selection'
need_exact_line_in_function failed_v13_abort_preflight '    assert_failed_v13_original_generation_only' 'original generation-only gate'
need_in_function validate_attempt3_slot_cleanup_gate '.state == "viewflow-attempt3-exchange-slot-cleanup-complete"' 'slot-cleanup completion state'
need_in_function validate_attempt3_slot_cleanup_gate '[[ $(sha256 "$attempt3_slot_cleanup_receipt") == "$attempt3_slot_cleanup_receipt_sha" ]] ||' 'slot-cleanup completion SHA equality'
need_in_function validate_attempt3_slot_cleanup_gate '.checkout_slots_absent == true' 'slot-cleanup source absence receipt'
need_in_function validate_attempt3_slot_cleanup_gate '.claims_preserved == true' 'slot-cleanup retained-claim receipt'
need_in_function validate_attempt3_slot_cleanup_gate '[[ ! -e $source && ! -L $source ]]' 'live exchange-slot absence'
need_in_function validate_attempt3_slot_cleanup_gate '$destination_identity == "$claim_identity"' 'live retained-claim inode identity'
need_in_function validate_failed_v13_slot_lineage_union '-z $fresh_operation_lineage_receipt && -z $fresh_operation_lineage_receipt_sha' 'legacy/fresh proof mutual exclusion'
need_exact_line_in_function validate_failed_v13_slot_lineage_union '        validate_attempt3_slot_cleanup_gate' 'legacy attempt3 cleanup branch'
need_exact_line_in_function validate_failed_v13_slot_lineage_union '        validate_fresh_operation_lineage_gate' 'fresh-operation lineage branch'
need_exact_line_in_function validate_failed_v13_slot_lineage_union '        validate_schema1_handoff_lineage_gate' 'schema1-handoff lineage branch'
need_in_function validate_schema1_handoff_lineage_gate '[[ $(sha256 "$schema1_handoff_lineage_receipt") == "$schema1_handoff_lineage_receipt_sha" ]] ||' 'schema1-handoff lineage SHA equality'
need_in_function validate_schema1_handoff_lineage_gate '.state == "viewflow-schema1-abort-handoff-to-fresh-v21"' 'schema1-handoff lineage state'
need_in_function validate_schema1_handoff_lineage_gate '.old_schema1_abort == {terminal_sha256:$terminal,authorization_sha256:$authorization,' 'schema1-handoff old terminal closure'
need_in_function validate_schema1_handoff_lineage_gate '.recovery == {failure_phase:"MUTATION_PERMITTED",mutation_possible:true}' 'schema1-handoff exact failure phase'
need_in_function validate_schema1_handoff_lineage_gate '.committed_artifacts == {marker_handoff:$h,linux_frozen:$b,publish_receipt:$p,' 'schema1-handoff exact committed artifacts'
need_in_function validate_schema1_handoff_lineage_gate '[[ $prefix_sha == "$suffix_sha" ]]' 'schema1-handoff VFDQA checksum'
need_in_function validate_failed_v13_terminal_state '.contract.inputs.linux_frozen.path == $frozen_path and .contract.outputs.request == $request_path and' 'post-force input path binding'
need_in_function failed_v13_abort_preflight 'schema1_handoff_abort_marker_cli_candidate != "$MARKER_CLI"' 'schema1-handoff new marker candidate isolation'
need_in_function make_and_validate_post_permit_rollback_abort_authorization '.schema_version == 5 and .state == "viewflow-deployment-quarantine-post-permit-rollback-abort-authorized"' 'post-permit auth schema5'
need_in_function make_and_validate_post_permit_rollback_abort_authorization '.force_release_executed == false and .rollback_performed == true' 'truthful force/rollback flags'
need_in_function validate_abort_receipt_v5 '.schema_version == 5 and .state == "deployment-quarantine-aborted"' 'post-permit receipt schema5'
need_in_function abort_deployment_marker_transactionally 'marker_executable=$schema1_handoff_abort_marker_cli_candidate' 'schema1-handoff candidate dispatch'
need_in_function make_and_validate_post_force_rollback_abort_authorization '.schema_version == 7 and .state == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized"' 'post-force auth schema7'
need_in_function make_and_validate_post_force_rollback_abort_authorization '.force_release_executed == true and .rollback_performed == true and .linux_stage_committed == false' 'truthful post-force flags'
need_in_function validate_abort_receipt_v7 '.schema_version == 7 and .state == "deployment-quarantine-aborted"' 'post-force receipt schema7'
need_in_function validate_abort_receipt_v7 '.force_release_executed == true and .rollback_performed == true and .linux_stage_committed == false' 'truthful post-force receipt flags'
need_in_function failed_v13_abort_preflight 'post_force_abort_marker_cli_candidate != "$MARKER_CLI"' 'post-force new marker candidate isolation'
need_in_function abort_deployment_marker_transactionally 'marker_executable=$post_force_abort_marker_cli_candidate' 'post-force candidate dispatch'
need_exact_line_in_function abort_deployment_marker_transactionally '        validate_abort_receipt_v7 "$deployment_abort_receipt"' 'schema7 VFDQA001 validator call'
need_in_function validate_failed_v13_terminal_state '.recovery == {failure_phase:"WINDOWS_FORCE_ATTESTED",mutation_possible:true}' 'post-force exact failure phase'
need_in_function validate_failed_v13_terminal_state '.committed_artifacts == {bootstrap_request:$request,force_envelope:$force,linux_frozen:$b,' 'post-force exact committed set'
need_in_function validate_fresh_operation_lineage_gate '.state == "viewflow-v4-inactive-terminal-to-fresh-v21"' 'fresh lineage schema1 state'
need_in_function validate_fresh_operation_lineage_gate '[[ $(sha256 "$fresh_operation_lineage_receipt") == "$fresh_operation_lineage_receipt_sha" ]] ||' 'fresh lineage SHA equality'
need_exact_line_in_function validate_fresh_operation_lineage_gate '    [[ $(jq -cS '\''del(.replayed)'\'' "$old_abort") == "$(jq -cS '\''del(.replayed)'\'' "$old_query")" ]] ||' 'fresh predecessor abort/query canonical replay equality'
need_in_function validate_fresh_operation_lineage_gate '.new_operation_id == $op and .new_coordinator_instance_id == $coordinator' 'fresh lineage operation/coordinator binding'
need_in_function validate_fresh_operation_lineage_gate '.old_operation_id == $old and .old_operation_id != $op' 'fresh lineage exact old-operation binding'
need_exact_line_in_function validate_fresh_operation_lineage_gate '        .fresh_boundary.deployment_marker_sha256 == $marker and' 'fresh lineage marker binding'
need_in_function validate_fresh_operation_lineage_gate 'old_root="/home/wilf/.local/state/viewflow/deployments/${old_operation}"' 'fixed old-operation evidence root'
need_in_function validate_fresh_operation_lineage_gate 'bridge_root="/home/wilf/.local/state/viewflow/v4-inactive-bridges/${old_operation}"' 'fixed inactive bridge evidence root'
need_in_function validate_fresh_operation_lineage_gate 'durable_path=$(jq -er ' 'durable VFDQA path derivation from abort receipt'
need_in_function validate_fresh_operation_lineage_gate '$(sha256 "$immutable_vfdqa") == "$(sha256 "$durable_path")"' 'immutable/durable VFDQA equality'
need_in_function validate_fresh_operation_lineage_gate '[[ $prefix_sha == "$suffix_sha" ]] ||' 'durable VFDQA self-checksum'
need_in_function validate_fresh_operation_lineage_gate '--slurpfile manifest "$candidate_manifest"' 'strict candidate manifest/current state join'
need_in_function validate_fresh_operation_lineage_gate '$m.windows.rollback_sha256 == .contract.inputs.windows_rollback.sha256' 'fifth Windows input binding'
need_in_function validate_fresh_operation_lineage_gate '.committed_artifacts == {bootstrap_request:$request,force_envelope:$f,linux_frozen:$b,' 'fresh exact committed artifact map'
need_in_function validate_fresh_operation_lineage_gate '.contract.inputs.windows_viewflow.path == ($root + "/windows-viewflowd.exe")' 'fresh operation candidate binding'
need_in_function validate_fresh_operation_lineage_gate 'contains(".attempt3.exchange-slot") | not' 'fresh contract excludes attempt3 exchange inputs'
need_in_function validate_fresh_operation_lineage_gate '[[ ! -e $source && ! -L $source ]] ||' 'fresh live attempt3-slot absence'
need_in_function assert_failed_v13_original_generation_only '$abort_marker_generation == "$marker_generation"' 'original marker generation equality'
need_in_function assert_failed_v13_original_generation_only '! -e $deployment_release_receipt && ! -L $deployment_release_receipt' 'release sentinel absence'
need_in_function assert_failed_v13_original_generation_only '! -e $recovery_deployment_publish_receipt && ! -L $recovery_deployment_publish_receipt' 'recovery-publish sentinel absence'
need_in_function failed_v13_abort_preflight "state_request=\$(jq -er '.contract.outputs.request" 'old-state request path derivation'
need_in_function failed_v13_abort_preflight "state_stop=\$(jq -er '.contract.outputs.windows_stop_evidence" 'old-state stop-evidence path derivation'
need_in_function validate_failed_v13_terminal_state '.contract.outputs.request == $request' 'old-state request path binding'
need_exact_line_in_function validate_failed_v13_terminal_state '            .contract.inputs.linux_frozen.path == $frozen and .contract.outputs.request == $request and' 'post-permit exact request path binding'
need_exact_line_in_function validate_failed_v13_terminal_state '        .contract.inputs.linux_frozen.path == $frozen and .contract.outputs.request == $request and' 'legacy failed-terminal exact request path binding'
need_exact_line_in_function validate_failed_v13_terminal_state '        .committed_artifacts.bootstrap_request == $request and' 'legacy failed-terminal bootstrap request hash binding'
need_in_function validate_failed_v13_terminal_state '.committed_artifacts.bootstrap_request == $request' 'old-state request hash binding'
need_in_function select_failed_v13_abort_marker_tuple 'abort_marker_operation_id=$operation_id' 'generation-1 abort tuple'
need_in_function select_failed_v13_abort_marker_tuple 'recovery_operation_id="${operation_id}_recovery"' 'generation-2 abort operation'
need_in_function select_failed_v13_abort_marker_tuple 'validate_publish_receipt "$recovery_deployment_publish_receipt" "$recovery_marker_generation" 0 "$recovery_operation_id"' 'generation-2 publish proof'
need_in_function validate_failed_v13_terminal_state '.phase == "WINDOWS_ROLLED_BACK"' 'old terminal phase equality'
need_in_function validate_failed_v13_terminal_state '    [[ $(sha256 "$path") == "$old_coordinator_state_sha" ]]' 'old terminal state SHA pin'
need_in_function failed_v13_abort_main '    [[ $state_after == "$state_before" && $state_after == "$old_coordinator_state_sha" ]] ||' 'old terminal state immutability proof'
need_in_function make_and_validate_abort_authorization 'keys == ["authenticated_v13_peer_receipt_sha256"' 'strict abort authorization key set'
need_in_function make_and_validate_abort_authorization '.initial_force_release_executed == true and .second_force_release_executed == false' 'abort force-release booleans'
need_in_function make_and_validate_abort_authorization '.rollback_token_consumed == false and .protocol_2_1 == false' 'abort protocol/token booleans'
need_exact_line_in_function failed_v13_pre_mutation_abort_preflight '    validate_pre_mutation_failed_terminal_state' 'pre-mutation immutable state validation'
need_exact_line_in_function failed_v13_pre_mutation_abort_preflight '    validate_pre_mutation_failed_baseline' 'pre-mutation old baseline validation'
need_exact_line_in_function failed_v13_pre_mutation_abort_preflight '    assert_pre_mutation_outputs_absent' 'pre-mutation local output absence gate'
need_exact_line_in_function failed_v13_pre_mutation_abort_preflight '    assert_failed_v13_original_generation_only' 'pre-mutation original generation-only gate'
need_in_function validate_pre_mutation_failed_terminal_state '.phase == "LINUX_RECOVERED"' 'pre-mutation exact terminal phase'
need_in_function validate_pre_mutation_failed_terminal_state '.recovery == {failure_phase:"WINDOWS_STARTED",mutation_possible:false}' 'pre-mutation exact failure/mutation state'
need_in_function validate_pre_mutation_failed_terminal_state '.committed_artifacts == {marker_handoff:$h,linux_frozen:$b,publish_receipt:$p,' 'pre-mutation exact committed artifact map'
need_in_function validate_pre_mutation_failed_terminal_state '.exit_code == 1' 'failed installer exit code binding'
need_in_function validate_pre_mutation_failed_terminal_state 'pre_mutation_old_windows_rollback_sha=$(jq -er '\''.old_rollback_sha256' 'old Windows rollback hash extraction'
need_in_function capture_pre_mutation_windows_live_proof 'windows_read_file "$windows_stop_evidence_path" "$remote_stop"' 'remote stop evidence raw-byte readback'
need_exact_line_in_function capture_pre_mutation_windows_live_proof '    validate_pre_mutation_stop_transport_bridge "$remote_stop" "$local_windows_stop_evidence"' 'strict remote/local stop transport bridge call'
need_in_function validate_pre_mutation_stop_transport_bridge 'r.count(b"\n")==1 and b"\r" not in r' 'remote exact terminal LF gate'
need_in_function validate_pre_mutation_stop_transport_bridge 'l.count(b"\n")==1 and l.count(b"\r")==1 and l[:-2]==r[:-1]' 'local exact terminal CRLF and raw prefix gate'
need_exact_line_in_function validate_pre_mutation_stop_transport_bridge '    [[ $remote_canonical == "$local_canonical" ]] ||' 'remote/local canonical JSON equality'
need_in_function validate_pre_mutation_stop_transport_bridge 'validate_windows_stop_evidence "$remote"' 'remote stop strict schema validation'
need_in_function validate_pre_mutation_stop_transport_bridge 'validate_windows_stop_evidence "$local_committed"' 'local stop strict schema validation'
need_in_function capture_pre_mutation_windows_live_proof 'windows_read_file "$windows_exit_path" "$remote_exit"' 'remote installer-exit raw-byte readback'
need_in_function capture_pre_mutation_windows_live_proof '[[ $(sha256 "$remote_exit") == "$(sha256 "$windows_installer_exit_receipt")" ]]' 'remote/local installer-exit byte equality'
need_in_function capture_pre_mutation_windows_live_proof '[[ $(jq -er '\''.claim_sha256'\'' "$windows_installer_exit_receipt") == "$claim_sha" &&' 'remote launcher claim byte-hash binding'
need_in_function capture_pre_mutation_windows_live_proof 'windows_read_file "$windows_operation_root\launcher-claim.json" "$remote_claim"' 'remote launcher claim raw-byte readback'
need_exact_line_in_function capture_pre_mutation_windows_live_proof '    validate_pre_mutation_remote_launcher_claim "$remote_claim" "$worker_pid" "$installer_command_sha"' 'canonical remote launcher claim validator call'
need_in_function validate_pre_mutation_remote_launcher_claim '.task_name == ("Viewflow Deployment " + $op) and' 'canonical launcher task name without TaskPath prefix'
if function_body validate_pre_mutation_remote_launcher_claim | grep -F '("\\Viewflow Deployment " + $op)' >/dev/null; then fail 'remote launcher claim accepts TaskPath-prefixed task name'; fi
need_in_function validate_windows_stop_evidence '.task_name == ("Viewflow Deployment " + $op) and' 'canonical stopped launcher task name'
need_in_function validate_windows_identity_scalar '"canonical-filetime":lambda v:type(v) is str and re.fullmatch(r"[1-9][0-9]{16,18}",v) is not None' 'canonical Windows FILETIME helper'
need_in_function validate_windows_identity_scalar '"positive-uint32":lambda v:type(v) is int and 1<=v<=4294967295' 'canonical positive uint32 helper'
need_in_function validate_windows_identity_scalar '"session-one":lambda v:type(v) is int and v==1' 'canonical integer session helper'
need_in_function validate_windows_identity_scalar '"utc-milliseconds":lambda v:type(v) is str and re.fullmatch' 'canonical UTC milliseconds helper'
need_in_function validate_windows_stop_evidence '(.worker_process_start_filetime_utc | test("^[1-9][0-9]{16,18}$"))' 'stopped launcher canonical FILETIME'
need_in_function validate_windows_stop_evidence '(.stopped_at_utc | type == "string" and test(' 'stopped launcher UTC milliseconds'
need_exact_line_in_function validate_windows_stop_evidence '        validate_windows_identity_scalar "$evidence" worker_pid positive-uint32' 'stopped launcher uint32 worker PID helper call'
need_exact_line_in_function validate_windows_stop_evidence '        validate_windows_identity_scalar "$evidence" stopped_at_utc utc-milliseconds' 'stopped launcher UTC helper call'
need_exact_line_in_function capture_pre_mutation_windows_live_proof '    validate_pre_mutation_stop_claim_identity "$remote_stop" "$remote_claim"' 'stop/claim worker identity call'
need_exact_line_in_function validate_pre_mutation_stop_claim_identity '    [[ $(jq -er '\''.worker_process_start_filetime_utc'\'' "$stop") == \' 'stop/claim worker start-time equality'
need_exact_line_in_function capture_pre_mutation_windows_live_proof '    validate_pre_mutation_remote_installer_process "$remote_process" "$worker_pid" "$claim_sha" "$installer_command_sha"' 'strict remote installer-process validator call'
need_in_function validate_pre_mutation_remote_installer_process '(.parent_pid | type == "number" and . == floor and . >= 1 and . <= 4294967295)' 'installer parent PID uint32 contract'
need_exact_line_in_function validate_pre_mutation_remote_installer_process '    validate_windows_identity_scalar "$process" process_start_filetime_utc canonical-filetime' 'installer canonical FILETIME helper call'
need_exact_line_in_function validate_pre_mutation_remote_launcher_claim '    validate_windows_identity_scalar "$claim" session_id session-one' 'claim canonical integer session helper call'
need_exact_line_in_function validate_pre_mutation_windows_live_proof '    validate_windows_identity_scalar "$proof" viewflow_process.session_id session-one' 'live-proof canonical integer session helper call'
need_in_function validate_pre_mutation_windows_live_proof '.deployment_task.task_name == ("Viewflow Deployment " + $op) and' 'canonical live-proof deployment task name'
need_in_function capture_pre_mutation_windows_live_proof "deployment_task=[ordered]@{task_name='Viewflow Deployment __OP__'" 'canonical PowerShell live-proof task name publication'
need_in_function capture_pre_mutation_windows_live_proof 'windows_read_file "$windows_operation_root\launcher-installer-process.json" "$remote_process"' 'remote installer-process raw-byte readback'
need_in_function capture_pre_mutation_windows_live_proof 'windows_read_file "$windows_operation_root\installer.stdout.log" "$remote_stdout"' 'remote installer stdout raw-byte readback'
need_in_function capture_pre_mutation_windows_live_proof 'windows_read_file "$windows_operation_root\installer.stderr.log" "$remote_stderr"' 'remote installer stderr raw-byte readback'
need_in_function capture_pre_mutation_windows_live_proof '$principalSid=CS ([string]$task.Principal.UserId)' 'canonical scheduled-task SID'
need_in_function capture_pre_mutation_windows_live_proof 'OwnerProtectedFile $exe;OwnerProtectedFile $wrapperPath;OwnerProtectedFile $rollbackPath' 'installed Windows non-reparse ACL gate'
need_in_function capture_pre_mutation_windows_live_proof '$members.Count-ne$expected.Count' 'operation-root exact member set'
need_in_function capture_pre_mutation_windows_live_proof 'operation_root=[ordered]@{member_count=[int]$members.Count;directory_member_count=[int]$directoryMemberCount;acl_rule_count=[int]$rootRules.Count;owner_sid=$rootOwnerSid;access_rules_protected=[bool]$rootAcl.AreAccessRulesProtected;staged_file_acl_checks=[int]$expected.Count;installed_file_acl_checks=3}' 'measured operation-root and ACL counts in proof'
need_in_function capture_pre_mutation_windows_live_proof 'process_counts=[ordered]@{installer=[int]$installers.Count;viewflow=[int]$rows.Count}' 'measured process counts in proof'
need_in_function validate_pre_mutation_windows_live_proof '.operation_root.member_count == 14 and .operation_root.directory_member_count == 0 and' 'operation-root measured counts validation'
need_in_function validate_pre_mutation_windows_live_proof '.process_counts.installer == 0 and .process_counts.viewflow == 1 and' 'process measured counts validation'
need_in_function capture_pre_mutation_windows_live_proof 'old_rollback_sha256=$rollback' 'fresh old rollback receipt binding'
need_in_function validate_pre_mutation_windows_live_proof '.old_rollback_sha256 == $rollback' 'fresh old rollback validation'
need_in_function validate_pre_mutation_windows_live_proof '.local_committed_stop_sha256 == $local_stop and .remote_raw_stop_sha256 == $remote_stop and' 'local/remote stop hash distinction'
need_in_function validate_pre_mutation_windows_live_proof '.remote_raw_installer_exit_sha256 == $remote_exit and .transport_normalization == $transport and' 'remote raw exit hash and fixed normalization binding'
need_in_function capture_pre_mutation_windows_live_proof "transport_normalization='windows-openssh-terminal-lf-to-local-crlf-v1'" 'fixed stop transport normalization publication'
need_in_function validate_pre_mutation_windows_live_proof '.remote_launcher_claim_sha256 == $claim and .remote_installer_process_receipt_sha256 == $process and' 'remote claim/process proof validation'
need_in_function validate_pre_mutation_windows_live_proof '.installer_stdout_sha256 == $stdout and .installer_stderr_sha256 == $stderr and' 'remote installer log proof validation'
need_in_function make_and_validate_pre_mutation_abort_authorization '.old_windows_rollback_sha256 == $old_rollback' 'schema2 authorization old rollback binding'
need_in_function make_and_validate_pre_mutation_abort_authorization '.initial_force_release_executed == false and .rollback_performed == false' 'schema2 truthful false mutation/rollback claims'
need_in_function make_and_validate_pre_mutation_abort_authorization '.windows_rollback_receipt_sha256 == null and .protocol_2_1 == false' 'schema2 absent rollback receipt and v1.3 protocol'
need_in_function abort_pre_mutation_deployment_marker_transactionally 'run_pinned_executable marker-candidate "$pre_mutation_abort_marker_cli_candidate"' 'sealed candidate marker abort gate'
need_in_function abort_pre_mutation_deployment_marker_transactionally '"$pre_mutation_abort_marker_cli_sha" abort --operation-id "$operation_id"' 'sealed candidate abort argv'
need_in_function abort_pre_mutation_deployment_marker_transactionally 'validate_abort_receipt_v2 "$deployment_abort_receipt"' 'schema2 abort receipt decode'
if function_body abort_pre_mutation_deployment_marker_transactionally | grep -F 'marker "$MARKER_CLI"' >/dev/null; then fail 'pre-mutation abort executes installed old marker CLI'; fi
need_in_function validate_abort_receipt_v2 '.schema_version == 2' 'schema2 VFDQA JSON receipt'
need_in_function validate_abort_receipt_v2 '.rollback_performed == false' 'schema2 receipt rollback false'
need_in_function validate_abort_receipt_binary '[[ $(dd if="$durable" bs=8 count=1 status=none) == VFDQA001 ]]' 'shared binary VFDQA magic decode'
need_in_function failed_v13_pre_mutation_abort_main '    freeze_authenticated_v13_peer' 'fresh authenticated v1.3 peer gate'
need_in_function failed_v13_pre_mutation_abort_main '    make_and_validate_pre_mutation_abort_authorization' 'schema2 authorization publication'
need_in_function failed_v13_pre_mutation_abort_main '    abort_pre_mutation_deployment_marker_transactionally' 'independent schema2 abort transaction'
need_in_function failed_v13_pre_mutation_abort_main '    publish_pre_mutation_abort_terminal' 'schema2 terminal publication'
need_in_function start_and_freeze_windows_v13 'if((HB \$xmlBytes)-cne'\''$task'\''){throw '\''old task XML hash differs'\''}' 'live old scheduled-task XML hash comparison'
need_in_function start_and_freeze_windows_v13 "if((HB ([IO.File]::ReadAllBytes('C:\\\\Users\\\\wilf\\\\AppData\\\\Local\\\\Programs\\\\Viewflow\\\\viewflow-client.ps1')))-cne'\$wrapper')" 'PS5-safe live old wrapper hash comparison'
need_in_function start_and_freeze_windows_v13 'if(\$rows.Count-ne1){throw '\''exact old viewflow process not found'\''}' 'single exact old Windows daemon'
need_in_function start_and_freeze_windows_v13 'if(\$sid-cne'\''$windows_user_sid'\''-or[int]\$p.SessionId-ne1){throw '\''old process owner/session differs'\''}' 'old Windows daemon owner/session'
need_in_function exact_executable_pids '    return 0' 'zero-match PID enumeration success'
need_in_function validate_fd_gate_contract "\$(stat -c '%u:%g:%a:%h' -- \"\$FD_GATE_ENV\") == 0:0:755:1" 'root-owned immutable env identity'
need_in_function validate_fd_gate_contract '$(sha256 "$FD_GATE_ENV") == "$FD_GATE_ENV_SHA256"' 'env runtime hash equality'
need_in_function validate_fd_gate_contract "\$(stat -c '%u:%g:%a:%h' -- \"\$FD_GATE_PYTHON\") == 0:0:755:1" 'root-owned immutable Python identity'
need_in_function validate_fd_gate_contract '$(sha256 "$FD_GATE_PYTHON") == "$FD_GATE_PYTHON_SHA256"' 'Python runtime hash equality'
need_exact_line_in_function run_pinned_executable '    "$FD_GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \' 'empty startup environment gate'
need_in_function run_pinned_executable '"$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_PAYLOAD_SHA256" "$FD_GATE_PAYLOAD"' 'isolated FD-gate invocation'
need 'fd=os.open(target,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)' 'O_NOFOLLOW target open'
need 'if role=="marker" and (not target_argv or target_argv[0] not in {"abort","publish","query","release"}):' 'installed marker exact subcommand allowlist'
need 'if role=="marker-candidate" and (not target_argv or target_argv[0] not in {"abort","query"}):' 'candidate marker exact subcommand allowlist'
need 'st=os.fstat(fd)' 'opened-file metadata validation'
need 'if len(verified_bytes)!=st.st_size or hashlib.sha256(verified_bytes).hexdigest()!=expected_sha:' 'opened-byte digest validation'
need 'if verified_bytes[:4]!=b"\x7fELF":' 'ELF target validation'
need 'current=os.stat(target,follow_symlinks=False)' 'post-open path identity snapshot'
need 'exec_fd=os.memfd_create("viewflow-verified-elf",os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)' 'sealed-copy memfd creation'
need 'written=os.write(exec_fd,remaining)' 'complete memfd byte copy'
need 'os.fsync(exec_fd)' 'memfd flush before sealing'
need 'required_seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL' 'exact immutable seal set'
need 'fcntl.fcntl(exec_fd,fcntl.F_ADD_SEALS,required_seals)' 'seal publication'
need 'if fcntl.fcntl(exec_fd,fcntl.F_GET_SEALS)!=required_seals:' 'exact seal readback'
need 'os.close(fd)' 'mutable source FD closure'
need 'clean_env={"HOME":"/home/wilf"' 'clean recovery environment'
need 'os.closerange(3,exec_fd)' 'inherited low-FD closure'
need 'os.closerange(exec_fd+1,limit)' 'inherited high-FD closure'
need 'os.execve(f"/proc/self/fd/{exec_fd}",[target,*target_argv],clean_env)' 'sealed-FD-only target exec'
need 'readonly FD_GATE_BWRAP=/usr/bin/bwrap' 'fixed Bubblewrap runtime path'
need 'readonly FD_GATE_BWRAP_SHA256=7c44fa8e7326e62e81ab3f70ff682bfc0eb3b447b39cf9fbb779a31948364762' 'fixed Bubblewrap runtime hash'
need 'gui_fd=sealed(read_verified(target,expected_sha,uid,mode,links),"viewflow-verified-deskflow")' 'sealed Deskflow GUI bytes'
need 'core_fd=sealed(read_verified(core,core_sha,uid,mode,links),"viewflow-verified-deskflow-core")' 'sealed Deskflow core bytes'
need '"--tmpfs",staging' 'private Deskflow sibling mount point'
need '"--ro-bind-data",str(gui_fd),gui' 'private read-only Deskflow GUI mapping'
need '"--ro-bind-data",str(core_fd),sealed_core' 'private read-only Deskflow core mapping'
need '"--remount-ro",staging' 'read-only sibling directory'
need_in_function validate_fd_gate_contract '$(sha256 "$FD_GATE_BWRAP") == "$FD_GATE_BWRAP_SHA256"' 'Bubblewrap runtime identity check'
need_in_function validate_fd_gate_contract '$(printf '\''%s'\'' "$FD_GATE_DESKFLOW_PAYLOAD" | sha256sum' 'Deskflow payload identity check'
need_in_function start_pinned_v13_transient_unit '[[ -z $load_state || $load_state == not-found ]] ||' 'preoccupied transient-unit rejection'
need_in_function canonical_fd_gate_exec_start_sha "'{argv:\$ARGS.positional,ignore_errors:false,path:\$path}'" 'fixed canonical ExecStart schema'
need_in_function canonical_fd_gate_exec_start_sha '"$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_PAYLOAD_SHA256" "$FD_GATE_PAYLOAD"' 'canonical fixed gate argv'
need_in_function canonical_fd_gate_exec_start_sha '"$FD_GATE_DESKFLOW_PAYLOAD_SHA256" "$FD_GATE_DESKFLOW_PAYLOAD"' 'canonical sealed sibling gate argv'
need_in_function observed_transient_exec_start_sha 'busctl --user --json=short call org.freedesktop.systemd1' 'manager unit object query'
need_in_function observed_transient_exec_start_sha 'busctl --user --json=short get-property org.freedesktop.systemd1' 'manager ExecStart query'
need_in_function observed_transient_exec_start_sha '{argv:$value[1],ignore_errors:$value[2],path:$value[0]}' 'observed canonical ExecStart schema'
need_in_function start_pinned_v13_transient_unit 'expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")' 'pre-launch expected ExecStart hash'
need_in_function start_pinned_v13_transient_unit 'observed_exec_start_sha=$(observed_transient_exec_start_sha "$unit")' 'post-launch observed ExecStart hash'
need_in_function start_pinned_v13_transient_unit '[[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' 'manager/expected ExecStart equality'
exec_expected=$(function_line start_pinned_v13_transient_unit '    expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")')
exec_launch=$(first_function_line start_pinned_v13_transient_unit '        systemd-run --user --quiet --unit "$unit"')
exec_observed=$(function_line start_pinned_v13_transient_unit '    observed_exec_start_sha=$(observed_transient_exec_start_sha "$unit")')
exec_equal=$(function_line start_pinned_v13_transient_unit '    [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||')
((exec_expected < exec_launch && exec_launch < exec_observed && exec_observed < exec_equal)) || fail 'transient expected/launch/observed/equality ordering is unsafe'
need_in_function start_pinned_v13_transient_unit '--property Type=exec --property KillMode=control-group' 'exec-ready control-group transient unit'
[[ $(function_body start_pinned_v13_transient_unit | grep -Fc -- '--property Type=exec --property KillMode=control-group') == 2 ]] || fail 'both recovery transient units must be Type=exec/KillMode=control-group'
for loader_variable in LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH; do
    [[ $(function_body start_pinned_v13_transient_unit | grep -Fc -- "--setenv=${loader_variable}=") == 2 ]] || fail "both recovery transient units must clear $loader_variable"
done
if function_body start_pinned_v13_transient_unit | grep -F -- '--collect' >/dev/null; then fail 'recovery transient unit may be garbage-collected and reused'; fi
need_in_function abort_deployment_marker_transactionally 'marker_role=marker' 'installed abort marker role default'
need_in_function abort_deployment_marker_transactionally 'marker_executable=$MARKER_CLI' 'installed abort marker default'
need_in_function abort_deployment_marker_transactionally 'marker_role=marker-candidate' 'schema1-handoff candidate marker role'
need_in_function abort_deployment_marker_transactionally 'marker_executable=$schema1_handoff_abort_marker_cli_candidate' 'schema1-handoff candidate marker selection'
need_in_function abort_deployment_marker_transactionally '"$marker_role" "$marker_executable" "$marker_executable_sha" query' 'FD-gated abort replay query'
need_in_function abort_deployment_marker_transactionally '"$marker_role" "$marker_executable" "$marker_executable_sha" abort' 'FD-gated abort transaction'
if function_body abort_deployment_marker_transactionally | grep -E 'capture_json_command[^[:cntrl:]]*"\$MARKER_CLI"[[:space:]]+(query|abort)' >/dev/null; then fail 'abort marker CLI is executed by mutable pathname'; fi
need_in_function start_and_freeze_linux_v13 'start_pinned_v13_transient_unit viewflow "$v13_viewflow_unit" "$VIEWFLOW_INSTALLED" "$old_viewflow_sha" \' 'FD-gated Viewflow transient start'
need_in_function start_and_freeze_linux_v13 'load_state=$(systemctl --user show --property LoadState --value "$v13_viewflow_unit" 2>/dev/null || true)' 'restart adoption load-state observation'
need_in_function start_and_freeze_linux_v13 'expected_exec_start_sha=$(expected_viewflow_v13_exec_start_sha)' 'restart adoption expected ExecStart reconstruction'
need_in_function start_and_freeze_linux_v13 'observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_viewflow_unit")' 'restart adoption observed ExecStart reconstruction'
need_exact_line_in_function start_and_freeze_linux_v13 '        [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' 'restart adoption exact ExecStart equality'
need_in_function start_and_freeze_linux_v13 "die 'pre-existing Linux v1.3 transient unit differs from fixed gate argv'" 'restart adoption exact ExecStart rejection'
need_in_function start_and_freeze_linux_v13 'process_sha=$(sha256 "/proc/$pid/exe" 2>/dev/null)' 'gate-to-target process SHA wait'
need_exact_line_in_function start_and_freeze_linux_v13 '           [[ $process_sha == "$old_viewflow_sha" ]]; then' 'gate-to-target process SHA equality before readiness'
need_in_function start_and_freeze_linux_v13 '[[ $pid =~ ^[1-9][0-9]*$ && $process_sha == "$old_viewflow_sha" ]] ||' 'post-wait process identity rejection'
need_in_function failed_v13_abort_preflight 'assert_adoptable_linux_v13_without_receipt' 'receipt-less transient adoption preflight'
need_in_function assert_adoptable_linux_v13_without_receipt '$observed_exec_start_sha == "$expected_exec_start_sha"' 'receipt-less transient ExecStart equality'
need_in_function assert_adoptable_linux_v13_without_receipt '$(sha256 "/proc/$pid/exe") == "$old_viewflow_sha"' 'receipt-less transient executable equality'
need_in_function assert_adoptable_linux_v13_without_receipt '$control_group == "$process_cgroup"' 'receipt-less transient cgroup equality'
need_in_function assert_adoptable_linux_v13_without_receipt '$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == inactive' 'receipt-less persistent Viewflow exclusion'
need_in_function assert_adoptable_linux_v13_without_receipt '$viewflow_runtime_pids == "$pid"' 'receipt-less single Viewflow runtime equality'
need_in_function assert_adoptable_linux_v13_without_receipt '$udp_listener == *"pid=$pid,"*' 'receipt-less UDP owner equality'
need_in_function assert_adoptable_linux_v13_without_receipt '$sidecar_listener == *"pid=$pid,"*' 'receipt-less sidecar owner equality'
need_in_function start_and_freeze_linux_v13 '$expected_exec_start_sha == "$(expected_viewflow_v13_exec_start_sha)"' 'Viewflow pre-launch expected hash continuity'
need_in_function start_and_freeze_linux_v13 '$observed_exec_start_sha == "$expected_exec_start_sha"' 'Viewflow observed/expected hash equality'
need_in_function start_and_freeze_linux_v13 'expected_exec_start_sha256:$expected_exec_start,exec_start_sha256:$observed_exec_start' 'Viewflow expected/observed receipt freeze'
need_in_function validate_linux_v13_started 'expected_exec_start_sha=$(expected_viewflow_v13_exec_start_sha)' 'Viewflow expected hash reconstruction'
need_in_function validate_linux_v13_started 'observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_viewflow_unit")' 'Viewflow manager hash observation'
need_in_function validate_linux_v13_started '[[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||' 'Viewflow live manager/expected equality'
need_in_function validate_linux_v13_started '.exec_start_sha256 == $observed_exec_start and .exec_start_sha256 == .expected_exec_start_sha256' 'Viewflow receipt/live/expected equality'
need_exact_line_in_function validate_linux_v13_started '    assert_adoptable_linux_v13_without_receipt' 'existing receipt retains exact single-runtime adoption boundary'
need_in_function start_and_freeze_windows_v13 '\$enc=New-Object Text.UnicodeEncoding(\$false,\$true)' 'Windows task XML UTF-16LE encoding'
need_in_function start_and_freeze_windows_v13 '[Array]::Copy(\$pre,0,\$xmlBytes,0,\$pre.Length)' 'Windows task XML BOM preservation'
need_in_function start_and_freeze_windows_v13 'if [[ -e $windows_v13_started_receipt || -L $windows_v13_started_receipt ]]; then' 'durable Windows receipt resume branch'
need_exact_line_in_function start_and_freeze_windows_v13 '        validate_windows_v13_started' 'durable Windows receipt live reattestation call'
need_in_function validate_windows_v13_started "capture_json_command 'Windows v1.3 live reattestation' \"\$live\" ssh_windows \"\$command\"" 'existing Windows receipt live SSH reattestation'
need_in_function validate_windows_v13_started 'windows_v13_live_reattest_counter=$((${windows_v13_live_reattest_counter:-0} + 1))' 'unique same-run Windows reattestation counter'
need_in_function validate_windows_v13_started 'live=$secure_dir/windows-v13-live.${windows_v13_live_reattest_counter}.json' 'unique same-run Windows reattestation path'
need_in_function validate_windows_v13_started '\$rows.Count-ne1' 'exact one live Windows v1.3 process'
need_in_function validate_windows_v13_started '.pid == $receipt[0].pid and .process_start_filetime_utc == $receipt[0].process_start_filetime_utc' 'Windows receipt/live PID and start-time equality'
need_in_function freeze_authenticated_v13_peer 'grep -F "viewflowd server authenticated peer ${EXPECTED_WINDOWS_SOURCE_IP}:"' 'Windows source-IP authentication record'
need_in_function freeze_authenticated_v13_peer '[[ -n $fresh_probe && $fresh_probe != "$baseline_probe" ]] && break' 'post-boundary fresh peer probe'
need_in_function freeze_authenticated_v13_peer 'fresh_probe_record_sha256:$probe' 'fresh peer probe receipt binding'
need_in_function freeze_authenticated_v13_peer 'current_v13_peer_probe_sha=$fresh_probe_sha' 'current abort-entry probe capture'
need_in_function freeze_authenticated_v13_peer 'if [[ -e $authenticated_v13_peer_receipt || -L $authenticated_v13_peer_receipt ]]; then' 'durable authenticated receipt resume branch'
need_in_function freeze_authenticated_v13_peer '        validate_authenticated_v13_peer' 'durable authenticated receipt replay validation'
need_in_function validate_authenticated_v13_peer 'journal_record_sha_exists "$invocation" "viewflowd server authenticated peer ${peer_ip}:${peer_port}" "$authenticated_sha"' 'authenticated journal record replay validation'
need_in_function validate_authenticated_v13_peer 'journal_record_sha_exists "$invocation" "viewflowd server peer ${peer_ip}:${peer_port} probe=" "$probe_sha"' 'fresh probe journal record replay validation'
need_in_function make_and_validate_abort_authorization '[[ $current_v13_peer_probe_sha =~ ^[0-9a-f]{64}$ ]]' 'current abort-entry probe precondition'
if function_body make_and_validate_abort_authorization | grep -F 'fresh_entry_probe_record_sha256' >/dev/null; then fail 'abort authorization exceeds frozen marker CLI schema'; fi
if function_body start_and_freeze_linux_v13 | grep -F -- 'systemctl --user start "$VIEWFLOW_UNIT"' >/dev/null; then fail 'failed-v1.3 Viewflow uses mutable persistent unit'; fi
need_in_function validate_abort_receipt_v1 'keys == ["abort_authorization_path"' 'strict abort JSON receipt keys'
need_in_function validate_abort_receipt_v1 'expected_durable="/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.${published_marker_sha}.${authorization_sha}.v1"' 'content-addressed abort receipt path'
need_in_function validate_abort_receipt_v1 '== 0101010301000000' 'VFDQA001 exact header bytes'
need_in_function validate_abort_receipt_v1 'authorization_recorded=$(dd if="$durable" bs=1 skip=304 count=32' 'VFDQA001 authorization hash decode'
need_in_function validate_abort_receipt_v1 'committed=$(od -An -tu8 -j336 -N8 "$durable"' 'VFDQA001 commit-time decode'
need_exact_line_in_function abort_deployment_marker_transactionally '        validate_abort_receipt_v5 "$deployment_abort_receipt"' 'schema5 VFDQA001 validator call'
need_exact_line_in_function abort_deployment_marker_transactionally '        validate_abort_receipt_v1 "$deployment_abort_receipt"' 'legacy VFDQA001 validator call'
need_exact_line_in_function abort_deployment_marker_transactionally '    start_and_freeze_windows_v13' 'last live Windows identity snapshot'
need_exact_line_in_function abort_deployment_marker_transactionally '    validate_authenticated_v13_peer' 'last authenticated peer binding'
need_in_function abort_deployment_marker_transactionally '[[ ! -e $DEPLOYMENT_MARKER && ! -e ${DEPLOYMENT_MARKER}.abort-claim && ! -e ${DEPLOYMENT_MARKER}.release-claim ]]' 'abort point claim/marker absence'
if function_body abort_deployment_marker_transactionally | grep -Eq '(^|[[:space:]])release([[:space:]\\]|$)|VFDQR001'; then fail 'failed-v1.3 abort transaction contains normal release semantics'; fi
pre_auth=$(function_line failed_v13_pre_mutation_abort_main '    make_and_validate_pre_mutation_abort_authorization')
pre_abort=$(function_line failed_v13_pre_mutation_abort_main '    abort_pre_mutation_deployment_marker_transactionally')
pre_terminal=$(function_line failed_v13_pre_mutation_abort_main '    publish_pre_mutation_abort_terminal')
((pre_auth < pre_abort && pre_abort < pre_terminal)) || fail 'pre-mutation authorization/abort/terminal order is invalid'
pre_tx_linux=$(function_line abort_pre_mutation_deployment_marker_transactionally '    validate_linux_v13_started')
pre_tx_windows=$(function_line abort_pre_mutation_deployment_marker_transactionally '    validate_pre_mutation_windows_v13_started')
pre_tx_peer=$(function_line abort_pre_mutation_deployment_marker_transactionally '    validate_authenticated_v13_peer')
pre_tx_abort=$(first_function_line abort_pre_mutation_deployment_marker_transactionally "capture_json_command 'pre-mutation failed-v1.3 deployment abort receipt'")
((pre_tx_linux < pre_tx_windows && pre_tx_windows < pre_tx_peer && pre_tx_peer < pre_tx_abort)) ||
    fail 'pre-mutation final live reattestation does not precede marker abort'
abort_linux=$(first_function_line failed_v13_abort_main '    start_and_freeze_linux_v13')
abort_windows=$(first_function_line failed_v13_abort_main '    start_and_freeze_windows_v13')
abort_peer=$(function_line failed_v13_abort_main '    freeze_authenticated_v13_peer')
abort_authorize=$(function_line failed_v13_abort_main '    make_and_validate_abort_authorization')
abort_commit=$(function_line failed_v13_abort_main '    abort_deployment_marker_transactionally')
abort_reset=$(function_line failed_v13_abort_main '    reset_failed_deskflow_recovery_unit')
abort_deskflow=$(function_line failed_v13_abort_main '    start_pinned_v13_transient_unit deskflow "$v13_deskflow_unit" "$DESKFLOW_INSTALLED" "$old_deskflow_sha"')
((abort_linux < abort_windows && abort_windows < abort_peer && abort_peer < abort_authorize && abort_authorize < abort_commit && abort_commit < abort_reset && abort_reset < abort_deskflow)) || fail 'failed-v1.3 restart/auth/abort/Deskflow ordering is unsafe'
need_in_function reset_failed_deskflow_recovery_unit '$observed == "$(legacy_deskflow_v13_exec_start_sha)"' 'exact failed memfd unit adoption'
need_in_function reset_failed_deskflow_recovery_unit 'grep -Fq '\''FATAL: core server binary does not exist'\''' 'sibling-path failure journal proof'
need_in_function reset_failed_deskflow_recovery_unit 'systemctl --user reset-failed "$v13_deskflow_unit"' 'failed transient replacement'
need_in_function failed_v13_abort_main '$(sha256 "/proc/$bwrap_pid/exe") == "$FD_GATE_BWRAP_SHA256"' 'Bubblewrap MainPID identity'
need_in_function failed_v13_abort_main 'deskflow_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_sha")' 'sealed GUI cgroup/hash discovery'
need_in_function failed_v13_abort_main 'core_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_core_sha")' 'sealed core cgroup/hash discovery'
need_in_function failed_v13_abort_main '$deskflow_cgroup == "$deskflow_process_cgroup" && $deskflow_cgroup == "$core_cgroup"' 'Bubblewrap/Deskflow/core same transient cgroup'
need_in_function publish_pre_mutation_abort_terminal '$deskflow_cgroup == "$deskflow_process_cgroup" && $deskflow_cgroup == "$core_cgroup"' 'pre-mutation Bubblewrap/Deskflow/core same transient cgroup'
need_in_function failed_v13_abort_main 'process_descends_from "$deskflow_pid" "$bwrap_pid" ||' 'Deskflow GUI descendant proof'
need_in_function failed_v13_abort_main 'process_descends_from "$core_pid" "$deskflow_pid" ||' 'deskflow-core descendant proof'
need_in_function failed_v13_abort_main '$deskflow_expected_exec_start_sha == "$(expected_deskflow_v13_exec_start_sha)"' 'Deskflow pre-launch expected hash continuity'
need_in_function failed_v13_abort_main '$deskflow_observed_exec_start_sha == "$deskflow_expected_exec_start_sha"' 'Deskflow observed/expected hash equality'
need_in_function publish_pre_mutation_abort_terminal '$deskflow_observed_exec_start_sha == "$deskflow_expected_exec_start_sha"' 'pre-mutation Deskflow observed/expected hash equality'
need_in_function failed_v13_abort_main 'linux_deskflow_expected_exec_start_sha256:$deskflow_expected_exec_start' 'Deskflow expected ExecStart receipt binding'
need_in_function failed_v13_abort_main 'linux_deskflow_exec_start_sha256:$deskflow_observed_exec_start' 'Deskflow observed ExecStart receipt binding'
need_in_function failed_v13_abort_main 'fd_gate_payload_sha256:$gate' 'Deskflow FD-gate receipt binding'
need_in_function failed_v13_abort_main 'bubblewrap_sha256:$bwrap' 'Deskflow Bubblewrap receipt binding'
need_in_function failed_v13_abort_main 'sealed_sibling_directory_read_only:true' 'sealed sibling runtime receipt binding'
need_in_function failed_v13_abort_main 'linux_deskflow_main_pid:$bwrap_pid' 'Bubblewrap systemd MainPID receipt binding'
need_in_function failed_v13_abort_main 'linux_deskflow_runtime_pid:$deskflow_pid' 'Deskflow GUI runtime PID receipt binding'
need_in_function validate_live_deskflow_recovery_tuple '$(cgroup_executable_sha_pids "$unit" "$FD_GATE_BWRAP_SHA256") == "$bwrap_pid"' 'final exact Bubblewrap cgroup census'
need_in_function validate_live_deskflow_recovery_tuple '$(cgroup_executable_sha_pids "$unit" "$old_deskflow_sha") == "$deskflow_pid"' 'final exact Deskflow GUI cgroup census'
need_in_function validate_live_deskflow_recovery_tuple '$(cgroup_executable_sha_pids "$unit" "$old_deskflow_core_sha") == "$core_pid"' 'final exact deskflow-core cgroup census'
need_in_function validate_live_deskflow_recovery_tuple '$(sha256 "$coordinator_state") == "$state_sha"' 'final old-state identity check'
need_in_function validate_live_deskflow_recovery_tuple 'process_descends_from "$deskflow_pid" "$bwrap_pid"' 'final Deskflow ancestry check'
need_in_function validate_live_deskflow_recovery_tuple 'process_descends_from "$core_pid" "$deskflow_pid"' 'final core ancestry check'
final_deskflow_revalidation=$(function_line failed_v13_abort_main '    validate_live_deskflow_recovery_tuple "$v13_deskflow_unit"')
terminal_receipt_publish=$(function_line failed_v13_abort_main "    publish_recovery_json_once 'failed-v1.3 abort terminal transition'")
((final_deskflow_revalidation < terminal_receipt_publish)) || fail 'Deskflow tuple is not revalidated immediately before terminal publication'
if function_body failed_v13_abort_main | grep -F -- 'systemctl --user start "$DESKFLOW_UNIT"' >/dev/null; then fail 'failed-v1.3 Deskflow uses mutable persistent unit'; fi
need '&& $resume == 0' 'resume no Start'; need '-Mode Status -RequestPath' 'resume Status'; need 'windows_create_or_verify' 'remote reconcile'; need 'phase_rank' 'monotonic phase'; need 'explicit --resume is required' 'resume gate'
need 'viewflow-windows-bootstrap-absent' 'resume Start requires exact absent status'; need 'first dispatch after proven-absent resume' 'proven-absent first dispatch'
need '-Mode Stop -RequestPath' 'exact Stop'; need '(.installer_process_count | type == "number" and . == floor and . == 0)' 'canonical zero installer count'; need 'viewflow-windows-bootstrap-stopped' 'Stop evidence'; need '.task_state == "Disabled"' 'task disabled'
need 'rollback_linux_two_phase || finish_recovery "$RECOVERY_FAILURE_EXIT"' 'Linux rollback'; need 'run_windows_rollback || finish_recovery "$RECOVERY_FAILURE_EXIT"' 'Windows rollback'; need 'republish_deployment_marker_for_recovery || finish_recovery "$RECOVERY_FAILURE_EXIT"' 'requarantine'
need 'runtime_recovery_state=retained' 'retained runtime'; need 'runtime_recovery_state=cleaned' 'cleaned runtime'; need 'runtime_recovery_state=pre_release' 'pre-release runtime'
need '.disconnect_during_active_route == "not_exercised_destructive"' 'destructive active-route disconnect exclusion'
# These are body-level guards, rather than token checks: a stale string after an
# early return, a moved durable intent, or a commented PowerShell proof must not
# make a safety check appear present.
need_in_function validate_frozen_linux_B "    assert_strict_json_document 'Linux frozen B' \"\$bootstrap_linux_evidence\"" 'strict frozen evidence input'
need_in_function validate_frozen_linux_B "    jq -e --arg op \"\$operation_id\" '" 'frozen evidence schema validation'
need_in_function validate_frozen_linux_B "    ' \"\$bootstrap_linux_evidence\" >/dev/null || die 'Linux frozen evidence B is invalid'" 'frozen evidence rejection'
if function_body validate_frozen_linux_B | grep -Eq '^[[:space:]]*(return|exit)[[:space:]]'; then fail 'frozen evidence validator can return before rejecting invalid evidence'; fi
need_pattern_in_function main '^[[:space:]]*validate_frozen_linux_B[[:space:]]*$' 'unconditional frozen evidence validation call'
need_in_function publish_new_file 'ln -- "$1" "$2";' 'hard-link-only no-clobber publish primitive'
need_in_function publish_json_file '    temp=$(mktemp --tmpdir="$(dirname -- "$destination")" '\''.viewflow-publish.XXXXXX'\'')' 'destination-filesystem publish temp'
need_in_function publish_json_file '    dd if="$source" of="$temp" status=none' 'publish byte copy'
need_in_function publish_json_file '    sync -f "$temp"' 'publish temp fsync'
need_in_function publish_json_file '    publish_new_file "$temp" "$destination"' 'hard-link publish'
publish_temp=$(function_line publish_json_file '    temp=$(mktemp --tmpdir="$(dirname -- "$destination")" '\''.viewflow-publish.XXXXXX'\'')')
publish_copy=$(function_line publish_json_file '    dd if="$source" of="$temp" status=none')
publish_sync=$(function_line publish_json_file '    sync -f "$temp"')
publish_link=$(function_line publish_json_file '    publish_new_file "$temp" "$destination"')
((publish_temp < publish_copy && publish_copy < publish_sync && publish_sync < publish_link)) || fail 'publish JSON is not copied/synced/hard-linked in order'
need_in_function remote_prepare_and_start_once 'if(!(Test-Path -LiteralPath \$root)){[void](New-Item -ItemType Directory -Path \$root -ErrorAction Stop)}' 'PowerShell operation-root creation without cmd pipe'
need_in_function ssh_windows '    encoded=$(printf '\''%s'\'' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)' 'UTF-16LE encoded PowerShell transport'
need_in_function ssh_windows '    ssh -F /dev/null -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" "$WINDOWS_SSH_TARGET" \' 'SSH ignores unusable bwrap-mapped system config'
need_in_function ssh_windows '        powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded"' 'PowerShell encoded-command transport with process-scoped policy for reviewed scripts'
need_in_function ssh_windows_stdin '    payload=$(printf '\''%s'\'' "$1" | base64 -w0)' 'UTF-8 source encoded outside PowerShell argv'
need_in_function ssh_windows_stdin "FromBase64String('\$payload')" 'single-line bootstrap decodes reviewed source'
need_in_function ssh_windows_stdin '[Console]::SetOut(\$buffer);try{' 'stdout is buffered before reviewed source executes'
need_in_function ssh_windows_stdin '\$values=@(&([ScriptBlock]::Create(\$source)))' 'pipeline output is transactionally buffered'
need_in_function ssh_windows_stdin 'catch{[Console]::SetOut(\$priorOut);[Console]::Error.WriteLine(\$_.Exception.Message);exit 1}' 'exception discards stdout and fails closed'
need_in_function ssh_windows_stdin '    printf '\''%s'\'' "$bootstrap" | ssh -F /dev/null -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" "$WINDOWS_SSH_TARGET" \' 'only one bootstrap line reaches PowerShell stdin'
need_in_function ssh_windows_stdin '        powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -' 'PowerShell stdin command mode'
need_in_function reopen_pre_mutation_stop_intent 'capture_json_command '\''pre-mutation retry live proof'\'' "$live" ssh_windows_stdin "$command"' 'long pre-mutation proof uses stdin transport'
need_exact_line_in_function capture_pre_mutation_windows_live_proof '    capture_json_command '\''fresh pre-mutation Windows old-live proof'\'' "$live" ssh_windows_stdin "$command"' 'fresh long Windows proof uses stdin transport'
need_in_function reopen_pre_mutation_stop_intent 'capture_json_command '\''pre-mutation launcher status'\'' "$status" ssh_windows \' 'short launcher status remains encoded transport'
need_in_function windows_read_file '[Console]::Out.Write([Convert]::ToBase64String([IO.File]::ReadAllBytes(\$p)))' 'newline-free Windows Base64 response'
need_in_function windows_read_file '    [[ $encoded =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] ||' 'strict canonical Base64 character and padding validation'
need_in_function windows_read_file '    if ! printf '\''%s'\'' "$encoded" | base64 --decode >"$temp"; then' 'strict Windows Base64 decode'
need_in_function windows_read_file '    canonical=$(base64 -w0 -- "$temp")' 'canonical Base64 re-encode'
need_in_function windows_read_file '    [[ $canonical == "$encoded" ]] || {' 'canonical Base64 equality'
windows_read_remote=$(function_line windows_read_file '[Console]::Out.Write([Convert]::ToBase64String([IO.File]::ReadAllBytes(\$p)))')
windows_read_validate=$(function_line windows_read_file '    [[ $encoded =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] ||')
windows_read_decode=$(function_line windows_read_file '    if ! printf '\''%s'\'' "$encoded" | base64 --decode >"$temp"; then')
windows_read_canonical=$(function_line windows_read_file '    canonical=$(base64 -w0 -- "$temp")')
windows_read_compare=$(function_line windows_read_file '    [[ $canonical == "$encoded" ]] || {')
windows_read_publish=$(function_line windows_read_file '    publish_new_file "$temp" "$destination"')
((windows_read_remote < windows_read_validate && windows_read_validate < windows_read_decode && windows_read_decode < windows_read_canonical && windows_read_canonical < windows_read_compare && windows_read_compare < windows_read_publish)) || fail 'Windows Base64 response is not validated/canonicalized before publication'
need_in_function windows_create_or_verify '[Console]::Out.Write((Get-FileHash -LiteralPath '\''$remote'\'' -Algorithm SHA256).Hash.ToLowerInvariant())' 'newline-free remote staged hash'
need_in_function windows_create_or_verify '        require_sha256 "remote staged input hash $remote" "$remote_hash"' 'strict lowercase remote staged hash'
need_in_function windows_create_or_verify '        [[ $remote_hash == "$expected" ]] ||' 'remote staged hash equality'
verify_remote_hash=$(function_line windows_create_or_verify '[Console]::Out.Write((Get-FileHash -LiteralPath '\''$remote'\'' -Algorithm SHA256).Hash.ToLowerInvariant())')
verify_hash_format=$(function_line windows_create_or_verify '        require_sha256 "remote staged input hash $remote" "$remote_hash"')
verify_hash_match=$(function_line windows_create_or_verify '        [[ $remote_hash == "$expected" ]] ||')
((verify_remote_hash < verify_hash_format && verify_hash_format < verify_hash_match)) || fail 'remote staged hash is not validated before equality comparison'
need_in_function prearm_windows_recovery '[Console]::Out.Write((Get-FileHash -LiteralPath '\''$WINDOWS_ROLLBACK_SCRIPT'\'' -Algorithm SHA256).Hash.ToLowerInvariant())' 'newline-free remote rollback hash'
need_in_function prearm_windows_recovery '    require_sha256 '\''remote rollback consumer hash'\'' "$remote_hash"' 'strict lowercase remote rollback hash'
need_in_function prearm_windows_recovery '    [[ $remote_hash == "$local_hash" ]] || die '\''remote rollback consumer differs from reviewed local bytes'\''' 'remote rollback hash equality'
need_in_function prearm_windows_recovery '    if windows_remote_exists "$windows_rollback_receipt_path"; then' 'terminal rollback receipt selects consumed token'
need_in_function prearm_windows_recovery '        expected_consumed_token_path="${windows_rollback_token_path%.json}.consumed.${operation_id}.json"' 'terminal rollback consumed-token derivation'
need_in_function prearm_windows_recovery '        windows_remote_exists "$windows_rollback_token_path" &&' 'terminal rollback rejects unconsumed original token'
need_in_function prearm_windows_recovery '        windows_read_file "$expected_consumed_token_path" "$remote_token_snapshot"' 'terminal rollback reads exact consumed token'
need_in_function prearm_windows_recovery '        windows_read_file "$windows_rollback_token_path" "$remote_token_snapshot"' 'nonterminal rollback reads original token'
need_in_function prearm_windows_recovery '    validate_rollback_snapshots' 'rollback snapshot validation after token selection'
prearm_remote_hash=$(function_line prearm_windows_recovery '[Console]::Out.Write((Get-FileHash -LiteralPath '\''$WINDOWS_ROLLBACK_SCRIPT'\'' -Algorithm SHA256).Hash.ToLowerInvariant())')
prearm_hash_format=$(function_line prearm_windows_recovery '    require_sha256 '\''remote rollback consumer hash'\'' "$remote_hash"')
prearm_hash_match=$(function_line prearm_windows_recovery '    [[ $remote_hash == "$local_hash" ]] || die '\''remote rollback consumer differs from reviewed local bytes'\''')
((prearm_remote_hash < prearm_hash_format && prearm_hash_format < prearm_hash_match)) || fail 'remote rollback hash is not validated before equality comparison'
prearm_terminal=$(function_line prearm_windows_recovery '    if windows_remote_exists "$windows_rollback_receipt_path"; then')
prearm_consumed_name=$(function_line prearm_windows_recovery '        expected_consumed_token_path="${windows_rollback_token_path%.json}.consumed.${operation_id}.json"')
prearm_original_absent=$(function_line prearm_windows_recovery '        windows_remote_exists "$windows_rollback_token_path" &&')
prearm_consumed_read=$(function_line prearm_windows_recovery '        windows_read_file "$expected_consumed_token_path" "$remote_token_snapshot"')
prearm_else=$(function_line prearm_windows_recovery '    else')
prearm_original_read=$(function_line prearm_windows_recovery '        windows_read_file "$windows_rollback_token_path" "$remote_token_snapshot"')
prearm_validate_snapshots=$(function_line prearm_windows_recovery '    validate_rollback_snapshots')
((prearm_terminal < prearm_consumed_name && prearm_consumed_name < prearm_original_absent && prearm_original_absent < prearm_consumed_read && prearm_consumed_read < prearm_else && prearm_else < prearm_original_read && prearm_original_read < prearm_validate_snapshots)) || fail 'rollback token selection is not terminal-consumed/nonterminal-original before unified validation'
need_in_function windows_create_file '    scp -F /dev/null -q -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" -- "$source"' 'SCP upload ignores unusable bwrap-mapped system config'
need_in_function windows_create_file 'Get-FileHash -LiteralPath \$tmp -Algorithm SHA256' 'remote upload hash calculation'
need_in_function windows_create_file "throw 'Viewflow upload hash mismatch'" 'remote upload hash validation'
need_in_function windows_create_file '\$acl.SetOwner(\$sid);\$acl.SetAccessRuleProtection(\$true,\$false)' 'owner-only protected upload ACL'
need_in_function windows_create_file 'Set-Acl -LiteralPath \$tmp -AclObject \$acl;[IO.File]::Move(\$tmp,\$dest)' 'ACL-before-publish ordering'
need_in_function windows_create_file '[IO.File]::Move(\$tmp,\$dest)' 'no-replace remote publish'
need_in_function windows_create_file 'finally{if(Test-Path -LiteralPath \$tmp){Remove-Item -LiteralPath \$tmp -Force}}' 'temporary upload cleanup'
need_in_function bootstrap_preflight '    for label in base64 bash date dd iconv jq journalctl ln mktemp mv od python3 readlink scp sha256sum ssh ss stat sync systemctl unlink; do' 'python/iconv/scp/unlink preflight dependency'
need_in_function wait_remote_receipt '        if windows_remote_exists "$remote"; then sync_remote_receipt "$label" "$remote" "$local_path"; return; fi' 'requested remote receipt wait'
need_in_function wait_remote_receipt '        if [[ $remote != "$windows_exit_path" ]] && windows_remote_exists "$windows_exit_path"; then' 'early terminal receipt excludes terminal self-wait'
need_in_function wait_remote_receipt "            sync_remote_receipt 'Windows installer early exit' \"\$windows_exit_path\" \\" 'early terminal receipt synchronization'
need_in_function wait_remote_receipt '            validate_windows_terminal_exit' 'early terminal receipt validation'
need_in_function wait_remote_receipt '            die "Windows installer terminated before $label"' 'early terminal receipt fail-closed'
wait_requested=$(function_line wait_remote_receipt '        if windows_remote_exists "$remote"; then sync_remote_receipt "$label" "$remote" "$local_path"; return; fi')
wait_early_exit=$(function_line wait_remote_receipt '        if [[ $remote != "$windows_exit_path" ]] && windows_remote_exists "$windows_exit_path"; then')
wait_early_sync=$(function_line wait_remote_receipt "            sync_remote_receipt 'Windows installer early exit' \"\$windows_exit_path\" \\")
wait_early_validate=$(function_line wait_remote_receipt '            validate_windows_terminal_exit')
wait_early_die=$(function_line wait_remote_receipt '            die "Windows installer terminated before $label"')
((wait_requested < wait_early_exit && wait_early_exit < wait_early_sync && wait_early_sync < wait_early_validate && wait_early_validate < wait_early_die)) || fail 'early terminal receipt is not synced/validated/failed in order'
preflight_phase=$(function_line bootstrap_preflight "        phase=\$(jq -er --arg op \"\$operation_id\" 'select(.schema_version == 2 and .state == \"viewflow-cross-host-bootstrap\" and .operation_id == \$op) | .phase' \"\$coordinator_state\")")
preflight_contract=$(function_body bootstrap_preflight | grep -nFx -- '        validate_state_contract "$coordinator_state"' | cut -d: -f1)
[[ $preflight_contract =~ ^[0-9]+$ ]] || fail 'bootstrap_preflight missing/duplicate exact normal state-contract call'
((preflight_phase < preflight_contract)) || fail 'resume state contract is not validated after phase restoration'
need_pattern_in_function bootstrap_preflight '^[[:space:]]*validate_state_contract "\$coordinator_state"[[:space:]]*$' 'unconditional normal resume state-contract validation call'
permit_intent=$(function_line publish_mutation_permit '    commit_phase WINDOWS_PERMIT_PUBLISH_INTENT')
permit_upload=$(function_line publish_mutation_permit '    windows_create_or_verify "$windows_mutation_permit" "$windows_permit_path"')
((permit_intent < permit_upload)) || fail 'mutation permit upload lacks prior durable intent'
release_validate=$(function_line release_deployment_marker_transactionally '    validate_release_receipt_v2 "$deployment_release_receipt"')
release_unquarantine=$(function_line release_deployment_marker_transactionally '    [[ ! -e $DEPLOYMENT_MARKER && ! -e ${DEPLOYMENT_MARKER}.release-claim ]] ||')
release_commit=$(function_line release_deployment_marker_transactionally '    commit_phase MARKER_RELEASED')
((release_validate < release_unquarantine && release_unquarantine < release_commit)) || fail 'release receipt validation/order is unsafe'
need_pattern_in_function release_deployment_marker_transactionally '^[[:space:]]*validate_release_receipt_v2 "\$deployment_release_receipt"[[:space:]]*$' 'unconditional VFDQR001 validator call'
need_pattern_in_function restart_windows_peer_after_cleanup ';\$xml=Export-ScheduledTask .*;if\(\(HashBytes \$xmlBytes\)-cne\$expectedTaskSha\)\{throw "scheduled task XML hash is invalid"\}' 'live scheduled-task XML hash comparison'
# Frozen phase-aware resume/recovery contract.  These checks deliberately bind
# executable branches, not a former linear main() transcript.
need_in_function commit_phase '            (.committed_artifacts // {}) as $old |' 'append-only committed-artifact base'
need_in_function commit_phase '            if (all($old | to_entries[]; $committed[.key] == .value) and' 'commit-time revalidation of every prior artifact'
need_in_function commit_phase '                   . as $item | ((($old | has($item.key)) | not) or $old[$item.key] == $item.value)' 'append-only overlap equality'
need_in_function commit_phase '                    ($old; if has($item.key) then . else .[$item.key] = $item.value end)' 'append-only artifact merge'
need_in_function commit_phase '            --arg mutation "$recovery_mutation_possible" --argjson committed "$committed"' 'string mutation input for boolean conversion'
need_in_function commit_phase '                                 mutation_possible:($mutation == "1" or $mutation == "true")' 'new state mutation JSON boolean'
need_in_function commit_phase '                    .recovery.mutation_possible = ($mutation == "1" or $mutation == "true")' 'existing state mutation JSON boolean'
need_in_function recover_both_hosts '        recovery_mutation_possible=$(jq -r '\''.recovery.mutation_possible'\'' "$coordinator_state")' 'durable false-compatible recovery mutation read'
need_in_function recover_both_hosts '        case $recovery_mutation_possible in' 'recovery mutation compatibility case'
need_pattern_in_function recover_both_hosts '^[[:space:]]*true\|1\)[[:space:]]+recovery_mutation_possible=1[[:space:]]*;;' 'true or numeric-one recovery mutation compatibility'
need_pattern_in_function recover_both_hosts '^[[:space:]]*false\|0\)[[:space:]]+recovery_mutation_possible=0[[:space:]]*;;' 'false or numeric-zero recovery mutation compatibility'
need_in_function stop_exact_windows_bootstrap '        "& '\''$windows_launcher_path'\'' -Mode Status -RequestPath '\''$windows_request_path'\''" || return' 'pre-stop status failure propagation'
need_in_function stop_exact_windows_bootstrap '            "& '\''$windows_launcher_path'\'' -Mode Stop -RequestPath '\''$windows_request_path'\''" || return' 'stop failure propagation'
need_in_function remote_prepare_and_start_once 'local command response=$secure_dir/launcher.json resumed_start=$secure_dir/launcher-resumed-start.json' 'owner-only launcher capture destinations'
need_in_function stop_exact_windows_bootstrap 'local status=$secure_dir/windows-stop-status.json evidence=$secure_dir/windows-stop-evidence.json' 'owner-only recovery capture destinations'
need_in_function recover_both_hosts '    trap - ERR INT TERM EXIT' 'single-shot recovery trap disarm'
need_in_function recover_both_hosts '    ((recovery_running == 0 && recovery_finished == 0)) || finish_recovery "$RECOVERY_FAILURE_EXIT"' 'double recovery rejection'
need_in_function finish_recovery '    recovery_required=0' 'recovery disarm before exit'
need_in_function finish_recovery '    recovery_finished=1' 'durable in-process recovery completion'
need_in_function finish_recovery '    cleanup_secure_dir' 'recovery secure-directory cleanup'
need_in_function cleanup_secure_dir "    secure_dir=''" 'secure-directory lifecycle reset'
need 'readonly PRE_MUTATION_THREAT_BOUNDARY=cooperating-crash-and-non-owner' 'explicit same-uid deployment-authority threat boundary'
need_in_function validate_pre_mutation_stop_state_baseline 'fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL' 'exact sealed-memfd baseline contract'
need_in_function validate_pre_mutation_stop_state_baseline 'immutable=(st.st_nlink==0 and seals==required)' 'sealed-memfd seal equality'
need_in_function validate_pre_mutation_stop_state_baseline 'os.statvfs(p).f_flag & os.ST_RDONLY' 'fixed gate path read-only mount contract'
need_in_function validate_pre_mutation_stop_state_baseline 'hashlib.sha256(data).hexdigest()==expected' 'baseline byte hash binding'
need_in_function validate_pre_mutation_stop_state_baseline '(.committed_artifacts | keys) == ["bootstrap_request","linux_frozen","marker_handoff","publish_receipt"]' 'sealed baseline exact committed set'
need_in_function reopen_pre_mutation_stop_intent '    validate_pre_mutation_stop_state_baseline' 'fresh sealed baseline validation'
need_in_function reopen_pre_mutation_stop_intent '        '"'"' "$pre_mutation_stop_state_baseline_path" >/dev/null ||' 'STOP authorization reads sealed baseline'
need_in_function render_pre_mutation_start_state '    '"'"' "$pre_mutation_stop_state_baseline_path"' 'START state constructed from sealed baseline'
need_in_function render_pre_mutation_start_state '($committed | keys) == ["bootstrap_request","linux_frozen","marker_handoff","pre_mutation_retry","publish_receipt"]' 'legacy pre-mutation reopened committed-artifact exact set'
need_in_function render_pre_mutation_start_state '"candidate_retirement_terminal","candidate_tree","linux_frozen","marker_handoff"' 'replacement pre-mutation reopened committed-artifact exact set'
need_in_function render_pre_mutation_start_state 'pre_mutation_stop_history:{phase:"STOP_INTENT",failure_phase:"WINDOWS_START_INTENT"' 'append-only failed recovery history'
need_in_function publish_pre_mutation_start_state_cas '        ln -- "$coordinator_state" "$pre_mutation_stop_state_claim" || die '"'"'cannot create STOP_INTENT state claim'"'"'' 'old canonical hard-link claim'
need_in_function publish_pre_mutation_start_state_cas '            [[ $claim_identity == "$canonical_identity" &&' 'old canonical inode CAS check'
need_in_function publish_pre_mutation_start_state_cas '            unlink -- "$coordinator_state"' 'old canonical unlink transition'
need_in_function publish_pre_mutation_start_state_cas '        ln -- "$pre_mutation_start_state_candidate" "$coordinator_state" ||' 'START state no-clobber hard-link publication'
need_in_function publish_pre_mutation_start_state_cas '    [[ $candidate_identity == "$canonical_identity" &&' 'published candidate inode identity'
need_in_function reopen_pre_mutation_stop_intent 'capture_json_command '\''pre-mutation launcher status'\'' "$status" ssh_windows' 'fresh launcher absence observation'
need_in_function reopen_pre_mutation_stop_intent 'capture_json_command '\''pre-mutation retry live proof'\'' "$live" ssh_windows_stdin "$command"' 'fresh remote identity proof'
need_in_function reopen_pre_mutation_stop_intent 'AssertAcl \$root \$true' 'exact protected operation-root ACL'
need_in_function reopen_pre_mutation_stop_intent 'AssertAcl \$path \$false' 'exact protected staged-file ACL'
need_in_function reopen_pre_mutation_stop_intent "\$proc.ProcessId-ne\$pre_mutation_old_process_id" 'exact old process ID gate'
need_in_function reopen_pre_mutation_stop_intent "\$proc.ParentProcessId-ne\$pre_mutation_old_parent_process_id" 'exact old parent process ID gate'
need_in_function reopen_pre_mutation_stop_intent "\$creationUtc-ne'\$pre_mutation_old_process_creation_date'" 'exact old process creation gate'
need_in_function reopen_pre_mutation_stop_intent '\$proc=\$procs[0];\$creationUtc=\$proc.CreationDate.ToUniversalTime().ToString' 'direct canonical UTC process-tuple construction'
need_in_function reopen_pre_mutation_stop_intent 'creation_date=\$creationUtc;' 'canonical UTC proof serialization'
if function_body reopen_pre_mutation_stop_intent | grep -Fq -- 'command=${command/'; then
    fail 'pre-mutation proof relies on fallible Bash pattern replacement'
fi
if function_body reopen_pre_mutation_stop_intent | grep -Fq -- 'creation_date=[string]\$proc.CreationDate'; then
    fail 'pre-mutation proof serializes a localized creation date'
fi
need_in_function remote_prepare_and_start_once '                reopen_pre_mutation_stop_intent || return' 'fresh pre-start identity reattestation with failure propagation'
need_in_function remote_prepare_and_start_once '            if ((pre_mutation_retry_active)); then' 'sealed-baseline retry activation gate'
need_in_function main '    if [[ $phase == STOP_INTENT && $resume_pre_mutation_stop_intent == 1 ]]; then' 'explicit pre-mutation retry dispatch'
need_in_function main '    if [[ $(phase_rank "$phase") -ge $(phase_rank STOP_INTENT) && $pre_mutation_retry_active == 0 ]]; then' 'special retry bypasses destructive recovery'
need_in_function bootstrap_preflight '            publish_pre_mutation_start_state_cas' 'crash-replay CAS adoption'
need_in_function bootstrap_preflight '                die '"'"'absent canonical state lacks the exact pre-mutation CAS recovery set'"'"'' 'absent-canonical fail closed'
need_in_function assert_marker_cli_identity '$(stat -c '"'"'%u:%a:%h'"'"' -- "$MARKER_CLI") == 1000:755:1' 'marker CLI owner/mode/link metadata'
need_in_function assert_marker_cli_identity '$(sha256 "$MARKER_CLI") == "$deployment_marker_sha"' 'installed marker CLI exact SHA'
need_in_function marker_cli '    assert_marker_cli_identity || return' 'marker execution identity gate'
need_exact_line_in_function marker_cli '    run_pinned_executable marker "$MARKER_CLI" "$deployment_marker_sha" "$@"' 'normal marker sealed-memfd execution'
if function_body marker_cli | grep -Fx -- '    "$MARKER_CLI" "$@"' >/dev/null; then fail 'normal marker uses mutable direct-path execution'; fi
need_in_function reconcile_deployment_marker_phase 'capture_json_command '"'"'active deployment marker transaction query'"'"' "$query" marker_cli query' 'active marker transactional query'
need_in_function reconcile_deployment_marker_phase '       [[ $phase == STOP_INTENT && $resume_pre_mutation_stop_intent == 1 ]] ||' 'special STOP_INTENT active-marker branch'
need_in_function reconcile_deployment_marker_phase '    if ((pre_mutation_retry_active)) ||' 'reopened START_INTENT active-marker branch'
need_in_function reconcile_deployment_marker_phase '.state == "deployment-quarantine-active"' 'active marker query state validation'
need_in_function reconcile_deployment_marker_phase 'query=$secure_dir/marker-phase-query.$marker_phase_query_counter.json' 'no-clobber marker query capture path'
need_in_function publish_mutation_permit '    reconcile_deployment_marker_phase' 'marker transaction recheck around permit'
need_in_function main '        reconcile_deployment_marker_phase' 'marker transaction recheck before Linux stage'
permit_marker_first=$(first_function_line publish_mutation_permit '    reconcile_deployment_marker_phase')
permit_marker_last=$(function_body publish_mutation_permit | grep -nF -- '    reconcile_deployment_marker_phase' | tail -n1 | cut -d: -f1)
permit_marker_count=$(function_body publish_mutation_permit | grep -Fc -- '    reconcile_deployment_marker_phase')
permit_commit=$(function_line publish_mutation_permit '    commit_phase WINDOWS_PERMIT_PUBLISH_INTENT')
permit_upload=$(function_line publish_mutation_permit '    windows_create_or_verify "$windows_mutation_permit" "$windows_permit_path"')
[[ $permit_marker_count == 2 && $permit_marker_last =~ ^[0-9]+$ ]] || fail 'permit lacks exactly two marker transaction attestations'
((permit_marker_first < permit_marker_last && permit_marker_last < permit_commit && permit_commit < permit_upload)) ||
    fail 'permit marker reattestation/intent/upload ordering is unsafe'
stage_force=$(function_line main '    commit_phase WINDOWS_FORCE_ATTESTED')
stage_marker=$(function_body main | grep -nF -- '        reconcile_deployment_marker_phase' | tail -n1 | cut -d: -f1)
stage_assert=$(function_body main | grep -nF -- '        assert_deployment_marker' | head -n1 | cut -d: -f1)
stage_run=$(function_line main '        run_linux_stage')
[[ $stage_marker =~ ^[0-9]+$ && $stage_assert =~ ^[0-9]+$ ]] || fail 'Linux stage marker gate anchors are missing'
((stage_force < stage_marker && stage_marker < stage_assert && stage_assert < stage_run)) ||
    fail 'Linux stage admission is not immediately preceded by marker transaction/byte attestation'
need_in_function main '    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_STAGED) && -e $linux_stage_receipt ]]; then' 'Ls receipt-first adoption gate'
need_in_function main '        validate_existing_linux_stage' 'Ls receipt validation adoption'
need_in_function main '        windows_create_or_verify "$linux_stage_receipt" "$windows_stage_path"' 'Ls remote receipt adoption'
need_in_function main '        commit_phase LINUX_STAGED' 'Ls durable adoption phase'
need_in_function main '    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_FINALIZED_MARKER_HELD) && -e $linux_finalize_receipt ]]; then' 'Lf receipt-first adoption gate'
need_in_function main '        validate_existing_linux_finalize' 'Lf receipt validation adoption'
need_in_function main '        commit_phase LINUX_FINALIZED_MARKER_HELD' 'Lf durable adoption phase'
need_in_function recover_both_hosts '            proof_count=0' 'recovery proof counter'
need_in_function recover_both_hosts '            if ((proof_count == 0)); then' 'recovery proof none regeneration branch'
need_in_function recover_both_hosts '            elif ((proof_count != 2)); then' 'recovery proof partial rejection'
need_in_function recover_both_hosts "                    --bootstrap-v1.3-legacy-config \\" 'explicit bootstrap-v1.3 legacy-config recovery call'
need_in_function recover_both_hosts "                die 'partial Linux deactivation proof publication is uncertain'" 'recovery proof partial fail-closed'
need_in_function ensure_recovery_publish_intent "        publish_json_file 'recovery marker publish intent' \"\$temp\" \"\$recovery_publish_intent\"" 'generation-2 durable publish intent'
need_in_function republish_deployment_marker_for_recovery '            ensure_recovery_publish_intent' 'generation-2 active marker intent'
need_in_function republish_deployment_marker_for_recovery '            if [[ ! -e $recovery_deployment_publish_receipt ]]; then adopt_active_recovery_marker "$current_sha"; fi' 'generation-2 active marker adoption'
need_in_function republish_deployment_marker_for_recovery '    ensure_recovery_publish_intent' 'generation-2 publish intent before publish'
need_in_function republish_deployment_marker_for_recovery "        die 'uncertain: failed deployment recovery will not complete a protocol-2.1 release claim'" 'recovery release-claim fail-closed'
if function_body republish_deployment_marker_for_recovery | grep -F -- '"$MARKER_CLI" release' >/dev/null; then fail 'failed-deployment recovery emits a normal release'; fi
need_in_function republish_deployment_marker_for_recovery '    [[ $state == deployment-quarantine-released ]] ||' 'pre-existing release proof before recovery republish'
need_in_function main '    if [[ $(phase_rank "$phase") -lt $(phase_rank RUST_ACCEPTANCE_ARMED) ]]; then arm_rust_acceptance; commit_phase RUST_ACCEPTANCE_ARMED' 'post-release Rust subphase'
need_in_function main '    if [[ $(phase_rank "$phase") -lt $(phase_rank CPP_ACCEPTANCE_ARMED) ]]; then wait_for_runtime_marker_and_arm_cpp; commit_phase CPP_ACCEPTANCE_ARMED' 'post-release C++ arm subphase'
need_in_function main '    if [[ $(phase_rank "$phase") -lt $(phase_rank CPP_CLEANED) ]]; then wait_for_cpp_cleanup; commit_phase CPP_CLEANED' 'post-release cleanup subphase'
need_in_function main '        commit_phase WINDOWS_RESTART_INTENT' 'post-release restart intent phase'
need_in_function main '        commit_phase WINDOWS_RESTARTED' 'post-release restart terminal phase'
need_in_function restart_windows_peer_after_cleanup "        publish_json_file 'durable Windows restart intent' \"\$intent\" \"\$local_windows_restart_intent\"" 'local restart intent'
need_in_function restart_windows_peer_after_cleanup '    windows_create_or_verify "$intent" "$windows_restart_intent_path"' 'remote restart intent'
need_in_function restart_windows_peer_after_cleanup "    windows_remote_exists \"\$windows_restart_claim_path\" && die 'uncertain: Windows restart claim exists without terminal receipt'" 'restart claim fail-closed'
need_in_function restart_windows_peer_after_cleanup '    commit_phase WINDOWS_RESTART_DISPATCHED' 'restart dispatch phase'
need_in_function restart_windows_peer_after_cleanup "        die 'Windows restart returned without durable terminal receipt'" 'restart terminal required'
need_in_function run_windows_rollback '    if windows_remote_exists "$windows_rollback_receipt_path"; then' 'rollback terminal-first query'
need_in_function run_windows_rollback '    elif windows_remote_exists "$windows_rollback_claim_path"; then' 'rollback dispatch claim query'
need_in_function run_windows_rollback '        make_recovery_bundle "$bundle"' 'rollback durable bundle'
need_in_function run_windows_rollback "        die 'uncertain: rollback dispatch claim exists without a terminal receipt; non-idempotent rollback will not replay'" 'rollback claim fail-closed'
need_in_function run_windows_rollback '        windows_create_or_verify "$bundle" "$windows_recovery_bundle_path"' 'rollback remote bundle'
need_in_function validate_rollback_snapshots '    authorized_manifest=$(jq -er '\''.rollback_authorization.manifest_sha256'\'' "$windows_prepared_receipt")' 'P-authorized manifest hash'
need_in_function validate_rollback_snapshots '    [[ $remote_manifest_sha == "$authorized_manifest" && $remote_token_sha == "$authorized_token" ]] ||' 'P manifest/token equality'
need_in_function validate_rollback_snapshots '        --arg proof "$windows_operation_root\\linux-deactivation-proof.json"' 'rollback fixed bootstrap proof leaf'
need_in_function validate_rollback_snapshots '        --arg runtime "$windows_operation_root\\runtime-receipt.json"' 'rollback fixed normal runtime leaf'
need_in_function make_recovery_bundle '        proof_name=$(windows_fixed_leaf "$windows_operation_root\\linux-deactivation-proof.json")' 'bundle fixed bootstrap proof basename'
need_in_function make_recovery_bundle '        runtime_name=$(windows_fixed_leaf "$windows_operation_root\\runtime-receipt.json")' 'bundle fixed normal runtime basename'
need_in_function validate_recovery_bundle '    proof_name=$(windows_fixed_leaf "$windows_operation_root\\linux-deactivation-proof.json")' 'bundle validates fixed bootstrap proof basename'
need_in_function validate_recovery_bundle '    runtime_name=$(windows_fixed_leaf "$windows_operation_root\\runtime-receipt.json")' 'bundle validates fixed normal runtime basename'
if function_body make_recovery_bundle | grep -F -- 'basename --' >/dev/null; then fail 'bundle derives remote leaf from a local basename'; fi
if function_body validate_recovery_bundle | grep -F -- 'basename --' >/dev/null; then fail 'bundle validation derives remote leaf from a local basename'; fi
need_in_function classify_runtime_after_containment '        runtime_recovery_state=pre_release' 'runtime-marker pre-release mapping'
need_in_function classify_runtime_after_containment '        runtime_recovery_state=cleaned' 'runtime-marker cleaned mapping'
need_in_function classify_runtime_after_containment '    runtime_recovery_state=retained' 'runtime-marker retained mapping'
recover_stop=$(function_line recover_both_hosts '        stop_exact_windows_bootstrap || finish_recovery "$RECOVERY_FAILURE_EXIT"')
recover_republish=$(first_function_line recover_both_hosts '        republish_deployment_marker_for_recovery || finish_recovery "$RECOVERY_FAILURE_EXIT"')
recover_linux=$(function_line recover_both_hosts '        rollback_linux_two_phase || finish_recovery "$RECOVERY_FAILURE_EXIT"')
recover_windows=$(function_line recover_both_hosts '        run_windows_rollback || finish_recovery "$RECOVERY_FAILURE_EXIT"')
((recover_stop < recover_republish && recover_republish < recover_linux && recover_linux < recover_windows)) || fail 'recovery not Stop/Linux-first/Windows-second'
for function_name in validate_candidate_replacement_lineage commit_phase phase_rank adopt_prepublished_marker_handoff validate_frozen_linux_B make_bootstrap_request remote_prepare_and_start_once validate_pre_mutation_retry_proof reopen_pre_mutation_stop_intent validate_windows_prepared_P publish_mutation_permit validate_windows_force_F stop_exact_windows_bootstrap run_linux_stage validate_windows_W_schema5 wait_windows_terminal_exit run_linux_finalize rollback_linux_two_phase validate_exact_bootstrap_cross_chain validate_release_receipt_v2 release_deployment_marker_transactionally validate_attempt3_slot_cleanup_gate validate_fresh_operation_lineage_gate validate_schema1_handoff_lineage_gate validate_failed_v13_slot_lineage_union validate_failed_v13_terminal_state validate_failed_v13_baseline_evidence validate_pre_mutation_failed_terminal_state validate_pre_mutation_failed_baseline assert_pre_mutation_outputs_absent validate_pre_mutation_windows_live_proof validate_pre_mutation_stop_transport_bridge capture_pre_mutation_windows_live_proof select_failed_v13_abort_marker_tuple assert_failed_v13_original_generation_only validate_fd_gate_contract run_pinned_executable canonical_fd_gate_exec_start_sha expected_viewflow_v13_exec_start_sha expected_deskflow_v13_exec_start_sha observed_transient_exec_start_sha start_pinned_v13_transient_unit start_and_freeze_linux_v13 start_and_freeze_windows_v13 freeze_pre_mutation_windows_v13 validate_pre_mutation_windows_v13_started freeze_authenticated_v13_peer make_and_validate_post_permit_rollback_abort_authorization make_and_validate_post_force_rollback_abort_authorization make_and_validate_abort_authorization make_and_validate_pre_mutation_abort_authorization validate_abort_receipt_binary validate_abort_receipt_v2 validate_abort_receipt_v1 validate_abort_receipt_v5 validate_abort_receipt_v7 abort_deployment_marker_transactionally abort_pre_mutation_deployment_marker_transactionally derive_pre_mutation_abort_contract failed_v13_pre_mutation_abort_preflight failed_v13_abort_preflight failed_v13_abort_main publish_pre_mutation_abort_terminal failed_v13_pre_mutation_abort_main ssh_windows windows_read_file cleanup_secure_dir finish_recovery recover_both_hosts main; do
    [[ $(grep -Ec -- "^${function_name}\\(\\) \\{" "$coordinator") == 1 ]] || fail "single $function_name"
    grep -Eq -- "^readonly -f( [A-Za-z_][A-Za-z0-9_]*)* $function_name( |$)" "$coordinator" || fail "unfrozen $function_name"
done
once 'trap handle_err ERR' 'ERR trap'; once "trap 'handle_signal 130' INT" 'INT trap'; once "trap 'handle_signal 143' TERM" 'TERM trap'; once 'trap handle_exit EXIT' 'EXIT trap'
[[ $(awk '!/^[[:space:]]*($|#)/ {x=$0} END {print x}' "$coordinator") == 'fi' ]] || fail 'mode dispatcher not final'
need 'if ((abort_failed_v13)); then' 'explicit failed-v1.3 abort dispatcher'
need '    failed_v13_abort_main' 'failed-v1.3 abort dispatcher target'
need '    main "$@"' 'normal coordinator dispatcher target'
printf 'cross-host coordinator two-phase static contract passed\n'
