#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

readonly STATE_ROOT=/home/wilf/.local/state/viewflow
readonly OLD_EOF_WRAPPER_SHA=4170bd4a552818636e75a42f6cb3cb13b49724dafc4b0b316afdfcd8d2fb39f3
readonly OLD_CHECKER_SHA=1dfb262ad6ac226d5530d083a9b78d18862dcceb1dbe6ab83bb09019018243b6
readonly OBSERVED_EXACT_WRAPPER_SHA=8e0e056b7f361436c8e87fa74b53310d1275bad996139eddf9035b572cc752d8
readonly OBSERVED_EXACT_CHECKER_SHA=2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2
readonly OLD_RAW_TRANSPORT=ssh-powershell-encodedcommand-raw-files-v1
readonly RAW_TRANSPORT=ssh-powershell-encodedcommand-exact-length-raw-files-v2

die(){ printf 'error: %s\n' "$*" >&2; exit 1; }
sha256(){ sha256sum -- "$1" | awk '{print $1}'; }

read -r -d '' POWERSHELL_WRAPPER <<'PS' || true
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
try {
  $lengthLine=[Console]::In.ReadLine()
  if($null -eq $lengthLine -or $lengthLine -notmatch '^[0-9]{1,8}$'){throw 'invalid stdin payload length'}
  $payloadLength=[int64]$lengthLine
  if($payloadLength -le 0 -or $payloadLength -gt 16777216){throw 'stdin payload length is out of range'}
  $builder=[Text.StringBuilder]::new()
  $buffer=New-Object char[] 8192
  $remaining=$payloadLength
  while($remaining -gt 0){
    $take=[Math]::Min([int64]$buffer.Length,$remaining)
    $read=[Console]::In.Read($buffer,0,[int]$take)
    if($read -le 0){throw 'short stdin payload'}
    [void]$builder.Append($buffer,0,$read)
    $remaining-=$read
  }
  $raw=$builder.ToString()
  if([Text.Encoding]::UTF8.GetByteCount($raw) -ne $payloadLength){throw 'stdin payload UTF-8 length differs'}
  $package=$raw|ConvertFrom-Json -ErrorAction Stop
  $strict=[Text.UTF8Encoding]::new($false,$true)
  $source=$strict.GetString([Convert]::FromBase64String([string]$package.probe_base64))
  $argumentsJson=$strict.GetString([Convert]::FromBase64String([string]$package.arguments_base64))
  $arguments=@{};$argumentsObject=$argumentsJson|ConvertFrom-Json -ErrorAction Stop
  $argumentsObject.psobject.Properties|ForEach-Object{$arguments[$_.Name]=[string]$_.Value}
  & ([ScriptBlock]::Create($source)) @arguments
  if(-not $?){exit 1}
} catch {
  [Console]::Error.WriteLine($_.Exception.ToString())
  exit 1
}
exit 0
PS
wrapper_sha=$(printf '%s' "$POWERSHELL_WRAPPER" | sha256sum | awk '{print $1}')
if [[ ${1:-} == --print-wrapper-sha256 ]]; then printf '%s\n' "$wrapper_sha"; exit 0; fi

manifest='' inventory='' incident='' tombstone='' old_op='' target='' bridge_root=''
raw_output='' disposition_output='' probe='' expected_probe='' expected_wrapper='' checker=''
expected_checker='' fixture_stdout='' fixture_stderr='' fixture_exit='' mode=''
while (($#)); do
  case $1 in
    --execute) [[ -z $mode ]] || die 'multiple modes'; mode=execute; shift ;;
    --resume) [[ -z $mode ]] || die 'multiple modes'; mode=resume; shift ;;
    --validate-inputs-only) [[ -z $mode ]] || die 'multiple modes'; mode=validate; shift ;;
    --manifest) manifest=$2; shift 2 ;;
    --windows-inventory) inventory=$2; shift 2 ;;
    --incident) incident=$2; shift 2 ;;
    --tombstone) tombstone=$2; shift 2 ;;
    --old-operation-id) old_op=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --bridge-root) bridge_root=$2; shift 2 ;;
    --raw-output) raw_output=$2; shift 2 ;;
    --disposition-output) disposition_output=$2; shift 2 ;;
    --probe) probe=$2; shift 2 ;;
    --expected-probe-sha256) expected_probe=$2; shift 2 ;;
    --expected-wrapper-sha256) expected_wrapper=$2; shift 2 ;;
    --checker) checker=$2; shift 2 ;;
    --expected-checker-sha256) expected_checker=$2; shift 2 ;;
    --fixture-stdout) fixture_stdout=$2; shift 2 ;;
    --fixture-stderr) fixture_stderr=$2; shift 2 ;;
    --fixture-exit-status) fixture_exit=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n $mode ]] || die 'one of --execute, --resume, or --validate-inputs-only is required'
