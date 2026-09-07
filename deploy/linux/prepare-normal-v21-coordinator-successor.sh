#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    cat >&2 <<'EOF'
Usage: prepare-normal-v21-coordinator-successor.sh MODE \
  --operation-id HEX32 --coordinator-instance-id UUID \
  --successor-coordinator PATH --successor-coordinator-sha256 LOWER64 \
  --successor-provenance PATH --successor-provenance-sha256 LOWER64

MODE is exactly one of: --check-only --execute --resume --replay
EOF
}

mode=''; operation_id=''; coordinator_id=''; successor=''; successor_sha=''; provenance=''; provenance_sha=''
while (($#)); do
    case $1 in
        --check-only|--execute|--resume|--replay) [[ -z $mode ]] || { usage; exit 64; }; mode=$1; shift ;;
        --operation-id) operation_id=${2-}; shift 2 ;;
        --coordinator-instance-id) coordinator_id=${2-}; shift 2 ;;
        --successor-coordinator) successor=${2-}; shift 2 ;;
        --successor-coordinator-sha256) successor_sha=${2-}; shift 2 ;;
        --successor-provenance) provenance=${2-}; shift 2 ;;
        --successor-provenance-sha256) provenance_sha=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 64 ;;
    esac
done
[[ -n $mode && -n $operation_id && -n $coordinator_id && -n $successor && -n $successor_sha &&
   -n $provenance && -n $provenance_sha ]] || { usage; exit 64; }
self_source=${BASH_SOURCE[0]}
[[ ! -L $self_source ]] || { echo 'error: receipt producer must not be a symlink' >&2; exit 1; }
self_source=$(realpath --canonicalize-existing -- "$self_source")

exec python3 - "$mode" "$operation_id" "$coordinator_id" "$successor" "$successor_sha" \
    "$provenance" "$provenance_sha" "$self_source" <<'PY'
import base64, ctypes, datetime, errno, fcntl, hashlib, json, os, re, stat, subprocess, sys, time, uuid

MODE, OP, COORD, SUCCESSOR, SUCCESSOR_SHA, PROVENANCE, PROVENANCE_SHA, SELF = sys.argv[1:]
UID=1000
STATE="/home/wilf/.local/state/viewflow"
ROOT=f"{STATE}/deployments/{OP}"
CAND=f"{STATE}/candidates/v21-operation-{OP}"
RECEIPT_LEAF="coordinator-successor-receipt.json"
WPROOF_LEAF="coordinator-successor-windows-prestate.json"
RECEIPT=f"{ROOT}/{RECEIPT_LEAF}"
WPROOF=f"{ROOT}/{WPROOF_LEAF}"
MARKER=f"{STATE}/deployment-quarantine.v1"
RUNTIME=f"{STATE}/deskflow-quarantine.v2"
SSH_TARGET="wilf@172.16.105.70"
WIN_ROOT=rf"C:\Users\wilf\AppData\Local\Viewflow\Deployments\{OP}"
SSH="/usr/bin/ssh"
SYSTEMCTL="/usr/bin/systemctl"
SS="/usr/bin/ss"
HEX32=re.compile(r"[0-9a-f]{32}\Z"); HEX64=re.compile(r"[0-9a-f]{64}\Z")
UUID=re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
UTC=re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")
NORMAL=["coordinator-state.json","coordinator-state.json.pre-mutation-retry.json","coordinator-state.json.pre-mutation-start-intent.v1.json","coordinator-state.json.pre-mutation-stop-claim.v1","coordinator-state.json.recovery-bundle.json","coordinator-state.json.windows-restart-intent.json","coordinator-state.json.windows-stop-evidence.json","cpp-arm-response.json","cpp-cleanup-receipt.json","cpp-status-response.json","deployment-release.json","linux-containment.transcript","linux-deactivation-transcript.json","linux-deactivation.json","linux-finalize.json","linux-host-proof.json","linux-stage.json","linux-stage.json.backup","post-release-receipt.json","recovery-deployment-publish.json","recovery-deployment-publish.json.intent.json","rust-acceptance-arm-response.json","rust-acceptance-query-response.json","windows-bootstrap-request.json","windows-force-envelope.json","windows-install.json","windows-installer-exit.json","windows-mutation-permit.json","windows-prepared.json","windows-restart-receipt.json","windows-rollback.json","windows-validation.json"]
PRE=["candidate-replacement-commit.json","candidate-retirement-terminal.json","coordinator-successor-windows-prestate.json","deployment-publish.json","launch-normal-v21.sh","linux-frozen.json","marker-handoff.json","normal-v21-candidate-retirement.intent.json"]
BASE=[x for x in PRE if x != WPROOF_LEAF]
ACL={"system.posix_acl_access","system.posix_acl_default"}

