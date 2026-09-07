#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2094,SC2155
# Hermetic schema fixture plus a crash-boundary model of the durable bridge
# journal. It never invokes systemctl, journalctl, ssh, or the production main.
set -Eeuo pipefail
umask 077
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly LINUX=$(cd -- "$HERE/.." && pwd)
readonly SOURCE=$LINUX/bridge-early-abort-terminal-to-fresh-v21.sh
root=$(mktemp -d --tmpdir 'viewflow-early-bridge-fixture.XXXXXX')
cleanup(){ chmod -R u+w -- "$root" 2>/dev/null || true; rm -rf -- "$root"; }
trap cleanup EXIT
copy=$root/bridge.sh
/usr/bin/python3 -I - "$SOURCE" "$copy" "$root" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();r=sys.argv[3]
s=s.replace('readonly STATE=/home/wilf/.local/state/viewflow','readonly STATE='+r)
s=s.replace('[[ $bridge_root == /home/wilf/.local/state/viewflow/bridges/$old_operation ]]','[[ $bridge_root == '+r+'/bridges/$old_operation ]]')
s=s.replace("$(stat -c '%u:%h' -- \"$path\") == 1000:1","$(stat -c '%u' -- \"$path\") == 1000")
s=s.replace('ensure_roots; snapshot_inputs; validate_inputs; make_plan; reattest_all_inputs',
            'ensure_roots; snapshot_inputs; validate_inputs; printf \'execute snapshot validation passed\\n\'; return')
Path(sys.argv[2]).write_text(s)
PY
chmod 0755 "$copy"

op=2ca3f46635b65615a1cffc1970d73911
coord=ad0e2ad1-608f-4aee-8701-900fe6c7fd6a
vf=d142fbbc65e311fa17b3307c252689afbb3963dda3e265cedc3bca7887daf96d
df=033065b0495a2b996a6731ecf6e47c2af476e1c120ab5d62dafb8b8aa3394c3f
core=e2ebbfe39a1b7f5f3e30953340c000e5b249e8d957ceda5fb0e9c4efad0ffd52
marker=$root/old-marker.bin authorization=$root/authorization.json abort=$root/abort-receipt.json
linux=$root/linux-started.json post=$root/post-abort-reattest.json terminal=$root/early-gate-terminal.json
candidate=$root/candidate prepare=$root/prepare.sh collector=$root/collector.sh
printf '\177ELFfixture' >"$candidate"; printf '#!/usr/bin/env bash\nexit 0\n' >"$prepare"; cp "$prepare" "$collector"
chmod 0755 "$candidate" "$prepare" "$collector"

/usr/bin/python3 -I - "$marker" "$op" "$coord" <<'PY'
import sys,uuid
b=bytearray(256);op=sys.argv[2].encode();b[:8]=b'VFDQT001';b[8:13]=bytes((1,1,2,1,1));b[13]=len(op);b[16:16+len(op)]=op
b[144:160]=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes
b[160:176]=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes
b[176:192]=uuid.UUID(sys.argv[3]).bytes;b[192:200]=(1000).to_bytes(8,'little');b[200:208]=(1).to_bytes(8,'little')
open(sys.argv[1],'wb').write(b)
PY
marker_sha=$(sha256sum "$marker"|awk '{print $1}')

windows=$(jq -cn --arg op "$op" '{bootstrap_worker_created:false,command_line_sha256:("1"*64),
 executable_path:"C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe",force_release_executed:false,
 initial_force_release_executed:false,installer_process_count:0,mutation_permit_published:false,
 new_operation_root_path:("C:\\Users\\wilf\\AppData\\Local\\Viewflow\\Deployments\\"+$op),new_operation_root_present:false,
 new_task_name:("Viewflow Deployment "+$op),new_task_path:"\\",new_task_present:false,parent_pid:2,pid:1,
 process_start_filetime_utc:"134326073277429320",protocol_2_1:false,request_sha256:("c"*64),rollback_performed:false,
 rollback_sha256:("2"*64),session_id:1,task_action_sha256:("9"*64),task_name:"Viewflow Peer",task_path:"\\",
 task_principal_sha256:("a"*64),task_state:"Running",task_xml_sha256:("3"*64),
 user_sid:"S-1-5-21-1940417919-1835306932-1635351729-1001",viewflowd_process_count:1,viewflowd_sha256:("4"*64),
 windows_rollback_receipt_sha256:null,wrapper_sha256:("5"*64)}')
linux_obj=$(jq -cn --arg op "$op" --arg vf "$vf" '{deskflow_core_process_count:0,deskflow_process_count:0,
 deskflow_tcp_listener_count:0,deskflow_unit_main_pid:0,deskflow_unit_state:"inactive",input_producer_count:0,
 runtime_marker_present:false,viewflow_control_group:("/user.slice/viewflow-v13-early-"+$op+".service"),
 viewflow_exec_start_sha256:("9"*64),viewflow_invocation_id:("a"*32),viewflow_main_pid:101,viewflow_process_count:1,
 viewflow_sidecar_listener_count:1,viewflow_start_ticks:202,viewflow_udp_listener_count:1,
 viewflow_unit:("viewflow-v13-early-"+$op+".service"),viewflow_unit_state:"active",viewflowd_sha256:$vf}')
jq -cn --arg op "$op" --arg marker "$marker_sha" --argjson linux "$linux_obj" --argjson windows "$windows" \
  '{schema_version:1,state:"viewflow-early-gate-start-viewflow",operation_id:$op,marker_sha256:$marker,marker_generation:"1",linux:$linux,windows:$windows}' >"$linux"
linux_sha=$(sha256sum "$linux"|awk '{print $1}')
jq -cn --arg op "$op" --arg marker "$marker_sha" --argjson linux "$linux_obj" --argjson windows "$windows" \
  '{schema_version:1,state:"viewflow-early-gate-post-abort-reattest",operation_id:$op,marker_sha256:$marker,marker_generation:"1",linux:$linux,windows:$windows}' >"$post"
