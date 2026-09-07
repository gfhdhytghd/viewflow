#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

readonly OPERATION_ID=55d06e8f96aa4adc9010e53612979374
readonly MANIFEST=/home/wilf/data/viewflow/deploy/post-abort-replay6-operation55-manifest.json
readonly MANIFEST_SHA256=159067efffeb62de2e1868adbb3c99f5546a89fe12c60f9d9a23e131f425b0bc

mode='' approval_sha='' script_sha='' fixture_runtime='' fixture_windows='' fixture_root=''
temporary_files=()
die() { printf 'post-VFDQA reconcile: %s\n' "$*" >&2; exit 1; }
cleanup() { ((${#temporary_files[@]} == 0)) || rm -f -- "${temporary_files[@]}"; }
trap cleanup EXIT
sha256() { sha256sum -- "$1" | awk '{print $1}'; }
require_sha() { [[ $1 =~ ^[0-9a-f]{64}$ ]] || die 'expected lowercase SHA-256'; }

while (($#)); do
  case $1 in
    --offline-preflight) [[ -z $mode ]] || die 'select one mode'; mode=offline; shift ;;
    --execute) [[ -z $mode ]] || die 'select one mode'; mode=execute; shift ;;
    --fixture) [[ -z $mode ]] || die 'select one mode'; mode=fixture; shift ;;
    --approval-sha256) (($# >= 2)) || die 'missing approval SHA'; approval_sha=$2; shift 2 ;;
    --script-sha256) (($# >= 2)) || die 'missing script SHA'; script_sha=$2; shift 2 ;;
    --fixture-runtime-proof) (($# >= 2)) || die 'missing fixture runtime proof'; fixture_runtime=$2; shift 2 ;;
    --fixture-windows-proof) (($# >= 2)) || die 'missing fixture Windows proof'; fixture_windows=$2; shift 2 ;;
    --fixture-root) (($# >= 2)) || die 'missing fixture root'; fixture_root=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $mode == offline || $mode == execute || $mode == fixture ]] || die 'select a mode'
[[ $(id -u) == 1000 && $HOME == /home/wilf ]] || die 'requires uid 1000 and HOME=/home/wilf'
[[ -f $MANIFEST && ! -L $MANIFEST && $(stat -c '%u:%a:%h' "$MANIFEST") == 1000:600:1 ]] || die 'manifest metadata differs'
[[ $(sha256 "$MANIFEST") == "$MANIFEST_SHA256" ]] || die 'manifest SHA differs'

strict_json() {
  python3 -I -E - "$1" <<'PY'
import json,sys
def pairs(items):
 d={}
 for k,v in items:
  if k in d: raise ValueError("duplicate key")
  d[k]=v
 return d
with open(sys.argv[1],"rb") as f: raw=f.read()
json.loads(raw.decode("utf-8"),object_pairs_hook=pairs)
PY
}

validate_manifest() {
  strict_json "$MANIFEST"
  jq -e --arg op "$OPERATION_ID" '
    keys == ["adopted_artifacts","approval","execution_authorized","incident_classification","linux_runtime","operation_id","outputs","required_absent","schema_version","state","vfdqa_binary","windows"] and
    .schema_version == 1 and .state == "viewflow-post-vfdqa-replay6-reconciliation-manifest" and
    .execution_authorized == false and .operation_id == $op and
    .incident_classification == ["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"] and
    (.adopted_artifacts|length) == 8 and (.required_absent|length) == 6 and
    (.outputs|keys) == ["incident","linux_runtime_inventory","terminal","windows_inventory"] and
    .linux_runtime.viewflow.main_pid == 3202576 and .linux_runtime.viewflow.start_ticks == 13449475 and
    .linux_runtime.deskflow.processes[0].pid == 60344 and .linux_runtime.deskflow.processes[0].start_ticks == 16812820 and
    .linux_runtime.deskflow.processes[1].pid == 60366 and .linux_runtime.deskflow.processes[1].start_ticks == 16812823 and
    .linux_runtime.deskflow.processes[2].pid == 60411 and .linux_runtime.deskflow.processes[2].start_ticks == 16812843 and
    .windows.observed_deployment_task_xml_sha256 != .windows.expected_deployment_task_xml_sha256
  ' "$MANIFEST" >/dev/null || die 'manifest contract invalid'
}

validate_regular_hash() {
  local label=$1 path=$2 expected=$3
  [[ -f $path && ! -L $path && $(stat -c '%u:%a:%h' "$path") == 1000:600:1 ]] || die "$label metadata differs"
  [[ $(sha256 "$path") == "$expected" ]] || die "$label SHA differs"
}

validate_adopted() {
  local row label path expected
  while IFS= read -r row; do
    label=$(jq -r '.key' <<<"$row"); path=$(jq -r '.value.path' <<<"$row"); expected=$(jq -r '.value.sha256' <<<"$row")
    validate_regular_hash "$label" "$path" "$expected"
  done < <(jq -c '.adopted_artifacts|to_entries[]' "$MANIFEST")
}

validate_vfdqa() {
  local p expected authorization receipt
  p=$(jq -r '.vfdqa_binary.path' "$MANIFEST"); expected=$(jq -r '.vfdqa_binary.sha256' "$MANIFEST")
  authorization=$(jq -r '.adopted_artifacts.invalid_provenance_authorization.path' "$MANIFEST")
  receipt=$(jq -r '.adopted_artifacts.vfdqa_json.path' "$MANIFEST")
  validate_regular_hash VFDQA001 "$p" "$expected"
  python3 -I -E - "$p" "$OPERATION_ID" \
    "$(jq -r '.vfdqa_binary.marker_sha256' "$MANIFEST")" \
    "$(jq -r '.vfdqa_binary.authorization_sha256' "$MANIFEST")" \
    "$(jq -r '.coordinator_instance_id' "$authorization")" \
    "$(jq -r '.marker_created_at_unix_ms' "$receipt")" "$(jq -r '.abort_committed_at_unix_ms' "$receipt")" <<'PY'
import hashlib,sys,uuid
p,op,marker_sha,auth_sha,coordinator,marker_ms,abort_ms=sys.argv[1:]; b=open(p,'rb').read()
if len(b)!=384 or b[:8]!=b'VFDQA001' or b[8:13]!=bytes((1,1,1,3,1)) or any(b[13:16]): raise SystemExit(1)
marker=b[16:272]
if marker[:13]!=b'VFDQT001\x01\x01\x02\x01\x01' or hashlib.sha256(marker).hexdigest()!=marker_sha: raise SystemExit(1)
encoded=op.encode()
if marker[13]!=len(encoded) or any(marker[14:16]) or marker[16:16+len(encoded)]!=encoded or any(marker[16+len(encoded):144]): raise SystemExit(1)
if marker[144:160]!=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes or marker[160:176]!=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes: raise SystemExit(1)
if marker[176:192]!=uuid.UUID(coordinator).bytes or int.from_bytes(marker[192:200],'little')!=int(marker_ms) or int.from_bytes(marker[200:208],'little')!=1 or any(marker[208:]): raise SystemExit(1)
if b[272:304].hex()!=marker_sha or b[304:336].hex()!=auth_sha or int.from_bytes(b[336:344],'little')!=int(abort_ms) or any(b[344:352]): raise SystemExit(1)
if hashlib.sha256(b[:352]).digest()!=b[352:384]: raise SystemExit(1)
PY
  jq -e --arg op "$OPERATION_ID" --arg marker "$(jq -r '.vfdqa_binary.marker_sha256' "$MANIFEST")" --arg path "$authorization" '
    keys==["authenticated_v13_peer_receipt_sha256","authorization_receipt_path","coordinator_instance_id","deployment_publish_receipt_sha256","initial_force_release_executed","installer_exit_receipt_sha256","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_generation","marker_handoff_receipt_sha256","marker_sha256","old_linux_deskflow_core_sha256","old_linux_deskflow_sha256","old_linux_viewflowd_sha256","old_windows_rollback_sha256","old_windows_task_xml_sha256","old_windows_viewflowd_sha256","old_windows_wrapper_sha256","operation_id","pre_mutation_retry_receipt_sha256","protocol_2_1","rollback_performed","schema_version","state","windows_live_proof_sha256","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
    .schema_version==2 and .state=="viewflow-deployment-quarantine-failed-pre-mutation-installer-baseline-restored-abort-authorized" and
    .operation_id==$op and .marker_sha256==$marker and .marker_generation=="1" and .authorization_receipt_path==$path and
    .initial_force_release_executed==false and .rollback_performed==false and .windows_rollback_receipt_sha256==null and .protocol_2_1==false and
    (.coordinator_instance_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
  ' "$authorization" >/dev/null || die 'invalid-provenance authorization cross-binding differs'
  jq -e --arg op "$OPERATION_ID" --arg marker "$(jq -r '.vfdqa_binary.marker_sha256' "$MANIFEST")" \
    --arg auth "$authorization" --arg auth_sha "$(jq -r '.vfdqa_binary.authorization_sha256' "$MANIFEST")" --arg binary "$p" \
    --arg coordinator "$(jq -r '.coordinator_instance_id' "$authorization")" '
    keys==["abort_authorization_path","abort_authorization_sha256","abort_claim_path","abort_committed_at_unix_ms","abort_committed_at_utc","abort_point","abort_receipt_path","aborted_marker_sha256","coordinator_instance_id","deployment_release_claimed","initial_force_release_executed","marker_created_at_unix_ms","marker_generation","marker_path","operation_id","protocol_2_1","protocol_version","replayed","rollback_performed","schema_version","source_display_id","state","target_device_id","windows_rollback_receipt_sha256"] and
    .schema_version==2 and .state=="deployment-quarantine-aborted" and .operation_id==$op and .coordinator_instance_id==$coordinator and
    .aborted_marker_sha256==$marker and .marker_generation=="1" and .source_display_id=="00000000-0000-0000-0000-000000000101" and
    .target_device_id=="00000000-0000-0000-0000-000000000002" and .protocol_version=="1.3" and .protocol_2_1==false and
    .abort_authorization_path==$auth and .abort_authorization_sha256==$auth_sha and .abort_receipt_path==$binary and
    .abort_point=="abort-claim-unlink-and-parent-directory-fsync" and .deployment_release_claimed==false and
    .initial_force_release_executed==false and .rollback_performed==false and .windows_rollback_receipt_sha256==null and
    (.marker_created_at_unix_ms|test("^[1-9][0-9]*$")) and (.abort_committed_at_unix_ms|test("^[1-9][0-9]*$"))
  ' "$receipt" >/dev/null || die 'VFDQA JSON cross-binding differs'
}

validate_abort_state() {
  local p
  for p in $(jq -r '.required_absent[]' "$MANIFEST"); do [[ ! -e $p && ! -L $p ]] || die "required absent path exists: $p"; done
  jq -e --arg op "$OPERATION_ID" '
    .schema_version==2 and .state=="deployment-quarantine-aborted" and .operation_id==$op and
    .deployment_release_claimed==false and .initial_force_release_executed==false and
    .rollback_performed==false and .windows_rollback_receipt_sha256==null
  ' "$(jq -r '.adopted_artifacts.vfdqa_json.path' "$MANIFEST")" >/dev/null || die 'VFDQA JSON contract differs'
}

process_ticks() { sed -n 's/^[0-9][0-9]* (.*) //p' "/proc/$1/stat" | awk '{print $20}'; }
process_ppid() { sed -n 's/^[0-9][0-9]* (.*) //p' "/proc/$1/stat" | awk '{print $2}'; }
process_cgroup() { awk -F: '$1=="0"{print $3}' "/proc/$1/cgroup"; }

observed_exec_start_sha() {
  local unit=$1 obj response
  obj=$(busctl --user --json=short call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetUnit s "$unit" | jq -er 'select(.type=="o" and (.data|length)==1)|.data[0]')
  response=$(busctl --user --json=short get-property org.freedesktop.systemd1 "$obj" org.freedesktop.systemd1.Service ExecStart)
  jq -ceS 'select(.type=="a(sasbttttuii)" and (.data|length)==1)|.data[0] as $v|{argv:$v[1],ignore_errors:$v[2],path:$v[0]}' <<<"$response" | sha256sum | awk '{print $1}'
}

validate_live_runtime() {
  local section unit cgroup pid expected actual_set expected_set
  for section in viewflow deskflow; do
    unit=$(jq -r ".linux_runtime.$section.unit" "$MANIFEST"); cgroup=$(jq -r ".linux_runtime.$section.control_group" "$MANIFEST")
    [[ $(systemctl --user show -p ActiveState --value "$unit") == active &&
       $(systemctl --user show -p SubState --value "$unit") == running &&
       $(systemctl --user show -p Transient --value "$unit") == yes &&
       $(systemctl --user show -p KillMode --value "$unit") == control-group &&
       $(systemctl --user show -p InvocationID --value "$unit") == "$(jq -r ".linux_runtime.$section.invocation_id" "$MANIFEST")" &&
       $(systemctl --user show -p ControlGroup --value "$unit") == "$cgroup" &&
       $(observed_exec_start_sha "$unit") == "$(jq -r ".linux_runtime.$section.exec_start_sha256" "$MANIFEST")" ]] || die "$section transient identity differs"
  done
  pid=$(jq -r '.linux_runtime.viewflow.main_pid' "$MANIFEST")
  [[ $(systemctl --user show -p MainPID --value "$(jq -r '.linux_runtime.viewflow.unit' "$MANIFEST")") == "$pid" &&
     $(process_ticks "$pid") == "$(jq -r '.linux_runtime.viewflow.start_ticks' "$MANIFEST")" &&
     $(sha256 "/proc/$pid/exe") == "$(jq -r '.linux_runtime.viewflow.exe_sha256' "$MANIFEST")" &&
     $(process_cgroup "$pid") == "$(jq -r '.linux_runtime.viewflow.control_group' "$MANIFEST")" ]] || die 'Viewflow runtime tuple differs'
  actual_set=$(sort -n "/sys/fs/cgroup$(jq -r '.linux_runtime.viewflow.control_group' "$MANIFEST")/cgroup.procs" | paste -sd, -)
  [[ $actual_set == "$pid" ]] || die 'Viewflow cgroup PID set differs'
  [[ $(systemctl --user show -p MainPID --value "$(jq -r '.linux_runtime.deskflow.unit' "$MANIFEST")") == "$(jq -r '.linux_runtime.deskflow.processes[0].pid' "$MANIFEST")" ]] || die 'Deskflow MainPID differs'
  while IFS= read -r section; do
    pid=$(jq -r '.pid' <<<"$section"); expected=$(jq -r '.parent_pid // empty' <<<"$section")
    [[ -e /proc/$pid && $(process_ticks "$pid") == "$(jq -r '.start_ticks' <<<"$section")" &&
       $(sha256 "/proc/$pid/exe") == "$(jq -r '.exe_sha256' <<<"$section")" &&
       $(process_cgroup "$pid") == "$(jq -r '.linux_runtime.deskflow.control_group' "$MANIFEST")" ]] || die "Deskflow PID $pid differs"
    [[ -z $expected || $(process_ppid "$pid") == "$expected" ]] || die "Deskflow PID $pid ancestry differs"
  done < <(jq -c '.linux_runtime.deskflow.processes[]' "$MANIFEST")
  actual_set=$(sort -n "/sys/fs/cgroup$(jq -r '.linux_runtime.deskflow.control_group' "$MANIFEST")/cgroup.procs" | paste -sd, -)
  expected_set=$(jq -r '[.linux_runtime.deskflow.processes[].pid]|sort|join(",")' "$MANIFEST")
  [[ $actual_set == "$expected_set" ]] || die 'Deskflow cgroup PID set differs'
}

validate_fixture_runtime() {
  strict_json "$fixture_runtime"
  jq -e --arg op "$OPERATION_ID" --slurpfile m "$MANIFEST" '
    keys==["boot_id","cgroup_pid_sets","observed_at_utc","operation_id","processes","state","units"] and .state=="CURRENT_RUNTIME_REATTESTED" and
    .operation_id==$op and
    .units.viewflow==($m[0].linux_runtime.viewflow|del(.start_ticks,.exe_sha256)) and
    .units.deskflow==(($m[0].linux_runtime.deskflow|del(.processes)) + {main_pid:$m[0].linux_runtime.deskflow.processes[0].pid}) and
    .processes.viewflow==[{role:"viewflow",pid:$m[0].linux_runtime.viewflow.main_pid,parent_pid:null,start_ticks:$m[0].linux_runtime.viewflow.start_ticks,exe_sha256:$m[0].linux_runtime.viewflow.exe_sha256,control_group:$m[0].linux_runtime.viewflow.control_group}] and
    .processes.deskflow==[$m[0].linux_runtime.deskflow.processes[] + {control_group:$m[0].linux_runtime.deskflow.control_group}] and
    .cgroup_pid_sets=={viewflow:[3202576],deskflow:[60344,60366,60411]} and
    (.boot_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
    (.observed_at_utc|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
  ' "$fixture_runtime" >/dev/null || die 'fixture runtime proof differs'
}

capture_live_runtime() {
  local out=$1 view_unit desk_unit view_pid desk_main desk_gui desk_core view_cgroup desk_cgroup
  view_unit=$(jq -r '.linux_runtime.viewflow.unit' "$MANIFEST"); desk_unit=$(jq -r '.linux_runtime.deskflow.unit' "$MANIFEST")
  view_pid=$(systemctl --user show -p MainPID --value "$view_unit"); desk_main=$(systemctl --user show -p MainPID --value "$desk_unit")
  desk_gui=$(jq -r '.linux_runtime.deskflow.processes[1].pid' "$MANIFEST"); desk_core=$(jq -r '.linux_runtime.deskflow.processes[2].pid' "$MANIFEST")
  view_cgroup=$(systemctl --user show -p ControlGroup --value "$view_unit"); desk_cgroup=$(systemctl --user show -p ControlGroup --value "$desk_unit")
  jq -cnS --arg op "$OPERATION_ID" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" --arg at "$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')" \
    --arg vu "$view_unit" --arg du "$desk_unit" --arg vc "$view_cgroup" --arg dc "$desk_cgroup" \
    --arg va "$(systemctl --user show -p ActiveState --value "$view_unit")" --arg vs "$(systemctl --user show -p SubState --value "$view_unit")" \
    --arg vt "$(systemctl --user show -p Transient --value "$view_unit")" --arg vk "$(systemctl --user show -p KillMode --value "$view_unit")" \
    --arg vi "$(systemctl --user show -p InvocationID --value "$view_unit")" --arg vx "$(observed_exec_start_sha "$view_unit")" \
    --arg da "$(systemctl --user show -p ActiveState --value "$desk_unit")" --arg ds "$(systemctl --user show -p SubState --value "$desk_unit")" \
    --arg dt "$(systemctl --user show -p Transient --value "$desk_unit")" --arg dk "$(systemctl --user show -p KillMode --value "$desk_unit")" \
    --arg di "$(systemctl --user show -p InvocationID --value "$desk_unit")" --arg dx "$(observed_exec_start_sha "$desk_unit")" \
    --argjson vp "$view_pid" --argjson dm "$desk_main" --argjson dg "$desk_gui" --argjson dcop "$desk_core" \
    --argjson vticks "$(process_ticks "$view_pid")" --argjson dmticks "$(process_ticks "$desk_main")" \
    --argjson dgticks "$(process_ticks "$desk_gui")" --argjson dcticks "$(process_ticks "$desk_core")" \
    --arg vsha "$(sha256 "/proc/$view_pid/exe")" --arg dmsha "$(sha256 "/proc/$desk_main/exe")" \
    --arg dgsha "$(sha256 "/proc/$desk_gui/exe")" --arg dcsha "$(sha256 "/proc/$desk_core/exe")" \
    --argjson dgppid "$(process_ppid "$desk_gui")" --argjson dcppid "$(process_ppid "$desk_core")" '
    {state:"CURRENT_RUNTIME_REATTESTED",operation_id:$op,observed_at_utc:$at,boot_id:$boot,
     units:{viewflow:{unit:$vu,active_state:$va,sub_state:$vs,transient:$vt,kill_mode:$vk,invocation_id:$vi,control_group:$vc,exec_start_sha256:$vx,main_pid:$vp},
            deskflow:{unit:$du,active_state:$da,sub_state:$ds,transient:$dt,kill_mode:$dk,invocation_id:$di,control_group:$dc,exec_start_sha256:$dx,main_pid:$dm}},
     cgroup_pid_sets:{viewflow:[$vp],deskflow:[$dm,$dg,$dcop]|sort},
     processes:{viewflow:[{role:"viewflow",pid:$vp,parent_pid:null,start_ticks:$vticks,exe_sha256:$vsha,control_group:$vc}],
                deskflow:[{role:"bubblewrap",pid:$dm,parent_pid:null,start_ticks:$dmticks,exe_sha256:$dmsha,control_group:$dc},
                          {role:"gui",pid:$dg,parent_pid:$dgppid,start_ticks:$dgticks,exe_sha256:$dgsha,control_group:$dc},
                          {role:"core",pid:$dcop,parent_pid:$dcppid,start_ticks:$dcticks,exe_sha256:$dcsha,control_group:$dc}]}}
  ' >"$out"
  validate_fixture_runtime_file "$out"
}

validate_fixture_runtime_file() { local saved=$fixture_runtime; fixture_runtime=$1; validate_fixture_runtime; fixture_runtime=$saved; }

windows_probe() {
  local proof=$1 wrapper wrapper_encoded payload
  read -r -d '' payload <<'PS' || true
$ErrorActionPreference='Stop'
function VfHash([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
function VfSid([string]$v){try{([Security.Principal.SecurityIdentifier]::new($v)).Value}catch{([Security.Principal.NTAccount]::new($v)).Translate([Security.Principal.SecurityIdentifier]).Value}}
function VfAcl([string]$p){$a=Get-Acl -LiteralPath $p -ErrorAction Stop;[ordered]@{owner_sid=(VfSid $a.Owner);protected=[bool]$a.AreAccessRulesProtected;rules=@($a.Access|ForEach-Object{[ordered]@{sid=(VfSid $_.IdentityReference.Value);type=[string]$_.AccessControlType;rights=[string]$_.FileSystemRights;inherited=[bool]$_.IsInherited;inheritance=[string]$_.InheritanceFlags;propagation=[string]$_.PropagationFlags}})}}
$op='55d06e8f96aa4adc9010e53612979374';$sid='S-1-5-21-1940417919-1835306932-1635351729-1001';$root='C:\Users\wilf\AppData\Local\Viewflow\Deployments\55d06e8f96aa4adc9010e53612979374'
$rootItem=Get-Item -LiteralPath $root -Force -ErrorAction Stop;$members=@(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop|Sort-Object Name|ForEach-Object{[ordered]@{name=$_.Name;directory=[bool]$_.PSIsContainer;reparse=[bool](($_.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0);length=if($_.PSIsContainer){$null}else{[long]$_.Length};sha256=if($_.PSIsContainer){$null}else{VfHash $_.FullName};acl=VfAcl $_.FullName}})
$enc=New-Object Text.UnicodeEncoding($false,$true);function VfTaskHash([string]$name){$xml=Export-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction Stop;$b=$enc.GetPreamble()+$enc.GetBytes($xml);$s=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','').ToLowerInvariant()}finally{$s.Dispose()}}
$peer=Get-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer' -ErrorAction Stop;$deploy=Get-ScheduledTask -TaskPath '\' -TaskName ('Viewflow Deployment '+$op) -ErrorAction Stop
$rows=@(Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'"|Where-Object{$_.ExecutablePath -eq 'C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe'});if($rows.Count-ne1){throw 'peer process count differs'};$p=$rows[0]
$installed='viewflowd.exe','viewflow-client.ps1','rollback-viewflow.ps1'|ForEach-Object{$q=Join-Path 'C:\Users\wilf\AppData\Local\Programs\Viewflow' $_;[ordered]@{name=$_;sha256=VfHash $q;acl=VfAcl $q}}
[ordered]@{schema_version=1;state='viewflow-post-vfdqa-windows-census';operation_id=$op;observed_at_utc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ');transport='stdin-base64-single-scriptblock-stop-on-error-v1';operation_root=[ordered]@{path=$root;reparse=[bool](($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0);acl=VfAcl $root;members=$members};deployment_task=[ordered]@{state=[string]$deploy.State;task_xml_sha256=VfTaskHash ('Viewflow Deployment '+$op);action_execute=[string]$deploy.Actions[0].Execute;action_arguments=[string]$deploy.Actions[0].Arguments;working_directory=[string]$deploy.Actions[0].WorkingDirectory};installed=$installed;peer=[ordered]@{task_state=[string]$peer.State;task_xml_sha256=VfTaskHash 'Viewflow Peer';pid=[int]$p.ProcessId;parent_pid=[int]$p.ParentProcessId;creation_date=$p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');session_id=[int]$p.SessionId;owner_sid=[string](Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid;exe_sha256=VfHash $p.ExecutablePath;command_line=[string]$p.CommandLine};classification=[ordered]@{physical_abort='VFDQA_COMMITTED';authorization_provenance='AUTHZ_PROVENANCE_INVALID';prior_normal_terminal='TERMINAL_ABSENT';current_runtime='CURRENT_RUNTIME_REATTESTED';windows_baseline='WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION';normal_release_ready=$false;fresh_bridge_ready=$false}}|ConvertTo-Json -Compress -Depth 8
PS
  # shellcheck disable=SC2016 # PowerShell variables must remain literal here.
  wrapper='try{$b=[Console]::In.ReadToEnd();$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b));&([ScriptBlock]::Create($s));if(-not $?){exit 1}}catch{[Console]::Error.WriteLine($_.Exception.ToString());exit 1};exit 0'
  wrapper_encoded=$(printf '%s' "$wrapper" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  printf '%s' "$payload" | base64 -w0 | ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes "$(jq -r '.windows.ssh_target' "$MANIFEST")" powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$wrapper_encoded" >"$proof"
}

validate_windows_proof() {
  strict_json "$1"
  jq -e --arg op "$OPERATION_ID" --slurpfile m "$MANIFEST" '
    keys==["classification","deployment_task","installed","observed_at_utc","operation_id","operation_root","peer","schema_version","state","transport"] and
    .schema_version==1 and .state=="viewflow-post-vfdqa-windows-census" and .operation_id==$op and
    .transport=="stdin-base64-single-scriptblock-stop-on-error-v1" and
    .classification=={physical_abort:"VFDQA_COMMITTED",authorization_provenance:"AUTHZ_PROVENANCE_INVALID",prior_normal_terminal:"TERMINAL_ABSENT",current_runtime:"CURRENT_RUNTIME_REATTESTED",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",normal_release_ready:false,fresh_bridge_ready:false} and
    .operation_root.path==$m[0].windows.operation_root and .operation_root.reparse==false and
    .operation_root.acl.owner_sid==$m[0].windows.user_sid and .operation_root.acl.protected==true and
    (.operation_root.acl.rules|length)==2 and
    ([.operation_root.acl.rules[].sid]|sort)==([$m[0].windows.user_sid,"S-1-5-18"]|sort) and
    ([.operation_root.acl.rules[]|select(.type!="Allow" or .rights!="FullControl" or .inherited!=false or .inheritance!="ContainerInherit, ObjectInherit" or .propagation!="None")]|length)==0 and
    (.operation_root.members|length)==14 and
    ([.operation_root.members[]|select(.directory or .reparse)]|length)==0 and
    ([.operation_root.members[]|{key:.name,value:.sha256}]|from_entries)==$m[0].windows.expected_members and
    .deployment_task.state=="Disabled" and .deployment_task.task_xml_sha256==$m[0].windows.observed_deployment_task_xml_sha256 and
    .deployment_task.task_xml_sha256!=$m[0].windows.expected_deployment_task_xml_sha256 and
    .peer.task_state=="Running" and .peer.task_xml_sha256==$m[0].windows.peer_task_xml_sha256 and
    .peer.pid==$m[0].windows.peer_process.pid and .peer.parent_pid==$m[0].windows.peer_process.parent_pid and
    .peer.creation_date==$m[0].windows.peer_process.creation_date and .peer.session_id==1 and
    .peer.owner_sid==$m[0].windows.user_sid and .peer.exe_sha256==$m[0].windows.peer_process.exe_sha256 and
    ([.installed[]|{key:.name,value:.sha256}]|from_entries)==$m[0].windows.installed_baseline and
    ([.installed[].acl.protected]|all(.==false)) and
    (.observed_at_utc|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
  ' "$1" >/dev/null || die 'hardened Windows census invalid'
}

recover_interrupted_publish() {
  python3 -I -E - "$1" <<'PY'
import os,stat,sys
dst=sys.argv[1]
try: st=os.lstat(dst)
except FileNotFoundError: raise SystemExit(0)
if st.st_nlink==1: raise SystemExit(0)
names={
 'post-abort-windows-inventory.replay6.schema2.json':'.viewflow-inventory-copy.',
 'post-abort-linux-runtime-inventory.replay6.schema2.json':'.viewflow-runtime-copy.',
 'post-abort-incident-terminal.replay6.schema2.json':'.viewflow-incident.',
 'failed-pre-mutation-abort-terminal.replay6.schema2.json':'.viewflow-terminal.'}
prefix=names.get(os.path.basename(dst))
if prefix is None or not(stat.S_ISREG(st.st_mode) and st.st_uid==1000 and stat.S_IMODE(st.st_mode)==0o600 and st.st_nlink==2): raise SystemExit(66)
parent=os.path.dirname(dst); peers=[]
with os.scandir(parent) as entries:
 for e in entries:
  if e.name.startswith(prefix):
   x=e.stat(follow_symlinks=False)
   if x.st_dev==st.st_dev and x.st_ino==st.st_ino: peers.append(e.path)
if len(peers)!=1: raise SystemExit(66)
peer=os.lstat(peers[0]); current=os.lstat(dst)
if not(peer.st_dev==st.st_dev and peer.st_ino==st.st_ino and peer.st_nlink==2 and
       current.st_dev==st.st_dev and current.st_ino==st.st_ino and current.st_nlink==2): raise SystemExit(66)
os.unlink(peers[0]); dfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
try: os.fsync(dfd)
finally: os.close(dfd)
now=os.lstat(dst)
if now.st_dev!=st.st_dev or now.st_ino!=st.st_ino or now.st_nlink!=1: raise SystemExit(66)
PY
}

publish_once() {
  local src=$1 dst=$2
  chmod 0600 "$src"
  recover_interrupted_publish "$dst"
  python3 -I -E - "$src" "$dst" <<'PY'
import os,stat,sys
src,dst=sys.argv[1:]
def read_all(fd,size):
 out=[]; remaining=size+1
 while remaining:
  chunk=os.read(fd,remaining)
  if not chunk: break
  out.append(chunk); remaining-=len(chunk)
 return b''.join(out)
fd=os.open(src,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 st=os.fstat(fd); data=read_all(fd,st.st_size)
 if not(stat.S_ISREG(st.st_mode) and st.st_uid==1000 and stat.S_IMODE(st.st_mode)==0o600 and st.st_nlink==1 and len(data)==st.st_size): raise SystemExit(66)
 os.fsync(fd)
finally: os.close(fd)
created=False; source_removed=False; dfd=os.open(os.path.dirname(dst),os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
try:
 try: os.link(src,dst,follow_symlinks=False); created=True
 except FileExistsError: pass
 os.fsync(dfd)
 out=os.open(dst,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try: ost=os.fstat(out); actual=read_all(out,ost.st_size)
 finally: os.close(out)
 if created:
  if not(ost.st_dev==st.st_dev and ost.st_ino==st.st_ino and ost.st_nlink==2): raise RuntimeError('created destination identity differs')
 elif ost.st_nlink!=1: raise SystemExit(66)
 if not(stat.S_ISREG(ost.st_mode) and ost.st_uid==1000 and stat.S_IMODE(ost.st_mode)==0o600 and len(actual)==ost.st_size and actual==data):
  raise RuntimeError('created destination bytes differ') if created else SystemExit(17)
 if created:
  os.unlink(src); source_removed=True; os.fsync(dfd)
  out=os.open(dst,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
  try: final=os.fstat(out); final_data=read_all(out,final.st_size)
  finally: os.close(out)
  if not(final.st_dev==st.st_dev and final.st_ino==st.st_ino and final.st_nlink==1 and len(final_data)==final.st_size and final_data==data):
   raise RuntimeError('final single-link destination differs')
except BaseException:
 if created and not source_removed:
  try:
   source_now=os.lstat(src); cur=os.lstat(dst)
   if (source_now.st_dev==st.st_dev and source_now.st_ino==st.st_ino and source_now.st_nlink==2 and
       cur.st_dev==st.st_dev and cur.st_ino==st.st_ino and cur.st_nlink==2):
    os.unlink(dst); os.fsync(dfd)
  except FileNotFoundError: pass
 raise
finally: os.close(dfd)
PY
}

validate_durable_output() {
  recover_interrupted_publish "$1"
  [[ -f $1 && ! -L $1 && $(stat -c '%u:%a:%h' "$1") == 1000:600:1 ]] || die 'durable output metadata differs'
  strict_json "$1"
}

output_path() {
  local key=$1 p
  p=$(jq -r ".outputs.$key" "$MANIFEST")
  if [[ $mode == fixture ]]; then printf '%s/%s\n' "$fixture_root" "${p##*/}"; else printf '%s\n' "$p"; fi
}

build_outputs() {
  local inventory=$1 runtime=$2 inventory_out runtime_out incident_out terminal_out temp observed runtime_sha
  inventory_out=$(output_path windows_inventory); runtime_out=$(output_path linux_runtime_inventory); incident_out=$(output_path incident); terminal_out=$(output_path terminal)
  validate_fixture_runtime_file "$runtime"
  if [[ -e $inventory_out || -L $inventory_out ]]; then
    validate_durable_output "$inventory_out"
    [[ $(jq -cS 'del(.observed_at_utc)' "$inventory") == "$(jq -cS 'del(.observed_at_utc)' "$inventory_out")" ]] || die 'fresh Windows census differs from durable census'
  else temp=$(mktemp --tmpdir="$(dirname "$inventory_out")" .viewflow-inventory-copy.XXXXXX); temporary_files+=("$temp"); cp -- "$inventory" "$temp"; publish_once "$temp" "$inventory_out"; fi
  if [[ -e $runtime_out || -L $runtime_out ]]; then
    validate_durable_output "$runtime_out"
    [[ $(jq -cS 'del(.observed_at_utc)' "$runtime") == "$(jq -cS 'del(.observed_at_utc)' "$runtime_out")" ]] || die 'fresh Linux runtime census differs from durable census'
  else temp=$(mktemp --tmpdir="$(dirname "$runtime_out")" .viewflow-runtime-copy.XXXXXX); temporary_files+=("$temp"); cp -- "$runtime" "$temp"; publish_once "$temp" "$runtime_out"; fi
  validate_windows_proof "$inventory_out"; validate_fixture_runtime_file "$runtime_out"; observed=$(jq -r '.observed_at_utc' "$inventory_out"); runtime_sha=$(sha256 "$runtime_out")
  [[ $mode != execute ]] || validate_live_runtime
  temp=$(mktemp --tmpdir="$(dirname "$incident_out")" .viewflow-incident.XXXXXX); temporary_files+=("$temp")
  jq -cnS --arg op "$OPERATION_ID" --arg manifest "$MANIFEST_SHA256" --arg inventory "$(sha256 "$inventory_out")" --arg runtime "$runtime_sha" --arg at "$observed" '
    {schema_version:2,state:"viewflow-post-vfdqa-incident-terminal-reconciliation-required",operation_id:$op,
     incident_classification:["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"],
     current_runtime_classification:"CURRENT_RUNTIME_REATTESTED",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",
     abort_physically_committed:true,old_authorization_retroactively_validated:false,normal_success_terminal:false,normal_deployment_release:false,
     rollback_performed:false,fresh_bridge_ready:false,old_peer_kept_running:true,linux_transients_kept_running:true,
     manifest_sha256:$manifest,windows_inventory_sha256:$inventory,linux_runtime_inventory_sha256:$runtime,reconciled_at_utc:$at}
  ' >"$temp"; publish_once "$temp" "$incident_out"
  [[ $mode != execute ]] || validate_live_runtime
  temp=$(mktemp --tmpdir="$(dirname "$terminal_out")" .viewflow-terminal.XXXXXX); temporary_files+=("$temp")
  jq -cnS --arg op "$OPERATION_ID" --arg manifest "$MANIFEST_SHA256" --arg incident "$(sha256 "$incident_out")" --arg inventory "$(sha256 "$inventory_out")" --arg runtime "$runtime_sha" --arg at "$observed" '
    {schema_version:2,state:"INVALID_AUTHZ_PROVENANCE_TOMBSTONE",operation_id:$op,
     incident_classification:["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"],
     current_runtime_classification:"CURRENT_RUNTIME_REATTESTED",windows_baseline_proof:"tainted-needs-remediation",
     physical_abort_committed:true,normal_success_terminal:false,normal_deployment_release:false,rollback_performed:false,
     fresh_bridge_ready:false,old_authorization_retroactively_validated:false,old_peer_kept_running:true,
     linux_viewflow_transient_kept_running:true,linux_deskflow_transient_kept_running:true,
     manifest_sha256:$manifest,windows_inventory_sha256:$inventory,incident_receipt_sha256:$incident,
     linux_runtime_reattestation_sha256:$runtime,terminalized_at_utc:$at}
  ' >"$temp"; publish_once "$temp" "$terminal_out"
  [[ $mode != execute ]] || validate_live_runtime
  jq -e '.state=="INVALID_AUTHZ_PROVENANCE_TOMBSTONE" and .fresh_bridge_ready==false and .normal_success_terminal==false' "$terminal_out" >/dev/null
}

validate_manifest; validate_adopted; validate_vfdqa; validate_abort_state
if [[ $mode == offline ]]; then
  [[ ! -e $(jq -r '.approval.path' "$MANIFEST") ]] || die 'reconciliation approval unexpectedly exists'
  printf 'post-VFDQA replay6 offline preflight passed; no live contact or publication\n'; exit 0
fi
if [[ $mode == fixture ]]; then
  [[ $fixture_root == /tmp/* && -d $fixture_root && ! -L $fixture_root && -f $fixture_runtime && -f $fixture_windows ]] || die 'unsafe fixture inputs'
  validate_fixture_runtime; validate_windows_proof "$fixture_windows"; build_outputs "$fixture_windows" "$fixture_runtime"
  printf 'post-VFDQA replay6 fixture reconciliation passed\n'; exit 0
fi
require_sha "$approval_sha"; require_sha "$script_sha"
[[ $(sha256 "${BASH_SOURCE[0]}") == "$script_sha" ]] || die 'script SHA differs'
approval=$(jq -r '.approval.path' "$MANIFEST"); validate_regular_hash approval "$approval" "$approval_sha"; strict_json "$approval"
jq -e --arg op "$OPERATION_ID" --arg manifest "$MANIFEST_SHA256" --arg script "$script_sha" '
  keys==["approved","approved_at_utc","manifest_sha256","operation_id","publication_method","schema_version","script_sha256","state"] and
  .schema_version==1 and .state=="viewflow-post-vfdqa-replay6-reconciliation-execution-approved" and .approved==true and
  .operation_id==$op and .manifest_sha256==$manifest and .script_sha256==$script and
  .publication_method=="create-once-no-replace-and-parent-fsync" and
  (.approved_at_utc|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
' "$approval" >/dev/null || die 'approval contract invalid'
validate_live_runtime
inventory=$(mktemp --tmpdir="$(dirname "$(output_path windows_inventory)")" .viewflow-windows-census.XXXXXX); runtime=$(mktemp --tmpdir="$(dirname "$(output_path linux_runtime_inventory)")" .viewflow-linux-census.XXXXXX); temporary_files+=("$inventory" "$runtime")
windows_probe "$inventory"; validate_windows_proof "$inventory"; validate_live_runtime; capture_live_runtime "$runtime"; validate_adopted; validate_vfdqa; validate_abort_state
build_outputs "$inventory" "$runtime"; validate_live_runtime; validate_abort_state
printf 'post-VFDQA replay6 incident terminal published; remediation remains required\n'
