#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

readonly OPERATION_ID=55d06e8f96aa4adc9010e53612979374
readonly MANIFEST=/home/wilf/data/viewflow/deploy/failed-pre-mutation-abort-55d06e8f-schema2-manifest.json
readonly MANIFEST_SHA256=916d78ac65862daca2c78aedf3536d67a44ee0c40fe69d420d46b0c5f9954378
readonly APPROVAL=/home/wilf/.local/state/viewflow/deployments/55d06e8f96aa4adc9010e53612979374/failed-pre-mutation-abort-schema2-execution-approval.json
readonly GATE_PYTHON=/usr/bin/python3.14
readonly GATE_PYTHON_SHA256=d78f9cf7178ecff09963551399855543c297f37ac207e626228bfe43cb26a70c
readonly GATE_BASH=/usr/bin/bash
readonly GATE_BASH_SHA256=575e03ac834b739349a4484de481abcd06a6f7193cefc795260a32a1943f20a5

readonly SEALED_SCHEMA2_EXEC='import fcntl,hashlib,json,os,re,stat,subprocess,sys
op,manifest_path,manifest_sha,approval_path,approval_sha,launcher_sha,gate_sha,mode=sys.argv[1:]
if mode not in {"offline-host-preflight","sandbox-preflight","execute"}:
    raise SystemExit(64)
runtime_env={"HOME":"/home/wilf","USER":"wilf","LOGNAME":"wilf","LANG":"C.UTF-8","PATH":"/usr/bin:/bin","XDG_RUNTIME_DIR":"/run/user/1000","DBUS_SESSION_BUS_ADDRESS":"unix:path=/run/user/1000/bus"}
required_seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
def strict_pairs(pairs):
    result={}
    for key,value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key]=value
    return result
def open_exact(path,expected,expected_mode):
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    st=os.fstat(fd)
    if not (stat.S_ISREG(st.st_mode) and st.st_uid==1000 and st.st_nlink==1 and stat.S_IMODE(st.st_mode)==expected_mode):
        raise SystemExit(66)
    data=b""
    while len(data)<st.st_size:
        chunk=os.read(fd,min(1048576,st.st_size-len(data)))
        if not chunk:
            raise SystemExit(65)
        data+=chunk
    if len(data)!=st.st_size or hashlib.sha256(data).hexdigest()!=expected:
        raise SystemExit(65)
    current=os.stat(path,follow_symlinks=False)
    if (current.st_dev,current.st_ino,current.st_uid,current.st_nlink,stat.S_IMODE(current.st_mode),current.st_size)!=(st.st_dev,st.st_ino,st.st_uid,st.st_nlink,stat.S_IMODE(st.st_mode),st.st_size):
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
    os.fsync(fd);os.lseek(fd,0,os.SEEK_SET)
    fcntl.fcntl(fd,fcntl.F_ADD_SEALS,required_seals)
    if fcntl.fcntl(fd,fcntl.F_GET_SEALS)!=required_seals:
        raise SystemExit(74)
    return fd
manifest_source_fd,manifest_stat,manifest_bytes=open_exact(manifest_path,manifest_sha,0o600)
manifest=json.loads(manifest_bytes.decode("utf-8"),object_pairs_hook=strict_pairs)
expected_manifest_keys={"active_marker_gate","approval","argv","execution_authorized","fresh_outputs","immutable_terminal_inputs","installed_v13_inputs","marker_candidate","operation_id","required_absent","reviewed_code","schema_version","state","threat_boundary"}
if not (set(manifest)==expected_manifest_keys and manifest.get("schema_version")==2 and manifest.get("state")=="viewflow-failed-pre-mutation-abort-schema2-command-manifest" and manifest.get("execution_authorized") is False and manifest.get("operation_id")==op and manifest.get("threat_boundary")=="cooperating-crash-and-non-owner"):
    raise SystemExit(67)
if manifest.get("approval")!={"path":approval_path,"required_absent_before_publication":True}:
    raise SystemExit(67)
reviewed=manifest["reviewed_code"]
if set(reviewed)!={"coordinator","checker","semantic_test","negative_test"} or any(set(item)!={"path","sha256"} for item in reviewed.values()):
    raise SystemExit(67)
candidate=manifest["marker_candidate"]
if set(candidate)!={"path","sha256"}:
    raise SystemExit(67)