post_sha=$(sha256sum "$post"|awk '{print $1}')

jq -cn --arg op "$op" --arg coord "$coord" --arg marker "$marker_sha" --arg path "$authorization" --arg linux "$linux_sha" \
 --arg vf "$vf" --arg df "$df" --arg core "$core" '{authenticated_v13_peer_receipt_sha256:("b"*64),authorization_receipt_path:$path,
 bootstrap_request_sha256:("c"*64),coordinator_failure_phase:null,coordinator_instance_id:$coord,coordinator_mutation_possible:false,
 coordinator_terminal_state_sha256:("d"*64),deployment_publish_receipt_sha256:("e"*64),force_release_executed:false,
 initial_force_release_executed:false,input_producer_count:0,linux_deskflow_started:false,linux_frozen_evidence_sha256:("f"*64),
 linux_v13_started_receipt_sha256:$linux,marker_generation:"1",marker_handoff_receipt_sha256:("1"*64),marker_sha256:$marker,
 mutation_permit_published:false,old_linux_deskflow_core_sha256:$core,old_linux_deskflow_sha256:$df,old_linux_viewflowd_sha256:$vf,
 old_windows_rollback_sha256:("2"*64),old_windows_task_xml_sha256:("3"*64),old_windows_viewflowd_sha256:("4"*64),
 old_windows_wrapper_sha256:("5"*64),operation_id:$op,protocol_2_1:false,rollback_performed:false,schema_version:3,
 state:"viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized",windows_bootstrap_worker_created:false,
 windows_installer_process_count:0,windows_live_proof_sha256:("6"*64),windows_new_operation_root_present:false,
 windows_new_task_present:false,windows_rollback_receipt_sha256:null,windows_stop_evidence_sha256:("7"*64),
 windows_v13_started_receipt_sha256:("8"*64)}' >"$authorization"
auth_sha=$(sha256sum "$authorization"|awk '{print $1}')
vfdqa=$root/.deployment-quarantine.v1.abort-receipt.${marker_sha}.${auth_sha}.v1
/usr/bin/python3 -I - "$vfdqa" "$marker" "$marker_sha" "$auth_sha" <<'PY'
import hashlib,sys
m=open(sys.argv[2],'rb').read();b=bytearray(384);b[:8]=b'VFDQA001';b[8:13]=bytes((1,1,1,3,1));b[16:272]=m
b[272:304]=bytes.fromhex(sys.argv[3]);b[304:336]=bytes.fromhex(sys.argv[4]);b[336:344]=(2000).to_bytes(8,'little');b[352:384]=hashlib.sha256(b[:352]).digest();open(sys.argv[1],'wb').write(b)
PY
vfdqa_sha=$(sha256sum "$vfdqa"|awk '{print $1}')

jq -cn --arg op "$op" --arg coord "$coord" --arg marker "$marker_sha" --arg durable "$vfdqa" --arg auth "$authorization" \
 --arg auth_sha "$auth_sha" --slurpfile a "$authorization" '$a[0] as $x|{abort_authorization_path:$auth,
 abort_authorization_sha256:$auth_sha,abort_claim_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim",
 abort_committed_at_unix_ms:"2000",abort_committed_at_utc:"1970-01-01T00:00:02.000Z",abort_point:"abort-claim-unlink-and-parent-directory-fsync",
 abort_receipt_path:$durable,aborted_marker_sha256:$marker,authenticated_v13_peer_receipt_sha256:$x.authenticated_v13_peer_receipt_sha256,
 authorization_state:$x.state,bootstrap_request_sha256:$x.bootstrap_request_sha256,coordinator_failure_phase:$x.coordinator_failure_phase,
 coordinator_instance_id:$coord,coordinator_mutation_possible:$x.coordinator_mutation_possible,
 coordinator_terminal_state_sha256:$x.coordinator_terminal_state_sha256,deployment_publish_receipt_sha256:$x.deployment_publish_receipt_sha256,
 deployment_release_claimed:false,force_release_executed:false,initial_force_release_executed:false,input_producer_count:0,
 linux_deskflow_started:false,linux_frozen_evidence_sha256:$x.linux_frozen_evidence_sha256,linux_v13_started_receipt_sha256:$x.linux_v13_started_receipt_sha256,
 marker_created_at_unix_ms:"1000",marker_generation:"1",marker_handoff_receipt_sha256:$x.marker_handoff_receipt_sha256,
 marker_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",mutation_permit_published:false,operation_id:$op,
 protocol_2_1:false,protocol_version:"1.3",replayed:false,rollback_performed:false,schema_version:3,
 source_display_id:"00000000-0000-0000-0000-000000000101",state:"deployment-quarantine-aborted",
 target_device_id:"00000000-0000-0000-0000-000000000002",windows_bootstrap_worker_created:false,
 windows_installer_process_count:0,windows_live_proof_sha256:$x.windows_live_proof_sha256,windows_new_operation_root_present:false,
 windows_new_task_present:false,windows_rollback_receipt_sha256:null,windows_stop_evidence_sha256:$x.windows_stop_evidence_sha256,
 windows_v13_started_receipt_sha256:$x.windows_v13_started_receipt_sha256}' >"$abort"
abort_sha=$(sha256sum "$abort"|awk '{print $1}')
jq -cn --arg op "$op" --arg auth "$auth_sha" --arg abort "$abort_sha" --arg post "$post_sha" --arg vfdqa "$vfdqa_sha" \
 '{abort_claim_absent:true,abort_receipt_sha256:$abort,authorization_sha256:$auth,coordinator_terminal_state_sha256:("d"*64),
 deskflow_core_process_count:0,deskflow_process_count:0,deskflow_tcp_listener_count:0,deskflow_unit_state:"inactive",input_producer_count:0,
 marker_absent:true,operation_id:$op,post_abort_reattest_sha256:$post,pre_abort_reattest_sha256:("e"*64),protocol_2_1:false,
 release_claim_absent:true,runtime_marker_absent:true,schema_version:1,state:"viewflow-early-bootstrap-gate-abort-terminal",
 vfdqa_binary_sha256:$vfdqa}' >"$terminal"
