#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

die(){ printf 'error: %s\n' "$*" >&2; exit 1; }
sha256(){ sha256sum -- "$1" | awk '{print $1}'; }
raw='' manifest='' inventory='' incident='' tombstone='' output='' mode=publish
expected_probe='' expected_wrapper='' old_op=''
while (($#)); do
  case $1 in
    --raw-census) raw=$2; shift 2 ;;
    --manifest) manifest=$2; shift 2 ;;
    --windows-inventory) inventory=$2; shift 2 ;;
    --incident) incident=$2; shift 2 ;;
    --tombstone) tombstone=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --old-operation-id) old_op=$2; shift 2 ;;
    --expected-probe-sha256) expected_probe=$2; shift 2 ;;
    --expected-wrapper-sha256) expected_wrapper=$2; shift 2 ;;
    --validate-only) mode=validate; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $old_op =~ ^[0-9a-f]{32}$ && $expected_probe =~ ^[0-9a-f]{64}$ &&
   $expected_wrapper =~ ^[0-9a-f]{64}$ ]] || die 'operation ID or expected SHA-256 is invalid'
for p in "$raw" "$manifest" "$inventory" "$incident" "$tombstone"; do
  [[ -n $p ]] || die 'a required input path is empty'
done
[[ $mode == validate || -n $output ]] || die 'output path is empty'

tmpdir=$(mktemp -d /tmp/viewflow-legacy-census-parser.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT
decoded=$tmpdir/stdout.raw
facts=$tmpdir/facts.json

python3 -I -E - "$raw" "$manifest" "$inventory" "$incident" "$tombstone" \
  "$decoded" "$facts" "$old_op" "$expected_probe" "$expected_wrapper" "$0" <<'PY'
import base64,binascii,hashlib,json,os,stat,sys,xml.etree.ElementTree as ET
raw_path,manifest_path,inv_path,incident_path,tomb_path,decoded_path,facts_path,op,probe_sha,wrapper_sha,checker_path=sys.argv[1:]

def pairs(values):
    out={}
    for key,value in values:
        if key in out: raise ValueError('duplicate object key: '+key)
        out[key]=value
    return out

def read_evidence(path):
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        st=os.fstat(fd)
        if not (stat.S_ISREG(st.st_mode) and stat.S_IMODE(st.st_mode)==0o600 and st.st_nlink==1):
            raise ValueError('evidence metadata is not 0600 regular nlink1')
        chunks=[]
        while True:
            chunk=os.read(fd,1024*1024)
            if not chunk: break
            chunks.append(chunk)
        return b''.join(chunks)
    finally: os.close(fd)

def parse(path):
    data=read_evidence(path)
    if not data or data.startswith(b'\xef\xbb\xbf'): raise ValueError('empty or BOM JSON')
    text=data.decode('utf-8','strict')
    value=json.loads(text,object_pairs_hook=pairs)
    if not isinstance(value,dict): raise ValueError('top-level JSON must be object')
    return data,value

def keys(value,expected,label):
    if not isinstance(value,dict) or set(value)!=set(expected):
        raise ValueError(label+' keys differ')

def hex64(value): return isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value)
def uint(value): return isinstance(value,int) and not isinstance(value,bool) and value>=0
def sha(data): return hashlib.sha256(data).hexdigest()

raw_bytes,raw=parse(raw_path); manifest_bytes,manifest=parse(manifest_path)
inv_bytes,inv=parse(inv_path); incident_bytes,incident=parse(incident_path); tomb_bytes,tomb=parse(tomb_path)
keys(raw,['schema_version','state','operation_id','observed_at_utc','transport','ssh_target','ssh_options','probe_script_sha256','wrapper_script_sha256','transport_upgrade_receipt_sha256','exit_status','stdout','stderr','parsed_census','incident_boundary'],'raw')
for stream in ('stdout','stderr'): keys(raw[stream],['base64','length','sha256'],'raw '+stream)
keys(raw['parsed_census'],['canonical_jq_cS_sha256','document'],'raw parsed_census')
keys(raw['incident_boundary'],['reconciliation_manifest_sha256','incident_sha256','invalid_authz_tombstone_sha256','prior_windows_inventory_sha256'],'raw incident boundary')
if not (raw['schema_version']==1 and raw['state']=='viewflow-windows-ssh-raw-census' and
        raw['operation_id']==op and raw['transport']=='ssh-powershell-encodedcommand-exact-length-raw-files-v2' and
        raw['probe_script_sha256']==probe_sha and hex64(raw['wrapper_script_sha256'])):
    raise ValueError('raw identity differs')