terminal=manifest["immutable_terminal_inputs"]
installed=manifest["installed_v13_inputs"]
if not (isinstance(terminal,list) and len(terminal)==8 and isinstance(installed,list) and len(installed)==6):
    raise SystemExit(67)
entries=[]
for item in [*reviewed.values(),candidate,*terminal,*installed]:
    if set(item) not in ({"path","sha256"},{"path","sha256","mode"}):
        raise SystemExit(67)
    path=item["path"];expected=item["sha256"];expected_mode=item.get("mode",755)
    if not (isinstance(path,str) and path.startswith("/") and isinstance(expected,str) and re.fullmatch(r"[0-9a-f]{64}",expected) and expected_mode in (600,644,755)):
        raise SystemExit(67)
    entries.append((path,expected,int(str(expected_mode),8)))
if len({path for path,_,_ in entries})!=len(entries):
    raise SystemExit(67)
active=manifest["active_marker_gate"]
if active!={"path":"/home/wilf/.local/state/viewflow/deployment-quarantine.v1","sha256":"eaeb8dd37fed10a957be5662ed9305783be2252b7fec345d72c184e7522a1ab6","mode":600,"generation":"1"}:
    raise SystemExit(67)
entries.append((active["path"],active["sha256"],0o600))
sealed={manifest_path:(seal_bytes("viewflow-schema2-manifest",manifest_bytes),manifest_source_fd,manifest_stat,manifest_bytes)}
for path,expected,expected_mode in entries:
    source_fd,source_stat,data=open_exact(path,expected,expected_mode)
    sealed[path]=(seal_bytes("viewflow-schema2-input",data),source_fd,source_stat,data)
state_path=terminal[0]["path"]
state=json.loads(sealed[state_path][3].decode("utf-8"),object_pairs_hook=strict_pairs)
expected_committed={"bootstrap_request":"d18ec8bf306b733db8fbf808e95dd673f724af53c2cf382d96ded9c074b772e0","linux_frozen":"427d65f908b565cf0e97460e0c199d49ff8bc8488d70b60048bdd32bd855d471","marker_handoff":"d64a93859f54a939d9dd51b405f647491381a5a3d0ed726bc1a90d16da1068bd","pre_mutation_retry":"22959074134ea02c7e4a7f13fdd5878575d42d319ed100938ce64a2b538af6fa","publish_receipt":"d2335b8961dc469f0252fa9e7e0600952b2b93a72dd738c89ec539f48ba19b21","windows_exit":"f8eacf7fe0803c1f51866037c29546cf0c23396e995aede71be819d11739e0c3","windows_stop_evidence":"f7eec7384cc5b3c0f81887edb8f34a6cd605a662298d6880b2ed5663d33fd777"}
if not (set(state)=={"committed_artifacts","contract","operation_id","phase","recovery","schema_version","state"} and state.get("schema_version")==2 and state.get("state")=="viewflow-cross-host-bootstrap" and state.get("operation_id")==op and state.get("phase")=="LINUX_RECOVERED" and state.get("recovery")=={"failure_phase":"WINDOWS_STARTED","mutation_possible":False} and state.get("committed_artifacts")==expected_committed):
    raise SystemExit(67)
outputs=manifest["fresh_outputs"]
expected_output_keys={"abort_receipt","authenticated_peer","authorization","linux_started","terminal","windows_live","windows_started"}
if set(outputs)!=expected_output_keys or len(set(outputs.values()))!=7 or any(not isinstance(path,str) or not path.startswith("/home/wilf/.local/state/viewflow/deployments/"+op+"/") for path in outputs.values()):
    raise SystemExit(67)
required_absent=manifest["required_absent"]
if not isinstance(required_absent,list) or len(required_absent)!=7 or len(set(required_absent))!=7:
    raise SystemExit(67)
argv=manifest["argv"]
if not (isinstance(argv,list) and len(argv)>=3 and argv[0]==reviewed["coordinator"]["path"] and argv[1]=="--abort-failed-v13-pre-mutation" and "--abort-failed-v13" not in argv and "--failed-v13-original-generation-only" in argv):
    raise SystemExit(67)
def arg(name):
    if argv.count(name)!=1:
        raise SystemExit(67)
    return argv[argv.index(name)+1]
