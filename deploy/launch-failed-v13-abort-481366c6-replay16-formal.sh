#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

readonly OPERATION_ID=481366c6c9654a679a96d4b6b1447ecb
readonly LAUNCHER=/home/wilf/data/viewflow/deploy/launch-failed-v13-abort-481366c6-replay16-formal.sh
readonly MANIFEST=/home/wilf/data/viewflow/deploy/failed-v13-abort-481366c6-replay16-manifest.json
readonly MANIFEST_SHA256=a2272271a574c3e8a0589b7e14b1a6a1a830f89005c8489a206d46b16a29edde
readonly APPROVAL=/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/failed-v13-abort-replay16-execution-approval.json
readonly GATE_ENV=/usr/bin/env
readonly GATE_ENV_SHA256=08392d72874da4f88c619ee717f2b4a5f28ba0534ff8cf1083fb2edc37d6475f
readonly GATE_PYTHON=/usr/bin/python3.14
readonly GATE_PYTHON_SHA256=d78f9cf7178ecff09963551399855543c297f37ac207e626228bfe43cb26a70c
readonly GATE_BASH=/usr/bin/bash
readonly GATE_BASH_SHA256=575e03ac834b739349a4484de481abcd06a6f7193cefc795260a32a1943f20a5
readonly GATE_SYSTEMCTL=/usr/bin/systemctl
readonly GATE_SYSTEMCTL_SHA256=afe98ef3d55f504b37c6e7eb7da21a639ae7fb558f4c9024c89abb580a703255
readonly GATE_JOURNALCTL=/usr/bin/journalctl
readonly GATE_JOURNALCTL_SHA256=633f2411b9b3c4e3a21e26669512a7b8578591963dacd8fd139ddc9534eebd34

readonly SEALED_REPLAY_EXEC='import fcntl,hashlib,json,os,re,stat,subprocess,sys
op,manifest_path,manifest_sha,approval_path,approval_sha,launcher_sha=sys.argv[1:]
runtime_env={"HOME":"/home/wilf","USER":"wilf","LOGNAME":"wilf","LANG":"C.UTF-8","PATH":"/usr/bin:/bin","XDG_RUNTIME_DIR":"/run/user/1000","DBUS_SESSION_BUS_ADDRESS":"unix:path=/run/user/1000/bus"}
required_seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
def strict_pairs(pairs):
    result={}
    for key,value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key]=value
    return result
def open_exact(path,expected,mode=None):
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    st=os.fstat(fd)
    if not (stat.S_ISREG(st.st_mode) and st.st_uid==1000 and st.st_nlink==1):
        raise SystemExit(66)
    if mode is not None and stat.S_IMODE(st.st_mode)!=mode:
        raise SystemExit(66)
    chunks=[]
    while True:
        chunk=os.read(fd,1048576)
        if not chunk:
            break
        chunks.append(chunk)
    data=b"".join(chunks)
    if len(data)!=st.st_size or hashlib.sha256(data).hexdigest()!=expected:
        raise SystemExit(65)
    current=os.stat(path,follow_symlinks=False)
    if (current.st_dev,current.st_ino,current.st_uid,current.st_nlink,stat.S_IMODE(current.st_mode))!=(st.st_dev,st.st_ino,st.st_uid,st.st_nlink,stat.S_IMODE(st.st_mode)):
        raise SystemExit(73)
    return fd,st,data
