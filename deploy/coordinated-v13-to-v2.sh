#!/usr/bin/env bash

# Cross-host protocol 1.3 -> 2.1 coordinator. VFDQT001 is coordinator-owned;
# VFQST002 is Deskflow-owned. Normal failed deployment recovery retains or
# republishes VFDQT001 and leaves both hosts inactive.  The separate
# --abort-failed-v13 entrypoint may remove it only after both exact legacy
# baselines and a fresh authenticated v1.3 peer have been re-established.
# shellcheck disable=SC2016,SC2086

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'error: coordinated-v13-to-v2.sh must be executed, not sourced\n' >&2
    return 64
fi

set -Eeuo pipefail
shopt -s nullglob

readonly WINDOWS_SSH_TARGET=wilf@172.16.105.70
readonly WINDOWS_ROLLBACK_SCRIPT='C:\Users\wilf\AppData\Local\Programs\Viewflow\rollback-viewflow.ps1'
readonly SSH_BATCH_OPTION=BatchMode=yes
readonly SSH_HOST_KEY_OPTION=StrictHostKeyChecking=yes
readonly MARKER_CLI=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker
readonly DEPLOYMENT_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly RUNTIME_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
readonly VIEWFLOW_INSTALLED=/home/wilf/.local/lib/viewflow/viewflowd
readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly VIEWFLOW_UNIT_INSTALLED=/home/wilf/.config/systemd/user/viewflow-peer.service
readonly DESKFLOW_DROPIN_INSTALLED=/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly DESKFLOW_UNIT=deskflow.service
readonly VIEWFLOW_SIDECAR=/run/user/1000/viewflow/deskflow.sock
readonly VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/post-release-acceptance.sock
readonly VIEWFLOW_ACCEPTANCE_STATE_DIR=/home/wilf/.local/state/viewflow/post-release-acceptance
readonly DESKFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock
readonly VIEWFLOW_PORT=44119
readonly DESKFLOW_PORT=24800
readonly REQUIRED_PROTOCOL=2.1
readonly REQUIRED_SIDECAR_PROTOCOL=3
readonly EXPECTED_WINDOWS_PEER=172.16.105.62:44119
readonly EXPECTED_WINDOWS_SOURCE_IP=172.16.105.70
readonly EXPECTED_WINDOWS_DEVICE=00000000000000000000000000000002
readonly RECOVERY_FAILURE_EXIT=70
# The sealed/read-only baseline and CAS below close cooperating-writer and
# crash-replay races.  The deployment owner (uid 1000) remains the authority;
# this is not a cryptographic boundary against an actively malicious same-uid
# process spanning the local and SSH observations.
readonly PRE_MUTATION_THREAT_BOUNDARY=cooperating-crash-and-non-owner
# This gate is deliberately a reviewed source constant, not an environment
# override.  It was held at zero until the independent failed-v1.3 abort path,
# its binary receipt decoder, and its crash/replay fixtures were complete.
readonly WINDOWS_RECOVERY_IMPLEMENTED=1
readonly FD_GATE_ENV=/usr/bin/env
readonly FD_GATE_ENV_SHA256=08392d72874da4f88c619ee717f2b4a5f28ba0534ff8cf1083fb2edc37d6475f
readonly FD_GATE_PYTHON=/usr/bin/python3.14
readonly FD_GATE_PYTHON_SHA256=d78f9cf7178ecff09963551399855543c297f37ac207e626228bfe43cb26a70c
readonly FD_GATE_LOADER='import hashlib,sys;expected,payload,*rest=sys.argv[1:];hashlib.sha256(payload.encode()).hexdigest()==expected or sys.exit(65);sys.argv=["viewflow-fd-gate",*rest];exec(compile(payload,"<viewflow-fd-gate>","exec"),{"__name__":"__main__"})'
readonly FD_GATE_LOADER_SHA256=0e3301c81b854c06500628ffd7a1968869e5a377d83a84e0726b33371d8f1eed
readonly FD_GATE_PAYLOAD='import fcntl,hashlib,os,stat,sys
target,expected_sha,expected_uid,expected_mode,expected_links,role,*target_argv=sys.argv[1:]
allowed={"marker":"/home/wilf/.local/lib/viewflow/viewflow-deployment-marker","viewflow":"/home/wilf/.local/lib/viewflow/viewflowd","deskflow":"/home/wilf/.local/lib/deskflow-scale-fix/deskflow"}
if role=="marker-candidate":
    if not os.path.isabs(target) or target==allowed["marker"]:
        raise SystemExit(64)
elif allowed.get(role)!=target:
    raise SystemExit(64)
if role=="marker" and (not target_argv or target_argv[0] not in {"abort","publish","query","release"}):
    raise SystemExit(64)
if role=="marker-candidate" and (not target_argv or target_argv[0] not in {"abort","query"}):
    raise SystemExit(64)
if role=="viewflow" and target_argv!=["serve","--bind","0.0.0.0:44119","--cert","/home/wilf/.local/share/viewflow/identity/peer.pem","--key","/home/wilf/.local/share/viewflow/identity/peer.key","--ca","/home/wilf/.local/share/viewflow/identity/ca.pem","--device-id","00000000000000000000000000000001","--sidecar-socket","/run/user/1000/viewflow/deskflow.sock","--sidecar-peer","172.16.105.70","--sidecar-target-device","00000000000000000000000000000002"]:
    raise SystemExit(64)
if role=="deskflow" and target_argv:
    raise SystemExit(64)
fd=os.open(target,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
st=os.fstat(fd)
if not (stat.S_ISREG(st.st_mode) and st.st_uid==int(expected_uid) and stat.S_IMODE(st.st_mode)==int(expected_mode,8) and st.st_nlink==int(expected_links)):
    raise SystemExit(66)
verified_bytes=bytearray()
with os.fdopen(os.dup(fd),"rb") as stream:
    for chunk in iter(lambda:stream.read(1048576),b""):
        verified_bytes.extend(chunk)
if len(verified_bytes)!=st.st_size or hashlib.sha256(verified_bytes).hexdigest()!=expected_sha:
    raise SystemExit(65)
if verified_bytes[:4]!=b"\x7fELF":
    raise SystemExit(65)
current=os.stat(target,follow_symlinks=False)
if (current.st_dev,current.st_ino,current.st_uid,stat.S_IMODE(current.st_mode),current.st_nlink)!=(st.st_dev,st.st_ino,st.st_uid,stat.S_IMODE(st.st_mode),st.st_nlink):
    raise SystemExit(73)
exec_fd=os.memfd_create("viewflow-verified-elf",os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
remaining=memoryview(verified_bytes)
while remaining:
    written=os.write(exec_fd,remaining)
    if written<=0:
        raise SystemExit(74)
    remaining=remaining[written:]
os.fsync(exec_fd)
os.lseek(exec_fd,0,os.SEEK_SET)
required_seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
fcntl.fcntl(exec_fd,fcntl.F_ADD_SEALS,required_seals)
if fcntl.fcntl(exec_fd,fcntl.F_GET_SEALS)!=required_seals:
    raise SystemExit(74)
sealed_st=os.fstat(exec_fd)
if not stat.S_ISREG(sealed_st.st_mode) or sealed_st.st_size!=len(verified_bytes):
    raise SystemExit(74)
os.close(fd)
clean_env={"HOME":"/home/wilf","USER":"wilf","LOGNAME":"wilf","XDG_RUNTIME_DIR":"/run/user/1000","DBUS_SESSION_BUS_ADDRESS":"unix:path=/run/user/1000/bus","LANG":"C.UTF-8","PATH":"/usr/bin:/bin"}
if role=="deskflow":
    clean_env.update({"XDG_SESSION_TYPE":"wayland","XDG_CURRENT_DESKTOP":"Hyprland","QT_QPA_PLATFORM":"wayland","WAYLAND_DISPLAY":"wayland-1","DISPLAY":":1","DESKFLOW_MOUSE_ADJUSTMENT_WINDOWSVM":"1.6","DESKFLOW_MOUSE_ADJUSTMENT_LINHAIKUODEMAC_MINI_LOCAL":"1.1","DESKFLOW_VIEWFLOW_SIDECAR_SOCKET":"/run/user/1000/viewflow/deskflow.sock","DESKFLOW_VIEWFLOW_SCREEN":"WindowsVM","DESKFLOW_VIEWFLOW_SOURCE_DISPLAY":"00000000000000000000000000000101","DESKFLOW_VIEWFLOW_ROUTE_TO":"00000000000000000000000000000002"})
os.set_inheritable(exec_fd,True)
limit=os.sysconf("SC_OPEN_MAX")
os.closerange(3,exec_fd)
os.closerange(exec_fd+1,limit)
os.execve(f"/proc/self/fd/{exec_fd}",[target,*target_argv],clean_env)'
readonly FD_GATE_PAYLOAD_SHA256=8229311dfe5d40d055675ce46eb49c1aa20abd911abed00b212498a5b0d46d20
readonly FD_GATE_BWRAP=/usr/bin/bwrap
readonly FD_GATE_BWRAP_SHA256=7c44fa8e7326e62e81ab3f70ff682bfc0eb3b447b39cf9fbb779a31948364762
readonly FD_GATE_DESKFLOW_PAYLOAD='import fcntl,hashlib,os,stat,sys
target,expected_sha,expected_uid,expected_mode,expected_links,role,bwrap,bwrap_sha,core,core_sha,*target_argv=sys.argv[1:]
if role!="deskflow" or target!="/home/wilf/.local/lib/deskflow-scale-fix/deskflow" or core!="/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core" or target_argv:
    raise SystemExit(64)
def read_verified(path,expected,uid,mode,links):
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    st=os.fstat(fd)
    if not (stat.S_ISREG(st.st_mode) and st.st_uid==uid and stat.S_IMODE(st.st_mode)==mode and st.st_nlink==links):
        raise SystemExit(66)
    chunks=[]
    while True:
        chunk=os.read(fd,1048576)
        if not chunk:
            break
        chunks.append(chunk)
    data=b"".join(chunks)
    current=os.stat(path,follow_symlinks=False)
    if len(data)!=st.st_size or hashlib.sha256(data).hexdigest()!=expected or data[:4]!=b"\x7fELF" or (current.st_dev,current.st_ino,current.st_uid,stat.S_IMODE(current.st_mode),current.st_nlink)!=(st.st_dev,st.st_ino,st.st_uid,stat.S_IMODE(st.st_mode),st.st_nlink):
        raise SystemExit(65)
    os.close(fd)
    return data
def sealed(data,name):
    fd=os.memfd_create(name,os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
    remaining=memoryview(data)
    while remaining:
        written=os.write(fd,remaining)
        if written<=0:
            raise SystemExit(74)
        remaining=remaining[written:]
    os.fsync(fd)
    os.lseek(fd,0,os.SEEK_SET)
    seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
    fcntl.fcntl(fd,fcntl.F_ADD_SEALS,seals)
    if fcntl.fcntl(fd,fcntl.F_GET_SEALS)!=seals or os.fstat(fd).st_size!=len(data):
        raise SystemExit(74)
    os.set_inheritable(fd,True)
    return fd
uid=int(expected_uid);mode=int(expected_mode,8);links=int(expected_links)
gui_fd=sealed(read_verified(target,expected_sha,uid,mode,links),"viewflow-verified-deskflow")
core_fd=sealed(read_verified(core,core_sha,uid,mode,links),"viewflow-verified-deskflow-core")
read_verified(bwrap,bwrap_sha,0,0o755,1)
staging="/tmp/viewflow-deskflow-recovery"
gui=staging+"/deskflow";sealed_core=staging+"/deskflow-core"
clean_env={"HOME":"/home/wilf","USER":"wilf","LOGNAME":"wilf","XDG_RUNTIME_DIR":"/run/user/1000","DBUS_SESSION_BUS_ADDRESS":"unix:path=/run/user/1000/bus","LANG":"C.UTF-8","PATH":"/usr/bin:/bin","XDG_SESSION_TYPE":"wayland","XDG_CURRENT_DESKTOP":"Hyprland","QT_QPA_PLATFORM":"wayland","WAYLAND_DISPLAY":"wayland-1","DISPLAY":":1","DESKFLOW_MOUSE_ADJUSTMENT_WINDOWSVM":"1.6","DESKFLOW_MOUSE_ADJUSTMENT_LINHAIKUODEMAC_MINI_LOCAL":"1.1","DESKFLOW_VIEWFLOW_SIDECAR_SOCKET":"/run/user/1000/viewflow/deskflow.sock","DESKFLOW_VIEWFLOW_SCREEN":"WindowsVM","DESKFLOW_VIEWFLOW_SOURCE_DISPLAY":"00000000000000000000000000000101","DESKFLOW_VIEWFLOW_ROUTE_TO":"00000000000000000000000000000002"}
argv=[bwrap,"--bind","/","/","--tmpfs","/tmp","--tmpfs",staging,"--perms","0755","--ro-bind-data",str(gui_fd),gui,"--perms","0755","--ro-bind-data",str(core_fd),sealed_core,"--remount-ro",staging,"--",gui]
limit=os.sysconf("SC_OPEN_MAX")
keep=sorted((gui_fd,core_fd))
start=3
for fd in keep:
    os.closerange(start,fd)
    start=fd+1
os.closerange(start,limit)
os.execve(bwrap,argv,clean_env)'
readonly FD_GATE_DESKFLOW_PAYLOAD_SHA256=629580d3f5c1a520045c499d28179b2e6bad03aeb13139c6cbcf05a545bd53b8

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
readonly linux_installer=$script_dir/linux/install-viewflow-deskflow.sh
readonly linux_stage=$script_dir/linux/bootstrap-stage-viewflow.sh
readonly linux_finalize=$script_dir/linux/bootstrap-finalize-viewflow-deskflow.sh
readonly linux_deactivator=$script_dir/linux/deactivate-viewflow-deskflow.sh
readonly windows_static_checker=$script_dir/windows/check-viewflow-client.sh
readonly linux_transaction_checker=$script_dir/linux/check-transactional-deploy.sh
readonly linux_deactivation_checker=$script_dir/linux/check-deactivate-viewflow-deskflow.sh
readonly reviewed_rollback_script=$script_dir/windows/rollback-viewflow.ps1

viewflow_candidate='' viewflow_sha='' deskflow_candidate='' deskflow_sha=''
deployment_marker_candidate='' deployment_marker_sha=''
deskflow_core_candidate='' deskflow_core_sha='' deskflow_provenance_manifest=''
deskflow_acceptance_producer_sha='' viewflow_acceptance_recorder_sha=''
deskflow_provenance_sha='' viewflow_unit_candidate='' viewflow_unit_sha=''
deskflow_dropin_candidate='' deskflow_dropin_sha='' operation_id=''
coordinator_instance_id='' marker_generation='' recovery_marker_generation=''
source_display_id='' target_device_id='' deployment_publish_receipt=''
recovery_deployment_publish_receipt='' deployment_release_receipt=''
cpp_status_response='' cpp_arm_response='' cpp_cleanup_receipt=''
rust_acceptance_arm_response='' rust_acceptance_query_response='' post_release_receipt=''
windows_restart_receipt=''
linux_host_proof='' bootstrap_linux_evidence='' bootstrap_windows_force_receipt=''
bootstrap_windows_install_receipt='' windows_viewflow_sha='' windows_wrapper_sha=''
windows_task_xml_sha='' windows_task_xml_override='' windows_user_sid='' windows_rollback_manifest_path=''
windows_readiness_receipt_path='' windows_readiness_lock_path=''
windows_rollback_token_path='' windows_recovery_bundle_path=''
windows_recovery_force_receipt_path='' windows_rollback_receipt_path=''
linux_deactivation_transcript='' linux_deactivation_proof=''
linux_containment_transcript='' local_windows_validation=''
local_windows_rollback_receipt='' normal_runtime_receipt=''
normal_daemon_exit_evidence='' normal_daemon_exit_observation=''
candidate_retirement_terminal='' candidate_retirement_terminal_sha=''
candidate_replacement_commit='' candidate_replacement_commit_sha=''
candidate_manifest_path='' candidate_manifest_sha='' candidate_tree_sha=''
candidate_replacement_initial_gate_complete=0
coordinator_successor_receipt='' coordinator_successor_receipt_sha=''
coordinator_successor_validated=0
coordinator_successor_windows_prestate='' coordinator_successor_windows_prestate_sha=''
coordinator_predecessor_path='' coordinator_predecessor_sha='' coordinator_predecessor_provenance_path='' coordinator_predecessor_provenance_sha=''
coordinator_successor_path='' coordinator_successor_sha='' coordinator_successor_provenance_path='' coordinator_successor_provenance_sha=''
abort_failed_v13=0 abort_failed_v13_pre_mutation=0 old_coordinator_state_sha=''
attempt3_slot_cleanup_receipt='' attempt3_slot_cleanup_receipt_sha=''
fresh_operation_lineage_receipt='' fresh_operation_lineage_receipt_sha=''
schema1_handoff_lineage_receipt='' schema1_handoff_lineage_receipt_sha=''
schema1_handoff_abort_marker_cli_candidate='' schema1_handoff_abort_marker_cli_sha=''
post_permit_rollback_abort=0
post_force_pre_linux_stage_rollback_abort=0
post_force_abort_marker_cli_candidate='' post_force_abort_marker_cli_sha=''
failed_v13_original_generation_only=0
deployment_abort_authorization='' deployment_abort_receipt=''
failed_v13_abort_transition_receipt='' linux_v13_started_receipt=''
windows_v13_started_receipt='' authenticated_v13_peer_receipt=''
v13_viewflow_unit='' v13_deskflow_unit=''
v13_viewflow_expected_exec_start_sha='' v13_deskflow_expected_exec_start_sha=''
abort_marker_operation_id='' abort_marker_generation='' abort_marker_publish_receipt=''
local_recovery_bundle=''
local_windows_stop_evidence='' local_windows_restart_intent='' recovery_publish_intent=''
pre_mutation_retry_proof=''
pre_mutation_abort_marker_cli_candidate='' pre_mutation_abort_marker_cli_sha=''
pre_mutation_windows_live_proof='' current_pre_mutation_windows_live_sha=''
current_pre_mutation_claim_sha='' current_pre_mutation_process_sha=''
current_pre_mutation_stdout_sha='' current_pre_mutation_stderr_sha=''
current_pre_mutation_remote_stop_sha='' current_pre_mutation_remote_exit_sha=''
readonly PRE_MUTATION_STOP_TRANSPORT_NORMALIZATION=windows-openssh-terminal-lf-to-local-crlf-v1
pre_mutation_old_windows_binary_sha='' pre_mutation_old_windows_wrapper_sha=''
pre_mutation_old_windows_task_sha='' pre_mutation_old_windows_rollback_sha=''
pre_mutation_start_state_candidate='' pre_mutation_stop_state_claim=''
pre_mutation_start_state_sha='' pre_mutation_retry_active=0
marker_phase_query_counter=0
acceptance_timeout_seconds=600 source_display_id_lower='' target_device_id_lower=''
coordinator_instance_id_lower=''
bootstrap_handoff_receipt='' windows_bootstrap_request='' windows_prepared_receipt=''
windows_mutation_permit='' windows_force_envelope='' linux_stage_receipt=''
linux_finalize_receipt='' windows_installer_exit_receipt='' coordinator_state=''
windows_viewflow_candidate='' windows_wrapper_candidate='' windows_launcher_candidate=''
windows_installer_candidate='' windows_launcher_sha='' windows_installer_sha=''
windows_rollback_script_sha='' windows_operation_root='' windows_request_path=''
windows_launcher_path='' windows_installer_path='' windows_candidate_path=''
windows_wrapper_path='' windows_rollback_path='' windows_prepared_path=''
windows_permit_path='' windows_raw_force_path='' windows_force_envelope_path=''
windows_stage_path='' windows_install_path='' windows_exit_path='' windows_request_sha=''
windows_commit_request_path='' windows_stop_evidence_path=''
windows_restart_intent_path='' windows_restart_claim_path='' windows_restart_terminal_path=''
windows_restart_intent_sha=''
resume=0 resume_pre_mutation_stop_intent=0 bootstrap_timeout_seconds=600
pre_mutation_old_executable_sha='' pre_mutation_old_wrapper_sha='' pre_mutation_old_task_xml_sha=''
pre_mutation_old_process_id='' pre_mutation_old_parent_process_id='' pre_mutation_old_process_creation_date=''
pre_mutation_stop_state_baseline_path='' pre_mutation_stop_state_baseline_sha=''
bootstrap_linux_original='' windows_force_original='' windows_install_original=''
recovery_operation_id='' active_marker_publish_receipt='' active_marker_operation_id=''
active_marker_generation='' active_marker_sha=''
recovery_failure_phase='' recovery_mutation_possible=0

old_viewflow_sha='' old_deskflow_sha='' old_deskflow_core_sha=''
old_viewflow_unit_sha='' old_deskflow_dropin_sha='' old_marker_cli_sha='' secure_dir=''
remote_manifest_snapshot='' remote_token_snapshot='' rollback_mode=''
remote_manifest_sha='' remote_token_sha='' published_marker_sha=''
acceptance_deployment_marker_sha=''
released_marker=0 recovery_required=0 recovery_running=0 recovery_finished=0 original_failure=1
phase=INIT
runtime_recovery_state=''

usage() {
    printf '%s\n' \
        'Usage: coordinated-v13-to-v2.sh [required artifact, marker, Windows, and evidence options]' \
        'See deploy/README.md for the reviewed cross-host transaction contract.'
}

die() { printf 'error: %s\n' "$*" >&2; return 1; }
coordinator_event() { : "$1"; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }
require_value() { [[ -n ${2-} ]] || die "$1 requires a value"; }
require_sha256() { [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "$1 must be a lowercase SHA-256"; }
require_uuid() {
    [[ $2 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
       $2 != 00000000-0000-0000-0000-000000000000 ]] || die "$1 must be a canonical non-zero UUID"
}
require_u64() { [[ $2 =~ ^[1-9][0-9]{0,19}$ ]] || die "$1 must be a non-zero decimal u64"; }

while (($#)); do
    case $1 in
        --viewflow-candidate) require_value "$1" "${2-}"; viewflow_candidate=$2; shift 2 ;;
        --viewflow-sha256) require_value "$1" "${2-}"; viewflow_sha=$2; shift 2 ;;
        --deployment-marker-candidate) require_value "$1" "${2-}"; deployment_marker_candidate=$2; shift 2 ;;
        --deployment-marker-sha256) require_value "$1" "${2-}"; deployment_marker_sha=$2; shift 2 ;;
        --deskflow-candidate) require_value "$1" "${2-}"; deskflow_candidate=$2; shift 2 ;;
        --deskflow-sha256) require_value "$1" "${2-}"; deskflow_sha=$2; shift 2 ;;
        --deskflow-core-candidate) require_value "$1" "${2-}"; deskflow_core_candidate=$2; shift 2 ;;
        --deskflow-core-sha256) require_value "$1" "${2-}"; deskflow_core_sha=$2; shift 2 ;;
        --deskflow-acceptance-producer-sha256) require_value "$1" "${2-}"; deskflow_acceptance_producer_sha=$2; shift 2 ;;
        --viewflow-acceptance-recorder-sha256) require_value "$1" "${2-}"; viewflow_acceptance_recorder_sha=$2; shift 2 ;;
        --deskflow-provenance-manifest) require_value "$1" "${2-}"; deskflow_provenance_manifest=$2; shift 2 ;;
        --deskflow-provenance-sha256) require_value "$1" "${2-}"; deskflow_provenance_sha=$2; shift 2 ;;
        --viewflow-unit-candidate) require_value "$1" "${2-}"; viewflow_unit_candidate=$2; shift 2 ;;
        --viewflow-unit-sha256) require_value "$1" "${2-}"; viewflow_unit_sha=$2; shift 2 ;;
        --deskflow-dropin-candidate) require_value "$1" "${2-}"; deskflow_dropin_candidate=$2; shift 2 ;;
        --deskflow-dropin-sha256) require_value "$1" "${2-}"; deskflow_dropin_sha=$2; shift 2 ;;
        --operation-id) require_value "$1" "${2-}"; operation_id=$2; shift 2 ;;
        --coordinator-instance-id) require_value "$1" "${2-}"; coordinator_instance_id=$2; shift 2 ;;
        --marker-generation) require_value "$1" "${2-}"; marker_generation=$2; shift 2 ;;
        --recovery-marker-generation) require_value "$1" "${2-}"; recovery_marker_generation=$2; shift 2 ;;
        --source-display-id) require_value "$1" "${2-}"; source_display_id=$2; shift 2 ;;
        --target-device-id) require_value "$1" "${2-}"; target_device_id=$2; shift 2 ;;
        --deployment-publish-receipt) require_value "$1" "${2-}"; deployment_publish_receipt=$2; shift 2 ;;
        --recovery-deployment-publish-receipt) require_value "$1" "${2-}"; recovery_deployment_publish_receipt=$2; shift 2 ;;
        --deployment-release-receipt) require_value "$1" "${2-}"; deployment_release_receipt=$2; shift 2 ;;
        --cpp-status-response) require_value "$1" "${2-}"; cpp_status_response=$2; shift 2 ;;
        --cpp-arm-response) require_value "$1" "${2-}"; cpp_arm_response=$2; shift 2 ;;
        --cpp-cleanup-receipt) require_value "$1" "${2-}"; cpp_cleanup_receipt=$2; shift 2 ;;
        --rust-acceptance-arm-response) require_value "$1" "${2-}"; rust_acceptance_arm_response=$2; shift 2 ;;
        --rust-acceptance-query-response) require_value "$1" "${2-}"; rust_acceptance_query_response=$2; shift 2 ;;
        --post-release-receipt) require_value "$1" "${2-}"; post_release_receipt=$2; shift 2 ;;
        --windows-restart-receipt) require_value "$1" "${2-}"; windows_restart_receipt=$2; shift 2 ;;
        --acceptance-timeout-seconds) require_value "$1" "${2-}"; acceptance_timeout_seconds=$2; shift 2 ;;
        --linux-host-proof) require_value "$1" "${2-}"; linux_host_proof=$2; shift 2 ;;
        --bootstrap-linux-evidence) require_value "$1" "${2-}"; bootstrap_linux_evidence=$2; shift 2 ;;
        --bootstrap-handoff-receipt) require_value "$1" "${2-}"; bootstrap_handoff_receipt=$2; shift 2 ;;
        --windows-bootstrap-request) require_value "$1" "${2-}"; windows_bootstrap_request=$2; shift 2 ;;
        --windows-prepared-receipt) require_value "$1" "${2-}"; windows_prepared_receipt=$2; shift 2 ;;
        --windows-mutation-permit) require_value "$1" "${2-}"; windows_mutation_permit=$2; shift 2 ;;
        --windows-force-release-envelope) require_value "$1" "${2-}"; windows_force_envelope=$2; shift 2 ;;
        --linux-stage-receipt) require_value "$1" "${2-}"; linux_stage_receipt=$2; shift 2 ;;
        --linux-finalize-receipt) require_value "$1" "${2-}"; linux_finalize_receipt=$2; shift 2 ;;
        --windows-installer-exit-receipt) require_value "$1" "${2-}"; windows_installer_exit_receipt=$2; shift 2 ;;
        --coordinator-state) require_value "$1" "${2-}"; coordinator_state=$2; shift 2 ;;
        --windows-viewflow-candidate) require_value "$1" "${2-}"; windows_viewflow_candidate=$2; shift 2 ;;
        --windows-wrapper-candidate) require_value "$1" "${2-}"; windows_wrapper_candidate=$2; shift 2 ;;
        --windows-launcher-candidate) require_value "$1" "${2-}"; windows_launcher_candidate=$2; shift 2 ;;
        --windows-launcher-sha256) require_value "$1" "${2-}"; windows_launcher_sha=$2; shift 2 ;;
        --windows-installer-candidate) require_value "$1" "${2-}"; windows_installer_candidate=$2; shift 2 ;;
        --windows-installer-sha256) require_value "$1" "${2-}"; windows_installer_sha=$2; shift 2 ;;
        --windows-rollback-script-sha256) require_value "$1" "${2-}"; windows_rollback_script_sha=$2; shift 2 ;;
        --bootstrap-timeout-seconds) require_value "$1" "${2-}"; bootstrap_timeout_seconds=$2; shift 2 ;;
        --resume) resume=1; shift ;;
        --resume-pre-mutation-stop-intent) resume_pre_mutation_stop_intent=1; resume=1; shift ;;
        --pre-mutation-old-executable-sha256) require_value "$1" "${2-}"; pre_mutation_old_executable_sha=$2; shift 2 ;;
        --pre-mutation-old-wrapper-sha256) require_value "$1" "${2-}"; pre_mutation_old_wrapper_sha=$2; shift 2 ;;
        --pre-mutation-old-task-xml-sha256) require_value "$1" "${2-}"; pre_mutation_old_task_xml_sha=$2; shift 2 ;;
        --pre-mutation-old-process-id) require_value "$1" "${2-}"; pre_mutation_old_process_id=$2; shift 2 ;;
        --pre-mutation-old-parent-process-id) require_value "$1" "${2-}"; pre_mutation_old_parent_process_id=$2; shift 2 ;;
        --pre-mutation-old-process-creation-date) require_value "$1" "${2-}"; pre_mutation_old_process_creation_date=$2; shift 2 ;;
        --pre-mutation-stop-state-baseline-fd-path|--pre-mutation-stop-state-baseline-path) require_value "$1" "${2-}"; pre_mutation_stop_state_baseline_path=$2; shift 2 ;;
        --pre-mutation-stop-state-baseline-sha256) require_value "$1" "${2-}"; pre_mutation_stop_state_baseline_sha=$2; shift 2 ;;
        --bootstrap-windows-force-receipt) require_value "$1" "${2-}"; bootstrap_windows_force_receipt=$2; shift 2 ;;
        --bootstrap-windows-install-receipt) require_value "$1" "${2-}"; bootstrap_windows_install_receipt=$2; shift 2 ;;
        --windows-viewflow-sha256) require_value "$1" "${2-}"; windows_viewflow_sha=$2; shift 2 ;;
        --windows-wrapper-sha256) require_value "$1" "${2-}"; windows_wrapper_sha=$2; shift 2 ;;
        --windows-task-xml-sha256) require_value "$1" "${2-}"; windows_task_xml_sha=$2; shift 2 ;;
        --windows-user-sid) require_value "$1" "${2-}"; windows_user_sid=$2; shift 2 ;;
        --windows-readiness-receipt-path) require_value "$1" "${2-}"; windows_readiness_receipt_path=$2; shift 2 ;;
        --windows-readiness-lock-path) require_value "$1" "${2-}"; windows_readiness_lock_path=$2; shift 2 ;;
        --windows-rollback-manifest-path) require_value "$1" "${2-}"; windows_rollback_manifest_path=$2; shift 2 ;;
        --windows-rollback-token-path) require_value "$1" "${2-}"; windows_rollback_token_path=$2; shift 2 ;;
        --windows-recovery-bundle-path) require_value "$1" "${2-}"; windows_recovery_bundle_path=$2; shift 2 ;;
        --windows-recovery-force-receipt-path) require_value "$1" "${2-}"; windows_recovery_force_receipt_path=$2; shift 2 ;;
        --windows-rollback-receipt-path) require_value "$1" "${2-}"; windows_rollback_receipt_path=$2; shift 2 ;;
        --linux-deactivation-transcript) require_value "$1" "${2-}"; linux_deactivation_transcript=$2; shift 2 ;;
        --linux-deactivation-proof) require_value "$1" "${2-}"; linux_deactivation_proof=$2; shift 2 ;;
        --linux-containment-transcript) require_value "$1" "${2-}"; linux_containment_transcript=$2; shift 2 ;;
        --local-windows-validation) require_value "$1" "${2-}"; local_windows_validation=$2; shift 2 ;;
        --local-windows-rollback-receipt) require_value "$1" "${2-}"; local_windows_rollback_receipt=$2; shift 2 ;;
        --normal-runtime-receipt) require_value "$1" "${2-}"; normal_runtime_receipt=$2; shift 2 ;;
        --normal-daemon-exit-evidence) require_value "$1" "${2-}"; normal_daemon_exit_evidence=$2; shift 2 ;;
        --normal-daemon-exit-observation) require_value "$1" "${2-}"; normal_daemon_exit_observation=$2; shift 2 ;;
        --candidate-retirement-terminal) require_value "$1" "${2-}"; candidate_retirement_terminal=$2; shift 2 ;;
        --candidate-retirement-terminal-sha256) require_value "$1" "${2-}"; candidate_retirement_terminal_sha=$2; shift 2 ;;
        --candidate-replacement-commit) require_value "$1" "${2-}"; candidate_replacement_commit=$2; shift 2 ;;
        --candidate-replacement-commit-sha256) require_value "$1" "${2-}"; candidate_replacement_commit_sha=$2; shift 2 ;;
        --coordinator-successor-receipt) require_value "$1" "${2-}"; coordinator_successor_receipt=$2; shift 2 ;;
        --coordinator-successor-receipt-sha256) require_value "$1" "${2-}"; coordinator_successor_receipt_sha=$2; shift 2 ;;
        --abort-failed-v13) abort_failed_v13=1; shift ;;
        --abort-failed-v13-pre-mutation) abort_failed_v13_pre_mutation=1; shift ;;
        --pre-mutation-abort-marker-cli-candidate) require_value "$1" "${2-}"; pre_mutation_abort_marker_cli_candidate=$2; shift 2 ;;
        --pre-mutation-abort-marker-cli-sha256) require_value "$1" "${2-}"; pre_mutation_abort_marker_cli_sha=$2; shift 2 ;;
        --pre-mutation-windows-live-proof) require_value "$1" "${2-}"; pre_mutation_windows_live_proof=$2; shift 2 ;;
        --attempt3-slot-cleanup-receipt) require_value "$1" "${2-}"; attempt3_slot_cleanup_receipt=$2; shift 2 ;;
        --attempt3-slot-cleanup-receipt-sha256) require_value "$1" "${2-}"; attempt3_slot_cleanup_receipt_sha=$2; shift 2 ;;
        --fresh-operation-lineage-receipt) require_value "$1" "${2-}"; fresh_operation_lineage_receipt=$2; shift 2 ;;
        --fresh-operation-lineage-receipt-sha256) require_value "$1" "${2-}"; fresh_operation_lineage_receipt_sha=$2; shift 2 ;;
        --schema1-handoff-lineage-receipt) require_value "$1" "${2-}"; schema1_handoff_lineage_receipt=$2; shift 2 ;;
        --schema1-handoff-lineage-receipt-sha256) require_value "$1" "${2-}"; schema1_handoff_lineage_receipt_sha=$2; shift 2 ;;
        --schema1-handoff-abort-marker-cli-candidate) require_value "$1" "${2-}"; schema1_handoff_abort_marker_cli_candidate=$2; shift 2 ;;
        --schema1-handoff-abort-marker-cli-sha256) require_value "$1" "${2-}"; schema1_handoff_abort_marker_cli_sha=$2; shift 2 ;;
        --post-force-abort-marker-cli-candidate) require_value "$1" "${2-}"; post_force_abort_marker_cli_candidate=$2; shift 2 ;;
        --post-force-abort-marker-cli-sha256) require_value "$1" "${2-}"; post_force_abort_marker_cli_sha=$2; shift 2 ;;
        --failed-v13-original-generation-only) failed_v13_original_generation_only=1; shift ;;
        --old-coordinator-state-sha256) require_value "$1" "${2-}"; old_coordinator_state_sha=$2; shift 2 ;;
        --deployment-abort-authorization) require_value "$1" "${2-}"; deployment_abort_authorization=$2; shift 2 ;;
        --deployment-abort-receipt) require_value "$1" "${2-}"; deployment_abort_receipt=$2; shift 2 ;;
        --failed-v13-abort-transition-receipt) require_value "$1" "${2-}"; failed_v13_abort_transition_receipt=$2; shift 2 ;;
        --linux-v13-started-receipt) require_value "$1" "${2-}"; linux_v13_started_receipt=$2; shift 2 ;;
        --windows-v13-started-receipt) require_value "$1" "${2-}"; windows_v13_started_receipt=$2; shift 2 ;;
        --authenticated-v13-peer-receipt) require_value "$1" "${2-}"; authenticated_v13_peer_receipt=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

replacement_flag_count=0
for replacement_value in "$candidate_retirement_terminal" "$candidate_retirement_terminal_sha" \
    "$candidate_replacement_commit" "$candidate_replacement_commit_sha"; do
    [[ -z $replacement_value ]] || ((replacement_flag_count += 1))
done
((replacement_flag_count == 0 || replacement_flag_count == 4)) ||
    die 'candidate replacement options must be supplied all-or-none'
if ((replacement_flag_count != 0 && (abort_failed_v13 || abort_failed_v13_pre_mutation))); then
    die 'candidate replacement options are valid only for the normal coordinator path'
fi
successor_flag_count=0
for successor_value in "$coordinator_successor_receipt" "$coordinator_successor_receipt_sha"; do
    [[ -z $successor_value ]] || ((successor_flag_count += 1))
done
((successor_flag_count == 0 || successor_flag_count == 2)) ||
    die 'coordinator successor options must be supplied all-or-none'
if ((successor_flag_count != 0 && (abort_failed_v13 || abort_failed_v13_pre_mutation))); then
    die 'coordinator successor options are valid only for the normal coordinator path'
fi
((successor_flag_count == 0 || replacement_flag_count == 4)) ||
    die 'coordinator successor authorization requires the complete candidate replacement lineage'
if ((successor_flag_count == 0)) && [[ $operation_id =~ ^[0-9a-f]{32}$ && -n $coordinator_state ]]; then
    successor_operation_root=$(dirname -- "$coordinator_state")
    if [[ $successor_operation_root == "/home/wilf/.local/state/viewflow/deployments/${operation_id}" &&
          ( -e $successor_operation_root/coordinator-successor-receipt.json ||
            -L $successor_operation_root/coordinator-successor-receipt.json ) ]]; then
        die 'coordinator successor receipt exists but its two options are missing'
    fi
fi
if ((replacement_flag_count == 0)) && [[ $operation_id =~ ^[0-9a-f]{32}$ && -n $coordinator_state ]]; then
    replacement_operation_root=$(dirname -- "$coordinator_state")
    if [[ $replacement_operation_root == "/home/wilf/.local/state/viewflow/deployments/${operation_id}" &&
          ( -e $replacement_operation_root/candidate-retirement-terminal.json ||
            -L $replacement_operation_root/candidate-retirement-terminal.json ||
            -e $replacement_operation_root/candidate-replacement-commit.json ||
            -L $replacement_operation_root/candidate-replacement-commit.json ) ]]; then
        die 'candidate replacement evidence exists but the four replacement options are missing'
    fi
fi

require_windows_absolute_path() {
    [[ $2 =~ ^[A-Za-z]:\\[A-Za-z0-9_.()[:space:]\\-]+$ ]] || die "$1 must be a safely quoted absolute Windows path"
}

windows_fixed_leaf() {
    local path=$1 leaf
    leaf=${path##*\\}
    if [[ $path != "$windows_operation_root\\$leaf" || ! $leaf =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
        die 'fixed Windows operation-root leaf is invalid'
        return 1
    fi
    printf '%s\n' "$leaf"
}

# The deactivator records the basename of --transcript-output in the bootstrap
# proof. Windows pins the matching remote transport leaf, so a caller-selected
# basename would make a valid-looking proof impossible for the rollback
# manifest to consume. Reject it before state, host contact, or publication.
require_bootstrap_deactivation_transport_leaf() {
    local leaf
    leaf=$(basename -- "$linux_deactivation_transcript")
    [[ $leaf == linux-deactivation-transcript.json ]] ||
        die '--linux-deactivation-transcript basename must be linux-deactivation-transcript.json'
}

require_absolute_input() {
    [[ $2 == /* && -f $2 && ! -L $2 ]] || die "$1 must be an absolute regular non-symlink file"
}

require_absolute_new_output() {
    local label=$1 path=$2 parent
    [[ $path == /* && ! -e $path && ! -L $path ]] || die "$label must be an unused absolute path"
    parent=$(dirname -- "$path")
    [[ -d $parent && ! -L $parent && $(stat -c '%u' -- "$parent") == 1000 ]] || die "$label parent is unsafe"
    (( (8#$(stat -c '%a' -- "$parent") & 8#077) == 0 )) || die "$label parent must be owner-only"
}

validate_candidate_replacement_lineage() {
    local operation_root candidate_root rejected_root expected_terminal expected_commit coordinator_source values check_state_absent
    operation_root=$(dirname -- "$coordinator_state")
    candidate_root="/home/wilf/.local/state/viewflow/candidates/v21-operation-${operation_id}"
    rejected_root=/home/wilf/.local/state/viewflow/candidates/rejected
    expected_terminal="$operation_root/candidate-retirement-terminal.json"
    expected_commit="$operation_root/candidate-replacement-commit.json"
    candidate_manifest_path="$candidate_root/candidate-manifest.json"
    if ((replacement_flag_count == 0)); then
        [[ ! -e $expected_terminal && ! -L $expected_terminal &&
           ! -e $expected_commit && ! -L $expected_commit ]] ||
            die 'candidate replacement evidence exists but the four replacement options are missing'
        candidate_manifest_sha=''
        candidate_tree_sha=''
        return 0
    fi
    [[ $candidate_retirement_terminal == "$expected_terminal" &&
       $candidate_replacement_commit == "$expected_commit" ]] ||
        die 'candidate replacement evidence paths are not canonical for this operation'
    require_sha256 '--candidate-retirement-terminal-sha256' "$candidate_retirement_terminal_sha"
    require_sha256 '--candidate-replacement-commit-sha256' "$candidate_replacement_commit_sha"
    if ((successor_flag_count == 2)); then
        [[ $coordinator_successor_receipt == "$operation_root/coordinator-successor-receipt.json" ]] ||
            die 'coordinator successor receipt path is not canonical for this operation'
        require_sha256 '--coordinator-successor-receipt-sha256' "$coordinator_successor_receipt_sha"
    fi
    coordinator_source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
    check_state_absent=0
    ((candidate_replacement_initial_gate_complete == 0 && resume == 0)) && check_state_absent=1
    values=$(python3 - "$candidate_retirement_terminal" "$candidate_retirement_terminal_sha" \
        "$candidate_replacement_commit" "$candidate_replacement_commit_sha" "$operation_id" \
        "$coordinator_instance_id" "$operation_root" "$candidate_root" "$rejected_root" \
        "$coordinator_state" "$coordinator_source" "$DEPLOYMENT_MARKER" "$MARKER_CLI" \
        "$deployment_publish_receipt" "$bootstrap_handoff_receipt" "$bootstrap_linux_evidence" \
        "$viewflow_candidate" "$viewflow_sha" "$deployment_marker_candidate" "$deployment_marker_sha" \
        "$viewflow_unit_candidate" "$viewflow_unit_sha" "$deskflow_dropin_candidate" "$deskflow_dropin_sha" \
        "$deskflow_provenance_manifest" "$deskflow_provenance_sha" "$deskflow_candidate" "$deskflow_sha" \
        "$deskflow_core_candidate" "$deskflow_core_sha" "$windows_viewflow_candidate" "$windows_viewflow_sha" \
        "$windows_wrapper_candidate" "$windows_wrapper_sha" "$windows_launcher_candidate" "$windows_launcher_sha" \
        "$windows_installer_candidate" "$windows_installer_sha" "$reviewed_rollback_script" \
        "$windows_rollback_script_sha" "$windows_task_xml_sha" "$windows_user_sid" "$check_state_absent" \
        "$successor_flag_count" "$coordinator_successor_receipt" "$coordinator_successor_receipt_sha" \
        "$WINDOWS_SSH_TARGET" "$windows_operation_root" <<'PY'
import calendar,datetime,hashlib,json,os,re,stat,sys
(
 terminal,terminal_expected,commit,commit_expected,op,coord,operation_root,candidate_root,rejected_root,
 coordinator_state,coordinator_source,active_marker,installed_marker_cli,publish,handoff,frozen,
 viewflow,viewflow_sha,marker_cli,marker_cli_sha,unit,unit_sha,dropin,dropin_sha,
 deskflow_provenance,deskflow_provenance_sha,deskflow,deskflow_sha,deskflow_core,deskflow_core_sha,
 windows_viewflow,windows_viewflow_sha,windows_wrapper,windows_wrapper_sha,windows_launcher,windows_launcher_sha,
 windows_installer,windows_installer_sha,rollback,rollback_sha,task_xml_sha,windows_sid,check_state_absent,
 successor_count,successor_receipt,successor_receipt_expected,windows_ssh_target,windows_operation_root
)=sys.argv[1:]
HEX=re.compile(r"[0-9a-f]{64}\Z"); UUID=re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
UTC=re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")
EXACT6=("candidate-manifest.json","windows-native-provenance.json","windows-source.manifest.sha256",
        "windows-source.tar.gz","windows-source.tar.gz.sha256","windows-viewflowd.exe")
MODES={name:(0o700 if name=="windows-viewflowd.exe" else 0o600) for name in EXACT6}
def die(message): raise SystemExit("error: candidate replacement: "+message)
def req(ok,message):
 if not ok: die(message)
def pairs(items):
 out={}
 for key,value in items:
  if key in out: die("duplicate JSON key "+repr(key))
  out[key]=value
 return out
def bad_number(value): die("floating/non-finite JSON number "+value)
def secure(path,mode=None,owner=1000,links=None):
 try: fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 except OSError as exc: die("cannot O_NOFOLLOW open "+path+": "+str(exc))
 try:
  before=os.fstat(fd)
  req(stat.S_ISREG(before.st_mode),"not a regular file "+path)
  req(before.st_uid==owner,"owner differs "+path)
  if mode is not None: req(stat.S_IMODE(before.st_mode)==mode,"mode differs "+path)
  if links is not None: req(before.st_nlink==links,"link count differs "+path)
  data=bytearray()
  while True:
   chunk=os.read(fd,1048576)
   if not chunk: break
   data.extend(chunk)
  after=os.fstat(fd)
 finally: os.close(fd)
 identity=lambda x:(x.st_dev,x.st_ino,x.st_size,x.st_uid,stat.S_IMODE(x.st_mode),x.st_nlink,x.st_mtime_ns)
 req(identity(before)==identity(after),"descriptor changed while read "+path)
 try: named=os.lstat(path)
 except OSError as exc: die("cannot re-stat "+path+": "+str(exc))
 req(not stat.S_ISLNK(named.st_mode) and identity(named)==identity(after),"path changed while read "+path)
 return bytes(data),hashlib.sha256(data).hexdigest(),after
def document(path,label):
 data,digest,_=secure(path,0o600,1000,1)
 try:
  text=data.decode("utf-8","strict"); decoder=json.JSONDecoder(object_pairs_hook=pairs,parse_float=bad_number,parse_constant=bad_number)
  start=0
  while start<len(text) and text[start] in " \t\r\n": start+=1
  value,end=decoder.raw_decode(text,start)
  tail=end
  while tail<len(text) and text[tail] in " \t\r\n": tail+=1
  req(tail==len(text),label+" has trailing JSON data")
  req(type(value) is dict,label+" root is not an object")
 except (UnicodeDecodeError,json.JSONDecodeError) as exc: die("invalid "+label+": "+str(exc))
 return value,digest
def keys(value,want,label): req(type(value) is dict and list(value)==want,label+" unknown/reordered keys")
def sha(value,label): req(type(value) is str and HEX.fullmatch(value) is not None,label+" is not lowercase SHA-256")
def path(value,label): req(type(value) is str and value.startswith("/"),label+" is not an absolute path")
def timestamp(value,label):
 unix_ms=value.get("created_at_unix_ms"); utc=value.get("created_at_utc")
 req(type(unix_ms) is int and unix_ms>0 and type(utc) is str and UTC.fullmatch(utc) is not None,label+" timestamp shape differs")
 try: seconds=calendar.timegm(datetime.datetime.strptime(utc[:19],"%Y-%m-%dT%H:%M:%S").timetuple())
 except (ValueError,OverflowError) as exc: die(label+" timestamp is invalid: "+str(exc))
 expected=seconds*1000+int(utc[20:23])
 req(unix_ms==expected,label+" UTC/unix_ms equality differs")
def named_timestamp(value,unix_key,utc_key,label):
 unix_ms=value.get(unix_key); utc=value.get(utc_key)
 req(type(unix_ms) is int and unix_ms>0 and type(utc) is str and UTC.fullmatch(utc) is not None,label+" timestamp shape differs")
 try: seconds=calendar.timegm(datetime.datetime.strptime(utc[:19],"%Y-%m-%dT%H:%M:%S").timetuple())
 except (ValueError,OverflowError) as exc: die(label+" timestamp is invalid: "+str(exc))
 req(unix_ms==seconds*1000+int(utc[20:23]),label+" UTC/unix_ms equality differs")
def directory(value,expected,label):
 req(value==expected,label+" path differs")
 try: meta=os.lstat(value)
 except OSError as exc: die("missing "+label+": "+str(exc))
 req(stat.S_ISDIR(meta.st_mode) and not stat.S_ISLNK(meta.st_mode) and meta.st_uid==1000 and
     stat.S_IMODE(meta.st_mode)==0o700,label+" metadata differs")
def actual_sha(path_value,expected,label,mode=None,links=None):
 sha(expected,label+" sha256"); _,digest,_=secure(path_value,mode,1000,links); req(digest==expected,label+" bytes differ")
def tree(root,label):
 try: entries=sorted(os.scandir(root),key=lambda item:item.name)
 except OSError as exc: die("cannot scan "+label+": "+str(exc))
 req(tuple(item.name for item in entries)==EXACT6,label+" is not exact6")
 rows=[]; records=[]
 for item in entries:
  req(not item.is_symlink(),label+" contains symlink "+item.name)
  data,digest,meta=secure(item.path,MODES[item.name],1000,1)
  mode=format(stat.S_IMODE(meta.st_mode),"04o")
  rows.append(item.name.encode()+b"\0"+mode.encode()+b"\0"+str(len(data)).encode()+b"\0"+digest.encode()+b"\n")
  records.append({"name":item.name,"mode":mode,"size_bytes":len(data),"sha256":digest})
 return hashlib.sha256(b"".join(rows)).hexdigest(),records
def fresh(value,label):
 want=["deployment_publish_path","deployment_publish_sha256","marker_handoff_path","marker_handoff_sha256",
       "linux_frozen_path","linux_frozen_sha256","deployment_marker_path","deployment_marker_sha256"]
 keys(value,want,label)
 closures=(("deployment_publish",publish),("marker_handoff",handoff),("linux_frozen",frozen),("deployment_marker",active_marker))
 for stem,expected_path in closures:
  req(value[stem+"_path"]==expected_path,label+" "+stem+" path differs")
  mode=0o600; actual_sha(expected_path,value[stem+"_sha256"],label+" "+stem,mode,1)
 return value
terminal_obj,terminal_sha=document(terminal,"retirement terminal")
commit_obj,commit_sha=document(commit,"replacement commit")
req(terminal_sha==terminal_expected,"retirement terminal option SHA differs")
req(commit_sha==commit_expected,"replacement commit option SHA differs")
TERM_KEYS=["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms",
 "created_at_utc","operation_root","candidate_root","old_candidate","fresh_boundary","authorized_seed","pre_retirement"]
keys(terminal_obj,TERM_KEYS,"retirement terminal")
req(terminal_obj["schema_version"]==1 and terminal_obj["state"]=="viewflow-normal-v21-candidate-retired","retirement terminal state differs")
req(terminal_obj["operation_id"]==op and terminal_obj["coordinator_instance_id"]==coord,"retirement terminal operation binding differs")
req(terminal_obj["replacement_ordinal"]==1,"retirement terminal ordinal differs")
timestamp(terminal_obj,"retirement terminal")
req(terminal_obj["operation_root"]==operation_root and terminal_obj["candidate_root"]==candidate_root,"retirement terminal roots differ")
keys(terminal_obj["old_candidate"],["canonical_path","archive_path","manifest_sha256","tree_sha256","files"],"retirement old candidate")
old=terminal_obj["old_candidate"]; sha(old["manifest_sha256"],"old manifest"); sha(old["tree_sha256"],"old tree")
archive=rejected_root+"/v21-operation-"+op+".rejected-"+old["manifest_sha256"]
req(old["canonical_path"]==candidate_root and old["archive_path"]==archive,"old candidate paths differ")
directory(rejected_root,rejected_root,"rejected candidate root"); directory(archive,archive,"old candidate archive")
archive_tree,archive_records=tree(archive,"old candidate archive")
req(old["tree_sha256"]==archive_tree and old["files"]==archive_records,"old candidate exact6 tree/files differ")
req(old["manifest_sha256"]==archive_records[0]["sha256"],"old candidate manifest digest differs")
terminal_fresh=fresh(terminal_obj["fresh_boundary"],"retirement fresh boundary")
publish_obj,publish_sha=document(publish,"replacement deployment publish receipt")
keys(publish_obj,["coordinator_instance_id","created_at_unix_ms","created_at_utc","marker_generation","marker_path","marker_sha256",
     "operation_id","protocol_version","schema_version","source_display_id","state","target_device_id"],"replacement deployment publish receipt")
req(publish_obj["schema_version"]==1 and publish_obj["state"]=="deployment-quarantine-published" and
    publish_obj["protocol_version"]=="2.1" and publish_obj["operation_id"]==op and publish_obj["coordinator_instance_id"]==coord and
    publish_obj["marker_generation"]=="1" and publish_obj["source_display_id"]=="00000000-0000-0000-0000-000000000101" and
    publish_obj["target_device_id"]=="00000000-0000-0000-0000-000000000002","replacement publish operation boundary differs")
req(publish_obj["marker_path"]==active_marker and publish_obj["marker_sha256"]==terminal_fresh["deployment_marker_sha256"] and
    publish_sha==terminal_fresh["deployment_publish_sha256"],"replacement publish active-marker closure differs")
handoff_obj,handoff_sha=document(handoff,"replacement marker handoff")
keys(handoff_obj,["schema_version","state","protocol_version","operation_id","source_display_id","target_device_id","coordinator_instance_id",
     "marker_generation","marker_cli_path","marker_cli_sha256","deployment_marker_path","deployment_marker_sha256",
     "deployment_publish_receipt_path","deployment_publish_receipt_sha256","deskflow_unit","deskflow_unit_active_state",
     "deskflow_unit_main_pid","deskflow_executable_path","deskflow_executable_sha256","deskflow_exact_process_count",
     "deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_core_exact_process_count","deskflow_tcp_port",
     "deskflow_tcp_listener_count","runtime_marker_path","runtime_marker_present","observed_at_utc"],"replacement marker handoff")
req(handoff_obj["schema_version"]==1 and handoff_obj["state"]=="viewflow-v13-marker-handoff-prepared" and
    handoff_obj["protocol_version"]=="2.1" and handoff_obj["operation_id"]==op and handoff_obj["coordinator_instance_id"]==coord and
    handoff_obj["marker_generation"]=="1","replacement handoff operation boundary differs")
req(handoff_obj["deployment_marker_path"]==active_marker and handoff_obj["deployment_marker_sha256"]==publish_obj["marker_sha256"] and
    handoff_obj["deployment_publish_receipt_path"]==publish and handoff_obj["deployment_publish_receipt_sha256"]==publish_sha and
    handoff_sha==terminal_fresh["marker_handoff_sha256"],"replacement P-H marker closure differs")
req(handoff_obj["marker_cli_path"]==installed_marker_cli and handoff_obj["marker_cli_sha256"]==marker_cli_sha and
    handoff_obj["runtime_marker_present"] is False and handoff_obj["deskflow_unit"]=="deskflow.service" and
    handoff_obj["deskflow_unit_active_state"]=="inactive" and handoff_obj["deskflow_unit_main_pid"]==0 and
    handoff_obj["deskflow_tcp_port"]==24800 and handoff_obj["deskflow_tcp_listener_count"]==0 and
    handoff_obj["deskflow_exact_process_count"]==0 and handoff_obj["deskflow_core_exact_process_count"]==0,
    "replacement handoff is not quiesced")
actual_sha(installed_marker_cli,marker_cli_sha,"replacement installed marker CLI")
actual_sha(marker_cli,marker_cli_sha,"replacement candidate marker CLI")
frozen_obj,frozen_sha=document(frozen,"replacement Linux frozen evidence")
keys(frozen_obj,["schema_version","state","operation_id","daemon","journal","pre_stop","post_stop","completed_at_unix_ms"],"replacement Linux frozen evidence")
req(frozen_obj["schema_version"]==1 and frozen_obj["state"]=="viewflow-v13-bootstrap-frozen" and frozen_obj["operation_id"]==op and
    frozen_sha==terminal_fresh["linux_frozen_sha256"],"replacement frozen operation boundary differs")
req(frozen_obj["pre_stop"].get("deskflow_unit_active_state")=="inactive" and frozen_obj["pre_stop"].get("deskflow_main_pid")==0 and
    frozen_obj["pre_stop"].get("deskflow_exact_process_count")==0 and frozen_obj["pre_stop"].get("deskflow_core_exact_process_count")==0 and
    frozen_obj["pre_stop"].get("deskflow_tcp_24800_listener_count")==0 and frozen_obj["post_stop"].get("unit_active_state")=="inactive" and
    frozen_obj["post_stop"].get("main_pid")==0 and frozen_obj["post_stop"].get("exact_process_count")==0 and
    frozen_obj["post_stop"].get("sidecar_socket_present") is False and frozen_obj["post_stop"].get("udp_44119_listener_count")==0,
    "replacement frozen boundary is not quiesced")
keys(terminal_obj["authorized_seed"],["root","candidate_manifest_path","candidate_manifest_sha256"],"authorized seed")
seed=terminal_obj["authorized_seed"]; path(seed["root"],"authorized seed root"); path(seed["candidate_manifest_path"],"authorized seed manifest")
req(seed["candidate_manifest_path"]==seed["root"]+"/candidate-manifest.json","authorized seed manifest path differs")
directory(seed["root"],seed["root"],"authorized seed root"); actual_sha(seed["candidate_manifest_path"],seed["candidate_manifest_sha256"],"authorized seed manifest",0o600,1)
keys(terminal_obj["pre_retirement"],["coordinator_state_path","coordinator_state_absent","standard_normal_outputs_absent"],"pre-retirement")
pre=terminal_obj["pre_retirement"]
req(pre=={"coordinator_state_path":coordinator_state,"coordinator_state_absent":True,"standard_normal_outputs_absent":True},"pre-retirement closure differs")
if check_state_absent=="1": req(not os.path.lexists(coordinator_state),"coordinator state existed before first replacement validation")
COMMIT_KEYS=["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms",
 "created_at_utc","operation_root","candidate_root","candidate_manifest_path","candidate_manifest_sha256","candidate_tree_sha256",
 "retirement_terminal_path","retirement_terminal_sha256","old_candidate_archive_path","old_candidate_manifest_sha256",
 "authorized_seed_manifest_sha256","fresh_boundary"]
keys(commit_obj,COMMIT_KEYS,"replacement commit")
req(commit_obj["schema_version"]==1 and commit_obj["state"]=="viewflow-normal-v21-candidate-replacement-committed","replacement commit state differs")
req(commit_obj["operation_id"]==op and commit_obj["coordinator_instance_id"]==coord and commit_obj["replacement_ordinal"]==1,"replacement commit operation binding differs")
timestamp(commit_obj,"replacement commit")
req(commit_obj["operation_root"]==operation_root and commit_obj["candidate_root"]==candidate_root and
    commit_obj["candidate_manifest_path"]==candidate_root+"/candidate-manifest.json","replacement commit roots differ")
req(commit_obj["retirement_terminal_path"]==terminal and commit_obj["retirement_terminal_sha256"]==terminal_sha and
    commit_obj["old_candidate_archive_path"]==archive and commit_obj["old_candidate_manifest_sha256"]==old["manifest_sha256"] and
    commit_obj["authorized_seed_manifest_sha256"]==seed["candidate_manifest_sha256"],"replacement commit lineage differs")
req(commit_obj["fresh_boundary"]==terminal_fresh,"replacement commit fresh boundary differs")
directory(candidate_root,candidate_root,"current candidate root")
candidate_tree,candidate_records=tree(candidate_root,"current candidate")
manifest_obj,manifest_sha=document(candidate_root+"/candidate-manifest.json","schema2 candidate manifest")
req(commit_obj["candidate_manifest_sha256"]==manifest_sha and commit_obj["candidate_tree_sha256"]==candidate_tree,"replacement commit current tree differs")
TOP=["schema_version","kind","operation_id","coordinator_instance_id","protocol_version","sidecar_protocol_version","marker_generation",
 "recovery_marker_generation","source_display_id","target_device_id","fresh_boundary","candidate_replacement","coordinator","linux_rust","linux_deskflow","windows"]
keys(manifest_obj,TOP,"schema2 candidate manifest")
req(manifest_obj["schema_version"]==2 and manifest_obj["kind"]=="viewflow-v21-cross-host-candidate-set","schema2 candidate version differs")
req(manifest_obj["operation_id"]==op and manifest_obj["coordinator_instance_id"]==coord and manifest_obj["protocol_version"]=="2.1" and
    manifest_obj["sidecar_protocol_version"]==3 and manifest_obj["marker_generation"]==1 and manifest_obj["recovery_marker_generation"]==2 and
    manifest_obj["source_display_id"]=="00000000-0000-0000-0000-000000000101" and
    manifest_obj["target_device_id"]=="00000000-0000-0000-0000-000000000002","schema2 candidate identity differs")
keys(manifest_obj["fresh_boundary"],["root","deployment_publish_receipt_sha256","marker_handoff_sha256","linux_frozen_sha256","deployment_marker","deployment_marker_sha256"],"candidate fresh boundary")
mf=manifest_obj["fresh_boundary"]
req(mf=={"root":operation_root,"deployment_publish_receipt_sha256":terminal_fresh["deployment_publish_sha256"],
         "marker_handoff_sha256":terminal_fresh["marker_handoff_sha256"],"linux_frozen_sha256":terminal_fresh["linux_frozen_sha256"],
         "deployment_marker":active_marker,"deployment_marker_sha256":terminal_fresh["deployment_marker_sha256"]},"candidate fresh boundary closure differs")
keys(manifest_obj["candidate_replacement"],["retirement_terminal_path","retirement_terminal_sha256","old_candidate_manifest_sha256",
     "replacement_ordinal","authorized_seed_manifest_sha256"],"candidate replacement")
req(manifest_obj["candidate_replacement"]=={"retirement_terminal_path":terminal,"retirement_terminal_sha256":terminal_sha,
    "old_candidate_manifest_sha256":old["manifest_sha256"],"replacement_ordinal":1,
    "authorized_seed_manifest_sha256":seed["candidate_manifest_sha256"]},"candidate replacement binding differs")
keys(manifest_obj["coordinator"],["entrypoint","entrypoint_sha256","source_provenance","source_provenance_sha256"],"candidate coordinator")
co=manifest_obj["coordinator"]
successor_values=["-"]*11
if successor_count=="2":
 req(successor_receipt==operation_root+"/coordinator-successor-receipt.json","coordinator successor receipt path is not canonical")
 successor_obj,successor_sha=document(successor_receipt,"coordinator successor receipt")
 req(successor_sha==successor_receipt_expected,"coordinator successor receipt option SHA differs")
 keys(successor_obj,["schema_version","state","operation_id","coordinator_instance_id","replacement_ordinal","created_at_unix_ms","created_at_utc",
      "operation_root","receipt_path","predecessor","marker_cli_alias_override","successor","absence","windows_prestate"],"coordinator successor receipt")
 req(successor_obj["schema_version"]==1 and successor_obj["state"]=="viewflow-normal-v21-coordinator-successor-authorized" and
     successor_obj["operation_id"]==op and successor_obj["coordinator_instance_id"]==coord and successor_obj["replacement_ordinal"]==1,
     "coordinator successor receipt identity differs")
 timestamp(successor_obj,"coordinator successor receipt")
 req(successor_obj["operation_root"]==operation_root and successor_obj["receipt_path"]==successor_receipt,
     "coordinator successor receipt roots differ")
 def artifact(value,expected_path,expected_sha,label):
  keys(value,["path","sha256"],label); req(value["path"]==expected_path and value["sha256"]==expected_sha,label+" binding differs")
  actual_sha(expected_path,expected_sha,label)
 pred=successor_obj["predecessor"]
 keys(pred,["deployment_publish","marker_handoff","linux_frozen","retirement_terminal","replacement_commit","candidate_manifest",
      "candidate_tree_sha256","launcher","coordinator"],"coordinator successor predecessor")
 artifact(pred["deployment_publish"],publish,publish_sha,"successor predecessor publish")
 artifact(pred["marker_handoff"],handoff,handoff_sha,"successor predecessor handoff")
 artifact(pred["linux_frozen"],frozen,frozen_sha,"successor predecessor frozen")
 artifact(pred["retirement_terminal"],terminal,terminal_sha,"successor predecessor retirement terminal")
 artifact(pred["replacement_commit"],commit,commit_sha,"successor predecessor replacement commit")
 artifact(pred["candidate_manifest"],candidate_root+"/candidate-manifest.json",manifest_sha,"successor predecessor candidate manifest")
 req(pred["candidate_tree_sha256"]==candidate_tree,"successor predecessor candidate tree differs")
 artifact(pred["launcher"],operation_root+"/launch-normal-v21.sh",pred["launcher"].get("sha256"),"successor predecessor launcher")
 keys(pred["coordinator"],["path","sha256","provenance_path","provenance_sha256"],"successor predecessor coordinator")
 pc=pred["coordinator"]
 req(pc=={"path":co["entrypoint"],"sha256":co["entrypoint_sha256"],"provenance_path":co["source_provenance"],
         "provenance_sha256":co["source_provenance_sha256"]},"successor predecessor manifest coordinator differs")
 actual_sha(pc["path"],pc["sha256"],"successor predecessor coordinator")
 actual_sha(pc["provenance_path"],pc["provenance_sha256"],"successor predecessor provenance")
 alias=successor_obj["marker_cli_alias_override"]
 keys(alias,["kind","only_handoff_field","historical_path","candidate_path","sha256"],"successor marker CLI alias")
 req(alias=={"kind":"marker-cli-path-alias-same-bytes-v1","only_handoff_field":"marker_cli_path","historical_path":installed_marker_cli,
             "candidate_path":marker_cli,"sha256":marker_cli_sha},"successor marker CLI alias differs")
 req(marker_cli_sha=="e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5",
     "successor marker CLI alias SHA is not the reviewed v3 candidate")
 succ=successor_obj["successor"]
 keys(succ,["coordinator_path","coordinator_sha256","provenance_path","provenance_sha256","receipt_producer_path","receipt_producer_sha256"],
      "coordinator successor")
 req(succ["coordinator_path"]==coordinator_source,"successor does not authorize the executing coordinator")
 req(pc["path"]!=succ["coordinator_path"] and pc["sha256"]!=succ["coordinator_sha256"],
     "successor receipt does not cross a distinct coordinator generation")
 actual_sha(succ["coordinator_path"],succ["coordinator_sha256"],"successor coordinator")
 actual_sha(succ["provenance_path"],succ["provenance_sha256"],"successor provenance")
 actual_sha(succ["receipt_producer_path"],succ["receipt_producer_sha256"],"successor receipt producer")
 absence=successor_obj["absence"]
 keys(absence,["coordinator_state_path","coordinator_state_absent","normal_output_leaves","normal_outputs_absent","pre_receipt_operation_leaves"],
      "coordinator successor absence")
 req(absence["coordinator_state_path"]==coordinator_state and absence["coordinator_state_absent"] is True and
     absence["normal_outputs_absent"] is True,"coordinator successor absence claims differ")
 normal_leaves=["coordinator-state.json","coordinator-state.json.pre-mutation-retry.json","coordinator-state.json.pre-mutation-start-intent.v1.json",
  "coordinator-state.json.pre-mutation-stop-claim.v1","coordinator-state.json.recovery-bundle.json","coordinator-state.json.windows-restart-intent.json",
  "coordinator-state.json.windows-stop-evidence.json","cpp-arm-response.json","cpp-cleanup-receipt.json","cpp-status-response.json",
  "deployment-release.json","linux-containment.transcript","linux-deactivation-transcript.json","linux-deactivation.json","linux-finalize.json",
  "linux-host-proof.json","linux-stage.json","linux-stage.json.backup","post-release-receipt.json","recovery-deployment-publish.json",
  "recovery-deployment-publish.json.intent.json","rust-acceptance-arm-response.json","rust-acceptance-query-response.json",
  "windows-bootstrap-request.json","windows-force-envelope.json","windows-install.json","windows-installer-exit.json","windows-mutation-permit.json",
  "windows-prepared.json","windows-restart-receipt.json","windows-rollback.json","windows-validation.json"]
 pre_receipt_leaves=["candidate-replacement-commit.json","candidate-retirement-terminal.json","coordinator-successor-windows-prestate.json",
  "deployment-publish.json","launch-normal-v21.sh","linux-frozen.json","marker-handoff.json","normal-v21-candidate-retirement.intent.json"]
 req(absence["normal_output_leaves"]==normal_leaves,"coordinator successor normal output leaves differ")
 req(absence["pre_receipt_operation_leaves"]==pre_receipt_leaves,"coordinator successor pre-receipt leaves differ")
 if check_state_absent=="1":
  req(sorted(os.listdir(operation_root))==sorted(pre_receipt_leaves+["coordinator-successor-receipt.json"]),
      "live pre-state operation leaves differ from the successor receipt")
 wp=successor_obj["windows_prestate"]
 keys(wp,["path","sha256"],"coordinator successor Windows prestate")
 req(wp["path"]==operation_root+"/coordinator-successor-windows-prestate.json","coordinator successor Windows prestate path differs")
 wproof,wproof_sha=document(wp["path"],"coordinator successor Windows prestate")
 req(wp["sha256"]==wproof_sha,"coordinator successor Windows prestate SHA differs")
 keys(wproof,["schema_version","state","operation_id","coordinator_instance_id","observed_at_unix_ms","observed_at_utc","windows_ssh_target",
      "windows_user_sid","windows_operation_root","operation_root_present","operation_bound_task_count","operation_bound_tasks",
      "operation_bound_process_count","operation_bound_processes","collector_path","collector_sha256"],"coordinator successor Windows prestate")
 req(wproof["schema_version"]==1 and wproof["state"]=="viewflow-normal-v21-coordinator-successor-windows-prestate" and
     wproof["operation_id"]==op and wproof["coordinator_instance_id"]==coord,"coordinator successor Windows prestate identity differs")
 named_timestamp(wproof,"observed_at_unix_ms","observed_at_utc","coordinator successor Windows prestate")
 req(wproof["windows_ssh_target"]==windows_ssh_target and wproof["windows_user_sid"]==windows_sid and
     wproof["windows_operation_root"]==windows_operation_root and wproof["operation_root_present"] is False and
     wproof["operation_bound_task_count"]==0 and wproof["operation_bound_tasks"]==[] and
     wproof["operation_bound_process_count"]==0 and wproof["operation_bound_processes"]==[],
     "coordinator successor Windows prestate is not absent")
 req(wproof["collector_path"]==succ["receipt_producer_path"] and
     wproof["collector_sha256"]==succ["receipt_producer_sha256"],"Windows prestate collector/receipt producer identity differs")
 actual_sha(wproof["collector_path"],wproof["collector_sha256"],"coordinator successor Windows prestate collector")
 successor_values=[successor_sha,wp["path"],wproof_sha,pc["path"],pc["sha256"],pc["provenance_path"],pc["provenance_sha256"],
                   succ["coordinator_path"],succ["coordinator_sha256"],succ["provenance_path"],succ["provenance_sha256"]]
else:
 req(co["entrypoint"]==coordinator_source,"candidate coordinator entrypoint differs")
 actual_sha(co["entrypoint"],co["entrypoint_sha256"],"candidate coordinator entrypoint")
 actual_sha(co["source_provenance"],co["source_provenance_sha256"],"candidate coordinator provenance")
keys(manifest_obj["linux_rust"],["provenance","provenance_sha256","viewflowd","viewflowd_sha256","deployment_marker","deployment_marker_sha256",
     "reviewed_build_manifest","reviewed_build_manifest_sha256","unit","unit_sha256","deskflow_dropin","deskflow_dropin_sha256"],"candidate Linux Rust")
lr=manifest_obj["linux_rust"]
for stem in ("provenance","reviewed_build_manifest"):
 actual_sha(lr[stem],lr[stem+"_sha256"],"candidate Linux Rust "+stem)
for stem,p,s in (("viewflowd",viewflow,viewflow_sha),("deployment_marker",marker_cli,marker_cli_sha),("unit",unit,unit_sha),("deskflow_dropin",dropin,dropin_sha)):
 req(lr[stem]==p and lr[stem+"_sha256"]==s,"candidate Linux Rust "+stem+" CLI differs"); actual_sha(p,s,"candidate Linux Rust "+stem)
keys(manifest_obj["linux_deskflow"],["provenance","provenance_sha256","deskflow","deskflow_sha256","deskflow_core","deskflow_core_sha256"],"candidate Deskflow")
ld=manifest_obj["linux_deskflow"]
for stem,p,s in (("provenance",deskflow_provenance,deskflow_provenance_sha),("deskflow",deskflow,deskflow_sha),("deskflow_core",deskflow_core,deskflow_core_sha)):
 req(ld[stem]==p and ld[stem+"_sha256"]==s,"candidate Deskflow "+stem+" CLI differs"); actual_sha(p,s,"candidate Deskflow "+stem)
keys(manifest_obj["windows"],["viewflowd","viewflowd_sha256","native_provenance","native_provenance_sha256","wrapper","wrapper_sha256",
     "launcher","launcher_sha256","installer","installer_sha256","rollback_sha256","old_task_xml_sha256","new_task_xml_override","session_1_user_sid"],"candidate Windows")
w=manifest_obj["windows"]
for stem,p,s in (("viewflowd",windows_viewflow,windows_viewflow_sha),("wrapper",windows_wrapper,windows_wrapper_sha),
                 ("launcher",windows_launcher,windows_launcher_sha),("installer",windows_installer,windows_installer_sha)):
 req(w[stem]==p and w[stem+"_sha256"]==s,"candidate Windows "+stem+" CLI differs"); actual_sha(p,s,"candidate Windows "+stem)
req(w["native_provenance"]==candidate_root+"/windows-native-provenance.json","candidate Windows native provenance path differs")
actual_sha(w["native_provenance"],w["native_provenance_sha256"],"candidate Windows native provenance",0o600,1)
req(w["rollback_sha256"]==rollback_sha,"candidate Windows rollback CLI differs"); actual_sha(rollback,rollback_sha,"candidate Windows rollback")
req(w["old_task_xml_sha256"]==task_xml_sha and w["new_task_xml_override"] is None and w["session_1_user_sid"]==windows_sid,"candidate Windows identity CLI differs")
req(manifest_sha==candidate_records[0]["sha256"],"candidate manifest exact6 digest differs")
print("\t".join([terminal_sha,commit_sha,manifest_sha,candidate_tree]+successor_values))
PY
    ) || return
    IFS=$'\t' read -r candidate_retirement_terminal_sha candidate_replacement_commit_sha candidate_manifest_sha candidate_tree_sha \
        coordinator_successor_receipt_sha coordinator_successor_windows_prestate coordinator_successor_windows_prestate_sha \
        coordinator_predecessor_path coordinator_predecessor_sha coordinator_predecessor_provenance_path coordinator_predecessor_provenance_sha \
        coordinator_successor_path coordinator_successor_sha coordinator_successor_provenance_path coordinator_successor_provenance_sha <<<"$values"
    for successor_name in coordinator_successor_receipt_sha coordinator_successor_windows_prestate coordinator_successor_windows_prestate_sha \
        coordinator_predecessor_path coordinator_predecessor_sha coordinator_predecessor_provenance_path coordinator_predecessor_provenance_sha \
        coordinator_successor_path coordinator_successor_sha coordinator_successor_provenance_path coordinator_successor_provenance_sha; do
        [[ ${!successor_name} != - ]] || printf -v "$successor_name" '%s' ''
    done
    [[ $candidate_retirement_terminal_sha =~ ^[0-9a-f]{64}$ &&
       $candidate_replacement_commit_sha =~ ^[0-9a-f]{64}$ &&
       $candidate_manifest_sha =~ ^[0-9a-f]{64}$ && $candidate_tree_sha =~ ^[0-9a-f]{64}$ ]] ||
        die 'candidate replacement validator returned an invalid digest tuple'
    if ((successor_flag_count == 2)); then
        [[ $coordinator_successor_receipt_sha =~ ^[0-9a-f]{64}$ &&
           $coordinator_successor_windows_prestate_sha =~ ^[0-9a-f]{64}$ &&
           $coordinator_predecessor_sha =~ ^[0-9a-f]{64}$ && $coordinator_predecessor_provenance_sha =~ ^[0-9a-f]{64}$ &&
           $coordinator_successor_sha =~ ^[0-9a-f]{64}$ && $coordinator_successor_provenance_sha =~ ^[0-9a-f]{64}$ ]] ||
            die 'coordinator successor validator returned an invalid digest tuple'
        coordinator_successor_validated=1
    fi
    candidate_replacement_initial_gate_complete=1
}

validate_pre_mutation_stop_state_baseline() {
    [[ $pre_mutation_stop_state_baseline_path =~ ^/proc/self/fd/[0-9]+$ ||
       $pre_mutation_stop_state_baseline_path == /tmp/viewflow-stop-state-baseline.json ]] ||
        die '--pre-mutation-stop-state-baseline-path must be an inherited /proc/self/fd/N or the fixed read-only gate path'
    require_sha256 '--pre-mutation-stop-state-baseline-sha256' "$pre_mutation_stop_state_baseline_sha"
    "$FD_GATE_PYTHON" -I -E -c 'import fcntl,hashlib,os,stat,sys
p,expected=sys.argv[1:]
flags=os.O_RDONLY|os.O_CLOEXEC
if not p.startswith("/proc/self/fd/"): flags|=os.O_NOFOLLOW
fd=os.open(p,flags)
try:
 st=os.fstat(fd)
 required=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
 data=b""
 while True:
  chunk=os.read(fd,1048576)
  if not chunk: break
  data+=chunk
 if p.startswith("/proc/self/fd/"):
  seals=fcntl.fcntl(fd,fcntl.F_GET_SEALS)
  immutable=(st.st_nlink==0 and seals==required)
 else:
  immutable=(p=="/tmp/viewflow-stop-state-baseline.json" and stat.S_IMODE(st.st_mode)==0o600 and bool(os.statvfs(p).f_flag & os.ST_RDONLY))
 ok=(stat.S_ISREG(st.st_mode) and st.st_uid==1000 and immutable and hashlib.sha256(data).hexdigest()==expected)
 raise SystemExit(0 if ok else 65)
finally:
 os.close(fd)' "$pre_mutation_stop_state_baseline_path" "$pre_mutation_stop_state_baseline_sha" ||
        die 'pre-mutation STOP_INTENT baseline immutability/SHA are invalid'
    jq -e 'type == "object"' "$pre_mutation_stop_state_baseline_path" >/dev/null ||
        die 'sealed pre-mutation STOP_INTENT baseline is not one JSON object'
    jq -s -e 'length == 1 and (.[0] | type == "object")' "$pre_mutation_stop_state_baseline_path" >/dev/null ||
        die 'sealed pre-mutation STOP_INTENT baseline is not exactly one JSON document'
    jq --stream -e 'reduce (inputs | select(length == 2) | .[0] | @json) as $p ({}; .[$p] = ((.[$p] // 0) + 1)) | all(to_entries[]; .value == 1)' \
        "$pre_mutation_stop_state_baseline_path" >/dev/null ||
        die 'sealed pre-mutation STOP_INTENT baseline contains duplicate keys'
    [[ $(sha256 "$pre_mutation_stop_state_baseline_path") == "$pre_mutation_stop_state_baseline_sha" ]] ||
        die 'sealed pre-mutation STOP_INTENT baseline changed after validation'
    jq -e --arg op "$operation_id" --arg replacement "$replacement_flag_count" --arg successor "$successor_flag_count" '
        .schema_version == 2 and .state == "viewflow-cross-host-bootstrap" and .operation_id == $op and
        .phase == "STOP_INTENT" and .recovery.failure_phase == "WINDOWS_START_INTENT" and
        .recovery.mutation_possible == false and
        (($replacement == "0" and (.committed_artifacts | keys) == ["bootstrap_request","linux_frozen","marker_handoff","publish_receipt"]) or
         ($replacement == "4" and $successor == "0" and
          (.committed_artifacts | keys) == ["bootstrap_request","candidate_manifest","candidate_replacement_commit",
                                           "candidate_retirement_terminal","candidate_tree","linux_frozen","marker_handoff","publish_receipt"]) or
         ($successor == "2" and
          (.committed_artifacts | keys) == ["bootstrap_request","candidate_manifest","candidate_replacement_commit",
                                           "candidate_retirement_terminal","candidate_tree","coordinator_successor_receipt",
                                           "coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"]))
    ' "$pre_mutation_stop_state_baseline_path" >/dev/null ||
        die 'sealed baseline is not the exact pre-mutation STOP_INTENT authorization'
}

assert_marker_cli_identity() {
    [[ -f $MARKER_CLI && ! -L $MARKER_CLI && $(stat -c '%u:%a:%h' -- "$MARKER_CLI") == 1000:755:1 ]] ||
        die 'installed marker CLI metadata differs from the gated artifact'
    [[ $(sha256 "$MARKER_CLI") == "$deployment_marker_sha" &&
       $(sha256 "$deployment_marker_candidate") == "$deployment_marker_sha" ]] ||
        die 'installed/candidate marker CLI bytes differ from the reviewed SHA'
}

marker_cli() {
    assert_marker_cli_identity || return
    run_pinned_executable marker "$MARKER_CLI" "$deployment_marker_sha" "$@"
}

assert_strict_json_document() {
    local label=$1 path=$2
    [[ -f $path && ! -L $path ]] || die "$label must be a regular non-symlink file"
    jq -e 'type == "object"' "$path" >/dev/null || die "$label is not one JSON object"
    jq -s -e 'length == 1 and (.[0] | type == "object")' "$path" >/dev/null ||
        die "$label must contain exactly one JSON document"
    jq --stream -e 'reduce (inputs | select(length == 2) | .[0] | @json) as $p ({}; .[$p] = ((.[$p] // 0) + 1)) | all(to_entries[]; .value == 1)' "$path" >/dev/null || die "$label contains duplicate object keys"
}

publish_new_file() { ln -- "$1" "$2"; }

capture_json_command() {
    local label=$1 destination=$2 temp status
    shift 2
    require_absolute_new_output "$label" "$destination" || return
    temp=$(mktemp --tmpdir="$(dirname -- "$destination")" '.viewflow-receipt.XXXXXX')
    chmod 0600 "$temp"
    if "$@" >"$temp"; then status=0; else status=$?; fi
    ((status == 0)) || { rm -f -- "$temp"; return "$status"; }
    assert_strict_json_document "$label" "$temp" || { status=$?; rm -f -- "$temp"; return "$status"; }
    publish_new_file "$temp" "$destination" || { status=$?; rm -f -- "$temp"; return "$status"; }
    rm -f -- "$temp"
}

cleanup_secure_dir() {
    local cleanup=$secure_dir
    secure_dir=''
    [[ -z $cleanup ]] || rm -rf -- "$cleanup"
}

finish_recovery() {
    local status=$1
    recovery_required=0
    recovery_finished=1
    cleanup_secure_dir
    exit "$status"
}

publish_json_file() {
    local label=$1 source=$2 destination=$3 temp
    require_absolute_new_output "$label" "$destination"
    assert_strict_json_document "$label" "$source"
    temp=$(mktemp --tmpdir="$(dirname -- "$destination")" '.viewflow-publish.XXXXXX')
    chmod 0600 "$temp"
    dd if="$source" of="$temp" status=none
    sync -f "$temp"
    assert_strict_json_document "$label" "$temp"
    publish_new_file "$temp" "$destination"
    rm -f -- "$temp"
}

copy_json_output() {
    local label=$1 source=$2 destination=$3 temp
    require_absolute_new_output "$label" "$destination"
    assert_strict_json_document "$label" "$source"
    temp=$(mktemp --tmpdir="$(dirname -- "$destination")" '.viewflow-copy.XXXXXX')
    chmod 0600 "$temp"
    dd if="$source" of="$temp" status=none
    assert_strict_json_document "$label" "$temp"
    publish_new_file "$temp" "$destination"
    rm -f -- "$temp"
}

sha_if_regular() { [[ -f $1 && ! -L $1 ]] && sha256 "$1" || printf 'null\n'; }

render_committed_artifacts() {
    ((replacement_flag_count == 0)) || validate_candidate_replacement_lineage
    jq -cn \
        --arg h "$(sha_if_regular "$bootstrap_handoff_receipt")" \
        --arg b "$(sha_if_regular "$bootstrap_linux_evidence")" \
        --arg publish "$(sha_if_regular "$deployment_publish_receipt")" \
        --arg request "$(sha_if_regular "$windows_bootstrap_request")" \
        --arg p "$(sha_if_regular "$windows_prepared_receipt")" \
        --arg permit "$(sha_if_regular "$windows_mutation_permit")" \
        --arg f "$(sha_if_regular "$windows_force_envelope")" \
        --arg ls "$(sha_if_regular "$linux_stage_receipt")" \
        --arg w "$(sha_if_regular "$bootstrap_windows_install_receipt")" \
        --arg exit "$(sha_if_regular "$windows_installer_exit_receipt")" \
        --arg lf "$(sha_if_regular "$linux_finalize_receipt")" \
        --arg release "$(sha_if_regular "$deployment_release_receipt")" \
        --arg cross "$(sha_if_regular "$linux_host_proof")" --arg bundle "$(sha_if_regular "$local_recovery_bundle")" \
        --arg stop "$(sha_if_regular "$local_windows_stop_evidence")" --arg recovery_intent "$(sha_if_regular "$recovery_publish_intent")" \
        --arg restart_intent "$(sha_if_regular "$local_windows_restart_intent")" \
        --arg rust_arm "$(sha_if_regular "$rust_acceptance_arm_response")" --arg cpp_status "$(sha_if_regular "$cpp_status_response")" \
        --arg cpp_arm "$(sha_if_regular "$cpp_arm_response")" --arg cpp_cleanup "$(sha_if_regular "$cpp_cleanup_receipt")" \
        --arg restart "$(sha_if_regular "$windows_restart_receipt")" --arg rust_final "$(sha_if_regular "$rust_acceptance_query_response")" \
        --arg post "$(sha_if_regular "$post_release_receipt")" --arg recovery_publish "$(sha_if_regular "$recovery_deployment_publish_receipt")" \
        --arg rollback "$(sha_if_regular "$local_windows_rollback_receipt")" \
        --arg pre_retry "$(sha_if_regular "$pre_mutation_retry_proof")" \
        --arg candidate_retirement "${candidate_retirement_terminal_sha:-null}" \
        --arg candidate_replacement "${candidate_replacement_commit_sha:-null}" \
        --arg candidate_manifest "${candidate_manifest_sha:-null}" \
        --arg candidate_tree "${candidate_tree_sha:-null}" \
        --arg successor_receipt "${coordinator_successor_receipt_sha:-null}" \
        --arg successor_windows "${coordinator_successor_windows_prestate_sha:-null}" '
        {marker_handoff:$h,linux_frozen:$b,publish_receipt:$publish,bootstrap_request:$request,
         windows_prepared:$p,mutation_permit:$permit,force_envelope:$f,linux_stage:$ls,
         windows_install:$w,windows_exit:$exit,linux_finalize:$lf,deployment_release:$release,cross_chain:$cross,
         recovery_bundle:$bundle,windows_stop_evidence:$stop,recovery_publish_intent:$recovery_intent,windows_restart_intent:$restart_intent,
         rust_arm:$rust_arm,cpp_status:$cpp_status,cpp_arm:$cpp_arm,cpp_cleanup:$cpp_cleanup,
         windows_restart:$restart,rust_final:$rust_final,post_release:$post,recovery_publish:$recovery_publish,
         windows_rollback:$rollback,pre_mutation_retry:$pre_retry,
         candidate_retirement_terminal:$candidate_retirement,candidate_replacement_commit:$candidate_replacement,
         candidate_manifest:$candidate_manifest,candidate_tree:$candidate_tree,
         coordinator_successor_receipt:$successor_receipt,coordinator_successor_windows_prestate:$successor_windows}
        | with_entries(select(.value != "null"))
    '
}

commit_phase() {
    local next=$1 temp current_rank next_rank committed
    current_rank=$(phase_rank "$phase"); next_rank=$(phase_rank "$next")
    ((current_rank < next_rank)) || return 0
    temp=$(mktemp --tmpdir="$(dirname -- "$coordinator_state")" '.viewflow-state.XXXXXX')
    chmod 0600 "$temp"
    committed=$(render_committed_artifacts)
    if [[ -e $coordinator_state ]]; then
        jq --arg next "$next" --arg failure "$recovery_failure_phase" \
            --arg mutation "$recovery_mutation_possible" --argjson committed "$committed" '
            (.committed_artifacts // {}) as $old |
            # Every durable artifact must still be present with the original
            # bytes at every phase transition.  A later render is allowed to
            # add a new key, but it may not omit or replace any earlier key.
            if (all($old | to_entries[]; $committed[.key] == .value) and
                all($committed | to_entries[];
                    . as $item | ((($old | has($item.key)) | not) or $old[$item.key] == $item.value))) then
                .phase = $next |
                .committed_artifacts = reduce ($committed | to_entries[]) as $item
                    ($old; if has($item.key) then . else .[$item.key] = $item.value end) |
                if $next == "STOP_INTENT" then
                    .recovery = {failure_phase:$failure,
                                 mutation_possible:($mutation == "1" or $mutation == "true")}
                elif (.recovery | type) == "object" then
                    .recovery.mutation_possible = ($mutation == "1" or $mutation == "true")
                else . end
            else error("committed artifact overlap changed") end
        ' "$coordinator_state" >"$temp"
    else
        render_state "$next" >"$temp"
    fi
    sync -f "$temp"
    mv -T -- "$temp" "$coordinator_state"
    sync -f "$coordinator_state"
    sync -f "$(dirname -- "$coordinator_state")"
    phase=$next
}

render_state() {
    local state=$1 committed
    committed=$(render_committed_artifacts)
    jq -cn --arg op "$operation_id" --arg state "$state" \
        --arg h "$bootstrap_handoff_receipt" --arg hsha "$(sha256 "$bootstrap_handoff_receipt")" \
        --arg b "$bootstrap_linux_original" --arg bsha "$(sha256 "$bootstrap_linux_evidence")" \
        --arg publish "$deployment_publish_receipt" --arg publishsha "$(sha256 "$deployment_publish_receipt")" \
        --arg vf "$viewflow_candidate" --arg vfsha "$viewflow_sha" --arg marker "$deployment_marker_candidate" --arg markersha "$deployment_marker_sha" \
        --arg df "$deskflow_candidate" --arg dfsha "$deskflow_sha" --arg core "$deskflow_core_candidate" --arg coresh "$deskflow_core_sha" \
        --arg provenance "$deskflow_provenance_manifest" --arg provenancesha "$deskflow_provenance_sha" \
        --arg unit "$viewflow_unit_candidate" --arg unitsha "$viewflow_unit_sha" \
        --arg dropin "$deskflow_dropin_candidate" --arg dropinsha "$deskflow_dropin_sha" \
        --arg launcher "$windows_launcher_candidate" --arg launchersha "$windows_launcher_sha" \
        --arg installer "$windows_installer_candidate" --arg installersha "$windows_installer_sha" \
        --arg win "$windows_viewflow_candidate" --arg winsha "$windows_viewflow_sha" --arg wrapper "$windows_wrapper_candidate" --arg wrappersha "$windows_wrapper_sha" \
        --arg rollback "$reviewed_rollback_script" --arg rollbacksha "$windows_rollback_script_sha" \
        --arg request "$windows_bootstrap_request" --arg p "$windows_prepared_receipt" --arg permit "$windows_mutation_permit" \
        --arg f "$windows_force_original" --arg ls "$linux_stage_receipt" --arg w "$windows_install_original" \
        --arg exit "$windows_installer_exit_receipt" --arg lf "$linux_finalize_receipt" --arg release "$deployment_release_receipt" \
        --arg cross "$linux_host_proof" --arg post "$post_release_receipt" --arg restart "$windows_restart_receipt" \
        --arg cppstatus "$cpp_status_response" --arg cpparm "$cpp_arm_response" --arg cppcleanup "$cpp_cleanup_receipt" \
        --arg rustarm "$rust_acceptance_arm_response" --arg rustquery "$rust_acceptance_query_response" \
        --arg recoverypublish "$recovery_deployment_publish_receipt" --arg deactivationproof "$linux_deactivation_proof" \
        --arg deactivationtranscript "$linux_deactivation_transcript" --arg containment "$linux_containment_transcript" \
        --arg validation "$local_windows_validation" --arg rollbackreceipt "$local_windows_rollback_receipt" \
        --arg localbundle "$local_recovery_bundle" \
        --arg localstop "$local_windows_stop_evidence" --arg recoveryintent "$recovery_publish_intent" \
        --arg localrestartintent "$local_windows_restart_intent" \
        --arg remote "$windows_operation_root" --arg remote_request "$windows_request_path" \
        --arg remote_prepared "$windows_prepared_path" --arg remote_permit "$windows_permit_path" \
        --arg remote_force "$windows_force_envelope_path" --arg remote_stage "$windows_stage_path" \
        --arg remote_install "$windows_install_path" --arg remote_exit "$windows_exit_path" \
        --arg remote_ready "$windows_readiness_receipt_path" --arg remote_lock "$windows_readiness_lock_path" \
        --arg remote_commit "$windows_commit_request_path" --arg remote_manifest "$windows_rollback_manifest_path" \
        --arg remote_token "$windows_rollback_token_path" --arg remote_bundle "$windows_recovery_bundle_path" \
        --arg remote_recovery "$windows_recovery_force_receipt_path" --arg remote_rollback "$windows_rollback_receipt_path" \
        --arg remote_rollback_claim "$windows_rollback_claim_path" \
        --arg remote_restart_intent "$windows_restart_intent_path" --arg remote_restart_claim "$windows_restart_claim_path" \
        --arg remote_restart_terminal "$windows_restart_terminal_path" \
        --arg source "$source_display_id" --arg target "$target_device_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg recovery_generation "$recovery_marker_generation" --arg sid "$windows_user_sid" \
        --arg task_override "$windows_task_xml_override" --argjson committed "$committed" \
        --arg candidate_retirement "$candidate_retirement_terminal" --arg candidate_retirement_sha "$candidate_retirement_terminal_sha" \
        --arg candidate_replacement "$candidate_replacement_commit" --arg candidate_replacement_sha "$candidate_replacement_commit_sha" \
        --arg candidate_manifest "$candidate_manifest_path" --arg candidate_manifest_sha "$candidate_manifest_sha" \
        --arg candidate_tree "$candidate_tree_sha" \
        --arg successor_receipt "$coordinator_successor_receipt" --arg successor_receipt_sha "$coordinator_successor_receipt_sha" \
        --arg successor_windows "$coordinator_successor_windows_prestate" --arg successor_windows_sha "$coordinator_successor_windows_prestate_sha" \
        --arg predecessor_path "$coordinator_predecessor_path" --arg predecessor_sha "$coordinator_predecessor_sha" \
        --arg predecessor_provenance "$coordinator_predecessor_provenance_path" --arg predecessor_provenance_sha "$coordinator_predecessor_provenance_sha" \
        --arg successor_path "$coordinator_successor_path" --arg successor_sha "$coordinator_successor_sha" \
        --arg successor_provenance "$coordinator_successor_provenance_path" --arg successor_provenance_sha "$coordinator_successor_provenance_sha" '
        {schema_version:2,state:"viewflow-cross-host-bootstrap",operation_id:$op,phase:$state,
         recovery:{failure_phase:null,mutation_possible:false},
         committed_artifacts:$committed,
         contract:{inputs:{marker_handoff:{path:$h,sha256:$hsha},linux_frozen:{path:$b,sha256:$bsha},publish_receipt:{path:$publish,sha256:$publishsha},
                           linux_viewflow:{path:$vf,sha256:$vfsha},linux_marker_cli:{path:$marker,sha256:$markersha},linux_deskflow:{path:$df,sha256:$dfsha},
                           linux_deskflow_core:{path:$core,sha256:$coresh},linux_provenance:{path:$provenance,sha256:$provenancesha},
                           linux_viewflow_unit:{path:$unit,sha256:$unitsha},linux_deskflow_dropin:{path:$dropin,sha256:$dropinsha},
                           windows_launcher:{path:$launcher,sha256:$launchersha},
                           windows_installer:{path:$installer,sha256:$installersha},windows_viewflow:{path:$win,sha256:$winsha},
                           windows_wrapper:{path:$wrapper,sha256:$wrappersha},windows_rollback:{path:$rollback,sha256:$rollbacksha}}
                         + (if $candidate_manifest_sha == "" then {} else
                              {candidate_retirement_terminal:{path:$candidate_retirement,sha256:$candidate_retirement_sha},
                               candidate_replacement_commit:{path:$candidate_replacement,sha256:$candidate_replacement_sha},
                               candidate_manifest:{path:$candidate_manifest,sha256:$candidate_manifest_sha},
                               candidate_tree_sha256:$candidate_tree}
                            end)
                         + (if $successor_receipt_sha == "" then {} else
                              {coordinator_successor_receipt:{path:$successor_receipt,sha256:$successor_receipt_sha},
                               coordinator_successor_windows_prestate:{path:$successor_windows,sha256:$successor_windows_sha},
                               coordinator_predecessor:{path:$predecessor_path,sha256:$predecessor_sha,
                                                        provenance_path:$predecessor_provenance,provenance_sha256:$predecessor_provenance_sha},
                               coordinator_successor:{path:$successor_path,sha256:$successor_sha,
                                                      provenance_path:$successor_provenance,provenance_sha256:$successor_provenance_sha}}
                            end),
                   outputs:{request:$request,prepared:$p,permit:$permit,force_envelope:$f,linux_stage:$ls,windows_install:$w,
                            windows_exit:$exit,linux_finalize:$lf,release:$release,cross_chain:$cross,post_release:$post,
                            windows_restart:$restart,cpp_status:$cppstatus,cpp_arm:$cpparm,cpp_cleanup:$cppcleanup,
                            rust_arm:$rustarm,rust_query:$rustquery,recovery_publish:$recoverypublish,
                            linux_deactivation_proof:$deactivationproof,linux_deactivation_transcript:$deactivationtranscript,
                            linux_containment:$containment,windows_validation:$validation,windows_rollback:$rollbackreceipt,
                            recovery_bundle:$localbundle,windows_stop_evidence:$localstop,recovery_publish_intent:$recoveryintent,
                            windows_restart_intent:$localrestartintent},
                   identity:{source_display_id:$source,target_device_id:$target,coordinator_instance_id:$coordinator,
                             marker_generation:$generation,recovery_marker_generation:$recovery_generation,windows_user_sid:$sid,
                             windows_task_xml_sha256_override:$task_override},
                   remote:{operation_root:$remote,request:$remote_request,prepared:$remote_prepared,permit:$remote_permit,
                           force_envelope:$remote_force,linux_stage:$remote_stage,windows_install:$remote_install,exit:$remote_exit,
                           readiness_receipt:$remote_ready,readiness_lock:$remote_lock,commit_request:$remote_commit,
                           rollback_manifest:$remote_manifest,rollback_token:$remote_token,recovery_bundle:$remote_bundle,
                           recovery_force_release:$remote_recovery,rollback_receipt:$remote_rollback,rollback_claim:$remote_rollback_claim,
                           restart_intent:$remote_restart_intent,restart_claim:$remote_restart_claim,restart_terminal:$remote_restart_terminal}}}
    '
}

validate_state_contract() {
    local state_source=${1:-$coordinator_state} expected=$secure_dir/state-expected.json expected_contract actual_contract current_committed
    render_state "$(jq -er '.phase' "$state_source")" >"$expected"
    expected_contract=$(jq -cS '.contract' "$expected")
    actual_contract=$(jq -cS '.contract' "$state_source")
    [[ $actual_contract == "$expected_contract" ]] || die 'resume inputs/outputs/artifact hashes differ from durable state'
    current_committed=$(render_committed_artifacts)
    jq -e --argjson current "$current_committed" '
        (.committed_artifacts | type == "object") and
        all(.committed_artifacts | to_entries[]; $current[.key] == .value)
    ' "$state_source" >/dev/null || die 'a durable committed artifact is missing or changed on resume'
    if ((replacement_flag_count == 4)); then
        jq -e --arg terminal "$candidate_retirement_terminal_sha" --arg commit "$candidate_replacement_commit_sha" \
            --arg manifest "$candidate_manifest_sha" --arg tree "$candidate_tree_sha" '
            .committed_artifacts.candidate_retirement_terminal == $terminal and
            .committed_artifacts.candidate_replacement_commit == $commit and
            .committed_artifacts.candidate_manifest == $manifest and
            .committed_artifacts.candidate_tree == $tree and
            .contract.inputs.candidate_retirement_terminal.sha256 == $terminal and
            .contract.inputs.candidate_replacement_commit.sha256 == $commit and
            .contract.inputs.candidate_manifest.sha256 == $manifest and
            .contract.inputs.candidate_tree_sha256 == $tree
        ' "$state_source" >/dev/null || die 'replacement coordinator state omitted a frozen candidate lineage input'
    fi
    if ((successor_flag_count == 2)); then
        jq -e --arg receipt "$coordinator_successor_receipt_sha" --arg windows "$coordinator_successor_windows_prestate_sha" \
            --arg predecessor "$coordinator_predecessor_path" --arg predecessor_sha "$coordinator_predecessor_sha" \
            --arg predecessor_provenance "$coordinator_predecessor_provenance_path" --arg predecessor_provenance_sha "$coordinator_predecessor_provenance_sha" \
            --arg successor "$coordinator_successor_path" --arg successor_sha "$coordinator_successor_sha" \
            --arg successor_provenance "$coordinator_successor_provenance_path" --arg successor_provenance_sha "$coordinator_successor_provenance_sha" '
            .committed_artifacts.coordinator_successor_receipt == $receipt and
            .committed_artifacts.coordinator_successor_windows_prestate == $windows and
            .contract.inputs.coordinator_successor_receipt.sha256 == $receipt and
            .contract.inputs.coordinator_successor_windows_prestate.sha256 == $windows and
            .contract.inputs.coordinator_predecessor == {path:$predecessor,sha256:$predecessor_sha,
              provenance_path:$predecessor_provenance,provenance_sha256:$predecessor_provenance_sha} and
            .contract.inputs.coordinator_successor == {path:$successor,sha256:$successor_sha,
              provenance_path:$successor_provenance,provenance_sha256:$successor_provenance_sha}
        ' "$state_source" >/dev/null || die 'successor coordinator state omitted a frozen coordinator lineage input'
    fi
}

render_pre_mutation_start_state() {
    local committed
    committed=$(render_committed_artifacts)
    jq --arg proof "$pre_mutation_retry_proof" --arg proof_sha "$(sha256 "$pre_mutation_retry_proof")" \
        --arg baseline_sha "$pre_mutation_stop_state_baseline_sha" --arg canonical "$coordinator_state" \
        --arg claim "$pre_mutation_stop_state_claim" --arg candidate "$pre_mutation_start_state_candidate" \
        --arg replacement "$replacement_flag_count" --arg successor "$successor_flag_count" --argjson committed "$committed" '
        (.committed_artifacts // {}) as $old |
        if (.phase == "STOP_INTENT" and .recovery.failure_phase == "WINDOWS_START_INTENT" and
            .recovery.mutation_possible == false and
            ((($replacement == "0" and
              ($old | keys) == ["bootstrap_request","linux_frozen","marker_handoff","publish_receipt"] and
              ($committed | keys) == ["bootstrap_request","linux_frozen","marker_handoff","pre_mutation_retry","publish_receipt"]) or
             ($replacement == "4" and $successor == "0" and
              ($old | keys) == ["bootstrap_request","candidate_manifest","candidate_replacement_commit",
                                "candidate_retirement_terminal","candidate_tree","linux_frozen","marker_handoff","publish_receipt"] and
              ($committed | keys) == ["bootstrap_request","candidate_manifest","candidate_replacement_commit",
                                      "candidate_retirement_terminal","candidate_tree","linux_frozen","marker_handoff",
                                      "pre_mutation_retry","publish_receipt"]) or
             ($successor == "2" and
              ($old | keys) == ["bootstrap_request","candidate_manifest","candidate_replacement_commit",
                                "candidate_retirement_terminal","candidate_tree","coordinator_successor_receipt",
                                "coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"] and
              ($committed | keys) == ["bootstrap_request","candidate_manifest","candidate_replacement_commit",
                                      "candidate_retirement_terminal","candidate_tree","coordinator_successor_receipt",
                                      "coordinator_successor_windows_prestate","linux_frozen","marker_handoff",
                                      "pre_mutation_retry","publish_receipt"])) and
            all($old | to_entries[]; $committed[.key] == .value))) then
            .phase = "WINDOWS_START_INTENT" |
            .committed_artifacts = $committed |
            .recovery = {failure_phase:null,mutation_possible:false,
                         pre_mutation_stop_history:{phase:"STOP_INTENT",failure_phase:"WINDOWS_START_INTENT",
                                                    mutation_possible:false,baseline_state_sha256:$baseline_sha,
                                                    canonical_state_path:$canonical,old_state_claim_path:$claim,
                                                    start_state_candidate_path:$candidate,
                                                    proof_path:$proof,proof_sha256:$proof_sha,
                                                    marker_gate_authorization:false,
                                                    marker_transaction_query_only:true}}
        else error("sealed pre-mutation STOP_INTENT baseline changed") end
    ' "$pre_mutation_stop_state_baseline_path"
}

validate_pre_mutation_start_state_file() {
    local path=$1 expected=$secure_dir/pre-mutation-start-expected.$BASHPID.$RANDOM.json expected_sha
    render_pre_mutation_start_state >"$expected"
    chmod 0600 "$expected"
    assert_strict_json_document 'expected pre-mutation START_INTENT state' "$expected"
    expected_sha=$(sha256 "$expected")
    [[ -f $path && ! -L $path && $(stat -c '%u:%a' -- "$path") == 1000:600 &&
       $(sha256 "$path") == "$expected_sha" ]] || {
        rm -f -- "$expected"
        die 'pre-mutation START_INTENT state differs from sealed baseline construction'
        return
    }
    pre_mutation_start_state_sha=$expected_sha
    rm -f -- "$expected"
}

publish_pre_mutation_start_state_cas() {
    local expected=$secure_dir/pre-mutation-start-candidate.json expected_sha canonical_sha claim_identity canonical_identity candidate_identity
    validate_pre_mutation_stop_state_baseline
    validate_pre_mutation_retry_proof "$pre_mutation_retry_proof"
    render_pre_mutation_start_state >"$expected"
    chmod 0600 "$expected"
    sync -f "$expected"
    assert_strict_json_document 'pre-mutation START_INTENT candidate' "$expected"
    expected_sha=$(sha256 "$expected")
    if [[ -e $pre_mutation_start_state_candidate || -L $pre_mutation_start_state_candidate ]]; then
        validate_pre_mutation_start_state_file "$pre_mutation_start_state_candidate"
        [[ $pre_mutation_start_state_sha == "$expected_sha" ]] || die 'pre-mutation START_INTENT candidate replay differs'
    else
        publish_json_file 'durable pre-mutation START_INTENT candidate' "$expected" "$pre_mutation_start_state_candidate"
        validate_pre_mutation_start_state_file "$pre_mutation_start_state_candidate"
    fi
    if [[ ! -e $pre_mutation_stop_state_claim && ! -L $pre_mutation_stop_state_claim ]]; then
        [[ -f $coordinator_state && ! -L $coordinator_state &&
           $(sha256 "$coordinator_state") == "$pre_mutation_stop_state_baseline_sha" ]] ||
            die 'canonical STOP_INTENT state changed before claim'
        ln -- "$coordinator_state" "$pre_mutation_stop_state_claim" || die 'cannot create STOP_INTENT state claim'
        sync -f "$(dirname -- "$coordinator_state")"
    fi
    [[ -f $pre_mutation_stop_state_claim && ! -L $pre_mutation_stop_state_claim &&
       $(stat -c '%u:%a' -- "$pre_mutation_stop_state_claim") == 1000:600 &&
       $(sha256 "$pre_mutation_stop_state_claim") == "$pre_mutation_stop_state_baseline_sha" ]] ||
        die 'STOP_INTENT state claim differs from sealed baseline'
    if [[ -e $coordinator_state || -L $coordinator_state ]]; then
        [[ -f $coordinator_state && ! -L $coordinator_state ]] || die 'canonical coordinator state is unsafe during CAS'
        canonical_sha=$(sha256 "$coordinator_state")
        if [[ $canonical_sha == "$expected_sha" ]]; then
            validate_pre_mutation_start_state_file "$coordinator_state"
        elif [[ $canonical_sha == "$pre_mutation_stop_state_baseline_sha" ]]; then
            claim_identity=$(stat -c '%d:%i' -- "$pre_mutation_stop_state_claim")
            canonical_identity=$(stat -c '%d:%i' -- "$coordinator_state")
            [[ $claim_identity == "$canonical_identity" &&
               $(sha256 "$coordinator_state") == "$pre_mutation_stop_state_baseline_sha" &&
               $(sha256 "$pre_mutation_stop_state_claim") == "$pre_mutation_stop_state_baseline_sha" ]] ||
                die 'canonical STOP_INTENT state changed after claim'
            unlink -- "$coordinator_state"
            sync -f "$(dirname -- "$coordinator_state")"
        else
            die 'canonical coordinator state is neither sealed STOP_INTENT nor exact START_INTENT'
        fi
    fi
    if [[ ! -e $coordinator_state && ! -L $coordinator_state ]]; then
        ln -- "$pre_mutation_start_state_candidate" "$coordinator_state" ||
            die 'START_INTENT canonical no-clobber publication lost a race'
        sync -f "$(dirname -- "$coordinator_state")"
    fi
    validate_pre_mutation_start_state_file "$coordinator_state"
    candidate_identity=$(stat -c '%d:%i' -- "$pre_mutation_start_state_candidate")
    canonical_identity=$(stat -c '%d:%i' -- "$coordinator_state")
    [[ $candidate_identity == "$canonical_identity" &&
       $(sha256 "$pre_mutation_stop_state_claim") == "$pre_mutation_stop_state_baseline_sha" ]] ||
        die 'pre-mutation START_INTENT CAS identities differ'
    pre_mutation_retry_active=1
    phase=WINDOWS_START_INTENT
    recovery_failure_phase=''
    recovery_mutation_possible=0
    rm -f -- "$expected"
}

adopt_consume_intent_inputs() {
    local intent=${linux_stage_receipt}.backup/consume-intent.json original consumed expected actual selected contract_original
    [[ -e $intent ]] || return 0
    assert_strict_json_document 'Linux consume intent' "$intent"
    jq -e --arg op "$operation_id" --arg stage "$(sha256 "$linux_stage_receipt")" '
        (keys == ["artifacts","created_at_unix_ms","operation_id","schema_version","stage_receipt_sha256","state"]) and
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-consume-intent" and
        .operation_id == $op and .stage_receipt_sha256 == $stage and
        (.artifacts | keys) == ["linux_frozen_evidence","windows_force_release_envelope","windows_install_receipt"] and
        all(.artifacts[]; (keys == ["consumed_path","original_path","sha256"]) and (.sha256 | test("^[0-9a-f]{64}$")))
    ' "$intent" >/dev/null || die 'Linux consume intent schema is invalid'
    for name in linux_frozen_evidence windows_force_release_envelope windows_install_receipt; do
        original=$(jq -er --arg n "$name" '.artifacts[$n].original_path' "$intent")
        consumed=$(jq -er --arg n "$name" '.artifacts[$n].consumed_path' "$intent")
        expected=$(jq -er --arg n "$name" '.artifacts[$n].sha256' "$intent")
        case $name in
            linux_frozen_evidence) contract_original=$bootstrap_linux_original ;;
            windows_force_release_envelope) contract_original=$windows_force_original ;;
            windows_install_receipt) contract_original=$windows_install_original ;;
        esac
        [[ $original == "$contract_original" ]] || die "consume intent original path differs: $name"
        if [[ -f $consumed && ! -L $consumed ]]; then
            [[ ! -e $original ]] || die "consume intent has both original and consumed copies: $name"
            selected=$consumed
        elif [[ -f $original && ! -L $original ]]; then
            [[ ! -e $consumed ]] || die "consume intent consumed path is unsafe: $name"
            selected=$original
        else die "consume intent artifact is absent: $name"; fi
        actual=$(sha256 "$selected"); [[ $actual == "$expected" ]] || die "consume intent artifact hash differs: $name"
        case $name in linux_frozen_evidence) bootstrap_linux_evidence=$selected ;; windows_force_release_envelope) windows_force_envelope=$selected ;; windows_install_receipt) bootstrap_windows_install_receipt=$selected ;; esac
    done
}

phase_rank() {
    case $1 in
        INIT) echo 0 ;; WINDOWS_PUBLISH_INTENT) echo 10 ;; WINDOWS_START_INTENT) echo 20 ;;
        WINDOWS_STARTED) echo 30 ;; WINDOWS_PREPARED) echo 40 ;; WINDOWS_PERMIT_PUBLISH_INTENT) echo 45 ;; MUTATION_PERMITTED) echo 50 ;;
        WINDOWS_FORCE_ATTESTED) echo 60 ;; LINUX_STAGED) echo 70 ;; WINDOWS_COMMITTED) echo 80 ;;
        WINDOWS_TERMINAL) echo 90 ;; LINUX_FINALIZED_MARKER_HELD) echo 100 ;; MARKER_RELEASED) echo 110 ;;
        RUST_ACCEPTANCE_ARMED) echo 112 ;; CPP_ACCEPTANCE_ARMED) echo 114 ;; CPP_CLEANED) echo 116 ;;
        WINDOWS_RESTART_INTENT) echo 117 ;; WINDOWS_RESTART_DISPATCHED) echo 118 ;; WINDOWS_RESTARTED) echo 119 ;;
        POST_RELEASE_VERIFIED) echo 120 ;;
        STOP_INTENT) echo 200 ;; STOPPED) echo 210 ;;
        LINUX_RECOVERED) echo 220 ;; WINDOWS_ROLLBACK_INTENT) echo 230 ;; WINDOWS_ROLLED_BACK) echo 240 ;; *) return 1 ;;
    esac
}

adopt_prepublished_marker_handoff() {
    local publish_sha handoff_sha
    assert_strict_json_document 'prepublished marker receipt' "$deployment_publish_receipt"
    assert_strict_json_document 'marker handoff H' "$bootstrap_handoff_receipt"
    validate_publish_receipt "$deployment_publish_receipt" "$marker_generation"
    publish_sha=$(sha256 "$deployment_publish_receipt")
    handoff_sha=$(sha256 "$bootstrap_handoff_receipt")
    jq -e --arg op "$operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg coordinator "$coordinator_instance_id" --arg generation "$marker_generation" \
        --arg marker "$DEPLOYMENT_MARKER" --arg marker_sha "$published_marker_sha" \
        --arg publish "$deployment_publish_receipt" --arg publish_sha "$publish_sha" \
        --arg cli "$MARKER_CLI" --arg cli_sha "$deployment_marker_sha" \
        --arg deskflow "$DESKFLOW_INSTALLED" --arg core "$DESKFLOW_CORE_INSTALLED" \
        --arg runtime "$RUNTIME_MARKER" '
        (keys == ["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256","deployment_publish_receipt_path","deployment_publish_receipt_sha256","deskflow_core_exact_process_count","deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_exact_process_count","deskflow_executable_path","deskflow_executable_sha256","deskflow_tcp_listener_count","deskflow_tcp_port","deskflow_unit","deskflow_unit_active_state","deskflow_unit_main_pid","marker_cli_path","marker_cli_sha256","marker_generation","observed_at_utc","operation_id","protocol_version","runtime_marker_path","runtime_marker_present","schema_version","source_display_id","state","target_device_id"]) and
        .schema_version == 1 and .state == "viewflow-v13-marker-handoff-prepared" and
        .protocol_version == "2.1" and .operation_id == $op and .source_display_id == $source and
        .target_device_id == $target and .coordinator_instance_id == $coordinator and
        .marker_generation == $generation and .deployment_marker_path == $marker and
        .deployment_marker_sha256 == $marker_sha and .deployment_publish_receipt_path == $publish and
        .deployment_publish_receipt_sha256 == $publish_sha and .marker_cli_path == $cli and
        .marker_cli_sha256 == $cli_sha and .deskflow_unit == "deskflow.service" and
        .deskflow_unit_active_state == "inactive" and .deskflow_unit_main_pid == 0 and
        .deskflow_executable_path == $deskflow and .deskflow_exact_process_count == 0 and
        .deskflow_core_executable_path == $core and .deskflow_core_exact_process_count == 0 and
        .deskflow_tcp_port == 24800 and .deskflow_tcp_listener_count == 0 and
        .runtime_marker_path == $runtime and .runtime_marker_present == false
    ' "$bootstrap_handoff_receipt" >/dev/null || die 'prepublished marker handoff H is invalid'
    [[ $handoff_sha =~ ^[0-9a-f]{64}$ ]] || die 'H hash failure'
    assert_deployment_marker || die 'prepublished VFDQT001 is not the H marker'
}

reconcile_deployment_marker_phase() {
    local query completed state
    marker_phase_query_counter=$((marker_phase_query_counter + 1))
    query=$secure_dir/marker-phase-query.$marker_phase_query_counter.json
    completed=$secure_dir/marker-phase-release.$marker_phase_query_counter.json
    if ((pre_mutation_retry_active)) ||
       [[ $phase == STOP_INTENT && $resume_pre_mutation_stop_intent == 1 ]] ||
       [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_FINALIZED_MARKER_HELD) ]]; then
        adopt_prepublished_marker_handoff
        capture_json_command 'active deployment marker transaction query' "$query" marker_cli query \
            --operation-id "$operation_id" --coordinator-instance-id "$coordinator_instance_id" \
            --marker-generation "$marker_generation" --marker-sha256 "$published_marker_sha"
        jq -e --arg op "$operation_id" --arg generation "$marker_generation" --arg sha "$published_marker_sha" '
            keys == ["marker_generation","marker_sha256","operation_id","protocol_version","schema_version","state"] and
            .schema_version == 2 and .state == "deployment-quarantine-active" and .protocol_version == "2.1" and
            .operation_id == $op and .marker_generation == $generation and .marker_sha256 == $sha
        ' "$query" >/dev/null || die 'active deployment marker transaction query is invalid'
        assert_deployment_marker || die 'active transaction query lacks exact VFDQT001 bytes'
        return
    fi
    validate_publish_receipt "$deployment_publish_receipt" "$marker_generation" 0
    capture_json_command 'released deployment marker phase query' "$query" marker_cli query \
        --operation-id "$operation_id" --coordinator-instance-id "$coordinator_instance_id" \
        --marker-generation "$marker_generation" --marker-sha256 "$published_marker_sha"
    state=$(jq -er '.state' "$query")
    case $state in
        deployment-quarantine-active)
            [[ $(phase_rank "$phase") -lt $(phase_rank MARKER_RELEASED) ]] ||
                die 'durable state says released but marker is active'
            jq -e --arg op "$operation_id" --arg generation "$marker_generation" --arg sha "$published_marker_sha" '
                keys == ["marker_generation","marker_sha256","operation_id","protocol_version","schema_version","state"] and
                .schema_version == 2 and .state == "deployment-quarantine-active" and .protocol_version == "2.1" and
                .operation_id == $op and .marker_generation == $generation and .marker_sha256 == $sha
            ' "$query" >/dev/null || die 'active marker query is invalid'
            assert_deployment_marker || die 'active release query lacks exact VFDQT001 bytes'
            ;;
        deployment-quarantine-release-claimed|deployment-quarantine-release-committed-pending-release)
            [[ $(phase_rank "$phase") -lt $(phase_rank MARKER_RELEASED) ]] ||
                die 'durable released phase regressed to an in-progress release'
            capture_json_command 'resume marker release transaction' "$completed" marker_cli release \
                --operation-id "$operation_id" --coordinator-instance-id "$coordinator_instance_id" \
                --marker-generation "$marker_generation" --marker-sha256 "$published_marker_sha"
            validate_release_receipt_v2 "$completed"
            [[ -e $deployment_release_receipt ]] || copy_json_output 'durable resumed release receipt' "$completed" "$deployment_release_receipt"
            released_marker=1
            acceptance_deployment_marker_sha=$published_marker_sha
            commit_phase MARKER_RELEASED
            ;;
        deployment-quarantine-released)
            jq -e '.replayed == true' "$query" >/dev/null || die 'released query was not marked as replay'
            validate_release_receipt_v2 "$query"
            if [[ -e $deployment_release_receipt ]]; then
                [[ $(jq -cS 'del(.replayed)' "$query") == "$(jq -cS 'del(.replayed)' "$deployment_release_receipt")" ]] ||
                    die 'released query stable fields differ from durable local release receipt'
            else
                copy_json_output 'durable adopted release receipt' "$query" "$deployment_release_receipt"
            fi
            released_marker=1
            acceptance_deployment_marker_sha=$published_marker_sha
            commit_phase MARKER_RELEASED
            ;;
        *) die 'unexpected deployment marker release query state' ;;
    esac
}

validate_frozen_linux_B() {
    assert_strict_json_document 'Linux frozen B' "$bootstrap_linux_evidence"
    jq -e --arg op "$operation_id" '
        .schema_version == 1 and .state == "viewflow-v13-bootstrap-frozen" and
        .operation_id == $op and .journal.counts.protocol_1_3_startup == 1 and
        .pre_stop.deskflow_unit_active_state == "inactive" and .post_stop.unit_active_state == "inactive" and
        .post_stop.main_pid == 0 and .post_stop.exact_process_count == 0 and .post_stop.udp_44119_listener_count == 0
    ' "$bootstrap_linux_evidence" >/dev/null || die 'Linux frozen evidence B is invalid'
    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_STAGED) ]]; then
        [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) != active ]] ||
            die 'Linux v1.3 Viewflow was not frozen before Windows bootstrap'
    elif [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_FINALIZED_MARKER_HELD) ]]; then
        [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active &&
           $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) != active ]] ||
            die 'resumed Ls phase does not have Viewflow-only runtime'
    else
        [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active &&
           $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) == active ]] ||
            die 'resumed Lf phase does not have both v2 units active'
    fi
}

derive_windows_paths() {
    windows_operation_root="C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\$operation_id"
    windows_request_path="$windows_operation_root\\request.json"
    windows_launcher_path="$windows_operation_root\\start-viewflow-bootstrap.ps1"
    windows_installer_path="$windows_operation_root\\install-viewflow.ps1"
    windows_candidate_path="$windows_operation_root\\viewflowd.exe"
    windows_wrapper_path="$windows_operation_root\\viewflow-client.ps1"
    windows_rollback_path="$windows_operation_root\\rollback-viewflow.ps1"
    windows_prepared_path="$windows_operation_root\\bootstrap-prepared.json"
    windows_permit_path="$windows_operation_root\\mutation-permit.json"
    windows_raw_force_path="$windows_operation_root\\raw-force-release.json"
    windows_force_envelope_path="$windows_operation_root\\force-release-envelope.json"
    windows_stage_path="$windows_operation_root\\linux-stage-receipt.json"
    windows_install_path="$windows_operation_root\\windows-install-success.json"
    windows_exit_path="$windows_operation_root\\installer-exit.json"
    windows_readiness_receipt_path="$windows_operation_root\\readiness.json"
    windows_readiness_lock_path="$windows_operation_root\\readiness.lock"
    windows_commit_request_path="$windows_operation_root\\readiness-commit-request.json"
    windows_stop_evidence_path="$windows_operation_root\\launcher-stop-evidence.json"
    windows_rollback_manifest_path="$windows_operation_root\\rollback-manifest.json"
    windows_rollback_token_path="$windows_operation_root\\rollback-token.json"
    windows_recovery_bundle_path="$windows_operation_root\\recovery-bundle.json"
    windows_recovery_force_receipt_path="$windows_operation_root\\recovery-force-release.json"
    windows_rollback_receipt_path="$windows_operation_root\\windows-rollback-receipt.json"
    windows_rollback_claim_path="$windows_operation_root\\windows-rollback-dispatch-claim.json"
    windows_restart_intent_path="$windows_operation_root\\post-release-restart-intent.json"
    windows_restart_claim_path="$windows_operation_root\\post-release-restart-claim.json"
    windows_restart_terminal_path="$windows_operation_root\\post-release-restart-terminal.json"
}

make_bootstrap_request() {
    local created handoff_sha linux_sha
    derive_windows_paths
    handoff_sha=$(sha256 "$bootstrap_handoff_receipt")
    linux_sha=$(sha256 "$bootstrap_linux_evidence")
    if [[ -e $windows_bootstrap_request ]]; then
        assert_strict_json_document 'durable Windows bootstrap request' "$windows_bootstrap_request"
        windows_request_sha=$(sha256 "$windows_bootstrap_request")
        return
    fi
    created=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
    jq -cn --arg op "$operation_id" --arg sid "$windows_user_sid" --arg root "$windows_operation_root" \
        --arg launcher "$windows_launcher_path" --arg launcher_sha "$windows_launcher_sha" \
        --arg installer "$windows_installer_path" --arg installer_sha "$windows_installer_sha" \
        --arg candidate "$windows_candidate_path" --arg candidate_sha "$windows_viewflow_sha" \
        --arg wrapper "$windows_wrapper_path" --arg wrapper_sha "$windows_wrapper_sha" \
        --arg rollback "$windows_rollback_path" --arg rollback_sha "$windows_rollback_script_sha" \
        --arg h "$windows_operation_root\\marker-handoff-receipt.json" --arg hsha "$handoff_sha" \
        --arg b "$windows_operation_root\\linux-v13-frozen-evidence.json" --arg bsha "$linux_sha" \
        --arg p "$windows_prepared_path" --arg permit "$windows_permit_path" \
        --arg raw "$windows_raw_force_path" --arg f "$windows_force_envelope_path" \
        --arg ls "$windows_stage_path" --arg w "$windows_install_path" --arg exit "$windows_exit_path" \
        --arg ready "$windows_operation_root\\readiness.json" --arg lock "$windows_operation_root\\readiness.lock" \
        --arg commit "$windows_operation_root\\readiness-commit-request.json" \
        --arg manifest "$windows_operation_root\\rollback-manifest.json" --arg token "$windows_operation_root\\rollback-token.json" \
        --arg bundle "$windows_operation_root\\recovery-bundle.json" \
        --arg proof "$windows_operation_root\\linux-deactivation-proof.json" \
        --arg transcript "$windows_operation_root\\linux-deactivation-transcript.json" \
        --arg recovery "$windows_operation_root\\recovery-force-release.json" --arg created "$created" '
        {schema_version:1,state:"viewflow-windows-bootstrap-requested",operation_id:$op,user_sid:$sid,
         expected_session_id:1,expected_peer:"172.16.105.62:44119",expected_server_name:"viewflow-linux",
         expected_local_device_id:"00000000000000000000000000000001",expected_device_id:"00000000000000000000000000000002",
         expected_source_display_id:"00000000000000000000000000000101",launcher_path:$launcher,launcher_sha256:$launcher_sha,
         installer_path:$installer,installer_sha256:$installer_sha,candidate_path:$candidate,candidate_sha256:$candidate_sha,
         wrapper_path:$wrapper,wrapper_sha256:$wrapper_sha,rollback_script_path:$rollback,rollback_script_sha256:$rollback_sha,
         marker_handoff_receipt_path:$h,marker_handoff_receipt_sha256:$hsha,linux_frozen_evidence_path:$b,
         linux_frozen_evidence_sha256:$bsha,prepared_receipt_path:$p,mutation_permit_path:$permit,
         raw_force_release_receipt_path:$raw,force_release_envelope_path:$f,linux_stage_receipt_path:$ls,
         install_success_receipt_path:$w,installer_exit_receipt_path:$exit,readiness_receipt_path:$ready,
         readiness_lock_path:$lock,readiness_commit_request_path:$commit,rollback_manifest_path:$manifest,
         rollback_token_path:$token,recovery_bundle_path:$bundle,linux_deactivation_proof_path:$proof,
         linux_deactivation_transcript_path:$transcript,recovery_force_release_receipt_path:$recovery,created_at_utc:$created}
    ' >"$windows_bootstrap_request.tmp"
    chmod 0600 "$windows_bootstrap_request.tmp"
    ln -- "$windows_bootstrap_request.tmp" "$windows_bootstrap_request"
    rm -f -- "$windows_bootstrap_request.tmp"
    windows_request_sha=$(sha256 "$windows_bootstrap_request")
}

remote_prepare_and_start_once() {
    local command response=$secure_dir/launcher.json resumed_start=$secure_dir/launcher-resumed-start.json
    command="\$root='$windows_operation_root';if(!(Test-Path -LiteralPath \$root)){[void](New-Item -ItemType Directory -Path \$root -ErrorAction Stop)};\$item=Get-Item -LiteralPath \$root -Force;if((\$item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'reparse operation root'};\$acl=New-Object Security.AccessControl.DirectorySecurity;\$sid=New-Object Security.Principal.SecurityIdentifier('$windows_user_sid');\$acl.SetOwner(\$sid);\$acl.SetAccessRuleProtection(\$true,\$false);\$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(\$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')));\$sys=New-Object Security.Principal.SecurityIdentifier('S-1-5-18');\$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(\$sys,'FullControl','ContainerInherit,ObjectInherit','None','Allow')));Set-Acl -LiteralPath \$root -AclObject \$acl"
    if [[ $phase == WINDOWS_PUBLISH_INTENT ]]; then
        ssh_windows "$command" >/dev/null
        windows_create_or_verify "$windows_launcher_candidate" "$windows_launcher_path"
        windows_create_or_verify "$windows_installer_candidate" "$windows_installer_path"
        windows_create_or_verify "$windows_viewflow_candidate" "$windows_candidate_path"
        windows_create_or_verify "$windows_wrapper_candidate" "$windows_wrapper_path"
        windows_create_or_verify "$reviewed_rollback_script" "$windows_rollback_path"
        windows_create_or_verify "$bootstrap_handoff_receipt" "$windows_operation_root\\marker-handoff-receipt.json"
        windows_create_or_verify "$bootstrap_linux_evidence" "$windows_operation_root\\linux-v13-frozen-evidence.json"
        windows_create_or_verify "$windows_bootstrap_request" "$windows_request_path"
        commit_phase WINDOWS_START_INTENT
    fi
    if [[ $phase == WINDOWS_START_INTENT && $resume == 0 ]]; then
        capture_json_command 'Windows launcher start response' "$response" ssh_windows \
            "& '$windows_launcher_path' -Mode Start -RequestPath '$windows_request_path'"
        commit_phase WINDOWS_STARTED
    else
        capture_json_command 'Windows launcher status response' "$response" ssh_windows \
            "& '$windows_launcher_path' -Mode Status -RequestPath '$windows_request_path'"
        if [[ $phase == WINDOWS_START_INTENT && $(jq -er '.state' "$response") == viewflow-windows-bootstrap-absent ]]; then
            if ((pre_mutation_retry_active)); then
                reopen_pre_mutation_stop_intent || return
            fi
            capture_json_command 'Windows launcher first dispatch after proven-absent resume' "$resumed_start" ssh_windows \
                "& '$windows_launcher_path' -Mode Start -RequestPath '$windows_request_path'"
            response=$resumed_start
            commit_phase WINDOWS_STARTED
        fi
    fi
    jq -e --arg op "$operation_id" --arg request "$windows_request_sha" '
        .schema_version == 1 and .operation_id == $op and .request_sha256 == $request and
        (.state == "viewflow-windows-bootstrap-starting" or .state == "viewflow-windows-bootstrap-running" or
         .state == "viewflow-windows-bootstrap-succeeded" or .state == "viewflow-windows-bootstrap-failed")
    ' "$response" >/dev/null || die 'Windows one-shot launcher response is invalid'
}

validate_pre_mutation_retry_proof() {
    local proof=$1
    assert_strict_json_document 'pre-mutation retry proof' "$proof"
    jq -e --arg op "$operation_id" --arg root "$windows_operation_root" \
        --arg exe "$pre_mutation_old_executable_sha" --arg wrapper "$pre_mutation_old_wrapper_sha" \
        --arg task "$pre_mutation_old_task_xml_sha" --arg sid "$windows_user_sid" \
        --argjson process_id "$pre_mutation_old_process_id" --argjson parent_process_id "$pre_mutation_old_parent_process_id" \
        --arg creation_date "$pre_mutation_old_process_creation_date" \
        --arg request "$windows_request_sha" --arg installer "$windows_installer_sha" \
        --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" \
        --arg rollback "$windows_rollback_script_sha" --arg launcher "$windows_launcher_sha" \
        --arg candidate_wrapper "$windows_wrapper_sha" --arg candidate "$windows_viewflow_sha" '
        keys == ["launcher_state","old_executable_sha256","old_rollback_sha256","old_wrapper_sha256","operation_id","operation_root_acl_exact","remote_operation_root","request_sha256","schema_version","staged_file_acls_exact","staged_files","state","task","task_xml_sha256","viewflow_process"] and
        .schema_version == 1 and .state == "viewflow-pre-mutation-stop-intent-retryable" and
        .operation_id == $op and .remote_operation_root == $root and .request_sha256 == $request and
        .operation_root_acl_exact == true and .staged_file_acls_exact == true and
        .launcher_state == "viewflow-windows-bootstrap-absent" and
        .old_executable_sha256 == $exe and .old_wrapper_sha256 == $wrapper and
        .old_rollback_sha256 == $rollback and .task_xml_sha256 == $task and
        (.staged_files | keys) == ["install-viewflow.ps1","linux-v13-frozen-evidence.json","marker-handoff-receipt.json","request.json","rollback-viewflow.ps1","start-viewflow-bootstrap.ps1","viewflow-client.ps1","viewflowd.exe"] and
        .staged_files == {"install-viewflow.ps1":$installer,"linux-v13-frozen-evidence.json":$frozen,
                          "marker-handoff-receipt.json":$handoff,"request.json":$request,
                          "rollback-viewflow.ps1":$rollback,"start-viewflow-bootstrap.ps1":$launcher,
                          "viewflow-client.ps1":$candidate_wrapper,"viewflowd.exe":$candidate} and
        (.task | keys) == ["action_arguments","action_execute","action_working_directory","logon_type","principal_sid","run_level","state","task_path"] and
        .task.task_path == "\\Viewflow Peer" and .task.state == "Running" and
        .task.action_execute == "C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" and
        .task.action_arguments == "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflow-client.ps1\"" and
        .task.action_working_directory == "C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow" and
        .task.principal_sid == $sid and .task.logon_type == "Interactive" and .task.run_level == "Limited" and
        (.viewflow_process | keys) == ["command_line","creation_date","executable_path","owner_sid","parent_process_id","process_id","session_id"] and
        .viewflow_process.executable_path == "C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe" and
        .viewflow_process.session_id == 1 and .viewflow_process.owner_sid == $sid and
        .viewflow_process.process_id == $process_id and
        .viewflow_process.parent_process_id == $parent_process_id and
        .viewflow_process.creation_date == $creation_date and
        .viewflow_process.command_line == "\"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe\" connect --peer 172.16.105.62:44119 --server-name viewflow-linux --cert C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\peer.pem --key C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\peer.key --ca C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\ca.pem --input-backend native --device-id 00000000000000000000000000000002 --probe-interval-ms 1000 --probe-timeout-ms 3000"
    ' "$proof" >/dev/null || die 'pre-mutation retry proof is invalid'
}

reopen_pre_mutation_stop_intent() {
    local status=$secure_dir/pre-mutation-launcher-status.json live=$secure_dir/pre-mutation-live.json \
        temp command existing_sha reopening=0
    [[ $resume_pre_mutation_stop_intent == 1 && $resume == 1 ]] || die 'pre-mutation STOP_INTENT requires explicit retry authorization'
    validate_pre_mutation_stop_state_baseline
    require_sha256 '--pre-mutation-old-executable-sha256' "$pre_mutation_old_executable_sha"
    require_sha256 '--pre-mutation-old-wrapper-sha256' "$pre_mutation_old_wrapper_sha"
    require_sha256 '--pre-mutation-old-task-xml-sha256' "$pre_mutation_old_task_xml_sha"
    [[ $pre_mutation_old_process_id =~ ^[1-9][0-9]*$ && $pre_mutation_old_parent_process_id =~ ^[1-9][0-9]*$ ]] ||
        die 'pre-mutation old process IDs must be positive decimal integers'
    [[ $pre_mutation_old_process_creation_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z$ ]] ||
        die 'pre-mutation old process creation date must be canonical UTC with seven fractional digits'
    if [[ $phase == STOP_INTENT ]]; then
        jq -e --arg replacement "$replacement_flag_count" --arg successor "$successor_flag_count" '
            .schema_version == 2 and .phase == "STOP_INTENT" and
            .recovery.failure_phase == "WINDOWS_START_INTENT" and .recovery.mutation_possible == false and
            (($replacement == "0" and (.committed_artifacts | keys) == ["bootstrap_request","linux_frozen","marker_handoff","publish_receipt"]) or
             ($replacement == "4" and $successor == "0" and
              (.committed_artifacts | keys) == ["bootstrap_request","candidate_manifest","candidate_replacement_commit",
                                               "candidate_retirement_terminal","candidate_tree","linux_frozen","marker_handoff","publish_receipt"]) or
             ($successor == "2" and
              (.committed_artifacts | keys) == ["bootstrap_request","candidate_manifest","candidate_replacement_commit",
                                               "candidate_retirement_terminal","candidate_tree","coordinator_successor_receipt",
                                               "coordinator_successor_windows_prestate","linux_frozen","marker_handoff","publish_receipt"]))
        ' "$pre_mutation_stop_state_baseline_path" >/dev/null ||
            die 'sealed STOP_INTENT baseline is not the exact pre-mutation retry state'
        reopening=1
    elif [[ $phase == WINDOWS_START_INTENT ]]; then
        publish_pre_mutation_start_state_cas
    else
        die 'pre-mutation retry is not at an authorized phase'
    fi
    for temp in "$windows_prepared_receipt" "$windows_mutation_permit" "$windows_force_envelope" \
        "$linux_stage_receipt" "$bootstrap_windows_install_receipt" "$windows_installer_exit_receipt" \
        "$linux_finalize_receipt" "$local_windows_stop_evidence" "$recovery_publish_intent" \
        "$recovery_deployment_publish_receipt" "$deployment_release_receipt" "$linux_host_proof" \
        "$cpp_status_response" "$cpp_arm_response" "$cpp_cleanup_receipt" \
        "$rust_acceptance_arm_response" "$rust_acceptance_query_response" "$post_release_receipt" \
        "$windows_restart_receipt" "$local_windows_restart_intent" "$local_recovery_bundle" \
        "$linux_deactivation_transcript" "$linux_deactivation_proof" "$linux_containment_transcript" \
        "$local_windows_validation" "$local_windows_rollback_receipt"; do
        [[ ! -e $temp && ! -L $temp ]] || die 'pre-mutation retry found a later local artifact'
    done
    assert_linux_inactive
    assert_deployment_marker
    [[ ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]] || die 'pre-mutation retry found a runtime quarantine marker'
    capture_json_command 'pre-mutation launcher status' "$status" ssh_windows \
        "& '$windows_launcher_path' -Mode Status -RequestPath '$windows_request_path'"
    jq -e --arg op "$operation_id" --arg request "$windows_request_sha" '
        keys == ["operation_id","request_sha256","schema_version","state","task_name"] and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-absent" and
        .operation_id == $op and .request_sha256 == $request
    ' "$status" >/dev/null || die 'pre-mutation launcher is not absent'
    command="\$root='$windows_operation_root';\$expected=[ordered]@{'install-viewflow.ps1'='$windows_installer_sha';'linux-v13-frozen-evidence.json'='$(sha256 "$bootstrap_linux_evidence")';'marker-handoff-receipt.json'='$(sha256 "$bootstrap_handoff_receipt")';'request.json'='$windows_request_sha';'rollback-viewflow.ps1'='$windows_rollback_script_sha';'start-viewflow-bootstrap.ps1'='$windows_launcher_sha';'viewflow-client.ps1'='$windows_wrapper_sha';'viewflowd.exe'='$windows_viewflow_sha'};\$userSid='$windows_user_sid';function AssertAcl([string]\$path,[bool]\$directory){\$acl=Get-Acl -LiteralPath \$path -ErrorAction Stop;try{\$owner=([Security.Principal.SecurityIdentifier]::new(\$acl.Owner)).Value}catch{\$owner=([Security.Principal.NTAccount]::new(\$acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value};if(\$owner-ne\$userSid-or-not\$acl.AreAccessRulesProtected){throw 'unsafe ACL owner/protection'};\$rules=@(\$acl.Access);\$expectedCount=if(\$directory){2}else{1};if(\$rules.Count-ne\$expectedCount){throw 'unexpected ACL rule count'};\$seen=@{};foreach(\$rule in \$rules){try{\$ruleSid=([Security.Principal.SecurityIdentifier]::new(\$rule.IdentityReference.Value)).Value}catch{\$ruleSid=([Security.Principal.NTAccount]::new(\$rule.IdentityReference.Value)).Translate([Security.Principal.SecurityIdentifier]).Value};if(\$rule.AccessControlType-ne'Allow'-or\$rule.FileSystemRights-ne'FullControl'-or\$rule.IsInherited){throw 'unsafe ACL rule'};if(\$directory){if(\$rule.InheritanceFlags-ne'ContainerInherit, ObjectInherit'-or\$rule.PropagationFlags-ne'None'-or(\$ruleSid-ne\$userSid-and\$ruleSid-ne'S-1-5-18')){throw 'unsafe directory ACL rule'}}else{if(\$rule.InheritanceFlags-ne'None'-or\$rule.PropagationFlags-ne'None'-or\$ruleSid-ne\$userSid){throw 'unsafe file ACL rule'}};if(\$seen.ContainsKey(\$ruleSid)){throw 'duplicate ACL rule'};\$seen[\$ruleSid]=\$true}};\$rootItem=Get-Item -LiteralPath \$root -Force -ErrorAction Stop;if((\$rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'reparse operation root'};AssertAcl \$root \$true;\$items=@(Get-ChildItem -LiteralPath \$root -Force -ErrorAction Stop);if(\$items.Count-ne8-or@(\$items|Where-Object{\$_.PSIsContainer}).Count-ne0){throw 'unexpected staging members'};\$staged=[ordered]@{};foreach(\$leaf in \$expected.Keys){\$path=Join-Path \$root \$leaf;\$item=Get-Item -LiteralPath \$path -Force -ErrorAction Stop;if(\$item.PSIsContainer-or(\$item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'unsafe staged leaf'};AssertAcl \$path \$false;\$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath \$path).Hash.ToLowerInvariant();if(\$hash-ne\$expected[\$leaf]){throw 'staged hash mismatch'};\$staged[\$leaf]=\$hash};\$task=Get-ScheduledTask -TaskPath '\\' -TaskName 'Viewflow Peer' -ErrorAction Stop;try{\$principalSid=([Security.Principal.SecurityIdentifier]::new(\$task.Principal.UserId)).Value}catch{\$principalSid=([Security.Principal.NTAccount]::new(\$task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value};if(\$task.State-ne'Running'-or\$task.Actions.Count-ne1-or\$task.Actions[0].Execute-ne'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'-or\$task.Actions[0].Arguments-ne'-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1\"'-or\$task.Actions[0].WorkingDirectory-ne'C:\Users\wilf\AppData\Local\Programs\Viewflow'-or\$principalSid-ne'$windows_user_sid'-or\$task.Principal.LogonType-ne'Interactive'-or\$task.Principal.RunLevel-ne'Limited'){throw 'old task identity mismatch'};\$xml=Export-ScheduledTask -TaskPath '\\' -TaskName 'Viewflow Peer';\$enc=[System.Text.UnicodeEncoding]::new(\$false,\$true);[byte[]]\$xmlBytes=\$enc.GetPreamble()+\$enc.GetBytes(\$xml);\$sha=[Security.Cryptography.SHA256]::Create();try{\$xmlHash=([BitConverter]::ToString(\$sha.ComputeHash(\$xmlBytes))).Replace('-','').ToLowerInvariant()}finally{\$sha.Dispose()};if(\$xmlHash-ne'$pre_mutation_old_task_xml_sha'){throw 'old task XML mismatch'};\$oldExe='C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe';\$oldWrapper='C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1';\$oldRollback='C:\Users\wilf\AppData\Local\Programs\Viewflow\rollback-viewflow.ps1';\$exeHash=(Get-FileHash -Algorithm SHA256 -LiteralPath \$oldExe).Hash.ToLowerInvariant();\$wrapperHash=(Get-FileHash -Algorithm SHA256 -LiteralPath \$oldWrapper).Hash.ToLowerInvariant();\$rollbackHash=(Get-FileHash -Algorithm SHA256 -LiteralPath \$oldRollback).Hash.ToLowerInvariant();if(\$exeHash-ne'$pre_mutation_old_executable_sha'-or\$wrapperHash-ne'$pre_mutation_old_wrapper_sha'-or\$rollbackHash-ne'$windows_rollback_script_sha'){throw 'old installed identity mismatch'};\$procs=@(Get-CimInstance Win32_Process -Filter \"Name='viewflowd.exe'\");if(\$procs.Count-ne1){throw 'unexpected viewflowd count'};\$proc=\$procs[0];\$creationUtc=\$proc.CreationDate.ToUniversalTime().ToString('o');if(\$proc.ProcessId-ne$pre_mutation_old_process_id-or\$proc.ParentProcessId-ne$pre_mutation_old_parent_process_id-or\$creationUtc-ne'$pre_mutation_old_process_creation_date'){throw 'old process tuple changed'};\$ownerSid=(Invoke-CimMethod -InputObject \$proc -MethodName GetOwnerSid -ErrorAction Stop).Sid;\$expectedCommand='\"C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe\" connect --peer 172.16.105.62:44119 --server-name viewflow-linux --cert C:\Users\wilf\AppData\Local\Programs\Viewflow\identity\peer.pem --key C:\Users\wilf\AppData\Local\Programs\Viewflow\identity\peer.key --ca C:\Users\wilf\AppData\Local\Programs\Viewflow\identity\ca.pem --input-backend native --device-id 00000000000000000000000000000002 --probe-interval-ms 1000 --probe-timeout-ms 3000';if(\$proc.ExecutablePath-ne\$oldExe-or\$proc.SessionId-ne1-or\$proc.CommandLine-ne\$expectedCommand-or\$ownerSid-ne'$windows_user_sid'){throw 'old process identity mismatch'};[ordered]@{schema_version=1;state='viewflow-pre-mutation-stop-intent-retryable';operation_id='$operation_id';remote_operation_root=\$root;request_sha256='$windows_request_sha';launcher_state='viewflow-windows-bootstrap-absent';operation_root_acl_exact=\$true;staged_file_acls_exact=\$true;staged_files=\$staged;old_executable_sha256=\$exeHash;old_wrapper_sha256=\$wrapperHash;old_rollback_sha256=\$rollbackHash;task_xml_sha256=\$xmlHash;task=[ordered]@{task_path='\\Viewflow Peer';state=[string]\$task.State;action_execute=\$task.Actions[0].Execute;action_arguments=\$task.Actions[0].Arguments;action_working_directory=\$task.Actions[0].WorkingDirectory;principal_sid=\$principalSid;logon_type=[string]\$task.Principal.LogonType;run_level=[string]\$task.Principal.RunLevel};viewflow_process=[ordered]@{process_id=[int]\$proc.ProcessId;parent_process_id=[int]\$proc.ParentProcessId;creation_date=\$creationUtc;executable_path=\$proc.ExecutablePath;session_id=[int]\$proc.SessionId;owner_sid=\$ownerSid;command_line=\$proc.CommandLine}}|ConvertTo-Json -Compress -Depth 5"
    capture_json_command 'pre-mutation retry live proof' "$live" ssh_windows_stdin "$command"
    validate_pre_mutation_retry_proof "$live"
    if [[ -e $pre_mutation_retry_proof ]]; then
        validate_pre_mutation_retry_proof "$pre_mutation_retry_proof"
        existing_sha=$(sha256 "$pre_mutation_retry_proof")
        [[ $existing_sha == "$(sha256 "$live")" ]] || die 'pre-mutation retry proof changed across replay'
    else
        ((reopening == 1)) || die 'pre-start retry proof disappeared'
        publish_json_file 'durable pre-mutation retry proof' "$live" "$pre_mutation_retry_proof"
    fi
    if ((reopening == 1)); then
        publish_pre_mutation_start_state_cas
    else
        validate_pre_mutation_start_state_file "$coordinator_state"
    fi
}

windows_remote_exists() { ssh_windows "if(Test-Path -LiteralPath '$1'){exit 0}else{exit 3}" >/dev/null; }

sync_remote_receipt() {
    local label=$1 remote=$2 local_path=$3 temp=$secure_dir/sync.json
    if [[ -e $local_path ]]; then
        windows_read_file "$remote" "$temp"
        [[ $(sha256 "$temp") == "$(sha256 "$local_path")" ]] || die "$label changed remotely"
        rm -f -- "$temp"
    else
        windows_read_file "$remote" "$local_path"
    fi
    assert_strict_json_document "$label" "$local_path"
}

wait_remote_receipt() {
    local label=$1 remote=$2 local_path=$3 deadline=$((SECONDS + bootstrap_timeout_seconds))
    while ((SECONDS < deadline)); do
        if windows_remote_exists "$remote"; then sync_remote_receipt "$label" "$remote" "$local_path"; return; fi
        if [[ $remote != "$windows_exit_path" ]] && windows_remote_exists "$windows_exit_path"; then
            sync_remote_receipt 'Windows installer early exit' "$windows_exit_path" \
                "$windows_installer_exit_receipt"
            validate_windows_terminal_exit
            die "Windows installer terminated before $label"
        fi
        sleep 0.2
    done
    die "timed out waiting for $label"
}

validate_windows_prepared_P() {
    local psha hsha bsha manifest token bundle recovery
    psha=$(sha256 "$windows_prepared_receipt"); hsha=$(sha256 "$bootstrap_handoff_receipt"); bsha=$(sha256 "$bootstrap_linux_evidence")
    jq -e --arg op "$operation_id" --arg sid "$windows_user_sid" --arg request "$windows_request_sha" \
        --arg h "$hsha" --arg b "$bsha" --arg candidate "$windows_viewflow_sha" \
        --arg permit "$windows_permit_path" --arg f "$windows_force_envelope_path" --arg ls "$windows_stage_path" \
        --arg w "$windows_install_path" --arg exit "$windows_exit_path" \
        --arg ready "$windows_readiness_receipt_path" --arg lock "$windows_readiness_lock_path" \
        --arg commit "$windows_commit_request_path" --arg bundle "$windows_recovery_bundle_path" \
        --arg recovery "$windows_recovery_force_receipt_path" --arg proof "$windows_operation_root\\linux-deactivation-proof.json" \
        --arg transcript "$windows_operation_root\\linux-deactivation-transcript.json" '
        (keys == ["bootstrap_request_sha256","candidate","linux_frozen_evidence_sha256","marker_handoff_receipt","old_executable","old_task","operation_id","outputs","prepared_at_utc","rollback_authorization","rollback_mode","rollback_script","schema_version","state","user_sid","wrapper"]) and
        (.outputs | keys) == ["force_release_envelope_path","force_release_receipt_path","install_success_receipt_path","installer_exit_receipt_path","linux_deactivation_proof_path","linux_deactivation_transcript_path","linux_stage_receipt_path","mutation_permit_path","readiness_commit_request_path","readiness_lock_path","readiness_receipt_path","recovery_bundle_path","recovery_force_release_receipt_path"] and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-recovery-armed" and
        .rollback_mode == "bootstrap-v1.3" and .operation_id == $op and .user_sid == $sid and
        .bootstrap_request_sha256 == $request and .marker_handoff_receipt.sha256 == $h and
        .linux_frozen_evidence_sha256 == $b and .candidate.sha256 == $candidate and
        .outputs.mutation_permit_path == $permit and .outputs.force_release_envelope_path == $f and
        .outputs.linux_stage_receipt_path == $ls and .outputs.install_success_receipt_path == $w and
        .outputs.installer_exit_receipt_path == $exit and .outputs.readiness_receipt_path == $ready and
        .outputs.readiness_lock_path == $lock and .outputs.readiness_commit_request_path == $commit and
        .outputs.recovery_bundle_path == $bundle and .outputs.recovery_force_release_receipt_path == $recovery and
        .outputs.linux_deactivation_proof_path == $proof and .outputs.linux_deactivation_transcript_path == $transcript
    ' "$windows_prepared_receipt" >/dev/null || die 'Windows prepared P is invalid'
    [[ $psha =~ ^[0-9a-f]{64}$ ]] || die 'P hash failure'
    manifest=$(jq -er '.rollback_authorization.manifest_path' "$windows_prepared_receipt")
    token=$(jq -er '.rollback_authorization.token_path' "$windows_prepared_receipt")
    bundle=$(jq -er '.outputs.recovery_bundle_path' "$windows_prepared_receipt")
    recovery=$(jq -er '.outputs.recovery_force_release_receipt_path' "$windows_prepared_receipt")
    [[ $manifest == "$windows_rollback_manifest_path" && $token == "$windows_rollback_token_path" &&
       $bundle == "$windows_recovery_bundle_path" && $recovery == "$windows_recovery_force_receipt_path" ]] ||
        die 'P contains a non-canonical operation-root recovery path'
    prearm_windows_recovery
}

publish_mutation_permit() {
    local temp psha hsha bsha nonce issued manifest_sha token_sha
    reconcile_deployment_marker_phase
    assert_deployment_marker
    if [[ -e $windows_mutation_permit ]]; then
        assert_strict_json_document 'durable mutation permit' "$windows_mutation_permit"
    else
        psha=$(sha256 "$windows_prepared_receipt"); hsha=$(sha256 "$bootstrap_handoff_receipt"); bsha=$(sha256 "$bootstrap_linux_evidence")
        manifest_sha=$(jq -er '.rollback_authorization.manifest_sha256' "$windows_prepared_receipt")
        token_sha=$(jq -er '.rollback_authorization.token_sha256' "$windows_prepared_receipt")
        nonce=$(printf '%s' "$operation_id:$coordinator_instance_id:$psha" | sha256sum | awk '{print $1}')
        issued=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
        temp=$secure_dir/permit.json
        jq -cn --arg op "$operation_id" --arg sid "$windows_user_sid" --arg coordinator "$coordinator_instance_id" \
            --arg nonce "$nonce" --arg request "$windows_request_sha" --arg h "$hsha" --arg p "$psha" --arg b "$bsha" \
            --arg candidate "$windows_viewflow_sha" --arg wrapper "$windows_wrapper_sha" --arg rollback "$windows_rollback_script_sha" \
            --arg manifest "$manifest_sha" --arg token "$token_sha" --arg viewflow "$viewflow_sha" \
            --arg marker "$deployment_marker_sha" --arg unit "$viewflow_unit_sha" --arg issued "$issued" '
            {schema_version:1,state:"viewflow-windows-bootstrap-mutation-permitted",operation_id:$op,user_sid:$sid,
             coordinator_instance_id:$coordinator,permit_nonce:$nonce,bootstrap_request_sha256:$request,
             marker_handoff_receipt_sha256:$h,windows_prepared_receipt_sha256:$p,linux_frozen_evidence_sha256:$b,
             candidate_sha256:$candidate,wrapper_sha256:$wrapper,rollback_script_sha256:$rollback,
             rollback_manifest_sha256:$manifest,rollback_token_sha256:$token,linux_viewflowd_sha256:$viewflow,
             linux_deployment_marker_sha256:$marker,linux_viewflow_unit_sha256:$unit,issued_at_utc:$issued}
        ' >"$temp"
        publish_json_file 'mutation permit' "$temp" "$windows_mutation_permit"
    fi
    jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg viewflow "$viewflow_sha" --arg marker "$deployment_marker_sha" --arg unit "$viewflow_unit_sha" '
        (keys == ["bootstrap_request_sha256","candidate_sha256","coordinator_instance_id","issued_at_utc","linux_deployment_marker_sha256","linux_frozen_evidence_sha256","linux_viewflow_unit_sha256","linux_viewflowd_sha256","marker_handoff_receipt_sha256","operation_id","permit_nonce","rollback_manifest_sha256","rollback_script_sha256","rollback_token_sha256","schema_version","state","user_sid","windows_prepared_receipt_sha256","wrapper_sha256"]) and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-mutation-permitted" and
        .operation_id == $op and .coordinator_instance_id == $coordinator and
        .linux_viewflowd_sha256 == $viewflow and .linux_deployment_marker_sha256 == $marker and
        .linux_viewflow_unit_sha256 == $unit
    ' "$windows_mutation_permit" >/dev/null || die 'durable mutation permit is invalid'
    reconcile_deployment_marker_phase
    assert_deployment_marker
    commit_phase WINDOWS_PERMIT_PUBLISH_INTENT
    windows_create_or_verify "$windows_mutation_permit" "$windows_permit_path"
    commit_phase MUTATION_PERMITTED
}

validate_windows_force_F() {
    jq -e --arg op "$operation_id" --arg sid "$windows_user_sid" --arg request "$windows_request_sha" \
        --arg h "$(sha256 "$bootstrap_handoff_receipt")" --arg p "$(sha256 "$windows_prepared_receipt")" \
        --arg permit "$(sha256 "$windows_mutation_permit")" --arg b "$(sha256 "$bootstrap_linux_evidence")" \
        --arg raw "$windows_raw_force_path" '
        (keys == ["bootstrap_request_sha256","completed_at_utc","linux_frozen_evidence_sha256","marker_handoff_receipt_sha256","mutation_permit_sha256","operation_id","raw_force_release_receipt_path","raw_force_release_receipt_sha256","schema_version","state","user_sid","windows_prepared_receipt_sha256"]) and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-force-release-attested" and
        .operation_id == $op and .user_sid == $sid and .bootstrap_request_sha256 == $request and
        .marker_handoff_receipt_sha256 == $h and .windows_prepared_receipt_sha256 == $p and
        .mutation_permit_sha256 == $permit and .linux_frozen_evidence_sha256 == $b and
        .raw_force_release_receipt_path == $raw and (.raw_force_release_receipt_sha256 | test("^[0-9a-f]{64}$"))
    ' "$windows_force_envelope" >/dev/null || die 'Windows F-envelope is invalid'
}

stop_exact_windows_bootstrap() {
    local status=$secure_dir/windows-stop-status.json evidence=$secure_dir/windows-stop-evidence.json
    if [[ -e $local_windows_stop_evidence ]]; then validate_windows_stop_evidence "$local_windows_stop_evidence"; return; fi
    if [[ -z $recovery_failure_phase || $(phase_rank "$recovery_failure_phase") -lt $(phase_rank WINDOWS_START_INTENT) ]]; then
        jq -cn --arg op "$operation_id" --arg request "$windows_request_sha" \
            '{schema_version:1,state:"viewflow-windows-bootstrap-no-worker-stopped",operation_id:$op,
              request_sha256:$request,status_sha256:"0000000000000000000000000000000000000000000000000000000000000000"}' >"$evidence"
        publish_json_file 'durable pre-dispatch no-worker evidence' "$evidence" "$local_windows_stop_evidence"
        validate_windows_stop_evidence "$local_windows_stop_evidence"
        return
    fi
    capture_json_command 'Windows bootstrap pre-stop status' "$status" ssh_windows \
        "& '$windows_launcher_path' -Mode Status -RequestPath '$windows_request_path'" || return
    if jq -e --arg op "$operation_id" --arg request "$windows_request_sha" '
        keys == ["operation_id","request_sha256","schema_version","state","task_name"] and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-absent" and
        .operation_id == $op and .request_sha256 == $request
    ' "$status" >/dev/null; then
        jq -cn --arg op "$operation_id" --arg request "$windows_request_sha" --arg status "$(sha256 "$status")" \
            '{schema_version:1,state:"viewflow-windows-bootstrap-no-worker-stopped",operation_id:$op,
              request_sha256:$request,status_sha256:$status}' >"$evidence"
    else
        capture_json_command 'exact Windows bootstrap stop evidence' "$evidence" ssh_windows \
            "& '$windows_launcher_path' -Mode Stop -RequestPath '$windows_request_path'" || return
        windows_remote_exists "$windows_stop_evidence_path" || die 'launcher Stop returned without durable stop evidence'
    fi
    publish_json_file 'durable Windows stop evidence' "$evidence" "$local_windows_stop_evidence"
    validate_windows_stop_evidence "$local_windows_stop_evidence"
}

validate_windows_identity_scalar() {
    local document=$1 json_path=$2 contract=$3
    "$FD_GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \
        "$FD_GATE_PYTHON" -I -E -c 'import json,pathlib,re,sys
document,path,contract=sys.argv[1:]
try:
 value=json.loads(pathlib.Path(document).read_text(encoding="utf-8"))
 for component in path.split("."):
  value=value[component]
except (KeyError,TypeError,ValueError,UnicodeDecodeError,OSError):
 raise SystemExit(1)
ok=({
 "canonical-filetime":lambda v:type(v) is str and re.fullmatch(r"[1-9][0-9]{16,18}",v) is not None,
 "positive-uint32":lambda v:type(v) is int and 1<=v<=4294967295,
 "zero-uint32":lambda v:type(v) is int and 0<=v<=4294967295,
 "session-one":lambda v:type(v) is int and v==1,
 "utc-milliseconds":lambda v:type(v) is str and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",v) is not None,
 }).get(contract)
raise SystemExit(0 if ok is not None and ok(value) else 1)' "$document" "$json_path" "$contract" ||
        die "non-canonical Windows identity scalar: $json_path ($contract)"
}

validate_windows_stop_evidence() {
    local evidence=$1
    assert_strict_json_document 'Windows stop evidence' "$evidence"
    jq -e --arg op "$operation_id" --arg request "$windows_request_sha" '
        .schema_version == 1 and .operation_id == $op and .request_sha256 == $request and
        (if .state == "viewflow-windows-bootstrap-no-worker-stopped" then
            keys == ["operation_id","request_sha256","schema_version","state","status_sha256"] and
            (.status_sha256 | test("^[0-9a-f]{64}$"))
         else .state == "viewflow-windows-bootstrap-stopped" and
            keys == ["claim_sha256","installer_process_count","operation_id","request_sha256","schema_version","state","stopped_at_utc","task_name","task_state","task_xml_sha256","worker_pid","worker_process_start_filetime_utc"] and
            .task_name == ("Viewflow Deployment " + $op) and
            (.installer_process_count | type == "number" and . == floor and . == 0) and .task_state == "Disabled" and
            (.claim_sha256 | test("^[0-9a-f]{64}$")) and (.task_xml_sha256 | test("^[0-9a-f]{64}$")) and
            (.worker_pid | type == "number" and . == floor and . >= 1 and . <= 4294967295) and
            (.worker_process_start_filetime_utc | test("^[1-9][0-9]{16,18}$")) and
            (.stopped_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) end)
    ' "$evidence" >/dev/null || die 'durable Windows stop evidence is invalid'
    if jq -e '.state == "viewflow-windows-bootstrap-stopped"' "$evidence" >/dev/null; then
        validate_windows_identity_scalar "$evidence" worker_pid positive-uint32
        validate_windows_identity_scalar "$evidence" worker_process_start_filetime_utc canonical-filetime
        validate_windows_identity_scalar "$evidence" installer_process_count zero-uint32
        validate_windows_identity_scalar "$evidence" stopped_at_utc utc-milliseconds
    fi
}

run_linux_stage() {
    "$linux_stage" stage --viewflow-candidate "$viewflow_candidate" --viewflow-sha256 "$viewflow_sha" \
        --deployment-marker-candidate "$deployment_marker_candidate" --deployment-marker-sha256 "$deployment_marker_sha" \
        --viewflow-unit-candidate "$viewflow_unit_candidate" --viewflow-unit-sha256 "$viewflow_unit_sha" \
        --operation-id "$operation_id" --source-display-id "$source_display_id_lower" --target-device-id "$target_device_id_lower" \
        --coordinator-instance-id "$coordinator_instance_id_lower" --marker-generation "$marker_generation" \
        --bootstrap-linux-evidence "$bootstrap_linux_evidence" --bootstrap-handoff-receipt "$bootstrap_handoff_receipt" \
        --windows-bootstrap-request "$windows_bootstrap_request" --windows-prepared-receipt "$windows_prepared_receipt" \
        --windows-mutation-permit "$windows_mutation_permit" --windows-force-release-envelope "$windows_force_envelope" \
        --deployment-publish-receipt "$deployment_publish_receipt" --windows-viewflow-sha256 "$windows_viewflow_sha" \
        --windows-user-sid "$windows_user_sid" --receipt-output "$linux_stage_receipt" --readiness-timeout-seconds 120
    windows_create_or_verify "$linux_stage_receipt" "$windows_stage_path"
    commit_phase LINUX_STAGED
}

validate_existing_linux_stage() {
    assert_strict_json_document 'existing Linux stage receipt' "$linux_stage_receipt"
    jq -e --arg op "$operation_id" --arg b "$(sha256 "$bootstrap_linux_evidence")" \
        --arg f "$(sha256 "$windows_force_envelope")" --arg marker "$published_marker_sha" \
        --arg viewflow "$viewflow_sha" --arg marker_tool "$deployment_marker_sha" --arg unit "$viewflow_unit_sha" '
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-staged" and
        .operation_id == $op and .protocol_version == "2.1" and
        .evidence_hashes.linux_frozen_evidence == $b and
        .evidence_hashes.windows_force_release_envelope == $f and
        .marker.sha256 == $marker and .artifact_hashes.staged_viewflowd == $viewflow and
        .artifact_hashes.staged_deployment_marker_tool == $marker_tool and
        .artifact_hashes.staged_viewflow_unit == $unit and
        .freeze_state.deskflow_unit_active_state == "inactive" and
        .freeze_state.deskflow_unit_main_pid == 0 and .freeze_state.runtime_marker_present == false
    ' "$linux_stage_receipt" >/dev/null || die 'existing Linux stage receipt is invalid'
}

validate_windows_W_schema5() {
    local linux_sha raw_sha handoff_sha prepared_sha permit_sha stage_sha request_sha old_sha adopted_task
    linux_sha=$(sha256 "$bootstrap_linux_evidence"); raw_sha=$(jq -er '.raw_force_release_receipt_sha256' "$windows_force_envelope")
    handoff_sha=$(sha256 "$bootstrap_handoff_receipt"); prepared_sha=$(sha256 "$windows_prepared_receipt")
    permit_sha=$(sha256 "$windows_mutation_permit"); stage_sha=$(sha256 "$linux_stage_receipt"); request_sha=$(sha256 "$windows_bootstrap_request")
    old_sha=$(jq -er '.old_executable.sha256' "$windows_prepared_receipt")
    jq -e --arg op "$operation_id" --arg linux "$linux_sha" --arg raw "$raw_sha" --arg old "$old_sha" \
        --arg handoff "$handoff_sha" --arg prepared "$prepared_sha" --arg permit "$permit_sha" \
        --arg stage "$stage_sha" --arg request "$request_sha" --arg candidate "$windows_viewflow_sha" \
        --arg wrapper "$windows_wrapper_sha" --arg sid "$windows_user_sid" '
        def hash: type == "string" and test("^[0-9a-f]{64}$");
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        def utc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$");
        (keys == ["bootstrap_request_sha256","commit_mode","commit_nonce","commit_request_sha256","committed_at_utc","committed_by_daemon","completed_at_utc","device_id","force_release_receipt_sha256","installed_wrapper_sha256","linux_frozen_evidence_sha256","linux_stage_receipt_sha256","marker_handoff_receipt_sha256","mutation_permit_sha256","new_process_pid","new_process_session_id","new_process_start_filetime","new_process_user_sid","new_viewflow_executable_sha256","old_viewflow_executable_sha256","operation_id","peer","protocol_version","readiness_connection_generation","readiness_established_at_utc","readiness_lock_sha256","readiness_receipt_sha256","scheduled_task_xml_sha256","schema_version","state","windows_prepared_receipt_sha256"]) and
        .schema_version == 5 and .state == "viewflow-v2-windows-installed" and .operation_id == $op and
        .commit_mode == "bootstrap-v1.3" and .committed_by_daemon == true and
        (.commit_nonce | type == "string" and test("^[0-9a-f]{32}$")) and (.commit_request_sha256 | hash) and
        .linux_frozen_evidence_sha256 == $linux and .force_release_receipt_sha256 == $raw and
        .marker_handoff_receipt_sha256 == $handoff and .windows_prepared_receipt_sha256 == $prepared and
        .mutation_permit_sha256 == $permit and .linux_stage_receipt_sha256 == $stage and
        .bootstrap_request_sha256 == $request and
        ([.force_release_receipt_sha256,.marker_handoff_receipt_sha256,.windows_prepared_receipt_sha256,
          .mutation_permit_sha256,.linux_stage_receipt_sha256,.bootstrap_request_sha256] | unique | length == 6) and
        .new_viewflow_executable_sha256 == $candidate and .old_viewflow_executable_sha256 == $old and
        .installed_wrapper_sha256 == $wrapper and (.scheduled_task_xml_sha256 | hash) and
        .new_process_user_sid == $sid and (.new_process_pid | uint53 and . > 0) and
        (.new_process_start_filetime | type == "string" and test("^[1-9][0-9]{0,19}$")) and .new_process_session_id == 1 and
        (.readiness_receipt_sha256 | hash) and (.readiness_lock_sha256 | hash) and
        (.readiness_connection_generation | uint53 and . > 0) and
        .protocol_version == "2.1" and .peer == "172.16.105.62:44119" and
        .device_id == "00000000000000000000000000000002" and
        (.readiness_established_at_utc | utc) and (.completed_at_utc | utc) and (.committed_at_utc | utc) and
        .readiness_established_at_utc <= .completed_at_utc and .completed_at_utc == .committed_at_utc
    ' "$bootstrap_windows_install_receipt" >/dev/null || die 'daemon-authored Windows schema-5 W is invalid'
    adopted_task=$(jq -er '.scheduled_task_xml_sha256' "$bootstrap_windows_install_receipt")
    [[ -z $windows_task_xml_sha || $windows_task_xml_sha == "$adopted_task" ]] || die 'W task XML SHA differs from optional override'
    windows_task_xml_sha=$adopted_task
}

validate_operation_readiness_chain() {
    local receipt=$secure_dir/readiness.json lock=$secure_dir/readiness.lock request=$secure_dir/readiness-commit-request.json
    local receipt_sha lock_sha request_sha raw_sha
    windows_read_file "$windows_readiness_receipt_path" "$receipt"
    windows_read_file "$windows_readiness_lock_path" "$lock"
    windows_read_file "$windows_commit_request_path" "$request"
    receipt_sha=$(sha256 "$receipt"); lock_sha=$(sha256 "$lock"); request_sha=$(sha256 "$request")
    [[ $receipt_sha == "$(jq -er '.readiness_receipt_sha256' "$bootstrap_windows_install_receipt")" &&
       $lock_sha == "$(jq -er '.readiness_lock_sha256' "$bootstrap_windows_install_receipt")" &&
       $request_sha == "$(jq -er '.commit_request_sha256' "$bootstrap_windows_install_receipt")" ]] ||
        die 'operation-root readiness artifacts do not match W'
    jq -e --arg op "$operation_id" --arg exe "$windows_viewflow_sha" --arg sid "$windows_user_sid" \
        --arg lock_path "$windows_readiness_lock_path" --arg lock_sha "$lock_sha" \
        --argjson pid "$(jq -er '.new_process_pid' "$bootstrap_windows_install_receipt")" \
        --arg start "$(jq -er '.new_process_start_filetime' "$bootstrap_windows_install_receipt")" \
        --argjson generation "$(jq -er '.readiness_connection_generation' "$bootstrap_windows_install_receipt")" \
        --arg established "$(jq -er '.readiness_established_at_utc' "$bootstrap_windows_install_receipt")" '
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        (keys == ["connection_generation","daemon_executable_sha256","daemon_pid","daemon_process_start_filetime","daemon_session_id","daemon_user_sid","established_at_utc","input_backend","local_device_id","operation_id","peer_address","probe_max_round_trip_ns","probe_max_uncertainty_ns","probe_round_trip_ns","probe_uncertainty_ns","protocol_major","protocol_minor","readiness_lock_path","readiness_lock_sha256","schema_version","server_name","state","validity"]) and
        .schema_version == 1 and .state == "viewflow-post-mtls-readiness-established" and
        .validity == "while-readiness-lock-is-held" and .operation_id == $op and
        .daemon_executable_sha256 == $exe and .daemon_pid == $pid and .daemon_process_start_filetime == $start and
        .connection_generation == $generation and .established_at_utc == $established and
        .daemon_session_id == 1 and .daemon_user_sid == $sid and
        .input_backend == "native" and .local_device_id == "00000000000000000000000000000002" and
        .peer_address == "172.16.105.62:44119" and .server_name == "viewflow-linux" and
        .protocol_major == 2 and .protocol_minor == 1 and .probe_max_round_trip_ns == 33333334 and
        .probe_max_uncertainty_ns == 4000000 and (.probe_round_trip_ns | uint53) and (.probe_uncertainty_ns | uint53) and
        .probe_round_trip_ns <= 33333334 and .probe_uncertainty_ns <= 4000000 and
        .readiness_lock_path == $lock_path and .readiness_lock_sha256 == $lock_sha
    ' "$receipt" >/dev/null || die 'operation-root readiness receipt is invalid'
    jq -e --arg op "$operation_id" --argjson pid "$(jq -er '.new_process_pid' "$bootstrap_windows_install_receipt")" \
        --arg start "$(jq -er '.new_process_start_filetime' "$bootstrap_windows_install_receipt")" \
        --argjson generation "$(jq -er '.readiness_connection_generation' "$bootstrap_windows_install_receipt")" '
        (keys == ["connection_generation","daemon_pid","daemon_process_start_filetime","operation_id","schema_version","state"]) and
        .schema_version == 1 and .state == "viewflow-post-mtls-readiness-lock" and .operation_id == $op and
        .daemon_pid == $pid and .daemon_process_start_filetime == $start and .connection_generation == $generation
    ' "$lock" >/dev/null || die 'operation-root readiness lock is invalid'
    raw_sha=$(jq -er '.raw_force_release_receipt_sha256' "$windows_force_envelope")
    jq -e --arg op "$operation_id" --arg raw "$raw_sha" --arg h "$(sha256 "$bootstrap_handoff_receipt")" \
        --arg p "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
        --arg ls "$(sha256 "$linux_stage_receipt")" --arg request "$(sha256 "$windows_bootstrap_request")" \
        --arg old "$(jq -er '.old_executable.sha256' "$windows_prepared_receipt")" --arg new "$windows_viewflow_sha" \
        --arg wrapper "$windows_wrapper_sha" --arg task "$windows_task_xml_sha" \
        --arg nonce "$(jq -er '.commit_nonce' "$bootstrap_windows_install_receipt")" \
        --arg ready "$receipt_sha" --arg lock "$lock_sha" \
        --arg linux "$(sha256 "$bootstrap_linux_evidence")" \
        --argjson pid "$(jq -er '.new_process_pid' "$bootstrap_windows_install_receipt")" \
        --arg start "$(jq -er '.new_process_start_filetime' "$bootstrap_windows_install_receipt")" \
        --argjson generation "$(jq -er '.readiness_connection_generation' "$bootstrap_windows_install_receipt")" '
        def utc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$");
        (keys == ["bootstrap_request_sha256","commit_nonce","connection_generation","daemon_pid","daemon_process_start_filetime","force_release_receipt_sha256","installed_wrapper_sha256","linux_frozen_evidence_sha256","linux_stage_receipt_sha256","marker_handoff_receipt_sha256","mode","mutation_permit_sha256","new_viewflow_executable_sha256","old_viewflow_executable_sha256","operation_id","readiness_lock_sha256","readiness_receipt_sha256","requested_at_utc","scheduled_task_xml_sha256","schema_version","state","windows_prepared_receipt_sha256"]) and
        .schema_version == 5 and .state == "viewflow-install-commit-request" and .mode == "bootstrap-v1.3" and
        .operation_id == $op and .commit_nonce == $nonce and .daemon_pid == $pid and
        .daemon_process_start_filetime == $start and .connection_generation == $generation and
        .readiness_receipt_sha256 == $ready and .readiness_lock_sha256 == $lock and (.requested_at_utc | utc) and
        .force_release_receipt_sha256 == $raw and .marker_handoff_receipt_sha256 == $h and
        .windows_prepared_receipt_sha256 == $p and .mutation_permit_sha256 == $permit and
        .linux_stage_receipt_sha256 == $ls and .bootstrap_request_sha256 == $request and
        ([.force_release_receipt_sha256,.marker_handoff_receipt_sha256,.windows_prepared_receipt_sha256,
          .mutation_permit_sha256,.linux_stage_receipt_sha256,.bootstrap_request_sha256] | unique | length == 6) and
        .linux_frozen_evidence_sha256 == $linux and .old_viewflow_executable_sha256 == $old and .new_viewflow_executable_sha256 == $new and
        .installed_wrapper_sha256 == $wrapper and .scheduled_task_xml_sha256 == $task
    ' "$request" >/dev/null || die 'operation-root readiness commit request is invalid'
}

validate_windows_terminal_exit() {
    jq -e --arg op "$operation_id" --arg request "$windows_request_sha" '
        (keys == ["claim_sha256","completed_at_utc","exit_code","installer_command_sha256","operation_id","request_sha256","schema_version","state"]) and
        .schema_version == 1 and .operation_id == $op and .request_sha256 == $request and
        ((.state == "viewflow-windows-bootstrap-succeeded" and .exit_code == 0) or
         (.state == "viewflow-windows-bootstrap-failed" and (.exit_code | type == "number" and . != 0))) and
        (.claim_sha256 | test("^[0-9a-f]{64}$")) and (.installer_command_sha256 | test("^[0-9a-f]{64}$"))
    ' "$windows_installer_exit_receipt" >/dev/null || die 'Windows launcher terminal exit is invalid'
    jq -e '.state == "viewflow-windows-bootstrap-succeeded" and .exit_code == 0' "$windows_installer_exit_receipt" >/dev/null ||
        die 'Windows bootstrap installer did not succeed'
}

wait_windows_terminal_exit() {
    wait_remote_receipt 'Windows installer exit' "$windows_exit_path" "$windows_installer_exit_receipt"
    validate_windows_terminal_exit
    commit_phase WINDOWS_TERMINAL
}

run_linux_finalize() {
    "$linux_finalize" finalize --viewflow-candidate "$viewflow_candidate" --viewflow-sha256 "$viewflow_sha" \
        --deployment-marker-candidate "$deployment_marker_candidate" --deployment-marker-sha256 "$deployment_marker_sha" \
        --viewflow-unit-candidate "$viewflow_unit_candidate" --viewflow-unit-sha256 "$viewflow_unit_sha" \
        --deskflow-candidate "$deskflow_candidate" --deskflow-sha256 "$deskflow_sha" \
        --deskflow-core-candidate "$deskflow_core_candidate" --deskflow-core-sha256 "$deskflow_core_sha" \
        --deskflow-dropin-candidate "$deskflow_dropin_candidate" --deskflow-dropin-sha256 "$deskflow_dropin_sha" \
        --deskflow-provenance-manifest "$deskflow_provenance_manifest" --deskflow-provenance-sha256 "$deskflow_provenance_sha" \
        --stage-receipt "$linux_stage_receipt" --bootstrap-linux-evidence "$bootstrap_linux_original" \
        --bootstrap-handoff-receipt "$bootstrap_handoff_receipt" --windows-bootstrap-request "$windows_bootstrap_request" \
        --windows-prepared-receipt "$windows_prepared_receipt" --windows-mutation-permit "$windows_mutation_permit" \
        --windows-force-release-envelope "$windows_force_original" --bootstrap-windows-install-receipt "$windows_install_original" \
        --deployment-publish-receipt "$deployment_publish_receipt" --operation-id "$operation_id" \
        --source-display-id "$source_display_id_lower" --target-device-id "$target_device_id_lower" \
        --coordinator-instance-id "$coordinator_instance_id_lower" --marker-generation "$marker_generation" \
        --windows-viewflow-sha256 "$windows_viewflow_sha" --windows-wrapper-sha256 "$windows_wrapper_sha" \
        --windows-task-xml-sha256 "$windows_task_xml_sha" --windows-user-sid "$windows_user_sid" \
        --receipt-output "$linux_finalize_receipt" --readiness-timeout-seconds 120
    bootstrap_linux_evidence=$(jq -er '.consumed_evidence.linux_frozen_evidence' "$linux_finalize_receipt")
    windows_force_envelope=$(jq -er '.consumed_evidence.windows_force_release_envelope' "$linux_finalize_receipt")
    bootstrap_windows_install_receipt=$(jq -er '.consumed_evidence.windows_install_receipt' "$linux_finalize_receipt")
    commit_phase LINUX_FINALIZED_MARKER_HELD
}

validate_existing_linux_finalize() {
    assert_strict_json_document 'existing Linux finalize receipt' "$linux_finalize_receipt"
    jq -e --arg op "$operation_id" --arg stage "$(sha256 "$linux_stage_receipt")" \
        --arg w "$(sha256 "$bootstrap_windows_install_receipt")" --arg marker "$published_marker_sha" '
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-finalized" and
        .operation_id == $op and .protocol_version == "2.1" and
        .stage_receipt_sha256 == $stage and .evidence_hashes.windows_install_receipt == $w and
        .marker_sha256 == $marker
    ' "$linux_finalize_receipt" >/dev/null || die 'existing Linux finalize receipt is invalid'
}

rollback_linux_two_phase() {
    if [[ -e $linux_finalize_receipt || -e ${linux_stage_receipt}.backup/consume-intent.json ]]; then
        "$linux_finalize" rollback --viewflow-candidate "$viewflow_candidate" --viewflow-sha256 "$viewflow_sha" \
            --deployment-marker-candidate "$deployment_marker_candidate" --deployment-marker-sha256 "$deployment_marker_sha" \
            --viewflow-unit-candidate "$viewflow_unit_candidate" --viewflow-unit-sha256 "$viewflow_unit_sha" \
            --deskflow-candidate "$deskflow_candidate" --deskflow-sha256 "$deskflow_sha" \
            --deskflow-core-candidate "$deskflow_core_candidate" --deskflow-core-sha256 "$deskflow_core_sha" \
            --deskflow-dropin-candidate "$deskflow_dropin_candidate" --deskflow-dropin-sha256 "$deskflow_dropin_sha" \
            --deskflow-provenance-manifest "$deskflow_provenance_manifest" --deskflow-provenance-sha256 "$deskflow_provenance_sha" \
            --stage-receipt "$linux_stage_receipt" --bootstrap-linux-evidence "$bootstrap_linux_original" \
            --bootstrap-handoff-receipt "$bootstrap_handoff_receipt" --windows-bootstrap-request "$windows_bootstrap_request" \
            --windows-prepared-receipt "$windows_prepared_receipt" --windows-mutation-permit "$windows_mutation_permit" \
            --windows-force-release-envelope "$windows_force_original" --bootstrap-windows-install-receipt "$windows_install_original" \
            --deployment-publish-receipt "$deployment_publish_receipt" --operation-id "$operation_id" \
            --source-display-id "$source_display_id_lower" --target-device-id "$target_device_id_lower" --coordinator-instance-id "$coordinator_instance_id_lower" \
            --marker-generation "$marker_generation" --windows-viewflow-sha256 "$windows_viewflow_sha" \
            --windows-wrapper-sha256 "$windows_wrapper_sha" --windows-task-xml-sha256 "$windows_task_xml_sha" \
            --windows-user-sid "$windows_user_sid" --receipt-output "$linux_finalize_receipt" --readiness-timeout-seconds 120 \
            --active-recovery-marker-publish-receipt "$active_marker_publish_receipt" \
            --active-recovery-marker-operation-id "$active_marker_operation_id" \
            --active-recovery-marker-coordinator-instance-id "$coordinator_instance_id_lower" \
            --active-recovery-marker-generation "$active_marker_generation" \
            --active-recovery-marker-sha256 "$active_marker_sha"
    elif [[ -d ${linux_stage_receipt}.backup || -e $linux_stage_receipt ]]; then
        "$linux_stage" rollback --viewflow-candidate "$viewflow_candidate" --viewflow-sha256 "$viewflow_sha" \
            --deployment-marker-candidate "$deployment_marker_candidate" --deployment-marker-sha256 "$deployment_marker_sha" \
            --viewflow-unit-candidate "$viewflow_unit_candidate" --viewflow-unit-sha256 "$viewflow_unit_sha" \
            --operation-id "$operation_id" --source-display-id "$source_display_id_lower" --target-device-id "$target_device_id_lower" \
            --coordinator-instance-id "$coordinator_instance_id_lower" --marker-generation "$marker_generation" \
            --bootstrap-linux-evidence "$bootstrap_linux_original" --bootstrap-handoff-receipt "$bootstrap_handoff_receipt" \
            --windows-bootstrap-request "$windows_bootstrap_request" --windows-prepared-receipt "$windows_prepared_receipt" \
            --windows-mutation-permit "$windows_mutation_permit" --windows-force-release-envelope "$windows_force_original" \
            --deployment-publish-receipt "$deployment_publish_receipt" --windows-viewflow-sha256 "$windows_viewflow_sha" \
            --windows-user-sid "$windows_user_sid" --receipt-output "$linux_stage_receipt" --readiness-timeout-seconds 120
    else
        graceful_linux_containment
    fi
}

validate_exact_bootstrap_cross_chain() {
    local wsha lssha exitsha lfsha temp=$secure_dir/cross-chain.json
    wsha=$(sha256 "$bootstrap_windows_install_receipt"); lssha=$(sha256 "$linux_stage_receipt"); exitsha=$(sha256 "$windows_installer_exit_receipt")
    validate_windows_W_schema5
    jq -e --arg op "$operation_id" --arg stage "$lssha" --arg w "$wsha" --arg marker "$published_marker_sha" '
        .schema_version == 1 and .state == "viewflow-linux-bootstrap-finalized" and
        .operation_id == $op and .protocol_version == "2.1" and .stage_receipt_sha256 == $stage and
        .evidence_hashes.windows_install_receipt == $w and .marker_sha256 == $marker
    ' "$linux_finalize_receipt" >/dev/null ||
        die 'Linux Lf does not exactly bind Ls/W and retained marker'
    lfsha=$(sha256 "$linux_finalize_receipt")
    [[ $exitsha =~ ^[0-9a-f]{64}$ ]] || die 'launcher exit hash failure'
    if [[ $(phase_rank "$phase") -lt $(phase_rank MARKER_RELEASED) ]]; then
        assert_deployment_marker || die 'VFDQT001 was not retained through Lf'
    else
        [[ $released_marker == 1 ]] || die 'released durable phase lacks exact VFDQR001 reconciliation'
    fi
    jq -cn --arg op "$operation_id" --arg h "$(sha256 "$bootstrap_handoff_receipt")" \
        --arg b "$(sha256 "$bootstrap_linux_evidence")" --arg request "$(sha256 "$windows_bootstrap_request")" \
        --arg p "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
        --arg f "$(sha256 "$windows_force_envelope")" --arg ls "$lssha" --arg w "$wsha" \
        --arg exit "$exitsha" --arg lf "$lfsha" --arg marker "$published_marker_sha" '
        {schema_version:1,state:"viewflow-cross-host-bootstrap-bound",operation_id:$op,protocol_version:"2.1",
         marker_handoff_receipt_sha256:$h,linux_frozen_evidence_sha256:$b,bootstrap_request_sha256:$request,
         windows_prepared_receipt_sha256:$p,mutation_permit_sha256:$permit,force_release_envelope_sha256:$f,
         linux_stage_receipt_sha256:$ls,windows_install_receipt_sha256:$w,windows_installer_exit_receipt_sha256:$exit,
         linux_finalize_receipt_sha256:$lf,deployment_marker_sha256:$marker}
    ' >"$temp"
    if [[ -e $linux_host_proof ]]; then
        [[ $(sha256 "$linux_host_proof") == "$(sha256 "$temp")" ]] || die 'cross-host chain proof changed on resume'
    else
        publish_json_file 'exact cross-host bootstrap chain' "$temp" "$linux_host_proof"
    fi
}

validate_release_receipt_v2() {
    local path=$1 durable expected_durable prefix_sha suffix_sha embedded_sha embedded_recorded op_len embedded_op
    local source_hex target_hex coordinator_hex generation committed reserved
    jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg marker "$DEPLOYMENT_MARKER" --arg sha "$published_marker_sha" \
        --arg source "$source_display_id" --arg target "$target_device_id" '
        (keys == ["coordinator_instance_id","marker_created_at_unix_ms","marker_generation","marker_path","operation_id","protocol_version","release_claim_path","release_committed_at_unix_ms","release_committed_at_utc","release_point","release_receipt_path","released_marker_sha256","replayed","schema_version","source_display_id","state","target_device_id"]) and
        .schema_version == 2 and .state == "deployment-quarantine-released" and .protocol_version == "2.1" and
        .operation_id == $op and .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .source_display_id == $source and .target_device_id == $target and
        .marker_path == $marker and .released_marker_sha256 == $sha and
        .release_claim_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1.release-claim" and
        (.marker_created_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.release_committed_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.release_committed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
        (.replayed | type == "boolean") and .release_point == "release-claim-unlink-and-parent-directory-fsync"
    ' "$path" >/dev/null || die 'VFDQT001 release JSON is invalid'
    durable=$(jq -er '.release_receipt_path' "$path")
    expected_durable="/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.release-receipt.${published_marker_sha}.v1"
    [[ $durable == "$expected_durable" ]] || die 'VFDQR001 path is not content-addressed by the marker SHA'
    [[ -f $durable && ! -L $durable && $(stat -c '%u:%a:%h:%s' -- "$durable") == 1000:600:1:352 ]] ||
        die 'VFDQR001 durable release receipt metadata is invalid'
    [[ $(dd if="$durable" bs=8 count=1 status=none) == VFDQR001 ]] || die 'VFDQR001 magic is invalid'
    [[ $(dd if="$durable" bs=1 skip=8 count=8 status=none | od -An -tx1 | tr -d ' \n') == 0101020101000000 ]] ||
        die 'VFDQR001 header/version/reserved bytes are invalid'
    [[ $(dd if="$durable" bs=1 skip=16 count=8 status=none) == VFDQT001 ]] || die 'embedded marker magic is invalid'
    embedded_sha=$(dd if="$durable" bs=1 skip=16 count=256 status=none | sha256sum | awk '{print $1}')
    embedded_recorded=$(dd if="$durable" bs=1 skip=272 count=32 status=none | od -An -tx1 | tr -d ' \n')
    [[ $embedded_sha == "$published_marker_sha" && $embedded_recorded == "$published_marker_sha" ]] ||
        die 'embedded VFDQT001 marker SHA is invalid'
    op_len=$(dd if="$durable" bs=1 skip=29 count=1 status=none | od -An -tu1 | tr -d ' ')
    [[ $op_len == 32 ]] || die 'embedded release operation ID length is invalid'
    embedded_op=$(dd if="$durable" bs=1 skip=32 count="$op_len" status=none)
    [[ $embedded_op == "$operation_id" ]] || die 'embedded release operation ID differs'
    source_hex=$(dd if="$durable" bs=1 skip=160 count=16 status=none | od -An -tx1 | tr -d ' \n')
    target_hex=$(dd if="$durable" bs=1 skip=176 count=16 status=none | od -An -tx1 | tr -d ' \n')
    coordinator_hex=$(dd if="$durable" bs=1 skip=192 count=16 status=none | od -An -tx1 | tr -d ' \n')
    generation=$(od -An -tu8 -j216 -N8 "$durable" | tr -d ' ')
    [[ $source_hex == "$source_display_id_lower" && $target_hex == "$target_device_id_lower" &&
       $coordinator_hex == "$coordinator_instance_id_lower" && $generation == "$marker_generation" ]] ||
        die 'embedded VFDQT001 identity/generation differs'
    committed=$(od -An -tu8 -j304 -N8 "$durable" | tr -d ' ')
    reserved=$(dd if="$durable" bs=1 skip=312 count=8 status=none | od -An -tx1 | tr -d ' \n')
    [[ $committed == "$(jq -er '.release_committed_at_unix_ms' "$path")" && $committed != 0 &&
       $reserved == 0000000000000000 ]] || die 'VFDQR001 commit timestamp/reserved bytes are invalid'
    prefix_sha=$(dd if="$durable" bs=320 count=1 status=none | sha256sum | awk '{print $1}')
    suffix_sha=$(dd if="$durable" bs=1 skip=320 count=32 status=none | od -An -tx1 | tr -d ' \n')
    [[ $prefix_sha == "$suffix_sha" ]] || die 'VFDQR001 self-checksum is invalid'
}

release_deployment_marker_transactionally() {
    local temp=$secure_dir/release.json
    if [[ -e $deployment_release_receipt ]]; then
        capture_json_command 'deployment release query' "$temp" marker_cli query --operation-id "$operation_id" \
            --coordinator-instance-id "$coordinator_instance_id" --marker-generation "$marker_generation" --marker-sha256 "$published_marker_sha"
        [[ $(jq -cS 'del(.replayed)' "$temp") == "$(jq -cS 'del(.replayed)' "$deployment_release_receipt")" &&
           $(jq -r '.replayed' "$temp") == true ]] || die 'released query stable fields differ from initial release'
        rm -f -- "$temp"
    else
        capture_json_command 'deployment release receipt' "$deployment_release_receipt" marker_cli release \
            --operation-id "$operation_id" --coordinator-instance-id "$coordinator_instance_id" \
            --marker-generation "$marker_generation" --marker-sha256 "$published_marker_sha"
    fi
    validate_release_receipt_v2 "$deployment_release_receipt"
    [[ ! -e $DEPLOYMENT_MARKER && ! -e ${DEPLOYMENT_MARKER}.release-claim ]] ||
        die 'deployment release remains quarantined or claimed'
    acceptance_deployment_marker_sha=$published_marker_sha
    released_marker=1
    commit_phase MARKER_RELEASED
}

require_owner_only_regular() {
    local label=$1 path=$2
    [[ $path == /* && -f $path && ! -L $path && $(stat -c '%u:%a:%h' -- "$path") == 1000:600:1 ]] ||
        die "$label must be an absolute uid-1000 mode-0600 single-link regular file"
}

publish_recovery_json_once() {
    local label=$1 source=$2 destination=$3
    if [[ -e $destination || -L $destination ]]; then
        require_owner_only_regular "$label" "$destination"
        assert_strict_json_document "$label" "$destination"
        [[ $(sha256 "$destination") == "$(sha256 "$source")" ]] || die "$label changed on replay"
    else
        publish_json_file "$label" "$source" "$destination"
    fi
}

validate_attempt3_slot_cleanup_gate() {
    local operation_root attempt_nonce index step expected_step_sha name slot_stem source destination claim expected_source
    local expected_destination expected_claim recorded_sha destination_identity claim_identity
    operation_root=$(dirname -- "$coordinator_state")
    [[ $attempt3_slot_cleanup_receipt == "$operation_root/cleanup-attempt3-exchange-slots-complete.json" ]] ||
        die 'attempt3 slot-cleanup receipt path is not fixed beside the old coordinator state'
    require_sha256 '--attempt3-slot-cleanup-receipt-sha256' "$attempt3_slot_cleanup_receipt_sha"
    require_owner_only_regular 'attempt3 slot-cleanup completion' "$attempt3_slot_cleanup_receipt"
    [[ $(sha256 "$attempt3_slot_cleanup_receipt") == "$attempt3_slot_cleanup_receipt_sha" ]] ||
        die 'attempt3 slot-cleanup completion SHA differs'
    assert_strict_json_document 'attempt3 slot-cleanup completion' "$attempt3_slot_cleanup_receipt"
    jq -e --arg op "$operation_id" '
        keys == ["archived_slots_verified","attempt_nonce","checkout_slots_absent","claims_preserved","cleanup_intent_sha256","frozen_archive_sha256","future_restored_receipt_sha256","future_sources_verified","operation_id","schema_version","state","step_receipt_sha256"] and
        .schema_version == 1 and .state == "viewflow-attempt3-exchange-slot-cleanup-complete" and
        .operation_id == $op and (.attempt_nonce | test("^[0-9a-f]{32}$")) and
        (.cleanup_intent_sha256 | test("^[0-9a-f]{64}$")) and
        (.frozen_archive_sha256 | test("^[0-9a-f]{64}$")) and
        (.future_restored_receipt_sha256 | test("^[0-9a-f]{64}$")) and
        (.step_receipt_sha256 | length == 3 and all(.[]; test("^[0-9a-f]{64}$"))) and
        .checkout_slots_absent == true and .archived_slots_verified == true and
        .future_sources_verified == true and .claims_preserved == true
    ' "$attempt3_slot_cleanup_receipt" >/dev/null || die 'attempt3 slot-cleanup completion schema/boundary is invalid'
    attempt_nonce=$(jq -er '.attempt_nonce' "$attempt3_slot_cleanup_receipt")
    for index in 0 1 2; do
        step="$operation_root/cleanup-attempt3-exchange-slots-step-${index}.json"
        expected_step_sha=$(jq -er --argjson i "$index" '.step_receipt_sha256[$i]' "$attempt3_slot_cleanup_receipt")
        require_owner_only_regular "attempt3 slot-cleanup step $index" "$step"
        [[ $(sha256 "$step") == "$expected_step_sha" ]] || die "attempt3 slot-cleanup step $index SHA differs"
        assert_strict_json_document "attempt3 slot-cleanup step $index" "$step"
        case $index in
            0) name=check-viewflow-client.sh; slot_stem=check-viewflow-client ;;
            1) name=install-viewflow.ps1; slot_stem=install-viewflow ;;
            2) name=rollback-viewflow.ps1; slot_stem=rollback-viewflow ;;
        esac
        expected_source="/home/wilf/data/viewflow/deploy/windows/.${slot_stem}.${operation_id}.attempt3.exchange-slot"
        expected_destination="$operation_root/attempt3-frozen/preserved-exchange-slots/$name"
        expected_claim="$operation_root/attempt3-frozen/preserved-exchange-slots/.${name}.suspect-claim"
        jq -e --arg op "$operation_id" --arg nonce "$attempt_nonce" --arg name "$name" \
            --arg source "$expected_source" --arg destination "$expected_destination" --arg claim "$expected_claim" \
            --argjson index "$index" '
            keys == ["attempt_nonce","claim_preserved","cleanup_intent_sha256","destination","future_restored_receipt_sha256","index","inode","name","operation_id","preserved_claim","schema_version","sha256","source","state"] and
            .schema_version == 1 and .state == "viewflow-attempt3-exchange-slot-archived" and
            .operation_id == $op and .attempt_nonce == $nonce and .index == $index and .name == $name and
            .source == $source and .destination == $destination and .preserved_claim == $claim and
            .claim_preserved == true and (.sha256 | test("^[0-9a-f]{64}$")) and
            (.inode | type == "number" and . == floor and . > 0)
        ' "$step" >/dev/null || die "attempt3 slot-cleanup step $index schema/binding is invalid"
        source=$(jq -er '.source' "$step"); destination=$(jq -er '.destination' "$step")
        claim=$(jq -er '.preserved_claim' "$step"); recorded_sha=$(jq -er '.sha256' "$step")
        [[ ! -e $source && ! -L $source ]] || die "attempt3 checkout exchange slot $index reappeared"
        [[ -f $destination && ! -L $destination && -f $claim && ! -L $claim ]] ||
            die "attempt3 preserved archive/claim $index is absent or unsafe"
        destination_identity=$(stat -c '%u:%h:%d:%i' -- "$destination")
        claim_identity=$(stat -c '%u:%h:%d:%i' -- "$claim")
        [[ $destination_identity == "$claim_identity" && $destination_identity == 1000:2:* &&
           $(sha256 "$destination") == "$recorded_sha" && $(sha256 "$claim") == "$recorded_sha" ]] ||
            die "attempt3 preserved archive/claim $index identity differs"
    done
}

validate_fresh_operation_lineage_gate() {
    local operation_root candidate_root candidate_manifest slot_stem source state_prepared state_permit state_recovery
    local old_operation old_root bridge_root old_terminal old_authorization old_abort old_query inactive_source persistent_started
    local durable_vfdqa immutable_vfdqa durable_path marker_sha authorization_sha prefix_sha suffix_sha
    operation_root=$(dirname -- "$coordinator_state")
    [[ $operation_root == "/home/wilf/.local/state/viewflow/deployments/${operation_id}" ]] ||
        die 'fresh-operation coordinator state is outside its fixed deployment root'
    candidate_root="/home/wilf/.local/state/viewflow/candidates/v21-operation-${operation_id}"
    [[ $fresh_operation_lineage_receipt == "$operation_root/v4-inactive-terminal-to-fresh-v21.json" ]] ||
        die 'fresh-operation lineage receipt path is not fixed beside the current coordinator state'
    require_sha256 '--fresh-operation-lineage-receipt-sha256' "$fresh_operation_lineage_receipt_sha"
    require_owner_only_regular 'fresh-operation lineage receipt' "$fresh_operation_lineage_receipt"
    [[ $(sha256 "$fresh_operation_lineage_receipt") == "$fresh_operation_lineage_receipt_sha" ]] ||
        die 'fresh-operation lineage receipt SHA differs'
    assert_strict_json_document 'fresh-operation lineage receipt' "$fresh_operation_lineage_receipt"
    old_operation=$(jq -er '.old_operation_id | select(type == "string" and test("^[0-9a-f]{32}$"))' "$fresh_operation_lineage_receipt")
    [[ $old_operation != "$operation_id" ]] || die 'fresh-operation lineage reuses its old operation ID'
    old_root="/home/wilf/.local/state/viewflow/deployments/${old_operation}"
    bridge_root="/home/wilf/.local/state/viewflow/v4-inactive-bridges/${old_operation}"
    old_terminal="$old_root/no-retry-v4-abort-terminal.json"
    old_authorization="$old_root/no-retry-v4-abort-authorization.json"
    old_abort="$old_root/no-retry-v4-abort-receipt.json"
    old_query="$old_root/no-retry-v4-abort-query-receipt.json"
    inactive_source="$bridge_root/inactive-source-validated.json"
    persistent_started="$bridge_root/persistent-started.json"
    immutable_vfdqa="$bridge_root/immutable-inputs/durable-vfdqa.bin"
    candidate_manifest="$candidate_root/candidate-manifest.json"
    for source in "$old_terminal" "$old_authorization" "$old_abort" "$old_query" "$inactive_source" \
        "$persistent_started" "$candidate_manifest"; do
        require_owner_only_regular 'fresh-operation lineage evidence' "$source"
        assert_strict_json_document 'fresh-operation lineage evidence' "$source"
    done
    authorization_sha=$(sha256 "$old_authorization")
    marker_sha=$(jq -er '.aborted_marker_sha256 | select(test("^[0-9a-f]{64}$"))' "$old_abort")
    durable_path=$(jq -er '.abort_receipt_path | select(type == "string" and startswith("/home/wilf/.local/state/viewflow/"))' "$old_abort")
    [[ $durable_path == "/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.${marker_sha}.${authorization_sha}.v1" ]] ||
        die 'old abort receipt names a non-canonical durable VFDQA path'
    [[ -f $durable_path && ! -L $durable_path && $(stat -c '%u:%a:%h:%s' -- "$durable_path") == 1000:600:1:384 ]] ||
        die 'durable VFDQA receipt metadata differs'
    [[ -f $immutable_vfdqa && ! -L $immutable_vfdqa && $(stat -c '%u:%a:%h:%s' -- "$immutable_vfdqa") == 1000:400:1:384 &&
       $(sha256 "$immutable_vfdqa") == "$(sha256 "$durable_path")" ]] ||
        die 'immutable bridge VFDQA copy differs from its durable receipt'
    [[ $(dd if="$durable_path" bs=1 count=8 status=none) == VFDQA001 ]] || die 'durable VFDQA magic differs'
    prefix_sha=$(dd if="$durable_path" bs=352 count=1 status=none | sha256sum | cut -d' ' -f1)
    suffix_sha=$(dd if="$durable_path" bs=1 skip=352 count=32 status=none | od -An -tx1 | tr -d ' \n')
    [[ $prefix_sha == "$suffix_sha" ]] || die 'durable VFDQA self-checksum differs'
    validate_publish_receipt "$deployment_publish_receipt" "$marker_generation" 0
    state_prepared=$(jq -er '.contract.outputs.prepared | select(type == "string" and startswith("/"))' "$coordinator_state")
    state_permit=$(jq -er '.contract.outputs.permit | select(type == "string" and startswith("/"))' "$coordinator_state")
    state_recovery=$(jq -er '.contract.outputs.recovery_bundle | select(type == "string" and startswith("/"))' "$coordinator_state")
    [[ $state_prepared == "$operation_root/windows-prepared.json" &&
       $state_permit == "$operation_root/windows-mutation-permit.json" &&
       $state_recovery == "${coordinator_state}.recovery-bundle.json" ]] ||
        die 'fresh-operation committed paths are outside the fixed deployment root'
    for source in "$state_prepared" "$state_permit" "$state_recovery"; do
        require_owner_only_regular 'fresh-operation committed artifact' "$source"
    done
    jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" \
        --arg publish "$(sha256 "$deployment_publish_receipt")" --arg frozen "$(sha256 "$bootstrap_linux_evidence")" \
        --arg marker "$published_marker_sha" --arg old "$old_operation" \
        --arg terminal "$(sha256 "$old_terminal")" --arg authorization "$authorization_sha" \
        --arg abort "$(sha256 "$old_abort")" --arg query "$(sha256 "$old_query")" \
        --arg source_validation "$(sha256 "$inactive_source")" --arg persistent "$(sha256 "$persistent_started")" \
        --arg vfdqa "$(sha256 "$durable_path")" '
        keys == ["fresh_boundary","inactive_source","marker_generation","new_coordinator_instance_id","new_operation_id","old_operation_id","persistent_v13","schema_version","state"] and
        .schema_version == 1 and .state == "viewflow-v4-inactive-terminal-to-fresh-v21" and
        .new_operation_id == $op and .new_coordinator_instance_id == $coordinator and
        .marker_generation == $generation and
        .old_operation_id == $old and .old_operation_id != $op and
        (.fresh_boundary | keys) == ["deployment_marker_sha256","deployment_publish_sha256","linux_frozen_sha256","marker_handoff_sha256","protocol_version"] and
        .fresh_boundary.protocol_version == "2.1" and
        .fresh_boundary.marker_handoff_sha256 == $handoff and
        .fresh_boundary.deployment_publish_sha256 == $publish and
        .fresh_boundary.linux_frozen_sha256 == $frozen and
        .fresh_boundary.deployment_marker_sha256 == $marker and
        (.inactive_source | keys) == ["abort_query_receipt_sha256","abort_receipt_sha256","authorization_sha256","linux_initially_inactive","source_validation_sha256","terminal_sha256","vfdqa_sha256","windows_old_peer_unchanged"] and
        (.inactive_source.abort_query_receipt_sha256 | test("^[0-9a-f]{64}$")) and
        all([.inactive_source.authorization_sha256,.inactive_source.source_validation_sha256,
             .inactive_source.terminal_sha256,.inactive_source.vfdqa_sha256][]; test("^[0-9a-f]{64}$")) and
        .inactive_source.linux_initially_inactive == true and .inactive_source.windows_old_peer_unchanged == true and
        (.persistent_v13 | keys) == ["authenticated_probe_record_sha256","persistent_started_sha256","stopped_by_collector"] and
        all([.persistent_v13.authenticated_probe_record_sha256,.persistent_v13.persistent_started_sha256][]; test("^[0-9a-f]{64}$")) and
        .persistent_v13.stopped_by_collector == true and
        .inactive_source.terminal_sha256 == $terminal and .inactive_source.authorization_sha256 == $authorization and
        .inactive_source.abort_receipt_sha256 == $abort and .inactive_source.abort_query_receipt_sha256 == $query and
        .inactive_source.source_validation_sha256 == $source_validation and .inactive_source.vfdqa_sha256 == $vfdqa and
        .persistent_v13.persistent_started_sha256 == $persistent
    ' "$fresh_operation_lineage_receipt" >/dev/null || die 'fresh-operation lineage schema/binding is invalid'
    jq -e --arg old "$old_operation" --arg authorization "$authorization_sha" --arg abort "$(sha256 "$old_abort")" \
        --arg query "$(sha256 "$old_query")" --arg vfdqa "$(sha256 "$durable_path")" '
        .schema_version == 4 and .state == "viewflow-failed-pre-mutation-no-retry-vfdqa-abort-terminal" and
        .operation_id == $old and .authorization_sha256 == $authorization and
        .abort_receipt_sha256 == $abort and .abort_query_receipt_sha256 == $query and
        .vfdqa_binary_sha256 == $vfdqa and .marker_absent == true and .runtime_marker_absent == true and
        .mutation_outputs_absent == true and .windows_old_peer_unchanged == true and
        .linux_viewflow_started == false and .linux_deskflow_started == false and .protocol_2_1 == false
    ' "$old_terminal" >/dev/null || die 'old no-retry-v4 terminal evidence is invalid'
    jq -e --arg old "$old_operation" --arg marker "$marker_sha" '
        .schema_version == 4 and
        .state == "viewflow-deployment-quarantine-failed-pre-mutation-no-retry-abort-authorized" and
        .operation_id == $old and .marker_sha256 == $marker and .marker_generation == "1" and
        .coordinator_failure_phase == "WINDOWS_STARTED" and .coordinator_mutation_possible == false and
        .initial_force_release_executed == false and .rollback_performed == false and
        .mutation_outputs_absent == true and .protocol_2_1 == false and
        .linux_viewflow_started == false and .linux_deskflow_started == false
    ' "$old_authorization" >/dev/null || die 'old no-retry-v4 abort authorization is invalid'
    jq -e --arg old "$old_operation" --arg authorization "$authorization_sha" --arg durable "$durable_path" \
        '
        .schema_version == 4 and .state == "deployment-quarantine-aborted" and .operation_id == $old and
        .abort_authorization_sha256 == $authorization and .abort_receipt_path == $durable and
        .protocol_version == "1.3" and .protocol_2_1 == false and .mutation_outputs_absent == true and
        .rollback_performed == false and .deployment_release_claimed == false and
        .source_display_id == "00000000-0000-0000-0000-000000000101" and
        .target_device_id == "00000000-0000-0000-0000-000000000002"
    ' "$old_abort" >/dev/null || die 'old no-retry-v4 abort receipt is invalid'
    [[ $(jq -cS 'del(.replayed)' "$old_abort") == "$(jq -cS 'del(.replayed)' "$old_query")" ]] ||
        die 'old abort/query receipt canonical replay fields differ'
    jq -e --arg old "$old_operation" --arg terminal "$(sha256 "$old_terminal")" \
        --arg authorization "$authorization_sha" --arg abort "$(sha256 "$old_abort")" \
        --arg query "$(sha256 "$old_query")" --arg vfdqa "$(sha256 "$durable_path")" '
        keys == ["abort_query_receipt_sha256","abort_receipt_sha256","authorization_sha256","linux_inactive","old_operation_id","plan_sha256","schema_version","state","terminal_sha256","vfdqa_sha256","windows_old_peer_unchanged"] and
        .schema_version == 1 and .state == "viewflow-v4-inactive-source-validated" and .old_operation_id == $old and
        .terminal_sha256 == $terminal and .authorization_sha256 == $authorization and
        .abort_receipt_sha256 == $abort and .abort_query_receipt_sha256 == $query and .vfdqa_sha256 == $vfdqa and
        .linux_inactive == true and .windows_old_peer_unchanged == true
    ' "$inactive_source" >/dev/null || die 'fresh bridge inactive-source evidence is invalid'
    jq -e --arg op "$operation_id" --arg probe "$(jq -er '.persistent_v13.authenticated_probe_record_sha256' "$fresh_operation_lineage_receipt")" '
        keys == ["authenticated_peer_ip","authenticated_probe_record_sha256","cmdline_sha256","control_group","environment_sha256","executable_sha256","expected_exec_start_sha256","invocation_id","journal_sha256","main_pid","operation_id","schema_version","start_ticks","state","unit","unit_file_sha256"] and
        .schema_version == 1 and .state == "viewflow-fresh-persistent-v13-authenticated" and .operation_id == $op and
        .authenticated_peer_ip == "172.16.105.70" and .authenticated_probe_record_sha256 == $probe and
        .unit == "viewflow-peer.service" and (.main_pid | type == "number" and . == floor and . > 0) and
        (.start_ticks | type == "number" and . == floor and . > 0)
    ' "$persistent_started" >/dev/null || die 'fresh bridge persistent-start evidence is invalid'
    jq -e --slurpfile manifest "$candidate_manifest" --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg root "$operation_root" --arg marker "$published_marker_sha" \
        --arg h "$(sha256 "$bootstrap_handoff_receipt")" --arg p "$(sha256 "$deployment_publish_receipt")" \
        --arg b "$(sha256 "$bootstrap_linux_evidence")" '
        $manifest[0] as $m |
        ($m | keys) == ["coordinator","coordinator_instance_id","fresh_boundary","kind","linux_deskflow","linux_rust","marker_generation","operation_id","protocol_version","recovery_marker_generation","schema_version","sidecar_protocol_version","source_display_id","target_device_id","windows"] and
        ($m.windows | keys) == ["installer","installer_sha256","launcher","launcher_sha256","native_provenance","native_provenance_sha256","new_task_xml_override","old_task_xml_sha256","rollback_sha256","session_1_user_sid","viewflowd","viewflowd_sha256","wrapper","wrapper_sha256"] and
        $m.schema_version == 1 and $m.kind == "viewflow-v21-cross-host-candidate-set" and
        $m.operation_id == $op and $m.coordinator_instance_id == $coordinator and
        $m.marker_generation == 1 and $m.recovery_marker_generation == 2 and
        $m.protocol_version == "2.1" and $m.sidecar_protocol_version == 3 and
        $m.fresh_boundary.root == $root and $m.fresh_boundary.deployment_marker_sha256 == $marker and
        $m.fresh_boundary.marker_handoff_sha256 == $h and $m.fresh_boundary.deployment_publish_receipt_sha256 == $p and
        $m.fresh_boundary.linux_frozen_sha256 == $b and
        $m.windows.viewflowd == .contract.inputs.windows_viewflow.path and $m.windows.viewflowd_sha256 == .contract.inputs.windows_viewflow.sha256 and
        $m.windows.wrapper == .contract.inputs.windows_wrapper.path and $m.windows.wrapper_sha256 == .contract.inputs.windows_wrapper.sha256 and
        $m.windows.launcher == .contract.inputs.windows_launcher.path and $m.windows.launcher_sha256 == .contract.inputs.windows_launcher.sha256 and
        $m.windows.installer == .contract.inputs.windows_installer.path and $m.windows.installer_sha256 == .contract.inputs.windows_installer.sha256 and
        .contract.inputs.windows_rollback.path == (($m.windows.installer | rindex("/")) as $i | $m.windows.installer[0:$i] + "/rollback-viewflow.ps1") and
        $m.windows.rollback_sha256 == .contract.inputs.windows_rollback.sha256
    ' "$coordinator_state" >/dev/null || die 'fresh candidate manifest/current state binding is invalid'
    jq -e --arg root "$candidate_root" --arg op "$operation_id" \
        --arg h "$(sha256 "$bootstrap_handoff_receipt")" --arg p "$(sha256 "$deployment_publish_receipt")" \
        --arg b "$(sha256 "$bootstrap_linux_evidence")" --arg f "$(sha256 "$windows_force_envelope")" \
        --arg request "$windows_request_sha" --arg prepared "$(sha256 "$state_prepared")" \
        --arg permit "$(sha256 "$state_permit")" --arg recovery "$(sha256 "$state_recovery")" \
        --arg stop "$(sha256 "$local_windows_stop_evidence")" --arg rollback "$(sha256 "$local_windows_rollback_receipt")" '
        .operation_id == $op and .phase == "WINDOWS_ROLLED_BACK" and
        .recovery == {failure_phase:"WINDOWS_FORCE_ATTESTED",mutation_possible:true} and
        .contract.inputs.windows_viewflow.path == ($root + "/windows-viewflowd.exe") and
        all([.contract.inputs.windows_viewflow.path,.contract.inputs.windows_wrapper.path,
             .contract.inputs.windows_launcher.path,.contract.inputs.windows_installer.path,
             .contract.inputs.windows_rollback.path][];
            startswith("/") and (contains(".attempt3.exchange-slot") | not)) and
        .committed_artifacts == {bootstrap_request:$request,force_envelope:$f,linux_frozen:$b,
          marker_handoff:$h,mutation_permit:$permit,publish_receipt:$p,recovery_bundle:$recovery,
          windows_prepared:$prepared,windows_rollback:$rollback,windows_stop_evidence:$stop}
    ' "$coordinator_state" >/dev/null || die 'fresh-operation state did not use the exact operation candidate and committed artifact set'
    for slot_stem in check-viewflow-client install-viewflow rollback-viewflow; do
        source="/home/wilf/data/viewflow/deploy/windows/.${slot_stem}.${operation_id}.attempt3.exchange-slot"
        [[ ! -e $source && ! -L $source ]] || die "fresh operation unexpectedly owns an attempt3 exchange slot: $slot_stem"
    done
    post_force_pre_linux_stage_rollback_abort=1
}

validate_schema1_handoff_lineage_gate() {
    local operation_root candidate_root candidate_manifest source state_prepared state_permit state_exit state_recovery
    local old_operation old_root old_prefix old_terminal old_authorization old_abort old_query old_transition old_handoff
    local durable_path marker_sha authorization_sha prefix_sha suffix_sha
    operation_root=$(dirname -- "$coordinator_state")
    [[ $operation_root == "/home/wilf/.local/state/viewflow/deployments/${operation_id}" ]] ||
        die 'schema1-handoff coordinator state is outside its fixed deployment root'
    candidate_root="/home/wilf/.local/state/viewflow/candidates/v21-operation-${operation_id}"
    candidate_manifest="$candidate_root/candidate-manifest.json"
    [[ $schema1_handoff_lineage_receipt == "$operation_root/schema1-abort-handoff-to-fresh-v21.json" ]] ||
        die 'schema1-handoff lineage receipt path is not fixed beside the current coordinator state'
    require_sha256 '--schema1-handoff-lineage-receipt-sha256' "$schema1_handoff_lineage_receipt_sha"
    require_owner_only_regular 'schema1-handoff lineage receipt' "$schema1_handoff_lineage_receipt"
    [[ $(sha256 "$schema1_handoff_lineage_receipt") == "$schema1_handoff_lineage_receipt_sha" ]] ||
        die 'schema1-handoff lineage receipt SHA differs'
    assert_strict_json_document 'schema1-handoff lineage receipt' "$schema1_handoff_lineage_receipt"
    old_operation=$(jq -er '.old_operation_id | select(type == "string" and test("^[0-9a-f]{32}$"))' "$schema1_handoff_lineage_receipt")
    [[ $old_operation != "$operation_id" ]] || die 'schema1-handoff lineage reuses its old operation ID'
    old_root="/home/wilf/.local/state/viewflow/deployments/${old_operation}"
    old_prefix="failed-v21-rollback-abort-${old_operation:0:8}-v2"
    old_terminal="$old_root/${old_prefix}-terminal.json"
    old_authorization="$old_root/${old_prefix}-authorization.json"
    old_abort="$old_root/${old_prefix}-receipt.json"
    old_query="$old_root/${old_prefix}-query.json"
    old_transition="$old_root/${old_prefix}-transition.json"
    old_handoff="$old_root/${old_prefix}-handoff-persistent-v13.json"
    for source in "$old_terminal" "$old_authorization" "$old_abort" "$old_query" "$old_transition" \
        "$old_handoff" "$candidate_manifest"; do
        require_owner_only_regular 'schema1-handoff lineage evidence' "$source"
        assert_strict_json_document 'schema1-handoff lineage evidence' "$source"
    done
    authorization_sha=$(sha256 "$old_authorization")
    marker_sha=$(jq -er '.aborted_marker_sha256 | select(test("^[0-9a-f]{64}$"))' "$old_abort")
    durable_path=$(jq -er '.abort_receipt_path | select(type == "string" and startswith("/home/wilf/.local/state/viewflow/"))' "$old_abort")
    [[ $durable_path == "/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.${marker_sha}.${authorization_sha}.v1" ]] ||
        die 'schema1-handoff old abort names a non-canonical durable VFDQA path'
    [[ -f $durable_path && ! -L $durable_path && $(stat -c '%u:%a:%h:%s' -- "$durable_path") == 1000:600:1:384 ]] ||
        die 'schema1-handoff durable VFDQA metadata differs'
    [[ $(dd if="$durable_path" bs=1 count=13 status=none | od -An -tx1 | tr -d ' \n') == 56464451413030310101010301 ]] ||
        die 'schema1-handoff durable VFDQA header differs'
    prefix_sha=$(dd if="$durable_path" bs=352 count=1 status=none | sha256sum | cut -d' ' -f1)
    suffix_sha=$(dd if="$durable_path" bs=1 skip=352 count=32 status=none | od -An -tx1 | tr -d ' \n')
    [[ $prefix_sha == "$suffix_sha" ]] || die 'schema1-handoff durable VFDQA self-checksum differs'
    validate_publish_receipt "$deployment_publish_receipt" "$marker_generation" 0
    state_prepared=$(jq -er '.contract.outputs.prepared' "$coordinator_state")
    state_permit=$(jq -er '.contract.outputs.permit' "$coordinator_state")
    state_exit=$(jq -er '.contract.outputs.windows_exit' "$coordinator_state")
    state_recovery=$(jq -er '.contract.outputs.recovery_bundle' "$coordinator_state")
    [[ $state_prepared == "$operation_root/windows-prepared.json" &&
       $state_permit == "$operation_root/windows-mutation-permit.json" &&
       $state_exit == "$operation_root/windows-installer-exit.json" &&
       $state_recovery == "${coordinator_state}.recovery-bundle.json" ]] ||
        die 'schema1-handoff committed paths are outside the fixed deployment root'
    windows_prepared_receipt=$state_prepared
    windows_mutation_permit=$state_permit
    windows_installer_exit_receipt=$state_exit
    local_recovery_bundle=$state_recovery
    for source in "$windows_prepared_receipt" "$windows_mutation_permit" "$windows_installer_exit_receipt" \
        "$local_recovery_bundle" "$linux_deactivation_transcript"; do
        require_owner_only_regular 'schema1-handoff committed artifact' "$source"
    done
    jq -e --arg old "$old_operation" --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg terminal "$(sha256 "$old_terminal")" \
        --arg authorization "$authorization_sha" --arg abort "$(sha256 "$old_abort")" \
        --arg query "$(sha256 "$old_query")" --arg transition "$(sha256 "$old_transition")" \
        --arg handoff "$(sha256 "$old_handoff")" --arg vfdqa "$(sha256 "$durable_path")" \
        --arg h "$(sha256 "$bootstrap_handoff_receipt")" --arg p "$(sha256 "$deployment_publish_receipt")" \
        --arg b "$(sha256 "$bootstrap_linux_evidence")" --arg candidate "$(sha256 "$candidate_manifest")" \
        --arg marker "$published_marker_sha" '
        keys == ["fresh_boundary","marker_generation","new_coordinator_instance_id","new_operation_id","old_operation_id","old_schema1_abort","schema_version","state"] and
        .schema_version == 1 and .state == "viewflow-schema1-abort-handoff-to-fresh-v21" and
        .old_operation_id == $old and .old_operation_id != $op and .new_operation_id == $op and
        .new_coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .old_schema1_abort == {terminal_sha256:$terminal,authorization_sha256:$authorization,
          abort_receipt_sha256:$abort,abort_query_sha256:$query,transition_sha256:$transition,
          handoff_persistent_sha256:$handoff,vfdqa_sha256:$vfdqa} and
        .fresh_boundary == {protocol_version:"2.1",marker_handoff_sha256:$h,
          deployment_publish_sha256:$p,linux_frozen_sha256:$b,candidate_manifest_sha256:$candidate,
          deployment_marker_sha256:$marker}
    ' "$schema1_handoff_lineage_receipt" >/dev/null || die 'schema1-handoff lineage schema/binding is invalid'
    jq -e --arg old "$old_operation" --arg authorization "$authorization_sha" \
        --arg abort "$(sha256 "$old_abort")" --arg query "$(sha256 "$old_query")" \
        --arg transition "$(sha256 "$old_transition")" --arg vfdqa "$(sha256 "$durable_path")" '
        keys == ["abort_claim_absent","abort_query_sha256","abort_receipt_sha256","authenticated_v13_peer_sha256","authorization_sha256","coordinator_sha256","coordinator_state_sha256","coordinator_transition_sha256","execution_approval_sha256","fresh_lineage_sha256","gate_sha256","launcher_sha256","linux_post_sha256","linux_pre_sha256","linux_v13_started_sha256","manifest_sha256","marker_absent","old_windows_peer_process_count","old_windows_peer_started","operation_id","protocol_2_1","release_claim_absent","runtime_marker_absent","schema_version","state","vfdqa_binary_sha256","windows_deployment_task_state","windows_operation_root_unchanged","windows_post_sha256","windows_pre_sha256","windows_v13_started_sha256"] and
        .schema_version == 1 and .state == "viewflow-failed-v21-rollback-vfdqa-abort-terminal" and
        .operation_id == $old and .authorization_sha256 == $authorization and
        .abort_receipt_sha256 == $abort and .abort_query_sha256 == $query and
        .coordinator_transition_sha256 == $transition and .vfdqa_binary_sha256 == $vfdqa and
        .marker_absent == true and .runtime_marker_absent == true and .abort_claim_absent == true and
        .release_claim_absent == true and .protocol_2_1 == false and .old_windows_peer_started == true and
        .old_windows_peer_process_count == 1 and .windows_deployment_task_state == "Disabled" and
        .windows_operation_root_unchanged == true
    ' "$old_terminal" >/dev/null || die 'schema1-handoff old terminal evidence is invalid'
    jq -e --arg old "$old_operation" --arg marker "$marker_sha" '
        keys == ["authenticated_v13_peer_receipt_sha256","authorization_receipt_path","coordinator_instance_id","deployment_publish_receipt_sha256","initial_force_release_executed","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_generation","marker_handoff_receipt_sha256","marker_sha256","old_linux_deskflow_core_sha256","old_linux_deskflow_sha256","old_linux_viewflowd_sha256","old_windows_viewflowd_sha256","old_windows_wrapper_sha256","operation_id","protocol_2_1","rollback_token_consumed","schema_version","second_force_release_executed","state","windows_claim_resolution_sha256","windows_force_envelope_sha256","windows_migration_receipt_sha256","windows_v13_started_receipt_sha256"] and
        .schema_version == 1 and .state == "viewflow-deployment-quarantine-abort-authorized" and
        .operation_id == $old and .marker_sha256 == $marker and .marker_generation == "1" and
        .initial_force_release_executed == true and .second_force_release_executed == false and
        .rollback_token_consumed == false and .protocol_2_1 == false
    ' "$old_authorization" >/dev/null || die 'schema1-handoff old authorization is invalid'
    jq -e --arg old "$old_operation" --arg authorization "$authorization_sha" --arg durable "$durable_path" \
        --arg marker "$marker_sha" '
        keys == ["abort_authorization_path","abort_authorization_sha256","abort_claim_path","abort_committed_at_unix_ms","abort_committed_at_utc","abort_point","abort_receipt_path","aborted_marker_sha256","coordinator_instance_id","deployment_release_claimed","initial_force_release_executed","marker_created_at_unix_ms","marker_generation","marker_path","operation_id","protocol_2_1","protocol_version","replayed","rollback_token_consumed","schema_version","second_force_release_executed","source_display_id","state","target_device_id"] and
        .schema_version == 1 and .state == "deployment-quarantine-aborted" and .operation_id == $old and
        .abort_authorization_sha256 == $authorization and .abort_receipt_path == $durable and
        .aborted_marker_sha256 == $marker and .marker_generation == "1" and .protocol_version == "1.3" and
        .protocol_2_1 == false and .deployment_release_claimed == false and
        .initial_force_release_executed == true and .second_force_release_executed == false and
        .rollback_token_consumed == false and .replayed == false
    ' "$old_abort" >/dev/null || die 'schema1-handoff old abort receipt is invalid'
    jq -e '.replayed == true' "$old_query" >/dev/null || die 'schema1-handoff old abort query is not a replay'
    [[ $(jq -cS 'del(.replayed)' "$old_abort") == "$(jq -cS 'del(.replayed)' "$old_query")" ]] ||
        die 'schema1-handoff old abort/query receipts differ'
    jq -e --arg old "$old_operation" --arg transition "$(sha256 "$old_transition")" \
        --arg linux "$(jq -er '.linux_v13_started_sha256' "$old_terminal")" '
        keys == ["completed_at_utc","deskflow","initial_state","linux_v13_started_receipt_path","linux_v13_started_receipt_sha256","operation_id","persistent_viewflow","post_transient_stop","preintent_partial_adopted","schema_version","state","terminal_receipt_path","terminal_receipt_sha256","transition_intent_path","transition_intent_sha256"] and
        .schema_version == 1 and .state == "viewflow-abort-transients-handed-off-to-persistent-v13" and
        .operation_id == $old and .initial_state == "both-live" and .preintent_partial_adopted == false and
        .terminal_receipt_sha256 == $transition and .linux_v13_started_receipt_sha256 == $linux and
        .post_transient_stop == {viewflow_exact_process_count:0,deskflow_exact_process_count:0,
          deskflow_core_exact_process_count:0,udp_44119_listener_count:0,tcp_24800_listener_count:0,
          sidecar_socket_present:false} and
        .persistent_viewflow.unit == "viewflow-peer.service" and .persistent_viewflow.unit_active_state == "active" and
        .persistent_viewflow.authenticated_peer_ip == "172.16.105.70" and
        (.persistent_viewflow.authenticated_probe_record_sha256 | test("^[0-9a-f]{64}$")) and
        .deskflow == {unit:"deskflow.service",unit_active_state:"inactive",main_pid:0,
          exact_process_count:0,core_exact_process_count:0,tcp_24800_listener_count:0,started_by_handoff:false}
    ' "$old_handoff" >/dev/null || die 'schema1-handoff old persistent handoff is invalid'
    jq -e --slurpfile manifest "$candidate_manifest" --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg root "$operation_root" --arg marker "$published_marker_sha" --arg h "$(sha256 "$bootstrap_handoff_receipt")" \
        --arg p "$(sha256 "$deployment_publish_receipt")" --arg b "$(sha256 "$bootstrap_linux_evidence")" '
        $manifest[0] as $m |
        $m.schema_version == 1 and $m.kind == "viewflow-v21-cross-host-candidate-set" and
        $m.operation_id == $op and $m.coordinator_instance_id == $coordinator and
        $m.marker_generation == 1 and $m.recovery_marker_generation == 2 and
        $m.protocol_version == "2.1" and $m.sidecar_protocol_version == 3 and
        $m.fresh_boundary.root == $root and $m.fresh_boundary.deployment_marker_sha256 == $marker and
        $m.fresh_boundary.marker_handoff_sha256 == $h and
        $m.fresh_boundary.deployment_publish_receipt_sha256 == $p and $m.fresh_boundary.linux_frozen_sha256 == $b and
        $m.windows.viewflowd == .contract.inputs.windows_viewflow.path and
        $m.windows.viewflowd_sha256 == .contract.inputs.windows_viewflow.sha256 and
        $m.windows.wrapper_sha256 == .contract.inputs.windows_wrapper.sha256 and
        $m.windows.launcher_sha256 == .contract.inputs.windows_launcher.sha256 and
        $m.windows.installer_sha256 == .contract.inputs.windows_installer.sha256 and
        $m.windows.rollback_sha256 == .contract.inputs.windows_rollback.sha256
    ' "$coordinator_state" >/dev/null || die 'schema1-handoff candidate manifest/current state binding is invalid'
    jq -e --arg op "$operation_id" --arg h "$(sha256 "$bootstrap_handoff_receipt")" \
        --arg p "$(sha256 "$deployment_publish_receipt")" --arg b "$(sha256 "$bootstrap_linux_evidence")" \
        --arg request "$windows_request_sha" --arg prepared "$(sha256 "$windows_prepared_receipt")" \
        --arg permit "$(sha256 "$windows_mutation_permit")" --arg exit "$(sha256 "$windows_installer_exit_receipt")" \
        --arg stop "$(sha256 "$local_windows_stop_evidence")" --arg recovery "$(sha256 "$local_recovery_bundle")" \
        --arg rollback "$(sha256 "$local_windows_rollback_receipt")" '
        .operation_id == $op and .phase == "WINDOWS_ROLLED_BACK" and
        .recovery == {failure_phase:"MUTATION_PERMITTED",mutation_possible:true} and
        .committed_artifacts == {marker_handoff:$h,linux_frozen:$b,publish_receipt:$p,
          bootstrap_request:$request,windows_prepared:$prepared,mutation_permit:$permit,windows_exit:$exit,
          windows_stop_evidence:$stop,recovery_bundle:$recovery,windows_rollback:$rollback}
    ' "$coordinator_state" >/dev/null || die 'schema1-handoff current committed artifact set is not exact'
    post_permit_rollback_abort=1
}

validate_failed_v13_slot_lineage_union() {
    if [[ -n $attempt3_slot_cleanup_receipt || -n $attempt3_slot_cleanup_receipt_sha ]]; then
        [[ -n $attempt3_slot_cleanup_receipt && -n $attempt3_slot_cleanup_receipt_sha &&
           -z $fresh_operation_lineage_receipt && -z $fresh_operation_lineage_receipt_sha &&
           -z $schema1_handoff_lineage_receipt && -z $schema1_handoff_lineage_receipt_sha ]] ||
            die 'failed-v1.3 abort slot-lineage proof must select exactly one complete branch'
        validate_attempt3_slot_cleanup_gate
    elif [[ -n $fresh_operation_lineage_receipt || -n $fresh_operation_lineage_receipt_sha ]]; then
        [[ -n $fresh_operation_lineage_receipt && -n $fresh_operation_lineage_receipt_sha &&
           -z $schema1_handoff_lineage_receipt && -z $schema1_handoff_lineage_receipt_sha ]] ||
            die 'failed-v1.3 abort slot-lineage proof must select exactly one complete branch'
        validate_fresh_operation_lineage_gate
    else
        [[ -n $schema1_handoff_lineage_receipt && -n $schema1_handoff_lineage_receipt_sha ]] ||
            die 'failed-v1.3 abort requires legacy cleanup, v4 lineage, or schema1-handoff lineage proof'
        validate_schema1_handoff_lineage_gate
    fi
}

validate_failed_v13_terminal_state() {
    local path=$coordinator_state
    require_owner_only_regular 'old coordinator terminal state' "$path"
    [[ $(sha256 "$path") == "$old_coordinator_state_sha" ]] || die 'old coordinator terminal state SHA differs'
    assert_strict_json_document 'old coordinator terminal state' "$path"
    if ((post_force_pre_linux_stage_rollback_abort)); then
        jq -e --arg h "$(sha256 "$bootstrap_handoff_receipt")" --arg p "$(sha256 "$deployment_publish_receipt")" \
            --arg b "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
            --arg prepared "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
            --arg force "$(sha256 "$windows_force_envelope")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
            --arg recovery "$(sha256 "$local_recovery_bundle")" --arg rollback "$(sha256 "$local_windows_rollback_receipt")" \
            --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" --arg generation "$marker_generation" \
            --arg source "$source_display_id" --arg target "$target_device_id" \
            --arg handoff_path "$bootstrap_handoff_receipt" --arg publish_path "$deployment_publish_receipt" \
            --arg frozen_path "$bootstrap_linux_evidence" --arg request_path "$windows_bootstrap_request" \
            --arg prepared_path "$windows_prepared_receipt" --arg permit_path "$windows_mutation_permit" \
            --arg force_path "$windows_force_envelope" --arg stop_path "$local_windows_stop_evidence" \
            --arg recovery_path "$local_recovery_bundle" --arg rollback_path "$local_windows_rollback_receipt" '
            keys == ["committed_artifacts","contract","operation_id","phase","recovery","schema_version","state"] and
            .schema_version == 2 and .state == "viewflow-cross-host-bootstrap" and .operation_id == $op and
            .phase == "WINDOWS_ROLLED_BACK" and .recovery == {failure_phase:"WINDOWS_FORCE_ATTESTED",mutation_possible:true} and
            (.contract | keys) == ["identity","inputs","outputs","remote"] and
            .contract.identity.coordinator_instance_id == $coordinator and .contract.identity.marker_generation == $generation and
            .contract.identity.source_display_id == $source and .contract.identity.target_device_id == $target and
            .contract.inputs.marker_handoff.path == $handoff_path and .contract.inputs.publish_receipt.path == $publish_path and
            .contract.inputs.linux_frozen.path == $frozen_path and .contract.outputs.request == $request_path and
            .contract.outputs.prepared == $prepared_path and .contract.outputs.permit == $permit_path and
            .contract.outputs.force_envelope == $force_path and .contract.outputs.windows_stop_evidence == $stop_path and
            .contract.outputs.recovery_bundle == $recovery_path and .contract.outputs.windows_rollback == $rollback_path and
            .committed_artifacts == {bootstrap_request:$request,force_envelope:$force,linux_frozen:$b,
              marker_handoff:$h,mutation_permit:$permit,publish_receipt:$p,recovery_bundle:$recovery,
              windows_prepared:$prepared,windows_rollback:$rollback,windows_stop_evidence:$stop}
        ' "$path" >/dev/null || die 'post-force pre-Linux-stage rollback terminal state/artifacts are invalid'
        return
    fi
    if [[ -n $schema1_handoff_lineage_receipt || -n $schema1_handoff_lineage_receipt_sha ]]; then
        post_permit_rollback_abort=1
        jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
            --arg generation "$marker_generation" --arg source "$source_display_id" --arg target "$target_device_id" \
            --arg handoff "$bootstrap_handoff_receipt" --arg publish "$deployment_publish_receipt" \
            --arg frozen "$bootstrap_linux_evidence" --arg request "$windows_bootstrap_request" \
            --arg stop "$local_windows_stop_evidence" --arg rollback "$local_windows_rollback_receipt" '
            keys == ["committed_artifacts","contract","operation_id","phase","recovery","schema_version","state"] and
            .schema_version == 2 and .state == "viewflow-cross-host-bootstrap" and .operation_id == $op and
            .phase == "WINDOWS_ROLLED_BACK" and
            .recovery == {failure_phase:"MUTATION_PERMITTED",mutation_possible:true} and
            (.contract | keys) == ["identity","inputs","outputs","remote"] and
            .contract.identity.coordinator_instance_id == $coordinator and
            .contract.identity.marker_generation == $generation and
            .contract.identity.source_display_id == $source and .contract.identity.target_device_id == $target and
            .contract.inputs.marker_handoff.path == $handoff and .contract.inputs.publish_receipt.path == $publish and
            .contract.inputs.linux_frozen.path == $frozen and .contract.outputs.request == $request and
            .contract.outputs.windows_stop_evidence == $stop and .contract.outputs.windows_rollback == $rollback
        ' "$path" >/dev/null || die 'post-permit rollback terminal state contract is invalid'
        jq -e --arg h "$(sha256 "$bootstrap_handoff_receipt")" --arg p "$(sha256 "$deployment_publish_receipt")" \
            --arg b "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
            --arg prepared "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
            --arg exit "$(sha256 "$windows_installer_exit_receipt")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
            --arg recovery "$(sha256 "$local_recovery_bundle")" --arg rollback "$(sha256 "$local_windows_rollback_receipt")" '
            .committed_artifacts == {marker_handoff:$h,linux_frozen:$b,publish_receipt:$p,
              bootstrap_request:$request,windows_prepared:$prepared,mutation_permit:$permit,windows_exit:$exit,
              windows_stop_evidence:$stop,recovery_bundle:$recovery,windows_rollback:$rollback}
        ' "$path" >/dev/null || die 'post-permit rollback terminal artifacts differ from exact committed hashes'
        return
    fi
    jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg handoff "$bootstrap_handoff_receipt" --arg publish "$deployment_publish_receipt" \
        --arg frozen "$bootstrap_linux_evidence" --arg force "$windows_force_envelope" \
        --arg request "$windows_bootstrap_request" --arg stop "$local_windows_stop_evidence" \
        --arg rollback "$local_windows_rollback_receipt" '
        keys == ["committed_artifacts","contract","operation_id","phase","recovery","schema_version","state"] and
        .schema_version == 2 and .state == "viewflow-cross-host-bootstrap" and .operation_id == $op and
        .phase == "WINDOWS_ROLLED_BACK" and .recovery.mutation_possible == true and
        (.contract | keys) == ["identity","inputs","outputs","remote"] and
        .contract.identity.coordinator_instance_id == $coordinator and
        .contract.identity.marker_generation == $generation and
        .contract.identity.source_display_id == $source and .contract.identity.target_device_id == $target and
        .contract.inputs.marker_handoff.path == $handoff and .contract.inputs.publish_receipt.path == $publish and
        .contract.inputs.linux_frozen.path == $frozen and .contract.outputs.request == $request and
        .contract.outputs.force_envelope == $force and
        .contract.outputs.windows_stop_evidence == $stop and .contract.outputs.windows_rollback == $rollback and
        ((.committed_artifacts | keys) as $names |
         all($names[]; . as $name |
             ["bootstrap_request","cpp_arm","cpp_cleanup","cpp_status","cross_chain","deployment_release","force_envelope","linux_finalize","linux_frozen","linux_stage","marker_handoff","mutation_permit","post_release","publish_receipt","recovery_bundle","recovery_publish","recovery_publish_intent","rust_arm","rust_final","windows_exit","windows_install","windows_prepared","windows_restart","windows_restart_intent","windows_rollback","windows_stop_evidence"] |
             index($name) != null))
    ' "$path" >/dev/null || die 'old coordinator terminal state contract is invalid'
    jq -e --arg h "$(sha256 "$bootstrap_handoff_receipt")" --arg p "$(sha256 "$deployment_publish_receipt")" \
        --arg b "$(sha256 "$bootstrap_linux_evidence")" --arg f "$(sha256 "$windows_force_envelope")" \
        --arg request "$windows_request_sha" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
        --arg rollback "$(sha256 "$local_windows_rollback_receipt")" '
        .committed_artifacts.marker_handoff == $h and .committed_artifacts.publish_receipt == $p and
        .committed_artifacts.linux_frozen == $b and .committed_artifacts.force_envelope == $f and
        .committed_artifacts.bootstrap_request == $request and
        .committed_artifacts.windows_stop_evidence == $stop and .committed_artifacts.windows_rollback == $rollback
    ' "$path" >/dev/null || die 'old terminal artifacts differ from append-only committed hashes'
}

validate_pre_mutation_failed_terminal_state() {
    local path=$coordinator_state state_request state_exit state_stop expected_retry
    require_owner_only_regular 'pre-mutation failed coordinator state' "$path"
    [[ $(sha256 "$path") == "$old_coordinator_state_sha" ]] ||
        die 'pre-mutation failed coordinator state SHA differs'
    assert_strict_json_document 'pre-mutation failed coordinator state' "$path"
    state_request=$(jq -er '.contract.outputs.request | select(type == "string" and startswith("/"))' "$path")
    state_exit=$(jq -er '.contract.outputs.windows_exit | select(type == "string" and startswith("/"))' "$path")
    state_stop=$(jq -er '.contract.outputs.windows_stop_evidence | select(type == "string" and startswith("/"))' "$path")
    expected_retry="${coordinator_state}.pre-mutation-retry.json"
    [[ -z $windows_bootstrap_request || $windows_bootstrap_request == "$state_request" ]] ||
        die 'caller request path differs from pre-mutation failed state'
    [[ -z $windows_installer_exit_receipt || $windows_installer_exit_receipt == "$state_exit" ]] ||
        die 'caller installer-exit path differs from pre-mutation failed state'
    [[ -z $local_windows_stop_evidence || $local_windows_stop_evidence == "$state_stop" ]] ||
        die 'caller stop-evidence path differs from pre-mutation failed state'
    windows_bootstrap_request=$state_request
    windows_installer_exit_receipt=$state_exit
    local_windows_stop_evidence=$state_stop
    pre_mutation_retry_proof=$expected_retry
    jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg request "$state_request" --arg exit "$state_exit" --arg stop "$state_stop" '
        keys == ["committed_artifacts","contract","operation_id","phase","recovery","schema_version","state"] and
        .schema_version == 2 and .state == "viewflow-cross-host-bootstrap" and .operation_id == $op and
        .phase == "LINUX_RECOVERED" and
        .recovery == {failure_phase:"WINDOWS_STARTED",mutation_possible:false} and
        (.committed_artifacts | keys) == ["bootstrap_request","linux_frozen","marker_handoff","pre_mutation_retry","publish_receipt","windows_exit","windows_stop_evidence"] and
        (.contract | keys) == ["identity","inputs","outputs","remote"] and
        .contract.identity.coordinator_instance_id == $coordinator and
        .contract.identity.marker_generation == $generation and
        .contract.identity.source_display_id == $source and .contract.identity.target_device_id == $target and
        .contract.outputs.request == $request and .contract.outputs.windows_exit == $exit and
        .contract.outputs.windows_stop_evidence == $stop
    ' "$path" >/dev/null || die 'pre-mutation failed state phase/contract is invalid'
    for artifact_path in "$bootstrap_handoff_receipt" "$deployment_publish_receipt" "$bootstrap_linux_evidence" \
        "$windows_bootstrap_request" "$windows_installer_exit_receipt" "$local_windows_stop_evidence" "$pre_mutation_retry_proof"; do
        require_owner_only_regular 'pre-mutation committed artifact' "$artifact_path"
    done
    windows_request_sha=$(sha256 "$windows_bootstrap_request")
    jq -e --arg h "$(sha256 "$bootstrap_handoff_receipt")" --arg p "$(sha256 "$deployment_publish_receipt")" \
        --arg b "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
        --arg retry "$(sha256 "$pre_mutation_retry_proof")" --arg exit "$(sha256 "$windows_installer_exit_receipt")" \
        --arg stop "$(sha256 "$local_windows_stop_evidence")" '
        .committed_artifacts == {marker_handoff:$h,linux_frozen:$b,publish_receipt:$p,
          bootstrap_request:$request,pre_mutation_retry:$retry,windows_exit:$exit,windows_stop_evidence:$stop}
    ' "$path" >/dev/null || die 'pre-mutation committed artifact hashes differ'
    assert_strict_json_document 'failed Windows installer exit' "$windows_installer_exit_receipt"
    jq -e --arg op "$operation_id" --arg request "$windows_request_sha" '
        keys == ["claim_sha256","completed_at_utc","exit_code","installer_command_sha256","operation_id","request_sha256","schema_version","state"] and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-failed" and .operation_id == $op and
        .exit_code == 1 and .request_sha256 == $request and
        (.claim_sha256 | test("^[0-9a-f]{64}$")) and (.installer_command_sha256 | test("^[0-9a-f]{64}$")) and
        (.completed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
    ' "$windows_installer_exit_receipt" >/dev/null || die 'failed installer exit is not the exact exit-1 terminal'
    validate_windows_stop_evidence "$local_windows_stop_evidence"
    [[ $(jq -er '.claim_sha256' "$windows_installer_exit_receipt") == $(jq -er '.claim_sha256' "$local_windows_stop_evidence") ]] ||
        die 'installer exit and stop evidence bind different launcher claims'
    pre_mutation_old_executable_sha=$(jq -er '.old_executable_sha256' "$pre_mutation_retry_proof")
    pre_mutation_old_wrapper_sha=$(jq -er '.old_wrapper_sha256' "$pre_mutation_retry_proof")
    pre_mutation_old_task_xml_sha=$(jq -er '.task_xml_sha256' "$pre_mutation_retry_proof")
    pre_mutation_old_process_id=$(jq -er '.viewflow_process.process_id' "$pre_mutation_retry_proof")
    pre_mutation_old_parent_process_id=$(jq -er '.viewflow_process.parent_process_id' "$pre_mutation_retry_proof")
    pre_mutation_old_process_creation_date=$(jq -er '.viewflow_process.creation_date' "$pre_mutation_retry_proof")
    pre_mutation_old_windows_binary_sha=$pre_mutation_old_executable_sha
    pre_mutation_old_windows_wrapper_sha=$pre_mutation_old_wrapper_sha
    pre_mutation_old_windows_task_sha=$pre_mutation_old_task_xml_sha
    pre_mutation_old_windows_rollback_sha=$(jq -er '.old_rollback_sha256' "$pre_mutation_retry_proof")
    if ((abort_failed_v13_pre_mutation)); then
        windows_launcher_sha=$(jq -er '.contract.inputs.windows_launcher.sha256' "$coordinator_state")
        windows_installer_sha=$(jq -er '.contract.inputs.windows_installer.sha256' "$coordinator_state")
        windows_viewflow_sha=$(jq -er '.contract.inputs.windows_viewflow.sha256' "$coordinator_state")
        windows_wrapper_sha=$(jq -er '.contract.inputs.windows_wrapper.sha256' "$coordinator_state")
        windows_rollback_script_sha=$(jq -er '.contract.inputs.windows_rollback.sha256' "$coordinator_state")
        derive_windows_paths
    fi
    validate_pre_mutation_retry_proof "$pre_mutation_retry_proof"
}

validate_pre_mutation_failed_baseline() {
    local state_marker_cli state_viewflow state_deskflow state_core
    assert_strict_json_document 'pre-mutation marker handoff' "$bootstrap_handoff_receipt"
    assert_strict_json_document 'pre-mutation Linux frozen evidence' "$bootstrap_linux_evidence"
    jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg marker "$DEPLOYMENT_MARKER" --arg runtime "$RUNTIME_MARKER" '
        keys == ["coordinator_instance_id","deployment_marker_path","deployment_marker_sha256","deployment_publish_receipt_path","deployment_publish_receipt_sha256","deskflow_core_exact_process_count","deskflow_core_executable_path","deskflow_core_executable_sha256","deskflow_exact_process_count","deskflow_executable_path","deskflow_executable_sha256","deskflow_tcp_listener_count","deskflow_tcp_port","deskflow_unit","deskflow_unit_active_state","deskflow_unit_main_pid","marker_cli_path","marker_cli_sha256","marker_generation","observed_at_utc","operation_id","protocol_version","runtime_marker_path","runtime_marker_present","schema_version","source_display_id","state","target_device_id"] and
        .schema_version == 1 and .state == "viewflow-v13-marker-handoff-prepared" and
        .operation_id == $op and .coordinator_instance_id == $coordinator and .marker_generation == "1" and
        .source_display_id == $source and .target_device_id == $target and
        .deployment_marker_path == $marker and .runtime_marker_path == $runtime and
        .deskflow_unit == "deskflow.service" and .deskflow_unit_active_state == "inactive" and
        .deskflow_unit_main_pid == 0 and .deskflow_exact_process_count == 0 and
        .deskflow_core_exact_process_count == 0 and .deskflow_tcp_listener_count == 0 and
        .deskflow_tcp_port == 24800 and .runtime_marker_present == false and
        (.marker_cli_sha256 | test("^[0-9a-f]{64}$")) and
        (.deskflow_executable_sha256 | test("^[0-9a-f]{64}$")) and
        (.deskflow_core_executable_sha256 | test("^[0-9a-f]{64}$"))
    ' "$bootstrap_handoff_receipt" >/dev/null || die 'pre-mutation marker handoff contract is invalid'
    jq -e --arg op "$operation_id" '
        .schema_version == 1 and .state == "viewflow-v13-bootstrap-frozen" and .operation_id == $op and
        .daemon.executable == "/home/wilf/.local/lib/viewflow/viewflowd" and
        (.daemon.sha256 | test("^[0-9a-f]{64}$")) and
        .journal.counts.protocol_1_3_startup == 1 and
        .pre_stop.deskflow_unit_active_state == "inactive" and .pre_stop.deskflow_main_pid == 0 and
        .pre_stop.deskflow_exact_process_count == 0 and .pre_stop.deskflow_core_exact_process_count == 0 and
        .pre_stop.deskflow_tcp_24800_listener_count == 0 and
        .post_stop.unit_active_state == "inactive" and .post_stop.main_pid == 0 and
        .post_stop.exact_process_count == 0 and .post_stop.udp_44119_listener_count == 0 and
        .post_stop.sidecar_socket_present == false
    ' "$bootstrap_linux_evidence" >/dev/null || die 'pre-mutation Linux frozen baseline is invalid'
    old_viewflow_sha=$(jq -er '.daemon.sha256' "$bootstrap_linux_evidence")
    old_deskflow_sha=$(jq -er '.deskflow_executable_sha256' "$bootstrap_handoff_receipt")
    old_deskflow_core_sha=$(jq -er '.deskflow_core_executable_sha256' "$bootstrap_handoff_receipt")
    old_marker_cli_sha=$(jq -er '.marker_cli_sha256' "$bootstrap_handoff_receipt")
    state_marker_cli=$(jq -er '.contract.inputs.linux_marker_cli.sha256' "$coordinator_state")
    state_viewflow=$(jq -er '.contract.inputs.linux_viewflow.sha256' "$coordinator_state")
    state_deskflow=$(jq -er '.contract.inputs.linux_deskflow.sha256' "$coordinator_state")
    state_core=$(jq -er '.contract.inputs.linux_deskflow_core.sha256' "$coordinator_state")
    [[ $state_marker_cli == "$old_marker_cli_sha" && $state_viewflow != "$old_viewflow_sha" &&
       $state_deskflow == "$old_deskflow_sha" && $state_core != "$old_deskflow_core_sha" ]] ||
        die 'pre-mutation old/candidate Linux artifact bindings are inconsistent'
    [[ $(sha256 "$MARKER_CLI") == "$old_marker_cli_sha" && $(sha256 "$VIEWFLOW_INSTALLED") == "$old_viewflow_sha" &&
       $(sha256 "$DESKFLOW_INSTALLED") == "$old_deskflow_sha" &&
       $(sha256 "$DESKFLOW_CORE_INSTALLED") == "$old_deskflow_core_sha" ]] ||
        die 'pre-mutation installed Linux v1.3 bytes differ'
    [[ ! -e $RUNTIME_MARKER && ! -L $RUNTIME_MARKER ]] || die 'pre-mutation abort refuses VFQST002'
}

assert_pre_mutation_outputs_absent() {
    local name path
    for name in prepared permit force_envelope linux_stage windows_install linux_finalize release cross_chain \
        post_release windows_restart cpp_status cpp_arm cpp_cleanup rust_arm rust_query recovery_publish \
        linux_deactivation_proof linux_deactivation_transcript linux_containment windows_validation \
        windows_rollback recovery_bundle recovery_publish_intent windows_restart_intent; do
        path=$(jq -er --arg name "$name" '.contract.outputs[$name] | select(type == "string" and startswith("/"))' "$coordinator_state")
        [[ ! -e $path && ! -L $path ]] || die "pre-mutation abort found forbidden local output: $name"
    done
    [[ ! -e ${DEPLOYMENT_MARKER}.release-claim && ! -e ${DEPLOYMENT_MARKER}.abort-claim ]] ||
        die 'pre-mutation abort found a marker transaction claim'
}

validate_pre_mutation_windows_live_proof() {
    local proof=$1
    require_owner_only_regular 'pre-mutation Windows live proof' "$proof"
    assert_strict_json_document 'pre-mutation Windows live proof' "$proof"
    jq -e --arg op "$operation_id" --arg sid "$windows_user_sid" --arg root "$windows_operation_root" \
        --arg retry "$(sha256 "$pre_mutation_retry_proof")" \
        --arg binary "$pre_mutation_old_windows_binary_sha" --arg wrapper "$pre_mutation_old_windows_wrapper_sha" \
        --arg task "$pre_mutation_old_windows_task_sha" --arg rollback "$pre_mutation_old_windows_rollback_sha" \
        --arg local_stop "$(sha256 "$local_windows_stop_evidence")" \
        --arg remote_stop "${current_pre_mutation_remote_stop_sha:-}" \
        --arg remote_exit "${current_pre_mutation_remote_exit_sha:-}" \
        --arg transport "$PRE_MUTATION_STOP_TRANSPORT_NORMALIZATION" \
        --arg claim "${current_pre_mutation_claim_sha:-}" --arg process "${current_pre_mutation_process_sha:-}" \
        --arg stdout "${current_pre_mutation_stdout_sha:-}" --arg stderr "${current_pre_mutation_stderr_sha:-}" \
        --argjson pid "$pre_mutation_old_process_id" --argjson parent "$pre_mutation_old_parent_process_id" \
        --arg creation "$pre_mutation_old_process_creation_date" '
        keys == ["deployment_task","installer_stderr_sha256","installer_stdout_sha256","local_committed_stop_sha256","mutation_outputs_absent","observed_at_utc","old_executable_sha256","old_rollback_sha256","old_wrapper_sha256","operation_id","operation_root","pre_mutation_retry_receipt_sha256","process_counts","remote_installer_process_receipt_sha256","remote_launcher_claim_sha256","remote_operation_root","remote_raw_installer_exit_sha256","remote_raw_stop_sha256","schema_version","state","task","task_xml_sha256","threat_boundary","transport_normalization","user_sid","viewflow_process"] and
        .schema_version == 1 and .state == "viewflow-failed-pre-mutation-installer-current-old-windows-baseline-live" and
        .operation_id == $op and .user_sid == $sid and .remote_operation_root == $root and
        .threat_boundary == "cooperating-crash-and-non-owner" and
        .local_committed_stop_sha256 == $local_stop and .remote_raw_stop_sha256 == $remote_stop and
        .remote_raw_installer_exit_sha256 == $remote_exit and .transport_normalization == $transport and
        .pre_mutation_retry_receipt_sha256 == $retry and
        .remote_launcher_claim_sha256 == $claim and .remote_installer_process_receipt_sha256 == $process and
        .installer_stdout_sha256 == $stdout and .installer_stderr_sha256 == $stderr and
        .old_executable_sha256 == $binary and .old_wrapper_sha256 == $wrapper and
        .old_rollback_sha256 == $rollback and .task_xml_sha256 == $task and
        (.observed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
        .mutation_outputs_absent == true and
        (.operation_root | keys) == ["access_rules_protected","acl_rule_count","directory_member_count","installed_file_acl_checks","member_count","owner_sid","staged_file_acl_checks"] and
        .operation_root.member_count == 14 and .operation_root.directory_member_count == 0 and
        .operation_root.acl_rule_count == 2 and .operation_root.owner_sid == $sid and
        .operation_root.access_rules_protected == true and
        .operation_root.staged_file_acl_checks == 14 and .operation_root.installed_file_acl_checks == 3 and
        (.process_counts | keys) == ["installer","viewflow"] and
        .process_counts.installer == 0 and .process_counts.viewflow == 1 and
        (.deployment_task | keys) == ["installer_process_count","state","task_name","task_xml_sha256","worker_pid_absent"] and
        .deployment_task.task_name == ("Viewflow Deployment " + $op) and .deployment_task.state == "Disabled" and
        (.deployment_task.installer_process_count | type == "number" and . == floor and . == 0) and .deployment_task.worker_pid_absent == true and
        (.deployment_task.task_xml_sha256 | test("^[0-9a-f]{64}$")) and
        (.task | keys) == ["action_arguments","action_execute","action_working_directory","logon_type","principal_sid","run_level","state","task_path"] and
        .task.task_path == "\\Viewflow Peer" and .task.state == "Running" and
        .task.action_execute == "C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" and
        .task.action_arguments == "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflow-client.ps1\"" and
        .task.action_working_directory == "C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow" and
        .task.principal_sid == $sid and .task.logon_type == "Interactive" and .task.run_level == "Limited" and
        (.viewflow_process | keys) == ["command_line","creation_date","executable_path","owner_sid","parent_process_id","process_id","session_id"] and
        (.viewflow_process.process_id | type == "number" and . == floor and . >= 1 and . <= 4294967295) and .viewflow_process.process_id == $pid and
        (.viewflow_process.parent_process_id | type == "number" and . == floor and . >= 1 and . <= 4294967295) and .viewflow_process.parent_process_id == $parent and
        .viewflow_process.creation_date == $creation and
        (.viewflow_process.session_id | type == "number" and . == floor and . == 1) and
        .viewflow_process.owner_sid == $sid and
        .viewflow_process.executable_path == "C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe" and
        .viewflow_process.command_line == "\"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe\" connect --peer 172.16.105.62:44119 --server-name viewflow-linux --cert C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\peer.pem --key C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\peer.key --ca C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\identity\\ca.pem --input-backend native --device-id 00000000000000000000000000000002 --probe-interval-ms 1000 --probe-timeout-ms 3000"
    ' "$proof" >/dev/null || die 'pre-mutation Windows live proof is invalid'
    validate_windows_identity_scalar "$proof" deployment_task.installer_process_count zero-uint32
    validate_windows_identity_scalar "$proof" viewflow_process.process_id positive-uint32
    validate_windows_identity_scalar "$proof" viewflow_process.parent_process_id positive-uint32
    validate_windows_identity_scalar "$proof" viewflow_process.session_id session-one
    validate_windows_identity_scalar "$proof" observed_at_utc utc-milliseconds
}

validate_pre_mutation_stop_transport_bridge() {
    local remote=$1 local_committed=$2 remote_canonical local_canonical
    validate_windows_stop_evidence "$remote"
    validate_windows_stop_evidence "$local_committed"
    "$FD_GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \
        "$FD_GATE_PYTHON" -I -E -c 'import pathlib,sys
r=pathlib.Path(sys.argv[1]).read_bytes(); l=pathlib.Path(sys.argv[2]).read_bytes()
ok=(len(r)>1 and r.endswith(b"\n") and not r.endswith(b"\r\n") and r.count(b"\n")==1 and b"\r" not in r and len(l)>2 and l.endswith(b"\r\n") and l.count(b"\n")==1 and l.count(b"\r")==1 and l[:-2]==r[:-1])
raise SystemExit(0 if ok else 1)' "$remote" "$local_committed" ||
        die 'remote/local launcher-stop evidence violates the exact LF-to-CRLF transport bridge'
    remote_canonical=$(jq -S -c . "$remote")
    local_canonical=$(jq -S -c . "$local_committed")
    [[ $remote_canonical == "$local_canonical" ]] ||
        die 'remote/local launcher-stop evidence canonical JSON differs'
}

validate_pre_mutation_remote_launcher_claim() {
    local claim=$1 worker_pid=$2 installer_command_sha=$3
    jq -e --arg op "$operation_id" --arg request "$windows_request_sha" --arg sid "$windows_user_sid" \
        --arg launcher "$windows_launcher_sha" --arg task "$(jq -er '.task_xml_sha256' "$local_windows_stop_evidence")" \
        --arg installer "$installer_command_sha" --argjson pid "$worker_pid" '
        keys == ["claimed_at_utc","installer_command_sha256","launcher_path","launcher_sha256","operation_id","owner_sid","pid","process_start_filetime_utc","request_sha256","schema_version","session_id","state","task_command_sha256","task_name","task_xml_sha256","worker_executable_path"] and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-claimed" and .operation_id == $op and
        .request_sha256 == $request and .launcher_sha256 == $launcher and .task_xml_sha256 == $task and
        .installer_command_sha256 == $installer and .pid == $pid and
        (.pid | type == "number" and . == floor and . >= 1 and . <= 4294967295) and
        .owner_sid == $sid and (.session_id | type == "number" and . == floor and . == 1) and
        .task_name == ("Viewflow Deployment " + $op) and
        (.worker_executable_path | ascii_downcase) == "c:\\windows\\system32\\windowspowershell\\v1.0\\powershell.exe" and
        (.process_start_filetime_utc | test("^[1-9][0-9]{16,18}$")) and
        (.task_command_sha256 | test("^[0-9a-f]{64}$")) and
        (.claimed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
    ' "$claim" >/dev/null || die 'remote launcher claim schema/binding is invalid'
    validate_windows_identity_scalar "$claim" pid positive-uint32
    validate_windows_identity_scalar "$claim" session_id session-one
    validate_windows_identity_scalar "$claim" process_start_filetime_utc canonical-filetime
    validate_windows_identity_scalar "$claim" claimed_at_utc utc-milliseconds
}

validate_pre_mutation_stop_claim_identity() {
    local stop=$1 claim=$2
    [[ $(jq -er '.worker_process_start_filetime_utc' "$stop") == \
       "$(jq -er '.process_start_filetime_utc' "$claim")" ]] ||
        die 'stop evidence and remote launcher claim bind different worker process start times'
}

validate_pre_mutation_remote_installer_process() {
    local process=$1 worker_pid=$2 claim_sha=$3 installer_command_sha=$4
    jq -e --arg op "$operation_id" --arg request "$windows_request_sha" --arg claim "$claim_sha" \
        --arg installer "$installer_command_sha" --arg sid "$windows_user_sid" --argjson parent "$worker_pid" '
        keys == ["claim_sha256","executable_path","installer_command_sha256","operation_id","owner_sid","parent_pid","pid","process_start_filetime_utc","request_sha256","schema_version","session_id","started_at_utc","state"] and
        .schema_version == 1 and .state == "viewflow-windows-bootstrap-installer-running" and
        .operation_id == $op and .request_sha256 == $request and .claim_sha256 == $claim and
        .installer_command_sha256 == $installer and .parent_pid == $parent and
        (.parent_pid | type == "number" and . == floor and . >= 1 and . <= 4294967295) and
        .owner_sid == $sid and (.session_id | type == "number" and . == floor and . == 1) and
        (.pid | type == "number" and . == floor and . >= 1 and . <= 4294967295) and
        (.executable_path | ascii_downcase) == "c:\\windows\\system32\\windowspowershell\\v1.0\\powershell.exe" and
        (.process_start_filetime_utc | test("^[1-9][0-9]{16,18}$")) and
        (.started_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
    ' "$process" >/dev/null || die 'remote installer process receipt schema/binding is invalid'
    validate_windows_identity_scalar "$process" parent_pid positive-uint32
    validate_windows_identity_scalar "$process" pid positive-uint32
    validate_windows_identity_scalar "$process" session_id session-one
    validate_windows_identity_scalar "$process" process_start_filetime_utc canonical-filetime
    validate_windows_identity_scalar "$process" started_at_utc utc-milliseconds
}

capture_pre_mutation_windows_live_proof() {
    local remote_stop remote_exit remote_claim remote_process remote_stdout remote_stderr live command
    local existing_stable live_stable worker_pid installer_pid deployment_task_xml_sha claim_sha installer_command_sha
    pre_mutation_windows_live_counter=$((${pre_mutation_windows_live_counter:-0} + 1))
    remote_stop=$secure_dir/remote-launcher-stop.${pre_mutation_windows_live_counter}.json
    remote_exit=$secure_dir/remote-installer-exit.${pre_mutation_windows_live_counter}.json
    remote_claim=$secure_dir/remote-launcher-claim.${pre_mutation_windows_live_counter}.json
    remote_process=$secure_dir/remote-installer-process.${pre_mutation_windows_live_counter}.json
    remote_stdout=$secure_dir/remote-installer-stdout.${pre_mutation_windows_live_counter}.log
    remote_stderr=$secure_dir/remote-installer-stderr.${pre_mutation_windows_live_counter}.log
    live=$secure_dir/pre-mutation-windows-live.${pre_mutation_windows_live_counter}.json
    windows_read_file "$windows_stop_evidence_path" "$remote_stop"
    validate_pre_mutation_stop_transport_bridge "$remote_stop" "$local_windows_stop_evidence"
    windows_read_file "$windows_exit_path" "$remote_exit"
    [[ $(sha256 "$remote_exit") == "$(sha256 "$windows_installer_exit_receipt")" ]] ||
        die 'remote durable installer-exit bytes differ from local committed receipt'
    assert_strict_json_document 'remote failed installer exit' "$remote_exit"
    windows_read_file "$windows_operation_root\launcher-claim.json" "$remote_claim"
    windows_read_file "$windows_operation_root\launcher-installer-process.json" "$remote_process"
    windows_read_file "$windows_operation_root\installer.stdout.log" "$remote_stdout"
    windows_read_file "$windows_operation_root\installer.stderr.log" "$remote_stderr"
    assert_strict_json_document 'remote launcher claim' "$remote_claim"
    assert_strict_json_document 'remote installer process receipt' "$remote_process"
    worker_pid=$(jq -er '.worker_pid' "$local_windows_stop_evidence")
    claim_sha=$(sha256 "$remote_claim")
    installer_command_sha=$(jq -er '.installer_command_sha256' "$windows_installer_exit_receipt")
    validate_pre_mutation_remote_launcher_claim "$remote_claim" "$worker_pid" "$installer_command_sha"
    validate_pre_mutation_stop_claim_identity "$remote_stop" "$remote_claim"
    [[ $(jq -er '.claim_sha256' "$windows_installer_exit_receipt") == "$claim_sha" &&
       $(jq -er '.claim_sha256' "$local_windows_stop_evidence") == "$claim_sha" ]] ||
        die 'remote launcher claim bytes differ from exit/stop claim hash'
    validate_pre_mutation_remote_installer_process "$remote_process" "$worker_pid" "$claim_sha" "$installer_command_sha"
    installer_pid=$(jq -er '.pid' "$remote_process")
    current_pre_mutation_claim_sha=$(sha256 "$remote_claim")
    current_pre_mutation_process_sha=$(sha256 "$remote_process")
    current_pre_mutation_stdout_sha=$(sha256 "$remote_stdout")
    current_pre_mutation_stderr_sha=$(sha256 "$remote_stderr")
    current_pre_mutation_remote_stop_sha=$(sha256 "$remote_stop")
    current_pre_mutation_remote_exit_sha=$(sha256 "$remote_exit")
    deployment_task_xml_sha=$(jq -er '.task_xml_sha256' "$local_windows_stop_evidence")
    # Build the single reviewed exact probe. The quoted heredoc prevents the local shell from interpreting any
    # PowerShell expression; only the fixed placeholders below are replaced.
    read -r -d '' command <<'POWERSHELL' || true
$ErrorActionPreference='Stop'
function HB([byte[]]$b){$s=[Security.Cryptography.SHA256]::Create();try{(([BitConverter]::ToString($s.ComputeHash($b))).Replace('-','')).ToLowerInvariant()}finally{$s.Dispose()}}
function CS([string]$v){try{return([Security.Principal.SecurityIdentifier]::new($v)).Value}catch{return([Security.Principal.NTAccount]::new($v)).Translate([Security.Principal.SecurityIdentifier]).Value}}
function OwnerProtectedFile([string]$p){$i=Get-Item -LiteralPath $p -Force -ErrorAction Stop;if($i.PSIsContainer-or($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'unsafe regular file'};$a=Get-Acl -LiteralPath $p -ErrorAction Stop;$r=@($a.Access);if((CS $a.Owner)-cne'__SID__'-or-not$a.AreAccessRulesProtected-or$r.Count-ne1-or$r[0].IsInherited-or$r[0].AccessControlType-ne'Allow'-or(CS $r[0].IdentityReference.Value)-cne'__SID__'-or$r[0].FileSystemRights-ne'FullControl'-or$r[0].InheritanceFlags-ne'None'-or$r[0].PropagationFlags-ne'None'){throw 'unsafe installed file ACL'}}
function OwnerOnlyStaged([string]$p){$i=Get-Item -LiteralPath $p -Force -ErrorAction Stop;if($i.PSIsContainer-or($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'unsafe staged file'};$a=Get-Acl -LiteralPath $p -ErrorAction Stop;$r=@($a.Access);if((CS $a.Owner)-cne'__SID__'-or-not$a.AreAccessRulesProtected-or$r.Count-ne1-or$r[0].IsInherited-or$r[0].AccessControlType-ne'Allow'-or(CS $r[0].IdentityReference.Value)-cne'__SID__'-or$r[0].FileSystemRights-ne'FullControl'-or$r[0].InheritanceFlags-ne'None'-or$r[0].PropagationFlags-ne'None'){throw 'unsafe staged ACL'}}
$root='__ROOT__'
$rootItem=Get-Item -LiteralPath $root -Force -ErrorAction Stop
if(-not$rootItem.PSIsContainer-or($rootItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'unsafe operation root'}
$rootAcl=Get-Acl -LiteralPath $root -ErrorAction Stop
$rootOwnerSid=CS $rootAcl.Owner
if($rootOwnerSid-cne'__SID__'-or-not$rootAcl.AreAccessRulesProtected){throw 'unsafe operation root ACL'}
$rootRules=@($rootAcl.Access);if($rootRules.Count-ne2){throw 'unexpected operation root ACL count'};$rootSeen=@{};foreach($r in $rootRules){$rs=CS $r.IdentityReference.Value;if($r.IsInherited-or$r.AccessControlType-ne'Allow'-or$r.FileSystemRights-ne'FullControl'-or$r.InheritanceFlags-ne'ContainerInherit, ObjectInherit'-or$r.PropagationFlags-ne'None'-or($rs-ne'__SID__'-and$rs-ne'S-1-5-18')-or$rootSeen.ContainsKey($rs)){throw 'unsafe operation root ACL rule'};$rootSeen[$rs]=$true}
$expected=[ordered]@{'install-viewflow.ps1'='__INSTALLER_SHA__';'linux-v13-frozen-evidence.json'='__FROZEN_SHA__';'marker-handoff-receipt.json'='__HANDOFF_SHA__';'request.json'='__REQUEST_SHA__';'rollback-viewflow.ps1'='__ROLLBACK_SCRIPT_SHA__';'start-viewflow-bootstrap.ps1'='__LAUNCHER_SHA__';'viewflow-client.ps1'='__CANDIDATE_WRAPPER_SHA__';'viewflowd.exe'='__CANDIDATE_SHA__';'installer-exit.json'='__EXIT_SHA__';'launcher-stop-evidence.json'='__STOP_SHA__';'launcher-claim.json'='__CLAIM_SHA__';'launcher-installer-process.json'='__PROCESS_SHA__';'installer.stdout.log'='__STDOUT_SHA__';'installer.stderr.log'='__STDERR_SHA__'}
$members=@(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)
$directoryMemberCount=@($members|Where-Object{$_.PSIsContainer}).Count
if($members.Count-ne$expected.Count-or$directoryMemberCount-ne0){throw 'unexpected operation-root member count'}
foreach($leaf in $expected.Keys){$p=Join-Path $root $leaf;OwnerOnlyStaged $p;if((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()-cne$expected[$leaf]){throw 'operation-root member hash differs'}}
$forbidden=@('__PREPARED__','__PERMIT__','__RAW_FORCE__','__FORCE__','__STAGE__','__INSTALL__','__READY__','__COMMIT__','__MANIFEST__','__TOKEN__','__BUNDLE__','__RECOVERY_FORCE__','__ROLLBACK_RECEIPT__','__ROLLBACK_CLAIM__')
foreach($p in $forbidden){if(Test-Path -LiteralPath $p){throw 'mutating output exists'}}
$deployment=Get-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Deployment __OP__' -ErrorAction Stop
if([string]$deployment.State-cne'Disabled'){throw 'deployment task not Disabled'}
$enc=New-Object Text.UnicodeEncoding($false,$true);$pre=$enc.GetPreamble()
$dxml=Export-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Deployment __OP__';$body=$enc.GetBytes($dxml);$bytes=New-Object byte[] ($pre.Length+$body.Length);[Array]::Copy($pre,0,$bytes,0,$pre.Length);[Array]::Copy($body,0,$bytes,$pre.Length,$body.Length);$dsha=HB $bytes
if($dsha-cne'__DEPLOYMENT_TASK_SHA__'){throw 'deployment task XML differs'}
if(Get-Process -Id __WORKER_PID__ -ErrorAction SilentlyContinue){throw 'launcher worker still exists'}
if(Get-Process -Id __INSTALLER_PID__ -ErrorAction SilentlyContinue){throw 'installer child still exists'}
$installers=@(Get-CimInstance Win32_Process|Where-Object{$_.CommandLine-like'*install-viewflow.ps1*' -and $_.CommandLine-like'*__OP__*'})
if($installers.Count-ne0){throw 'installer process remains'}
$task=Get-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer' -ErrorAction Stop
$principalSid=CS ([string]$task.Principal.UserId)
if([string]$task.State-cne'Running'-or$principalSid-cne'__SID__'){throw 'old task identity differs'}
$xml=Export-ScheduledTask -TaskPath '\' -TaskName 'Viewflow Peer';$body=$enc.GetBytes($xml);$bytes=New-Object byte[] ($pre.Length+$body.Length);[Array]::Copy($pre,0,$bytes,0,$pre.Length);[Array]::Copy($body,0,$bytes,$pre.Length,$body.Length);$taskSha=HB $bytes
if($taskSha-cne'__OLD_TASK_SHA__'){throw 'old task XML differs'}
$exe='C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflowd.exe';$wrapperPath='C:\Users\wilf\AppData\Local\Programs\Viewflow\viewflow-client.ps1';$rollbackPath='C:\Users\wilf\AppData\Local\Programs\Viewflow\rollback-viewflow.ps1'
OwnerProtectedFile $exe;OwnerProtectedFile $wrapperPath;OwnerProtectedFile $rollbackPath
$binary=HB ([IO.File]::ReadAllBytes($exe));$wrapper=HB ([IO.File]::ReadAllBytes($wrapperPath));$rollback=HB ([IO.File]::ReadAllBytes($rollbackPath))
if($binary-cne'__OLD_BINARY_SHA__'-or$wrapper-cne'__OLD_WRAPPER_SHA__'-or$rollback-cne'__OLD_ROLLBACK_SHA__'){throw 'old installed bytes differ'}
$rows=@(Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'"|Where-Object{$_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath)-ceq$exe})
if($rows.Count-ne1){throw 'old viewflow process count differs'}
$p=$rows[0];$sid=(Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid).Sid;$creation=$p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
[ordered]@{schema_version=1;state='viewflow-failed-pre-mutation-installer-current-old-windows-baseline-live';operation_id='__OP__';user_sid='__SID__';remote_operation_root=$root;threat_boundary='cooperating-crash-and-non-owner';local_committed_stop_sha256='__LOCAL_STOP_SHA__';remote_raw_stop_sha256='__REMOTE_STOP_SHA__';remote_raw_installer_exit_sha256='__REMOTE_EXIT_SHA__';transport_normalization='windows-openssh-terminal-lf-to-local-crlf-v1';remote_launcher_claim_sha256='__CLAIM_SHA__';remote_installer_process_receipt_sha256='__PROCESS_SHA__';installer_stdout_sha256='__STDOUT_SHA__';installer_stderr_sha256='__STDERR_SHA__';pre_mutation_retry_receipt_sha256='__RETRY_SHA__';observed_at_utc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ');old_executable_sha256=$binary;old_wrapper_sha256=$wrapper;old_rollback_sha256=$rollback;task_xml_sha256=$taskSha;mutation_outputs_absent=$true;operation_root=[ordered]@{member_count=[int]$members.Count;directory_member_count=[int]$directoryMemberCount;acl_rule_count=[int]$rootRules.Count;owner_sid=$rootOwnerSid;access_rules_protected=[bool]$rootAcl.AreAccessRulesProtected;staged_file_acl_checks=[int]$expected.Count;installed_file_acl_checks=3};process_counts=[ordered]@{installer=[int]$installers.Count;viewflow=[int]$rows.Count};deployment_task=[ordered]@{task_name='Viewflow Deployment __OP__';state=[string]$deployment.State;task_xml_sha256=$dsha;worker_pid_absent=$true;installer_process_count=[int]$installers.Count};task=[ordered]@{task_path='\Viewflow Peer';state=[string]$task.State;action_execute=$task.Actions[0].Execute;action_arguments=$task.Actions[0].Arguments;action_working_directory=$task.Actions[0].WorkingDirectory;principal_sid=$principalSid;logon_type=[string]$task.Principal.LogonType;run_level=[string]$task.Principal.RunLevel};viewflow_process=[ordered]@{process_id=[int]$p.ProcessId;parent_process_id=[int]$p.ParentProcessId;creation_date=$creation;executable_path=$p.ExecutablePath;session_id=[int]$p.SessionId;owner_sid=[string]$sid;command_line=$p.CommandLine}}|ConvertTo-Json -Compress -Depth 5
POWERSHELL
    command=${command//__SID__/$windows_user_sid}; command=${command//__ROOT__/$windows_operation_root}
    command=${command//__OP__/$operation_id}; command=${command//__WORKER_PID__/$worker_pid}
    command=${command//__INSTALLER_PID__/$installer_pid}
    command=${command//__DEPLOYMENT_TASK_SHA__/$deployment_task_xml_sha}
    command=${command//__OLD_TASK_SHA__/$pre_mutation_old_windows_task_sha}
    command=${command//__OLD_BINARY_SHA__/$pre_mutation_old_windows_binary_sha}
    command=${command//__OLD_WRAPPER_SHA__/$pre_mutation_old_windows_wrapper_sha}
    command=${command//__OLD_ROLLBACK_SHA__/$pre_mutation_old_windows_rollback_sha}
    command=${command//__RETRY_SHA__/$(sha256 "$pre_mutation_retry_proof")}
    command=${command//__LOCAL_STOP_SHA__/$(sha256 "$local_windows_stop_evidence")}
    command=${command//__REMOTE_STOP_SHA__/$(sha256 "$remote_stop")}; command=${command//__REMOTE_EXIT_SHA__/$(sha256 "$remote_exit")}
    command=${command//__CLAIM_SHA__/$(sha256 "$remote_claim")}; command=${command//__PROCESS_SHA__/$(sha256 "$remote_process")}
    command=${command//__STDOUT_SHA__/$(sha256 "$remote_stdout")}; command=${command//__STDERR_SHA__/$(sha256 "$remote_stderr")}
    command=${command//__INSTALLER_SHA__/$windows_installer_sha}; command=${command//__FROZEN_SHA__/$(sha256 "$bootstrap_linux_evidence")}
    command=${command//__HANDOFF_SHA__/$(sha256 "$bootstrap_handoff_receipt")}; command=${command//__REQUEST_SHA__/$windows_request_sha}
    command=${command//__ROLLBACK_SCRIPT_SHA__/$windows_rollback_script_sha}; command=${command//__LAUNCHER_SHA__/$windows_launcher_sha}
    command=${command//__CANDIDATE_WRAPPER_SHA__/$windows_wrapper_sha}; command=${command//__CANDIDATE_SHA__/$windows_viewflow_sha}
    command=${command//__PREPARED__/$windows_prepared_path}; command=${command//__PERMIT__/$windows_permit_path}
    command=${command//__RAW_FORCE__/$windows_raw_force_path}; command=${command//__FORCE__/$windows_force_envelope_path}
    command=${command//__STAGE__/$windows_stage_path}; command=${command//__INSTALL__/$windows_install_path}
    command=${command//__READY__/$windows_readiness_receipt_path}; command=${command//__COMMIT__/$windows_commit_request_path}
    command=${command//__MANIFEST__/$windows_rollback_manifest_path}; command=${command//__TOKEN__/$windows_rollback_token_path}
    command=${command//__BUNDLE__/$windows_recovery_bundle_path}; command=${command//__RECOVERY_FORCE__/$windows_recovery_force_receipt_path}
    command=${command//__ROLLBACK_RECEIPT__/$windows_rollback_receipt_path}; command=${command//__ROLLBACK_CLAIM__/$windows_rollback_claim_path}
    capture_json_command 'fresh pre-mutation Windows old-live proof' "$live" ssh_windows_stdin "$command"
    chmod 0600 "$live"
    validate_pre_mutation_windows_live_proof "$live"
    if [[ -e $pre_mutation_windows_live_proof || -L $pre_mutation_windows_live_proof ]]; then
        validate_pre_mutation_windows_live_proof "$pre_mutation_windows_live_proof"
        existing_stable=$(jq -cS 'del(.observed_at_utc)' "$pre_mutation_windows_live_proof")
        live_stable=$(jq -cS 'del(.observed_at_utc)' "$live")
        [[ $existing_stable == "$live_stable" ]] || die 'fresh Windows old-live tuple changed across abort replay'
    else
        publish_json_file 'durable pre-mutation Windows live proof' "$live" "$pre_mutation_windows_live_proof"
    fi
    current_pre_mutation_windows_live_sha=$(sha256 "$live")
}

validate_failed_v13_baseline_evidence() {
    assert_strict_json_document 'Linux deactivation proof' "$linux_deactivation_proof"
    jq -e --arg op "$operation_id" '
        .schema_version == 3 and .state == "viewflow-linux-deactivated" and .operation_id == $op and
        .stopped_runtime.viewflow.unit_active_state == "inactive" and .stopped_runtime.viewflow.main_pid == 0 and
        .stopped_runtime.viewflow.exact_process_count == 0 and .stopped_runtime.viewflow.udp_44119_listener_count == 0 and
        .stopped_runtime.deskflow.unit_active_state == "inactive" and .stopped_runtime.deskflow.main_pid == 0 and
        .stopped_runtime.deskflow.exact_process_count == 0 and .stopped_runtime.deskflow.core_exact_process_count == 0 and
        .stopped_runtime.deskflow.tcp_24800_listener_count == 0
    ' "$linux_deactivation_proof" >/dev/null || die 'Linux deactivation proof is not the exact inactive baseline'
    validate_windows_stop_evidence "$local_windows_stop_evidence"
    assert_strict_json_document 'Windows migration receipt' "$local_windows_rollback_receipt"
    jq -e --arg op "$operation_id" --arg sid "$windows_user_sid" '
        keys == ["completed_at_utc","consumed_token_path","exact_process_count","linux_deactivation_proof_sha256","linux_deactivation_transcript_sha256","manifest_sha256","operation_id","recovery_bundle_sha256","recovery_force_release_receipt_sha256","restored","rollback_mode","schema_version","stable_observation_ms","state","task_name","task_state","token_sha256","user_sid"] and
        .schema_version == 2 and .state == "viewflow-windows-rollback-completed" and
        .rollback_mode == "bootstrap-v1.3" and .operation_id == $op and .user_sid == $sid and
        .task_name == "\\Viewflow Peer" and .task_state == "Ready" and .exact_process_count == 0 and
        (.restored | keys) == ["binary_path","binary_sha256","restored_task_xml_sha256","task_xml_sha256","wrapper_path","wrapper_sha256"] and
        .restored.task_xml_sha256 == .restored.restored_task_xml_sha256 and
        .restored.binary_path == "C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe" and
        .restored.wrapper_path == "C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflow-client.ps1" and
        (.restored.binary_sha256 | test("^[0-9a-f]{64}$")) and (.restored.wrapper_sha256 | test("^[0-9a-f]{64}$")) and
        (.restored.task_xml_sha256 | test("^[0-9a-f]{64}$"))
    ' "$local_windows_rollback_receipt" >/dev/null || die 'Windows migration receipt is not the exact restored v1.3 baseline'
    old_viewflow_sha=$(jq -er '.installed_artifacts.viewflowd.sha256' "$linux_deactivation_proof")
    old_deskflow_sha=$(jq -er '.installed_artifacts.deskflow.sha256' "$linux_deactivation_proof")
    old_deskflow_core_sha=$(jq -er '.installed_artifacts.deskflow_core.sha256' "$linux_deactivation_proof")
    old_viewflow_unit_sha=$(jq -er '.installed_artifacts.viewflow_unit.sha256' "$linux_deactivation_proof")
    old_deskflow_dropin_sha=$(jq -er '.installed_artifacts.deskflow_dropin.sha256' "$linux_deactivation_proof")
    old_marker_cli_sha=$(jq -er '.installed_artifacts.deployment_marker_tool.sha256' "$linux_deactivation_proof")
    for value in "$old_viewflow_sha" "$old_deskflow_sha" "$old_deskflow_core_sha" "$old_viewflow_unit_sha" \
        "$old_deskflow_dropin_sha" "$old_marker_cli_sha"; do require_sha256 'restored Linux artifact' "$value"; done
    [[ $(sha256 "$VIEWFLOW_INSTALLED") == "$old_viewflow_sha" && $(sha256 "$DESKFLOW_INSTALLED") == "$old_deskflow_sha" &&
       $(sha256 "$DESKFLOW_CORE_INSTALLED") == "$old_deskflow_core_sha" && $(sha256 "$VIEWFLOW_UNIT_INSTALLED") == "$old_viewflow_unit_sha" &&
       $(sha256 "$DESKFLOW_DROPIN_INSTALLED") == "$old_deskflow_dropin_sha" && $(sha256 "$MARKER_CLI") == "$old_marker_cli_sha" ]] ||
        die 'restored Linux v1.3 artifact bytes changed'
}

select_failed_v13_abort_marker_tuple() {
    local original_sha current_sha authorized_op authorized_generation authorized_sha
    validate_publish_receipt "$deployment_publish_receipt" "$marker_generation" 0
    original_sha=$published_marker_sha
    current_sha=''
    [[ ! -e $DEPLOYMENT_MARKER ]] || current_sha=$(sha256 "$DEPLOYMENT_MARKER")
    if [[ $current_sha == "$original_sha" ]]; then
        abort_marker_operation_id=$operation_id
        abort_marker_generation=$marker_generation
        abort_marker_publish_receipt=$deployment_publish_receipt
        published_marker_sha=$original_sha
    elif [[ -n $recovery_deployment_publish_receipt && -f $recovery_deployment_publish_receipt && ! -L $recovery_deployment_publish_receipt ]]; then
        recovery_operation_id="${operation_id}_recovery"
        recovery_marker_generation=$(jq -er '.contract.identity.recovery_marker_generation' "$coordinator_state")
        require_owner_only_regular 'recovery marker publish receipt' "$recovery_deployment_publish_receipt"
        validate_publish_receipt "$recovery_deployment_publish_receipt" "$recovery_marker_generation" 0 "$recovery_operation_id"
        [[ -z $current_sha || $current_sha == "$published_marker_sha" ]] || die 'active marker differs from recovery publish receipt'
        abort_marker_operation_id=$recovery_operation_id
        abort_marker_generation=$recovery_marker_generation
        abort_marker_publish_receipt=$recovery_deployment_publish_receipt
    elif [[ -e $deployment_abort_authorization ]]; then
        authorized_op=$(jq -er '.operation_id' "$deployment_abort_authorization")
        authorized_generation=$(jq -er '.marker_generation' "$deployment_abort_authorization")
        authorized_sha=$(jq -er '.marker_sha256' "$deployment_abort_authorization")
        if [[ $authorized_op == "$operation_id" && $authorized_generation == "$marker_generation" && $authorized_sha == "$original_sha" ]]; then
            abort_marker_operation_id=$operation_id
            abort_marker_generation=$marker_generation
            abort_marker_publish_receipt=$deployment_publish_receipt
            published_marker_sha=$original_sha
        else
            recovery_operation_id="${operation_id}_recovery"
            recovery_marker_generation=$(jq -er '.contract.identity.recovery_marker_generation' "$coordinator_state")
            require_owner_only_regular 'recovery marker publish receipt' "$recovery_deployment_publish_receipt"
            validate_publish_receipt "$recovery_deployment_publish_receipt" "$recovery_marker_generation" 0 "$recovery_operation_id"
            [[ $authorized_op == "$recovery_operation_id" && $authorized_generation == "$recovery_marker_generation" &&
               $authorized_sha == "$published_marker_sha" ]] || die 'abort authorization does not select an exact active marker tuple'
            abort_marker_operation_id=$recovery_operation_id
            abort_marker_generation=$recovery_marker_generation
            abort_marker_publish_receipt=$recovery_deployment_publish_receipt
        fi
    else
        die 'no exact generation-1/generation-2 marker tuple is available for failed-v1.3 abort'
    fi
    [[ -z $current_sha ]] || assert_deployment_marker || die 'selected failed-v1.3 abort marker bytes differ'
}

assert_failed_v13_original_generation_only() {
    local state_release state_recovery_publish
    ((failed_v13_original_generation_only == 1)) ||
        die 'failed-v1.3 abort requires --failed-v13-original-generation-only'
    state_release=$(jq -er '.contract.outputs.release | select(type == "string" and startswith("/"))' "$coordinator_state")
    state_recovery_publish=$(jq -er '.contract.outputs.recovery_publish | select(type == "string" and startswith("/"))' "$coordinator_state")
    [[ $deployment_release_receipt == "$state_release" &&
       $recovery_deployment_publish_receipt == "$state_recovery_publish" ]] ||
        die 'original-generation-only sentinel paths differ from immutable old state'
    [[ ! -e $deployment_release_receipt && ! -L $deployment_release_receipt &&
       ! -e $recovery_deployment_publish_receipt && ! -L $recovery_deployment_publish_receipt ]] ||
        die 'original-generation-only abort refuses release or recovery-publication evidence'
    [[ $abort_marker_operation_id == "$operation_id" && $abort_marker_generation == "$marker_generation" &&
       $abort_marker_publish_receipt == "$deployment_publish_receipt" ]] ||
        die 'failed-v1.3 abort selected a recovery generation instead of original generation 1'
    if [[ ! -e $deployment_abort_authorization ]]; then
        [[ -f $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER && $(sha256 "$DEPLOYMENT_MARKER") == "$published_marker_sha" ]] ||
            die 'original generation-1 marker is not active before first authorization'
    fi
}

validate_fd_gate_contract() {
    [[ -f $FD_GATE_ENV && ! -L $FD_GATE_ENV &&
       $(stat -c '%u:%g:%a:%h' -- "$FD_GATE_ENV") == 0:0:755:1 &&
       $(sha256 "$FD_GATE_ENV") == "$FD_GATE_ENV_SHA256" ]] ||
        die 'root-owned clean-environment runtime identity differs'
    [[ -f $FD_GATE_PYTHON && ! -L $FD_GATE_PYTHON &&
       $(stat -c '%u:%g:%a:%h' -- "$FD_GATE_PYTHON") == 0:0:755:1 &&
       $(sha256 "$FD_GATE_PYTHON") == "$FD_GATE_PYTHON_SHA256" ]] ||
        die 'root-owned Python FD-gate runtime identity differs'
    [[ -f $FD_GATE_BWRAP && ! -L $FD_GATE_BWRAP &&
       $(stat -c '%u:%g:%a:%h' -- "$FD_GATE_BWRAP") == 0:0:755:1 &&
       $(sha256 "$FD_GATE_BWRAP") == "$FD_GATE_BWRAP_SHA256" ]] ||
        die 'root-owned Bubblewrap runtime identity differs'
    [[ $(printf '%s' "$FD_GATE_LOADER" | sha256sum | awk '{print $1}') == "$FD_GATE_LOADER_SHA256" &&
       $(printf '%s' "$FD_GATE_PAYLOAD" | sha256sum | awk '{print $1}') == "$FD_GATE_PAYLOAD_SHA256" &&
       $(printf '%s' "$FD_GATE_DESKFLOW_PAYLOAD" | sha256sum | awk '{print $1}') == "$FD_GATE_DESKFLOW_PAYLOAD_SHA256" ]] ||
        die 'FD-gate loader/payload code hash differs'
}

run_pinned_executable() {
    local role=$1 target=$2 expected_sha=$3
    shift 3
    validate_fd_gate_contract
    "$FD_GATE_ENV" -i HOME=/home/wilf PATH=/usr/bin:/bin \
        "$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_PAYLOAD_SHA256" "$FD_GATE_PAYLOAD" \
        "$target" "$expected_sha" 1000 0755 1 "$role" "$@"
}

canonical_fd_gate_exec_start_sha() {
    local role=$1 target=$2 expected_sha=$3 canonical
    shift 3
    if [[ $role == deskflow ]]; then
        canonical=$(jq -cnS --arg path "$FD_GATE_PYTHON" --args \
            '{argv:$ARGS.positional,ignore_errors:false,path:$path}' -- \
            "$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_DESKFLOW_PAYLOAD_SHA256" "$FD_GATE_DESKFLOW_PAYLOAD" \
            "$target" "$expected_sha" 1000 0755 1 "$role" "$FD_GATE_BWRAP" "$FD_GATE_BWRAP_SHA256" \
            "$DESKFLOW_CORE_INSTALLED" "$old_deskflow_core_sha" "$@")
    else
        canonical=$(jq -cnS --arg path "$FD_GATE_PYTHON" --args \
            '{argv:$ARGS.positional,ignore_errors:false,path:$path}' -- \
            "$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_PAYLOAD_SHA256" "$FD_GATE_PAYLOAD" \
            "$target" "$expected_sha" 1000 0755 1 "$role" "$@")
    fi
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

legacy_deskflow_v13_exec_start_sha() {
    local canonical
    canonical=$(jq -cnS --arg path "$FD_GATE_PYTHON" --args \
        '{argv:$ARGS.positional,ignore_errors:false,path:$path}' -- \
        "$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_PAYLOAD_SHA256" "$FD_GATE_PAYLOAD" \
        "$DESKFLOW_INSTALLED" "$old_deskflow_sha" 1000 0755 1 deskflow)
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

expected_viewflow_v13_exec_start_sha() {
    canonical_fd_gate_exec_start_sha viewflow "$VIEWFLOW_INSTALLED" "$old_viewflow_sha" \
        serve --bind 0.0.0.0:44119 \
        --cert /home/wilf/.local/share/viewflow/identity/peer.pem \
        --key /home/wilf/.local/share/viewflow/identity/peer.key \
        --ca /home/wilf/.local/share/viewflow/identity/ca.pem \
        --device-id 00000000000000000000000000000001 \
        --sidecar-socket /run/user/1000/viewflow/deskflow.sock \
        --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002
}

expected_deskflow_v13_exec_start_sha() {
    canonical_fd_gate_exec_start_sha deskflow "$DESKFLOW_INSTALLED" "$old_deskflow_sha"
}

observed_transient_exec_start_sha() {
    local unit=$1 object_response object_path property_response canonical
    object_response=$(busctl --user --json=short call org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetUnit s "$unit")
    object_path=$(printf '%s\n' "$object_response" | jq -er 'select(.type == "o" and (.data|length) == 1) | .data[0]')
    property_response=$(busctl --user --json=short get-property org.freedesktop.systemd1 \
        "$object_path" org.freedesktop.systemd1.Service ExecStart)
    canonical=$(jq -ceS '
        select(.type == "a(sasbttttuii)" and (.data|length) == 1) |
        .data[0] as $value |
        select(($value|length) == 10 and ($value[0]|type) == "string" and
               ($value[1]|type) == "array" and ($value[2]|type) == "boolean") |
        {argv:$value[1],ignore_errors:$value[2],path:$value[0]}
    ' < <(printf '%s\n' "$property_response"))
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

reset_failed_deskflow_recovery_unit() {
    local load_state active_state sub_state main_pid invocation observed deadline
    load_state=$(systemctl --user show --property LoadState --value "$v13_deskflow_unit" 2>/dev/null || true)
    [[ -z $load_state || $load_state == not-found ]] && return
    active_state=$(systemctl --user show --property ActiveState --value "$v13_deskflow_unit")
    sub_state=$(systemctl --user show --property SubState --value "$v13_deskflow_unit")
    main_pid=$(unit_main_pid "$v13_deskflow_unit")
    invocation=$(systemctl --user show --property InvocationID --value "$v13_deskflow_unit")
    observed=$(observed_transient_exec_start_sha "$v13_deskflow_unit")
    [[ $load_state == loaded && $active_state == failed && $sub_state == failed && $main_pid == 0 &&
       $invocation =~ ^[0-9a-f]{32}$ && $observed == "$(legacy_deskflow_v13_exec_start_sha)" &&
       -z $(systemctl --user show --property ControlGroup --value "$v13_deskflow_unit") ]] ||
        die 'pre-existing failed Deskflow recovery unit identity differs'
    journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
        grep -Fq 'FATAL: core server binary does not exist' ||
        die 'pre-existing failed Deskflow unit lacks the sealed-memfd sibling-path failure proof'
    [[ -z $(exact_executable_pids "$DESKFLOW_INSTALLED") && -z $(exact_executable_pids "$DESKFLOW_CORE_INSTALLED") ]] ||
        die 'failed Deskflow recovery unit still has an installed-path process'
    systemctl --user reset-failed "$v13_deskflow_unit"
    deadline=$((SECONDS + 10))
    while ((SECONDS < deadline)); do
        load_state=$(systemctl --user show --property LoadState --value "$v13_deskflow_unit" 2>/dev/null || true)
        [[ -z $load_state || $load_state == not-found ]] && return
        sleep 0.1
    done
    die 'failed Deskflow transient unit did not unload after reset-failed'
}

start_pinned_v13_transient_unit() {
    local kind=$1 unit=$2 target=$3 expected_sha=$4 load_state expected_exec_start_sha observed_exec_start_sha
    shift 4
    validate_fd_gate_contract
    load_state=$(systemctl --user show --property LoadState --value "$unit" 2>/dev/null || true)
    [[ -z $load_state || $load_state == not-found ]] || die "transient recovery unit is preoccupied: $unit"
    expected_exec_start_sha=$(canonical_fd_gate_exec_start_sha "$kind" "$target" "$expected_sha" "$@")
    if [[ $kind == viewflow ]]; then
        v13_viewflow_expected_exec_start_sha=$expected_exec_start_sha
        systemd-run --user --quiet --unit "$unit" --property Type=exec --property KillMode=control-group \
            --property Restart=no --property NoNewPrivileges=yes --property PrivateTmp=yes \
            --property RuntimeDirectory=viewflow --property RuntimeDirectoryMode=0700 \
            --setenv=LD_PRELOAD= --setenv=LD_AUDIT= --setenv=LD_LIBRARY_PATH= \
            "$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_PAYLOAD_SHA256" "$FD_GATE_PAYLOAD" \
            "$target" "$expected_sha" 1000 0755 1 viewflow "$@"
    elif [[ $kind == deskflow ]]; then
        v13_deskflow_expected_exec_start_sha=$expected_exec_start_sha
        systemd-run --user --quiet --unit "$unit" --property Type=exec --property KillMode=control-group \
            --property Restart=no \
            --setenv=LD_PRELOAD= --setenv=LD_AUDIT= --setenv=LD_LIBRARY_PATH= \
            --setenv=XDG_SESSION_TYPE=wayland --setenv=XDG_CURRENT_DESKTOP=Hyprland \
            --setenv=QT_QPA_PLATFORM=wayland --setenv=WAYLAND_DISPLAY=wayland-1 --setenv=DISPLAY=:1 \
            --setenv=DESKFLOW_MOUSE_ADJUSTMENT_WINDOWSVM=1.6 \
            --setenv=DESKFLOW_MOUSE_ADJUSTMENT_LINHAIKUODEMAC_MINI_LOCAL=1.1 \
            --setenv=DESKFLOW_VIEWFLOW_SIDECAR_SOCKET=/run/user/1000/viewflow/deskflow.sock \
            --setenv=DESKFLOW_VIEWFLOW_SCREEN=WindowsVM \
            --setenv=DESKFLOW_VIEWFLOW_SOURCE_DISPLAY=00000000000000000000000000000101 \
            --setenv=DESKFLOW_VIEWFLOW_ROUTE_TO=00000000000000000000000000000002 \
            "$FD_GATE_PYTHON" -I -E -c "$FD_GATE_LOADER" "$FD_GATE_DESKFLOW_PAYLOAD_SHA256" "$FD_GATE_DESKFLOW_PAYLOAD" \
            "$target" "$expected_sha" 1000 0755 1 deskflow "$FD_GATE_BWRAP" "$FD_GATE_BWRAP_SHA256" \
            "$DESKFLOW_CORE_INSTALLED" "$old_deskflow_core_sha" "$@"
    else
        die "unknown transient recovery kind: $kind"
    fi
    observed_exec_start_sha=$(observed_transient_exec_start_sha "$unit")
    [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||
        die "transient recovery unit ExecStart differs from fixed $kind gate argv"
}

start_and_freeze_linux_v13() {
    local temp=$secure_dir/linux-v13-started.json pid ticks invocation control_group process_cgroup deadline
    local expected_exec_start_sha observed_exec_start_sha load_state process_sha
    if [[ -e $linux_v13_started_receipt || -L $linux_v13_started_receipt ]]; then
        validate_linux_v13_started
        return
    fi
    load_state=$(systemctl --user show --property LoadState --value "$v13_viewflow_unit" 2>/dev/null || true)
    if [[ -z $load_state || $load_state == not-found ]]; then
        start_pinned_v13_transient_unit viewflow "$v13_viewflow_unit" "$VIEWFLOW_INSTALLED" "$old_viewflow_sha" \
            serve --bind 0.0.0.0:44119 \
            --cert /home/wilf/.local/share/viewflow/identity/peer.pem \
            --key /home/wilf/.local/share/viewflow/identity/peer.key \
            --ca /home/wilf/.local/share/viewflow/identity/ca.pem \
            --device-id 00000000000000000000000000000001 \
            --sidecar-socket /run/user/1000/viewflow/deskflow.sock \
            --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002
    else
        expected_exec_start_sha=$(expected_viewflow_v13_exec_start_sha)
        observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_viewflow_unit")
        [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||
            die 'pre-existing Linux v1.3 transient unit differs from fixed gate argv'
        v13_viewflow_expected_exec_start_sha=$expected_exec_start_sha
    fi
    deadline=$((SECONDS + 60)); pid=0
    while ((SECONDS < deadline)); do
        pid=$(unit_main_pid "$v13_viewflow_unit")
        process_sha=''
        if [[ $pid =~ ^[1-9][0-9]*$ ]] &&
           process_sha=$(sha256 "/proc/$pid/exe" 2>/dev/null) &&
           [[ $process_sha == "$old_viewflow_sha" ]]; then
            break
        fi
        pid=0
        sleep 0.1
    done
    [[ $pid =~ ^[1-9][0-9]*$ && $process_sha == "$old_viewflow_sha" ]] ||
        die 'restored Linux v1.3 Viewflow process identity is invalid'
    ticks=$(process_start_ticks "$pid")
    invocation=$(systemctl --user show --property InvocationID --value "$v13_viewflow_unit")
    control_group=$(systemctl --user show --property ControlGroup --value "$v13_viewflow_unit")
    expected_exec_start_sha=$v13_viewflow_expected_exec_start_sha
    observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_viewflow_unit")
    process_cgroup=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")
    [[ $invocation =~ ^[0-9a-f]{32}$ ]] || die 'restored Linux v1.3 invocation ID is invalid'
    [[ $expected_exec_start_sha == "$(expected_viewflow_v13_exec_start_sha)" &&
       $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||
        die 'restored Linux v1.3 manager ExecStart differs from fixed gate argv'
    [[ $control_group == "$process_cgroup" && $control_group == */"${v13_viewflow_unit}" ]] ||
        die 'restored Linux v1.3 transient cgroup identity is invalid'
    [[ $(systemctl --user show --property Transient --value "$v13_viewflow_unit") == yes &&
       $(systemctl --user show --property KillMode --value "$v13_viewflow_unit") == control-group ]] ||
        die 'restored Linux v1.3 unit is not the pinned transient control-group unit'
    journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
        grep -Fq 'viewflowd protocol 1.3 serving mTLS QUIC' || die 'restored Linux process has no v1.3 startup proof'
    jq -cn --arg op "$operation_id" --arg marker "$published_marker_sha" --arg sha "$old_viewflow_sha" \
        --arg invocation "$invocation" --arg unit "$v13_viewflow_unit" --arg cgroup "$control_group" \
        --arg expected_exec_start "$expected_exec_start_sha" --arg observed_exec_start "$observed_exec_start_sha" \
        --arg gate "$FD_GATE_PAYLOAD_SHA256" \
        --argjson pid "$pid" --argjson ticks "$ticks" '
        {schema_version:1,state:"viewflow-linux-v1.3-started-under-deployment-quarantine",operation_id:$op,
         protocol_version:"1.3",deployment_marker_sha256:$marker,viewflowd_sha256:$sha,
         unit:$unit,unit_active_state:"active",transient:true,kill_mode:"control-group",control_group:$cgroup,
         expected_exec_start_sha256:$expected_exec_start,exec_start_sha256:$observed_exec_start,
         fd_gate_payload_sha256:$gate,
         main_pid:$pid,start_ticks:$ticks,invocation_id:$invocation}
    ' >"$temp"
    publish_recovery_json_once 'Linux v1.3 started receipt' "$temp" "$linux_v13_started_receipt"
}

validate_linux_v13_started() {
    local pid ticks invocation control_group process_cgroup expected_exec_start_sha observed_exec_start_sha
    require_owner_only_regular 'Linux v1.3 started receipt' "$linux_v13_started_receipt"
    assert_strict_json_document 'Linux v1.3 started receipt' "$linux_v13_started_receipt"
    pid=$(unit_main_pid "$v13_viewflow_unit"); ticks=$(process_start_ticks "$pid")
    invocation=$(systemctl --user show --property InvocationID --value "$v13_viewflow_unit")
    control_group=$(systemctl --user show --property ControlGroup --value "$v13_viewflow_unit")
    expected_exec_start_sha=$(expected_viewflow_v13_exec_start_sha)
    observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_viewflow_unit")
    [[ $observed_exec_start_sha == "$expected_exec_start_sha" ]] ||
        die 'Linux v1.3 manager ExecStart differs from fixed gate argv during validation'
    process_cgroup=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")
    jq -e --arg op "$operation_id" --arg marker "$published_marker_sha" --arg sha "$old_viewflow_sha" \
        --arg invocation "$invocation" --arg unit "$v13_viewflow_unit" --arg cgroup "$control_group" \
        --arg expected_exec_start "$expected_exec_start_sha" --arg observed_exec_start "$observed_exec_start_sha" \
        --arg gate "$FD_GATE_PAYLOAD_SHA256" \
        --argjson pid "$pid" --argjson ticks "$ticks" '
        keys == ["control_group","deployment_marker_sha256","exec_start_sha256","expected_exec_start_sha256","fd_gate_payload_sha256","invocation_id","kill_mode","main_pid","operation_id","protocol_version","schema_version","start_ticks","state","transient","unit","unit_active_state","viewflowd_sha256"] and
        .schema_version == 1 and .state == "viewflow-linux-v1.3-started-under-deployment-quarantine" and
        .operation_id == $op and .protocol_version == "1.3" and .deployment_marker_sha256 == $marker and
        .viewflowd_sha256 == $sha and .unit == $unit and .unit_active_state == "active" and
        .transient == true and .kill_mode == "control-group" and .control_group == $cgroup and
        .expected_exec_start_sha256 == $expected_exec_start and
        .exec_start_sha256 == $observed_exec_start and .exec_start_sha256 == .expected_exec_start_sha256 and
        .fd_gate_payload_sha256 == $gate and
        .main_pid == $pid and .start_ticks == $ticks and .invocation_id == $invocation
    ' "$linux_v13_started_receipt" >/dev/null || die 'Linux v1.3 started receipt/live identity mismatch'
    [[ $control_group == "$process_cgroup" && $control_group == */"${v13_viewflow_unit}" &&
       $(systemctl --user show --property Transient --value "$v13_viewflow_unit") == yes &&
       $(systemctl --user show --property KillMode --value "$v13_viewflow_unit") == control-group &&
       $(sha256 "/proc/$pid/exe") == "$old_viewflow_sha" ]] || die 'Linux v1.3 live transient identity changed'
    # A receipt must never weaken the receipt-less adoption boundary.  Re-run
    # the exact single-runtime/listener/persistent-unit checks after binding
    # the receipt to the live transient tuple.
    assert_adoptable_linux_v13_without_receipt
}

start_and_freeze_windows_v13() {
    local temp=$secure_dir/windows-v13-started.json command
    local binary wrapper task
    if [[ -e $windows_v13_started_receipt || -L $windows_v13_started_receipt ]]; then
        validate_windows_v13_started
        return
    fi
    binary=$(jq -er '.restored.binary_sha256' "$local_windows_rollback_receipt")
    wrapper=$(jq -er '.restored.wrapper_sha256' "$local_windows_rollback_receipt")
    task=$(jq -er '.restored.task_xml_sha256' "$local_windows_rollback_receipt")
    command="\$ErrorActionPreference='Stop';function HB([byte[]]\$b){\$s=[Security.Cryptography.SHA256]::Create();try{(([BitConverter]::ToString(\$s.ComputeHash(\$b))).Replace('-','')).ToLowerInvariant()}finally{\$s.Dispose()}};if((HB ([IO.File]::ReadAllBytes('C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflow-client.ps1')))-cne'$wrapper'){throw 'old wrapper hash differs'};\$task=Get-ScheduledTask -TaskPath '\\' -TaskName 'Viewflow Peer' -ErrorAction Stop;\$xml=Export-ScheduledTask -TaskPath '\\' -TaskName 'Viewflow Peer';\$enc=New-Object Text.UnicodeEncoding(\$false,\$true);\$pre=\$enc.GetPreamble();\$body=\$enc.GetBytes(\$xml);\$xmlBytes=New-Object byte[] (\$pre.Length+\$body.Length);[Array]::Copy(\$pre,0,\$xmlBytes,0,\$pre.Length);[Array]::Copy(\$body,0,\$xmlBytes,\$pre.Length,\$body.Length);if((HB \$xmlBytes)-cne'$task'){throw 'old task XML hash differs'};if([string]\$task.State-cne'Running'){Start-ScheduledTask -TaskPath '\\' -TaskName 'Viewflow Peer'};\$deadline=[DateTime]::UtcNow.AddSeconds(60);do{Start-Sleep -Milliseconds 200;\$rows=@(Get-CimInstance Win32_Process -Filter \"Name='viewflowd.exe'\"|Where-Object{\$_.ExecutablePath -and [IO.Path]::GetFullPath(\$_.ExecutablePath)-ceq'C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe' -and (HB ([IO.File]::ReadAllBytes(\$_.ExecutablePath)))-ceq'$binary'})}while(\$rows.Count-ne1-and[DateTime]::UtcNow-lt\$deadline);if(\$rows.Count-ne1){throw 'exact old viewflow process not found'};\$p=\$rows[0];\$sid=(Invoke-CimMethod -InputObject \$p -MethodName GetOwnerSid).Sid;if(\$sid-cne'$windows_user_sid'-or[int]\$p.SessionId-ne1){throw 'old process owner/session differs'};\$result=[ordered]@{schema_version=1;state='viewflow-windows-v1.3-started-under-deployment-quarantine';operation_id='$operation_id';protocol_version='1.3';deployment_marker_sha256='$published_marker_sha';task_name='\\Viewflow Peer';task_state=[string](Get-ScheduledTask -TaskPath '\\' -TaskName 'Viewflow Peer').State;task_xml_sha256='$task';viewflowd_sha256='$binary';wrapper_sha256='$wrapper';pid=[int]\$p.ProcessId;process_start_filetime_utc=[string](\$p.CreationDate.ToFileTimeUtc());session_id=[int]\$p.SessionId;user_sid=[string]\$sid};\$result|ConvertTo-Json -Compress"
    capture_json_command 'Windows v1.3 started receipt candidate' "$temp" ssh_windows "$command"
    publish_recovery_json_once 'Windows v1.3 started receipt' "$temp" "$windows_v13_started_receipt"
}

validate_windows_v13_started() {
    local binary wrapper task command live
    windows_v13_live_reattest_counter=$((${windows_v13_live_reattest_counter:-0} + 1))
    live=$secure_dir/windows-v13-live.${windows_v13_live_reattest_counter}.json
    binary=$(jq -er '.restored.binary_sha256' "$local_windows_rollback_receipt")
    wrapper=$(jq -er '.restored.wrapper_sha256' "$local_windows_rollback_receipt")
    task=$(jq -er '.restored.task_xml_sha256' "$local_windows_rollback_receipt")
    require_owner_only_regular 'Windows v1.3 started receipt' "$windows_v13_started_receipt"
    assert_strict_json_document 'Windows v1.3 started receipt' "$windows_v13_started_receipt"
    jq -e --arg op "$operation_id" --arg marker "$published_marker_sha" --arg binary "$binary" \
        --arg wrapper "$wrapper" --arg task "$task" --arg sid "$windows_user_sid" '
        keys == ["deployment_marker_sha256","operation_id","pid","process_start_filetime_utc","protocol_version","schema_version","session_id","state","task_name","task_state","task_xml_sha256","user_sid","viewflowd_sha256","wrapper_sha256"] and
        .schema_version == 1 and .state == "viewflow-windows-v1.3-started-under-deployment-quarantine" and
        .operation_id == $op and .protocol_version == "1.3" and .deployment_marker_sha256 == $marker and
        .task_name == "\\Viewflow Peer" and .task_state == "Running" and .task_xml_sha256 == $task and
        .viewflowd_sha256 == $binary and .wrapper_sha256 == $wrapper and .user_sid == $sid and
        (.session_id | type == "number" and . == floor and . == 1) and
        (.pid | type == "number" and . == floor and . >= 1 and . <= 4294967295) and
        (.process_start_filetime_utc | test("^[1-9][0-9]{16,18}$"))
    ' "$windows_v13_started_receipt" >/dev/null || die 'Windows v1.3 started receipt is invalid'
    validate_windows_identity_scalar "$windows_v13_started_receipt" pid positive-uint32
    validate_windows_identity_scalar "$windows_v13_started_receipt" session_id session-one
    validate_windows_identity_scalar "$windows_v13_started_receipt" process_start_filetime_utc canonical-filetime
    command="\$ErrorActionPreference='Stop';function HB([byte[]]\$b){\$s=[Security.Cryptography.SHA256]::Create();try{(([BitConverter]::ToString(\$s.ComputeHash(\$b))).Replace('-','')).ToLowerInvariant()}finally{\$s.Dispose()}};\$wrapperSha=HB ([IO.File]::ReadAllBytes('C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflow-client.ps1'));if(\$wrapperSha-cne'$wrapper'){throw 'live old wrapper hash differs'};\$task=Get-ScheduledTask -TaskPath '\\' -TaskName 'Viewflow Peer' -ErrorAction Stop;if([string]\$task.State-cne'Running'){throw 'live old task is not Running'};\$xml=Export-ScheduledTask -TaskPath '\\' -TaskName 'Viewflow Peer';\$enc=New-Object Text.UnicodeEncoding(\$false,\$true);\$pre=\$enc.GetPreamble();\$body=\$enc.GetBytes(\$xml);\$xmlBytes=New-Object byte[] (\$pre.Length+\$body.Length);[Array]::Copy(\$pre,0,\$xmlBytes,0,\$pre.Length);[Array]::Copy(\$body,0,\$xmlBytes,\$pre.Length,\$body.Length);\$taskSha=HB \$xmlBytes;if(\$taskSha-cne'$task'){throw 'live old task XML hash differs'};\$rows=@(Get-CimInstance Win32_Process -Filter \"Name='viewflowd.exe'\"|Where-Object{\$_.ExecutablePath -and [IO.Path]::GetFullPath(\$_.ExecutablePath)-ceq'C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe' -and (HB ([IO.File]::ReadAllBytes(\$_.ExecutablePath)))-ceq'$binary'});if(\$rows.Count-ne1){throw 'live exact old viewflow process count differs'};\$p=\$rows[0];\$sid=(Invoke-CimMethod -InputObject \$p -MethodName GetOwnerSid).Sid;if(\$sid-cne'$windows_user_sid'-or[int]\$p.SessionId-ne1){throw 'live old process owner/session differs'};[ordered]@{task_state=[string]\$task.State;task_xml_sha256=\$taskSha;viewflowd_sha256='$binary';wrapper_sha256=\$wrapperSha;pid=[int]\$p.ProcessId;process_start_filetime_utc=[string](\$p.CreationDate.ToFileTimeUtc());session_id=[int]\$p.SessionId;user_sid=[string]\$sid}|ConvertTo-Json -Compress"
    capture_json_command 'Windows v1.3 live reattestation' "$live" ssh_windows "$command"
    assert_strict_json_document 'Windows v1.3 live reattestation' "$live"
    validate_windows_identity_scalar "$live" pid positive-uint32
    validate_windows_identity_scalar "$live" session_id session-one
    validate_windows_identity_scalar "$live" process_start_filetime_utc canonical-filetime
    jq -e --slurpfile receipt "$windows_v13_started_receipt" '
        keys == ["pid","process_start_filetime_utc","session_id","task_state","task_xml_sha256","user_sid","viewflowd_sha256","wrapper_sha256"] and
        .task_state == $receipt[0].task_state and .task_xml_sha256 == $receipt[0].task_xml_sha256 and
        .viewflowd_sha256 == $receipt[0].viewflowd_sha256 and .wrapper_sha256 == $receipt[0].wrapper_sha256 and
        .pid == $receipt[0].pid and .process_start_filetime_utc == $receipt[0].process_start_filetime_utc and
        .session_id == $receipt[0].session_id and .user_sid == $receipt[0].user_sid
    ' "$live" >/dev/null || die 'Windows v1.3 receipt no longer matches live task/process identity'
}

journal_record_sha_exists() {
    local invocation=$1 needle=$2 expected=$3 line
    while IFS= read -r line; do
        [[ $(printf '%s' "$line" | sha256sum | awk '{print $1}') == "$expected" ]] && return 0
    done < <(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" | grep -F "$needle" || true)
    return 1
}

freeze_authenticated_v13_peer() {
    local temp=$secure_dir/authenticated-v13-peer.json invocation deadline authenticated_line authenticated_sha
    local peer_endpoint peer_port baseline_probe fresh_probe fresh_probe_sha
    invocation=$(jq -er '.invocation_id' "$linux_v13_started_receipt")
    authenticated_line=$(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
        grep -F "viewflowd server authenticated peer ${EXPECTED_WINDOWS_SOURCE_IP}:" | tail -n1 || true)
    [[ -n $authenticated_line ]] || die 'no authenticated v1.3 Windows peer observation'
    peer_endpoint=${authenticated_line##*authenticated peer }
    [[ $peer_endpoint == "${EXPECTED_WINDOWS_SOURCE_IP}:"* ]] || die 'authenticated v1.3 Windows source IP differs'
    peer_port=${peer_endpoint##*:}
    [[ $peer_port =~ ^[1-9][0-9]*$ && $peer_port -le 65535 ]] || die 'authenticated v1.3 Windows source port is invalid'
    baseline_probe=$(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
        grep -F "viewflowd server peer ${peer_endpoint} probe=" | tail -n1 || true)
    deadline=$((SECONDS + 60)); fresh_probe=''
    while ((SECONDS < deadline)); do
        fresh_probe=$(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
            grep -F "viewflowd server peer ${peer_endpoint} probe=" | tail -n1 || true)
        [[ -n $fresh_probe && $fresh_probe != "$baseline_probe" ]] && break
        fresh_probe=''
        sleep 0.2
    done
    [[ -n $fresh_probe ]] || die 'no fresh authenticated v1.3 Windows peer probe'
    authenticated_sha=$(printf '%s' "$authenticated_line" | sha256sum | awk '{print $1}')
    fresh_probe_sha=$(printf '%s' "$fresh_probe" | sha256sum | awk '{print $1}')
    current_v13_peer_probe_sha=$fresh_probe_sha
    if [[ -e $authenticated_v13_peer_receipt || -L $authenticated_v13_peer_receipt ]]; then
        validate_authenticated_v13_peer
        return
    fi
    jq -cn --arg op "$operation_id" --arg marker "$published_marker_sha" --arg invocation "$invocation" \
        --arg linux "$(sha256 "$linux_v13_started_receipt")" --arg windows "$(sha256 "$windows_v13_started_receipt")" \
        --arg ip "$EXPECTED_WINDOWS_SOURCE_IP" --argjson port "$peer_port" \
        --arg authenticated "$authenticated_sha" --arg probe "$fresh_probe_sha" '
        {schema_version:1,state:"viewflow-v1.3-peer-authenticated-under-deployment-quarantine",operation_id:$op,
         protocol_version:"1.3",protocol_2_1:false,deployment_marker_sha256:$marker,
         linux_v13_started_receipt_sha256:$linux,windows_v13_started_receipt_sha256:$windows,
         linux_invocation_id:$invocation,authenticated_peer_ip:$ip,authenticated_peer_port:$port,
         authenticated_peer_record_sha256:$authenticated,fresh_probe_record_sha256:$probe}
    ' >"$temp"
    publish_recovery_json_once 'authenticated v1.3 peer receipt' "$temp" "$authenticated_v13_peer_receipt"
}

validate_authenticated_v13_peer() {
    local invocation peer_ip peer_port authenticated_sha probe_sha
    require_owner_only_regular 'authenticated v1.3 peer receipt' "$authenticated_v13_peer_receipt"
    assert_strict_json_document 'authenticated v1.3 peer receipt' "$authenticated_v13_peer_receipt"
    jq -e --arg op "$operation_id" --arg marker "$published_marker_sha" \
        --arg linux "$(sha256 "$linux_v13_started_receipt")" --arg windows "$(sha256 "$windows_v13_started_receipt")" \
        --arg invocation "$(jq -er '.invocation_id' "$linux_v13_started_receipt")" '
        keys == ["authenticated_peer_ip","authenticated_peer_port","authenticated_peer_record_sha256","deployment_marker_sha256","fresh_probe_record_sha256","linux_invocation_id","linux_v13_started_receipt_sha256","operation_id","protocol_2_1","protocol_version","schema_version","state","windows_v13_started_receipt_sha256"] and
        .schema_version == 1 and .state == "viewflow-v1.3-peer-authenticated-under-deployment-quarantine" and
        .operation_id == $op and .protocol_version == "1.3" and .protocol_2_1 == false and
        .deployment_marker_sha256 == $marker and .linux_v13_started_receipt_sha256 == $linux and
        .windows_v13_started_receipt_sha256 == $windows and .linux_invocation_id == $invocation and
        .authenticated_peer_ip == "172.16.105.70" and
        (.authenticated_peer_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
        (.authenticated_peer_record_sha256 | test("^[0-9a-f]{64}$")) and
        (.fresh_probe_record_sha256 | test("^[0-9a-f]{64}$"))
    ' "$authenticated_v13_peer_receipt" >/dev/null || die 'authenticated v1.3 peer receipt is invalid'
    invocation=$(jq -er '.linux_invocation_id' "$authenticated_v13_peer_receipt")
    peer_ip=$(jq -er '.authenticated_peer_ip' "$authenticated_v13_peer_receipt")
    peer_port=$(jq -er '.authenticated_peer_port' "$authenticated_v13_peer_receipt")
    authenticated_sha=$(jq -er '.authenticated_peer_record_sha256' "$authenticated_v13_peer_receipt")
    probe_sha=$(jq -er '.fresh_probe_record_sha256' "$authenticated_v13_peer_receipt")
    journal_record_sha_exists "$invocation" "viewflowd server authenticated peer ${peer_ip}:${peer_port}" "$authenticated_sha" ||
        die 'authenticated v1.3 peer journal record disappeared'
    journal_record_sha_exists "$invocation" "viewflowd server peer ${peer_ip}:${peer_port} probe=" "$probe_sha" ||
        die 'fresh v1.3 peer probe journal record disappeared'
}

freeze_pre_mutation_windows_v13() {
    local temp=$secure_dir/pre-mutation-windows-v13-started.json
    capture_pre_mutation_windows_live_proof
    if [[ ! -e $windows_v13_started_receipt && ! -L $windows_v13_started_receipt ]]; then
        jq -cn --arg op "$operation_id" --arg marker "$published_marker_sha" \
            --arg live "$(sha256 "$pre_mutation_windows_live_proof")" \
            --arg binary "$pre_mutation_old_windows_binary_sha" --arg wrapper "$pre_mutation_old_windows_wrapper_sha" \
            --arg task "$pre_mutation_old_windows_task_sha" --arg sid "$windows_user_sid" \
            --argjson pid "$pre_mutation_old_process_id" --argjson parent "$pre_mutation_old_parent_process_id" \
            --arg creation "$pre_mutation_old_process_creation_date" '
            {schema_version:2,state:"viewflow-windows-v1.3-current-baseline-verified-under-deployment-quarantine",
             operation_id:$op,protocol_version:"1.3",protocol_2_1:false,deployment_marker_sha256:$marker,
             windows_live_proof_sha256:$live,viewflowd_sha256:$binary,wrapper_sha256:$wrapper,
             task_xml_sha256:$task,pid:$pid,parent_pid:$parent,creation_date:$creation,session_id:1,user_sid:$sid,
             task_name:"\\Viewflow Peer",task_state:"Running",initial_force_release_executed:false,
             rollback_performed:false,windows_rollback_receipt_sha256:null}
        ' >"$temp"
        publish_json_file 'pre-mutation Windows v1.3 current-baseline receipt' "$temp" "$windows_v13_started_receipt"
    fi
    validate_pre_mutation_windows_v13_started
}

validate_pre_mutation_windows_v13_started() {
    require_owner_only_regular 'pre-mutation Windows v1.3 current-baseline receipt' "$windows_v13_started_receipt"
    assert_strict_json_document 'pre-mutation Windows v1.3 current-baseline receipt' "$windows_v13_started_receipt"
    jq -e --arg op "$operation_id" --arg marker "$published_marker_sha" \
        --arg live "$(sha256 "$pre_mutation_windows_live_proof")" \
        --arg binary "$pre_mutation_old_windows_binary_sha" --arg wrapper "$pre_mutation_old_windows_wrapper_sha" \
        --arg task "$pre_mutation_old_windows_task_sha" --arg sid "$windows_user_sid" \
        --argjson pid "$pre_mutation_old_process_id" --argjson parent "$pre_mutation_old_parent_process_id" \
        --arg creation "$pre_mutation_old_process_creation_date" '
        keys == ["creation_date","deployment_marker_sha256","initial_force_release_executed","operation_id","parent_pid","pid","protocol_2_1","protocol_version","rollback_performed","schema_version","session_id","state","task_name","task_state","task_xml_sha256","user_sid","viewflowd_sha256","windows_live_proof_sha256","windows_rollback_receipt_sha256","wrapper_sha256"] and
        .schema_version == 2 and .state == "viewflow-windows-v1.3-current-baseline-verified-under-deployment-quarantine" and
        .operation_id == $op and .protocol_version == "1.3" and .protocol_2_1 == false and
        .deployment_marker_sha256 == $marker and .windows_live_proof_sha256 == $live and
        .viewflowd_sha256 == $binary and .wrapper_sha256 == $wrapper and .task_xml_sha256 == $task and
        (.pid | type == "number" and . == floor and . >= 1 and . <= 4294967295) and .pid == $pid and
        (.parent_pid | type == "number" and . == floor and . >= 1 and . <= 4294967295) and .parent_pid == $parent and
        .creation_date == $creation and
        (.session_id | type == "number" and . == floor and . == 1) and .user_sid == $sid and .task_name == "\\Viewflow Peer" and .task_state == "Running" and
        .initial_force_release_executed == false and .rollback_performed == false and
        .windows_rollback_receipt_sha256 == null
    ' "$windows_v13_started_receipt" >/dev/null || die 'pre-mutation Windows v1.3 current-baseline receipt is invalid'
    validate_windows_identity_scalar "$windows_v13_started_receipt" pid positive-uint32
    validate_windows_identity_scalar "$windows_v13_started_receipt" parent_pid positive-uint32
    validate_windows_identity_scalar "$windows_v13_started_receipt" session_id session-one
    capture_pre_mutation_windows_live_proof
}

make_and_validate_pre_mutation_abort_authorization() {
    local temp=$secure_dir/pre-mutation-abort-authorization.json
    [[ $current_v13_peer_probe_sha =~ ^[0-9a-f]{64}$ ]] ||
        die 'pre-mutation abort lacks a fresh authenticated v1.3 peer probe'
    if [[ ! -e $deployment_abort_authorization && ! -L $deployment_abort_authorization ]]; then
        jq -cn --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
            --arg generation "$marker_generation" --arg marker "$published_marker_sha" \
            --arg authorization "$deployment_abort_authorization" \
            --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$deployment_publish_receipt")" \
            --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg exit "$(sha256 "$windows_installer_exit_receipt")" \
            --arg stop "$(sha256 "$local_windows_stop_evidence")" --arg retry "$(sha256 "$pre_mutation_retry_proof")" \
            --arg live "$(sha256 "$pre_mutation_windows_live_proof")" \
            --arg linux "$old_viewflow_sha" --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
            --arg windows "$pre_mutation_old_windows_binary_sha" --arg wrapper "$pre_mutation_old_windows_wrapper_sha" \
            --arg task "$pre_mutation_old_windows_task_sha" --arg old_rollback "$pre_mutation_old_windows_rollback_sha" \
            --arg linux_started "$(sha256 "$linux_v13_started_receipt")" \
            --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
            --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
            {schema_version:2,state:"viewflow-deployment-quarantine-failed-pre-mutation-installer-baseline-restored-abort-authorized",
             operation_id:$op,coordinator_instance_id:$coordinator,marker_generation:$generation,marker_sha256:$marker,
             authorization_receipt_path:$authorization,marker_handoff_receipt_sha256:$handoff,
             deployment_publish_receipt_sha256:$publish,linux_frozen_evidence_sha256:$frozen,
             installer_exit_receipt_sha256:$exit,windows_stop_evidence_sha256:$stop,
             pre_mutation_retry_receipt_sha256:$retry,windows_live_proof_sha256:$live,
             old_linux_viewflowd_sha256:$linux,old_linux_deskflow_sha256:$deskflow,
             old_linux_deskflow_core_sha256:$core,old_windows_viewflowd_sha256:$windows,
             old_windows_wrapper_sha256:$wrapper,old_windows_task_xml_sha256:$task,
             old_windows_rollback_sha256:$old_rollback,
             linux_v13_started_receipt_sha256:$linux_started,windows_v13_started_receipt_sha256:$windows_started,
             authenticated_v13_peer_receipt_sha256:$authenticated,initial_force_release_executed:false,
             rollback_performed:false,windows_rollback_receipt_sha256:null,protocol_2_1:false}
        ' >"$temp"
        publish_json_file 'pre-mutation failed-v1.3 abort authorization' "$temp" "$deployment_abort_authorization"
    fi
    require_owner_only_regular 'pre-mutation failed-v1.3 abort authorization' "$deployment_abort_authorization"
    assert_strict_json_document 'pre-mutation failed-v1.3 abort authorization' "$deployment_abort_authorization"
    jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$marker_generation" --arg marker "$published_marker_sha" \
        --arg authorization "$deployment_abort_authorization" \
        --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$deployment_publish_receipt")" \
        --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg exit "$(sha256 "$windows_installer_exit_receipt")" \
        --arg stop "$(sha256 "$local_windows_stop_evidence")" --arg retry "$(sha256 "$pre_mutation_retry_proof")" \
        --arg live "$(sha256 "$pre_mutation_windows_live_proof")" --arg linux "$old_viewflow_sha" \
        --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
        --arg windows "$pre_mutation_old_windows_binary_sha" --arg wrapper "$pre_mutation_old_windows_wrapper_sha" \
        --arg task "$pre_mutation_old_windows_task_sha" --arg old_rollback "$pre_mutation_old_windows_rollback_sha" \
        --arg linux_started "$(sha256 "$linux_v13_started_receipt")" \
        --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
        --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
        keys == ["authenticated_v13_peer_receipt_sha256","authorization_receipt_path","coordinator_instance_id","deployment_publish_receipt_sha256","initial_force_release_executed","installer_exit_receipt_sha256","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_generation","marker_handoff_receipt_sha256","marker_sha256","old_linux_deskflow_core_sha256","old_linux_deskflow_sha256","old_linux_viewflowd_sha256","old_windows_rollback_sha256","old_windows_task_xml_sha256","old_windows_viewflowd_sha256","old_windows_wrapper_sha256","operation_id","pre_mutation_retry_receipt_sha256","protocol_2_1","rollback_performed","schema_version","state","windows_live_proof_sha256","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
        .schema_version == 2 and .state == "viewflow-deployment-quarantine-failed-pre-mutation-installer-baseline-restored-abort-authorized" and
        .operation_id == $op and .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .marker_sha256 == $marker and .authorization_receipt_path == $authorization and
        .marker_handoff_receipt_sha256 == $handoff and .deployment_publish_receipt_sha256 == $publish and
        .linux_frozen_evidence_sha256 == $frozen and .installer_exit_receipt_sha256 == $exit and
        .windows_stop_evidence_sha256 == $stop and .pre_mutation_retry_receipt_sha256 == $retry and
        .windows_live_proof_sha256 == $live and .old_linux_viewflowd_sha256 == $linux and
        .old_linux_deskflow_sha256 == $deskflow and .old_linux_deskflow_core_sha256 == $core and
        .old_windows_viewflowd_sha256 == $windows and .old_windows_wrapper_sha256 == $wrapper and
        .old_windows_task_xml_sha256 == $task and .old_windows_rollback_sha256 == $old_rollback and
        .linux_v13_started_receipt_sha256 == $linux_started and
        .windows_v13_started_receipt_sha256 == $windows_started and
        .authenticated_v13_peer_receipt_sha256 == $authenticated and
        .initial_force_release_executed == false and .rollback_performed == false and
        .windows_rollback_receipt_sha256 == null and .protocol_2_1 == false
    ' "$deployment_abort_authorization" >/dev/null || die 'pre-mutation abort authorization schema/binding is invalid'
}

make_and_validate_post_permit_rollback_abort_authorization() {
    local temp=$secure_dir/post-permit-rollback-abort-authorization.json
    local windows_binary windows_wrapper
    windows_binary=$(jq -er '.restored.binary_sha256' "$local_windows_rollback_receipt")
    windows_wrapper=$(jq -er '.restored.wrapper_sha256' "$local_windows_rollback_receipt")
    [[ $current_v13_peer_probe_sha =~ ^[0-9a-f]{64}$ ]] ||
        die 'post-permit rollback abort lacks a fresh v1.3 peer probe'
    if [[ ! -e $deployment_abort_authorization && ! -L $deployment_abort_authorization ]]; then
        jq -cn --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" \
            --arg generation "$abort_marker_generation" --arg marker "$published_marker_sha" \
            --arg authorization "$deployment_abort_authorization" --arg state "$(sha256 "$coordinator_state")" \
            --arg lineage "$(sha256 "$schema1_handoff_lineage_receipt")" \
            --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$abort_marker_publish_receipt")" \
            --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
            --arg prepared "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
            --arg exit "$(sha256 "$windows_installer_exit_receipt")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
            --arg recovery "$(sha256 "$local_recovery_bundle")" --arg proof "$(sha256 "$linux_deactivation_proof")" \
            --arg transcript "$(sha256 "$linux_deactivation_transcript")" \
            --arg rollback "$(sha256 "$local_windows_rollback_receipt")" --arg linux "$old_viewflow_sha" \
            --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
            --arg windows "$windows_binary" --arg wrapper "$windows_wrapper" \
            --arg linux_started "$(sha256 "$linux_v13_started_receipt")" \
            --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
            --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
            {schema_version:5,state:"viewflow-deployment-quarantine-post-permit-rollback-abort-authorized",
             operation_id:$op,coordinator_instance_id:$coordinator,marker_generation:$generation,marker_sha256:$marker,
             authorization_receipt_path:$authorization,coordinator_terminal_state_sha256:$state,
             coordinator_failure_phase:"MUTATION_PERMITTED",coordinator_mutation_possible:true,
             schema1_handoff_lineage_receipt_sha256:$lineage,marker_handoff_receipt_sha256:$handoff,
             deployment_publish_receipt_sha256:$publish,linux_frozen_evidence_sha256:$frozen,
             bootstrap_request_sha256:$request,windows_prepared_receipt_sha256:$prepared,
             mutation_permit_receipt_sha256:$permit,installer_exit_receipt_sha256:$exit,
             windows_stop_evidence_sha256:$stop,recovery_bundle_sha256:$recovery,
             linux_deactivation_proof_sha256:$proof,linux_deactivation_transcript_sha256:$transcript,
             windows_rollback_receipt_sha256:$rollback,old_linux_viewflowd_sha256:$linux,
             old_linux_deskflow_sha256:$deskflow,old_linux_deskflow_core_sha256:$core,
             old_windows_viewflowd_sha256:$windows,old_windows_wrapper_sha256:$wrapper,
             linux_v13_started_receipt_sha256:$linux_started,windows_v13_started_receipt_sha256:$windows_started,
             authenticated_v13_peer_receipt_sha256:$authenticated,mutation_permit_published:true,
             force_release_executed:false,rollback_performed:true,initial_force_release_executed:false,
             second_force_release_executed:false,rollback_token_consumed:true,protocol_2_1:false}
        ' >"$temp"
        publish_json_file 'post-permit rollback abort authorization' "$temp" "$deployment_abort_authorization"
    fi
    require_owner_only_regular 'post-permit rollback abort authorization' "$deployment_abort_authorization"
    assert_strict_json_document 'post-permit rollback abort authorization' "$deployment_abort_authorization"
    jq -e --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$abort_marker_generation" --arg marker "$published_marker_sha" \
        --arg authorization "$deployment_abort_authorization" --arg state "$(sha256 "$coordinator_state")" \
        --arg lineage "$(sha256 "$schema1_handoff_lineage_receipt")" \
        --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$abort_marker_publish_receipt")" \
        --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
        --arg prepared "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
        --arg exit "$(sha256 "$windows_installer_exit_receipt")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
        --arg recovery "$(sha256 "$local_recovery_bundle")" --arg proof "$(sha256 "$linux_deactivation_proof")" \
        --arg transcript "$(sha256 "$linux_deactivation_transcript")" \
        --arg rollback "$(sha256 "$local_windows_rollback_receipt")" --arg linux "$old_viewflow_sha" \
        --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
        --arg windows "$(jq -er '.restored.binary_sha256' "$local_windows_rollback_receipt")" \
        --arg wrapper "$(jq -er '.restored.wrapper_sha256' "$local_windows_rollback_receipt")" \
        --arg linux_started "$(sha256 "$linux_v13_started_receipt")" \
        --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
        --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
        keys == ["authenticated_v13_peer_receipt_sha256","authorization_receipt_path","bootstrap_request_sha256","coordinator_failure_phase","coordinator_instance_id","coordinator_mutation_possible","coordinator_terminal_state_sha256","deployment_publish_receipt_sha256","force_release_executed","initial_force_release_executed","installer_exit_receipt_sha256","linux_deactivation_proof_sha256","linux_deactivation_transcript_sha256","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_generation","marker_handoff_receipt_sha256","marker_sha256","mutation_permit_published","mutation_permit_receipt_sha256","old_linux_deskflow_core_sha256","old_linux_deskflow_sha256","old_linux_viewflowd_sha256","old_windows_viewflowd_sha256","old_windows_wrapper_sha256","operation_id","protocol_2_1","recovery_bundle_sha256","rollback_performed","rollback_token_consumed","schema1_handoff_lineage_receipt_sha256","schema_version","second_force_release_executed","state","windows_prepared_receipt_sha256","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
        .schema_version == 5 and .state == "viewflow-deployment-quarantine-post-permit-rollback-abort-authorized" and
        .operation_id == $op and .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .marker_sha256 == $marker and .authorization_receipt_path == $authorization and
        .coordinator_terminal_state_sha256 == $state and .coordinator_failure_phase == "MUTATION_PERMITTED" and
        .coordinator_mutation_possible == true and .schema1_handoff_lineage_receipt_sha256 == $lineage and
        .marker_handoff_receipt_sha256 == $handoff and .deployment_publish_receipt_sha256 == $publish and
        .linux_frozen_evidence_sha256 == $frozen and .bootstrap_request_sha256 == $request and
        .windows_prepared_receipt_sha256 == $prepared and .mutation_permit_receipt_sha256 == $permit and
        .installer_exit_receipt_sha256 == $exit and .windows_stop_evidence_sha256 == $stop and
        .recovery_bundle_sha256 == $recovery and .linux_deactivation_proof_sha256 == $proof and
        .linux_deactivation_transcript_sha256 == $transcript and .windows_rollback_receipt_sha256 == $rollback and
        .old_linux_viewflowd_sha256 == $linux and .old_linux_deskflow_sha256 == $deskflow and
        .old_linux_deskflow_core_sha256 == $core and .old_windows_viewflowd_sha256 == $windows and
        .old_windows_wrapper_sha256 == $wrapper and .linux_v13_started_receipt_sha256 == $linux_started and
        .windows_v13_started_receipt_sha256 == $windows_started and
        .authenticated_v13_peer_receipt_sha256 == $authenticated and
        .mutation_permit_published == true and .force_release_executed == false and .rollback_performed == true and
        .initial_force_release_executed == false and .second_force_release_executed == false and
        .rollback_token_consumed == true and .protocol_2_1 == false
    ' "$deployment_abort_authorization" >/dev/null || die 'post-permit rollback abort authorization schema/binding is invalid'
}

make_and_validate_post_force_rollback_abort_authorization() {
    local temp=$secure_dir/post-force-rollback-abort-authorization.json
    local windows_binary windows_wrapper
    windows_binary=$(jq -er '.restored.binary_sha256' "$local_windows_rollback_receipt")
    windows_wrapper=$(jq -er '.restored.wrapper_sha256' "$local_windows_rollback_receipt")
    [[ $current_v13_peer_probe_sha =~ ^[0-9a-f]{64}$ ]] ||
        die 'post-force rollback abort lacks a fresh v1.3 peer probe'
    if [[ ! -e $deployment_abort_authorization && ! -L $deployment_abort_authorization ]]; then
        jq -cn --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" \
            --arg generation "$abort_marker_generation" --arg marker "$published_marker_sha" \
            --arg authorization "$deployment_abort_authorization" --arg state "$(sha256 "$coordinator_state")" \
            --arg lineage "$(sha256 "$fresh_operation_lineage_receipt")" \
            --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$abort_marker_publish_receipt")" \
            --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
            --arg prepared "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
            --arg force "$(sha256 "$windows_force_envelope")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
            --arg recovery "$(sha256 "$local_recovery_bundle")" --arg proof "$(sha256 "$linux_deactivation_proof")" \
            --arg transcript "$(sha256 "$linux_deactivation_transcript")" \
            --arg rollback "$(sha256 "$local_windows_rollback_receipt")" --arg linux "$old_viewflow_sha" \
            --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
            --arg windows "$windows_binary" --arg wrapper "$windows_wrapper" \
            --arg linux_started "$(sha256 "$linux_v13_started_receipt")" \
            --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
            --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
            {schema_version:7,state:"viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized",
             operation_id:$op,coordinator_instance_id:$coordinator,marker_generation:$generation,marker_sha256:$marker,
             authorization_receipt_path:$authorization,coordinator_terminal_state_sha256:$state,
             coordinator_failure_phase:"WINDOWS_FORCE_ATTESTED",coordinator_mutation_possible:true,
             fresh_operation_lineage_receipt_sha256:$lineage,marker_handoff_receipt_sha256:$handoff,
             deployment_publish_receipt_sha256:$publish,linux_frozen_evidence_sha256:$frozen,
             bootstrap_request_sha256:$request,windows_prepared_receipt_sha256:$prepared,
             mutation_permit_receipt_sha256:$permit,windows_force_envelope_sha256:$force,
             windows_stop_evidence_sha256:$stop,recovery_bundle_sha256:$recovery,
             linux_deactivation_proof_sha256:$proof,linux_deactivation_transcript_sha256:$transcript,
             windows_rollback_receipt_sha256:$rollback,old_linux_viewflowd_sha256:$linux,
             old_linux_deskflow_sha256:$deskflow,old_linux_deskflow_core_sha256:$core,
             old_windows_viewflowd_sha256:$windows,old_windows_wrapper_sha256:$wrapper,
             linux_v13_started_receipt_sha256:$linux_started,windows_v13_started_receipt_sha256:$windows_started,
             authenticated_v13_peer_receipt_sha256:$authenticated,mutation_permit_published:true,
             force_release_executed:true,rollback_performed:true,linux_stage_committed:false,
             windows_install_committed:false,windows_installer_exit_present:false,
             initial_force_release_executed:true,second_force_release_executed:false,
             rollback_token_consumed:true,protocol_2_1:false}
        ' >"$temp"
        publish_json_file 'post-force rollback abort authorization' "$temp" "$deployment_abort_authorization"
    fi
    require_owner_only_regular 'post-force rollback abort authorization' "$deployment_abort_authorization"
    assert_strict_json_document 'post-force rollback abort authorization' "$deployment_abort_authorization"
    jq -e --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$abort_marker_generation" --arg marker "$published_marker_sha" \
        --arg authorization "$deployment_abort_authorization" --arg state "$(sha256 "$coordinator_state")" \
        --arg lineage "$(sha256 "$fresh_operation_lineage_receipt")" \
        --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$abort_marker_publish_receipt")" \
        --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
        --arg prepared "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
        --arg force "$(sha256 "$windows_force_envelope")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
        --arg recovery "$(sha256 "$local_recovery_bundle")" --arg proof "$(sha256 "$linux_deactivation_proof")" \
        --arg transcript "$(sha256 "$linux_deactivation_transcript")" --arg rollback "$(sha256 "$local_windows_rollback_receipt")" \
        --arg linux "$old_viewflow_sha" --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
        --arg windows "$(jq -er '.restored.binary_sha256' "$local_windows_rollback_receipt")" \
        --arg wrapper "$(jq -er '.restored.wrapper_sha256' "$local_windows_rollback_receipt")" \
        --arg linux_started "$(sha256 "$linux_v13_started_receipt")" --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
        --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
        keys == ["authenticated_v13_peer_receipt_sha256","authorization_receipt_path","bootstrap_request_sha256","coordinator_failure_phase","coordinator_instance_id","coordinator_mutation_possible","coordinator_terminal_state_sha256","deployment_publish_receipt_sha256","force_release_executed","fresh_operation_lineage_receipt_sha256","initial_force_release_executed","linux_deactivation_proof_sha256","linux_deactivation_transcript_sha256","linux_frozen_evidence_sha256","linux_stage_committed","linux_v13_started_receipt_sha256","marker_generation","marker_handoff_receipt_sha256","marker_sha256","mutation_permit_published","mutation_permit_receipt_sha256","old_linux_deskflow_core_sha256","old_linux_deskflow_sha256","old_linux_viewflowd_sha256","old_windows_viewflowd_sha256","old_windows_wrapper_sha256","operation_id","protocol_2_1","recovery_bundle_sha256","rollback_performed","rollback_token_consumed","schema_version","second_force_release_executed","state","windows_force_envelope_sha256","windows_install_committed","windows_installer_exit_present","windows_prepared_receipt_sha256","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
        .schema_version == 7 and .state == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized" and
        .operation_id == $op and .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .marker_sha256 == $marker and .authorization_receipt_path == $authorization and
        .coordinator_terminal_state_sha256 == $state and .coordinator_failure_phase == "WINDOWS_FORCE_ATTESTED" and
        .coordinator_mutation_possible == true and .fresh_operation_lineage_receipt_sha256 == $lineage and
        .marker_handoff_receipt_sha256 == $handoff and .deployment_publish_receipt_sha256 == $publish and
        .linux_frozen_evidence_sha256 == $frozen and .bootstrap_request_sha256 == $request and
        .windows_prepared_receipt_sha256 == $prepared and .mutation_permit_receipt_sha256 == $permit and
        .windows_force_envelope_sha256 == $force and .windows_stop_evidence_sha256 == $stop and
        .recovery_bundle_sha256 == $recovery and .linux_deactivation_proof_sha256 == $proof and
        .linux_deactivation_transcript_sha256 == $transcript and .windows_rollback_receipt_sha256 == $rollback and
        .old_linux_viewflowd_sha256 == $linux and .old_linux_deskflow_sha256 == $deskflow and
        .old_linux_deskflow_core_sha256 == $core and .old_windows_viewflowd_sha256 == $windows and
        .old_windows_wrapper_sha256 == $wrapper and .linux_v13_started_receipt_sha256 == $linux_started and
        .windows_v13_started_receipt_sha256 == $windows_started and
        .authenticated_v13_peer_receipt_sha256 == $authenticated and .mutation_permit_published == true and
        .force_release_executed == true and .rollback_performed == true and .linux_stage_committed == false and
        .windows_install_committed == false and .windows_installer_exit_present == false and
        .initial_force_release_executed == true and .second_force_release_executed == false and
        .rollback_token_consumed == true and .protocol_2_1 == false
    ' "$deployment_abort_authorization" >/dev/null || die 'post-force rollback abort authorization schema/binding is invalid'
}

make_and_validate_abort_authorization() {
    local temp=$secure_dir/abort-authorization.json
    local windows_binary windows_wrapper
    if ((post_force_pre_linux_stage_rollback_abort)); then
        make_and_validate_post_force_rollback_abort_authorization
        return
    elif ((post_permit_rollback_abort)); then
        make_and_validate_post_permit_rollback_abort_authorization
        return
    fi
    windows_binary=$(jq -er '.restored.binary_sha256' "$local_windows_rollback_receipt")
    windows_wrapper=$(jq -er '.restored.wrapper_sha256' "$local_windows_rollback_receipt")
    [[ $current_v13_peer_probe_sha =~ ^[0-9a-f]{64}$ ]] || die 'current abort entry lacks a fresh v1.3 peer probe'
    if [[ ! -e $deployment_abort_authorization && ! -L $deployment_abort_authorization ]]; then
        jq -cn --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" \
            --arg generation "$abort_marker_generation" --arg marker "$published_marker_sha" \
            --arg authorization "$deployment_abort_authorization" \
            --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$abort_marker_publish_receipt")" \
            --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg force "$(sha256 "$windows_force_envelope")" \
            --arg migration "$(sha256 "$local_windows_rollback_receipt")" --arg claim "$(sha256 "$local_windows_stop_evidence")" \
            --arg linux "$old_viewflow_sha" --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
            --arg windows "$windows_binary" --arg wrapper "$windows_wrapper" \
            --arg linux_started "$(sha256 "$linux_v13_started_receipt")" \
            --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
            --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
            {schema_version:1,state:"viewflow-deployment-quarantine-abort-authorized",operation_id:$op,
             coordinator_instance_id:$coordinator,marker_generation:$generation,marker_sha256:$marker,
             authorization_receipt_path:$authorization,marker_handoff_receipt_sha256:$handoff,
             deployment_publish_receipt_sha256:$publish,linux_frozen_evidence_sha256:$frozen,
             windows_force_envelope_sha256:$force,windows_migration_receipt_sha256:$migration,
             windows_claim_resolution_sha256:$claim,old_linux_viewflowd_sha256:$linux,
             old_linux_deskflow_sha256:$deskflow,old_linux_deskflow_core_sha256:$core,
             old_windows_viewflowd_sha256:$windows,old_windows_wrapper_sha256:$wrapper,
             linux_v13_started_receipt_sha256:$linux_started,windows_v13_started_receipt_sha256:$windows_started,
             authenticated_v13_peer_receipt_sha256:$authenticated,
             initial_force_release_executed:true,
             second_force_release_executed:false,rollback_token_consumed:false,protocol_2_1:false}
        ' >"$temp"
        publish_json_file 'failed-v1.3 abort authorization' "$temp" "$deployment_abort_authorization"
    fi
    require_owner_only_regular 'failed-v1.3 abort authorization' "$deployment_abort_authorization"
    assert_strict_json_document 'failed-v1.3 abort authorization' "$deployment_abort_authorization"
    jq -e --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$abort_marker_generation" --arg marker "$published_marker_sha" \
        --arg authorization "$deployment_abort_authorization" \
        --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$abort_marker_publish_receipt")" \
        --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg force "$(sha256 "$windows_force_envelope")" \
        --arg migration "$(sha256 "$local_windows_rollback_receipt")" --arg claim "$(sha256 "$local_windows_stop_evidence")" \
        --arg linux "$old_viewflow_sha" --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
        --arg windows "$windows_binary" --arg wrapper "$windows_wrapper" \
        --arg linux_started "$(sha256 "$linux_v13_started_receipt")" --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
        --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
        keys == ["authenticated_v13_peer_receipt_sha256","authorization_receipt_path","coordinator_instance_id","deployment_publish_receipt_sha256","initial_force_release_executed","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_generation","marker_handoff_receipt_sha256","marker_sha256","old_linux_deskflow_core_sha256","old_linux_deskflow_sha256","old_linux_viewflowd_sha256","old_windows_viewflowd_sha256","old_windows_wrapper_sha256","operation_id","protocol_2_1","rollback_token_consumed","schema_version","second_force_release_executed","state","windows_claim_resolution_sha256","windows_force_envelope_sha256","windows_migration_receipt_sha256","windows_v13_started_receipt_sha256"] and
        .schema_version == 1 and .state == "viewflow-deployment-quarantine-abort-authorized" and
        .operation_id == $op and .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .marker_sha256 == $marker and .authorization_receipt_path == $authorization and
        .marker_handoff_receipt_sha256 == $handoff and .deployment_publish_receipt_sha256 == $publish and
        .linux_frozen_evidence_sha256 == $frozen and .windows_force_envelope_sha256 == $force and
        .windows_migration_receipt_sha256 == $migration and .windows_claim_resolution_sha256 == $claim and
        .old_linux_viewflowd_sha256 == $linux and .old_linux_deskflow_sha256 == $deskflow and
        .old_linux_deskflow_core_sha256 == $core and .old_windows_viewflowd_sha256 == $windows and
        .old_windows_wrapper_sha256 == $wrapper and .linux_v13_started_receipt_sha256 == $linux_started and
        .windows_v13_started_receipt_sha256 == $windows_started and .authenticated_v13_peer_receipt_sha256 == $authenticated and
        .initial_force_release_executed == true and .second_force_release_executed == false and
        .rollback_token_consumed == false and .protocol_2_1 == false
    ' "$deployment_abort_authorization" >/dev/null || die 'failed-v1.3 abort authorization schema/binding is invalid'
}

validate_abort_receipt_binary() {
    local path=$1 authorization_sha durable expected_durable prefix_sha suffix_sha marker_sha marker_recorded authorization_recorded
    local op_len embedded_op source_hex target_hex coordinator_hex generation committed reserved
    authorization_sha=$(sha256 "$deployment_abort_authorization")
    durable=$(jq -er '.abort_receipt_path' "$path")
    expected_durable="/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.${published_marker_sha}.${authorization_sha}.v1"
    [[ $durable == "$expected_durable" ]] || die 'VFDQA001 path is not content-addressed by marker+authorization hashes'
    [[ -f $durable && ! -L $durable && $(stat -c '%u:%a:%h:%s' -- "$durable") == 1000:600:1:384 ]] ||
        die 'VFDQA001 durable receipt metadata is invalid'
    [[ $(dd if="$durable" bs=8 count=1 status=none) == VFDQA001 ]] || die 'VFDQA001 magic is invalid'
    [[ $(dd if="$durable" bs=1 skip=8 count=8 status=none | od -An -tx1 | tr -d ' \n') == 0101010301000000 ]] ||
        die 'VFDQA001 header/version/reserved bytes are invalid'
    [[ $(dd if="$durable" bs=1 skip=16 count=8 status=none) == VFDQT001 ]] || die 'VFDQA001 embedded marker magic is invalid'
    marker_sha=$(dd if="$durable" bs=1 skip=16 count=256 status=none | sha256sum | awk '{print $1}')
    marker_recorded=$(dd if="$durable" bs=1 skip=272 count=32 status=none | od -An -tx1 | tr -d ' \n')
    authorization_recorded=$(dd if="$durable" bs=1 skip=304 count=32 status=none | od -An -tx1 | tr -d ' \n')
    [[ $marker_sha == "$published_marker_sha" && $marker_recorded == "$published_marker_sha" &&
       $authorization_recorded == "$authorization_sha" ]] || die 'VFDQA001 marker/authorization hash binding is invalid'
    op_len=$(od -An -tu1 -j29 -N1 "$durable" | tr -d ' ')
    embedded_op=$(dd if="$durable" bs=1 skip=32 count="$op_len" status=none)
    source_hex=$(dd if="$durable" bs=1 skip=160 count=16 status=none | od -An -tx1 | tr -d ' \n')
    target_hex=$(dd if="$durable" bs=1 skip=176 count=16 status=none | od -An -tx1 | tr -d ' \n')
    coordinator_hex=$(dd if="$durable" bs=1 skip=192 count=16 status=none | od -An -tx1 | tr -d ' \n')
    generation=$(od -An -tu8 -j216 -N8 "$durable" | tr -d ' ')
    [[ $embedded_op == "$abort_marker_operation_id" && $source_hex == "$source_display_id_lower" &&
       $target_hex == "$target_device_id_lower" && $coordinator_hex == "$coordinator_instance_id_lower" &&
       $generation == "$abort_marker_generation" ]] || die 'VFDQA001 embedded marker identity differs'
    committed=$(od -An -tu8 -j336 -N8 "$durable" | tr -d ' ')
    reserved=$(dd if="$durable" bs=1 skip=344 count=8 status=none | od -An -tx1 | tr -d ' \n')
    [[ $committed == "$(jq -er '.abort_committed_at_unix_ms' "$path")" && $committed != 0 &&
       $reserved == 0000000000000000 ]] || die 'VFDQA001 timestamp/reserved bytes are invalid'
    prefix_sha=$(dd if="$durable" bs=352 count=1 status=none | sha256sum | awk '{print $1}')
    suffix_sha=$(dd if="$durable" bs=1 skip=352 count=32 status=none | od -An -tx1 | tr -d ' \n')
    [[ $prefix_sha == "$suffix_sha" ]] || die 'VFDQA001 self-checksum is invalid'
}

validate_abort_receipt_v2() {
    local path=$1 authorization_sha
    authorization_sha=$(sha256 "$deployment_abort_authorization")
    jq -e --arg op "$operation_id" --arg coordinator "$coordinator_instance_id" --arg generation "$marker_generation" \
        --arg marker "$DEPLOYMENT_MARKER" --arg sha "$published_marker_sha" --arg source "$source_display_id" \
        --arg target "$target_device_id" --arg authorization "$deployment_abort_authorization" --arg authsha "$authorization_sha" '
        keys == ["abort_authorization_path","abort_authorization_sha256","abort_claim_path","abort_committed_at_unix_ms","abort_committed_at_utc","abort_point","abort_receipt_path","aborted_marker_sha256","coordinator_instance_id","deployment_release_claimed","initial_force_release_executed","marker_created_at_unix_ms","marker_generation","marker_path","operation_id","protocol_2_1","protocol_version","replayed","rollback_performed","schema_version","source_display_id","state","target_device_id","windows_rollback_receipt_sha256"] and
        .schema_version == 2 and .state == "deployment-quarantine-aborted" and .protocol_version == "1.3" and
        .protocol_2_1 == false and .operation_id == $op and .coordinator_instance_id == $coordinator and
        .marker_generation == $generation and .source_display_id == $source and .target_device_id == $target and
        .marker_path == $marker and .abort_claim_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim" and
        .abort_authorization_path == $authorization and .abort_authorization_sha256 == $authsha and
        .aborted_marker_sha256 == $sha and .deployment_release_claimed == false and
        .initial_force_release_executed == false and .rollback_performed == false and
        .windows_rollback_receipt_sha256 == null and
        (.marker_created_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.abort_committed_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.abort_committed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
        .abort_point == "abort-claim-unlink-and-parent-directory-fsync" and (.replayed | type == "boolean")
    ' "$path" >/dev/null || die 'pre-mutation failed-v1.3 abort JSON receipt is invalid'
    validate_abort_receipt_binary "$path"
}

validate_abort_receipt_v1() {
    local path=$1 authorization_sha durable expected_durable prefix_sha suffix_sha marker_sha marker_recorded authorization_recorded
    local op_len embedded_op source_hex target_hex coordinator_hex generation committed reserved
    authorization_sha=$(sha256 "$deployment_abort_authorization")
    jq -e --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" --arg generation "$abort_marker_generation" \
        --arg marker "$DEPLOYMENT_MARKER" --arg sha "$published_marker_sha" --arg source "$source_display_id" \
        --arg target "$target_device_id" --arg authorization "$deployment_abort_authorization" --arg authsha "$authorization_sha" '
        keys == ["abort_authorization_path","abort_authorization_sha256","abort_claim_path","abort_committed_at_unix_ms","abort_committed_at_utc","abort_point","abort_receipt_path","aborted_marker_sha256","coordinator_instance_id","deployment_release_claimed","initial_force_release_executed","marker_created_at_unix_ms","marker_generation","marker_path","operation_id","protocol_2_1","protocol_version","replayed","rollback_token_consumed","schema_version","second_force_release_executed","source_display_id","state","target_device_id"] and
        .schema_version == 1 and .state == "deployment-quarantine-aborted" and .protocol_version == "1.3" and .protocol_2_1 == false and
        .operation_id == $op and .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .source_display_id == $source and .target_device_id == $target and .marker_path == $marker and
        .abort_claim_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim" and
        .abort_authorization_path == $authorization and .abort_authorization_sha256 == $authsha and
        .aborted_marker_sha256 == $sha and .deployment_release_claimed == false and
        .initial_force_release_executed == true and .second_force_release_executed == false and .rollback_token_consumed == false and
        (.marker_created_at_unix_ms | test("^[1-9][0-9]*$")) and (.abort_committed_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.abort_committed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
        .abort_point == "abort-claim-unlink-and-parent-directory-fsync" and (.replayed | type == "boolean")
    ' "$path" >/dev/null || { die 'failed-v1.3 abort JSON receipt is invalid'; return 1; }
    durable=$(jq -er '.abort_receipt_path' "$path")
    expected_durable="/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.${published_marker_sha}.${authorization_sha}.v1"
    [[ $durable == "$expected_durable" ]] || { die 'VFDQA001 path is not content-addressed by marker+authorization hashes'; return 1; }
    [[ -f $durable && ! -L $durable && $(stat -c '%u:%a:%h:%s' -- "$durable") == 1000:600:1:384 ]] ||
        { die 'VFDQA001 durable receipt metadata is invalid'; return 1; }
    [[ $(dd if="$durable" bs=8 count=1 status=none) == VFDQA001 ]] || { die 'VFDQA001 magic is invalid'; return 1; }
    [[ $(dd if="$durable" bs=1 skip=8 count=8 status=none | od -An -tx1 | tr -d ' \n') == 0101010301000000 ]] ||
        { die 'VFDQA001 header/version/reserved bytes are invalid'; return 1; }
    [[ $(dd if="$durable" bs=1 skip=16 count=8 status=none) == VFDQT001 ]] || { die 'VFDQA001 embedded marker magic is invalid'; return 1; }
    marker_sha=$(dd if="$durable" bs=1 skip=16 count=256 status=none | sha256sum | awk '{print $1}')
    marker_recorded=$(dd if="$durable" bs=1 skip=272 count=32 status=none | od -An -tx1 | tr -d ' \n')
    authorization_recorded=$(dd if="$durable" bs=1 skip=304 count=32 status=none | od -An -tx1 | tr -d ' \n')
    [[ $marker_sha == "$published_marker_sha" && $marker_recorded == "$published_marker_sha" &&
       $authorization_recorded == "$authorization_sha" ]] || { die 'VFDQA001 marker/authorization hash binding is invalid'; return 1; }
    op_len=$(od -An -tu1 -j29 -N1 "$durable" | tr -d ' ')
    embedded_op=$(dd if="$durable" bs=1 skip=32 count="$op_len" status=none)
    source_hex=$(dd if="$durable" bs=1 skip=160 count=16 status=none | od -An -tx1 | tr -d ' \n')
    target_hex=$(dd if="$durable" bs=1 skip=176 count=16 status=none | od -An -tx1 | tr -d ' \n')
    coordinator_hex=$(dd if="$durable" bs=1 skip=192 count=16 status=none | od -An -tx1 | tr -d ' \n')
    generation=$(od -An -tu8 -j216 -N8 "$durable" | tr -d ' ')
    [[ $embedded_op == "$abort_marker_operation_id" && $source_hex == "$source_display_id_lower" &&
       $target_hex == "$target_device_id_lower" && $coordinator_hex == "$coordinator_instance_id_lower" &&
       $generation == "$abort_marker_generation" ]] || { die 'VFDQA001 embedded marker identity differs'; return 1; }
    committed=$(od -An -tu8 -j336 -N8 "$durable" | tr -d ' ')
    reserved=$(dd if="$durable" bs=1 skip=344 count=8 status=none | od -An -tx1 | tr -d ' \n')
    [[ $committed == "$(jq -er '.abort_committed_at_unix_ms' "$path")" && $committed != 0 &&
       $reserved == 0000000000000000 ]] || { die 'VFDQA001 timestamp/reserved bytes are invalid'; return 1; }
    prefix_sha=$(dd if="$durable" bs=352 count=1 status=none | sha256sum | awk '{print $1}')
    suffix_sha=$(dd if="$durable" bs=1 skip=352 count=32 status=none | od -An -tx1 | tr -d ' \n')
    [[ $prefix_sha == "$suffix_sha" ]] || { die 'VFDQA001 self-checksum is invalid'; return 1; }
}

validate_abort_receipt_v5() {
    local path=$1 authorization_sha
    authorization_sha=$(sha256 "$deployment_abort_authorization")
    jq -e --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$abort_marker_generation" --arg marker "$DEPLOYMENT_MARKER" \
        --arg sha "$published_marker_sha" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg authorization "$deployment_abort_authorization" --arg authsha "$authorization_sha" \
        --arg state "$(sha256 "$coordinator_state")" --arg lineage "$(sha256 "$schema1_handoff_lineage_receipt")" \
        --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$abort_marker_publish_receipt")" \
        --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
        --arg prepared "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
        --arg exit "$(sha256 "$windows_installer_exit_receipt")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
        --arg recovery "$(sha256 "$local_recovery_bundle")" --arg proof "$(sha256 "$linux_deactivation_proof")" \
        --arg transcript "$(sha256 "$linux_deactivation_transcript")" --arg rollback "$(sha256 "$local_windows_rollback_receipt")" \
        --arg linux_started "$(sha256 "$linux_v13_started_receipt")" \
        --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
        --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
        keys == ["abort_authorization_path","abort_authorization_sha256","abort_claim_path","abort_committed_at_unix_ms","abort_committed_at_utc","abort_point","abort_receipt_path","aborted_marker_sha256","authenticated_v13_peer_receipt_sha256","authorization_state","bootstrap_request_sha256","coordinator_failure_phase","coordinator_instance_id","coordinator_mutation_possible","coordinator_terminal_state_sha256","deployment_publish_receipt_sha256","deployment_release_claimed","force_release_executed","initial_force_release_executed","installer_exit_receipt_sha256","linux_deactivation_proof_sha256","linux_deactivation_transcript_sha256","linux_frozen_evidence_sha256","linux_v13_started_receipt_sha256","marker_created_at_unix_ms","marker_generation","marker_handoff_receipt_sha256","marker_path","mutation_permit_published","mutation_permit_receipt_sha256","operation_id","protocol_2_1","protocol_version","recovery_bundle_sha256","replayed","rollback_performed","rollback_token_consumed","schema1_handoff_lineage_receipt_sha256","schema_version","second_force_release_executed","source_display_id","state","target_device_id","windows_prepared_receipt_sha256","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
        .schema_version == 5 and .state == "deployment-quarantine-aborted" and
        .authorization_state == "viewflow-deployment-quarantine-post-permit-rollback-abort-authorized" and
        .protocol_version == "1.3" and .protocol_2_1 == false and .operation_id == $op and
        .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .source_display_id == $source and .target_device_id == $target and .marker_path == $marker and
        .abort_claim_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim" and
        .abort_authorization_path == $authorization and .abort_authorization_sha256 == $authsha and
        .aborted_marker_sha256 == $sha and .deployment_release_claimed == false and
        .coordinator_terminal_state_sha256 == $state and .coordinator_failure_phase == "MUTATION_PERMITTED" and
        .coordinator_mutation_possible == true and .schema1_handoff_lineage_receipt_sha256 == $lineage and
        .marker_handoff_receipt_sha256 == $handoff and .deployment_publish_receipt_sha256 == $publish and
        .linux_frozen_evidence_sha256 == $frozen and .bootstrap_request_sha256 == $request and
        .windows_prepared_receipt_sha256 == $prepared and .mutation_permit_receipt_sha256 == $permit and
        .installer_exit_receipt_sha256 == $exit and .windows_stop_evidence_sha256 == $stop and
        .recovery_bundle_sha256 == $recovery and .linux_deactivation_proof_sha256 == $proof and
        .linux_deactivation_transcript_sha256 == $transcript and .windows_rollback_receipt_sha256 == $rollback and
        .linux_v13_started_receipt_sha256 == $linux_started and .windows_v13_started_receipt_sha256 == $windows_started and
        .authenticated_v13_peer_receipt_sha256 == $authenticated and .mutation_permit_published == true and
        .force_release_executed == false and .rollback_performed == true and
        .initial_force_release_executed == false and .second_force_release_executed == false and
        .rollback_token_consumed == true and (.replayed | type == "boolean") and
        (.marker_created_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.abort_committed_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.abort_committed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
        .abort_point == "abort-claim-atomic-retire-and-parent-directory-fsync"
    ' "$path" >/dev/null || { die 'post-permit rollback VFDQA JSON receipt is invalid'; return 1; }
    validate_abort_receipt_binary "$path"
}

validate_abort_receipt_v7() {
    local path=$1 authorization_sha
    authorization_sha=$(sha256 "$deployment_abort_authorization")
    jq -e --arg op "$abort_marker_operation_id" --arg coordinator "$coordinator_instance_id" \
        --arg generation "$abort_marker_generation" --arg marker "$DEPLOYMENT_MARKER" \
        --arg sha "$published_marker_sha" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg authorization "$deployment_abort_authorization" --arg authsha "$authorization_sha" \
        --arg state "$(sha256 "$coordinator_state")" --arg lineage "$(sha256 "$fresh_operation_lineage_receipt")" \
        --arg handoff "$(sha256 "$bootstrap_handoff_receipt")" --arg publish "$(sha256 "$abort_marker_publish_receipt")" \
        --arg frozen "$(sha256 "$bootstrap_linux_evidence")" --arg request "$windows_request_sha" \
        --arg prepared "$(sha256 "$windows_prepared_receipt")" --arg permit "$(sha256 "$windows_mutation_permit")" \
        --arg force "$(sha256 "$windows_force_envelope")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
        --arg recovery "$(sha256 "$local_recovery_bundle")" --arg proof "$(sha256 "$linux_deactivation_proof")" \
        --arg transcript "$(sha256 "$linux_deactivation_transcript")" --arg rollback "$(sha256 "$local_windows_rollback_receipt")" \
        --arg linux_started "$(sha256 "$linux_v13_started_receipt")" \
        --arg windows_started "$(sha256 "$windows_v13_started_receipt")" \
        --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" '
        keys == ["abort_authorization_path","abort_authorization_sha256","abort_claim_path","abort_committed_at_unix_ms","abort_committed_at_utc","abort_point","abort_receipt_path","aborted_marker_sha256","authenticated_v13_peer_receipt_sha256","authorization_state","bootstrap_request_sha256","coordinator_failure_phase","coordinator_instance_id","coordinator_mutation_possible","coordinator_terminal_state_sha256","deployment_publish_receipt_sha256","deployment_release_claimed","force_release_executed","fresh_operation_lineage_receipt_sha256","initial_force_release_executed","linux_deactivation_proof_sha256","linux_deactivation_transcript_sha256","linux_frozen_evidence_sha256","linux_stage_committed","linux_v13_started_receipt_sha256","marker_created_at_unix_ms","marker_generation","marker_handoff_receipt_sha256","marker_path","mutation_permit_published","mutation_permit_receipt_sha256","operation_id","protocol_2_1","protocol_version","recovery_bundle_sha256","replayed","rollback_performed","rollback_token_consumed","schema_version","second_force_release_executed","source_display_id","state","target_device_id","windows_force_envelope_sha256","windows_install_committed","windows_installer_exit_present","windows_prepared_receipt_sha256","windows_rollback_receipt_sha256","windows_stop_evidence_sha256","windows_v13_started_receipt_sha256"] and
        .schema_version == 7 and .state == "deployment-quarantine-aborted" and
        .authorization_state == "viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized" and
        .protocol_version == "1.3" and .protocol_2_1 == false and .operation_id == $op and
        .coordinator_instance_id == $coordinator and .marker_generation == $generation and
        .source_display_id == $source and .target_device_id == $target and .marker_path == $marker and
        .abort_claim_path == "/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim" and
        .abort_authorization_path == $authorization and .abort_authorization_sha256 == $authsha and
        .aborted_marker_sha256 == $sha and .deployment_release_claimed == false and
        .coordinator_terminal_state_sha256 == $state and .coordinator_failure_phase == "WINDOWS_FORCE_ATTESTED" and
        .coordinator_mutation_possible == true and .fresh_operation_lineage_receipt_sha256 == $lineage and
        .marker_handoff_receipt_sha256 == $handoff and .deployment_publish_receipt_sha256 == $publish and
        .linux_frozen_evidence_sha256 == $frozen and .bootstrap_request_sha256 == $request and
        .windows_prepared_receipt_sha256 == $prepared and .mutation_permit_receipt_sha256 == $permit and
        .windows_force_envelope_sha256 == $force and .windows_stop_evidence_sha256 == $stop and
        .recovery_bundle_sha256 == $recovery and .linux_deactivation_proof_sha256 == $proof and
        .linux_deactivation_transcript_sha256 == $transcript and .windows_rollback_receipt_sha256 == $rollback and
        .linux_v13_started_receipt_sha256 == $linux_started and .windows_v13_started_receipt_sha256 == $windows_started and
        .authenticated_v13_peer_receipt_sha256 == $authenticated and .mutation_permit_published == true and
        .force_release_executed == true and .rollback_performed == true and .linux_stage_committed == false and
        .windows_install_committed == false and .windows_installer_exit_present == false and
        .initial_force_release_executed == true and .second_force_release_executed == false and
        .rollback_token_consumed == true and (.replayed | type == "boolean") and
        (.marker_created_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.abort_committed_at_unix_ms | test("^[1-9][0-9]*$")) and
        (.abort_committed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
        .abort_point == "abort-claim-atomic-retire-and-parent-directory-fsync"
    ' "$path" >/dev/null || { die 'post-force rollback VFDQA JSON receipt is invalid'; return 1; }
    validate_abort_receipt_binary "$path"
}

abort_deployment_marker_transactionally() {
    local temp=$secure_dir/abort-query.json authorization_sha marker_role marker_executable marker_executable_sha
    # The authorization binds immutable receipts; take one last live identity
    # snapshot after publishing it and immediately before entering the local
    # marker CLI transaction.  The replay comparison refuses a changed PID,
    # task XML, wrapper, executable, SID, session, or Linux invocation.
    start_and_freeze_linux_v13
    start_and_freeze_windows_v13
    validate_authenticated_v13_peer
    authorization_sha=$(sha256 "$deployment_abort_authorization")
    marker_role=marker
    marker_executable=$MARKER_CLI
    marker_executable_sha=$old_marker_cli_sha
    if ((post_force_pre_linux_stage_rollback_abort)); then
        marker_role=marker-candidate
        marker_executable=$post_force_abort_marker_cli_candidate
        marker_executable_sha=$post_force_abort_marker_cli_sha
    elif ((post_permit_rollback_abort)); then
        marker_role=marker-candidate
        marker_executable=$schema1_handoff_abort_marker_cli_candidate
        marker_executable_sha=$schema1_handoff_abort_marker_cli_sha
    fi
    if [[ -e $deployment_abort_receipt ]]; then
        capture_json_command 'failed-v1.3 abort replay query' "$temp" run_pinned_executable \
            "$marker_role" "$marker_executable" "$marker_executable_sha" query \
            --operation-id "$abort_marker_operation_id" --coordinator-instance-id "$coordinator_instance_id" \
            --marker-generation "$abort_marker_generation" --marker-sha256 "$published_marker_sha" \
            --abort-authorization-path "$deployment_abort_authorization" --abort-authorization-sha256 "$authorization_sha"
        [[ $(jq -cS 'del(.replayed)' "$temp") == "$(jq -cS 'del(.replayed)' "$deployment_abort_receipt")" &&
           $(jq -r '.replayed' "$temp") == true ]] || die 'failed-v1.3 abort replay differs from durable receipt'
        rm -f -- "$temp"
    else
        capture_json_command 'failed-v1.3 deployment abort receipt' "$deployment_abort_receipt" run_pinned_executable \
            "$marker_role" "$marker_executable" "$marker_executable_sha" abort \
            --operation-id "$abort_marker_operation_id" --coordinator-instance-id "$coordinator_instance_id" \
            --marker-generation "$abort_marker_generation" --marker-sha256 "$published_marker_sha" \
            --abort-authorization-path "$deployment_abort_authorization" --abort-authorization-sha256 "$authorization_sha"
    fi
    if ((post_force_pre_linux_stage_rollback_abort)); then
        validate_abort_receipt_v7 "$deployment_abort_receipt"
    elif ((post_permit_rollback_abort)); then
        validate_abort_receipt_v5 "$deployment_abort_receipt"
    else
        validate_abort_receipt_v1 "$deployment_abort_receipt"
    fi
    [[ ! -e $DEPLOYMENT_MARKER && ! -e ${DEPLOYMENT_MARKER}.abort-claim && ! -e ${DEPLOYMENT_MARKER}.release-claim ]] ||
        die 'failed-v1.3 abort remains quarantined or claimed'
}

abort_pre_mutation_deployment_marker_transactionally() {
    local temp=$secure_dir/pre-mutation-abort-query.json authorization_sha
    start_and_freeze_linux_v13
    validate_linux_v13_started
    freeze_pre_mutation_windows_v13
    validate_pre_mutation_windows_v13_started
    validate_authenticated_v13_peer
    validate_pre_mutation_failed_terminal_state
    validate_pre_mutation_failed_baseline
    assert_pre_mutation_outputs_absent
    authorization_sha=$(sha256 "$deployment_abort_authorization")
    if [[ -e $deployment_abort_receipt ]]; then
        capture_json_command 'pre-mutation failed-v1.3 abort replay query' "$temp" run_pinned_executable \
            marker-candidate "$pre_mutation_abort_marker_cli_candidate" "$pre_mutation_abort_marker_cli_sha" query \
            --operation-id "$operation_id" --coordinator-instance-id "$coordinator_instance_id" \
            --marker-generation "$marker_generation" --marker-sha256 "$published_marker_sha" \
            --abort-authorization-path "$deployment_abort_authorization" --abort-authorization-sha256 "$authorization_sha"
        [[ $(jq -cS 'del(.replayed)' "$temp") == "$(jq -cS 'del(.replayed)' "$deployment_abort_receipt")" &&
           $(jq -r '.replayed' "$temp") == true ]] || die 'pre-mutation VFDQA replay differs from durable receipt'
        rm -f -- "$temp"
    else
        capture_json_command 'pre-mutation failed-v1.3 deployment abort receipt' "$deployment_abort_receipt" \
            run_pinned_executable marker-candidate "$pre_mutation_abort_marker_cli_candidate" \
            "$pre_mutation_abort_marker_cli_sha" abort --operation-id "$operation_id" \
            --coordinator-instance-id "$coordinator_instance_id" --marker-generation "$marker_generation" \
            --marker-sha256 "$published_marker_sha" --abort-authorization-path "$deployment_abort_authorization" \
            --abort-authorization-sha256 "$authorization_sha"
    fi
    validate_abort_receipt_v2 "$deployment_abort_receipt"
    [[ ! -e $DEPLOYMENT_MARKER && ! -e ${DEPLOYMENT_MARKER}.abort-claim && ! -e ${DEPLOYMENT_MARKER}.release-claim ]] ||
        die 'pre-mutation failed-v1.3 abort remains quarantined or claimed'
}

derive_pre_mutation_abort_contract() {
    local state_path state_sha caller
    derive_windows_paths
    for caller in windows_launcher_sha windows_installer_sha windows_viewflow_sha windows_wrapper_sha windows_rollback_script_sha; do
        state_path=${caller#windows_}; state_path=${state_path%_sha}
        case $caller in
            windows_launcher_sha) state_sha=$(jq -er '.contract.inputs.windows_launcher.sha256' "$coordinator_state") ;;
            windows_installer_sha) state_sha=$(jq -er '.contract.inputs.windows_installer.sha256' "$coordinator_state") ;;
            windows_viewflow_sha) state_sha=$(jq -er '.contract.inputs.windows_viewflow.sha256' "$coordinator_state") ;;
            windows_wrapper_sha) state_sha=$(jq -er '.contract.inputs.windows_wrapper.sha256' "$coordinator_state") ;;
            windows_rollback_script_sha) state_sha=$(jq -er '.contract.inputs.windows_rollback.sha256' "$coordinator_state") ;;
        esac
        if [[ -n ${!caller} && ${!caller} != "$state_sha" ]]; then
            die "caller $caller differs from immutable pre-mutation state"
        fi
        printf -v "$caller" '%s' "$state_sha"
    done
    windows_request_sha=$(sha256 "$windows_bootstrap_request")
}

failed_v13_pre_mutation_abort_preflight() {
    local label path state_path
    ((WINDOWS_RECOVERY_IMPLEMENTED == 1)) || die 'failed-v1.3 Windows recovery/abort gate is disabled'
    [[ $(id -u) == 1000 && $HOME == /home/wilf ]] ||
        die 'run pre-mutation failed-v1.3 abort as uid 1000 with HOME=/home/wilf'
    for label in base64 bash busctl dd grep iconv jq journalctl ln mktemp od sha256sum ssh stat sync systemctl systemd-run; do
        command -v "$label" >/dev/null || die "required pre-mutation abort command unavailable: $label"
    done
    [[ $operation_id =~ ^[0-9a-f]{32}$ ]] || die '--operation-id must be exactly 32 lowercase hex characters'
    require_sha256 '--old-coordinator-state-sha256' "$old_coordinator_state_sha"
    require_sha256 '--pre-mutation-abort-marker-cli-sha256' "$pre_mutation_abort_marker_cli_sha"
    require_uuid '--coordinator-instance-id' "$coordinator_instance_id"
    require_uuid '--source-display-id' "$source_display_id"
    require_uuid '--target-device-id' "$target_device_id"
    [[ $marker_generation == 1 ]] || die 'pre-mutation failed-v1.3 abort requires original generation 1'
    ((failed_v13_original_generation_only == 1)) ||
        die 'pre-mutation failed-v1.3 abort requires --failed-v13-original-generation-only'
    [[ $windows_user_sid =~ ^S-1-[0-9]+(-[0-9]+)+$ ]] || die 'invalid Windows SID'
    source_display_id_lower=$(lower_id "$source_display_id")
    target_device_id_lower=$(lower_id "$target_device_id")
    coordinator_instance_id_lower=$(lower_id "$coordinator_instance_id")
    v13_viewflow_unit="viewflow-v13-recovery-${operation_id}.service"
    v13_deskflow_unit="deskflow-v13-recovery-${operation_id}.service"
    validate_fd_gate_contract
    require_owner_only_regular 'pre-mutation failed coordinator state' "$coordinator_state"
    [[ $(sha256 "$coordinator_state") == "$old_coordinator_state_sha" ]] ||
        die 'pre-mutation failed coordinator state SHA differs before path derivation'
    state_path=$(jq -er '.contract.inputs.marker_handoff.path' "$coordinator_state")
    [[ $bootstrap_handoff_receipt == "$state_path" ]] || die 'marker handoff path differs from immutable state'
    state_path=$(jq -er '.contract.inputs.publish_receipt.path' "$coordinator_state")
    [[ $deployment_publish_receipt == "$state_path" ]] || die 'publish receipt path differs from immutable state'
    state_path=$(jq -er '.contract.inputs.linux_frozen.path' "$coordinator_state")
    [[ $bootstrap_linux_evidence == "$state_path" ]] || die 'Linux frozen path differs from immutable state'
    validate_pre_mutation_failed_terminal_state
    derive_pre_mutation_abort_contract
    for path in "$bootstrap_handoff_receipt" "$deployment_publish_receipt" "$bootstrap_linux_evidence" \
        "$windows_bootstrap_request" "$windows_installer_exit_receipt" "$local_windows_stop_evidence" \
        "$pre_mutation_retry_proof"; do
        require_owner_only_regular 'pre-mutation terminal input' "$path"
    done
    [[ $pre_mutation_abort_marker_cli_candidate == /* &&
       $pre_mutation_abort_marker_cli_candidate != "$MARKER_CLI" &&
       -f $pre_mutation_abort_marker_cli_candidate && ! -L $pre_mutation_abort_marker_cli_candidate &&
       $(stat -c '%u:%a:%h' -- "$pre_mutation_abort_marker_cli_candidate") == 1000:755:1 &&
       $(sha256 "$pre_mutation_abort_marker_cli_candidate") == "$pre_mutation_abort_marker_cli_sha" ]] ||
        die 'pre-mutation marker CLI candidate identity/hash is invalid'
    for path in "$deployment_abort_authorization" "$deployment_abort_receipt" \
        "$failed_v13_abort_transition_receipt" "$linux_v13_started_receipt" \
        "$windows_v13_started_receipt" "$authenticated_v13_peer_receipt" "$pre_mutation_windows_live_proof"; do
        if [[ -e $path || -L $path ]]; then
            require_owner_only_regular 'pre-mutation durable output' "$path"
        else
            require_absolute_new_output 'pre-mutation durable output' "$path"
        fi
    done
    [[ ! -e $local_windows_rollback_receipt && ! -L $local_windows_rollback_receipt ]] ||
        die 'pre-mutation abort refuses a Windows rollback receipt'
    [[ ! -e $linux_deactivation_proof && ! -L $linux_deactivation_proof ]] ||
        die 'pre-mutation abort refuses a Linux rollback/deactivation proof'
    [[ ! -e ${DEPLOYMENT_MARKER}.release-claim ]] || die 'pre-mutation abort refuses a release claim'
    secure_dir=$(mktemp -d); chmod 0700 "$secure_dir"
    validate_pre_mutation_failed_terminal_state
    validate_pre_mutation_failed_baseline
    assert_pre_mutation_outputs_absent
    validate_publish_receipt "$deployment_publish_receipt" "$marker_generation" 0
    abort_marker_operation_id=$operation_id
    abort_marker_generation=$marker_generation
    abort_marker_publish_receipt=$deployment_publish_receipt
    assert_failed_v13_original_generation_only
    if [[ -e $DEPLOYMENT_MARKER ]]; then
        assert_deployment_marker || die 'pre-mutation abort marker differs from generation-1 publish receipt'
    else
        [[ -e $deployment_abort_authorization && -e $deployment_abort_receipt ]] ||
            die 'pre-mutation marker is absent without committed VFDQA evidence'
    fi
    if [[ ! -e $linux_v13_started_receipt ]]; then
        if [[ $(systemctl --user show --property LoadState --value "$v13_viewflow_unit" 2>/dev/null || true) == loaded ]]; then
            assert_adoptable_linux_v13_without_receipt
        else
            assert_linux_inactive
        fi
    fi
}

failed_v13_abort_preflight() {
    local label path active_abort_sha state_request state_stop state_prepared state_permit state_exit state_recovery state_force
    ((WINDOWS_RECOVERY_IMPLEMENTED == 1)) || die 'failed-v1.3 Windows recovery/abort gate is disabled'
    [[ $(id -u) == 1000 && $HOME == /home/wilf ]] || die 'run failed-v1.3 abort as uid 1000 with HOME=/home/wilf'
    for label in bash busctl dd dirname grep iconv jq journalctl ln mktemp od sha256sum ssh stat sync systemctl systemd-run; do
        command -v "$label" >/dev/null || die "required abort command unavailable: $label"
    done
    [[ $operation_id =~ ^[0-9a-f]{32}$ ]] || die '--operation-id must be exactly 32 lowercase hex characters'
    require_sha256 '--old-coordinator-state-sha256' "$old_coordinator_state_sha"
    require_uuid '--coordinator-instance-id' "$coordinator_instance_id"
    require_uuid '--source-display-id' "$source_display_id"
    require_uuid '--target-device-id' "$target_device_id"
    [[ $marker_generation == 1 ]] || die 'failed-v1.3 terminal state must bind original generation 1'
    ((failed_v13_original_generation_only == 1)) ||
        die 'failed-v1.3 abort requires --failed-v13-original-generation-only'
    [[ $windows_user_sid =~ ^S-1-[0-9]+(-[0-9]+)+$ ]] || die 'invalid Windows SID'
    source_display_id_lower=$(lower_id "$source_display_id")
    target_device_id_lower=$(lower_id "$target_device_id")
    coordinator_instance_id_lower=$(lower_id "$coordinator_instance_id")
    v13_viewflow_unit="viewflow-v13-recovery-${operation_id}.service"
    v13_deskflow_unit="deskflow-v13-recovery-${operation_id}.service"
    validate_fd_gate_contract
    require_owner_only_regular 'old coordinator terminal state' "$coordinator_state"
    [[ $(sha256 "$coordinator_state") == "$old_coordinator_state_sha" ]] ||
        die 'old coordinator terminal state SHA differs before path derivation'
    assert_strict_json_document 'old coordinator terminal state' "$coordinator_state"
    state_request=$(jq -er '.contract.outputs.request | select(type == "string" and startswith("/"))' "$coordinator_state")
    state_stop=$(jq -er '.contract.outputs.windows_stop_evidence | select(type == "string" and startswith("/"))' "$coordinator_state")
    [[ -z $windows_bootstrap_request || $windows_bootstrap_request == "$state_request" ]] ||
        die 'caller bootstrap request path differs from immutable old state'
    [[ -z $local_windows_stop_evidence || $local_windows_stop_evidence == "$state_stop" ]] ||
        die 'caller Windows stop-evidence path differs from immutable old state'
    windows_bootstrap_request=$state_request
    local_windows_stop_evidence=$state_stop
    if [[ -n $fresh_operation_lineage_receipt || -n $fresh_operation_lineage_receipt_sha ]] &&
       jq -e '.phase == "WINDOWS_ROLLED_BACK" and
              .recovery == {failure_phase:"WINDOWS_FORCE_ATTESTED",mutation_possible:true}' \
          "$coordinator_state" >/dev/null; then
        post_force_pre_linux_stage_rollback_abort=1
        state_prepared=$(jq -er '.contract.outputs.prepared | select(type == "string" and startswith("/"))' "$coordinator_state")
        state_permit=$(jq -er '.contract.outputs.permit | select(type == "string" and startswith("/"))' "$coordinator_state")
        state_recovery=$(jq -er '.contract.outputs.recovery_bundle | select(type == "string" and startswith("/"))' "$coordinator_state")
        state_force=$(jq -er '.contract.outputs.force_envelope | select(type == "string" and startswith("/"))' "$coordinator_state")
        windows_prepared_receipt=$state_prepared
        windows_mutation_permit=$state_permit
        local_recovery_bundle=$state_recovery
        windows_force_envelope=$state_force
        [[ ! -e $(jq -er '.contract.outputs.linux_stage' "$coordinator_state") &&
           ! -L $(jq -er '.contract.outputs.linux_stage' "$coordinator_state") &&
           ! -e $(jq -er '.contract.outputs.windows_install' "$coordinator_state") &&
           ! -L $(jq -er '.contract.outputs.windows_install' "$coordinator_state") &&
           ! -e $(jq -er '.contract.outputs.windows_exit' "$coordinator_state") &&
           ! -L $(jq -er '.contract.outputs.windows_exit' "$coordinator_state") ]] ||
            die 'post-force pre-Linux-stage abort found forbidden LS/W/installer-exit output'
        require_sha256 '--post-force-abort-marker-cli-sha256' "$post_force_abort_marker_cli_sha"
        [[ $post_force_abort_marker_cli_candidate == /* &&
           $post_force_abort_marker_cli_candidate != "$MARKER_CLI" &&
           -f $post_force_abort_marker_cli_candidate && ! -L $post_force_abort_marker_cli_candidate &&
           $(stat -c '%u:%a:%h' -- "$post_force_abort_marker_cli_candidate") == 1000:755:1 &&
           $(sha256 "$post_force_abort_marker_cli_candidate") == "$post_force_abort_marker_cli_sha" ]] ||
            die 'post-force marker CLI candidate identity/hash is invalid'
    elif [[ -n $schema1_handoff_lineage_receipt || -n $schema1_handoff_lineage_receipt_sha ]]; then
        post_permit_rollback_abort=1
        state_prepared=$(jq -er '.contract.outputs.prepared | select(type == "string" and startswith("/"))' "$coordinator_state")
        state_permit=$(jq -er '.contract.outputs.permit | select(type == "string" and startswith("/"))' "$coordinator_state")
        state_exit=$(jq -er '.contract.outputs.windows_exit | select(type == "string" and startswith("/"))' "$coordinator_state")
        state_recovery=$(jq -er '.contract.outputs.recovery_bundle | select(type == "string" and startswith("/"))' "$coordinator_state")
        state_force=$(jq -er '.contract.outputs.force_envelope | select(type == "string" and startswith("/"))' "$coordinator_state")
        [[ -z $windows_prepared_receipt || $windows_prepared_receipt == "$state_prepared" ]] || die 'caller prepared path differs from post-permit state'
        [[ -z $windows_mutation_permit || $windows_mutation_permit == "$state_permit" ]] || die 'caller permit path differs from post-permit state'
        [[ -z $windows_installer_exit_receipt || $windows_installer_exit_receipt == "$state_exit" ]] || die 'caller installer-exit path differs from post-permit state'
        [[ -z $windows_force_envelope || $windows_force_envelope == "$state_force" ]] || die 'caller force-envelope path differs from post-permit state'
        windows_prepared_receipt=$state_prepared
        windows_mutation_permit=$state_permit
        windows_installer_exit_receipt=$state_exit
        windows_force_envelope=$state_force
        local_recovery_bundle=$state_recovery
        [[ ! -e $windows_force_envelope && ! -L $windows_force_envelope ]] ||
            die 'post-permit rollback abort refuses a force envelope that was never committed'
        require_sha256 '--schema1-handoff-abort-marker-cli-sha256' "$schema1_handoff_abort_marker_cli_sha"
        [[ $schema1_handoff_abort_marker_cli_candidate == /* &&
           $schema1_handoff_abort_marker_cli_candidate != "$MARKER_CLI" &&
           -f $schema1_handoff_abort_marker_cli_candidate && ! -L $schema1_handoff_abort_marker_cli_candidate &&
           $(stat -c '%u:%a:%h' -- "$schema1_handoff_abort_marker_cli_candidate") == 1000:755:1 &&
           $(sha256 "$schema1_handoff_abort_marker_cli_candidate") == "$schema1_handoff_abort_marker_cli_sha" ]] ||
            die 'schema1-handoff marker CLI candidate identity/hash is invalid'
    elif [[ -n $schema1_handoff_abort_marker_cli_candidate || -n $schema1_handoff_abort_marker_cli_sha ]]; then
        die 'schema1-handoff marker CLI candidate requires schema1-handoff lineage proof'
    fi
    if ((post_force_pre_linux_stage_rollback_abort == 0)) &&
       [[ -n $post_force_abort_marker_cli_candidate || -n $post_force_abort_marker_cli_sha ]]; then
        die 'post-force marker CLI candidate requires the exact fresh-operation post-force lineage'
    fi
    for path in "$bootstrap_handoff_receipt" "$deployment_publish_receipt" "$windows_bootstrap_request" \
        "$bootstrap_linux_evidence" "$local_windows_stop_evidence" "$local_windows_rollback_receipt" \
        "$linux_deactivation_proof"; do
        require_owner_only_regular 'failed-v1.3 terminal input' "$path"
    done
    if ((post_permit_rollback_abort || post_force_pre_linux_stage_rollback_abort)); then
        for path in "$windows_prepared_receipt" "$windows_mutation_permit" \
            "$local_recovery_bundle" "$linux_deactivation_transcript"; do
            require_owner_only_regular 'post-mutation rollback terminal input' "$path"
        done
        if ((post_permit_rollback_abort)); then
            require_owner_only_regular 'post-permit rollback installer exit' "$windows_installer_exit_receipt"
        else
            require_owner_only_regular 'post-force rollback force envelope' "$windows_force_envelope"
        fi
    else
        require_owner_only_regular 'failed-v1.3 force envelope' "$windows_force_envelope"
    fi
    windows_request_sha=$(sha256 "$windows_bootstrap_request")
    for path in "$deployment_abort_authorization" "$deployment_abort_receipt" \
        "$failed_v13_abort_transition_receipt" "$linux_v13_started_receipt" \
        "$windows_v13_started_receipt" "$authenticated_v13_peer_receipt"; do
        if [[ -e $path || -L $path ]]; then require_owner_only_regular 'failed-v1.3 durable output' "$path"
        else require_absolute_new_output 'failed-v1.3 durable output' "$path"; fi
    done
    [[ -f $MARKER_CLI && ! -L $MARKER_CLI ]] || die 'installed deployment marker CLI is unsafe'
    [[ ! -e ${DEPLOYMENT_MARKER}.release-claim ]] || die 'failed-v1.3 abort refuses a release claim'
    secure_dir=$(mktemp -d); chmod 0700 "$secure_dir"
    validate_failed_v13_terminal_state
    validate_failed_v13_baseline_evidence
    validate_failed_v13_slot_lineage_union
    select_failed_v13_abort_marker_tuple
    assert_failed_v13_original_generation_only
    if [[ $abort_marker_generation == "$marker_generation" ]]; then
        [[ ! -e $deployment_release_receipt ]] || die 'generation-1 abort refuses a normal VFDQR001 local receipt'
    else
        active_abort_sha=$published_marker_sha
        require_owner_only_regular 'pre-existing generation-1 release receipt' "$deployment_release_receipt"
        validate_publish_receipt "$deployment_publish_receipt" "$marker_generation" 0
        validate_release_receipt_v2 "${deployment_release_receipt}"
        published_marker_sha=$active_abort_sha
    fi
    if [[ -e $DEPLOYMENT_MARKER ]]; then
        assert_deployment_marker || die 'failed-v1.3 abort marker differs from selected publish receipt'
    else
        [[ -e $deployment_abort_authorization ]] || die 'active marker absent before durable abort authorization'
    fi
    [[ ! -e $RUNTIME_MARKER ]] || die 'failed-v1.3 abort refuses a runtime VFQST002 marker'
    if [[ ! -e $linux_v13_started_receipt ]]; then
        if [[ $(systemctl --user show --property LoadState --value "$v13_viewflow_unit" 2>/dev/null || true) == loaded ]]; then
            assert_adoptable_linux_v13_without_receipt
        else
            assert_linux_inactive
        fi
    fi
}

failed_v13_abort_main() {
    local temp bwrap_pid deskflow_pid core_pid state_before state_after deadline bwrap_ticks deskflow_ticks core_ticks
    local deskflow_invocation deskflow_cgroup bwrap_cgroup deskflow_process_cgroup core_cgroup
    local deskflow_expected_exec_start_sha deskflow_observed_exec_start_sha
    failed_v13_abort_preflight
    temp=$secure_dir/failed-v13-abort-transition.json
    state_before=$(sha256 "$coordinator_state")
    start_and_freeze_linux_v13
    validate_linux_v13_started
    start_and_freeze_windows_v13
    validate_windows_v13_started
    freeze_authenticated_v13_peer
    validate_authenticated_v13_peer
    start_and_freeze_linux_v13
    start_and_freeze_windows_v13
    validate_authenticated_v13_peer
    validate_failed_v13_terminal_state
    validate_failed_v13_baseline_evidence
    make_and_validate_abort_authorization
    abort_deployment_marker_transactionally
    reset_failed_deskflow_recovery_unit
    start_pinned_v13_transient_unit deskflow "$v13_deskflow_unit" "$DESKFLOW_INSTALLED" "$old_deskflow_sha"
    deadline=$((SECONDS + 60)); bwrap_pid=0
    while ((SECONDS < deadline)); do
        bwrap_pid=$(unit_main_pid "$v13_deskflow_unit")
        [[ $bwrap_pid =~ ^[1-9][0-9]*$ ]] && break
        sleep 0.1
    done
    [[ $bwrap_pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$bwrap_pid/exe") == "$FD_GATE_BWRAP_SHA256" ]] ||
        die 'restored Deskflow did not retain the exact Bubblewrap supervisor as MainPID'
    deadline=$((SECONDS + 60)); deskflow_pid=''
    while ((SECONDS < deadline)); do
        deskflow_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_sha")
        [[ $deskflow_pid =~ ^[1-9][0-9]*$ ]] && break
        sleep 0.1
    done
    [[ $deskflow_pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$deskflow_pid/exe") == "$old_deskflow_sha" ]] ||
        die 'restored Deskflow GUI did not start from exact sealed bytes'
    deadline=$((SECONDS + 60)); core_pid=''
    while ((SECONDS < deadline)); do
        core_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_core_sha")
        [[ $core_pid =~ ^[1-9][0-9]*$ ]] && break
        sleep 0.1
    done
    [[ $core_pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$core_pid/exe") == "$old_deskflow_core_sha" ]] ||
        die 'restored deskflow-core did not start with exact old executable'
    bwrap_ticks=$(process_start_ticks "$bwrap_pid"); deskflow_ticks=$(process_start_ticks "$deskflow_pid")
    core_ticks=$(process_start_ticks "$core_pid")
    deskflow_invocation=$(systemctl --user show --property InvocationID --value "$v13_deskflow_unit")
    deskflow_cgroup=$(systemctl --user show --property ControlGroup --value "$v13_deskflow_unit")
    bwrap_cgroup=$(process_control_group "$bwrap_pid"); deskflow_process_cgroup=$(process_control_group "$deskflow_pid")
    core_cgroup=$(process_control_group "$core_pid")
    deskflow_expected_exec_start_sha=$v13_deskflow_expected_exec_start_sha
    deskflow_observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_deskflow_unit")
    [[ $deskflow_expected_exec_start_sha == "$(expected_deskflow_v13_exec_start_sha)" &&
       $deskflow_observed_exec_start_sha == "$deskflow_expected_exec_start_sha" ]] ||
        die 'restored Deskflow manager ExecStart differs from fixed gate argv'
    [[ $deskflow_invocation =~ ^[0-9a-f]{32}$ && $deskflow_cgroup == "$bwrap_cgroup" &&
       $deskflow_cgroup == "$deskflow_process_cgroup" && $deskflow_cgroup == "$core_cgroup" &&
       $deskflow_cgroup == */"${v13_deskflow_unit}" &&
       $(systemctl --user show --property Transient --value "$v13_deskflow_unit") == yes &&
       $(systemctl --user show --property KillMode --value "$v13_deskflow_unit") == control-group &&
       $(systemctl --user show --property ActiveState --value "$v13_deskflow_unit") == active ]] ||
        die 'restored Deskflow transient unit/cgroup identity is invalid'
    process_descends_from "$deskflow_pid" "$bwrap_pid" || die 'Deskflow GUI is not descended from the pinned Bubblewrap MainPID'
    process_descends_from "$core_pid" "$deskflow_pid" || die 'deskflow-core is not descended from the pinned Deskflow GUI'
    state_after=$(sha256 "$coordinator_state")
    [[ $state_after == "$state_before" && $state_after == "$old_coordinator_state_sha" ]] ||
        die 'immutable old coordinator terminal state changed during abort recovery'
    jq -cn --arg op "$operation_id" --arg state "$state_after" --arg marker "$published_marker_sha" \
        --arg authorization "$(sha256 "$deployment_abort_authorization")" --arg abort "$(sha256 "$deployment_abort_receipt")" \
        --arg linux "$(sha256 "$linux_v13_started_receipt")" --arg windows "$(sha256 "$windows_v13_started_receipt")" \
        --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" \
        --arg deskflow_unit "$v13_deskflow_unit" --arg deskflow_invocation "$deskflow_invocation" \
        --arg deskflow_cgroup "$deskflow_cgroup" \
        --arg deskflow_expected_exec_start "$deskflow_expected_exec_start_sha" \
        --arg deskflow_observed_exec_start "$deskflow_observed_exec_start_sha" \
        --arg gate "$FD_GATE_DESKFLOW_PAYLOAD_SHA256" --arg bwrap "$FD_GATE_BWRAP_SHA256" \
        --arg deskflow_sha "$old_deskflow_sha" --arg core_sha "$old_deskflow_core_sha" \
        --argjson bwrap_pid "$bwrap_pid" --argjson bwrap_ticks "$bwrap_ticks" \
        --argjson deskflow_pid "$deskflow_pid" \
        --argjson deskflow_ticks "$deskflow_ticks" --argjson core_pid "$core_pid" --argjson core_ticks "$core_ticks" '
        {schema_version:1,state:"viewflow-failed-v1.3-bootstrap-abort-terminal",operation_id:$op,
         protocol_version:"1.3",protocol_2_1:false,normal_deployment_release:false,
         old_coordinator_terminal_state_sha256:$state,deployment_marker_sha256:$marker,
         abort_authorization_sha256:$authorization,deployment_abort_receipt_sha256:$abort,
         linux_v13_started_receipt_sha256:$linux,windows_v13_started_receipt_sha256:$windows,
         authenticated_v13_peer_receipt_sha256:$authenticated,linux_viewflow_unit_state:"active",
         linux_deskflow_unit_state:"active",linux_deskflow_unit:$deskflow_unit,
         linux_deskflow_invocation_id:$deskflow_invocation,linux_deskflow_control_group:$deskflow_cgroup,
         linux_deskflow_expected_exec_start_sha256:$deskflow_expected_exec_start,
         linux_deskflow_exec_start_sha256:$deskflow_observed_exec_start,
         fd_gate_payload_sha256:$gate,bubblewrap_sha256:$bwrap,
         linux_deskflow_executable_sha256:$deskflow_sha,linux_deskflow_core_executable_sha256:$core_sha,
         linux_deskflow_runtime_path:"/tmp/viewflow-deskflow-recovery/deskflow",
         linux_deskflow_core_runtime_path:"/tmp/viewflow-deskflow-recovery/deskflow-core",
         sealed_sibling_directory_read_only:true,
         linux_deskflow_main_pid:$bwrap_pid,linux_deskflow_main_start_ticks:$bwrap_ticks,
         linux_deskflow_runtime_pid:$deskflow_pid,linux_deskflow_runtime_start_ticks:$deskflow_ticks,
         linux_deskflow_core_pid:$core_pid,linux_deskflow_core_start_ticks:$core_ticks}
    ' >"$temp"
    validate_live_deskflow_recovery_tuple "$v13_deskflow_unit" "$bwrap_pid" "$bwrap_ticks" \
        "$deskflow_pid" "$deskflow_ticks" "$core_pid" "$core_ticks" "$deskflow_invocation" \
        "$deskflow_cgroup" "$deskflow_expected_exec_start_sha" "$state_after"
    publish_recovery_json_once 'failed-v1.3 abort terminal transition' "$temp" "$failed_v13_abort_transition_receipt"
    printf 'failed v1.3 bootstrap recovery completed; VFDQA001 abort and fresh authenticated v1.3 baseline passed\n'
}

publish_pre_mutation_abort_terminal() {
    local temp=$secure_dir/pre-mutation-abort-transition.json state_after deadline
    local bwrap_pid=0 deskflow_pid='' core_pid='' bwrap_ticks deskflow_ticks core_ticks
    local deskflow_invocation deskflow_cgroup bwrap_cgroup deskflow_process_cgroup core_cgroup
    local deskflow_expected_exec_start_sha deskflow_observed_exec_start_sha
    reset_failed_deskflow_recovery_unit
    start_pinned_v13_transient_unit deskflow "$v13_deskflow_unit" "$DESKFLOW_INSTALLED" "$old_deskflow_sha"
    deadline=$((SECONDS + 60))
    while ((SECONDS < deadline)); do
        bwrap_pid=$(unit_main_pid "$v13_deskflow_unit")
        [[ $bwrap_pid =~ ^[1-9][0-9]*$ ]] && break
        sleep 0.1
    done
    [[ $bwrap_pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$bwrap_pid/exe") == "$FD_GATE_BWRAP_SHA256" ]] ||
        die 'pre-mutation restored Deskflow lacks exact Bubblewrap MainPID'
    deadline=$((SECONDS + 60))
    while ((SECONDS < deadline)); do
        deskflow_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_sha")
        [[ $deskflow_pid =~ ^[1-9][0-9]*$ ]] && break
        sleep 0.1
    done
    [[ $deskflow_pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$deskflow_pid/exe") == "$old_deskflow_sha" ]] ||
        die 'pre-mutation restored Deskflow GUI identity is invalid'
    deadline=$((SECONDS + 60))
    while ((SECONDS < deadline)); do
        core_pid=$(cgroup_executable_sha_pids "$v13_deskflow_unit" "$old_deskflow_core_sha")
        [[ $core_pid =~ ^[1-9][0-9]*$ ]] && break
        sleep 0.1
    done
    [[ $core_pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$core_pid/exe") == "$old_deskflow_core_sha" ]] ||
        die 'pre-mutation restored deskflow-core identity is invalid'
    bwrap_ticks=$(process_start_ticks "$bwrap_pid"); deskflow_ticks=$(process_start_ticks "$deskflow_pid")
    core_ticks=$(process_start_ticks "$core_pid")
    deskflow_invocation=$(systemctl --user show --property InvocationID --value "$v13_deskflow_unit")
    deskflow_cgroup=$(systemctl --user show --property ControlGroup --value "$v13_deskflow_unit")
    bwrap_cgroup=$(process_control_group "$bwrap_pid"); deskflow_process_cgroup=$(process_control_group "$deskflow_pid")
    core_cgroup=$(process_control_group "$core_pid")
    deskflow_expected_exec_start_sha=$v13_deskflow_expected_exec_start_sha
    deskflow_observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_deskflow_unit")
    [[ $deskflow_expected_exec_start_sha == "$(expected_deskflow_v13_exec_start_sha)" &&
       $deskflow_observed_exec_start_sha == "$deskflow_expected_exec_start_sha" ]] ||
        die 'pre-mutation restored Deskflow ExecStart differs from fixed sealed gate'
    [[ $deskflow_invocation =~ ^[0-9a-f]{32}$ && $deskflow_cgroup == "$bwrap_cgroup" &&
       $deskflow_cgroup == "$deskflow_process_cgroup" && $deskflow_cgroup == "$core_cgroup" &&
       $deskflow_cgroup == */"${v13_deskflow_unit}" &&
       $(systemctl --user show --property Transient --value "$v13_deskflow_unit") == yes &&
       $(systemctl --user show --property KillMode --value "$v13_deskflow_unit") == control-group &&
       $(systemctl --user show --property ActiveState --value "$v13_deskflow_unit") == active ]] ||
        die 'pre-mutation restored Deskflow transient tuple is invalid'
    process_descends_from "$deskflow_pid" "$bwrap_pid" || die 'restored Deskflow GUI parent differs'
    process_descends_from "$core_pid" "$deskflow_pid" || die 'restored deskflow-core parent differs'
    validate_linux_v13_started
    validate_pre_mutation_windows_v13_started
    validate_authenticated_v13_peer
    validate_pre_mutation_failed_terminal_state
    state_after=$(sha256 "$coordinator_state")
    [[ $state_after == "$old_coordinator_state_sha" ]] || die 'pre-mutation coordinator terminal state changed'
    jq -cn --arg op "$operation_id" --arg state_sha "$state_after" --arg marker "$published_marker_sha" \
        --arg exit "$(sha256 "$windows_installer_exit_receipt")" --arg stop "$(sha256 "$local_windows_stop_evidence")" \
        --arg retry "$(sha256 "$pre_mutation_retry_proof")" --arg live "$(sha256 "$pre_mutation_windows_live_proof")" \
        --arg authorization "$(sha256 "$deployment_abort_authorization")" --arg abort "$(sha256 "$deployment_abort_receipt")" \
        --arg linux "$(sha256 "$linux_v13_started_receipt")" --arg windows "$(sha256 "$windows_v13_started_receipt")" \
        --arg authenticated "$(sha256 "$authenticated_v13_peer_receipt")" \
        --arg unit "$v13_deskflow_unit" --arg invocation "$deskflow_invocation" --arg cgroup "$deskflow_cgroup" \
        --arg expected_exec "$deskflow_expected_exec_start_sha" --arg observed_exec "$deskflow_observed_exec_start_sha" \
        --arg deskflow "$old_deskflow_sha" --arg core "$old_deskflow_core_sha" \
        --argjson bwrap_pid "$bwrap_pid" --argjson bwrap_ticks "$bwrap_ticks" \
        --argjson deskflow_pid "$deskflow_pid" --argjson deskflow_ticks "$deskflow_ticks" \
        --argjson core_pid "$core_pid" --argjson core_ticks "$core_ticks" '
        {schema_version:2,state:"viewflow-failed-pre-mutation-installer-baseline-restored-abort-terminal",
         operation_id:$op,protocol_version:"1.3",protocol_2_1:false,normal_deployment_release:false,
         initial_force_release_executed:false,rollback_performed:false,windows_rollback_receipt_sha256:null,
         old_coordinator_terminal_state_sha256:$state_sha,deployment_marker_sha256:$marker,
         installer_exit_receipt_sha256:$exit,windows_stop_evidence_sha256:$stop,
         pre_mutation_retry_receipt_sha256:$retry,windows_live_proof_sha256:$live,
         abort_authorization_sha256:$authorization,deployment_abort_receipt_sha256:$abort,
         linux_v13_started_receipt_sha256:$linux,windows_v13_started_receipt_sha256:$windows,
         authenticated_v13_peer_receipt_sha256:$authenticated,linux_viewflow_unit_state:"active",
         linux_deskflow_unit_state:"active",linux_deskflow_unit:$unit,linux_deskflow_invocation_id:$invocation,
         linux_deskflow_control_group:$cgroup,linux_deskflow_expected_exec_start_sha256:$expected_exec,
         linux_deskflow_exec_start_sha256:$observed_exec,linux_deskflow_executable_sha256:$deskflow,
         linux_deskflow_core_executable_sha256:$core,linux_deskflow_main_pid:$bwrap_pid,
         linux_deskflow_main_start_ticks:$bwrap_ticks,linux_deskflow_runtime_pid:$deskflow_pid,
         linux_deskflow_runtime_start_ticks:$deskflow_ticks,linux_deskflow_core_pid:$core_pid,
         linux_deskflow_core_start_ticks:$core_ticks}
    ' >"$temp"
    validate_live_deskflow_recovery_tuple "$v13_deskflow_unit" "$bwrap_pid" "$bwrap_ticks" \
        "$deskflow_pid" "$deskflow_ticks" "$core_pid" "$core_ticks" "$deskflow_invocation" \
        "$deskflow_cgroup" "$deskflow_expected_exec_start_sha" "$state_after"
    publish_recovery_json_once 'pre-mutation failed-v1.3 abort terminal' "$temp" "$failed_v13_abort_transition_receipt"
}

failed_v13_pre_mutation_abort_main() {
    failed_v13_pre_mutation_abort_preflight
    start_and_freeze_linux_v13
    validate_linux_v13_started
    freeze_pre_mutation_windows_v13
    validate_pre_mutation_windows_v13_started
    freeze_authenticated_v13_peer
    validate_authenticated_v13_peer
    validate_pre_mutation_failed_terminal_state
    validate_pre_mutation_failed_baseline
    assert_pre_mutation_outputs_absent
    make_and_validate_pre_mutation_abort_authorization
    abort_pre_mutation_deployment_marker_transactionally
    publish_pre_mutation_abort_terminal
    printf 'failed pre-mutation installer baseline recovery completed; truthful schema-2 VFDQA001 and authenticated v1.3 baseline passed\n'
}

lower_id() { printf '%s\n' "${1//-/}"; }

process_start_ticks() {
    local pid=$1 tail
    tail=$(sed -n 's/^[0-9][0-9]* (.*) //p' "/proc/$pid/stat")
    printf '%s\n' "$tail" | awk '{print $20}'
}

validate_provenance() {
    assert_strict_json_document 'Deskflow provenance manifest' "$deskflow_provenance_manifest"
    jq -e --arg protocol "$REQUIRED_PROTOCOL" --argjson sidecar "$REQUIRED_SIDECAR_PROTOCOL" '
        (keys == ["artifacts","build","generated_at_utc","kind","protocol_version","schema_version","sidecar_protocol_version","source","upstream"]) and
        .protocol_version == $protocol and .sidecar_protocol_version == $sidecar
    ' "$deskflow_provenance_manifest" >/dev/null || die 'Deskflow provenance protocol 2.1/sidecar 3 contract is invalid'
}

ssh_windows() {
    local encoded
    encoded=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
    ssh -F /dev/null -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" "$WINDOWS_SSH_TARGET" \
        powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded"
}

ssh_windows_stdin() {
    local payload bootstrap
    payload=$(printf '%s' "$1" | base64 -w0)
    bootstrap="\$ErrorActionPreference='Stop';\$priorOut=[Console]::Out;\$buffer=[IO.StringWriter]::new([Globalization.CultureInfo]::InvariantCulture);[Console]::SetOut(\$buffer);try{\$source=[Text.UTF8Encoding]::new(\$false,\$true).GetString([Convert]::FromBase64String('$payload'));\$values=@(&([ScriptBlock]::Create(\$source)));[Console]::SetOut(\$priorOut);[Console]::Out.Write(\$buffer.ToString());if(\$values.Count-ne0){[Console]::Out.Write([string]::Join([Environment]::NewLine,@(\$values|ForEach-Object{[string]\$_})))};exit 0}catch{[Console]::SetOut(\$priorOut);[Console]::Error.WriteLine(\$_.Exception.Message);exit 1}finally{[Console]::SetOut(\$priorOut);\$buffer.Dispose()}"
    printf '%s' "$bootstrap" | ssh -F /dev/null -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" "$WINDOWS_SSH_TARGET" \
        powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -
}

windows_read_file() {
    local remote=$1 destination=$2 encoded temp canonical
    encoded=$(ssh_windows "\$p='$remote';[Console]::Out.Write([Convert]::ToBase64String([IO.File]::ReadAllBytes(\$p)))")
    [[ $encoded =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] ||
        die 'Windows remote file response is not canonical Base64'
    temp=$(mktemp --tmpdir="$(dirname -- "$destination")" '.viewflow-windows-read.XXXXXX')
    chmod 0600 "$temp"
    if ! printf '%s' "$encoded" | base64 --decode >"$temp"; then
        rm -f -- "$temp"
        die 'Windows remote file response cannot be decoded as Base64'
    fi
    canonical=$(base64 -w0 -- "$temp")
    [[ $canonical == "$encoded" ]] || {
        rm -f -- "$temp"
        die 'Windows remote file response has noncanonical Base64 padding'
    }
    publish_new_file "$temp" "$destination"
    rm -f -- "$temp"
}

windows_create_file() {
    local source=$1 remote=$2 expected upload_id upload_remote upload_scp
    expected=$(sha256 "$source")
    upload_id=$(printf '%s:%s:%s:%s' "$operation_id" "$BASHPID" "$RANDOM" "$(date +%s%N)" | sha256sum)
    upload_id=${upload_id%% *}
    upload_remote="$remote.upload-$upload_id"
    upload_scp=${upload_remote//\\//}
    scp -F /dev/null -q -o "$SSH_BATCH_OPTION" -o "$SSH_HOST_KEY_OPTION" -- "$source" \
        "$WINDOWS_SSH_TARGET:$upload_scp"
    ssh_windows \
        "\$tmp='$upload_remote';\$dest='$remote';try{\$item=Get-Item -LiteralPath \$tmp -Force -ErrorAction Stop;if(\$item.PSIsContainer-or(\$item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'unsafe Viewflow upload'};\$actual=(Get-FileHash -LiteralPath \$tmp -Algorithm SHA256).Hash.ToLowerInvariant();if(\$actual-ne'$expected'){throw 'Viewflow upload hash mismatch'};\$acl=New-Object Security.AccessControl.FileSecurity;\$sid=New-Object Security.Principal.SecurityIdentifier('$windows_user_sid');\$acl.SetOwner(\$sid);\$acl.SetAccessRuleProtection(\$true,\$false);\$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(\$sid,'FullControl','Allow')));Set-Acl -LiteralPath \$tmp -AclObject \$acl;[IO.File]::Move(\$tmp,\$dest)}finally{if(Test-Path -LiteralPath \$tmp){Remove-Item -LiteralPath \$tmp -Force}}"
}

windows_create_or_verify() {
    local source=$1 remote=$2 expected remote_hash
    expected=$(sha256 "$source")
    if windows_remote_exists "$remote"; then
        remote_hash=$(ssh_windows "[Console]::Out.Write((Get-FileHash -LiteralPath '$remote' -Algorithm SHA256).Hash.ToLowerInvariant())")
        require_sha256 "remote staged input hash $remote" "$remote_hash"
        [[ $remote_hash == "$expected" ]] ||
            die "remote staged input changed: $remote"
    else
        windows_create_file "$source" "$remote"
    fi
}

validate_rollback_snapshots() {
    local common bootstrap normal authorized_manifest authorized_token
    assert_strict_json_document 'remote rollback manifest snapshot' "$remote_manifest_snapshot"
    assert_strict_json_document 'remote rollback token snapshot' "$remote_token_snapshot"
    remote_manifest_sha=$(sha256 "$remote_manifest_snapshot")
    remote_token_sha=$(sha256 "$remote_token_snapshot")
    authorized_manifest=$(jq -er '.rollback_authorization.manifest_sha256' "$windows_prepared_receipt")
    authorized_token=$(jq -er '.rollback_authorization.token_sha256' "$windows_prepared_receipt")
    [[ $remote_manifest_sha == "$authorized_manifest" && $remote_token_sha == "$authorized_token" ]] ||
        die 'rollback manifest/token bytes differ from P authorization'
    rollback_mode=$(jq -er '.rollback_mode' "$remote_manifest_snapshot")
    common='["backup","candidate_sha256","created_at_utc","expected_deactivation_evidence_type","force_release_tool","installed","operation_id","recovery_bundle_path","recovery_force_release_receipt_path","rollback_mode","rollback_nonce","schema_version","state","task_name","token_path","token_sha256","user_sid"]'
    bootstrap='["linux_deactivation_proof_path","linux_deactivation_transcript_path"]'
    normal='["daemon_exit_evidence_path","daemon_exit_observation_path","runtime_receipt_path"]'
    jq -e --arg op "$operation_id" --arg sid "$windows_user_sid" --arg mode "$rollback_mode" \
        --arg token_path "$windows_rollback_token_path" --arg token_sha "$remote_token_sha" \
        --arg bundle "$windows_recovery_bundle_path" --arg force "$windows_recovery_force_receipt_path" \
        --arg proof "$windows_operation_root\\linux-deactivation-proof.json" \
        --arg transcript "$windows_operation_root\\linux-deactivation-transcript.json" \
        --arg runtime "$windows_operation_root\\runtime-receipt.json" \
        --arg evidence "$windows_operation_root\\daemon-exit-evidence.json" \
        --arg observation "$windows_operation_root\\daemon-exit-observation.json" \
        --argjson common "$common" --argjson bootstrap "$bootstrap" --argjson normal "$normal" '
        .schema_version == 2 and .state == "viewflow-windows-rollback-armed" and .operation_id == $op and .user_sid == $sid and
        .rollback_mode == $mode and .token_path == $token_path and .token_sha256 == $token_sha and
        .recovery_bundle_path == $bundle and .recovery_force_release_receipt_path == $force and
        (keys == (($common + (if $mode == "bootstrap-v1.3" then $bootstrap else $normal end)) | sort)) and
        (if $mode == "bootstrap-v1.3" then
            .expected_deactivation_evidence_type == "schema_version=3;state=viewflow-linux-deactivated" and
            .linux_deactivation_proof_path == $proof and .linux_deactivation_transcript_path == $transcript
         elif $mode == "normal-v2" then
            .expected_deactivation_evidence_type == "schema_version=4;state=viewflow-input-quiesced;schema_version=1;state=viewflow-daemon-exited;schema_version=1;state=viewflow-daemon-exit-observation" and
            .runtime_receipt_path == $runtime and .daemon_exit_evidence_path == $evidence and
            .daemon_exit_observation_path == $observation
         else false end)
    ' "$remote_manifest_snapshot" >/dev/null || die 'rollback manifest exact discriminated union is invalid'
    jq -e --arg op "$operation_id" --arg sid "$windows_user_sid" --arg mode "$rollback_mode" '
        (keys == ["created_at_utc","nonce","operation_id","rollback_mode","schema_version","state","user_sid"]) and
        .schema_version == 1 and .state == "viewflow-windows-rollback-authorized" and
        .rollback_mode == $mode and .operation_id == $op and .user_sid == $sid and (.nonce | test("^[0-9a-f]{64}$"))
    ' "$remote_token_snapshot" >/dev/null || die 'rollback token exact schema is invalid'
}

prearm_windows_recovery() {
    local remote_hash local_hash expected_consumed_token_path
    remote_hash=$(ssh_windows "[Console]::Out.Write((Get-FileHash -LiteralPath '$WINDOWS_ROLLBACK_SCRIPT' -Algorithm SHA256).Hash.ToLowerInvariant())")
    require_sha256 'remote rollback consumer hash' "$remote_hash"
    local_hash=$(sha256 "$reviewed_rollback_script")
    [[ $remote_hash == "$local_hash" ]] || die 'remote rollback consumer differs from reviewed local bytes'
    windows_read_file "$windows_rollback_manifest_path" "$remote_manifest_snapshot"
    if windows_remote_exists "$windows_rollback_receipt_path"; then
        [[ $windows_rollback_token_path == *.json ]] ||
            die 'rollback token path lacks the frozen JSON suffix'
        expected_consumed_token_path="${windows_rollback_token_path%.json}.consumed.${operation_id}.json"
        windows_remote_exists "$windows_rollback_token_path" &&
            die 'terminal rollback receipt coexists with an unconsumed authorization token'
        windows_read_file "$expected_consumed_token_path" "$remote_token_snapshot"
    else
        windows_read_file "$windows_rollback_token_path" "$remote_token_snapshot"
    fi
    validate_rollback_snapshots
}

capture_old_linux_hashes() {
    old_viewflow_sha=$(sha256 "$VIEWFLOW_INSTALLED")
    old_deskflow_sha=$(sha256 "$DESKFLOW_INSTALLED")
    old_deskflow_core_sha=$(sha256 "$DESKFLOW_CORE_INSTALLED")
    old_marker_cli_sha=$(sha256 "$MARKER_CLI")
    old_viewflow_unit_sha=$(sha256 "$VIEWFLOW_UNIT_INSTALLED")
    old_deskflow_dropin_sha=$(sha256 "$DESKFLOW_DROPIN_INSTALLED")
}

assert_old_linux_hashes() {
    [[ $(sha256 "$VIEWFLOW_INSTALLED") == "$old_viewflow_sha" &&
       $(sha256 "$DESKFLOW_INSTALLED") == "$old_deskflow_sha" &&
       $(sha256 "$DESKFLOW_CORE_INSTALLED") == "$old_deskflow_core_sha" &&
       $(sha256 "$MARKER_CLI") == "$old_marker_cli_sha" &&
       $(sha256 "$VIEWFLOW_UNIT_INSTALLED") == "$old_viewflow_unit_sha" &&
       $(sha256 "$DESKFLOW_DROPIN_INSTALLED") == "$old_deskflow_dropin_sha" ]]
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

cgroup_executable_sha_pids() {
    local unit=$1 expected_sha=$2 cgroup pid actual
    cgroup=$(systemctl --user show --property ControlGroup --value "$unit")
    [[ $cgroup == /* && -r /sys/fs/cgroup${cgroup}/cgroup.procs ]] || return 0
    while IFS= read -r pid; do
        [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/exe ]] || continue
        actual=$(sha256 "/proc/$pid/exe" 2>/dev/null || true)
        [[ $actual == "$expected_sha" ]] && printf '%s\n' "$pid"
    done </sys/fs/cgroup${cgroup}/cgroup.procs
    return 0
}

process_control_group() { awk -F: '$1 == "0" {print $3}' "/proc/$1/cgroup"; }
process_descends_from() {
    local child=$1 ancestor=$2 parent depth=0
    while [[ $child =~ ^[1-9][0-9]*$ && $child != 1 && $depth -lt 64 ]]; do
        [[ $child == "$ancestor" ]] && return 0
        parent=$(awk '/^PPid:/ {print $2}' "/proc/$child/status" 2>/dev/null || true)
        [[ $parent =~ ^[1-9][0-9]*$ ]] || return 1
        child=$parent
        depth=$((depth + 1))
    done
    [[ $child == "$ancestor" ]]
}

validate_live_deskflow_recovery_tuple() {
    local unit=$1 bwrap_pid=$2 bwrap_ticks=$3 deskflow_pid=$4 deskflow_ticks=$5
    local core_pid=$6 core_ticks=$7 invocation=$8 cgroup=$9 expected_exec_start=${10} state_sha=${11}
    [[ $(unit_main_pid "$unit") == "$bwrap_pid" &&
       $(process_start_ticks "$bwrap_pid") == "$bwrap_ticks" &&
       $(process_start_ticks "$deskflow_pid") == "$deskflow_ticks" &&
       $(process_start_ticks "$core_pid") == "$core_ticks" &&
       $(sha256 "/proc/$bwrap_pid/exe") == "$FD_GATE_BWRAP_SHA256" &&
       $(sha256 "/proc/$deskflow_pid/exe") == "$old_deskflow_sha" &&
       $(sha256 "/proc/$core_pid/exe") == "$old_deskflow_core_sha" &&
       $(cgroup_executable_sha_pids "$unit" "$FD_GATE_BWRAP_SHA256") == "$bwrap_pid" &&
       $(cgroup_executable_sha_pids "$unit" "$old_deskflow_sha") == "$deskflow_pid" &&
       $(cgroup_executable_sha_pids "$unit" "$old_deskflow_core_sha") == "$core_pid" &&
       $(systemctl --user show --property InvocationID --value "$unit") == "$invocation" &&
       $(systemctl --user show --property ControlGroup --value "$unit") == "$cgroup" &&
       $(process_control_group "$bwrap_pid") == "$cgroup" &&
       $(process_control_group "$deskflow_pid") == "$cgroup" &&
       $(process_control_group "$core_pid") == "$cgroup" &&
       $(systemctl --user show --property ActiveState --value "$unit") == active &&
       $(systemctl --user show --property SubState --value "$unit") == running &&
       $(systemctl --user show --property Transient --value "$unit") == yes &&
       $(systemctl --user show --property KillMode --value "$unit") == control-group &&
       $(observed_transient_exec_start_sha "$unit") == "$expected_exec_start" &&
       $(sha256 "$coordinator_state") == "$state_sha" ]] ||
        die 'Deskflow live recovery tuple changed before terminal receipt publication'
    process_descends_from "$deskflow_pid" "$bwrap_pid" ||
        die 'Deskflow GUI ancestry changed before terminal receipt publication'
    process_descends_from "$core_pid" "$deskflow_pid" ||
        die 'deskflow-core ancestry changed before terminal receipt publication'
}

unit_main_pid() { systemctl --user show --property MainPID --value "$1"; }

assert_linux_inactive() {
    local deskflow_pids viewflow_pids core_pids
    [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) == inactive &&
       $(unit_main_pid "$DESKFLOW_UNIT") == 0 &&
       $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == inactive &&
       $(unit_main_pid "$VIEWFLOW_UNIT") == 0 ]]
    deskflow_pids=$(exact_executable_pids "$DESKFLOW_INSTALLED")
    viewflow_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
    core_pids=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    [[ -z $deskflow_pids && -z $viewflow_pids && -z $core_pids &&
       -z $(ss -H -ltn "sport = :$DESKFLOW_PORT" 2>/dev/null) &&
       -z $(ss -H -lun "sport = :$VIEWFLOW_PORT" 2>/dev/null) && ! -e $VIEWFLOW_SIDECAR ]]
}

assert_adoptable_linux_v13_without_receipt() {
    local pid expected_exec_start_sha observed_exec_start_sha control_group process_cgroup
    local proc argv0 viewflow_runtime_pids='' udp_listener sidecar_listener
    pid=$(unit_main_pid "$v13_viewflow_unit")
    expected_exec_start_sha=$(expected_viewflow_v13_exec_start_sha)
    observed_exec_start_sha=$(observed_transient_exec_start_sha "$v13_viewflow_unit")
    control_group=$(systemctl --user show --property ControlGroup --value "$v13_viewflow_unit")
    process_cgroup=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")
    for proc in /proc/[0-9]*; do
        [[ -r $proc/cmdline && -e $proc/exe ]] || continue
        argv0=$(tr '\0' '\n' <"$proc/cmdline" | head -n 1)
        [[ $argv0 == "$VIEWFLOW_INSTALLED" ]] || continue
        [[ $(sha256 "$proc/exe" 2>/dev/null || true) == "$old_viewflow_sha" ]] || continue
        viewflow_runtime_pids+="${proc##*/}"$'\n'
    done
    viewflow_runtime_pids=${viewflow_runtime_pids%$'\n'}
    udp_listener=$(ss -H -lunp "sport = :$VIEWFLOW_PORT" 2>/dev/null)
    sidecar_listener=$(ss -H -xlpn 2>/dev/null | grep -F -- "$VIEWFLOW_SIDECAR" || true)
    [[ $pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$pid/exe") == "$old_viewflow_sha" &&
       $observed_exec_start_sha == "$expected_exec_start_sha" &&
       $control_group == "$process_cgroup" && $control_group == */"${v13_viewflow_unit}" &&
       $(systemctl --user show --property ActiveState --value "$v13_viewflow_unit") == active &&
       $(systemctl --user show --property SubState --value "$v13_viewflow_unit") == running &&
       $(systemctl --user show --property Transient --value "$v13_viewflow_unit") == yes &&
       $(systemctl --user show --property KillMode --value "$v13_viewflow_unit") == control-group &&
       $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == inactive &&
       $(unit_main_pid "$VIEWFLOW_UNIT") == 0 && $viewflow_runtime_pids == "$pid" &&
       $udp_listener != *$'\n'* && $udp_listener == *"pid=$pid,"* &&
       $sidecar_listener != *$'\n'* && $sidecar_listener == *"pid=$pid,"* &&
       -z $(exact_executable_pids "$DESKFLOW_INSTALLED") &&
       -z $(exact_executable_pids "$DESKFLOW_CORE_INSTALLED") &&
       -z $(ss -H -ltn "sport = :$DESKFLOW_PORT" 2>/dev/null) ]] ||
        die 'receipt-less Linux v1.3 transient is not the exact adoptable recovery unit'
}

assert_deployment_marker() {
    [[ -f $DEPLOYMENT_MARKER && ! -L $DEPLOYMENT_MARKER &&
       $(stat -c '%u:%a:%h:%s' -- "$DEPLOYMENT_MARKER") == 1000:600:1:256 ]] || return 1
    [[ $(dd if="$DEPLOYMENT_MARKER" bs=8 count=1 status=none) == VFDQT001 &&
       $(sha256 "$DEPLOYMENT_MARKER") == "$published_marker_sha" ]]
}

assert_runtime_marker_retained() {
    [[ -f $RUNTIME_MARKER && ! -L $RUNTIME_MARKER &&
       $(stat -c '%u:%a:%h:%s' -- "$RUNTIME_MARKER") == 1000:600:1:152 ]] || return 1
    [[ $(dd if="$RUNTIME_MARKER" bs=8 count=1 status=none) == VFQST002 ]]
}

validate_publish_receipt() {
    local path=$1 generation=$2 require_active=${3:-1} expected_operation=${4:-$operation_id}
    assert_strict_json_document 'deployment marker publish receipt' "$path"
    jq -e --arg op "$expected_operation" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg coordinator "$coordinator_instance_id" --arg generation "$generation" --arg marker "$DEPLOYMENT_MARKER" '
        (keys == ["coordinator_instance_id","created_at_unix_ms","created_at_utc","marker_generation","marker_path","marker_sha256","operation_id","protocol_version","schema_version","source_display_id","state","target_device_id"]) and
        .schema_version == 1 and .state == "deployment-quarantine-published" and .protocol_version == "2.1" and
        .operation_id == $op and .source_display_id == $source and .target_device_id == $target and
        .coordinator_instance_id == $coordinator and .marker_generation == $generation and .marker_path == $marker and
        (.marker_sha256 | test("^[0-9a-f]{64}$")) and (.created_at_unix_ms | test("^[1-9][0-9]*$"))
    ' "$path" >/dev/null || die 'deployment marker publish receipt is invalid'
    published_marker_sha=$(jq -er '.marker_sha256' "$path")
    ((require_active == 0)) || assert_deployment_marker || die 'VFDQT001 bytes do not match their publish receipt'
}

publish_deployment_marker() {
    local temp
    require_absolute_new_output '--deployment-publish-receipt' "$deployment_publish_receipt"
    temp=$(mktemp --tmpdir="$(dirname -- "$deployment_publish_receipt")" '.viewflow-publish.XXXXXX')
    chmod 0600 "$temp"
    recovery_required=1
    phase=RECOVERY_ARMED
    marker_cli publish --operation-id "$operation_id" --source-display-id "$source_display_id" \
        --target-device-id "$target_device_id" --coordinator-instance-id "$coordinator_instance_id" \
        --marker-generation "$marker_generation" >"$temp"
    validate_publish_receipt "$temp" "$marker_generation"
    publish_new_file "$temp" "$deployment_publish_receipt"
    rm -f -- "$temp"
}

ensure_recovery_publish_intent() {
    local temp=$secure_dir/recovery-publish-intent.json
    if [[ ! -e $recovery_publish_intent ]]; then
        jq -cn --arg op "$recovery_operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
            --arg coordinator "$coordinator_instance_id" --arg generation "$recovery_marker_generation" \
            '{schema_version:1,state:"viewflow-recovery-marker-publish-intent",operation_id:$op,
              source_display_id:$source,target_device_id:$target,coordinator_instance_id:$coordinator,
              marker_generation:$generation}' >"$temp"
        publish_json_file 'recovery marker publish intent' "$temp" "$recovery_publish_intent"
    fi
    jq -e --arg op "$recovery_operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg coordinator "$coordinator_instance_id" --arg generation "$recovery_marker_generation" '
        keys == ["coordinator_instance_id","marker_generation","operation_id","schema_version","source_display_id","state","target_device_id"] and
        .schema_version == 1 and .state == "viewflow-recovery-marker-publish-intent" and
        .operation_id == $op and .source_display_id == $source and .target_device_id == $target and
        .coordinator_instance_id == $coordinator and .marker_generation == $generation
    ' "$recovery_publish_intent" >/dev/null || die 'recovery marker publish intent changed'
}

adopt_active_recovery_marker() {
    local marker_sha=$1 query=$secure_dir/recovery-marker-query.json op_len embedded_op source_hex target_hex coordinator_hex generation created seconds millis utc temp
    capture_json_command 'recovery marker active query' "$query" marker_cli query \
        --operation-id "$recovery_operation_id" --coordinator-instance-id "$coordinator_instance_id" \
        --marker-generation "$recovery_marker_generation" --marker-sha256 "$marker_sha"
    jq -e --arg op "$recovery_operation_id" --arg generation "$recovery_marker_generation" --arg sha "$marker_sha" '
        keys == ["marker_generation","marker_sha256","operation_id","protocol_version","schema_version","state"] and
        .schema_version == 2 and .state == "deployment-quarantine-active" and .protocol_version == "2.1" and
        .operation_id == $op and .marker_generation == $generation and .marker_sha256 == $sha
    ' "$query" >/dev/null || die 'lost recovery publish reply did not leave the exact active tuple'
    [[ $(dd if="$DEPLOYMENT_MARKER" bs=8 count=1 status=none) == VFDQT001 ]] || die 'recovery marker magic is invalid'
    op_len=$(od -An -tu1 -j13 -N1 "$DEPLOYMENT_MARKER" | tr -d ' ')
    embedded_op=$(dd if="$DEPLOYMENT_MARKER" bs=1 skip=16 count="$op_len" status=none)
    source_hex=$(dd if="$DEPLOYMENT_MARKER" bs=1 skip=144 count=16 status=none | od -An -tx1 | tr -d ' \n')
    target_hex=$(dd if="$DEPLOYMENT_MARKER" bs=1 skip=160 count=16 status=none | od -An -tx1 | tr -d ' \n')
    coordinator_hex=$(dd if="$DEPLOYMENT_MARKER" bs=1 skip=176 count=16 status=none | od -An -tx1 | tr -d ' \n')
    created=$(od -An -tu8 -j192 -N8 "$DEPLOYMENT_MARKER" | tr -d ' ')
    generation=$(od -An -tu8 -j200 -N8 "$DEPLOYMENT_MARKER" | tr -d ' ')
    [[ $embedded_op == "$recovery_operation_id" && $source_hex == "$source_display_id_lower" &&
       $target_hex == "$target_device_id_lower" && $coordinator_hex == "$coordinator_instance_id_lower" &&
       $generation == "$recovery_marker_generation" ]] || die 'active recovery marker bytes differ from publish intent'
    seconds=$((created / 1000)); millis=$((created % 1000))
    printf -v utc '%s.%03dZ' "$(date -u -d "@$seconds" '+%Y-%m-%dT%H:%M:%S')" "$millis"
    temp=$secure_dir/adopted-recovery-publish.json
    jq -cn --arg op "$recovery_operation_id" --arg source "$source_display_id" --arg target "$target_device_id" \
        --arg coordinator "$coordinator_instance_id" --arg generation "$recovery_marker_generation" \
        --arg sha "$marker_sha" --arg created "$created" --arg utc "$utc" --arg marker "$DEPLOYMENT_MARKER" '
        {schema_version:1,state:"deployment-quarantine-published",protocol_version:"2.1",operation_id:$op,
         source_display_id:$source,target_device_id:$target,coordinator_instance_id:$coordinator,
         marker_generation:$generation,marker_path:$marker,marker_sha256:$sha,
         created_at_unix_ms:$created,created_at_utc:$utc}
    ' >"$temp"
    publish_json_file 'adopted recovery publish receipt' "$temp" "$recovery_deployment_publish_receipt"
}

republish_deployment_marker_for_recovery() {
    local query=$secure_dir/release-state.json state gen1_sha current_sha
    validate_publish_receipt "$deployment_publish_receipt" "$marker_generation" 0
    gen1_sha=$published_marker_sha
    if [[ -e $DEPLOYMENT_MARKER ]]; then
        current_sha=$(sha256 "$DEPLOYMENT_MARKER")
        if [[ $current_sha == "$gen1_sha" ]]; then
            active_marker_publish_receipt=$deployment_publish_receipt
            active_marker_operation_id=$operation_id
            active_marker_generation=$marker_generation
            active_marker_sha=$gen1_sha
            published_marker_sha=$gen1_sha
        else
            ensure_recovery_publish_intent
            if [[ ! -e $recovery_deployment_publish_receipt ]]; then adopt_active_recovery_marker "$current_sha"; fi
            validate_publish_receipt "$recovery_deployment_publish_receipt" "$recovery_marker_generation" 1 "$recovery_operation_id"
            active_marker_publish_receipt=$recovery_deployment_publish_receipt
            active_marker_operation_id=$recovery_operation_id
            active_marker_generation=$recovery_marker_generation
            active_marker_sha=$published_marker_sha
        fi
        return
    fi
    if [[ -e ${DEPLOYMENT_MARKER}.release-claim ]]; then
        die 'uncertain: failed deployment recovery will not complete a protocol-2.1 release claim'
    fi
    capture_json_command 'already-released marker recovery query' "$query" marker_cli query \
        --operation-id "$operation_id" --coordinator-instance-id "$coordinator_instance_id" \
        --marker-generation "$marker_generation" --marker-sha256 "$published_marker_sha"
    state=$(jq -er '.state' "$query")
    [[ $state == deployment-quarantine-released ]] ||
        die 'marker absence lacks exact pre-existing normal-release proof'
    validate_release_receipt_v2 "$query"
    ensure_recovery_publish_intent
    capture_json_command 'recovery deployment publish receipt' "$recovery_deployment_publish_receipt" \
        marker_cli publish --operation-id "$recovery_operation_id" --source-display-id "$source_display_id" \
        --target-device-id "$target_device_id" --coordinator-instance-id "$coordinator_instance_id" \
        --marker-generation "$recovery_marker_generation"
    validate_publish_receipt "$recovery_deployment_publish_receipt" "$recovery_marker_generation" 1 "$recovery_operation_id"
    active_marker_publish_receipt=$recovery_deployment_publish_receipt
    active_marker_operation_id=$recovery_operation_id
    active_marker_generation=$recovery_marker_generation
    active_marker_sha=$published_marker_sha
    released_marker=0
}

validate_cpp_cleanup_receipt() {
    local operation_sha core_pid core_ticks core_boot daemon_pid daemon_ticks daemon_boot
    assert_strict_json_document 'C++ cleanup receipt' "$cpp_cleanup_receipt"
    operation_sha=$(printf '%s' "$operation_id" | sha256sum | awk '{print $1}')
    core_pid=$(jq -er '.core_pid' "$cpp_status_response")
    core_ticks=$(jq -er '.core_start_ticks' "$cpp_status_response")
    core_boot=$(jq -er '.core_boot_id' "$cpp_status_response")
    daemon_pid=$(jq -er '.producer_pid' "$rust_acceptance_arm_response")
    daemon_ticks=$(jq -er '.producer_start_ticks' "$rust_acceptance_arm_response")
    daemon_boot=$(jq -er '.producer_boot_id | gsub("-";"")' "$rust_acceptance_arm_response")
    jq -e --arg op "$operation_id" --arg op_sha "$operation_sha" \
        --arg source "$source_display_id_lower" --arg target "$target_device_id_lower" \
        --arg deployment "$acceptance_deployment_marker_sha" --arg core "$deskflow_core_sha" \
        --arg runtime "$RUNTIME_MARKER" --arg core_boot "$core_boot" --arg daemon_boot "$daemon_boot" \
        --argjson core_pid "$core_pid" --argjson core_ticks "$core_ticks" \
        --argjson daemon_pid "$daemon_pid" --argjson daemon_ticks "$daemon_ticks" '
        (keys == ["acknowledged","active_lease_generation","bound_peer_address","bound_peer_epoch","bound_peer_family","bound_peer_port","bound_peer_scope_id","cleanup_complete_body_size","cleanup_complete_mode","cleanup_operation_id","cleanup_sha256","completed_at_unix_ms","coordinator_operation_id","coordinator_operation_id_sha256","core_boot_id","core_executable_sha256","core_pid","core_start_ticks","daemon_boot_id","daemon_pid","daemon_start_ticks","deployment_marker_bound","deployment_marker_sha256","marker_last_sequence","owner_device_id","protocol_version","route_generation","runtime_marker_magic","runtime_marker_path","runtime_marker_released","runtime_marker_sha256","runtime_marker_size","schema_version","sidecar_protocol_version","source_display_id","state","target_device_id","tombstone_magic","tombstone_sha256","tombstone_size"]) and
        .schema_version == 1 and .state == "deskflow-runtime-cleanup-evidence" and
        .protocol_version == "2.1" and .sidecar_protocol_version == 3 and
        .coordinator_operation_id == $op and .coordinator_operation_id_sha256 == $op_sha and
        .source_display_id == $source and .target_device_id == $target and .owner_device_id == $target and
        .deployment_marker_bound == true and .deployment_marker_sha256 == $deployment and
        .cleanup_complete_body_size == 277 and .cleanup_complete_mode == "normal" and .acknowledged == true and
        .runtime_marker_magic == "VFQST002" and .runtime_marker_size == 152 and
        .runtime_marker_path == $runtime and .runtime_marker_released == true and
        .tombstone_magic == "VFACK001" and .tombstone_size == 72 and
        (.cleanup_operation_id | test("^[0-9a-f]{32}$")) and
        (.cleanup_sha256 | test("^[0-9a-f]{64}$")) and
        (.runtime_marker_sha256 | test("^[0-9a-f]{64}$")) and
        (.tombstone_sha256 | test("^[0-9a-f]{64}$")) and
        .core_executable_sha256 == $core and .core_pid == $core_pid and
        .core_start_ticks == $core_ticks and .core_boot_id == $core_boot and
        .daemon_pid == $daemon_pid and .daemon_start_ticks == $daemon_ticks and .daemon_boot_id == $daemon_boot and
        (.route_generation | type == "number" and . == floor and . > 0) and
        (.active_lease_generation | type == "number" and . == floor and . > 0) and
        (.marker_last_sequence | type == "number" and . == floor and . >= 0) and
        (.bound_peer_epoch | type == "number" and . == floor and . > 0) and
        (.completed_at_unix_ms | type == "number" and . == floor and . > 0)
    ' "$cpp_cleanup_receipt" >/dev/null || die 'live C++ CleanupComplete/runtime-marker proof is invalid'
    [[ ! -e $RUNTIME_MARKER ]] || die 'C++ claimed runtime marker release but VFQST002 remains'
}

validate_cpp_status() {
    local core_pid core_ticks boot_id
    assert_strict_json_document 'live C++ status' "$1"
    core_pid=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    [[ $core_pid =~ ^[1-9][0-9]*$ ]] || die 'exactly one live deskflow-core is required'
    core_ticks=$(process_start_ticks "$core_pid")
    boot_id=$(tr -d -- '-' </proc/sys/kernel/random/boot_id)
    jq -e --arg runtime "$RUNTIME_MARKER" --arg boot "$boot_id" \
        --argjson pid "$core_pid" --argjson ticks "$core_ticks" '
        (keys == ["core_boot_id","core_pid","core_start_ticks","protocol_version","receipt_available","runtime_marker_path","runtime_marker_present","schema_version","sidecar_configured","sidecar_protocol_version","state"]) and
        .schema_version == 1 and .state == "deskflow-live-acceptance-status" and
        .protocol_version == "2.1" and .sidecar_protocol_version == 3 and .sidecar_configured == true and
        .runtime_marker_path == $runtime and .core_pid == $pid and .core_start_ticks == $ticks and .core_boot_id == $boot
    ' "$1" >/dev/null || die 'live deskflow-core status is invalid'
    [[ $(sha256 "/proc/$core_pid/exe") == "$deskflow_core_sha" ]] || die 'live deskflow-core status hash mismatch'
}

arm_cpp_acceptance() {
    if [[ -e $cpp_arm_response ]]; then
        jq -e 'keys == ["armed","schema_version","state"] and .schema_version == 1 and
            .state == "viewflow-acceptance-armed" and .armed == true' "$cpp_arm_response" >/dev/null ||
            die 'durable C++ arm response is invalid'
        return
    fi
    capture_json_command 'C++ acceptance arm response' "$cpp_arm_response" \
        env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$DESKFLOW_ACCEPTANCE_SOCKET" "$DESKFLOW_CORE_INSTALLED" \
        --viewflow-acceptance-query arm --coordinator-operation-id "$operation_id" \
        --source-display-id "$source_display_id_lower" --target-device-id "$target_device_id_lower" \
        --deployment-marker-sha256 "$acceptance_deployment_marker_sha"
    jq -e '(keys == ["armed","schema_version","state"]) and .schema_version == 1 and
        .state == "viewflow-acceptance-armed" and .armed == true' "$cpp_arm_response" >/dev/null ||
        die 'live deskflow-core arm response is invalid'
}

assert_linux_ready_and_publish_proof() {
    local viewflow_pid deskflow_pid core_pid invocation temp install_sha
    viewflow_pid=$(unit_main_pid "$VIEWFLOW_UNIT")
    deskflow_pid=$(unit_main_pid "$DESKFLOW_UNIT")
    [[ $viewflow_pid =~ ^[1-9][0-9]*$ && $deskflow_pid =~ ^[1-9][0-9]*$ ]] ||
        die 'Linux units have no live main PID'
    [[ $(sha256 "/proc/$viewflow_pid/exe") == "$viewflow_sha" &&
       $(sha256 "/proc/$deskflow_pid/exe") == "$deskflow_sha" ]] ||
        die 'Linux main process hash proof failed'
    core_pid=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    [[ $core_pid =~ ^[1-9][0-9]*$ && $(sha256 "/proc/$core_pid/exe") == "$deskflow_core_sha" ]] ||
        die 'Linux deskflow-core proof failed'
    [[ $(sha256 "$MARKER_CLI") == "$deployment_marker_sha" ]] ||
        die 'installed deployment marker CLI hash proof failed'
    invocation=$(systemctl --user show --property InvocationID --value "$VIEWFLOW_UNIT")
    [[ $invocation =~ ^[0-9a-f]{32}$ ]] || die 'Linux Viewflow invocation ID is invalid'
    journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
        grep -Fq "viewflowd protocol $REQUIRED_PROTOCOL serving mTLS QUIC" ||
        die 'Linux protocol 2.1 proof is absent'
    journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
        grep -Fq 'viewflowd server authenticated peer ' || die 'Linux authenticated peer proof is absent'
    install_sha=$(sha256 "$bootstrap_windows_install_receipt")
    temp=$(mktemp --tmpdir="$(dirname -- "$linux_host_proof")" '.viewflow-linux-proof.XXXXXX')
    chmod 0600 "$temp"
    jq -cn --arg op "$operation_id" --arg protocol "$REQUIRED_PROTOCOL" \
        --argjson sidecar "$REQUIRED_SIDECAR_PROTOCOL" --arg invocation "$invocation" \
        --arg vf "$viewflow_sha" --arg df "$deskflow_sha" --arg core "$deskflow_core_sha" \
        --arg windows "$windows_viewflow_sha" --arg install "$install_sha" \
        --arg deployment "$published_marker_sha" \
        '{schema_version:1,state:"viewflow-linux-host-ready",protocol_version:$protocol,sidecar_protocol_version:$sidecar,operation_id:$op,viewflow_invocation_id:$invocation,linux_viewflow_sha256:$vf,windows_viewflow_sha256:$windows,deskflow_sha256:$df,deskflow_core_sha256:$core,windows_install_receipt_sha256:$install,deployment_marker_sha256:$deployment}' >"$temp"
    publish_new_file "$temp" "$linux_host_proof"
    rm -f -- "$temp"
    assert_deployment_marker
}

validate_two_host_cross_binding() {
    local install_sha
    install_sha=$(sha256 "$bootstrap_windows_install_receipt")
    jq -e --arg op "$operation_id" --arg protocol "$REQUIRED_PROTOCOL" \
        --argjson sidecar "$REQUIRED_SIDECAR_PROTOCOL" --arg linux "$viewflow_sha" \
        --arg windows "$windows_viewflow_sha" --arg install "$install_sha" \
        --arg deployment "$published_marker_sha" '
        (keys == ["deployment_marker_sha256","deskflow_core_sha256","deskflow_sha256","linux_viewflow_sha256","operation_id","protocol_version","schema_version","sidecar_protocol_version","state","viewflow_invocation_id","windows_install_receipt_sha256","windows_viewflow_sha256"]) and
        .schema_version == 1 and .state == "viewflow-linux-host-ready" and .operation_id == $op and
        .protocol_version == $protocol and .sidecar_protocol_version == $sidecar and
        .linux_viewflow_sha256 == $linux and .windows_viewflow_sha256 == $windows and
        .windows_install_receipt_sha256 == $install and .deployment_marker_sha256 == $deployment
    ' "$linux_host_proof" >/dev/null || die 'Linux host proof is invalid'
    jq -e --arg op "$operation_id" --arg windows "$windows_viewflow_sha" \
        --arg protocol "$REQUIRED_PROTOCOL" --arg peer "$EXPECTED_WINDOWS_PEER" \
        --arg device "$EXPECTED_WINDOWS_DEVICE" '
        .operation_id == $op and .committed_by_daemon == true and
        .new_viewflow_executable_sha256 == $windows and .protocol_version == $protocol and
        .peer == $peer and .device_id == $device
    ' "$bootstrap_windows_install_receipt" >/dev/null ||
        die 'Windows host proof does not cross-bind Linux endpoint'
}

validate_rust_control_identity() {
    local path=$1 expected_status=$2 viewflow_pid viewflow_ticks
    viewflow_pid=$(unit_main_pid "$VIEWFLOW_UNIT")
    viewflow_ticks=$(process_start_ticks "$viewflow_pid")
    jq -e --arg status "$expected_status" --arg op "$operation_id" --arg vf "$viewflow_sha" \
        --argjson pid "$viewflow_pid" --argjson ticks "$viewflow_ticks" '
        (keys == ["accepted_sequence_strictly_increasing","acked_unique_sequence_count","duplicate_ack_count","error","late_ack_rejection_count","max_us","ok","operation_id","p99_us","producer_boot_id","producer_executable_sha256","producer_pid","producer_start_ticks","receipt_path","replay_rejection_count","sample_count","schema_version","status","transcript_path","transcript_sha256"]) and
        .schema_version == 1 and .ok == true and .status == $status and .operation_id == $op and
        .producer_pid == $pid and .producer_start_ticks == $ticks and
        .producer_executable_sha256 == $vf and (.producer_boot_id | type == "string" and length > 0) and
        (.transcript_path | type == "string" and startswith("/")) and
        (.transcript_sha256 | test("^[0-9a-f]{64}$")) and .error == null
    ' "$path" >/dev/null || die "viewflowd acceptance $expected_status response is invalid"
    [[ $(sha256 "/proc/$viewflow_pid/exe") == "$viewflow_sha" ]] || die 'live viewflowd recorder hash mismatch'
}

arm_rust_acceptance() {
    local release_sha
    if [[ -e $rust_acceptance_arm_response ]]; then
        validate_rust_control_identity "$rust_acceptance_arm_response" armed_external_exercise_required
        return
    fi
    release_sha=$(sha256 "$deployment_release_receipt")
    capture_json_command 'viewflowd acceptance arm response' "$rust_acceptance_arm_response" \
        "$VIEWFLOW_INSTALLED" acceptance-arm --acceptance-socket "$VIEWFLOW_ACCEPTANCE_SOCKET" \
        --operation-id "$operation_id" --source-display-id "$source_display_id_lower" \
        --target-device-id "$target_device_id_lower" --linux-viewflow-sha256 "$viewflow_sha" \
        --windows-viewflow-sha256 "$windows_viewflow_sha" \
        --deployment-release-receipt "$deployment_release_receipt" \
        --deployment-release-receipt-sha256 "$release_sha"
    validate_rust_control_identity "$rust_acceptance_arm_response" armed_external_exercise_required
    jq -e '.receipt_path != null and .sample_count == null and .max_us == null and .p99_us == null and
        .accepted_sequence_strictly_increasing == null and .acked_unique_sequence_count == null and
        .duplicate_ack_count == null and .replay_rejection_count == null and .late_ack_rejection_count == null' \
        "$rust_acceptance_arm_response" >/dev/null || die 'viewflowd arm response contains fabricated completion metrics'
}

wait_for_runtime_marker_and_arm_cpp() {
    local deadline=$((SECONDS + acceptance_timeout_seconds)) temp
    temp=$secure_dir/cpp-status.json
    if [[ -e $cpp_status_response ]]; then
        validate_cpp_status "$cpp_status_response"
        arm_cpp_acceptance
        return
    fi
    printf '%s\n' 'EXERCISE_PHASE: enter the route, exercise keyboard/pointer/five buttons/both axes, and remain remote until ARMED_RETURN_ALLOWED'
    while ((SECONDS < deadline)); do
        rm -f -- "$temp"
        if env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$DESKFLOW_ACCEPTANCE_SOCKET" \
            "$DESKFLOW_CORE_INSTALLED" --viewflow-acceptance-query status >"$temp" 2>/dev/null; then
            validate_cpp_status "$temp"
            jq -e '.receipt_available == false' "$temp" >/dev/null || die 'stale C++ cleanup receipt existed before acceptance arm'
            if jq -e '.runtime_marker_present == true' "$temp" >/dev/null; then
                assert_runtime_marker_retained || die 'C++ status claimed a runtime marker with invalid VFQST002 bytes'
                publish_json_file 'C++ marker-present status response' "$temp" "$cpp_status_response"
                arm_cpp_acceptance
                printf '%s\n' 'ARMED_RETURN_ALLOWED: return local now; cleanup must finish before the coordinator restarts the Windows peer'
                return
            fi
            jq -e '.runtime_marker_present == false' "$temp" >/dev/null || die 'C++ runtime marker status is not Boolean'
        fi
        sleep 0.1
    done
    die 'timed out waiting for live VFQST002 before C++ arm'
}

wait_for_cpp_cleanup() {
    local deadline=$((SECONDS + acceptance_timeout_seconds)) cpp_temp rust_temp
    cpp_temp=$secure_dir/cpp-cleanup.json
    rust_temp=$secure_dir/rust-query-pending.json
    if [[ -e $cpp_cleanup_receipt ]]; then validate_cpp_cleanup_receipt; return; fi
    while ((SECONDS < deadline)); do
        rm -f -- "$cpp_temp" "$rust_temp"
        if env DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET="$DESKFLOW_ACCEPTANCE_SOCKET" \
            "$DESKFLOW_CORE_INSTALLED" --viewflow-acceptance-query cleanup \
            --coordinator-operation-id "$operation_id" --source-display-id "$source_display_id_lower" \
            --target-device-id "$target_device_id_lower" --deployment-marker-sha256 "$acceptance_deployment_marker_sha" \
            >"$cpp_temp" 2>/dev/null; then
            publish_json_file 'C++ cleanup receipt' "$cpp_temp" "$cpp_cleanup_receipt"
            validate_cpp_cleanup_receipt
            [[ ! -e $DEPLOYMENT_MARKER ]] || die 'VFDQT001 reappeared before normal cleanup completed'
            return
        fi
        if "$VIEWFLOW_INSTALLED" acceptance-query --acceptance-socket "$VIEWFLOW_ACCEPTANCE_SOCKET" \
            --operation-id "$operation_id" >"$rust_temp" 2>/dev/null; then
            assert_strict_json_document 'pending viewflowd acceptance response' "$rust_temp"
            if jq -e '.schema_version == 1 and .ok == false and .status == "failed_closed" and
                .error == "active_route_disconnect_requires_containment" and .receipt_path == null' \
                "$rust_temp" >/dev/null; then
                die 'active_route_disconnect_requires_containment'
            fi
            jq -e '.schema_version == 1 and .ok == true and .status == "pending_external_exercise" and .receipt_path == null' \
                "$rust_temp" >/dev/null || die 'viewflowd acceptance failed closed before normal cleanup'
        else
            die 'viewflowd acceptance query failed before normal cleanup'
        fi
        sleep 0.1
    done
    die 'timed out waiting for acknowledged C++ normal cleanup'
}

validate_windows_restart_intent() {
    local intent=$1
    assert_strict_json_document 'Windows restart intent' "$intent"
    jq -e --arg op "$operation_id" --argjson old "$(jq -er '.new_process_pid' "$bootstrap_windows_install_receipt")" \
        --argjson generation "$(jq -er '.readiness_connection_generation' "$bootstrap_windows_install_receipt")" \
        --arg exe "$windows_viewflow_sha" --arg wrapper "$windows_wrapper_sha" --arg task "$windows_task_xml_sha" '
        keys == ["linux_authenticated_peer_count","linux_invocation_id","old_connection_generation","old_process_pid","operation_id","schema_version","state","task_xml_sha256","viewflow_sha256","wrapper_sha256"] and
        .schema_version == 1 and .state == "viewflow-post-release-restart-intent" and .operation_id == $op and
        .old_process_pid == $old and .old_connection_generation == $generation and
        .viewflow_sha256 == $exe and .wrapper_sha256 == $wrapper and .task_xml_sha256 == $task and
        (.linux_invocation_id | type == "string" and test("^[0-9a-f]{32}$")) and
        (.linux_authenticated_peer_count | type == "number" and . == floor and . >= 0)
    ' "$intent" >/dev/null || die 'Windows restart intent is invalid'
}

wait_for_linux_restart_auth() {
    local invocation=$1 before=$2 deadline=$((SECONDS + 30)) after
    while ((SECONDS < deadline)); do
        after=$(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
            grep -Fc 'viewflowd server authenticated peer 172.16.105.70:' || true)
        ((after > before)) && return
        sleep 0.1
    done
    die 'Linux did not observe a new authenticated Windows peer after owner task restart'
}

validate_existing_windows_restart_receipt() {
    local receipt=${1:-$windows_restart_receipt}
    assert_strict_json_document 'durable Windows restart terminal receipt' "$receipt"
    jq -e --arg op "$operation_id" --arg sid "$windows_user_sid" \
        --argjson old "$(jq -er '.new_process_pid' "$bootstrap_windows_install_receipt")" \
        --argjson old_generation "$(jq -er '.readiness_connection_generation' "$bootstrap_windows_install_receipt")" \
        --arg exe "$windows_viewflow_sha" --arg wrapper "$windows_wrapper_sha" --arg task "$windows_task_xml_sha" \
        --arg receipt_path "$windows_readiness_receipt_path" --arg lock_path "$windows_readiness_lock_path" \
        --arg intent "$windows_restart_intent_sha" '
        def integer: type == "number" and . == floor;
        (keys == ["old_process_exited","old_process_pid","operation_id","process_identity","readiness_lock","readiness_lock_held","readiness_lock_sha256","readiness_receipt","readiness_receipt_sha256","restart_intent_sha256","restarted_at_utc","schema_version","state","task_identity","task_name"]) and
        .schema_version == 2 and .state == "viewflow-owner-task-restarted-after-cleanup" and
        .operation_id == $op and .restart_intent_sha256 == $intent and .task_name == "\\Viewflow Peer" and .old_process_pid == $old and .old_process_exited == true and
        .readiness_lock_held == true and (.readiness_receipt_sha256 | test("^[0-9a-f]{64}$")) and (.readiness_lock_sha256 | test("^[0-9a-f]{64}$")) and
        (.readiness_receipt | keys) == ["connection_generation","daemon_executable_sha256","daemon_pid","daemon_process_start_filetime","daemon_session_id","daemon_user_sid","established_at_utc","input_backend","local_device_id","operation_id","peer_address","probe_max_round_trip_ns","probe_max_uncertainty_ns","probe_round_trip_ns","probe_uncertainty_ns","protocol_major","protocol_minor","readiness_lock_path","readiness_lock_sha256","schema_version","server_name","state","validity"] and
        .readiness_receipt.schema_version == 1 and .readiness_receipt.state == "viewflow-post-mtls-readiness-established" and .readiness_receipt.validity == "while-readiness-lock-is-held" and
        .readiness_receipt.operation_id == $op and .readiness_receipt.daemon_executable_sha256 == $exe and .readiness_receipt.daemon_user_sid == $sid and
        .readiness_receipt.daemon_session_id == 1 and .readiness_receipt.input_backend == "native" and .readiness_receipt.local_device_id == "00000000000000000000000000000002" and
        .readiness_receipt.peer_address == "172.16.105.62:44119" and .readiness_receipt.server_name == "viewflow-linux" and .readiness_receipt.protocol_major == 2 and .readiness_receipt.protocol_minor == 1 and
        (.readiness_receipt.connection_generation | integer and . > $old_generation) and (.readiness_receipt.probe_round_trip_ns | integer and . >= 0 and . <= 33333334) and
        .readiness_receipt.probe_max_round_trip_ns == 33333334 and (.readiness_receipt.probe_uncertainty_ns | integer and . >= 0 and . <= 4000000) and .readiness_receipt.probe_max_uncertainty_ns == 4000000 and
        .readiness_receipt.readiness_lock_path == $lock_path and .readiness_receipt.readiness_lock_sha256 == .readiness_lock_sha256 and
        (.readiness_lock | keys) == ["connection_generation","daemon_pid","daemon_process_start_filetime","operation_id","schema_version","state"] and
        .readiness_lock.schema_version == 1 and .readiness_lock.state == "viewflow-post-mtls-readiness-lock" and .readiness_lock.operation_id == $op and
        .readiness_lock.daemon_pid == .readiness_receipt.daemon_pid and .readiness_lock.daemon_process_start_filetime == .readiness_receipt.daemon_process_start_filetime and .readiness_lock.connection_generation == .readiness_receipt.connection_generation and
        (.process_identity | keys) == ["image_path","image_sha256","pid","session_id","start_filetime","user_sid"] and
        .process_identity.pid == .readiness_receipt.daemon_pid and .process_identity.pid != $old and .process_identity.pid > 0 and .process_identity.start_filetime == .readiness_receipt.daemon_process_start_filetime and .process_identity.session_id == 1 and .process_identity.user_sid == $sid and .process_identity.image_sha256 == $exe and
        (.task_identity | keys) == ["action_arguments","action_executable","principal_logon_type","principal_run_level","principal_user_sid","state","task_xml_sha256","working_directory","wrapper_path","wrapper_sha256"] and
        .task_identity.state == "Running" and .task_identity.principal_user_sid == $sid and .task_identity.principal_logon_type == "Interactive" and .task_identity.principal_run_level == "Limited" and .task_identity.wrapper_sha256 == $wrapper and .task_identity.task_xml_sha256 == $task and
        (.restarted_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and (.readiness_receipt.established_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
    ' "$receipt" >/dev/null || die 'durable Windows restart terminal receipt is invalid'
}

restart_windows_peer_after_cleanup() {
    local old_pid old_generation command encoded_command invocation auth_before intent=$secure_dir/restart-intent.json \
        terminal=$secure_dir/restart-terminal.remote.json intent_sha status=0
    old_pid=$(jq -er '.new_process_pid' "$bootstrap_windows_install_receipt")
    old_generation=$(jq -er '.readiness_connection_generation' "$bootstrap_windows_install_receipt")
    if [[ -e $local_windows_restart_intent ]]; then
        intent=$local_windows_restart_intent
        validate_windows_restart_intent "$intent"
    else
        invocation=$(systemctl --user show --property InvocationID --value "$VIEWFLOW_UNIT")
        [[ $invocation =~ ^[0-9a-f]{32}$ ]] || die 'Linux Viewflow invocation ID is invalid'
        auth_before=$(journalctl --user --quiet --output cat "_SYSTEMD_INVOCATION_ID=$invocation" |
            grep -Fc 'viewflowd server authenticated peer 172.16.105.70:' || true)
        jq -cn --arg op "$operation_id" --argjson pid "$old_pid" --argjson generation "$old_generation" \
            --arg exe "$windows_viewflow_sha" --arg wrapper "$windows_wrapper_sha" --arg task "$windows_task_xml_sha" \
            --arg invocation "$invocation" --argjson auth "$auth_before" '
            {schema_version:1,state:"viewflow-post-release-restart-intent",operation_id:$op,old_process_pid:$pid,
             old_connection_generation:$generation,viewflow_sha256:$exe,wrapper_sha256:$wrapper,task_xml_sha256:$task,
             linux_invocation_id:$invocation,linux_authenticated_peer_count:$auth}
        ' >"$intent"
        validate_windows_restart_intent "$intent"
        publish_json_file 'durable Windows restart intent' "$intent" "$local_windows_restart_intent"
        intent=$local_windows_restart_intent
    fi
    windows_create_or_verify "$intent" "$windows_restart_intent_path"
    invocation=$(jq -er '.linux_invocation_id' "$intent")
    auth_before=$(jq -er '.linux_authenticated_peer_count' "$intent")
    intent_sha=$(sha256 "$intent")
    windows_restart_intent_sha=$intent_sha
    if [[ -e $windows_restart_receipt ]]; then
        windows_remote_exists "$windows_restart_terminal_path" || die 'local restart receipt lacks remote terminal'
        windows_read_file "$windows_restart_terminal_path" "$terminal"
        [[ $(sha256 "$terminal") == "$(sha256 "$windows_restart_receipt")" ]] || die 'remote restart terminal changed'
        validate_existing_windows_restart_receipt
        wait_for_linux_restart_auth "$invocation" "$auth_before"
        return
    fi
    if windows_remote_exists "$windows_restart_terminal_path"; then
        windows_read_file "$windows_restart_terminal_path" "$terminal"
        validate_existing_windows_restart_receipt "$terminal"
        wait_for_linux_restart_auth "$invocation" "$auth_before"
        copy_json_output 'durable Windows restart terminal receipt' "$terminal" "$windows_restart_receipt"
        return
    fi
    windows_remote_exists "$windows_restart_claim_path" && die 'uncertain: Windows restart claim exists without terminal receipt'
    commit_phase WINDOWS_RESTART_DISPATCHED
    command=$(printf '%s\n' \
        '$ErrorActionPreference="Stop"' \
        '$expectedSid="'$windows_user_sid'"; $expectedOp="'$operation_id'"; $expectedExeSha="'$windows_viewflow_sha'"; $expectedWrapperSha="'$windows_wrapper_sha'"; $expectedTaskSha="'$windows_task_xml_sha'"' \
        '$restartIntentPath="'$windows_restart_intent_path'"; $restartClaimPath="'$windows_restart_claim_path'"; $restartTerminalPath="'$windows_restart_terminal_path'"; $expectedRestartIntentSha="'$intent_sha'"' \
        '$receiptPath=[IO.Path]::GetFullPath("'$windows_readiness_receipt_path'"); $lockPath=[IO.Path]::GetFullPath("'$windows_readiness_lock_path'")' \
        '$installRoot=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Programs\Viewflow")); $daemonPath=[IO.Path]::GetFullPath((Join-Path $installRoot "viewflowd.exe")); $wrapperPath=[IO.Path]::GetFullPath((Join-Path $installRoot "viewflow-client.ps1")); $powerShellPath=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"))' \
        'function HashBytes([byte[]]$b){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash($b))-replace "-","").ToLowerInvariant()}finally{$h.Dispose()}}' \
        'function FileHash([string]$p){return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}' \
        'if((FileHash $restartIntentPath)-cne$expectedRestartIntentSha){throw "restart intent hash differs"};$claimBytes=(New-Object Text.UTF8Encoding($false)).GetBytes($expectedRestartIntentSha);$claimStream=[IO.File]::Open($restartClaimPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$claimStream.Write($claimBytes,0,$claimBytes.Length);$claimStream.Flush($true)}finally{$claimStream.Dispose()}' \
        'function ExactKeys($o,[string[]]$k,[string]$n){$a=@($o.PSObject.Properties.Name|Sort-Object);$b=@($k|Sort-Object);if($a.Count-ne$b.Count-or(($a-join "`n")-cne($b-join "`n"))){throw "$n has a non-exact property set"}}' \
        'function OwnerOnly([string]$p,[string]$n){$i=Get-Item -LiteralPath $p -Force;if($i.PSIsContainer-or(($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0)){throw "$n is not a regular non-reparse file"};$a=Get-Acl -LiteralPath $p;$owner=([Security.Principal.NTAccount][string]$a.Owner).Translate([Security.Principal.SecurityIdentifier]).Value;$r=@($a.Access);if($owner-cne$expectedSid-or-not$a.AreAccessRulesProtected-or$r.Count-ne1-or$r[0].IsInherited-or$r[0].AccessControlType-ne[Security.AccessControl.AccessControlType]::Allow-or$r[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value-cne$expectedSid-or(($r[0].FileSystemRights-band[Security.AccessControl.FileSystemRights]::FullControl)-ne[Security.AccessControl.FileSystemRights]::FullControl)){throw "$n is not owner-only"}}' \
        'function Snapshot([IO.FileStream]$s,[string]$n){if($s.Length-le0-or$s.Length-gt65536){throw "$n size is invalid"};$s.Position=0;$b=New-Object byte[] ([int]$s.Length);$o=0;while($o-lt$b.Length){$c=$s.Read($b,$o,$b.Length-$o);if($c-le0){throw "$n is truncated"};$o+=$c};$u=New-Object Text.UTF8Encoding($false,$true);$t=$u.GetString($b);$round=$u.GetBytes($t);if($round.Length-ne$b.Length){throw "$n is not canonical UTF-8"};for($i=0;$i-lt$b.Length;$i++){if($round[$i]-ne$b[$i]){throw "$n is not canonical UTF-8"}};$dq=[regex]::Escape([string][char]34);$keyPattern=$dq+"((?:\\.|[^"+$dq+"\\])*)"+$dq+"\s*:";$names=New-Object "Collections.Generic.HashSet[string]" ([StringComparer]::Ordinal);foreach($m in [regex]::Matches($t,$keyPattern)){if($m.Groups[1].Value.IndexOf([char]92)-ge0-or-not$names.Add($m.Groups[1].Value)){throw "$n contains an escaped or duplicate key"}};try{$v=$t|ConvertFrom-Json}catch{throw "$n is invalid JSON"};[pscustomobject]@{Bytes=$b;Text=$t;Value=$v;Sha256=(HashBytes $b)}}' \
        'function LiveLock([string]$p){$w=$null;$sharing=$false;try{$w=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)}catch [IO.IOException]{if(($_.Exception.HResult-band0xffff)-eq32){$sharing=$true}else{throw}}finally{if($null-ne$w){$w.Dispose()}};if(-not$sharing){throw "readiness lock is not held by the daemon"}}' \
        'function Identity([int]$pid){$p=[Diagnostics.Process]::GetProcessById($pid);$c=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}"-f$pid);if($null-eq$c){throw "daemon CIM identity missing"};$owner=Invoke-CimMethod -InputObject $c -MethodName GetOwnerSid;if([uint32]$owner.ReturnValue-ne0){throw "daemon owner SID unavailable"};[pscustomobject]@{Pid=[long]$pid;StartFiletime=$p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture);Session=[long]$p.SessionId;Sid=[string]$owner.Sid;Image=[IO.Path]::GetFullPath([string]$c.ExecutablePath);CommandLine=[string]$c.CommandLine}}' \
        '$old=[long]'$old_pid'; $oldGeneration=[long]'$old_generation'; $restartBegan=[DateTime]::UtcNow' \
        'Stop-ScheduledTask -TaskPath "\" -TaskName "Viewflow Peer"' \
        '$deadline=[DateTime]::UtcNow.AddSeconds(30);while(Get-Process -Id $old -ErrorAction SilentlyContinue){if([DateTime]::UtcNow-ge$deadline){throw "old Viewflow PID did not exit"};Start-Sleep -Milliseconds 100}' \
        'Start-ScheduledTask -TaskPath "\" -TaskName "Viewflow Peer"' \
        '$deadline=[DateTime]::UtcNow.AddSeconds(30);$receiptStream=$null;$lockStream=$null;$readyRead=$null;$lockRead=$null;$identity=$null' \
        'while([DateTime]::UtcNow-lt$deadline){try{$p=@(Get-Process -Name viewflowd -ErrorAction SilentlyContinue|Where-Object{$_.Id-ne$old}|Sort-Object Id);if($p.Count-ne1){throw "expected exactly one new daemon"};OwnerOnly $receiptPath "readiness receipt";OwnerOnly $lockPath "readiness lock";$receiptStream=[IO.File]::Open($receiptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$lockStream=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);$readyRead=Snapshot $receiptStream "readiness receipt";$lockRead=Snapshot $lockStream "readiness lock";$ready=$readyRead.Value;$lock=$lockRead.Value;$identity=Identity ([int]$p[0].Id);if([long]$ready.daemon_pid-ne$identity.Pid-or[long]$ready.connection_generation-le$oldGeneration){throw "readiness is not from the new generation"};break}catch{if($null-ne$receiptStream){$receiptStream.Dispose();$receiptStream=$null};if($null-ne$lockStream){$lockStream.Dispose();$lockStream=$null};Start-Sleep -Milliseconds 100}}' \
        'if($null-eq$readyRead-or$null-eq$lockRead-or$null-eq$identity){throw "fresh pinned post-mTLS readiness was not observed"}' \
        'try{' \
        '$receiptKeys=@("schema_version","state","validity","operation_id","daemon_executable_sha256","daemon_pid","daemon_process_start_filetime","daemon_session_id","daemon_user_sid","connection_generation","input_backend","local_device_id","peer_address","server_name","protocol_major","protocol_minor","probe_round_trip_ns","probe_max_round_trip_ns","probe_uncertainty_ns","probe_max_uncertainty_ns","readiness_lock_path","readiness_lock_sha256","established_at_utc");ExactKeys $ready $receiptKeys "readiness receipt"' \
        '$lockKeys=@("schema_version","state","operation_id","daemon_pid","daemon_process_start_filetime","connection_generation");ExactKeys $lock $lockKeys "readiness lock"' \
        'if($ready.schema_version-isnot[int]-or$ready.schema_version-ne1-or$ready.state-cne"viewflow-post-mtls-readiness-established"-or$ready.validity-cne"while-readiness-lock-is-held"-or$ready.operation_id-cne$expectedOp-or$ready.daemon_executable_sha256-cne$expectedExeSha-or$ready.input_backend-cne"native"-or$ready.local_device_id-cne"00000000000000000000000000000002"-or$ready.peer_address-cne"172.16.105.62:44119"-or$ready.server_name-cne"viewflow-linux"){throw "readiness fixed binding is invalid"}' \
        'if($ready.daemon_pid-isnot[int]-or[long]$ready.daemon_pid-ne$identity.Pid-or$ready.daemon_process_start_filetime-isnot[string]-or$ready.daemon_process_start_filetime-cne$identity.StartFiletime-or$ready.daemon_session_id-isnot[int]-or[long]$ready.daemon_session_id-ne1-or$ready.daemon_user_sid-cne$expectedSid-or$identity.Session-ne1-or$identity.Sid-cne$expectedSid-or-not$identity.Image.Equals($daemonPath,[StringComparison]::OrdinalIgnoreCase)-or(FileHash $identity.Image)-cne$expectedExeSha){throw "readiness daemon identity is invalid"}' \
        'if($ready.connection_generation-isnot[long]-and$ready.connection_generation-isnot[int]){throw "readiness generation type is invalid"};if([long]$ready.connection_generation-le$oldGeneration-or$ready.protocol_major-isnot[int]-or$ready.protocol_major-ne2-or$ready.protocol_minor-isnot[int]-or$ready.protocol_minor-ne1){throw "readiness generation or protocol is invalid"}' \
        'foreach($n in @("probe_round_trip_ns","probe_max_round_trip_ns","probe_uncertainty_ns","probe_max_uncertainty_ns")){if($ready.$n-isnot[long]-and$ready.$n-isnot[int]){throw "readiness probe type is invalid"}};if([long]$ready.probe_round_trip_ns-lt0-or[long]$ready.probe_round_trip_ns-gt33333334-or[long]$ready.probe_max_round_trip_ns-ne33333334-or[long]$ready.probe_uncertainty_ns-lt0-or[long]$ready.probe_uncertainty_ns-gt4000000-or[long]$ready.probe_max_uncertainty_ns-ne4000000){throw "readiness probe bounds are invalid"}' \
        '$est=[DateTime]::ParseExact([string]$ready.established_at_utc,"yyyy-MM-ddTHH:mm:ss.fffZ",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal-bor[Globalization.DateTimeStyles]::AdjustToUniversal);if($est-lt$restartBegan.AddSeconds(-1)-or$est-gt[DateTime]::UtcNow){throw "readiness established time is invalid"}' \
        'if(-not([IO.Path]::GetFullPath([string]$ready.readiness_lock_path)).Equals($lockPath,[StringComparison]::OrdinalIgnoreCase)-or$ready.readiness_lock_sha256-cne$lockRead.Sha256){throw "readiness lock path or hash is invalid"}' \
        'if($lock.schema_version-isnot[int]-or$lock.schema_version-ne1-or$lock.state-cne"viewflow-post-mtls-readiness-lock"-or$lock.operation_id-cne$expectedOp-or$lock.daemon_pid-isnot[int]-or[long]$lock.daemon_pid-ne$identity.Pid-or$lock.daemon_process_start_filetime-isnot[string]-or$lock.daemon_process_start_filetime-cne$identity.StartFiletime-or[long]$lock.connection_generation-ne[long]$ready.connection_generation){throw "readiness lock identity is invalid"}' \
        'LiveLock $lockPath' \
        '$task=Get-ScheduledTask -TaskPath "\" -TaskName "Viewflow Peer";$actions=@($task.Actions);if($task.State-ne"Running"-or$actions.Count-ne1-or@($task.Triggers).Count-ne0){throw "scheduled task shape is invalid"};$actionExe=[IO.Path]::GetFullPath(([Environment]::ExpandEnvironmentVariables([string]$actions[0].Execute)).Trim([char]34));if(-not$actionExe.Equals($powerShellPath,[StringComparison]::OrdinalIgnoreCase)-or-not([IO.Path]::GetFullPath([string]$actions[0].WorkingDirectory)).Equals($installRoot,[StringComparison]::OrdinalIgnoreCase)){throw "scheduled task action identity is invalid"}' \
        '$principalSid=(New-Object Security.Principal.NTAccount -ArgumentList ([string]$task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value;if($principalSid-cne$expectedSid-or[string]$task.Principal.LogonType-ne"Interactive"-or[string]$task.Principal.RunLevel-ne"Limited"){throw "scheduled task principal is invalid"}' \
        'if((FileHash $wrapperPath)-cne$expectedWrapperSha){throw "scheduled task wrapper hash is invalid"};$xml=Export-ScheduledTask -TaskPath "\" -TaskName "Viewflow Peer";$enc=New-Object Text.UnicodeEncoding($false,$true);$pre=$enc.GetPreamble();$body=$enc.GetBytes($xml);$xmlBytes=New-Object byte[] ($pre.Length+$body.Length);[Array]::Copy($pre,0,$xmlBytes,0,$pre.Length);[Array]::Copy($body,0,$xmlBytes,$pre.Length,$body.Length);if((HashBytes $xmlBytes)-cne$expectedTaskSha){throw "scheduled task XML hash is invalid"}' \
        '$readyAgain=Snapshot $receiptStream "readiness receipt recheck";$lockAgain=Snapshot $lockStream "readiness lock recheck";if($readyAgain.Sha256-cne$readyRead.Sha256-or$lockAgain.Sha256-cne$lockRead.Sha256){throw "pinned readiness artifacts changed"};$identityAgain=Identity ([int]$identity.Pid);if($identityAgain.StartFiletime-cne$identity.StartFiletime-or$identityAgain.Sid-cne$identity.Sid-or-not$identityAgain.Image.Equals($identity.Image,[StringComparison]::OrdinalIgnoreCase)-or(FileHash $identityAgain.Image)-cne$expectedExeSha){throw "daemon identity changed during validation"};LiveLock $lockPath' \
        '$result=[ordered]@{schema_version=2;state="viewflow-owner-task-restarted-after-cleanup";operation_id=$expectedOp;restart_intent_sha256=$expectedRestartIntentSha;task_name="\Viewflow Peer";old_process_pid=$old;old_process_exited=$true;restarted_at_utc=[DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");readiness_receipt_sha256=$readyRead.Sha256;readiness_lock_sha256=$lockRead.Sha256;readiness_lock_held=$true;readiness_receipt=$ready;readiness_lock=$lock;task_identity=[ordered]@{state=[string]$task.State;action_executable=$actionExe;action_arguments=[string]$actions[0].Arguments;working_directory=[IO.Path]::GetFullPath([string]$actions[0].WorkingDirectory);principal_user_sid=$principalSid;principal_logon_type=[string]$task.Principal.LogonType;principal_run_level=[string]$task.Principal.RunLevel;wrapper_path=$wrapperPath;wrapper_sha256=$expectedWrapperSha;task_xml_sha256=$expectedTaskSha};process_identity=[ordered]@{pid=$identity.Pid;start_filetime=$identity.StartFiletime;session_id=$identity.Session;user_sid=$identity.Sid;image_path=$identity.Image;image_sha256=$expectedExeSha}};$json=$result|ConvertTo-Json -Depth 5 -Compress;$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json);$terminal=[IO.File]::Open($restartTerminalPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$terminal.Write($bytes,0,$bytes.Length);$terminal.Flush($true)}finally{$terminal.Dispose()}' \
        '}finally{if($null-ne$receiptStream){$receiptStream.Dispose()};if($null-ne$lockStream){$lockStream.Dispose()}}')
    encoded_command=$(printf '%s' "$command" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
    command="powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded_command"
    if ssh_windows "$command" >/dev/null; then status=0; else status=$?; fi
    if windows_remote_exists "$windows_restart_terminal_path"; then
        windows_read_file "$windows_restart_terminal_path" "$terminal"
    else
        ((status == 0)) || return "$status"
        die 'Windows restart returned without durable terminal receipt'
    fi
    validate_existing_windows_restart_receipt "$terminal"
    wait_for_linux_restart_auth "$invocation" "$auth_before"
    copy_json_output 'durable Windows restart terminal receipt' "$terminal" "$windows_restart_receipt"
}

validate_normal_acceptance_transcript() {
    local transcript=$1 release_sha expected_transcript
    expected_transcript=$VIEWFLOW_ACCEPTANCE_STATE_DIR/post-release-$operation_id.transcript.json
    [[ $transcript == "$expected_transcript" ]] || die 'viewflowd query named an unexpected transcript path'
    assert_strict_json_document 'normal acceptance transcript' "$transcript"
    release_sha=$(sha256 "$deployment_release_receipt")
    jq -e --arg op "$operation_id" --arg source "$source_display_id_lower" \
        --arg target "$target_device_id_lower" --arg vf "$viewflow_sha" --arg windows "$windows_viewflow_sha" \
        --arg release "$release_sha" '
        def positive_integer: type == "number" and . == floor and . > 0;
        def ack_keys: keys == ["acked_unique_sequence_count","duplicate_ack_count","late_ack_rejection_count","replay_rejection_count"];
        def ack_valid: ack_keys and ([.[]] | all(type == "number" and . == floor and . >= 0));
        def workflow: [.events[] | select(.kind != "disconnect_before_activation")];
        def coverage: ["button1_pressed","button1_released","button2_pressed","button2_released","button3_pressed","button3_released","button4_pressed","button4_released","button5_pressed","button5_released","horizontal_wheel","keyboard_pressed","keyboard_released","pointer_motion","vertical_wheel"];
        (keys == ["armed_at_unix_ms","daemon_instance_id","deployment_release_receipt_sha256","events","failure_reason","input_samples","linux_viewflow_sha256","operation_id","producer_boot_id","producer_executable_sha256","producer_pid","producer_start_ticks","protocol_version","schema_version","sidecar_protocol_version","source_display_id","state","target_device_id","windows_viewflow_sha256"]) and
        .schema_version == 1 and .state == "viewflow-post-release-acceptance-armed" and
        .operation_id == $op and .protocol_version == "2.1" and .sidecar_protocol_version == 3 and
        .source_display_id == $source and .target_device_id == $target and
        .linux_viewflow_sha256 == $vf and .windows_viewflow_sha256 == $windows and
        .deployment_release_receipt_sha256 == $release and .failure_reason == null and
        ([.events[].kind] == ["route_activated","entry_acknowledged","release_all_applied","revoke_applied","return_acknowledged","disconnect_after_return"] or
         [.events[].kind] == ["disconnect_before_activation","route_activated","entry_acknowledged","release_all_applied","revoke_applied","return_acknowledged","disconnect_after_return"]) and
        ([.events[] | select(.kind == "disconnect_before_activation")][0]? as $before |
            $before == null or (($before | keys) == ["input_ack_metrics","kind","observed_at_unix_ms","peer_epoch","peer_socket"] and
            ($before.input_ack_metrics | ack_valid) and ($before.peer_epoch | positive_integer))) and
        (workflow[0] as $route | workflow[1] as $entry | workflow[2] as $release_event |
         workflow[3] as $revoke | workflow[4] as $return | workflow[5] as $after |
            ($route | keys) == ["active_lease_generation","kind","observed_at_unix_ms","peer_epoch","peer_socket","route_generation","source_display_id","target_device_id"] and
            $route.source_display_id == $source and $route.target_device_id == $target and
            ($route.route_generation | positive_integer) and ($route.active_lease_generation | positive_integer) and
            ($route.peer_epoch | positive_integer) and
            ($entry | keys) == ["kind","observed_at_unix_ms","route_generation"] and $entry.route_generation == $route.route_generation and
            ($release_event | keys) == ["event_sequence","kind","lease_generation","observed_at_unix_ms","peer_epoch"] and
            $release_event.lease_generation == $route.active_lease_generation and ($release_event.event_sequence | positive_integer) and
            $release_event.peer_epoch == $route.peer_epoch and
            ($revoke | keys) == ["kind","lease_generation","observed_at_unix_ms","operation_id","peer_epoch"] and
            $revoke.lease_generation == ($route.active_lease_generation + 1) and $revoke.peer_epoch == $release_event.peer_epoch and
            ($revoke.operation_id | test("^[0-9a-f]{32}$")) and
            ($return | keys) == ["kind","observed_at_unix_ms","route_generation"] and $return.route_generation == $route.route_generation and
            ($after | keys) == ["input_ack_metrics","kind","observed_at_unix_ms","peer_epoch","peer_socket"] and
            $after.peer_epoch == $revoke.peer_epoch and ($after.input_ack_metrics | ack_valid)) and
        (.input_samples | length > 0) and
        ([.input_samples[].kind] | unique | sort) == coverage and
        all(.input_samples[]; (keys == ["capture_to_applied_ack_us","event_sequence","kind"]) and
            (.event_sequence | positive_integer) and
            (.capture_to_applied_ack_us | type == "number" and . == floor and . >= 0 and . <= 32000)) and
        ([range(1; (.input_samples | length)) as $i |
            .input_samples[$i].event_sequence >= .input_samples[$i - 1].event_sequence] | all)
    ' "$transcript" >/dev/null || die 'normal acceptance transcript event/HID/latency chain is invalid'
}

validate_normal_acceptance_receipt() {
    local receipt=$1 transcript=$2 release_sha transcript_sha sample_count
    release_sha=$(sha256 "$deployment_release_receipt")
    transcript_sha=$(sha256 "$transcript")
    sample_count=$(jq '[.input_samples[].event_sequence] | unique | length' "$transcript")
    jq -e --arg op "$operation_id" --arg source "$source_display_id_lower" --arg target "$target_device_id_lower" \
        --arg vf "$viewflow_sha" --arg windows "$windows_viewflow_sha" --arg release "$release_sha" \
        --arg transcript "$transcript_sha" --argjson samples "$sample_count" \
        --slurpfile control "$rust_acceptance_query_response" '
        (keys == ["accepted_sequence_strictly_increasing","acked_unique_sequence_count","completed_at_unix_ms","deployment_release_receipt_sha256","disconnect_after_return","disconnect_before_activation","disconnect_during_active_route","duplicate_ack_count","entry_return","held_inputs","late_ack_rejection_count","linux_viewflow_sha256","max_us","operation_id","p99_us","producer_boot_id","producer_executable_sha256","producer_pid","producer_start_ticks","protocol_version","replay_rejection_count","route_admission","runtime_marker_present","sample_count","schema_version","sidecar_protocol_version","source_display_id","state","target_device_id","transcript_sha256","windows_viewflow_sha256"]) and
        .schema_version == 1 and .state == "viewflow-normal-post-release-acceptance-passed" and
        .operation_id == $op and .protocol_version == "2.1" and .sidecar_protocol_version == 3 and
        .source_display_id == $source and .target_device_id == $target and
        .linux_viewflow_sha256 == $vf and .windows_viewflow_sha256 == $windows and
        .deployment_release_receipt_sha256 == $release and .transcript_sha256 == $transcript and
        .route_admission == "admitted" and .entry_return == "passed" and .held_inputs == "released" and
        (.disconnect_before_activation == "passed" or .disconnect_before_activation == "not_exercised") and
        .disconnect_during_active_route == "not_exercised_destructive" and .disconnect_after_return == "passed" and
        .runtime_marker_present == false and .sample_count == $samples and .sample_count > 0 and
        (.max_us | type == "number" and . <= 32000) and (.p99_us | type == "number" and . <= 32000) and
        .accepted_sequence_strictly_increasing == true and .acked_unique_sequence_count == (.sample_count + 1) and
        .duplicate_ack_count == 0 and .replay_rejection_count == 0 and .late_ack_rejection_count == 0 and
        .producer_pid == $control[0].producer_pid and .producer_start_ticks == $control[0].producer_start_ticks and
        .producer_boot_id == $control[0].producer_boot_id and .producer_executable_sha256 == $vf and
        .sample_count == $control[0].sample_count and .max_us == $control[0].max_us and .p99_us == $control[0].p99_us and
        .acked_unique_sequence_count == $control[0].acked_unique_sequence_count and
        .duplicate_ack_count == $control[0].duplicate_ack_count and
        .replay_rejection_count == $control[0].replay_rejection_count and
        .late_ack_rejection_count == $control[0].late_ack_rejection_count
    ' "$receipt" >/dev/null || die 'normal post-release acceptance receipt is invalid'
}

wait_for_rust_acceptance() {
    local deadline=$((SECONDS + acceptance_timeout_seconds)) temp transcript receipt
    temp=$secure_dir/rust-query-final.json
    while [[ ! -e $rust_acceptance_query_response ]] && ((SECONDS < deadline)); do
        rm -f -- "$temp"
        if "$VIEWFLOW_INSTALLED" acceptance-query --acceptance-socket "$VIEWFLOW_ACCEPTANCE_SOCKET" \
            --operation-id "$operation_id" >"$temp" 2>/dev/null; then
            assert_strict_json_document 'viewflowd acceptance query response' "$temp"
            if jq -e '.ok == true and .status == "passed"' "$temp" >/dev/null; then
                publish_json_file 'viewflowd passed query response' "$temp" "$rust_acceptance_query_response"
                validate_rust_control_identity "$rust_acceptance_query_response" passed
                break
            fi
            if jq -e '.schema_version == 1 and .ok == false and .status == "failed_closed" and
                .error == "active_route_disconnect_requires_containment" and .receipt_path == null' \
                "$temp" >/dev/null; then
                die 'active_route_disconnect_requires_containment'
            fi
            jq -e '.ok == true and .status == "pending_external_exercise" and .receipt_path == null' "$temp" >/dev/null ||
                die 'viewflowd reported failed-closed acceptance after Windows restart'
        else
            die 'viewflowd acceptance query failed after Windows restart'
        fi
        sleep 0.1
    done
    [[ -f $rust_acceptance_query_response ]] || die 'timed out waiting for after-return disconnect acceptance'
    validate_rust_control_identity "$rust_acceptance_query_response" passed
    transcript=$(jq -er '.transcript_path' "$rust_acceptance_query_response")
    receipt=$(jq -er '.receipt_path' "$rust_acceptance_query_response")
    [[ $receipt == "$VIEWFLOW_ACCEPTANCE_STATE_DIR/post-release-$operation_id.receipt.json" ]] ||
        die 'viewflowd query named an unexpected receipt path'
    validate_normal_acceptance_transcript "$transcript"
    [[ $(sha256 "$transcript") == "$(jq -er '.transcript_sha256' "$rust_acceptance_query_response")" ]] ||
        die 'viewflowd query transcript hash does not match durable bytes'
    assert_strict_json_document 'durable normal acceptance receipt' "$receipt"
    validate_normal_acceptance_receipt "$receipt" "$transcript"
    if [[ -e $post_release_receipt ]]; then
        assert_strict_json_document 'existing normal post-release acceptance receipt' "$post_release_receipt"
        [[ $(sha256 "$post_release_receipt") == "$(sha256 "$receipt")" ]] ||
            die 'existing normal post-release acceptance receipt differs from producer bytes'
        validate_normal_acceptance_receipt "$post_release_receipt" "$transcript"
    else
        copy_json_output 'normal post-release acceptance receipt' "$receipt" "$post_release_receipt"
    fi
    [[ ! -e $DEPLOYMENT_MARKER && ! -e $RUNTIME_MARKER ]] || die 'final marker state is not clean'
}

graceful_linux_containment() {
    systemctl --user stop "$DESKFLOW_UNIT" >/dev/null 2>&1 || true
    systemctl --user stop "$VIEWFLOW_UNIT" >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    assert_linux_inactive
}

classify_runtime_after_containment() {
    if ((released_marker == 0)) && assert_deployment_marker && [[ ! -e $RUNTIME_MARKER ]]; then
        runtime_recovery_state=pre_release
        return
    fi
    if [[ -f $cpp_cleanup_receipt ]] && validate_cpp_cleanup_receipt; then
        [[ ! -e $RUNTIME_MARKER ]] || die 'verified normal cleanup did not leave VFQST002 absent'
        runtime_recovery_state=cleaned
        return
    fi
    assert_runtime_marker_retained ||
        die 'recovery found neither a verified normal cleanup nor strict owner-retained VFQST002'
    runtime_recovery_state=retained
}

assert_recovery_runtime_state() {
    if [[ $runtime_recovery_state == pre_release ]]; then
        [[ ! -e $RUNTIME_MARKER ]] || die 'VFQST002 appeared although deployment quarantine was never released'
    elif [[ $runtime_recovery_state == cleaned ]]; then
        [[ ! -e $RUNTIME_MARKER ]] || die 'VFQST002 reappeared after verified normal cleanup'
    elif [[ $runtime_recovery_state == retained ]]; then
        assert_runtime_marker_retained || die 'uncertain cleanup lost owner-retained VFQST002'
    else
        die 'runtime recovery state was not classified'
    fi
}

validate_linux_deactivation_proof() {
    local transcript_sha
    transcript_sha=$(sha256 "$linux_deactivation_transcript")
    assert_strict_json_document 'Linux deactivation proof' "$linux_deactivation_proof"
    jq -e --arg op "$operation_id" --arg transcript "$transcript_sha" \
        --arg marker_path "$MARKER_CLI" --arg marker_sha "$old_marker_cli_sha" \
        --arg viewflow_path "$VIEWFLOW_INSTALLED" --arg viewflow_sha "$old_viewflow_sha" \
        --arg deskflow_path "$DESKFLOW_INSTALLED" --arg deskflow_sha "$old_deskflow_sha" \
        --arg core_path "$DESKFLOW_CORE_INSTALLED" --arg core_sha "$old_deskflow_core_sha" \
        --arg unit_path "$VIEWFLOW_UNIT_INSTALLED" --arg unit_sha "$old_viewflow_unit_sha" \
        --arg dropin_path "$DESKFLOW_DROPIN_INSTALLED" --arg dropin_sha "$old_deskflow_dropin_sha" '
        (keys == ["identity","installed_artifacts","loaded_configuration","observation","operation_id","schema_version","state","stopped_runtime"]) and
        .schema_version == 3 and .state == "viewflow-linux-deactivated" and .operation_id == $op and
        (.installed_artifacts | keys) == ["deployment_marker_tool","deskflow","deskflow_core","deskflow_dropin","viewflow_unit","viewflowd"] and
        .installed_artifacts.deployment_marker_tool.path == $marker_path and
        .installed_artifacts.deployment_marker_tool.sha256 == $marker_sha and
        .installed_artifacts.viewflowd == {path:$viewflow_path,sha256:$viewflow_sha} and
        .installed_artifacts.deskflow == {path:$deskflow_path,sha256:$deskflow_sha} and
        .installed_artifacts.deskflow_core == {path:$core_path,sha256:$core_sha} and
        .installed_artifacts.viewflow_unit == {path:$unit_path,sha256:$unit_sha} and
        .installed_artifacts.deskflow_dropin == {path:$dropin_path,sha256:$dropin_sha} and
        .stopped_runtime.deployment_marker_tool.exact_process_count == 0 and
        .observation.command_output_sha256 == $transcript and
        .stopped_runtime.deskflow.unit_active_state == "inactive" and .stopped_runtime.deskflow.main_pid == 0 and
        .stopped_runtime.viewflow.unit_active_state == "inactive" and .stopped_runtime.viewflow.main_pid == 0
    ' "$linux_deactivation_proof" >/dev/null
}

make_recovery_bundle() {
    local output=$1 created proof_sha transcript_sha runtime_sha evidence_sha observation_sha temp
    local proof_name transcript_name runtime_name evidence_name observation_name
    if [[ -e $output ]]; then validate_recovery_bundle "$output"; return; fi
    temp=$(mktemp --tmpdir="$(dirname -- "$output")" '.viewflow-recovery-bundle.XXXXXX')
    chmod 0600 "$temp"
    created=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    if [[ $rollback_mode == bootstrap-v1.3 ]]; then
        proof_sha=$(sha256 "$linux_deactivation_proof")
        transcript_sha=$(sha256 "$linux_deactivation_transcript")
        proof_name=$(windows_fixed_leaf "$windows_operation_root\\linux-deactivation-proof.json")
        transcript_name=$(windows_fixed_leaf "$windows_operation_root\\linux-deactivation-transcript.json")
        jq -cn --arg op "$operation_id" --arg manifest "$remote_manifest_sha" \
            --arg token "$remote_token_sha" --arg proof_name "$proof_name" \
            --arg proof "$proof_sha" --arg transcript_name "$transcript_name" \
            --arg transcript "$transcript_sha" --arg created "$created" \
            '{schema_version:1,state:"viewflow-cross-host-recovery-authorized",rollback_mode:"bootstrap-v1.3",operation_id:$op,rollback_manifest_sha256:$manifest,rollback_token_sha256:$token,linux_deactivation_proof_file_name:$proof_name,linux_deactivation_proof_sha256:$proof,linux_deactivation_transcript_file_name:$transcript_name,linux_deactivation_transcript_sha256:$transcript,created_at_utc:$created}' >"$temp"
    else
        runtime_sha=$(sha256 "$normal_runtime_receipt")
        evidence_sha=$(sha256 "$normal_daemon_exit_evidence")
        observation_sha=$(sha256 "$normal_daemon_exit_observation")
        runtime_name=$(windows_fixed_leaf "$windows_operation_root\\runtime-receipt.json")
        evidence_name=$(windows_fixed_leaf "$windows_operation_root\\daemon-exit-evidence.json")
        observation_name=$(windows_fixed_leaf "$windows_operation_root\\daemon-exit-observation.json")
        jq -cn --arg op "$operation_id" --arg manifest "$remote_manifest_sha" --arg token "$remote_token_sha" \
            --arg runtime_name "$runtime_name" --arg runtime "$runtime_sha" \
            --arg evidence_name "$evidence_name" --arg evidence "$evidence_sha" \
            --arg observation_name "$observation_name" --arg observation "$observation_sha" \
            --arg created "$created" \
            '{schema_version:1,state:"viewflow-cross-host-recovery-authorized",rollback_mode:"normal-v2",operation_id:$op,rollback_manifest_sha256:$manifest,rollback_token_sha256:$token,runtime_receipt_file_name:$runtime_name,runtime_receipt_sha256:$runtime,daemon_exit_evidence_file_name:$evidence_name,daemon_exit_evidence_sha256:$evidence,daemon_exit_observation_file_name:$observation_name,daemon_exit_observation_sha256:$observation,created_at_utc:$created}' >"$temp"
    fi
    sync -f "$temp"
    publish_new_file "$temp" "$output"
    rm -f -- "$temp"
    validate_recovery_bundle "$output"
}

validate_recovery_bundle() {
    local path=$1 proof_name transcript_name runtime_name evidence_name observation_name
    proof_name=$(windows_fixed_leaf "$windows_operation_root\\linux-deactivation-proof.json")
    transcript_name=$(windows_fixed_leaf "$windows_operation_root\\linux-deactivation-transcript.json")
    runtime_name=$(windows_fixed_leaf "$windows_operation_root\\runtime-receipt.json")
    evidence_name=$(windows_fixed_leaf "$windows_operation_root\\daemon-exit-evidence.json")
    observation_name=$(windows_fixed_leaf "$windows_operation_root\\daemon-exit-observation.json")
    assert_strict_json_document 'durable recovery bundle' "$path"
    jq -e --arg op "$operation_id" --arg mode "$rollback_mode" --arg manifest "$remote_manifest_sha" \
        --arg token "$remote_token_sha" --arg proof "$(sha_if_regular "$linux_deactivation_proof")" \
        --arg transcript "$(sha_if_regular "$linux_deactivation_transcript")" \
        --arg runtime "$(sha_if_regular "$normal_runtime_receipt")" --arg evidence "$(sha_if_regular "$normal_daemon_exit_evidence")" \
        --arg observation "$(sha_if_regular "$normal_daemon_exit_observation")" \
        --arg proof_name "$proof_name" --arg transcript_name "$transcript_name" \
        --arg runtime_name "$runtime_name" --arg evidence_name "$evidence_name" --arg observation_name "$observation_name" '
        .schema_version == 1 and .state == "viewflow-cross-host-recovery-authorized" and
        .operation_id == $op and .rollback_mode == $mode and
        .rollback_manifest_sha256 == $manifest and .rollback_token_sha256 == $token and
        (.created_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
        (if $mode == "bootstrap-v1.3" then
            .linux_deactivation_proof_file_name == $proof_name and .linux_deactivation_transcript_file_name == $transcript_name and
            .linux_deactivation_proof_sha256 == $proof and .linux_deactivation_transcript_sha256 == $transcript
         else .runtime_receipt_file_name == $runtime_name and .daemon_exit_evidence_file_name == $evidence_name and
              .daemon_exit_observation_file_name == $observation_name and .runtime_receipt_sha256 == $runtime and
              .daemon_exit_evidence_sha256 == $evidence and .daemon_exit_observation_sha256 == $observation end)
    ' "$path" >/dev/null || die 'durable recovery bundle changed or is invalid'
}

run_windows_rollback() {
    local bundle=$local_recovery_bundle proof_path transcript_path
    local runtime_path evidence_path observation_path command validation_command rollback_replayed=0 status=0
    local claim=$secure_dir/windows-rollback-dispatch-claim.json remote_claim=$secure_dir/windows-rollback-dispatch-claim.remote.json claim_b64
    if windows_remote_exists "$windows_rollback_receipt_path"; then
        sync_remote_receipt 'Windows rollback receipt replay' "$windows_rollback_receipt_path" "$local_windows_rollback_receipt"
        rollback_replayed=1
    elif windows_remote_exists "$windows_rollback_claim_path"; then
        make_recovery_bundle "$bundle"
        windows_read_file "$windows_rollback_claim_path" "$remote_claim"
        assert_strict_json_document 'Windows rollback dispatch claim' "$remote_claim"
        jq -e --arg op "$operation_id" --arg mode "$rollback_mode" --arg bundle "$(sha256 "$bundle")" '
            keys == ["operation_id","recovery_bundle_sha256","rollback_mode","schema_version","state"] and
            .schema_version == 1 and .state == "viewflow-windows-rollback-dispatch-claimed" and
            .operation_id == $op and .rollback_mode == $mode and .recovery_bundle_sha256 == $bundle
        ' "$remote_claim" >/dev/null || die 'Windows rollback dispatch claim is invalid'
        die 'uncertain: rollback dispatch claim exists without a terminal receipt; non-idempotent rollback will not replay'
    fi
    if ((rollback_replayed == 0)); then
        make_recovery_bundle "$bundle"
    fi
    if ((rollback_replayed)); then
        :
    elif [[ $rollback_mode == bootstrap-v1.3 ]]; then
        proof_path="$windows_operation_root\\linux-deactivation-proof.json"
        transcript_path="$windows_operation_root\\linux-deactivation-transcript.json"
        require_windows_absolute_path 'manifest Linux proof path' "$proof_path"
        require_windows_absolute_path 'manifest Linux transcript path' "$transcript_path"
        windows_create_or_verify "$linux_deactivation_proof" "$proof_path"
        windows_create_or_verify "$linux_deactivation_transcript" "$transcript_path"
        validation_command="& '$WINDOWS_ROLLBACK_SCRIPT' -ManifestPath '$windows_rollback_manifest_path' -TokenPath '$windows_rollback_token_path' -RecoveryBundlePath '$windows_recovery_bundle_path' -RecoveryForceReleaseReceiptPath '$windows_recovery_force_receipt_path' -LinuxDeactivationProofPath '$proof_path' -LinuxDeactivationTranscriptPath '$transcript_path' -ValidateOnly"
        command="& '$WINDOWS_ROLLBACK_SCRIPT' -ManifestPath '$windows_rollback_manifest_path' -TokenPath '$windows_rollback_token_path' -RecoveryBundlePath '$windows_recovery_bundle_path' -RecoveryForceReleaseReceiptPath '$windows_recovery_force_receipt_path' -LinuxDeactivationProofPath '$proof_path' -LinuxDeactivationTranscriptPath '$transcript_path' -ReceiptPath '$windows_rollback_receipt_path'"
    else
        runtime_path="$windows_operation_root\\runtime-receipt.json"
        evidence_path="$windows_operation_root\\daemon-exit-evidence.json"
        observation_path="$windows_operation_root\\daemon-exit-observation.json"
        require_windows_absolute_path 'manifest runtime receipt path' "$runtime_path"
        require_windows_absolute_path 'manifest daemon evidence path' "$evidence_path"
        require_windows_absolute_path 'manifest daemon observation path' "$observation_path"
        windows_create_or_verify "$normal_runtime_receipt" "$runtime_path"
        windows_create_or_verify "$normal_daemon_exit_evidence" "$evidence_path"
        windows_create_or_verify "$normal_daemon_exit_observation" "$observation_path"
        validation_command="& '$WINDOWS_ROLLBACK_SCRIPT' -ManifestPath '$windows_rollback_manifest_path' -TokenPath '$windows_rollback_token_path' -RecoveryBundlePath '$windows_recovery_bundle_path' -RecoveryForceReleaseReceiptPath '$windows_recovery_force_receipt_path' -RuntimeReceiptPath '$runtime_path' -DaemonExitEvidencePath '$evidence_path' -DaemonExitObservationPath '$observation_path' -ValidateOnly"
        command="& '$WINDOWS_ROLLBACK_SCRIPT' -ManifestPath '$windows_rollback_manifest_path' -TokenPath '$windows_rollback_token_path' -RecoveryBundlePath '$windows_recovery_bundle_path' -RecoveryForceReleaseReceiptPath '$windows_recovery_force_receipt_path' -RuntimeReceiptPath '$runtime_path' -DaemonExitEvidencePath '$evidence_path' -DaemonExitObservationPath '$observation_path' -ReceiptPath '$windows_rollback_receipt_path'"
    fi
    if ((rollback_replayed == 0)); then
        windows_create_or_verify "$bundle" "$windows_recovery_bundle_path"
        if [[ ! -e $local_windows_validation ]]; then
            capture_json_command 'Windows rollback validation' "$local_windows_validation" ssh_windows "$validation_command"
        fi
        jq -cn --arg op "$operation_id" --arg mode "$rollback_mode" --arg bundle "$(sha256 "$bundle")" \
            '{schema_version:1,state:"viewflow-windows-rollback-dispatch-claimed",operation_id:$op,rollback_mode:$mode,recovery_bundle_sha256:$bundle}' >"$claim"
        claim_b64=$(base64 -w0 -- "$claim")
        command="\$claimPath='$windows_rollback_claim_path';\$claimBytes=[Convert]::FromBase64String('$claim_b64');\$claimStream=[IO.File]::Open(\$claimPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{\$claimStream.Write(\$claimBytes,0,\$claimBytes.Length);\$claimStream.Flush(\$true)}finally{\$claimStream.Dispose()};$command"
        if ssh_windows "$command" >/dev/null; then status=0; else status=$?; fi
        windows_remote_exists "$windows_rollback_receipt_path" || {
            ((status == 0)) || return "$status"
            die 'Windows rollback returned without a durable terminal receipt'
        }
        windows_read_file "$windows_rollback_receipt_path" "$local_windows_rollback_receipt"
    fi
    if ((rollback_replayed == 0)); then
        jq -e --arg op "$operation_id" --arg mode "$rollback_mode" '
            .schema_version == 1 and .state == "viewflow-windows-rollback-validation-succeeded" and
            .operation_id == $op and .rollback_mode == $mode
        ' "$local_windows_validation" >/dev/null || die 'Windows rollback ValidateOnly receipt is invalid'
    fi
    assert_strict_json_document 'Windows rollback receipt' "$local_windows_rollback_receipt"
    jq -e --arg op "$operation_id" --arg mode "$rollback_mode" \
        --arg manifest "$remote_manifest_sha" --arg token "$remote_token_sha" '
        .schema_version == 2 and .state == "viewflow-windows-rollback-completed" and
        .operation_id == $op and .rollback_mode == $mode and .manifest_sha256 == $manifest and
        .token_sha256 == $token and .task_state == "Ready" and .exact_process_count == 0 and
        (if $mode == "bootstrap-v1.3" then
            has("linux_deactivation_proof_sha256") and has("linux_deactivation_transcript_sha256") and
            (has("runtime_receipt_sha256") | not) and (has("daemon_exit_evidence_sha256") | not) and
            (has("daemon_exit_observation_sha256") | not)
         else
            has("runtime_receipt_sha256") and has("daemon_exit_evidence_sha256") and
            has("daemon_exit_observation_sha256") and (has("linux_deactivation_proof_sha256") | not) and
            (has("linux_deactivation_transcript_sha256") | not)
         end)
    ' "$local_windows_rollback_receipt" >/dev/null || die 'Windows rollback completion receipt is invalid'
}

recover_both_hosts() {
    local status=${1:-1} proof_count runtime_marker_state
    trap - ERR INT TERM EXIT
    ((recovery_running == 0 && recovery_finished == 0)) || finish_recovery "$RECOVERY_FAILURE_EXIT"
    recovery_running=1
    original_failure=$status
    if [[ $(phase_rank "$phase") -ge $(phase_rank STOP_INTENT) ]]; then
        recovery_failure_phase=$(jq -er '.recovery.failure_phase' "$coordinator_state")
        recovery_mutation_possible=$(jq -r '.recovery.mutation_possible' "$coordinator_state")
        case $recovery_mutation_possible in
            true|1) recovery_mutation_possible=1 ;;
            false|0) recovery_mutation_possible=0 ;;
            *) finish_recovery "$RECOVERY_FAILURE_EXIT" ;;
        esac
    else
        recovery_failure_phase=$phase
        if [[ $(phase_rank "$phase") -ge $(phase_rank WINDOWS_PERMIT_PUBLISH_INTENT) ]]; then
            recovery_mutation_possible=1
        else
            recovery_mutation_possible=0
        fi
    fi
    coordinator_event RECOVERY_BEGIN
    commit_phase STOP_INTENT
    if [[ $(phase_rank "$phase") -lt $(phase_rank STOPPED) ]]; then
        stop_exact_windows_bootstrap || finish_recovery "$RECOVERY_FAILURE_EXIT"
        commit_phase STOPPED
    else
        validate_windows_stop_evidence "$local_windows_stop_evidence" || finish_recovery "$RECOVERY_FAILURE_EXIT"
    fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_RECOVERED) ]]; then
        graceful_linux_containment || finish_recovery "$RECOVERY_FAILURE_EXIT"
        republish_deployment_marker_for_recovery || finish_recovery "$RECOVERY_FAILURE_EXIT"
        if [[ -z $windows_task_xml_sha && -f $bootstrap_windows_install_receipt ]]; then
            validate_windows_W_schema5 || finish_recovery "$RECOVERY_FAILURE_EXIT"
        fi
        rollback_linux_two_phase || finish_recovery "$RECOVERY_FAILURE_EXIT"
        graceful_linux_containment || finish_recovery "$RECOVERY_FAILURE_EXIT"
        classify_runtime_after_containment || finish_recovery "$RECOVERY_FAILURE_EXIT"
        capture_old_linux_hashes || finish_recovery "$RECOVERY_FAILURE_EXIT"
        if [[ $rollback_mode == bootstrap-v1.3 ]]; then
            proof_count=0
            [[ -e $linux_deactivation_transcript ]] && ((proof_count += 1))
            [[ -e $linux_deactivation_proof ]] && ((proof_count += 1))
            if ((proof_count == 0)); then
                [[ $runtime_recovery_state == retained ]] && runtime_marker_state=retained || runtime_marker_state=absent
                assert_old_linux_hashes || finish_recovery "$RECOVERY_FAILURE_EXIT"
                "$linux_deactivator" --viewflow-sha256 "$old_viewflow_sha" \
                    --deployment-marker-sha256 "$old_marker_cli_sha" \
                    --deskflow-sha256 "$old_deskflow_sha" --deskflow-core-sha256 "$old_deskflow_core_sha" \
                    --viewflow-unit-sha256 "$old_viewflow_unit_sha" \
                    --deskflow-dropin-sha256 "$old_deskflow_dropin_sha" --operation-id "$operation_id" \
                    --runtime-marker-state "$runtime_marker_state" \
                    --bootstrap-v1.3-legacy-config \
                    --transcript-output "$linux_deactivation_transcript" --proof-output "$linux_deactivation_proof" ||
                    finish_recovery "$RECOVERY_FAILURE_EXIT"
            elif ((proof_count != 2)); then
                die 'partial Linux deactivation proof publication is uncertain' || finish_recovery "$RECOVERY_FAILURE_EXIT"
            fi
            validate_linux_deactivation_proof || finish_recovery "$RECOVERY_FAILURE_EXIT"
        fi
        assert_linux_inactive || finish_recovery "$RECOVERY_FAILURE_EXIT"
        assert_deployment_marker || finish_recovery "$RECOVERY_FAILURE_EXIT"
        assert_recovery_runtime_state || finish_recovery "$RECOVERY_FAILURE_EXIT"
        commit_phase LINUX_RECOVERED
    else
        republish_deployment_marker_for_recovery || finish_recovery "$RECOVERY_FAILURE_EXIT"
        classify_runtime_after_containment || finish_recovery "$RECOVERY_FAILURE_EXIT"
        capture_old_linux_hashes || finish_recovery "$RECOVERY_FAILURE_EXIT"
        if [[ $rollback_mode == bootstrap-v1.3 ]]; then validate_linux_deactivation_proof || finish_recovery "$RECOVERY_FAILURE_EXIT"; fi
    fi
    assert_linux_inactive || finish_recovery "$RECOVERY_FAILURE_EXIT"
    assert_deployment_marker || finish_recovery "$RECOVERY_FAILURE_EXIT"
    assert_recovery_runtime_state || finish_recovery "$RECOVERY_FAILURE_EXIT"
    commit_phase LINUX_RECOVERED
    if ((recovery_mutation_possible)); then
        commit_phase WINDOWS_ROLLBACK_INTENT
        run_windows_rollback || finish_recovery "$RECOVERY_FAILURE_EXIT"
        commit_phase WINDOWS_ROLLED_BACK
    fi
    assert_linux_inactive || finish_recovery "$RECOVERY_FAILURE_EXIT"
    assert_deployment_marker || finish_recovery "$RECOVERY_FAILURE_EXIT"
    assert_recovery_runtime_state || finish_recovery "$RECOVERY_FAILURE_EXIT"
    coordinator_event RECOVERY_DONE
    finish_recovery "$original_failure"
}

handle_err() {
    local status=$?
    ((recovery_required)) && recover_both_hosts "$status"
    exit "$status"
}

handle_signal() {
    local status=$1
    ((recovery_required)) && recover_both_hosts "$status"
    exit "$status"
}

handle_exit() {
    local status=$?
    if ((recovery_required && recovery_running == 0)); then
        ((status != 0)) || status=$RECOVERY_FAILURE_EXIT
        recover_both_hosts "$status"
    fi
    cleanup_secure_dir
}

preflight() {
    local label path
    [[ $(id -u) == 1000 && $HOME == /home/wilf ]] || die 'run as uid 1000 with HOME=/home/wilf'
    for label in base64 bash date dd env grep iconv jq journalctl ln mktemp readlink scp sha256sum ssh ss stat systemctl; do
        command -v "$label" >/dev/null || die "required command unavailable: $label"
    done
    for path in "$MARKER_CLI" "$linux_installer" "$linux_deactivator" \
        "$reviewed_rollback_script" "$VIEWFLOW_INSTALLED" "$DESKFLOW_INSTALLED" \
        "$DESKFLOW_CORE_INSTALLED" "$VIEWFLOW_UNIT_INSTALLED" "$DESKFLOW_DROPIN_INSTALLED"; do
        [[ -f $path && ! -L $path ]] || die "required installed/reviewed file is unsafe: $path"
    done
    for label in viewflow_sha deployment_marker_sha deskflow_sha deskflow_core_sha deskflow_provenance_sha \
        deskflow_acceptance_producer_sha viewflow_acceptance_recorder_sha viewflow_unit_sha deskflow_dropin_sha windows_viewflow_sha windows_wrapper_sha \
        windows_task_xml_sha; do require_sha256 "--${label//_/-}" "${!label}"; done
    [[ $deskflow_acceptance_producer_sha == "$deskflow_core_sha" ]] ||
        die 'C++ acceptance producer SHA must equal the deployed deskflow-core artifact SHA'
    [[ $viewflow_acceptance_recorder_sha == "$viewflow_sha" ]] ||
        die 'Rust acceptance recorder SHA must equal the deployed viewflowd artifact SHA'
    [[ $operation_id =~ ^[A-Za-z0-9_-]{16,128}$ ]] || die 'invalid operation ID'
    require_uuid '--coordinator-instance-id' "$coordinator_instance_id"
    require_uuid '--source-display-id' "$source_display_id"
    require_uuid '--target-device-id' "$target_device_id"
    source_display_id_lower=$(lower_id "$source_display_id")
    target_device_id_lower=$(lower_id "$target_device_id")
    [[ $acceptance_timeout_seconds =~ ^[1-9][0-9]{0,3}$ && $acceptance_timeout_seconds -le 3600 ]] ||
        die '--acceptance-timeout-seconds must be in 1..3600'
    require_u64 '--marker-generation' "$marker_generation"
    require_u64 '--recovery-marker-generation' "$recovery_marker_generation"
    [[ $marker_generation != "$recovery_marker_generation" ]] ||
        die 'normal and recovery marker generations must differ'
    [[ $windows_user_sid =~ ^S-1-[0-9-]+$ ]] || die 'invalid Windows SID'
    for path in "$viewflow_candidate" "$deployment_marker_candidate" "$deskflow_candidate" "$deskflow_core_candidate" \
        "$deskflow_provenance_manifest" "$viewflow_unit_candidate" "$deskflow_dropin_candidate" \
        "$bootstrap_linux_evidence" "$bootstrap_windows_force_receipt" \
        "$bootstrap_windows_install_receipt"; do require_absolute_input 'local input' "$path"; done
    [[ $(sha256 "$viewflow_candidate") == "$viewflow_sha" &&
       $(sha256 "$deployment_marker_candidate") == "$deployment_marker_sha" &&
       $(sha256 "$deskflow_candidate") == "$deskflow_sha" &&
       $(sha256 "$deskflow_core_candidate") == "$deskflow_core_sha" &&
       $(sha256 "$deskflow_provenance_manifest") == "$deskflow_provenance_sha" &&
       $(sha256 "$viewflow_unit_candidate") == "$viewflow_unit_sha" &&
       $(sha256 "$deskflow_dropin_candidate") == "$deskflow_dropin_sha" ]] ||
        die 'candidate hash mismatch'
    for path in "$windows_readiness_receipt_path" "$windows_readiness_lock_path" \
        "$windows_rollback_manifest_path" "$windows_rollback_token_path" \
        "$windows_recovery_bundle_path" "$windows_recovery_force_receipt_path" \
        "$windows_rollback_receipt_path"; do require_windows_absolute_path 'Windows recovery path' "$path"; done
    for path in "$deployment_publish_receipt" "$recovery_deployment_publish_receipt" \
        "$deployment_release_receipt" "$cpp_status_response" "$cpp_arm_response" "$cpp_cleanup_receipt" \
        "$rust_acceptance_arm_response" "$rust_acceptance_query_response" "$post_release_receipt" \
        "$windows_restart_receipt" "$linux_host_proof" "$linux_deactivation_transcript" \
        "$linux_deactivation_proof" "$linux_containment_transcript" \
        "$local_windows_validation" "$local_windows_rollback_receipt"; do
        require_absolute_new_output 'evidence output' "$path"
    done
    secure_dir=$(mktemp -d)
    chmod 0700 "$secure_dir"
    remote_manifest_snapshot=$secure_dir/rollback-manifest.json
    remote_token_snapshot=$secure_dir/rollback-token.json
    validate_provenance
    grep -Fq -- '--acceptance-socket %t/viewflow/post-release-acceptance.sock --acceptance-state-dir /home/wilf/.local/state/viewflow/post-release-acceptance' "$viewflow_unit_candidate" ||
        die 'Viewflow unit lacks the frozen acceptance socket/state-dir contract'
    grep -Fq -- 'Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock' "$deskflow_dropin_candidate" ||
        die 'Deskflow drop-in lacks the frozen live-core acceptance socket contract'
    "$windows_static_checker"
    "$linux_transaction_checker"
    "$linux_deactivation_checker"
    capture_old_linux_hashes
    prearm_windows_recovery
    if [[ $rollback_mode == normal-v2 ]]; then
        require_absolute_input '--normal-runtime-receipt' "$normal_runtime_receipt"
        require_absolute_input '--normal-daemon-exit-evidence' "$normal_daemon_exit_evidence"
        require_absolute_input '--normal-daemon-exit-observation' "$normal_daemon_exit_observation"
    fi
}

run_linux_transaction() {
    phase=LINUX_INSTALLING
    "$linux_installer" --viewflow-candidate "$viewflow_candidate" --viewflow-sha256 "$viewflow_sha" \
        --deployment-marker-candidate "$deployment_marker_candidate" \
        --deployment-marker-sha256 "$deployment_marker_sha" \
        --deskflow-candidate "$deskflow_candidate" --deskflow-sha256 "$deskflow_sha" \
        --deskflow-core-candidate "$deskflow_core_candidate" --deskflow-core-sha256 "$deskflow_core_sha" \
        --deskflow-provenance-manifest "$deskflow_provenance_manifest" \
        --deskflow-provenance-sha256 "$deskflow_provenance_sha" \
        --viewflow-unit-candidate "$viewflow_unit_candidate" --viewflow-unit-sha256 "$viewflow_unit_sha" \
        --deskflow-dropin-candidate "$deskflow_dropin_candidate" \
        --deskflow-dropin-sha256 "$deskflow_dropin_sha" --operation-id "$operation_id" \
        --bootstrap-linux-evidence "$bootstrap_linux_evidence" \
        --bootstrap-windows-force-receipt "$bootstrap_windows_force_receipt" \
        --bootstrap-windows-install-receipt "$bootstrap_windows_install_receipt" \
        --windows-viewflow-sha256 "$windows_viewflow_sha" --windows-wrapper-sha256 "$windows_wrapper_sha" \
        --windows-task-xml-sha256 "$windows_task_xml_sha" --windows-user-sid "$windows_user_sid"
    phase=LINUX_READY
}

bootstrap_preflight() {
    local label path
    [[ $(id -u) == 1000 && $HOME == /home/wilf ]] || die 'run as uid 1000 with HOME=/home/wilf'
    for label in base64 bash date dd iconv jq journalctl ln mktemp mv od python3 readlink scp sha256sum ssh ss stat sync systemctl unlink; do
        command -v "$label" >/dev/null || die "required command unavailable: $label"
    done
    [[ $operation_id =~ ^[0-9a-f]{32}$ ]] || die '--operation-id must be exactly 32 lowercase hex characters'
    derive_windows_paths
    local_recovery_bundle="${coordinator_state}.recovery-bundle.json"
    local_windows_stop_evidence="${coordinator_state}.windows-stop-evidence.json"
    local_windows_restart_intent="${coordinator_state}.windows-restart-intent.json"
    recovery_publish_intent="${recovery_deployment_publish_receipt}.intent.json"
    pre_mutation_retry_proof="${coordinator_state}.pre-mutation-retry.json"
    pre_mutation_start_state_candidate="${coordinator_state}.pre-mutation-start-intent.v1.json"
    pre_mutation_stop_state_claim="${coordinator_state}.pre-mutation-stop-claim.v1"
    for label in viewflow_sha deployment_marker_sha deskflow_sha deskflow_core_sha deskflow_provenance_sha \
        deskflow_acceptance_producer_sha viewflow_acceptance_recorder_sha viewflow_unit_sha deskflow_dropin_sha \
        windows_viewflow_sha windows_wrapper_sha windows_launcher_sha windows_installer_sha \
        windows_rollback_script_sha; do require_sha256 "--${label//_/-}" "${!label}"; done
    [[ -z $windows_task_xml_sha ]] || require_sha256 '--windows-task-xml-sha256' "$windows_task_xml_sha"
    if ((resume_pre_mutation_stop_intent)); then
        require_sha256 '--pre-mutation-old-executable-sha256' "$pre_mutation_old_executable_sha"
        require_sha256 '--pre-mutation-old-wrapper-sha256' "$pre_mutation_old_wrapper_sha"
        require_sha256 '--pre-mutation-old-task-xml-sha256' "$pre_mutation_old_task_xml_sha"
        [[ $pre_mutation_old_process_id =~ ^[1-9][0-9]*$ && $pre_mutation_old_parent_process_id =~ ^[1-9][0-9]*$ ]] ||
            die 'pre-mutation old process IDs must be positive decimal integers'
        [[ $pre_mutation_old_process_creation_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z$ ]] ||
            die 'pre-mutation old process creation date must be canonical UTC with seven fractional digits'
        [[ -n $pre_mutation_stop_state_baseline_path ]] ||
            die '--pre-mutation-stop-state-baseline-path is required for the special resume'
        require_sha256 '--pre-mutation-stop-state-baseline-sha256' "$pre_mutation_stop_state_baseline_sha"
    elif [[ -n $pre_mutation_old_executable_sha || -n $pre_mutation_old_wrapper_sha || -n $pre_mutation_old_task_xml_sha ||
            -n $pre_mutation_old_process_id || -n $pre_mutation_old_parent_process_id || -n $pre_mutation_old_process_creation_date ||
            -n $pre_mutation_stop_state_baseline_path || -n $pre_mutation_stop_state_baseline_sha ]]; then
        die 'pre-mutation identity hashes require --resume-pre-mutation-stop-intent'
    fi
    windows_task_xml_override=$windows_task_xml_sha
    require_uuid '--coordinator-instance-id' "$coordinator_instance_id"
    require_uuid '--source-display-id' "$source_display_id"
    require_uuid '--target-device-id' "$target_device_id"
    require_u64 '--marker-generation' "$marker_generation"
    require_u64 '--recovery-marker-generation' "$recovery_marker_generation"
    [[ $marker_generation == 1 && $recovery_marker_generation == 2 ]] ||
        die 'bootstrap handoff/recovery generations must be exactly 1/2'
    recovery_operation_id="${operation_id}_recovery"
    [[ $windows_user_sid =~ ^S-1-[0-9]+(-[0-9]+)+$ ]] || die 'invalid Windows SID'
    [[ $bootstrap_timeout_seconds =~ ^[1-9][0-9]*$ && $bootstrap_timeout_seconds -le 3600 ]] || die 'invalid bootstrap timeout'
    source_display_id_lower=$(lower_id "$source_display_id"); target_device_id_lower=$(lower_id "$target_device_id")
    coordinator_instance_id_lower=$(lower_id "$coordinator_instance_id")
    [[ $source_display_id_lower == 00000000000000000000000000000101 &&
       $target_device_id_lower == 00000000000000000000000000000002 ]] ||
        die 'bootstrap source/target IDs differ from the frozen Windows topology'
    require_bootstrap_deactivation_transport_leaf
    bootstrap_linux_original=$bootstrap_linux_evidence
    windows_force_original=$windows_force_envelope
    windows_install_original=$bootstrap_windows_install_receipt
    [[ ! -f $linux_finalize_receipt ]] || assert_strict_json_document 'existing Linux finalize receipt' "$linux_finalize_receipt"
    adopt_consume_intent_inputs
    for path in "$viewflow_candidate" "$deployment_marker_candidate" "$deskflow_candidate" "$deskflow_core_candidate" \
        "$deskflow_provenance_manifest" "$viewflow_unit_candidate" "$deskflow_dropin_candidate" \
        "$windows_viewflow_candidate" "$windows_wrapper_candidate" "$windows_launcher_candidate" \
        "$windows_installer_candidate" "$bootstrap_handoff_receipt" "$bootstrap_linux_evidence" \
        "$deployment_publish_receipt"; do require_absolute_input 'bootstrap input' "$path"; done
    [[ $(sha256 "$viewflow_candidate") == "$viewflow_sha" &&
       $(sha256 "$deployment_marker_candidate") == "$deployment_marker_sha" &&
       $(sha256 "$deskflow_candidate") == "$deskflow_sha" &&
       $(sha256 "$deskflow_core_candidate") == "$deskflow_core_sha" &&
       $(sha256 "$deskflow_provenance_manifest") == "$deskflow_provenance_sha" &&
       $(sha256 "$viewflow_unit_candidate") == "$viewflow_unit_sha" &&
       $(sha256 "$deskflow_dropin_candidate") == "$deskflow_dropin_sha" &&
       $(sha256 "$windows_viewflow_candidate") == "$windows_viewflow_sha" &&
       $(sha256 "$windows_wrapper_candidate") == "$windows_wrapper_sha" &&
       $(sha256 "$windows_launcher_candidate") == "$windows_launcher_sha" &&
       $(sha256 "$windows_installer_candidate") == "$windows_installer_sha" &&
       $(sha256 "$reviewed_rollback_script") == "$windows_rollback_script_sha" ]] || die 'candidate hash mismatch'
    [[ $deskflow_acceptance_producer_sha == "$deskflow_core_sha" && $viewflow_acceptance_recorder_sha == "$viewflow_sha" ]] ||
        die 'acceptance producers must be the deployed binaries'
    validate_candidate_replacement_lineage
    for path in "$windows_bootstrap_request" "$windows_prepared_receipt" "$windows_mutation_permit" \
        "$windows_force_envelope" "$linux_stage_receipt" "$bootstrap_windows_install_receipt" \
        "$windows_installer_exit_receipt" "$linux_finalize_receipt" "$coordinator_state" "$deployment_release_receipt" \
        "$linux_host_proof" "$cpp_status_response" "$cpp_arm_response" "$cpp_cleanup_receipt" \
        "$rust_acceptance_arm_response" "$rust_acceptance_query_response" "$post_release_receipt" \
        "$windows_restart_receipt" "$recovery_deployment_publish_receipt" "$linux_deactivation_transcript" \
        "$linux_deactivation_proof" "$linux_containment_transcript" "$local_windows_validation" "$local_windows_rollback_receipt" \
        "$local_recovery_bundle" "$local_windows_stop_evidence" "$local_windows_restart_intent" "$recovery_publish_intent"; do
        if [[ ! -e $path ]]; then require_absolute_new_output 'bootstrap durable output' "$path"; fi
    done
    for path in "$pre_mutation_start_state_candidate" "$pre_mutation_stop_state_claim"; do
        if [[ ! -e $path && ! -L $path ]]; then require_absolute_new_output 'pre-mutation CAS output' "$path"; fi
    done
    secure_dir=$(mktemp -d); chmod 0700 "$secure_dir"
    remote_manifest_snapshot=$secure_dir/rollback-manifest.json; remote_token_snapshot=$secure_dir/rollback-token.json
    validate_provenance
    "$windows_static_checker"
    "$script_dir/linux/check-bootstrap-stage-viewflow.sh"
    "$script_dir/linux/check-bootstrap-finalize-viewflow-deskflow.sh"
    if ((resume_pre_mutation_stop_intent)); then
        ((resume == 1)) || die 'special pre-mutation retry also requires --resume'
        validate_pre_mutation_stop_state_baseline
        validate_state_contract "$pre_mutation_stop_state_baseline_path"
        [[ -f $windows_bootstrap_request && ! -L $windows_bootstrap_request ]] ||
            die 'special pre-mutation retry requires the original bootstrap request'
        windows_request_sha=$(sha256 "$windows_bootstrap_request")
        if [[ -e $coordinator_state || -L $coordinator_state ]]; then
            [[ -f $coordinator_state && ! -L $coordinator_state ]] ||
                die 'canonical coordinator state is unsafe during special resume'
            if [[ $(sha256 "$coordinator_state") == "$pre_mutation_stop_state_baseline_sha" ]]; then
                phase=STOP_INTENT
            else
                [[ -f $pre_mutation_retry_proof && ! -L $pre_mutation_retry_proof ]] ||
                    die 'special START_INTENT adoption requires the durable retry proof'
                publish_pre_mutation_start_state_cas
            fi
        else
            [[ -f $pre_mutation_retry_proof && ! -L $pre_mutation_retry_proof &&
               -f $pre_mutation_start_state_candidate && ! -L $pre_mutation_start_state_candidate &&
               -f $pre_mutation_stop_state_claim && ! -L $pre_mutation_stop_state_claim ]] ||
                die 'absent canonical state lacks the exact pre-mutation CAS recovery set'
            publish_pre_mutation_start_state_cas
        fi
    elif [[ -f $coordinator_state ]]; then
        ((resume == 1)) || die 'coordinator state exists; explicit --resume is required'
        assert_strict_json_document 'coordinator state' "$coordinator_state"
        phase=$(jq -er --arg op "$operation_id" 'select(.schema_version == 2 and .state == "viewflow-cross-host-bootstrap" and .operation_id == $op) | .phase' "$coordinator_state")
        validate_state_contract "$coordinator_state"
        [[ $phase != WINDOWS_START_INTENT || $(jq -r '.recovery.pre_mutation_stop_history.phase // ""' "$coordinator_state") != STOP_INTENT ]] ||
            die 'pre-mutation retry before Start requires the sealed-baseline special resume'
    elif ((resume)); then
        die '--resume requires an existing durable coordinator state'
    fi
}

main() {
    coordinator_event ENTRY
    bootstrap_preflight
    if [[ $phase == STOP_INTENT && $resume_pre_mutation_stop_intent == 1 ]]; then
        make_bootstrap_request
        reconcile_deployment_marker_phase
        reopen_pre_mutation_stop_intent
    fi
    recovery_required=1
    make_bootstrap_request
    if [[ $(phase_rank "$phase") -ge $(phase_rank STOP_INTENT) && $pre_mutation_retry_active == 0 ]]; then
        [[ -f $windows_prepared_receipt ]] && validate_windows_prepared_P
        recover_both_hosts "$RECOVERY_FAILURE_EXIT"
    fi
    reconcile_deployment_marker_phase
    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_STAGED) && -e $linux_stage_receipt ]]; then
        validate_existing_linux_stage
        [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active &&
           $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) != active ]] ||
            die 'orphan Ls receipt lacks Viewflow-only live state'
        windows_create_or_verify "$linux_stage_receipt" "$windows_stage_path"
        commit_phase LINUX_STAGED
    fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_FINALIZED_MARKER_HELD) && -e $linux_finalize_receipt ]]; then
        validate_existing_linux_finalize
        [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active &&
           $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) == active ]] ||
            die 'orphan Lf receipt lacks both v2 units active'
        commit_phase LINUX_FINALIZED_MARKER_HELD
    fi
    validate_frozen_linux_B
    if [[ $phase == INIT ]]; then commit_phase WINDOWS_PUBLISH_INTENT; fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank WINDOWS_PREPARED) ]]; then
        remote_prepare_and_start_once
        wait_remote_receipt 'Windows prepared P' "$windows_prepared_path" "$windows_prepared_receipt"
        validate_windows_prepared_P
        commit_phase WINDOWS_PREPARED
    else
        validate_windows_prepared_P
    fi
    publish_mutation_permit
    if [[ $(phase_rank "$phase") -lt $(phase_rank WINDOWS_FORCE_ATTESTED) ]]; then
        wait_remote_receipt 'Windows force-release envelope F' "$windows_force_envelope_path" "$windows_force_envelope"
    fi
    validate_windows_force_F
    commit_phase WINDOWS_FORCE_ATTESTED
    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_STAGED) ]]; then
        reconcile_deployment_marker_phase
        assert_deployment_marker
        run_linux_stage
    else
        validate_existing_linux_stage
    fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank WINDOWS_COMMITTED) ]]; then
        wait_remote_receipt 'daemon-authored Windows W' "$windows_install_path" "$bootstrap_windows_install_receipt"
    fi
    validate_windows_W_schema5
    if [[ $(phase_rank "$phase") -lt $(phase_rank WINDOWS_COMMITTED) ]]; then validate_operation_readiness_chain; fi
    commit_phase WINDOWS_COMMITTED
    if [[ $(phase_rank "$phase") -lt $(phase_rank WINDOWS_TERMINAL) ]]; then wait_windows_terminal_exit; else validate_windows_terminal_exit; fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank LINUX_FINALIZED_MARKER_HELD) ]]; then run_linux_finalize; else validate_existing_linux_finalize; fi
    validate_exact_bootstrap_cross_chain
    if [[ $(phase_rank "$phase") -lt $(phase_rank MARKER_RELEASED) ]]; then
        assert_deployment_marker
        release_deployment_marker_transactionally
    fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank RUST_ACCEPTANCE_ARMED) ]]; then arm_rust_acceptance; commit_phase RUST_ACCEPTANCE_ARMED
    else arm_rust_acceptance; fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank CPP_ACCEPTANCE_ARMED) ]]; then wait_for_runtime_marker_and_arm_cpp; commit_phase CPP_ACCEPTANCE_ARMED
    else validate_cpp_status "$cpp_status_response"; arm_cpp_acceptance; fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank CPP_CLEANED) ]]; then wait_for_cpp_cleanup; commit_phase CPP_CLEANED
    else validate_cpp_cleanup_receipt; fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank WINDOWS_RESTARTED) ]]; then
        commit_phase WINDOWS_RESTART_INTENT
        restart_windows_peer_after_cleanup
        commit_phase WINDOWS_RESTARTED
    else restart_windows_peer_after_cleanup; fi
    if [[ $(phase_rank "$phase") -lt $(phase_rank POST_RELEASE_VERIFIED) ]]; then
        wait_for_rust_acceptance
        commit_phase POST_RELEASE_VERIFIED
    else
        wait_for_rust_acceptance
    fi
    recovery_required=0
    phase=SUCCESS_DISARMED
    trap - ERR INT TERM EXIT
    cleanup_secure_dir
    phase=DONE
    [[ $phase == DONE ]]
    printf 'cross-host two-phase bootstrap completed; VFDQR001 release and normal HID acceptance passed\n'
}

readonly -f usage die coordinator_event sha256 require_value require_sha256 require_uuid require_u64 lower_id process_start_ticks
readonly -f require_windows_absolute_path windows_fixed_leaf require_bootstrap_deactivation_transport_leaf require_absolute_input require_absolute_new_output
readonly -f validate_candidate_replacement_lineage
readonly -f validate_pre_mutation_stop_state_baseline assert_marker_cli_identity marker_cli
readonly -f assert_strict_json_document publish_new_file capture_json_command cleanup_secure_dir finish_recovery publish_json_file copy_json_output validate_provenance
readonly -f sha_if_regular render_committed_artifacts render_state validate_state_contract adopt_consume_intent_inputs
readonly -f render_pre_mutation_start_state validate_pre_mutation_start_state_file publish_pre_mutation_start_state_cas
readonly -f commit_phase phase_rank adopt_prepublished_marker_handoff reconcile_deployment_marker_phase validate_frozen_linux_B derive_windows_paths make_bootstrap_request
readonly -f remote_prepare_and_start_once validate_pre_mutation_retry_proof reopen_pre_mutation_stop_intent windows_remote_exists sync_remote_receipt wait_remote_receipt validate_windows_prepared_P
readonly -f publish_mutation_permit validate_windows_force_F stop_exact_windows_bootstrap validate_windows_stop_evidence
readonly -f run_linux_stage validate_existing_linux_stage validate_windows_W_schema5 validate_operation_readiness_chain validate_windows_terminal_exit wait_windows_terminal_exit
readonly -f run_linux_finalize validate_existing_linux_finalize rollback_linux_two_phase validate_exact_bootstrap_cross_chain validate_release_receipt_v2 release_deployment_marker_transactionally
readonly -f require_owner_only_regular publish_recovery_json_once validate_attempt3_slot_cleanup_gate validate_fresh_operation_lineage_gate validate_schema1_handoff_lineage_gate validate_failed_v13_slot_lineage_union validate_failed_v13_terminal_state validate_failed_v13_baseline_evidence
readonly -f validate_pre_mutation_failed_terminal_state validate_pre_mutation_failed_baseline assert_pre_mutation_outputs_absent
readonly -f validate_pre_mutation_windows_live_proof validate_pre_mutation_stop_transport_bridge capture_pre_mutation_windows_live_proof
readonly -f select_failed_v13_abort_marker_tuple assert_failed_v13_original_generation_only
readonly -f validate_fd_gate_contract run_pinned_executable canonical_fd_gate_exec_start_sha legacy_deskflow_v13_exec_start_sha
readonly -f expected_viewflow_v13_exec_start_sha expected_deskflow_v13_exec_start_sha observed_transient_exec_start_sha reset_failed_deskflow_recovery_unit start_pinned_v13_transient_unit
readonly -f start_and_freeze_linux_v13 validate_linux_v13_started start_and_freeze_windows_v13 validate_windows_v13_started
readonly -f journal_record_sha_exists freeze_authenticated_v13_peer validate_authenticated_v13_peer make_and_validate_post_permit_rollback_abort_authorization make_and_validate_post_force_rollback_abort_authorization make_and_validate_abort_authorization
readonly -f freeze_pre_mutation_windows_v13 validate_pre_mutation_windows_v13_started make_and_validate_pre_mutation_abort_authorization
readonly -f validate_abort_receipt_binary validate_abort_receipt_v2 validate_abort_receipt_v1 validate_abort_receipt_v5 validate_abort_receipt_v7
readonly -f abort_deployment_marker_transactionally abort_pre_mutation_deployment_marker_transactionally
readonly -f derive_pre_mutation_abort_contract failed_v13_pre_mutation_abort_preflight
readonly -f failed_v13_abort_preflight failed_v13_abort_main publish_pre_mutation_abort_terminal failed_v13_pre_mutation_abort_main
readonly -f ssh_windows ssh_windows_stdin windows_read_file windows_create_file windows_create_or_verify
readonly -f validate_rollback_snapshots prearm_windows_recovery capture_old_linux_hashes
readonly -f assert_old_linux_hashes exact_executable_pids cgroup_executable_sha_pids process_control_group process_descends_from validate_live_deskflow_recovery_tuple unit_main_pid assert_linux_inactive
readonly -f assert_adoptable_linux_v13_without_receipt
readonly -f assert_deployment_marker assert_runtime_marker_retained validate_publish_receipt
readonly -f publish_deployment_marker ensure_recovery_publish_intent adopt_active_recovery_marker republish_deployment_marker_for_recovery
readonly -f validate_cpp_cleanup_receipt validate_cpp_status arm_cpp_acceptance assert_linux_ready_and_publish_proof
readonly -f validate_two_host_cross_binding validate_rust_control_identity arm_rust_acceptance
readonly -f wait_for_runtime_marker_and_arm_cpp wait_for_cpp_cleanup validate_windows_restart_intent wait_for_linux_restart_auth
readonly -f validate_existing_windows_restart_receipt restart_windows_peer_after_cleanup
readonly -f validate_normal_acceptance_transcript validate_normal_acceptance_receipt wait_for_rust_acceptance
readonly -f graceful_linux_containment classify_runtime_after_containment assert_recovery_runtime_state validate_linux_deactivation_proof
readonly -f make_recovery_bundle validate_recovery_bundle run_windows_rollback recover_both_hosts
readonly -f handle_err handle_signal handle_exit preflight run_linux_transaction bootstrap_preflight main

trap handle_err ERR
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap handle_exit EXIT

((abort_failed_v13 + abort_failed_v13_pre_mutation <= 1)) || die 'failed-v1.3 abort modes are mutually exclusive'
if ((abort_failed_v13_pre_mutation)); then
    failed_v13_pre_mutation_abort_main
elif ((abort_failed_v13)); then
    failed_v13_abort_main
else
    main "$@"
fi
