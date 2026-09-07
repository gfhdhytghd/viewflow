#!/usr/bin/env bash

# shellcheck disable=SC2154,SC2329
# Bridge the schema-4 no-retry/inactive abort terminal into a distinct, fresh
# protocol-2.1 generation-1 bootstrap.  This file is intentionally Linux-only:
# it does not contact, stop, or mutate the Windows peer.

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'error: bridge-v4-inactive-terminal-to-fresh-v21.sh must be executed, not sourced\n' >&2
    return 64
fi
if [[ -n ${LD_PRELOAD-} || -n ${LD_AUDIT-} || -n ${LD_LIBRARY_PATH-} ||
      -n ${BASH_ENV-} || -n ${ENV-} || -n ${PYTHONPATH-} || -n ${PYTHONHOME-} ]]; then
    printf 'error: loader, shell, and Python startup environment must be empty; use env -i\n' >&2
    exit 64
fi
unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH BASH_ENV ENV PYTHONPATH PYTHONHOME
set -Eeuo pipefail
shopt -s nullglob
umask 077
readonly PATH=/usr/bin:/bin
readonly EXPECTED_UID=1000
readonly EXPECTED_HOME=/home/wilf
readonly XDG_RUNTIME_DIR=/run/user/1000
readonly DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export PATH XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

readonly STATE=/home/wilf/.local/state/viewflow
readonly DEPLOYMENTS=$STATE/deployments
readonly MARKER=$STATE/deployment-quarantine.v1
readonly MARKER_LOCK=$STATE/.deployment-quarantine.v1.lock
readonly ABORT_CLAIM=$STATE/deployment-quarantine.v1.abort-claim
readonly RELEASE_CLAIM=$STATE/deployment-quarantine.v1.release-claim
readonly RUNTIME_MARKER=$STATE/deskflow-quarantine.v2
readonly VIEWFLOW=/home/wilf/.local/lib/viewflow/viewflowd
readonly VIEWFLOW_UNIT_FILE=/home/wilf/.config/systemd/user/viewflow-peer.service
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly MARKER_CLI=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker
readonly REVIEWED_MARKER_SHA=8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54
readonly V4_OPERATION=83fa3121bcb645e5847db05cc8cd5250
readonly V4_MARKER_CLI_SHA=c237736c4d8d4db6ba6e118ac46dc083bdf3d8ae99a0b08716bc5d3206fc6c57
readonly V4_PROVENANCE_SHA=f3023dd53acade01874af56a22fda0be126fd3bdb8160d9a471cc17cd320b7bd
readonly V4_MANIFEST_SHA=8a13bf6f5df4fb6cc6fb36e4a0d7a6be65d787a358a0259d360862e8ac62cf11
readonly V4_GATE_SHA=e2c0f4a2968bfb9f23fe224d1f9ec815c22ce1bb953151a55c4d44c166087a29
readonly V4_LAUNCHER_SHA=a23dba7212fab71b50d9d4508d2ee1e834af87495a65bcae059b0a4208fcd9d1
readonly DESKFLOW=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly DESKFLOW_UNIT=deskflow.service
readonly SIDECAR_SOCKET=/run/user/1000/viewflow/deskflow.sock
readonly SOURCE_UUID=00000000-0000-0000-0000-000000000101
readonly TARGET_UUID=00000000-0000-0000-0000-000000000002
readonly STARTUP='viewflowd protocol 1.3 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged'
readonly EXPECTED_EXECSTART='ExecStart=/home/wilf/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119 --cert /home/wilf/.local/share/viewflow/identity/peer.pem --key /home/wilf/.local/share/viewflow/identity/peer.key --ca /home/wilf/.local/share/viewflow/identity/ca.pem --device-id 00000000000000000000000000000001 --sidecar-socket %t/viewflow/deskflow.sock --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002'
readonly STOP_TIMEOUT=30
readonly START_TIMEOUT=90

mode='' old_operation='' terminal='' terminal_sha='' authorization='' authorization_sha=''
abort_receipt='' abort_receipt_sha='' abort_query='' abort_query_sha='' vfdqa='' vfdqa_sha=''
execution_approval='' execution_approval_sha=''
v4_marker_cli='' v4_marker_cli_sha='' v4_provenance='' v4_provenance_sha=''
installed_viewflow_sha='' installed_unit_sha=''
marker_candidate='' marker_candidate_sha='' prepare_script='' prepare_script_sha=''
collector_script='' collector_script_sha='' bridge_root=''
plan='' new_operation='' new_coordinator='' fresh_root=''
publish_receipt='' handoff_receipt='' frozen_evidence='' final_receipt=''
temporary_files=()
original_argv=("$@")
marker_lock_fd=${VIEWFLOW_MARKER_LOCK_FD-}
bridge_source_path=${VIEWFLOW_BRIDGE_SOURCE_PATH-$0}
bridge_source_sha=${VIEWFLOW_BRIDGE_SOURCE_SHA256-}
if [[ -z $marker_lock_fd ]]; then bridge_source_path=$0; bridge_source_sha=''; fi

usage() {
    cat <<'EOF'
Usage: bridge-v4-inactive-terminal-to-fresh-v21.sh (--execute|--resume|--validate-inputs-only) \
  --old-operation-id LOWER32 \
  --v4-abort-terminal PATH --v4-abort-terminal-sha256 LOWER64 \
  --abort-authorization PATH --abort-authorization-sha256 LOWER64 \
  --abort-receipt PATH --abort-receipt-sha256 LOWER64 \
  --abort-query-receipt PATH --abort-query-receipt-sha256 LOWER64 \
  --vfdqa PATH --vfdqa-sha256 LOWER64 \
  --v4-marker-cli PATH --v4-marker-cli-sha256 LOWER64 \
  --v4-marker-cli-provenance PATH --v4-marker-cli-provenance-sha256 LOWER64 \
  --installed-viewflow-sha256 LOWER64 --installed-viewflow-unit-sha256 LOWER64 \
  --deployment-marker-candidate PATH --deployment-marker-sha256 LOWER64 \
  --prepare-script PATH --prepare-script-sha256 LOWER64 \
  --collector-script PATH --collector-script-sha256 LOWER64 \
  --bridge-root /home/wilf/.local/state/viewflow/v4-inactive-bridges/LOWER32

--execute durably chooses one fresh operation/coordinator pair. --resume may
only continue that exact plan. Linux must begin fully inactive; no transient
retirement is performed. Deskflow and the Windows old Peer are never started,
stopped, contacted, or mutated by this Linux-only bridge.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; return 1; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
need() { [[ -n ${2-} ]] || die "$1 requires a value"; }
lower64() { [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "$1 must be lowercase SHA-256"; }

while (($#)); do
    case $1 in
        --execute|--resume|--validate-inputs-only) [[ -z $mode ]] || die 'select one mode'; mode=${1#--}; shift ;;
        --old-operation-id) need "$1" "${2-}"; old_operation=$2; shift 2 ;;
        --v4-abort-terminal) need "$1" "${2-}"; terminal=$2; shift 2 ;;
        --v4-abort-terminal-sha256) need "$1" "${2-}"; terminal_sha=$2; shift 2 ;;
        --abort-authorization) need "$1" "${2-}"; authorization=$2; shift 2 ;;
        --abort-authorization-sha256) need "$1" "${2-}"; authorization_sha=$2; shift 2 ;;
        --abort-receipt) need "$1" "${2-}"; abort_receipt=$2; shift 2 ;;
        --abort-receipt-sha256) need "$1" "${2-}"; abort_receipt_sha=$2; shift 2 ;;
        --abort-query-receipt) need "$1" "${2-}"; abort_query=$2; shift 2 ;;
        --abort-query-receipt-sha256) need "$1" "${2-}"; abort_query_sha=$2; shift 2 ;;
        --vfdqa) need "$1" "${2-}"; vfdqa=$2; shift 2 ;;
        --vfdqa-sha256) need "$1" "${2-}"; vfdqa_sha=$2; shift 2 ;;
        --v4-marker-cli) need "$1" "${2-}"; v4_marker_cli=$2; shift 2 ;;
        --v4-marker-cli-sha256) need "$1" "${2-}"; v4_marker_cli_sha=$2; shift 2 ;;
        --v4-marker-cli-provenance) need "$1" "${2-}"; v4_provenance=$2; shift 2 ;;
        --v4-marker-cli-provenance-sha256) need "$1" "${2-}"; v4_provenance_sha=$2; shift 2 ;;
        --installed-viewflow-sha256) need "$1" "${2-}"; installed_viewflow_sha=$2; shift 2 ;;
        --installed-viewflow-unit-sha256) need "$1" "${2-}"; installed_unit_sha=$2; shift 2 ;;
        --deployment-marker-candidate) need "$1" "${2-}"; marker_candidate=$2; shift 2 ;;
        --deployment-marker-sha256) need "$1" "${2-}"; marker_candidate_sha=$2; shift 2 ;;
        --prepare-script) need "$1" "${2-}"; prepare_script=$2; shift 2 ;;
        --prepare-script-sha256) need "$1" "${2-}"; prepare_script_sha=$2; shift 2 ;;
        --collector-script) need "$1" "${2-}"; collector_script=$2; shift 2 ;;
        --collector-script-sha256) need "$1" "${2-}"; collector_script_sha=$2; shift 2 ;;
        --bridge-root) need "$1" "${2-}"; bridge_root=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done
authorization_claim_path=$authorization
vfdqa_claim_path=$vfdqa
v4_marker_cli_claim_path=$v4_marker_cli

cleanup() {
    local status=$? item
    for item in "${temporary_files[@]}"; do [[ -z $item ]] || rm -f -- "$item"; done
    exit "$status"
}
trap cleanup EXIT

