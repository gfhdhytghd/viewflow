#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077
exec python3 - "$@" <<'PY'
import ctypes,hashlib,json,os,re,secrets,shutil,stat,sys,time
from pathlib import Path
S=Path("/home/wilf/.local/state/viewflow"); SEED=S/"candidates/v21-normal-seed-v3-20260904T123027Z-oZ1vdq"; CANDS=S/"candidates"; DEPS=S/"deployments"
SRC="00000000-0000-0000-0000-000000000101"; TGT="00000000-0000-0000-0000-000000000002"
SEED_MANIFEST_SHA="07bbb719e07ae03a9591a8dc0bf2603bf8a9538ea42774c31bd050bca2004be0"
FILES={"windows-viewflowd.exe":("87631e877811377f018d65dc5ca2b1d6b68e2b268d7d15b8d0646aac3d9f5b04",0o700),"windows-native-provenance.json":("fc4cb5cff71ad859f113cd2ad21cfff90217401772cba08f21c0394735bac17d",0o600),"windows-source.manifest.sha256":("7ecccb607a166c847aa1293905f8fd14909803734751b6ca71549470fc6f95e2",0o600),"windows-source.tar.gz":("da3014217499fc7deb5eac1fa07fb85e9cbfcecb0bff9fd14df54530d3367131",0o600),"windows-source.tar.gz.sha256":("aea8ec8fe6232e0883b97e58cd027e735b1e2a39b2c3761b5a3fcadbff7139ee",0o600)}
TOP="schema_version kind operation_id coordinator_instance_id protocol_version sidecar_protocol_version marker_generation recovery_marker_generation source_display_id target_device_id fresh_boundary coordinator linux_rust linux_deskflow windows".split()
NEST={"fresh_boundary":"root deployment_publish_receipt_sha256 marker_handoff_sha256 linux_frozen_sha256 deployment_marker deployment_marker_sha256".split(),"coordinator":"entrypoint entrypoint_sha256 source_provenance source_provenance_sha256".split(),"linux_rust":"provenance provenance_sha256 viewflowd viewflowd_sha256 deployment_marker deployment_marker_sha256 reviewed_build_manifest reviewed_build_manifest_sha256 unit unit_sha256 deskflow_dropin deskflow_dropin_sha256".split(),"linux_deskflow":"provenance provenance_sha256 deskflow deskflow_sha256 deskflow_core deskflow_core_sha256".split(),"windows":"viewflowd viewflowd_sha256 native_provenance native_provenance_sha256 wrapper wrapper_sha256 launcher launcher_sha256 installer installer_sha256 rollback_sha256 old_task_xml_sha256 new_task_xml_override session_1_user_sid".split()}
PK="coordinator_instance_id created_at_unix_ms created_at_utc marker_generation marker_path marker_sha256 operation_id protocol_version schema_version source_display_id state target_device_id".split()
HK="schema_version state protocol_version operation_id source_display_id target_device_id coordinator_instance_id marker_generation marker_cli_path marker_cli_sha256 deployment_marker_path deployment_marker_sha256 deployment_publish_receipt_path deployment_publish_receipt_sha256 deskflow_unit deskflow_unit_active_state deskflow_unit_main_pid deskflow_executable_path deskflow_executable_sha256 deskflow_exact_process_count deskflow_core_executable_path deskflow_core_executable_sha256 deskflow_core_exact_process_count deskflow_tcp_port deskflow_tcp_listener_count runtime_marker_path runtime_marker_present observed_at_utc".split()
FK="schema_version state operation_id daemon journal pre_stop post_stop completed_at_unix_ms".split()
TERM_KEYS="schema_version state operation_id coordinator_instance_id replacement_ordinal created_at_unix_ms created_at_utc operation_root candidate_root old_candidate fresh_boundary authorized_seed pre_retirement".split()
OLD_KEYS="canonical_path archive_path manifest_sha256 tree_sha256 files".split()
BOUNDARY_KEYS="deployment_publish_path deployment_publish_sha256 marker_handoff_path marker_handoff_sha256 linux_frozen_path linux_frozen_sha256 deployment_marker_path deployment_marker_sha256".split()
SEED_KEYS="root candidate_manifest_path candidate_manifest_sha256".split()
PRE_KEYS="coordinator_state_path coordinator_state_absent standard_normal_outputs_absent".split()
COMMIT_KEYS="schema_version state operation_id coordinator_instance_id replacement_ordinal created_at_unix_ms created_at_utc operation_root candidate_root candidate_manifest_path candidate_manifest_sha256 candidate_tree_sha256 retirement_terminal_path retirement_terminal_sha256 old_candidate_archive_path old_candidate_manifest_sha256 authorized_seed_manifest_sha256 fresh_boundary".split()
def die(m): raise SystemExit("error: "+m)
def reg(p,mode=None):
 try: x=os.lstat(p)
 except OSError as e: die("missing path: "+str(p))
 if not stat.S_ISREG(x.st_mode) or stat.S_ISLNK(x.st_mode) or x.st_uid!=os.getuid() or x.st_nlink!=1: die("unsafe path: "+str(p))
 if mode is not None and stat.S_IMODE(x.st_mode)!=mode: die("unexpected mode: "+str(p))
 return x