def seal_bytes(name,data):
    fd=os.memfd_create(name,os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
    view=memoryview(data)
    while view:
        written=os.write(fd,view)
        if written<=0:
            raise SystemExit(74)
        view=view[written:]
    os.fsync(fd)
    os.lseek(fd,0,os.SEEK_SET)
    fcntl.fcntl(fd,fcntl.F_ADD_SEALS,required_seals)
    if fcntl.fcntl(fd,fcntl.F_GET_SEALS)!=required_seals:
        raise SystemExit(74)
    return fd
manifest_source_fd,manifest_stat,manifest_bytes=open_exact(manifest_path,manifest_sha)
approval_source_fd,approval_stat,approval_bytes=open_exact(approval_path,approval_sha,0o600)
manifest=json.loads(manifest_bytes.decode("utf-8"),object_pairs_hook=strict_pairs)
approval=json.loads(approval_bytes.decode("utf-8"),object_pairs_hook=strict_pairs)
if not (manifest.get("schema_version")==1 and manifest.get("state")=="viewflow-failed-v13-abort-replay16-command-manifest" and manifest.get("execution_authorized") is False and manifest.get("operation_id")==op and manifest.get("recovery_boundary")=="post-vfdqa-committed-pre-terminal-transition"):
    raise SystemExit(67)
expected_manifest_keys={"abort_replay_policy","committed_abort","execution_authorized","existing_outputs","failed_deskflow_gate","fresh_transition","immutable_base_plan","immutable_gates","live_viewflow_gate","operation_id","prior_replay","recovery_boundary","reviewed_replay","schema_version","sealed_inputs","state"}
if set(manifest)!=expected_manifest_keys:
    raise SystemExit(67)
policy=manifest.get("abort_replay_policy",{})
if policy!={"abort_command_forbidden":True,"pinned_query_required":True,"marker_required_absent":True,"abort_claim_required_absent":True,"release_claim_required_absent":True,"runtime_marker_required_absent":True}:
    raise SystemExit(67)
expected_approval_keys={"abort_authorization_sha256","approved","approved_at_utc","checker_sha256","coordinator_sha256","durable_abort_receipt_sha256","launcher_sha256","local_abort_receipt_sha256","negative_test_sha256","operation_id","prior_approval_sha256","publication_method","replay_manifest_sha256","schema_version","semantic_test_sha256","slot_cleanup_receipt_sha256","state","terminal_state_sha256","transient_adoption_test_sha256"}
if not (set(approval)==expected_approval_keys and approval.get("schema_version")==16 and approval.get("state")=="viewflow-failed-v13-abort-replay16-execution-approved" and approval.get("approved") is True and approval.get("operation_id")==op and approval.get("publication_method")=="create-once-no-replace-and-parent-fsync"):
    raise SystemExit(67)
if not isinstance(approval.get("approved_at_utc"),str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",approval["approved_at_utc"]) is None:
    raise SystemExit(67)
reviewed=manifest["reviewed_replay"]
committed=manifest["committed_abort"]
gates=manifest["immutable_gates"]
prior=manifest["prior_replay"]
approval_expected={
    "replay_manifest_sha256":manifest_sha,"launcher_sha256":launcher_sha,
    "coordinator_sha256":reviewed["coordinator_sha256"],"checker_sha256":reviewed["checker_sha256"],
    "semantic_test_sha256":reviewed["semantic_test_sha256"],"negative_test_sha256":reviewed["negative_test_sha256"],
    "transient_adoption_test_sha256":reviewed["transient_adoption_test_sha256"],
    "prior_approval_sha256":prior["approval_sha256"],"terminal_state_sha256":gates["terminal_state_sha256"],
    "slot_cleanup_receipt_sha256":gates["slot_cleanup_receipt_sha256"],
    "abort_authorization_sha256":committed["authorization_sha256"],
    "local_abort_receipt_sha256":committed["local_receipt_sha256"],
    "durable_abort_receipt_sha256":committed["durable_receipt_sha256"]}
if any(approval.get(key)!=value for key,value in approval_expected.items()):
    raise SystemExit(67)
sealed={manifest_path:(seal_bytes("viewflow-replay16-manifest",manifest_bytes),manifest_source_fd,manifest_stat,manifest_bytes),approval_path:(seal_bytes("viewflow-replay16-approval",approval_bytes),approval_source_fd,approval_stat,approval_bytes)}
paths=set()
for entry in manifest.get("sealed_inputs",[]):
    if not isinstance(entry,dict) or set(entry)!={"path","sha256"}:
        raise SystemExit(67)
    path=entry.get("path"); expected=entry.get("sha256")
    if not isinstance(path,str) or not path.startswith("/") or path in paths or not isinstance(expected,str) or len(expected)!=64:
        raise SystemExit(67)
    paths.add(path)
    source_fd,source_stat,data=open_exact(path,expected,0o600 if path==prior["approval_path"] else None)
    sealed[path]=(seal_bytes("viewflow-replay16-input",data),source_fd,source_stat,data)
required_paths={manifest["immutable_base_plan"]["path"],reviewed["coordinator_path"],reviewed["checker_path"],reviewed["semantic_test_path"],reviewed["negative_test_path"],reviewed["transient_adoption_test_path"],gates["terminal_state_path"],gates["slot_cleanup_receipt_path"],committed["authorization_path"],committed["local_receipt_path"],committed["durable_receipt_path"],prior["approval_path"]}|{entry["path"] for entry in manifest["existing_outputs"]}
if not required_paths.issubset(paths):
    raise SystemExit(67)
def blob(path):
    return sealed[path][3]
plan=json.loads(blob(manifest["immutable_base_plan"]["path"]).decode("utf-8"),object_pairs_hook=strict_pairs)
argv=plan.get("argv")
if not (plan.get("state")=="viewflow-failed-v13-abort-command-plan" and plan.get("execution_authorized") is False and plan.get("operation_id")==op and isinstance(argv,list) and len(argv)>2 and argv[0]==reviewed["coordinator_path"] and argv[1]=="--abort-failed-v13"):
    raise SystemExit(67)
if argv[argv.index("--deployment-abort-receipt")+1]!=committed["local_receipt_path"] or argv[argv.index("--failed-v13-abort-transition-receipt")+1]!=manifest["fresh_transition"]["path"]:
    raise SystemExit(67)
expected_existing={
    "/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/linux-v13-started.json":"a6cb9399aeaa379f8359b9db4cb5db144d4b87d5d7fa315c07458587a00bc3c9",
    "/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/windows-v13-started.json":"9426a4a22dafbc0f5283d69162bbcc04bf4819ccecde124f2628c1c0212ca763",
    "/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/authenticated-v13-peer.json":"606be9ef6c3788211088859e7cba31eb7a5b037f9cbceaf4cb13192f27b29a61",
    "/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/failed-v13-abort-authorization.json":"1c7ea381dc11e1ae75868d3d4b44e8e289d84a1d82153f157f58c1cfa42e2202",
    "/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/failed-v13-abort-receipt.json":"e63d46c9f211e32a1e8401f258d0849f48c641edd48bdbf31a591dee5ca5e42c"}
existing=manifest.get("existing_outputs")
if not isinstance(existing,list) or len(existing)!=5 or any(not isinstance(entry,dict) or set(entry)!={"path","sha256"} for entry in existing):
    raise SystemExit(67)
existing_map={entry["path"]:entry["sha256"] for entry in existing}
if len(existing_map)!=5 or existing_map!=expected_existing:
    raise SystemExit(67)
terminal_inputs=plan.get("terminal_inputs")
restored_linux=plan.get("restored_linux_gate")
if not isinstance(terminal_inputs,list) or len(terminal_inputs)!=8 or any(not isinstance(entry,dict) or set(entry)!={"path","sha256"} for entry in terminal_inputs):
    raise SystemExit(67)
if not isinstance(restored_linux,dict) or set(restored_linux)!={"viewflowd","deployment_marker_tool","deskflow","deskflow_core","viewflow_unit","deskflow_dropin"} or any(not isinstance(entry,dict) or set(entry)!={"path","sha256"} for entry in restored_linux.values()):
    raise SystemExit(67)
expected_sealed={manifest["immutable_base_plan"]["path"]:manifest["immutable_base_plan"]["sha256"],prior["approval_path"]:prior["approval_sha256"],reviewed["coordinator_path"]:reviewed["coordinator_sha256"],reviewed["checker_path"]:reviewed["checker_sha256"],reviewed["semantic_test_path"]:reviewed["semantic_test_sha256"],reviewed["negative_test_path"]:reviewed["negative_test_sha256"],reviewed["transient_adoption_test_path"]:reviewed["transient_adoption_test_sha256"],gates["terminal_state_path"]:gates["terminal_state_sha256"],gates["slot_cleanup_receipt_path"]:gates["slot_cleanup_receipt_sha256"],committed["durable_receipt_path"]:committed["durable_receipt_sha256"]}
for entry in terminal_inputs:
    expected_sealed[entry["path"]]=entry["sha256"]
for entry in restored_linux.values():
    expected_sealed[entry["path"]]=entry["sha256"]
expected_sealed.update(expected_existing)
actual_sealed={entry["path"]:entry["sha256"] for entry in manifest["sealed_inputs"]}
if len(manifest["sealed_inputs"])!=29 or len(actual_sealed)!=29 or len(expected_sealed)!=29 or actual_sealed!=expected_sealed:
    raise SystemExit(67)
prior_approval=json.loads(blob(prior["approval_path"]).decode("utf-8"),object_pairs_hook=strict_pairs)
prior_keys={"active_marker_sha256","approved","approved_at_utc","archived_failed_authorization_sha256","checker_sha256","coordinator_sha256","launcher_sha256","negative_test_sha256","operation_id","prior_approval_sha256","publication_method","replay_manifest_sha256","schema_version","semantic_test_sha256","slot_cleanup_receipt_sha256","state","terminal_state_sha256"}
prior_expected={"active_marker_sha256":"0adec6f0c87081b352dacfef0d5ab2158145a149e4583b48239cc51fa55065e8","archived_failed_authorization_sha256":"8e3dc462ffd9e6ca409b99312382c40b9b42b4242245962fd1c78536277506f6","checker_sha256":"5ca036a87a14f6be412491eac3e8410ccd46447a00bcde43435b8ddeeb3e9e9c","coordinator_sha256":"a669a198156d112eecd59cdad160800dce8836aec73826964de0d057695eab94","launcher_sha256":prior["launcher_sha256"],"negative_test_sha256":"d23abfe5df340aba67dbf734c1a63d53ce47c2b9a8fb4f561b936991f5d82704","operation_id":op,"prior_approval_sha256":"d8c4703e94f8e1ceb5a8adc57b1af0af120880a6f3ccdab126f6e223ee318141","publication_method":"create-once-no-replace-and-parent-fsync","replay_manifest_sha256":prior["manifest_sha256"],"schema_version":15,"semantic_test_sha256":"d63ecf224ea07836187eaa50d8813ea88277b20ca60f1e112de07e52689769d9","slot_cleanup_receipt_sha256":gates["slot_cleanup_receipt_sha256"],"state":"viewflow-failed-v13-abort-replay15-execution-approved","terminal_state_sha256":gates["terminal_state_sha256"]}
if set(prior_approval)!=prior_keys or prior_approval.get("approved") is not True or any(prior_approval.get(key)!=value for key,value in prior_expected.items()) or not isinstance(prior_approval.get("approved_at_utc"),str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",prior_approval["approved_at_utc"]) is None:
    raise SystemExit(67)
authorization=json.loads(blob(committed["authorization_path"]).decode("utf-8"),object_pairs_hook=strict_pairs)
local_receipt=json.loads(blob(committed["local_receipt_path"]).decode("utf-8"),object_pairs_hook=strict_pairs)
durable=blob(committed["durable_receipt_path"])
if not (authorization.get("state")=="viewflow-deployment-quarantine-abort-authorized" and authorization.get("operation_id")==op and authorization.get("marker_sha256")==committed["marker_sha256"]):
    raise SystemExit(67)
if not (local_receipt.get("state")=="deployment-quarantine-aborted" and local_receipt.get("operation_id")==op and local_receipt.get("abort_authorization_sha256")==committed["authorization_sha256"] and local_receipt.get("aborted_marker_sha256")==committed["marker_sha256"] and local_receipt.get("abort_receipt_path")==committed["durable_receipt_path"] and local_receipt.get("replayed") is False):
    raise SystemExit(67)
if not (len(durable)==384 and durable[:8]==b"VFDQA001" and durable[16:24]==b"VFDQT001" and hashlib.sha256(durable[16:272]).hexdigest()==committed["marker_sha256"] and durable[272:304].hex()==committed["marker_sha256"] and durable[304:336].hex()==committed["authorization_sha256"] and hashlib.sha256(durable[:352]).digest()==durable[352:384]):
    raise SystemExit(67)
absent=[gates["active_marker_path"],gates["abort_claim_path"],gates["release_claim_path"],gates["runtime_marker_path"],gates["release_receipt_path"],gates["recovery_publish_receipt_path"],manifest["fresh_transition"]["path"]]
def validate_absent():
    if any(os.path.lexists(path) for path in absent):
        raise SystemExit(69)
def unit_value(unit,name):
    return subprocess.check_output(["/usr/bin/systemctl","--user","show","--property",name,"--value",unit],env=runtime_env,text=True).strip()
def validate_viewflow():
    gate=manifest["live_viewflow_gate"]; unit=gate["unit"]
    if [unit_value(unit,name) for name in ("LoadState","ActiveState","SubState","Transient","KillMode","InvocationID","ControlGroup")]!=["loaded","active","running","yes","control-group",gate["invocation_id"],gate["control_group"]]:
        raise SystemExit(68)
    pid=int(unit_value(unit,"MainPID"))
    if pid!=gate["main_pid"]:
        raise SystemExit(68)
    with open(f"/proc/{pid}/stat","r",encoding="ascii") as stream:
        fields=stream.read().strip().rsplit(") ",1)[1].split()
    if int(fields[19])!=gate["start_ticks"]:
        raise SystemExit(68)
    with open(f"/proc/{pid}/cgroup","r",encoding="ascii") as stream:
        groups=[line.rstrip("\n").split(":",2)[2] for line in stream if line.startswith("0::")]
    if groups!=[gate["control_group"]]:
        raise SystemExit(68)
    with open(f"/proc/{pid}/exe","rb") as stream:
        digest=hashlib.file_digest(stream,"sha256").hexdigest()
    if digest!=gate["executable_sha256"]:
        raise SystemExit(68)
def validate_failed_deskflow():
    gate=manifest["failed_deskflow_gate"]; unit=gate["unit"]
    names=("LoadState","ActiveState","SubState","Result","ExecMainCode","ExecMainStatus","MainPID","ControlGroup","InvocationID")
    expected=[gate["load_state"],gate["active_state"],gate["sub_state"],gate["result"],gate["exec_main_code"],gate["exec_main_status"],str(gate["main_pid"]),gate["control_group"],gate["invocation_id"]]
    if [unit_value(unit,name) for name in names]!=expected:
        raise SystemExit(68)
    exec_start=subprocess.check_output(["/usr/bin/systemctl","--user","show","--property","ExecStart","--value",unit],env=runtime_env)
    if hashlib.sha256(exec_start).hexdigest()!=gate["exec_start_observation_sha256"]:
        raise SystemExit(68)
    output=subprocess.check_output(["/usr/bin/journalctl","--user","--quiet","--output","json","--all",f"_SYSTEMD_INVOCATION_ID={gate['"'"'invocation_id'"'"']}"] ,env=runtime_env)
    hits=[]
    fields=("MESSAGE","_SYSTEMD_INVOCATION_ID","_PID","_UID","_GID","_COMM","_EXE","_SYSTEMD_USER_UNIT","__CURSOR","__REALTIME_TIMESTAMP","__MONOTONIC_TIMESTAMP")
    for line in output.splitlines():
        record=json.loads(line)
        if record.get("MESSAGE")==gate["fatal_message"]:
            canonical=json.dumps({key:record.get(key) for key in fields},ensure_ascii=False,separators=(",",":"),sort_keys=True).encode("utf-8")
            if record.get("__CURSOR")==gate["fatal_record_cursor"] and hashlib.sha256(canonical).hexdigest()==gate["fatal_record_sha256"]:
                hits.append(canonical)
    if len(hits)!=1:
        raise SystemExit(68)
def reattest_sources():
    for path,(sealed_fd,source_fd,source_stat,data) in sealed.items():
        if fcntl.fcntl(sealed_fd,fcntl.F_GET_SEALS)!=required_seals:
            raise SystemExit(74)
        st=os.fstat(source_fd)
        current=os.stat(path,follow_symlinks=False)
        if (st.st_dev,st.st_ino,st.st_uid,st.st_nlink,st.st_size)!=(source_stat.st_dev,source_stat.st_ino,source_stat.st_uid,source_stat.st_nlink,source_stat.st_size) or (current.st_dev,current.st_ino)!=(st.st_dev,st.st_ino):
            raise SystemExit(73)
        if hashlib.sha256(os.pread(source_fd,st.st_size,0)).digest()!=hashlib.sha256(data).digest():
            raise SystemExit(65)
def run_script(path,args,extra_env=None):
    fd=sealed[path][0]; os.set_inheritable(fd,True)
    env=dict(runtime_env)
    if extra_env:
        env.update(extra_env)
    subprocess.run(["/usr/bin/bash",f"/proc/self/fd/{fd}",*args],env=env,pass_fds=tuple(item[0] for item in sealed.values()),check=True,stdout=subprocess.DEVNULL)
validate_absent();validate_viewflow();validate_failed_deskflow();reattest_sources()
coordinator=reviewed["coordinator_path"];checker=reviewed["checker_path"];semantic=reviewed["semantic_test_path"];negative=reviewed["negative_test_path"];adoption=reviewed["transient_adoption_test_path"]
coordinator_fd=sealed[coordinator][0];checker_fd=sealed[checker][0];semantic_fd=sealed[semantic][0]
run_script(checker,[f"/proc/self/fd/{coordinator_fd}"])
run_script(adoption,[f"/proc/self/fd/{coordinator_fd}"])
run_script(semantic,[f"/proc/self/fd/{coordinator_fd}"],{"CROSS_HOST_COORDINATOR_CHECKER":f"/proc/self/fd/{checker_fd}"})
run_script(negative,[],{"CROSS_HOST_COORDINATOR_SOURCE":f"/proc/self/fd/{coordinator_fd}","CROSS_HOST_COORDINATOR_CHECKER":f"/proc/self/fd/{checker_fd}","CROSS_HOST_COORDINATOR_SEMANTIC_TEST":f"/proc/self/fd/{semantic_fd}"})
validate_absent();validate_viewflow();validate_failed_deskflow();reattest_sources()
os.set_inheritable(coordinator_fd,True)
keep={coordinator_fd}
for path,(sealed_fd,source_fd,source_stat,data) in sealed.items():
    if sealed_fd not in keep:
        os.close(sealed_fd)
    os.close(source_fd)
limit=os.sysconf("SC_OPEN_MAX")
os.closerange(3,coordinator_fd)
os.closerange(coordinator_fd+1,limit)
os.execve("/usr/bin/bash",["/usr/bin/bash",f"/proc/self/fd/{coordinator_fd}",*argv[1:]],runtime_env)'

approval_sha256=''
sealed_launcher_sha256=''
die() { printf 'failed-v13 replay16 launcher: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d ' ' -f 1; }
require_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]] || die 'SHA argument must be lowercase SHA-256'; }

while (($#)); do
    case $1 in
        --approval-sha256) (($# >= 2)) || die '--approval-sha256 requires a value'; approval_sha256=$2; shift 2 ;;
        --sealed-launcher-sha256) (($# >= 2)) || die '--sealed-launcher-sha256 requires a value'; sealed_launcher_sha256=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
require_sha256 "$approval_sha256"
require_sha256 "$sealed_launcher_sha256"
[[ $(id -u) == 1000 && $HOME == /home/wilf ]] || die 'run as uid 1000 with HOME=/home/wilf'
launcher_source=${BASH_SOURCE[0]}
[[ $launcher_source =~ ^/proc/self/fd/([0-9]+)$ ]] || die 'launcher must run from an inherited sealed FD'
launcher_fd=${BASH_REMATCH[1]}
"$GATE_PYTHON" -I -E -c 'import fcntl,hashlib,os,sys
fd=int(sys.argv[1]);expected=sys.argv[2];st=os.fstat(fd);offset=0;digest=hashlib.sha256()
while offset<st.st_size:
    chunk=os.pread(fd,min(1048576,st.st_size-offset),offset)
    if not chunk: raise SystemExit(1)
    digest.update(chunk);offset+=len(chunk)
required=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
raise SystemExit(0 if offset==st.st_size and digest.hexdigest()==expected and fcntl.fcntl(fd,fcntl.F_GET_SEALS)==required else 1)' "$launcher_fd" "$sealed_launcher_sha256" ||
    die 'inherited launcher FD bytes/seals differ from approved SHA'
for runtime_spec in \
    "$GATE_ENV:$GATE_ENV_SHA256" "$GATE_PYTHON:$GATE_PYTHON_SHA256" "$GATE_BASH:$GATE_BASH_SHA256" \
    "$GATE_SYSTEMCTL:$GATE_SYSTEMCTL_SHA256" "$GATE_JOURNALCTL:$GATE_JOURNALCTL_SHA256"; do
    runtime_path=${runtime_spec%%:*}; runtime_sha=${runtime_spec#*:}
    [[ $(stat -c '%u:%g:%a:%h' -- "$runtime_path") == 0:0:755:1 && $(sha256 "$runtime_path") == "$runtime_sha" ]] ||
        die "root-owned runtime differs: $runtime_path"
done
[[ -f $MANIFEST && ! -L $MANIFEST && $(stat -c '%u:%a:%h' -- "$MANIFEST") == 1000:600:1 && $(sha256 "$MANIFEST") == "$MANIFEST_SHA256" ]] ||
    die 'replay16 manifest identity differs'
[[ -f $APPROVAL && ! -L $APPROVAL && $(stat -c '%u:%a:%h' -- "$APPROVAL") == 1000:600:1 && $(sha256 "$APPROVAL") == "$approval_sha256" ]] ||
    die 'replay16 approval is absent, unsafe, or differs'
exec "$GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \
    "$GATE_PYTHON" -I -E -c "$SEALED_REPLAY_EXEC" "$OPERATION_ID" \
    "$MANIFEST" "$MANIFEST_SHA256" "$APPROVAL" "$approval_sha256" "$sealed_launcher_sha256"