if not isinstance(raw['ssh_target'],str) or not raw['ssh_target']: raise ValueError('target is invalid')
upgrade_sha=raw['transport_upgrade_receipt_sha256']
if not (upgrade_sha=='none' or hex64(upgrade_sha)): raise ValueError('transport upgrade binding is invalid')
upgrade_path=os.path.join(os.path.dirname(os.path.abspath(raw_path)),'windows-legacy-census-transport-upgrade.v1.json')
if upgrade_sha=='none':
    if raw['wrapper_script_sha256']!=wrapper_sha: raise ValueError('current raw wrapper differs')
    if raw['ssh_options']!=['-F','/dev/null','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','WarnWeakCrypto=no','-o','ConnectTimeout=10','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=3']: raise ValueError('current SSH options are invalid')
    if os.path.lexists(upgrade_path): raise ValueError('unbound transport upgrade receipt exists')
else:
    if raw['wrapper_script_sha256']!='8e0e056b7f361436c8e87fa74b53310d1275bad996139eddf9035b572cc752d8': raise ValueError('upgraded raw wrapper differs')
    if raw['ssh_options']!=['-F','/dev/null','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=3']: raise ValueError('upgraded SSH options are invalid')
    upgrade_bytes,upgrade=parse(upgrade_path)
    if sha(upgrade_bytes)!=upgrade_sha: raise ValueError('transport upgrade receipt SHA differs')
    keys(upgrade,['schema_version','state','old_operation_id','reason','old_intent','old_wrapper_sha256','new_wrapper_sha256','old_checker_sha256','new_checker_sha256','old_transport','new_transport','outputs','producer'],'transport upgrade receipt')
    keys(upgrade['old_intent'],['path','sha256'],'transport upgrade old intent')
    keys(upgrade['outputs'],['raw_census','legacy_disposition'],'transport upgrade outputs')
    keys(upgrade['producer'],['probe_sha256','checker_sha256'],'transport upgrade producer')
    old_intent_bytes,old_intent=parse(upgrade['old_intent']['path'])
    if not (upgrade['schema_version']==1 and upgrade['state']=='viewflow-post-vfdqa-windows-legacy-census-transport-upgrade' and
            upgrade['old_operation_id']==op and upgrade['reason']=='EOF_DEADLOCK_NO_RAW_PUBLISHED' and
            upgrade['old_intent']['path']==os.path.join(os.path.dirname(os.path.abspath(raw_path)),'windows-legacy-census-capture-intent.json') and
            hex64(upgrade['old_intent']['sha256']) and sha(old_intent_bytes)==upgrade['old_intent']['sha256'] and
            old_intent['schema_version']==1 and old_intent['state']=='viewflow-post-vfdqa-windows-legacy-capture-intent' and old_intent['old_operation_id']==op and
            old_intent['ssh_options']==['-F','/dev/null','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes'] and
            old_intent['outputs']=={'raw_census':raw_path,'legacy_disposition':os.path.join(os.path.dirname(os.path.abspath(raw_path)),'windows-legacy-disposition.json')} and
            old_intent['producer']['powershell_wrapper_sha256']=='4170bd4a552818636e75a42f6cb3cb13b49724dafc4b0b316afdfcd8d2fb39f3' and old_intent['producer']['checker']['sha256']=='1dfb262ad6ac226d5530d083a9b78d18862dcceb1dbe6ab83bb09019018243b6' and
            upgrade['old_wrapper_sha256']=='4170bd4a552818636e75a42f6cb3cb13b49724dafc4b0b316afdfcd8d2fb39f3' and
            upgrade['new_wrapper_sha256']=='8e0e056b7f361436c8e87fa74b53310d1275bad996139eddf9035b572cc752d8' and upgrade['old_checker_sha256']=='1dfb262ad6ac226d5530d083a9b78d18862dcceb1dbe6ab83bb09019018243b6' and
            upgrade['new_checker_sha256']=='2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2' and upgrade['old_transport']=='ssh-powershell-encodedcommand-raw-files-v1' and
            upgrade['new_transport']=='ssh-powershell-encodedcommand-exact-length-raw-files-v2' and
            upgrade['outputs']=={'raw_census':raw_path,'legacy_disposition':os.path.join(os.path.dirname(os.path.abspath(raw_path)),'windows-legacy-disposition.json')} and
            upgrade['producer']=={'probe_sha256':probe_sha,'checker_sha256':'2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2'}):
        raise ValueError('transport upgrade receipt binding differs')