bindings={"--operation-id":op,"--old-coordinator-state-sha256":"553b49cbc0f63b5586c959e9e2e0a7e53c9a44672b7e555cb5f3602a3dc6972f","--pre-mutation-abort-marker-cli-candidate":candidate["path"],"--pre-mutation-abort-marker-cli-sha256":candidate["sha256"],"--pre-mutation-windows-live-proof":outputs["windows_live"],"--windows-v13-started-receipt":outputs["windows_started"],"--linux-v13-started-receipt":outputs["linux_started"],"--authenticated-v13-peer-receipt":outputs["authenticated_peer"],"--deployment-abort-authorization":outputs["authorization"],"--deployment-abort-receipt":outputs["abort_receipt"],"--failed-v13-abort-transition-receipt":outputs["terminal"]}
if any(arg(name)!=value for name,value in bindings.items()):
    raise SystemExit(67)
def validate_absent(include_approval):
    absent=[*required_absent,*outputs.values()]
    if include_approval:
        absent.append(approval_path)
    if any(os.path.lexists(path) for path in absent):
        raise SystemExit(69)
def reattest_sources():
    for path,(sealed_fd,source_fd,source_stat,data) in sealed.items():
        if fcntl.fcntl(sealed_fd,fcntl.F_GET_SEALS)!=required_seals:
            raise SystemExit(74)
        st=os.fstat(source_fd);current=os.stat(path,follow_symlinks=False)
        if (st.st_dev,st.st_ino,st.st_uid,st.st_nlink,st.st_size,stat.S_IMODE(st.st_mode))!=(source_stat.st_dev,source_stat.st_ino,source_stat.st_uid,source_stat.st_nlink,source_stat.st_size,stat.S_IMODE(source_stat.st_mode)) or (current.st_dev,current.st_ino)!=(st.st_dev,st.st_ino):
            raise SystemExit(73)
        if hashlib.sha256(os.pread(source_fd,st.st_size,0)).digest()!=hashlib.sha256(data).digest():
            raise SystemExit(65)
def run_script(path,args,extra_env=None):
    fd=sealed[path][0];os.set_inheritable(fd,True)
    env=dict(runtime_env)
    if extra_env: env.update(extra_env)
    subprocess.run(["/usr/bin/bash",f"/proc/self/fd/{fd}",*args],env=env,pass_fds=tuple(item[0] for item in sealed.values()),check=True,stdout=subprocess.DEVNULL)
validate_absent(mode=="offline-host-preflight");reattest_sources()
coordinator=reviewed["coordinator"]["path"];checker=reviewed["checker"]["path"];semantic=reviewed["semantic_test"]["path"];negative=reviewed["negative_test"]["path"]
coordinator_fd=sealed[coordinator][0];checker_fd=sealed[checker][0];semantic_fd=sealed[semantic][0]
subprocess.run(["/usr/bin/bash","-n",f"/proc/self/fd/{coordinator_fd}"],env=runtime_env,pass_fds=(coordinator_fd,),check=True)
if mode!="sandbox-preflight":
    run_script(checker,[f"/proc/self/fd/{coordinator_fd}"])
    run_script(semantic,[f"/proc/self/fd/{coordinator_fd}"],{"CROSS_HOST_COORDINATOR_CHECKER":f"/proc/self/fd/{checker_fd}"})
    run_script(negative,[],{"CROSS_HOST_COORDINATOR_SOURCE":f"/proc/self/fd/{coordinator_fd}","CROSS_HOST_COORDINATOR_CHECKER":f"/proc/self/fd/{checker_fd}","CROSS_HOST_COORDINATOR_SEMANTIC_TEST":f"/proc/self/fd/{semantic_fd}"})
validate_absent(mode=="offline-host-preflight");reattest_sources()
if mode in {"offline-host-preflight","sandbox-preflight"}:
    print("schema2 abort sealed-FD "+mode+" passed")
    raise SystemExit(0)