[[ $old_op =~ ^[0-9a-f]{32}$ && $expected_probe =~ ^[0-9a-f]{64}$ &&
   $expected_wrapper =~ ^[0-9a-f]{64}$ && $expected_checker =~ ^[0-9a-f]{64}$ ]] ||
  die 'operation ID or expected SHA-256 is invalid'
[[ $wrapper_sha == "$expected_wrapper" ]] || die 'PowerShell wrapper SHA-256 differs'
[[ -f $probe && ! -L $probe && $(sha256 "$probe") == "$expected_probe" ]] || die 'probe identity differs'
[[ -f $checker && ! -L $checker && $(sha256 "$checker") == "$expected_checker" ]] || die 'checker identity differs'
[[ -f $manifest && ! -L $manifest && -f $inventory && ! -L $inventory &&
   -f $incident && ! -L $incident && -f $tombstone && ! -L $tombstone ]] || die 'evidence input is not a plain file'
[[ $(jq -r '.operation_id' "$manifest") == "$old_op" &&
   $(jq -r '.windows.ssh_target' "$manifest") == "$target" ]] || die 'manifest operation/target binding differs'
expected_raw=$bridge_root/evidence/windows-ssh-raw-census.json
expected_disposition=$bridge_root/evidence/windows-legacy-disposition.json
upgrade_output=$bridge_root/evidence/windows-legacy-census-transport-upgrade.v1.json
stderr_classification_output=$bridge_root/evidence/windows-legacy-census-stderr-classification.v1.json
[[ $bridge_root == "$STATE_ROOT/post-vfdqa-bridges/$old_op" ]] || die 'bridge root must use the fixed post-VFDQA namespace'
[[ $raw_output == "$expected_raw" && $disposition_output == "$expected_disposition" ]] || die 'output path is outside the fixed bridge evidence contract'
intent_output=$bridge_root/evidence/windows-legacy-census-capture-intent.json

python3 -I -E - "$STATE_ROOT" "$bridge_root" "$mode" <<'PY'
import os,stat,sys

state_root,root,mode=sys.argv[1:]
parent=os.path.join(state_root,'post-vfdqa-bridges')
evidence=os.path.join(root,'evidence')

def check_dir(path,label):
    st=os.lstat(path)
    if not (stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode) and
            stat.S_IMODE(st.st_mode)==0o700 and st.st_uid==os.getuid()):
        raise SystemExit(label+' metadata differs')

def sync_dir(path):
    fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

if not os.path.lexists(state_root):
    raise SystemExit('state root is absent')
check_dir(state_root,'state root')

if mode == 'validate':
    # Validation is deliberately read-only: absent bridge descendants remain
    # absent, while any existing component is checked before path use.
    for path,label in ((parent,'bridge parent'),(root,'bridge root'),
                       (evidence,'bridge evidence')):
        if os.path.lexists(path):
            check_dir(path,label)
else:
    # The exact chain is state_root/post-vfdqa-bridges/$old_op/evidence.  Do
    # not use recursive mkdir: every component is checked before continuing.
    for path,parent_path,label in ((parent,state_root,'bridge parent'),
                                   (root,parent,'bridge root'),
                                   (evidence,root,'bridge evidence')):
        if os.path.lexists(path):
            check_dir(path,label)
            continue
        os.mkdir(path,0o700)
        os.chmod(path,0o700)
        check_dir(path,label)
        sync_dir(parent_path)
PY