if not isinstance(raw['observed_at_utc'],str): raise ValueError('capture time is invalid')
if not (isinstance(raw['exit_status'],int) and not isinstance(raw['exit_status'],bool)):
    raise ValueError('exit status is not an integer')
if raw['exit_status']!=0: raise ValueError('remote probe exit status is nonzero')
streams={}
for name in ('stdout','stderr'):
    item=raw[name]
    if not (isinstance(item['base64'],str) and uint(item['length']) and hex64(item['sha256'])):
        raise ValueError(name+' metadata is invalid')
    try: data=base64.b64decode(item['base64'],validate=True)
    except binascii.Error as exc: raise ValueError(name+' base64 is invalid') from exc
    if base64.b64encode(data).decode('ascii')!=item['base64'] or len(data)!=item['length'] or sha(data)!=item['sha256']:
        raise ValueError(name+' bytes do not match length/SHA/base64')
    streams[name]=data
stderr_classification_path=os.path.join(os.path.dirname(os.path.abspath(raw_path)),'windows-legacy-census-stderr-classification.v1.json')
if streams['stderr']==b'':
    if os.path.lexists(stderr_classification_path): raise ValueError('empty stderr has an unbound classification receipt')
    stderr_classification_sha='none'
else:
    prefix=(b'** WARNING: connection is not using a post-quantum key exchange algorithm.\r\n'
            b'** This session may be vulnerable to "store now, decrypt later" attacks.\r\n'
            b'** The server may need to be upgraded. See https://openssh.com/pq.html\r\n'
            b'#< CLIXML\r\n')
    stderr=streams['stderr']
    if not stderr.startswith(prefix): raise ValueError('stderr prefix differs')
    clixml_bytes=stderr[len(prefix):]
    clixml_text=clixml_bytes.decode('cp936','strict'); clixml_encoding='cp936'
    try: root_xml=ET.fromstring(clixml_text)
    except ET.ParseError as exc: raise ValueError('stderr CLIXML is malformed') from exc
    if any(node.tag.rsplit('}',1)[-1]!='Obj' for node in root_xml): raise ValueError('stderr contains a non-Obj top-level record')
    objs=[node for node in root_xml.iter() if node.tag.rsplit('}',1)[-1]=='Obj']
    if not objs or any(node.attrib.get('S')!='progress' for node in objs): raise ValueError('stderr contains non-progress CLIXML record')
    for node in root_xml.iter():
        if node.text and node.text.strip() and node.tag.rsplit('}',1)[-1] not in ('AV','AI','I64','Nil','PI','PC','T','SR','SD','PR'):
            raise ValueError('stderr contains unexpected CLIXML text')
    stderr_classification_bytes,stderr_classification=parse(stderr_classification_path)
    stderr_classification_sha=sha(stderr_classification_bytes)
    keys(stderr_classification,['schema_version','state','old_operation_id','reason','raw_census_path','raw_census_sha256','transport_upgrade_receipt_sha256','stderr_length','stderr_sha256','prefix_sha256','clixml_sha256','clixml_encoding','remote_probe_error','transport_error','accepted','observed_probe_script_sha256','observed_wrapper_script_sha256','observed_transport','final_probe_sha256','final_wrapper_sha256','final_checker_sha256'],'stderr classification receipt')
    if not (stderr_classification['schema_version']==1 and stderr_classification['state']=='viewflow-post-vfdqa-windows-legacy-census-stderr-classification' and
            stderr_classification['old_operation_id']==op and stderr_classification['reason']=='POWERSHELL_PROGRESS_ONLY_WITH_OPENSSH_PQ_WARNING' and
            stderr_classification['raw_census_path']==os.path.abspath(raw_path) and stderr_classification['raw_census_sha256']==sha(raw_bytes) and
            stderr_classification['transport_upgrade_receipt_sha256']==raw['transport_upgrade_receipt_sha256'] and raw['transport_upgrade_receipt_sha256']!='none' and
            stderr_classification['stderr_length']==len(stderr) and stderr_classification['stderr_sha256']==sha(stderr) and
            stderr_classification['prefix_sha256']==sha(prefix) and stderr_classification['clixml_sha256']==sha(clixml_bytes) and
            stderr_classification['clixml_encoding']==clixml_encoding and stderr_classification['observed_probe_script_sha256']==raw['probe_script_sha256'] and
            stderr_classification['observed_wrapper_script_sha256']==raw['wrapper_script_sha256'] and stderr_classification['observed_transport']==raw['transport'] and
            stderr_classification['final_probe_sha256']==probe_sha and stderr_classification['final_wrapper_sha256']==wrapper_sha and
            stderr_classification['final_checker_sha256']==sha(open(checker_path,'rb').read()) and stderr_classification['remote_probe_error'] is False and
            stderr_classification['transport_error'] is False and stderr_classification['accepted'] is True):
        raise ValueError('stderr classification binding differs')
