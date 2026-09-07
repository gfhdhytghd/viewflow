#!/usr/bin/env bash

# Convert a successful schema-2 failed-pre-mutation VFDQA terminal into a
# fresh generation-1 bootstrap boundary.  This is deliberately a separate
# transaction: it never resumes, rewrites, or reuses the aborted operation.

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'error: bridge-abort-terminal-to-fresh-v21.sh must be executed, not sourced\n' >&2
    return 64
fi
if [[ -n ${LD_PRELOAD-} || -n ${LD_AUDIT-} || -n ${LD_LIBRARY_PATH-} ||
      -n ${BASH_ENV-} || -n ${ENV-} ]]; then
    printf 'error: loader/shell startup environment must be empty; invoke through env -i\n' >&2
    exit 64
fi
unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH BASH_ENV ENV
set -Eeuo pipefail
shopt -s nullglob
umask 077
readonly PATH=/usr/bin:/bin
export PATH

readonly EXPECTED_UID=1000
readonly EXPECTED_HOME=/home/wilf
readonly MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly MARKER_CLAIM=/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim
readonly RELEASE_CLAIM=/home/wilf/.local/state/viewflow/deployment-quarantine.v1.release-claim
readonly RUNTIME_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
readonly MARKER_CLI=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker
readonly VIEWFLOW=/home/wilf/.local/lib/viewflow/viewflowd
readonly VIEWFLOW_UNIT_FILE=/home/wilf/.config/systemd/user/viewflow-peer.service
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly DESKFLOW=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly DESKFLOW_RUNTIME=/tmp/viewflow-deskflow-recovery/deskflow
readonly CORE_RUNTIME=/tmp/viewflow-deskflow-recovery/deskflow-core
readonly ACCEPTANCE_SOCKET=/run/user/1000/deskflow/viewflow-acceptance.sock
readonly SIDECAR_SOCKET=/run/user/1000/viewflow/deskflow.sock
readonly SOURCE_ID=00000000000000000000000000000101
readonly TARGET_ID=00000000000000000000000000000002
readonly SOURCE_UUID=00000000-0000-0000-0000-000000000101
readonly TARGET_UUID=00000000-0000-0000-0000-000000000002
readonly STARTUP='viewflowd protocol 1.3 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged'
readonly DEPLOYMENTS=/home/wilf/.local/state/viewflow/deployments
readonly STOP_TIMEOUT=30
readonly CLEANUP_TIMEOUT=300

readonly -a CONFIG_PATHS=(
    /run/user/1000/systemd/user.control/deskflow.service
    /run/user/1000/systemd/user.control/viewflow-peer.service
    /run/user/1000/systemd/user/deskflow.service
    /run/user/1000/systemd/user/viewflow-peer.service
    /run/user/1000/systemd/user/deskflow.service.d/zz-direct-deskflow.conf
)

mode='' old_operation='' terminal='' terminal_sha='' authorization='' authorization_sha=''
abort_receipt='' abort_receipt_sha='' linux_started='' linux_started_sha=''
bwrap_sha='' installed_viewflow_sha='' installed_unit_sha=''
marker_candidate='' marker_candidate_sha='' prepare_script='' prepare_script_sha=''
collector_script='' collector_script_sha='' bridge_root=''
plan='' intent='' cleanup_proof='' config_intent='' backup_dir='' final_receipt=''
fresh_root='' publish_receipt='' handoff_receipt='' frozen_evidence=''
new_operation='' new_coordinator=''
temporary_files=()

usage() {
    cat <<'EOF'
Usage: bridge-abort-terminal-to-fresh-v21.sh (--execute|--resume|--validate-inputs-only) \
  --old-operation-id LOWER32 \
  --abort-terminal PATH --abort-terminal-sha256 LOWER64 \
  --abort-authorization PATH --abort-authorization-sha256 LOWER64 \
  --abort-binary-receipt PATH --abort-binary-receipt-sha256 LOWER64 \
  --linux-v13-started-receipt PATH --linux-v13-started-receipt-sha256 LOWER64 \
  --bubblewrap-sha256 LOWER64 \
  --installed-viewflow-sha256 LOWER64 --installed-viewflow-unit-sha256 LOWER64 \
  --deployment-marker-candidate PATH --deployment-marker-sha256 LOWER64 \
  --prepare-script PATH --prepare-script-sha256 LOWER64 \
  --collector-script PATH --collector-script-sha256 LOWER64 \
  --bridge-root /home/wilf/.local/state/viewflow/bridges/LOWER32

--execute creates a fresh operation/coordinator identity exactly once.
--resume consumes that immutable plan and continues forward.  If an input route
is active, the command prints RETURN_REQUIRED and waits for the normal sidecar-3
ReleaseAll Applied + lease-revoke cleanup receipt before stopping anything.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; return 1; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
canonical_json_sha() { jq -cS . "$1" | sha256sum | awk '{print tolower($1)}'; }
need() { [[ -n ${2-} ]] || die "$1 requires a value"; }
lower64() { [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "$1 must be lowercase SHA-256"; }

while (($#)); do
    case $1 in
        --execute|--resume|--validate-inputs-only)
            [[ -z $mode ]] || die 'select exactly one mode'; mode=${1#--}; shift ;;
        --old-operation-id) need "$1" "${2-}"; old_operation=$2; shift 2 ;;
        --abort-terminal) need "$1" "${2-}"; terminal=$2; shift 2 ;;
        --abort-terminal-sha256) need "$1" "${2-}"; terminal_sha=$2; shift 2 ;;
        --abort-authorization) need "$1" "${2-}"; authorization=$2; shift 2 ;;
        --abort-authorization-sha256) need "$1" "${2-}"; authorization_sha=$2; shift 2 ;;
        --abort-binary-receipt) need "$1" "${2-}"; abort_receipt=$2; shift 2 ;;
        --abort-binary-receipt-sha256) need "$1" "${2-}"; abort_receipt_sha=$2; shift 2 ;;
        --linux-v13-started-receipt) need "$1" "${2-}"; linux_started=$2; shift 2 ;;
        --linux-v13-started-receipt-sha256) need "$1" "${2-}"; linux_started_sha=$2; shift 2 ;;
        --bubblewrap-sha256) need "$1" "${2-}"; bwrap_sha=$2; shift 2 ;;
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

cleanup() {
    local status=$? path
    for path in "${temporary_files[@]}"; do [[ -z $path ]] || rm -f -- "$path"; done
    exit "$status"
}
trap cleanup EXIT

strict_json() {
    python3 - "$1" <<'PY'
import json, pathlib, sys
def pairs(items):
    out={}
    for key,value in items:
        if key in out: raise ValueError("duplicate key")
        out[key]=value
    return out
p=pathlib.Path(sys.argv[1]); text=p.read_text(encoding="utf-8")
d=json.JSONDecoder(object_pairs_hook=pairs); start=len(text)-len(text.lstrip())
try: _,end=d.raw_decode(text,start)
except Exception as error: raise SystemExit(str(error))
if text[end:].strip(): raise SystemExit("trailing JSON content")
PY
}

