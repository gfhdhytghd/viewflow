#!/usr/bin/env bash

# Linux-only, fail-closed bridge from a reconciled post-VFDQA incident and
# invalid-authorization tombstone to a fresh protocol-2.1 generation-1 chain.

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'error: bridge-post-vfdqa-tombstone-to-fresh-v21.sh must be executed, not sourced\n' >&2
    return 64
fi
if [[ -n ${LD_PRELOAD-} || -n ${LD_AUDIT-} || -n ${LD_LIBRARY_PATH-} || -n ${BASH_ENV-} || -n ${ENV-} ]]; then
    printf 'error: loader/shell startup environment must be empty; invoke through env -i\n' >&2; exit 64
fi
unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH BASH_ENV ENV
set -Eeuo pipefail
shopt -s nullglob
umask 077
readonly PATH=/usr/bin:/bin
export PATH

readonly EXPECTED_UID=1000 EXPECTED_HOME=/home/wilf
readonly STATE_ROOT=/home/wilf/.local/state/viewflow
readonly DEPLOYMENTS=$STATE_ROOT/deployments
readonly MARKER=$STATE_ROOT/deployment-quarantine.v1
readonly MARKER_CLAIM=$STATE_ROOT/deployment-quarantine.v1.abort-claim
readonly RELEASE_CLAIM=$STATE_ROOT/deployment-quarantine.v1.release-claim
readonly RUNTIME_MARKER=$STATE_ROOT/deskflow-quarantine.v2
readonly ACCEPTANCE_SOCKET=/run/user/1000/deskflow/viewflow-acceptance.sock
readonly SIDECAR_SOCKET=/run/user/1000/viewflow/deskflow.sock
readonly VIEWFLOW=/home/wilf/.local/lib/viewflow/viewflowd
readonly VIEWFLOW_UNIT_FILE=/home/wilf/.config/systemd/user/viewflow-peer.service
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly DESKFLOW_UNIT=deskflow.service
readonly MARKER_CLI=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker
readonly DESKFLOW=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly OLD_EOF_WRAPPER_SHA=4170bd4a552818636e75a42f6cb3cb13b49724dafc4b0b316afdfcd8d2fb39f3
readonly OLD_EOF_CHECKER_SHA=1dfb262ad6ac226d5530d083a9b78d18862dcceb1dbe6ab83bb09019018243b6
readonly OBSERVED_EXACT_WRAPPER_SHA=8e0e056b7f361436c8e87fa74b53310d1275bad996139eddf9035b572cc752d8
readonly OBSERVED_EXACT_CHECKER_SHA=2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2
readonly SOURCE_UUID=00000000-0000-0000-0000-000000000101
readonly TARGET_UUID=00000000-0000-0000-0000-000000000002
readonly SOURCE_ID=00000000000000000000000000000101
readonly TARGET_ID=00000000000000000000000000000002
readonly STARTUP='viewflowd protocol 1.3 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged'
readonly -a CONFIG_PATHS=(
  /run/user/1000/systemd/user.control/deskflow.service
  /run/user/1000/systemd/user.control/viewflow-peer.service
  /run/user/1000/systemd/user/deskflow.service
  /run/user/1000/systemd/user/viewflow-peer.service
  /run/user/1000/systemd/user/deskflow.service.d/zz-direct-deskflow.conf)

mode='' old_operation='' incident='' incident_sha='' tombstone='' tombstone_sha=''
vfdqa='' vfdqa_sha='' manifest='' manifest_sha='' windows_census='' windows_census_sha=''
linux_inventory='' linux_inventory_sha='' windows_raw_census='' windows_raw_census_sha=''
windows_disposition='' windows_disposition_sha=''
windows_capture_intent='' transport_upgrade_path='' transport_upgrade_sha=''
stderr_classification_path='' stderr_classification_sha=''
installed_viewflow_sha='' installed_unit_sha='' marker_candidate='' marker_candidate_sha=''
prepare_script='' prepare_script_sha='' collector_script='' collector_script_sha='' bridge_root=''
plan='' cleanup_proof='' config_intent='' backup_dir='' fresh_root='' new_operation='' new_coordinator=''
publish_receipt='' handoff_receipt='' frozen_evidence='' final_receipt=''
sealed_dir='' marker_snapshot='' prepare_snapshot='' collector_snapshot=''
temporary_files=()

usage() { cat <<'EOF'
Usage: bridge-post-vfdqa-tombstone-to-fresh-v21.sh (--validate-inputs-only|--execute|--resume) \
 --old-operation-id LOWER32 \
 --incident-terminal PATH --incident-terminal-sha256 LOWER64 \
 --invalid-authz-tombstone PATH --invalid-authz-tombstone-sha256 LOWER64 \
 --vfdqa-receipt PATH --vfdqa-receipt-sha256 LOWER64 \
 --reconciliation-manifest PATH --reconciliation-manifest-sha256 LOWER64 \
 --windows-census PATH --windows-census-sha256 LOWER64 \
 --linux-runtime-inventory PATH --linux-runtime-inventory-sha256 LOWER64 \
 --windows-raw-census PATH --windows-raw-census-sha256 LOWER64 \
 --windows-disposition PATH --windows-disposition-sha256 LOWER64 \
 --installed-viewflow-sha256 LOWER64 --installed-viewflow-unit-sha256 LOWER64 \
 --deployment-marker-candidate PATH --deployment-marker-sha256 LOWER64 \
 --prepare-script PATH --prepare-script-sha256 LOWER64 \
 --collector-script PATH --collector-script-sha256 LOWER64 \
 --bridge-root /home/wilf/.local/state/viewflow/post-vfdqa-bridges/LOWER32
EOF
}
die(){ printf 'error: %s\n' "$*" >&2; return 1; }
need(){ [[ -n ${2-} ]] || die "$1 requires a value"; }
sha256(){ sha256sum -- "$1" | awk '{print tolower($1)}'; }
canonical_json_sha(){ jq -cS . "$1" | sha256sum | awk '{print tolower($1)}'; }
lower64(){ [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "$1 must be lowercase SHA-256"; }

while (($#)); do
 case $1 in
  --validate-inputs-only|--execute|--resume) [[ -z $mode ]] || die 'select exactly one mode'; mode=${1#--}; shift;;
  --old-operation-id) need "$1" "${2-}"; old_operation=$2; shift 2;;
  --incident-terminal) need "$1" "${2-}"; incident=$2; shift 2;;
  --incident-terminal-sha256) need "$1" "${2-}"; incident_sha=$2; shift 2;;
  --invalid-authz-tombstone) need "$1" "${2-}"; tombstone=$2; shift 2;;
  --invalid-authz-tombstone-sha256) need "$1" "${2-}"; tombstone_sha=$2; shift 2;;
  --vfdqa-receipt) need "$1" "${2-}"; vfdqa=$2; shift 2;;
  --vfdqa-receipt-sha256) need "$1" "${2-}"; vfdqa_sha=$2; shift 2;;
  --reconciliation-manifest) need "$1" "${2-}"; manifest=$2; shift 2;;
  --reconciliation-manifest-sha256) need "$1" "${2-}"; manifest_sha=$2; shift 2;;
  --windows-census) need "$1" "${2-}"; windows_census=$2; shift 2;;
  --windows-census-sha256) need "$1" "${2-}"; windows_census_sha=$2; shift 2;;
  --linux-runtime-inventory) need "$1" "${2-}"; linux_inventory=$2; shift 2;;
  --linux-runtime-inventory-sha256) need "$1" "${2-}"; linux_inventory_sha=$2; shift 2;;
  --windows-raw-census) need "$1" "${2-}"; windows_raw_census=$2; shift 2;;
  --windows-raw-census-sha256) need "$1" "${2-}"; windows_raw_census_sha=$2; shift 2;;
  --windows-disposition) need "$1" "${2-}"; windows_disposition=$2; shift 2;;
  --windows-disposition-sha256) need "$1" "${2-}"; windows_disposition_sha=$2; shift 2;;
  --installed-viewflow-sha256) need "$1" "${2-}"; installed_viewflow_sha=$2; shift 2;;
  --installed-viewflow-unit-sha256) need "$1" "${2-}"; installed_unit_sha=$2; shift 2;;
  --deployment-marker-candidate) need "$1" "${2-}"; marker_candidate=$2; shift 2;;
  --deployment-marker-sha256) need "$1" "${2-}"; marker_candidate_sha=$2; shift 2;;
  --prepare-script) need "$1" "${2-}"; prepare_script=$2; shift 2;;
  --prepare-script-sha256) need "$1" "${2-}"; prepare_script_sha=$2; shift 2;;
  --collector-script) need "$1" "${2-}"; collector_script=$2; shift 2;;
  --collector-script-sha256) need "$1" "${2-}"; collector_script_sha=$2; shift 2;;
  --bridge-root) need "$1" "${2-}"; bridge_root=$2; shift 2;;
  -h|--help) usage; exit 0;; *) usage >&2; die "unknown option: $1";;
 esac
done
cleanup(){ local rc=$? p; for p in "${temporary_files[@]}"; do [[ -z $p ]] || rm -f -- "$p"; done; exit "$rc"; }
trap cleanup EXIT

