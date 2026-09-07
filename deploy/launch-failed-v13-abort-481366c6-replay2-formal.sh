#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

readonly OPERATION_ID=481366c6c9654a679a96d4b6b1447ecb
readonly LAUNCHER=/home/wilf/data/viewflow/deploy/launch-failed-v13-abort-481366c6-replay2-formal.sh
readonly MANIFEST=/home/wilf/data/viewflow/deploy/failed-v13-abort-481366c6-replay2-manifest.json
readonly MANIFEST_SHA256=b9481e0989df914a0f0178e814a44f3786ba1d4be9d4bd3d58af65e0a5c3855a
readonly PLAN=/home/wilf/data/viewflow/deploy/failed-v13-abort-481366c6-args.json
readonly PLAN_SHA256=8f029bbb3d18abeaf5fe70d8bafcfbe3381e0aa84dbb88826f382032d6363b3d
readonly COORDINATOR=/home/wilf/data/viewflow/deploy/coordinated-v13-to-v2.sh
readonly COORDINATOR_SHA256=c049e6ab8e97ca73dfd51add93f5fcf8c3869551e3ba402fa7b70952d7f18d6d
readonly CHECKER=/home/wilf/data/viewflow/deploy/check-cross-host-coordinator.sh
readonly CHECKER_SHA256=fd91011e3fb0c4be57f5564e5d192f78eaf44456b16e2d0e98e0aebe7a6afc2e
readonly ADOPTION_TEST=/home/wilf/data/viewflow/deploy/tests/cross-host-coordinator-transient-adoption-test.sh
readonly ADOPTION_TEST_SHA256=6be2282f6a58684396f391cf955f70d05fe66153d6e98df443d64fa7821f7882
readonly APPROVAL=/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/failed-v13-abort-replay2-execution-approval.json
readonly PRIOR_APPROVAL=/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/failed-v13-abort-execution-approval.json
readonly PRIOR_APPROVAL_SHA256=d8c4703e94f8e1ceb5a8adc57b1af0af120880a6f3ccdab126f6e223ee318141
readonly TERMINAL_STATE=/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/coordinator-state.json
readonly TERMINAL_STATE_SHA256=83922f9e26a8e6c09d8363eab646f3143357b7859514e801f83d6f84b6128b8a
readonly SLOT_CLEANUP=/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/cleanup-attempt3-exchange-slots-complete.json
readonly SLOT_CLEANUP_SHA256=7c995aee63c51d12d0c1fc8436161b94f42161cbf21f435ffeb29548477bc96e
readonly ACTIVE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly ACTIVE_MARKER_SHA256=0adec6f0c87081b352dacfef0d5ab2158145a149e4583b48239cc51fa55065e8
readonly GATE_ENV=/usr/bin/env
readonly GATE_ENV_SHA256=08392d72874da4f88c619ee717f2b4a5f28ba0534ff8cf1083fb2edc37d6475f
readonly GATE_PYTHON=/usr/bin/python3.14
readonly GATE_PYTHON_SHA256=d78f9cf7178ecff09963551399855543c297f37ac207e626228bfe43cb26a70c
readonly GATE_BASH=/usr/bin/bash
readonly GATE_BASH_SHA256=575e03ac834b739349a4484de481abcd06a6f7193cefc795260a32a1943f20a5
readonly GATE_SYSTEMCTL=/usr/bin/systemctl
readonly GATE_SYSTEMCTL_SHA256=afe98ef3d55f504b37c6e7eb7da21a639ae7fb558f4c9024c89abb580a703255
readonly SEALED_REPLAY_EXEC='import fcntl,hashlib,json,os,stat,subprocess,sys
op,*raw=sys.argv[1:]
if len(raw)!=20:
    raise SystemExit(64)
def strict_pairs(pairs):
    out={}
    for key,value in pairs:
        if key in out:
            raise ValueError("duplicate key")
        out[key]=value
    return out
blobs={}
for index in range(0,len(raw),2):
    path,expected=raw[index:index+2]
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    st=os.fstat(fd)
    if not (stat.S_ISREG(st.st_mode) and st.st_uid==1000 and st.st_nlink==1):
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
    if (current.st_dev,current.st_ino,current.st_uid,current.st_nlink)!=(st.st_dev,st.st_ino,st.st_uid,st.st_nlink):
        raise SystemExit(73)
    os.close(fd)
    blobs[path]=data
