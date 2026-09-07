#!/usr/bin/env python3
"""Create the P/H/F bootstrap boundary after c9's recovery-v2 tombstone.

This is deliberately not a coordinator and never talks to Windows.  It is the
small, Linux-only transaction between the c9 recovery-v2 terminal and the
schema7 terminal-to-fresh validator: retire the exact temporary v1.3 service,
bring up the installed persistent v1.3 service long enough to publish a new
generation-1 VFDQT P/H boundary, and let the frozen-evidence collector stop it.
"""
from __future__ import annotations

import argparse, array, ctypes, errno, fcntl, hashlib, json, os, re, stat, subprocess, sys, time
from pathlib import Path

UID=1000
STATE=Path("/home/wilf/.local/state/viewflow")
OLD="c9b05e9bea4140d69f9d137a0f992ba0"
NEW="902bd39e80df420394cfa3ece89e2136"
COORD="d3ac8fa1-b623-49c4-9e97-513012a1328d"
FAILED="8310669e11154652bd21ed5020440e92"
FAILED_COORD="e693aa61-9f78-4e86-a343-4dfefd47be78"
FAILED_MANIFEST_SHA="7a9fed3c7d44f827c64745b17e7bd95d046a204fbb24170dbf259d08d06404c7"
FAILED_APPROVAL_SHA="ec3a4d98be7a74a7fac9348abb1efc3933370b834198ec9bf32e7b7db5b12ff0"
FAILED_SYSTEMD_PREIMAGE_SHA="72cb21cd4059d53d374be8d82ad80e6718bceeb1fb5d65513f2f5283251157c0"
FAILED_LIFECYCLE_SHA="03a126f2032daf34c60483df8f65e34ee21d8ddef9b5597bea9a89389dbbcf98"
PREPARE_HELPER_SHA="1b2fff138742e2b210f02eb18dc6caffd053fd9015c9a46222bfeb1bf708c88a"
FINAL_BRIDGE="/home/wilf/data/viewflow/deploy/linux/bridge-schema7-c9-vfdqa-terminal-to-fresh-v21.py"
FINAL_BRIDGE_SHA="6bec4fcbe41576ff3f159f06734d2f4de8e5e7e6da422369f209d6e2226fbca0"
OLDROOT=STATE/"deployments"/OLD
ROOT=STATE/"bridges"/"c9-recovery-v2"/NEW
FRESH=STATE/"deployments"/NEW
FAILED_ROOT=STATE/"bridges"/"c9-recovery-v2"/FAILED
FAILED_FRESH=STATE/"deployments"/FAILED
FAILED_CANDIDATE=STATE/"candidates"/("v21-operation-"+FAILED)
FAILED_CLOSURE=FAILED_ROOT/"failed-successor-closure.json"
SHA=re.compile(r"[0-9a-f]{64}\Z")
OP=re.compile(r"[0-9a-f]{32}\Z")
UUID=re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
AT_EMPTY_PATH=0x1000
TRANSIENT_VIEWFLOW_MEMFD="/memfd:viewflow-verified-elf (deleted)"
# The memfd process is the old v1.3 server after the transient launcher has
# exec'd it.  The fd gate is intentionally not part of this final argv: it is
# bound to the transient unit's canonical systemd ExecStart below.
EXPECTED_VIEWFLOW_V13_ARGV=(
    b"/home/wilf/.local/lib/viewflow/viewflowd", b"serve", b"--bind", b"0.0.0.0:44119",
    b"--cert", b"/home/wilf/.local/share/viewflow/identity/peer.pem",
    b"--key", b"/home/wilf/.local/share/viewflow/identity/peer.key",
    b"--ca", b"/home/wilf/.local/share/viewflow/identity/ca.pem",
    b"--device-id", b"00000000000000000000000000000001",
    b"--sidecar-socket", b"/run/user/1000/viewflow/deskflow.sock",
    b"--sidecar-peer", b"172.16.105.70",
    b"--sidecar-target-device", b"00000000000000000000000000000002",
)
ENV={"HOME":"/home/wilf","USER":"wilf","LOGNAME":"wilf","PATH":"/usr/bin:/bin",
     "LANG":"C.UTF-8","LC_ALL":"C.UTF-8","XDG_RUNTIME_DIR":"/run/user/1000",
     "DBUS_SESSION_BUS_ADDRESS":"unix:path=/run/user/1000/bus"}

class Error(RuntimeError): pass
def die(s): raise Error(s)
def digest(b): return hashlib.sha256(b).hexdigest()
def ident(s): return (s.st_dev,s.st_ino,s.st_mode,s.st_uid,s.st_gid,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
def canonical(v): return (json.dumps(v,sort_keys=True,separators=(",",":"))+"\n").encode()
def pairs(xs):
    d={}
    for k,v in xs:
        if k in d: raise ValueError("duplicate JSON key")
        d[k]=v
    return d
def strict(raw,label):
    try:
        text=raw.decode("utf-8","strict")
        dec=json.JSONDecoder(object_pairs_hook=pairs,parse_float=lambda _ : (_ for _ in ()).throw(ValueError()))
        v,end=dec.raw_decode(text)
    except Exception as e: raise Error(label+" is not strict JSON") from e
    if type(v) is not dict or text[end:].strip(): die(label+" is not one JSON object")
    return v
def stable(path,sha,mode,label,json_document=False):
    if not (isinstance(path,str) and path.startswith("/") and SHA.fullmatch(sha)): die(label+" pin differs")
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd); named=os.stat(path,follow_symlinks=False)
        required_links=2 if label=="marker_candidate" else 1
        if not(stat.S_ISREG(before.st_mode) and before.st_uid==UID and before.st_nlink==required_links and stat.S_IMODE(before.st_mode)==mode and ident(before)==ident(named)): die(label+" metadata differs")
        out=[]
        while True:
            b=os.read(fd,1<<20)
            if not b: break
            out.append(b)
        raw=b"".join(out)
        if ident(os.fstat(fd))!=ident(before) or digest(raw)!=sha: die(label+" changed while read")
    finally: os.close(fd)
    return strict(raw,label) if json_document else raw
def generated(path,label):
    """Read a create-once receipt without a pre-known SHA, but never by name alone."""
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd); named=os.stat(path,follow_symlinks=False)
        if not(stat.S_ISREG(before.st_mode) and before.st_uid==UID and before.st_nlink==1 and stat.S_IMODE(before.st_mode)==0o600 and ident(before)==ident(named)): die(label+" generated metadata differs")
        raw=os.read(fd,before.st_size+1)
        if len(raw)!=before.st_size or ident(os.fstat(fd))!=ident(before): die(label+" changed while read")
        return strict(raw,label)
    finally: os.close(fd)
def create_once(path,raw,_after_stage=None):
    """FD-pinned owner-only publication with no named staging dentry.

    `linkat(AT_EMPTY_PATH)` names the exact O_TMPFILE descriptor only at the
    no-replace linearization point.  In particular, a same-UID process cannot
    swap a visible temporary pathname between write/fsync and publication.
    """
    parent=Path(path).parent; leaf=Path(path).name
    fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        s=os.fstat(fd); named=os.stat(parent,follow_symlinks=False)
        if s.st_uid!=UID or stat.S_IMODE(s.st_mode)!=0o700 or ident(s)!=ident(named): die("output parent differs")
        try: os.stat(leaf,dir_fd=fd,follow_symlinks=False); die("create-once output exists: "+str(path))
        except FileNotFoundError: pass
        out=os.open(".",os.O_TMPFILE|os.O_RDWR|os.O_CLOEXEC,0o600,dir_fd=fd)
        try:
            os.fchmod(out,0o600)
            view=memoryview(raw)
            while view:
                n=os.write(out,view)
                if n<=0: die("short output write")
                view=view[n:]
            os.fsync(out)
            staged=os.fstat(out)
            if not(stat.S_ISREG(staged.st_mode) and staged.st_uid==UID and stat.S_IMODE(staged.st_mode)==0o600 and staged.st_nlink==0): die("create-once anonymous stage differs")
            if _after_stage is not None: _after_stage(fd,leaf)
            libc=ctypes.CDLL(None,use_errno=True); linkat=libc.linkat
            linkat.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_int]; linkat.restype=ctypes.c_int
            if linkat(out,b"",fd,os.fsencode(leaf),AT_EMPTY_PATH):
                e=ctypes.get_errno()
                if e==errno.EEXIST: die("create-once output exists: "+str(path))
                raise OSError(e,os.strerror(e))
            named_leaf=os.stat(leaf,dir_fd=fd,follow_symlinks=False)
            if ident(os.fstat(out))!=ident(named_leaf): die("create-once output dentry changed before fsync")
            os.fsync(fd)
        finally: os.close(out)
    finally:
        os.close(fd)
def read_fd_to_eof(fd):
    """Read a descriptor until EOF; procfs files deliberately report st_size=0."""
    chunks=[]
    while True:
        chunk=os.read(fd,1<<20)
        if not chunk: return b"".join(chunks)
        chunks.append(chunk)
def sha_file(path):
    # This is only used after a caller has pinned the pathname or for its own
    # create-once output.  It nevertheless reads the descriptor, not a second
    # pathname lookup.
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC)
    try: return digest(read_fd_to_eof(fd))
    finally: os.close(fd)
def lifecycle_sha256(): return sha_file(str(Path(__file__).resolve()))
def require_dir(path,label,missing=False):
    if missing and not os.path.lexists(path):
        os.mkdir(path,0o700); os.chmod(path,0o700)
    s=os.stat(path,follow_symlinks=False)
    if not(stat.S_ISDIR(s.st_mode) and s.st_uid==UID and stat.S_IMODE(s.st_mode)==0o700 and not os.path.islink(path)): die(label+" directory differs")

def parser():
    p=argparse.ArgumentParser()
    m=p.add_mutually_exclusive_group(required=True)
    m.add_argument("--prepare",action="store_true");m.add_argument("--offline-check",action="store_true")
    m.add_argument("--publish-execution-approval",action="store_true");m.add_argument("--execute",action="store_true");m.add_argument("--resume",action="store_true")
    m.add_argument("--close-failed-attempt",action="store_true");m.add_argument("--check-failed-attempt",action="store_true")
    p.add_argument("--manifest",default=str(ROOT/"manifest.json"));p.add_argument("--manifest-sha256",default="")
    p.add_argument("--approval-sha256",default="");p.add_argument("--approved-at-utc",default="")
    p.add_argument("--recovery-terminal");p.add_argument("--recovery-terminal-sha256");p.add_argument("--recovery-query");p.add_argument("--recovery-query-sha256")
    p.add_argument("--recovery-approval");p.add_argument("--recovery-approval-sha256")
    for x in ("authorization","abort-receipt","abort-query","vfdqa","linux-v13-started","windows-v13-started","authenticated-v13-peer","transition"):
        p.add_argument("--"+x);p.add_argument("--"+x+"-sha256")
    p.add_argument("--marker-candidate");p.add_argument("--marker-candidate-sha256")
    p.add_argument("--prepare-script");p.add_argument("--prepare-script-sha256")
    p.add_argument("--collector-script");p.add_argument("--collector-script-sha256")
    p.add_argument("--final-bridge");p.add_argument("--final-bridge-sha256")
    p.add_argument("--viewflow");p.add_argument("--viewflow-sha256");p.add_argument("--viewflow-unit");p.add_argument("--viewflow-unit-sha256")
    p.add_argument("--deskflow");p.add_argument("--deskflow-sha256");p.add_argument("--deskflow-core");p.add_argument("--deskflow-core-sha256")
    p.add_argument("--failed-closure");p.add_argument("--failed-closure-sha256")
    return p.parse_args()