terminal_sha=$(sha256sum "$terminal"|awk '{print $1}')
chmod 0600 "$authorization" "$abort" "$linux" "$post" "$terminal" "$vfdqa"

args=(--validate-inputs-only --old-operation-id "$op" --early-abort-terminal "$terminal" --early-abort-terminal-sha256 "$terminal_sha"
 --abort-authorization "$authorization" --abort-authorization-sha256 "$auth_sha" --abort-receipt "$abort" --abort-receipt-sha256 "$abort_sha"
 --linux-started "$linux" --linux-started-sha256 "$linux_sha" --post-abort-reattest "$post" --post-abort-reattest-sha256 "$post_sha"
 --vfdqa "$vfdqa" --vfdqa-sha256 "$vfdqa_sha" --installed-viewflow-sha256 "$vf" --installed-viewflow-unit-sha256 "$(printf unit|sha256sum|awk '{print $1}')"
 --deployment-marker-candidate "$candidate" --deployment-marker-sha256 "$(sha256sum "$candidate"|awk '{print $1}')"
 --prepare-script "$prepare" --prepare-script-sha256 "$(sha256sum "$prepare"|awk '{print $1}')"
 --collector-script "$collector" --collector-script-sha256 "$(sha256sum "$collector"|awk '{print $1}')" --bridge-root "$root/bridges/$op")
/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${args[@]}" >/dev/null

# Run the real execute pre-mutation path through immutable snapshot creation
# and the second validate_inputs pass. The fixture copy returns immediately
# afterward, before make_plan/systemd/process inspection.
mkdir "$root/deployments"; chmod 0700 "$root/deployments"
execute_args=("${args[@]}"); execute_args[0]=--execute
execute_output=$(/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${execute_args[@]}")
[[ $execute_output == 'execute snapshot validation passed' ]] || {
    printf 'error: hermetic execute snapshot validation did not complete\n' >&2; exit 1;
}
[[ $(stat -c '%a:%s' "$vfdqa") == 600:384 &&
   $(stat -c '%a:%s' "$root/bridges/$op/immutable-inputs/durable-vfdqa.bin") == 400:384 ]] || {
    printf 'error: original/snapshot VFDQA mode-size split differs\n' >&2; exit 1;
}

mutated=$root/mutated-terminal.json
jq '.schema_version=2' "$terminal" >"$mutated"; chmod 0600 "$mutated"
bad=("${args[@]}"); bad[4]=$mutated; bad[6]=$(sha256sum "$mutated"|awk '{print $1}')
if /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${bad[@]}" >/dev/null 2>&1; then
    printf 'error: schema mutation was accepted\n' >&2; exit 1
fi

bad_post=$root/bad-post.json
jq '.windows.request_sha256=("0"*64)' "$post" >"$bad_post"; chmod 0600 "$bad_post"
bad_windows=("${args[@]}"); bad_windows[20]=$bad_post; bad_windows[22]=$(sha256sum "$bad_post"|awk '{print $1}')
if /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${bad_windows[@]}" >/dev/null 2>&1; then
    printf 'error: Windows authorization-binding mutation was accepted\n' >&2; exit 1
fi

# Prove authorization binding independently of tuple equality by mutating both
# snapshots to the same request hash and checking each against authorization.
bound_started=$root/bound-started.json; bound_post=$root/bound-post.json
jq '.windows.request_sha256=("0"*64)' "$linux" >"$bound_started"
jq '.windows.request_sha256=("0"*64)' "$post" >"$bound_post"
chmod 0600 "$bound_started" "$bound_post"
[[ $(jq -cS '.windows' "$bound_started") == "$(jq -cS '.windows' "$bound_post")" ]] || {
    printf 'error: authorization-binding pair is not tuple-equal\n' >&2; exit 1;
}
snapshot_contract=$root/snapshot-contract.sh
sed -n '/^validate_snapshot()/,/^}/p' "$SOURCE" >"$snapshot_contract"
for pair in "$bound_started:viewflow-early-gate-start-viewflow" "$bound_post:viewflow-early-gate-post-abort-reattest"; do
    target=${pair%%:*}; expected_state=${pair#*:}
    if /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$snapshot_contract" "$authorization" "$op" "$marker_sha" "$target" "$expected_state" <<'BASH' >/dev/null 2>&1
set -Eeuo pipefail
source "$1"; authorization=$2; old_operation=$3; marker_sha=$4; target=$5; state=$6
die(){ return 1; }
validate_snapshot "$target" "$state" "$marker_sha"
BASH
    then
        printf 'error: tuple-equal Windows authorization mismatch was accepted: %s\n' "$expected_state" >&2; exit 1
    fi
done

# Strict Python scalar checks reject float/bool spellings that jq numeric
# equality/floor predicates otherwise accept.
scalar_contract=$root/scalar-contract.sh
sed -n '/^validate_input_scalar_contract()/,/^}/p' "$SOURCE" >"$scalar_contract"
for mutation in session-float pid-float parent-bool filetime-leading-zero; do
    scalar_started=$root/scalar-$mutation-started.json; scalar_post=$root/scalar-$mutation-post.json
    case $mutation in
        session-float|pid-float)
            key=${mutation%-float}; [[ $key == session ]] && key=session_id
            /usr/bin/python3 -I - "$linux" "$scalar_started" "$key" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text();needle='"'+sys.argv[3]+'":1'
if text.count(needle)!=1:raise SystemExit('float fixture anchor differs')
pathlib.Path(sys.argv[2]).write_text(text.replace(needle,needle+'.0'))
PY
            /usr/bin/python3 -I - "$post" "$scalar_post" "$key" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text();needle='"'+sys.argv[3]+'":1'
if text.count(needle)!=1:raise SystemExit('float fixture anchor differs')
pathlib.Path(sys.argv[2]).write_text(text.replace(needle,needle+'.0'))
PY
            ;;
        parent-bool)
            jq '.windows.parent_pid=true' "$linux" >"$scalar_started"; jq '.windows.parent_pid=true' "$post" >"$scalar_post" ;;
        filetime-leading-zero)
            jq '.windows.process_start_filetime_utc="0134326073277429320"' "$linux" >"$scalar_started"
            jq '.windows.process_start_filetime_utc="0134326073277429320"' "$post" >"$scalar_post" ;;
    esac
    chmod 0600 "$scalar_started" "$scalar_post"
    if /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$scalar_contract" "$authorization" "$abort" "$terminal" "$scalar_started" "$scalar_post" <<'BASH' >/dev/null 2>&1