tmpdir=$(mktemp -d /tmp/viewflow-windows-raw-census.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT
stdout_raw=$tmpdir/stdout.raw; stderr_raw=$tmpdir/stderr.raw; parsed=$tmpdir/parsed.json
manifest_sha=$(sha256 "$manifest"); inventory_sha=$(sha256 "$inventory")
incident_sha=$(sha256 "$incident"); tombstone_sha=$(sha256 "$tombstone")
intent_candidate=$tmpdir/intent.json
jq -cnS --arg op "$old_op" --arg target "$target" --arg raw "$raw_output" --arg disposition "$disposition_output" \
  --arg manifest_path "$manifest" --arg manifest_sha "$manifest_sha" --arg inventory_path "$inventory" --arg inventory_sha "$inventory_sha" \
  --arg incident_path "$incident" --arg incident_sha "$incident_sha" --arg tombstone_path "$tombstone" --arg tombstone_sha "$tombstone_sha" \
  --arg probe_path "$probe" --arg probe_sha "$expected_probe" --arg wrapper_sha "$expected_wrapper" --arg checker_path "$checker" --arg checker_sha "$expected_checker" '
 {schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-capture-intent",old_operation_id:$op,ssh_target:$target,
  ssh_options:["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","WarnWeakCrypto=no","-o","ConnectTimeout=10","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=3"],
  outputs:{raw_census:$raw,legacy_disposition:$disposition},
  inputs:{reconciliation_manifest:{path:$manifest_path,sha256:$manifest_sha},prior_windows_inventory:{path:$inventory_path,sha256:$inventory_sha},incident:{path:$incident_path,sha256:$incident_sha},invalid_authz_tombstone:{path:$tombstone_path,sha256:$tombstone_sha}},
  producer:{probe:{path:$probe_path,sha256:$probe_sha},powershell_wrapper_sha256:$wrapper_sha,checker:{path:$checker_path,sha256:$checker_sha}}}
' >"$intent_candidate"; chmod 0600 "$intent_candidate"
old_intent_candidate=$tmpdir/old-intent.json
jq -cnS --slurpfile current "$intent_candidate" --arg old "$OLD_EOF_WRAPPER_SHA" --arg old_checker "$OLD_CHECKER_SHA" '
  $current[0] | .ssh_options=["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes"] |
  .producer.powershell_wrapper_sha256=$old | .producer.checker.sha256=$old_checker
' >"$old_intent_candidate"; chmod 0600 "$old_intent_candidate"

atomic_publish(){
 python3 -I -E - "$1" "$2" "$3" <<'PY'
import glob,hashlib,os,stat,sys
src,dst,policy=sys.argv[1:]; data=open(src,'rb').read(); parent=os.path.dirname(os.path.abspath(dst))
prefix=os.path.join(parent,'.'+os.path.basename(dst)+'.staging.'); stage=prefix+hashlib.sha256(data).hexdigest()
unexpected=[p for p in glob.glob(prefix+'*') if p!=stage]
if unexpected: raise SystemExit('unexpected publication staging file')
def fsync_parent():
 fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
 try: os.fsync(fd)
 finally: os.close(fd)
def meta(path,links):
 st=os.lstat(path)
 if not(stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and stat.S_IMODE(st.st_mode)==0o600 and st.st_uid==os.getuid() and st.st_nlink in links): raise SystemExit('publication metadata differs')
 return st
def read(path):
 fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  st=os.fstat(fd); chunks=[]
  while True:
   chunk=os.read(fd,1024*1024)
   if not chunk: break
   chunks.append(chunk)
  out=b''.join(chunks)
  if len(out)!=st.st_size: raise SystemExit('short publication read')
  return st,out
 finally: os.close(fd)
dst_exists=os.path.lexists(dst); stage_exists=os.path.lexists(stage)
if dst_exists:
 ds=meta(dst,{1,2}); _,actual=read(dst)
 if actual!=data: raise SystemExit('existing publication differs')
 if ds.st_nlink==2:
  if not stage_exists: raise SystemExit('unrecognized publication hard link')
  ss=meta(stage,{2})
  if (ss.st_dev,ss.st_ino)!=(ds.st_dev,ds.st_ino): raise SystemExit('publication staging inode differs')
  os.unlink(stage); fsync_parent(); stage_exists=False
 elif stage_exists: raise SystemExit('unexpected staging beside complete publication')
 meta(dst,{1})
 if policy=='create': raise SystemExit('publication already exists')
 raise SystemExit(0)
if stage_exists:
 meta(stage,{1}); _,actual=read(stage)
 if actual!=data or policy=='create': raise SystemExit('staging publication differs or requires resume')
else:
 fd=os.open(stage,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
 try:
  view=memoryview(data)
  while view:
   n=os.write(fd,view)
   if n<=0: raise OSError('short staging write')
   view=view[n:]
  os.fsync(fd)
 finally: os.close(fd)
 meta(stage,{1})
os.link(stage,dst,follow_symlinks=False); fsync_parent()
ss=meta(stage,{2}); ds=meta(dst,{2})
if (ss.st_dev,ss.st_ino)!=(ds.st_dev,ds.st_ino): raise SystemExit('publication inode differs')
_,actual=read(dst)
if actual!=data: raise SystemExit('publication readback differs')
os.unlink(stage); fsync_parent(); meta(dst,{1}); _,actual=read(dst)
if actual!=data: raise SystemExit('final publication differs')
PY
}

classify_stderr(){
 python3 -I -E - "$1" "$2" "$raw_output" "$transport_upgrade_sha256" "$expected_probe" "$expected_wrapper" "$expected_checker" <<'PY'
import base64,binascii,hashlib,json,os,stat,sys,xml.etree.ElementTree as ET
raw_path,candidate,raw_output,upgrade_sha,probe_sha,wrapper_sha,checker_sha=sys.argv[1:]
prefix=(b'** WARNING: connection is not using a post-quantum key exchange algorithm.\r\n'
        b'** This session may be vulnerable to "store now, decrypt later" attacks.\r\n'
        b'** The server may need to be upgraded. See https://openssh.com/pq.html\r\n'
        b'#< CLIXML\r\n')
def pairs(items):
 out={}
 for k,v in items:
  if k in out: raise ValueError('duplicate raw key')
  out[k]=v
 return out
data=open(raw_path,'rb').read(); raw=json.loads(data.decode('utf-8'),object_pairs_hook=pairs)
if raw.get('exit_status')!=0 or raw.get('transport_upgrade_receipt_sha256')!=upgrade_sha or upgrade_sha=='none': raise SystemExit('stderr classification raw binding differs')
def decode_stream(name):
 item=raw[name]; encoded=item['base64']; decoded=base64.b64decode(encoded,validate=True)
 if len(decoded)!=item['length'] or hashlib.sha256(decoded).hexdigest()!=item['sha256']: raise SystemExit(name+' bytes differ')
 return decoded
stdout=decode_stream('stdout'); stderr=decode_stream('stderr')
json.loads(stdout.decode('utf-8'),object_pairs_hook=pairs)
if not stderr.startswith(prefix): raise SystemExit('stderr prefix differs')
xml_bytes=stderr[len(prefix):]
xml_text=xml_bytes.decode('cp936','strict'); encoding='cp936'
root=ET.fromstring(xml_text)
if any(node.tag.rsplit('}',1)[-1]!='Obj' for node in root): raise SystemExit('stderr contains a non-Obj top-level record')
objs=[node for node in root.iter() if node.tag.rsplit('}',1)[-1]=='Obj']
if not objs or any(node.attrib.get('S')!='progress' for node in objs): raise SystemExit('stderr contains non-progress CLIXML record')
for node in root.iter():
 if (node.text and node.text.strip()) and node.tag.rsplit('}',1)[-1] not in ('AV','AI','I64','Nil','PI','PC','T','SR','SD','PR'):
  raise SystemExit('stderr contains unexpected CLIXML text')
json.dump({'schema_version':1,'state':'viewflow-post-vfdqa-windows-legacy-census-stderr-classification',
           'old_operation_id':raw['operation_id'],'reason':'POWERSHELL_PROGRESS_ONLY_WITH_OPENSSH_PQ_WARNING',
           'raw_census_path':raw_output,'raw_census_sha256':hashlib.sha256(data).hexdigest(),
           'transport_upgrade_receipt_sha256':upgrade_sha,'stderr_length':len(stderr),
           'stderr_sha256':hashlib.sha256(stderr).hexdigest(),'prefix_sha256':hashlib.sha256(prefix).hexdigest(),
           'clixml_sha256':hashlib.sha256(xml_bytes).hexdigest(),'clixml_encoding':encoding,
           'remote_probe_error':False,'transport_error':False,'accepted':True,
           'observed_probe_script_sha256':raw['probe_script_sha256'],'observed_wrapper_script_sha256':raw['wrapper_script_sha256'],'observed_transport':raw['transport'],
           'final_probe_sha256':probe_sha,'final_wrapper_sha256':wrapper_sha,'final_checker_sha256':checker_sha},
          open(candidate,'w',encoding='utf-8',newline='\n'),sort_keys=True,separators=(',',':')); open(candidate,'a',encoding='utf-8').write('\n')
PY
 chmod 0600 "$2"
 atomic_publish "$2" "$stderr_classification_output" resume
}

transport_upgrade_sha256=none
if [[ $mode == validate ]]; then
  python3 -I -E - "$intent_candidate" "$old_intent_candidate" "$intent_output" <<'PY'
import os,stat,sys
candidate,old_candidate,path=sys.argv[1:]; expected=open(candidate,'rb').read()
if os.path.lexists(path):
 st=os.lstat(path)
 if not(stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and stat.S_IMODE(st.st_mode)==0o600 and st.st_nlink==1): raise SystemExit('existing intent metadata differs')
 fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try: actual=os.read(fd,st.st_size+1)
 finally: os.close(fd)
 if actual!=expected:
  old=open(old_candidate,'rb').read()
  if actual!=old: raise SystemExit('existing intent differs')
PY
  printf 'post-VFDQA Windows legacy census inputs valid; no capture or publication\n'
  exit 0
fi
if [[ $mode == resume && -e $intent_output && ! -L $intent_output && $expected_wrapper != "$OLD_EOF_WRAPPER_SHA" ]] &&
   ! cmp -s -- "$intent_output" "$intent_candidate"; then
  python3 -I -E - "$old_intent_candidate" "$intent_output" "$raw_output" "$disposition_output" "$upgrade_output" <<'PY'
import glob,hashlib,os,stat,sys
candidate,intent,raw,disposition,upgrade=sys.argv[1:]
def read_regular(path):
 st=os.lstat(path)
 if not(stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and
         stat.S_IMODE(st.st_mode)==0o600 and st.st_uid==os.getuid() and st.st_nlink==1):
  raise SystemExit('transport upgrade file metadata differs')
 fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  data=b''
  while True:
   chunk=os.read(fd,1024*1024)
   if not chunk: break
   data+=chunk
  return data
 finally: os.close(fd)
if read_regular(intent)!=read_regular(candidate):
 raise SystemExit('existing intent is not the exact EOF-framing intent')
if not os.path.lexists(upgrade):
 for path in (raw,disposition):
  if os.path.lexists(path): raise SystemExit('transport upgrade requires absent raw/disposition')
 parent=os.path.dirname(raw)
 for prefix in ('.'+os.path.basename(raw)+'.staging.',
                '.'+os.path.basename(disposition)+'.staging.'):
  if glob.glob(os.path.join(parent,prefix+'*')):
   raise SystemExit('transport upgrade requires no evidence staging')
PY
  old_intent_sha=$(sha256 "$intent_output")
  if [[ -e $upgrade_output || -L $upgrade_output ]]; then
    python3 -I -E - "$upgrade_output" "$old_intent_sha" "$raw_output" "$disposition_output" "$expected_probe" <<'PY'
import hashlib,json,os,stat,sys
path,old_intent_sha,raw,disposition,probe=sys.argv[1:]
def pairs(items):
 out={}
 for key,value in items:
  if key in out: raise SystemExit('existing transport upgrade receipt has duplicate key')
  out[key]=value
 return out
def read_regular(path):
 st=os.lstat(path)
 if not(stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and stat.S_IMODE(st.st_mode)==0o600 and st.st_uid==os.getuid() and st.st_nlink==1): raise SystemExit('existing transport upgrade receipt metadata differs')
 fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  fst=os.fstat(fd)
  if (fst.st_dev,fst.st_ino)!=(st.st_dev,st.st_ino): raise SystemExit('existing transport upgrade receipt changed')
  chunks=[]
  while True:
   chunk=os.read(fd,1024*1024)
   if not chunk: break
   chunks.append(chunk)
  data=b''.join(chunks)
  if len(data)!=fst.st_size: raise SystemExit('existing transport upgrade receipt short read')
  return data
 finally: os.close(fd)
data=read_regular(path); value=json.loads(data.decode('utf-8'),object_pairs_hook=pairs)
expected={'schema_version':1,'state':'viewflow-post-vfdqa-windows-legacy-census-transport-upgrade','old_operation_id':'55d06e8f96aa4adc9010e53612979374','reason':'EOF_DEADLOCK_NO_RAW_PUBLISHED','old_wrapper_sha256':'4170bd4a552818636e75a42f6cb3cb13b49724dafc4b0b316afdfcd8d2fb39f3','new_wrapper_sha256':'8e0e056b7f361436c8e87fa74b53310d1275bad996139eddf9035b572cc752d8','old_checker_sha256':'1dfb262ad6ac226d5530d083a9b78d18862dcceb1dbe6ab83bb09019018243b6','new_checker_sha256':'2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2','old_transport':'ssh-powershell-encodedcommand-raw-files-v1','new_transport':'ssh-powershell-encodedcommand-exact-length-raw-files-v2'}
if set(value)!=set(expected)|{'old_intent','outputs','producer'}: raise SystemExit('existing transport upgrade receipt schema differs')
for key,value_expected in expected.items():
 if value.get(key)!=value_expected: raise SystemExit('existing transport upgrade receipt differs')
if set(value['old_intent'])!={'path','sha256'} or set(value['outputs'])!={'raw_census','legacy_disposition'} or set(value['producer'])!={'probe_sha256','checker_sha256'}: raise SystemExit('existing transport upgrade receipt schema differs')
if value.get('old_intent')!={'path':os.path.join(os.path.dirname(os.path.abspath(raw)),'windows-legacy-census-capture-intent.json'),'sha256':old_intent_sha} or value.get('outputs')!={'raw_census':raw,'legacy_disposition':disposition} or value.get('producer')!={'probe_sha256':probe,'checker_sha256':'2bf19eeb458227fe0214081c160c02593ce95ff8b344c3745e9bf0ad0e7529a2'}: raise SystemExit('existing transport upgrade receipt binding differs')
PY
    transport_upgrade_sha256=$(sha256 "$upgrade_output")
  else
  [[ $wrapper_sha == "$OBSERVED_EXACT_WRAPPER_SHA" &&
     $expected_checker == "$OBSERVED_EXACT_CHECKER_SHA" ]] ||
    die 'historical transport upgrade receipt is absent and cannot be recreated by a different producer'
  upgrade_candidate=$tmpdir/transport-upgrade.json
  jq -cnS --arg op "$old_op" --arg intent "$intent_output" --arg intent_sha "$old_intent_sha" \
    --arg old "$OLD_EOF_WRAPPER_SHA" --arg new "$OBSERVED_EXACT_WRAPPER_SHA" --arg old_checker "$OLD_CHECKER_SHA" --arg new_checker "$OBSERVED_EXACT_CHECKER_SHA" --arg old_transport "$OLD_RAW_TRANSPORT" --arg new_transport "$RAW_TRANSPORT" --arg probe "$expected_probe" \
    --arg checker "$OBSERVED_EXACT_CHECKER_SHA" --arg raw "$raw_output" --arg disposition "$disposition_output" \
    '{schema_version:1,state:"viewflow-post-vfdqa-windows-legacy-census-transport-upgrade",old_operation_id:$op,
      reason:"EOF_DEADLOCK_NO_RAW_PUBLISHED",old_intent:{path:$intent,sha256:$intent_sha},
      old_wrapper_sha256:$old,new_wrapper_sha256:$new,old_checker_sha256:$old_checker,
      new_checker_sha256:$new_checker,old_transport:$old_transport,new_transport:$new_transport,
      outputs:{raw_census:$raw,legacy_disposition:$disposition},producer:{probe_sha256:$probe,checker_sha256:$checker}}' \
    >"$upgrade_candidate"; chmod 0600 "$upgrade_candidate"
  atomic_publish "$upgrade_candidate" "$upgrade_output" resume
  transport_upgrade_sha256=$(sha256 "$upgrade_output")
  fi
else
  atomic_publish "$intent_candidate" "$intent_output" "$([[ $mode == execute ]] && printf create || printf resume)"
fi

resume_existing_raw(){
  python3 -I -E - "$raw_output" <<'PY'
import glob,os,stat,sys
dst=sys.argv[1]; parent=os.path.dirname(dst); prefix=os.path.join(parent,'.'+os.path.basename(dst)+'.staging.')
stages=glob.glob(prefix+'*')
def valid(path,links):
 st=os.lstat(path)
 if not(stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and stat.S_IMODE(st.st_mode)==0o600 and st.st_uid==os.getuid() and st.st_nlink in links): raise SystemExit('raw/staging metadata differs')
 return st
def sync():
 fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
 try: os.fsync(fd)
 finally: os.close(fd)
if os.path.lexists(dst):
 ds=valid(dst,{1,2})
 if ds.st_nlink==2:
  if len(stages)!=1: raise SystemExit('raw hardlink has no unique staging peer')
  ss=valid(stages[0],{2})
  if (ss.st_dev,ss.st_ino)!=(ds.st_dev,ds.st_ino): raise SystemExit('raw staging inode differs')
  os.unlink(stages[0]); sync()
 elif stages: raise SystemExit('unexpected staging beside complete raw census')
 valid(dst,{1}); print(dst); raise SystemExit(0)
if len(stages)>1: raise SystemExit('multiple raw staging files')
if len(stages)==1:
 valid(stages[0],{1}); print(stages[0]); raise SystemExit(0)
PY
}

if [[ $mode == execute ]]; then
  [[ ! -e $raw_output && ! -L $raw_output && ! -e $disposition_output && ! -L $disposition_output ]] || die 'execute requires absent raw and disposition outputs'
  compgen -G "$(dirname "$raw_output")/.$(basename "$raw_output").staging.*" >/dev/null && die 'execute refuses existing raw staging'
else
  existing=$(resume_existing_raw)
    if [[ -n $existing ]]; then
      if [[ $existing != "$raw_output" ]]; then
        atomic_publish "$existing" "$raw_output" resume
        existing=$raw_output
      fi
    if [[ $(jq -r '.stderr.length' "$existing") =~ ^[1-9][0-9]*$ ]] &&
       [[ ! -e $disposition_output && ! -L $disposition_output ]]; then
      transport_upgrade_sha256=$(jq -er '.transport_upgrade_receipt_sha256' "$existing")
      classify_stderr "$existing" "$tmpdir/stderr-classification.json"
    fi
    "$checker" --validate-only --raw-census "$existing" --manifest "$manifest" --windows-inventory "$inventory" \
      --incident "$incident" --tombstone "$tombstone" --old-operation-id "$old_op" \
      --expected-probe-sha256 "$expected_probe" --expected-wrapper-sha256 "$expected_wrapper"
    "$checker" --raw-census "$raw_output" --manifest "$manifest" --windows-inventory "$inventory" \
      --incident "$incident" --tombstone "$tombstone" --output "$disposition_output" \
      --old-operation-id "$old_op" --expected-probe-sha256 "$expected_probe" --expected-wrapper-sha256 "$expected_wrapper"
    printf 'post-VFDQA Windows legacy census resumed without SSH\n'
    exit 0
  fi
  [[ ! -e $disposition_output && ! -L $disposition_output ]] || die 'disposition exists without raw census'
fi

fixture=false
if [[ -n $fixture_stdout || -n $fixture_stderr || -n $fixture_exit ]]; then
  [[ ${VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE:-} == 1 && -f $fixture_stdout && ! -L $fixture_stdout &&
     -f $fixture_stderr && ! -L $fixture_stderr && $fixture_exit =~ ^[0-9]+$ ]] || die 'unsafe fixture capture request'
  cp -- "$fixture_stdout" "$stdout_raw"; cp -- "$fixture_stderr" "$stderr_raw"; exit_status=$fixture_exit; fixture=true
else
  operation_root=$(jq -r '.windows.operation_root' "$manifest")
  arguments=$(jq -cn --arg op "$old_op" --arg root "$operation_root" --arg manifest "$manifest_sha" \
    --arg incident "$incident_sha" --arg tombstone "$tombstone_sha" --arg inventory "$inventory_sha" \
    '{OperationId:$op,OperationRoot:$root,ManifestSha256:$manifest,IncidentSha256:$incident,TombstoneSha256:$tombstone,WindowsInventorySha256:$inventory}')
  package=$(jq -cn --arg probe "$(base64 -w0 "$probe")" --arg arguments "$(printf '%s' "$arguments" | base64 -w0)" \
    '{probe_base64:$probe,arguments_base64:$arguments}')
  encoded_wrapper=$(printf '%s' "$POWERSHELL_WRAPPER" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  set +e
  package_length=$(printf '%s' "$package" | wc -c | awk '{print $1}')
  printf '%s\n%s' "$package_length" "$package" | timeout --foreground --signal=TERM --kill-after=5s 120 \
    ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o WarnWeakCrypto=no -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$target" \
    powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -EncodedCommand "$encoded_wrapper" >"$stdout_raw" 2>"$stderr_raw"
  exit_status=$?
  set -e
fi
chmod 0600 "$stdout_raw" "$stderr_raw"

# Reject invalid UTF-8, trailing JSON, duplicate keys, and non-object stdout
# before jq is allowed to construct parsed_census.
python3 -I -E - "$stdout_raw" "$parsed" <<'PY'
import json,sys
def pairs(items):
 out={}
 for key,value in items:
  if key in out: raise ValueError('duplicate object key: '+key)
  out[key]=value
 return out
data=open(sys.argv[1],'rb').read(); text=data.decode('utf-8','strict')
value=json.loads(text,object_pairs_hook=pairs)
if not isinstance(value,dict): raise ValueError('probe stdout must be one JSON object')
with open(sys.argv[2],'x',encoding='utf-8',newline='\n') as out:
 json.dump(value,out,separators=(',',':'),sort_keys=True); out.write('\n')
PY
canonical=$tmpdir/canonical.json
jq -ceS . "$parsed" >"$canonical"
canonical_sha=$(sha256 "$canonical")
observed=$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')
raw_candidate=$tmpdir/raw.json
  jq -cnS --arg op "$old_op" --arg observed "$observed" --arg target "$target" --arg upgrade "$transport_upgrade_sha256" --arg transport "$RAW_TRANSPORT" \
  --arg probe "$expected_probe" --arg wrapper "$expected_wrapper" --argjson exit "$exit_status" \
  --arg stdout_b64 "$(base64 -w0 "$stdout_raw")" --arg stdout_sha "$(sha256 "$stdout_raw")" --argjson stdout_len "$(stat -c %s "$stdout_raw")" \
  --arg stderr_b64 "$(base64 -w0 "$stderr_raw")" --arg stderr_sha "$(sha256 "$stderr_raw")" --argjson stderr_len "$(stat -c %s "$stderr_raw")" \
  --slurpfile parsed "$parsed" --arg canonical "$canonical_sha" --arg manifest "$manifest_sha" \
  --arg incident "$incident_sha" --arg tombstone "$tombstone_sha" --arg inventory "$inventory_sha" '
  {schema_version:1,state:"viewflow-windows-ssh-raw-census",operation_id:$op,observed_at_utc:$observed,
   transport:$transport,ssh_target:$target,
   ssh_options:["-F","/dev/null","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","WarnWeakCrypto=no","-o","ConnectTimeout=10","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=3"],
   probe_script_sha256:$probe,wrapper_script_sha256:$wrapper,transport_upgrade_receipt_sha256:$upgrade,exit_status:$exit,
   stdout:{base64:$stdout_b64,length:$stdout_len,sha256:$stdout_sha},
   stderr:{base64:$stderr_b64,length:$stderr_len,sha256:$stderr_sha},
   parsed_census:{canonical_jq_cS_sha256:$canonical,document:$parsed[0]},
   incident_boundary:{reconciliation_manifest_sha256:$manifest,incident_sha256:$incident,
     invalid_authz_tombstone_sha256:$tombstone,prior_windows_inventory_sha256:$inventory}}
' >"$raw_candidate"
chmod 0600 "$raw_candidate"

atomic_publish "$raw_candidate" "$raw_output" "$([[ $mode == execute ]] && printf create || printf resume)"
"$checker" --raw-census "$raw_output" --manifest "$manifest" --windows-inventory "$inventory" \
  --incident "$incident" --tombstone "$tombstone" --output "$disposition_output" \
  --old-operation-id "$old_op" --expected-probe-sha256 "$expected_probe" \
  --expected-wrapper-sha256 "$expected_wrapper"
[[ $fixture == true ]] || printf 'lossless Windows SSH census and legacy disposition published\n'