open(decoded_path,'xb').write(streams['stdout'])
stdout_text=streams['stdout'].decode('utf-8','strict')
census=json.loads(stdout_text,object_pairs_hook=pairs)
if not isinstance(census,dict): raise ValueError('probe stdout must contain one JSON object')
if raw['parsed_census']['document']!=census or not hex64(raw['parsed_census']['canonical_jq_cS_sha256']): raise ValueError('parsed census does not match raw stdout')

keys(manifest,['schema_version','state','execution_authorized','operation_id','incident_classification','adopted_artifacts','vfdqa_binary','required_absent','linux_runtime','windows','outputs','approval'],'manifest')
keys(manifest['windows'],['ssh_target','user_sid','operation_root','expected_members','expected_deployment_task_xml_sha256','observed_deployment_task_xml_sha256','peer_task_xml_sha256','installed_baseline','peer_process'],'manifest windows')
if not (manifest['schema_version']==1 and manifest['state']=='viewflow-post-vfdqa-replay6-reconciliation-manifest' and manifest['operation_id']==op):
    raise ValueError('manifest identity differs')
keys(inv,['schema_version','state','operation_id','observed_at_utc','transport','operation_root','deployment_task','installed','peer','classification'],'windows inventory')
keys(inv['operation_root'],['path','reparse','acl','members'],'inventory operation_root')
keys(inv['deployment_task'],['state','task_xml_sha256','action_execute','action_arguments','working_directory'],'inventory deployment_task')
keys(inv['peer'],['task_state','task_xml_sha256','pid','parent_pid','creation_date','session_id','owner_sid','exe_sha256','command_line'],'inventory peer')
if not (inv['schema_version']==1 and inv['state']=='viewflow-post-vfdqa-windows-census' and inv['operation_id']==op):
    raise ValueError('Windows inventory identity differs')

keys(incident,['schema_version','state','operation_id','incident_classification','current_runtime_classification','windows_baseline','abort_physically_committed','old_authorization_retroactively_validated','normal_success_terminal','normal_deployment_release','rollback_performed','fresh_bridge_ready','old_peer_kept_running','linux_transients_kept_running','manifest_sha256','windows_inventory_sha256','linux_runtime_inventory_sha256','reconciled_at_utc'],'incident')
keys(tomb,['schema_version','state','operation_id','incident_classification','current_runtime_classification','windows_baseline_proof','physical_abort_committed','normal_success_terminal','normal_deployment_release','rollback_performed','fresh_bridge_ready','old_authorization_retroactively_validated','old_peer_kept_running','linux_viewflow_transient_kept_running','linux_deskflow_transient_kept_running','manifest_sha256','windows_inventory_sha256','incident_receipt_sha256','linux_runtime_reattestation_sha256','terminalized_at_utc'],'tombstone')
classification=['VFDQA_COMMITTED','AUTHZ_PROVENANCE_INVALID','TERMINAL_ABSENT']
if not (incident['schema_version']==2 and incident['state']=='viewflow-post-vfdqa-incident-terminal-reconciliation-required' and incident['operation_id']==op and incident['incident_classification']==classification and incident['normal_success_terminal'] is False and incident['fresh_bridge_ready'] is False):
    raise ValueError('incident disposition differs')