def expected_terminal(t,sources):
    want={"schema_version":2,"state":"viewflow-c9b05e9-schema7-vfdqa-abort-recovery-v2-terminal","operation_id":OLD,
          "coordinator_redispatched":False,"marker_abort_redispatched":False,"marker_absent":True,"abort_claim_absent":True,"release_claim_absent":True,
          "query_sha256":sources["recovery_query"]["sha256"],"authorization_sha256":sources["authorization"]["sha256"],"abort_receipt_sha256":sources["abort_receipt"]["sha256"],"durable_vfdqa_sha256":sources["vfdqa"]["sha256"],"linux_v13_started_sha256":sources["linux_v13_started"]["sha256"],"windows_v13_started_sha256":sources["windows_v13_started"]["sha256"],"authenticated_v13_peer_sha256":sources["authenticated_v13_peer"]["sha256"],"transition_sha256":sources["transition"]["sha256"]}
    if set(t)!={"schema_version","state","operation_id","manifest_sha256","gate_sha256","launcher_sha256","approval_sha256","predecessor_approval_sha256","authorization_sha256","abort_receipt_sha256","transition_sha256","linux_v13_started_sha256","windows_v13_started_sha256","authenticated_v13_peer_sha256","durable_vfdqa_sha256","retired_claim_sha256","query_sha256","coordinator_redispatched","marker_abort_redispatched","marker_absent","abort_claim_absent","release_claim_absent"}: die("recovery-v2 terminal keyset differs")
    if any(t[k]!=v for k,v in want.items()): die("recovery-v2 terminal truth differs")
TRANSITION_KEYS={"abort_authorization_sha256","authenticated_v13_peer_receipt_sha256","bubblewrap_sha256","deployment_abort_receipt_sha256","deployment_marker_sha256","fd_gate_payload_sha256","linux_deskflow_control_group","linux_deskflow_core_executable_sha256","linux_deskflow_core_pid","linux_deskflow_core_runtime_path","linux_deskflow_core_start_ticks","linux_deskflow_exec_start_sha256","linux_deskflow_executable_sha256","linux_deskflow_expected_exec_start_sha256","linux_deskflow_invocation_id","linux_deskflow_main_pid","linux_deskflow_main_start_ticks","linux_deskflow_runtime_path","linux_deskflow_runtime_pid","linux_deskflow_runtime_start_ticks","linux_deskflow_unit","linux_deskflow_unit_state","linux_v13_started_receipt_sha256","linux_viewflow_unit_state","normal_deployment_release","old_coordinator_terminal_state_sha256","operation_id","protocol_2_1","protocol_version","schema_version","sealed_sibling_directory_read_only","state","windows_v13_started_receipt_sha256"}
LINUX_STARTED_KEYS={"control_group","deployment_marker_sha256","exec_start_sha256","expected_exec_start_sha256","fd_gate_payload_sha256","invocation_id","kill_mode","main_pid","operation_id","protocol_version","schema_version","start_ticks","state","transient","unit","unit_active_state","viewflowd_sha256"}
RECOVERY_QUERY_KEYS={"abort_receipt_sha256","authorization_sha256","coordinator_redispatched","durable_vfdqa_sha256","marker_abort_redispatched","marker_query","marker_query_sha256","operation_id","predecessor_approval_sha256","query_source","schema_version","state"}
RECOVERY_APPROVAL_KEYS={"abort_receipt_sha256","abort_redispatch_forbidden","approved","approved_at_utc","authenticated_v13_peer_sha256","authorization_sha256","coordinator_dispatch_forbidden","durable_vfdqa_sha256","gate_sha256","launcher_sha256","linux_v13_started_sha256","manifest_sha256","only_pinned_marker_query","operation_id","predecessor_approval_sha256","publication_method","retired_claim_sha256","schema_version","state","transition_sha256","windows_v13_started_sha256"}
def validate_linux_started(v,sources):
    if set(v)!=LINUX_STARTED_KEYS: die("transient Viewflow receipt keyset differs")
    required={"schema_version":1,"state":"viewflow-linux-v1.3-started-under-deployment-quarantine","operation_id":OLD,"protocol_version":"1.3","transient":True,"kill_mode":"control-group","unit_active_state":"active","viewflowd_sha256":sources["viewflow"]["sha256"]}
    if any(v[k]!=x for k,x in required.items()) or v["exec_start_sha256"]!=v["expected_exec_start_sha256"]: die("transient Viewflow receipt binding differs")
    for key in ("deployment_marker_sha256","exec_start_sha256","expected_exec_start_sha256","fd_gate_payload_sha256"):
        if not SHA.fullmatch(v[key]): die("transient Viewflow receipt hash differs")
    if not(re.fullmatch(r"viewflow-v13-recovery-"+OLD+r"[.]service",v["unit"]) and v["control_group"].endswith("/"+v["unit"]) and re.fullmatch(r"[0-9a-f]{32}",v["invocation_id"])): die("transient Viewflow unit/cgroup differs")
    for key in ("main_pid","start_ticks"):
        if type(v[key]) is not int or v[key]<=0: die("transient Viewflow PID/ticks differs")
def validate_transition(v,sources):
    if set(v)!=TRANSITION_KEYS: die("transition keyset differs")
    required={"schema_version":1,"state":"viewflow-failed-v1.3-bootstrap-abort-terminal","operation_id":OLD,"protocol_version":"1.3","protocol_2_1":False,"normal_deployment_release":False,"linux_deskflow_unit_state":"active","linux_viewflow_unit_state":"active","sealed_sibling_directory_read_only":True,"old_coordinator_terminal_state_sha256":"066ef1bfa69aa09989204245c16d15c19eb66003a8a715f553c70b76976d7e8f","linux_v13_started_receipt_sha256":sources["linux_v13_started"]["sha256"],"windows_v13_started_receipt_sha256":sources["windows_v13_started"]["sha256"],"authenticated_v13_peer_receipt_sha256":sources["authenticated_v13_peer"]["sha256"],"abort_authorization_sha256":sources["authorization"]["sha256"],"deployment_abort_receipt_sha256":sources["abort_receipt"]["sha256"]}
    if any(v[k]!=x for k,x in required.items()): die("transition cross-binding differs")
    if v["linux_deskflow_exec_start_sha256"]!=v["linux_deskflow_expected_exec_start_sha256"]: die("transition Deskflow ExecStart differs")
    if not(re.fullmatch(r"deskflow-v13-recovery-"+OLD+r"[.]service",v["linux_deskflow_unit"]) and v["linux_deskflow_control_group"].endswith("/"+v["linux_deskflow_unit"])): die("transition Deskflow unit/cgroup differs")
    for key in ("linux_deskflow_main_pid","linux_deskflow_main_start_ticks","linux_deskflow_runtime_pid","linux_deskflow_runtime_start_ticks","linux_deskflow_core_pid","linux_deskflow_core_start_ticks"):
        if type(v[key]) is not int or v[key]<=0: die("transition PID/ticks differs")
    for key in ("linux_deskflow_executable_sha256","linux_deskflow_core_executable_sha256","bubblewrap_sha256","fd_gate_payload_sha256","deployment_marker_sha256"):
        if not SHA.fullmatch(v[key]): die("transition hash differs")
    if v["linux_deskflow_executable_sha256"]!=sources["deskflow"]["sha256"] or v["linux_deskflow_core_executable_sha256"]!=sources["deskflow_core"]["sha256"]: die("transition installed Deskflow hash differs")
    if v["linux_deskflow_runtime_path"]!="/tmp/viewflow-deskflow-recovery/deskflow" or v["linux_deskflow_core_runtime_path"]!="/tmp/viewflow-deskflow-recovery/deskflow-core": die("transition runtime path differs")

def spec(path,sha,mode): return {"path":path,"sha256":sha,"mode":mode}
def plan_from_args(a):
    names=("recovery_terminal","recovery_query","recovery_approval","authorization","abort_receipt","abort_query","vfdqa","linux_v13_started","windows_v13_started","authenticated_v13_peer","transition")
    sources={}
    for n in names:
        path=getattr(a,n); h=getattr(a,n+"_sha256")
        if not path or not h: die("--prepare requires "+n)
        sources[n]=spec(path,h,0o600)
    for n in ("marker_candidate","prepare_script","collector_script","final_bridge","viewflow","deskflow","deskflow_core"):
        path=getattr(a,n);h=getattr(a,n+"_sha256")
        if not path or not h: die("--prepare requires "+n)
        sources[n]=spec(path,h,0o755)
    if sources["final_bridge"] != spec(FINAL_BRIDGE,FINAL_BRIDGE_SHA,0o755):
        die("final bridge path/SHA is not the ABI-reviewed c9 schema7 bridge")
    if not a.viewflow_unit or not a.viewflow_unit_sha256: die("--prepare requires viewflow-unit")
    sources["viewflow_unit"]=spec(a.viewflow_unit,a.viewflow_unit_sha256,0o644)
    if not a.failed_closure or not a.failed_closure_sha256: die("--prepare requires failed-closure")
    if a.failed_closure!=str(FAILED_CLOSURE): die("failed successor closure path is fixed")
    # The closure is an ordinary source of the new plan: it is re-opened
    # below under its supplied SHA, and validates the failed attempt's three
    # immutable predecessor leaves before the plan can exist.
    sources["failed_closure"]=spec(a.failed_closure,a.failed_closure_sha256,0o600)
    validate_failed_closure(stable(a.failed_closure,a.failed_closure_sha256,0o600,"failed_closure",True),a.failed_closure_sha256)
    return {"schema_version":1,"state":"viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-plan","execution_authorized":False,
      "old_operation_id":OLD,"new_operation_id":NEW,"new_coordinator_instance_id":COORD,"bridge_root":str(ROOT),"fresh_root":str(FRESH),
      "outputs":{"approval":str(ROOT/"execution-approval.json"),"systemd_preimage":str(ROOT/"systemd-preimage.json"),"cleanup_proof":str(ROOT/"sidecar-release-all-cleanup.json"),"retire_intent":str(ROOT/"retire-intent.json"),"retire_deskflow":str(ROOT/"retire-deskflow.json"),"retire_viewflow":str(ROOT/"retire-viewflow.json"),"retired":str(ROOT/"retired.json"),"persistent_intent":str(ROOT/"persistent-intent.json"),"persistent_started":str(ROOT/"persistent-started.json"),"deployment_publish":str(FRESH/"deployment-publish.json"),"marker_handoff":str(FRESH/"marker-handoff.json"),"linux_frozen":str(FRESH/"linux-frozen.json"),"terminal":str(FRESH/"v4-inactive-terminal-to-fresh-v21.json")},"sources":sources}