def od(p,mode=0o700):
 try: x=os.lstat(p)
 except OSError: die("missing directory: "+str(p))
 if not stat.S_ISDIR(x.st_mode) or stat.S_ISLNK(x.st_mode) or x.st_uid!=os.getuid() or x.st_nlink!=1 or stat.S_IMODE(x.st_mode)!=mode: die("unsafe directory: "+str(p))
def sha(p):
 a=reg(p); h=hashlib.sha256()
 with open(p,"rb",buffering=0) as f:
  for b in iter(lambda:f.read(1048576),b""): h.update(b)
 z=reg(p)
 if (a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns)!=(z.st_dev,z.st_ino,z.st_size,z.st_mtime_ns): die("input changed while hashing")
 return h.hexdigest()
def _reject_duplicate_pairs(pairs):
 out={}
 for key,value in pairs:
  if key in out: raise ValueError("duplicate JSON object key")
  out[key]=value
 return out
def _reject_float(value): raise ValueError("floating-point JSON numbers are forbidden")
def _reject_constant(value): raise ValueError("NaN/Infinity JSON numbers are forbidden")
def strict_json_object(p, label):
 reg(p,0o600)
 try:
  with open(p,"rb",buffering=0) as f: raw=f.read()
  text=raw.decode("utf-8","strict")
  decoder=json.JSONDecoder(object_pairs_hook=_reject_duplicate_pairs,
                           parse_float=_reject_float,
                           parse_constant=_reject_constant)
  start=0
  while start<len(text) and text[start] in " \t\r\n": start+=1
  value,end=decoder.raw_decode(text,start)
  tail=end
  while tail<len(text) and text[tail] in " \t\r\n": tail+=1
  if tail!=len(text): raise ValueError("trailing JSON data")
  if not isinstance(value,dict): raise ValueError("root must be one JSON object")
 except Exception as e: die("invalid "+label+": "+str(e))
 return value
def jfile(p,keys,label):
 x=strict_json_object(p,label)
 if list(x)!=keys: die(label+" has unknown/reordered keys")
 return x
def hx(x,n,label):
 if not isinstance(x,str) or len(x)!=n or any(c not in "0123456789abcdef" for c in x): die(label+" must be lowercase hex")
def uid(x,label):
 if not isinstance(x,str) or len(x)!=36 or [x[8],x[13],x[18],x[23]]!=["-"]*4: die(label+" must be canonical lowercase UUID")
 hx(x.replace("-",""),32,label)
def bind(x,op,coord,label):
 if x["schema_version"]!=1 or x["protocol_version"]!="2.1" or x["operation_id"]!=op or x["coordinator_instance_id"]!=coord or x["marker_generation"]!="1" or x["source_display_id"]!=SRC or x["target_device_id"]!=TGT: die(label+" boundary mismatch")
def timestamp(x,label):
 if not isinstance(x,int) or isinstance(x,bool) or x<0 or not isinstance(label,str): die(label+" timestamp must be integer milliseconds")
