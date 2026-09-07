#!/usr/bin/env bash
# Create-once successor of a sealed normal-v2.1 launcher.  It deliberately
# retains every v3 deployment candidate embedded in the predecessor; only the
# coordinator implementation is replaced after the sealed successor receipt
# authorizes that exact replacement.
set -Eeuo pipefail
umask 077
readonly STATE=/home/wilf/.local/state/viewflow
readonly BASE_SHA=3984cb3185a1165f260e3f0b83a4fbfdba86420da3317dbec615957e858d2146
die(){ printf 'error: successor launcher: %s\n' "$*" >&2; exit 1; }
usage(){ printf '%s\n' "Usage: $0 (--check-only|--run-check-only|--run-execute|--run-resume) --operation-id HEX32 --coordinator-uuid UUID --v4-coordinator PATH --v4-coordinator-sha256 SHA --v4-provenance PATH --v4-provenance-sha256 SHA --v4-producer PATH --v4-producer-sha256 SHA --successor-receipt PATH --successor-receipt-sha256 SHA --windows-prestate PATH --windows-prestate-sha256 SHA" >&2; }
mode=''; op=''; coord=''; v4=''; v4sha=''; prov=''; provsha=''; producer=''; producersha=''; receipt=''; receiptsha=''; wproof=''; wproofsha=''
while (($#)); do case $1 in
 --check-only|--run-check-only|--run-execute|--run-resume|--execute) [[ -z $mode ]] || die 'one generator mode required'; mode=$1;shift;;
 --operation-id) op=${2-};shift 2;; --coordinator-uuid) coord=${2-};shift 2;;
 --v4-coordinator) v4=${2-};shift 2;; --v4-coordinator-sha256) v4sha=${2-};shift 2;;
 --v4-provenance) prov=${2-};shift 2;; --v4-provenance-sha256) provsha=${2-};shift 2;;
 --v4-producer) producer=${2-};shift 2;; --v4-producer-sha256) producersha=${2-};shift 2;;
 --successor-receipt) receipt=${2-};shift 2;; --successor-receipt-sha256) receiptsha=${2-};shift 2;;
 --windows-prestate) wproof=${2-};shift 2;; --windows-prestate-sha256) wproofsha=${2-};shift 2;;
 -h|--help) usage;exit 0;; *) usage;die "unknown option $1";; esac; done