set -Eeuo pipefail
source "$1"; authorization=$2; abort_receipt=$3; terminal=$4; linux_started=$5; post_reattest=$6
validate_input_scalar_contract
BASH
    then
        printf 'error: strict scalar mutation was accepted: %s\n' "$mutation" >&2; exit 1
    fi
done

# Exercise the production snapshot code under umask 077 and on resume.
snapshot_library=$root/snapshot-library.sh
{
    sed -n '/^safe_owner_dir()/,/^}/p' "$SOURCE"
    sed -n '/^snapshot_one()/,/^}/p' "$SOURCE"
    sed -n '/^snapshot_inputs()/,/^}/p' "$SOURCE"
} >"$snapshot_library"
snapshot_bridge=$root/snapshot-bridge; mkdir "$snapshot_bridge"; chmod 0700 "$snapshot_bridge"
/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$snapshot_library" "$snapshot_bridge" "$terminal" "$authorization" "$abort" "$linux" "$post" "$vfdqa" "$candidate" "$prepare" "$collector" <<'BASH'
set -Eeuo pipefail; umask 077
source "$1"; bridge_root=$2; terminal=$3; authorization=$4; abort_receipt=$5; linux_started=$6; post_reattest=$7; vfdqa=$8
marker_candidate=$9; prepare_script=${10}; collector_script=${11}; die(){ printf 'snapshot fixture failed: %s\n' "$*" >&2; return 1; }
safe_owner_dir(){ local mode; [[ -d $2 && ! -L $2 && $(stat -c %u "$2") == 1000 ]] || die "$1 owner differs"; mode=$(stat -c %a "$2"); (( (8#$mode & 8#077)==0 )); }
sha(){ sha256sum "$1"|awk '{print $1}'; }
terminal_sha=$(sha "$terminal"); authorization_sha=$(sha "$authorization"); abort_receipt_sha=$(sha "$abort_receipt")
linux_started_sha=$(sha "$linux_started"); post_reattest_sha=$(sha "$post_reattest"); vfdqa_sha=$(sha "$vfdqa")
marker_candidate_sha=$(sha "$marker_candidate"); prepare_script_sha=$(sha "$prepare_script"); collector_script_sha=$(sha "$collector_script")
snapshot_inputs; snapshot_inputs
directory=$bridge_root/immutable-inputs
[[ $(stat -c %a "$directory") == 500 ]]
[[ $(find "$directory" -maxdepth 1 -type f -perm 0555 -printf '%f\n'|sort|tr '\n' ' ') == 'collect-viewflow-v13-bootstrap-evidence.sh prepare-v13-marker-handoff.sh viewflow-deployment-marker ' ]]
[[ $(find "$directory" -maxdepth 1 -type f -perm 0400 -printf '%f\n'|sort|tr '\n' ' ') == 'abort-receipt.json authorization.json durable-vfdqa.bin early-gate-terminal.json linux-started.json post-abort-reattest.json ' ]]
BASH

# Execute the production /proc environment validator against a hermetic proc
# tree, then prove dangerous and merely unapproved names are both rejected.
environment_contract=$root/environment-contract.sh
sed -n '/^process_environment_sha()/,/^}/p' "$SOURCE" >"$environment_contract"
proc_fixture=$root/proc; mkdir -p "$proc_fixture/77"
/usr/bin/python3 -I - "$proc_fixture/77" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]);fields=['S']+['0']*50;fields[19]='202'
(root/'stat').write_text('77 (viewflowd) '+' '.join(fields)+'\n')
entries=[b'HOME=/home/wilf',b'USER=wilf',b'LOGNAME=wilf',b'XDG_RUNTIME_DIR=/run/user/1000',
 b'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus',b'INVOCATION_ID='+b'a'*32,
 b'SYSTEMD_EXEC_PID=77',b'PATH=/usr/lib/jvm/java-21-openjdk/bin:/home/wilf/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/home/wilf/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/opt/cuda/bin:/usr/lib/emscripten:/usr/lib/jvm/default/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl:/usr/lib/rustup/bin:/home/wilf/.local/bin',
 b'JOURNAL_STREAM=8:9',b'GTK_IM_MODULE=fcitx',b'QT_IM_MODULE=fcitx',
 b'XMODIFIERS=@im=fcitx',b'RUNTIME_DIRECTORY=/run/user/1000/viewflow',b'MANAGERPIDFDID=16403']
(root/'environ').write_bytes(b'\0'.join(entries)+b'\0')
PY
environment_hash=$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$environment_contract" "$proc_fixture" <<'BASH'
set -Eeuo pipefail; source "$1"; process_environment_sha 77 202 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$2"
BASH
)
[[ $environment_hash =~ ^[0-9a-f]{64}$ ]] || { printf 'error: approved environment hash missing\n' >&2; exit 1; }
for name in LD_PRELOAD UNAPPROVED_VARIABLE; do
    cp "$proc_fixture/77/environ" "$proc_fixture/77/environ.good"
    printf '%s=/tmp/injected.so\0' "$name" >>"$proc_fixture/77/environ"
    if /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$environment_contract" "$proc_fixture" <<'BASH' >/dev/null 2>&1
set -Eeuo pipefail; source "$1"; process_environment_sha 77 202 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$2"
BASH
    then
        printf 'error: daemon environment mutation was accepted: %s\n' "$name" >&2; exit 1
    fi
    mv "$proc_fixture/77/environ.good" "$proc_fixture/77/environ"
done
for replacement in 'GTK_IM_MODULE=ibus' 'QT_IM_MODULE=ibus' 'XMODIFIERS=@im=ibus' \
                   'RUNTIME_DIRECTORY=/tmp/viewflow' 'MANAGERPIDFDID=016403' 'MANAGERPIDFDID=0' \
                   'PATH=/usr/bin' \
                   'PATH=/home/wilf/.nix-profile/bin:/usr/lib/jvm/java-21-openjdk/bin:/nix/var/nix/profiles/default/bin:/home/wilf/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/opt/cuda/bin:/usr/lib/emscripten:/usr/lib/jvm/default/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl:/usr/lib/rustup/bin:/home/wilf/.local/bin' \
                   'PATH=/usr/lib/jvm/java-21-openjdk/bin:/home/wilf/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/home/wilf/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/opt/cuda/bin:/usr/lib/emscripten:/usr/lib/jvm/default/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl:/usr/lib/rustup/bin:/home/wilf/.local/bin:/home/wilf/bin'; do
    name=${replacement%%=*}; cp "$proc_fixture/77/environ" "$proc_fixture/77/environ.good"
    /usr/bin/python3 -I - "$proc_fixture/77/environ" "$name" "$replacement" <<'PY'
import pathlib,sys
path=pathlib.Path(sys.argv[1]);name=sys.argv[2].encode()+b'=';replacement=sys.argv[3].encode();entries=path.read_bytes()[:-1].split(b'\0')
matches=[index for index,value in enumerate(entries) if value.startswith(name)]
if len(matches)!=1:raise SystemExit('environment value mutation anchor differs')
entries[matches[0]]=replacement;path.write_bytes(b'\0'.join(entries)+b'\0')
PY
    if /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$environment_contract" "$proc_fixture" <<'BASH' >/dev/null 2>&1
set -Eeuo pipefail; source "$1"; process_environment_sha 77 202 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$2"
BASH
    then
        printf 'error: permissive daemon environment value was accepted: %s\n' "$replacement" >&2; exit 1
    fi
    mv "$proc_fixture/77/environ.good" "$proc_fixture/77/environ"
done

# Exercise receipt recovery against an advancing probe stream. The immutable
# receipt-bound probe may be followed by newer probes (and may occur more than
# once), but it must itself be an exact message after the matching endpoint's
# authenticated record.
receipt_probe_contract=$root/receipt-probe-contract.sh
sed -n '/^validate_receipt_bound_probe()/,/^}/p' "$SOURCE" >"$receipt_probe_contract"
auth_line='viewflowd server authenticated peer 172.16.105.70:54321'
bound_probe='viewflowd server peer 172.16.105.70:54321 probe=17 responder_us=29'
later_probe='viewflowd server peer 172.16.105.70:54321 probe=18 responder_us=31'
bound_probe_sha=$(printf '%s' "$bound_probe" | sha256sum | awk '{print $1}')
write_probe_journal() {
    local output=$1; shift
    : >"$output"
    local message
    for message in "$@"; do jq -cn --arg message "$message" '{MESSAGE:$message}' >>"$output"; done
}
valid_probe_journal=$root/receipt-probes-valid.ndjson
write_probe_journal "$valid_probe_journal" "$auth_line" "$bound_probe" "$later_probe"
occurrences=$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$receipt_probe_contract" "$valid_probe_journal" "$bound_probe_sha" <<'BASH'
set -Eeuo pipefail;source "$1";validate_receipt_bound_probe "$2" "$3"
BASH
)
[[ $occurrences == 1 ]] || { printf 'error: later probe displaced receipt-bound probe\n' >&2; exit 1; }
duplicate_probe_journal=$root/receipt-probes-duplicate.ndjson
write_probe_journal "$duplicate_probe_journal" "$auth_line" "$bound_probe" "$bound_probe" "$later_probe"
occurrences=$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$receipt_probe_contract" "$duplicate_probe_journal" "$bound_probe_sha" <<'BASH'
set -Eeuo pipefail;source "$1";validate_receipt_bound_probe "$2" "$3"
BASH
)
[[ $occurrences == 2 ]] || { printf 'error: one-or-more receipt-bound probe policy differs\n' >&2; exit 1; }
missing_probe_journal=$root/receipt-probes-missing.ndjson
write_probe_journal "$missing_probe_journal" "$auth_line" "$later_probe"
tampered_probe_journal=$root/receipt-probes-tampered.ndjson
write_probe_journal "$tampered_probe_journal" "$auth_line" "${bound_probe}0" "$later_probe"
preauth_probe_journal=$root/receipt-probes-preauth.ndjson
write_probe_journal "$preauth_probe_journal" "$bound_probe" "$auth_line" "$later_probe"
for rejected in "$missing_probe_journal" "$tampered_probe_journal" "$preauth_probe_journal"; do
    if /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$receipt_probe_contract" "$rejected" "$bound_probe_sha" <<'BASH' >/dev/null 2>&1