def validate_plan(v,sha):
    keys={"schema_version","state","execution_authorized","old_operation_id","new_operation_id","new_coordinator_instance_id","bridge_root","fresh_root","outputs","sources"}
    if set(v)!=keys or v.get("schema_version")!=1 or v.get("state")!="viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-plan" or v.get("execution_authorized") is not False or v.get("old_operation_id")!=OLD or v.get("new_operation_id")!=NEW or v.get("new_coordinator_instance_id")!=COORD or v.get("bridge_root")!=str(ROOT) or v.get("fresh_root")!=str(FRESH): die("lifecycle manifest identity differs")
    sources=v["sources"]
    outputs={"approval":str(ROOT/"execution-approval.json"),"systemd_preimage":str(ROOT/"systemd-preimage.json"),"cleanup_proof":str(ROOT/"sidecar-release-all-cleanup.json"),"retire_intent":str(ROOT/"retire-intent.json"),"retire_deskflow":str(ROOT/"retire-deskflow.json"),"retire_viewflow":str(ROOT/"retire-viewflow.json"),"retired":str(ROOT/"retired.json"),"persistent_intent":str(ROOT/"persistent-intent.json"),"persistent_started":str(ROOT/"persistent-started.json"),"deployment_publish":str(FRESH/"deployment-publish.json"),"marker_handoff":str(FRESH/"marker-handoff.json"),"linux_frozen":str(FRESH/"linux-frozen.json"),"terminal":str(FRESH/"v4-inactive-terminal-to-fresh-v21.json")}
    if v["outputs"]!=outputs: die("lifecycle output paths differ")
    expected={"recovery_terminal":0o600,"recovery_query":0o600,"recovery_approval":0o600,"authorization":0o600,"abort_receipt":0o600,"abort_query":0o600,"vfdqa":0o600,"linux_v13_started":0o600,"windows_v13_started":0o600,"authenticated_v13_peer":0o600,"transition":0o600,"marker_candidate":0o755,"prepare_script":0o755,"collector_script":0o755,"final_bridge":0o755,"viewflow":0o755,"viewflow_unit":0o644,"deskflow":0o755,"deskflow_core":0o755,"failed_closure":0o600}
    if set(sources)!=set(expected): die("lifecycle source keyset differs")
    docs={}
    for n,mode in expected.items():
        x=sources[n]
        if set(x)!={"path","sha256","mode"} or x["mode"]!=mode: die(n+" spec differs")
        docs[n]=stable(x["path"],x["sha256"],mode,n,n in ("recovery_terminal","recovery_query","recovery_approval","authorization","abort_receipt","abort_query","linux_v13_started","windows_v13_started","authenticated_v13_peer","transition","failed_closure"))
    validate_failed_closure(docs["failed_closure"],sources["failed_closure"]["sha256"])
    expected_terminal(docs["recovery_terminal"],sources)
    t=docs["recovery_terminal"]
    if t["approval_sha256"]!=sources["recovery_approval"]["sha256"]: die("recovery terminal approval binding differs")
    q=docs["recovery_query"]
    if sources["abort_query"]["sha256"]!=sources["recovery_query"]["sha256"] or docs["abort_query"]!=q or set(q)!=RECOVERY_QUERY_KEYS or q.get("schema_version")!=2 or q.get("state")!="viewflow-c9b05e9-schema7-abort-recovery-v2-query-committed" or q.get("operation_id")!=OLD or q.get("coordinator_redispatched") is not False or q.get("marker_abort_redispatched") is not False or q.get("query_source")!="sealed-marker-cli-query" or q.get("authorization_sha256")!=sources["authorization"]["sha256"] or q.get("abort_receipt_sha256")!=sources["abort_receipt"]["sha256"] or q.get("durable_vfdqa_sha256")!=sources["vfdqa"]["sha256"] or digest(canonical(q.get("marker_query")))!=q.get("marker_query_sha256"): die("recovery-v2 query differs")
    a=docs["recovery_approval"]
    if set(a)!=RECOVERY_APPROVAL_KEYS or a.get("schema_version")!=2 or a.get("state")!="viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved" or a.get("approved") is not True or a.get("operation_id")!=OLD or a.get("authorization_sha256")!=sources["authorization"]["sha256"] or a.get("abort_receipt_sha256")!=sources["abort_receipt"]["sha256"] or a.get("linux_v13_started_sha256")!=sources["linux_v13_started"]["sha256"] or a.get("windows_v13_started_sha256")!=sources["windows_v13_started"]["sha256"] or a.get("authenticated_v13_peer_sha256")!=sources["authenticated_v13_peer"]["sha256"] or a.get("transition_sha256")!=sources["transition"]["sha256"]: die("recovery-v2 approval differs")
    for k,n in (("authorization_sha256","authorization"),("abort_receipt_sha256","abort_receipt"),("transition_sha256","transition"),("linux_v13_started_sha256","linux_v13_started"),("windows_v13_started_sha256","windows_v13_started"),("authenticated_v13_peer_sha256","authenticated_v13_peer")):
        if t[k]!=sources[n]["sha256"]: die("recovery terminal "+k+" differs")
    validate_linux_started(docs["linux_v13_started"],sources)
    validate_transition(docs["transition"],sources)
    return docs

FAILED_SOURCE_MODES={"recovery_terminal":0o600,"recovery_query":0o600,"recovery_approval":0o600,"authorization":0o600,"abort_receipt":0o600,"abort_query":0o600,"vfdqa":0o600,"linux_v13_started":0o600,"windows_v13_started":0o600,"authenticated_v13_peer":0o600,"transition":0o600,"marker_candidate":0o755,"prepare_script":0o755,"collector_script":0o755,"final_bridge":0o755,"viewflow":0o755,"viewflow_unit":0o644,"deskflow":0o755,"deskflow_core":0o755}
def failed_outputs():
    return {"approval":str(FAILED_ROOT/"execution-approval.json"),"systemd_preimage":str(FAILED_ROOT/"systemd-preimage.json"),"cleanup_proof":str(FAILED_ROOT/"sidecar-release-all-cleanup.json"),"retire_intent":str(FAILED_ROOT/"retire-intent.json"),"retire_deskflow":str(FAILED_ROOT/"retire-deskflow.json"),"retire_viewflow":str(FAILED_ROOT/"retire-viewflow.json"),"retired":str(FAILED_ROOT/"retired.json"),"persistent_intent":str(FAILED_ROOT/"persistent-intent.json"),"persistent_started":str(FAILED_ROOT/"persistent-started.json"),"deployment_publish":str(FAILED_FRESH/"deployment-publish.json"),"marker_handoff":str(FAILED_FRESH/"marker-handoff.json"),"linux_frozen":str(FAILED_FRESH/"linux-frozen.json"),"terminal":str(FAILED_FRESH/"v4-inactive-terminal-to-fresh-v21.json")}

def failed_root_leaves(include_closure):
    require_dir(FAILED_ROOT,"failed successor bridge root")
    expected={"manifest.json","execution-approval.json","systemd-preimage.json"}
    if include_closure: expected.add(FAILED_CLOSURE.name)
    actual={p.name for p in FAILED_ROOT.iterdir()}
    if actual!=expected: die("failed successor bridge leaf set differs")
    manifest=stable(str(FAILED_ROOT/"manifest.json"),FAILED_MANIFEST_SHA,0o600,"failed_manifest",True)
    approval_raw=stable(str(FAILED_ROOT/"execution-approval.json"),FAILED_APPROVAL_SHA,0o600,"failed_approval")
    preimage=stable(str(FAILED_ROOT/"systemd-preimage.json"),FAILED_SYSTEMD_PREIMAGE_SHA,0o600,"failed_systemd_preimage",True)
    return manifest,strict(approval_raw,"failed approval"),preimage

def failed_manifest_documents(manifest):
    keys={"schema_version","state","execution_authorized","old_operation_id","new_operation_id","new_coordinator_instance_id","bridge_root","fresh_root","outputs","sources"}
    if set(manifest)!=keys or manifest.get("schema_version")!=1 or manifest.get("state")!="viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-plan" or manifest.get("execution_authorized") is not False or manifest.get("old_operation_id")!=OLD or manifest.get("new_operation_id")!=FAILED or manifest.get("new_coordinator_instance_id")!=FAILED_COORD or manifest.get("bridge_root")!=str(FAILED_ROOT) or manifest.get("fresh_root")!=str(FAILED_FRESH) or manifest.get("outputs")!=failed_outputs(): die("failed successor manifest identity differs")
    sources=manifest.get("sources")
    if type(sources) is not dict or set(sources)!=set(FAILED_SOURCE_MODES): die("failed successor manifest source keyset differs")
    docs={}
    json_sources={"recovery_terminal","recovery_query","recovery_approval","authorization","abort_receipt","abort_query","linux_v13_started","windows_v13_started","authenticated_v13_peer","transition"}
    for name,mode in FAILED_SOURCE_MODES.items():
        x=sources[name]
        if type(x) is not dict or set(x)!={"path","sha256","mode"} or x.get("mode")!=mode: die("failed successor "+name+" source differs")
        # The reviewed cleanenv candidate is intentionally a two-link sealed
        # provenance pair; every other failed-attempt source is single-link.
        label="marker_candidate" if name=="marker_candidate" else "failed_"+name
        docs[name]=stable(x["path"],x["sha256"],mode,label,name in json_sources)
    if sources["final_bridge"]!=spec(FINAL_BRIDGE,FINAL_BRIDGE_SHA,0o755): die("failed successor final bridge pin differs")
    if sources["prepare_script"]["sha256"]!=PREPARE_HELPER_SHA: die("failed successor prepare helper source hash differs")
    expected_terminal(docs["recovery_terminal"],sources)
    if docs["recovery_terminal"]["approval_sha256"]!=sources["recovery_approval"]["sha256"]: die("failed successor recovery approval binding differs")
    q=docs["recovery_query"]
    if sources["abort_query"]["sha256"]!=sources["recovery_query"]["sha256"] or docs["abort_query"]!=q or set(q)!=RECOVERY_QUERY_KEYS or q.get("schema_version")!=2 or q.get("state")!="viewflow-c9b05e9-schema7-abort-recovery-v2-query-committed" or q.get("operation_id")!=OLD or q.get("coordinator_redispatched") is not False or q.get("marker_abort_redispatched") is not False or q.get("query_source")!="sealed-marker-cli-query" or q.get("authorization_sha256")!=sources["authorization"]["sha256"] or q.get("abort_receipt_sha256")!=sources["abort_receipt"]["sha256"] or q.get("durable_vfdqa_sha256")!=sources["vfdqa"]["sha256"] or digest(canonical(q.get("marker_query")))!=q.get("marker_query_sha256"): die("failed successor recovery query differs")
    a=docs["recovery_approval"]
    if set(a)!=RECOVERY_APPROVAL_KEYS or a.get("schema_version")!=2 or a.get("state")!="viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved" or a.get("approved") is not True or a.get("operation_id")!=OLD or a.get("authorization_sha256")!=sources["authorization"]["sha256"] or a.get("abort_receipt_sha256")!=sources["abort_receipt"]["sha256"] or a.get("linux_v13_started_sha256")!=sources["linux_v13_started"]["sha256"] or a.get("windows_v13_started_sha256")!=sources["windows_v13_started"]["sha256"] or a.get("authenticated_v13_peer_sha256")!=sources["authenticated_v13_peer"]["sha256"] or a.get("transition_sha256")!=sources["transition"]["sha256"]: die("failed successor recovery approval differs")
    validate_linux_started(docs["linux_v13_started"],sources); validate_transition(docs["transition"],sources)
    return sources,docs

def failed_approval(approval):
    want={"schema_version":1,"state":"viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-execution-approved","approved":True,"manifest_sha256":FAILED_MANIFEST_SHA,"lifecycle_sha256":FAILED_LIFECYCLE_SHA,"old_operation_id":OLD,"new_operation_id":FAILED,"new_coordinator_instance_id":FAILED_COORD,"approved_at_utc":"2026-09-04T19:27:35.908Z","publication_method":"create-once-no-replace-and-parent-fsync"}
    if approval!=want: die("failed successor execution approval differs")

def failed_preimage(preimage):
    if set(preimage)!={"schema_version","state","manifest_sha256","deskflow","recovery_deskflow","viewflow"} or preimage.get("schema_version")!=1 or preimage.get("state")!="viewflow-c9-recovery-v2-systemd-mask-dropin-preimage" or preimage.get("manifest_sha256")!=FAILED_MANIFEST_SHA: die("failed successor systemd preimage differs")
    for name in ("deskflow","recovery_deskflow","viewflow"):
        v=preimage.get(name)
        if type(v) is not dict or set(v)!={"fragment_path","dropin_paths","unit_file_state","unit_cat_sha256"} or not all(isinstance(v[k],str) for k in ("fragment_path","dropin_paths","unit_file_state")) or not SHA.fullmatch(v.get("unit_cat_sha256","")): die("failed successor systemd preimage record differs")

def failed_inputs(include_closure=False):
    manifest,approval_doc,preimage=failed_root_leaves(include_closure)
    sources,docs=failed_manifest_documents(manifest); failed_approval(approval_doc); failed_preimage(preimage)
    docs["failed_systemd_preimage"]=preimage
    return sources,docs

def assert_failed_systemd_preimage(preimage,transition):
    """The closure is invalid if any current effective unit source drifted."""
    assert_systemd_record("deskflow.service",preimage["deskflow"])
    assert_systemd_record(transition["linux_deskflow_unit"],preimage["recovery_deskflow"])
    assert_systemd_record("viewflow-peer.service",preimage["viewflow"])
    return {"deskflow":True,"recovery_deskflow":True,"viewflow":True}

