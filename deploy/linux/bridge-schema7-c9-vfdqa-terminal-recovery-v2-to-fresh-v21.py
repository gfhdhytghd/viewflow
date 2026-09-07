#!/usr/bin/env python3
"""Fail-closed, offline-only final bridge for the retired c9 recovery-v2 path.

The original schema7 bridge is deliberately not imported or modified: its
frozen hash is an input to the recovery lifecycle.  This successor accepts
only the actual under-deployment-quarantine v1.3 receipts and publishes the
normal-v21 nine-key terminal only after a separate, self-pinned approval.
"""
from __future__ import annotations
import argparse, ctypes, errno, hashlib, json, os, re, stat, subprocess, sys, uuid
from pathlib import Path

UID=1000
STATE=Path("/home/wilf/.local/state/viewflow")
OLD="c9b05e9bea4140d69f9d137a0f992ba0"; NEW="902bd39e80df420394cfa3ece89e2136"
COORD="d3ac8fa1-b623-49c4-9e97-513012a1328d"
ROOT=STATE/"bridges"/"c9-recovery-v2"/NEW; FRESH=STATE/"deployments"/NEW
OLDROOT=STATE/"deployments"/OLD
LIFECYCLE=Path("/home/wilf/data/viewflow/deploy/linux/c9-recovery-v2-fresh-boundary.py")
LIFECYCLE_SHA="7a81a0bf2b9ade2db3e6ecb1d798b1282073b23f3bf52779eeb25967ff6b10d8"
MANIFEST=ROOT/"manifest.json"; MANIFEST_SHA="d85feb42366a300cbd7ab0b5221307a88fbbd30650f03abe445324cc63b5ad58"
LIFECYCLE_APPROVAL=ROOT/"execution-approval.json"; LIFECYCLE_APPROVAL_SHA="8bda579d4e484cc8e89265b80b619176c79eddb7a974a3bf4a6bd55582ccdbaf"
FINAL=FRESH/"v4-inactive-terminal-to-fresh-v21.json"
APPROVAL=ROOT/"final-bridge-v2-execution-approval.json"
BRIDGE_PATH=Path("/home/wilf/data/viewflow/deploy/linux/bridge-schema7-c9-vfdqa-terminal-recovery-v2-to-fresh-v21.py")
HEX=re.compile(r"[0-9a-f]{64}\Z"); UTC=re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z\Z")