set -Eeuo pipefail;source "$1";validate_receipt_bound_probe "$2" "$3"
BASH
    then
        printf 'error: invalid receipt-bound probe journal was accepted: %s\n' "$rejected" >&2; exit 1
    fi
done

# Hidepid-style census: a benign PID 1 with readable identity fields but no
# readable exe is skipped; a Deskflow-looking PID with the same missing exe is
# fail-closed.
census_contract=$root/census-contract.sh
sed -n '/^assert_process_census()/,/^}/p' "$SOURCE" >"$census_contract"
census_proc=$root/census-proc; mkdir -p "$census_proc/1"
/usr/bin/python3 -I - "$census_proc/1" systemd /sbin/init 101 <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]);fields=['S']+['0']*50;fields[19]=sys.argv[4]
(root/'stat').write_text('1 (systemd) '+' '.join(fields)+'\n');(root/'comm').write_text(sys.argv[2]+'\n')
(root/'cmdline').write_bytes(sys.argv[3].encode()+b'\0')
PY
/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$census_contract" "$census_proc" <<'BASH'
set -Eeuo pipefail;source "$1";VIEWFLOW=/fake/viewflowd;VIEWFLOW_ARGV=(/fake/viewflowd serve)
assert_process_census 0 "$2"
BASH
mkdir "$census_proc/2"
/usr/bin/python3 -I - "$census_proc/2" deskflow /usr/bin/deskflow 202 <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]);fields=['S']+['0']*50;fields[19]=sys.argv[4]
(root/'stat').write_text('2 (deskflow) '+' '.join(fields)+'\n');(root/'comm').write_text(sys.argv[2]+'\n')
(root/'cmdline').write_bytes(sys.argv[3].encode()+b'\0')
PY
# The census Python's one exact PID is excluded before argv classification.
/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$census_contract" "$census_proc" <<'BASH'
set -Eeuo pipefail;source "$1";VIEWFLOW=/fake/viewflowd;VIEWFLOW_ARGV=(/fake/viewflowd serve /run/user/1000/viewflow/deskflow.sock)
assert_process_census 0 "$2" 2
BASH
# The identical process is rejected when it is not the census self PID.
if /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$census_contract" "$census_proc" <<'BASH' >/dev/null 2>&1
set -Eeuo pipefail;source "$1";VIEWFLOW=/fake/viewflowd;VIEWFLOW_ARGV=(/fake/viewflowd serve)
assert_process_census 0 "$2"
BASH
then
    printf 'error: candidate-looking unreadable executable was accepted\n' >&2; exit 1