if not (tomb['schema_version']==2 and tomb['state']=='INVALID_AUTHZ_PROVENANCE_TOMBSTONE' and tomb['operation_id']==op and tomb['incident_classification']==classification and tomb['normal_success_terminal'] is False and tomb['fresh_bridge_ready'] is False):
    raise ValueError('tombstone disposition differs')
binding={'reconciliation_manifest_sha256':sha(manifest_bytes),'incident_sha256':sha(incident_bytes),'invalid_authz_tombstone_sha256':sha(tomb_bytes),'prior_windows_inventory_sha256':sha(inv_bytes)}
if not (raw['incident_boundary']==binding and incident['manifest_sha256']==binding['reconciliation_manifest_sha256'] and incident['windows_inventory_sha256']==binding['prior_windows_inventory_sha256'] and tomb['manifest_sha256']==binding['reconciliation_manifest_sha256'] and tomb['windows_inventory_sha256']==binding['prior_windows_inventory_sha256'] and tomb['incident_receipt_sha256']==binding['incident_sha256']):
    raise ValueError('reconciliation evidence hash chain differs')

keys(census,['schema_version','state','operation_id','observed_at_utc','policy','operation_root','deployment_task','installed','peer_task','viewflowd_processes','prohibited_actions','reconciliation_binding','classification'],'probe census')
keys(census['operation_root'],['path','reparse','acl','members','before_census_sha256','after_census_sha256','disposition'],'probe root')
keys(census['deployment_task'],['task_path','task_name','state','task_xml_sha256','actions','principal','disposition'],'probe deployment task')
keys(census['peer_task'],['task_path','task_name','state','task_xml_sha256','actions','principal'],'probe peer task')
keys(census['classification'],['physical_abort','authorization_provenance','prior_normal_terminal','windows_baseline','normal_release_ready','fresh_bridge_ready'],'probe classification')
probe_binding={'manifest_sha256':binding['reconciliation_manifest_sha256'],'incident_sha256':binding['incident_sha256'],'tombstone_sha256':binding['invalid_authz_tombstone_sha256'],'windows_inventory_sha256':binding['prior_windows_inventory_sha256']}
if not (census['schema_version']==1 and census['state']=='viewflow-post-vfdqa-windows-legacy-census' and census['operation_id']==op and census['policy']=='FREEZE_ONLY_NO_MUTATION' and census['prohibited_actions']==['ENABLE','REPLACE','DELETE'] and census['reconciliation_binding']==probe_binding):
    raise ValueError('probe census identity/binding differs')
expected_class={'physical_abort':'VFDQA_COMMITTED','authorization_provenance':'AUTHZ_PROVENANCE_INVALID','prior_normal_terminal':'TERMINAL_ABSENT','windows_baseline':'WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION','normal_release_ready':False,'fresh_bridge_ready':False}
if census['classification']!=expected_class: raise ValueError('probe classification differs')

def acl(value,label):
    keys(value,['owner_sid','protected','rules'],label)
    if not isinstance(value['owner_sid'],str) or not isinstance(value['protected'],bool) or not isinstance(value['rules'],list): raise ValueError(label+' scalar type differs')
    for i,rule in enumerate(value['rules']):
        keys(rule,['sid','type','rights','inherited','inheritance','propagation'],label+' rule')
        if not (all(isinstance(rule[x],str) for x in ('sid','type','rights','inheritance','propagation')) and isinstance(rule['inherited'],bool)): raise ValueError(label+' rule type differs')

root=census['operation_root']; invroot=inv['operation_root']
if not (root['path']==manifest['windows']['operation_root']==invroot['path'] and root['reparse'] is False and root['disposition']=='FROZEN_PRESENT_UNCHANGED' and hex64(root['before_census_sha256']) and root['before_census_sha256']==root['after_census_sha256']): raise ValueError('operation root disposition differs')
acl(root['acl'],'root ACL')
if root['acl']!=invroot['acl']: raise ValueError('root ACL differs from bound inventory')
if not (isinstance(root['members'],list) and len(root['members'])==14): raise ValueError('operation root must contain exactly 14 members')
inv_members={x['name']:x for x in invroot['members']}
if len(inv_members)!=14: raise ValueError('bound inventory members are not unique/exact')
for member in root['members']:
    keys(member,['name','directory','reparse','length','sha256','acl'],'root member')
    acl(member['acl'],'root member ACL')
    if member['name'] not in inv_members or member!=inv_members[member['name']] or member['directory'] is not False or member['reparse'] is not False or not uint(member['length']) or not hex64(member['sha256']): raise ValueError('root member metadata differs')