def sidecar_live(pid):
    path=Path("/run/user/1000/viewflow/deskflow.sock")
    s=os.stat(path,follow_symlinks=False)
    if not(stat.S_ISSOCK(s.st_mode) and s.st_uid==UID and stat.S_IMODE(s.st_mode)==0o600 and s.st_nlink==1 and not os.path.islink(path)): die("Viewflow sidecar socket metadata differs")
    lines=[x for x in cmd(["/usr/bin/ss","-H","-lxnp"]).splitlines() if str(path) in x]
    if len(lines)!=1 or ("pid="+str(pid)+",") not in lines[0]: die("Viewflow sidecar socket ownership differs")
    return {"path":str(path),"inode":s.st_ino,"owner_pid":pid,"listener_count":1}

def failed_live(sources,docs):
    transition=docs["transition"]; started=docs["linux_v13_started"]
    want_t={"linux_deskflow_unit":"deskflow-v13-recovery-"+OLD+".service","linux_deskflow_main_pid":2641607,"linux_deskflow_main_start_ticks":6355585,"linux_deskflow_runtime_pid":2641625,"linux_deskflow_runtime_start_ticks":6355588,"linux_deskflow_core_pid":2641700,"linux_deskflow_core_start_ticks":6355614,"linux_deskflow_invocation_id":"57ec0e3c566c4c6391e1a4fbbec243dd"}
    want_v={"unit":"viewflow-v13-recovery-"+OLD+".service","main_pid":2628788,"start_ticks":6353894,"invocation_id":"b58c1b47e9e44e0db9237dd2054471ed"}
    if any(transition.get(k)!=v for k,v in want_t.items()) or any(started.get(k)!=v for k,v in want_v.items()): die("failed successor live identity differs")
    systemd_preimage_verified=assert_failed_systemd_preimage(docs["failed_systemd_preimage"],transition)
    deskflow_live(transition); viewflow_evidence=viewflow_live(started,sources["viewflow"]["path"])
    udp=cmd(["/usr/bin/ss","-H","-lunp","sport = :44119"]); tcp=cmd(["/usr/bin/ss","-H","-ltnp","sport = :24800"])
    if len([x for x in udp.splitlines() if x.strip()])!=1 or ("pid="+str(started["main_pid"])+",") not in udp: die("failed successor UDP listener differs")
    if len([x for x in tcp.splitlines() if x.strip()])!=1 or ("pid="+str(transition["linux_deskflow_core_pid"])+",") not in tcp: die("failed successor TCP listener differs")
    sidecar=sidecar_live(started["main_pid"])
    acceptance=(Path("/run/user/1000/deskflow/viewflow-acceptance.sock"),Path("/run/user/1000/viewflow/deskflow-acceptance.sock"),Path("/run/user/1000/viewflow/post-release-acceptance.sock"))
    if any(os.path.lexists(p) for p in acceptance): die("failed successor acceptance socket exists")
    if os.path.lexists(STATE/"deskflow-quarantine.v2") or os.path.lexists(STATE/"deployment-quarantine.v1"): die("failed successor VFQST/VFDQT marker exists")
    for unit in ("deskflow.service","viewflow-peer.service"):
        if sysprop(unit,"ActiveState")!="inactive" or sysprop(unit,"MainPID")!="0" or sysprop(unit,"ControlGroup"): die("persistent unit is not inactive")
    wl_copy=exact_pids("/usr/bin/wl-copy")
    if wl_copy: die("current wl-copy process remains present")
    log=stable_deskflow_log_slice()
    if log["legacy_route_outcome"]!="returned-local": die("failed successor log is not a complete returned-local cycle")
    census={
        # This retired transient is deliberately not an installed-path
        # Viewflow process.  Count only its exact, receipt-bound memfd name;
        # persistent-service adoption remains exclusively installed-path.
        "transient_viewflow_memfd_exact_process_count":len(transient_viewflow_pids()),
        "deskflow_runtime_exact_process_count":len(exact_pids(transition["linux_deskflow_runtime_path"])),
        "deskflow_core_exact_process_count":len(exact_pids(transition["linux_deskflow_core_runtime_path"])),
    }
    return {
        "viewflow":{"unit":started["unit"],"pid":started["main_pid"],"start_ticks":started["start_ticks"],"invocation_id":started["invocation_id"],"control_group":started["control_group"],**viewflow_evidence},
        "deskflow":{"unit":transition["linux_deskflow_unit"],"main_pid":transition["linux_deskflow_main_pid"],"main_start_ticks":transition["linux_deskflow_main_start_ticks"],"runtime_pid":transition["linux_deskflow_runtime_pid"],"runtime_start_ticks":transition["linux_deskflow_runtime_start_ticks"],"core_pid":transition["linux_deskflow_core_pid"],"core_start_ticks":transition["linux_deskflow_core_start_ticks"],"invocation_id":transition["linux_deskflow_invocation_id"],"control_group":transition["linux_deskflow_control_group"]},
        "listeners":{"udp_44119":{"count":1,"owner_pid":started["main_pid"],"sha256":digest(udp.encode())},"tcp_24800":{"count":1,"owner_pid":transition["linux_deskflow_core_pid"],"sha256":digest(tcp.encode())}},
        "sidecar":sidecar,"acceptance_sockets":{"deskflow":False,"viewflow":False,"post_release":False},"markers":{"vfqst":False,"vfdqt":False},"persistent_units":{"deskflow":False,"viewflow":False},"systemd_preimage_verified":systemd_preimage_verified,"deskflow_log":log,
        "auxiliary_process_absence":{"current_exact_wl_copy_process_count":0,"current_relevant_process_census":census,"historical_auxiliary_process_actions_not_durably_attested":True},
    }

def failed_closure(live):
    return {"schema_version":1,"state":"viewflow-c9-recovery-v2-failed-successor-closed","error":"deleted-runtime-path-suffix-unhandled","failed_operation_id":FAILED,"old_operation_id":OLD,"failed_coordinator_instance_id":FAILED_COORD,"failed_bridge_root":str(FAILED_ROOT),"failed_fresh_root":str(FAILED_FRESH),"failed_candidate_root":str(FAILED_CANDIDATE),"failed_manifest_sha256":FAILED_MANIFEST_SHA,"failed_approval_sha256":FAILED_APPROVAL_SHA,"failed_systemd_preimage_sha256":FAILED_SYSTEMD_PREIMAGE_SHA,"failed_lifecycle_sha256":FAILED_LIFECYCLE_SHA,"closure_lifecycle_sha256":lifecycle_sha256(),"publication_method":"create-once-no-replace-and-parent-fsync","fresh_root_empty":True,"candidate_absent":True,"live":live}

def validate_failed_closure(v,sha,include_closure=True):
    expected={"schema_version","state","error","failed_operation_id","old_operation_id","failed_coordinator_instance_id","failed_bridge_root","failed_fresh_root","failed_candidate_root","failed_manifest_sha256","failed_approval_sha256","failed_systemd_preimage_sha256","failed_lifecycle_sha256","closure_lifecycle_sha256","publication_method","fresh_root_empty","candidate_absent","live"}
    if set(v)!=expected or any(v.get(k)!=x for k,x in {"schema_version":1,"state":"viewflow-c9-recovery-v2-failed-successor-closed","error":"deleted-runtime-path-suffix-unhandled","failed_operation_id":FAILED,"old_operation_id":OLD,"failed_coordinator_instance_id":FAILED_COORD,"failed_bridge_root":str(FAILED_ROOT),"failed_fresh_root":str(FAILED_FRESH),"failed_candidate_root":str(FAILED_CANDIDATE),"failed_manifest_sha256":FAILED_MANIFEST_SHA,"failed_approval_sha256":FAILED_APPROVAL_SHA,"failed_systemd_preimage_sha256":FAILED_SYSTEMD_PREIMAGE_SHA,"failed_lifecycle_sha256":FAILED_LIFECYCLE_SHA,"closure_lifecycle_sha256":lifecycle_sha256(),"publication_method":"create-once-no-replace-and-parent-fsync","fresh_root_empty":True,"candidate_absent":True}.items()) or not SHA.fullmatch(sha): die("failed successor closure identity differs")
    live=v.get("live")
    if type(live) is not dict or set(live)!={"viewflow","deskflow","listeners","sidecar","acceptance_sockets","markers","persistent_units","systemd_preimage_verified","deskflow_log","auxiliary_process_absence"}: die("failed successor closure live keyset differs")
    sources,docs=failed_inputs(include_closure)
    started=docs["linux_v13_started"]; transition=docs["transition"]
    expected_view={"unit":started["unit"],"pid":2628788,"start_ticks":6353894,"invocation_id":"b58c1b47e9e44e0db9237dd2054471ed","control_group":started["control_group"],"runtime_executable":TRANSIENT_VIEWFLOW_MEMFD,"runtime_sha256":started["viewflowd_sha256"],"exec_start_sha256":started["exec_start_sha256"],"fd_gate_payload_sha256":started["fd_gate_payload_sha256"]}
    expected_desk={"unit":transition["linux_deskflow_unit"],"main_pid":2641607,"main_start_ticks":6355585,"runtime_pid":2641625,"runtime_start_ticks":6355588,"core_pid":2641700,"core_start_ticks":6355614,"invocation_id":"57ec0e3c566c4c6391e1a4fbbec243dd","control_group":transition["linux_deskflow_control_group"]}
    view=live.get("viewflow",{})
    if set(view)!=(set(expected_view)|{"argv_sha256"}) or any(view.get(k)!=x for k,x in expected_view.items()) or not SHA.fullmatch(view.get("argv_sha256","")) or live.get("deskflow")!=expected_desk: die("failed successor closure process identity differs")
    current_census={"transient_viewflow_memfd_exact_process_count":1,"deskflow_runtime_exact_process_count":1,"deskflow_core_exact_process_count":1}
    if live.get("listeners",{}).get("udp_44119",{}).get("count")!=1 or live.get("listeners",{}).get("udp_44119",{}).get("owner_pid")!=2628788 or live.get("listeners",{}).get("tcp_24800",{}).get("count")!=1 or live.get("listeners",{}).get("tcp_24800",{}).get("owner_pid")!=2641700 or live.get("sidecar",{}).get("path")!="/run/user/1000/viewflow/deskflow.sock" or live.get("sidecar",{}).get("owner_pid")!=2628788 or live.get("acceptance_sockets")!={"deskflow":False,"viewflow":False,"post_release":False} or live.get("markers")!={"vfqst":False,"vfdqt":False} or live.get("persistent_units")!={"deskflow":False,"viewflow":False} or live.get("systemd_preimage_verified")!={"deskflow":True,"recovery_deskflow":True,"viewflow":True} or live.get("deskflow_log",{}).get("legacy_route_outcome")!="returned-local" or live.get("auxiliary_process_absence")!={"current_exact_wl_copy_process_count":0,"current_relevant_process_census":current_census,"historical_auxiliary_process_actions_not_durably_attested":True}: die("failed successor closure live binding differs")
    if not all(SHA.fullmatch(live["listeners"][k].get("sha256","")) for k in ("udp_44119","tcp_24800")) or set(live.get("sidecar",{}))!={"path","inode","owner_pid","listener_count"} or type(live["sidecar"].get("inode")) is not int or live["sidecar"]["inode"]<=0 or live["sidecar"].get("listener_count")!=1: die("failed successor closure listener hash differs")
    log=live["deskflow_log"]
    if set(log)!={"dev","ino","size","mtime_ns","sha256","startup_anchor_offset","legacy_route_outcome","route_event_sequence"} or not all(type(log.get(k)) is int and log[k]>=0 for k in ("dev","ino","size","mtime_ns","startup_anchor_offset")) or not SHA.fullmatch(log.get("sha256","")) or type(log.get("route_event_sequence")) is not list or log["route_event_sequence"][-5:]!=["sidecar-active","switch-to-remote","leaving-local","switch-to-local","entered-local"]: die("failed successor closure log binding differs")
    # A new plan must not merely trust the receipt's claim: the immutable old
    # bridge leaves are reopened under their fixed hashes and the old candidate
    # and empty failed fresh root are rechecked.
    require_dir(FAILED_FRESH,"failed successor fresh root")
    if any(FAILED_FRESH.iterdir()) or os.path.lexists(FAILED_CANDIDATE): die("failed successor closure boundary changed")