fi

# Execute the production marker stable-open decoder against a regular marker,
# a symlink, and an atomic swap between two individually valid marker byte sets.
fresh_op=11111111222233334444555555555555
fresh_coord=11111111-2222-4333-8444-555555555555
marker_a=$root/fresh-a.marker marker_b=$root/fresh-b.marker marker_live=$root/fresh-live.marker
marker_lock=$root/.deployment-quarantine.v1.lock
/usr/bin/python3 -I - "$marker_a" "$marker_b" "$fresh_op" "$fresh_coord" <<'PY'
import sys,uuid
for index,path in enumerate(sys.argv[1:3],1):
 b=bytearray(256);op=sys.argv[3].encode();b[:13]=b'VFDQT001\x01\x01\x02\x01\x01';b[13]=len(op);b[16:16+len(op)]=op
 b[144:160]=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes;b[160:176]=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes
 b[176:192]=uuid.UUID(sys.argv[4]).bytes;b[192:200]=(3000+index).to_bytes(8,'little');b[200:208]=(1).to_bytes(8,'little')
 open(path,'wb').write(b)
PY
chmod 0600 "$marker_a" "$marker_b"; cp "$marker_a" "$marker_live"; chmod 0600 "$marker_live"
: >"$marker_lock"; chmod 0600 "$marker_lock"
marker_harness=$root/marker-harness.sh
{
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nMARKER=%q\nMARKER_LOCK=%q\nnew_operation=%q\nnew_coordinator=%q\nmarker_lock_fd=${VIEWFLOW_MARKER_LOCK_FD-}\ndie(){ return 1; }\n' "$marker_live" "$marker_lock" "$fresh_op" "$fresh_coord"
    sed -n '/^assert_marker_lock_held()/,/^}/p' "$SOURCE"
    sed -n '/^validate_fresh_marker_record()/,/^}/p' "$SOURCE"
    sed -n '/^validate_fresh_marker_bytes()/,/^}/p' "$SOURCE"
    printf 'validate_fresh_marker_bytes\n'
} >"$marker_harness"; chmod 0700 "$marker_harness"
exec {fixture_lock_fd}<>"$marker_lock"; flock -x "$fixture_lock_fd"
marker_hash_a=$(/usr/bin/env -i PATH=/usr/bin:/bin VIEWFLOW_MARKER_LOCK_FD="$fixture_lock_fd" /usr/bin/bash "$marker_harness")
ln -s "$marker_a" "$root/fresh-symlink.marker"
sed "s|MARKER=$(printf '%q' "$marker_live")|MARKER=$(printf '%q' "$root/fresh-symlink.marker")|" "$marker_harness" >"$root/symlink-harness.sh"
chmod 0700 "$root/symlink-harness.sh"
if /usr/bin/env -i PATH=/usr/bin:/bin VIEWFLOW_MARKER_LOCK_FD="$fixture_lock_fd" /usr/bin/bash "$root/symlink-harness.sh" >/dev/null 2>&1; then
    printf 'error: marker symlink was accepted\n' >&2; exit 1
fi
cp "$marker_b" "$root/replacement.marker"; chmod 0600 "$root/replacement.marker"; mv -T "$root/replacement.marker" "$marker_live"
marker_hash_b=$(/usr/bin/env -i PATH=/usr/bin:/bin VIEWFLOW_MARKER_LOCK_FD="$fixture_lock_fd" /usr/bin/bash "$marker_harness")
[[ $marker_hash_a != "$marker_hash_b" ]] || { printf 'error: legal marker swap was not hash-visible\n' >&2; exit 1; }