def utc_millis(x,label):
 if not isinstance(x,str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",x): die(label+" timestamp must be canonical UTC milliseconds")
def nr(a,b):
 l=ctypes.CDLL(None,use_errno=True); f=l.renameat2; f.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
 if f(-100,os.fsencode(a),-100,os.fsencode(b),1): e=ctypes.get_errno(); raise OSError(e,os.strerror(e))
def copy(src,dst,expected,mode):
 reg(src,mode)
 if sha(src)!=expected: die("seed hash mismatch")
 fd=os.open(dst,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode)
 try:
  with open(src,"rb") as i,os.fdopen(fd,"wb",closefd=False) as o:
   for b in iter(lambda:i.read(1048576),b""): o.write(b)
   o.flush(); os.fsync(fd)
 finally: os.close(fd)
 if sha(dst)!=expected: die("copy hash mismatch")
def tree(root, files):
 rows=[]
 for item in files:
  if not isinstance(item,dict) or list(item)!=["name","mode","size_bytes","sha256"]: die("retirement file schema mismatch")
  name=item["name"]
  if not isinstance(name,str) or not name or "/" in name or name in (".",".."): die("unsafe retirement file name")
  path=Path(root)/name; st=reg(path)
  if item["mode"] != format(stat.S_IMODE(st.st_mode),"04o") or item["size_bytes"] != st.st_size or item["sha256"] != sha(path): die("retired tree file mismatch: "+name)
  hx(item["sha256"],64,"retired file hash")
  rows.append((name,item["mode"],str(item["size_bytes"]),item["sha256"]))
 if [x[0] for x in sorted(rows)] != [x[0] for x in rows]: die("retirement files are not sorted")
 names={x[0] for x in rows}
 actual=set()
 for entry in os.scandir(root):
  if entry.is_symlink() or not stat.S_ISREG(entry.stat(follow_symlinks=False).st_mode): die("retirement tree contains symlink/non-regular entry")
  actual.add(entry.name)
 if actual != names: die("retirement tree contains unexpected files")
 payload="".join("%s\0%s\0%s\0%s\n"%x for x in rows).encode()
 return hashlib.sha256(payload).hexdigest()
def validate_tree(root, files, expected_tree):
 od(root)
 if tree(root,files)!=expected_tree: die("retirement tree hash mismatch")
def validate_term(path, expected_sha, op, coord, boundary, seed_sha, target):
 hx(expected_sha,64,"retirement terminal sha256")
 if sha(path)!=expected_sha: die("retirement terminal hash mismatch")
 t=jfile(path,TERM_KEYS,"retirement terminal")
 if t["schema_version"]!=1 or t["state"]!="viewflow-normal-v21-candidate-retired" or t["operation_id"]!=op or t["coordinator_instance_id"]!=coord or t["replacement_ordinal"]!=1: die("retirement terminal identity mismatch")
 timestamp(t["created_at_unix_ms"],"retirement terminal"); utc_millis(t["created_at_utc"],"retirement terminal")
 if t["operation_root"]!=str(Path(v["fresh"])) or t["candidate_root"]!=str(target): die("retirement terminal root mismatch")
 if list(t["old_candidate"])!=OLD_KEYS: die("retirement old-candidate schema mismatch")
 old=t["old_candidate"]; hx(old["manifest_sha256"],64,"old candidate manifest sha256"); hx(old["tree_sha256"],64,"old candidate tree sha256")
 validate_tree(old["archive_path"],old["files"],old["tree_sha256"])
 if old["canonical_path"]!=str(target) or (not target.exists() and os.path.lexists(old["canonical_path"])): die("retired canonical candidate is not absent")
 manifest_file=next((x for x in old["files"] if x["name"]=="candidate-manifest.json"),None)
 if manifest_file is None or manifest_file["sha256"]!=old["manifest_sha256"]: die("retired manifest hash is not bound to archive")
 if list(t["fresh_boundary"])!=BOUNDARY_KEYS or t["fresh_boundary"]!=boundary: die("retirement fresh boundary mismatch")
 if list(t["authorized_seed"])!=SEED_KEYS or t["authorized_seed"]!={"root":str(SEED),"candidate_manifest_path":str(SEED/"candidate-manifest.json"),"candidate_manifest_sha256":seed_sha}: die("authorized seed mismatch")
 if list(t["pre_retirement"])!=PRE_KEYS or t["pre_retirement"]["coordinator_state_absent"] is not True or t["pre_retirement"]["standard_normal_outputs_absent"] is not True: die("pre-retirement absence proof mismatch")
 return t
def write_json_noreplace(path, obj):
 data=(json.dumps(obj,separators=(",",":"),ensure_ascii=True)+"\n").encode(); stage=Path(str(path)+".staging-"+str(os.getpid())+"-"+secrets.token_hex(8))
 fd=os.open(stage,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 try:
  pos=0
  while pos<len(data):
   n=os.write(fd,data[pos:]);
   if n<=0: die("short commit receipt write")
   pos+=n
  os.fsync(fd)
 finally: os.close(fd)
 try: nr(stage,path)
 except BaseException:
  if stage.exists(): stage.unlink()
  raise
 parent=os.open(Path(path).parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);os.fsync(parent);os.close(parent)
 return hashlib.sha256(data).hexdigest()
def now_stamp():
 ms=time.time_ns()//1000000
 utc=time.strftime("%Y-%m-%dT%H:%M:%S",time.gmtime(ms//1000))+".%03dZ"%(ms%1000)
 return ms,utc
def parse(a):
 d={}; check=False; resume=False; names={"--operation-id":"op","--coordinator-uuid":"coord","--fresh-root":"fresh","--handoff":"handoff","--frozen":"frozen","--publish":"publish","--candidate-retirement-terminal":"term","--candidate-retirement-terminal-sha256":"term_sha"}; i=0
 while i<len(a):
  if a[i] in ("-h","--help"): print("Usage: $0 --operation-id HEX32 --coordinator-uuid UUID --fresh-root DIR --handoff FILE --frozen FILE --publish FILE --candidate-retirement-terminal TERM --candidate-retirement-terminal-sha256 SHA [--check-only|--resume]"); raise SystemExit
  if a[i]=="--check-only": check=True;i+=1;continue
  if a[i]=="--resume": resume=True;i+=1;continue
  if a[i] not in names or i+1==len(a): die("unknown/incomplete option: "+a[i])
  d[names[a[i]]]=a[i+1];i+=2
 if any(k not in d for k in ("op","coord","fresh","handoff","frozen","publish","term","term_sha")): die("all boundary and retirement arguments required")
 d["check"]=check;d["resume"]=resume;return d
v=parse(sys.argv[1:]); op=v["op"]; coord=v["coord"]; hx(op,32,"operation id"); uid(coord,"coordinator uuid"); hx(v["term_sha"],64,"retirement terminal sha256")
for x in (v["fresh"],v["handoff"],v["frozen"],v["publish"],v["term"]):
 if not os.path.isabs(x): die("all paths must be absolute")
fresh,handoff,frozen,publish,term=map(Path,(v["fresh"],v["handoff"],v["frozen"],v["publish"],v["term"])); od(DEPS);od(CANDS,0o700);od(fresh); reg(term,0o600)
if fresh.resolve()!=fresh or fresh.name!=op or fresh.parent!=DEPS: die("fresh root identity mismatch")
if any(x.parent!=fresh for x in (handoff,frozen,publish)): die("inputs must be direct fresh-root leaves")
p=jfile(publish,PK,"publish"); h=jfile(handoff,HK,"handoff"); f=jfile(frozen,FK,"frozen")
bind(p,op,coord,"publish");bind(h,op,coord,"handoff")
if p["state"]!="deployment-quarantine-published" or h["state"]!="viewflow-v13-marker-handoff-prepared" or f["schema_version"]!=1 or f["state"]!="viewflow-v13-bootstrap-frozen" or f["operation_id"]!=op: die("fresh input state mismatch")
if h["deployment_publish_receipt_path"]!=str(publish) or h["deployment_publish_receipt_sha256"]!=sha(publish): die("publish receipt binding mismatch")
if h["deployment_marker_path"]!=p["marker_path"] or h["deployment_marker_sha256"]!=p["marker_sha256"]: die("marker binding mismatch")
marker=Path(h["deployment_marker_path"])
if not marker.is_absolute() or sha(marker)!=p["marker_sha256"]: die("deployment marker missing/hash mismatch")
hx(p["marker_sha256"],64,"marker hash")
if h["runtime_marker_present"] is not False or h["deskflow_unit_active_state"]!="inactive" or h["deskflow_unit_main_pid"]!=0 or h["deskflow_exact_process_count"]!=0 or h["deskflow_core_exact_process_count"]!=0 or h["deskflow_tcp_listener_count"]!=0: die("fresh boundary not quiesced")
if sha(SEED/"candidate-manifest.json")!=SEED_MANIFEST_SHA: die("seed manifest hash mismatch")
seed=strict_json_object(SEED/"candidate-manifest.json","seed manifest")
if list(seed)!=TOP or any(list(seed[k])!=NEST[k] for k in NEST): die("seed manifest unknown/reordered keys")
if seed["schema_version"]!=1 or seed["kind"]!="viewflow-v21-cross-host-candidate-set" or seed["protocol_version"]!="2.1" or seed["sidecar_protocol_version"]!=3: die("seed manifest version mismatch")
boundary={"deployment_publish_path":str(publish),"deployment_publish_sha256":sha(publish),"marker_handoff_path":str(handoff),"marker_handoff_sha256":sha(handoff),"linux_frozen_path":str(frozen),"linux_frozen_sha256":sha(frozen),"deployment_marker_path":str(marker),"deployment_marker_sha256":p["marker_sha256"]}
manifest_boundary={"root":str(fresh),"deployment_publish_receipt_sha256":boundary["deployment_publish_sha256"],"marker_handoff_sha256":boundary["marker_handoff_sha256"],"linux_frozen_sha256":boundary["linux_frozen_sha256"],"deployment_marker":str(marker),"deployment_marker_sha256":p["marker_sha256"]}
target=CANDS/("v21-operation-"+op)
if term!=fresh/"candidate-retirement-terminal.json": die("retirement terminal path is not canonical")
terminal=validate_term(term,v["term_sha"],op,coord,boundary,SEED_MANIFEST_SHA,target)
commit= fresh/"candidate-replacement-commit.json"
def candidate_rows(root):
 rows=[]
 for n,(expected,mode) in FILES.items(): rows.append({"name":n,"mode":format(mode,"04o"),"size_bytes":os.stat(Path(root)/n).st_size,"sha256":expected})
 m=Path(root)/"candidate-manifest.json"; rows.append({"name":"candidate-manifest.json","mode":"0600","size_bytes":os.stat(m).st_size,"sha256":sha(m)})
 return sorted(rows,key=lambda x:x["name"])
def check_candidate(root, replacement, schema2=True):
 od(root)
 expected_keys=(TOP[:11]+["candidate_replacement"]+TOP[11:]) if schema2 else TOP
 m=jfile(Path(root)/"candidate-manifest.json",expected_keys,"candidate manifest")
 if m["schema_version"]!=(2 if schema2 else 1): die("candidate manifest schema mismatch")
 if schema2:
  if list(m["candidate_replacement"])!=["retirement_terminal_path","retirement_terminal_sha256","old_candidate_manifest_sha256","replacement_ordinal","authorized_seed_manifest_sha256"] or m["candidate_replacement"]!=replacement: die("candidate replacement mismatch")
  if m["fresh_boundary"]!=manifest_boundary: die("candidate fresh boundary mismatch")
 rows=candidate_rows(root)
 for row in rows[:-1]:
  if sha(Path(root)/row["name"])!=row["sha256"]: die("candidate artifact mismatch: "+row["name"])
 return sha(Path(root)/"candidate-manifest.json"),tree(root,rows)
replacement={"retirement_terminal_path":str(term),"retirement_terminal_sha256":v["term_sha"],"old_candidate_manifest_sha256":terminal["old_candidate"]["manifest_sha256"],"replacement_ordinal":1,"authorized_seed_manifest_sha256":SEED_MANIFEST_SHA}
if target.exists() or target.is_symlink():
 if not v["resume"]: die("operation candidate exists; use --resume for deterministic recovery")
 manifest_sha,candidate_tree_sha=check_candidate(target,replacement)
 if commit.exists() or commit.is_symlink():
  c=jfile(commit,COMMIT_KEYS,"candidate replacement commit")
  timestamp(c["created_at_unix_ms"],"candidate replacement commit"); utc_millis(c["created_at_utc"],"candidate replacement commit")
  expected={"schema_version":1,"state":"viewflow-normal-v21-candidate-replacement-committed","operation_id":op,"coordinator_instance_id":coord,"replacement_ordinal":1,"operation_root":str(fresh),"candidate_root":str(target),"candidate_manifest_path":str(target/"candidate-manifest.json"),"candidate_manifest_sha256":manifest_sha,"candidate_tree_sha256":candidate_tree_sha,"retirement_terminal_path":str(term),"retirement_terminal_sha256":v["term_sha"],"old_candidate_archive_path":terminal["old_candidate"]["archive_path"],"old_candidate_manifest_sha256":terminal["old_candidate"]["manifest_sha256"],"authorized_seed_manifest_sha256":SEED_MANIFEST_SHA,"fresh_boundary":boundary}
  if any(c.get(k)!=x for k,x in expected.items()): die("candidate replacement commit replay mismatch")
  print("candidate replacement commit replayed: "+str(commit));print("candidate manifest sha256: "+manifest_sha);raise SystemExit(0)
 if v["check"]: print("candidate replacement resume checks passed");raise SystemExit(0)
 commit_ms,commit_utc=now_stamp(); commit_obj={"schema_version":1,"state":"viewflow-normal-v21-candidate-replacement-committed","operation_id":op,"coordinator_instance_id":coord,"replacement_ordinal":1,"created_at_unix_ms":commit_ms,"created_at_utc":commit_utc,"operation_root":str(fresh),"candidate_root":str(target),"candidate_manifest_path":str(target/"candidate-manifest.json"),"candidate_manifest_sha256":manifest_sha,"candidate_tree_sha256":candidate_tree_sha,"retirement_terminal_path":str(term),"retirement_terminal_sha256":v["term_sha"],"old_candidate_archive_path":terminal["old_candidate"]["archive_path"],"old_candidate_manifest_sha256":terminal["old_candidate"]["manifest_sha256"],"authorized_seed_manifest_sha256":SEED_MANIFEST_SHA,"fresh_boundary":boundary}
 write_json_noreplace(commit,commit_obj);print("candidate replacement committed: "+str(commit));print("candidate manifest sha256: "+manifest_sha);raise SystemExit(0)
if v["resume"]: die("--resume requires an existing candidate")
if commit.exists() or commit.is_symlink(): die("commit receipt exists without candidate")
stage=CANDS/(".v21-operation-"+op+".staging-"+str(os.getpid())+"-"+secrets.token_hex(8))
try:
 os.mkdir(stage,0o700)
 for n,(x,m) in FILES.items(): copy(SEED/n,stage/n,x,m)
 out=json.loads(json.dumps(seed)); out["operation_id"]=op;out["coordinator_instance_id"]=coord;out["schema_version"]=2
 out["fresh_boundary"]=manifest_boundary
 replacement_obj={"retirement_terminal_path":str(term),"retirement_terminal_sha256":v["term_sha"],"old_candidate_manifest_sha256":terminal["old_candidate"]["manifest_sha256"],"replacement_ordinal":1,"authorized_seed_manifest_sha256":SEED_MANIFEST_SHA}
 ordered={}
 for key in TOP:
  ordered[key]=out[key]
  if key=="fresh_boundary": ordered["candidate_replacement"]=replacement_obj
 out=ordered
 out["windows"]["viewflowd"]=str(target/"windows-viewflowd.exe");out["windows"]["native_provenance"]=str(target/"windows-native-provenance.json")
 data=(json.dumps(out,indent=2,ensure_ascii=True)+"\n").encode(); fd=os.open(stage/"candidate-manifest.json",os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 try:
  pos=0
  while pos<len(data):
   n=os.write(fd,data[pos:])
   if n<=0: die("short manifest write")
   pos+=n
  os.fsync(fd)
 finally: os.close(fd)
 msha=hashlib.sha256(data).hexdigest()
 if v["check"]: shutil.rmtree(stage); print("candidate replacement checks passed");raise SystemExit(0)
 else: nr(stage,target); dfd=os.open(CANDS,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);os.fsync(dfd);os.close(dfd)
 manifest_sha,candidate_tree_sha=check_candidate(target,replacement_obj)
 commit_ms,commit_utc=now_stamp(); commit_obj={"schema_version":1,"state":"viewflow-normal-v21-candidate-replacement-committed","operation_id":op,"coordinator_instance_id":coord,"replacement_ordinal":1,"created_at_unix_ms":commit_ms,"created_at_utc":commit_utc,"operation_root":str(fresh),"candidate_root":str(target),"candidate_manifest_path":str(target/"candidate-manifest.json"),"candidate_manifest_sha256":manifest_sha,"candidate_tree_sha256":candidate_tree_sha,"retirement_terminal_path":str(term),"retirement_terminal_sha256":v["term_sha"],"old_candidate_archive_path":terminal["old_candidate"]["archive_path"],"old_candidate_manifest_sha256":terminal["old_candidate"]["manifest_sha256"],"authorized_seed_manifest_sha256":SEED_MANIFEST_SHA,"fresh_boundary":boundary}
 write_json_noreplace(commit,commit_obj)
 print("prepared normal v2.1 candidate: "+str(target));print("candidate manifest sha256: "+manifest_sha);print("candidate replacement commit: "+str(commit))
except BaseException:
 if stage.exists(): shutil.rmtree(stage,ignore_errors=True)
 raise
PY