if {x['name']:x['sha256'] for x in root['members']}!=manifest['windows']['expected_members']: raise ValueError('root member SHA set differs')

def task(value,label,name,state,xmlsha):
    if not (value['task_path']=='\\' and value['task_name']==name and value['state']==state and value['task_xml_sha256']==xmlsha): raise ValueError(label+' identity differs')
    if not isinstance(value['actions'],list) or len(value['actions'])!=1: raise ValueError(label+' action count differs')
    keys(value['actions'][0],['execute','arguments','working_directory'],label+' action')
    if not all(isinstance(value['actions'][0][x],str) and value['actions'][0][x] for x in ('execute','arguments','working_directory')): raise ValueError(label+' action differs')
    keys(value['principal'],['user_id','logon_type','run_level'],label+' principal')
    if not all(isinstance(value['principal'][x],str) and value['principal'][x] for x in ('user_id','logon_type','run_level')): raise ValueError(label+' principal differs')
    if value['principal']['logon_type']!='Interactive' or value['principal']['run_level']!='Limited': raise ValueError(label+' logon/run-level differs')

deploy=census['deployment_task']; task(deploy,'deployment task','Viewflow Deployment '+op,'Disabled',manifest['windows']['observed_deployment_task_xml_sha256'])
if deploy['disposition']!='FROZEN_DISABLED_UNCHANGED' or deploy['actions'][0]!={'execute':inv['deployment_task']['action_execute'],'arguments':inv['deployment_task']['action_arguments'],'working_directory':inv['deployment_task']['working_directory']}: raise ValueError('deployment task disposition/action differs')
peer=census['peer_task']; task(peer,'peer task','Viewflow Peer','Running',manifest['windows']['peer_task_xml_sha256'])

if not isinstance(census['installed'],list) or len(census['installed'])!=3: raise ValueError('installed set count differs')
inv_inst={x['name']:x for x in inv['installed']}
for item in census['installed']:
    keys(item,['name','path','directory','reparse','length','sha256','acl'],'installed item'); acl(item['acl'],'installed ACL')
    if item['name'] not in inv_inst or item['directory'] is not False or item['reparse'] is not False or not uint(item['length']) or item['sha256']!=manifest['windows']['installed_baseline'].get(item['name']) or item['sha256']!=inv_inst[item['name']]['sha256'] or item['acl']!=inv_inst[item['name']]['acl']: raise ValueError('installed file metadata differs')

procs=census['viewflowd_processes']
if not isinstance(procs,list) or len(procs)!=1: raise ValueError('system-wide viewflowd.exe count must be exactly one')
proc=procs[0]; keys(proc,['name','path','pid','parent_pid','creation_date','session_id','owner_sid','exe_sha256','command_line'],'viewflowd process')
expected_proc=manifest['windows']['peer_process']; expected_path='C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe'
if not (proc['name'].lower()=='viewflowd.exe' and proc['path']==expected_path and proc['pid']==expected_proc['pid'] and proc['parent_pid']==expected_proc['parent_pid'] and proc['creation_date']==expected_proc['creation_date'] and proc['session_id']==1 and proc['owner_sid']==manifest['windows']['user_sid'] and proc['exe_sha256']==expected_proc['exe_sha256']): raise ValueError('system-wide peer process identity differs')

with open(facts_path,'x',encoding='utf-8',newline='\n') as out:
    json.dump({'binding':binding,'raw_sha256':sha(raw_bytes),'stderr_classification_sha256':stderr_classification_sha,'deployment_task':deploy,'operation_root':root,'peer':{'task':peer,'process':proc}},out,separators=(',',':'),sort_keys=True)
    out.write('\n')
PY

