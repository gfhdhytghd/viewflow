#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly LINUX=$(cd -- "$HERE/.." && pwd)
root=$(mktemp -d --tmpdir viewflow-post-vfdqa-input.XXXXXX)
cleanup_root(){ chmod -R u+rwx "$root" 2>/dev/null || true; rm -rf -- "$root"; }
trap cleanup_root EXIT
copy=$root/bridge.sh
apply_copy(){ sed "s|readonly STATE_ROOT=/home/wilf/.local/state/viewflow|readonly STATE_ROOT=$root/state|" "$LINUX/bridge-post-vfdqa-tombstone-to-fresh-v21.sh" >"$copy"; chmod 0700 "$copy"; }
apply_copy
op=11111111111111111111111111111111; mkdir -p "$root/state/post-vfdqa-bridges/$op/evidence"; chmod 0700 "$root/state" "$root/state/post-vfdqa-bridges" "$root/state/post-vfdqa-bridges/$op" "$root/state/post-vfdqa-bridges/$op/evidence"
bridge=$root/state/post-vfdqa-bridges/$op; incident=$root/incident.json; tomb=$root/tomb.json; manifest=$root/manifest.json; win=$root/windows.json; linux=$root/linux.json; auth=$root/auth.json; receipt=$root/vfdqa.bin
raw=$bridge/evidence/windows-ssh-raw-census.json; disposition=$bridge/evidence/windows-legacy-disposition.json
intent=$bridge/evidence/windows-legacy-census-capture-intent.json
candidate=$root/candidate; prepare=$root/prepare; collector=$root/collector; printf x >"$candidate"; printf '#!/bin/sh\n' >"$prepare"; printf '#!/bin/sh\n' >"$collector"
jq -cn '{coordinator_instance_id:"22222222-2222-2222-2222-222222222222"}' >"$auth"; auth_sha=$(sha256sum "$auth"|awk '{print $1}')
marker=$root/marker
python3 - "$marker" "$op" <<'PY'
import sys,uuid
b=bytearray(256); o=sys.argv[2].encode(); b[:13]=b'VFDQT001\x01\x01\x02\x01\x01'; b[13]=len(o); b[16:16+len(o)]=o
b[144:160]=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes; b[160:176]=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes; b[176:192]=uuid.UUID('22222222-2222-2222-2222-222222222222').bytes; b[192:200]=(1).to_bytes(8,'little'); b[200:208]=(1).to_bytes(8,'little'); open(sys.argv[1],'wb').write(b)
PY
marker_sha=$(sha256sum "$marker"|awk '{print $1}')
python3 - "$receipt" "$marker" "$marker_sha" "$auth_sha" <<'PY'
import hashlib,sys
m=open(sys.argv[2],'rb').read(); b=bytearray(384); b[:8]=b'VFDQA001'; b[8:13]=bytes((1,1,1,3,1)); b[16:272]=m; b[272:304]=bytes.fromhex(sys.argv[3]); b[304:336]=bytes.fromhex(sys.argv[4]); b[336:344]=(1).to_bytes(8,'little'); b[352:384]=hashlib.sha256(b[:352]).digest(); open(sys.argv[1],'wb').write(b)
PY
receipt_sha=$(sha256sum "$receipt"|awk '{print $1}')
jq -cn --arg op "$op" '{schema_version:1,state:"viewflow-post-vfdqa-windows-census",operation_id:$op,classification:{physical_abort:"VFDQA_COMMITTED",authorization_provenance:"AUTHZ_PROVENANCE_INVALID",prior_normal_terminal:"TERMINAL_ABSENT",current_runtime:"CURRENT_RUNTIME_REATTESTED",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",normal_release_ready:false,fresh_bridge_ready:false}}' >"$win"; win_sha=$(sha256sum "$win"|awk '{print $1}')
jq -cn --arg op "$op" '{boot_id:"33333333-3333-3333-3333-333333333333",cgroup_pid_sets:{viewflow:[10],deskflow:[20,21,22]},observed_at_utc:"2026-08-31T00:00:00.000Z",operation_id:$op,state:"CURRENT_RUNTIME_REATTESTED",units:{viewflow:{unit:"view.service",control_group:"/view",invocation_id:"a",active_state:"active",sub_state:"running",transient:"yes",kill_mode:"control-group",exec_start_sha256:("a"*64),main_pid:10},deskflow:{unit:"desk.service",control_group:"/desk",invocation_id:"b",active_state:"active",sub_state:"running",transient:"yes",kill_mode:"control-group",exec_start_sha256:("b"*64),main_pid:20}},processes:{viewflow:[{role:"viewflow",pid:10,parent_pid:null,start_ticks:1,exe_sha256:("c"*64),control_group:"/view"}],deskflow:[{role:"bubblewrap",pid:20,parent_pid:null,start_ticks:2,exe_sha256:("d"*64),control_group:"/desk"},{role:"gui",pid:21,parent_pid:20,start_ticks:3,exe_sha256:("e"*64),control_group:"/desk"},{role:"core",pid:22,parent_pid:21,start_ticks:4,exe_sha256:("f"*64),control_group:"/desk"}]}}' >"$linux"; linux_sha=$(sha256sum "$linux"|awk '{print $1}')
jq -cn --arg op "$op" --arg ap "$auth" --arg as "$auth_sha" --arg vp "$receipt" --arg vs "$receipt_sha" --arg wp "$win" --arg lp "$linux" --arg marker "$marker_sha" '{adopted_artifacts:{invalid_provenance_authorization:{path:$ap,sha256:$as}},approval:{},execution_authorized:false,incident_classification:["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"],linux_runtime:{},operation_id:$op,outputs:{incident:"unused",linux_runtime_inventory:$lp,terminal:"unused",windows_inventory:$wp},required_absent:[],schema_version:1,state:"viewflow-post-vfdqa-replay6-reconciliation-manifest",vfdqa_binary:{path:$vp,sha256:$vs,size:384,marker_sha256:$marker,authorization_sha256:$as},windows:{}}' >"$manifest"; manifest_sha=$(sha256sum "$manifest"|awk '{print $1}')
jq -cn --arg op "$op" --arg m "$manifest_sha" --arg w "$win_sha" --arg l "$linux_sha" '{abort_physically_committed:true,current_runtime_classification:"CURRENT_RUNTIME_REATTESTED",fresh_bridge_ready:false,incident_classification:["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"],linux_runtime_inventory_sha256:$l,linux_transients_kept_running:true,manifest_sha256:$m,normal_deployment_release:false,normal_success_terminal:false,old_authorization_retroactively_validated:false,old_peer_kept_running:true,operation_id:$op,reconciled_at_utc:"2026-08-31T00:00:00.000Z",rollback_performed:false,schema_version:2,state:"viewflow-post-vfdqa-incident-terminal-reconciliation-required",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",windows_inventory_sha256:$w}' >"$incident"; incident_sha=$(sha256sum "$incident"|awk '{print $1}')
jq -cn --arg op "$op" --arg m "$manifest_sha" --arg w "$win_sha" --arg l "$linux_sha" --arg i "$incident_sha" '{current_runtime_classification:"CURRENT_RUNTIME_REATTESTED",fresh_bridge_ready:false,incident_classification:["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"],incident_receipt_sha256:$i,linux_deskflow_transient_kept_running:true,linux_runtime_reattestation_sha256:$l,linux_viewflow_transient_kept_running:true,manifest_sha256:$m,normal_deployment_release:false,normal_success_terminal:false,old_authorization_retroactively_validated:false,old_peer_kept_running:true,operation_id:$op,physical_abort_committed:true,rollback_performed:false,schema_version:2,state:"INVALID_AUTHZ_PROVENANCE_TOMBSTONE",terminalized_at_utc:"2026-08-31T00:00:00.000Z",windows_baseline_proof:"tainted-needs-remediation",windows_inventory_sha256:$w}' >"$tomb"; tomb_sha=$(sha256sum "$tomb"|awk '{print $1}')
probe_out=$root/probe-out.json
jq -cn --arg op "$op" '{schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-census",operation_id:$op}' >"$probe_out"
probe_sha=$(printf 'a%.0s' {1..64}); wrapper_sha=$(printf 'b%.0s' {1..64}); checker_sha=$(printf 'c%.0s' {1..64})
canonical_sha=$(jq -cS . "$probe_out" | sha256sum | awk '{print $1}')
jq -cn --arg op "$op" --arg m "$manifest_sha" --arg i "$incident_sha" --arg t "$tomb_sha" --arg w "$win_sha" --arg probe "$probe_sha" --arg wrapper "$wrapper_sha" --arg out "$(base64 -w0 "$probe_out")" --arg outsha "$(sha256sum "$probe_out"|awk '{print $1}')" --argjson outlen "$(stat -c %s "$probe_out")" --arg empty "$(printf ''|sha256sum|awk '{print $1}')" --arg canonical "$canonical_sha" --slurpfile doc "$probe_out" '{schema_version:1,state:"viewflow-windows-ssh-raw-census",operation_id:$op,observed_at_utc:"2026-08-31T00:00:00.000Z",transport:"ssh-powershell-encodedcommand-exact-length-raw-files-v2",ssh_target:"fixture@windows",ssh_options:["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","WarnWeakCrypto=no","-o","ConnectTimeout=10","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=3"],probe_script_sha256:$probe,wrapper_script_sha256:$wrapper,transport_upgrade_receipt_sha256:"none",exit_status:0,stdout:{base64:$out,length:$outlen,sha256:$outsha},stderr:{base64:"",length:0,sha256:$empty},parsed_census:{canonical_jq_cS_sha256:$canonical,document:$doc[0]},incident_boundary:{reconciliation_manifest_sha256:$m,incident_sha256:$i,invalid_authz_tombstone_sha256:$t,prior_windows_inventory_sha256:$w}}' >"$raw"; raw_sha=$(sha256sum "$raw"|awk '{print $1}')
jq -cn --arg op "$op" --arg m "$manifest" --arg ms "$manifest_sha" --arg w "$win" --arg ws "$win_sha" --arg i "$incident" --arg is "$incident_sha" --arg t "$tomb" --arg ts "$tomb_sha" --arg raw "$raw" --arg disposition "$disposition" --arg probe "$probe_sha" --arg wrapper "$wrapper_sha" --arg checker "$checker_sha" '{schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-capture-intent",old_operation_id:$op,ssh_target:"fixture@windows",ssh_options:["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","WarnWeakCrypto=no","-o","ConnectTimeout=10","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=3"],inputs:{reconciliation_manifest:{path:$m,sha256:$ms},prior_windows_inventory:{path:$w,sha256:$ws},incident:{path:$i,sha256:$is},invalid_authz_tombstone:{path:$t,sha256:$ts}},outputs:{raw_census:$raw,legacy_disposition:$disposition},producer:{probe:{path:"/fixture/probe.ps1",sha256:$probe},powershell_wrapper_sha256:$wrapper,checker:{path:"/fixture/checker.sh",sha256:$checker}}}' >"$intent"
jq -cn --arg op "$op" --arg raw "$raw_sha" --arg m "$manifest_sha" --arg i "$incident_sha" --arg t "$tomb_sha" --arg w "$win_sha" '{schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-disposition",old_operation_id:$op,action:"preserve-and-quarantine-no-mutation",incident_boundary:{reconciliation_manifest_sha256:$m,incident_sha256:$i,invalid_authz_tombstone_sha256:$t,prior_windows_inventory_sha256:$w},raw_census_sha256:$raw,stderr_classification_sha256:"none",operation_root:{state:"quarantined"},legacy_deployment_task:{state:"preserved"},peer:{state:"preserved"},legacy_isolation_complete:true,fresh_bridge_ready:false}' >"$disposition"; disposition_sha=$(sha256sum "$disposition"|awk '{print $1}')
chmod 0600 "$incident" "$tomb" "$manifest" "$win" "$linux" "$auth" "$receipt" "$raw" "$intent" "$disposition" "$candidate" "$prepare" "$collector"
args=(--validate-inputs-only --old-operation-id "$op" --incident-terminal "$incident" --incident-terminal-sha256 "$incident_sha" --invalid-authz-tombstone "$tomb" --invalid-authz-tombstone-sha256 "$tomb_sha" --vfdqa-receipt "$receipt" --vfdqa-receipt-sha256 "$receipt_sha" --reconciliation-manifest "$manifest" --reconciliation-manifest-sha256 "$manifest_sha" --windows-census "$win" --windows-census-sha256 "$win_sha" --linux-runtime-inventory "$linux" --linux-runtime-inventory-sha256 "$linux_sha" --windows-raw-census "$raw" --windows-raw-census-sha256 "$raw_sha" --windows-disposition "$disposition" --windows-disposition-sha256 "$disposition_sha" --installed-viewflow-sha256 "$marker_sha" --installed-viewflow-unit-sha256 "$marker_sha" --deployment-marker-candidate "$candidate" --deployment-marker-sha256 "$(sha256sum "$candidate"|awk '{print $1}')" --prepare-script "$prepare" --prepare-script-sha256 "$(sha256sum "$prepare"|awk '{print $1}')" --collector-script "$collector" --collector-script-sha256 "$(sha256sum "$collector"|awk '{print $1}')" --bridge-root "$bridge")
run(){ /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${args[@]}"; }
set_arg(){ local key=$1 value=$2 n; for ((n=0;n<${#args[@]};n++)); do if [[ ${args[n]} == "$key" ]]; then args[n+1]=$value; return; fi; done; echo "error: missing fixture argument $key" >&2; exit 1; }
run >/dev/null

# Exercise the historical four-file recovery chain as a second valid union arm.
old_wrapper=4170bd4a552818636e75a42f6cb3cb13b49724dafc4b0b316afdfcd8d2fb39f3; old_checker=1dfb262ad6ac226d5530d083a9b78d18862dcceb1dbe6ab83bb09019018243b6
observed_wrapper=8e0e056b7f361436c8e87fa74b53310d1275bad996139eddf9035b572cc752d8; observed_checker=2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2
jq --arg wrapper "$old_wrapper" --arg checker "$old_checker" '.ssh_options=["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes"]|.producer.powershell_wrapper_sha256=$wrapper|.producer.checker.sha256=$checker' "$intent" >"$root/intent.old"; mv "$root/intent.old" "$intent"; chmod 0600 "$intent"
upgrade=$bridge/evidence/windows-legacy-census-transport-upgrade.v1.json
jq -cn --arg op "$op" --arg intent "$intent" --arg intent_sha "$(sha256sum "$intent"|awk '{print $1}')" --arg raw "$raw" --arg disposition "$disposition" --arg probe "$probe_sha" --arg old_wrapper "$old_wrapper" --arg old_checker "$old_checker" --arg wrapper "$observed_wrapper" --arg checker "$observed_checker" '{schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-census-transport-upgrade",old_operation_id:$op,reason:"EOF_DEADLOCK_NO_RAW_PUBLISHED",old_intent:{path:$intent,sha256:$intent_sha},old_wrapper_sha256:$old_wrapper,new_wrapper_sha256:$wrapper,old_checker_sha256:$old_checker,new_checker_sha256:$checker,old_transport:"ssh-powershell-encodedcommand-raw-files-v1",new_transport:"ssh-powershell-encodedcommand-exact-length-raw-files-v2",outputs:{raw_census:$raw,legacy_disposition:$disposition},producer:{probe_sha256:$probe,checker_sha256:$checker}}' >"$upgrade"; chmod 0600 "$upgrade"; upgrade_sha=$(sha256sum "$upgrade"|awk '{print $1}')
stderr_file=$root/stderr.bin; xml_file=$root/progress.xml
printf '<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><MS><PR><T>Completed</T></PR></MS></Obj></Objs>' >"$xml_file"
printf '** WARNING: connection is not using a post-quantum key exchange algorithm.\r\n** This session may be vulnerable to "store now, decrypt later" attacks.\r\n** The server may need to be upgraded. See https://openssh.com/pq.html\r\n#< CLIXML\r\n' >"$stderr_file"; cat "$xml_file" >>"$stderr_file"
jq --arg wrapper "$observed_wrapper" --arg upgrade "$upgrade_sha" --arg b64 "$(base64 -w0 "$stderr_file")" --arg stderr_sha "$(sha256sum "$stderr_file"|awk '{print $1}')" --argjson stderr_len "$(stat -c %s "$stderr_file")" '.wrapper_script_sha256=$wrapper|.transport_upgrade_receipt_sha256=$upgrade|.ssh_options=["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","ConnectTimeout=10","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=3"]|.stderr={base64:$b64,length:$stderr_len,sha256:$stderr_sha}' "$raw" >"$root/raw.upgraded"; mv "$root/raw.upgraded" "$raw"; chmod 0600 "$raw"; raw_sha=$(sha256sum "$raw"|awk '{print $1}')
classification=$bridge/evidence/windows-legacy-census-stderr-classification.v1.json
prefix_sha=$(head -c 233 "$stderr_file"|sha256sum|awk '{print $1}')
jq -cn --arg op "$op" --arg raw_path "$raw" --arg raw_sha "$raw_sha" --arg upgrade "$upgrade_sha" --arg stderr_sha "$(sha256sum "$stderr_file"|awk '{print $1}')" --arg prefix_sha "$prefix_sha" --arg xml_sha "$(sha256sum "$xml_file"|awk '{print $1}')" --arg probe "$probe_sha" --arg wrapper "$observed_wrapper" --arg final_wrapper "$(printf 'd%.0s' {1..64})" --arg final_checker "$(printf 'e%.0s' {1..64})" --argjson stderr_len "$(stat -c %s "$stderr_file")" '{schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-census-stderr-classification",old_operation_id:$op,reason:"POWERSHELL_PROGRESS_ONLY_WITH_OPENSSH_PQ_WARNING",raw_census_path:$raw_path,raw_census_sha256:$raw_sha,transport_upgrade_receipt_sha256:$upgrade,stderr_length:$stderr_len,stderr_sha256:$stderr_sha,prefix_sha256:$prefix_sha,clixml_sha256:$xml_sha,clixml_encoding:"cp936",remote_probe_error:false,transport_error:false,accepted:true,observed_probe_script_sha256:$probe,observed_wrapper_script_sha256:$wrapper,observed_transport:"ssh-powershell-encodedcommand-exact-length-raw-files-v2",final_probe_sha256:$probe,final_wrapper_sha256:$final_wrapper,final_checker_sha256:$final_checker}' >"$classification"; chmod 0600 "$classification"; classification_sha=$(sha256sum "$classification"|awk '{print $1}')
jq --arg raw "$raw_sha" --arg classification "$classification_sha" '.raw_census_sha256=$raw|.stderr_classification_sha256=$classification' "$disposition" >"$root/disposition.upgraded"; mv "$root/disposition.upgraded" "$disposition"; chmod 0600 "$disposition"; disposition_sha=$(sha256sum "$disposition"|awk '{print $1}')
set_arg --windows-raw-census-sha256 "$raw_sha"; set_arg --windows-disposition-sha256 "$disposition_sha"
run >/dev/null
cp "$incident" "$root/good-incident"; jq '.state="viewflow-failed-pre-mutation-installer-baseline-restored-abort-terminal"' "$root/good-incident" >"$incident"; incident_sha=$(sha256sum "$incident"|awk '{print $1}'); args[6]=$incident_sha
if run >/dev/null 2>&1; then echo 'error: old normal terminal accepted' >&2; exit 1; fi
cp "$root/good-incident" "$incident"; incident_sha=$(sha256sum "$incident"|awk '{print $1}'); args[6]=$incident_sha; run >/dev/null
jq '.windows_inventory_sha256=("0"*64)' "$root/good-incident" >"$incident"; incident_sha=$(sha256sum "$incident"|awk '{print $1}'); args[6]=$incident_sha
if run >/dev/null 2>&1; then echo 'error: cross-hash mismatch accepted' >&2; exit 1; fi
cp "$root/good-incident" "$incident"; incident_sha=$(sha256sum "$incident"|awk '{print $1}'); args[6]=$incident_sha
chmod 0666 "$candidate"
if run >/dev/null 2>&1; then echo 'error: group/world-writable source accepted' >&2; exit 1; fi
chmod 0600 "$candidate"; printf changed >"$candidate"
if run >/dev/null 2>&1; then echo 'error: same-UID source rewrite accepted' >&2; exit 1; fi
printf x >"$candidate"; chmod 0600 "$candidate"; run >/dev/null

# Execute the production plan/resume validators without entering any live phase.
semantic=$root/semantic-bridge.sh
python3 - "$LINUX/bridge-post-vfdqa-tombstone-to-fresh-v21.sh" "$semantic" "$root/state" <<'PY'
import pathlib,sys
source,out,state=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3]
text=source.read_text().replace('/home/wilf/.local/state/viewflow',state)
old='\nmain\n'
if text.count(old)!=1: raise SystemExit('main anchor differs')
harness=r'''
semantic_main(){
 validate_inputs
 mkdir -p -- "$DEPLOYMENTS"; chmod 0700 "$DEPLOYMENTS"
 plan=$bridge_root/transition-plan.json; cleanup_proof=$bridge_root/retirement-cleanup.json; config_intent=$bridge_root/runtime-config-relocation-intent.json; backup_dir=$bridge_root/runtime-config-backups
 sealed_dir=$bridge_root/sealed-inputs; marker_snapshot=$sealed_dir/marker-candidate; prepare_snapshot=$sealed_dir/prepare-script; collector_snapshot=$sealed_dir/collector-script
 make_plan
 [[ $(jq -er .new_operation_id "$plan") != "$old_operation" ]] || die 'semantic fixture accepted reused operation ID'
 [[ $(jq -er .new_coordinator_instance_id "$plan") != 22222222-2222-2222-2222-222222222222 ]] || die 'semantic fixture accepted reused coordinator ID'
 cp -- "$plan" "$bridge_root/good-plan.json"; chmod 0600 "$bridge_root/good-plan.json"
 jq --arg old "$old_operation" '.new_operation_id=$old|.fresh_operation_root=("''' + state + r'''/deployments/"+$old)' "$bridge_root/good-plan.json" >"$bridge_root/bad-plan.json"; chmod 0600 "$bridge_root/bad-plan.json"; mv -- "$bridge_root/bad-plan.json" "$plan"
 if validate_plan >/dev/null 2>&1; then die 'semantic fixture accepted reused operation ID mutation'; fi
 cp -- "$bridge_root/good-plan.json" "$plan"; chmod 0600 "$plan"
 jq '.new_coordinator_instance_id="22222222-2222-2222-2222-222222222222"' "$bridge_root/good-plan.json" >"$bridge_root/bad-plan.json"; chmod 0600 "$bridge_root/bad-plan.json"; mv -- "$bridge_root/bad-plan.json" "$plan"
 if validate_plan >/dev/null 2>&1; then die 'semantic fixture accepted reused coordinator mutation'; fi
 cp -- "$bridge_root/good-plan.json" "$plan"; chmod 0600 "$plan"; validate_plan
 chmod 0700 "$sealed_dir"; chmod 0700 "$prepare_snapshot"; printf '#!/bin/sh\n# same-uid snapshot rewrite\n' >"$prepare_snapshot"; chmod 0500 "$prepare_snapshot" "$sealed_dir"
 if make_plan >/dev/null 2>&1; then die 'semantic fixture accepted rewritten sealed snapshot'; fi
 chmod 0700 "$sealed_dir"; chmod 0700 "$prepare_snapshot"; cp -- "$prepare_script" "$prepare_snapshot"; chmod 0500 "$prepare_snapshot" "$sealed_dir"; make_plan
 cp -- "$prepare_script" "$bridge_root/prepare-replacement"; chmod 0600 "$bridge_root/prepare-replacement"; mv -- "$bridge_root/prepare-replacement" "$prepare_script"
 if make_plan >/dev/null 2>&1; then die 'semantic fixture accepted same-UID source replacement'; fi
 printf 'semantic plan/snapshot validators passed\n'
}
semantic_main
'''
out.write_text(text.replace(old,'\n'+harness))
PY
chmod 0700 "$semantic"
semantic_args=("${args[@]}"); semantic_args[0]=--execute
/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$semantic" "${semantic_args[@]}" >/dev/null
printf 'post-VFDQA tombstone input fixture passed\n'