approval_source_fd,approval_stat,approval_bytes=open_exact(approval_path,approval_sha,0o600)
approval=json.loads(approval_bytes.decode("utf-8"),object_pairs_hook=strict_pairs)
approval_keys={"approved","approved_at_utc","coordinator_sha256","gate_sha256","launcher_sha256","manifest_sha256","marker_candidate_sha256","operation_id","publication_method","schema_version","state","terminal_state_sha256"}
expected={"schema_version":2,"state":"viewflow-failed-pre-mutation-abort-schema2-execution-approved","approved":True,"operation_id":op,"manifest_sha256":manifest_sha,"launcher_sha256":launcher_sha,"gate_sha256":gate_sha,"coordinator_sha256":reviewed["coordinator"]["sha256"],"marker_candidate_sha256":candidate["sha256"],"terminal_state_sha256":"553b49cbc0f63b5586c959e9e2e0a7e53c9a44672b7e555cb5f3602a3dc6972f","publication_method":"create-once-no-replace-and-parent-fsync"}
if set(approval)!=approval_keys or any(approval.get(key)!=value for key,value in expected.items()) or not isinstance(approval.get("approved_at_utc"),str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",approval["approved_at_utc"]) is None:
    raise SystemExit(67)
reattest_sources()
os.set_inheritable(coordinator_fd,True)
for path,(sealed_fd,source_fd,source_stat,data) in sealed.items():
    if sealed_fd!=coordinator_fd: os.close(sealed_fd)
    os.close(source_fd)
os.close(approval_source_fd)
limit=os.sysconf("SC_OPEN_MAX");os.closerange(3,coordinator_fd);os.closerange(coordinator_fd+1,limit)
os.execve("/usr/bin/bash",["/usr/bin/bash",f"/proc/self/fd/{coordinator_fd}",*argv[1:]],runtime_env)'

mode='' approval_sha256='' launcher_sha256='' gate_sha256=''
die() { printf 'schema2 abort launcher: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d ' ' -f 1; }
require_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]] || die 'expected lowercase SHA-256'; }

while (($#)); do
    case $1 in
        --offline-host-preflight) mode=offline-host-preflight; shift ;;
        --sandbox-preflight) mode=sandbox-preflight; shift ;;
        --execute) mode=execute; shift ;;
        --approval-sha256) (($# >= 2)) || die 'missing approval SHA'; approval_sha256=$2; shift 2 ;;
        --launcher-sha256) (($# >= 2)) || die 'missing launcher SHA'; launcher_sha256=$2; shift 2 ;;
        --gate-sha256) (($# >= 2)) || die 'missing gate SHA'; gate_sha256=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ $mode == offline-host-preflight || $mode == sandbox-preflight || $mode == execute ]] || die 'select exactly one mode'
require_sha256 "$launcher_sha256"
require_sha256 "$gate_sha256"
if [[ $mode == execute ]]; then require_sha256 "$approval_sha256"; else approval_sha256=-; fi
[[ $(id -u) == 1000 && $HOME == /home/wilf ]] || die 'run as uid 1000 with HOME=/home/wilf'
if [[ $mode == sandbox-preflight ]]; then runtime_owner=65534:65534; else runtime_owner=0:0; fi
launcher_source=${BASH_SOURCE[0]}
[[ $launcher_source =~ ^/proc/self/fd/([0-9]+)$ ]] || die 'launcher must run from an inherited sealed FD'
launcher_fd=${BASH_REMATCH[1]}
"$GATE_PYTHON" -I -E -c 'import fcntl,hashlib,os,sys
fd=int(sys.argv[1]);expected=sys.argv[2];st=os.fstat(fd);data=os.pread(fd,st.st_size,0)
required=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
raise SystemExit(0 if hashlib.sha256(data).hexdigest()==expected and fcntl.fcntl(fd,fcntl.F_GET_SEALS)==required else 1)' "$launcher_fd" "$launcher_sha256" || die 'launcher FD bytes/seals differ'
for spec in "$GATE_PYTHON:$GATE_PYTHON_SHA256" "$GATE_BASH:$GATE_BASH_SHA256"; do
    runtime=${spec%%:*}; expected=${spec#*:}
    [[ $(stat -c '%u:%g:%a:%h' -- "$runtime") == "$runtime_owner:755:1" && $(sha256 "$runtime") == "$expected" ]] || die "trusted runtime differs: $runtime"
done
exec /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin "$GATE_PYTHON" -I -E -c "$SEALED_SCHEMA2_EXEC" \
    "$OPERATION_ID" "$MANIFEST" "$MANIFEST_SHA256" "$APPROVAL" "$approval_sha256" \
    "$launcher_sha256" "$gate_sha256" "$mode"