strict_json() {
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$1" <<'PY'
import json,os,sys
def pairs(items):
 out={}
 for key,value in items:
  if key in out: raise ValueError('duplicate key')
  out[key]=value
 return out
def reject_float(value): raise ValueError('floating-point JSON number is prohibited')
def reject_constant(value): raise ValueError('non-finite JSON number is prohibited')
fd=os.open(sys.argv[1],os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 data=b''
 while True:
  chunk=os.read(fd,1<<20)
  if not chunk: break
  data+=chunk
finally: os.close(fd)
text=data.decode('utf-8'); decoder=json.JSONDecoder(object_pairs_hook=pairs,parse_float=reject_float,parse_constant=reject_constant)
start=len(text)-len(text.lstrip()); value,end=decoder.raw_decode(text,start)
if not isinstance(value,dict) or text[end:].strip(): raise SystemExit('not one strict JSON object')
PY
}

validate_input_scalar_contract() {
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$authorization" "$abort_receipt" "$terminal" "$linux_started" "$post_reattest" <<'PY'
import json,re,sys
def load(path):
 with open(path,'r',encoding='utf-8') as stream:return json.load(stream)
def integer(obj,key,low=0,high=None):
 value=obj[key]
 if type(value) is not int or value<low or (high is not None and value>high):raise SystemExit(f'{key} is not an exact JSON integer')
def decimal(obj,key,low=1,high=None):
 value=obj[key]
 if not isinstance(value,str) or not re.fullmatch(r'[1-9][0-9]*',value):raise SystemExit(f'{key} is not canonical decimal')
 number=int(value)
 if number<low or (high is not None and number>high) or str(number)!=value:raise SystemExit(f'{key} decimal range differs')
authorization,abort,terminal,started,post=map(load,sys.argv[1:])
for obj in (authorization,abort,terminal,started,post):integer(obj,'schema_version',1,3)
for key in ('windows_installer_process_count','input_producer_count'):integer(authorization,key,0,0)
for key in ('windows_installer_process_count','input_producer_count'):integer(abort,key,0,0)
for key in ('deskflow_core_process_count','deskflow_process_count','deskflow_tcp_listener_count','input_producer_count'):integer(terminal,key,0,0)
decimal(abort,'marker_created_at_unix_ms',1,2**64-1);decimal(abort,'abort_committed_at_unix_ms',1,2**64-1)
for snapshot in (started,post):
 linux=snapshot['linux'];windows=snapshot['windows']
 for key in ('viewflow_main_pid','viewflow_start_ticks'):integer(linux,key,1,2**64-1)
 for key,value in {'viewflow_process_count':1,'viewflow_udp_listener_count':1,'viewflow_sidecar_listener_count':1,
                   'deskflow_unit_main_pid':0,'deskflow_process_count':0,'deskflow_core_process_count':0,
                   'deskflow_tcp_listener_count':0,'input_producer_count':0}.items():integer(linux,key,value,value)
 integer(windows,'session_id',1,1);integer(windows,'pid',1,2**32-1);integer(windows,'parent_pid',1,2**32-1)
 for key,value in {'viewflowd_process_count':1,'installer_process_count':0}.items():integer(windows,key,value,value)
 decimal(windows,'process_start_filetime_utc',1,2**64-1)
PY
}

safe_owner_dir() {
    local label=$1 path=$2 mode
    [[ -d $path && ! -L $path && $(stat -c '%u:%h' -- "$path") == 1000:1 ]] ||
        die "$label must be an owner-1000 single-link real directory"
    mode=$(stat -c '%a' -- "$path"); (( (8#$mode & 8#077) == 0 )) || die "$label must be owner-only"
}

exact_file() {
    local label=$1 path=$2 expected=$3 expected_mode=$4 expected_size=${5-}
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$label" "$path" "$expected" "$expected_mode" "$expected_size" <<'PY'
import hashlib,os,stat,sys
label,path,expected,mode,expected_size=sys.argv[1:]
if not path.startswith('/'): raise SystemExit(label+' path is not absolute')
fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 before=os.fstat(fd); digest=hashlib.sha256()
 while True:
  chunk=os.read(fd,1<<20)
  if not chunk: break
  digest.update(chunk)
 after=os.fstat(fd); current=os.stat(path,follow_symlinks=False)
 ident=lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_uid,s.st_gid,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
 if (not stat.S_ISREG(before.st_mode) or before.st_uid!=1000 or before.st_nlink!=1
     or stat.S_IMODE(before.st_mode)!=int(mode,8) or ident(before)!=ident(after) or ident(after)!=ident(current)
     or (expected_size and before.st_size!=int(expected_size)) or digest.hexdigest()!=expected): raise SystemExit(label+' stable identity/hash/size differs')
finally: os.close(fd)
PY
}

publish_new() {
    local source=$1 destination=$2
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$source" "$destination" <<'PY'
import ctypes,errno,os,stat,sys
source,destination=sys.argv[1:]; parent=os.path.dirname(destination); leaf=os.path.basename(destination)
if not destination.startswith('/') or leaf in ('','.','..') or os.path.dirname(source)!=parent:
 raise SystemExit('unsafe publication paths')
pfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 pst=os.fstat(pfd)
 if pst.st_uid!=1000 or stat.S_IMODE(pst.st_mode)&0o077: raise SystemExit('publication parent is not owner-only')
 sfd=os.open(os.path.basename(source),os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=pfd)
 try:
  sst=os.fstat(sfd)
  if not stat.S_ISREG(sst.st_mode) or sst.st_uid!=1000 or sst.st_nlink!=1 or stat.S_IMODE(sst.st_mode)!=0o600:
   raise SystemExit('publication source metadata differs')
  os.fsync(sfd)
 finally: os.close(sfd)
 libc=ctypes.CDLL(None,use_errno=True); fn=libc.renameat2
 fn.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint];fn.restype=ctypes.c_int
 if fn(pfd,os.fsencode(os.path.basename(source)),pfd,os.fsencode(leaf),1)!=0:
  error=ctypes.get_errno()
  if error==errno.EEXIST: raise SystemExit('create-once publication raced')
  raise OSError(error,os.strerror(error))
 os.fsync(pfd)
 dfd=os.open(leaf,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=pfd)
 try:
  dst=os.fstat(dfd)
  if (dst.st_dev,dst.st_ino)!=(sst.st_dev,sst.st_ino) or dst.st_uid!=1000 or dst.st_nlink!=1 or stat.S_IMODE(dst.st_mode)!=0o600:
   raise SystemExit('published identity differs')
 finally: os.close(dfd)
finally: os.close(pfd)
PY
}

new_temp() {
    local parent=$1 prefix=$2 out
    out=$(mktemp --tmpdir="$parent" ".$prefix.XXXXXX")
    chmod 0600 "$out"; temporary_files+=("$out"); printf '%s\n' "$out"
}

run_pinned_bash() {
    local source=$1 expected=$2; shift 2
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$source" "$expected" "$@" <<'PY'
import fcntl,hashlib,os,stat,sys
path,expected,*args=sys.argv[1:]
fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 before=os.fstat(fd); data=b''
 while True:
  chunk=os.read(fd,1<<20)
  if not chunk: break
  data+=chunk
 after=os.fstat(fd); current=os.stat(path,follow_symlinks=False)
 ident=lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_uid,s.st_gid,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
 if (not stat.S_ISREG(before.st_mode) or before.st_uid!=1000 or before.st_nlink!=1
     or stat.S_IMODE(before.st_mode) not in (0o555,0o755) or ident(before)!=ident(after) or ident(after)!=ident(current)
     or hashlib.sha256(data).hexdigest()!=expected): raise SystemExit('pinned script identity/hash differs')
finally: os.close(fd)
sealed=os.memfd_create('viewflow-pinned-bridge-script',os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
view=memoryview(data)
while view:
 count=os.write(sealed,view)
 if count<=0: raise SystemExit('sealed script short write')
 view=view[count:]
os.lseek(sealed,0,os.SEEK_SET)
seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
fcntl.fcntl(sealed,fcntl.F_ADD_SEALS,seals)
if fcntl.fcntl(sealed,fcntl.F_GET_SEALS)!=seals: raise SystemExit('sealed script flags differ')
flags=fcntl.fcntl(sealed,fcntl.F_GETFD);fcntl.fcntl(sealed,fcntl.F_SETFD,flags&~fcntl.FD_CLOEXEC)
os.execve('/usr/bin/bash',['/usr/bin/bash',f'/proc/self/fd/{sealed}',*args],{
 'HOME':'/home/wilf','PATH':'/usr/bin:/bin','XDG_RUNTIME_DIR':'/run/user/1000',
 'DBUS_SESSION_BUS_ADDRESS':'unix:path=/run/user/1000/bus'})
PY
}

validate_inputs() {
    local marker_sha old_coord durable data_mode=600 executable_mode=755
    [[ -n $mode && $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] || die 'mode/uid/HOME differs'
    [[ $XDG_RUNTIME_DIR == /run/user/1000 && $DBUS_SESSION_BUS_ADDRESS == unix:path=/run/user/1000/bus ]] ||
        die 'explicit user bus environment differs'
    [[ $old_operation == "$V4_OPERATION" ]] || die 'old operation is not the frozen 83fa V4 operation'
    [[ $bridge_root == /home/wilf/.local/state/viewflow/bridges/$old_operation ]] ||
        die 'bridge root must be the fixed old-operation path'
    lower64 terminal "$terminal_sha"; lower64 authorization "$authorization_sha"; lower64 abort "$abort_receipt_sha"
    lower64 linux "$linux_started_sha"; lower64 post "$post_reattest_sha"; lower64 VFDQA "$vfdqa_sha"
    lower64 viewflow "$installed_viewflow_sha"; lower64 unit "$installed_unit_sha"; lower64 candidate "$marker_candidate_sha"
    lower64 prepare "$prepare_script_sha"; lower64 collector "$collector_script_sha"
    if [[ $terminal == "$bridge_root/immutable-inputs/early-gate-terminal.json" ]]; then data_mode=400; executable_mode=555; fi
    exact_file 'early terminal' "$terminal" "$terminal_sha" "$data_mode"; strict_json "$terminal"
    exact_file 'authorization' "$authorization" "$authorization_sha" "$data_mode"; strict_json "$authorization"
    exact_file 'abort receipt' "$abort_receipt" "$abort_receipt_sha" "$data_mode"; strict_json "$abort_receipt"
    exact_file 'Linux started' "$linux_started" "$linux_started_sha" "$data_mode"; strict_json "$linux_started"
    exact_file 'post-abort reattestation' "$post_reattest" "$post_reattest_sha" "$data_mode"; strict_json "$post_reattest"
    exact_file 'durable VFDQA snapshot/source' "$vfdqa" "$vfdqa_sha" "$data_mode" 384
    if [[ $data_mode == 400 ]]; then
        exact_file 'content-addressed durable VFDQA original' "$vfdqa_claim_path" "$vfdqa_sha" 600 384
    fi
    exact_file 'marker candidate' "$marker_candidate" "$marker_candidate_sha" "$executable_mode"
    exact_file 'prepare script' "$prepare_script" "$prepare_script_sha" "$executable_mode"
    exact_file 'collector script' "$collector_script" "$collector_script_sha" "$executable_mode"

    jq -e --arg op "$old_operation" --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" \
      --arg post "$post_reattest_sha" --arg vfdqa "$vfdqa_sha" '
      keys==["abort_claim_absent","abort_receipt_sha256","authorization_sha256","coordinator_terminal_state_sha256","deskflow_core_process_count","deskflow_process_count","deskflow_tcp_listener_count","deskflow_unit_state","input_producer_count","marker_absent","operation_id","post_abort_reattest_sha256","pre_abort_reattest_sha256","protocol_2_1","release_claim_absent","runtime_marker_absent","schema_version","state","vfdqa_binary_sha256"] and
      .schema_version==1 and .state=="viewflow-early-bootstrap-gate-abort-terminal" and .operation_id==$op and
      .authorization_sha256==$auth and .abort_receipt_sha256==$abort and .post_abort_reattest_sha256==$post and
      .vfdqa_binary_sha256==$vfdqa and (.coordinator_terminal_state_sha256|test("^[0-9a-f]{64}$")) and
      (.pre_abort_reattest_sha256|test("^[0-9a-f]{64}$")) and .marker_absent==true and
      .abort_claim_absent==true and .release_claim_absent==true and .runtime_marker_absent==true and
      .deskflow_unit_state=="inactive" and .deskflow_process_count==0 and .deskflow_core_process_count==0 and
      .deskflow_tcp_listener_count==0 and .input_producer_count==0 and .protocol_2_1==false
    ' "$terminal" >/dev/null || die 'schema-1 early abort terminal differs'

    marker_sha=$(jq -er '.marker_sha256' "$authorization"); old_coord=$(jq -er '.coordinator_instance_id' "$authorization")
    jq -e --arg op "$old_operation" --arg coord "$old_coord" --arg path "$authorization_claim_path" --arg marker "$marker_sha" \
      --arg state "$(jq -er '.coordinator_terminal_state_sha256' "$terminal")" --arg linux "$linux_started_sha" \
      --arg vf "$installed_viewflow_sha" '
      keys==["authenticated_v13_peer_receipt_sha256","authorization_receipt_path","bootstrap_request_sha256","coordinator_failure_phase","coordinator_instance_id","coordinator_mutation_possible","coordinator_terminal_state_sha256","deployment_publish_receipt_sha256","force_release_executed","initial_force_release_executed","input_producer_count","linux_deskflow_started","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_generation","marker_handoff_receipt_sha256","marker_sha256","mutation_permit_published","old_linux_deskflow_core_sha256","old_linux_deskflow_sha256","old_linux_viewflowd_sha256","old_windows_rollback_sha256","old_windows_task_xml_sha256","old_windows_viewflowd_sha256","old_windows_wrapper_sha256","operation_id","protocol_2_1","rollback_performed","schema_version","state","windows_bootstrap_worker_created","windows_installer_process_count","windows_live_proof_sha256","windows_new_operation_root_present","windows_new_task_present","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
      .schema_version==3 and .state=="viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized" and
      .operation_id==$op and .coordinator_instance_id==$coord and .authorization_receipt_path==$path and
      .marker_generation=="1" and .marker_sha256==$marker and .coordinator_terminal_state_sha256==$state and
      .linux_v13_started_receipt_sha256==$linux and .old_linux_viewflowd_sha256==$vf and
      all([.marker_handoff_receipt_sha256,.deployment_publish_receipt_sha256,.linux_frozen_evidence_sha256,
           .bootstrap_request_sha256,.windows_stop_evidence_sha256,.windows_live_proof_sha256,
           .old_linux_deskflow_sha256,.old_linux_deskflow_core_sha256,.old_windows_viewflowd_sha256,
           .old_windows_wrapper_sha256,.old_windows_task_xml_sha256,.old_windows_rollback_sha256,
           .windows_v13_started_receipt_sha256,.authenticated_v13_peer_receipt_sha256][];test("^[0-9a-f]{64}$")) and
      .coordinator_failure_phase==null and .coordinator_mutation_possible==false and
      .windows_bootstrap_worker_created==false and
      .windows_new_operation_root_present==false and .windows_new_task_present==false and
      .windows_installer_process_count==0 and .mutation_permit_published==false and .force_release_executed==false and
      .initial_force_release_executed==false and .rollback_performed==false and .windows_rollback_receipt_sha256==null and
      .linux_deskflow_started==false and .input_producer_count==0 and .protocol_2_1==false
    ' "$authorization" >/dev/null || die 'schema-3 early/no-worker authorization differs'

    jq -e --arg op "$old_operation" --arg coord "$old_coord" --arg marker "$marker_sha" \
      --arg auth_path "$authorization_claim_path" --arg auth "$authorization_sha" --arg durable "$vfdqa_claim_path" '
      keys==["abort_authorization_path","abort_authorization_sha256","abort_claim_path","abort_committed_at_unix_ms","abort_committed_at_utc","abort_point","abort_receipt_path","aborted_marker_sha256","authenticated_v13_peer_receipt_sha256","authorization_state","bootstrap_request_sha256","coordinator_failure_phase","coordinator_instance_id","coordinator_mutation_possible","coordinator_terminal_state_sha256","deployment_publish_receipt_sha256","deployment_release_claimed","force_release_executed","initial_force_release_executed","input_producer_count","linux_deskflow_started","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_created_at_unix_ms","marker_generation","marker_handoff_receipt_sha256","marker_path","mutation_permit_published","operation_id","protocol_2_1","protocol_version","replayed","rollback_performed","schema_version","source_display_id","state","target_device_id","windows_bootstrap_worker_created","windows_installer_process_count","windows_live_proof_sha256","windows_new_operation_root_present","windows_new_task_present","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
      .schema_version==3 and .state=="deployment-quarantine-aborted" and .protocol_version=="1.3" and .protocol_2_1==false and
      .operation_id==$op and .coordinator_instance_id==$coord and .source_display_id=="00000000-0000-0000-0000-000000000101" and
      .target_device_id=="00000000-0000-0000-0000-000000000002" and .marker_generation=="1" and
      .marker_path=="/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and
      .abort_claim_path=="/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim" and
      .abort_receipt_path==$durable and .abort_authorization_path==$auth_path and .abort_authorization_sha256==$auth and
      .aborted_marker_sha256==$marker and .abort_point=="abort-claim-unlink-and-parent-directory-fsync" and
      .deployment_release_claimed==false and (.replayed|type)=="boolean" and
      .authorization_state=="viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized" and
      (.marker_created_at_unix_ms|test("^[1-9][0-9]*$")) and (.abort_committed_at_unix_ms|test("^[1-9][0-9]*$")) and
      (.abort_committed_at_utc|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
    ' "$abort_receipt" >/dev/null || die 'schema-3 abort receipt differs'
    for key in coordinator_terminal_state_sha256 coordinator_failure_phase coordinator_mutation_possible marker_handoff_receipt_sha256 deployment_publish_receipt_sha256 linux_frozen_evidence_sha256 bootstrap_request_sha256 windows_stop_evidence_sha256 windows_live_proof_sha256 linux_v13_started_receipt_sha256 windows_v13_started_receipt_sha256 authenticated_v13_peer_receipt_sha256 windows_bootstrap_worker_created windows_new_operation_root_present windows_new_task_present windows_installer_process_count mutation_permit_published force_release_executed rollback_performed windows_rollback_receipt_sha256 initial_force_release_executed linux_deskflow_started input_producer_count; do
        [[ $(jq -cS --arg key "$key" '.[$key]' "$abort_receipt") == "$(jq -cS --arg key "$key" '.[$key]' "$authorization")" ]] ||
            die "abort receipt/authorization cross-binding differs: $key"
    done

    validate_input_scalar_contract
    validate_snapshot "$linux_started" 'viewflow-early-gate-start-viewflow' "$marker_sha"
    validate_snapshot "$post_reattest" 'viewflow-early-gate-post-abort-reattest' "$marker_sha"
    jq -e --slurpfile started "$linux_started" '.linux==$started[0].linux and .windows==$started[0].windows' "$post_reattest" >/dev/null ||
        die 'post-abort stable Linux/Windows tuple differs from Linux-started'
    [[ $(jq -er '.linux.viewflowd_sha256' "$linux_started") == "$installed_viewflow_sha" ]] || die 'installed Viewflow hash cross-binding differs'
    [[ $(jq -er '.linux.viewflow_unit' "$linux_started") == "viewflow-v13-early-$old_operation.service" ]] || die 'old transient unit differs'

    durable=$(jq -er '.abort_receipt_path' "$abort_receipt")
    [[ $durable == "$vfdqa_claim_path" && $vfdqa_claim_path == "$STATE/.deployment-quarantine.v1.abort-receipt.${marker_sha}.${authorization_sha}.v1" ]] ||
        die 'content-addressed 384-byte VFDQA path/binding differs'
    validate_vfdqa "$marker_sha" "$old_coord"
}

validate_inputs() {
    local data_mode=600 executable_mode=755 v4_mode=700 old_coord marker_sha durable
    [[ -n $mode && $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] || die 'mode/uid/HOME differs'
    [[ $XDG_RUNTIME_DIR == /run/user/1000 && $DBUS_SESSION_BUS_ADDRESS == unix:path=/run/user/1000/bus ]] ||
        die 'explicit user bus environment differs'
    [[ $old_operation =~ ^[0-9a-f]{32}$ ]] || die 'old operation must be lowercase 32hex'
    [[ $bridge_root == "$STATE/v4-inactive-bridges/$old_operation" ]] || die 'bridge root must use fixed V4 inactive namespace'
    for pair in "terminal:$terminal_sha" "authorization:$authorization_sha" "abort:$abort_receipt_sha" \
                "query:$abort_query_sha" "VFDQA:$vfdqa_sha" "V4 CLI:$v4_marker_cli_sha" \
                "V4 provenance:$v4_provenance_sha" "Viewflow:$installed_viewflow_sha" "unit:$installed_unit_sha" \
                "reviewed marker:$marker_candidate_sha" "prepare:$prepare_script_sha" "collector:$collector_script_sha"; do
        lower64 "${pair%%:*}" "${pair#*:}"
    done
    if [[ $terminal == "$bridge_root/immutable-inputs/no-retry-v4-abort-terminal.json" ]]; then
        data_mode=400; executable_mode=555; v4_mode=500
    fi
    exact_file 'V4 terminal' "$terminal" "$terminal_sha" "$data_mode"; strict_json "$terminal"
    execution_approval_sha=$(jq -er '.execution_approval_sha256' "$terminal")
    lower64 'V4 execution approval' "$execution_approval_sha"
    [[ -n $execution_approval ]] ||
        execution_approval=$DEPLOYMENTS/$old_operation/failed-pre-mutation-abort-83fa3121-no-retry-execution-approval.json
    exact_file 'V4 execution approval' "$execution_approval" "$execution_approval_sha" "$data_mode"; strict_json "$execution_approval"
    exact_file 'V4 authorization' "$authorization" "$authorization_sha" "$data_mode"; strict_json "$authorization"
    exact_file 'V4 native abort receipt' "$abort_receipt" "$abort_receipt_sha" "$data_mode"; strict_json "$abort_receipt"
    exact_file 'V4 native abort query receipt' "$abort_query" "$abort_query_sha" "$data_mode"; strict_json "$abort_query"
    exact_file 'durable VFDQA snapshot/source' "$vfdqa" "$vfdqa_sha" "$data_mode" 384
    [[ $data_mode != 400 ]] || exact_file 'content-addressed durable VFDQA original' "$vfdqa_claim_path" "$vfdqa_sha" 600 384
    exact_file 'V4 marker CLI' "$v4_marker_cli" "$v4_marker_cli_sha" "$v4_mode"
    exact_file 'V4 marker CLI provenance' "$v4_provenance" "$v4_provenance_sha" "$data_mode"; strict_json "$v4_provenance"
    exact_file 'reviewed marker candidate' "$marker_candidate" "$marker_candidate_sha" "$executable_mode"
    exact_file 'prepare script' "$prepare_script" "$prepare_script_sha" "$executable_mode"
    exact_file 'collector script' "$collector_script" "$collector_script_sha" "$executable_mode"
    [[ $marker_candidate_sha == "$REVIEWED_MARKER_SHA" && $(sha256 "$MARKER_CLI") == "$REVIEWED_MARKER_SHA" ]] ||
        die 'fresh marker candidate is not the reviewed 8d marker CLI'
    [[ $v4_marker_cli_sha == "$V4_MARKER_CLI_SHA" && $v4_provenance_sha == "$V4_PROVENANCE_SHA" ]] ||
        die 'V4 marker CLI/provenance baseline differs'

    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$terminal" "$terminal_sha" "$execution_approval" "$execution_approval_sha" "$authorization" "$authorization_sha" \
      "$abort_receipt" "$abort_receipt_sha" "$abort_query" "$abort_query_sha" "$v4_provenance" "$v4_provenance_sha" \
      "$old_operation" "$authorization_claim_path" "$vfdqa_claim_path" "$vfdqa_sha" "$v4_marker_cli_claim_path" "$v4_marker_cli_sha" \
      "$installed_viewflow_sha" "$V4_MANIFEST_SHA" "$V4_GATE_SHA" "$V4_LAUNCHER_SHA" <<'PY'
import json,re,sys
(terminal_path,terminal_sha,approval_path,approval_sha,auth_path,auth_sha,receipt_path,receipt_sha,query_path,query_sha,
 provenance_path,provenance_sha,operation,auth_claim,vfdqa_claim,vfdqa_sha,v4_cli_path,v4_cli_sha,installed_viewflow_sha,
 manifest_sha,gate_sha,launcher_sha)=sys.argv[1:]
def load(path):
 with open(path,'r',encoding='utf-8') as stream:return json.load(stream)
def keys(value,expected,label):
 if set(value)!=set(expected):raise SystemExit(label+' exact keys differ')
def hash64(value,label):
 if not isinstance(value,str) or not re.fullmatch(r'[0-9a-f]{64}',value) or value=='0'*64:raise SystemExit(label+' hash differs')
def decimal(value,label):
 if not isinstance(value,str) or not re.fullmatch(r'[1-9][0-9]*',value) or int(value)>2**64-1:raise SystemExit(label+' decimal differs')
t,e,a,r,q,p=map(load,(terminal_path,approval_path,auth_path,receipt_path,query_path,provenance_path))
terminal_keys='''schema_version state operation_id coordinator_terminal_state_sha256 coordinator_failure_phase coordinator_mutation_possible authorization_sha256 abort_receipt_sha256 abort_query_receipt_sha256 vfdqa_binary_sha256 execution_approval_sha256 manifest_sha256 gate_sha256 launcher_sha256 v4_marker_cli_sha256 v4_marker_cli_provenance_sha256 linux_inactive_pre_sha256 windows_old_peer_live_sha256 windows_operation_root_inventory_sha256 linux_inactive_post_sha256 windows_old_peer_post_sha256 marker_absent abort_claim_absent release_claim_absent runtime_marker_absent linux_viewflow_started linux_deskflow_started input_producer_count windows_old_peer_unchanged windows_operation_root_present windows_operation_root_unchanged windows_deployment_task_state mutation_outputs_absent protocol_2_1'''.split()
keys(t,terminal_keys,'V4 terminal')
if not (t['schema_version']==4 and t['state']=='viewflow-failed-pre-mutation-no-retry-vfdqa-abort-terminal' and t['operation_id']==operation
 and t['coordinator_failure_phase']=='WINDOWS_STARTED' and t['coordinator_mutation_possible'] is False
 and t['authorization_sha256']==auth_sha and t['abort_receipt_sha256']==receipt_sha and t['abort_query_receipt_sha256']==query_sha
 and t['execution_approval_sha256']==approval_sha and t['manifest_sha256']==manifest_sha and t['gate_sha256']==gate_sha and t['launcher_sha256']==launcher_sha
 and t['v4_marker_cli_sha256']==v4_cli_sha and t['v4_marker_cli_provenance_sha256']==provenance_sha and t['vfdqa_binary_sha256']==vfdqa_sha
 and all(t[name] is True for name in ('marker_absent','abort_claim_absent','release_claim_absent','runtime_marker_absent','windows_old_peer_unchanged','windows_operation_root_present','windows_operation_root_unchanged','mutation_outputs_absent'))
 and t['linux_viewflow_started'] is False and t['linux_deskflow_started'] is False and type(t['input_producer_count']) is int and t['input_producer_count']==0
 and t['windows_deployment_task_state']=='Disabled' and t['protocol_2_1'] is False):raise SystemExit('V4 terminal truth/binding differs')
for name in ('coordinator_terminal_state_sha256','execution_approval_sha256','manifest_sha256','gate_sha256','launcher_sha256','linux_inactive_pre_sha256','windows_old_peer_live_sha256','windows_operation_root_inventory_sha256','linux_inactive_post_sha256','windows_old_peer_post_sha256','vfdqa_binary_sha256'):hash64(t[name],name)
approval_keys='''schema_version state approved operation_id manifest_sha256 gate_sha256 launcher_sha256 coordinator_state_sha256 marker_sha256 v4_marker_cli_sha256 v4_marker_cli_provenance_sha256 transaction_implementation approved_at_utc'''.split()
keys(e,approval_keys,'V4 execution approval')
if not (e['schema_version']==4 and e['state']=='viewflow-failed-pre-mutation-no-retry-abort-execution-approved' and e['approved'] is True
 and e['operation_id']==operation and e['manifest_sha256']==manifest_sha and e['gate_sha256']==gate_sha and e['launcher_sha256']==launcher_sha
 and e['coordinator_state_sha256']==t['coordinator_terminal_state_sha256'] and e['v4_marker_cli_sha256']==v4_cli_sha
 and e['v4_marker_cli_provenance_sha256']==provenance_sha and e['transaction_implementation']=='sealed-fd-native-rust-v4-abort-then-query'
 and isinstance(e['approved_at_utc'],str) and re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z',e['approved_at_utc'])):raise SystemExit('V4 execution approval binding differs')
for name in ('coordinator_state_sha256','marker_sha256','v4_marker_cli_sha256','v4_marker_cli_provenance_sha256'):hash64(e[name],name)
auth_keys='''schema_version state operation_id coordinator_instance_id marker_generation marker_sha256 authorization_receipt_path coordinator_terminal_state_sha256 coordinator_failure_phase coordinator_mutation_possible marker_handoff_receipt_sha256 deployment_publish_receipt_sha256 linux_frozen_evidence_sha256 bootstrap_request_sha256 installer_exit_receipt_sha256 windows_stop_evidence_sha256 linux_inactive_proof_sha256 windows_old_peer_live_proof_sha256 windows_operation_root_inventory_sha256 old_linux_viewflowd_sha256 old_linux_deskflow_sha256 old_linux_deskflow_core_sha256 old_windows_viewflowd_sha256 old_windows_wrapper_sha256 old_windows_task_xml_sha256 old_windows_rollback_sha256 windows_operation_root_present windows_deployment_task_present windows_deployment_task_state windows_bootstrap_worker_count windows_installer_process_count mutation_outputs_absent linux_viewflow_started linux_deskflow_started input_producer_count initial_force_release_executed rollback_performed windows_rollback_receipt_sha256 protocol_2_1'''.split()
keys(a,auth_keys,'V4 authorization')
if not (a['schema_version']==4 and a['state']=='viewflow-deployment-quarantine-failed-pre-mutation-no-retry-abort-authorized'
 and a['operation_id']==operation and re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}',a['coordinator_instance_id'])
 and a['marker_generation']=='1' and a['authorization_receipt_path']==auth_claim and a['coordinator_terminal_state_sha256']==t['coordinator_terminal_state_sha256']
 and e['marker_sha256']==a['marker_sha256']
 and a['coordinator_failure_phase']=='WINDOWS_STARTED' and a['coordinator_mutation_possible'] is False
 and a['linux_inactive_proof_sha256']==t['linux_inactive_pre_sha256'] and a['windows_old_peer_live_proof_sha256']==t['windows_old_peer_live_sha256']
 and a['windows_operation_root_inventory_sha256']==t['windows_operation_root_inventory_sha256'] and a['old_linux_viewflowd_sha256']==installed_viewflow_sha
 and a['windows_operation_root_present'] is True and a['windows_deployment_task_present'] is True and a['windows_deployment_task_state']=='Disabled'
 and all(type(a[name]) is int and a[name]==0 for name in ('windows_bootstrap_worker_count','windows_installer_process_count','input_producer_count'))
 and a['mutation_outputs_absent'] is True and a['linux_viewflow_started'] is False and a['linux_deskflow_started'] is False
 and a['initial_force_release_executed'] is False and a['rollback_performed'] is False and a['windows_rollback_receipt_sha256'] is None and a['protocol_2_1'] is False):raise SystemExit('V4 authorization truth/binding differs')
for name in ('marker_sha256','marker_handoff_receipt_sha256','deployment_publish_receipt_sha256','linux_frozen_evidence_sha256','bootstrap_request_sha256','installer_exit_receipt_sha256','windows_stop_evidence_sha256','linux_inactive_proof_sha256','windows_old_peer_live_proof_sha256','windows_operation_root_inventory_sha256','old_linux_viewflowd_sha256','old_linux_deskflow_sha256','old_linux_deskflow_core_sha256','old_windows_viewflowd_sha256','old_windows_wrapper_sha256','old_windows_task_xml_sha256','old_windows_rollback_sha256'):hash64(a[name],name)
receipt_keys='''abort_authorization_path abort_authorization_sha256 abort_claim_path abort_committed_at_unix_ms abort_committed_at_utc abort_point abort_receipt_path aborted_marker_sha256 authorization_state bootstrap_request_sha256 coordinator_failure_phase coordinator_instance_id coordinator_mutation_possible coordinator_terminal_state_sha256 deployment_publish_receipt_sha256 deployment_release_claimed initial_force_release_executed input_producer_count installer_exit_receipt_sha256 linux_deskflow_started linux_frozen_evidence_sha256 linux_inactive_proof_sha256 linux_viewflow_started marker_created_at_unix_ms marker_generation marker_handoff_receipt_sha256 marker_path mutation_outputs_absent old_linux_deskflow_core_sha256 old_linux_deskflow_sha256 old_linux_viewflowd_sha256 old_windows_rollback_sha256 old_windows_task_xml_sha256 old_windows_viewflowd_sha256 old_windows_wrapper_sha256 operation_id protocol_2_1 protocol_version replayed rollback_performed schema_version source_display_id state target_device_id windows_bootstrap_worker_count windows_deployment_task_present windows_deployment_task_state windows_installer_process_count windows_old_peer_live_proof_sha256 windows_operation_root_inventory_sha256 windows_operation_root_present windows_rollback_receipt_sha256 windows_stop_evidence_sha256'''.split()
copied=(set(auth_keys)&set(receipt_keys))-{'schema_version','state','operation_id','coordinator_instance_id','marker_generation','authorization_receipt_path'}
for value,label in ((r,'abort receipt'),(q,'abort query receipt')):
 keys(value,receipt_keys,label)
 if any(value[name]!=a[name] for name in copied):raise SystemExit(label+' authorization cross-binding differs')
 if not (value['schema_version']==4 and value['state']=='deployment-quarantine-aborted' and value['authorization_state']==a['state']
  and value['operation_id']==operation and value['coordinator_instance_id']==a['coordinator_instance_id'] and value['marker_generation']=='1'
  and value['source_display_id']=='00000000-0000-0000-0000-000000000101' and value['target_device_id']=='00000000-0000-0000-0000-000000000002'
  and value['marker_path']=='/home/wilf/.local/state/viewflow/deployment-quarantine.v1'
  and value['abort_claim_path']=='/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim'
  and value['abort_authorization_path']==auth_claim and value['abort_authorization_sha256']==auth_sha
  and value['abort_receipt_path']==vfdqa_claim and value['aborted_marker_sha256']==a['marker_sha256']
  and value['abort_point']=='abort-claim-unlink-and-parent-directory-fsync' and value['deployment_release_claimed'] is False
  and value['protocol_version']=='1.3' and value['protocol_2_1'] is False and type(value['replayed']) is bool):raise SystemExit(label+' identity differs')
 decimal(value['marker_created_at_unix_ms'],label+' marker time');decimal(value['abort_committed_at_unix_ms'],label+' commit time')
 if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z',value['abort_committed_at_utc']):raise SystemExit(label+' UTC differs')
if q['replayed'] is not True or any(q[name]!=r[name] for name in receipt_keys if name!='replayed'):raise SystemExit('abort query is not exact replay of abort receipt')
keys(p,'schema_version state operation_id built_at_utc toolchain target standalone base candidate verification'.split(),'V4 provenance')
if not (p['schema_version']==1 and p['state']=='viewflow-no-retry-v4-marker-candidate-provenance' and p['operation_id']==operation
 and p['candidate']['path']==v4_cli_path and p['candidate']['sha256']==v4_cli_sha and p['candidate']['mode']=='0700'
 and p['candidate']['owner_uid']==1000 and p['candidate']['owner_gid']==1000 and p['candidate']['link_count']==1
 and p['candidate']['size']==1003088 and p['candidate']['build_id']=='6b116abd3f6f7b33cf84deb1e404056741388685'
 and p['target']=='x86_64-unknown-linux-gnu'):raise SystemExit('V4 CLI provenance binding differs')
PY
    marker_sha=$(jq -er '.marker_sha256' "$authorization"); old_coord=$(jq -er '.coordinator_instance_id' "$authorization")
    durable=$(jq -er '.abort_receipt_path' "$abort_receipt")
    [[ $durable == "$vfdqa_claim_path" && $vfdqa_claim_path == "$STATE/.deployment-quarantine.v1.abort-receipt.${marker_sha}.${authorization_sha}.v1" ]] ||
        die 'content-addressed V4 VFDQA path/binding differs'
    validate_vfdqa "$marker_sha" "$old_coord"
}

validate_snapshot() {
    local path=$1 state=$2 marker_sha=$3
    jq -e --arg op "$old_operation" --arg state "$state" --arg marker "$marker_sha" \
      --arg request "$(jq -er '.bootstrap_request_sha256' "$authorization")" \
      --arg windows_vf "$(jq -er '.old_windows_viewflowd_sha256' "$authorization")" \
      --arg wrapper "$(jq -er '.old_windows_wrapper_sha256' "$authorization")" \
      --arg task_xml "$(jq -er '.old_windows_task_xml_sha256' "$authorization")" \
      --arg rollback "$(jq -er '.old_windows_rollback_sha256' "$authorization")" '
      keys==["linux","marker_generation","marker_sha256","operation_id","schema_version","state","windows"] and
      .schema_version==1 and .state==$state and .operation_id==$op and .marker_sha256==$marker and .marker_generation=="1" and
      (.linux|keys)==["deskflow_core_process_count","deskflow_process_count","deskflow_tcp_listener_count","deskflow_unit_main_pid","deskflow_unit_state","input_producer_count","runtime_marker_present","viewflow_control_group","viewflow_exec_start_sha256","viewflow_invocation_id","viewflow_main_pid","viewflow_process_count","viewflow_sidecar_listener_count","viewflow_start_ticks","viewflow_udp_listener_count","viewflow_unit","viewflow_unit_state","viewflowd_sha256"] and
      .linux.viewflow_unit==("viewflow-v13-early-"+$op+".service") and .linux.viewflow_unit_state=="active" and
      (.linux.viewflow_main_pid|type=="number" and .>0 and .==floor) and (.linux.viewflow_start_ticks|type=="number" and .>0 and .==floor) and
      (.linux.viewflow_invocation_id|test("^[0-9a-f]{32}$")) and (.linux as $l|$l.viewflow_control_group|endswith("/"+$l.viewflow_unit)) and
      (.linux.viewflow_exec_start_sha256|test("^[0-9a-f]{64}$")) and .linux.viewflow_process_count==1 and
      .linux.viewflow_udp_listener_count==1 and .linux.viewflow_sidecar_listener_count==1 and
      .linux.deskflow_unit_state=="inactive" and .linux.deskflow_unit_main_pid==0 and .linux.deskflow_process_count==0 and
      .linux.deskflow_core_process_count==0 and .linux.deskflow_tcp_listener_count==0 and .linux.runtime_marker_present==false and
      .linux.input_producer_count==0 and
      (.windows|keys)==["bootstrap_worker_created","command_line_sha256","executable_path","force_release_executed","initial_force_release_executed","installer_process_count","mutation_permit_published","new_operation_root_path","new_operation_root_present","new_task_name","new_task_path","new_task_present","parent_pid","pid","process_start_filetime_utc","protocol_2_1","request_sha256","rollback_performed","rollback_sha256","session_id","task_action_sha256","task_name","task_path","task_principal_sha256","task_state","task_xml_sha256","user_sid","viewflowd_process_count","viewflowd_sha256","windows_rollback_receipt_sha256","wrapper_sha256"] and
      .windows.task_path=="\\" and .windows.task_name=="Viewflow Peer" and .windows.task_state=="Running" and
      .windows.request_sha256==$request and .windows.viewflowd_sha256==$windows_vf and .windows.wrapper_sha256==$wrapper and
      .windows.task_xml_sha256==$task_xml and .windows.rollback_sha256==$rollback and
      (.windows.task_action_sha256|test("^[0-9a-f]{64}$")) and (.windows.task_principal_sha256|test("^[0-9a-f]{64}$")) and
      (.windows.command_line_sha256|test("^[0-9a-f]{64}$")) and
      .windows.session_id==1 and (.windows.pid|type=="number" and .>=1 and .<=4294967295 and .==floor) and
      (.windows.parent_pid|type=="number" and .>=1 and .<=4294967295 and .==floor) and
      (.windows.process_start_filetime_utc|test("^[1-9][0-9]{16,18}$")) and
      .windows.user_sid=="S-1-5-21-1940417919-1835306932-1635351729-1001" and
      .windows.executable_path=="C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe" and
      .windows.new_operation_root_path==("C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\"+$op) and
      .windows.new_task_path=="\\" and .windows.new_task_name==("Viewflow Deployment "+$op) and
      .windows.viewflowd_process_count==1 and .windows.new_operation_root_present==false and .windows.new_task_present==false and
      .windows.bootstrap_worker_created==false and .windows.installer_process_count==0 and .windows.mutation_permit_published==false and
      .windows.initial_force_release_executed==false and .windows.force_release_executed==false and .windows.rollback_performed==false and
      .windows.windows_rollback_receipt_sha256==null and .windows.protocol_2_1==false
    ' "$path" >/dev/null || die "$state schema/binding differs"
}

validate_vfdqa() {
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$vfdqa" "$vfdqa_sha" "$1" "$authorization_sha" \
      "$old_operation" "$2" "$(jq -er '.marker_created_at_unix_ms' "$abort_receipt")" \
      "$(jq -er '.abort_committed_at_unix_ms' "$abort_receipt")" <<'PY'
import hashlib,sys,uuid
b=open(sys.argv[1],'rb').read(); outer,marker_sha,auth_sha,op,coord,created,committed=sys.argv[2:]
if len(b)!=384 or hashlib.sha256(b).hexdigest()!=outer or b[:8]!=b'VFDQA001' or b[8:13]!=bytes((1,1,1,3,1)) or any(b[13:16]): raise SystemExit('VFDQA header/hash differs')
m=b[16:272]
if len(m)!=256 or m[:13]!=b'VFDQT001\x01\x01\x02\x01\x01' or hashlib.sha256(m).hexdigest()!=marker_sha: raise SystemExit('embedded VFDQT differs')
raw=op.encode()
if m[13]!=len(raw) or any(m[14:16]) or m[16:16+len(raw)]!=raw or any(m[16+len(raw):144]): raise SystemExit('embedded operation differs')
if m[144:160]!=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes or m[160:176]!=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes or m[176:192]!=uuid.UUID(coord).bytes: raise SystemExit('embedded identity differs')
if str(int.from_bytes(m[192:200],'little'))!=created or int.from_bytes(m[200:208],'little')!=1 or any(m[208:]): raise SystemExit('embedded time/generation differs')
if b[272:304].hex()!=marker_sha or b[304:336].hex()!=auth_sha or str(int.from_bytes(b[336:344],'little'))!=committed or any(b[344:352]) or hashlib.sha256(b[:352]).digest()!=b[352:384]: raise SystemExit('VFDQA cross-binding/checksum differs')
PY
}

readonly -a VIEWFLOW_ARGV=(
    /home/wilf/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119
    --cert /home/wilf/.local/share/viewflow/identity/peer.pem
    --key /home/wilf/.local/share/viewflow/identity/peer.key
    --ca /home/wilf/.local/share/viewflow/identity/ca.pem
    --device-id 00000000000000000000000000000001
    --sidecar-socket /run/user/1000/viewflow/deskflow.sock
    --sidecar-peer 172.16.105.70
    --sidecar-target-device 00000000000000000000000000000002
)

unit_prop() { systemctl --user show --property "$2" --value "$1"; }
process_ticks() { sed -E 's/^[0-9]+ \(.*\) //' "/proc/$1/stat" | awk '{print $20}'; }
process_cgroup() { awk -F: '$1=="0" {print $3}' "/proc/$1/cgroup"; }

expected_argv_sha() {
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "${VIEWFLOW_ARGV[@]}" <<'PY'
import hashlib,json,sys
print(hashlib.sha256(json.dumps(sys.argv[1:],sort_keys=True,separators=(',',':')).encode()).hexdigest())
PY
}

cmdline_sha() { sha256 "/proc/$1/cmdline"; }

expected_cmdline_sha() {
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "${VIEWFLOW_ARGV[@]}" <<'PY'
import hashlib,sys
print(hashlib.sha256(b'\0'.join(x.encode() for x in sys.argv[1:])+b'\0').hexdigest())
PY
}

observed_exec_start_json() {
    local response object property
    response=$(busctl --user --json=short call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
        org.freedesktop.systemd1.Manager GetUnit s "$1")
    object=$(jq -er 'select(.type=="o" and (.data|length)==1)|.data[0]' <<<"$response")
    property=$(busctl --user --json=short get-property org.freedesktop.systemd1 "$object" \
        org.freedesktop.systemd1.Service ExecStart)
    jq -ceS 'select(.type=="a(sasbttttuii)" and (.data|length)==1)|.data[0] as $v|
      select(($v|length)==10)|{argv:$v[1],ignore_errors:$v[2],path:$v[0]}' <<<"$property"
}

expected_exec_start_json() {
    jq -cn --args '$ARGS.positional as $argv|{argv:$argv,ignore_errors:false,path:$argv[0]}' -- "${VIEWFLOW_ARGV[@]}"
}

exact_executable_pids() {
    local expected=$1 proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
    return 0
}

assert_process_census() {
    local allowed_pid=${1:-0} proc_root=${2:-/proc} self_pid_override=${3-}
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$allowed_pid" "$proc_root" "$self_pid_override" "$VIEWFLOW" "${VIEWFLOW_ARGV[@]}" <<'PY'
import os,re,stat,sys
allowed=int(sys.argv[1]);proc_root=sys.argv[2];override=sys.argv[3];viewflow=os.path.realpath(sys.argv[4]);expected=[x.encode() for x in sys.argv[5:]]
if override and proc_root=='/proc':raise SystemExit('self PID override is forbidden for production census')
self_pid=int(override) if override else os.getpid()
token=re.compile(rb'(?i)(?<![a-z0-9_])deskflow(?:-core)?(?![a-z0-9_])')
def identity(value):return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid)
def stable_read(path):
 fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  before=os.fstat(fd);data=b''
  while True:
   chunk=os.read(fd,1<<20)
   if not chunk:break
   data+=chunk
  after=os.fstat(fd);current=os.stat(path,follow_symlinks=False)
  if not stat.S_ISREG(before.st_mode) or identity(before)!=identity(after) or identity(after)!=identity(current):
   raise OSError('proc identity changed')
  return data
 finally:os.close(fd)
def start_ticks(base):
 data=stable_read(base+'/stat');close=data.rfind(b') ')
 if close<0:raise OSError('proc stat malformed')
 fields=data[close+2:].split()
 if len(fields)<20 or not fields[19].isdigit():raise OSError('proc start ticks malformed')
 return fields[19]
bad=[]
for name in os.listdir(proc_root):
 if not name.isdigit(): continue
 pid=int(name);base=f'{proc_root}/{pid}'
 if pid==self_pid:continue
 try:
  ticks_before=start_ticks(base);comm=stable_read(base+'/comm').rstrip(b'\n')
  raw=stable_read(base+'/cmdline');argv=raw.rstrip(b'\0').split(b'\0') if raw else []
  if start_ticks(base)!=ticks_before:continue
 except (FileNotFoundError,ProcessLookupError): continue
 except (PermissionError,OSError,UnicodeError):
  raise SystemExit(f'incomplete system-wide process census at PID {pid}')
 candidate=pid==allowed or any(token.search(field) for field in [comm,*argv])
 if not candidate:continue
 try:
  link=os.readlink(base+'/exe');exe=os.path.realpath(link if os.path.isabs(link) else os.path.join(base,link))
  if start_ticks(base)!=ticks_before:continue
 except (FileNotFoundError,ProcessLookupError):
  try:still_same=start_ticks(base)==ticks_before
  except (FileNotFoundError,ProcessLookupError):continue
  except (PermissionError,OSError,UnicodeError):still_same=True
  if still_same:raise SystemExit(f'candidate executable unreadable at PID {pid}')
  continue
 except (PermissionError,OSError,UnicodeError):
  raise SystemExit(f'candidate executable unreadable at PID {pid}')
 fields=[comm,os.fsencode(exe),os.path.basename(os.fsencode(exe)),*argv]
 if pid==allowed:
  if not (exe==viewflow and argv==expected):bad.append(pid)
 elif any(token.search(field) for field in fields):bad.append(pid)
if bad: raise SystemExit('unexpected Deskflow-displaying process: '+','.join(map(str,bad)))
PY
}

assert_deskflow_zero() {
    local allowed_pid=${1:-0} state main exact_gui exact_core tcp_count
    state=$(unit_prop "$DESKFLOW_UNIT" ActiveState); main=$(unit_prop "$DESKFLOW_UNIT" MainPID)
    exact_gui=$(exact_executable_pids "$DESKFLOW"); exact_core=$(exact_executable_pids "$DESKFLOW_CORE")
    tcp_count=$(ss -H -ltn 'sport = :24800' | awk 'END {print NR+0}')
    [[ $state == inactive && $main == 0 && -z $exact_gui && -z $exact_core && $tcp_count == 0 &&
       ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]] || die 'Deskflow/VFQST/TCP boundary is not zero'
    assert_process_census "$allowed_pid"
}

assert_claims_absent() {
    [[ ! -e $ABORT_CLAIM && ! -L $ABORT_CLAIM && ! -e $RELEASE_CLAIM && ! -L $RELEASE_CLAIM ]] ||
        die 'deployment claim exists'
}

capture_journal() {
    local pid=$1 invocation=$2 output=$3 boot boot_compact
    boot=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id); boot_compact=${boot//-/}
    journalctl --user --quiet --no-pager --output=json "_SYSTEMD_INVOCATION_ID=$invocation" "_PID=$pid" \
      "_BOOT_ID=$boot_compact" >"$output"
    jq -s -e --arg inv "$invocation" --arg pid "$pid" --arg boot "$boot_compact" '
      length>0 and all(.[];._SYSTEMD_INVOCATION_ID==$inv and ._PID==$pid and ._BOOT_ID==$boot)
    ' "$output" >/dev/null || die 'journal crossed PID/invocation/boot identity'
    [[ $(jq -sr --arg line "$STARTUP" '[.[]|select((.MESSAGE//"")==$line)]|length' "$output") == 1 ]] ||
        die 'journal lacks exactly one protocol-1.3 startup record'
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$output" <<'PY'
import json,re,sys
items=[json.loads(line) for line in open(sys.argv[1],encoding='utf-8') if line.strip()]
auth=re.compile(r'^viewflowd server authenticated peer (172\.16\.105\.70:[1-9][0-9]{0,4})$')
probe=re.compile(r'^viewflowd server peer (172\.16\.105\.70:[1-9][0-9]{0,4}) probe=[0-9]+ responder_us=[0-9]+$')
seen=set(); chosen=None
for item in items:
 line=item.get('MESSAGE','')
 match=auth.fullmatch(line)
 if match:
  port=int(match.group(1).rsplit(':',1)[1])
  if port>65535: raise SystemExit('authenticated peer port differs')
  seen.add(match.group(1))
 match=probe.fullmatch(line)
 if match and match.group(1) in seen: chosen=line
if chosen is None: raise SystemExit('no exact post-auth Windows probe in invocation')
print(chosen)
PY
}

validate_receipt_bound_probe() {
    local journal=$1 expected_sha=$2
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$journal" "$expected_sha" <<'PY'
import hashlib,json,re,sys
path,expected=sys.argv[1:]
if not re.fullmatch(r'[0-9a-f]{64}',expected):raise SystemExit('receipt-bound probe SHA differs')
items=[json.loads(line) for line in open(path,encoding='utf-8') if line.strip()]
auth=re.compile(r'^viewflowd server authenticated peer (172\.16\.105\.70:([1-9][0-9]{0,4}))$')
probe=re.compile(r'^viewflowd server peer (172\.16\.105\.70:([1-9][0-9]{0,4})) probe=[0-9]+ responder_us=[0-9]+$')
authenticated=set();matches=0
for item in items:
 line=item.get('MESSAGE','')
 auth_match=auth.fullmatch(line)
 if auth_match:
  port=int(auth_match.group(2))
  if port>65535:raise SystemExit('authenticated peer port differs')
  authenticated.add(auth_match.group(1))
  continue
 probe_match=probe.fullmatch(line)
 if not probe_match:continue
 port=int(probe_match.group(2))
 if port>65535:raise SystemExit('probe peer port differs')
 if probe_match.group(1) not in authenticated:continue
 if hashlib.sha256(line.encode('utf-8')).hexdigest()==expected:matches+=1
# One or more exact post-auth occurrences are accepted; later distinct probes
# are expected and cannot displace the immutable receipt-bound record.
if matches<1:raise SystemExit('receipt-bound exact post-auth probe disappeared')
print(matches)
PY
}

validate_old_live() {
    local pid ticks invocation cgroup unit journal probe exact_pids udp sidecar
    pid=$(jq -er '.linux.viewflow_main_pid' "$linux_started"); ticks=$(jq -er '.linux.viewflow_start_ticks' "$linux_started")
    invocation=$(jq -er '.linux.viewflow_invocation_id' "$linux_started"); cgroup=$(jq -er '.linux.viewflow_control_group' "$linux_started")
    unit=$(jq -er '.linux.viewflow_unit' "$linux_started")
    [[ $(unit_prop "$unit" LoadState) == loaded && $(unit_prop "$unit" ActiveState) == active &&
       $(unit_prop "$unit" SubState) == running && $(unit_prop "$unit" Transient) == yes &&
       $(unit_prop "$unit" KillMode) == control-group && $(unit_prop "$unit" MainPID) == "$pid" &&
       $(unit_prop "$unit" InvocationID) == "$invocation" && $(unit_prop "$unit" ControlGroup) == "$cgroup" &&
       $(process_ticks "$pid") == "$ticks" && $(process_cgroup "$pid") == "$cgroup" &&
       $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" &&
       $(cmdline_sha "$pid") == "$(expected_cmdline_sha)" &&
       $(jq -er '.linux.viewflow_exec_start_sha256' "$linux_started") == "$(expected_argv_sha)" &&
       $(observed_exec_start_json "$unit") == "$(expected_exec_start_json)" ]] || die 'old transient PID/start/exec/argv tuple differs'
    exact_pids=$(exact_executable_pids "$VIEWFLOW"); [[ $exact_pids == "$pid" ]] || die 'extra Viewflow process exists'
    udp=$(ss -H -lunp 'sport = :44119'); [[ $(awk 'NF{n++}END{print n+0}' <<<"$udp") == 1 && $udp == *"pid=$pid,"* ]] ||
        die 'old transient does not exclusively own UDP 44119'
    sidecar=$(ss -H -lxnp | grep -F -- "$SIDECAR_SOCKET" || true); [[ $(awk 'NF{n++}END{print n+0}' <<<"$sidecar") == 1 && $sidecar == *"pid=$pid,"* ]] ||
        die 'old transient sidecar listener differs'
    assert_deskflow_zero "$pid"; assert_claims_absent
    [[ ! -e $MARKER && ! -L $MARKER ]] || die 'old VFDQT unexpectedly reappeared'
    journal=$(new_temp "$bridge_root" old-journal); probe=$(capture_journal "$pid" "$invocation" "$journal")
    [[ $probe =~ ^viewflowd\ server\ peer\ 172\.16\.105\.70: ]] || die 'old authenticated probe differs'
}

assert_all_runtime_zero() {
    local old_unit=$1 exact udp sidecar old_main old_cgroup
    old_main=$(unit_prop "$old_unit" MainPID 2>/dev/null || true); old_cgroup=$(unit_prop "$old_unit" ControlGroup 2>/dev/null || true)
    exact=$(exact_executable_pids "$VIEWFLOW"); udp=$(ss -H -lun 'sport = :44119'); sidecar=$(ss -H -lx | grep -F -- "$SIDECAR_SOCKET" || true)
    [[ ${old_main:-0} == 0 && -z $old_cgroup && -z $exact && -z $udp && -z $sidecar ]] || die 'old transient/runtime did not reach zero'
    assert_deskflow_zero 0; assert_claims_absent
}

validate_persistent_start_intent() {
    local intent=$bridge_root/persistent-start-intent.json old_stopped=$bridge_root/old-stopped.json
    exact_file 'persistent start intent' "$intent" "$(sha256 "$intent")" 600; strict_json "$intent"
    jq -e --arg op "$new_operation" --arg stopped "$(sha256 "$old_stopped")" --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" '
      keys==["old_stopped_sha256","operation_id","schema_version","state","unit_file_sha256","viewflowd_sha256"] and
      .schema_version==1 and .state=="viewflow-fresh-persistent-v13-start-intent" and .operation_id==$op and
      .old_stopped_sha256==$stopped and .viewflowd_sha256==$vf and .unit_file_sha256==$unit
    ' "$intent" >/dev/null || die 'persistent start intent binding differs'
}

assert_old_transient_absent() {
    local unit=$1 old_pid=$2 old_ticks=$3 active main cgroup
    active=$(unit_prop "$unit" ActiveState 2>/dev/null || true); main=$(unit_prop "$unit" MainPID 2>/dev/null || true)
    cgroup=$(unit_prop "$unit" ControlGroup 2>/dev/null || true)
    [[ $active == inactive || -z $active ]] || die 'old transient unit is not inactive/absent'
    [[ ${main:-0} == 0 && -z $cgroup ]] || die 'old transient unit still has PID/cgroup ownership'
    if [[ -r /proc/$old_pid/stat && $(process_ticks "$old_pid" 2>/dev/null || true) == "$old_ticks" ]]; then
        die 'old transient recorded PID/start tuple still exists'
    fi
}

validate_persistent_live_before_receipt() {
    local expected_pid=${1-} expected_ticks=${2-} expected_invocation=${3-} expected_cgroup=${4-} expected_environment_sha=${5-}
    local pid invocation cgroup ticks environment_sha udp sidecar old_unit old_pid old_ticks
    (($#==0 || $#==5)) || die 'internal pre-receipt persistent tuple contract differs'
    validate_persistent_start_intent; validate_installed_persistent
    pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID); invocation=$(unit_prop "$VIEWFLOW_UNIT" InvocationID)
    cgroup=$(unit_prop "$VIEWFLOW_UNIT" ControlGroup); ticks=$(process_ticks "$pid")
    [[ $pid =~ ^[1-9][0-9]*$ && $ticks =~ ^[1-9][0-9]*$ && $invocation =~ ^[0-9a-f]{32}$ &&
       $cgroup == */viewflow-peer.service && $(unit_prop "$VIEWFLOW_UNIT" LoadState) == loaded &&
       $(unit_prop "$VIEWFLOW_UNIT" ActiveState) == active && $(unit_prop "$VIEWFLOW_UNIT" SubState) == running &&
       $(unit_prop "$VIEWFLOW_UNIT" Transient) == no && $(process_cgroup "$pid") == "$cgroup" &&
       $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" && $(cmdline_sha "$pid") == "$(expected_cmdline_sha)" &&
       $(observed_exec_start_json "$VIEWFLOW_UNIT") == "$(expected_exec_start_json)" &&
       $(exact_executable_pids "$VIEWFLOW") == "$pid" ]] || die 'intent-authorized persistent service live tuple differs before receipt'
    assert_persistent_unit_contract; assert_cgroup_only_main "$cgroup" "$pid"
    environment_sha=$(process_environment_sha "$pid" "$ticks" "$invocation")
    if (($#==5)); then
        [[ $pid == "$expected_pid" && $ticks == "$expected_ticks" && $invocation == "$expected_invocation" &&
           $cgroup == "$expected_cgroup" && $environment_sha == "$expected_environment_sha" ]] ||
            die 'persistent receipt tuple became stale before create-once publication'
    fi
    udp=$(ss -H -lunp 'sport = :44119'); [[ $(awk 'NF{n++}END{print n+0}' <<<"$udp") == 1 && $udp == *"pid=$pid,"* ]] ||
        die 'intent-authorized persistent UDP ownership differs before receipt'
    sidecar=$(ss -H -lxnp | grep -F -- "$SIDECAR_SOCKET" || true)
    [[ $(awk 'NF{n++}END{print n+0}' <<<"$sidecar") == 1 && $sidecar == *"pid=$pid,"* ]] ||
        die 'intent-authorized persistent sidecar ownership differs before receipt'
    assert_deskflow_zero "$pid"; assert_claims_absent
    old_unit=$(jq -er '.linux.viewflow_unit' "$linux_started")
    old_pid=$(jq -er '.linux.viewflow_main_pid' "$linux_started")
    old_ticks=$(jq -er '.linux.viewflow_start_ticks' "$linux_started")
    assert_old_transient_absent "$old_unit" "$old_pid" "$old_ticks"
}

ensure_roots() {
    local parent
    parent=$(dirname -- "$bridge_root")
    if [[ ! -e $parent && ! -L $parent ]]; then
        [[ $parent == "$STATE/bridges" ]]; mkdir -- "$parent"; chmod 0700 "$parent"; sync -f "$STATE"
    fi
    safe_owner_dir 'bridge parent' "$parent"
    if [[ ! -e $bridge_root && ! -L $bridge_root ]]; then mkdir -- "$bridge_root"; chmod 0700 "$bridge_root"; sync -f "$parent"; fi
    safe_owner_dir 'bridge root' "$bridge_root"; safe_owner_dir 'deployments root' "$DEPLOYMENTS"
}

snapshot_one() {
    local variable=$1 leaf=$2 expected=$3 expected_mode=$4 source destination
    source=${!variable}; destination=$bridge_root/immutable-inputs/$leaf
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$source" "$destination" "$expected" "$expected_mode" <<'PY'
import ctypes,errno,hashlib,os,stat,sys
source,destination,expected,mode=sys.argv[1:]; mode=int(mode,8); parent=os.path.dirname(destination); leaf=os.path.basename(destination)
def identity(value):
 return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
def stable_read(path):
 fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  before=os.fstat(fd); data=b''
  while True:
   chunk=os.read(fd,1<<20)
   if not chunk: break
   data+=chunk
  after=os.fstat(fd); current=os.stat(path,follow_symlinks=False)
  if (not stat.S_ISREG(before.st_mode) or before.st_uid!=1000 or before.st_nlink!=1
      or identity(before)!=identity(after) or identity(after)!=identity(current)
      or hashlib.sha256(data).hexdigest()!=expected): raise SystemExit('snapshot source identity/hash differs')
  return data
 finally: os.close(fd)
data=stable_read(source); pfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
temporary=None
try:
 pst=os.fstat(pfd)
 if pst.st_uid!=1000 or stat.S_IMODE(pst.st_mode) not in (0o700,0o500): raise SystemExit('snapshot directory mode/owner differs')
 try: dfd=os.open(leaf,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=pfd)
 except FileNotFoundError: dfd=None
 if dfd is not None:
  try:
   dst=os.fstat(dfd); existing=b''
   while True:
    chunk=os.read(dfd,1<<20)
    if not chunk: break
    existing+=chunk
   after=os.fstat(dfd); current=os.stat(leaf,dir_fd=pfd,follow_symlinks=False)
   if (not stat.S_ISREG(dst.st_mode) or dst.st_uid!=1000 or dst.st_nlink!=1 or stat.S_IMODE(dst.st_mode)!=mode
       or identity(dst)!=identity(after) or identity(after)!=identity(current)
       or existing!=data or hashlib.sha256(existing).hexdigest()!=expected): raise SystemExit('sealed snapshot differs')
  finally: os.close(dfd)
 else:
  if stat.S_IMODE(pst.st_mode)!=0o700: raise SystemExit('sealed snapshot is incomplete')
  temporary='.'+leaf+'.tmp.'+os.urandom(16).hex()
  fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC,mode,dir_fd=pfd)
  try:
   view=memoryview(data)
   while view:
    count=os.write(fd,view)
    if count<=0: raise SystemExit('snapshot short write')
    view=view[count:]
   os.fchmod(fd,mode)
   os.fsync(fd)
  finally: os.close(fd)
  libc=ctypes.CDLL(None,use_errno=True); rename_no_replace=libc.renameat2
  rename_no_replace.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint];rename_no_replace.restype=ctypes.c_int
  if rename_no_replace(pfd,os.fsencode(temporary),pfd,os.fsencode(leaf),1)!=0:
   error=ctypes.get_errno(); raise OSError(error,os.strerror(error))
  temporary=None;os.fsync(pfd)
  dfd=os.open(leaf,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=pfd)
  try:
   dst=os.fstat(dfd);published=b''
   while True:
    chunk=os.read(dfd,1<<20)
    if not chunk:break
    published+=chunk
   after=os.fstat(dfd);current=os.stat(leaf,dir_fd=pfd,follow_symlinks=False)
   if (not stat.S_ISREG(dst.st_mode) or dst.st_uid!=1000 or dst.st_nlink!=1 or stat.S_IMODE(dst.st_mode)!=mode
       or identity(dst)!=identity(after) or identity(after)!=identity(current) or published!=data
       or hashlib.sha256(published).hexdigest()!=expected):raise SystemExit('published snapshot identity/hash/mode differs')
  finally:os.close(dfd)
finally:
 if temporary is not None:
  try:os.unlink(temporary,dir_fd=pfd)
  except FileNotFoundError:pass
 os.close(pfd)
PY
    printf -v "$variable" '%s' "$destination"
}

snapshot_inputs() {
    local directory=$bridge_root/immutable-inputs mode
    if [[ ! -e $directory && ! -L $directory ]]; then mkdir -- "$directory"; chmod 0700 "$directory"; sync -f "$bridge_root"; fi
    safe_owner_dir 'immutable snapshot directory' "$directory"; mode=$(stat -c '%a' -- "$directory")
    [[ $mode == 700 || $mode == 500 ]] || die 'immutable snapshot directory mode differs'
    snapshot_one terminal early-gate-terminal.json "$terminal_sha" 400
    snapshot_one authorization authorization.json "$authorization_sha" 400
    snapshot_one abort_receipt abort-receipt.json "$abort_receipt_sha" 400
    snapshot_one linux_started linux-started.json "$linux_started_sha" 400
    snapshot_one post_reattest post-abort-reattest.json "$post_reattest_sha" 400
    snapshot_one vfdqa durable-vfdqa.bin "$vfdqa_sha" 400
    snapshot_one marker_candidate viewflow-deployment-marker "$marker_candidate_sha" 555
    snapshot_one prepare_script prepare-v13-marker-handoff.sh "$prepare_script_sha" 555
    snapshot_one collector_script collect-viewflow-v13-bootstrap-evidence.sh "$collector_script_sha" 555
    if [[ $mode == 700 ]]; then chmod 0500 "$directory"; sync -f "$bridge_root"; fi
    [[ $(find "$directory" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' ') == \
       'abort-receipt.json authorization.json collect-viewflow-v13-bootstrap-evidence.sh durable-vfdqa.bin early-gate-terminal.json linux-started.json post-abort-reattest.json prepare-v13-marker-handoff.sh viewflow-deployment-marker ' ]] ||
        die 'immutable snapshot file set differs'
}

validate_plan() {
    exact_file 'transition plan' "$plan" "$(sha256 "$plan")" 600; strict_json "$plan"
    jq -e --arg old "$old_operation" --arg old_coord "$(jq -er '.coordinator_instance_id' "$authorization")" \
      --arg terminal "$terminal" --arg terminal_sha "$terminal_sha" --arg auth "$authorization" --arg auth_sha "$authorization_sha" \
      --arg abort "$abort_receipt" --arg abort_sha "$abort_receipt_sha" --arg linux "$linux_started" --arg linux_sha "$linux_started_sha" \
      --arg post "$post_reattest" --arg post_sha "$post_reattest_sha" --arg vfdqa "$vfdqa" --arg vfdqa_sha "$vfdqa_sha" \
      --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" --arg marker "$marker_candidate" --arg marker_sha "$marker_candidate_sha" \
      --arg prepare "$prepare_script" --arg prepare_sha "$prepare_script_sha" --arg collector "$collector_script" --arg collector_sha "$collector_script_sha" '
      keys==["fresh_operation_root","inputs","new_coordinator_instance_id","new_operation_id","old_operation_id","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-early-abort-terminal-to-fresh-v21-plan" and .old_operation_id==$old and
      (.new_operation_id|test("^[0-9a-f]{32}$")) and .new_operation_id!=$old and
      (.new_coordinator_instance_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      .new_coordinator_instance_id!=$old_coord and .fresh_operation_root==("/home/wilf/.local/state/viewflow/deployments/"+.new_operation_id) and
      .inputs=={terminal:{path:$terminal,sha256:$terminal_sha},authorization:{path:$auth,sha256:$auth_sha},abort_receipt:{path:$abort,sha256:$abort_sha},linux_started:{path:$linux,sha256:$linux_sha},post_abort_reattest:{path:$post,sha256:$post_sha},vfdqa:{path:$vfdqa,sha256:$vfdqa_sha},installed_viewflow_sha256:$vf,installed_viewflow_unit_sha256:$unit,marker_candidate:{path:$marker,sha256:$marker_sha},prepare_script:{path:$prepare,sha256:$prepare_sha},collector_script:{path:$collector,sha256:$collector_sha}}
    ' "$plan" >/dev/null || die 'transition plan binding differs'
    new_operation=$(jq -er '.new_operation_id' "$plan"); new_coordinator=$(jq -er '.new_coordinator_instance_id' "$plan")
    fresh_root=$(jq -er '.fresh_operation_root' "$plan")
    if [[ ! -e $fresh_root && ! -L $fresh_root ]]; then mkdir -- "$fresh_root"; chmod 0700 "$fresh_root"; sync -f "$DEPLOYMENTS"; fi
    safe_owner_dir 'fresh root' "$fresh_root"
    publish_receipt=$fresh_root/deployment-publish.json; handoff_receipt=$fresh_root/marker-handoff.json
    frozen_evidence=$fresh_root/linux-frozen.json; final_receipt=$fresh_root/early-abort-terminal-to-fresh-v21.json
}

make_plan() {
    local temp id
    plan=$bridge_root/transition-plan.json
    if [[ -e $plan || -L $plan ]]; then validate_plan; return; fi
    [[ $mode == execute ]] || die 'resume requires an immutable transition plan'
    id=$(uuidgen | tr 'A-F' 'a-f'); new_operation=${id//-/}; new_coordinator=$(uuidgen | tr 'A-F' 'a-f')
    [[ $new_operation != "$old_operation" && $new_coordinator != "$(jq -er '.coordinator_instance_id' "$authorization")" ]] || die 'fresh identity reuse'
    fresh_root=$DEPLOYMENTS/$new_operation; [[ ! -e $fresh_root && ! -L $fresh_root ]] || die 'fresh root collision'
    temp=$(new_temp "$bridge_root" plan)
    jq -cn --arg old "$old_operation" --arg new "$new_operation" --arg coord "$new_coordinator" --arg root "$fresh_root" \
      --arg terminal "$terminal" --arg terminal_sha "$terminal_sha" --arg auth "$authorization" --arg auth_sha "$authorization_sha" \
      --arg abort "$abort_receipt" --arg abort_sha "$abort_receipt_sha" --arg linux "$linux_started" --arg linux_sha "$linux_started_sha" \
      --arg post "$post_reattest" --arg post_sha "$post_reattest_sha" --arg vfdqa "$vfdqa" --arg vfdqa_sha "$vfdqa_sha" \
      --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" --arg marker "$marker_candidate" --arg marker_sha "$marker_candidate_sha" \
      --arg prepare "$prepare_script" --arg prepare_sha "$prepare_script_sha" --arg collector "$collector_script" --arg collector_sha "$collector_script_sha" '
      {schema_version:1,state:"viewflow-early-abort-terminal-to-fresh-v21-plan",old_operation_id:$old,new_operation_id:$new,
       new_coordinator_instance_id:$coord,fresh_operation_root:$root,inputs:{terminal:{path:$terminal,sha256:$terminal_sha},
       authorization:{path:$auth,sha256:$auth_sha},abort_receipt:{path:$abort,sha256:$abort_sha},linux_started:{path:$linux,sha256:$linux_sha},
       post_abort_reattest:{path:$post,sha256:$post_sha},vfdqa:{path:$vfdqa,sha256:$vfdqa_sha},installed_viewflow_sha256:$vf,
       installed_viewflow_unit_sha256:$unit,marker_candidate:{path:$marker,sha256:$marker_sha},prepare_script:{path:$prepare,sha256:$prepare_sha},
       collector_script:{path:$collector,sha256:$collector_sha}}}
    ' >"$temp"
    publish_new "$temp" "$plan"; temporary_files=(); validate_plan
}

ensure_old_retired() {
    local intent=$bridge_root/old-stop-intent.json stopped=$bridge_root/old-stopped.json persistent_intent=$bridge_root/persistent-start-intent.json
    local unit temp deadline pid ticks persistent_state
    unit=$(jq -er '.linux.viewflow_unit' "$linux_started"); pid=$(jq -er '.linux.viewflow_main_pid' "$linux_started")
    ticks=$(jq -er '.linux.viewflow_start_ticks' "$linux_started")
    if [[ -e $stopped || -L $stopped ]]; then
        exact_file 'old stopped receipt' "$stopped" "$(sha256 "$stopped")" 600; strict_json "$stopped"
        jq -e --arg old "$old_operation" --arg plan_sha "$(sha256 "$plan")" --arg unit "$unit" --argjson pid "$pid" '
          keys==["old_main_pid","old_operation_id","old_unit","plan_sha256","post_stop","schema_version","state"] and
          .schema_version==1 and .state=="viewflow-early-abort-old-transient-stopped" and .old_operation_id==$old and
          .plan_sha256==$plan_sha and .old_unit==$unit and .old_main_pid==$pid and
          .post_stop=={viewflow_process_count:0,udp_44119_listener_count:0,sidecar_socket_present:false,
            deskflow_process_count:0,deskflow_core_process_count:0,tcp_24800_listener_count:0}
        ' "$stopped" >/dev/null || die 'old stopped receipt binding differs'
        assert_old_transient_absent "$unit" "$pid" "$ticks"
        if [[ -e $persistent_intent || -L $persistent_intent ]]; then
            validate_persistent_start_intent
            persistent_state=$(unit_prop "$VIEWFLOW_UNIT" ActiveState 2>/dev/null || true)
            case $persistent_state in
                active) validate_persistent_live_before_receipt ;;
                inactive|'') assert_all_runtime_zero "$unit" ;;
                *) die 'intent-authorized persistent service is neither exact-active nor fully stopped' ;;
            esac
        else
            assert_all_runtime_zero "$unit"
        fi
        return
    fi
    if [[ ! -e $intent && ! -L $intent ]]; then
        validate_old_live
        temp=$(new_temp "$bridge_root" old-stop-intent)
        jq -cn --arg old "$old_operation" --arg plan_sha "$(sha256 "$plan")" --arg unit "$unit" \
          --arg invocation "$(jq -er '.linux.viewflow_invocation_id' "$linux_started")" \
          --argjson pid "$pid" --argjson ticks "$(jq -er '.linux.viewflow_start_ticks' "$linux_started")" '
          {schema_version:1,state:"viewflow-early-abort-old-transient-stop-intent",old_operation_id:$old,
           plan_sha256:$plan_sha,unit:$unit,main_pid:$pid,start_ticks:$ticks,invocation_id:$invocation}
        ' >"$temp"; publish_new "$temp" "$intent"
    else
        exact_file 'old stop intent' "$intent" "$(sha256 "$intent")" 600; strict_json "$intent"
        jq -e --arg old "$old_operation" --arg plan_sha "$(sha256 "$plan")" --arg unit "$unit" --argjson pid "$pid" \
          --argjson ticks "$(jq -er '.linux.viewflow_start_ticks' "$linux_started")" --arg invocation "$(jq -er '.linux.viewflow_invocation_id' "$linux_started")" '
          keys==["invocation_id","main_pid","old_operation_id","plan_sha256","schema_version","start_ticks","state","unit"] and
          .schema_version==1 and .state=="viewflow-early-abort-old-transient-stop-intent" and .old_operation_id==$old and
          .plan_sha256==$plan_sha and .unit==$unit and .main_pid==$pid and .start_ticks==$ticks and .invocation_id==$invocation
        ' "$intent" >/dev/null || die 'old stop intent binding differs'
    fi
    case $(unit_prop "$unit" ActiveState 2>/dev/null || true) in
        active) validate_old_live; systemctl --user stop "$unit" ;;
        inactive|'') ;;
        *) die 'unsupported old transient state during resume' ;;
    esac
    deadline=$((SECONDS+STOP_TIMEOUT))
    while ((SECONDS<deadline)); do assert_all_runtime_zero "$unit" 2>/dev/null && break; sleep 0.1; done
    assert_all_runtime_zero "$unit"; [[ ! -e /proc/$pid ]] || die 'old recorded PID remains after stop'
    temp=$(new_temp "$bridge_root" old-stopped)
    jq -cn --arg old "$old_operation" --arg plan_sha "$(sha256 "$plan")" --arg unit "$unit" --argjson pid "$pid" '
      {schema_version:1,state:"viewflow-early-abort-old-transient-stopped",old_operation_id:$old,plan_sha256:$plan_sha,
       old_unit:$unit,old_main_pid:$pid,post_stop:{viewflow_process_count:0,udp_44119_listener_count:0,
       sidecar_socket_present:false,deskflow_process_count:0,deskflow_core_process_count:0,tcp_24800_listener_count:0}}
    ' >"$temp"; publish_new "$temp" "$stopped"
}

validate_installed_persistent() {
    exact_file 'installed Viewflow' "$VIEWFLOW" "$installed_viewflow_sha" 755
    exact_file 'installed Viewflow unit' "$VIEWFLOW_UNIT_FILE" "$installed_unit_sha" 644
    [[ $(grep -Fxc -- "$EXPECTED_EXECSTART" "$VIEWFLOW_UNIT_FILE") == 1 && $(grep -Fc 'ExecStart' "$VIEWFLOW_UNIT_FILE") == 1 ]] ||
        die 'installed persistent unit ExecStart differs'
    [[ $(sha256 "$DESKFLOW") == "$(jq -er '.old_linux_deskflow_sha256' "$authorization")" &&
       $(sha256 "$DESKFLOW_CORE") == "$(jq -er '.old_linux_deskflow_core_sha256' "$authorization")" ]] ||
        die 'installed Deskflow bytes differ from early authorization'
    assert_persistent_unit_contract
}

assert_persistent_unit_contract() {
    [[ $(unit_prop "$VIEWFLOW_UNIT" FragmentPath) == "$VIEWFLOW_UNIT_FILE" &&
       -z $(unit_prop "$VIEWFLOW_UNIT" DropInPaths) && -z $(unit_prop "$VIEWFLOW_UNIT" Environment) &&
       $(unit_prop "$VIEWFLOW_UNIT" KillMode) == control-group && $(unit_prop "$VIEWFLOW_UNIT" Restart) == on-failure &&
       $(unit_prop "$VIEWFLOW_UNIT" RestartUSec) == 1s && -z $(unit_prop "$VIEWFLOW_UNIT" ExecStartPre) &&
       -z $(unit_prop "$VIEWFLOW_UNIT" ExecStartPost) ]] || die 'persistent effective unit contract differs'
}

assert_cgroup_only_main() {
    local cgroup=$1 pid=$2 procs
    [[ $cgroup == /* && -f /sys/fs/cgroup$cgroup/cgroup.procs ]] || die 'persistent cgroup.procs is unavailable'
    procs=$(sort -n "/sys/fs/cgroup$cgroup/cgroup.procs" | tr '\n' ' ')
    [[ $procs == "$pid " ]] || die 'persistent cgroup contains an unexpected helper PID'
}

process_environment_sha() {
    local pid=$1 ticks=$2 invocation=$3 proc_root=${4:-/proc}
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$pid" "$ticks" "$invocation" "$proc_root" <<'PY'
import hashlib,os,re,sys
pid,expected_ticks,invocation,proc_root=sys.argv[1:];base=f'{proc_root}/{pid}'
def ticks():
 with open(base+'/stat','rb') as stream:data=stream.read()
 close=data.rfind(b') ')
 if close<0:raise SystemExit('process stat is malformed')
 return data[close+2:].split()[19].decode()
if ticks()!=expected_ticks:raise SystemExit('process start ticks changed before environment read')
fd=os.open(base+'/environ',os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 before=os.fstat(fd);data=b''
 while True:
  chunk=os.read(fd,1<<20)
  if not chunk:break
  data+=chunk
 after=os.fstat(fd)
 if (before.st_dev,before.st_ino,before.st_mode)!=(after.st_dev,after.st_ino,after.st_mode):raise SystemExit('process environment identity changed')
finally:os.close(fd)
if ticks()!=expected_ticks or not data.endswith(b'\0'):raise SystemExit('process changed across environment read')
entries=data[:-1].split(b'\0');environment={}
allowed={'HOME','LANG','LANGUAGE','LC_ALL','LC_CTYPE','LOGNAME','PATH','SHELL','USER','XDG_RUNTIME_DIR','DBUS_SESSION_BUS_ADDRESS',
 'DISPLAY','WAYLAND_DISPLAY','XAUTHORITY','XDG_CURRENT_DESKTOP','XDG_DATA_DIRS','XDG_SESSION_CLASS','XDG_SESSION_DESKTOP',
 'XDG_SESSION_ID','XDG_SESSION_TYPE','XDG_SEAT','XDG_VTNR','XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_STATE_HOME','DESKTOP_SESSION',
 'HYPRLAND_INSTANCE_SIGNATURE','AQ_DRM_DEVICES','XCURSOR_SIZE','XCURSOR_THEME','GDK_BACKEND','GTK_THEME','QT_QPA_PLATFORM',
 'QT_QPA_PLATFORMTHEME','QT_WAYLAND_DISABLE_WINDOWDECORATION','QT_AUTO_SCREEN_SCALE_FACTOR','MOZ_ENABLE_WAYLAND',
 'SDL_VIDEODRIVER','_JAVA_AWT_WM_NONREPARENTING','NIXOS_OZONE_WL','ELECTRON_OZONE_PLATFORM_HINT','SSH_AUTH_SOCK',
 'GTK_IM_MODULE','QT_IM_MODULE','XMODIFIERS','RUNTIME_DIRECTORY','MANAGERPIDFDID',
 'INVOCATION_ID','JOURNAL_STREAM','SYSTEMD_EXEC_PID','MEMORY_PRESSURE_WATCH','MEMORY_PRESSURE_WRITE','SYSTEMD_UNIT','SYSTEMD_SLICE','MANAGERPID'}
for entry in entries:
 if b'=' not in entry:raise SystemExit('process environment entry is malformed')
 raw_name,value=entry.split(b'=',1)
 try:name=raw_name.decode('ascii')
 except UnicodeDecodeError:raise SystemExit('process environment name is not ASCII')
 if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',name) or name in environment:raise SystemExit('process environment name differs')
 if name not in allowed:raise SystemExit('process environment contains an unapproved name: '+name)
 environment[name]=value
for forbidden in ('LD_PRELOAD','LD_AUDIT','LD_LIBRARY_PATH','PYTHONPATH','PYTHONHOME','BASH_ENV','ENV'):
 if forbidden in environment:raise SystemExit('dangerous process environment is present: '+forbidden)
required={
 'HOME':b'/home/wilf','USER':b'wilf','LOGNAME':b'wilf','XDG_RUNTIME_DIR':b'/run/user/1000',
 'DBUS_SESSION_BUS_ADDRESS':b'unix:path=/run/user/1000/bus','INVOCATION_ID':invocation.encode(),'SYSTEMD_EXEC_PID':pid.encode(),
 'RUNTIME_DIRECTORY':b'/run/user/1000/viewflow'}
for name,value in required.items():
 if environment.get(name)!=value:raise SystemExit('required process environment differs: '+name)
desktop_input_exact={'GTK_IM_MODULE':b'fcitx','QT_IM_MODULE':b'fcitx','XMODIFIERS':b'@im=fcitx'}
for name,value in desktop_input_exact.items():
 if environment.get(name)!=value:raise SystemExit('approved input-method environment differs: '+name)
manager_pidfd_id=environment.get('MANAGERPIDFDID',b'')
if not re.fullmatch(rb'[1-9][0-9]{0,18}',manager_pidfd_id) or int(manager_pidfd_id)>2**63-1:
 raise SystemExit('MANAGERPIDFDID is not canonical bounded positive decimal')
approved_path=(b'/usr/lib/jvm/java-21-openjdk/bin:/home/wilf/.nix-profile/bin:/nix/var/nix/profiles/default/bin:'
 b'/home/wilf/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/opt/cuda/bin:/usr/lib/emscripten:'
 b'/usr/lib/jvm/default/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl:/usr/lib/rustup/bin:'
 b'/home/wilf/.local/bin')
if environment.get('PATH')!=approved_path:
 raise SystemExit('approved process PATH differs')
if not re.fullmatch(rb'[1-9][0-9]*:[1-9][0-9]*',environment.get('JOURNAL_STREAM',b'')):raise SystemExit('JOURNAL_STREAM differs')
canonical=b'\0'.join(sorted(entries))+b'\0';print(hashlib.sha256(canonical).hexdigest())
PY
}

validate_persistent_receipt() {
    local receipt=$bridge_root/persistent-started.json pid ticks invocation cgroup environment_sha probe_sha journal temp udp sidecar
    exact_file 'persistent start receipt' "$receipt" "$(sha256 "$receipt")" 600; strict_json "$receipt"
    jq -e --arg op "$new_operation" --arg vf "$installed_viewflow_sha" --arg unit_sha "$installed_unit_sha" \
      --arg expected "$(printf '%s' "$(expected_exec_start_json)" | sha256sum | awk '{print $1}')" --arg cmd "$(expected_cmdline_sha)" '
      keys==["authenticated_peer_ip","authenticated_probe_record_sha256","cmdline_sha256","control_group","environment_sha256","executable_sha256","expected_exec_start_sha256","invocation_id","journal_sha256","main_pid","operation_id","schema_version","start_ticks","state","unit","unit_file_sha256"] and
      .schema_version==1 and .state=="viewflow-fresh-persistent-v13-authenticated" and .operation_id==$op and
      .unit=="viewflow-peer.service" and .executable_sha256==$vf and .unit_file_sha256==$unit_sha and
      (.main_pid|type=="number" and .>0 and .==floor) and (.start_ticks|type=="number" and .>0 and .==floor) and
      (.invocation_id|test("^[0-9a-f]{32}$")) and (.control_group|endswith("/viewflow-peer.service")) and
      .expected_exec_start_sha256==$expected and .cmdline_sha256==$cmd and (.environment_sha256|test("^[0-9a-f]{64}$")) and .authenticated_peer_ip=="172.16.105.70" and
      (.authenticated_probe_record_sha256|test("^[0-9a-f]{64}$")) and (.journal_sha256|test("^[0-9a-f]{64}$"))
    ' "$receipt" >/dev/null || die 'persistent start receipt binding differs'
    pid=$(jq -er '.main_pid' "$receipt"); ticks=$(jq -er '.start_ticks' "$receipt")
    invocation=$(jq -er '.invocation_id' "$receipt"); cgroup=$(jq -er '.control_group' "$receipt")
    [[ $(unit_prop "$VIEWFLOW_UNIT" LoadState) == loaded && $(unit_prop "$VIEWFLOW_UNIT" ActiveState) == active &&
       $(unit_prop "$VIEWFLOW_UNIT" SubState) == running && $(unit_prop "$VIEWFLOW_UNIT" MainPID) == "$pid" &&
       $(unit_prop "$VIEWFLOW_UNIT" InvocationID) == "$invocation" && $(unit_prop "$VIEWFLOW_UNIT" ControlGroup) == "$cgroup" &&
       $(unit_prop "$VIEWFLOW_UNIT" Transient) == no && $(process_ticks "$pid") == "$ticks" && $(process_cgroup "$pid") == "$cgroup" &&
       $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" && $(cmdline_sha "$pid") == "$(expected_cmdline_sha)" &&
       $(observed_exec_start_json "$VIEWFLOW_UNIT") == "$(expected_exec_start_json)" &&
       $(exact_executable_pids "$VIEWFLOW") == "$pid" ]] || die 'persistent service PID/start/exec/argv tuple differs'
    assert_persistent_unit_contract; assert_cgroup_only_main "$cgroup" "$pid"
    environment_sha=$(process_environment_sha "$pid" "$ticks" "$invocation")
    [[ $environment_sha == "$(jq -er '.environment_sha256' "$receipt")" ]] || die 'persistent process environment changed or is unapproved'
    udp=$(ss -H -lunp 'sport = :44119'); [[ $(awk 'NF{n++}END{print n+0}' <<<"$udp") == 1 && $udp == *"pid=$pid,"* ]] || die 'persistent UDP ownership differs'
    sidecar=$(ss -H -lxnp | grep -F -- "$SIDECAR_SOCKET" || true); [[ $(awk 'NF{n++}END{print n+0}' <<<"$sidecar") == 1 && $sidecar == *"pid=$pid,"* ]] || die 'persistent sidecar ownership differs'
    assert_deskflow_zero "$pid"; assert_claims_absent
    temp=$(new_temp "$bridge_root" persistent-reattest-journal); capture_journal "$pid" "$invocation" "$temp" >/dev/null
    probe_sha=$(jq -er '.authenticated_probe_record_sha256' "$receipt")
    validate_receipt_bound_probe "$temp" "$probe_sha" >/dev/null || die 'receipt-bound fresh authenticated probe disappeared'
    [[ $(process_environment_sha "$pid" "$ticks" "$invocation") == "$environment_sha" ]] || die 'persistent process environment changed across live reattestation'
    validate_persistent_live_before_receipt "$pid" "$ticks" "$invocation" "$cgroup" "$environment_sha"
}

ensure_persistent_started() {
    local intent=$bridge_root/persistent-start-intent.json receipt=$bridge_root/persistent-started.json old_stopped=$bridge_root/old-stopped.json
    local temp deadline pid ticks invocation cgroup environment_sha journal probe persistent_state persistent_main persistent_cgroup old_unit
    old_unit=$(jq -er '.linux.viewflow_unit' "$linux_started")
    validate_installed_persistent
    if [[ -e $receipt || -L $receipt ]]; then validate_persistent_receipt; return; fi
    if [[ ! -e $intent && ! -L $intent ]]; then
        [[ $(unit_prop "$VIEWFLOW_UNIT" ActiveState) == inactive && $(unit_prop "$VIEWFLOW_UNIT" MainPID) == 0 ]] ||
            die 'persistent service active without start intent'
        temp=$(new_temp "$bridge_root" persistent-start-intent)
        jq -cn --arg op "$new_operation" --arg stopped "$(sha256 "$old_stopped")" --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" '
          {schema_version:1,state:"viewflow-fresh-persistent-v13-start-intent",operation_id:$op,
           old_stopped_sha256:$stopped,viewflowd_sha256:$vf,unit_file_sha256:$unit}
        ' >"$temp"; publish_new "$temp" "$intent"
    fi
    validate_persistent_start_intent
    persistent_state=$(unit_prop "$VIEWFLOW_UNIT" ActiveState 2>/dev/null || true)
    case $persistent_state in
        active)
            validate_persistent_live_before_receipt
            ;;
        inactive|'')
            persistent_main=$(unit_prop "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true)
            persistent_cgroup=$(unit_prop "$VIEWFLOW_UNIT" ControlGroup 2>/dev/null || true)
            [[ ${persistent_main:-0} == 0 && -z $persistent_cgroup ]] ||
                die 'intent-authorized persistent service has stale PID/cgroup before start'
            assert_all_runtime_zero "$old_unit"
            systemctl --user daemon-reload
            [[ $(sha256 "$VIEWFLOW") == "$installed_viewflow_sha" && $(sha256 "$VIEWFLOW_UNIT_FILE") == "$installed_unit_sha" ]] ||
                die 'installed files changed across daemon-reload'
            assert_persistent_unit_contract
            systemctl --user start "$VIEWFLOW_UNIT"
            ;;
        *) die 'intent-authorized persistent service is neither exact-active nor fully stopped' ;;
    esac
    deadline=$((SECONDS+START_TIMEOUT)); pid=0
    while ((SECONDS<deadline)); do
        pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true)
        [[ $pid =~ ^[1-9][0-9]*$ && -e /proc/$pid/exe && $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" ]] && break
        pid=0; sleep 0.1
    done
    [[ $pid =~ ^[1-9][0-9]*$ ]] || die 'persistent v1.3 service did not start'
    ticks=$(process_ticks "$pid"); invocation=$(unit_prop "$VIEWFLOW_UNIT" InvocationID); cgroup=$(unit_prop "$VIEWFLOW_UNIT" ControlGroup)
    journal=$(new_temp "$bridge_root" persistent-journal)
    deadline=$((SECONDS+START_TIMEOUT)); probe=''
    while ((SECONDS<deadline)); do probe=$(capture_journal "$pid" "$invocation" "$journal" 2>/dev/null || true); [[ -n $probe ]] && break; sleep 0.2; done
    [[ -n $probe ]] || die 'fresh persistent invocation lacks exact authenticated probe'
    environment_sha=$(process_environment_sha "$pid" "$ticks" "$invocation")
    temp=$(new_temp "$bridge_root" persistent-started)
    jq -cn --arg op "$new_operation" --arg vf "$installed_viewflow_sha" --arg unit_sha "$installed_unit_sha" \
      --arg invocation "$invocation" --arg cgroup "$cgroup" --arg expected "$(printf '%s' "$(expected_exec_start_json)" | sha256sum | awk '{print $1}')" \
      --arg cmd "$(expected_cmdline_sha)" --arg probe "$(printf '%s' "$probe" | sha256sum | awk '{print $1}')" \
      --arg environment "$environment_sha" --arg journal "$(sha256 "$journal")" --argjson pid "$pid" --argjson ticks "$ticks" '
      {schema_version:1,state:"viewflow-fresh-persistent-v13-authenticated",operation_id:$op,unit:"viewflow-peer.service",
       main_pid:$pid,start_ticks:$ticks,invocation_id:$invocation,control_group:$cgroup,executable_sha256:$vf,
       unit_file_sha256:$unit_sha,expected_exec_start_sha256:$expected,cmdline_sha256:$cmd,environment_sha256:$environment,authenticated_peer_ip:"172.16.105.70",
       authenticated_probe_record_sha256:$probe,journal_sha256:$journal}
    ' >"$temp"
    validate_persistent_live_before_receipt "$pid" "$ticks" "$invocation" "$cgroup" "$environment_sha"
    publish_new "$temp" "$receipt"; validate_persistent_receipt
}

assert_marker_lock_held() {
    if [[ ! $marker_lock_fd =~ ^[0-9]+$ ]] || ((marker_lock_fd<3)); then die 'marker lock FD is absent'; fi
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$marker_lock_fd" "$MARKER_LOCK" <<'PY'
import fcntl,os,stat,sys
fd=int(sys.argv[1]);path=sys.argv[2]
def identity(value):return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
before=os.fstat(fd);current=os.stat(path,follow_symlinks=False)
if (not stat.S_ISREG(before.st_mode) or before.st_uid!=1000 or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=0o600
    or identity(before)!=identity(current)):raise SystemExit('marker lock stable identity/mode differs')
probe=os.open(path,os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 try:fcntl.flock(probe,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:pass
 else:raise SystemExit('marker lock FD is not exclusively locked')
finally:os.close(probe)
PY
}

enter_marker_lock() {
    [[ -z $marker_lock_fd ]] || { assert_marker_lock_held; return; }
    exec /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$bridge_source_path" "$bridge_source_sha" "$MARKER_LOCK" "${original_argv[@]}" <<'PY'
import fcntl,hashlib,os,stat,sys
script,expected_source_sha,lock,*args=sys.argv[1:];parent=os.path.dirname(lock);leaf=os.path.basename(lock)
def identity(value):return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
pfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 pst=os.fstat(pfd)
 if pst.st_uid!=1000 or stat.S_IMODE(pst.st_mode)&0o077:raise SystemExit('marker lock parent is not owner-only')
 try:
  fd=os.open(leaf,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC|os.O_NOFOLLOW,0o600,dir_fd=pfd)
  os.fchmod(fd,0o600);os.fsync(fd);os.fsync(pfd)
 except FileExistsError:fd=os.open(leaf,os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=pfd)
 before=os.fstat(fd);current=os.stat(leaf,dir_fd=pfd,follow_symlinks=False)
 if (not stat.S_ISREG(before.st_mode) or before.st_uid!=1000 or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=0o600
     or identity(before)!=identity(current)):raise SystemExit('marker lock stable identity/mode differs')
 fcntl.flock(fd,fcntl.LOCK_EX)
 after=os.fstat(fd);current=os.stat(leaf,dir_fd=pfd,follow_symlinks=False)
 if identity(before)!=identity(after) or identity(after)!=identity(current):raise SystemExit('marker lock changed while acquiring')
finally:os.close(pfd)
sfd=os.open(script,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 sbefore=os.fstat(sfd);data=b''
 while True:
  chunk=os.read(sfd,1<<20)
  if not chunk:break
  data+=chunk
 safter=os.fstat(sfd);scurrent=os.stat(script,follow_symlinks=False)
 if (not stat.S_ISREG(sbefore.st_mode) or sbefore.st_uid!=1000 or sbefore.st_nlink!=1
     or identity(sbefore)!=identity(safter) or identity(safter)!=identity(scurrent)):raise SystemExit('bridge source changed before locked re-exec')
finally:os.close(sfd)
source_sha=hashlib.sha256(data).hexdigest()
if expected_source_sha and source_sha!=expected_source_sha:raise SystemExit('bridge source hash changed across locked re-exec')
sealed=os.memfd_create('viewflow-marker-locked-bridge',os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING);view=memoryview(data)
while view:
 count=os.write(sealed,view)
 if count<=0:raise SystemExit('bridge sealed re-exec short write')
 view=view[count:]
os.lseek(sealed,0,os.SEEK_SET);seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
fcntl.fcntl(sealed,fcntl.F_ADD_SEALS,seals)
if fcntl.fcntl(sealed,fcntl.F_GET_SEALS)!=seals:raise SystemExit('bridge sealed re-exec flags differ')
fcntl.fcntl(fd,fcntl.F_SETFD,fcntl.fcntl(fd,fcntl.F_GETFD)&~fcntl.FD_CLOEXEC)
fcntl.fcntl(sealed,fcntl.F_SETFD,fcntl.fcntl(sealed,fcntl.F_GETFD)&~fcntl.FD_CLOEXEC)
os.execve('/usr/bin/bash',['/usr/bin/bash',f'/proc/self/fd/{sealed}',*args],{
 'HOME':'/home/wilf','PATH':'/usr/bin:/bin','XDG_RUNTIME_DIR':'/run/user/1000','DBUS_SESSION_BUS_ADDRESS':'unix:path=/run/user/1000/bus',
 'VIEWFLOW_MARKER_LOCK_FD':str(fd),'VIEWFLOW_BRIDGE_SOURCE_PATH':script,'VIEWFLOW_BRIDGE_SOURCE_SHA256':source_sha})
PY
}

release_marker_lock() {
    assert_marker_lock_held
    exec {marker_lock_fd}>&-
    marker_lock_fd=''; unset VIEWFLOW_MARKER_LOCK_FD
}

validate_fresh_marker_record() {
    assert_marker_lock_held
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$MARKER" "$new_operation" "$new_coordinator" "$marker_lock_fd" "$MARKER_LOCK" <<'PY'
import hashlib,os,stat,sys,uuid
path,operation,coordinator,lock_fd,lock_path=sys.argv[1:];lock_fd=int(lock_fd)
def ident(value): return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
locked=os.fstat(lock_fd);lock_current=os.stat(lock_path,follow_symlinks=False)
if (not stat.S_ISREG(locked.st_mode) or locked.st_uid!=1000 or locked.st_nlink!=1 or stat.S_IMODE(locked.st_mode)!=0o600
    or ident(locked)!=ident(lock_current)):raise SystemExit('marker lock differs during marker read')
fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
try:
 before=os.fstat(fd);b=b''
 while True:
  chunk=os.read(fd,4096)
  if not chunk:break
  b+=chunk
 after=os.fstat(fd);current=os.stat(path,follow_symlinks=False)
 if (not stat.S_ISREG(before.st_mode) or before.st_uid!=1000 or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=0o600
     or before.st_size!=256 or ident(before)!=ident(after) or ident(after)!=ident(current)): raise SystemExit('fresh marker stable-open identity differs')
finally:os.close(fd)
op=operation.encode();coord=coordinator
if len(b)!=256 or b[:13]!=b'VFDQT001\x01\x01\x02\x01\x01' or b[13]!=len(op) or any(b[14:16]): raise SystemExit('fresh marker header differs')
if b[16:16+len(op)]!=op or any(b[16+len(op):144]): raise SystemExit('fresh marker operation differs')
if b[144:160]!=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes or b[160:176]!=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes or b[176:192]!=uuid.UUID(coord).bytes: raise SystemExit('fresh marker identity differs')
created=int.from_bytes(b[192:200],'little')
if created==0 or int.from_bytes(b[200:208],'little')!=1 or any(b[208:]): raise SystemExit('fresh marker timestamp/generation differs')
print(hashlib.sha256(b).hexdigest(),created,before.st_dev,before.st_ino,sep=':')
PY
}

validate_fresh_marker_bytes() { validate_fresh_marker_record | awk -F: '{print $1}'; }

validate_publish_and_handoff() {
    local marker_record marker_sha
    marker_record=$(validate_fresh_marker_record); marker_sha=${marker_record%%:*}
    exact_file 'fresh publish receipt' "$publish_receipt" "$(sha256 "$publish_receipt")" 600; strict_json "$publish_receipt"
    exact_file 'fresh handoff receipt' "$handoff_receipt" "$(sha256 "$handoff_receipt")" 600; strict_json "$handoff_receipt"
    jq -e --arg op "$new_operation" --arg coord "$new_coordinator" --arg marker "$marker_sha" '
      keys==["coordinator_instance_id","created_at_unix_ms","created_at_utc","marker_generation","marker_path","marker_sha256","operation_id","protocol_version","schema_version","source_display_id","state","target_device_id"] and
      .schema_version==1 and .state=="deployment-quarantine-published" and .protocol_version=="2.1" and .operation_id==$op and
      .coordinator_instance_id==$coord and .marker_generation=="1" and .source_display_id=="00000000-0000-0000-0000-000000000101" and
      .target_device_id=="00000000-0000-0000-0000-000000000002" and .marker_path=="/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and
      .marker_sha256==$marker and (.created_at_unix_ms|test("^[1-9][0-9]*$"))
    ' "$publish_receipt" >/dev/null || die 'fresh deployment publish receipt differs'
    jq -e --arg op "$new_operation" --arg coord "$new_coordinator" --arg marker "$marker_sha" \
      --arg cli "$marker_candidate_sha" --arg publish "$publish_receipt" --arg publish_sha "$(sha256 "$publish_receipt")" \
      --arg deskflow "$(jq -er '.old_linux_deskflow_sha256' "$authorization")" --arg core "$(jq -er '.old_linux_deskflow_core_sha256' "$authorization")" '
      keys==["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256","deployment_publish_receipt_path","deployment_publish_receipt_sha256","deskflow_core_exact_process_count","deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_exact_process_count","deskflow_executable_path","deskflow_executable_sha256","deskflow_tcp_listener_count","deskflow_tcp_port","deskflow_unit","deskflow_unit_active_state","deskflow_unit_main_pid","marker_cli_path","marker_cli_sha256","marker_generation","observed_at_utc","operation_id","protocol_version","runtime_marker_path","runtime_marker_present","schema_version","source_display_id","state","target_device_id"] and
      .schema_version==1 and .state=="viewflow-v13-marker-handoff-prepared" and .protocol_version=="2.1" and .operation_id==$op and
      .coordinator_instance_id==$coord and .marker_generation=="1" and .source_display_id=="00000000-0000-0000-0000-000000000101" and
      .target_device_id=="00000000-0000-0000-0000-000000000002" and .marker_cli_path=="/home/wilf/.local/lib/viewflow/viewflow-deployment-marker" and
      .marker_cli_sha256==$cli and .deployment_marker_path=="/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and
      .deployment_marker_sha256==$marker and .deployment_publish_receipt_path==$publish and .deployment_publish_receipt_sha256==$publish_sha and
      .deskflow_unit=="deskflow.service" and .deskflow_unit_active_state=="inactive" and .deskflow_unit_main_pid==0 and
      .deskflow_executable_sha256==$deskflow and .deskflow_exact_process_count==0 and .deskflow_core_executable_sha256==$core and
      .deskflow_core_exact_process_count==0 and .deskflow_tcp_listener_count==0 and .runtime_marker_present==false
    ' "$handoff_receipt" >/dev/null || die 'fresh marker handoff receipt differs'
    exact_file 'installed marker CLI' "$MARKER_CLI" "$marker_candidate_sha" 755
    [[ $(validate_fresh_marker_record) == "$marker_record" ]] || die 'fresh marker inode/hash changed across publish/handoff validation'
    assert_claims_absent
}

recover_partial_marker_handoff() {
    local temp created_ms created_utc marker_record marker_sha observed deskflow_sha core_sha stages=()
    assert_marker_lock_held
    [[ -e $bridge_root/marker-publish-intent.json && ! -L $bridge_root/marker-publish-intent.json ]] ||
        die 'fresh marker exists without durable publish intent'
    marker_record=$(validate_fresh_marker_record); marker_sha=${marker_record%%:*}; created_ms=${marker_record#*:}; created_ms=${created_ms%%:*}
    exact_file 'partial marker CLI' "$MARKER_CLI" "$marker_candidate_sha" 755
    if [[ ! -e $publish_receipt && ! -L $publish_receipt ]]; then
        stages=("$fresh_root"/.viewflow-publish.*)
        if ((${#stages[@]} > 1)); then die 'multiple retained prepare publish stages exist'; fi
        if ((${#stages[@]} == 1)); then
            exact_file 'retained prepare stage' "${stages[0]}" "$(sha256 "${stages[0]}")" 600; strict_json "${stages[0]}"
            jq -e --arg op "$new_operation" --arg coord "$new_coordinator" --arg marker "$marker_sha" '
              .schema_version==1 and .state=="deployment-quarantine-published" and .operation_id==$op and
              .coordinator_instance_id==$coord and .marker_sha256==$marker
            ' "${stages[0]}" >/dev/null || die 'retained prepare stage binding differs'
            publish_new "${stages[0]}" "$publish_receipt"
        else
            created_utc=$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$created_ms" <<'PY'
import datetime,sys
ms=int(sys.argv[1]);dt=datetime.datetime.fromtimestamp(ms/1000,datetime.timezone.utc)
print(dt.strftime('%Y-%m-%dT%H:%M:%S.')+f'{ms%1000:03d}Z')
PY
)
            temp=$(new_temp "$fresh_root" recovered-publish)
            jq -cn --arg op "$new_operation" --arg coord "$new_coordinator" --arg marker "$marker_sha" --arg ms "$created_ms" --arg utc "$created_utc" '
              {schema_version:1,state:"deployment-quarantine-published",protocol_version:"2.1",operation_id:$op,
               source_display_id:"00000000-0000-0000-0000-000000000101",target_device_id:"00000000-0000-0000-0000-000000000002",
               coordinator_instance_id:$coord,marker_generation:"1",marker_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",
               marker_sha256:$marker,created_at_unix_ms:$ms,created_at_utc:$utc}
            ' >"$temp"; publish_new "$temp" "$publish_receipt"
        fi
    fi
    if [[ ! -e $handoff_receipt && ! -L $handoff_receipt ]]; then
        assert_deskflow_zero "$(jq -er '.main_pid' "$bridge_root/persistent-started.json")"
        observed=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z'); deskflow_sha=$(sha256 "$DESKFLOW"); core_sha=$(sha256 "$DESKFLOW_CORE")
        temp=$(new_temp "$fresh_root" recovered-handoff)
        jq -cn --arg op "$new_operation" --arg coord "$new_coordinator" --arg marker "$marker_sha" --arg cli "$marker_candidate_sha" \
          --arg publish "$publish_receipt" --arg publish_sha "$(sha256 "$publish_receipt")" --arg deskflow "$deskflow_sha" --arg core "$core_sha" --arg observed "$observed" '
          {schema_version:1,state:"viewflow-v13-marker-handoff-prepared",protocol_version:"2.1",operation_id:$op,
           source_display_id:"00000000-0000-0000-0000-000000000101",target_device_id:"00000000-0000-0000-0000-000000000002",
           coordinator_instance_id:$coord,marker_generation:"1",marker_cli_path:"/home/wilf/.local/lib/viewflow/viewflow-deployment-marker",
           marker_cli_sha256:$cli,deployment_marker_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",
           deployment_marker_sha256:$marker,deployment_publish_receipt_path:$publish,deployment_publish_receipt_sha256:$publish_sha,
           deskflow_unit:"deskflow.service",deskflow_unit_active_state:"inactive",deskflow_unit_main_pid:0,
           deskflow_executable_path:"/home/wilf/.local/lib/deskflow-scale-fix/deskflow",deskflow_executable_sha256:$deskflow,
           deskflow_exact_process_count:0,deskflow_core_executable_path:"/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core",
           deskflow_core_executable_sha256:$core,deskflow_core_exact_process_count:0,deskflow_tcp_port:24800,
           deskflow_tcp_listener_count:0,runtime_marker_path:"/home/wilf/.local/state/viewflow/deskflow-quarantine.v2",
           runtime_marker_present:false,observed_at_utc:$observed}
        ' >"$temp"; publish_new "$temp" "$handoff_receipt"
    fi
    [[ $(validate_fresh_marker_record) == "$marker_record" ]] || die 'fresh marker inode/hash changed during marker recovery'
    validate_publish_and_handoff
}

invoke_prepare_contract() {
    run_pinned_bash "$prepare_script" "$prepare_script_sha" \
      --deployment-marker-candidate "$marker_candidate" --deployment-marker-sha256 "$marker_candidate_sha" \
      --operation-id "$new_operation" --source-display-id "$SOURCE_UUID" --target-device-id "$TARGET_UUID" \
      --coordinator-instance-id "$new_coordinator" --marker-generation 1 \
      --deployment-publish-receipt "$publish_receipt" --bootstrap-handoff-receipt "$handoff_receipt"
}

ensure_marker_handoff() {
    local intent=$bridge_root/marker-publish-intent.json temp
    assert_marker_lock_held
    if [[ -e $handoff_receipt || -L $handoff_receipt ]]; then validate_publish_and_handoff; return; fi
    if [[ ! -e $intent && ! -L $intent ]]; then
        [[ ! -e $MARKER && ! -L $MARKER && ! -e $publish_receipt && ! -L $publish_receipt ]] ||
            die 'fresh marker/receipt exists before marker intent'
        temp=$(new_temp "$bridge_root" marker-intent)
        jq -cn --arg op "$new_operation" --arg coord "$new_coordinator" --arg persistent "$(sha256 "$bridge_root/persistent-started.json")" \
          --arg candidate "$marker_candidate_sha" --arg prepare "$prepare_script_sha" '
          {schema_version:1,state:"viewflow-fresh-marker-publish-intent",operation_id:$op,coordinator_instance_id:$coord,
           marker_generation:"1",persistent_started_sha256:$persistent,marker_candidate_sha256:$candidate,prepare_script_sha256:$prepare}
        ' >"$temp"; publish_new "$temp" "$intent"
    else
        exact_file 'marker publish intent' "$intent" "$(sha256 "$intent")" 600; strict_json "$intent"
        jq -e --arg op "$new_operation" --arg coord "$new_coordinator" --arg persistent "$(sha256 "$bridge_root/persistent-started.json")" \
          --arg candidate "$marker_candidate_sha" --arg prepare "$prepare_script_sha" '
          keys==["coordinator_instance_id","marker_candidate_sha256","marker_generation","operation_id","persistent_started_sha256","prepare_script_sha256","schema_version","state"] and
          .schema_version==1 and .state=="viewflow-fresh-marker-publish-intent" and .operation_id==$op and
          .coordinator_instance_id==$coord and .marker_generation=="1" and .persistent_started_sha256==$persistent and
          .marker_candidate_sha256==$candidate and .prepare_script_sha256==$prepare
        ' "$intent" >/dev/null || die 'marker publish intent binding differs'
    fi
    validate_persistent_receipt
    if [[ -e $MARKER || -L $MARKER || -e $publish_receipt || -L $publish_receipt ]]; then recover_partial_marker_handoff; return; fi
    release_marker_lock
    invoke_prepare_contract
    enter_marker_lock
    die 'locked marker re-exec unexpectedly returned'
}

validate_collector_intent() {
    local intent=$bridge_root/collector-intent.json persistent=$bridge_root/persistent-started.json
    exact_file 'collector intent' "$intent" "$(sha256 "$intent")" 600; strict_json "$intent"
    jq -e --arg op "$new_operation" --arg persistent_sha "$(sha256 "$persistent")" --arg marker_sha "$(sha256 "$handoff_receipt")" \
      --arg vf "$installed_viewflow_sha" --slurpfile p "$persistent" '
      keys==["boot_id","daemon_pid","daemon_sha256","daemon_start_ticks","handoff_sha256","invocation_id","operation_id","persistent_started_sha256","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-fresh-v13-collector-intent" and .operation_id==$op and
      .persistent_started_sha256==$persistent_sha and .handoff_sha256==$marker_sha and .daemon_sha256==$vf and
      ($p|length)==1 and .daemon_pid==$p[0].main_pid and .daemon_start_ticks==$p[0].start_ticks and .invocation_id==$p[0].invocation_id and
      (.boot_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    ' "$intent" >/dev/null || die 'collector intent binding differs'
}

observe_persistent_stably_stopped() {
    local deadline=$((SECONDS+STOP_TIMEOUT)) stable=0 last_restarts='' state sub main result restarts restart_policy cgroup
    while ((SECONDS<deadline)); do
        state=$(unit_prop "$VIEWFLOW_UNIT" ActiveState 2>/dev/null || true)
        sub=$(unit_prop "$VIEWFLOW_UNIT" SubState 2>/dev/null || true)
        main=$(unit_prop "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true)
        result=$(unit_prop "$VIEWFLOW_UNIT" Result 2>/dev/null || true)
        restarts=$(unit_prop "$VIEWFLOW_UNIT" NRestarts 2>/dev/null || true)
        restart_policy=$(unit_prop "$VIEWFLOW_UNIT" Restart 2>/dev/null || true)
        cgroup=$(unit_prop "$VIEWFLOW_UNIT" ControlGroup 2>/dev/null || true)
        if [[ $state == inactive && $sub == dead && $main == 0 && $result == success &&
              $restarts =~ ^[0-9]+$ && $restart_policy == on-failure &&
              -z $cgroup && ( -z $last_restarts || $restarts == "$last_restarts" ) ]]; then
            stable=$((stable+1)); last_restarts=$restarts
            ((stable>=5)) && return 0
        else
            stable=0; last_restarts=$restarts
        fi
        sleep 0.2
    done
    die 'persistent service did not remain inactive/dead with stable restart counter'
}

stop_persistent_for_collector_recovery() {
    local intent=$bridge_root/collector-intent.json
    validate_collector_intent
    [[ $(jq -er '.daemon_pid' "$intent") =~ ^[1-9][0-9]*$ ]] || die 'collector intent PID differs before stop recovery'
    systemctl --user stop "$VIEWFLOW_UNIT"
    assert_persistent_unit_contract; observe_persistent_stably_stopped
}

validate_frozen() {
    local path=${1:-$frozen_evidence} intent=$bridge_root/collector-intent.json completed age boot
    validate_collector_intent
    exact_file 'fresh Linux frozen evidence' "$path" "$(sha256 "$path")" 600; strict_json "$path"
    jq -e --arg op "$new_operation" --arg vf "$installed_viewflow_sha" --slurpfile intent "$intent" '
      keys==["completed_at_unix_ms","daemon","journal","operation_id","post_stop","pre_stop","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-v13-bootstrap-frozen" and .operation_id==$op and
      (.daemon|keys)==["boot_id","daemon_instance_id","executable","pid","sha256","start_ticks","systemd_invocation_id"] and
      .daemon.executable=="/home/wilf/.local/lib/viewflow/viewflowd" and .daemon.sha256==$vf and
      .daemon.pid==$intent[0].daemon_pid and .daemon.start_ticks==$intent[0].daemon_start_ticks and
      .daemon.boot_id==$intent[0].boot_id and .daemon.systemd_invocation_id==$intent[0].invocation_id and
      .daemon.daemon_instance_id==(.daemon.boot_id+"-"+(.daemon.pid|tostring)+"-"+(.daemon.start_ticks|tostring)) and
      (.journal|keys)==["counts","end_cursor","end_realtime_timestamp_us","entry_count","protocol_startup_cursor","protocol_startup_realtime_timestamp_us","query_boot_id","query_pid","query_systemd_invocation_id","slice_sha256","start_cursor","start_realtime_timestamp_us"] and
      .journal.query_boot_id==(.daemon.boot_id|gsub("-";"")) and .journal.query_pid==(.daemon.pid|tostring) and
      .journal.query_systemd_invocation_id==.daemon.systemd_invocation_id and .journal.entry_count>0 and
      (.journal.counts|keys)==["cleanup_or_release_error","input_event","input_sidecar_activation","lease_offered","protocol_1_3_startup"] and
      .journal.counts.protocol_1_3_startup==1 and all(.journal.counts[];type=="number" and .>=0 and .==floor) and
      .pre_stop=={deskflow_unit_active_state:"inactive",deskflow_main_pid:0,deskflow_exact_process_count:0,
        deskflow_core_exact_process_count:0,deskflow_tcp_24800_listener_count:0} and
      .post_stop.unit_active_state=="inactive" and .post_stop.main_pid==0 and .post_stop.exact_process_count==0 and
      .post_stop.udp_44119_listener_count==0 and .post_stop.sidecar_socket_present==false and
      .post_stop.original_daemon_pid_present==false and (.completed_at_unix_ms|type=="number" and .>0 and .==floor)
    ' "$path" >/dev/null || die 'fresh Linux frozen evidence binding differs'
    boot=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id); [[ $(jq -er '.daemon.boot_id' "$path") == "$boot" ]] || die 'frozen evidence is from another boot'
    completed=$(jq -er '.completed_at_unix_ms' "$path"); age=$(($(date -u +%s)-completed/1000)); ((age>=0 && age<=1800)) || die 'frozen evidence age differs'
    observe_persistent_stably_stopped
    [[ ! -e /proc/$(jq -er '.daemon.pid' "$path") && $(unit_prop "$VIEWFLOW_UNIT" MainPID) == 0 &&
       -z $(exact_executable_pids "$VIEWFLOW") && -z $(ss -H -lun 'sport = :44119') && ! -e $SIDECAR_SOCKET ]] ||
        die 'persistent Viewflow is not frozen/stopped'
    assert_deskflow_zero 0
}

recover_after_collector_stop() {
    local intent=$bridge_root/collector-intent.json temp journal transcript pid ticks boot invocation compact
    local startup_count lease_count input_count activation_count error_count entries start_cursor start_us startup_cursor startup_us end_cursor end_us
    local journal_sha transcript_sha completed
    validate_collector_intent
    pid=$(jq -er '.daemon_pid' "$intent"); ticks=$(jq -er '.daemon_start_ticks' "$intent")
    boot=$(jq -er '.boot_id' "$intent"); invocation=$(jq -er '.invocation_id' "$intent"); compact=${boot//-/}
    stop_persistent_for_collector_recovery
    [[ $(tr -d '\r\n' </proc/sys/kernel/random/boot_id) == "$boot" && ! -e /proc/$pid &&
       $(unit_prop "$VIEWFLOW_UNIT" MainPID) == 0 && -z $(exact_executable_pids "$VIEWFLOW") &&
       -z $(ss -H -lun 'sport = :44119') && ! -e $SIDECAR_SOCKET ]] || die 'collector recovery is not at exact stopped boundary'
    assert_deskflow_zero 0
    journal=$(new_temp "$bridge_root" collector-recovery-journal)
    journalctl --user --quiet --no-pager --output=json "_SYSTEMD_INVOCATION_ID=$invocation" "_PID=$pid" "_BOOT_ID=$compact" >"$journal"
    jq -s -e --arg inv "$invocation" --arg pid "$pid" --arg boot "$compact" '
      length>0 and all(.[];._SYSTEMD_INVOCATION_ID==$inv and ._PID==$pid and ._BOOT_ID==$boot)
    ' "$journal" >/dev/null || die 'collector recovery journal crossed invocation/PID/boot'
    startup_count=$(jq -sr --arg line "$STARTUP" '[.[]|select((.MESSAGE//"")==$line)]|length' "$journal"); [[ $startup_count == 1 ]] || die 'collector recovery startup count differs'
    lease_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("lease_offered="))]|length' "$journal")
    input_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("input_event_sequence="))]|length' "$journal")
    activation_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("input sidecar activation"))]|length' "$journal")
    error_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("(?i)(((cleanup|release[-_ ]?all|releaseall).*(failed|error|not confirmed|timed out|rejected))|((failed|error).*(cleanup|release[-_ ]?all|releaseall)))"))]|length' "$journal")
    entries=$(jq -s 'length' "$journal"); start_cursor=$(jq -sr '.[0].__CURSOR' "$journal"); start_us=$(jq -sr '.[0].__REALTIME_TIMESTAMP|tonumber' "$journal")
    startup_cursor=$(jq -sr --arg line "$STARTUP" '[.[]|select((.MESSAGE//"")==$line)][0].__CURSOR' "$journal")
    startup_us=$(jq -sr --arg line "$STARTUP" '[.[]|select((.MESSAGE//"")==$line)][0].__REALTIME_TIMESTAMP|tonumber' "$journal")
    end_cursor=$(jq -sr '.[-1].__CURSOR' "$journal"); end_us=$(jq -sr '.[-1].__REALTIME_TIMESTAMP|tonumber' "$journal"); journal_sha=$(sha256 "$journal")
    transcript=$(new_temp "$bridge_root" collector-recovery-transcript)
    {
        printf 'systemctl_is_active=inactive\n'; printf 'systemctl_main_pid=0\n'; printf 'exact_viewflow_pids=\n'
        printf 'udp_44119_listeners=\n'; printf 'sidecar_socket_present=false\n'; printf 'original_daemon_pid_present=false\n'
    } >"$transcript"
    transcript_sha=$(sha256 "$transcript"); completed=$(($(date -u +%s%N)/1000000)); temp=$(new_temp "$fresh_root" recovered-frozen)
    jq -n --arg op "$new_operation" --argjson pid "$pid" --argjson ticks "$ticks" --arg boot "$boot" --arg compact "$compact" \
      --arg invocation "$invocation" --arg vf "$installed_viewflow_sha" --arg start_cursor "$start_cursor" --argjson start_us "$start_us" \
      --arg startup_cursor "$startup_cursor" --argjson startup_us "$startup_us" --arg end_cursor "$end_cursor" --argjson end_us "$end_us" \
      --argjson entries "$entries" --arg journal_sha "$journal_sha" --argjson startup_count "$startup_count" --argjson lease_count "$lease_count" \
      --argjson input_count "$input_count" --argjson activation_count "$activation_count" --argjson error_count "$error_count" \
      --arg transcript_sha "$transcript_sha" --argjson completed "$completed" '
      {schema_version:1,state:"viewflow-v13-bootstrap-frozen",operation_id:$op,
       daemon:{pid:$pid,start_ticks:$ticks,boot_id:$boot,daemon_instance_id:($boot+"-"+($pid|tostring)+"-"+($ticks|tostring)),
         sha256:$vf,executable:"/home/wilf/.local/lib/viewflow/viewflowd",systemd_invocation_id:$invocation},
       journal:{query_boot_id:$compact,query_pid:($pid|tostring),query_systemd_invocation_id:$invocation,start_cursor:$start_cursor,
         start_realtime_timestamp_us:$start_us,protocol_startup_cursor:$startup_cursor,protocol_startup_realtime_timestamp_us:$startup_us,
         end_cursor:$end_cursor,end_realtime_timestamp_us:$end_us,entry_count:$entries,slice_sha256:$journal_sha,
         counts:{protocol_1_3_startup:$startup_count,lease_offered:$lease_count,input_event:$input_count,
           input_sidecar_activation:$activation_count,cleanup_or_release_error:$error_count}},
       pre_stop:{deskflow_unit_active_state:"inactive",deskflow_main_pid:0,deskflow_exact_process_count:0,
         deskflow_core_exact_process_count:0,deskflow_tcp_24800_listener_count:0},
       post_stop:{unit_active_state:"inactive",main_pid:0,exact_process_count:0,udp_44119_listener_count:0,
         sidecar_socket_present:false,original_daemon_pid_present:false,
         command_outputs:{systemctl_is_active:"inactive",systemctl_main_pid:"0",exact_viewflow_pids:"",udp_44119_listeners:"",
           sidecar_socket_present:"false",original_daemon_pid_present:"false"},
         command_output_format:"key=value newline-delimited UTF-8 in displayed order",command_output_sha256:$transcript_sha},completed_at_unix_ms:$completed}
    ' >"$temp"; publish_new "$temp" "$frozen_evidence"; validate_frozen
}

ensure_frozen() {
    local intent=$bridge_root/collector-intent.json persistent=$bridge_root/persistent-started.json stage=$fresh_root/.collector-staged-$new_operation.json temp
    if [[ -e $frozen_evidence || -L $frozen_evidence ]]; then validate_frozen; return; fi
    if [[ ! -e $intent && ! -L $intent ]]; then
        validate_persistent_receipt; temp=$(new_temp "$bridge_root" collector-intent)
        jq -cn --arg op "$new_operation" --arg persistent_sha "$(sha256 "$persistent")" --arg handoff "$(sha256 "$handoff_receipt")" \
          --arg vf "$installed_viewflow_sha" --arg boot "$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)" \
          --arg invocation "$(jq -er '.invocation_id' "$persistent")" --argjson pid "$(jq -er '.main_pid' "$persistent")" \
          --argjson ticks "$(jq -er '.start_ticks' "$persistent")" '
          {schema_version:1,state:"viewflow-fresh-v13-collector-intent",operation_id:$op,persistent_started_sha256:$persistent_sha,
           handoff_sha256:$handoff,daemon_pid:$pid,daemon_start_ticks:$ticks,boot_id:$boot,invocation_id:$invocation,daemon_sha256:$vf}
        ' >"$temp"; publish_new "$temp" "$intent"
    fi
    validate_collector_intent
    if [[ -e $stage || -L $stage ]]; then
        validate_frozen "$stage"; publish_new "$stage" "$frozen_evidence"; validate_frozen; return
    fi
    if [[ $(unit_prop "$VIEWFLOW_UNIT" ActiveState) != active ]]; then recover_after_collector_stop; return; fi
    validate_persistent_receipt
    invoke_collector_contract "$intent" "$stage"
    validate_frozen "$stage"; publish_new "$stage" "$frozen_evidence"; validate_frozen
}

invoke_collector_contract() {
    local intent=$1 stage=$2
    run_pinned_bash "$collector_script" "$collector_script_sha" --daemon-pid "$(jq -er '.daemon_pid' "$intent")" \
      --daemon-sha256 "$installed_viewflow_sha" --operation-id "$new_operation" --evidence-output "$stage"
}

validate_final() {
    local marker_record marker_sha
    assert_marker_lock_held
    marker_record=$(validate_fresh_marker_record); marker_sha=${marker_record%%:*}
    exact_file 'bridge terminal receipt' "$final_receipt" "$(sha256 "$final_receipt")" 600; strict_json "$final_receipt"
    jq -e --arg old "$old_operation" --arg new "$new_operation" --arg coord "$new_coordinator" \
      --arg terminal "$terminal_sha" --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" --arg linux "$linux_started_sha" \
      --arg post "$post_reattest_sha" --arg vfdqa "$vfdqa_sha" --arg stopped "$(sha256 "$bridge_root/old-stopped.json")" \
      --arg persistent "$(sha256 "$bridge_root/persistent-started.json")" --arg probe "$(jq -er '.authenticated_probe_record_sha256' "$bridge_root/persistent-started.json")" \
      --arg publish "$(sha256 "$publish_receipt")" --arg handoff "$(sha256 "$handoff_receipt")" --arg frozen "$(sha256 "$frozen_evidence")" --arg marker "$marker_sha" '
      keys==["fresh_boundary","marker_generation","new_coordinator_instance_id","new_operation_id","old_operation_id","old_terminal","persistent_v13","retirement","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-early-abort-terminal-to-fresh-v21" and .old_operation_id==$old and
      .new_operation_id==$new and .new_operation_id!=.old_operation_id and .new_coordinator_instance_id==$coord and .marker_generation=="1" and
      .old_terminal=={terminal_sha256:$terminal,authorization_sha256:$auth,abort_receipt_sha256:$abort,
        linux_started_sha256:$linux,post_abort_reattest_sha256:$post,vfdqa_sha256:$vfdqa} and
      .retirement=={old_stopped_sha256:$stopped,viewflow_process_count:0,deskflow_process_count:0,
        deskflow_core_process_count:0,udp_44119_listener_count:0,tcp_24800_listener_count:0,sidecar_socket_present:false} and
      .persistent_v13=={persistent_started_sha256:$persistent,authenticated_probe_record_sha256:$probe,stopped_by_collector:true} and
      .fresh_boundary=={deployment_publish_sha256:$publish,marker_handoff_sha256:$handoff,linux_frozen_sha256:$frozen,
        deployment_marker_sha256:$marker,protocol_version:"2.1"}
    ' "$final_receipt" >/dev/null || die 'bridge terminal receipt binding differs'
    [[ $(validate_fresh_marker_record) == "$marker_record" ]] || die 'fresh marker inode/hash changed across final validation'
}

publish_final() {
    local temp marker_record marker_sha
    assert_marker_lock_held
    if [[ -e $final_receipt || -L $final_receipt ]]; then validate_final; return; fi
    validate_publish_and_handoff; validate_frozen
    marker_record=$(validate_fresh_marker_record); marker_sha=${marker_record%%:*}; temp=$(new_temp "$fresh_root" bridge-terminal)
    jq -cn --arg old "$old_operation" --arg new "$new_operation" --arg coord "$new_coordinator" \
      --arg terminal "$terminal_sha" --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" --arg linux "$linux_started_sha" \
      --arg post "$post_reattest_sha" --arg vfdqa "$vfdqa_sha" --arg stopped "$(sha256 "$bridge_root/old-stopped.json")" \
      --arg persistent "$(sha256 "$bridge_root/persistent-started.json")" --arg probe "$(jq -er '.authenticated_probe_record_sha256' "$bridge_root/persistent-started.json")" \
      --arg publish "$(sha256 "$publish_receipt")" --arg handoff "$(sha256 "$handoff_receipt")" --arg frozen "$(sha256 "$frozen_evidence")" --arg marker "$marker_sha" '
      {schema_version:1,state:"viewflow-early-abort-terminal-to-fresh-v21",old_operation_id:$old,new_operation_id:$new,
       new_coordinator_instance_id:$coord,marker_generation:"1",old_terminal:{terminal_sha256:$terminal,authorization_sha256:$auth,
       abort_receipt_sha256:$abort,linux_started_sha256:$linux,post_abort_reattest_sha256:$post,vfdqa_sha256:$vfdqa},
       retirement:{old_stopped_sha256:$stopped,viewflow_process_count:0,deskflow_process_count:0,deskflow_core_process_count:0,
       udp_44119_listener_count:0,tcp_24800_listener_count:0,sidecar_socket_present:false},
       persistent_v13:{persistent_started_sha256:$persistent,authenticated_probe_record_sha256:$probe,stopped_by_collector:true},
       fresh_boundary:{deployment_publish_sha256:$publish,marker_handoff_sha256:$handoff,linux_frozen_sha256:$frozen,
       deployment_marker_sha256:$marker,protocol_version:"2.1"}}
    ' >"$temp"
    [[ $(validate_fresh_marker_record) == "$marker_record" ]] || die 'fresh marker inode/hash changed before final publication'
    publish_new "$temp" "$final_receipt"
    [[ $(validate_fresh_marker_record) == "$marker_record" ]] || die 'fresh marker inode/hash changed across create-once final publication'
    validate_final
}

reattest_all_inputs() {
    [[ $(sha256 "$terminal") == "$terminal_sha" && $(sha256 "$authorization") == "$authorization_sha" &&
       $(sha256 "$abort_receipt") == "$abort_receipt_sha" && $(sha256 "$linux_started") == "$linux_started_sha" &&
       $(sha256 "$post_reattest") == "$post_reattest_sha" && $(sha256 "$vfdqa") == "$vfdqa_sha" &&
       $(sha256 "$marker_candidate") == "$marker_candidate_sha" && $(sha256 "$prepare_script") == "$prepare_script_sha" &&
       $(sha256 "$collector_script") == "$collector_script_sha" ]] || die 'an immutable input changed during the bridge'
}

snapshot_inputs() {
    local directory=$bridge_root/immutable-inputs
    if [[ ! -e $directory && ! -L $directory ]]; then mkdir -- "$directory"; chmod 0700 "$directory"; sync -f "$bridge_root"; fi
    safe_owner_dir 'immutable snapshot directory' "$directory"
    snapshot_one terminal no-retry-v4-abort-terminal.json "$terminal_sha" 400
    snapshot_one execution_approval no-retry-v4-execution-approval.json "$execution_approval_sha" 400
    snapshot_one authorization no-retry-v4-abort-authorization.json "$authorization_sha" 400
    snapshot_one abort_receipt no-retry-v4-abort-receipt.json "$abort_receipt_sha" 400
    snapshot_one abort_query no-retry-v4-abort-query-receipt.json "$abort_query_sha" 400
    snapshot_one vfdqa durable-vfdqa.bin "$vfdqa_sha" 400
    snapshot_one v4_marker_cli no-retry-v4-marker-cli "$v4_marker_cli_sha" 500
    snapshot_one v4_provenance no-retry-v4-marker-provenance.json "$v4_provenance_sha" 400
    snapshot_one marker_candidate viewflow-deployment-marker "$marker_candidate_sha" 555
    snapshot_one prepare_script prepare-v13-marker-handoff.sh "$prepare_script_sha" 555
    snapshot_one collector_script collect-viewflow-v13-bootstrap-evidence.sh "$collector_script_sha" 555
    chmod 0500 "$directory"; sync -f "$bridge_root"
    terminal=$directory/no-retry-v4-abort-terminal.json; execution_approval=$directory/no-retry-v4-execution-approval.json
    authorization=$directory/no-retry-v4-abort-authorization.json
    abort_receipt=$directory/no-retry-v4-abort-receipt.json; abort_query=$directory/no-retry-v4-abort-query-receipt.json
    vfdqa=$directory/durable-vfdqa.bin; v4_marker_cli=$directory/no-retry-v4-marker-cli
    v4_provenance=$directory/no-retry-v4-marker-provenance.json; marker_candidate=$directory/viewflow-deployment-marker
    prepare_script=$directory/prepare-v13-marker-handoff.sh; collector_script=$directory/collect-viewflow-v13-bootstrap-evidence.sh
}

validate_plan() {
    local old_coordinator
    old_coordinator=$(jq -er '.coordinator_instance_id' "$authorization")
    exact_file 'V4 inactive transition plan' "$plan" "$(sha256 "$plan")" 600; strict_json "$plan"
    jq -e --arg old "$old_operation" --arg terminal "$terminal_sha" --arg approval "$execution_approval_sha" --arg manifest "$V4_MANIFEST_SHA" \
      --arg gate "$V4_GATE_SHA" --arg launcher "$V4_LAUNCHER_SHA" --arg auth "$authorization_sha" \
      --arg abort "$abort_receipt_sha" --arg query "$abort_query_sha" --arg vfdqa "$vfdqa_sha" \
      --arg v4 "$v4_marker_cli_sha" --arg provenance "$v4_provenance_sha" --arg vf "$installed_viewflow_sha" \
      --arg unit "$installed_unit_sha" --arg marker "$marker_candidate_sha" --arg prepare "$prepare_script_sha" --arg collector "$collector_script_sha" \
      --arg old_coord "$old_coordinator" '
      keys==["fresh_operation_root","inputs","new_coordinator_instance_id","new_operation_id","old_operation_id","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-v4-inactive-terminal-to-fresh-v21-plan" and .old_operation_id==$old and
      (.new_operation_id|test("^[0-9a-f]{32}$")) and .new_operation_id!=$old and
      (.new_coordinator_instance_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and .new_coordinator_instance_id!=$old_coord and
      .fresh_operation_root==("/home/wilf/.local/state/viewflow/deployments/"+.new_operation_id) and
      .inputs=={terminal_sha256:$terminal,execution_approval_sha256:$approval,v4_manifest_sha256:$manifest,
       v4_gate_sha256:$gate,v4_launcher_sha256:$launcher,authorization_sha256:$auth,abort_receipt_sha256:$abort,
       abort_query_receipt_sha256:$query,vfdqa_sha256:$vfdqa,v4_marker_cli_sha256:$v4,
       v4_marker_cli_provenance_sha256:$provenance,installed_viewflow_sha256:$vf,installed_unit_sha256:$unit,
       reviewed_marker_sha256:$marker,prepare_script_sha256:$prepare,collector_script_sha256:$collector}
    ' "$plan" >/dev/null || die 'V4 inactive transition plan differs'
    new_operation=$(jq -er '.new_operation_id' "$plan"); new_coordinator=$(jq -er '.new_coordinator_instance_id' "$plan")
    fresh_root=$(jq -er '.fresh_operation_root' "$plan")
    if [[ ! -e $fresh_root && ! -L $fresh_root ]]; then
        mkdir -- "$fresh_root"; chmod 0700 "$fresh_root"; sync -f "$DEPLOYMENTS"
    fi
    safe_owner_dir 'fresh operation root' "$fresh_root"
    publish_receipt=$fresh_root/deployment-publish.json; handoff_receipt=$fresh_root/marker-handoff.json
    frozen_evidence=$fresh_root/linux-frozen.json; final_receipt=$fresh_root/v4-inactive-terminal-to-fresh-v21.json
}

make_plan() {
    local temp candidate_operation candidate_coordinator old_coordinator
    plan=$bridge_root/transition-plan.json
    if [[ -e $plan || -L $plan ]]; then validate_plan; return; fi
    [[ $mode == execute ]] || die 'resume requires an existing V4 inactive transition plan'
    candidate_operation=$(uuidgen | tr -d '-' | tr 'A-F' 'a-f'); candidate_coordinator=$(uuidgen | tr 'A-F' 'a-f')
    [[ $candidate_operation =~ ^[0-9a-f]{32}$ && $candidate_operation != "$old_operation" ]] || die 'fresh operation generation differs'
    old_coordinator=$(jq -er '.coordinator_instance_id' "$authorization")
    [[ $candidate_coordinator =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ &&
       $candidate_coordinator != "$old_coordinator" ]] || die 'fresh coordinator generation differs'
    [[ ! -e $DEPLOYMENTS/$candidate_operation && ! -L $DEPLOYMENTS/$candidate_operation ]] || die 'fresh root collision'
    temp=$(new_temp "$bridge_root" plan)
    jq -cn --arg old "$old_operation" --arg new "$candidate_operation" --arg coord "$candidate_coordinator" \
      --arg root "$DEPLOYMENTS/$candidate_operation" --arg terminal "$terminal_sha" --arg approval "$execution_approval_sha" \
      --arg manifest "$V4_MANIFEST_SHA" --arg gate "$V4_GATE_SHA" --arg launcher "$V4_LAUNCHER_SHA" --arg auth "$authorization_sha" \
      --arg abort "$abort_receipt_sha" --arg query "$abort_query_sha" --arg vfdqa "$vfdqa_sha" --arg v4 "$v4_marker_cli_sha" \
      --arg provenance "$v4_provenance_sha" --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" \
      --arg marker "$marker_candidate_sha" --arg prepare "$prepare_script_sha" --arg collector "$collector_script_sha" '
      {schema_version:1,state:"viewflow-v4-inactive-terminal-to-fresh-v21-plan",old_operation_id:$old,new_operation_id:$new,
       new_coordinator_instance_id:$coord,fresh_operation_root:$root,inputs:{terminal_sha256:$terminal,
       execution_approval_sha256:$approval,v4_manifest_sha256:$manifest,v4_gate_sha256:$gate,v4_launcher_sha256:$launcher,
       authorization_sha256:$auth,abort_receipt_sha256:$abort,abort_query_receipt_sha256:$query,vfdqa_sha256:$vfdqa,
       v4_marker_cli_sha256:$v4,v4_marker_cli_provenance_sha256:$provenance,installed_viewflow_sha256:$vf,
       installed_unit_sha256:$unit,reviewed_marker_sha256:$marker,prepare_script_sha256:$prepare,collector_script_sha256:$collector}}
    ' >"$temp"; publish_new "$temp" "$plan"; validate_plan
}

ensure_roots() {
    local parent
    parent=$(dirname -- "$bridge_root")
    if [[ ! -e $parent && ! -L $parent ]]; then
        [[ $parent == "$STATE/v4-inactive-bridges" ]] || die 'unexpected V4 bridge parent'
        mkdir -- "$parent"; chmod 0700 "$parent"; sync -f "$STATE"
    fi
    safe_owner_dir 'V4 bridge parent' "$parent"
    if [[ ! -e $bridge_root && ! -L $bridge_root ]]; then
        mkdir -- "$bridge_root"; chmod 0700 "$bridge_root"; sync -f "$parent"
    fi
    safe_owner_dir 'V4 bridge root' "$bridge_root"; safe_owner_dir 'deployments root' "$DEPLOYMENTS"
}

assert_source_inactive() {
    local vf_state vf_sub vf_main vf_cgroup df_state df_sub df_main df_cgroup transient transient_state transient_main transient_cgroup
    local exact udp tcp sidecar
    vf_state=$(unit_prop "$VIEWFLOW_UNIT" ActiveState 2>/dev/null || true); vf_sub=$(unit_prop "$VIEWFLOW_UNIT" SubState 2>/dev/null || true)
    vf_main=$(unit_prop "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true); vf_cgroup=$(unit_prop "$VIEWFLOW_UNIT" ControlGroup 2>/dev/null || true)
    df_state=$(unit_prop "$DESKFLOW_UNIT" ActiveState 2>/dev/null || true); df_sub=$(unit_prop "$DESKFLOW_UNIT" SubState 2>/dev/null || true)
    df_main=$(unit_prop "$DESKFLOW_UNIT" MainPID 2>/dev/null || true); df_cgroup=$(unit_prop "$DESKFLOW_UNIT" ControlGroup 2>/dev/null || true)
    transient=viewflow-v13-no-retry-abort-$old_operation.service
    transient_state=$(unit_prop "$transient" ActiveState 2>/dev/null || true); transient_main=$(unit_prop "$transient" MainPID 2>/dev/null || true)
    transient_cgroup=$(unit_prop "$transient" ControlGroup 2>/dev/null || true)
    [[ $vf_state == inactive && $vf_sub == dead && ${vf_main:-0} == 0 && -z $vf_cgroup &&
       $df_state == inactive && $df_sub == dead && ${df_main:-0} == 0 && -z $df_cgroup &&
       ( $transient_state == inactive || -z $transient_state ) && ${transient_main:-0} == 0 && -z $transient_cgroup ]] ||
        die 'V4 source systemd boundary is not fully inactive/dead'
    exact=$(exact_executable_pids "$VIEWFLOW"); udp=$(ss -H -lun 'sport = :44119'); tcp=$(ss -H -ltn 'sport = :24800')
    sidecar=$(ss -H -lx | grep -F -- "$SIDECAR_SOCKET" || true)
    [[ -z $exact && -z $udp && -z $tcp && -z $sidecar && ! -e $SIDECAR_SOCKET && ! -L $SIDECAR_SOCKET ]] ||
        die 'V4 source process/listener boundary is not fully inactive'
    assert_deskflow_zero 0; assert_claims_absent
}

validate_source_boundary_receipt() {
    local receipt=$bridge_root/inactive-source-validated.json
    exact_file 'V4 inactive source receipt' "$receipt" "$(sha256 "$receipt")" 600; strict_json "$receipt"
    jq -e --arg op "$old_operation" --arg plan "$(sha256 "$plan")" --arg terminal "$terminal_sha" \
      --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" --arg query "$abort_query_sha" --arg vfdqa "$vfdqa_sha" '
      keys==["abort_query_receipt_sha256","abort_receipt_sha256","authorization_sha256","linux_inactive","old_operation_id","plan_sha256","schema_version","state","terminal_sha256","vfdqa_sha256","windows_old_peer_unchanged"] and
      .schema_version==1 and .state=="viewflow-v4-inactive-source-validated" and .old_operation_id==$op and .plan_sha256==$plan and
      .terminal_sha256==$terminal and .authorization_sha256==$auth and .abort_receipt_sha256==$abort and
      .abort_query_receipt_sha256==$query and .vfdqa_sha256==$vfdqa and .linux_inactive==true and .windows_old_peer_unchanged==true
    ' "$receipt" >/dev/null || die 'V4 inactive source receipt differs'
}

validate_persistent_start_intent() {
    local intent=$bridge_root/persistent-start-intent.json source=$bridge_root/inactive-source-validated.json
    exact_file 'persistent start intent' "$intent" "$(sha256 "$intent")" 600; strict_json "$intent"
    jq -e --arg op "$new_operation" --arg source "$(sha256 "$source")" --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" '
      keys==["inactive_source_sha256","operation_id","schema_version","state","unit_file_sha256","viewflowd_sha256"] and
      .schema_version==1 and .state=="viewflow-v4-inactive-fresh-persistent-v13-start-intent" and .operation_id==$op and
      .inactive_source_sha256==$source and .viewflowd_sha256==$vf and .unit_file_sha256==$unit
    ' "$intent" >/dev/null || die 'V4 persistent start intent binding differs'
}

validate_persistent_live_before_receipt() {
    local expected_pid=${1-} expected_ticks=${2-} expected_invocation=${3-} expected_cgroup=${4-} expected_environment_sha=${5-}
    local pid invocation cgroup ticks environment_sha udp sidecar
    (($#==0 || $#==5)) || die 'internal pre-receipt persistent tuple contract differs'
    validate_persistent_start_intent; validate_installed_persistent
    pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID); invocation=$(unit_prop "$VIEWFLOW_UNIT" InvocationID)
    cgroup=$(unit_prop "$VIEWFLOW_UNIT" ControlGroup); ticks=$(process_ticks "$pid")
    [[ $pid =~ ^[1-9][0-9]*$ && $ticks =~ ^[1-9][0-9]*$ && $invocation =~ ^[0-9a-f]{32}$ &&
       $cgroup == */viewflow-peer.service && $(unit_prop "$VIEWFLOW_UNIT" LoadState) == loaded &&
       $(unit_prop "$VIEWFLOW_UNIT" ActiveState) == active && $(unit_prop "$VIEWFLOW_UNIT" SubState) == running &&
       $(unit_prop "$VIEWFLOW_UNIT" Transient) == no && $(process_cgroup "$pid") == "$cgroup" &&
       $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" && $(cmdline_sha "$pid") == "$(expected_cmdline_sha)" &&
       $(observed_exec_start_json "$VIEWFLOW_UNIT") == "$(expected_exec_start_json)" &&
       $(exact_executable_pids "$VIEWFLOW") == "$pid" ]] || die 'V4 persistent service live tuple differs before receipt'
    assert_persistent_unit_contract; assert_cgroup_only_main "$cgroup" "$pid"
    environment_sha=$(process_environment_sha "$pid" "$ticks" "$invocation")
    if (($#==5)); then
        [[ $pid == "$expected_pid" && $ticks == "$expected_ticks" && $invocation == "$expected_invocation" &&
           $cgroup == "$expected_cgroup" && $environment_sha == "$expected_environment_sha" ]] ||
            die 'V4 persistent receipt tuple became stale before publication'
    fi
    udp=$(ss -H -lunp 'sport = :44119'); [[ $(awk 'NF{n++}END{print n+0}' <<<"$udp") == 1 && $udp == *"pid=$pid,"* ]] ||
        die 'V4 persistent UDP ownership differs before receipt'
    sidecar=$(ss -H -lxnp | grep -F -- "$SIDECAR_SOCKET" || true)
    [[ $(awk 'NF{n++}END{print n+0}' <<<"$sidecar") == 1 && $sidecar == *"pid=$pid,"* ]] || die 'V4 persistent sidecar differs before receipt'
    assert_deskflow_zero "$pid"; assert_claims_absent
}

ensure_source_boundary() {
    local receipt=$bridge_root/inactive-source-validated.json intent=$bridge_root/persistent-start-intent.json temp state
    if [[ ! -e $receipt && ! -L $receipt ]]; then
        assert_source_inactive
        temp=$(new_temp "$bridge_root" inactive-source)
        jq -cn --arg op "$old_operation" --arg plan "$(sha256 "$plan")" --arg terminal "$terminal_sha" --arg auth "$authorization_sha" \
          --arg abort "$abort_receipt_sha" --arg query "$abort_query_sha" --arg vfdqa "$vfdqa_sha" '
          {schema_version:1,state:"viewflow-v4-inactive-source-validated",old_operation_id:$op,plan_sha256:$plan,
           terminal_sha256:$terminal,authorization_sha256:$auth,abort_receipt_sha256:$abort,abort_query_receipt_sha256:$query,
           vfdqa_sha256:$vfdqa,linux_inactive:true,windows_old_peer_unchanged:true}
        ' >"$temp"; publish_new "$temp" "$receipt"
    fi
    validate_source_boundary_receipt
    if [[ -e $intent || -L $intent ]]; then
        validate_persistent_start_intent; state=$(unit_prop "$VIEWFLOW_UNIT" ActiveState 2>/dev/null || true)
        case $state in active) validate_persistent_live_before_receipt ;; inactive|'') assert_source_inactive ;;
            *) die 'intent-authorized V4 persistent state differs' ;; esac
    else
        assert_source_inactive
    fi
}

ensure_persistent_started() {
    local intent=$bridge_root/persistent-start-intent.json receipt=$bridge_root/persistent-started.json source=$bridge_root/inactive-source-validated.json
    local temp deadline pid ticks invocation cgroup environment_sha journal probe state main cgroup_before
    validate_installed_persistent
    if [[ -e $receipt || -L $receipt ]]; then validate_persistent_receipt; return; fi
    if [[ ! -e $intent && ! -L $intent ]]; then
        assert_source_inactive; temp=$(new_temp "$bridge_root" persistent-start-intent)
        jq -cn --arg op "$new_operation" --arg source "$(sha256 "$source")" --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" '
          {schema_version:1,state:"viewflow-v4-inactive-fresh-persistent-v13-start-intent",operation_id:$op,
           inactive_source_sha256:$source,viewflowd_sha256:$vf,unit_file_sha256:$unit}
        ' >"$temp"; publish_new "$temp" "$intent"
    fi
    validate_persistent_start_intent; state=$(unit_prop "$VIEWFLOW_UNIT" ActiveState 2>/dev/null || true)
    case $state in
      active) validate_persistent_live_before_receipt ;;
      inactive|'')
        main=$(unit_prop "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true); cgroup_before=$(unit_prop "$VIEWFLOW_UNIT" ControlGroup 2>/dev/null || true)
        [[ ${main:-0} == 0 && -z $cgroup_before ]] || die 'V4 persistent has stale PID/cgroup before start'
        assert_source_inactive; systemctl --user daemon-reload
        [[ $(sha256 "$VIEWFLOW") == "$installed_viewflow_sha" && $(sha256 "$VIEWFLOW_UNIT_FILE") == "$installed_unit_sha" ]] || die 'installed files changed across daemon-reload'
        assert_persistent_unit_contract; systemctl --user start "$VIEWFLOW_UNIT" ;;
      *) die 'intent-authorized V4 persistent state differs' ;;
    esac
    deadline=$((SECONDS+START_TIMEOUT)); pid=0
    while ((SECONDS<deadline)); do pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true); [[ $pid =~ ^[1-9][0-9]*$ && -e /proc/$pid/exe && $(sha256 "/proc/$pid/exe") == "$installed_viewflow_sha" ]] && break; pid=0; sleep 0.1; done
    [[ $pid =~ ^[1-9][0-9]*$ ]] || die 'V4 persistent v1.3 service did not start'
    ticks=$(process_ticks "$pid"); invocation=$(unit_prop "$VIEWFLOW_UNIT" InvocationID); cgroup=$(unit_prop "$VIEWFLOW_UNIT" ControlGroup)
    journal=$(new_temp "$bridge_root" persistent-journal); deadline=$((SECONDS+START_TIMEOUT)); probe=''
    while ((SECONDS<deadline)); do probe=$(capture_journal "$pid" "$invocation" "$journal" 2>/dev/null || true); [[ -n $probe ]] && break; sleep 0.2; done
    [[ -n $probe ]] || die 'V4 fresh persistent invocation lacks exact authenticated probe'
    environment_sha=$(process_environment_sha "$pid" "$ticks" "$invocation"); temp=$(new_temp "$bridge_root" persistent-started)
    jq -cn --arg op "$new_operation" --arg vf "$installed_viewflow_sha" --arg unit_sha "$installed_unit_sha" --arg invocation "$invocation" \
      --arg cgroup "$cgroup" --arg expected "$(printf '%s' "$(expected_exec_start_json)" | sha256sum | awk '{print $1}')" \
      --arg cmd "$(expected_cmdline_sha)" --arg probe "$(printf '%s' "$probe" | sha256sum | awk '{print $1}')" \
      --arg environment "$environment_sha" --arg journal "$(sha256 "$journal")" --argjson pid "$pid" --argjson ticks "$ticks" '
      {schema_version:1,state:"viewflow-fresh-persistent-v13-authenticated",operation_id:$op,unit:"viewflow-peer.service",
       main_pid:$pid,start_ticks:$ticks,invocation_id:$invocation,control_group:$cgroup,executable_sha256:$vf,unit_file_sha256:$unit_sha,
       expected_exec_start_sha256:$expected,cmdline_sha256:$cmd,environment_sha256:$environment,authenticated_peer_ip:"172.16.105.70",
       authenticated_probe_record_sha256:$probe,journal_sha256:$journal}
    ' >"$temp"
    validate_persistent_live_before_receipt "$pid" "$ticks" "$invocation" "$cgroup" "$environment_sha"
    publish_new "$temp" "$receipt"; validate_persistent_receipt
}

validate_final() {
    local source=$bridge_root/inactive-source-validated.json persistent=$bridge_root/persistent-started.json
    exact_file 'V4 inactive fresh final receipt' "$final_receipt" "$(sha256 "$final_receipt")" 600; strict_json "$final_receipt"
    jq -e --arg old "$old_operation" --arg new "$new_operation" --arg coord "$new_coordinator" --arg source "$(sha256 "$source")" \
      --arg terminal "$terminal_sha" --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" --arg query "$abort_query_sha" \
      --arg vfdqa "$vfdqa_sha" --arg persistent "$(sha256 "$persistent")" --arg probe "$(jq -er '.authenticated_probe_record_sha256' "$persistent")" \
      --arg publish "$(sha256 "$publish_receipt")" --arg handoff "$(sha256 "$handoff_receipt")" --arg frozen "$(sha256 "$frozen_evidence")" \
      --arg marker "$(validate_fresh_marker_record | cut -d: -f1)" '
      keys==["fresh_boundary","inactive_source","marker_generation","new_coordinator_instance_id","new_operation_id","old_operation_id","persistent_v13","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-v4-inactive-terminal-to-fresh-v21" and .old_operation_id==$old and .new_operation_id==$new and
      .new_coordinator_instance_id==$coord and .marker_generation=="1" and
      .inactive_source=={source_validation_sha256:$source,terminal_sha256:$terminal,authorization_sha256:$auth,
       abort_receipt_sha256:$abort,abort_query_receipt_sha256:$query,vfdqa_sha256:$vfdqa,linux_initially_inactive:true,windows_old_peer_unchanged:true} and
      .persistent_v13=={persistent_started_sha256:$persistent,authenticated_probe_record_sha256:$probe,stopped_by_collector:true} and
      .fresh_boundary=={deployment_publish_sha256:$publish,marker_handoff_sha256:$handoff,linux_frozen_sha256:$frozen,
       deployment_marker_sha256:$marker,protocol_version:"2.1"}
    ' "$final_receipt" >/dev/null || die 'V4 inactive fresh final receipt differs'
}

publish_final() {
    local source=$bridge_root/inactive-source-validated.json persistent=$bridge_root/persistent-started.json temp marker_record marker_sha
    assert_marker_lock_held
    if [[ -e $final_receipt || -L $final_receipt ]]; then validate_final; return; fi
    validate_publish_and_handoff; validate_frozen; marker_record=$(validate_fresh_marker_record); marker_sha=${marker_record%%:*}
    temp=$(new_temp "$fresh_root" v4-inactive-terminal)
    jq -cn --arg old "$old_operation" --arg new "$new_operation" --arg coord "$new_coordinator" --arg source "$(sha256 "$source")" \
      --arg terminal "$terminal_sha" --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" --arg query "$abort_query_sha" \
      --arg vfdqa "$vfdqa_sha" --arg persistent "$(sha256 "$persistent")" --arg probe "$(jq -er '.authenticated_probe_record_sha256' "$persistent")" \
      --arg publish "$(sha256 "$publish_receipt")" --arg handoff "$(sha256 "$handoff_receipt")" --arg frozen "$(sha256 "$frozen_evidence")" --arg marker "$marker_sha" '
      {schema_version:1,state:"viewflow-v4-inactive-terminal-to-fresh-v21",old_operation_id:$old,new_operation_id:$new,
       new_coordinator_instance_id:$coord,marker_generation:"1",inactive_source:{source_validation_sha256:$source,
       terminal_sha256:$terminal,authorization_sha256:$auth,abort_receipt_sha256:$abort,abort_query_receipt_sha256:$query,
       vfdqa_sha256:$vfdqa,linux_initially_inactive:true,windows_old_peer_unchanged:true},persistent_v13:{persistent_started_sha256:$persistent,
       authenticated_probe_record_sha256:$probe,stopped_by_collector:true},fresh_boundary:{deployment_publish_sha256:$publish,
       marker_handoff_sha256:$handoff,linux_frozen_sha256:$frozen,deployment_marker_sha256:$marker,protocol_version:"2.1"}}
    ' >"$temp"
    [[ $(validate_fresh_marker_record) == "$marker_record" ]] || die 'fresh marker changed before V4 final publication'
    publish_new "$temp" "$final_receipt"
    [[ $(validate_fresh_marker_record) == "$marker_record" ]] || die 'fresh marker changed across V4 final publication'
    validate_final
}

reattest_all_inputs() {
    [[ $(sha256 "$terminal") == "$terminal_sha" && $(sha256 "$execution_approval") == "$execution_approval_sha" &&
       $(sha256 "$authorization") == "$authorization_sha" &&
       $(sha256 "$abort_receipt") == "$abort_receipt_sha" && $(sha256 "$abort_query") == "$abort_query_sha" &&
       $(sha256 "$vfdqa") == "$vfdqa_sha" && $(sha256 "$v4_marker_cli") == "$v4_marker_cli_sha" &&
       $(sha256 "$v4_provenance") == "$v4_provenance_sha" && $(sha256 "$marker_candidate") == "$marker_candidate_sha" &&
       $(sha256 "$prepare_script") == "$prepare_script_sha" && $(sha256 "$collector_script") == "$collector_script_sha" ]] ||
        die 'a V4 immutable input changed during bridge execution'
}

main() {
    for command in awk busctl date find flock grep jq journalctl mkdir mktemp python3 readlink sed sha256sum sleep sort ss stat sync systemctl tr uuidgen; do
        command -v "$command" >/dev/null || die "missing command: $command"
    done
    validate_inputs
    if [[ $mode == validate-inputs-only ]]; then printf 'schema4 no-retry/inactive abort inputs validated\n'; return; fi
    ensure_roots; snapshot_inputs; validate_inputs; make_plan; reattest_all_inputs
    ensure_source_boundary; reattest_all_inputs
    if [[ ! -e $bridge_root/collector-intent.json && ! -L $bridge_root/collector-intent.json &&
          ! -e $frozen_evidence && ! -L $frozen_evidence ]]; then ensure_persistent_started; fi
    enter_marker_lock
    ensure_marker_handoff; reattest_all_inputs
    ensure_frozen; reattest_all_inputs
    publish_final
    printf 'fresh protocol-2.1 boundary ready: %s\n' "$final_receipt"
}

main