# Execute the real locker/re-exec function from an outer harness. The outer
# process must be replaced, so only the locked inner branch may return from
# enter_marker_lock; its exact success/failure status becomes the caller's
# status and the outer continuation is unreachable.
reexec_lock=$root/reexec-marker.lock
reexec_harness=$root/marker-reexec-harness.sh
{
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nmarker_lock_fd=${VIEWFLOW_MARKER_LOCK_FD-}\nbridge_source_path=${VIEWFLOW_BRIDGE_SOURCE_PATH-$0}\nbridge_source_sha=${VIEWFLOW_BRIDGE_SOURCE_SHA256-}\nif [[ -z $marker_lock_fd ]]; then bridge_source_path=$0; bridge_source_sha=""; fi\nMARKER_LOCK=%q\noriginal_argv=("$@")\ndie(){ printf "reexec harness: %%s\\n" "$*" >&2; return 1; }\n' "$reexec_lock"
    sed -n '/^assert_marker_lock_held()/,/^}/p' "$SOURCE"
    sed -n '/^enter_marker_lock()/,/^}/p' "$SOURCE"
    cat <<'BASH'
rc=$1;inner_output=$2;outer_sentinel=$3
if [[ -n $marker_lock_fd ]]; then
    enter_marker_lock
    printf 'inner:%s\n' "$rc" >"$inner_output"
    exit "$rc"
fi
enter_marker_lock
printf 'outer-returned\n' >"$outer_sentinel"
exit 99
BASH
} >"$reexec_harness"
chmod 0700 "$reexec_harness"
inner_zero=$root/reexec-inner-zero outer_zero=$root/reexec-outer-zero
/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash "$reexec_harness" 0 "$inner_zero" "$outer_zero"
[[ $(<"$inner_zero") == inner:0 && ! -e $outer_zero ]] || {
    printf 'error: outer locker returned instead of exec-replacing on rc0\n' >&2; exit 1;
}
inner_fail=$root/reexec-inner-fail outer_fail=$root/reexec-outer-fail
if /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash "$reexec_harness" 37 "$inner_fail" "$outer_fail"; then
    printf 'error: locked inner nonzero status was not propagated\n' >&2; exit 1
else
    reexec_rc=$?
fi
[[ $reexec_rc == 37 && $(<"$inner_fail") == inner:37 && ! -e $outer_fail ]] || {
    printf 'error: outer locker nonzero propagation/unreachability differs\n' >&2; exit 1;
}

# Execute the production argv-contract functions with a capture double. This
# checks the actual argument vectors rather than merely grepping option names.
contract_lib=$root/contracts.sh
{
    sed -n '/^invoke_prepare_contract()/,/^}/p' "$SOURCE"
    sed -n '/^invoke_collector_contract()/,/^}/p' "$SOURCE"
} >"$contract_lib"
intent_json=$root/intent.json; printf '{"daemon_pid":77}\n' >"$intent_json"
prepare_argv=$root/prepare.argv collector_argv=$root/collector.argv
/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bash -s "$contract_lib" "$prepare_argv" "$collector_argv" "$intent_json" <<'BASH'
set -Eeuo pipefail
source "$1"; prepare_out=$2; collector_out=$3; intent=$4
run_pinned_bash() { local out=$CAPTURE; shift 0; printf '%s\n' "$@" >"$out"; }
prepare_script=/snap/prepare;prepare_script_sha=p_sha;marker_candidate=/snap/marker;marker_candidate_sha=m_sha
new_operation=0123456789abcdef0123456789abcdef;SOURCE_UUID=00000000-0000-0000-0000-000000000101
TARGET_UUID=00000000-0000-0000-0000-000000000002;new_coordinator=11111111-2222-4333-8444-555555555555
publish_receipt=/fresh/deployment-publish.json;handoff_receipt=/fresh/marker-handoff.json
CAPTURE=$prepare_out;invoke_prepare_contract
collector_script=/snap/collector;collector_script_sha=c_sha;installed_viewflow_sha=v_sha
CAPTURE=$collector_out;invoke_collector_contract "$intent" /fresh/.collector-stage.json
BASH
mapfile -t got_prepare <"$prepare_argv"
expected_prepare=(/snap/prepare p_sha --deployment-marker-candidate /snap/marker --deployment-marker-sha256 m_sha
 --operation-id 0123456789abcdef0123456789abcdef --source-display-id 00000000-0000-0000-0000-000000000101
 --target-device-id 00000000-0000-0000-0000-000000000002 --coordinator-instance-id 11111111-2222-4333-8444-555555555555
 --marker-generation 1 --deployment-publish-receipt /fresh/deployment-publish.json --bootstrap-handoff-receipt /fresh/marker-handoff.json)
[[ ${got_prepare[*]} == "${expected_prepare[*]}" ]] || { printf 'error: prepare argv contract differs\n' >&2; exit 1; }
mapfile -t got_collector <"$collector_argv"
expected_collector=(/snap/collector c_sha --daemon-pid 77 --daemon-sha256 v_sha --operation-id 0123456789abcdef0123456789abcdef --evidence-output /fresh/.collector-stage.json)
[[ ${got_collector[*]} == "${expected_collector[*]}" ]] || { printf 'error: collector argv contract differs\n' >&2; exit 1; }

/usr/bin/python3 -I - "$SOURCE" <<'PY'
from pathlib import Path
import copy,hashlib,re,sys,uuid
s=Path(sys.argv[1]).read_text()
for token in ('ensure_old_retired','ensure_persistent_started','recover_partial_marker_handoff','recover_after_collector_stop',
              'assert_process_census','unexpected Deskflow-displaying process','create-once publication raced',
              'observe_persistent_stably_stopped','assert_cgroup_only_main','snapshot_inputs',
              'validate_persistent_start_intent','assert_old_transient_absent','validate_persistent_live_before_receipt',
              'intent-authorized persistent service live tuple differs before receipt',
              'persistent receipt tuple became stale before create-once publication'):
 assert token in s, token