canonical=$tmpdir/stdout.canonical.json
jq -ceS . "$decoded" >"$canonical" || die 'probe stdout is not valid JSON'
canonical_sha=$(sha256 "$canonical")
[[ $(jq -r '.parsed_census.canonical_jq_cS_sha256' "$raw") == "$canonical_sha" ]] || die 'canonical jq -cS bytes SHA differs'
candidate=$tmpdir/disposition.json
jq -cnS --slurpfile f "$facts" --arg op "$old_op" '
  $f[0] as $x |
  {schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-disposition",old_operation_id:$op,
   action:"preserve-and-quarantine-no-mutation",incident_boundary:$x.binding,
   raw_census_sha256:$x.raw_sha256,stderr_classification_sha256:$x.stderr_classification_sha256,operation_root:$x.operation_root,
   legacy_deployment_task:$x.deployment_task,peer:$x.peer,
   legacy_isolation_complete:true,fresh_bridge_ready:false}
' >"$candidate"
chmod 0600 "$candidate"
if [[ $mode == validate ]]; then
  printf 'post-VFDQA Windows legacy census inputs valid\n'
  exit 0
fi

python3 -I -E - "$candidate" "$output" <<'PY'
import glob,hashlib,os,stat,sys
src,dst=sys.argv[1:]; parent=os.path.dirname(os.path.abspath(dst)); data=open(src,'rb').read()
prefix=os.path.join(parent,'.'+os.path.basename(dst)+'.staging.'); stage=prefix+hashlib.sha256(data).hexdigest()
unexpected=[p for p in glob.glob(prefix+'*') if p!=stage]
if unexpected: raise SystemExit('unexpected disposition staging file')
pst=os.lstat(parent)
if not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode): raise SystemExit('output parent is unsafe')
def meta(path,links):
 st=os.lstat(path)
 if not(stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and stat.S_IMODE(st.st_mode)==0o600 and st.st_nlink in links and st.st_uid==os.getuid()): raise SystemExit('output/staging metadata differs')
 return st
def read(path):
 fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  st=os.fstat(fd); out=b''
  while len(out)<st.st_size:
   chunk=os.read(fd,st.st_size-len(out))
   if not chunk: break
   out+=chunk
  if len(out)!=st.st_size: raise SystemExit('short output read')
  return st,out
 finally: os.close(fd)
def fsync_parent():
 fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
 try: os.fsync(fd)
 finally: os.close(fd)
dst_exists=os.path.lexists(dst); stage_exists=os.path.lexists(stage)
if dst_exists:
 ds=meta(dst,{1,2}); _,actual=read(dst)
 if actual!=data: raise SystemExit('existing disposition differs')
 if ds.st_nlink==2:
  if not stage_exists: raise SystemExit('unrecognized disposition hard link')
  ss=meta(stage,{2})
  if (ss.st_dev,ss.st_ino)!=(ds.st_dev,ds.st_ino): raise SystemExit('disposition staging inode differs')
  os.unlink(stage); fsync_parent(); stage_exists=False
 elif stage_exists:
  raise SystemExit('unexpected staging beside complete disposition')
 final=meta(dst,{1}); _,actual=read(dst)
 if actual!=data: raise SystemExit('replayed disposition differs')
 raise SystemExit(0)
if stage_exists:
 meta(stage,{1}); _,actual=read(stage)
 if actual!=data: raise SystemExit('partial/different disposition staging')
else:
 flags=os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC|os.O_NOFOLLOW
 fd=os.open(stage,flags,0o600)
 try:
  view=memoryview(data)
  while view:
   written=os.write(fd,view)
   if written<=0: raise OSError('short staging write')
   view=view[written:]
  os.fsync(fd)
 finally: os.close(fd)
 meta(stage,{1})
os.link(stage,dst,follow_symlinks=False); fsync_parent()
ss=meta(stage,{2}); ds=meta(dst,{2})
if (ss.st_dev,ss.st_ino)!=(ds.st_dev,ds.st_ino): raise SystemExit('published disposition inode differs')
_,actual=read(dst)
if actual!=data: raise SystemExit('published disposition bytes differ')
os.unlink(stage); fsync_parent(); meta(dst,{1}); _,actual=read(dst)
if actual!=data: raise SystemExit('final disposition readback differs')
PY
printf 'post-VFDQA Windows legacy disposition published\n'