def die(s): raise SystemExit("error: coordinator successor: "+s)
def req(v,s):
    if not v: die(s)
def pairs(items):
    d={}
    for k,v in items:
        req(k not in d,"duplicate JSON key "+repr(k)); d[k]=v
    return d
def badnum(x): die("floating or non-finite JSON number "+x)
def parse(data,label):
    try:
        text=data.decode("utf-8","strict")
        value,end=json.JSONDecoder(object_pairs_hook=pairs,parse_float=badnum,parse_constant=badnum).raw_decode(text)
    except (UnicodeError,json.JSONDecodeError) as e: die(label+" is not strict JSON: "+str(e))
    req(text[end:].strip()=="" and type(value) is dict,label+" must be one JSON object")
    return value
def keys(v,ordered,label): req(type(v) is dict and list(v.keys())==ordered,label+" exact ordered keys differ")
def members(v,names,label): req(type(v) is dict and set(v)==set(names),label+" exact keys differ")
def canon(path,label): req(path.startswith("/") and os.path.normpath(path)==path and "//" not in path,label+" path is not canonical")
def meta(st): return (st.st_dev,st.st_ino,st.st_uid,stat.S_IMODE(st.st_mode),st.st_nlink,st.st_size)
def acl(fd,label): req(not (set(os.listxattr(fd)) & ACL),label+" has POSIX ACL")
def open_dir(path,mode,label):
    canon(path,label); fd=os.open("/",os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
    try:
        for c in path.split("/")[1:]:
            n=os.open(c,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=fd); os.close(fd); fd=n
        st=os.fstat(fd); req(stat.S_ISDIR(st.st_mode) and st.st_uid==UID and stat.S_IMODE(st.st_mode)==mode and st.st_nlink>=1,label+" identity differs"); acl(fd,label)
        req(meta(os.stat(path,follow_symlinks=False))==meta(st),label+" path changed")
        return fd
    except BaseException: os.close(fd); raise
def read_at(pfd,leaf,mode,label,nlink=1):
    req("/" not in leaf and leaf not in ("",".",".."),label+" unsafe leaf")
    try: fd=os.open(leaf,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=pfd)
    except OSError as e: die(label+" open failed: "+str(e))
    try:
        a=os.fstat(fd); req(stat.S_ISREG(a.st_mode) and a.st_uid==UID and stat.S_IMODE(a.st_mode)==mode and a.st_nlink==nlink,label+" identity differs"); acl(fd,label)
        out=b""
        while True:
            b=os.read(fd,131072)
            if not b: break
            out+=b
        z=os.fstat(fd); req(meta(a)==meta(z) and meta(os.stat(leaf,dir_fd=pfd,follow_symlinks=False))==meta(z) and len(out)==z.st_size,label+" changed while read")
        return out,hashlib.sha256(out).hexdigest()
    finally: os.close(fd)
def read_abs(path,mode,label,nlink=1):
    canon(path,label); parent,leaf=os.path.split(path); fd=open_dir(parent,stat.S_IMODE(os.stat(parent,follow_symlinks=False).st_mode),label+" parent")
    try: return read_at(fd,leaf,mode,label,nlink)
    finally: os.close(fd)
def sha_art(path,mode,label,expected=None,nlink=1):
    data,digest=read_abs(path,mode,label,nlink)
    if expected is not None: req(digest==expected,label+" SHA-256 differs")
    return data,digest
def canonical_bytes(v): return (json.dumps(v,separators=(",",":"),ensure_ascii=True)+"\n").encode("ascii")
def timestamp(v,mskey,utckey,label):
    ms=v.get(mskey); utc=v.get(utckey)
    req(type(ms) is int and not isinstance(ms,bool) and ms>0 and type(utc) is str and UTC.fullmatch(utc),label+" timestamp type differs")
    expected=datetime.datetime.fromtimestamp(ms/1000,datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z")
    req(utc==expected,label+" timestamp values differ")
def now():
    ms=time.time_ns()//1_000_000
    return ms,datetime.datetime.fromtimestamp(ms/1000,datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z")
def publish(pfd,leaf,data,label):
    try: tfd=os.open(".",os.O_TMPFILE|os.O_RDWR|os.O_CLOEXEC,0o600,dir_fd=pfd)
    except OSError as e: die(label+" O_TMPFILE failed: "+str(e))
    try:
        os.fchmod(tfd,0o600); view=memoryview(data)
        while view:
            n=os.write(tfd,view); req(n>0,label+" short write"); view=view[n:]
        os.fsync(tfd)
        libc=ctypes.CDLL(None,use_errno=True); fn=libc.linkat; fn.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_int]; fn.restype=ctypes.c_int
        AT_EMPTY_PATH=0x1000
        if fn(tfd,b"",pfd,os.fsencode(leaf),AT_EMPTY_PATH)!=0:
            e=ctypes.get_errno(); die(label+(" already exists" if e==errno.EEXIST else " linkat failed: "+os.strerror(e)))
        os.fsync(pfd)
    finally: os.close(tfd)
    got,_=read_at(pfd,leaf,0o600,label); req(got==data,label+" published bytes differ")
def list_root(fd): os.lseek(fd,0,os.SEEK_SET); return sorted(os.listdir(fd))
def exact_root(fd,expected,label): req(list_root(fd)==sorted(expected),label+" operation leaves differ: "+repr(list_root(fd)))

def validate_prehistory(rootfd):
    blobs={}; shas={}
    for leaf in BASE:
        mode=0o500 if leaf=="launch-normal-v21.sh" else 0o600
        blobs[leaf],shas[leaf]=read_at(rootfd,leaf,mode,leaf)
    p=parse(blobs["deployment-publish.json"],"deployment publish")
    h=parse(blobs["marker-handoff.json"],"marker handoff")
    f=parse(blobs["linux-frozen.json"],"linux frozen")
    t=parse(blobs["candidate-retirement-terminal.json"],"retirement terminal")
    c=parse(blobs["candidate-replacement-commit.json"],"replacement commit")
    members(p,["coordinator_instance_id","created_at_unix_ms","created_at_utc","marker_generation","marker_path","marker_sha256","operation_id","protocol_version","schema_version","source_display_id","state","target_device_id"],"deployment publish")
    members(h,["schema_version","state","protocol_version","operation_id","source_display_id","target_device_id","coordinator_instance_id","marker_generation","marker_cli_path","marker_cli_sha256","deployment_marker_path","deployment_marker_sha256","deployment_publish_receipt_path","deployment_publish_receipt_sha256","deskflow_unit","deskflow_unit_active_state","deskflow_unit_main_pid","deskflow_executable_path","deskflow_executable_sha256","deskflow_exact_process_count","deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_core_exact_process_count","deskflow_tcp_port","deskflow_tcp_listener_count","runtime_marker_path","runtime_marker_present","observed_at_utc"],"marker handoff")
    members(f,["schema_version","state","operation_id","daemon","journal","pre_stop","post_stop","completed_at_unix_ms"],"Linux frozen")
    keys(t,["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms","created_at_utc","operation_root","candidate_root","old_candidate","fresh_boundary","authorized_seed","pre_retirement"],"retirement terminal")
    keys(t.get("old_candidate"),["canonical_path","archive_path","manifest_sha256","tree_sha256","files"],"retirement terminal old candidate")
    keys(t.get("fresh_boundary"),["deployment_publish_path","deployment_publish_sha256","marker_handoff_path","marker_handoff_sha256","linux_frozen_path","linux_frozen_sha256","deployment_marker_path","deployment_marker_sha256"],"retirement terminal fresh boundary")
    keys(t.get("authorized_seed"),["root","candidate_manifest_path","candidate_manifest_sha256"],"retirement terminal authorized seed")
    keys(t.get("pre_retirement"),["coordinator_state_path","coordinator_state_absent","standard_normal_outputs_absent"],"retirement terminal pre-state")
    keys(c,["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms","created_at_utc","operation_root","candidate_root","candidate_manifest_path","candidate_manifest_sha256","candidate_tree_sha256","retirement_terminal_path","retirement_terminal_sha256","old_candidate_archive_path","old_candidate_manifest_sha256","authorized_seed_manifest_sha256","fresh_boundary"],"replacement commit")
    req(p.get("schema_version")==1 and p.get("state")=="deployment-quarantine-published" and p.get("operation_id")==OP and p.get("coordinator_instance_id")==COORD and p.get("protocol_version")=="2.1" and p.get("marker_generation")=="1","deployment publish identity differs")
    req(h.get("schema_version")==1 and h.get("state")=="viewflow-v13-marker-handoff-prepared" and h.get("operation_id")==OP and h.get("coordinator_instance_id")==COORD and h.get("deployment_publish_receipt_path")==ROOT+"/deployment-publish.json" and h.get("deployment_publish_receipt_sha256")==shas["deployment-publish.json"] and h.get("deployment_marker_path")==MARKER and h.get("deployment_marker_sha256")==p.get("marker_sha256"),"marker handoff closure differs")
    req(f.get("schema_version")==1 and f.get("state")=="viewflow-v13-bootstrap-frozen" and f.get("operation_id")==OP,"Linux frozen identity differs")
    post=f.get("post_stop",{}); req(post.get("unit_active_state")=="inactive" and post.get("main_pid")==0 and post.get("exact_process_count")==0 and post.get("udp_44119_listener_count")==0 and post.get("sidecar_socket_present") is False,"Linux frozen boundary differs")
    req(t.get("schema_version")==1 and t.get("state")=="viewflow-normal-v21-candidate-retired" and t.get("operation_id")==OP and t.get("coordinator_instance_id")==COORD and t.get("replacement_ordinal")==1 and t.get("operation_root")==ROOT and t.get("candidate_root")==CAND,"retirement terminal identity differs")
    timestamp(t,"created_at_unix_ms","created_at_utc","retirement terminal")
    req(c.get("schema_version")==1 and c.get("state")=="viewflow-normal-v21-candidate-replacement-committed" and c.get("operation_id")==OP and c.get("coordinator_instance_id")==COORD and c.get("replacement_ordinal")==1 and c.get("operation_root")==ROOT and c.get("candidate_root")==CAND and c.get("retirement_terminal_path")==ROOT+"/candidate-retirement-terminal.json" and c.get("retirement_terminal_sha256")==shas["candidate-retirement-terminal.json"],"replacement commit identity differs")
    timestamp(c,"created_at_unix_ms","created_at_utc","replacement commit")
    return blobs,shas,p,h,t,c

def candidate_tree():
    fd=open_dir(CAND,0o700,"candidate root")
    try:
        expected=["candidate-manifest.json","windows-native-provenance.json","windows-source.manifest.sha256","windows-source.tar.gz","windows-source.tar.gz.sha256","windows-viewflowd.exe"]
        req(sorted(os.listdir(fd))==expected,"candidate exact six leaves differ")
        digest=hashlib.sha256(); rec={}
        for leaf in expected:
            mode=0o700 if leaf=="windows-viewflowd.exe" else 0o600
            data,sha=read_at(fd,leaf,mode,"candidate "+leaf); size=len(data)
            digest.update((leaf+"\0"+f"{mode:04o}"+"\0"+str(size)+"\0"+sha+"\n").encode("ascii")); rec[leaf]=(data,sha)
        manifest=parse(rec["candidate-manifest.json"][0],"candidate manifest")
        return manifest,rec["candidate-manifest.json"][1],digest.hexdigest()
    finally: os.close(fd)

def verify_retired_archive(t):
    old=t.get("old_candidate",{}); old_sha=old.get("manifest_sha256")
    archive=f"{STATE}/candidates/rejected/v21-operation-{OP}.rejected-{old_sha}"
    req(old.get("canonical_path")==CAND and old.get("archive_path")==archive and HEX64.fullmatch(old_sha or ""),"retired archive path binding differs")
    fd=open_dir(archive,0o700,"retired candidate archive")
    try:
        expected=["candidate-manifest.json","windows-native-provenance.json","windows-source.manifest.sha256","windows-source.tar.gz","windows-source.tar.gz.sha256","windows-viewflowd.exe"]
        req(sorted(os.listdir(fd))==expected,"retired archive exact six leaves differ")
        records=[]; digest=hashlib.sha256()
        for leaf in expected:
            mode=0o700 if leaf=="windows-viewflowd.exe" else 0o600
            data,sha=read_at(fd,leaf,mode,"retired archive "+leaf); size=len(data)
            records.append({"name":leaf,"mode":f"{mode:04o}","size_bytes":size,"sha256":sha})
            digest.update((leaf+"\0"+f"{mode:04o}"+"\0"+str(size)+"\0"+sha+"\n").encode("ascii"))
        req(records==old.get("files") and digest.hexdigest()==old.get("tree_sha256") and records[0]["sha256"]==old_sha,"retired archive tree closure differs")
    finally: os.close(fd)

def validate_candidate(t,c,shas):
    verify_retired_archive(t)
    m,msha,tree=candidate_tree()
    keys(m,["schema_version","kind","operation_id","coordinator_instance_id","protocol_version","sidecar_protocol_version","marker_generation","recovery_marker_generation","source_display_id","target_device_id","fresh_boundary","candidate_replacement","coordinator","linux_rust","linux_deskflow","windows"],"candidate manifest")
    keys(m.get("fresh_boundary"),["root","deployment_publish_receipt_sha256","marker_handoff_sha256","linux_frozen_sha256","deployment_marker","deployment_marker_sha256"],"candidate fresh boundary")
    keys(m.get("candidate_replacement"),["retirement_terminal_path","retirement_terminal_sha256","old_candidate_manifest_sha256","replacement_ordinal","authorized_seed_manifest_sha256"],"candidate replacement")
    keys(m.get("coordinator"),["entrypoint","entrypoint_sha256","source_provenance","source_provenance_sha256"],"candidate coordinator")
    req(m.get("schema_version")==2 and m.get("kind")=="viewflow-v21-cross-host-candidate-set" and m.get("operation_id")==OP and m.get("coordinator_instance_id")==COORD and m.get("protocol_version")=="2.1" and m.get("sidecar_protocol_version")==3,"candidate manifest identity differs")
    cr=m.get("candidate_replacement",{})
    req(cr.get("retirement_terminal_path")==ROOT+"/candidate-retirement-terminal.json" and cr.get("retirement_terminal_sha256")==shas["candidate-retirement-terminal.json"] and cr.get("replacement_ordinal")==1,"candidate replacement closure differs")
    req(c.get("candidate_manifest_path")==CAND+"/candidate-manifest.json" and c.get("candidate_manifest_sha256")==msha and c.get("candidate_tree_sha256")==tree,"replacement commit candidate closure differs")
    req(c.get("authorized_seed_manifest_sha256")==cr.get("authorized_seed_manifest_sha256")==t.get("authorized_seed",{}).get("candidate_manifest_sha256"),"authorized seed lineage differs")
    tf=t.get("fresh_boundary",{}); cf=c.get("fresh_boundary",{}); mf=m.get("fresh_boundary",{})
    expected={"deployment_publish_path":ROOT+"/deployment-publish.json","deployment_publish_sha256":shas["deployment-publish.json"],"marker_handoff_path":ROOT+"/marker-handoff.json","marker_handoff_sha256":shas["marker-handoff.json"],"linux_frozen_path":ROOT+"/linux-frozen.json","linux_frozen_sha256":shas["linux-frozen.json"],"deployment_marker_path":MARKER,"deployment_marker_sha256":mf.get("deployment_marker_sha256")}
    req(tf==cf==expected and mf.get("root")==ROOT and mf.get("deployment_publish_receipt_sha256")==tf.get("deployment_publish_sha256") and mf.get("marker_handoff_sha256")==tf.get("marker_handoff_sha256") and mf.get("linux_frozen_sha256")==tf.get("linux_frozen_sha256") and mf.get("deployment_marker")==MARKER and mf.get("deployment_marker_sha256")==tf.get("deployment_marker_sha256"),"fresh boundary lineage differs")
    return m,msha,tree

def service_zero():
    for unit in ("viewflow-peer.service","deskflow.service"):
        p=subprocess.run([SYSTEMCTL,"--user","show","-p","ActiveState","-p","MainPID","--value",unit],text=True,capture_output=True)
        req(p.returncode==0,unit+" state query failed")
        vals=[x.strip() for x in p.stdout.splitlines() if x.strip()]
        req(vals==["inactive","0"] or vals==["0","inactive"],unit+" is not inactive/MainPID0: "+repr(vals))
    for proto,port in (("-ltn","24800"),("-lun","44119")):
        p=subprocess.run([SS,"-H",proto,"sport = :"+port],text=True,capture_output=True)
        req(p.returncode==0 and p.stdout.strip()=="",port+" listener exists or census failed")
    req(not os.path.lexists(RUNTIME),"runtime quarantine marker exists")

def marker_zero(p,h):
    data,msha=sha_art(MARKER,0o600,"active deployment marker",p.get("marker_sha256"))
    op_len=data[13] if len(data)==256 else 0
    req(len(data)==256 and data[:13]==b"VFDQT001\x01\x01\x02\x01\x01" and 16<=op_len<=128 and
        data[14:16]==b"\0\0" and data[16:16+op_len]==OP.encode("ascii") and
        data[16+op_len:144]==b"\0"*(128-op_len) and data[176:192]==uuid.UUID(COORD).bytes and
        int.from_bytes(data[200:208],"little")==1 and data[208:]==b"\0"*48 and
        h.get("deployment_marker_sha256")==msha,"active deployment marker tuple differs")
    for leaf in ("deployment-quarantine.v1.release-claim","deployment-quarantine.v1.abort-claim"):
        req(not os.path.lexists(STATE+"/"+leaf),leaf+" exists")
    req(not os.path.lexists(f"{STATE}/.deployment-quarantine.v1.release-receipt.{msha}.v1"),"current marker release receipt exists")
    prefix=f".deployment-quarantine.v1.abort-receipt.{msha}."
    req(not any(x.startswith(prefix) and x.endswith(".v1") for x in os.listdir(STATE)),"current marker abort receipt exists")
    return msha

def prevalidate(rootfd,expected):
    exact_root(rootfd,expected,"pre-state")
    req(all(not os.path.lexists(ROOT+"/"+x) for x in NORMAL),"normal output already exists")
    blobs,shas,p,h,t,c=validate_prehistory(rootfd)
    intent=parse(blobs["normal-v21-candidate-retirement.intent.json"],"retirement intent")
    keys(intent,["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms","created_at_utc","operation_root","candidate_root","archive_path","terminal_path","terminal_receipt"],"retirement intent")
    req(intent.get("schema_version")==1 and intent.get("state")=="viewflow-normal-v21-candidate-retirement-intent" and
        intent.get("operation_id")==OP and intent.get("coordinator_instance_id")==COORD and
        intent.get("operation_root")==ROOT and intent.get("candidate_root")==CAND and
        intent.get("terminal_path")==ROOT+"/candidate-retirement-terminal.json" and intent.get("terminal_receipt")==t,
        "retirement intent closure differs")
    m,msha,tree=validate_candidate(t,c,shas)
    req(t["fresh_boundary"]["deployment_marker_sha256"]==p.get("marker_sha256"),"fresh boundary marker SHA differs from publish")
    marker_zero(p,h); service_zero()
    self_data,self_sha=sha_art(SELF,0o755,"receipt producer")
    succ_data,succ_sha=sha_art(SUCCESSOR,0o755,"successor coordinator",SUCCESSOR_SHA)
    prov_data,prov_sha=sha_art(PROVENANCE,0o600,"successor provenance",PROVENANCE_SHA)
    prov=parse(prov_data,"successor provenance"); source=prov.get("source",{}); source_root=source.get("root")
    req(prov.get("schema_version")==2 and prov.get("kind")=="viewflow-linux-rust-release-provenance" and
        prov.get("protocol_version")=="2.1" and prov.get("sidecar_protocol_version")==3 and
        type(source_root) is str and SUCCESSOR.startswith(source_root+"/") and SELF.startswith(source_root+"/"),"successor provenance identity/root differs")
    rel=SUCCESSOR[len(source_root)+1:]
    bound=[x for x in source.get("files",[]) if type(x) is dict and x.get("path")==rel]
    req(len(bound)==1 and bound[0].get("sha256")==SUCCESSOR_SHA,"successor provenance does not bind coordinator bytes")
    self_rel=SELF[len(source_root)+1:]
    producer_bound=[x for x in source.get("files",[]) if type(x) is dict and x.get("path")==self_rel]
    req(len(producer_bound)==1 and producer_bound[0].get("sha256")==self_sha,"successor provenance does not bind receipt producer bytes")
    co=m.get("coordinator",{}); req(set(co)=={"entrypoint","entrypoint_sha256","source_provenance","source_provenance_sha256"},"predecessor coordinator fields differ")
    sha_art(co["entrypoint"],0o755,"predecessor coordinator",co["entrypoint_sha256"]); sha_art(co["source_provenance"],0o600,"predecessor provenance",co["source_provenance_sha256"])
    req(co["entrypoint"]!=SUCCESSOR and co["entrypoint_sha256"]!=SUCCESSOR_SHA,"successor is not a distinct coordinator generation")
    lr=m.get("linux_rust",{}); hist=h.get("marker_cli_path"); cand=lr.get("deployment_marker"); alias_sha=lr.get("deployment_marker_sha256")
    req(alias_sha=="e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5","candidate marker CLI is not reviewed v3")
    sha_art(hist,0o755,"historical marker CLI",alias_sha); sha_art(cand,0o755,"candidate marker CLI",alias_sha,2)
    return {"blobs":blobs,"shas":shas,"manifest":m,"manifest_sha":msha,"tree":tree,"self_sha":self_sha,"co":co,"hist":hist,"cand":cand,"alias_sha":alias_sha}

def ps_collect():
    ps=r'''$ErrorActionPreference='Stop'
$op='__OP__'; $root='__ROOT__'; $needle=@($op,$root); $tasks=@();
$present=Test-Path -LiteralPath $root
if($present){$i=Get-Item -LiteralPath $root -Force; if(($i.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){throw 'operation root is a reparse point'}}
Get-ScheduledTask | ForEach-Object { $t=$_; $a=(($t.Actions | ForEach-Object { [string]$_.Execute+' '+[string]$_.Arguments+' '+[string]$_.WorkingDirectory }) -join "`n"); $x=Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath; $s=([string]$t.TaskPath+[string]$t.TaskName+"`n"+$a+"`n"+$x); foreach($n in $needle){if($s.IndexOf($n,[StringComparison]::OrdinalIgnoreCase)-ge 0){$tasks+=([string]$t.TaskPath+[string]$t.TaskName);break}} }
$procs=@(); Get-CimInstance Win32_Process | ForEach-Object { $s=([string]$_.CommandLine+"`n"+[string]$_.ExecutablePath); foreach($n in $needle){if($s.IndexOf($n,[StringComparison]::OrdinalIgnoreCase)-ge 0){$procs+=([string]$_.ProcessId);break}} }
[ordered]@{operation_root_present=[bool]$present;operation_bound_tasks=@($tasks);operation_bound_processes=@($procs)} | ConvertTo-Json -Compress
'''.replace("__OP__",OP).replace("__ROOT__",WIN_ROOT.replace("'","''"))
    encoded=base64.b64encode(ps.encode("utf-16le")).decode("ascii")
    cmd=[SSH,"-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","ConnectTimeout=10",SSH_TARGET,"powershell.exe","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",encoded]
    p=subprocess.run(cmd,capture_output=True,timeout=45)
    req(p.returncode==0,"Windows read-only collector failed")
    v=parse(p.stdout,"Windows collector output")
    keys(v,["operation_root_present","operation_bound_tasks","operation_bound_processes"],"Windows collector output")
    req(v["operation_root_present"] is False and v["operation_bound_tasks"]==[] and v["operation_bound_processes"]==[],"Windows current-operation prestate is not absent")
    return v

def make_wproof(collected,self_sha,sid):
    ms,utc=now()
    return {"schema_version":1,"state":"viewflow-normal-v21-coordinator-successor-windows-prestate","operation_id":OP,"coordinator_instance_id":COORD,"observed_at_unix_ms":ms,"observed_at_utc":utc,"windows_ssh_target":SSH_TARGET,"windows_user_sid":sid,"windows_operation_root":WIN_ROOT,"operation_root_present":False,"operation_bound_task_count":0,"operation_bound_tasks":[],"operation_bound_process_count":0,"operation_bound_processes":[],"collector_path":SELF,"collector_sha256":self_sha}
def validate_wproof(v,self_sha,sid):
    keys(v,["schema_version","state","operation_id","coordinator_instance_id","observed_at_unix_ms","observed_at_utc","windows_ssh_target","windows_user_sid","windows_operation_root","operation_root_present","operation_bound_task_count","operation_bound_tasks","operation_bound_process_count","operation_bound_processes","collector_path","collector_sha256"],"Windows prestate")
    timestamp(v,"observed_at_unix_ms","observed_at_utc","Windows prestate")
    req(v==dict(v, schema_version=1,state="viewflow-normal-v21-coordinator-successor-windows-prestate",operation_id=OP,coordinator_instance_id=COORD,windows_ssh_target=SSH_TARGET,windows_user_sid=sid,windows_operation_root=WIN_ROOT,operation_root_present=False,operation_bound_task_count=0,operation_bound_tasks=[],operation_bound_process_count=0,operation_bound_processes=[],collector_path=SELF,collector_sha256=self_sha),"Windows prestate fixed values differ")
def artifact(path,sha): return {"path":path,"sha256":sha}
def make_receipt(ctx,wsha):
    ms,utc=now(); s=ctx["shas"]; m=ctx["manifest"]; co=ctx["co"]
    return {"schema_version":1,"state":"viewflow-normal-v21-coordinator-successor-authorized","operation_id":OP,"coordinator_instance_id":COORD,"replacement_ordinal":1,"created_at_unix_ms":ms,"created_at_utc":utc,"operation_root":ROOT,"receipt_path":RECEIPT,
      "predecessor":{"deployment_publish":artifact(ROOT+"/deployment-publish.json",s["deployment-publish.json"]),"marker_handoff":artifact(ROOT+"/marker-handoff.json",s["marker-handoff.json"]),"linux_frozen":artifact(ROOT+"/linux-frozen.json",s["linux-frozen.json"]),"retirement_terminal":artifact(ROOT+"/candidate-retirement-terminal.json",s["candidate-retirement-terminal.json"]),"replacement_commit":artifact(ROOT+"/candidate-replacement-commit.json",s["candidate-replacement-commit.json"]),"candidate_manifest":artifact(CAND+"/candidate-manifest.json",ctx["manifest_sha"]),"candidate_tree_sha256":ctx["tree"],"launcher":artifact(ROOT+"/launch-normal-v21.sh",s["launch-normal-v21.sh"]),"coordinator":{"path":co["entrypoint"],"sha256":co["entrypoint_sha256"],"provenance_path":co["source_provenance"],"provenance_sha256":co["source_provenance_sha256"]}},
      "marker_cli_alias_override":{"kind":"marker-cli-path-alias-same-bytes-v1","only_handoff_field":"marker_cli_path","historical_path":ctx["hist"],"candidate_path":ctx["cand"],"sha256":ctx["alias_sha"]},
      "successor":{"coordinator_path":SUCCESSOR,"coordinator_sha256":SUCCESSOR_SHA,"provenance_path":PROVENANCE,"provenance_sha256":PROVENANCE_SHA,"receipt_producer_path":SELF,"receipt_producer_sha256":ctx["self_sha"]},
      "absence":{"coordinator_state_path":ROOT+"/coordinator-state.json","coordinator_state_absent":True,"normal_output_leaves":NORMAL,"normal_outputs_absent":True,"pre_receipt_operation_leaves":PRE},
      "windows_prestate":artifact(WPROOF,wsha)}
def validate_receipt(v,ctx,wsha):
    keys(v,["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms","created_at_utc","operation_root","receipt_path","predecessor","marker_cli_alias_override","successor","absence","windows_prestate"],"successor receipt")
    timestamp(v,"created_at_unix_ms","created_at_utc","successor receipt")
    expected=make_receipt(ctx,wsha); expected["created_at_unix_ms"]=v["created_at_unix_ms"]; expected["created_at_utc"]=v["created_at_utc"]
    req(v==expected,"successor receipt binding differs")

req(MODE in ("--check-only","--execute","--resume","--replay"),"invalid mode")
req(os.geteuid()==UID,"must run as uid 1000")
req(HEX32.fullmatch(OP) and UUID.fullmatch(COORD) and HEX64.fullmatch(SUCCESSOR_SHA) and HEX64.fullmatch(PROVENANCE_SHA),"noncanonical argument")
canon(SELF,"receipt producer"); canon(SUCCESSOR,"successor coordinator"); canon(PROVENANCE,"successor provenance")
rootfd=open_dir(ROOT,0o700,"operation root")
try:
    try: fcntl.flock(rootfd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: die("operation root is locked")
    have_w=os.path.lexists(WPROOF); have_r=os.path.lexists(RECEIPT)
    if MODE=="--check-only":
        req(not have_w and not have_r,"check-only requires fresh successor outputs"); prevalidate(rootfd,BASE); print("coordinator successor preflight verified"); raise SystemExit(0)
    if MODE=="--execute":
        req(not have_w and not have_r,"execute requires fresh successor outputs"); ctx=prevalidate(rootfd,BASE); collected=ps_collect(); sid=ctx["manifest"]["windows"]["session_1_user_sid"]
        w=make_wproof(collected,ctx["self_sha"],sid); publish(rootfd,WPROOF_LEAF,canonical_bytes(w),"Windows prestate"); have_w=True
    elif MODE=="--resume": req(have_w and not have_r,"resume requires Windows prestate and no receipt")
    else: req(have_w and have_r,"replay requires both durable outputs")
    ctx=prevalidate(rootfd,PRE+([RECEIPT_LEAF] if have_r else [])); sid=ctx["manifest"]["windows"]["session_1_user_sid"]
    wdata,wsha=read_at(rootfd,WPROOF_LEAF,0o600,"Windows prestate"); w=parse(wdata,"Windows prestate"); validate_wproof(w,ctx["self_sha"],sid)
    if MODE=="--resume":
        ps_collect()
    if not have_r: publish(rootfd,RECEIPT_LEAF,canonical_bytes(make_receipt(ctx,wsha)),"successor receipt")
    rdata,rsha=read_at(rootfd,RECEIPT_LEAF,0o600,"successor receipt"); validate_receipt(parse(rdata,"successor receipt"),ctx,wsha)
    exact_root(rootfd,PRE+[RECEIPT_LEAF],"terminal")
    print("coordinator successor "+("replayed" if MODE=="--replay" else "authorized")+" receipt_sha256="+rsha+" windows_prestate_sha256="+wsha)
finally: os.close(rootfd)
PY