# Every source is a fixed, owner-only receipt.  Keeping the values here makes
# this a recovery set rather than a generic producer that could cross bridges.
PINS={
 "terminal":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-terminal.json","805ecce48133f4e52d0751b43d688e48ff72c4d1af8aaa96047c7c4db6f5d555"),
 "recovery_approval":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-execution-approval.json","cdb0cce3e431279240a8748109ef3f03f7b76bfe310b55285ea4c26ac1490066"),
 "authorization":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-authorization.json","598a11e781506a9cc2267d266d08df0c0a35db056595ff44fd993d8e8c5b45ad"),
 "receipt":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-receipt.json","b9baa81d2b7c356be6c699736db2befdf7e3b4a554b954c99279ace6d57472bd"),
 "query":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-query.json","d9e63801e3d78bc3fb848bf5f33ecd28eb208d2467e83a4425edc166efc7bb5c"),
 "transition":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-transition.json","14345a57e9c94c07916ea5b4bcc390fe8ceae6f207723b9bda414a758e11f0c7"),
 "linux":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-linux-v13-started.json","0f9d013499dd45e94fc0efbb7e907c965165296f998276bb6505fafb86d78c45"),
 "windows":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-windows-v13-started.json","e4037a8f6024e49169dba1ee094de7a9a90ff2180636c7b6cf098ebf401003a5"),
 "auth":("failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-authenticated-v13-peer.json","39c37a58ad970d21731cfb78e85184d37799e41a3e7cf62b74e67e068aa82e8a"),
}
VFDQA=STATE/".deployment-quarantine.v1.abort-receipt.9bc030e47e4d148341cf3cf540f318d291614b39769590a1035e2dcbc336f90a.598a11e781506a9cc2267d266d08df0c0a35db056595ff44fd993d8e8c5b45ad.v1"
VFDQA_SHA="56ae0daa3327e2ee469376968d59bd02086f1730b0f3fc1bd0459dca9422a67f"
RETIRED={"sidecar-release-all-cleanup.json":"8ca70d28ae185383bae9f32d191faa2af4c4515cabc8b67b9fca61500d643bd6","retire-intent.json":"aef43475e8b0918a6df569feb6ece58125bbdb2bb2d75ca1b1cb4ff31fc362ab","retire-viewflow.json":"75def93eae9bd73b2cced2e609809b51b675814a64c4e37d1f770da39d5ae4af","retire-deskflow.json":"4270040a66f05246b8707b884a4aab14963cc9b16f1ac8bbdb9c36d9fc279220","retired.json":"655bfe368f76b855be32b93189a82c525236e8ce36e685ad394c78c98ebde3ee","persistent-intent.json":"29955731a31afe638d973eaa195b2dd2fa39a01ec0997a87ced4476dd67a11f6","persistent-started.json":"57701b02087a8d226b7ca9a4022a34c26b08107a7e1f26d5c787f078b4f036c5"}
PHS={"deployment-publish.json":"27fa547abc99a3d7a610af023f4c24e8fbbcc15fd9a9da33d082fa412ff24cc9","marker-handoff.json":"dd2c75dfdc6f259806fc231b54031dc0cf5c7c3c3de800abc4608645b921f2ad","linux-frozen.json":"285bfe900e247fd612f69ef2a10e89e15bb4150c087d8e882a7ecd50a44ff3b7"}
MARKER=STATE/"deployment-quarantine.v1"; MARKER_SHA="0fa4b1ac4cca19099058cb259c064169762fa8b6fbeaf04ddd30ee0e411fe107"

class Fail(RuntimeError): pass
def die(s): raise Fail(s)
def digest(raw): return hashlib.sha256(raw).hexdigest()
def ident(s): return (s.st_dev,s.st_ino,s.st_size,s.st_mode,s.st_uid,s.st_nlink)
def pairs(xs):
 d={}
 for k,v in xs:
  if k in d: raise ValueError("duplicate key")
  d[k]=v
 return d
def strict(raw,label):
 try:
  text=raw.decode("utf-8","strict"); v,end=json.JSONDecoder(object_pairs_hook=pairs,parse_float=lambda _:(_ for _ in ()).throw(ValueError()),parse_constant=lambda _:(_ for _ in ()).throw(ValueError())).raw_decode(text)
 except Exception as e: raise Fail(label+" strict JSON differs") from e
 if type(v) is not dict or text[end:].strip(): die(label+" must be one JSON object")
 return v
def read(path,expected,mode,label,json_document=True):
 if not (str(path).startswith("/") and HEX.fullmatch(expected)): die(label+" pin differs")
 fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  before=os.fstat(fd); named=os.stat(path,follow_symlinks=False); raw=b""
  if not(stat.S_ISREG(before.st_mode) and before.st_uid==UID and before.st_nlink==1 and stat.S_IMODE(before.st_mode)==mode and ident(before)==ident(named)): die(label+" metadata differs")
  while True:
   x=os.read(fd,1<<20)
   if not x: break
   raw+=x
  if ident(os.fstat(fd))!=ident(before) or digest(raw)!=expected: die(label+" changed")
 finally: os.close(fd)
 return strict(raw,label) if json_document else raw
def keys(v,want,label):
 if set(v)!=set(want): die(label+" schema differs")
def must(v,label,**want):
 if any(v.get(k)!=x for k,x in want.items()): die(label+" binding differs")
def canonical(v): return (json.dumps(v,separators=(",",":"),sort_keys=False)+"\n").encode()
def output_parent(path):
 parent=path.parent; s=os.stat(parent,follow_symlinks=False)
 if not(parent.is_dir() and not parent.is_symlink() and s.st_uid==UID and stat.S_IMODE(s.st_mode)==0o700): die("output parent differs")