private_input() {
    local label=$1 path=$2 expected=$3
    [[ $path == /* && -f $path && ! -L $path && $(stat -c '%u:%a:%h' -- "$path") == 1000:600:1 ]] ||
        die "$label must be uid-1000 mode-0600 single-link regular bytes"
    [[ $(sha256 "$path") == "$expected" ]] || die "$label SHA-256 differs"
}

safe_source() {
    local label=$1 path=$2 expected=$3
    [[ $path == /* && -f $path && ! -L $path && $(stat -c '%u:%h' -- "$path") == 1000:1 ]] ||
        die "$label must be an owner-1000 single-link regular file"
    [[ $(sha256 "$path") == "$expected" ]] || die "$label SHA-256 differs"
}

safe_owner_dir() {
    local label=$1 path=$2 mode
    [[ -d $path && ! -L $path && $(stat -c '%u:%h' -- "$path") == 1000:1 ]] ||
        die "$label must be an owner-1000 single-link real directory"
    mode=$(stat -c '%a' -- "$path"); (( (8#$mode & 8#077) == 0 )) || die "$label must be owner-only"
}

publish_new() {
    local source=$1 destination=$2 parent
    parent=$(dirname -- "$destination"); safe_owner_dir 'output parent' "$parent"
    [[ ! -e $destination && ! -L $destination ]] || die "create-once output exists: $destination"
    chmod 0600 "$source"; sync -f "$source"
    ln -- "$source" "$destination" || die "create-once publication raced: $destination"
    rm -f -- "$source"; sync -f "$destination"; sync -f "$parent"
    [[ $(stat -c '%u:%a:%h' -- "$destination") == 1000:600:1 ]] || die 'published output metadata differs'
}

validate_terminal() {
    strict_json "$terminal"; strict_json "$authorization"
    jq -e --arg op "$old_operation" --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" \
        --arg linux "$linux_started_sha" '
      keys == ["abort_authorization_sha256","authenticated_v13_peer_receipt_sha256","deployment_abort_receipt_sha256","deployment_marker_sha256","initial_force_release_executed","installer_exit_receipt_sha256","linux_deskflow_control_group","linux_deskflow_core_executable_sha256","linux_deskflow_core_pid","linux_deskflow_core_start_ticks","linux_deskflow_exec_start_sha256","linux_deskflow_executable_sha256","linux_deskflow_expected_exec_start_sha256","linux_deskflow_invocation_id","linux_deskflow_main_pid","linux_deskflow_main_start_ticks","linux_deskflow_runtime_pid","linux_deskflow_runtime_start_ticks","linux_deskflow_unit","linux_deskflow_unit_state","linux_v13_started_receipt_sha256","linux_viewflow_unit_state","normal_deployment_release","old_coordinator_terminal_state_sha256","operation_id","pre_mutation_retry_receipt_sha256","protocol_2_1","protocol_version","rollback_performed","schema_version","state","windows_live_proof_sha256","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
      .schema_version == 2 and .state == "viewflow-failed-pre-mutation-installer-baseline-restored-abort-terminal" and
      .operation_id == $op and .protocol_version == "1.3" and .protocol_2_1 == false and
      .normal_deployment_release == false and .initial_force_release_executed == false and
      .rollback_performed == false and .windows_rollback_receipt_sha256 == null and
      .abort_authorization_sha256 == $auth and .deployment_abort_receipt_sha256 == $abort and
      .linux_v13_started_receipt_sha256 == $linux and
      .linux_viewflow_unit_state == "active" and .linux_deskflow_unit_state == "active" and
      (.deployment_marker_sha256|test("^[0-9a-f]{64}$")) and
      (.linux_deskflow_unit|test("^deskflow-v13-recovery-[0-9a-f]{32}\\.service$")) and
      (.linux_deskflow_invocation_id|test("^[0-9a-f]{32}$")) and
      (.linux_deskflow_control_group as $cg | .linux_deskflow_unit as $u | $cg|endswith("/" + $u)) and
      .linux_deskflow_exec_start_sha256 == .linux_deskflow_expected_exec_start_sha256 and
      all([.linux_deskflow_main_pid,.linux_deskflow_main_start_ticks,.linux_deskflow_runtime_pid,
           .linux_deskflow_runtime_start_ticks,.linux_deskflow_core_pid,.linux_deskflow_core_start_ticks][];
          type=="number" and .==floor and .>0)
    ' "$terminal" >/dev/null || die 'schema-2 abort terminal is invalid'
    jq -e --arg op "$old_operation" --arg marker "$(jq -er '.deployment_marker_sha256' "$terminal")" \
        --arg path "$authorization" --arg linux "$installed_viewflow_sha" \
        --arg deskflow "$(jq -er '.linux_deskflow_executable_sha256' "$terminal")" \
        --arg core "$(jq -er '.linux_deskflow_core_executable_sha256' "$terminal")" '
      keys == ["authenticated_v13_peer_receipt_sha256","authorization_receipt_path","coordinator_instance_id","deployment_publish_receipt_sha256","initial_force_release_executed","installer_exit_receipt_sha256","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_generation","marker_handoff_receipt_sha256","marker_sha256","old_linux_deskflow_core_sha256","old_linux_deskflow_sha256","old_linux_viewflowd_sha256","old_windows_rollback_sha256","old_windows_task_xml_sha256","old_windows_viewflowd_sha256","old_windows_wrapper_sha256","operation_id","pre_mutation_retry_receipt_sha256","protocol_2_1","rollback_performed","schema_version","state","windows_live_proof_sha256","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
      .schema_version==2 and .state=="viewflow-deployment-quarantine-failed-pre-mutation-installer-baseline-restored-abort-authorized" and
      .operation_id==$op and (.coordinator_instance_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      .marker_generation=="1" and .marker_sha256==$marker and
      .authorization_receipt_path==$path and .old_linux_viewflowd_sha256==$linux and
      .old_linux_deskflow_sha256==$deskflow and .old_linux_deskflow_core_sha256==$core and
      .initial_force_release_executed==false and .rollback_performed==false and
      .windows_rollback_receipt_sha256==null and .protocol_2_1==false
    ' "$authorization" >/dev/null || die 'schema-2 abort authorization is invalid'
    strict_json "$linux_started"
    jq -e --arg op "$old_operation" --arg marker "$(jq -er '.deployment_marker_sha256' "$terminal")" \
        --arg sha "$installed_viewflow_sha" '
      keys == ["control_group","deployment_marker_sha256","exec_start_sha256","expected_exec_start_sha256","fd_gate_payload_sha256","invocation_id","kill_mode","main_pid","operation_id","protocol_version","schema_version","start_ticks","state","transient","unit","unit_active_state","viewflowd_sha256"] and
      .schema_version==1 and .state=="viewflow-linux-v1.3-started-under-deployment-quarantine" and
      .operation_id==$op and .protocol_version=="1.3" and .deployment_marker_sha256==$marker and
      .viewflowd_sha256==$sha and .transient==true and .kill_mode=="control-group" and
      .unit_active_state=="active" and .exec_start_sha256==.expected_exec_start_sha256
    ' "$linux_started" >/dev/null || die 'Linux transient start receipt is invalid'
}

validate_abort_binary() {
    local marker_sha auth_sha expected_path
    marker_sha=$(jq -er '.deployment_marker_sha256' "$terminal"); auth_sha=$authorization_sha
    expected_path="/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.${marker_sha}.${auth_sha}.v1"
    [[ $abort_receipt == "$expected_path" ]] || die 'VFDQA receipt path is not the content-addressed fixed path'
    [[ -f $abort_receipt && ! -L $abort_receipt && $(stat -c '%u:%a:%h:%s' -- "$abort_receipt") == 1000:600:1:384 ]] ||
        die 'VFDQA receipt metadata differs'
    python3 - "$abort_receipt" "$abort_receipt_sha" "$marker_sha" "$auth_sha" "$old_operation" \
      "$(jq -er '.coordinator_instance_id' "$authorization")" <<'PY'
import hashlib, pathlib, sys, uuid
p=pathlib.Path(sys.argv[1]); b=p.read_bytes()
if hashlib.sha256(b).hexdigest()!=sys.argv[2]: raise SystemExit("outer VFDQA hash differs")
if len(b)!=384 or b[:8]!=b"VFDQA001" or b[8:13]!=bytes((1,1,1,3,1)) or any(b[13:16]):
    raise SystemExit("VFDQA header differs")
marker=b[16:272]
if marker[:13]!=b"VFDQT001\x01\x01\x02\x01\x01" or hashlib.sha256(marker).hexdigest()!=sys.argv[3]:
    raise SystemExit("embedded marker differs")
op=sys.argv[5].encode()
if marker[13]!=len(op) or any(marker[14:16]) or marker[16:16+len(op)]!=op or any(marker[16+len(op):144]):
    raise SystemExit("embedded marker operation differs")
if marker[144:160]!=uuid.UUID("00000000-0000-0000-0000-000000000101").bytes:
    raise SystemExit("embedded marker source differs")
if marker[160:176]!=uuid.UUID("00000000-0000-0000-0000-000000000002").bytes:
    raise SystemExit("embedded marker target differs")
if marker[176:192]!=uuid.UUID(sys.argv[6]).bytes or int.from_bytes(marker[192:200],"little")==0:
    raise SystemExit("embedded marker coordinator/time differs")
if int.from_bytes(marker[200:208],"little")!=1 or any(marker[208:]):
    raise SystemExit("embedded marker generation/reserved bytes differ")
if b[272:304].hex()!=sys.argv[3] or b[304:336].hex()!=sys.argv[4] or int.from_bytes(b[336:344],"little")==0:
    raise SystemExit("VFDQA binding differs")
if any(b[344:352]) or hashlib.sha256(b[:352]).digest()!=b[352:384]:
    raise SystemExit("VFDQA checksum differs")
PY
    [[ ! -e $MARKER_CLAIM && ! -L $MARKER_CLAIM && ! -e $RELEASE_CLAIM && ! -L $RELEASE_CLAIM ]] ||
        die 'an old deployment claim reappeared'
    if [[ -e $MARKER || -L $MARKER ]]; then
        [[ -f $plan && ! -L $plan && $(stat -c '%u:%a:%h' -- "$plan") == 1000:600:1 ]] ||
            die 'an active marker exists without an immutable fresh bridge plan'
        new_operation=$(jq -er '.new_operation_id' "$plan"); new_coordinator=$(jq -er '.new_coordinator_instance_id' "$plan")
        [[ $new_operation != "$old_operation" ]] || die 'fresh plan reused the aborted operation'
        validate_fresh_marker_bytes
    fi
}

preflight_inputs() {
    local item
    [[ -n $mode ]] || die 'a mode is required'
    [[ $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] || die 'run as uid 1000 with HOME=/home/wilf'
    for item in awk busctl cmp date dd dirname grep jq journalctl ln mkdir mktemp mv python3 readlink rm sha256sum sleep ss stat sync systemctl tr uuidgen; do
        command -v "$item" >/dev/null || die "required command is unavailable: $item"
    done
    [[ $old_operation =~ ^[0-9a-f]{32}$ ]] || die 'old operation ID must be lowercase 32hex'
    lower64 terminal "$terminal_sha"; lower64 authorization "$authorization_sha"; lower64 abort "$abort_receipt_sha"
    lower64 linux-started "$linux_started_sha"; lower64 bubblewrap "$bwrap_sha"
    lower64 installed-viewflow "$installed_viewflow_sha"; lower64 installed-unit "$installed_unit_sha"
    lower64 marker-candidate "$marker_candidate_sha"; lower64 prepare-script "$prepare_script_sha"
    lower64 collector-script "$collector_script_sha"
    private_input 'abort terminal' "$terminal" "$terminal_sha"
    private_input 'abort authorization' "$authorization" "$authorization_sha"
    private_input 'Linux started receipt' "$linux_started" "$linux_started_sha"
    safe_source 'marker candidate' "$marker_candidate" "$marker_candidate_sha"
    safe_source 'prepare script' "$prepare_script" "$prepare_script_sha"
    safe_source 'collector script' "$collector_script" "$collector_script_sha"
    [[ $bridge_root == /home/wilf/.local/state/viewflow/bridges/$old_operation ]] ||
        die 'bridge root must be the fixed old-operation content path'
    validate_terminal; validate_abort_binary
}

process_ticks() { sed -E 's/^[0-9]+ \(.*\) //' "/proc/$1/stat" | awk '{print $20}'; }
process_cgroup() { awk -F: '$1=="0" {print $3}' "/proc/$1/cgroup"; }
unit_prop() { systemctl --user show --property "$2" --value "$1"; }

observed_exec_start_sha() {
    local response object property canonical
    response=$(busctl --user --json=short call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
        org.freedesktop.systemd1.Manager GetUnit s "$1")
    object=$(jq -er 'select(.type=="o" and (.data|length)==1)|.data[0]' <<<"$response")
    property=$(busctl --user --json=short get-property org.freedesktop.systemd1 "$object" \
        org.freedesktop.systemd1.Service ExecStart)
    canonical=$(jq -ceS 'select(.type=="a(sasbttttuii)" and (.data|length)==1)|.data[0] as $v|
      select(($v|length)==10)|{argv:$v[1],ignore_errors:$v[2],path:$v[0]}' <<<"$property")
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

exact_pids() {
    local expected=$1 proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
    return 0
}

validate_live_transients() {
    local vf_unit df_unit vf_pid vf_ticks vf_inv vf_cgroup df_main df_gui df_core df_inv df_cgroup
    vf_unit=$(jq -er '.unit' "$linux_started"); vf_pid=$(jq -er '.main_pid' "$linux_started")
    vf_ticks=$(jq -er '.start_ticks' "$linux_started"); vf_inv=$(jq -er '.invocation_id' "$linux_started")
    vf_cgroup=$(jq -er '.control_group' "$linux_started")
    df_unit=$(jq -er '.linux_deskflow_unit' "$terminal"); df_main=$(jq -er '.linux_deskflow_main_pid' "$terminal")
    df_gui=$(jq -er '.linux_deskflow_runtime_pid' "$terminal"); df_core=$(jq -er '.linux_deskflow_core_pid' "$terminal")
    df_inv=$(jq -er '.linux_deskflow_invocation_id' "$terminal"); df_cgroup=$(jq -er '.linux_deskflow_control_group' "$terminal")
    [[ $(unit_prop "$vf_unit" ActiveState) == active && $(unit_prop "$vf_unit" Transient) == yes &&
       $(unit_prop "$vf_unit" KillMode) == control-group && $(unit_prop "$vf_unit" MainPID) == "$vf_pid" &&
       $(unit_prop "$vf_unit" InvocationID) == "$vf_inv" && $(unit_prop "$vf_unit" ControlGroup) == "$vf_cgroup" &&
       $(process_ticks "$vf_pid") == "$vf_ticks" && $(process_cgroup "$vf_pid") == "$vf_cgroup" &&
       $(sha256 "/proc/$vf_pid/exe") == "$installed_viewflow_sha" &&
       $(observed_exec_start_sha "$vf_unit") == "$(jq -er '.exec_start_sha256' "$linux_started")" ]] ||
        die 'live Viewflow transient tuple differs'
    [[ $(unit_prop "$df_unit" ActiveState) == active && $(unit_prop "$df_unit" Transient) == yes &&
       $(unit_prop "$df_unit" KillMode) == control-group && $(unit_prop "$df_unit" MainPID) == "$df_main" &&
       $(unit_prop "$df_unit" InvocationID) == "$df_inv" && $(unit_prop "$df_unit" ControlGroup) == "$df_cgroup" &&
       $(process_ticks "$df_main") == "$(jq -er '.linux_deskflow_main_start_ticks' "$terminal")" &&
       $(process_ticks "$df_gui") == "$(jq -er '.linux_deskflow_runtime_start_ticks' "$terminal")" &&
       $(process_ticks "$df_core") == "$(jq -er '.linux_deskflow_core_start_ticks' "$terminal")" &&
       $(process_cgroup "$df_main") == "$df_cgroup" && $(process_cgroup "$df_gui") == "$df_cgroup" &&
       $(process_cgroup "$df_core") == "$df_cgroup" && $(sha256 "/proc/$df_main/exe") == "$bwrap_sha" &&
       $(sha256 "/proc/$df_gui/exe") == "$(jq -er '.linux_deskflow_executable_sha256' "$terminal")" &&
       $(sha256 "/proc/$df_core/exe") == "$(jq -er '.linux_deskflow_core_executable_sha256' "$terminal")" &&
       $(observed_exec_start_sha "$df_unit") == "$(jq -er '.linux_deskflow_exec_start_sha256' "$terminal")" ]] ||
        die 'live Deskflow transient tuple differs'
}

make_plan() {
    local temp new_uuid old_coordinator
    if [[ -e $plan || -L $plan ]]; then validate_plan; return; fi
    [[ $mode == execute ]] || die 'resume requires the existing immutable plan'
    new_uuid=$(uuidgen | tr 'A-F' 'a-f'); new_operation=${new_uuid//-/}
    new_coordinator=$(uuidgen | tr 'A-F' 'a-f')
    old_coordinator=$(jq -er '.coordinator_instance_id' "$authorization")
    [[ $new_operation =~ ^[0-9a-f]{32}$ && $new_operation != "$old_operation" &&
       $new_coordinator =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
       $new_coordinator != "$old_coordinator" ]] ||
        die 'failed to generate fresh identities'
    fresh_root="$DEPLOYMENTS/$new_operation"
    [[ ! -e $fresh_root && ! -L $fresh_root ]] || die 'generated operation root already exists'
    temp=$(mktemp --tmpdir="$bridge_root" '.bridge-plan.XXXXXX'); temporary_files+=("$temp")
    jq -cn --arg old "$old_operation" --arg new "$new_operation" --arg coordinator "$new_coordinator" \
      --arg terminal "$terminal" --arg terminal_sha "$terminal_sha" --arg auth "$authorization" --arg auth_sha "$authorization_sha" \
      --arg abort "$abort_receipt" --arg abort_sha "$abort_receipt_sha" --arg linux "$linux_started" --arg linux_sha "$linux_started_sha" \
      --arg bwrap "$bwrap_sha" --arg viewflow "$installed_viewflow_sha" --arg unit "$installed_unit_sha" \
      --arg marker "$marker_candidate" --arg marker_sha "$marker_candidate_sha" \
      --arg prepare "$prepare_script" --arg prepare_sha "$prepare_script_sha" --arg collector "$collector_script" --arg collector_sha "$collector_script_sha" \
      --arg fresh "$fresh_root" '
      {schema_version:1,state:"viewflow-abort-terminal-to-fresh-v21-plan",old_operation_id:$old,
       new_operation_id:$new,new_coordinator_instance_id:$coordinator,fresh_operation_root:$fresh,
       inputs:{abort_terminal:{path:$terminal,sha256:$terminal_sha},abort_authorization:{path:$auth,sha256:$auth_sha},
         abort_binary_receipt:{path:$abort,sha256:$abort_sha},linux_v13_started:{path:$linux,sha256:$linux_sha},
         bubblewrap_sha256:$bwrap,installed_viewflow_sha256:$viewflow,installed_viewflow_unit_sha256:$unit,
         marker_candidate:{path:$marker,sha256:$marker_sha},prepare_script:{path:$prepare,sha256:$prepare_sha},
         collector_script:{path:$collector,sha256:$collector_sha}}}
    ' >"$temp"
    publish_new "$temp" "$plan"; temporary_files=()
    mkdir -- "$fresh_root"; chmod 0700 "$fresh_root"; sync -f "$DEPLOYMENTS"
    validate_plan
}

validate_plan() {
    private_input 'bridge plan' "$plan" "$(sha256 "$plan")"; strict_json "$plan"
    jq -e --arg old "$old_operation" --arg old_coordinator "$(jq -er '.coordinator_instance_id' "$authorization")" \
      --arg terminal_path "$terminal" --arg terminal "$terminal_sha" \
      --arg auth_path "$authorization" --arg auth "$authorization_sha" --arg abort_path "$abort_receipt" \
      --arg abort "$abort_receipt_sha" --arg linux_path "$linux_started" --arg linux "$linux_started_sha" \
      --arg bwrap "$bwrap_sha" --arg vf "$installed_viewflow_sha" --arg unit "$installed_unit_sha" \
      --arg marker_path "$marker_candidate" --arg marker "$marker_candidate_sha" \
      --arg prepare_path "$prepare_script" --arg prepare "$prepare_script_sha" \
      --arg collector_path "$collector_script" --arg collector "$collector_script_sha" '
      keys==["fresh_operation_root","inputs","new_coordinator_instance_id","new_operation_id","old_operation_id","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-abort-terminal-to-fresh-v21-plan" and .old_operation_id==$old and
      (.new_operation_id|test("^[0-9a-f]{32}$")) and .new_operation_id!=$old and
      (.new_coordinator_instance_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      .new_coordinator_instance_id!=$old_coordinator and
      .fresh_operation_root==("/home/wilf/.local/state/viewflow/deployments/"+.new_operation_id) and
      .inputs=={abort_terminal:{path:$terminal_path,sha256:$terminal},abort_authorization:{path:$auth_path,sha256:$auth},
        abort_binary_receipt:{path:$abort_path,sha256:$abort},linux_v13_started:{path:$linux_path,sha256:$linux},
        bubblewrap_sha256:$bwrap,installed_viewflow_sha256:$vf,installed_viewflow_unit_sha256:$unit,
        marker_candidate:{path:$marker_path,sha256:$marker},prepare_script:{path:$prepare_path,sha256:$prepare},
        collector_script:{path:$collector_path,sha256:$collector}}
    ' "$plan" >/dev/null || die 'bridge plan binding is invalid'
    new_operation=$(jq -er '.new_operation_id' "$plan"); new_coordinator=$(jq -er '.new_coordinator_instance_id' "$plan")
    fresh_root=$(jq -er '.fresh_operation_root' "$plan")
    if [[ ! -e $fresh_root && ! -L $fresh_root ]]; then
        mkdir -- "$fresh_root"; chmod 0700 "$fresh_root"; sync -f "$DEPLOYMENTS"
    fi
    safe_owner_dir 'fresh operation root' "$fresh_root"
    publish_receipt=$fresh_root/deployment-publish.json; handoff_receipt=$fresh_root/marker-handoff.json
    frozen_evidence=$fresh_root/linux-frozen.json; final_receipt=$fresh_root/abort-terminal-to-fresh-v21.json
}

validate_status() {
    jq -e --argjson pid "$(jq -er '.linux_deskflow_core_pid' "$terminal")" \
      --argjson ticks "$(jq -er '.linux_deskflow_core_start_ticks' "$terminal")" \
      --arg boot "$(tr -d -- '-' </proc/sys/kernel/random/boot_id)" '
      keys==["core_boot_id","core_pid","core_start_ticks","protocol_version","receipt_available","runtime_marker_path","runtime_marker_present","schema_version","sidecar_configured","sidecar_protocol_version","state"] and
      .schema_version==1 and .state=="deskflow-live-acceptance-status" and .protocol_version=="2.1" and
      .sidecar_protocol_version==3 and .sidecar_configured==true and .runtime_marker_path=="/home/wilf/.local/state/viewflow/deskflow-quarantine.v2" and
      .core_pid==$pid and .core_start_ticks==$ticks and .core_boot_id==$boot and
      (.runtime_marker_present|type=="boolean") and .receipt_available==false
    ' "$1" >/dev/null || die 'live acceptance status differs'
}

validate_cleanup_receipt() {
    local cleanup_id epoch
    jq -e --arg op "$new_operation" --arg op_sha "$(printf '%s' "$new_operation" | sha256sum | awk '{print $1}')" \
      --arg marker "$(jq -er '.deployment_marker_sha256' "$terminal")" \
      --arg core "$(jq -er '.linux_deskflow_core_executable_sha256' "$terminal")" \
      --arg core_boot "$(tr -d -- '-' </proc/sys/kernel/random/boot_id)" \
      --arg daemon_boot "$(tr -d -- '-' </proc/sys/kernel/random/boot_id)" \
      --argjson core_pid "$(jq -er '.linux_deskflow_core_pid' "$terminal")" \
      --argjson core_ticks "$(jq -er '.linux_deskflow_core_start_ticks' "$terminal")" \
      --argjson daemon_pid "$(jq -er '.main_pid' "$linux_started")" --argjson daemon_ticks "$(jq -er '.start_ticks' "$linux_started")" '
      keys==["acknowledged","active_lease_generation","bound_peer_address","bound_peer_epoch","bound_peer_family","bound_peer_port","bound_peer_scope_id","cleanup_complete_body_size","cleanup_complete_mode","cleanup_operation_id","cleanup_sha256","completed_at_unix_ms","coordinator_operation_id","coordinator_operation_id_sha256","core_boot_id","core_executable_sha256","core_pid","core_start_ticks","daemon_boot_id","daemon_pid","daemon_start_ticks","deployment_marker_bound","deployment_marker_sha256","marker_last_sequence","owner_device_id","protocol_version","route_generation","runtime_marker_magic","runtime_marker_path","runtime_marker_released","runtime_marker_sha256","runtime_marker_size","schema_version","sidecar_protocol_version","source_display_id","state","target_device_id","tombstone_magic","tombstone_sha256","tombstone_size"] and
      .schema_version==1 and .state=="deskflow-runtime-cleanup-evidence" and .protocol_version=="2.1" and
      .sidecar_protocol_version==3 and .cleanup_complete_mode=="normal" and .cleanup_complete_body_size==277 and
      .coordinator_operation_id==$op and .coordinator_operation_id_sha256==$op_sha and
      .source_display_id=="00000000000000000000000000000101" and
      .target_device_id=="00000000000000000000000000000002" and .owner_device_id=="00000000000000000000000000000002" and
      .deployment_marker_bound==true and .deployment_marker_sha256==$marker and .acknowledged==true and
      .runtime_marker_magic=="VFQST002" and .runtime_marker_released==true and .runtime_marker_size==152 and
      .runtime_marker_path=="/home/wilf/.local/state/viewflow/deskflow-quarantine.v2" and
      .tombstone_magic=="VFACK001" and .tombstone_size==72 and
      (.cleanup_operation_id|test("^[0-9a-f]{32}$")) and .cleanup_operation_id!="00000000000000000000000000000000" and
      (.cleanup_sha256|test("^[0-9a-f]{64}$")) and (.runtime_marker_sha256|test("^[0-9a-f]{64}$")) and
      (.tombstone_sha256|test("^[0-9a-f]{64}$")) and .core_executable_sha256==$core and
      .core_pid==$core_pid and .core_start_ticks==$core_ticks and .core_boot_id==$core_boot and
      .daemon_pid==$daemon_pid and .daemon_start_ticks==$daemon_ticks and .daemon_boot_id==$daemon_boot and
      (.route_generation|type=="number" and .>0 and .==floor) and
      (.active_lease_generation|type=="number" and .>0 and .<9007199254740991 and .==floor) and
      (.marker_last_sequence|type=="number" and .>=0 and .<9007199254740991 and .==floor) and
      (.bound_peer_epoch|type=="number" and .>0 and .<=9007199254740991 and .==floor) and
      .bound_peer_family==4 and (.bound_peer_address|test("^[0-9a-f]{32}$")) and
      (.bound_peer_port|type=="number" and .>=1 and .<=65535 and .==floor) and .bound_peer_scope_id==0 and
      (.completed_at_unix_ms|type=="number" and .>0 and .==floor)
    ' "$1" >/dev/null || { die 'ReleaseAll Applied cleanup receipt differs'; return 1; }
    cleanup_id=$(jq -er '.cleanup_operation_id' "$1"); epoch=$(jq -er '.bound_peer_epoch' "$1")
    [[ ${cleanup_id:0:16} == "$(printf '%016x' "$epoch")" && ${cleanup_id:16:16} != 0000000000000000 ]] || {
        die 'cleanup revoke operation does not bind the exact peer epoch'; return 1;
    }
}

ensure_cleanup_proof() {
    local status arm temp deadline nested
    if [[ -e $cleanup_proof || -L $cleanup_proof ]]; then
        private_input 'retirement cleanup proof' "$cleanup_proof" "$(sha256 "$cleanup_proof")"; strict_json "$cleanup_proof"
        jq -e --arg op "$new_operation" '
          .schema_version==1 and .operation_id==$op and
          ((keys==["acceptance_status","acceptance_status_sha256","operation_id","pressed_state","schema_version","state"] and
            .state=="viewflow-transient-retirement-no-active-route" and .pressed_state=="no-active-route" and
            (.acceptance_status_sha256|test("^[0-9a-f]{64}$"))) or
           (keys==["cleanup_receipt","cleanup_receipt_sha256","operation_id","pressed_state","schema_version","state"] and
            .state=="viewflow-transient-retirement-release-all-applied" and .pressed_state=="released" and
            (.cleanup_receipt_sha256|test("^[0-9a-f]{64}$"))))' "$cleanup_proof" >/dev/null ||
            die 'existing retirement cleanup proof differs'
        nested=$(mktemp --tmpdir="$bridge_root" '.existing-cleanup-nested.XXXXXX'); temporary_files+=("$nested")
        if jq -e '.state=="viewflow-transient-retirement-no-active-route"' "$cleanup_proof" >/dev/null; then
            jq -e '.acceptance_status' "$cleanup_proof" >"$nested"; validate_status "$nested"
            [[ $(jq -cS '.acceptance_status' "$cleanup_proof" | sha256sum | awk '{print $1}') == "$(jq -er '.acceptance_status_sha256' "$cleanup_proof")" ]] ||
                die 'embedded acceptance status hash differs'
        else
            jq -e '.cleanup_receipt' "$cleanup_proof" >"$nested"; validate_cleanup_receipt "$nested"
            [[ $(jq -cS '.cleanup_receipt' "$cleanup_proof" | sha256sum | awk '{print $1}') == "$(jq -er '.cleanup_receipt_sha256' "$cleanup_proof")" ]] ||
                die 'embedded cleanup receipt hash differs'
        fi
        [[ ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]] || die 'runtime marker reappeared after cleanup proof'
        return
    fi
    validate_live_transients
    status=$(mktemp --tmpdir="$bridge_root" '.acceptance-status.XXXXXX'); temporary_files+=("$status")
    env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$ACCEPTANCE_SOCKET" "/proc/$(jq -er '.linux_deskflow_core_pid' "$terminal")/exe" \
      --viewflow-acceptance-query status >"$status"
    strict_json "$status"; validate_status "$status"
    temp=$(mktemp --tmpdir="$bridge_root" '.cleanup-proof.XXXXXX'); temporary_files+=("$temp")
    if jq -e '.runtime_marker_present==false' "$status" >/dev/null; then
        jq -cn --arg op "$new_operation" --arg status_sha "$(canonical_json_sha "$status")" --slurpfile status "$status" \
          '{schema_version:1,state:"viewflow-transient-retirement-no-active-route",operation_id:$op,
            pressed_state:"no-active-route",acceptance_status_sha256:$status_sha,acceptance_status:$status[0]}' >"$temp"
    else
        arm=$(mktemp --tmpdir="$bridge_root" '.acceptance-arm.XXXXXX'); temporary_files+=("$arm")
        env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$ACCEPTANCE_SOCKET" "/proc/$(jq -er '.linux_deskflow_core_pid' "$terminal")/exe" --viewflow-acceptance-query arm \
          --coordinator-operation-id "$new_operation" --source-display-id "$SOURCE_ID" --target-device-id "$TARGET_ID" \
          --deployment-marker-sha256 "$(jq -er '.deployment_marker_sha256' "$terminal")" >"$arm"
        jq -e 'keys==["armed","schema_version","state"] and .schema_version==1 and .state=="viewflow-acceptance-armed" and .armed==true' "$arm" >/dev/null ||
            die 'failed to arm exact runtime cleanup'
        printf 'RETURN_REQUIRED: return the pointer local; waiting for ReleaseAll Applied and lease revoke\n' >&2
        deadline=$((SECONDS+CLEANUP_TIMEOUT))
        while ((SECONDS<deadline)); do
            if env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$ACCEPTANCE_SOCKET" "/proc/$(jq -er '.linux_deskflow_core_pid' "$terminal")/exe" --viewflow-acceptance-query cleanup \
              --coordinator-operation-id "$new_operation" --source-display-id "$SOURCE_ID" --target-device-id "$TARGET_ID" \
              --deployment-marker-sha256 "$(jq -er '.deployment_marker_sha256' "$terminal")" >"$temp" 2>/dev/null; then break; fi
            sleep 0.1
        done
        validate_cleanup_receipt "$temp"
        local raw=$temp wrapper
        wrapper=$(mktemp --tmpdir="$bridge_root" '.cleanup-wrapper.XXXXXX'); temporary_files+=("$wrapper")
        jq -cn --arg op "$new_operation" --arg raw_sha "$(canonical_json_sha "$raw")" --slurpfile receipt "$raw" \
          '{schema_version:1,state:"viewflow-transient-retirement-release-all-applied",operation_id:$op,
            pressed_state:"released",cleanup_receipt_sha256:$raw_sha,cleanup_receipt:$receipt[0]}' >"$wrapper"
        temp=$wrapper
    fi
    publish_new "$temp" "$cleanup_proof"
    temporary_files=()
    [[ ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]] || die 'runtime marker remains after cleanup proof'
}

transients_zero() {
    local vf_unit df_unit
    vf_unit=$(jq -er '.unit' "$linux_started"); df_unit=$(jq -er '.linux_deskflow_unit' "$terminal")
    [[ $(unit_prop "$vf_unit" MainPID 2>/dev/null || true) =~ ^(0|)$ &&
       $(unit_prop "$df_unit" MainPID 2>/dev/null || true) =~ ^(0|)$ &&
       -z $(exact_pids "$VIEWFLOW") && -z $(exact_pids "$DESKFLOW_RUNTIME") && -z $(exact_pids "$CORE_RUNTIME") &&
       -z $(ss -H -lun "sport = :44119") && -z $(ss -H -ltn "sport = :24800") && ! -e $SIDECAR_SOCKET &&
       -z $(unit_prop "$vf_unit" ControlGroup 2>/dev/null || true) && -z $(unit_prop "$df_unit" ControlGroup 2>/dev/null || true) ]]
}

retire_transients() {
    local vf_unit df_unit deadline
    transients_zero && return
    validate_live_transients
    df_unit=$(jq -er '.linux_deskflow_unit' "$terminal"); vf_unit=$(jq -er '.unit' "$linux_started")
    systemctl --user stop "$df_unit"; systemctl --user stop "$vf_unit"
    deadline=$((SECONDS+STOP_TIMEOUT))
    while ((SECONDS<deadline)); do transients_zero && return; sleep 0.1; done
    die 'transient cgroups/processes/listeners did not reach zero'
}

snapshot_config_intent() {
    local temp path
    if [[ -e $config_intent || -L $config_intent ]]; then
        private_input 'config relocation intent' "$config_intent" "$(sha256 "$config_intent")"; strict_json "$config_intent"
        jq -e '
          keys==["entries","schema_version","state"] and .schema_version==1 and
          .state=="viewflow-runtime-config-relocation-intent" and (.entries|length)==5 and
          [.entries[].path]==["/run/user/1000/systemd/user.control/deskflow.service",
            "/run/user/1000/systemd/user.control/viewflow-peer.service","/run/user/1000/systemd/user/deskflow.service",
            "/run/user/1000/systemd/user/viewflow-peer.service","/run/user/1000/systemd/user/deskflow.service.d/zz-direct-deskflow.conf"] and
          [.entries[].backup_leaf]==["0-deskflow.service","1-viewflow-peer.service","2-deskflow.service",
            "3-viewflow-peer.service","4-zz-direct-deskflow.conf"] and
          [.entries[].kind]==["symlink","symlink","symlink","symlink","regular"] and
          all(.entries[]; keys==["backup_leaf","dev","ino","kind","mode","nlink","path","sha256","uid"] and
            .uid==1000 and .nlink==1 and (.sha256|test("^[0-9a-f]{64}$")))
        ' "$config_intent" >/dev/null || die 'config relocation intent schema differs'
        return
    fi
    temp=$(mktemp --tmpdir="$bridge_root" '.config-intent.XXXXXX'); temporary_files+=("$temp")
    python3 - "$temp" "${CONFIG_PATHS[@]}" <<'PY'
import hashlib,json,os,stat,sys
out=[]
for path in sys.argv[2:]:
    parent=os.path.dirname(path)
    if os.path.realpath(parent)!=parent:
        raise SystemExit("config parent contains a symlink: "+parent)
    pst=os.stat(parent,follow_symlinks=False)
    if not stat.S_ISDIR(pst.st_mode) or pst.st_uid!=1000:
        raise SystemExit("unsafe config parent: "+parent)
    st=os.lstat(path)
    if st.st_uid!=1000 or st.st_nlink!=1: raise SystemExit("unsafe config owner/link count: "+path)
    if stat.S_ISLNK(st.st_mode):
        target=os.readlink(path)
        if target!="/dev/null" or stat.S_IMODE(st.st_mode)!=0o777: raise SystemExit("mask is not exact /dev/null symlink: "+path)
        kind="symlink"; digest=hashlib.sha256(target.encode()).hexdigest()
    elif stat.S_ISREG(st.st_mode) and path.endswith("zz-direct-deskflow.conf"):
        if stat.S_IMODE(st.st_mode)&0o022: raise SystemExit("dangerous drop-in is group/world writable")
        kind="regular"; digest=hashlib.sha256(open(path,"rb").read()).hexdigest()
    else: raise SystemExit("unexpected config dentry: "+path)
    out.append({"path":path,"backup_leaf":str(len(out))+"-"+os.path.basename(path),"kind":kind,
                "uid":st.st_uid,"mode":stat.S_IMODE(st.st_mode),"nlink":st.st_nlink,"dev":st.st_dev,"ino":st.st_ino,"sha256":digest})
doc={"schema_version":1,"state":"viewflow-runtime-config-relocation-intent","entries":out}
open(sys.argv[1],"w").write(json.dumps(doc,separators=(",",":"),sort_keys=True))
PY
    publish_new "$temp" "$config_intent"; temporary_files=()
}

relocate_one() {
    python3 - "$config_intent" "$1" "$backup_dir" <<'PY'
import ctypes,errno,hashlib,json,os,stat,sys
doc=json.load(open(sys.argv[1])); e=doc["entries"][int(sys.argv[2])]; source=e["path"]
leaf=e["backup_leaf"]
if os.path.isabs(leaf) or os.path.basename(leaf)!=leaf or "/" in leaf or "\\" in leaf:
    raise SystemExit("unsafe backup leaf")
dest=os.path.join(sys.argv[3],leaf)
if os.path.realpath(sys.argv[3])!=sys.argv[3] or os.path.realpath(os.path.dirname(source))!=os.path.dirname(source):
    raise SystemExit("source or backup parent contains a symlink")
if os.path.realpath(os.path.dirname(dest))!=os.path.realpath(sys.argv[3]):
    raise SystemExit("backup destination escaped")
def check(path):
    st=os.lstat(path); kind="symlink" if stat.S_ISLNK(st.st_mode) else "regular"
    data=os.readlink(path).encode() if kind=="symlink" else open(path,"rb").read()
    got=(kind,st.st_uid,stat.S_IMODE(st.st_mode),st.st_nlink,st.st_dev,st.st_ino,hashlib.sha256(data).hexdigest())
    want=(e["kind"],e["uid"],e["mode"],e["nlink"],e["dev"],e["ino"],e["sha256"])
    if got!=want: raise SystemExit("config dentry identity differs: "+path)
if os.path.lexists(source) and os.path.lexists(dest): raise SystemExit("both config names exist")
if os.path.lexists(dest): check(dest); raise SystemExit(0)
if not os.path.lexists(source): raise SystemExit("config dentry disappeared")
check(source)
libc=ctypes.CDLL(None,use_errno=True); AT_FDCWD=-100; RENAME_NOREPLACE=1
if libc.renameat2(AT_FDCWD,source.encode(),AT_FDCWD,dest.encode(),RENAME_NOREPLACE)!=0:
    raise OSError(ctypes.get_errno(),os.strerror(ctypes.get_errno()))
for parent in (os.path.dirname(source),os.path.dirname(dest)):
    fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); os.fsync(fd); os.close(fd)
if os.path.lexists(source): raise SystemExit("source remained after rename")
check(dest)
PY
}

relocate_runtime_config() {
    local index
    snapshot_config_intent
    if [[ ! -e $backup_dir && ! -L $backup_dir ]]; then
        mkdir -- "$backup_dir"; chmod 0700 "$backup_dir"; sync -f "$(dirname -- "$backup_dir")"
    fi
    safe_owner_dir 'config backup directory' "$backup_dir"
    for index in 0 1 2 3 4; do relocate_one "$index"; done
    systemctl --user daemon-reload
    [[ $(unit_prop "$VIEWFLOW_UNIT" LoadState) == loaded && $(unit_prop "$DESKFLOW_UNIT" LoadState) == loaded ]] ||
        die 'persistent units did not unmask after relocation'
}

start_persistent_v13() {
    local deadline pid invocation
    [[ -f $VIEWFLOW && ! -L $VIEWFLOW && $(sha256 "$VIEWFLOW") == "$installed_viewflow_sha" ]] || die 'installed Viewflow differs'
    [[ -f $VIEWFLOW_UNIT_FILE && ! -L $VIEWFLOW_UNIT_FILE && $(sha256 "$VIEWFLOW_UNIT_FILE") == "$installed_unit_sha" ]] || die 'installed Viewflow unit differs'
    [[ $(sha256 "$DESKFLOW") == "$(jq -er '.linux_deskflow_executable_sha256' "$terminal")" &&
       $(sha256 "$DESKFLOW_CORE") == "$(jq -er '.linux_deskflow_core_executable_sha256' "$terminal")" ]] || die 'installed old Deskflow bytes differ'
    [[ $(unit_prop "$DESKFLOW_UNIT" MainPID) == 0 && -z $(exact_pids "$DESKFLOW") && -z $(exact_pids "$DESKFLOW_CORE") ]] ||
        die 'persistent Deskflow must remain stopped'
    if [[ $(unit_prop "$VIEWFLOW_UNIT" ActiveState) != active ]]; then systemctl --user start "$VIEWFLOW_UNIT"; fi
    deadline=$((SECONDS+30)); pid=0
    while ((SECONDS<deadline)); do
        pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true)
        [[ $pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$pid/exe" 2>/dev/null || true) == "$installed_viewflow_sha" ]] && break
        sleep 0.1
    done
    [[ $pid =~ ^[1-9][0-9]*$ ]] || die 'persistent v1.3 Viewflow did not start'
    invocation=$(unit_prop "$VIEWFLOW_UNIT" InvocationID)
    journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" | grep -Fqx "$STARTUP" ||
        die 'persistent Viewflow lacks exact protocol-1.3 startup proof'
    [[ $(ss -H -lunp 'sport = :44119') == *"pid=$pid,"* ]] || die 'persistent Viewflow does not own UDP 44119'
}

validate_fresh_handoff() {
    validate_publish_receipt
    private_input 'fresh handoff receipt' "$handoff_receipt" "$(sha256 "$handoff_receipt")"; strict_json "$handoff_receipt"
    jq -e --arg op "$new_operation" --arg coordinator "$new_coordinator" --arg cli_sha "$marker_candidate_sha" \
      --arg marker_sha "$(sha256 "$MARKER")" --arg publish "$publish_receipt" --arg publish_sha "$(sha256 "$publish_receipt")" \
      --arg deskflow_sha "$(jq -er '.linux_deskflow_executable_sha256' "$terminal")" \
      --arg core_sha "$(jq -er '.linux_deskflow_core_executable_sha256' "$terminal")" '
      keys==["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256","deployment_publish_receipt_path","deployment_publish_receipt_sha256","deskflow_core_exact_process_count","deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_exact_process_count","deskflow_executable_path","deskflow_executable_sha256","deskflow_tcp_listener_count","deskflow_tcp_port","deskflow_unit","deskflow_unit_active_state","deskflow_unit_main_pid","marker_cli_path","marker_cli_sha256","marker_generation","observed_at_utc","operation_id","protocol_version","runtime_marker_path","runtime_marker_present","schema_version","source_display_id","state","target_device_id"] and
      .schema_version==1 and .state=="viewflow-v13-marker-handoff-prepared" and .protocol_version=="2.1" and
      .operation_id==$op and .coordinator_instance_id==$coordinator and .marker_generation=="1" and
      .source_display_id=="00000000-0000-0000-0000-000000000101" and
      .target_device_id=="00000000-0000-0000-0000-000000000002" and
      .marker_cli_path=="/home/wilf/.local/lib/viewflow/viewflow-deployment-marker" and .marker_cli_sha256==$cli_sha and
      .deployment_marker_path=="/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and
      .deployment_marker_sha256==$marker_sha and .deployment_publish_receipt_path==$publish and
      .deployment_publish_receipt_sha256==$publish_sha and .deskflow_unit=="deskflow.service" and
      .deskflow_unit_active_state=="inactive" and .deskflow_unit_main_pid==0 and
      .deskflow_executable_path=="/home/wilf/.local/lib/deskflow-scale-fix/deskflow" and
      .deskflow_executable_sha256==$deskflow_sha and .deskflow_exact_process_count==0 and
      .deskflow_core_executable_path=="/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core" and
      .deskflow_core_executable_sha256==$core_sha and .deskflow_core_exact_process_count==0 and
      .deskflow_tcp_port==24800 and .deskflow_tcp_listener_count==0 and
      .runtime_marker_path=="/home/wilf/.local/state/viewflow/deskflow-quarantine.v2" and
      .runtime_marker_present==false and
      (.observed_at_utc|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.000Z$"))
    ' "$handoff_receipt" >/dev/null || die 'fresh marker handoff differs'
    [[ -f $MARKER && ! -L $MARKER && $(stat -c '%u:%a:%h:%s' -- "$MARKER") == 1000:600:1:256 &&
       $(sha256 "$MARKER") == "$(jq -er '.deployment_marker_sha256' "$handoff_receipt")" ]] || die 'fresh marker differs'
}

validate_publish_receipt() {
    private_input 'fresh publish receipt' "$publish_receipt" "$(sha256 "$publish_receipt")"
    strict_json "$publish_receipt"
    jq -e --arg op "$new_operation" --arg coordinator "$new_coordinator" --arg candidate "$marker_candidate_sha" '
      keys==["coordinator_instance_id","created_at_unix_ms","created_at_utc","marker_generation","marker_path","marker_sha256","operation_id","protocol_version","schema_version","source_display_id","state","target_device_id"] and
      .schema_version==1 and .state=="deployment-quarantine-published" and .protocol_version=="2.1" and
      .operation_id==$op and .coordinator_instance_id==$coordinator and .marker_generation=="1" and
      .source_display_id=="00000000-0000-0000-0000-000000000101" and
      .target_device_id=="00000000-0000-0000-0000-000000000002" and
      .marker_path=="/home/wilf/.local/state/viewflow/deployment-quarantine.v1" and
      (.marker_sha256|test("^[0-9a-f]{64}$")) and (.created_at_unix_ms|test("^[1-9][0-9]*$")) and
      (.created_at_utc|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
    ' "$publish_receipt" >/dev/null || die 'fresh publish receipt differs'
    [[ $(sha256 "$MARKER_CLI") == "$marker_candidate_sha" && $(sha256 "$MARKER") == "$(jq -er '.marker_sha256' "$publish_receipt")" ]] ||
        die 'fresh publish receipt does not bind installed CLI/marker bytes'
}

validate_fresh_marker_bytes() {
    python3 - "$MARKER" "$new_operation" "$new_coordinator" <<'PY'
import hashlib,sys,uuid
b=open(sys.argv[1],"rb").read(); op=sys.argv[2]; coordinator=sys.argv[3]
if len(b)!=256 or b[:13]!=b"VFDQT001\x01\x01\x02\x01\x01" or b[13]!=len(op) or any(b[14:16]):
    raise SystemExit("fresh marker header differs")
if b[16:16+len(op)]!=op.encode() or any(b[16+len(op):144]): raise SystemExit("fresh marker operation differs")
if b[144:160]!=uuid.UUID("00000000-0000-0000-0000-000000000101").bytes: raise SystemExit("fresh marker source differs")
if b[160:176]!=uuid.UUID("00000000-0000-0000-0000-000000000002").bytes: raise SystemExit("fresh marker target differs")
if b[176:192]!=uuid.UUID(coordinator).bytes or int.from_bytes(b[192:200],"little")==0 or int.from_bytes(b[200:208],"little")!=1 or any(b[208:]):
    raise SystemExit("fresh marker coordinator/time/generation differs")
PY
}

recover_partial_handoff() {
    local temp created_ms created_utc deskflow_sha core_sha publish_sha marker_sha observed stages=()
    [[ -f $MARKER && ! -L $MARKER && $(stat -c '%u:%a:%h:%s' -- "$MARKER") == 1000:600:1:256 ]] ||
        die 'partial handoff lacks a safe active marker'
    [[ -f $MARKER_CLI && ! -L $MARKER_CLI && $(stat -c '%u:%a:%h' -- "$MARKER_CLI") == 1000:755:1 &&
       $(sha256 "$MARKER_CLI") == "$marker_candidate_sha" ]] || die 'partial handoff lacks the exact marker CLI'
    validate_fresh_marker_bytes
    marker_sha=$(sha256 "$MARKER")
    if [[ ! -e $publish_receipt && ! -L $publish_receipt ]]; then
        stages=("$fresh_root"/.viewflow-publish.*)
        if ((${#stages[@]} > 1)); then die 'multiple retained prepare publish stages exist'; fi
        if ((${#stages[@]} == 1)); then
            [[ -f ${stages[0]} && ! -L ${stages[0]} && $(stat -c '%u:%a:%h' -- "${stages[0]}") == 1000:600:1 ]] ||
                die 'retained prepare publish stage metadata differs'
            strict_json "${stages[0]}"
            jq -e --arg op "$new_operation" --arg coordinator "$new_coordinator" --arg marker "$marker_sha" '
              .schema_version==1 and .state=="deployment-quarantine-published" and .protocol_version=="2.1" and
              .operation_id==$op and .coordinator_instance_id==$coordinator and .marker_generation=="1" and
              .source_display_id=="00000000-0000-0000-0000-000000000101" and
              .target_device_id=="00000000-0000-0000-0000-000000000002" and .marker_sha256==$marker
            ' "${stages[0]}" >/dev/null || die 'retained prepare publish stage binding differs'
            publish_new "${stages[0]}" "$publish_receipt"
        else
            read -r created_ms created_utc < <(python3 - "$MARKER" <<'PY'
import datetime,sys
b=open(sys.argv[1],"rb").read(); ms=int.from_bytes(b[192:200],"little")
dt=datetime.datetime.fromtimestamp(ms/1000,datetime.timezone.utc)
print(ms,dt.strftime("%Y-%m-%dT%H:%M:%S.")+f"{ms%1000:03d}Z")
PY
            )
            temp=$(mktemp --tmpdir="$fresh_root" '.recovered-publish.XXXXXX'); temporary_files+=("$temp")
            jq -cn --arg op "$new_operation" --arg coordinator "$new_coordinator" --arg marker "$marker_sha" \
              --arg created_ms "$created_ms" --arg created_utc "$created_utc" '
              {schema_version:1,state:"deployment-quarantine-published",protocol_version:"2.1",operation_id:$op,
               source_display_id:"00000000-0000-0000-0000-000000000101",target_device_id:"00000000-0000-0000-0000-000000000002",
               coordinator_instance_id:$coordinator,marker_generation:"1",marker_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",
               marker_sha256:$marker,created_at_unix_ms:$created_ms,created_at_utc:$created_utc}
            ' >"$temp"
            publish_new "$temp" "$publish_receipt"; temporary_files=()
        fi
    fi
    validate_publish_receipt
    if [[ ! -e $handoff_receipt && ! -L $handoff_receipt ]]; then
        [[ $(unit_prop "$DESKFLOW_UNIT" MainPID) == 0 && -z $(exact_pids "$DESKFLOW") &&
           -z $(exact_pids "$DESKFLOW_CORE") && -z $(ss -H -ltn 'sport = :24800') && ! -e $RUNTIME_MARKER ]] ||
            die 'cannot recover marker handoff while Deskflow/runtime marker is present'
        deskflow_sha=$(sha256 "$DESKFLOW"); core_sha=$(sha256 "$DESKFLOW_CORE")
        publish_sha=$(sha256 "$publish_receipt"); observed=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
        temp=$(mktemp --tmpdir="$fresh_root" '.recovered-handoff.XXXXXX'); temporary_files+=("$temp")
        jq -cn --arg op "$new_operation" --arg coordinator "$new_coordinator" --arg cli_sha "$marker_candidate_sha" \
          --arg marker_sha "$marker_sha" --arg publish "$publish_receipt" --arg publish_sha "$publish_sha" \
          --arg deskflow_sha "$deskflow_sha" --arg core_sha "$core_sha" --arg observed "$observed" '
          {schema_version:1,state:"viewflow-v13-marker-handoff-prepared",protocol_version:"2.1",operation_id:$op,
           source_display_id:"00000000-0000-0000-0000-000000000101",target_device_id:"00000000-0000-0000-0000-000000000002",
           coordinator_instance_id:$coordinator,marker_generation:"1",marker_cli_path:"/home/wilf/.local/lib/viewflow/viewflow-deployment-marker",
           marker_cli_sha256:$cli_sha,deployment_marker_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",
           deployment_marker_sha256:$marker_sha,deployment_publish_receipt_path:$publish,
           deployment_publish_receipt_sha256:$publish_sha,deskflow_unit:"deskflow.service",deskflow_unit_active_state:"inactive",
           deskflow_unit_main_pid:0,deskflow_executable_path:"/home/wilf/.local/lib/deskflow-scale-fix/deskflow",
           deskflow_executable_sha256:$deskflow_sha,deskflow_exact_process_count:0,
           deskflow_core_executable_path:"/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core",
           deskflow_core_executable_sha256:$core_sha,deskflow_core_exact_process_count:0,deskflow_tcp_port:24800,
           deskflow_tcp_listener_count:0,runtime_marker_path:"/home/wilf/.local/state/viewflow/deskflow-quarantine.v2",
           runtime_marker_present:false,observed_at_utc:$observed}
        ' >"$temp"
        publish_new "$temp" "$handoff_receipt"; temporary_files=()
    fi
    validate_fresh_handoff
}

prepare_fresh_handoff() {
    if [[ -e $handoff_receipt || -L $handoff_receipt ]]; then validate_fresh_handoff; return; fi
    if [[ -e $MARKER || -L $MARKER || -e $publish_receipt || -L $publish_receipt ]]; then
        recover_partial_handoff
        return
    fi
    [[ $(sha256 "$prepare_script") == "$prepare_script_sha" ]] || die 'prepare script changed before invocation'
    /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$prepare_script" \
      --deployment-marker-candidate "$marker_candidate" --deployment-marker-sha256 "$marker_candidate_sha" \
      --operation-id "$new_operation" --source-display-id "$SOURCE_UUID" --target-device-id "$TARGET_UUID" \
      --coordinator-instance-id "$new_coordinator" --marker-generation 1 \
      --deployment-publish-receipt "$publish_receipt" --bootstrap-handoff-receipt "$handoff_receipt"
    validate_fresh_handoff
}

write_collector_intent() {
    local out=$1 pid invocation boot ticks
    pid=$(unit_prop "$VIEWFLOW_UNIT" MainPID); invocation=$(unit_prop "$VIEWFLOW_UNIT" InvocationID)
    boot=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id); ticks=$(process_ticks "$pid")
    jq -cn --arg op "$new_operation" --arg boot "$boot" --arg invocation "$invocation" --arg sha "$installed_viewflow_sha" \
      --argjson pid "$pid" --argjson ticks "$ticks" \
      '{schema_version:1,state:"viewflow-fresh-v13-collector-intent",operation_id:$op,daemon_pid:$pid,
        daemon_start_ticks:$ticks,boot_id:$boot,invocation_id:$invocation,daemon_sha256:$sha}' >"$out"
}

validate_frozen() {
    local collector_intent=$fresh_root/collector-intent.json current_boot completed age
    private_input 'fresh Linux frozen evidence' "$frozen_evidence" "$(sha256 "$frozen_evidence")"; strict_json "$frozen_evidence"
    [[ -e $collector_intent && ! -L $collector_intent ]] || die 'fresh frozen evidence lacks its pre-stop collector intent'
    private_input 'collector intent' "$collector_intent" "$(sha256 "$collector_intent")"; strict_json "$collector_intent"
    jq -e --arg op "$new_operation" --arg sha "$installed_viewflow_sha" '
      keys==["boot_id","daemon_pid","daemon_sha256","daemon_start_ticks","invocation_id","operation_id","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-fresh-v13-collector-intent" and .operation_id==$op and
      .daemon_sha256==$sha and (.daemon_pid|type=="number" and .>0 and .==floor) and
      (.daemon_start_ticks|type=="number" and .>0 and .==floor) and
      (.boot_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      (.invocation_id|test("^[0-9a-f]{32}$"))
    ' "$collector_intent" >/dev/null || die 'collector intent binding differs'
    jq -e --arg op "$new_operation" --arg sha "$installed_viewflow_sha" --slurpfile intent "$collector_intent" '
      keys==["completed_at_unix_ms","daemon","journal","operation_id","post_stop","pre_stop","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-v13-bootstrap-frozen" and .operation_id==$op and
      (.daemon|keys)==["boot_id","daemon_instance_id","executable","pid","sha256","start_ticks","systemd_invocation_id"] and
      .daemon.sha256==$sha and .daemon.executable=="/home/wilf/.local/lib/viewflow/viewflowd" and
      (.daemon.pid|type=="number" and .>0 and .==floor) and (.daemon.start_ticks|type=="number" and .>0 and .==floor) and
      (.daemon.boot_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      .daemon.daemon_instance_id==(.daemon.boot_id+"-"+(.daemon.pid|tostring)+"-"+(.daemon.start_ticks|tostring)) and
      (.daemon.systemd_invocation_id|test("^[0-9a-f]{32}$")) and
      ($intent|length)==1 and .daemon.pid==$intent[0].daemon_pid and .daemon.start_ticks==$intent[0].daemon_start_ticks and
        .daemon.boot_id==$intent[0].boot_id and .daemon.systemd_invocation_id==$intent[0].invocation_id and
        .daemon.sha256==$intent[0].daemon_sha256 and
      (.journal|keys)==["counts","end_cursor","end_realtime_timestamp_us","entry_count","protocol_startup_cursor","protocol_startup_realtime_timestamp_us","query_boot_id","query_pid","query_systemd_invocation_id","slice_sha256","start_cursor","start_realtime_timestamp_us"] and
      .journal.query_boot_id==(.daemon.boot_id|gsub("-";"")) and .journal.query_pid==(.daemon.pid|tostring) and
      .journal.query_systemd_invocation_id==.daemon.systemd_invocation_id and .journal.entry_count>0 and
      (.journal.slice_sha256|test("^[0-9a-f]{64}$")) and
      (.journal.counts|keys)==["cleanup_or_release_error","input_event","input_sidecar_activation","lease_offered","protocol_1_3_startup"] and
      .journal.counts.protocol_1_3_startup==1 and all(.journal.counts[]; type=="number" and .>=0 and .==floor) and
      .pre_stop=={deskflow_unit_active_state:"inactive",deskflow_main_pid:0,deskflow_exact_process_count:0,
        deskflow_core_exact_process_count:0,deskflow_tcp_24800_listener_count:0} and
      (.post_stop|keys)==["command_output_format","command_output_sha256","command_outputs","exact_process_count","main_pid","original_daemon_pid_present","sidecar_socket_present","udp_44119_listener_count","unit_active_state"] and
      .post_stop.unit_active_state=="inactive" and .post_stop.main_pid==0 and .post_stop.exact_process_count==0 and
      .post_stop.udp_44119_listener_count==0 and .post_stop.sidecar_socket_present==false and
      .post_stop.original_daemon_pid_present==false and
      .post_stop.command_output_format=="key=value newline-delimited UTF-8 in displayed order" and
      (.post_stop.command_output_sha256|test("^[0-9a-f]{64}$")) and
      .post_stop.command_outputs=={systemctl_is_active:"inactive",systemctl_main_pid:"0",exact_viewflow_pids:"",
        udp_44119_listeners:"",sidecar_socket_present:"false",original_daemon_pid_present:"false"} and
      (.completed_at_unix_ms|type=="number" and .>0 and .==floor)
    ' "$frozen_evidence" >/dev/null || die 'fresh Linux frozen evidence differs'
    current_boot=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)
    [[ $(jq -er '.daemon.boot_id' "$frozen_evidence") == "$current_boot" ]] || die 'fresh Linux frozen evidence belongs to another boot'
    completed=$(jq -er '.completed_at_unix_ms' "$frozen_evidence"); age=$(($(date -u +%s)-completed/1000))
    ((age >= 0 && age <= 1800)) || die 'fresh Linux frozen evidence is stale or from the future'
    [[ ! -e /proc/$(jq -er '.daemon.pid' "$frozen_evidence") ]] || die 'frozen persistent Viewflow PID exists again'
}

recover_frozen_after_collector_stop() {
    local collector_intent=$1 temp journal transcript pid ticks boot invocation journal_boot
    local startup_count lease_count input_count activation_count error_count entries start_cursor start_us startup_cursor startup_us end_cursor end_us
    local journal_sha transcript_sha completed
    private_input 'collector intent' "$collector_intent" "$(sha256 "$collector_intent")"; strict_json "$collector_intent"
    jq -e --arg op "$new_operation" --arg sha "$installed_viewflow_sha" '
      keys==["boot_id","daemon_pid","daemon_sha256","daemon_start_ticks","invocation_id","operation_id","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-fresh-v13-collector-intent" and .operation_id==$op and
      .daemon_sha256==$sha and (.daemon_pid|type=="number" and .>0) and (.daemon_start_ticks|type=="number" and .>0) and
      (.boot_id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      (.invocation_id|test("^[0-9a-f]{32}$"))
    ' "$collector_intent" >/dev/null || die 'collector intent schema differs'
    pid=$(jq -er '.daemon_pid' "$collector_intent"); ticks=$(jq -er '.daemon_start_ticks' "$collector_intent")
    boot=$(jq -er '.boot_id' "$collector_intent"); invocation=$(jq -er '.invocation_id' "$collector_intent"); journal_boot=${boot//-/}
    [[ $(tr -d '\r\n' </proc/sys/kernel/random/boot_id) == "$boot" && ! -e /proc/$pid &&
       $(unit_prop "$VIEWFLOW_UNIT" MainPID) == 0 && -z $(exact_pids "$VIEWFLOW") &&
       -z $(ss -H -lun 'sport = :44119') && ! -e $SIDECAR_SOCKET ]] ||
        die 'collector recovery boundary is not the exact stopped invocation'
    journal=$(mktemp --tmpdir="$fresh_root" '.collector-recovery-journal.XXXXXX'); temporary_files+=("$journal")
    journalctl --user --quiet --no-pager --output=json "_SYSTEMD_INVOCATION_ID=$invocation" "_PID=$pid" "_BOOT_ID=$journal_boot" >"$journal"
    jq -s -e --arg inv "$invocation" --arg pid "$pid" --arg boot "$journal_boot" '
      length>0 and all(.[]; ._SYSTEMD_INVOCATION_ID==$inv and ._PID==$pid and ._BOOT_ID==$boot)
    ' "$journal" >/dev/null || die 'collector recovery journal crosses the frozen invocation'
    startup_count=$(jq -sr --arg line "$STARTUP" '[.[]|select((.MESSAGE//"")==$line)]|length' "$journal")
    [[ $startup_count == 1 ]] || die 'collector recovery journal lacks one exact startup line'
    lease_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("lease_offered="))]|length' "$journal")
    input_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("input_event_sequence="))]|length' "$journal")
    activation_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("input sidecar activation"))]|length' "$journal")
    error_count=$(jq -sr '[.[]|(.MESSAGE//"")|select(test("(?i)(((cleanup|release[-_ ]?all|releaseall).*(failed|error|not confirmed|timed out|rejected))|((failed|error).*(cleanup|release[-_ ]?all|releaseall)))"))]|length' "$journal")
    entries=$(jq -s 'length' "$journal"); start_cursor=$(jq -sr '.[0].__CURSOR' "$journal"); start_us=$(jq -sr '.[0].__REALTIME_TIMESTAMP' "$journal")
    startup_cursor=$(jq -sr --arg line "$STARTUP" '[.[]|select(.MESSAGE==$line)][0].__CURSOR' "$journal")
    startup_us=$(jq -sr --arg line "$STARTUP" '[.[]|select(.MESSAGE==$line)][0].__REALTIME_TIMESTAMP' "$journal")
    end_cursor=$(jq -sr '.[-1].__CURSOR' "$journal"); end_us=$(jq -sr '.[-1].__REALTIME_TIMESTAMP' "$journal"); journal_sha=$(sha256 "$journal")
    transcript=$(mktemp --tmpdir="$fresh_root" '.collector-recovery-transcript.XXXXXX'); temporary_files+=("$transcript")
    {
        printf 'systemctl_is_active=inactive\n'
        printf 'systemctl_main_pid=0\n'
        printf 'exact_viewflow_pids=\n'
        printf 'udp_44119_listeners=\n'
        printf 'sidecar_socket_present=false\n'
        printf 'original_daemon_pid_present=false\n'
    } >"$transcript"
    transcript_sha=$(sha256 "$transcript"); completed=$(($(date -u +%s%N)/1000000))
    temp=$(mktemp --tmpdir="$fresh_root" '.collector-recovered-evidence.XXXXXX'); temporary_files+=("$temp")
    jq -n --arg op "$new_operation" --argjson pid "$pid" --argjson ticks "$ticks" --arg boot "$boot" --arg journal_boot "$journal_boot" \
      --arg sha "$installed_viewflow_sha" --arg invocation "$invocation" --arg start_cursor "$start_cursor" --argjson start_us "$start_us" \
      --arg startup_cursor "$startup_cursor" --argjson startup_us "$startup_us" --arg end_cursor "$end_cursor" --argjson end_us "$end_us" \
      --argjson entries "$entries" --arg journal_sha "$journal_sha" --argjson startup_count "$startup_count" \
      --argjson lease_count "$lease_count" --argjson input_count "$input_count" --argjson activation_count "$activation_count" \
      --argjson error_count "$error_count" --arg transcript_sha "$transcript_sha" --argjson completed "$completed" '
      {schema_version:1,state:"viewflow-v13-bootstrap-frozen",operation_id:$op,
       daemon:{pid:$pid,start_ticks:$ticks,boot_id:$boot,daemon_instance_id:($boot+"-"+($pid|tostring)+"-"+($ticks|tostring)),
         sha256:$sha,executable:"/home/wilf/.local/lib/viewflow/viewflowd",systemd_invocation_id:$invocation},
       journal:{query_boot_id:$journal_boot,query_pid:($pid|tostring),query_systemd_invocation_id:$invocation,
         start_cursor:$start_cursor,start_realtime_timestamp_us:$start_us,protocol_startup_cursor:$startup_cursor,
         protocol_startup_realtime_timestamp_us:$startup_us,end_cursor:$end_cursor,end_realtime_timestamp_us:$end_us,
         entry_count:$entries,slice_sha256:$journal_sha,counts:{protocol_1_3_startup:$startup_count,lease_offered:$lease_count,
           input_event:$input_count,input_sidecar_activation:$activation_count,cleanup_or_release_error:$error_count}},
       pre_stop:{deskflow_unit_active_state:"inactive",deskflow_main_pid:0,deskflow_exact_process_count:0,
         deskflow_core_exact_process_count:0,deskflow_tcp_24800_listener_count:0},
       post_stop:{unit_active_state:"inactive",main_pid:0,exact_process_count:0,udp_44119_listener_count:0,
         sidecar_socket_present:false,original_daemon_pid_present:false,
         command_outputs:{systemctl_is_active:"inactive",systemctl_main_pid:"0",exact_viewflow_pids:"",
           udp_44119_listeners:"",sidecar_socket_present:"false",original_daemon_pid_present:"false"},
         command_output_format:"key=value newline-delimited UTF-8 in displayed order",command_output_sha256:$transcript_sha},
       completed_at_unix_ms:$completed}
    ' >"$temp"
    publish_new "$temp" "$frozen_evidence"; temporary_files=()
    validate_frozen
}

freeze_persistent_v13() {
    local collector_intent=$fresh_root/collector-intent.json temp pid
    if [[ -e $frozen_evidence || -L $frozen_evidence ]]; then validate_frozen; return; fi
    if [[ $(unit_prop "$VIEWFLOW_UNIT" ActiveState) != active ]]; then
        [[ -e $collector_intent && ! -L $collector_intent ]] || die 'persistent Viewflow stopped without a collector intent'
        recover_frozen_after_collector_stop "$collector_intent"
        return
    fi
    if [[ ! -e $collector_intent && ! -L $collector_intent ]]; then
        temp=$(mktemp --tmpdir="$fresh_root" '.collector-intent.XXXXXX'); temporary_files+=("$temp")
        write_collector_intent "$temp"; publish_new "$temp" "$collector_intent"; temporary_files=()
    else private_input 'collector intent' "$collector_intent" "$(sha256 "$collector_intent")"; fi
    pid=$(jq -er '.daemon_pid' "$collector_intent")
    [[ $(sha256 "$collector_script") == "$collector_script_sha" ]] || die 'collector script changed before invocation'
    /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$collector_script" \
      --daemon-pid "$pid" --daemon-sha256 "$installed_viewflow_sha" --operation-id "$new_operation" \
      --evidence-output "$frozen_evidence"
    validate_frozen
}

validate_final_receipt() {
    local backups pressed
    private_input 'bridge final receipt' "$final_receipt" "$(sha256 "$final_receipt")"; strict_json "$final_receipt"
    pressed=$(jq -er '.pressed_state' "$cleanup_proof")
    backups=$(python3 - "$config_intent" "$backup_dir" <<'PY'
import json,os,sys
d=json.load(open(sys.argv[1])); out=[]
for e in d["entries"]:
 p=os.path.join(sys.argv[2],e["backup_leaf"])
 out.append({"original_path":e["path"],"backup_path":p,"sha256":e["sha256"],"kind":e["kind"]})
print(json.dumps(out,separators=(",",":")))
PY
)
    jq -e --arg old "$old_operation" --arg new "$new_operation" --arg coordinator "$new_coordinator" \
      --arg terminal "$terminal_sha" --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" \
      --arg linux "$linux_started_sha" --arg cleanup "$(sha256 "$cleanup_proof")" \
      --arg config "$(sha256 "$config_intent")" --arg publish "$(sha256 "$publish_receipt")" \
      --arg handoff "$(sha256 "$handoff_receipt")" --arg frozen "$(sha256 "$frozen_evidence")" \
      --arg marker "$(sha256 "$MARKER")" --arg pressed "$pressed" --argjson backups "$backups" '
      keys==["fresh_boundary","marker_generation","new_coordinator_instance_id","new_operation_id","old_abort","old_operation_id","retirement","runtime_config_relocation","schema_version","state"] and
      .schema_version==1 and .state=="viewflow-fresh-v21-bootstrap-boundary-ready" and
      .old_operation_id==$old and .new_operation_id==$new and .new_operation_id!=.old_operation_id and
      .new_coordinator_instance_id==$coordinator and .marker_generation=="1" and
      .old_abort=={terminal_sha256:$terminal,authorization_sha256:$auth,vfdqa_receipt_sha256:$abort,
        linux_v13_started_sha256:$linux} and
      (.retirement|keys)==["cleanup_proof_sha256","pressed_state","sidecar_socket_present","tcp_24800_listener_count","transient_core_process_count","transient_deskflow_process_count","transient_viewflow_process_count","udp_44119_listener_count"] and
      .retirement.cleanup_proof_sha256==$cleanup and .retirement.pressed_state==$pressed and
      .retirement.transient_viewflow_process_count==0 and .retirement.transient_deskflow_process_count==0 and
      .retirement.transient_core_process_count==0 and .retirement.udp_44119_listener_count==0 and
      .retirement.tcp_24800_listener_count==0 and .retirement.sidecar_socket_present==false and
      .runtime_config_relocation=={intent_sha256:$config,backups:$backups} and
      .fresh_boundary=={deployment_publish_receipt_sha256:$publish,marker_handoff_receipt_sha256:$handoff,
        linux_frozen_evidence_sha256:$frozen,deployment_marker_sha256:$marker,protocol_version:"2.1"}
    ' "$final_receipt" >/dev/null || die 'bridge final receipt binding differs'
}

publish_final() {
    local temp backups index pressed
    if [[ -e $final_receipt || -L $final_receipt ]]; then validate_final_receipt; return; fi
    validate_fresh_handoff; validate_frozen; transients_zero || die 'transients are not zero at final publication'
    [[ $(unit_prop "$VIEWFLOW_UNIT" MainPID) == 0 && -z $(ss -H -lun 'sport = :44119') ]] || die 'collector did not freeze persistent Viewflow'
    for index in 0 1 2 3 4; do relocate_one "$index"; done
    pressed=$(jq -er '.pressed_state' "$cleanup_proof")
    backups=$(python3 - "$config_intent" "$backup_dir" <<'PY'
import hashlib,json,os,sys
d=json.load(open(sys.argv[1])); out=[]
for e in d["entries"]:
 p=os.path.join(sys.argv[2],e["backup_leaf"])
 if not os.path.lexists(p) or os.path.lexists(e["path"]): raise SystemExit("config relocation incomplete")
 out.append({"original_path":e["path"],"backup_path":p,"sha256":e["sha256"],"kind":e["kind"]})
print(json.dumps(out,separators=(",",":")))
PY
)
    temp=$(mktemp --tmpdir="$fresh_root" '.bridge-final.XXXXXX'); temporary_files+=("$temp")
    jq -cn --arg old "$old_operation" --arg new "$new_operation" --arg coordinator "$new_coordinator" \
      --arg terminal "$terminal_sha" --arg auth "$authorization_sha" --arg abort "$abort_receipt_sha" \
      --arg linux "$linux_started_sha" --arg cleanup "$(sha256 "$cleanup_proof")" \
      --arg config "$(sha256 "$config_intent")" --arg publish "$(sha256 "$publish_receipt")" \
      --arg handoff "$(sha256 "$handoff_receipt")" --arg frozen "$(sha256 "$frozen_evidence")" \
      --arg marker "$(sha256 "$MARKER")" --arg pressed "$pressed" --argjson backups "$backups" '
      {schema_version:1,state:"viewflow-fresh-v21-bootstrap-boundary-ready",old_operation_id:$old,
       new_operation_id:$new,new_coordinator_instance_id:$coordinator,marker_generation:"1",
       old_abort:{terminal_sha256:$terminal,authorization_sha256:$auth,vfdqa_receipt_sha256:$abort,
         linux_v13_started_sha256:$linux},retirement:{cleanup_proof_sha256:$cleanup,pressed_state:$pressed,
         transient_viewflow_process_count:0,transient_deskflow_process_count:0,transient_core_process_count:0,
         udp_44119_listener_count:0,tcp_24800_listener_count:0,sidecar_socket_present:false},
       runtime_config_relocation:{intent_sha256:$config,backups:$backups},
       fresh_boundary:{deployment_publish_receipt_sha256:$publish,marker_handoff_receipt_sha256:$handoff,
         linux_frozen_evidence_sha256:$frozen,deployment_marker_sha256:$marker,protocol_version:"2.1"}}
    ' >"$temp"
    publish_new "$temp" "$final_receipt"; temporary_files=()
    validate_final_receipt
}

main() {
    plan=$bridge_root/transition-plan.json
    preflight_inputs
    [[ $mode == validate-inputs-only ]] && { printf 'schema2 abort bridge inputs validated\n'; return; }
    local bridge_parent
    bridge_parent=$(dirname -- "$bridge_root")
    if [[ ! -e $bridge_parent && ! -L $bridge_parent ]]; then
        [[ $bridge_parent == /home/wilf/.local/state/viewflow/bridges &&
           -d /home/wilf/.local/state/viewflow && ! -L /home/wilf/.local/state/viewflow ]] ||
            die 'bridge parent cannot be created safely'
        mkdir -- "$bridge_parent"; chmod 0700 "$bridge_parent"; sync -f /home/wilf/.local/state/viewflow
    fi
    safe_owner_dir 'bridge parent' "$bridge_parent"
    if [[ ! -e $bridge_root && ! -L $bridge_root ]]; then
        mkdir -- "$bridge_root"; chmod 0700 "$bridge_root"; sync -f "$(dirname -- "$bridge_root")"
    fi
    safe_owner_dir 'bridge root' "$bridge_root"
    safe_owner_dir 'deployments root' "$DEPLOYMENTS"
    plan=$bridge_root/transition-plan.json; intent=$bridge_root/retirement-intent.json
    cleanup_proof=$bridge_root/retirement-cleanup.json; config_intent=$bridge_root/runtime-config-relocation-intent.json
    backup_dir=$bridge_root/runtime-config-backups
    make_plan
    if [[ ! -e $intent && ! -L $intent ]]; then
        local temp
        temp=$(mktemp --tmpdir="$bridge_root" '.retirement-intent.XXXXXX'); temporary_files+=("$temp")
        jq -cn --arg plan "$(sha256 "$plan")" --arg old "$old_operation" --arg new "$new_operation" \
          '{schema_version:1,state:"viewflow-abort-transient-retirement-intent",plan_sha256:$plan,
            old_operation_id:$old,new_operation_id:$new}' >"$temp"
        publish_new "$temp" "$intent"; temporary_files=()
    else
        private_input 'retirement intent' "$intent" "$(sha256 "$intent")"; strict_json "$intent"
        jq -e --arg plan "$(sha256 "$plan")" --arg old "$old_operation" --arg new "$new_operation" '
          keys==["new_operation_id","old_operation_id","plan_sha256","schema_version","state"] and
          .schema_version==1 and .state=="viewflow-abort-transient-retirement-intent" and
          .plan_sha256==$plan and .old_operation_id==$old and .new_operation_id==$new
        ' "$intent" >/dev/null || die 'retirement intent binding differs'
    fi
    ensure_cleanup_proof
    retire_transients
    relocate_runtime_config
    if [[ ! -e $frozen_evidence && ! -L $frozen_evidence &&
          ! -e $fresh_root/collector-intent.json && ! -L $fresh_root/collector-intent.json ]]; then
        start_persistent_v13
    fi
    prepare_fresh_handoff
    freeze_persistent_v13
    publish_final
    printf 'fresh protocol-2.1 bootstrap boundary ready: %s\n' "$final_receipt"
}

main