class Bridge:
 def __init__(self):
  self.f={};self.op=uuid.UUID('11111111-2222-3333-4444-555555555555').hex;self.marker=None;self.service=None
 def once(self,k,v):
  if k in self.f and self.f[k]!=v: raise RuntimeError('no-clobber')
  self.f[k]=v
 def exact_service(self,pid=77,ticks=202,invocation='a'*32):
  return {'unit':'viewflow-peer.service','active':'active','sub':'running','main':pid,'ticks':ticks,
          'invocation':invocation,'exe':'approved-viewflow-sha','argv':'approved-argv-sha',
          'cgroup':'/user.slice/viewflow-peer.service','cgroup_pids':[pid],'viewflow_pids':[pid],
          'udp_pid':pid,'sidecar_pid':pid,'deskflow':0,'tcp24800':0,'claims':0,'environment':'approved'}
 def expected_intent(self):return self.op+':old-stopped-sha:approved-viewflow-sha:approved-unit-sha'
 def validate_pre_receipt(self,captured=None):
  if self.f.get('persistent-start-intent')!=self.expected_intent():raise RuntimeError('intent-binding')
  if self.service is None:raise RuntimeError('incorrect-persistent')
  if self.service!=self.exact_service(self.service['main'],self.service['ticks'],self.service['invocation']):raise RuntimeError('incorrect-persistent')
  if captured is not None and any(self.service[key]!=captured[key] for key in ('main','ticks','invocation','cgroup','environment')):
   raise RuntimeError('stale-receipt-tuple')
  if self.f.get('old-unit','inactive')!='inactive':raise RuntimeError('old-unit-resurrected')
 def validate_old_recovery(self):
  if self.f.get('old-stopped')!='zero' or self.f.get('old-unit','inactive')!='inactive':raise RuntimeError('old-not-retired')
  if self.service is None:return
  if 'persistent-start-intent' not in self.f:raise RuntimeError('active-without-intent')
  self.validate_pre_receipt()
 def run(self,crash=None,extra=False,race=False,auto_restart=False,resurrect_old_after_probe=False,stale_tuple_after_probe=False):
  if extra: raise RuntimeError('extra-process')
  self.once('plan',self.op)
  if 'old-stopped' in self.f:self.validate_old_recovery()
  else:self.once('old-stopped','zero')
  if crash=='after-stop': return
  self.once('persistent-start-intent',self.expected_intent())
  if self.service is None:self.service=self.exact_service()
  self.validate_pre_receipt()
  if crash=='after-persistent-active-before-receipt':return
  captured=copy.deepcopy(self.service);self.once('fresh-auth-probe',str(captured['main'])+':'+captured['invocation'])
  if resurrect_old_after_probe:self.f['old-unit']='active-non-viewflow-helper'
  if stale_tuple_after_probe:self.service=self.exact_service(78,303,'b'*32)
  self.validate_pre_receipt(captured)
  self.once('persistent-started','auth-probe')
  if crash=='after-persistent-start': return
  marker='VFDQT:'+self.op
  if race: marker='VFDQT:'+'0'*32
  if self.marker is not None and self.marker!=marker: raise RuntimeError('marker-race')
  self.marker=marker
  if not self.marker.endswith(self.op): raise RuntimeError('marker-race')
  if crash=='after-marker-publish': return
  self.once('deployment-publish.json',hashlib.sha256(marker.encode()).hexdigest())
  self.once('marker-handoff.json','H')
  self.once('collector-intent','pid-ticks-invocation')
  if crash=='after-collector-stop': return
  if auto_restart: raise RuntimeError('auto-restart')
  self.once('linux-frozen.json','B');self.once('early-abort-terminal-to-fresh-v21.json','terminal')
for point in (None,'after-stop','after-persistent-active-before-receipt','after-persistent-start','after-marker-publish','after-collector-stop'):
 b=Bridge();b.run(point);old=b.op
 b.run()
 assert b.op==old and b.marker=='VFDQT:'+old
 assert all(x in b.f for x in ('deployment-publish.json','marker-handoff.json','linux-frozen.json','early-abort-terminal-to-fresh-v21.json'))
b=Bridge();b.run();b.f['linux-frozen.json']='attacker'
try:b.run()
except RuntimeError as e:assert str(e)=='no-clobber'
else:raise AssertionError('no-clobber failure')
for kwargs,label in (({'extra':True},'extra-process'),({'race':True},'marker-race'),({'auto_restart':True},'auto-restart')):
 try:Bridge().run(**kwargs)
 except RuntimeError as e:assert str(e)==label
 else:raise AssertionError(label+' accepted')
# A persistent process before any durable start intent is never grandfathered.
b=Bridge();b.once('plan',b.op);b.once('old-stopped','zero');b.service=b.exact_service()
try:b.run()
except RuntimeError as e:assert str(e)=='active-without-intent'
else:raise AssertionError('active persistent without intent accepted')
# Resume immediately after service activation but before its authenticated
# receipt, then reject an extra Viewflow PID and each representative bad tuple.
for field,value,label in (('viewflow_pids',[77,88],'rogue persistent'),('cgroup_pids',[77,88],'cgroup helper'),
                          ('exe','attacker-sha','wrong executable'),('argv','attacker-argv','wrong argv'),
                          ('udp_pid',88,'wrong UDP owner'),('sidecar_pid',88,'wrong sidecar owner')):
 b=Bridge();b.run('after-persistent-active-before-receipt');b.service[field]=value
 try:b.run()
 except RuntimeError as e:assert str(e)=='incorrect-persistent'
 else:raise AssertionError(label+' accepted before persistent receipt')
b=Bridge();b.run('after-persistent-active-before-receipt');b.f['persistent-start-intent']='wrong-binding'
try:b.run()
except RuntimeError as e:assert str(e)=='intent-binding'
else:raise AssertionError('mutated persistent start intent accepted')
# Recreate the retired unit with a non-Viewflow/non-Deskflow helper after the
# fresh authenticated probe: the last observation before receipt publication
# must still reject it. Also reject a fully valid new persistent invocation,
# because the receipt was assembled from the now-stale captured tuple.
for kwargs,label in (({'resurrect_old_after_probe':True},'old-unit-resurrected'),
                     ({'stale_tuple_after_probe':True},'stale-receipt-tuple')):
 try:Bridge().run(**kwargs)
 except RuntimeError as e:assert str(e)==label
 else:raise AssertionError(label+' accepted after authenticated probe')
PY

printf 'early-abort terminal to fresh-v2.1 schema/crash fixture passed\n'