def create_once(path,raw):
 output_parent(path); dfd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  try: os.stat(path.name,dir_fd=dfd,follow_symlinks=False); die("create-once output exists")
  except FileNotFoundError: pass
  fd=os.open(".",os.O_TMPFILE|os.O_RDWR|os.O_CLOEXEC,0o600,dir_fd=dfd)
  try:
   os.write(fd,raw); os.fsync(fd); s=os.fstat(fd)
   if not(stat.S_ISREG(s.st_mode) and s.st_uid==UID and stat.S_IMODE(s.st_mode)==0o600 and s.st_nlink==0): die("anonymous stage differs")
   libc=ctypes.CDLL(None,use_errno=True); linkat=libc.linkat; linkat.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_int]
   if linkat(fd,b"",dfd,os.fsencode(path.name),0x1000):
    e=ctypes.get_errno(); die("create-once output exists" if e==errno.EEXIST else os.strerror(e))
   if ident(os.fstat(fd))!=ident(os.stat(path.name,dir_fd=dfd,follow_symlinks=False)): die("published identity differs")
   os.fsync(dfd)
  finally: os.close(fd)
 finally: os.close(dfd)
def self_source_sha():
 # Do not authorize an arbitrary symlink/import path.  Both approval creation
 # and final publication pin this exact, stable source object independently.
 if Path(__file__).absolute()!=BRIDGE_PATH: die("bridge invocation path differs")
 fd=os.open(BRIDGE_PATH,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  before=os.fstat(fd); named=os.stat(BRIDGE_PATH,follow_symlinks=False); raw=b""
  if not(stat.S_ISREG(before.st_mode) and before.st_uid==UID and before.st_nlink==1 and stat.S_IMODE(before.st_mode)==0o755 and ident(before)==ident(named)): die("bridge source metadata differs")
  while True:
   x=os.read(fd,1<<20)
   if not x: break
   raw+=x
  if ident(os.fstat(fd))!=ident(before): die("bridge source changed")
 finally: os.close(fd)
 return digest(raw)

def c9_sources():
 v={n:read(OLDROOT/name,sha,0o600,n) for n,(name,sha) in PINS.items()}; vf=read(VFDQA,VFDQA_SHA,0o600,"vfdqa",False)
 term=v["terminal"]; keys(term,"abort_claim_absent abort_receipt_sha256 approval_sha256 authenticated_v13_peer_sha256 authorization_sha256 coordinator_redispatched durable_vfdqa_sha256 gate_sha256 launcher_sha256 linux_v13_started_sha256 manifest_sha256 marker_abort_redispatched marker_absent operation_id predecessor_approval_sha256 query_sha256 release_claim_absent retired_claim_sha256 schema_version state transition_sha256 windows_v13_started_sha256".split(),"c9 terminal")
 must(term,"c9 terminal",schema_version=2,state="viewflow-c9b05e9-schema7-vfdqa-abort-recovery-v2-terminal",operation_id=OLD,coordinator_redispatched=False,marker_abort_redispatched=False,marker_absent=True,abort_claim_absent=True,release_claim_absent=True,approval_sha256=PINS["recovery_approval"][1],authorization_sha256=PINS["authorization"][1],abort_receipt_sha256=PINS["receipt"][1],query_sha256=PINS["query"][1],durable_vfdqa_sha256=VFDQA_SHA,transition_sha256=PINS["transition"][1],linux_v13_started_sha256=PINS["linux"][1],windows_v13_started_sha256=PINS["windows"][1],authenticated_v13_peer_sha256=PINS["auth"][1])
 keys(v["linux"],"control_group deployment_marker_sha256 exec_start_sha256 expected_exec_start_sha256 fd_gate_payload_sha256 invocation_id kill_mode main_pid operation_id protocol_version schema_version start_ticks state transient unit unit_active_state viewflowd_sha256".split(),"linux receipt")
 must(v["linux"],"linux receipt",schema_version=1,state="viewflow-linux-v1.3-started-under-deployment-quarantine",operation_id=OLD,protocol_version="1.3",transient=True,kill_mode="control-group",unit_active_state="active")
 keys(v["windows"],"deployment_marker_sha256 operation_id pid process_start_filetime_utc protocol_version schema_version session_id state task_name task_state task_xml_sha256 user_sid viewflowd_sha256 wrapper_sha256".split(),"windows receipt")
 must(v["windows"],"windows receipt",schema_version=1,state="viewflow-windows-v1.3-started-under-deployment-quarantine",operation_id=OLD,protocol_version="1.3",task_state="Running")
 keys(v["auth"],"authenticated_peer_ip authenticated_peer_port authenticated_peer_record_sha256 deployment_marker_sha256 fresh_probe_record_sha256 linux_invocation_id linux_v13_started_receipt_sha256 operation_id protocol_2_1 protocol_version schema_version state windows_v13_started_receipt_sha256".split(),"auth receipt")
 must(v["auth"],"auth receipt",schema_version=1,state="viewflow-v1.3-peer-authenticated-under-deployment-quarantine",operation_id=OLD,protocol_2_1=False,protocol_version="1.3",linux_v13_started_receipt_sha256=PINS["linux"][1],windows_v13_started_receipt_sha256=PINS["windows"][1])
 for n in ("recovery_approval","authorization","receipt","query","transition"):
  must(v[n],"c9 "+n,operation_id=OLD)
 must(v["recovery_approval"],"c9 approval",schema_version=2,state="viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved",approved=True,authorization_sha256=PINS["authorization"][1],abort_receipt_sha256=PINS["receipt"][1],durable_vfdqa_sha256=VFDQA_SHA)
 must(v["query"],"c9 query",schema_version=2,state="viewflow-c9b05e9-schema7-abort-recovery-v2-query-committed",coordinator_redispatched=False,marker_abort_redispatched=False,authorization_sha256=PINS["authorization"][1],abort_receipt_sha256=PINS["receipt"][1],durable_vfdqa_sha256=VFDQA_SHA)
 must(v["receipt"],"c9 receipt",schema_version=7,state="deployment-quarantine-aborted",deployment_release_claimed=False,replayed=False,abort_authorization_sha256=PINS["authorization"][1])
 must(v["transition"],"c9 transition",schema_version=1,state="viewflow-failed-v1.3-bootstrap-abort-terminal",protocol_2_1=False,normal_deployment_release=False,linux_v13_started_receipt_sha256=PINS["linux"][1],windows_v13_started_receipt_sha256=PINS["windows"][1],authenticated_v13_peer_receipt_sha256=PINS["auth"][1])
 if not(len(vf)==384 and vf[:8]==b"VFDQA001" and digest(vf[:352])==vf[352:].hex() and vf[304:336].hex()==PINS["authorization"][1] and vf[344:352]==b"\0"*8 and digest(vf[16:272])==term["retired_claim_sha256"]): die("VFDQA differs")
 return v
def lifecycle():
 read(LIFECYCLE,LIFECYCLE_SHA,0o700,"lifecycle",False); m=read(MANIFEST,MANIFEST_SHA,0o600,"manifest"); a=read(LIFECYCLE_APPROVAL,LIFECYCLE_APPROVAL_SHA,0o600,"lifecycle approval")
 keys(m,"bridge_root execution_authorized fresh_root new_coordinator_instance_id new_operation_id old_operation_id outputs schema_version sources state".split(),"lifecycle manifest")
 must(m,"lifecycle manifest",schema_version=1,state="viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-plan",execution_authorized=False,bridge_root=str(ROOT),fresh_root=str(FRESH),old_operation_id=OLD,new_operation_id=NEW,new_coordinator_instance_id=COORD)
 must(a,"lifecycle approval",schema_version=1,state="viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-execution-approved",approved=True,manifest_sha256=MANIFEST_SHA,lifecycle_sha256=LIFECYCLE_SHA,old_operation_id=OLD,new_operation_id=NEW,new_coordinator_instance_id=COORD)
 for name,sha in RETIRED.items():
  x=read(ROOT/name,sha,0o600,name); must(x,name,schema_version=1,manifest_sha256=MANIFEST_SHA)
 for name,sha in PHS.items():
  x=read(FRESH/name,sha,0o600,name); must(x,name,schema_version=1,operation_id=NEW)
 p=read(FRESH/"deployment-publish.json",PHS["deployment-publish.json"],0o600,"publish"); h=read(FRESH/"marker-handoff.json",PHS["marker-handoff.json"],0o600,"handoff"); f=read(FRESH/"linux-frozen.json",PHS["linux-frozen.json"],0o600,"frozen")
 must(p,"publish",state="deployment-quarantine-published",coordinator_instance_id=COORD,protocol_version="2.1",marker_generation="1",marker_sha256=MARKER_SHA)
 must(h,"handoff",state="viewflow-v13-marker-handoff-prepared",coordinator_instance_id=COORD,protocol_version="2.1",marker_generation="1",deployment_publish_receipt_sha256=PHS["deployment-publish.json"],deskflow_unit_active_state="inactive",deskflow_unit_main_pid=0,deskflow_exact_process_count=0,deskflow_core_exact_process_count=0,deskflow_tcp_listener_count=0,runtime_marker_present=False)
 must(f,"frozen",state="viewflow-v13-bootstrap-frozen")
 if f.get("pre_stop",{}).get("deskflow_unit_active_state")!="inactive" or f.get("post_stop",{}).get("exact_process_count")!=0 or f.get("post_stop",{}).get("udp_44119_listener_count")!=0: die("Linux zero proof differs")
 marker=read(MARKER,MARKER_SHA,0o600,"active marker",False)
 source=uuid.UUID("00000000-0000-0000-0000-000000000101").bytes; target=uuid.UUID("00000000-0000-0000-0000-000000000002").bytes
 if not(len(marker)==256 and marker[:8]==b"VFDQT001" and marker[8:13]==bytes((1,1,2,1,1)) and marker[13]==32 and marker[14:16]==b"\0\0" and marker[16:48]==NEW.encode() and not any(marker[48:144]) and marker[144:160]==source and marker[160:176]==target and marker[176:192]==uuid.UUID(COORD).bytes and int.from_bytes(marker[192:200],"little")>0 and int.from_bytes(marker[200:208],"little")==1 and not any(marker[208:])): die("active VFDQT layout differs")
 return p,h,f
def approval_document():
 return {"schema_version":1,"state":"viewflow-c9-final-bridge-v2-execution-approved","approved":True,"old_operation_id":OLD,"new_operation_id":NEW,"new_coordinator_instance_id":COORD,"recovery_source_sha256":LIFECYCLE_SHA,"manifest_sha256":MANIFEST_SHA,"lifecycle_approval_sha256":LIFECYCLE_APPROVAL_SHA,"bridge_path":str(BRIDGE_PATH),"bridge_sha256":self_source_sha(),"terminal_sha256":PINS["terminal"][1],"retired_leaf_sha256":RETIRED,"deployment_publish_sha256":PHS["deployment-publish.json"],"marker_handoff_sha256":PHS["marker-handoff.json"],"linux_frozen_sha256":PHS["linux-frozen.json"],"publication_method":"O_TMPFILE-linkat-AT_EMPTY_PATH-create-once-and-parent-fsync"}
def require_approval():
 a=read(APPROVAL,digest(canonical(approval_document())),0o600,"final bridge approval")
 if a!=approval_document(): die("self-pinned approval differs")
def current_linux_zero():
 # This is read-only and intentionally runs only on the explicitly requested
 # final-publish arm.  Frozen P/H/F remains provenance, never a substitute for
 # current absence proof.
 for unit in ("viewflow-peer.service","deskflow.service","viewflow-v13-recovery-"+OLD+".service","deskflow-v13-recovery-"+OLD+".service"):
  r=subprocess.run(["/usr/bin/systemctl","--user","show",unit,"--property=ActiveState","--property=MainPID","--value"],env={"PATH":"/usr/bin:/bin","XDG_RUNTIME_DIR":"/run/user/1000","DBUS_SESSION_BUS_ADDRESS":"unix:path=/run/user/1000/bus"},stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,check=False)
  if r.returncode==0 and [x.strip() for x in r.stdout.splitlines() if x.strip()]!=["inactive","0"]: die("current systemd zero differs: "+unit)
  if r.returncode not in (0,4): die("cannot read current systemd state: "+unit)
 r=subprocess.run(["/usr/bin/ss","-H","-ltnup"],env={"PATH":"/usr/bin:/bin"},stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,check=True)
 if any((":24800" in x or ":44119" in x) for x in r.stdout.splitlines()): die("current listener zero differs")
 for path in ("/run/user/1000/viewflow/deskflow.sock","/run/user/1000/deskflow/viewflow-acceptance.sock","/run/user/1000/viewflow/deskflow-acceptance.sock","/run/user/1000/viewflow/post-release-acceptance.sock",str(STATE/"deskflow-quarantine.v2")):
  if os.path.lexists(path): die("current sidecar/acceptance marker differs")
 for proc in Path("/proc").iterdir():
  if not proc.name.isdigit(): continue
  try: exe=os.readlink(proc/"exe")
  except OSError: continue
  installed=("/home/wilf/.local/lib/viewflow/viewflowd","/home/wilf/.local/lib/deskflow-scale-fix/deskflow","/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core")
  if exe in installed or exe in tuple(x+" (deleted)" for x in installed) or exe.startswith("/memfd:viewflow-") or exe.startswith("/tmp/viewflow-deskflow-recovery/deskflow") or exe.startswith("/tmp/viewflow-deskflow-recovery/deskflow-core"): die("current exact process zero differs")
def final_document(p,h,f):
 return {"schema_version":1,"state":"viewflow-v4-inactive-terminal-to-fresh-v21","old_operation_id":OLD,"new_operation_id":NEW,"new_coordinator_instance_id":COORD,"marker_generation":"1","inactive_source":{"source_validation_sha256":PINS["terminal"][1],"terminal_sha256":PINS["terminal"][1],"authorization_sha256":PINS["authorization"][1],"abort_receipt_sha256":PINS["receipt"][1],"abort_query_receipt_sha256":PINS["query"][1],"vfdqa_sha256":VFDQA_SHA,"linux_initially_inactive":True,"windows_old_peer_unchanged":True},"persistent_v13":{"persistent_started_sha256":RETIRED["persistent-started.json"],"authenticated_probe_record_sha256":PINS["auth"][1],"stopped_by_collector":True},"fresh_boundary":{"deployment_publish_sha256":PHS["deployment-publish.json"],"marker_handoff_sha256":PHS["marker-handoff.json"],"linux_frozen_sha256":PHS["linux-frozen.json"],"deployment_marker_sha256":p["marker_sha256"],"protocol_version":"2.1"}}
def main():
 ap=argparse.ArgumentParser(); g=ap.add_mutually_exclusive_group(required=True); g.add_argument("--validate-inputs-only",action="store_true"); g.add_argument("--publish-approval",action="store_true"); g.add_argument("--publish-final",action="store_true"); a=ap.parse_args()
 c9_sources(); p,h,f=lifecycle()
 if a.publish_approval: create_once(APPROVAL,canonical(approval_document()))
 elif a.publish_final: require_approval(); current_linux_zero(); create_once(FINAL,canonical(final_document(p,h,f)))
 print("c9 final bridge v2 validated"+(" and published" if a.publish_approval or a.publish_final else ""))
if __name__=="__main__":
 try: main()
 except (Fail,OSError,ValueError,KeyError) as e: print("error: c9 final bridge v2: "+str(e),file=sys.stderr); sys.exit(1)