coordinator,plan,approval,manifest=raw[0],raw[2],raw[4],raw[6]
approval_object=json.loads(blobs[approval].decode("utf-8"),object_pairs_hook=strict_pairs)
manifest_object=json.loads(blobs[manifest].decode("utf-8"),object_pairs_hook=strict_pairs)
plan_object=json.loads(blobs[plan].decode("utf-8"),object_pairs_hook=strict_pairs)
if not (approval_object.get("schema_version")==2 and approval_object.get("state")=="viewflow-failed-v13-abort-replay2-execution-approved" and approval_object.get("approved") is True and approval_object.get("operation_id")==op):
    raise SystemExit(67)
if not (manifest_object.get("state")=="viewflow-failed-v13-abort-replay2-command-manifest" and manifest_object.get("execution_authorized") is False and manifest_object.get("operation_id")==op):
    raise SystemExit(67)
argv=plan_object.get("argv")
if not (plan_object.get("state")=="viewflow-failed-v13-abort-command-plan" and plan_object.get("execution_authorized") is False and plan_object.get("operation_id")==op and isinstance(argv,list) and len(argv)>2 and argv[0]==coordinator and argv[1]=="--abort-failed-v13"):
    raise SystemExit(67)
runtime_env={"HOME":"/home/wilf","USER":"wilf","LOGNAME":"wilf","LANG":"C.UTF-8","PATH":"/usr/bin:/bin","XDG_RUNTIME_DIR":"/run/user/1000","DBUS_SESSION_BUS_ADDRESS":"unix:path=/run/user/1000/bus"}
def unit_value(unit,property_name):
    return subprocess.check_output(["/usr/bin/systemctl","--user","show","--property",property_name,"--value",unit],env=runtime_env,text=True).strip()
def validate_live_tuple():
    gate=manifest_object.get("live_adoption_gate",{})
    unit=gate.get("unit")
    pid=int(unit_value(unit,"MainPID"))
    if pid!=gate.get("main_pid"):
        raise SystemExit(68)
    with open(f"/proc/{pid}/stat","r",encoding="ascii") as stream:
        remainder=stream.read().strip().rsplit(") ",1)[1].split()
    if int(remainder[19])!=gate.get("start_ticks"):
        raise SystemExit(68)
    if unit_value(unit,"InvocationID")!=gate.get("invocation_id"):
        raise SystemExit(68)
    control_group=unit_value(unit,"ControlGroup")
    with open(f"/proc/{pid}/cgroup","r",encoding="ascii") as stream:
        process_groups=[line.rstrip("\n").split(":",2)[2] for line in stream if line.startswith("0::")]
    if process_groups!=[control_group] or control_group!=gate.get("control_group"):
        raise SystemExit(68)
    with open(f"/proc/{pid}/exe","rb") as stream:
        executable_sha=hashlib.file_digest(stream,"sha256").hexdigest()
    if executable_sha!=gate.get("executable_sha256"):
        raise SystemExit(68)
    if [unit_value(unit,name) for name in ("ActiveState","SubState","Transient","KillMode")]!=["active","running","yes","control-group"]:
        raise SystemExit(68)