[[ -n $mode && $op =~ ^[0-9a-f]{32}$ && $coord =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 'canonical mode/operation/coordinator required'
for x in "$v4sha" "$provsha" "$producersha" "$receiptsha" "$wproofsha"; do [[ $x =~ ^[0-9a-f]{64}$ ]] || die 'canonical SHA-256 required'; done
root=$STATE/deployments/$op; base=$root/launch-normal-v21.sh
[[ $receipt == "$root/coordinator-successor-receipt.json" && $wproof == "$root/coordinator-successor-windows-prestate.json" ]] || die 'receipt/WPROOF paths must be canonical operation leaves'
[[ $mode != --execute ]] || die 'durable successor output is forbidden; use --run-execute'
[[ $v4 == /* && $prov == /* && $producer == /* ]] || die 'unsafe paths'
[[ -d $root && ! -L $root && $(stat -c '%a:%u' "$root") == 700:1000 ]] || die 'operation root identity differs'

# One strict descriptor reader validates every immutable authorization input.
values=$(python3 - "$op" "$coord" "$root" "$base" "$BASE_SHA" "$v4" "$v4sha" "$prov" "$provsha" "$producer" "$producersha" "$receipt" "$receiptsha" "$wproof" "$wproofsha" <<'PY'
import datetime,hashlib,json,os,re,stat,sys
op,coord,root,base,bsha,v4,vsha,prov,psha,producer,prsha,receipt,rsha,wproof,wsha=sys.argv[1:]
def die(x): raise SystemExit('error: successor input: '+x)
def req(x,m):
 if not x: die(m)
def pairs(a):
 d={}
 for k,v in a:
  if k in d: die('duplicate key '+repr(k))
  d[k]=v
 return d
def bad(x): die('floating/non-finite '+x)
def read(p,mode):
 try: fd=os.open(p,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 except OSError as e: die('O_NOFOLLOW '+p+': '+str(e))
 try:
  a=os.fstat(fd); req(stat.S_ISREG(a.st_mode) and a.st_uid==1000 and stat.S_IMODE(a.st_mode)==mode and a.st_nlink==1,'identity '+p)
  b=b''
  while True:
   q=os.read(fd,131072)
   if not q: break
   b+=q
  z=os.fstat(fd)
 finally: os.close(fd)
 n=os.lstat(p); ident=lambda q:(q.st_dev,q.st_ino,q.st_size,q.st_uid,stat.S_IMODE(q.st_mode),q.st_nlink,q.st_mtime_ns,q.st_ctime_ns); req(not stat.S_ISLNK(n.st_mode) and ident(a)==ident(z)==ident(n),'changed '+p)
 return b,hashlib.sha256(b).hexdigest()
def doc(p,mode):
 b,s=read(p,mode)
 try:
  t=b.decode(); d,e=json.JSONDecoder(object_pairs_hook=pairs,parse_float=bad,parse_constant=bad).raw_decode(t)
 except Exception as x: die('JSON '+p+': '+str(x))
 req(t[e:].strip()=='' and type(d) is dict,'strict JSON '+p); return d,s
def keys(d,k,n): req(type(d) is dict and list(d)==k,n+' exact ordered schema')
basebytes,actual=read(base,0o500); req(actual==bsha,'base launcher SHA')
text=basebytes.decode('utf-8','strict'); req('viewflow-deployment-marker-no-retry-v4' not in text and 'v4' not in text.lower(),'predecessor must retain v3 candidates')
for p,s,m in ((v4,vsha,0o755),(prov,psha,0o600),(producer,prsha,0o755)):
 _,a=read(p,m); req(a==s,'pinned artifact '+p)
r,actual=doc(receipt,0o600); req(actual==rsha,'receipt SHA')
keys(r,['schema_version','state','operation_id','coordinator_instance_id','replacement_ordinal','created_at_unix_ms','created_at_utc','operation_root','receipt_path','predecessor','marker_cli_alias_override','successor','absence','windows_prestate'],'receipt')
req(r['schema_version']==1 and r['state']=='viewflow-normal-v21-coordinator-successor-authorized' and r['operation_id']==op and r['coordinator_instance_id']==coord and r['replacement_ordinal']==1 and r['operation_root']==root and r['receipt_path']==receipt,'receipt identity')
req(type(r['created_at_unix_ms']) is int and type(r['created_at_utc']) is str and r['created_at_utc']==datetime.datetime.fromtimestamp(r['created_at_unix_ms']/1000,datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),'receipt timestamp')
pred=r['predecessor']; keys(pred,['deployment_publish','marker_handoff','linux_frozen','retirement_terminal','replacement_commit','candidate_manifest','candidate_tree_sha256','launcher','coordinator'],'receipt predecessor')
req(pred['launcher'].get('path')==base and pred['launcher'].get('sha256')==bsha,'receipt predecessor launcher')
cm=pred['candidate_manifest']; keys(cm,['path','sha256'],'receipt predecessor candidate manifest')
req(type(cm['path']) is str and cm['path'].startswith('/') and type(cm['sha256']) is str and re.fullmatch(r'[0-9a-f]{64}',cm['sha256']) is not None,'receipt predecessor candidate manifest path')
manifest,msha=doc(cm['path'],0o600); req(msha==cm['sha256'],'receipt predecessor candidate manifest SHA')
top1=['schema_version','kind','operation_id','coordinator_instance_id','protocol_version','sidecar_protocol_version','marker_generation','recovery_marker_generation','source_display_id','target_device_id','fresh_boundary','coordinator','linux_rust','linux_deskflow','windows']
top2=top1[:11]+['candidate_replacement']+top1[11:]
req(list(manifest) in (top1,top2) and manifest.get('schema_version') in (1,2) and manifest.get('kind')=='viewflow-v21-cross-host-candidate-set' and manifest.get('operation_id')==op and manifest.get('coordinator_instance_id')==coord and manifest.get('protocol_version')=='2.1' and manifest.get('sidecar_protocol_version')==3,'candidate manifest identity')
win=manifest.get('windows'); keys(win,['viewflowd','viewflowd_sha256','native_provenance','native_provenance_sha256','wrapper','wrapper_sha256','launcher','launcher_sha256','installer','installer_sha256','rollback_sha256','old_task_xml_sha256','new_task_xml_override','session_1_user_sid'],'candidate manifest Windows')
sid=re.search(r'--windows-user-sid\s+([^\s\\]+)',text); req(sid is not None and win['session_1_user_sid']==sid.group(1) and win['new_task_xml_override'] is None and type(win['old_task_xml_sha256']) is str and re.fullmatch(r'[0-9a-f]{64}',win['old_task_xml_sha256']) is not None,'candidate Windows identity CLI')
for name,leaf in (('retirement_terminal','candidate-retirement-terminal.json'),('replacement_commit','candidate-replacement-commit.json')):
 item=pred[name]; keys(item,['path','sha256'],'receipt predecessor '+name)
 req(item['path']==root+'/'+leaf and type(item['sha256']) is str and re.fullmatch(r'[0-9a-f]{64}',item['sha256']) is not None,'receipt predecessor '+name+' path')
 _,got=read(item['path'],0o600); req(got==item['sha256'],'receipt predecessor '+name+' SHA')
alias=r['marker_cli_alias_override']; keys(alias,['kind','only_handoff_field','historical_path','candidate_path','sha256'],'receipt marker alias'); req(alias['kind']=='marker-cli-path-alias-same-bytes-v1' and alias['only_handoff_field']=='marker_cli_path','receipt marker alias values')
succ=r['successor']; keys(succ,['coordinator_path','coordinator_sha256','provenance_path','provenance_sha256','receipt_producer_path','receipt_producer_sha256'],'receipt successor')
req(succ=={'coordinator_path':v4,'coordinator_sha256':vsha,'provenance_path':prov,'provenance_sha256':psha,'receipt_producer_path':producer,'receipt_producer_sha256':prsha},'receipt v4 closure')
absence=r['absence']; keys(absence,['coordinator_state_path','coordinator_state_absent','normal_output_leaves','normal_outputs_absent','pre_receipt_operation_leaves'],'receipt absence'); req(absence['coordinator_state_path']==root+'/coordinator-state.json' and absence['coordinator_state_absent'] is True and absence['normal_outputs_absent'] is True,'receipt absence values')
wp=r['windows_prestate']; keys(wp,['path','sha256'],'receipt WPROOF'); req(wp=={'path':wproof,'sha256':wsha},'receipt WPROOF closure')
w,actual=doc(wproof,0o600); req(actual==wsha,'WPROOF SHA')
keys(w,['schema_version','state','operation_id','coordinator_instance_id','observed_at_unix_ms','observed_at_utc','windows_ssh_target','windows_user_sid','windows_operation_root','operation_root_present','operation_bound_task_count','operation_bound_tasks','operation_bound_process_count','operation_bound_processes','collector_path','collector_sha256'],'WPROOF')
req(type(w['observed_at_unix_ms']) is int and type(w['observed_at_utc']) is str and w['observed_at_utc']==datetime.datetime.fromtimestamp(w['observed_at_unix_ms']/1000,datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),'WPROOF timestamp')
req(w['schema_version']==1 and w['state']=='viewflow-normal-v21-coordinator-successor-windows-prestate' and w['operation_id']==op and w['coordinator_instance_id']==coord and w['windows_ssh_target']=='wilf@172.16.105.70' and w['operation_root_present'] is False and w['operation_bound_task_count']==0 and w['operation_bound_tasks']==[] and w['operation_bound_process_count']==0 and w['operation_bound_processes']==[] and w['collector_path']==producer and w['collector_sha256']==prsha,'WPROOF absence')
print(actual,pred['retirement_terminal']['path'],pred['retirement_terminal']['sha256'],pred['replacement_commit']['path'],pred['replacement_commit']['sha256'],win['old_task_xml_sha256'],sep='\t')
PY
)
IFS=$'\t' read -r checked_wproof replacement_terminal replacement_terminal_sha replacement_commit replacement_commit_sha old_task_xml_sha <<<"$values"
[[ $checked_wproof == "$wproofsha" && $replacement_terminal_sha =~ ^[0-9a-f]{64}$ && $replacement_commit_sha =~ ^[0-9a-f]{64}$ && $old_task_xml_sha =~ ^[0-9a-f]{64}$ ]] || die 'validator returned invalid successor closure'

# Transform only the execution endpoint and mode guard of the sealed launcher.
# The predecessor body continues to pin the v3 candidate manifest/CLI and all
# deployment artifacts; this prevents a source-stage v4 coordinator from
# smuggling in a v4 deployment binary.
runtime_dir=/run/user/1000
[[ -d $runtime_dir && ! -L $runtime_dir && $(stat -c '%a:%u' "$runtime_dir") == 700:1000 ]] || die 'runtime directory identity differs'
render=$(mktemp --tmpdir="$runtime_dir" .viewflow-successor.XXXXXX)
rm -f -- "$render"
trap 'rm -f -- "$render"' EXIT
python3 - "$base" "$render" "$v4" "$v4sha" "$prov" "$provsha" "$producer" "$producersha" "$receipt" "$receiptsha" "$wproof" "$wproofsha" "$replacement_terminal" "$replacement_terminal_sha" "$replacement_commit" "$replacement_commit_sha" "$old_task_xml_sha" <<'PY'
import os,sys
base,out,v4,vsha,prov,psha,producer,prsha,receipt,rsha,wproof,wsha,terminal,terminalsha,commit,commitsha,taskxmlsha=sys.argv[1:]
t=open(base,encoding='utf-8').read()
old='[[ $# -le 1 ]] || die \'usage: launch-normal-v21.sh [--check-only|--execute|--resume]\'\nmode=${1:---check-only}\n[[ $mode == --check-only || $mode == --execute || $mode == --resume ]] || die \'usage: launch-normal-v21.sh [--check-only|--execute|--resume]\''
if old not in t:
 old='[[ $# -le 1 ]] || die \'usage: launch-normal-v21.sh [--check-only|--execute]\'\nmode=${1:---check-only}\n[[ $mode == --check-only || $mode == --execute ]] || die \'usage: launch-normal-v21.sh [--check-only|--execute]\''
new='[[ $# -le 1 ]] || die \'usage: launch-normal-v21-successor.sh [--offline-check|--check-only|--execute|--resume]\'\nmode=${1:---offline-check}\n[[ $mode == --offline-check || $mode == --check-only || $mode == --execute || $mode == --resume ]] || die \'usage: launch-normal-v21-successor.sh [--offline-check|--check-only|--execute|--resume]\''
if old not in t: raise SystemExit('base launcher mode contract changed')
t=t.replace(old,new,1)
replacement='if [[ $mode == --resume ]]; then successor_resume_state "$ROOT/coordinator-state.json"; else for leaf in "${outputs[@]}"; do [[ ! -e $ROOT/$leaf && ! -L $ROOT/$leaf ]] || die "fresh output already exists: $ROOT/$leaf"; done; fi\nsuccessor_runtime_pins\n[[ $mode == --offline-check ]] && { printf \x27normal v2.1 successor offline checks passed\\n\x27; exit 0; }\nsuccessor_live_recheck\n[[ $mode == --check-only ]] && { printf \x27normal v2.1 successor live checks passed\\n\x27; exit 0; }\ncoordinator_mode=(); [[ $mode == --resume ]] && coordinator_mode+=(--resume)\ncoordinator_replacement=(--candidate-retirement-terminal '+repr(terminal)+' --candidate-retirement-terminal-sha256 '+repr(terminalsha)+' --candidate-replacement-commit '+repr(commit)+' --candidate-replacement-commit-sha256 '+repr(commitsha)+' --windows-task-xml-sha256 '+repr(taskxmlsha)+')\nexec '+repr(v4)+' "${coordinator_mode[@]}" "${coordinator_replacement[@]}" --coordinator-successor-receipt '+repr(receipt)+' --coordinator-successor-receipt-sha256 '+repr(rsha)+' \\\n'
start=t.find('if [[ $mode == --resume ]]; then')
anchor='exec "$COORDINATOR" "${coordinator_mode[@]}" "${coordinator_replacement[@]}" \\\n'
end=t.find(anchor,start)
if start<0 or end<0: raise SystemExit('base launcher full resume/check/execute contract changed')
t=t[:start]+replacement+t[end+len(anchor):]
insert='''\nreadonly SUCCESSOR_COORDINATOR=%r\nreadonly SUCCESSOR_COORDINATOR_SHA=%r\nreadonly SUCCESSOR_PROVENANCE=%r\nreadonly SUCCESSOR_PROVENANCE_SHA=%r\nreadonly SUCCESSOR_PRODUCER=%r\nreadonly SUCCESSOR_PRODUCER_SHA=%r\nreadonly SUCCESSOR_RECEIPT=%r\nreadonly SUCCESSOR_RECEIPT_SHA=%r\nreadonly SUCCESSOR_WPROOF=%r\nreadonly SUCCESSOR_WPROOF_SHA=%r\nsuccessor_runtime_pins() { check_file "$SUCCESSOR_COORDINATOR" "$SUCCESSOR_COORDINATOR_SHA"; check_file "$SUCCESSOR_PROVENANCE" "$SUCCESSOR_PROVENANCE_SHA"; check_file "$SUCCESSOR_PRODUCER" "$SUCCESSOR_PRODUCER_SHA"; check_file "$SUCCESSOR_RECEIPT" "$SUCCESSOR_RECEIPT_SHA"; check_file "$SUCCESSOR_WPROOF" "$SUCCESSOR_WPROOF_SHA"; }\ndeprecated_resume_state() { python3 - "$1" "$OP" "$SUCCESSOR_RECEIPT_SHA" "$SUCCESSOR_WPROOF_SHA" <<'PY2'\nimport json,os,sys\np,op,r,w=sys.argv[1:]; fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW); b=os.read(fd,1<<24); os.close(fd); x=json.loads(b); if not (type(x) is dict and x.get('operation_id')==op and x['contract']['inputs']['coordinator_successor_receipt']['sha256']==r and x['contract']['inputs']['coordinator_successor_windows_prestate']['sha256']==w): raise SystemExit('resume contract')\nPY2\n}\nsuccessor_live_recheck() {\n  for unit in viewflow-peer.service deskflow.service; do mapfile -t q < <(systemctl --user show -p ActiveState -p MainPID --value "$unit"); [[ ${q[*]} == 'inactive 0' ]] || die "live unit not inactive/MainPID0: $unit"; done\n  ! ss -H -ltn 'sport = :24800' | grep -q . || die '24800 listener exists'; ! ss -H -lun 'sport = :44119' | grep -q . || die '44119 listener exists'\n  [[ ! -e /home/wilf/.local/state/viewflow/deskflow-quarantine.v2 && ! -L /home/wilf/.local/state/viewflow/deskflow-quarantine.v2 ]] || die 'VFQST002 exists'\n  [[ $(sha256sum /home/wilf/.local/state/viewflow/deployment-quarantine.v1 | awk '{print $1}') == "$MARKER_SHA" ]] || die 'active VFDQT changed'\n  ps=$(python3 - "$OP" <<'PY2'\nimport base64,sys\nop=sys.argv[1]; root='C:\\\\Users\\\\wilf\\\\AppData\\\\Local\\\\Viewflow\\\\Deployments\\\\'+op\ns="""$ErrorActionPreference='Stop';$op='%%s';$root='%%s';if(Test-Path -LiteralPath $root){throw 'operation root present'};$need=@($op,$root);$tasks=@(Get-ScheduledTask -ErrorAction Stop);foreach($t in $tasks){$xml=Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop;$action=($t.Actions|Out-String);if((@($t.TaskName,$t.TaskPath,$xml,$action)|Out-String|Select-String -SimpleMatch -Pattern $need)){throw 'operation task/action/xml present'}};foreach($p in @(Get-CimInstance Win32_Process -ErrorAction Stop)){if((@($p.CommandLine,$p.ExecutablePath)|Out-String|Select-String -SimpleMatch -Pattern $need)){throw 'operation process present'}}"""%%(op,root)\nprint(base64.b64encode(s.encode('utf-16le')).decode())\nPY2\n)\n  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 wilf@172.16.105.70 powershell -NoProfile -EncodedCommand "$ps"\n}\n''' % (v4, '', '', '', '', '', receipt, rsha, wproof,wsha)
dead_start=insert.find('\ndeprecated_resume_state()')
dead_end=insert.find('\nsuccessor_live_recheck()',dead_start)
if dead_start<0 or dead_end<0: raise SystemExit('old resume validator splice missing')
insert=insert[:dead_start]+insert[dead_end:]
insert=insert.replace("readonly SUCCESSOR_COORDINATOR_SHA=''", "readonly SUCCESSOR_COORDINATOR_SHA="+repr(vsha)).replace("readonly SUCCESSOR_PROVENANCE=''", "readonly SUCCESSOR_PROVENANCE="+repr(prov)).replace("readonly SUCCESSOR_PROVENANCE_SHA=''", "readonly SUCCESSOR_PROVENANCE_SHA="+repr(psha)).replace("readonly SUCCESSOR_PRODUCER=''", "readonly SUCCESSOR_PRODUCER="+repr(producer)).replace("readonly SUCCESSOR_PRODUCER_SHA=''", "readonly SUCCESSOR_PRODUCER_SHA="+repr(prsha))
insert+='''\nsuccessor_resume_state() { python3 - "$1" "$OP" "$SUCCESSOR_RECEIPT_SHA" "$SUCCESSOR_WPROOF_SHA" "$SUCCESSOR_COORDINATOR_SHA" <<'PY3'
import json,os,stat,sys
p,op,r,w,c=sys.argv[1:]
def bad(x): raise SystemExit('resume number')
def pairs(a):
 d={}
 for k,v in a:
  if k in d: raise SystemExit('resume duplicate')
  d[k]=v
 return d
fd=os.open(p,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 a=os.fstat(fd)
 if not(stat.S_ISREG(a.st_mode) and a.st_uid==1000 and stat.S_IMODE(a.st_mode)==0o600 and a.st_nlink==1): raise SystemExit('resume state identity')
 b=b''
 while True:
  q=os.read(fd,131072)
  if not q: break
  b+=q
 z=os.fstat(fd)
finally: os.close(fd)
n=os.lstat(p)
ident=lambda q:(q.st_dev,q.st_ino,q.st_size,q.st_uid,stat.S_IMODE(q.st_mode),q.st_nlink,q.st_mtime_ns,q.st_ctime_ns)
if stat.S_ISLNK(n.st_mode) or not (ident(a)==ident(z)==ident(n)): raise SystemExit('resume state changed')
t=b.decode('utf-8'); x,end=json.JSONDecoder(object_pairs_hook=pairs,parse_float=bad,parse_constant=bad).raw_decode(t)
if t[end:].strip() or type(x) is not dict or x.get('schema_version')!=2 or x.get('state')!='viewflow-cross-host-bootstrap' or x.get('operation_id')!=op: raise SystemExit('resume state schema')
i=x.get('contract',{}).get('inputs',{})
if i.get('coordinator_successor_receipt',{}).get('sha256')!=r or i.get('coordinator_successor_windows_prestate',{}).get('sha256')!=w or i.get('coordinator_successor',{}).get('sha256')!=c: raise SystemExit('resume successor closure')
PY3
}\n'''
t=t.replace('readonly CAND=',insert+'\nreadonly CAND=',1)
fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o500)
try: os.write(fd,t.encode()); os.fsync(fd)
finally: os.close(fd)
PY
[[ $(stat -c '%a:%u:%h' "$render") == 500:1000:1 ]] || die 'rendered successor identity'
bash -n "$render"
if ! rg -Fq -- 'successor_runtime_pins' "$render" || ! rg -Fq -- '-EncodedCommand' "$render" || ! rg -Fq -- 'coordinator-successor-receipt-sha256' "$render" || ! rg -Fq -- 'candidate-retirement-terminal-sha256' "$render"; then die 'rendered successor model differs'; fi
if [[ $mode == --check-only ]]; then
    printf 'normal v2.1 successor launcher check-only passed\n'
    exit 0
fi
case $mode in
 --run-check-only) generated_mode=--check-only;;
 --run-execute) generated_mode=--execute;;
 --run-resume) generated_mode=--resume;;
 *) die 'internal successor mode';;
esac
# Deliberately execute an already-unlinked runtime descriptor; neither the
# operation root nor /run retains a restartable successor launcher after a
# crash.  The v4 first gate therefore still observes its frozen leaf set.
exec {render_fd}<"$render"
rm -f -- "$render"
[[ ! -e $render && ! -L $render ]] || die 'runtime successor unlink failed'
bash "/proc/self/fd/$render_fd" "$generated_mode"
exec {render_fd}<&-
printf 'normal v2.1 successor launcher run completed\n'