strict_json(){ python3 -I -E - "$1" <<'PY'
import json,sys
def pairs(items):
 d={}
 for k,v in items:
  if k in d: raise ValueError('duplicate key')
  d[k]=v
 return d
raw=open(sys.argv[1],'rb').read(); text=raw.decode('utf-8'); dec=json.JSONDecoder(object_pairs_hook=pairs)
start=len(text)-len(text.lstrip()); _,end=dec.raw_decode(text,start)
if text[end:].strip(): raise SystemExit('trailing JSON content')
PY
}
private_input(){ local label=$1 path=$2 expected=$3; [[ $path == /* && -f $path && ! -L $path && $(stat -c '%u:%a:%h' -- "$path") == 1000:600:1 ]] || die "$label must be uid-1000 mode-0600 nlink-1 regular bytes"; [[ $(sha256 "$path") == "$expected" ]] || die "$label SHA-256 differs"; }
safe_source(){ local label=$1 path=$2 expected=$3 mode; [[ $path == /* && -f $path && ! -L $path && $(stat -c '%u:%h' -- "$path") == 1000:1 ]] || die "$label must be owner-1000 nlink-1 regular bytes"; mode=$(stat -c %a -- "$path"); (( (8#$mode & 8#022)==0 )) || die "$label must not be group/world writable"; [[ $(sha256 "$path") == "$expected" ]] || die "$label SHA-256 differs"; }
safe_dir(){ [[ -d $2 && ! -L $2 && $(stat -c '%u' -- "$2") == 1000 ]] || die "$1 must be an owner-1000 real directory"; local m; m=$(stat -c %a -- "$2"); (( (8#$m & 8#077)==0 )) || die "$1 must be owner-only"; }

publish_once(){ python3 -I -E - "$1" "$2" <<'PY'
import ctypes,errno,os,stat,sys
src,dst=sys.argv[1:]; parent=os.path.dirname(dst)
fd=os.open(src,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 st=os.fstat(fd)
 if not(stat.S_ISREG(st.st_mode) and st.st_uid==1000 and stat.S_IMODE(st.st_mode)==0o600 and st.st_nlink==1): raise SystemExit('unsafe receipt stage')
 os.fsync(fd)
finally: os.close(fd)
dfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 libc=ctypes.CDLL(None,use_errno=True); RENAME_NOREPLACE=1
 if libc.renameat2(-100,src.encode(),-100,dst.encode(),RENAME_NOREPLACE)!=0:
  e=ctypes.get_errno()
  if e==errno.EEXIST: raise SystemExit('create-once receipt exists')
  raise OSError(e,os.strerror(e))
 os.fsync(dfd)
finally: os.close(dfd)
out=os.open(dst,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 s=os.fstat(out); os.fsync(out)
 if not(stat.S_ISREG(s.st_mode) and s.st_uid==1000 and stat.S_IMODE(s.st_mode)==0o600 and s.st_nlink==1): raise SystemExit('published receipt metadata differs')
finally: os.close(out)
PY
}
snapshot_source(){
 local label=$1 source=$2 expected=$3 destination=$4
 python3 -I -E - "$label" "$source" "$expected" "$destination" <<'PY'
import errno,hashlib,os,stat,sys
label,src,expected,dst=sys.argv[1:]
def read_fd(fd):
 os.lseek(fd,0,os.SEEK_SET); out=[]
 while True:
  b=os.read(fd,1024*1024)
  if not b: break
  out.append(b)
 return b''.join(out)
def valid(st,mode):
 return stat.S_ISREG(st.st_mode) and st.st_uid==1000 and st.st_nlink==1 and not(stat.S_IMODE(st.st_mode)&0o022) and stat.S_IMODE(st.st_mode)==mode
sfd=os.open(src,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 before=os.fstat(sfd); data=read_fd(sfd); after=os.fstat(sfd)
 if not(stat.S_ISREG(before.st_mode) and before.st_uid==1000 and before.st_nlink==1 and not(stat.S_IMODE(before.st_mode)&0o022) and (before.st_dev,before.st_ino,before.st_size)==(after.st_dev,after.st_ino,after.st_size)):
  raise SystemExit(label+' source metadata changed')
 if hashlib.sha256(data).hexdigest()!=expected: raise SystemExit(label+' source hash differs')
finally: os.close(sfd)
try:
 dfd=os.open(dst,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC|os.O_NOFOLLOW,0o500)
except FileExistsError:
 dfd=-1
if dfd>=0:
 try:
  view=memoryview(data)
  while view: view=view[os.write(dfd,view):]
  os.fchmod(dfd,0o500); os.fsync(dfd)
 finally: os.close(dfd)
 pfd=os.open(os.path.dirname(dst),os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try: os.fsync(pfd)
 finally: os.close(pfd)
fd=os.open(dst,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 st=os.fstat(fd); got=read_fd(fd)
 if not valid(st,0o500) or hashlib.sha256(got).hexdigest()!=expected: raise SystemExit(label+' sealed snapshot differs')
finally: os.close(fd)
PY
}
ensure_sealed_sources(){
 if [[ ! -e $sealed_dir && ! -L $sealed_dir ]]; then mkdir -- "$sealed_dir"; chmod 0700 "$sealed_dir"; sync -f "$bridge_root"; fi
 [[ -d $sealed_dir && ! -L $sealed_dir && $(stat -c '%u' -- "$sealed_dir") == 1000 ]] || die 'sealed source directory differs'
 if [[ -e $plan || -L $plan ]]; then [[ $(stat -c %a -- "$sealed_dir") == 500 ]] || die 'planned sealed source directory mode differs'; else [[ $(stat -c %a -- "$sealed_dir") =~ ^(500|700)$ ]] || die 'unplanned sealed source directory mode differs'; fi
 snapshot_source marker-candidate "$marker_candidate" "$marker_candidate_sha" "$marker_snapshot" || return 1
 snapshot_source prepare-script "$prepare_script" "$prepare_script_sha" "$prepare_snapshot" || return 1
 snapshot_source collector-script "$collector_script" "$collector_script_sha" "$collector_snapshot" || return 1
 chmod 0500 "$sealed_dir"; sync -f "$bridge_root"
}
validate_vfdqa(){
 local auth_path auth_sha marker_sha coordinator
 auth_path=$(jq -er '.adopted_artifacts.invalid_provenance_authorization.path' "$manifest")
 auth_sha=$(jq -er '.adopted_artifacts.invalid_provenance_authorization.sha256' "$manifest")
 marker_sha=$(jq -er '.vfdqa_binary.marker_sha256' "$manifest")
 private_input 'invalid-provenance historical authorization' "$auth_path" "$auth_sha"; strict_json "$auth_path"
 coordinator=$(jq -er '.coordinator_instance_id' "$auth_path")
 python3 -I -E - "$vfdqa" "$vfdqa_sha" "$old_operation" "$marker_sha" "$auth_sha" "$coordinator" <<'PY'
import hashlib,sys,uuid
p,outer,op,marker_sha,auth_sha,coord=sys.argv[1:]; b=open(p,'rb').read()
if len(b)!=384 or hashlib.sha256(b).hexdigest()!=outer or b[:8]!=b'VFDQA001' or b[8:13]!=bytes((1,1,1,3,1)) or any(b[13:16]): raise SystemExit('VFDQA header/hash differs')
m=b[16:272]
if m[:13]!=b'VFDQT001\x01\x01\x02\x01\x01' or hashlib.sha256(m).hexdigest()!=marker_sha: raise SystemExit('embedded marker differs')
o=op.encode()
if m[13]!=len(o) or any(m[14:16]) or m[16:16+len(o)]!=o or any(m[16+len(o):144]): raise SystemExit('embedded operation differs')
if m[144:160]!=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes or m[160:176]!=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes or m[176:192]!=uuid.UUID(coord).bytes: raise SystemExit('embedded tuple differs')
if int.from_bytes(m[192:200],'little')==0 or int.from_bytes(m[200:208],'little')!=1 or any(m[208:]): raise SystemExit('embedded generation differs')
if b[272:304].hex()!=marker_sha or b[304:336].hex()!=auth_sha or int.from_bytes(b[336:344],'little')==0 or any(b[344:352]) or hashlib.sha256(b[:352]).digest()!=b[352:384]: raise SystemExit('VFDQA cross-binding differs')
PY
}
validate_windows_transport(){
 windows_capture_intent=$bridge_root/evidence/windows-legacy-census-capture-intent.json
 transport_upgrade_path=$bridge_root/evidence/windows-legacy-census-transport-upgrade.v1.json
 stderr_classification_path=$bridge_root/evidence/windows-legacy-census-stderr-classification.v1.json
 transport_upgrade_sha=$(jq -er '.transport_upgrade_receipt_sha256' "$windows_raw_census")
 stderr_classification_sha=$(jq -er '.stderr_classification_sha256' "$windows_disposition")
 private_input 'Windows capture intent' "$windows_capture_intent" "$(sha256 "$windows_capture_intent")" || return 1; strict_json "$windows_capture_intent" || return 1
 if [[ $transport_upgrade_sha != none ]]; then lower64 transport-upgrade "$transport_upgrade_sha" || return 1; private_input 'Windows transport upgrade receipt' "$transport_upgrade_path" "$transport_upgrade_sha" || return 1; strict_json "$transport_upgrade_path" || return 1; fi
 if [[ $stderr_classification_sha != none ]]; then lower64 stderr-classification "$stderr_classification_sha" || return 1; private_input 'Windows stderr classification receipt' "$stderr_classification_path" "$stderr_classification_sha" || return 1; strict_json "$stderr_classification_path" || return 1; fi
 python3 -I -E - "$old_operation" "$windows_raw_census" "$windows_raw_census_sha" "$windows_disposition" "$windows_disposition_sha" "$windows_capture_intent" "$transport_upgrade_path" "$stderr_classification_path" "$manifest" "$manifest_sha" "$windows_census" "$windows_census_sha" "$incident" "$incident_sha" "$tombstone" "$tombstone_sha" "$OLD_EOF_WRAPPER_SHA" "$OLD_EOF_CHECKER_SHA" "$OBSERVED_EXACT_WRAPPER_SHA" "$OBSERVED_EXACT_CHECKER_SHA" <<'PY'
import base64,binascii,hashlib,json,os,sys,xml.etree.ElementTree as ET
(op,raw_path,raw_expected,disp_path,disp_expected,intent_path,upgrade_path,class_path,
 manifest_path,manifest_sha,inventory_path,inventory_sha,incident_path,incident_sha,
 tomb_path,tomb_sha,old_wrapper,old_checker,observed_wrapper,observed_checker)=sys.argv[1:]
def pairs(items):
 out={}
 for k,v in items:
  if k in out: raise ValueError('duplicate JSON key: '+k)
  out[k]=v
 return out
def load(path):
 data=open(path,'rb').read(); value=json.loads(data.decode('utf-8','strict'),object_pairs_hook=pairs)
 if not isinstance(value,dict): raise ValueError(path+' top-level must be object')
 return data,value
def exact(value,expected,label):
 if not isinstance(value,dict) or set(value)!=set(expected): raise ValueError(label+' keys differ')
def sha(data): return hashlib.sha256(data).hexdigest()
def hex64(v): return isinstance(v,str) and len(v)==64 and all(c in '0123456789abcdef' for c in v)
def stream(value,label):
 exact(value,['base64','length','sha256'],label)
 if not isinstance(value['base64'],str) or not isinstance(value['length'],int) or isinstance(value['length'],bool) or value['length']<0 or not hex64(value['sha256']): raise ValueError(label+' metadata differs')
 try: data=base64.b64decode(value['base64'],validate=True)
 except binascii.Error as e: raise ValueError(label+' base64 differs') from e
 if base64.b64encode(data).decode()!=value['base64'] or len(data)!=value['length'] or sha(data)!=value['sha256']: raise ValueError(label+' bytes differ')
 return data
raw_bytes,raw=load(raw_path); disp_bytes,disp=load(disp_path); intent_bytes,intent=load(intent_path)
if sha(raw_bytes)!=raw_expected or sha(disp_bytes)!=disp_expected: raise ValueError('outer Windows evidence SHA differs')
exact(raw,['schema_version','state','operation_id','observed_at_utc','transport','ssh_target','ssh_options','probe_script_sha256','wrapper_script_sha256','transport_upgrade_receipt_sha256','exit_status','stdout','stderr','parsed_census','incident_boundary'],'raw census')
exact(raw['parsed_census'],['canonical_jq_cS_sha256','document'],'raw parsed census')
exact(raw['incident_boundary'],['reconciliation_manifest_sha256','incident_sha256','invalid_authz_tombstone_sha256','prior_windows_inventory_sha256'],'raw incident boundary')
binding={'reconciliation_manifest_sha256':manifest_sha,'incident_sha256':incident_sha,'invalid_authz_tombstone_sha256':tomb_sha,'prior_windows_inventory_sha256':inventory_sha}
if not (raw['schema_version']==1 and raw['state']=='viewflow-windows-ssh-raw-census' and raw['operation_id']==op and raw['transport']=='ssh-powershell-encodedcommand-exact-length-raw-files-v2' and raw['exit_status']==0 and raw['incident_boundary']==binding and isinstance(raw['observed_at_utc'],str) and isinstance(raw['ssh_target'],str) and raw['ssh_target'] and hex64(raw['probe_script_sha256']) and hex64(raw['wrapper_script_sha256'])): raise ValueError('raw census identity/binding differs')
stdout=stream(raw['stdout'],'raw stdout'); stderr=stream(raw['stderr'],'raw stderr')
stdout_doc=json.loads(stdout.decode('utf-8','strict'),object_pairs_hook=pairs)
parsed=raw['parsed_census']['document']
if stdout_doc!=parsed or not hex64(raw['parsed_census']['canonical_jq_cS_sha256']): raise ValueError('raw stdout/parsed census differs')
if not (isinstance(parsed,dict) and parsed.get('schema_version')==1 and parsed.get('state')=='viewflow-post-vfdqa-windows-legacy-census' and parsed.get('operation_id')==op): raise ValueError('raw parsed census identity differs')
exact(intent,['schema_version','state','old_operation_id','ssh_target','ssh_options','inputs','outputs','producer'],'capture intent')
exact(intent['inputs'],['reconciliation_manifest','prior_windows_inventory','incident','invalid_authz_tombstone'],'capture intent inputs')
for k in intent['inputs']: exact(intent['inputs'][k],['path','sha256'],'capture intent '+k)
exact(intent['outputs'],['raw_census','legacy_disposition'],'capture intent outputs')
exact(intent['producer'],['probe','powershell_wrapper_sha256','checker'],'capture intent producer')
exact(intent['producer']['probe'],['path','sha256'],'capture intent probe'); exact(intent['producer']['checker'],['path','sha256'],'capture intent checker')
inputs={'reconciliation_manifest':{'path':manifest_path,'sha256':manifest_sha},'prior_windows_inventory':{'path':inventory_path,'sha256':inventory_sha},'incident':{'path':incident_path,'sha256':incident_sha},'invalid_authz_tombstone':{'path':tomb_path,'sha256':tomb_sha}}
outputs={'raw_census':raw_path,'legacy_disposition':disp_path}
if not (intent['schema_version']==1 and intent['state']=='viewflow-post-vfdqa-windows-legacy-capture-intent' and intent['old_operation_id']==op and intent['ssh_target']==raw['ssh_target'] and intent['inputs']==inputs and intent['outputs']==outputs and intent['producer']['probe']['sha256']==raw['probe_script_sha256'] and isinstance(intent['producer']['probe']['path'],str) and intent['producer']['probe']['path'] and isinstance(intent['producer']['checker']['path'],str) and intent['producer']['checker']['path'] and hex64(intent['producer']['checker']['sha256']) and hex64(intent['producer']['powershell_wrapper_sha256'])): raise ValueError('capture intent exact binding differs')
upgrade_sha=raw['transport_upgrade_receipt_sha256']
exact(disp,['schema_version','state','old_operation_id','action','incident_boundary','raw_census_sha256','stderr_classification_sha256','operation_root','legacy_deployment_task','peer','legacy_isolation_complete','fresh_bridge_ready'],'legacy disposition')
if not (disp['schema_version']==1 and disp['state']=='viewflow-post-vfdqa-windows-legacy-disposition' and disp['old_operation_id']==op and disp['action']=='preserve-and-quarantine-no-mutation' and disp['incident_boundary']==binding and disp['raw_census_sha256']==raw_expected and disp['legacy_isolation_complete'] is True and disp['fresh_bridge_ready'] is False and isinstance(disp['operation_root'],dict) and isinstance(disp['legacy_deployment_task'],dict) and isinstance(disp['peer'],dict)): raise ValueError('legacy disposition identity/binding differs')
if upgrade_sha=='none':
 if os.path.lexists(upgrade_path): raise ValueError('fresh chain has an unbound upgrade receipt')
 if os.path.lexists(class_path): raise ValueError('fresh chain has an unbound stderr classification')
 if stderr or disp['stderr_classification_sha256']!='none': raise ValueError('fresh chain requires empty stderr and no classification')
 if raw['ssh_options']!=['-F','/dev/null','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','WarnWeakCrypto=no','-o','ConnectTimeout=10','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=3'] or intent['ssh_options']!=raw['ssh_options'] or intent['producer']['powershell_wrapper_sha256']!=raw['wrapper_script_sha256']: raise ValueError('fresh chain producer/SSH options differ')
else:
 if not hex64(upgrade_sha) or not hex64(disp['stderr_classification_sha256']) or not stderr: raise ValueError('legacy recovery chain is incomplete')
 upgrade_bytes,upgrade=load(upgrade_path); class_bytes,classification=load(class_path)
 if sha(upgrade_bytes)!=upgrade_sha or sha(class_bytes)!=disp['stderr_classification_sha256']: raise ValueError('legacy recovery receipt SHA differs')
 exact(upgrade,['schema_version','state','old_operation_id','reason','old_intent','old_wrapper_sha256','new_wrapper_sha256','old_checker_sha256','new_checker_sha256','old_transport','new_transport','outputs','producer'],'transport upgrade')
 exact(upgrade['old_intent'],['path','sha256'],'transport upgrade old intent'); exact(upgrade['outputs'],['raw_census','legacy_disposition'],'transport upgrade outputs'); exact(upgrade['producer'],['probe_sha256','checker_sha256'],'transport upgrade producer')
 if not (upgrade['schema_version']==1 and upgrade['state']=='viewflow-post-vfdqa-windows-legacy-census-transport-upgrade' and upgrade['old_operation_id']==op and upgrade['reason']=='EOF_DEADLOCK_NO_RAW_PUBLISHED' and upgrade['old_intent']=={'path':intent_path,'sha256':sha(intent_bytes)} and upgrade['old_wrapper_sha256']==old_wrapper and upgrade['new_wrapper_sha256']==observed_wrapper and upgrade['old_checker_sha256']==old_checker and upgrade['new_checker_sha256']==observed_checker and upgrade['old_transport']=='ssh-powershell-encodedcommand-raw-files-v1' and upgrade['new_transport']==raw['transport'] and upgrade['outputs']==outputs and upgrade['producer']=={'probe_sha256':raw['probe_script_sha256'],'checker_sha256':observed_checker} and raw['wrapper_script_sha256']==observed_wrapper and intent['producer']['powershell_wrapper_sha256']==old_wrapper and intent['producer']['checker']['sha256']==old_checker and intent['ssh_options']==['-F','/dev/null','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes'] and raw['ssh_options']==['-F','/dev/null','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=3']): raise ValueError('transport upgrade exact binding differs')
 exact(classification,['schema_version','state','old_operation_id','reason','raw_census_path','raw_census_sha256','transport_upgrade_receipt_sha256','stderr_length','stderr_sha256','prefix_sha256','clixml_sha256','clixml_encoding','remote_probe_error','transport_error','accepted','observed_probe_script_sha256','observed_wrapper_script_sha256','observed_transport','final_probe_sha256','final_wrapper_sha256','final_checker_sha256'],'stderr classification')
 prefix=(b'** WARNING: connection is not using a post-quantum key exchange algorithm.\r\n' b'** This session may be vulnerable to "store now, decrypt later" attacks.\r\n' b'** The server may need to be upgraded. See https://openssh.com/pq.html\r\n' b'#< CLIXML\r\n')
 if not stderr.startswith(prefix): raise ValueError('stderr classification prefix differs')
 xml_bytes=stderr[len(prefix):]; root=ET.fromstring(xml_bytes.decode('cp936','strict')); objs=[n for n in root.iter() if n.tag.rsplit('}',1)[-1]=='Obj']
 if any(n.tag.rsplit('}',1)[-1]!='Obj' for n in root) or not objs or any(n.attrib.get('S')!='progress' for n in objs): raise ValueError('stderr classification XML differs')
 for n in root.iter():
  if n.text and n.text.strip() and n.tag.rsplit('}',1)[-1] not in ('AV','AI','I64','Nil','PI','PC','T','SR','SD','PR'): raise ValueError('stderr classification XML text differs')
 if not (classification['schema_version']==1 and classification['state']=='viewflow-post-vfdqa-windows-legacy-census-stderr-classification' and classification['old_operation_id']==op and classification['reason']=='POWERSHELL_PROGRESS_ONLY_WITH_OPENSSH_PQ_WARNING' and classification['raw_census_path']==raw_path and classification['raw_census_sha256']==raw_expected and classification['transport_upgrade_receipt_sha256']==upgrade_sha and classification['stderr_length']==len(stderr) and classification['stderr_sha256']==sha(stderr) and classification['prefix_sha256']==sha(prefix) and classification['clixml_sha256']==sha(xml_bytes) and classification['clixml_encoding']=='cp936' and classification['remote_probe_error'] is False and classification['transport_error'] is False and classification['accepted'] is True and classification['observed_probe_script_sha256']==raw['probe_script_sha256'] and classification['observed_wrapper_script_sha256']==raw['wrapper_script_sha256'] and classification['observed_transport']==raw['transport'] and classification['final_probe_sha256']==raw['probe_script_sha256'] and hex64(classification['final_wrapper_sha256']) and hex64(classification['final_checker_sha256'])): raise ValueError('stderr classification exact binding differs')
PY
}
validate_inputs(){
 local s
 [[ -n $mode && $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] || die 'mode and uid-1000 HOME=/home/wilf are required'
 [[ $old_operation =~ ^[0-9a-f]{32}$ ]] || die 'old operation ID must be lowercase 32hex'
 for s in incident:$incident_sha tombstone:$tombstone_sha vfdqa:$vfdqa_sha manifest:$manifest_sha windows:$windows_census_sha linux:$linux_inventory_sha raw:$windows_raw_census_sha disposition:$windows_disposition_sha viewflow:$installed_viewflow_sha unit:$installed_unit_sha marker:$marker_candidate_sha prepare:$prepare_script_sha collector:$collector_script_sha; do lower64 "${s%%:*}" "${s#*:}"; done
 private_input incident "$incident" "$incident_sha"; private_input tombstone "$tombstone" "$tombstone_sha"; private_input manifest "$manifest" "$manifest_sha"
 private_input 'Windows census' "$windows_census" "$windows_census_sha"; private_input 'Linux runtime inventory' "$linux_inventory" "$linux_inventory_sha"
 private_input 'Windows raw census' "$windows_raw_census" "$windows_raw_census_sha"; private_input 'Windows legacy disposition' "$windows_disposition" "$windows_disposition_sha"
 [[ -f $vfdqa && ! -L $vfdqa && $(stat -c '%u:%a:%h:%s' -- "$vfdqa") == 1000:600:1:384 && $(sha256 "$vfdqa") == "$vfdqa_sha" ]] || die 'VFDQA receipt must be uid-1000 0600 nlink-1 384 bytes'
 safe_source marker "$marker_candidate" "$marker_candidate_sha"; safe_source prepare "$prepare_script" "$prepare_script_sha"; safe_source collector "$collector_script" "$collector_script_sha"
 for s in "$incident" "$tombstone" "$manifest" "$windows_census" "$linux_inventory" "$windows_raw_census" "$windows_disposition"; do strict_json "$s"; done
 jq -e --arg op "$old_operation" --arg m "$manifest_sha" --arg w "$windows_census_sha" --arg l "$linux_inventory_sha" '
  keys==["abort_physically_committed","current_runtime_classification","fresh_bridge_ready","incident_classification","linux_runtime_inventory_sha256","linux_transients_kept_running","manifest_sha256","normal_deployment_release","normal_success_terminal","old_authorization_retroactively_validated","old_peer_kept_running","operation_id","reconciled_at_utc","rollback_performed","schema_version","state","windows_baseline","windows_inventory_sha256"] and
  .schema_version==2 and .state=="viewflow-post-vfdqa-incident-terminal-reconciliation-required" and .operation_id==$op and
  .incident_classification==["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"] and .current_runtime_classification=="CURRENT_RUNTIME_REATTESTED" and .windows_baseline=="WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION" and
  .abort_physically_committed==true and .old_authorization_retroactively_validated==false and .normal_success_terminal==false and .normal_deployment_release==false and .rollback_performed==false and .fresh_bridge_ready==false and .old_peer_kept_running==true and .linux_transients_kept_running==true and
  .manifest_sha256==$m and .windows_inventory_sha256==$w and .linux_runtime_inventory_sha256==$l' "$incident" >/dev/null || die 'incident terminal contract invalid'
 jq -e --arg op "$old_operation" --arg m "$manifest_sha" --arg w "$windows_census_sha" --arg l "$linux_inventory_sha" --arg i "$incident_sha" '
  keys==["current_runtime_classification","fresh_bridge_ready","incident_classification","incident_receipt_sha256","linux_deskflow_transient_kept_running","linux_runtime_reattestation_sha256","linux_viewflow_transient_kept_running","manifest_sha256","normal_deployment_release","normal_success_terminal","old_authorization_retroactively_validated","old_peer_kept_running","operation_id","physical_abort_committed","rollback_performed","schema_version","state","terminalized_at_utc","windows_baseline_proof","windows_inventory_sha256"] and
  .schema_version==2 and .state=="INVALID_AUTHZ_PROVENANCE_TOMBSTONE" and .operation_id==$op and .incident_classification==["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"] and .current_runtime_classification=="CURRENT_RUNTIME_REATTESTED" and .windows_baseline_proof=="tainted-needs-remediation" and
  .physical_abort_committed==true and .normal_success_terminal==false and .normal_deployment_release==false and .rollback_performed==false and .fresh_bridge_ready==false and .old_authorization_retroactively_validated==false and .old_peer_kept_running==true and .linux_viewflow_transient_kept_running==true and .linux_deskflow_transient_kept_running==true and
  .manifest_sha256==$m and .windows_inventory_sha256==$w and .incident_receipt_sha256==$i and .linux_runtime_reattestation_sha256==$l' "$tombstone" >/dev/null || die 'invalid-authorization tombstone contract invalid'
 jq -e --arg op "$old_operation" --arg wp "$windows_census" --arg lp "$linux_inventory" --arg vpath "$vfdqa" --arg vsha "$vfdqa_sha" '
  keys==["adopted_artifacts","approval","execution_authorized","incident_classification","linux_runtime","operation_id","outputs","required_absent","schema_version","state","vfdqa_binary","windows"] and .schema_version==1 and .state=="viewflow-post-vfdqa-replay6-reconciliation-manifest" and .execution_authorized==false and .operation_id==$op and .incident_classification==["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"] and .outputs.windows_inventory==$wp and .outputs.linux_runtime_inventory==$lp and .vfdqa_binary.path==$vpath and .vfdqa_binary.sha256==$vsha and .vfdqa_binary.size==384' "$manifest" >/dev/null || die 'reconciliation manifest contract invalid'
 jq -e --arg op "$old_operation" '.schema_version==1 and .state=="viewflow-post-vfdqa-windows-census" and .operation_id==$op and .classification=={physical_abort:"VFDQA_COMMITTED",authorization_provenance:"AUTHZ_PROVENANCE_INVALID",prior_normal_terminal:"TERMINAL_ABSENT",current_runtime:"CURRENT_RUNTIME_REATTESTED",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",normal_release_ready:false,fresh_bridge_ready:false}' "$windows_census" >/dev/null || die 'Windows census contract invalid'
 jq -e --arg op "$old_operation" 'keys==["boot_id","cgroup_pid_sets","observed_at_utc","operation_id","processes","state","units"] and .state=="CURRENT_RUNTIME_REATTESTED" and .operation_id==$op and (.processes.viewflow|length)==1 and (.processes.deskflow|length)==3' "$linux_inventory" >/dev/null || die 'Linux runtime inventory contract invalid'
 [[ $bridge_root == "$STATE_ROOT/post-vfdqa-bridges/$old_operation" ]] || die 'bridge root must use the independent post-VFDQA namespace'
 [[ $windows_raw_census == "$bridge_root/evidence/windows-ssh-raw-census.json" && $windows_disposition == "$bridge_root/evidence/windows-legacy-disposition.json" ]] || die 'Windows evidence paths must use the fixed bridge evidence namespace'
 safe_dir 'bridge evidence directory' "$bridge_root/evidence"
 validate_windows_transport || return 1
 [[ ! -e $MARKER_CLAIM && ! -L $MARKER_CLAIM && ! -e $RELEASE_CLAIM && ! -L $RELEASE_CLAIM ]] || die 'post-VFDQA claim boundary differs'
 if [[ -e $MARKER || -L $MARKER ]]; then
  [[ $mode == resume && -f $bridge_root/transition-plan.json && ! -L $bridge_root/transition-plan.json ]] || die 'active marker is allowed only for an immutable-plan resume'
 fi
 validate_vfdqa
}

process_ticks(){ sed -E 's/^[0-9]+ \(.*\) //' "/proc/$1/stat" | awk '{print $20}'; }
process_cgroup(){ awk -F: '$1=="0"{print $3}' "/proc/$1/cgroup"; }
unit_prop(){ systemctl --user show --property "$2" --value "$1"; }
observed_exec_start_sha(){ local response object property; response=$(busctl --user --json=short call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetUnit s "$1"); object=$(jq -er 'select(.type=="o" and (.data|length)==1)|.data[0]' <<<"$response"); property=$(busctl --user --json=short get-property org.freedesktop.systemd1 "$object" org.freedesktop.systemd1.Service ExecStart); jq -ceS 'select(.type=="a(sasbttttuii)" and (.data|length)==1)|.data[0] as $v|select(($v|length)==10)|{argv:$v[1],ignore_errors:$v[2],path:$v[0]}' <<<"$property" | sha256sum | awk '{print $1}'; }
exact_pids(){ local want=$1 p x; for p in /proc/[0-9]*; do [[ -e $p/exe ]] || continue; x=$(readlink -f -- "$p/exe" 2>/dev/null || true); [[ $x == "$want" ]] && printf '%s\n' "${p##*/}"; done; return 0; }
validate_live_tuple(){
 local role unit cg pid row expected actual
 [[ $(< /proc/sys/kernel/random/boot_id) == "$(jq -er .boot_id "$linux_inventory")" ]] || die 'Linux boot ID drifted; independent post-reboot reconciliation evidence is required'
 for role in viewflow deskflow; do
  unit=$(jq -er ".units.$role.unit" "$linux_inventory"); cg=$(jq -er ".units.$role.control_group" "$linux_inventory")
  [[ $(unit_prop "$unit" ActiveState) == active && $(unit_prop "$unit" Transient) == yes && $(unit_prop "$unit" KillMode) == control-group && $(unit_prop "$unit" InvocationID) == "$(jq -er ".units.$role.invocation_id" "$linux_inventory")" && $(unit_prop "$unit" ControlGroup) == "$cg" && $(observed_exec_start_sha "$unit") == "$(jq -er ".units.$role.exec_start_sha256" "$linux_inventory")" ]] || die "$role unit tuple drifted"
 done
 while IFS= read -r row; do
  pid=$(jq -er .pid <<<"$row"); cg=$(jq -er .control_group <<<"$row")
  [[ -e /proc/$pid && $(process_ticks "$pid") == "$(jq -er .start_ticks <<<"$row")" && $(process_cgroup "$pid") == "$cg" && $(sha256 "/proc/$pid/exe") == "$(jq -er .exe_sha256 <<<"$row")" ]] || die "runtime PID tuple drifted: $pid"
 done < <(jq -c '.processes.viewflow[],.processes.deskflow[]' "$linux_inventory")
 for role in viewflow deskflow; do
  expected=$(jq -r ".cgroup_pid_sets.$role|sort|join(\",\")" "$linux_inventory"); cg=$(jq -er ".units.$role.control_group" "$linux_inventory"); actual=$(sort -n "/sys/fs/cgroup$cg/cgroup.procs" | paste -sd, -)
  [[ $actual == "$expected" ]] || die "$role cgroup PID-set drifted"
 done
}

make_plan(){
 local temp old_coord marker_dev marker_ino marker_mode prepare_dev prepare_ino prepare_mode collector_dev collector_ino collector_mode
 if [[ -e $plan || -L $plan ]]; then ensure_sealed_sources || return 1; validate_plan || return 1; return; fi
 [[ $mode == execute ]] || die 'resume requires an immutable transition plan'
 ensure_sealed_sources || return 1
 new_operation=$(uuidgen | tr -d '-' | tr A-F a-f); new_coordinator=$(uuidgen | tr A-F a-f)
 old_coord=$(jq -er '.coordinator_instance_id' "$(jq -er '.adopted_artifacts.invalid_provenance_authorization.path' "$manifest")")
 [[ $new_operation =~ ^[0-9a-f]{32}$ && $new_operation != "$old_operation" && $new_coordinator != "$old_coord" ]] || die 'fresh identity generation failed'
 fresh_root=$DEPLOYMENTS/$new_operation; [[ ! -e $fresh_root && ! -L $fresh_root ]] || die 'fresh operation root exists'
 read -r marker_dev marker_ino marker_mode < <(stat -c '%d %i %a' -- "$marker_candidate"); read -r prepare_dev prepare_ino prepare_mode < <(stat -c '%d %i %a' -- "$prepare_script"); read -r collector_dev collector_ino collector_mode < <(stat -c '%d %i %a' -- "$collector_script")
 temp=$(mktemp --tmpdir="$bridge_root" .transition-plan.XXXXXX); temporary_files+=("$temp")
 jq -cn --arg old "$old_operation" --arg new "$new_operation" --arg coord "$new_coordinator" --arg incident "$incident_sha" --arg tomb "$tombstone_sha" --arg vfdqa "$vfdqa_sha" --arg manifest "$manifest_sha" --arg win "$windows_census_sha" --arg linux "$linux_inventory_sha" --arg raw_path "$windows_raw_census" --arg raw_sha "$windows_raw_census_sha" --arg upgrade_path "$transport_upgrade_path" --arg upgrade_sha "$transport_upgrade_sha" --arg classification_path "$stderr_classification_path" --arg classification_sha "$stderr_classification_sha" --arg disposition_path "$windows_disposition" --arg disposition_sha "$windows_disposition_sha" --arg fresh "$fresh_root" --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" --arg mp "$marker_candidate" --arg ms "$marker_snapshot" --arg mh "$marker_candidate_sha" --argjson md "$marker_dev" --argjson mi "$marker_ino" --argjson mm "$((8#$marker_mode))" --arg pp "$prepare_script" --arg ps "$prepare_snapshot" --arg ph "$prepare_script_sha" --argjson pd "$prepare_dev" --argjson pi "$prepare_ino" --argjson pm "$((8#$prepare_mode))" --arg cp "$collector_script" --arg cs "$collector_snapshot" --arg ch "$collector_script_sha" --argjson cd "$collector_dev" --argjson ci "$collector_ino" --argjson cm "$((8#$collector_mode))" '
  {schema_version:1,state:"viewflow-post-vfdqa-tombstone-to-fresh-v21-transition-plan",old_operation_id:$old,new_operation_id:$new,new_coordinator_instance_id:$coord,fresh_operation_root:$fresh,invalid_authorization_role:"historical-invalidity-proof-only-never-authority",inputs:{incident_sha256:$incident,tombstone_sha256:$tomb,vfdqa_sha256:$vfdqa,reconciliation_manifest_sha256:$manifest,windows_census_sha256:$win,linux_runtime_inventory_sha256:$linux,windows_raw_census:{path:$raw_path,sha256:$raw_sha},windows_transport_upgrade:{path:$upgrade_path,sha256:$upgrade_sha},windows_stderr_classification:{path:$classification_path,sha256:$classification_sha},windows_legacy_disposition:{path:$disposition_path,sha256:$disposition_sha},installed_viewflow_sha256:$vf,installed_viewflow_unit_sha256:$unit,execution_sources:{marker_candidate:{source_path:$mp,source_sha256:$mh,source_dev:$md,source_ino:$mi,source_mode:$mm,snapshot_path:$ms,snapshot_sha256:$mh},prepare_script:{source_path:$pp,source_sha256:$ph,source_dev:$pd,source_ino:$pi,source_mode:$pm,snapshot_path:$ps,snapshot_sha256:$ph},collector_script:{source_path:$cp,source_sha256:$ch,source_dev:$cd,source_ino:$ci,source_mode:$cm,snapshot_path:$cs,snapshot_sha256:$ch}}}}' >"$temp"
 publish_once "$temp" "$plan"; temporary_files=(); mkdir -- "$fresh_root"; chmod 0700 "$fresh_root"; sync -f "$DEPLOYMENTS"; validate_plan
}
validate_plan(){
 local old_coord marker_dev marker_ino marker_mode prepare_dev prepare_ino prepare_mode collector_dev collector_ino collector_mode
 private_input plan "$plan" "$(sha256 "$plan")" || return 1; strict_json "$plan" || return 1; old_coord=$(jq -er '.coordinator_instance_id' "$(jq -er '.adopted_artifacts.invalid_provenance_authorization.path' "$manifest")")
 [[ -d $sealed_dir && ! -L $sealed_dir && $(stat -c '%u:%a' -- "$sealed_dir") == 1000:500 ]] || { die 'sealed source directory is not immutable'; return 1; }
 safe_source sealed-marker-candidate "$marker_snapshot" "$marker_candidate_sha" || return 1; [[ $(stat -c %a -- "$marker_snapshot") == 500 ]] || { die 'sealed marker snapshot mode differs'; return 1; }
 safe_source sealed-prepare-script "$prepare_snapshot" "$prepare_script_sha" || return 1; [[ $(stat -c %a -- "$prepare_snapshot") == 500 ]] || { die 'sealed prepare snapshot mode differs'; return 1; }
 safe_source sealed-collector-script "$collector_snapshot" "$collector_script_sha" || return 1; [[ $(stat -c %a -- "$collector_snapshot") == 500 ]] || { die 'sealed collector snapshot mode differs'; return 1; }
 read -r marker_dev marker_ino marker_mode < <(stat -c '%d %i %a' -- "$marker_candidate"); read -r prepare_dev prepare_ino prepare_mode < <(stat -c '%d %i %a' -- "$prepare_script"); read -r collector_dev collector_ino collector_mode < <(stat -c '%d %i %a' -- "$collector_script")
 jq -e --arg old "$old_operation" --arg oldc "$old_coord" --arg i "$incident_sha" --arg t "$tombstone_sha" --arg v "$vfdqa_sha" --arg m "$manifest_sha" --arg w "$windows_census_sha" --arg l "$linux_inventory_sha" --arg rp "$windows_raw_census" --arg rs "$windows_raw_census_sha" --arg up "$transport_upgrade_path" --arg us "$transport_upgrade_sha" --arg cp2 "$stderr_classification_path" --arg cs2 "$stderr_classification_sha" --arg dp "$windows_disposition" --arg ds "$windows_disposition_sha" --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" --arg mp "$marker_candidate" --arg ms "$marker_snapshot" --arg mh "$marker_candidate_sha" --argjson md "$marker_dev" --argjson mi "$marker_ino" --argjson mm "$((8#$marker_mode))" --arg pp "$prepare_script" --arg ps "$prepare_snapshot" --arg ph "$prepare_script_sha" --argjson pd "$prepare_dev" --argjson pi "$prepare_ino" --argjson pm "$((8#$prepare_mode))" --arg cp "$collector_script" --arg cs "$collector_snapshot" --arg ch "$collector_script_sha" --argjson cd "$collector_dev" --argjson ci "$collector_ino" --argjson cm "$((8#$collector_mode))" '
  keys==["fresh_operation_root","inputs","invalid_authorization_role","new_coordinator_instance_id","new_operation_id","old_operation_id","schema_version","state"] and .schema_version==1 and .state=="viewflow-post-vfdqa-tombstone-to-fresh-v21-transition-plan" and .old_operation_id==$old and (.new_operation_id|test("^[0-9a-f]{32}$")) and .new_operation_id!=$old and (.new_coordinator_instance_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and .new_coordinator_instance_id!=$oldc and .fresh_operation_root==( "/home/wilf/.local/state/viewflow/deployments/"+.new_operation_id) and .invalid_authorization_role=="historical-invalidity-proof-only-never-authority" and .inputs=={incident_sha256:$i,tombstone_sha256:$t,vfdqa_sha256:$v,reconciliation_manifest_sha256:$m,windows_census_sha256:$w,linux_runtime_inventory_sha256:$l,windows_raw_census:{path:$rp,sha256:$rs},windows_transport_upgrade:{path:$up,sha256:$us},windows_stderr_classification:{path:$cp2,sha256:$cs2},windows_legacy_disposition:{path:$dp,sha256:$ds},installed_viewflow_sha256:$vf,installed_viewflow_unit_sha256:$unit,execution_sources:{marker_candidate:{source_path:$mp,source_sha256:$mh,source_dev:$md,source_ino:$mi,source_mode:$mm,snapshot_path:$ms,snapshot_sha256:$mh},prepare_script:{source_path:$pp,source_sha256:$ph,source_dev:$pd,source_ino:$pi,source_mode:$pm,snapshot_path:$ps,snapshot_sha256:$ph},collector_script:{source_path:$cp,source_sha256:$ch,source_dev:$cd,source_ino:$ci,source_mode:$cm,snapshot_path:$cs,snapshot_sha256:$ch}}}' "$plan" >/dev/null || { die 'transition plan binding differs'; return 1; }
 new_operation=$(jq -er .new_operation_id "$plan"); new_coordinator=$(jq -er .new_coordinator_instance_id "$plan"); fresh_root=$(jq -er .fresh_operation_root "$plan")
 [[ -d $fresh_root ]] || { mkdir -- "$fresh_root"; chmod 0700 "$fresh_root"; sync -f "$DEPLOYMENTS"; }; safe_dir 'fresh root' "$fresh_root"
 publish_receipt=$fresh_root/deployment-publish.json; handoff_receipt=$fresh_root/marker-handoff.json; frozen_evidence=$fresh_root/linux-frozen.json; final_receipt=$fresh_root/post-vfdqa-tombstone-to-fresh-v21.json
}

validate_acceptance_status(){
 local core_pid core_ticks boot
 core_pid=$(jq -er '.processes.deskflow[]|select(.role=="core")|.pid' "$linux_inventory")
 core_ticks=$(jq -er '.processes.deskflow[]|select(.role=="core")|.start_ticks' "$linux_inventory")
 boot=$(tr -d -- '-' </proc/sys/kernel/random/boot_id)
 jq -e --argjson pid "$core_pid" --argjson ticks "$core_ticks" --arg boot "$boot" '
  keys==["core_boot_id","core_pid","core_start_ticks","protocol_version","receipt_available","runtime_marker_path","runtime_marker_present","schema_version","sidecar_configured","sidecar_protocol_version","state"] and
  .schema_version==1 and .state=="deskflow-live-acceptance-status" and .protocol_version=="2.1" and
  .sidecar_protocol_version==3 and .sidecar_configured==true and .runtime_marker_path=="/home/wilf/.local/state/viewflow/deskflow-quarantine.v2" and
  .core_pid==$pid and .core_start_ticks==$ticks and .core_boot_id==$boot and .runtime_marker_present==false and .receipt_available==false' "$1" >/dev/null || { die 'acceptance status differs'; return 1; }
}
validate_cleanup_receipt(){
 local core_pid core_ticks core_sha daemon_pid daemon_ticks boot cleanup_id epoch
 core_pid=$(jq -er '.processes.deskflow[]|select(.role=="core")|.pid' "$linux_inventory"); core_ticks=$(jq -er '.processes.deskflow[]|select(.role=="core")|.start_ticks' "$linux_inventory"); core_sha=$(jq -er '.processes.deskflow[]|select(.role=="core")|.exe_sha256' "$linux_inventory")
 daemon_pid=$(jq -er '.processes.viewflow[0].pid' "$linux_inventory"); daemon_ticks=$(jq -er '.processes.viewflow[0].start_ticks' "$linux_inventory"); boot=$(tr -d -- '-' </proc/sys/kernel/random/boot_id)
 jq -e --arg op "$new_operation" --arg op_sha "$(printf '%s' "$new_operation"|sha256sum|awk '{print $1}')" --arg marker "$(jq -er '.vfdqa_binary.marker_sha256' "$manifest")" --arg core "$core_sha" --arg boot "$boot" --argjson cp "$core_pid" --argjson ct "$core_ticks" --argjson dp "$daemon_pid" --argjson dt "$daemon_ticks" '
  keys==["acknowledged","active_lease_generation","bound_peer_address","bound_peer_epoch","bound_peer_family","bound_peer_port","bound_peer_scope_id","cleanup_complete_body_size","cleanup_complete_mode","cleanup_operation_id","cleanup_sha256","completed_at_unix_ms","coordinator_operation_id","coordinator_operation_id_sha256","core_boot_id","core_executable_sha256","core_pid","core_start_ticks","daemon_boot_id","daemon_pid","daemon_start_ticks","deployment_marker_bound","deployment_marker_sha256","marker_last_sequence","owner_device_id","protocol_version","route_generation","runtime_marker_magic","runtime_marker_path","runtime_marker_released","runtime_marker_sha256","runtime_marker_size","schema_version","sidecar_protocol_version","source_display_id","state","target_device_id","tombstone_magic","tombstone_sha256","tombstone_size"] and
  .schema_version==1 and .state=="deskflow-runtime-cleanup-evidence" and .protocol_version=="2.1" and .sidecar_protocol_version==3 and .cleanup_complete_mode=="normal" and .cleanup_complete_body_size==277 and .coordinator_operation_id==$op and .coordinator_operation_id_sha256==$op_sha and
  .source_display_id=="00000000000000000000000000000101" and .target_device_id=="00000000000000000000000000000002" and .owner_device_id=="00000000000000000000000000000002" and .deployment_marker_bound==true and .deployment_marker_sha256==$marker and .acknowledged==true and
  .runtime_marker_magic=="VFQST002" and .runtime_marker_released==true and .runtime_marker_size==152 and .runtime_marker_path=="/home/wilf/.local/state/viewflow/deskflow-quarantine.v2" and .tombstone_magic=="VFACK001" and .tombstone_size==72 and
  (.cleanup_operation_id|test("^[0-9a-f]{32}$")) and .cleanup_operation_id!=("0"*32) and (.cleanup_sha256|test("^[0-9a-f]{64}$")) and (.runtime_marker_sha256|test("^[0-9a-f]{64}$")) and (.tombstone_sha256|test("^[0-9a-f]{64}$")) and
  .core_executable_sha256==$core and .core_pid==$cp and .core_start_ticks==$ct and .core_boot_id==$boot and .daemon_pid==$dp and .daemon_start_ticks==$dt and .daemon_boot_id==$boot and
  (.route_generation|type=="number" and .>0 and .==floor) and (.active_lease_generation|type=="number" and .>0 and .<9007199254740991 and .==floor) and (.marker_last_sequence|type=="number" and .>=0 and .<9007199254740991 and .==floor) and
  (.bound_peer_epoch|type=="number" and .>0 and .<=9007199254740991 and .==floor) and .bound_peer_family==4 and (.bound_peer_address|test("^[0-9a-f]{32}$")) and (.bound_peer_port|type=="number" and .>=1 and .<=65535 and .==floor) and .bound_peer_scope_id==0 and (.completed_at_unix_ms|type=="number" and .>0 and .==floor)' "$1" >/dev/null || { die 'cleanup receipt differs'; return 1; }
 cleanup_id=$(jq -er .cleanup_operation_id "$1"); epoch=$(jq -er .bound_peer_epoch "$1"); [[ ${cleanup_id:0:16} == "$(printf '%016x' "$epoch")" && ${cleanup_id:16:16} != 0000000000000000 ]] || { die 'cleanup epoch binding differs'; return 1; }
}
validate_cleanup_proof(){
 local nested
 private_input cleanup "$cleanup_proof" "$(sha256 "$cleanup_proof")" || return 1; strict_json "$cleanup_proof" || return 1; nested=$(mktemp --tmpdir="$bridge_root" .cleanup-nested.XXXXXX); temporary_files+=("$nested")
 if jq -e --arg op "$new_operation" 'keys==["acceptance_status","acceptance_status_sha256","operation_id","pressed_state","schema_version","state"] and .schema_version==1 and .state=="viewflow-post-vfdqa-retirement-no-active-route" and .operation_id==$op and .pressed_state=="no-active-route" and (.acceptance_status_sha256|test("^[0-9a-f]{64}$"))' "$cleanup_proof" >/dev/null; then
  jq -e .acceptance_status "$cleanup_proof" >"$nested"; validate_acceptance_status "$nested" || return 1; [[ $(canonical_json_sha "$nested") == "$(jq -er .acceptance_status_sha256 "$cleanup_proof")" ]] || { die 'acceptance status cross-hash differs'; return 1; }
 elif jq -e --arg op "$new_operation" 'keys==["cleanup_receipt","cleanup_receipt_sha256","operation_id","pressed_state","schema_version","state"] and .schema_version==1 and .state=="viewflow-post-vfdqa-retirement-release-all-applied" and .operation_id==$op and .pressed_state=="released" and (.cleanup_receipt_sha256|test("^[0-9a-f]{64}$"))' "$cleanup_proof" >/dev/null; then
  jq -e .cleanup_receipt "$cleanup_proof" >"$nested"; validate_cleanup_receipt "$nested" || return 1; [[ $(canonical_json_sha "$nested") == "$(jq -er .cleanup_receipt_sha256 "$cleanup_proof")" ]] || { die 'cleanup receipt cross-hash differs'; return 1; }
 else die 'cleanup proof exact schema differs'; return 1; fi
 [[ ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]] || { die 'VFQST002 reappeared'; return 1; }
}

ensure_cleanup(){
 local core status arm raw temp deadline marker_sha
 if [[ -e $cleanup_proof || -L $cleanup_proof ]]; then validate_cleanup_proof; return; fi
 validate_live_tuple; core=$(jq -er '.processes.deskflow[]|select(.role=="core")|.pid' "$linux_inventory"); marker_sha=$(jq -er '.vfdqa_binary.marker_sha256' "$manifest")
 status=$(mktemp --tmpdir="$bridge_root" .status.XXXXXX); temporary_files+=("$status")
 env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$ACCEPTANCE_SOCKET" "/proc/$core/exe" --viewflow-acceptance-query status >"$status"; strict_json "$status"
 temp=$(mktemp --tmpdir="$bridge_root" .cleanup.XXXXXX); temporary_files+=("$temp")
 if jq -e '.runtime_marker_present==false' "$status" >/dev/null; then
  validate_acceptance_status "$status"; jq -cn --arg op "$new_operation" --arg sha "$(canonical_json_sha "$status")" --slurpfile status "$status" '{schema_version:1,state:"viewflow-post-vfdqa-retirement-no-active-route",operation_id:$op,pressed_state:"no-active-route",acceptance_status_sha256:$sha,acceptance_status:$status[0]}' >"$temp"
 else
  arm=$(mktemp --tmpdir="$bridge_root" .arm.XXXXXX); temporary_files+=("$arm")
  env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$ACCEPTANCE_SOCKET" "/proc/$core/exe" --viewflow-acceptance-query arm --coordinator-operation-id "$new_operation" --source-display-id "$SOURCE_ID" --target-device-id "$TARGET_ID" --deployment-marker-sha256 "$marker_sha" >"$arm"
  jq -e '.schema_version==1 and .state=="viewflow-acceptance-armed" and .armed==true' "$arm" >/dev/null || die 'cleanup arm failed'
  printf 'RETURN_REQUIRED: return pointer local; waiting for ReleaseAll Applied and lease revoke\n' >&2; raw=$(mktemp --tmpdir="$bridge_root" .cleanup-raw.XXXXXX); temporary_files+=("$raw"); deadline=$((SECONDS+300))
  while ((SECONDS<deadline)); do env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$ACCEPTANCE_SOCKET" "/proc/$core/exe" --viewflow-acceptance-query cleanup --coordinator-operation-id "$new_operation" --source-display-id "$SOURCE_ID" --target-device-id "$TARGET_ID" --deployment-marker-sha256 "$marker_sha" >"$raw" 2>/dev/null && break; sleep .1; done
  validate_cleanup_receipt "$raw"; jq -cn --arg op "$new_operation" --arg sha "$(canonical_json_sha "$raw")" --slurpfile receipt "$raw" '{schema_version:1,state:"viewflow-post-vfdqa-retirement-release-all-applied",operation_id:$op,pressed_state:"released",cleanup_receipt_sha256:$sha,cleanup_receipt:$receipt[0]}' >"$temp"
 fi
 publish_once "$temp" "$cleanup_proof"; temporary_files=(); validate_cleanup_proof
}
transients_zero(){ local vu du; vu=$(jq -er .units.viewflow.unit "$linux_inventory"); du=$(jq -er .units.deskflow.unit "$linux_inventory"); [[ $(unit_prop "$vu" MainPID 2>/dev/null || true) =~ ^(0|)$ && $(unit_prop "$du" MainPID 2>/dev/null || true) =~ ^(0|)$ && -z $(exact_pids "$VIEWFLOW") && -z $(exact_pids "$DESKFLOW") && -z $(exact_pids "$DESKFLOW_CORE") && -z $(ss -H -lun 'sport = :44119') && -z $(ss -H -ltn 'sport = :24800') && ! -e $SIDECAR_SOCKET && ! -e $RUNTIME_MARKER && -z $(unit_prop "$vu" ControlGroup 2>/dev/null || true) && -z $(unit_prop "$du" ControlGroup 2>/dev/null || true) ]]; }
retire_transients(){ local vu du deadline; transients_zero && return; validate_live_tuple; vu=$(jq -er .units.viewflow.unit "$linux_inventory"); du=$(jq -er .units.deskflow.unit "$linux_inventory"); systemctl --user stop "$du"; systemctl --user stop "$vu"; deadline=$((SECONDS+30)); while ((SECONDS<deadline)); do transients_zero && return; sleep .1; done; die 'retirement did not reach zero'; }

snapshot_config(){
 local temp
 if [[ -e $config_intent || -L $config_intent ]]; then private_input config-intent "$config_intent" "$(sha256 "$config_intent")"; validate_config_intent; return; fi
 temp=$(mktemp --tmpdir="$bridge_root" .config-intent.XXXXXX); temporary_files+=("$temp")
 python3 -I -E - "$temp" "${CONFIG_PATHS[@]}" <<'PY'
import hashlib,json,os,stat,sys
out=[]
for p in sys.argv[2:]:
 st=os.lstat(p)
 if st.st_uid!=1000 or st.st_nlink!=1: raise SystemExit('config owner/link drift')
 if stat.S_ISLNK(st.st_mode):
  data=os.readlink(p).encode()
  if data!=b'/dev/null' or stat.S_IMODE(st.st_mode)!=0o777: raise SystemExit('mask drift')
  kind='symlink'
 elif stat.S_ISREG(st.st_mode) and p.endswith('zz-direct-deskflow.conf') and not(stat.S_IMODE(st.st_mode)&0o022): kind='regular'; data=open(p,'rb').read()
 else: raise SystemExit('config type drift')
 out.append({'path':p,'backup_leaf':str(len(out))+'-'+os.path.basename(p),'kind':kind,'uid':st.st_uid,'mode':stat.S_IMODE(st.st_mode),'nlink':st.st_nlink,'dev':st.st_dev,'ino':st.st_ino,'sha256':hashlib.sha256(data).hexdigest()})
open(sys.argv[1],'w').write(json.dumps({'schema_version':1,'state':'viewflow-post-vfdqa-runtime-config-relocation-intent','entries':out},sort_keys=True,separators=(',',':')))
PY
 publish_once "$temp" "$config_intent"; temporary_files=(); validate_config_intent
}
validate_config_intent(){ strict_json "$config_intent"; jq -e '
 keys==["entries","schema_version","state"] and .schema_version==1 and .state=="viewflow-post-vfdqa-runtime-config-relocation-intent" and (.entries|length)==5 and
 [.entries[].path]==["/run/user/1000/systemd/user.control/deskflow.service","/run/user/1000/systemd/user.control/viewflow-peer.service","/run/user/1000/systemd/user/deskflow.service","/run/user/1000/systemd/user/viewflow-peer.service","/run/user/1000/systemd/user/deskflow.service.d/zz-direct-deskflow.conf"] and
 [.entries[].backup_leaf]==["0-deskflow.service","1-viewflow-peer.service","2-deskflow.service","3-viewflow-peer.service","4-zz-direct-deskflow.conf"] and [.entries[].kind]==["symlink","symlink","symlink","symlink","regular"] and
 all(.entries[]; keys==["backup_leaf","dev","ino","kind","mode","nlink","path","sha256","uid"] and .uid==1000 and .nlink==1 and (.sha256|test("^[0-9a-f]{64}$")))' "$config_intent" >/dev/null || die 'config intent contract differs'; }
relocate_one(){ python3 -I -E - "$config_intent" "$1" "$backup_dir" <<'PY'
import ctypes,hashlib,json,os,stat,sys
e=json.load(open(sys.argv[1]))['entries'][int(sys.argv[2])]; src=e['path']; leaf=e['backup_leaf']
if os.path.isabs(leaf) or os.path.basename(leaf)!=leaf: raise SystemExit('unsafe backup leaf')
dst=os.path.join(sys.argv[3],leaf)
def check(p):
 st=os.lstat(p); kind='symlink' if stat.S_ISLNK(st.st_mode) else 'regular'; data=os.readlink(p).encode() if kind=='symlink' else open(p,'rb').read()
 if (kind,st.st_uid,stat.S_IMODE(st.st_mode),st.st_nlink,st.st_dev,st.st_ino,hashlib.sha256(data).hexdigest())!=(e['kind'],e['uid'],e['mode'],e['nlink'],e['dev'],e['ino'],e['sha256']): raise SystemExit('config tuple drift')
if os.path.lexists(src) and os.path.lexists(dst): raise SystemExit('both config names exist')
if os.path.lexists(dst): check(dst); raise SystemExit(0)
if not os.path.lexists(src): raise SystemExit('neither config name exists')
check(src); libc=ctypes.CDLL(None,use_errno=True); RENAME_NOREPLACE=1
if libc.renameat2(-100,src.encode(),-100,dst.encode(),RENAME_NOREPLACE)!=0: raise OSError(ctypes.get_errno(),os.strerror(ctypes.get_errno()))
for d in (os.path.dirname(src),os.path.dirname(dst)):
 fd=os.open(d,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); os.fsync(fd); os.close(fd)
check(dst)
PY
}
relocate_config(){ local i; snapshot_config; if [[ ! -e $backup_dir && ! -L $backup_dir ]]; then mkdir -- "$backup_dir"; chmod 0700 "$backup_dir"; sync -f "$bridge_root"; fi; safe_dir backup "$backup_dir"; for i in 0 1 2 3 4; do relocate_one "$i"; done; systemctl --user daemon-reload; }

validate_fresh_marker_bytes(){ python3 -I -E - "$MARKER" "$new_operation" "$new_coordinator" <<'PY'
import sys,uuid
b=open(sys.argv[1],'rb').read(); op=sys.argv[2].encode()
if len(b)!=256 or b[:13]!=b'VFDQT001\x01\x01\x02\x01\x01' or b[13]!=len(op) or any(b[14:16]) or b[16:16+len(op)]!=op or any(b[16+len(op):144]): raise SystemExit('fresh marker header/operation differs')
if b[144:160]!=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes or b[160:176]!=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes or b[176:192]!=uuid.UUID(sys.argv[3]).bytes: raise SystemExit('fresh marker identity differs')
if int.from_bytes(b[192:200],'little')==0 or int.from_bytes(b[200:208],'little')!=1 or any(b[208:]): raise SystemExit('fresh marker time/generation differs')
PY
}
validate_publish_receipt(){
 [[ -f $MARKER && ! -L $MARKER && $(stat -c '%u:%a:%h:%s' -- "$MARKER") == 1000:600:1:256 ]] || { die 'fresh marker metadata differs'; return 1; }
 validate_fresh_marker_bytes || return 1; private_input publish "$publish_receipt" "$(sha256 "$publish_receipt")" || return 1; strict_json "$publish_receipt" || return 1
 jq -e --arg op "$new_operation" --arg c "$new_coordinator" --arg marker "$(sha256 "$MARKER")" '
  keys==["coordinator_instance_id","created_at_unix_ms","created_at_utc","marker_generation","marker_path","marker_sha256","operation_id","protocol_version","schema_version","source_display_id","state","target_device_id"] and
  .schema_version==1 and .state=="deployment-quarantine-published" and .protocol_version=="2.1" and .operation_id==$op and .coordinator_instance_id==$c and .marker_generation=="1" and
  .source_display_id=="00000000-0000-0000-0000-000000000101" and .target_device_id=="00000000-0000-0000-0000-000000000002" and .marker_path=="/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and .marker_sha256==$marker and
  (.created_at_unix_ms|test("^[1-9][0-9]*$")) and (.created_at_utc|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))' "$publish_receipt" >/dev/null || { die 'publish receipt exact schema differs'; return 1; }
}
validate_handoff(){
 local gui_sha core_sha
 validate_publish_receipt || return 1; gui_sha=$(jq -er '.processes.deskflow[]|select(.role=="gui")|.exe_sha256' "$linux_inventory"); core_sha=$(jq -er '.processes.deskflow[]|select(.role=="core")|.exe_sha256' "$linux_inventory")
 private_input H "$handoff_receipt" "$(sha256 "$handoff_receipt")" || return 1; strict_json "$handoff_receipt" || return 1
 jq -e --arg op "$new_operation" --arg c "$new_coordinator" --arg cli "$marker_candidate_sha" --arg marker "$(sha256 "$MARKER")" --arg pp "$publish_receipt" --arg ps "$(sha256 "$publish_receipt")" --arg gui "$gui_sha" --arg core "$core_sha" '
  keys==["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256","deployment_publish_receipt_path","deployment_publish_receipt_sha256","deskflow_core_exact_process_count","deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_exact_process_count","deskflow_executable_path","deskflow_executable_sha256","deskflow_tcp_listener_count","deskflow_tcp_port","deskflow_unit","deskflow_unit_active_state","deskflow_unit_main_pid","marker_cli_path","marker_cli_sha256","marker_generation","observed_at_utc","operation_id","protocol_version","runtime_marker_path","runtime_marker_present","schema_version","source_display_id","state","target_device_id"] and
  .schema_version==1 and .state=="viewflow-v13-marker-handoff-prepared" and .protocol_version=="2.1" and .operation_id==$op and .coordinator_instance_id==$c and .marker_generation=="1" and
  .source_display_id=="00000000-0000-0000-0000-000000000101" and .target_device_id=="00000000-0000-0000-0000-000000000002" and .marker_cli_path=="/home/wilf/.local/lib/viewflow/viewflow-deployment-marker" and .marker_cli_sha256==$cli and
  .deployment_marker_path=="/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and .deployment_marker_sha256==$marker and .deployment_publish_receipt_path==$pp and .deployment_publish_receipt_sha256==$ps and
  .deskflow_unit=="deskflow.service" and .deskflow_unit_active_state=="inactive" and .deskflow_unit_main_pid==0 and .deskflow_executable_path=="/home/wilf/.local/lib/deskflow-scale-fix/deskflow" and .deskflow_executable_sha256==$gui and .deskflow_exact_process_count==0 and
  .deskflow_core_executable_path=="/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core" and .deskflow_core_executable_sha256==$core and .deskflow_core_exact_process_count==0 and .deskflow_tcp_port==24800 and .deskflow_tcp_listener_count==0 and
  .runtime_marker_path=="/home/wilf/.local/state/viewflow/deskflow-quarantine.v2" and .runtime_marker_present==false and (.observed_at_utc|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000Z$"))' "$handoff_receipt" >/dev/null || { die 'H exact schema/cross-binding differs'; return 1; }
}
recover_partial_handoff(){
 local temp marker_sha created_ms created_utc observed gui_sha core_sha
 [[ -f $MARKER && ! -L $MARKER && $(stat -c '%u:%a:%h:%s' -- "$MARKER") == 1000:600:1:256 ]] || die 'partial marker is unsafe'; validate_fresh_marker_bytes; marker_sha=$(sha256 "$MARKER")
 [[ -f $MARKER_CLI && ! -L $MARKER_CLI && $(sha256 "$MARKER_CLI") == "$marker_candidate_sha" ]] || die 'marker CLI differs during recovery'
 if [[ ! -e $publish_receipt && ! -L $publish_receipt ]]; then
  read -r created_ms created_utc < <(python3 -I -E - "$MARKER" <<'PY'
import datetime,sys
b=open(sys.argv[1],'rb').read(); ms=int.from_bytes(b[192:200],'little'); d=datetime.datetime.fromtimestamp(ms/1000,datetime.timezone.utc); print(ms,d.strftime('%Y-%m-%dT%H:%M:%S.')+f'{ms%1000:03d}Z')
PY
  )
  temp=$(mktemp --tmpdir="$fresh_root" .recovered-publish.XXXXXX); temporary_files+=("$temp"); jq -cn --arg op "$new_operation" --arg c "$new_coordinator" --arg marker "$marker_sha" --arg ms "$created_ms" --arg utc "$created_utc" '{schema_version:1,state:"deployment-quarantine-published",protocol_version:"2.1",operation_id:$op,source_display_id:"00000000-0000-0000-0000-000000000101",target_device_id:"00000000-0000-0000-0000-000000000002",coordinator_instance_id:$c,marker_generation:"1",marker_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",marker_sha256:$marker,created_at_unix_ms:$ms,created_at_utc:$utc}' >"$temp"; publish_once "$temp" "$publish_receipt"; temporary_files=()
 fi
 validate_publish_receipt
 if [[ ! -e $handoff_receipt && ! -L $handoff_receipt ]]; then
  [[ $(unit_prop "$DESKFLOW_UNIT" MainPID 2>/dev/null || true) =~ ^(0|)$ && -z $(exact_pids "$DESKFLOW") && -z $(exact_pids "$DESKFLOW_CORE") && -z $(ss -H -ltn 'sport = :24800') && ! -e $RUNTIME_MARKER ]] || die 'H recovery boundary is not quiescent'
  gui_sha=$(jq -er '.processes.deskflow[]|select(.role=="gui")|.exe_sha256' "$linux_inventory"); core_sha=$(jq -er '.processes.deskflow[]|select(.role=="core")|.exe_sha256' "$linux_inventory"); safe_source installed-deskflow "$DESKFLOW" "$gui_sha"; safe_source installed-deskflow-core "$DESKFLOW_CORE" "$core_sha"
  observed=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z'); temp=$(mktemp --tmpdir="$fresh_root" .recovered-h.XXXXXX); temporary_files+=("$temp")
  jq -cn --arg op "$new_operation" --arg c "$new_coordinator" --arg cli "$marker_candidate_sha" --arg marker "$marker_sha" --arg pp "$publish_receipt" --arg ps "$(sha256 "$publish_receipt")" --arg gui "$gui_sha" --arg core "$core_sha" --arg at "$observed" '{schema_version:1,state:"viewflow-v13-marker-handoff-prepared",protocol_version:"2.1",operation_id:$op,source_display_id:"00000000-0000-0000-0000-000000000101",target_device_id:"00000000-0000-0000-0000-000000000002",coordinator_instance_id:$c,marker_generation:"1",marker_cli_path:"/home/wilf/.local/lib/viewflow/viewflow-deployment-marker",marker_cli_sha256:$cli,deployment_marker_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",deployment_marker_sha256:$marker,deployment_publish_receipt_path:$pp,deployment_publish_receipt_sha256:$ps,deskflow_unit:"deskflow.service",deskflow_unit_active_state:"inactive",deskflow_unit_main_pid:0,deskflow_executable_path:"/home/wilf/.local/lib/deskflow-scale-fix/deskflow",deskflow_executable_sha256:$gui,deskflow_exact_process_count:0,deskflow_core_executable_path:"/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core",deskflow_core_executable_sha256:$core,deskflow_core_exact_process_count:0,deskflow_tcp_port:24800,deskflow_tcp_listener_count:0,runtime_marker_path:"/home/wilf/.local/state/viewflow/deskflow-quarantine.v2",runtime_marker_present:false,observed_at_utc:$at}' >"$temp"; publish_once "$temp" "$handoff_receipt"; temporary_files=()
 fi
 validate_handoff
}
validate_collector_intent(){
 private_input collector-intent "$1" "$(sha256 "$1")" || return 1; strict_json "$1" || return 1
 jq -e --arg op "$new_operation" --arg sha "$installed_viewflow_sha" 'keys==["boot_id","daemon_pid","daemon_sha256","daemon_start_ticks","invocation_id","operation_id","schema_version","state"] and .schema_version==1 and .state=="viewflow-fresh-v13-collector-intent" and .operation_id==$op and .daemon_sha256==$sha and (.daemon_pid|type=="number" and .>0 and .==floor) and (.daemon_start_ticks|type=="number" and .>0 and .==floor) and (.boot_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and (.invocation_id|test("^[0-9a-f]{32}$"))' "$1" >/dev/null || { die 'collector intent exact schema differs'; return 1; }
}
validate_frozen(){
 local intent=$fresh_root/collector-intent.json boot completed age
 validate_collector_intent "$intent" || return 1; private_input B "$frozen_evidence" "$(sha256 "$frozen_evidence")" || return 1; strict_json "$frozen_evidence" || return 1
 jq -e --arg op "$new_operation" --arg sha "$installed_viewflow_sha" --slurpfile intent "$intent" '
  keys==["completed_at_unix_ms","daemon","journal","operation_id","post_stop","pre_stop","schema_version","state"] and .schema_version==1 and .state=="viewflow-v13-bootstrap-frozen" and .operation_id==$op and
  (.daemon|keys)==["boot_id","daemon_instance_id","executable","pid","sha256","start_ticks","systemd_invocation_id"] and .daemon.sha256==$sha and .daemon.executable=="/home/wilf/.local/lib/viewflow/viewflowd" and (.daemon.pid|type=="number" and .>0 and .==floor) and (.daemon.start_ticks|type=="number" and .>0 and .==floor) and .daemon.daemon_instance_id==(.daemon.boot_id+"-"+(.daemon.pid|tostring)+"-"+(.daemon.start_ticks|tostring)) and
  .daemon.pid==$intent[0].daemon_pid and .daemon.start_ticks==$intent[0].daemon_start_ticks and .daemon.boot_id==$intent[0].boot_id and .daemon.systemd_invocation_id==$intent[0].invocation_id and .daemon.sha256==$intent[0].daemon_sha256 and
  (.journal|keys)==["counts","end_cursor","end_realtime_timestamp_us","entry_count","protocol_startup_cursor","protocol_startup_realtime_timestamp_us","query_boot_id","query_pid","query_systemd_invocation_id","slice_sha256","start_cursor","start_realtime_timestamp_us"] and .journal.query_boot_id==(.daemon.boot_id|gsub("-";"")) and .journal.query_pid==(.daemon.pid|tostring) and .journal.query_systemd_invocation_id==.daemon.systemd_invocation_id and .journal.entry_count>0 and (.journal.slice_sha256|test("^[0-9a-f]{64}$")) and
  (.journal.counts|keys)==["cleanup_or_release_error","input_event","input_sidecar_activation","lease_offered","protocol_1_3_startup"] and .journal.counts.protocol_1_3_startup==1 and all(.journal.counts[];type=="number" and .>=0 and .==floor) and
  .pre_stop=={deskflow_unit_active_state:"inactive",deskflow_main_pid:0,deskflow_exact_process_count:0,deskflow_core_exact_process_count:0,deskflow_tcp_24800_listener_count:0} and
  (.post_stop|keys)==["command_output_format","command_output_sha256","command_outputs","exact_process_count","main_pid","original_daemon_pid_present","sidecar_socket_present","udp_44119_listener_count","unit_active_state"] and .post_stop.unit_active_state=="inactive" and .post_stop.main_pid==0 and .post_stop.exact_process_count==0 and .post_stop.udp_44119_listener_count==0 and .post_stop.sidecar_socket_present==false and .post_stop.original_daemon_pid_present==false and
  .post_stop.command_outputs=={systemctl_is_active:"inactive",systemctl_main_pid:"0",exact_viewflow_pids:"",udp_44119_listeners:"",sidecar_socket_present:"false",original_daemon_pid_present:"false"} and .post_stop.command_output_format=="key=value newline-delimited UTF-8 in displayed order" and (.post_stop.command_output_sha256|test("^[0-9a-f]{64}$")) and (.completed_at_unix_ms|type=="number" and .>0 and .==floor)' "$frozen_evidence" >/dev/null || { die 'B exact schema/cross-binding differs'; return 1; }
 boot=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id); [[ $(jq -er .daemon.boot_id "$frozen_evidence") == "$boot" && ! -e /proc/$(jq -er .daemon.pid "$frozen_evidence") ]] || { die 'B boot/PID boundary differs'; return 1; }
 completed=$(jq -er .completed_at_unix_ms "$frozen_evidence"); age=$(($(date -u +%s)-completed/1000)); ((age>=0 && age<=1800)) || { die 'B is stale or future'; return 1; }
}
recover_frozen_after_collector_stop(){
 local intent=$1 pid ticks boot inv journal_boot journal transcript temp entries start_cursor start_us startup_cursor startup_us end_cursor end_us journal_sha transcript_sha completed startup_count lease_count input_count activation_count error_count
 validate_collector_intent "$intent" || return 1; pid=$(jq -er .daemon_pid "$intent"); ticks=$(jq -er .daemon_start_ticks "$intent"); boot=$(jq -er .boot_id "$intent"); inv=$(jq -er .invocation_id "$intent"); journal_boot=${boot//-/}
 [[ $(tr -d '\r\n' </proc/sys/kernel/random/boot_id) == "$boot" && ! -e /proc/$pid && $(unit_prop "$VIEWFLOW_UNIT" MainPID) == 0 && -z $(exact_pids "$VIEWFLOW") && -z $(ss -H -lun 'sport = :44119') && ! -e $SIDECAR_SOCKET ]] || { die 'collector-stop recovery boundary differs'; return 1; }
 journal=$(mktemp --tmpdir="$fresh_root" .collector-journal.XXXXXX); temporary_files+=("$journal"); journalctl --user --quiet --no-pager --output=json "_SYSTEMD_INVOCATION_ID=$inv" "_PID=$pid" "_BOOT_ID=$journal_boot" >"$journal"
 jq -s -e --arg inv "$inv" --arg pid "$pid" --arg boot "$journal_boot" 'length>0 and all(.[];._SYSTEMD_INVOCATION_ID==$inv and ._PID==$pid and ._BOOT_ID==$boot)' "$journal" >/dev/null || { die 'collector recovery journal crosses invocation'; return 1; }
 startup_count=$(jq -sr --arg line "$STARTUP" '[.[]|select((.MESSAGE//"")==$line)]|length' "$journal"); [[ $startup_count == 1 ]] || { die 'collector recovery needs one startup line'; return 1; }
 lease_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("lease_offered="))]|length' "$journal"); input_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("input_event_sequence="))]|length' "$journal"); activation_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("input sidecar activation"))]|length' "$journal"); error_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("(?i)(((cleanup|release[-_ ]?all|releaseall).*(failed|error|not confirmed|timed out|rejected))|((failed|error).*(cleanup|release[-_ ]?all|releaseall)))"))]|length' "$journal")
 entries=$(jq -s length "$journal"); start_cursor=$(jq -sr '.[0].__CURSOR' "$journal"); start_us=$(jq -sr '.[0].__REALTIME_TIMESTAMP' "$journal"); startup_cursor=$(jq -sr --arg line "$STARTUP" '[.[]|select(.MESSAGE==$line)][0].__CURSOR' "$journal"); startup_us=$(jq -sr --arg line "$STARTUP" '[.[]|select(.MESSAGE==$line)][0].__REALTIME_TIMESTAMP' "$journal"); end_cursor=$(jq -sr '.[-1].__CURSOR' "$journal"); end_us=$(jq -sr '.[-1].__REALTIME_TIMESTAMP' "$journal"); journal_sha=$(sha256 "$journal")
 transcript=$(mktemp --tmpdir="$fresh_root" .collector-transcript.XXXXXX); temporary_files+=("$transcript"); printf '%s\n' 'systemctl_is_active=inactive' 'systemctl_main_pid=0' 'exact_viewflow_pids=' 'udp_44119_listeners=' 'sidecar_socket_present=false' 'original_daemon_pid_present=false' >"$transcript"; transcript_sha=$(sha256 "$transcript"); completed=$(($(date -u +%s%N)/1000000))
 temp=$(mktemp --tmpdir="$fresh_root" .recovered-b.XXXXXX); temporary_files+=("$temp")
 jq -n --arg op "$new_operation" --argjson pid "$pid" --argjson ticks "$ticks" --arg boot "$boot" --arg jb "$journal_boot" --arg sha "$installed_viewflow_sha" --arg inv "$inv" --arg sc "$start_cursor" --argjson su "$start_us" --arg pc "$startup_cursor" --argjson pu "$startup_us" --arg ec "$end_cursor" --argjson eu "$end_us" --argjson entries "$entries" --arg js "$journal_sha" --argjson startup "$startup_count" --argjson lease "$lease_count" --argjson input "$input_count" --argjson activation "$activation_count" --argjson errors "$error_count" --arg ts "$transcript_sha" --argjson completed "$completed" '{schema_version:1,state:"viewflow-v13-bootstrap-frozen",operation_id:$op,daemon:{pid:$pid,start_ticks:$ticks,boot_id:$boot,daemon_instance_id:($boot+"-"+($pid|tostring)+"-"+($ticks|tostring)),sha256:$sha,executable:"/home/wilf/.local/lib/viewflow/viewflowd",systemd_invocation_id:$inv},journal:{query_boot_id:$jb,query_pid:($pid|tostring),query_systemd_invocation_id:$inv,start_cursor:$sc,start_realtime_timestamp_us:$su,protocol_startup_cursor:$pc,protocol_startup_realtime_timestamp_us:$pu,end_cursor:$ec,end_realtime_timestamp_us:$eu,entry_count:$entries,slice_sha256:$js,counts:{protocol_1_3_startup:$startup,lease_offered:$lease,input_event:$input,input_sidecar_activation:$activation,cleanup_or_release_error:$errors}},pre_stop:{deskflow_unit_active_state:"inactive",deskflow_main_pid:0,deskflow_exact_process_count:0,deskflow_core_exact_process_count:0,deskflow_tcp_24800_listener_count:0},post_stop:{unit_active_state:"inactive",main_pid:0,exact_process_count:0,udp_44119_listener_count:0,sidecar_socket_present:false,original_daemon_pid_present:false,command_outputs:{systemctl_is_active:"inactive",systemctl_main_pid:"0",exact_viewflow_pids:"",udp_44119_listeners:"",sidecar_socket_present:"false",original_daemon_pid_present:"false"},command_output_format:"key=value newline-delimited UTF-8 in displayed order",command_output_sha256:$ts},completed_at_unix_ms:$completed}' >"$temp"
 publish_once "$temp" "$frozen_evidence" || return 1; temporary_files=(); validate_frozen || return 1
}
ensure_persistent_v13(){
 local pid deadline inv
 [[ $(sha256 "$VIEWFLOW") == "$installed_viewflow_sha" && $(sha256 "$VIEWFLOW_UNIT_FILE") == "$installed_unit_sha" ]] || die 'installed persistent v1.3 bytes differ'
 if [[ $(unit_prop "$VIEWFLOW_UNIT" ActiveState) != active ]]; then systemctl --user start "$VIEWFLOW_UNIT"; fi
 deadline=$((SECONDS+30)); pid=0
 while ((SECONDS<deadline)); do pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true); [[ $pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$pid/exe" 2>/dev/null || true) == "$installed_viewflow_sha" ]] && break; sleep .1; done
 [[ $pid =~ ^[1-9][0-9]*$ ]] || die 'persistent v1.3 did not reach an exact PID'; inv=$(unit_prop "$VIEWFLOW_UNIT" InvocationID)
 journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$inv" | grep -Fqx "$STARTUP" || die 'persistent v1.3 exact startup line absent'
 [[ $(ss -H -lunp 'sport = :44119') == *"pid=$pid,"* ]] || die 'persistent v1.3 does not own UDP 44119'
}
run_prepare_snapshot(){
 python3 -I -E - "$sealed_dir" "$prepare_script_sha" "$marker_candidate_sha" "$new_operation" "$new_coordinator" "$publish_receipt" "$handoff_receipt" <<'PY'
import hashlib,os,stat,sys
root,script_sha,marker_sha,op,coord,publish,handoff=sys.argv[1:]
dfd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
def verified(name,expected):
 fd=os.open(name,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=dfd); st=os.fstat(fd); data=b''
 while True:
  part=os.read(fd,1024*1024)
  if not part: break
  data+=part
 if not(stat.S_ISREG(st.st_mode) and st.st_uid==1000 and stat.S_IMODE(st.st_mode)==0o500 and st.st_nlink==1 and hashlib.sha256(data).hexdigest()==expected): raise SystemExit(name+' snapshot differs')
 os.lseek(fd,0,os.SEEK_SET); os.set_inheritable(fd,True); return fd
dst=os.fstat(dfd)
if not(stat.S_ISDIR(dst.st_mode) and dst.st_uid==1000 and stat.S_IMODE(dst.st_mode)==0o500): raise SystemExit('sealed directory differs')
sfd=verified('prepare-script',script_sha); verified('marker-candidate',marker_sha); os.set_inheritable(dfd,True)
script=f'/proc/self/fd/{sfd}'; candidate=f'/proc/self/fd/{dfd}/marker-candidate'
argv=['/usr/bin/bash',script,'--deployment-marker-candidate',candidate,'--deployment-marker-sha256',marker_sha,'--operation-id',op,'--source-display-id','00000000-0000-0000-0000-000000000101','--target-device-id','00000000-0000-0000-0000-000000000002','--coordinator-instance-id',coord,'--marker-generation','1','--deployment-publish-receipt',publish,'--bootstrap-handoff-receipt',handoff]
os.execve('/usr/bin/bash',argv,{'HOME':'/home/wilf','PATH':'/usr/bin:/bin'})
PY
}
run_collector_snapshot(){
 python3 -I -E - "$sealed_dir" "$collector_script_sha" "$1" "$new_operation" "$frozen_evidence" "$installed_viewflow_sha" <<'PY'
import hashlib,os,stat,sys
root,expected,pid,op,out,daemon_sha=sys.argv[1:]
dfd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW); dst=os.fstat(dfd)
if not(stat.S_ISDIR(dst.st_mode) and dst.st_uid==1000 and stat.S_IMODE(dst.st_mode)==0o500): raise SystemExit('sealed directory differs')
fd=os.open('collector-script',os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=dfd); st=os.fstat(fd); data=b''
while True:
 b=os.read(fd,1024*1024)
 if not b: break
 data+=b
if not(stat.S_ISREG(st.st_mode) and st.st_uid==1000 and stat.S_IMODE(st.st_mode)==0o500 and st.st_nlink==1 and hashlib.sha256(data).hexdigest()==expected): raise SystemExit('collector snapshot differs')
os.lseek(fd,0,os.SEEK_SET); os.set_inheritable(fd,True); script=f'/proc/self/fd/{fd}'
os.execve('/usr/bin/bash',['/usr/bin/bash',script,'--daemon-pid',pid,'--daemon-sha256',daemon_sha,'--operation-id',op,'--evidence-output',out],{'HOME':'/home/wilf','PATH':'/usr/bin:/bin'})
PY
}

fresh_chain(){
 local pid intent
 safe_source installed-viewflow "$VIEWFLOW" "$installed_viewflow_sha"; safe_source installed-viewflow-unit "$VIEWFLOW_UNIT_FILE" "$installed_unit_sha"
 if [[ -e $MARKER || -L $MARKER || -e $publish_receipt || -L $publish_receipt ]]; then recover_partial_handoff
 elif [[ -e $handoff_receipt || -L $handoff_receipt ]]; then die 'H exists without marker/publish receipt'
 else
  ensure_persistent_v13; run_prepare_snapshot; validate_handoff
 fi
 if [[ ! -e $frozen_evidence && ! -L $frozen_evidence ]]; then
  intent=$fresh_root/collector-intent.json; pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID)
  if [[ -e $intent || -L $intent ]]; then
   validate_collector_intent "$intent"
   if [[ $pid == 0 ]]; then recover_frozen_after_collector_stop "$intent"
   else [[ $pid == "$(jq -er .daemon_pid "$intent")" && $(process_ticks "$pid") == "$(jq -er .daemon_start_ticks "$intent")" && $(unit_prop "$VIEWFLOW_UNIT" InvocationID) == "$(jq -er .invocation_id "$intent")" && $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" ]] || die 'live collector tuple differs from immutable intent'; run_collector_snapshot "$pid"; fi
  else
   if [[ ! $pid =~ ^[1-9][0-9]*$ ]]; then ensure_persistent_v13; pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID); fi
   local temp; temp=$(mktemp --tmpdir="$fresh_root" .collector-intent.XXXXXX); temporary_files+=("$temp"); jq -cn --arg op "$new_operation" --argjson pid "$pid" --argjson ticks "$(process_ticks "$pid")" --arg boot "$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)" --arg inv "$(unit_prop "$VIEWFLOW_UNIT" InvocationID)" --arg sha "$installed_viewflow_sha" '{schema_version:1,state:"viewflow-fresh-v13-collector-intent",operation_id:$op,daemon_pid:$pid,daemon_start_ticks:$ticks,boot_id:$boot,invocation_id:$inv,daemon_sha256:$sha}' >"$temp"; publish_once "$temp" "$intent"; temporary_files=(); run_collector_snapshot "$pid"
  fi
 fi
 validate_frozen
}
publish_final(){
 local temp
 if [[ -e $final_receipt || -L $final_receipt ]]; then validate_final_receipt; return; fi
 transients_zero || die 'final zero boundary differs'
 temp=$(mktemp --tmpdir="$fresh_root" .final.XXXXXX); temporary_files+=("$temp")
 jq -cn --arg old "$old_operation" --arg new "$new_operation" --arg coord "$new_coordinator" --arg plan "$(sha256 "$plan")" --arg incident "$incident_sha" --arg tomb "$tombstone_sha" --arg cleanup "$(sha256 "$cleanup_proof")" --arg config "$(sha256 "$config_intent")" --arg h "$(sha256 "$handoff_receipt")" --arg b "$(sha256 "$frozen_evidence")" --arg raw_path "$windows_raw_census" --arg raw_sha "$windows_raw_census_sha" --arg upgrade_path "$transport_upgrade_path" --arg upgrade_sha "$transport_upgrade_sha" --arg classification_path "$stderr_classification_path" --arg classification_sha "$stderr_classification_sha" --arg disposition_path "$windows_disposition" --arg disposition_sha "$windows_disposition_sha" '{schema_version:1,state:"viewflow-post-vfdqa-linux-fresh-v21-bootstrap-boundary-ready",old_operation_id:$old,new_operation_id:$new,new_coordinator_instance_id:$coord,marker_generation:"1",transition_plan_sha256:$plan,old_incident:{incident_sha256:$incident,invalid_authorization_tombstone_sha256:$t,old_authorization_role:"invalidity-proof-only"},retirement:{cleanup_proof_sha256:$cleanup,deskflow_stopped_before_viewflow:true,release_all_or_no_route_proven:true,zero_listeners_processes_sockets_vfqst002:true},runtime_config_relocation:{intent_sha256:$config,item_count:5,rename_method:"renameat2-RENAME_NOREPLACE"},linux_fresh_boundary:{protocol_version:"2.1",marker_handoff_receipt_sha256:$h,linux_frozen_evidence_sha256:$b},windows_evidence:{raw_census:{path:$raw_path,sha256:$raw_sha},transport_upgrade:{path:$upgrade_path,sha256:$upgrade_sha},stderr_classification:{path:$classification_path,sha256:$classification_sha},legacy_disposition:{path:$disposition_path,sha256:$disposition_sha},legacy_isolation_complete:true,fresh_bridge_ready:false}}' >"$temp"
 publish_once "$temp" "$final_receipt"; temporary_files=(); validate_final_receipt
}
validate_final_receipt(){
 private_input final "$final_receipt" "$(sha256 "$final_receipt")" || return 1; strict_json "$final_receipt" || return 1
 jq -e --arg old "$old_operation" --arg new "$new_operation" --arg c "$new_coordinator" --arg plan "$(sha256 "$plan")" --arg i "$incident_sha" --arg t "$tombstone_sha" --arg cleanup "$(sha256 "$cleanup_proof")" --arg config "$(sha256 "$config_intent")" --arg h "$(sha256 "$handoff_receipt")" --arg b "$(sha256 "$frozen_evidence")" --arg rp "$windows_raw_census" --arg rs "$windows_raw_census_sha" --arg up "$transport_upgrade_path" --arg us "$transport_upgrade_sha" --arg cp "$stderr_classification_path" --arg cs "$stderr_classification_sha" --arg dp "$windows_disposition" --arg ds "$windows_disposition_sha" '
  keys==["linux_fresh_boundary","marker_generation","new_coordinator_instance_id","new_operation_id","old_incident","old_operation_id","retirement","runtime_config_relocation","schema_version","state","transition_plan_sha256","windows_evidence"] and
  .schema_version==1 and .state=="viewflow-post-vfdqa-linux-fresh-v21-bootstrap-boundary-ready" and .old_operation_id==$old and .new_operation_id==$new and .new_operation_id!=.old_operation_id and .new_coordinator_instance_id==$c and .marker_generation=="1" and .transition_plan_sha256==$plan and
  .old_incident=={incident_sha256:$i,invalid_authorization_tombstone_sha256:$t,old_authorization_role:"invalidity-proof-only"} and
  .retirement=={cleanup_proof_sha256:$cleanup,deskflow_stopped_before_viewflow:true,release_all_or_no_route_proven:true,zero_listeners_processes_sockets_vfqst002:true} and
  .runtime_config_relocation=={intent_sha256:$config,item_count:5,rename_method:"renameat2-RENAME_NOREPLACE"} and
  .linux_fresh_boundary=={protocol_version:"2.1",marker_handoff_receipt_sha256:$h,linux_frozen_evidence_sha256:$b} and
  .windows_evidence=={raw_census:{path:$rp,sha256:$rs},transport_upgrade:{path:$up,sha256:$us},stderr_classification:{path:$cp,sha256:$cs},legacy_disposition:{path:$dp,sha256:$ds},legacy_isolation_complete:true,fresh_bridge_ready:false}' "$final_receipt" >/dev/null || { die 'final receipt exact schema/cross-binding differs'; return 1; }
 validate_cleanup_proof || return 1; validate_handoff || return 1; validate_frozen || return 1; transients_zero || { die 'final receipt no longer matches zero boundary'; return 1; }
}
main(){
 validate_inputs; [[ $mode == validate-inputs-only ]] && { printf 'post-VFDQA incident/tombstone bridge inputs validated\n'; return; }
 local parent; parent=$(dirname -- "$bridge_root"); [[ -d $parent ]] || { [[ $parent == "$STATE_ROOT/post-vfdqa-bridges" ]] || die 'unsafe bridge parent'; mkdir -- "$parent"; chmod 0700 "$parent"; sync -f "$STATE_ROOT"; }; safe_dir bridge-parent "$parent"; [[ -d $bridge_root ]] || { mkdir -- "$bridge_root"; chmod 0700 "$bridge_root"; sync -f "$parent"; }; safe_dir bridge-root "$bridge_root"
 plan=$bridge_root/transition-plan.json; cleanup_proof=$bridge_root/retirement-cleanup.json; config_intent=$bridge_root/runtime-config-relocation-intent.json; backup_dir=$bridge_root/runtime-config-backups
 sealed_dir=$bridge_root/sealed-inputs; marker_snapshot=$sealed_dir/marker-candidate; prepare_snapshot=$sealed_dir/prepare-script; collector_snapshot=$sealed_dir/collector-script
 make_plan; ensure_cleanup; retire_transients; relocate_config; fresh_chain; publish_final
 printf 'fresh protocol-2.1 boundary ready: %s\n' "$final_receipt"
}
main
