#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077
checker=${1:-/home/wilf/data/viewflow/deploy/windows/check-post-vfdqa-legacy-census.sh}
probe=${PROBE_SOURCE:-/home/wilf/data/viewflow/deploy/windows/capture-post-vfdqa-legacy-census.ps1}
manifest_source=${MANIFEST_SOURCE:-/home/wilf/data/viewflow/deploy/post-abort-replay6-operation55-manifest.json}
op=55d06e8f96aa4adc9010e53612979374
probe_sha=$(sha256sum "$probe"|awk '{print $1}'); wrapper_sha=$(printf 'a%.0s' {1..64})
root=$(mktemp -d /tmp/viewflow-legacy-census-negative.XXXXXX)
trap 'rm -rf -- "$root"' EXIT
manifest=$root/manifest.json; inventory=$root/inventory.json; incident=$root/incident.json; tombstone=$root/tombstone.json
cp -- "$manifest_source" "$manifest"

jq -cnS --slurpfile m "$manifest" '
 $m[0] as $x|{schema_version:1,state:"viewflow-post-vfdqa-windows-census",operation_id:$x.operation_id,
 observed_at_utc:"2026-08-31T15:26:28.161Z",transport:"stdin-base64-single-scriptblock-stop-on-error-v1",
 operation_root:{path:$x.windows.operation_root,reparse:false,acl:{owner_sid:$x.windows.user_sid,protected:true,rules:[
  {sid:$x.windows.user_sid,type:"Allow",rights:"FullControl",inherited:false,inheritance:"ContainerInherit, ObjectInherit",propagation:"None"},
  {sid:"S-1-5-18",type:"Allow",rights:"FullControl",inherited:false,inheritance:"ContainerInherit, ObjectInherit",propagation:"None"}]},
  members:($x.windows.expected_members|to_entries|map({name:.key,directory:false,reparse:false,length:(.key|length),sha256:.value,
   acl:{owner_sid:$x.windows.user_sid,protected:true,rules:[{sid:$x.windows.user_sid,type:"Allow",rights:"FullControl",inherited:false,inheritance:"None",propagation:"None"}]}}))},
 deployment_task:{state:"Disabled",task_xml_sha256:$x.windows.observed_deployment_task_xml_sha256,action_execute:"powershell.exe",action_arguments:"-File start-viewflow-bootstrap.ps1",working_directory:$x.windows.operation_root},
 installed:($x.windows.installed_baseline|to_entries|map({name:.key,sha256:.value,acl:{owner_sid:$x.windows.user_sid,protected:false,rules:[{sid:$x.windows.user_sid,type:"Allow",rights:"ReadAndExecute",inherited:true,inheritance:"None",propagation:"None"}]}})),
 peer:{task_state:"Running",task_xml_sha256:$x.windows.peer_task_xml_sha256,pid:$x.windows.peer_process.pid,parent_pid:$x.windows.peer_process.parent_pid,creation_date:$x.windows.peer_process.creation_date,session_id:1,owner_sid:$x.windows.user_sid,exe_sha256:$x.windows.peer_process.exe_sha256,command_line:"exact-old-command"},
 classification:{physical_abort:"VFDQA_COMMITTED",authorization_provenance:"AUTHZ_PROVENANCE_INVALID",prior_normal_terminal:"TERMINAL_ABSENT",current_runtime:"CURRENT_RUNTIME_REATTESTED",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",normal_release_ready:false,fresh_bridge_ready:false}}
' >"$inventory"
chmod 0600 "$manifest" "$inventory"
manifest_sha=$(sha256sum "$manifest"|awk '{print $1}'); inventory_sha=$(sha256sum "$inventory"|awk '{print $1}')
jq -cnS --arg op "$op" --arg m "$manifest_sha" --arg w "$inventory_sha" '
 {schema_version:2,state:"viewflow-post-vfdqa-incident-terminal-reconciliation-required",operation_id:$op,
 incident_classification:["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"],current_runtime_classification:"CURRENT_RUNTIME_REATTESTED",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",abort_physically_committed:true,old_authorization_retroactively_validated:false,normal_success_terminal:false,normal_deployment_release:false,rollback_performed:false,fresh_bridge_ready:false,old_peer_kept_running:true,linux_transients_kept_running:true,manifest_sha256:$m,windows_inventory_sha256:$w,linux_runtime_inventory_sha256:("b"*64),reconciled_at_utc:"2026-08-31T15:26:28.161Z"}
' >"$incident"; chmod 0600 "$incident"; incident_sha=$(sha256sum "$incident"|awk '{print $1}')
jq -cnS --arg op "$op" --arg m "$manifest_sha" --arg w "$inventory_sha" --arg i "$incident_sha" '
 {schema_version:2,state:"INVALID_AUTHZ_PROVENANCE_TOMBSTONE",operation_id:$op,
 incident_classification:["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"],current_runtime_classification:"CURRENT_RUNTIME_REATTESTED",windows_baseline_proof:"tainted-needs-remediation",physical_abort_committed:true,normal_success_terminal:false,normal_deployment_release:false,rollback_performed:false,fresh_bridge_ready:false,old_authorization_retroactively_validated:false,old_peer_kept_running:true,linux_viewflow_transient_kept_running:true,linux_deskflow_transient_kept_running:true,manifest_sha256:$m,windows_inventory_sha256:$w,incident_receipt_sha256:$i,linux_runtime_reattestation_sha256:("b"*64),terminalized_at_utc:"2026-08-31T15:26:28.161Z"}
' >"$tombstone"; chmod 0600 "$tombstone"; tombstone_sha=$(sha256sum "$tombstone"|awk '{print $1}')

probe_json=$root/probe.json
jq -cnS --slurpfile m "$manifest" --slurpfile w "$inventory" --arg ms "$manifest_sha" --arg is "$incident_sha" --arg ts "$tombstone_sha" --arg ws "$inventory_sha" '
 $m[0] as $x|$w[0] as $i|
 {schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-census",operation_id:$x.operation_id,observed_at_utc:"2026-08-31T15:30:00.000Z",policy:"FREEZE_ONLY_NO_MUTATION",
 operation_root:($i.operation_root+{before_census_sha256:("c"*64),after_census_sha256:("c"*64),disposition:"FROZEN_PRESENT_UNCHANGED"}),
 deployment_task:{task_path:"\\",task_name:("Viewflow Deployment "+$x.operation_id),state:"Disabled",task_xml_sha256:$x.windows.observed_deployment_task_xml_sha256,actions:[{execute:$i.deployment_task.action_execute,arguments:$i.deployment_task.action_arguments,working_directory:$i.deployment_task.working_directory}],principal:{user_id:"wilf",logon_type:"Interactive",run_level:"Limited"},disposition:"FROZEN_DISABLED_UNCHANGED"},
 installed:($i.installed|map(. as $v|{name:.name,path:("C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\"+.name),directory:false,reparse:false,length:(.name|length),sha256:.sha256,acl:.acl})),
 peer_task:{task_path:"\\",task_name:"Viewflow Peer",state:"Running",task_xml_sha256:$x.windows.peer_task_xml_sha256,actions:[{execute:"powershell.exe",arguments:"-File viewflow-client.ps1",working_directory:"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow"}],principal:{user_id:"wilf",logon_type:"Interactive",run_level:"Limited"}},
 viewflowd_processes:[{name:"viewflowd.exe",path:"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe",pid:$x.windows.peer_process.pid,parent_pid:$x.windows.peer_process.parent_pid,creation_date:$x.windows.peer_process.creation_date,session_id:1,owner_sid:$x.windows.user_sid,exe_sha256:$x.windows.peer_process.exe_sha256,command_line:"exact-old-command"}],
 prohibited_actions:["ENABLE","REPLACE","DELETE"],reconciliation_binding:{manifest_sha256:$ms,incident_sha256:$is,tombstone_sha256:$ts,windows_inventory_sha256:$ws},classification:{physical_abort:"VFDQA_COMMITTED",authorization_provenance:"AUTHZ_PROVENANCE_INVALID",prior_normal_terminal:"TERMINAL_ABSENT",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",normal_release_ready:false,fresh_bridge_ready:false}}
' >"$probe_json"
# Raw fidelity case: the decoded stdout deliberately ends in CRLF.
python3 -I -E - "$probe_json" "$root/stdout.raw" <<'PY'
import sys
data=open(sys.argv[1],'rb').read().rstrip(b'\n')+b'\r\n'
open(sys.argv[2],'wb').write(data)
PY
: >"$root/stderr.raw"; chmod 0600 "$root/stdout.raw" "$root/stderr.raw"
canonical=$root/canonical; jq -ceS . "$root/stdout.raw" >"$canonical"; canonical_sha=$(sha256sum "$canonical"|awk '{print $1}')

make_raw(){
 local output=$1 exit_status=${2:-0} document=${3:-$probe_json}
 jq -cnS --arg op "$op" --arg probe "$probe_sha" --arg wrapper "$wrapper_sha" --argjson exit "$exit_status" \
  --arg out "$(base64 -w0 "$root/stdout.raw")" --arg outsha "$(sha256sum "$root/stdout.raw"|awk '{print $1}')" --argjson outlen "$(stat -c %s "$root/stdout.raw")" \
  --arg err "" --arg errsha "$(sha256sum "$root/stderr.raw"|awk '{print $1}')" --slurpfile doc "$document" --arg canonical "$canonical_sha" \
  --arg ms "$manifest_sha" --arg is "$incident_sha" --arg ts "$tombstone_sha" --arg ws "$inventory_sha" '
  {schema_version:1,state:"viewflow-windows-ssh-raw-census",operation_id:$op,observed_at_utc:"2026-08-31T15:30:01.000Z",transport:"ssh-powershell-encodedcommand-exact-length-raw-files-v2",ssh_target:"fixture@windows",ssh_options:["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","WarnWeakCrypto=no","-o","ConnectTimeout=10","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=3"],probe_script_sha256:$probe,wrapper_script_sha256:$wrapper,transport_upgrade_receipt_sha256:"none",exit_status:$exit,stdout:{base64:$out,length:$outlen,sha256:$outsha},stderr:{base64:$err,length:0,sha256:$errsha},parsed_census:{canonical_jq_cS_sha256:$canonical,document:$doc[0]},incident_boundary:{reconciliation_manifest_sha256:$ms,incident_sha256:$is,invalid_authz_tombstone_sha256:$ts,prior_windows_inventory_sha256:$ws}}
 ' >"$output"; chmod 0600 "$output"
}
run(){ "$checker" --raw-census "$1" --manifest "$manifest" --windows-inventory "$inventory" --incident "$incident" --tombstone "$tombstone" --output "$2" --old-operation-id "$op" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_sha"; }
reject(){ local raw=$1 out=$2; if run "$raw" "$out" >/dev/null 2>&1; then echo "negative escaped: $raw" >&2; exit 1; fi; }

raw=$root/raw.json; out=$root/disposition.json; make_raw "$raw"; run "$raw" "$out" >/dev/null
[[ $(jq -r '.stdout.sha256' "$raw") == "$(sha256sum "$root/stdout.raw"|awk '{print $1}')" ]] || { echo 'CRLF raw SHA changed' >&2; exit 1; }
before=$(sha256sum "$out"|awk '{print $1}'); run "$raw" "$out" >/dev/null; [[ $(sha256sum "$out"|awk '{print $1}') == "$before" ]] || exit 1
printf occupied >"$root/different-output"; chmod 0600 "$root/different-output"; reject "$raw" "$root/different-output"; [[ $(cat "$root/different-output") == occupied ]] || exit 1
# Disposition staging-only and link-before-unlink crash recovery.
saved_disposition=$root/saved-disposition.json; cp -- "$out" "$saved_disposition"; chmod 0600 "$saved_disposition"
disposition_stage=$root/.disposition.json.staging.$(sha256sum "$saved_disposition"|awk '{print $1}')
rm -f -- "$out"; cp -- "$saved_disposition" "$disposition_stage"; chmod 0600 "$disposition_stage"; run "$raw" "$out" >/dev/null
[[ ! -e $disposition_stage && $(sha256sum "$out"|awk '{print $1}') == "$before" ]] || { echo 'disposition staging crash was not recovered' >&2; exit 1; }
ln -- "$out" "$disposition_stage"; run "$raw" "$out" >/dev/null
[[ ! -e $disposition_stage && $(stat -c %h "$out") == 1 ]] || { echo 'disposition link-before-unlink crash was not recovered' >&2; exit 1; }
rm -f -- "$out"; printf partial >"$root/.disposition.json.staging.bad"; chmod 0600 "$root/.disposition.json.staging.bad"
reject "$raw" "$out"; [[ -f $root/.disposition.json.staging.bad && ! -e $out ]] || { echo 'partial disposition staging escaped' >&2; exit 1; }
rm -f -- "$root/.disposition.json.staging.bad"

bad=$root/nonzero.json; make_raw "$bad" 7; reject "$bad" "$root/nonzero.out"
bad=$root/extra.json; jq '.extra=true' "$raw" >"$bad"; chmod 0600 "$bad"; reject "$bad" "$root/extra.out"
bad=$root/task-mutation.json; jq '.parsed_census.document.deployment_task.disposition="REPLACE"' "$raw" >"$bad"; chmod 0600 "$bad"; reject "$bad" "$root/task.out"
for expr in '.parsed_census.document.operation_root.members[0].length+=1' '.parsed_census.document.operation_root.members[0].acl.owner_sid="S-1-5-32-544"' '.parsed_census.document.installed[0].reparse=true' '.parsed_census.document.deployment_task.actions[0].execute="evil.exe"' '.parsed_census.document.peer_task.principal.run_level="Highest"' '.parsed_census.document.viewflowd_processes += [.parsed_census.document.viewflowd_processes[0]]'; do
 bad=$root/p0.$RANDOM.json; jq "$expr" "$raw" >"$bad"; chmod 0600 "$bad"; reject "$bad" "$root/p0.$RANDOM.out"
done
bad=$root/duplicate.json; python3 -I -E - "$raw" "$bad" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(d.replace(b'{',b'{"schema_version":1,',1))
PY
chmod 0600 "$bad"; reject "$bad" "$root/duplicate.out"
bad=$root/malformed.json; cp -- "$raw" "$bad"; printf '\xff' >>"$bad"; chmod 0600 "$bad"; reject "$bad" "$root/malformed.out"
ln -s "$raw" "$root/raw-link.json"; reject "$root/raw-link.json" "$root/link.out"
cp -- "$raw" "$root/raw-hard.json"; ln "$root/raw-hard.json" "$root/raw-hard-peer.json"; reject "$root/raw-hard.json" "$root/hard.out"
ln -s "$root/missing" "$root/output-link.json"; reject "$raw" "$root/output-link.json"
printf occupied >"$root/occupied"; chmod 0600 "$root/occupied"; ln "$root/occupied" "$root/output-hard"; reject "$raw" "$root/output-hard"; [[ $(cat "$root/output-hard") == occupied ]] || exit 1

linux_wrapper_source=${LINUX_WRAPPER_SOURCE:-/home/wilf/data/viewflow/deploy/capture-post-vfdqa-windows-legacy-census.sh}
state_root=$root/state
mkdir -- "$state_root"; chmod 0700 "$state_root"
linux_wrapper=$root/linux-wrapper.sh
sed "s#^readonly STATE_ROOT=.*#readonly STATE_ROOT=$state_root#" "$linux_wrapper_source" >"$linux_wrapper"
chmod 0700 "$linux_wrapper"
wrapper_contract_sha=$("$linux_wrapper" --print-wrapper-sha256)
checker_sha=$(sha256sum "$checker"|awk '{print $1}')

# The remote reader must be length-framed and finish after the declared payload;
# an EOF-sensitive ReadToEnd transport is forbidden.  This static fixture is
# intentionally independent of a Windows host and proves the no-EOF contract.
# shellcheck disable=SC2016
if rg -F --quiet '[Console]::In.ReadToEnd()' "$linux_wrapper_source"; then
 echo 'EOF-sensitive PowerShell stdin reader escaped' >&2; exit 1
fi
# shellcheck disable=SC2016
for required in '[Console]::In.ReadLine()' '[Console]::In.Read($buffer,0,[int]$take)' 'short stdin payload' \
                'WarnWeakCrypto=no' 'ConnectTimeout=10' 'ServerAliveInterval=5' 'ServerAliveCountMax=3' \
                'timeout --foreground --signal=TERM --kill-after=5s 120'; do
 rg -F --quiet -- "$required" "$linux_wrapper_source" || { echo "exact-length SSH contract missing: $required" >&2; exit 1; }
done
bridge=$state_root/post-vfdqa-bridges/$op; raw_published=$bridge/evidence/windows-ssh-raw-census.json; disposition_published=$bridge/evidence/windows-legacy-disposition.json

# The state root exists, but its post-vfdqa parent is intentionally absent:
# execute must create exactly that parent, the operation root, and evidence.
[[ ! -e $state_root/post-vfdqa-bridges && ! -L $state_root/post-vfdqa-bridges ]] || { echo 'parent fixture was not absent' >&2; exit 1; }

# Existing symlink/wrong-mode components must be rejected before any intent or
# evidence is written.  Each case uses a fresh state root and wrapper copy so
# the fixed canonical namespace remains operation-bound.
make_wrapper_for_state(){
 local state=$1 destination=$2
 mkdir -- "$state"; chmod 0700 "$state"
 sed "s#^readonly STATE_ROOT=.*#readonly STATE_ROOT=$state#" "$linux_wrapper_source" >"$destination"
 chmod 0700 "$destination"
}
run_state_capture(){
 local script=$1 state=$2 mode=${3:---execute}
 local candidate=$state/post-vfdqa-bridges/$op
 VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$script" "$mode" --manifest "$manifest" --windows-inventory "$inventory" \
  --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" \
  --bridge-root "$candidate" --raw-output "$candidate/evidence/windows-ssh-raw-census.json" \
  --disposition-output "$candidate/evidence/windows-legacy-disposition.json" \
  --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" \
  --checker "$checker" --expected-checker-sha256 "$checker_sha" --fixture-stdout "$root/stdout.raw" \
  --fixture-stderr "$root/stderr.raw" --fixture-exit-status 0
}
run_state_validate(){
 local script=$1 state=$2
 local candidate=$state/post-vfdqa-bridges/$op
 "$script" --validate-inputs-only --manifest "$manifest" --windows-inventory "$inventory" \
  --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" \
  --bridge-root "$candidate" --raw-output "$candidate/evidence/windows-ssh-raw-census.json" \
  --disposition-output "$candidate/evidence/windows-legacy-disposition.json" \
  --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" \
  --checker "$checker" --expected-checker-sha256 "$checker_sha"
}
expect_state_reject(){
 if run_state_capture "$1" "$2" >/dev/null 2>&1; then
  echo "unsafe bridge directory state escaped: $3" >&2; exit 1
 fi
}

bad_state=$root/bad-state; bad_wrapper=$root/bad-wrapper.sh; make_wrapper_for_state "$bad_state" "$bad_wrapper"
bad_parent=$bad_state/post-vfdqa-bridges
rmdir -- "$bad_state"; ln -s /tmp "$bad_state"; expect_state_reject "$bad_wrapper" "$bad_state" 'state-root symlink'; rm -- "$bad_state"
mkdir -- "$bad_state"; chmod 0750 "$bad_state"; expect_state_reject "$bad_wrapper" "$bad_state" 'state-root wrong mode'; chmod 0700 "$bad_state"
ln -s /tmp "$bad_parent"; expect_state_reject "$bad_wrapper" "$bad_state" 'parent symlink'; [[ -L $bad_parent ]] || exit 1; rm -- "$bad_parent"
mkdir -- "$bad_parent"; chmod 0750 "$bad_parent"; expect_state_reject "$bad_wrapper" "$bad_state" 'parent wrong mode'; rmdir -- "$bad_parent"
mkdir -- "$bad_parent"; chmod 0700 "$bad_parent"
ln -s /tmp "$bad_parent/$op"; expect_state_reject "$bad_wrapper" "$bad_state" 'root symlink'; rm -- "$bad_parent/$op"
mkdir -- "$bad_parent/$op"; chmod 0750 "$bad_parent/$op"; expect_state_reject "$bad_wrapper" "$bad_state" 'root wrong mode'; rmdir -- "$bad_parent/$op"
mkdir -- "$bad_parent/$op"; chmod 0700 "$bad_parent/$op"
ln -s /tmp "$bad_parent/$op/evidence"; expect_state_reject "$bad_wrapper" "$bad_state" 'evidence symlink'; rm -- "$bad_parent/$op/evidence"
mkdir -- "$bad_parent/$op/evidence"; chmod 0750 "$bad_parent/$op/evidence"; expect_state_reject "$bad_wrapper" "$bad_state" 'evidence wrong mode'; rmdir -- "$bad_parent/$op/evidence" "$bad_parent/$op" "$bad_parent" "$bad_state"

# Validation must not create the missing post-vfdqa parent or any descendants.
validate_state=$root/validate-state; validate_wrapper=$root/validate-wrapper.sh
make_wrapper_for_state "$validate_state" "$validate_wrapper"
run_state_validate "$validate_wrapper" "$validate_state" >/dev/null
[[ ! -e $validate_state/post-vfdqa-bridges && ! -L $validate_state/post-vfdqa-bridges ]] || { echo 'validate-inputs-only created bridge directories' >&2; exit 1; }

VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$linux_wrapper" --execute --manifest "$manifest" --windows-inventory "$inventory" \
 --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" \
 --bridge-root "$bridge" --raw-output "$raw_published" --disposition-output "$disposition_published" \
 --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" \
 --checker "$checker" --expected-checker-sha256 "$checker_sha" --fixture-stdout "$root/stdout.raw" \
 --fixture-stderr "$root/stderr.raw" --fixture-exit-status 0 >/dev/null
for published in "$raw_published" "$disposition_published"; do
 [[ -f $published && ! -L $published && $(stat -c '%a:%h' "$published") == 600:1 ]] || { echo "bad publication metadata: $published" >&2; exit 1; }
done
[[ $(stat -c '%a' "$bridge") == 700 && $(stat -c '%a' "$bridge/evidence") == 700 ]] || { echo 'bridge directory mode differs' >&2; exit 1; }

# Transport-upgrade recovery: preserve an exact old intent with no raw output,
# create the independent upgrade receipt once, then resume using the new
# framing.  A second resume must reuse both receipts without clobbering them.
upgrade_state=$root/upgrade-state; upgrade_wrapper=$root/upgrade-wrapper.sh
make_wrapper_for_state "$upgrade_state" "$upgrade_wrapper"
upgrade_bridge=$upgrade_state/post-vfdqa-bridges/$op
mkdir -- "$upgrade_state/post-vfdqa-bridges" "$upgrade_bridge" "$upgrade_bridge/evidence"
chmod 0700 "$upgrade_state/post-vfdqa-bridges" "$upgrade_bridge" "$upgrade_bridge/evidence"
old_wrapper_sha=4170bd4a552818636e75a42f6cb3cb13b49724dafc4b0b316afdfcd8d2fb39f3
old_checker_sha=1dfb262ad6ac226d5530d083a9b78d18862dcceb1dbe6ab83bb09019018243b6
upgrade_intent=$upgrade_bridge/evidence/windows-legacy-census-capture-intent.json
jq -cnS --slurpfile current "$bridge/evidence/windows-legacy-census-capture-intent.json" \
 --arg old "$old_wrapper_sha" --arg old_checker "$old_checker_sha" --arg raw "$upgrade_bridge/evidence/windows-ssh-raw-census.json" \
 --arg disposition "$upgrade_bridge/evidence/windows-legacy-disposition.json" \
 '$current[0] | .ssh_options=["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes"] |
  .outputs.raw_census=$raw | .outputs.legacy_disposition=$disposition |
  .producer.powershell_wrapper_sha256=$old | .producer.checker.sha256=$old_checker' >"$upgrade_intent"
chmod 0600 "$upgrade_intent"
old_intent_before=$(sha256sum "$upgrade_intent")
upgrade_receipt=$upgrade_bridge/evidence/windows-legacy-census-transport-upgrade.v1.json
old_intent_sha=$(sha256sum "$upgrade_intent" | awk '{print $1}')
jq -cnS --arg op "$op" --arg intent "$upgrade_intent" --arg intent_sha "$old_intent_sha" \
 --arg raw "$upgrade_bridge/evidence/windows-ssh-raw-census.json" \
 --arg disposition "$upgrade_bridge/evidence/windows-legacy-disposition.json" --arg probe "$probe_sha" \
 '{schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-census-transport-upgrade",old_operation_id:$op,
   reason:"EOF_DEADLOCK_NO_RAW_PUBLISHED",old_intent:{path:$intent,sha256:$intent_sha},
   old_wrapper_sha256:"4170bd4a552818636e75a42f6cb3cb13b49724dafc4b0b316afdfcd8d2fb39f3",
   new_wrapper_sha256:"8e0e056b7f361436c8e87fa74b53310d1275bad996139eddf9035b572cc752d8",
   old_checker_sha256:"1dfb262ad6ac226d5530d083a9b78d18862dcceb1dbe6ab83bb09019018243b6",
   new_checker_sha256:"2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2",
   old_transport:"ssh-powershell-encodedcommand-raw-files-v1",
   new_transport:"ssh-powershell-encodedcommand-exact-length-raw-files-v2",
   outputs:{raw_census:$raw,legacy_disposition:$disposition},
   producer:{probe_sha256:$probe,checker_sha256:"2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2"}}' >"$upgrade_receipt"
chmod 0600 "$upgrade_receipt"
upgrade_sha=$(sha256sum "$upgrade_receipt" | awk '{print $1}')
jq -cS --arg upgrade "$upgrade_sha" '
 .ssh_options=["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","ConnectTimeout=10","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=3"] |
 .wrapper_script_sha256="8e0e056b7f361436c8e87fa74b53310d1275bad996139eddf9035b572cc752d8" |
 .transport_upgrade_receipt_sha256=$upgrade
' "$raw_published" >"$upgrade_bridge/evidence/windows-ssh-raw-census.json"
chmod 0600 "$upgrade_bridge/evidence/windows-ssh-raw-census.json"
run_state_capture "$upgrade_wrapper" "$upgrade_state" --resume >/dev/null
[[ -f $upgrade_receipt && $(stat -c '%u:%a:%h' "$upgrade_receipt") == 1000:600:1 ]] || { echo 'transport upgrade receipt metadata differs' >&2; exit 1; }
[[ $(jq -r '.reason' "$upgrade_receipt") == EOF_DEADLOCK_NO_RAW_PUBLISHED &&
   $(jq -r '.transport_upgrade_receipt_sha256' "$upgrade_bridge/evidence/windows-ssh-raw-census.json") == "$(sha256sum "$upgrade_receipt" | awk '{print $1}')" ]] || { echo 'transport upgrade binding differs' >&2; exit 1; }
[[ $(sha256sum "$upgrade_intent") == "$old_intent_before" ]] || { echo 'old intent was modified during transport upgrade' >&2; exit 1; }
upgrade_before=$(sha256sum "$upgrade_receipt" "$upgrade_bridge/evidence/windows-ssh-raw-census.json" "$upgrade_bridge/evidence/windows-legacy-disposition.json")
run_state_capture "$upgrade_wrapper" "$upgrade_state" --resume >/dev/null
[[ $(sha256sum "$upgrade_receipt" "$upgrade_bridge/evidence/windows-ssh-raw-census.json" "$upgrade_bridge/evidence/windows-legacy-disposition.json") == "$upgrade_before" ]] || { echo 'transport upgrade replay clobbered evidence' >&2; exit 1; }

# Existing raw with the observed OpenSSH PQ warning and CP936 progress-only
# CLIXML is classified on resume, without SSH, then carried into disposition.
valid_stderr=$root/valid-pq-stderr.raw
python3 -I -E - "$valid_stderr" <<'PY'
import sys
prefix=(b'** WARNING: connection is not using a post-quantum key exchange algorithm.\r\n'
        b'** This session may be vulnerable to "store now, decrypt later" attacks.\r\n'
        b'** The server may need to be upgraded. See https://openssh.com/pq.html\r\n'
        b'#< CLIXML\r\n')
xml=(b'<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">'
     b'<Obj S="progress" RefId="0"><MS><PR><AV>\xa1\xb1\xb6\xc8</AV></PR></MS></Obj></Objs>\r\n')
open(sys.argv[1],'wb').write(prefix+xml)
PY
set_stderr(){
 local source=$1 raw_path=$upgrade_bridge/evidence/windows-ssh-raw-census.json tmp=$root/stderr-raw.json
 jq --arg b64 "$(base64 -w0 "$source")" --argjson len "$(stat -c %s "$source")" --arg sha "$(sha256sum "$source" | awk '{print $1}')" \
   '.stderr={base64:$b64,length:$len,sha256:$sha}' "$raw_path" >"$tmp"; chmod 0600 "$tmp"; cp -- "$tmp" "$raw_path"; chmod 0600 "$raw_path"
 rm -f -- "$upgrade_bridge/evidence/windows-legacy-disposition.json" "$upgrade_bridge/evidence/windows-legacy-census-stderr-classification.v1.json"
}
set_stderr "$valid_stderr"
upgrade_sha_before_classification=$(sha256sum "$upgrade_receipt"|awk '{print $1}')
run_state_capture "$upgrade_wrapper" "$upgrade_state" --resume >/dev/null
stderr_receipt=$upgrade_bridge/evidence/windows-legacy-census-stderr-classification.v1.json
[[ -f $stderr_receipt && $(jq -r '.clixml_encoding' "$stderr_receipt") == cp936 &&
   $(jq -r '.accepted' "$stderr_receipt") == true &&
   $(jq -r '.stderr_classification_sha256' "$upgrade_bridge/evidence/windows-legacy-disposition.json") == "$(sha256sum "$stderr_receipt" | awk '{print $1}')" &&
   $(sha256sum "$upgrade_receipt"|awk '{print $1}') == "$upgrade_sha_before_classification" ]] || { echo 'stderr classification receipt binding differs' >&2; exit 1; }
stderr_before=$(sha256sum "$stderr_receipt" "$upgrade_bridge/evidence/windows-legacy-disposition.json")
run_state_capture "$upgrade_wrapper" "$upgrade_state" --resume >/dev/null
[[ $(sha256sum "$stderr_receipt" "$upgrade_bridge/evidence/windows-legacy-disposition.json") == "$stderr_before" &&
   $(sha256sum "$upgrade_receipt"|awk '{print $1}') == "$upgrade_sha_before_classification" ]] || { echo 'stderr classification replay clobbered evidence' >&2; exit 1; }
for bad_stderr in \
  "$root/error-pq-stderr.raw" "$root/warning-pq-stderr.raw" "$root/unknown-pq-stderr.raw" \
  "$root/malformed-pq-stderr.raw" "$root/extra-pq-stderr.raw" "$root/encoding-pq-stderr.raw"; do
 case $bad_stderr in
  *error*) body='<Objs><Obj S="error" /></Objs>';;
  *warning*) body='<Objs><Obj S="warning" /></Objs>';;
  *unknown*) body='<Objs><Record S="progress" /></Objs>';;
  *malformed*) body='<Objs><Obj S="progress" ></Objs>';;
  *extra*) body='<Objs><Obj S="progress" /></Objs>EXTRA';;
  *encoding*) body='<Objs><Obj S="progress"><AV>'$'\x81''</AV></Obj></Objs>';;
 esac
 printf '%s\r\n' "$body" >"$bad_stderr"
 if [[ $bad_stderr == *encoding* ]]; then printf '\x81' >>"$bad_stderr"; fi
 # Prefix is supplied separately so every case exercises the classifier.
 python3 -I -E - "$bad_stderr" <<'PY'
import sys
p=sys.argv[1]; body=open(p,'rb').read(); prefix=(b'** WARNING: connection is not using a post-quantum key exchange algorithm.\r\n'+b'** This session may be vulnerable to "store now, decrypt later" attacks.\r\n'+b'** The server may need to be upgraded. See https://openssh.com/pq.html\r\n'+b'#< CLIXML\r\n'); open(p,'wb').write(prefix+body)
PY
 set_stderr "$bad_stderr"
 expect_state_reject "$upgrade_wrapper" "$upgrade_state" "bad stderr $bad_stderr"
done
set_stderr "$valid_stderr"; run_state_capture "$upgrade_wrapper" "$upgrade_state" --resume >/dev/null

# Receipt publication is create-once: occupied, duplicate-content, symlink, and
# unrelated hard-link states must all fail closed without changing old intent.
saved_upgrade=$root/saved-transport-upgrade.json; cp -- "$upgrade_receipt" "$saved_upgrade"; chmod 0600 "$saved_upgrade"
printf occupied >"$upgrade_receipt"; chmod 0600 "$upgrade_receipt"
expect_state_reject "$upgrade_wrapper" "$upgrade_state" 'occupied upgrade receipt'
cp -- "$saved_upgrade" "$upgrade_receipt"; chmod 0600 "$upgrade_receipt"
python3 -I -E - "$upgrade_receipt" <<'PY'
import sys
p=sys.argv[1]; data=open(p,'rb').read(); open(p,'wb').write(data.replace(b'{',b'{"schema_version":1,',1))
PY
chmod 0600 "$upgrade_receipt"; expect_state_reject "$upgrade_wrapper" "$upgrade_state" 'duplicate upgrade receipt'
cp -- "$saved_upgrade" "$upgrade_receipt"; chmod 0600 "$upgrade_receipt"
rm -- "$upgrade_receipt"; ln -s "$saved_upgrade" "$upgrade_receipt"; expect_state_reject "$upgrade_wrapper" "$upgrade_state" 'symlink upgrade receipt'; rm -- "$upgrade_receipt"
cp -- "$saved_upgrade" "$upgrade_receipt"; chmod 0600 "$upgrade_receipt"
ln -- "$upgrade_receipt" "$upgrade_receipt.peer"; expect_state_reject "$upgrade_wrapper" "$upgrade_state" 'hardlink upgrade receipt'; rm -- "$upgrade_receipt.peer"

# A raw-only replay of the old intent is not upgrade-eligible: the receipt is
# mandatory, so the wrapper refuses to proceed rather than silently reusing it.
rawonly_state=$root/rawonly-state; rawonly_wrapper=$root/rawonly-wrapper.sh
make_wrapper_for_state "$rawonly_state" "$rawonly_wrapper"
rawonly_bridge=$rawonly_state/post-vfdqa-bridges/$op
mkdir -- "$rawonly_state/post-vfdqa-bridges" "$rawonly_bridge" "$rawonly_bridge/evidence"
chmod 0700 "$rawonly_state/post-vfdqa-bridges" "$rawonly_bridge" "$rawonly_bridge/evidence"
rawonly_intent=$rawonly_bridge/evidence/windows-legacy-census-capture-intent.json
jq -cnS --slurpfile current "$bridge/evidence/windows-legacy-census-capture-intent.json" \
 --arg old "$old_wrapper_sha" --arg old_checker "$old_checker_sha" --arg raw "$rawonly_bridge/evidence/windows-ssh-raw-census.json" \
 --arg disposition "$rawonly_bridge/evidence/windows-legacy-disposition.json" \
 '$current[0] | .ssh_options=["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes"] |
  .outputs.raw_census=$raw | .outputs.legacy_disposition=$disposition |
  .producer.powershell_wrapper_sha256=$old | .producer.checker.sha256=$old_checker' >"$rawonly_intent"; chmod 0600 "$rawonly_intent"
cp -- "$upgrade_bridge/evidence/windows-ssh-raw-census.json" "$rawonly_bridge/evidence/windows-ssh-raw-census.json"; chmod 0600 "$rawonly_bridge/evidence/windows-ssh-raw-census.json"
expect_state_reject "$rawonly_wrapper" "$rawonly_state" 'raw-only old intent'

published_before=$(sha256sum "$raw_published" "$disposition_published")
VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$linux_wrapper" --resume --manifest "$manifest" --windows-inventory "$inventory" \
 --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" \
 --bridge-root "$bridge" --raw-output "$raw_published" --disposition-output "$disposition_published" \
 --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" \
 --checker "$checker" --expected-checker-sha256 "$checker_sha" --fixture-stdout "$root/stdout.raw" \
 --fixture-stderr "$root/stderr.raw" --fixture-exit-status 0 >/dev/null
[[ $(sha256sum "$raw_published" "$disposition_published") == "$published_before" ]] || { echo 'no-clobber evidence bytes changed' >&2; exit 1; }
if VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$linux_wrapper" --execute --manifest "$manifest" --windows-inventory "$inventory" \
 --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" \
 --bridge-root "$bridge" --raw-output "$raw_published" --disposition-output "$disposition_published" \
 --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" \
 --checker "$checker" --expected-checker-sha256 "$checker_sha" --fixture-stdout "$root/stdout.raw" \
 --fixture-stderr "$root/stderr.raw" --fixture-exit-status 0 >/dev/null 2>&1; then
 echo 'execute replay accepted existing intent/evidence' >&2; exit 1
fi

# Crash after raw staging fsync but before no-replace link: resume validates the
# staged raw evidence, promotes it without SSH, then regenerates disposition.
saved_raw=$root/saved-raw.json; cp -- "$raw_published" "$saved_raw"; chmod 0600 "$saved_raw"
rm -f -- "$raw_published" "$disposition_published"
raw_stage=$bridge/evidence/.windows-ssh-raw-census.json.staging.$(sha256sum "$saved_raw"|awk '{print $1}')
cp -- "$saved_raw" "$raw_stage"; chmod 0600 "$raw_stage"
VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$linux_wrapper" --resume --manifest "$manifest" --windows-inventory "$inventory" \
 --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" \
 --bridge-root "$bridge" --raw-output "$raw_published" --disposition-output "$disposition_published" \
 --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" \
 --checker "$checker" --expected-checker-sha256 "$checker_sha" >/dev/null
[[ ! -e $raw_stage && $(sha256sum "$raw_published"|awk '{print $1}') == "$(sha256sum "$saved_raw"|awk '{print $1}')" ]] || { echo 'raw staging crash was not recovered' >&2; exit 1; }

# Crash after link but before staging unlink (nlink2) is the only recognized
# hard-link state. Resume removes the same-inode staging peer.
ln -- "$raw_published" "$raw_stage"; [[ $(stat -c %h "$raw_published") == 2 ]] || exit 1
VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$linux_wrapper" --resume --manifest "$manifest" --windows-inventory "$inventory" \
 --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" \
 --bridge-root "$bridge" --raw-output "$raw_published" --disposition-output "$disposition_published" \
 --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" \
 --checker "$checker" --expected-checker-sha256 "$checker_sha" >/dev/null
[[ ! -e $raw_stage && $(stat -c %h "$raw_published") == 1 ]] || { echo 'link-before-unlink raw crash was not recovered' >&2; exit 1; }

# Partial finals/staging and a changed capture intent hard-stop.
rm -f -- "$raw_published" "$disposition_published"; printf partial >"$raw_published"; chmod 0600 "$raw_published"
if VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$linux_wrapper" --resume --manifest "$manifest" --windows-inventory "$inventory" --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" --bridge-root "$bridge" --raw-output "$raw_published" --disposition-output "$disposition_published" --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" --checker "$checker" --expected-checker-sha256 "$checker_sha" >/dev/null 2>&1; then echo 'partial raw final escaped' >&2; exit 1; fi
rm -f -- "$raw_published"; printf partial >"$bridge/evidence/.windows-ssh-raw-census.json.staging.bad"; chmod 0600 "$bridge/evidence/.windows-ssh-raw-census.json.staging.bad"
if VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$linux_wrapper" --resume --manifest "$manifest" --windows-inventory "$inventory" --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" --bridge-root "$bridge" --raw-output "$raw_published" --disposition-output "$disposition_published" --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" --checker "$checker" --expected-checker-sha256 "$checker_sha" >/dev/null 2>&1; then echo 'partial raw staging escaped' >&2; exit 1; fi
rm -f -- "$bridge/evidence/.windows-ssh-raw-census.json.staging.bad"
changed_manifest=$root/changed-manifest.json; jq '.approval.required_absent_now=false' "$manifest" >"$changed_manifest"; chmod 0600 "$changed_manifest"
if VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1 "$linux_wrapper" --resume --manifest "$changed_manifest" --windows-inventory "$inventory" --incident "$incident" --tombstone "$tombstone" --old-operation-id "$op" --target "$(jq -r '.windows.ssh_target' "$manifest")" --bridge-root "$bridge" --raw-output "$raw_published" --disposition-output "$disposition_published" --probe "$probe" --expected-probe-sha256 "$probe_sha" --expected-wrapper-sha256 "$wrapper_contract_sha" --checker "$checker" --expected-checker-sha256 "$checker_sha" >/dev/null 2>&1; then echo 'different capture intent escaped' >&2; exit 1; fi

if rg -i --quiet '(^|[^[:alnum:]_-])(Enable-ScheduledTask|Register-ScheduledTask|Unregister-ScheduledTask|Start-ScheduledTask|Stop-ScheduledTask|Remove-Item|Move-Item|Copy-Item|Set-Acl|Stop-Process)([^[:alnum:]_-]|$)' "$probe"; then
 echo 'PowerShell probe contains a mutation cmdlet' >&2; exit 1
fi
printf 'post-VFDQA legacy census strict/negative fixtures passed\n'