def read_manifest(a):
    if not SHA.fullmatch(a.manifest_sha256): die("manifest SHA is required")
    v=stable(a.manifest,a.manifest_sha256,0o600,"manifest",True);docs=validate_plan(v,a.manifest_sha256)
    return v,docs
def approval(plan,msha,when):
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z",when): die("approval timestamp differs")
    return {"schema_version":1,"state":"viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-execution-approved","approved":True,"manifest_sha256":msha,"lifecycle_sha256":lifecycle_sha256(),"old_operation_id":OLD,"new_operation_id":NEW,"new_coordinator_instance_id":COORD,"approved_at_utc":when,"publication_method":"create-once-no-replace-and-parent-fsync"}
def validate_approval(plan,msha,raw,expected):
    v=strict(raw,"approval")
    if canonical(v)!=raw or v!=approval(plan,msha,v.get("approved_at_utc","")) or digest(raw)!=expected: die("execution approval differs")

def cmd(argv,timeout=90):
    r=subprocess.run(argv,env=ENV,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if r.returncode: die("command failed: "+" ".join(argv[:3]))
    return r.stdout.decode("utf-8","strict")
def sysprop(unit,key): return cmd(["/usr/bin/systemctl","--user","show","--property",key,"--value",unit]).strip()
def systemd_record(unit):
    # Record the exact effective source before any stop/start.  This bridge
    # never edits a mask or drop-in: a changed effective configuration makes a
    # resume fail rather than silently restoring a guessed unit file.
    return {"fragment_path":sysprop(unit,"FragmentPath"),"dropin_paths":sysprop(unit,"DropInPaths"),"unit_file_state":sysprop(unit,"UnitFileState"),"unit_cat_sha256":digest(cmd(["/usr/bin/systemctl","--user","cat",unit]).encode())}
def assert_systemd_record(unit,record):
    if systemd_record(unit)!=record: die("systemd mask/drop-in preimage changed")
def ticks(pid):
    data=Path("/proc")/str(pid)/"stat"; raw=data.read_text(); return int(raw[raw.rfind(") ")+2:].split()[19])
def process_executable(pid,expected_ticks):
    """Return (resolved-path, sha256) only if one process lifetime owns it."""
    if ticks(pid)!=expected_ticks: die("process changed before executable read")
    link=f"/proc/{pid}/exe"; resolved=os.path.realpath(link)
    fd=os.open(link,os.O_RDONLY|os.O_CLOEXEC)
    try:
        value=digest(read_fd_to_eof(fd))
    finally: os.close(fd)
    if ticks(pid)!=expected_ticks or os.path.realpath(link)!=resolved: die("process changed while executable read")
    return resolved,value
def exact_pids(exe):
    out=[]
    for p in Path("/proc").glob("[0-9]*"):
        try:
            if os.path.realpath(p/"exe") in (exe,exe+" (deleted)"): out.append(int(p.name))
        except OSError: pass
    return out
def process_argv(pid,expected_ticks):
    path=f"/proc/{pid}/cmdline"
    if ticks(pid)!=expected_ticks: die("process changed before argv read")
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try: raw=read_fd_to_eof(fd)
    finally: os.close(fd)
    if ticks(pid)!=expected_ticks or not raw.endswith(b"\0"): die("process changed while argv read")
    return raw.rstrip(b"\0").split(b"\0")
def transient_viewflow_pids():
    out=[]
    for p in Path("/proc").glob("[0-9]*"):
        try:
            if os.path.realpath(p/"exe")==TRANSIENT_VIEWFLOW_MEMFD: out.append(int(p.name))
        except OSError: pass
    return out
def transient_viewflow_argv(argv):
    if argv!=list(EXPECTED_VIEWFLOW_V13_ARGV): die("transient Viewflow final v1.3 argv differs")
    return digest(b"\0".join(argv)+b"\0")
def observed_exec_start_sha256(unit):
    """Hash systemd's canonical ExecStart tuple, as the v1.3 handoff does."""
    object_response=strict(cmd(["/usr/bin/busctl","--user","--json=short","call","org.freedesktop.systemd1","/org/freedesktop/systemd1","org.freedesktop.systemd1.Manager","GetUnit","s",unit]).encode(),"systemd GetUnit response")
    if object_response.get("type")!="o" or type(object_response.get("data")) is not list or len(object_response["data"])!=1 or type(object_response["data"][0]) is not str: die("systemd GetUnit response differs")
    property_response=strict(cmd(["/usr/bin/busctl","--user","--json=short","get-property","org.freedesktop.systemd1",object_response["data"][0],"org.freedesktop.systemd1.Service","ExecStart"]).encode(),"systemd ExecStart response")
    if property_response.get("type")!="a(sasbttttuii)" or type(property_response.get("data")) is not list or len(property_response["data"])!=1: die("systemd ExecStart response differs")
    value=property_response["data"][0]
    if type(value) is not list or len(value)!=10 or type(value[0]) is not str or type(value[1]) is not list or type(value[2]) is not bool: die("systemd ExecStart tuple differs")
    return digest(json.dumps({"argv":value[1],"ignore_errors":value[2],"path":value[0]},sort_keys=True,separators=(",",":"),ensure_ascii=False).encode("utf-8"))
def transient_viewflow_exec_start(started):
    observed=observed_exec_start_sha256(started["unit"])
    if observed!=started["exec_start_sha256"] or observed!=started["expected_exec_start_sha256"]: die("transient Viewflow fd-gate ExecStart binding differs")
    return observed
def transient_deskflow_exec_start(transition):
    observed=observed_exec_start_sha256(transition["linux_deskflow_unit"])
    if observed!=transition["linux_deskflow_exec_start_sha256"] or observed!=transition["linux_deskflow_expected_exec_start_sha256"]: die("transient Deskflow ExecStart binding differs")
    return observed
def transient_viewflow_census(started):
    pid=started["main_pid"]
    if transient_viewflow_pids()!=[pid]: die("transient Viewflow memfd census differs")
    runtime,executable_sha=process_executable(pid,started["start_ticks"])
    if runtime!=TRANSIENT_VIEWFLOW_MEMFD or executable_sha!=started["viewflowd_sha256"]: die("transient Viewflow memfd/executable binding differs")
    argv_sha256=transient_viewflow_argv(process_argv(pid,started["start_ticks"]))
    exec_start_sha256=transient_viewflow_exec_start(started)
    return {"runtime_executable":runtime,"runtime_sha256":executable_sha,"argv_sha256":argv_sha256,"exec_start_sha256":exec_start_sha256,"fd_gate_payload_sha256":started["fd_gate_payload_sha256"]}
def listener_count(argv): return len([x for x in cmd(argv).splitlines() if x.strip()])
def deskflow_live(t):
    unit=t["linux_deskflow_unit"]
    if not(sysprop(unit,"ActiveState")=="active" and sysprop(unit,"MainPID")==str(t["linux_deskflow_main_pid"]) and sysprop(unit,"InvocationID")==t["linux_deskflow_invocation_id"] and sysprop(unit,"ControlGroup")==t["linux_deskflow_control_group"]): die("transient Deskflow systemd tuple differs")
    transient_deskflow_exec_start(t)
    triples=(("linux_deskflow_main_pid","linux_deskflow_main_start_ticks",None,"bubblewrap_sha256"),("linux_deskflow_runtime_pid","linux_deskflow_runtime_start_ticks","linux_deskflow_runtime_path","linux_deskflow_executable_sha256"),("linux_deskflow_core_pid","linux_deskflow_core_start_ticks","linux_deskflow_core_runtime_path","linux_deskflow_core_executable_sha256"))
    seen=[]
    for pk,tk,pathk,hashk in triples:
        pid=t[pk]
        path,executable_sha=process_executable(pid,t[tk])
        if executable_sha!=t[hashk]: die("transient Deskflow PID/start/executable tuple differs")
        if pathk and path not in (t[pathk],t[pathk]+" (deleted)"): die("transient Deskflow runtime path differs")
        seen.append(str(pid))
    cg=Path("/sys/fs/cgroup"+t["linux_deskflow_control_group"]+"/cgroup.procs")
    if not cg.is_file() or sorted(cg.read_text().split())!=sorted(seen): die("transient Deskflow cgroup membership differs")
def viewflow_live(started,viewflow):
    vu=started["unit"]; vp=started["main_pid"]
    evidence=transient_viewflow_census(started)
    vfcg=Path("/sys/fs/cgroup"+started["control_group"]+"/cgroup.procs")
    if not(sysprop(vu,"ActiveState")=="active" and sysprop(vu,"MainPID")==str(vp) and sysprop(vu,"InvocationID")==started["invocation_id"] and sysprop(vu,"ControlGroup")==started["control_group"] and vfcg.is_file() and vfcg.read_text().split()==[str(vp)]): die("transient Viewflow PID/start/cgroup tuple differs")
    return evidence
def transient_live(t,started,viewflow):
    deskflow_live(t); viewflow_live(started,viewflow)
def frozen_viewflow_network(started):
    """While Deskflow is frozen, bind the live UDP owner and lack of a core peer."""
    pid=started["main_pid"]
    listener=cmd(["/usr/bin/ss","-H","-lunp","sport = :44119"])
    established=cmd(["/usr/bin/ss","-H","-tnp","state","established","( sport = :44119 or dport = :44119 )"])
    lines=[x for x in listener.splitlines() if x.strip()]
    if len(lines)!=1 or str(pid) not in lines[0] or established.strip(): die("frozen Viewflow socket ownership/peer state differs")
    return {"udp_44119_listener_count":1,"listener_sha256":digest(listener.encode()),"owner_pid":pid,"established_peer_count":0,"established_sha256":digest(established.encode())}
def viewflow_zero(viewflow):
    established=cmd(["/usr/bin/ss","-H","-tnp","state","established","( sport = :44119 or dport = :44119 )"])
    if exact_pids(viewflow) or transient_viewflow_pids() or listener_count(["/usr/bin/ss","-H","-lun","sport = :44119"]) or established.strip(): die("Viewflow boundary is not zero")
def deskflow_zero(t):
    unit=t["linux_deskflow_unit"]
    if (sysprop(unit,"MainPID")!="0" or sysprop(unit,"ControlGroup") or exact_pids(t["linux_deskflow_runtime_path"]) or exact_pids(t["linux_deskflow_core_runtime_path"]) or listener_count(["/usr/bin/ss","-H","-ltn","sport = :24800"])): die("Deskflow boundary is not zero")
def zero(t,viewflow):
    deskflow_zero(t)
    viewflow_zero(viewflow)
    if os.path.lexists(STATE/"deskflow-quarantine.v2"): die("VFQST runtime marker exists")
def stable_deskflow_log_slice(path="/home/wilf/deskflow.log"):
    """Stable-FD current-core slice; rotation/truncation is an uncertainty."""
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd); named=os.stat(path,follow_symlinks=False)
        if not(stat.S_ISREG(before.st_mode) and before.st_uid==UID and before.st_nlink==1 and ident(before)==ident(named)): die("Deskflow log metadata differs")
        raw=os.read(fd,before.st_size+1); after=os.fstat(fd); named_after=os.stat(path,follow_symlinks=False)
        if len(raw)!=before.st_size or ident(before)!=ident(after) or ident(after)!=ident(named_after): die("Deskflow log rotated/truncated/changed while read")
    finally: os.close(fd)
    text=raw.decode("utf-8","strict"); anchor="IPC: started server, waiting for clients"; offset=text.rfind(anchor)
    if offset<0 or text.count(anchor,offset)!=1: die("Deskflow current-core startup anchor is not unique")
    interval=text[offset:]
    events=(
        ("sidecar-active",'Viewflow sidecar active for Deskflow screen "WindowsVM"'),
        ("switch-to-remote",'switch from "SuperPower" to "WindowsVM"'),
        ("leaving-local","leaving screen"),
        ("switch-to-local",'switch from "WindowsVM" to "SuperPower"'),
        ("entered-local","entering screen"),
    )
    observed=[]
    for name,needle in events:
        observed.extend((at,name) for at in positions(interval,needle))
    observed=[name for _,name in sorted(observed)]
    cycle=[x[0] for x in events]
    if not observed:
        outcome="never-left-local"
    elif len(observed)%len(cycle)==0 and observed==cycle*(len(observed)//len(cycle)):
        # The legacy Server return handler reaches this exact remote->local
        # switch only after its sidecar return is taken.  A final full cycle
        # therefore is evidence of the acknowledged, local pressed-state.
        outcome="returned-local"
    else:
        die("Deskflow current invocation has an unmatched Viewflow route event")
    return {"dev":before.st_dev,"ino":before.st_ino,"size":before.st_size,"mtime_ns":before.st_mtime_ns,"sha256":digest(raw),"startup_anchor_offset":offset,"legacy_route_outcome":outcome,"route_event_sequence":observed}
def positions(text,needle):
    at=0
    while True:
        at=text.find(needle,at)
        if at<0: return
        yield at; at+=len(needle)
def legacy_no_route_journal_counts(*streams):
    """Parse journal JSON; raw substring spelling is not a lease proof."""
    needles=("input sidecar activation","input event","lease_offered","lease_active","transport_confirmed=true","releaseall","lease revoke","runtime cleanup","return required")
    counts={x:0 for x in needles}
    for stream in streams:
        for line in stream.splitlines():
            try: item=json.loads(line)
            except Exception as e: raise Error("legacy journal JSON is malformed") from e
            msg=item.get("MESSAGE")
            if not isinstance(msg,str): die("legacy journal MESSAGE differs")
            msg=msg.lower()
            for x in needles: counts[x]+=msg.count(x)
    return counts
def verify_deskflow_log_slice(record):
    if stable_deskflow_log_slice()!=record: die("Deskflow log changed before retirement")
def core_environment_snapshot(t):
    pid=t["linux_deskflow_core_pid"]; fd=os.open("/proc/"+str(pid)+"/environ",os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        if ticks(pid)!=t["linux_deskflow_core_start_ticks"]: die("Deskflow core changed before environment read")
        before=os.fstat(fd); raw=read_fd_to_eof(fd); after=os.fstat(fd)
        # /proc/$pid/environ commonly reports st_size=0 even for a non-empty
        # environment.  The PID/start-ticks checks bind this descriptor to the
        # frozen core; no size-based pseudo-proof is accepted.
        if ident(before)!=ident(after) or ticks(pid)!=t["linux_deskflow_core_start_ticks"]: die("Deskflow core environment changed while read")
    finally: os.close(fd)
    vars={x.split(b"=",1)[0].decode("ascii","strict") for x in raw.rstrip(b"\0").split(b"\0") if x}
    # Audit only.  The installed legacy core's configuration semantics differ
    # from the pristine candidate source, so these variables cannot establish
    # route state.  The frozen log slice plus drained GUI pipes is decisive.
    return {"core_environment_sha256":digest(raw),"acceptance_socket_configured":"DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET" in vars,"quarantine_marker_configured":"DESKFLOW_VIEWFLOW_QUARANTINE_MARKER" in vars,"deployment_marker_configured":"DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER" in vars}
def frozen_core_log_pipes(t):
    """Bind core stdout/stderr pipes to GUI readers and prove no unread bytes."""
    core=t["linux_deskflow_core_pid"]; gui=t["linux_deskflow_runtime_pid"]
    if ticks(core)!=t["linux_deskflow_core_start_ticks"] or ticks(gui)!=t["linux_deskflow_runtime_start_ticks"]: die("frozen Deskflow pipe owner changed")
    result=[]
    for writer_fd in (1,2):
        writer=os.readlink(f"/proc/{core}/fd/{writer_fd}")
        if not re.fullmatch(r"pipe:\[[0-9]+\]",writer): die("Deskflow core stdout/stderr is not a pipe")
        readers=[]
        for candidate in Path(f"/proc/{gui}/fd").iterdir():
            try:
                if os.readlink(candidate)!=writer: continue
                fd=os.open(candidate,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC)
                try:
                    pending=array.array("i",[0]); fcntl.ioctl(fd,0x541B,pending,True) # FIONREAD
                    if pending[0]!=0: die("frozen Deskflow GUI log pipe has unread bytes")
                finally: os.close(fd)
                readers.append(int(candidate.name))
            except FileNotFoundError: die("Deskflow GUI FD changed during frozen pipe proof")
        if not readers: die("Deskflow core log pipe has no GUI reader")
        result.append({"writer_fd":writer_fd,"pipe":writer,"reader_fds":sorted(readers),"pending_bytes":0})
    if ticks(core)!=t["linux_deskflow_core_start_ticks"] or ticks(gui)!=t["linux_deskflow_runtime_start_ticks"]: die("frozen Deskflow pipe owner changed while read")
    return result
def freeze_transient_deskflow(t,started):
    unit=t["linux_deskflow_unit"]; cmd(["/usr/bin/systemctl","--user","freeze",unit])
    if sysprop(unit,"FreezerState")!="frozen": die("transient Deskflow freeze did not linearize")
    transient_live(t,started,"/home/wilf/.local/lib/viewflow/viewflowd")
    return frozen_core_log_pipes(t)
def cleanup_proof(t,started,path,msha):
    """No Deskflow stop before a status proof or durable ReleaseAll/revoke proof."""
    if os.path.lexists(path):
        v=generated(path,"sidecar cleanup proof")
        if v.get("manifest_sha256")!=msha or v.get("operation_id")!=NEW or v.get("state") not in ("viewflow-c9-recovery-v2-no-active-route","viewflow-c9-recovery-v2-release-all-applied","viewflow-c9-recovery-v2-legacy-frozen-no-active-route","viewflow-c9-recovery-v2-legacy-frozen-returned-local"): die("existing sidecar cleanup proof differs")
        if v["state"]=="viewflow-c9-recovery-v2-no-active-route":
            keys={"schema_version","state","operation_id","manifest_sha256","pressed_state","freezer_state","post_freeze_runtime_marker_present","acceptance_status","acceptance_status_sha256"}
            if set(v)!=keys or v["pressed_state"]!="no-active-route" or v["freezer_state"]!="frozen" or v["post_freeze_runtime_marker_present"] is not False or digest(canonical(v["acceptance_status"]))!=v["acceptance_status_sha256"]: die("existing no-active-route proof differs")
        if v["state"]=="viewflow-c9-recovery-v2-release-all-applied":
            keys={"schema_version","state","operation_id","manifest_sha256","pressed_state","freezer_state","post_freeze_runtime_marker_present","cleanup_receipt","cleanup_receipt_sha256"}
            if set(v)!=keys or v["pressed_state"]!="released" or v["freezer_state"]!="frozen" or v["post_freeze_runtime_marker_present"] is not False or digest(canonical(v["cleanup_receipt"]))!=v["cleanup_receipt_sha256"]: die("existing ReleaseAll proof differs")
        if sysprop(t["linux_deskflow_unit"],"FreezerState")!="frozen": die("cleanup proof lost its frozen linearization")
        if v["state"] in ("viewflow-c9-recovery-v2-legacy-frozen-no-active-route","viewflow-c9-recovery-v2-legacy-frozen-returned-local"):
            keys={"schema_version","state","operation_id","manifest_sha256","pressed_state","runtime_marker_present","acceptance_sockets","freezer_state","core_environment","core_log_pipes","deskflow_log","deskflow","viewflow","viewflow_network","deskflow_journal_sha256","viewflow_journal_sha256","forbidden_event_counts"}
            desk={"unit":t["linux_deskflow_unit"],"invocation_id":t["linux_deskflow_invocation_id"],"main_pid":t["linux_deskflow_main_pid"],"main_start_ticks":t["linux_deskflow_main_start_ticks"],"control_group":t["linux_deskflow_control_group"],"core_pid":t["linux_deskflow_core_pid"],"core_start_ticks":t["linux_deskflow_core_start_ticks"]}
            view={"unit":started["unit"],"invocation_id":started["invocation_id"],"main_pid":started["main_pid"],"start_ticks":started["start_ticks"],"control_group":started["control_group"]}
            want_outcome="never-left-local" if v["state"].endswith("no-active-route") else "returned-local"
            want_pressed="no-active-route" if want_outcome=="never-left-local" else "released"
            if set(v)!=keys or v["pressed_state"]!=want_pressed or v["runtime_marker_present"] is not False or v["acceptance_sockets"]!={"deskflow":False,"viewflow":False} or v["freezer_state"]!="frozen" or any(v["forbidden_event_counts"].values()) or not all(SHA.fullmatch(v[k]) for k in ("deskflow_journal_sha256","viewflow_journal_sha256")) or not isinstance(v["deskflow"],dict) or not isinstance(v["viewflow"],dict) or not isinstance(v["viewflow_network"],dict) or any(v["deskflow"].get(k)!=x for k,x in desk.items()) or any(v["viewflow"].get(k)!=x for k,x in view.items()) or v["deskflow"].get("boot_id")!=v["viewflow"].get("boot_id") or not UUID.fullmatch(v["deskflow"].get("boot_id","")) or v["deskflow_log"].get("legacy_route_outcome")!=want_outcome or v["viewflow_network"]!={"udp_44119_listener_count":1,"listener_sha256":v["viewflow_network"].get("listener_sha256"),"owner_pid":started["main_pid"],"established_peer_count":0,"established_sha256":v["viewflow_network"].get("established_sha256")} or not SHA.fullmatch(v["viewflow_network"].get("listener_sha256","")) or not SHA.fullmatch(v["viewflow_network"].get("established_sha256","")): die("legacy frozen route proof differs")
            if sysprop(t["linux_deskflow_unit"],"FreezerState")!="frozen": die("frozen cleanup proof lost its linearization")
            if core_environment_snapshot(t)!=v["core_environment"]: die("frozen core environment proof changed")
            verify_deskflow_log_slice(v["deskflow_log"])
            if frozen_core_log_pipes(t)!=v["core_log_pipes"]: die("frozen core log pipe proof changed")
            if frozen_viewflow_network(started)!=v["viewflow_network"]: die("frozen Viewflow socket proof changed")
        if os.path.lexists(STATE/"deskflow-quarantine.v2"): die("VFQST remains after cleanup proof")
        return
    exe="/proc/"+str(t["linux_deskflow_core_pid"])+"/exe"; env=dict(ENV);env["DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET"]="/run/user/1000/deskflow/viewflow-acceptance.sock"
    socket_a=Path("/run/user/1000/deskflow/viewflow-acceptance.sock");socket_b=Path("/run/user/1000/viewflow/deskflow-acceptance.sock")
    if not os.path.lexists(socket_a) and not os.path.lexists(socket_b):
        # Freeze is the proof-to-stop linearization point.  Do not read a
        # moving legacy core and then stop it: it can switch screens between.
        pipes=freeze_transient_deskflow(t,started)
        # Socket absence alone is never a cleanup decision.  Recheck it after
        # the linearizing freeze, then use the frozen core's log slice,
        # drained GUI log pipes, and both journal intervals.
        if os.path.lexists(socket_a) or os.path.lexists(socket_b): die("acceptance socket appeared before frozen no-route proof")
        log=stable_deskflow_log_slice()
        core_env=core_environment_snapshot(t)
        network=frozen_viewflow_network(started)
        desk_j=cmd(["/usr/bin/journalctl","--user","--quiet","--no-pager","--output=json","_SYSTEMD_INVOCATION_ID="+t["linux_deskflow_invocation_id"]])
        # The Viewflow invocation comes from the pinned v1.3 started receipt,
        # not a PID lookup that could have been recycled.
        # It is supplied below through the closure-free read of the receipt.
        view_j=cmd(["/usr/bin/journalctl","--user","--quiet","--no-pager","--output=json","_SYSTEMD_INVOCATION_ID="+started["invocation_id"]])
        # A never-routed core must not have emitted any route activity.  Once
        # the frozen Deskflow log proves a complete returned-local cycle, the
        # older Viewflow journal's lease-offered/active records are expected
        # historical evidence, not outstanding pressed state.  The exact
        # Server return sequence and drained pipes are decisive in that mode.
        outcome=log["legacy_route_outcome"]
        counts=legacy_no_route_journal_counts(desk_j,view_j) if outcome=="never-left-local" else {}
        if any(counts.values()) or os.path.lexists(STATE/"deskflow-quarantine.v2"): die("legacy journal does not prove pressed-state zero")
        # The process is frozen, so this closes proof-to-stop races.  The
        # frozen log slice excludes both sidecar activation and ordinary
        # fallback to WindowsVM during this invocation; pipe drain proves no
        # core event is still waiting in the GUI reader.
        verify_deskflow_log_slice(log)
        if sysprop(t["linux_deskflow_unit"],"FreezerState")!="frozen": die("Deskflow thawed before no-route proof publication")
        boot=Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        if frozen_core_log_pipes(t)!=pipes: die("frozen core log pipe changed before proof publication")
        state={"never-left-local":"viewflow-c9-recovery-v2-legacy-frozen-no-active-route","returned-local":"viewflow-c9-recovery-v2-legacy-frozen-returned-local"}[outcome]
        pressed={"never-left-local":"no-active-route","returned-local":"released"}[outcome]
        create_once(path,canonical({"schema_version":1,"state":state,"operation_id":NEW,"manifest_sha256":msha,"pressed_state":pressed,"runtime_marker_present":False,"acceptance_sockets":{"deskflow":False,"viewflow":False},"freezer_state":"frozen","core_environment":core_env,"core_log_pipes":pipes,"deskflow_log":log,"deskflow":{"unit":t["linux_deskflow_unit"],"invocation_id":t["linux_deskflow_invocation_id"],"main_pid":t["linux_deskflow_main_pid"],"main_start_ticks":t["linux_deskflow_main_start_ticks"],"control_group":t["linux_deskflow_control_group"],"core_pid":t["linux_deskflow_core_pid"],"core_start_ticks":t["linux_deskflow_core_start_ticks"],"boot_id":boot},"viewflow":{"unit":started["unit"],"invocation_id":started["invocation_id"],"main_pid":started["main_pid"],"start_ticks":started["start_ticks"],"control_group":started["control_group"],"boot_id":boot},"viewflow_network":network,"deskflow_journal_sha256":digest(desk_j.encode()),"viewflow_journal_sha256":digest(view_j.encode()),"forbidden_event_counts":counts}))
        return
    def call(args,timeout=30):
        r=subprocess.run([exe,"--viewflow-acceptance-query",*args],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
        if r.returncode or r.stderr: die("sidecar acceptance query failed")
        return strict(r.stdout,"sidecar acceptance result")
    status=call(["status"])
    expected={"schema_version":1,"state":"deskflow-live-acceptance-status","protocol_version":"2.1","sidecar_protocol_version":3,"sidecar_configured":True,"core_pid":t["linux_deskflow_core_pid"],"core_start_ticks":t["linux_deskflow_core_start_ticks"],"runtime_marker_path":str(STATE/"deskflow-quarantine.v2"),"receipt_available":False}
    if any(status.get(k)!=v for k,v in expected.items()) or set(status)!={"core_boot_id","core_pid","core_start_ticks","protocol_version","receipt_available","runtime_marker_path","runtime_marker_present","schema_version","sidecar_configured","sidecar_protocol_version","state"}: die("sidecar status proof differs")
    if status["runtime_marker_present"] is False:
        # Freeze immediately after the status observation.  A post-status
        # route must materialize VFQST; otherwise proof-to-stop would race.
        freeze_transient_deskflow(t,started)
        if os.path.lexists(STATE/"deskflow-quarantine.v2"): die("sidecar route appeared before freeze")
        create_once(path,canonical({"schema_version":1,"state":"viewflow-c9-recovery-v2-no-active-route","operation_id":NEW,"manifest_sha256":msha,"pressed_state":"no-active-route","freezer_state":"frozen","post_freeze_runtime_marker_present":False,"acceptance_status":status,"acceptance_status_sha256":digest(canonical(status))}))
        return
    arm=["arm","--coordinator-operation-id",NEW,"--source-display-id","00000000000000000000000000000101","--target-device-id","00000000000000000000000000000002","--deployment-marker-sha256",t["deployment_marker_sha256"]]
    armed=call(arm)
    if armed!={"schema_version":1,"state":"viewflow-acceptance-armed","armed":True}: die("sidecar cleanup arm differs")
    deadline=time.monotonic()+300; receipt=None
    while time.monotonic()<deadline:
        try: receipt=call(["cleanup",*arm[1:]],timeout=5);break
        except (Error,subprocess.TimeoutExpired): time.sleep(.1)
    if receipt is None: die("ReleaseAll/revoke cleanup timed out")
    required={"schema_version":1,"state":"deskflow-runtime-cleanup-evidence","protocol_version":"2.1","sidecar_protocol_version":3,"cleanup_complete_mode":"normal","cleanup_complete_body_size":277,"coordinator_operation_id":NEW,"core_pid":t["linux_deskflow_core_pid"],"core_start_ticks":t["linux_deskflow_core_start_ticks"],"deployment_marker_bound":True,"deployment_marker_sha256":t["deployment_marker_sha256"],"acknowledged":True,"runtime_marker_released":True,"runtime_marker_magic":"VFQST002","runtime_marker_size":152,"tombstone_magic":"VFACK001","tombstone_size":72}
    if any(receipt.get(k)!=v for k,v in required.items()): die("ReleaseAll Applied cleanup receipt differs")
    freeze_transient_deskflow(t,started)
    if os.path.lexists(STATE/"deskflow-quarantine.v2"): die("VFQST reappeared before frozen retirement")
    create_once(path,canonical({"schema_version":1,"state":"viewflow-c9-recovery-v2-release-all-applied","operation_id":NEW,"manifest_sha256":msha,"pressed_state":"released","freezer_state":"frozen","post_freeze_runtime_marker_present":False,"cleanup_receipt":receipt,"cleanup_receipt_sha256":digest(canonical(receipt))}))
    if os.path.lexists(STATE/"deskflow-quarantine.v2"): die("VFQST remains after ReleaseAll/revoke")

def execute(plan,msha,docs):
    s=plan["sources"];o=plan["outputs"]; transient=docs["linux_v13_started"]; transition=docs["transition"]
    unit=transient["unit"]; pid=int(transient["main_pid"]); start=int(transient["start_ticks"])
    preimage=Path(o["systemd_preimage"]); intent=Path(o["retire_intent"]); retired=Path(o["retired"])
    if not preimage.exists():
        create_once(preimage,canonical({"schema_version":1,"state":"viewflow-c9-recovery-v2-systemd-mask-dropin-preimage","manifest_sha256":msha,"deskflow":systemd_record("deskflow.service"),"recovery_deskflow":systemd_record(transition["linux_deskflow_unit"]),"viewflow":systemd_record("viewflow-peer.service")}))
    pre=generated(preimage,"systemd preimage")
    if pre.get("manifest_sha256")!=msha or pre.get("state")!="viewflow-c9-recovery-v2-systemd-mask-dropin-preimage": die("systemd preimage differs")
    assert_systemd_record("deskflow.service",pre["deskflow"]); assert_systemd_record(transition["linux_deskflow_unit"],pre["recovery_deskflow"]); assert_systemd_record("viewflow-peer.service",pre["viewflow"])
    if not intent.exists():
        transient_live(transition,transient,s["viewflow"]["path"])
        cleanup_proof(transition,transient,o["cleanup_proof"],msha)
        proof=generated(o["cleanup_proof"],"sidecar cleanup proof")
        legacy=proof["state"] in ("viewflow-c9-recovery-v2-legacy-frozen-no-active-route","viewflow-c9-recovery-v2-legacy-frozen-returned-local")
        order=["viewflow","deskflow"] if legacy else ["deskflow","viewflow"]
        create_once(intent,canonical({"schema_version":1,"state":"viewflow-c9-recovery-v2-retire-intent","manifest_sha256":msha,"cleanup_proof_sha256":sha_file(o["cleanup_proof"]),"old_operation_id":OLD,"new_operation_id":NEW,"order":order,"deskflow_unit":transition["linux_deskflow_unit"],"deskflow_main_pid":transition["linux_deskflow_main_pid"],"deskflow_main_start_ticks":transition["linux_deskflow_main_start_ticks"],"transient_unit":unit,"transient_main_pid":pid,"transient_start_ticks":start}))
    if not retired.exists():
        iv=generated(intent,"retire intent")
        expected={"schema_version":1,"state":"viewflow-c9-recovery-v2-retire-intent","manifest_sha256":msha,"cleanup_proof_sha256":sha_file(o["cleanup_proof"]),"old_operation_id":OLD,"new_operation_id":NEW,"deskflow_unit":transition["linux_deskflow_unit"],"deskflow_main_pid":transition["linux_deskflow_main_pid"],"deskflow_main_start_ticks":transition["linux_deskflow_main_start_ticks"],"transient_unit":unit,"transient_main_pid":pid,"transient_start_ticks":start}
        proof=generated(o["cleanup_proof"],"sidecar cleanup proof")
        legacy=proof["state"] in ("viewflow-c9-recovery-v2-legacy-frozen-no-active-route","viewflow-c9-recovery-v2-legacy-frozen-returned-local")
        expected_order=["viewflow","deskflow"] if legacy else ["deskflow","viewflow"]
        if set(iv)!=(set(expected)|{"order"}) or any(iv[k]!=v for k,v in expected.items()) or iv["order"]!=expected_order: die("retire intent/order cleanup-proof binding differs")
        def target_zero(name):
            return viewflow_zero(s["viewflow"]["path"]) if name=="viewflow" else deskflow_zero(transition)
        def target_live(name):
            return viewflow_live(transient,s["viewflow"]["path"]) if name=="viewflow" else deskflow_live(transition)
        def target_unit(name): return unit if name=="viewflow" else transition["linux_deskflow_unit"]
        def complete_step(name,index):
            receipt=Path(o["retire_"+name])
            if receipt.exists():
                rv=generated(receipt,"retire "+name+" receipt")
                if rv!={"schema_version":1,"state":"viewflow-c9-recovery-v2-retire-step-complete","manifest_sha256":msha,"retire_intent_sha256":sha_file(intent),"step":name,"step_index":index,"unit":target_unit(name),"process_count":0}: die("retire "+name+" receipt differs")
                target_zero(name); return
            # Before the first stop the full frozen proof is rechecked.  A
            # post-stop crash has no receipt yet, but a true zero target is a
            # safe, durable reconstruction; never demand a vanished peer.
            active=sysprop(target_unit(name),"ActiveState")=="active"
            if index==0 and active:
                cleanup_proof(transition,transient,o["cleanup_proof"],msha)
            if index==0 and not active and name=="viewflow":
                # Crash after legacy Viewflow stop but before its receipt:
                # retain the frozen exact Deskflow identity, accept only a
                # complete Viewflow zero boundary, then reconstruct receipt.
                deskflow_live(transition)
                if sysprop(transition["linux_deskflow_unit"],"FreezerState")!="frozen": die("legacy Viewflow post-stop recovery lost frozen Deskflow")
            if active:
                target_live(name)
                cmd(["/usr/bin/systemctl","--user","stop",target_unit(name)])
            deadline=time.monotonic()+30
            while time.monotonic()<deadline:
                try: target_zero(name); break
                except Error: time.sleep(.1)
            target_zero(name)
            create_once(receipt,canonical({"schema_version":1,"state":"viewflow-c9-recovery-v2-retire-step-complete","manifest_sha256":msha,"retire_intent_sha256":sha_file(intent),"step":name,"step_index":index,"unit":target_unit(name),"process_count":0}))
        for index,name in enumerate(iv["order"]): complete_step(name,index)
        zero(transition,s["viewflow"]["path"])
        create_once(retired,canonical({"schema_version":1,"state":"viewflow-c9-recovery-v2-transient-retired","manifest_sha256":msha,"old_operation_id":OLD,"new_operation_id":NEW,"deskflow_process_count":0,"viewflow_process_count":0,"udp_44119_listener_count":0,"tcp_24800_listener_count":0,"runtime_marker_present":False}))
    rv=generated(retired,"retired receipt")
    if rv!={"schema_version":1,"state":"viewflow-c9-recovery-v2-transient-retired","manifest_sha256":msha,"old_operation_id":OLD,"new_operation_id":NEW,"deskflow_process_count":0,"viewflow_process_count":0,"udp_44119_listener_count":0,"tcp_24800_listener_count":0,"runtime_marker_present":False}: die("retired receipt differs")
    zero(transition,s["viewflow"]["path"])
    if not Path(o["persistent_intent"]).exists():
        create_once(o["persistent_intent"],canonical({"schema_version":1,"state":"viewflow-c9-recovery-v2-persistent-v13-start-intent","manifest_sha256":msha,"retired_sha256":sha_file(retired),"operation_id":NEW,"viewflowd_sha256":s["viewflow"]["sha256"],"unit_sha256":s["viewflow_unit"]["sha256"]}))
    if not Path(o["persistent_started"]).exists():
        if sha_file(s["viewflow"]["path"])!=s["viewflow"]["sha256"] or sha_file(s["viewflow_unit"]["path"])!=s["viewflow_unit"]["sha256"]: die("persistent installed bytes changed")
        cmd(["/usr/bin/systemctl","--user","daemon-reload"])
        state=sysprop("viewflow-peer.service","ActiveState")
        if state=="inactive": cmd(["/usr/bin/systemctl","--user","start","viewflow-peer.service"])
        elif state!="active": die("persistent unit is not safely adoptable")
        deadline=time.monotonic()+90; observed=None
        while time.monotonic()<deadline:
            p=sysprop("viewflow-peer.service","MainPID")
            if p.isdigit() and int(p)>0 and exact_pids(s["viewflow"]["path"])==[int(p)]: observed=int(p);break
            time.sleep(.1)
        if observed is None: die("persistent v1.3 did not start/adopt")
        # This must see a fresh authenticated peer; a merely-running local daemon is insufficient.
        inv=sysprop("viewflow-peer.service","InvocationID"); deadline=time.monotonic()+90; journal=""
        while time.monotonic()<deadline:
            journal=cmd(["/usr/bin/journalctl","--user","--quiet","--no-pager","--output=json","_SYSTEMD_INVOCATION_ID="+inv])
            if "viewflowd server authenticated peer 172.16.105.70:" in journal and "viewflowd server peer 172.16.105.70:" in journal: break
            time.sleep(.2)
        if "viewflowd server authenticated peer 172.16.105.70:" not in journal or "viewflowd server peer 172.16.105.70:" not in journal: die("persistent v1.3 lacks fresh authenticated Windows peer")
        create_once(o["persistent_started"],canonical({"schema_version":1,"state":"viewflow-c9-recovery-v2-persistent-v13-authenticated","operation_id":NEW,"manifest_sha256":msha,"main_pid":observed,"start_ticks":ticks(observed),"invocation_id":inv,"viewflowd_sha256":s["viewflow"]["sha256"],"journal_sha256":digest(journal.encode())}))
    ps=generated(o["persistent_started"],"persistent receipt")
    if set(ps)!={"schema_version","state","operation_id","manifest_sha256","main_pid","start_ticks","invocation_id","viewflowd_sha256","journal_sha256"} or ps.get("schema_version")!=1 or ps.get("state")!="viewflow-c9-recovery-v2-persistent-v13-authenticated" or ps.get("operation_id")!=NEW or ps.get("manifest_sha256")!=msha or ps.get("viewflowd_sha256")!=s["viewflow"]["sha256"] or not isinstance(ps.get("main_pid"),int) or not isinstance(ps.get("start_ticks"),int) or not re.fullmatch(r"[0-9a-f]{32}",ps.get("invocation_id","")) or not SHA.fullmatch(ps.get("journal_sha256","")): die("persistent receipt differs")
    frozen=Path(o["linux_frozen"])
    if frozen.exists():
        fv=generated(frozen,"fresh frozen receipt")
        if set(fv)!={"schema_version","state","operation_id","daemon","journal","pre_stop","post_stop","completed_at_unix_ms"} or fv.get("schema_version")!=1 or fv.get("state")!="viewflow-v13-bootstrap-frozen" or fv.get("operation_id")!=NEW or not isinstance(fv.get("daemon"),dict) or any(fv["daemon"].get(k)!=ps[k] for k in ("main_pid","start_ticks")) or fv["daemon"].get("systemd_invocation_id")!=ps["invocation_id"] or fv["daemon"].get("sha256")!=s["viewflow"]["sha256"]: die("fresh frozen receipt does not bind persistent receipt")
        zero(transition,s["viewflow"]["path"])
    else:
        p=ps["main_pid"]
        if sysprop("viewflow-peer.service","ActiveState")!="active" or sysprop("viewflow-peer.service","MainPID")!=str(p) or sysprop("viewflow-peer.service","InvocationID")!=ps["invocation_id"] or exact_pids(s["viewflow"]["path"])!=[p] or process_executable(p,ps["start_ticks"])[1]!=s["viewflow"]["sha256"]: die("persistent process cannot be safely adopted")
        journal=cmd(["/usr/bin/journalctl","--user","--quiet","--no-pager","--output=json","_SYSTEMD_INVOCATION_ID="+ps["invocation_id"]])
        if "viewflowd server authenticated peer 172.16.105.70:" not in journal or "viewflowd server peer 172.16.105.70:" not in journal: die("persistent receipt lost fresh authenticated Windows peer")
    assert_systemd_record("deskflow.service",pre["deskflow"]); assert_systemd_record(transition["linux_deskflow_unit"],pre["recovery_deskflow"]); assert_systemd_record("viewflow-peer.service",pre["viewflow"])
    # P/H is marker-cli-owned; collector owns F and stops exactly the recorded PID.
    if not Path(o["deployment_publish"]).exists():
        cmd([s["prepare_script"]["path"],"--deployment-marker-candidate",s["marker_candidate"]["path"],"--deployment-marker-sha256",s["marker_candidate"]["sha256"],"--operation-id",NEW,"--source-display-id","00000000-0000-0000-0000-000000000101","--target-device-id","00000000-0000-0000-0000-000000000002","--coordinator-instance-id",COORD,"--marker-generation","1","--deployment-publish-receipt",o["deployment_publish"],"--bootstrap-handoff-receipt",o["marker_handoff"]])
    if not Path(o["linux_frozen"]).exists():
        r=generated(o["persistent_started"],"persistent receipt")
        cmd([s["collector_script"]["path"],"--daemon-pid",str(r["main_pid"]),"--daemon-sha256",s["viewflow"]["sha256"],"--operation-id",NEW,"--evidence-output",o["linux_frozen"]])
    # The final bridge owns its create-once terminal.  Invoke only the pinned
    # source after P/H/F exist; it reopens and revalidates VFDQT itself.
    final_mode="--validate-inputs-only" if Path(o["terminal"]).exists() else "--publish-final"
    final=["/usr/bin/python3","-I",s["final_bridge"]["path"],final_mode,
      "--old-operation-id",OLD,"--old-coordinator-uuid","86c03003-2b67-451d-a990-396e1a66b406",
      "--fresh-operation-id",NEW,"--fresh-coordinator-uuid",COORD,"--fresh-root",str(FRESH),"--output",o["terminal"]]
    bridge_names={"terminal":"recovery_terminal","recovery-approval":"recovery_approval","authorization":"authorization","abort-receipt":"abort_receipt","abort-query":"abort_query","vfdqa":"vfdqa","linux-v13-started":"linux_v13_started","windows-v13-started":"windows_v13_started","authenticated-v13-peer":"authenticated_v13_peer","transition":"transition","deployment-publish":"deployment_publish","marker-handoff":"marker_handoff","linux-frozen":"linux_frozen"}
    for flag,name in bridge_names.items():
        if name in s: path,h=s[name]["path"],s[name]["sha256"]
        else: path,h=o[name],sha_file(o[name])
        final.extend(["--"+flag,path,"--"+flag+"-sha256",h])
    cmd(final,timeout=90)
    print(o["deployment_publish"]);print(o["marker_handoff"]);print(o["linux_frozen"])

def close_failed_attempt():
    """Seal the observed pre-mutation failure; this path never controls units."""
    if os.path.lexists(FAILED_CLOSURE): die("failed successor closure already exists")
    sources,docs=failed_inputs(False)
    require_dir(FAILED_FRESH,"failed successor fresh root")
    if any(FAILED_FRESH.iterdir()): die("failed successor fresh root is not empty")
    if os.path.lexists(FAILED_CANDIDATE): die("failed successor candidate exists")
    live=failed_live(sources,docs)
    raw=canonical(failed_closure(live))
    create_once(FAILED_CLOSURE,raw)
    # Publish success only after re-opening the exact generated receipt and
    # the original three leaf closure.  It is deliberately a no-op after this.
    validate_failed_closure(generated(FAILED_CLOSURE,"failed successor closure"),digest(raw))
    print(FAILED_CLOSURE); print(digest(raw))

def check_failed_attempt():
    """Run the close gate without naming or writing any output dentry."""
    if os.path.lexists(FAILED_CLOSURE): die("failed successor closure already exists")
    sources,docs=failed_inputs(False)
    require_dir(FAILED_FRESH,"failed successor fresh root")
    if any(FAILED_FRESH.iterdir()): die("failed successor fresh root is not empty")
    if os.path.lexists(FAILED_CANDIDATE): die("failed successor candidate exists")
    raw=canonical(failed_closure(failed_live(sources,docs)))
    validate_failed_closure(strict(raw,"failed successor check receipt"),digest(raw),False)
    print("failed successor attempt validated; no mutation")

def main():
    a=parser()
    if a.check_failed_attempt:
        check_failed_attempt(); return
    if a.close_failed_attempt:
        close_failed_attempt(); return
    if a.prepare:
        if a.manifest!=str(ROOT/"manifest.json"): die("manifest path is fixed")
        require_dir(STATE,"state"); require_dir(STATE/"bridges","bridges",True); require_dir(STATE/"bridges"/"c9-recovery-v2","bridge parent",True); require_dir(ROOT,"bridge root",True)
        # The root is itself part of the audited plan.  An empty owner-only
        # root is create-once; a second --prepare may only proceed through the
        # already-published manifest, never select another identity.
        require_dir(STATE/"deployments","deployments")
        if os.path.lexists(FRESH):
            # A power loss between mkdir(FRESH) and create_once(manifest) is
            # recoverable only if it left this operation-owned directory
            # genuinely empty.  Never adopt a partial foreign publication.
            require_dir(FRESH,"fresh root")
            if any(FRESH.iterdir()): die("fresh operation root contains partial output")
        else:
            require_dir(FRESH,"fresh root",True)
        plan=plan_from_args(a); create_once(a.manifest,canonical(plan)); print(a.manifest);return
    plan,docs=read_manifest(a)
    if a.offline_check: print("c9 recovery-v2 lifecycle plan validated; no mutation");return
    if a.publish_execution_approval:
        raw=canonical(approval(plan,a.manifest_sha256,a.approved_at_utc)); create_once(plan["outputs"]["approval"],raw); print(digest(raw));return
    if not SHA.fullmatch(a.approval_sha256): die("execute/resume requires exact approval SHA")
    raw=stable(plan["outputs"]["approval"],a.approval_sha256,0o600,"approval")
    validate_approval(plan,a.manifest_sha256,raw,a.approval_sha256)
    execute(plan,a.manifest_sha256,docs)
if __name__=="__main__":
    try: main()
    except (Error,OSError,ValueError,subprocess.SubprocessError) as e: print("error: c9 recovery-v2 fresh boundary: "+str(e),file=sys.stderr);sys.exit(1)