validate_live_tuple()
exec_fd=os.memfd_create("viewflow-replay2-coordinator",os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
view=memoryview(blobs[coordinator])
while view:
    written=os.write(exec_fd,view)
    if written<=0:
        raise SystemExit(74)
    view=view[written:]
os.fsync(exec_fd)
os.lseek(exec_fd,0,os.SEEK_SET)
seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
fcntl.fcntl(exec_fd,fcntl.F_ADD_SEALS,seals)
if fcntl.fcntl(exec_fd,fcntl.F_GET_SEALS)!=seals:
    raise SystemExit(74)
os.set_inheritable(exec_fd,True)
limit=os.sysconf("SC_OPEN_MAX")
validate_live_tuple()
os.closerange(3,exec_fd)
os.closerange(exec_fd+1,limit)
os.execve("/usr/bin/bash",["/usr/bin/bash",f"/proc/self/fd/{exec_fd}",*argv[1:]],runtime_env)'

approval_sha256=''
die() { printf 'failed-v13 replay2 launcher: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d ' ' -f 1; }
require_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]] || die 'approval SHA must be lowercase SHA-256'; }
strict_json() {
    python3 -c 'import json,sys
def hook(pairs):
    out={}
    for key,value in pairs:
        if key in out: raise ValueError("duplicate key")
        out[key]=value
    return out
with open(sys.argv[1],"rb") as stream:
    data=stream.read()
if not data.endswith(b"\n") or data[:-1].endswith(b"\n"):
    raise SystemExit("noncanonical JSON framing")
json.loads(data.decode("utf-8"),object_pairs_hook=hook)' "$1" || die "$2 is not strict JSON"
}
require_regular_path_fd() {
    local label=$1 artifact_path=$2 fd=$3 expected_sha=$4 path_identity fd_identity
    [[ -f $artifact_path && ! -L $artifact_path ]] || die "$label path is absent or unsafe"
    path_identity=$(stat -c '%u:%h:%d:%i' -- "$artifact_path")
    fd_identity=$(stat -Lc '%u:%h:%d:%i' -- "/proc/$$/fd/$fd")
    [[ $path_identity == "$fd_identity" && $fd_identity == 1000:1:* ]] || die "$label FD/path identity differs"
    [[ $(sha256 "/proc/$$/fd/$fd") == "$expected_sha" ]] || die "$label SHA differs"
}
require_plan_artifact() {
    local label=$1 artifact_path=$2 expected_sha=$3
    [[ -f $artifact_path && ! -L $artifact_path && $(stat -c '%u:%h' -- "$artifact_path") == 1000:1 ]] ||
        die "$label path is absent or unsafe"
    [[ $(sha256 "$artifact_path") == "$expected_sha" ]] || die "$label SHA differs"
}
process_start_ticks() {
    local stat_line remainder
    IFS= read -r stat_line <"/proc/$1/stat" || return 1
    remainder=${stat_line#*) }
    awk '{print $20}' <<<"$remainder"
}
validate_live_adoption() {
    local unit pid ticks invocation cgroup process_cgroup executable_sha
    unit=$(jq -er '.live_adoption_gate.unit' "/proc/$$/fd/5")
    pid=$(systemctl --user show --property MainPID --value "$unit")
    [[ $pid == "$(jq -er '.live_adoption_gate.main_pid' "/proc/$$/fd/5")" ]] || die 'live transient MainPID changed'
    ticks=$(process_start_ticks "$pid")
    [[ $ticks == "$(jq -er '.live_adoption_gate.start_ticks' "/proc/$$/fd/5")" ]] || die 'live transient start ticks changed'
    invocation=$(systemctl --user show --property InvocationID --value "$unit")
    [[ $invocation == "$(jq -er '.live_adoption_gate.invocation_id' "/proc/$$/fd/5")" ]] || die 'live transient invocation changed'
    cgroup=$(systemctl --user show --property ControlGroup --value "$unit")
    process_cgroup=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")
    [[ $cgroup == "$process_cgroup" && $cgroup == "$(jq -er '.live_adoption_gate.control_group' "/proc/$$/fd/5")" ]] ||
        die 'live transient cgroup changed'
    executable_sha=$(sha256 "/proc/$pid/exe")
    [[ $executable_sha == "$(jq -er '.live_adoption_gate.executable_sha256' "/proc/$$/fd/5")" ]] ||
        die 'live transient executable changed'
    [[ $(systemctl --user show --property ActiveState --value "$unit") == active &&
       $(systemctl --user show --property SubState --value "$unit") == running &&
       $(systemctl --user show --property Transient --value "$unit") == yes &&
       $(systemctl --user show --property KillMode --value "$unit") == control-group ]] ||
        die 'live transient unit state changed'
}

while (($#)); do
    case $1 in
        --approval-sha256) (($# >= 2)) || die '--approval-sha256 requires a value'; approval_sha256=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
require_sha256 "$approval_sha256"
[[ $(id -u) == 1000 && $HOME == /home/wilf ]] || die 'run as uid 1000 with HOME=/home/wilf'
for command_name in awk bash cut jq python3 readlink sha256sum stat systemctl; do command -v "$command_name" >/dev/null || die "missing command: $command_name"; done
[[ $(readlink -f -- "${BASH_SOURCE[0]}") == "$LAUNCHER" ]] || die 'launcher path is not canonical'
[[ $(stat -c '%u:%g:%a:%h' -- "$GATE_ENV") == 0:0:755:1 && $(sha256 "$GATE_ENV") == "$GATE_ENV_SHA256" ]] ||
    die 'root-owned clean-environment runtime differs'
[[ $(stat -c '%u:%g:%a:%h' -- "$GATE_PYTHON") == 0:0:755:1 && $(sha256 "$GATE_PYTHON") == "$GATE_PYTHON_SHA256" ]] ||
    die 'root-owned Python gate runtime differs'
[[ $(stat -c '%u:%g:%a:%h' -- "$GATE_BASH") == 0:0:755:1 && $(sha256 "$GATE_BASH") == "$GATE_BASH_SHA256" ]] ||
    die 'root-owned Bash runtime differs'
[[ $(stat -c '%u:%g:%a:%h' -- "$GATE_SYSTEMCTL") == 0:0:755:1 && $(sha256 "$GATE_SYSTEMCTL") == "$GATE_SYSTEMCTL_SHA256" ]] ||
    die 'root-owned systemctl runtime differs'

exec 9<"$COORDINATOR"
exec 8<"$PLAN"
exec 7<"$APPROVAL"
exec 6<"$CHECKER"
exec 5<"$MANIFEST"
exec 4<"$PRIOR_APPROVAL"
exec 3<"$ADOPTION_TEST"
require_regular_path_fd coordinator "$COORDINATOR" 9 "$COORDINATOR_SHA256"
require_regular_path_fd plan "$PLAN" 8 "$PLAN_SHA256"
require_regular_path_fd approval "$APPROVAL" 7 "$approval_sha256"
require_regular_path_fd checker "$CHECKER" 6 "$CHECKER_SHA256"
require_regular_path_fd manifest "$MANIFEST" 5 "$MANIFEST_SHA256"
require_regular_path_fd prior-approval "$PRIOR_APPROVAL" 4 "$PRIOR_APPROVAL_SHA256"
require_regular_path_fd adoption-test "$ADOPTION_TEST" 3 "$ADOPTION_TEST_SHA256"
[[ $(stat -c '%a' -- "$APPROVAL") == 600 ]] || die 'approval receipt mode is not 0600'
strict_json "/proc/$$/fd/8" plan
strict_json "/proc/$$/fd/7" approval
strict_json "/proc/$$/fd/5" manifest
strict_json "/proc/$$/fd/4" prior-approval

launcher_sha256=$(sha256 "$LAUNCHER")
jq -e --arg op "$OPERATION_ID" --arg manifest "$MANIFEST_SHA256" --arg launcher "$launcher_sha256" \
    --arg coordinator "$COORDINATOR_SHA256" --arg checker "$CHECKER_SHA256" \
    --arg prior "$PRIOR_APPROVAL_SHA256" --arg terminal "$TERMINAL_STATE_SHA256" \
    --arg cleanup "$SLOT_CLEANUP_SHA256" --arg marker "$ACTIVE_MARKER_SHA256" '
    keys == ["active_marker_sha256","approved","approved_at_utc","checker_sha256","coordinator_sha256","launcher_sha256","operation_id","prior_approval_sha256","publication_method","replay_manifest_sha256","schema_version","slot_cleanup_receipt_sha256","state","terminal_state_sha256"] and
    .schema_version == 2 and .state == "viewflow-failed-v13-abort-replay2-execution-approved" and
    .operation_id == $op and .approved == true and .publication_method == "create-once-no-replace-and-parent-fsync" and
    .replay_manifest_sha256 == $manifest and .launcher_sha256 == $launcher and
    .coordinator_sha256 == $coordinator and .checker_sha256 == $checker and
    .prior_approval_sha256 == $prior and .terminal_state_sha256 == $terminal and
    .slot_cleanup_receipt_sha256 == $cleanup and .active_marker_sha256 == $marker and
    (.approved_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
' "/proc/$$/fd/7" >/dev/null || die 'replay2 approval receipt schema/binding differs'

jq -e --arg op "$OPERATION_ID" --arg plan "$PLAN_SHA256" --arg prior "$PRIOR_APPROVAL_SHA256" \
    --arg coordinator "$COORDINATOR_SHA256" --arg checker "$CHECKER_SHA256" --arg test "$ADOPTION_TEST_SHA256" \
    --arg terminal "$TERMINAL_STATE_SHA256" --arg cleanup "$SLOT_CLEANUP_SHA256" --arg marker "$ACTIVE_MARKER_SHA256" '
    .schema_version == 1 and .state == "viewflow-failed-v13-abort-replay2-command-manifest" and
    .execution_authorized == false and .operation_id == $op and
    .failure_class == "transient-main-pid-visible-before-sealed-target-exec" and
    .immutable_base_plan.sha256 == $plan and .prior_attempt.approval_sha256 == $prior and
    .reviewed_replay.coordinator_sha256 == $coordinator and .reviewed_replay.checker_sha256 == $checker and
    .reviewed_replay.transient_adoption_test_sha256 == $test and
    .immutable_gates.terminal_state_sha256 == $terminal and
    .immutable_gates.slot_cleanup_receipt_sha256 == $cleanup and
    .immutable_gates.active_marker_sha256 == $marker and .immutable_gates.runtime_marker_absent == true
' "/proc/$$/fd/5" >/dev/null || die 'replay2 manifest schema/binding differs'

jq -e --arg op "$OPERATION_ID" '
    .schema_version == 1 and .state == "viewflow-failed-v13-abort-command-plan" and
    .execution_authorized == false and .operation_id == $op and
    .coordinator.sha256 == "f33cb08a6c13cdbe6aceea5356b4b453a2c8e48a40d63edf7984cefbe25c6a7c" and
    .coordinator.checker_sha256 == "757f884d0b370814c5059f0d5a90cb9a546cd0b932efc02cccb3399d63deeca7" and
    .argv[0] == "/home/wilf/data/viewflow/deploy/coordinated-v13-to-v2.sh" and
    .argv[1] == "--abort-failed-v13" and (.argv | index("--failed-v13-original-generation-only")) != null
' "/proc/$$/fd/8" >/dev/null || die 'immutable base plan differs'

require_plan_artifact terminal-state "$TERMINAL_STATE" "$TERMINAL_STATE_SHA256"
require_plan_artifact slot-cleanup "$SLOT_CLEANUP" "$SLOT_CLEANUP_SHA256"
require_plan_artifact active-marker "$ACTIVE_MARKER" "$ACTIVE_MARKER_SHA256"
[[ $(jq -er '.phase' "$TERMINAL_STATE") == WINDOWS_ROLLED_BACK ]] || die 'terminal state phase changed'
[[ $(jq -er '.state' "$SLOT_CLEANUP") == viewflow-attempt3-exchange-slot-cleanup-complete ]] || die 'slot-cleanup state changed'
[[ ! -e /home/wilf/.local/state/viewflow/deskflow-quarantine.v2 ]] || die 'runtime quarantine marker appeared'
while IFS=$'\t' read -r artifact_path expected_sha; do
    require_plan_artifact terminal-input "$artifact_path" "$expected_sha"
done < <(jq -r '.terminal_inputs[] | [.path,.sha256] | @tsv' "/proc/$$/fd/8")
while IFS=$'\t' read -r artifact_path expected_sha; do
    require_plan_artifact restored-linux "$artifact_path" "$expected_sha"
done < <(jq -r '.restored_linux_gate[] | [.path,.sha256] | @tsv' "/proc/$$/fd/8")
while IFS= read -r artifact_path; do
    [[ ! -e $artifact_path && ! -L $artifact_path ]] || die "fresh/sentinel path already exists: $artifact_path"
done < <(jq -r '.required_absent_branch_sentinels[],.fresh_outputs[]' "/proc/$$/fd/8")

validate_live_adoption
/usr/bin/bash "/proc/$$/fd/6" "$COORDINATOR" >/dev/null
/usr/bin/bash "/proc/$$/fd/3" "$COORDINATOR" >/dev/null
require_regular_path_fd coordinator "$COORDINATOR" 9 "$COORDINATOR_SHA256"
require_regular_path_fd plan "$PLAN" 8 "$PLAN_SHA256"
require_regular_path_fd approval "$APPROVAL" 7 "$approval_sha256"
require_regular_path_fd checker "$CHECKER" 6 "$CHECKER_SHA256"
require_regular_path_fd manifest "$MANIFEST" 5 "$MANIFEST_SHA256"
require_regular_path_fd prior-approval "$PRIOR_APPROVAL" 4 "$PRIOR_APPROVAL_SHA256"
require_regular_path_fd adoption-test "$ADOPTION_TEST" 3 "$ADOPTION_TEST_SHA256"
validate_live_adoption
mapfile -t exact_argv < <(jq -r '.argv[]' "/proc/$$/fd/8")
[[ ${#exact_argv[@]} -gt 2 && ${exact_argv[0]} == "$COORDINATOR" ]] || die 'exact argv is invalid'
exec "$GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \
    "$GATE_PYTHON" -I -E -c "$SEALED_REPLAY_EXEC" "$OPERATION_ID" \
    "$COORDINATOR" "$COORDINATOR_SHA256" "$PLAN" "$PLAN_SHA256" \
    "$APPROVAL" "$approval_sha256" "$MANIFEST" "$MANIFEST_SHA256" \
    "$PRIOR_APPROVAL" "$PRIOR_APPROVAL_SHA256" "$CHECKER" "$CHECKER_SHA256" \
    "$ADOPTION_TEST" "$ADOPTION_TEST_SHA256" "$TERMINAL_STATE" "$TERMINAL_STATE_SHA256" \
    "$SLOT_CLEANUP" "$SLOT_CLEANUP_SHA256" "$ACTIVE_MARKER" "$ACTIVE_MARKER_SHA256"
