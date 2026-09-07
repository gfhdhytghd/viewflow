#!/usr/bin/env bash
# shellcheck disable=SC2094,SC2155
set -Eeuo pipefail
umask 077
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly LINUX=$(cd -- "$HERE/.." && pwd)
root=$(mktemp -d --tmpdir 'viewflow-bridge-input.XXXXXX')
trap 'rm -rf -- "$root"' EXIT
copy=$root/bridge.sh
python3 - "$LINUX/bridge-abort-terminal-to-fresh-v21.sh" "$copy" "$root" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(); r=sys.argv[3]
s=s.replace('/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.',r+'/.deployment-quarantine.v1.abort-receipt.')
s=s.replace('readonly MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1','readonly MARKER='+r+'/deployment-quarantine.v1')
s=s.replace('readonly MARKER_CLAIM=/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim','readonly MARKER_CLAIM='+r+'/deployment-quarantine.v1.abort-claim')
s=s.replace('readonly RELEASE_CLAIM=/home/wilf/.local/state/viewflow/deployment-quarantine.v1.release-claim','readonly RELEASE_CLAIM='+r+'/deployment-quarantine.v1.release-claim')
s=s.replace('[[ $bridge_root == /home/wilf/.local/state/viewflow/bridges/$old_operation ]]','[[ $bridge_root == '+r+'/bridges/$old_operation ]]')
pathlib.Path(sys.argv[2]).write_text(s)
PY
chmod 0700 "$copy"

op=11111111111111111111111111111111
vf=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
df=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
core=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
marker=$root/marker.bin auth=$root/auth.json linux=$root/linux.json terminal=$root/terminal.json
candidate=$root/candidate prepare=$root/prepare collector=$root/collector
printf x >"$candidate"; printf '#!/bin/sh\n' >"$prepare"; printf '#!/bin/sh\n' >"$collector"

python3 - "$marker" "$op" <<'PY'
import sys,uuid
b=bytearray(256);op=sys.argv[2].encode();b[:8]=b'VFDQT001';b[8:13]=bytes((1,1,2,1,1));b[13]=len(op);b[16:16+len(op)]=op
b[144:160]=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes
b[160:176]=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes
b[176:192]=uuid.UUID('22222222-2222-2222-2222-222222222222').bytes
b[192:200]=(1).to_bytes(8,'little');b[200:208]=(1).to_bytes(8,'little');open(sys.argv[1],'wb').write(b)
PY
marker_sha=$(sha256sum "$marker" | awk '{print $1}')

jq -cn --arg op "$op" --arg marker "$marker_sha" --arg vf "$vf" '
 {schema_version:1,state:"viewflow-linux-v1.3-started-under-deployment-quarantine",operation_id:$op,protocol_version:"1.3",
 deployment_marker_sha256:$marker,viewflowd_sha256:$vf,unit:("viewflow-v13-recovery-"+$op+".service"),unit_active_state:"active",
 transient:true,kill_mode:"control-group",control_group:("/x/viewflow-v13-recovery-"+$op+".service"),
 expected_exec_start_sha256:$marker,exec_start_sha256:$marker,fd_gate_payload_sha256:$marker,
 main_pid:10,start_ticks:20,invocation_id:"33333333333333333333333333333333"}' >"$linux"
linux_sha=$(sha256sum "$linux" | awk '{print $1}')

jq -cn --arg op "$op" --arg marker "$marker_sha" --arg vf "$vf" --arg df "$df" --arg core "$core" \
 --arg path "$auth" --arg linux "$linux_sha" '
 {schema_version:2,state:"viewflow-deployment-quarantine-failed-pre-mutation-installer-baseline-restored-abort-authorized",
 operation_id:$op,coordinator_instance_id:"22222222-2222-2222-2222-222222222222",marker_generation:"1",marker_sha256:$marker,
 authorization_receipt_path:$path,marker_handoff_receipt_sha256:$marker,deployment_publish_receipt_sha256:$marker,
 linux_frozen_evidence_sha256:$marker,installer_exit_receipt_sha256:$marker,windows_stop_evidence_sha256:$marker,
 pre_mutation_retry_receipt_sha256:$marker,windows_live_proof_sha256:$marker,old_linux_viewflowd_sha256:$vf,
 old_linux_deskflow_sha256:$df,old_linux_deskflow_core_sha256:$core,old_windows_viewflowd_sha256:$marker,
 old_windows_wrapper_sha256:$marker,old_windows_task_xml_sha256:$marker,old_windows_rollback_sha256:$marker,
 linux_v13_started_receipt_sha256:$linux,windows_v13_started_receipt_sha256:$marker,
 authenticated_v13_peer_receipt_sha256:$marker,initial_force_release_executed:false,rollback_performed:false,
 windows_rollback_receipt_sha256:null,protocol_2_1:false}' >"$auth"
auth_sha=$(sha256sum "$auth" | awk '{print $1}')

abort=$root/.deployment-quarantine.v1.abort-receipt.${marker_sha}.${auth_sha}.v1
python3 - "$abort" "$marker" "$marker_sha" "$auth_sha" <<'PY'
import hashlib,sys
m=open(sys.argv[2],'rb').read();b=bytearray(384);b[:8]=b'VFDQA001';b[8:13]=bytes((1,1,1,3,1));b[16:272]=m
b[272:304]=bytes.fromhex(sys.argv[3]);b[304:336]=bytes.fromhex(sys.argv[4]);b[336:344]=(1).to_bytes(8,'little')
b[352:384]=hashlib.sha256(b[:352]).digest();open(sys.argv[1],'wb').write(b)
PY
abort_sha=$(sha256sum "$abort" | awk '{print $1}')

jq -cn --arg op "$op" --arg marker "$marker_sha" --arg auth "$auth_sha" --arg abort "$abort_sha" \
 --arg linux "$linux_sha" --arg df "$df" --arg core "$core" '
 {schema_version:2,state:"viewflow-failed-pre-mutation-installer-baseline-restored-abort-terminal",operation_id:$op,
 protocol_version:"1.3",protocol_2_1:false,normal_deployment_release:false,initial_force_release_executed:false,
 rollback_performed:false,windows_rollback_receipt_sha256:null,old_coordinator_terminal_state_sha256:$marker,
 deployment_marker_sha256:$marker,installer_exit_receipt_sha256:$marker,windows_stop_evidence_sha256:$marker,
 pre_mutation_retry_receipt_sha256:$marker,windows_live_proof_sha256:$marker,abort_authorization_sha256:$auth,
 deployment_abort_receipt_sha256:$abort,linux_v13_started_receipt_sha256:$linux,windows_v13_started_receipt_sha256:$marker,
 authenticated_v13_peer_receipt_sha256:$marker,linux_viewflow_unit_state:"active",linux_deskflow_unit_state:"active",
 linux_deskflow_unit:("deskflow-v13-recovery-"+$op+".service"),linux_deskflow_invocation_id:"44444444444444444444444444444444",
 linux_deskflow_control_group:("/x/deskflow-v13-recovery-"+$op+".service"),linux_deskflow_expected_exec_start_sha256:$marker,
 linux_deskflow_exec_start_sha256:$marker,linux_deskflow_executable_sha256:$df,linux_deskflow_core_executable_sha256:$core,
 linux_deskflow_main_pid:1,linux_deskflow_main_start_ticks:2,linux_deskflow_runtime_pid:3,
 linux_deskflow_runtime_start_ticks:4,linux_deskflow_core_pid:5,linux_deskflow_core_start_ticks:6}' >"$terminal"
terminal_sha=$(sha256sum "$terminal" | awk '{print $1}')
chmod 0600 "$auth" "$linux" "$terminal" "$abort" "$candidate" "$prepare" "$collector"

args=(--validate-inputs-only --old-operation-id "$op" --abort-terminal "$terminal" --abort-terminal-sha256 "$terminal_sha"
 --abort-authorization "$auth" --abort-authorization-sha256 "$auth_sha" --abort-binary-receipt "$abort" --abort-binary-receipt-sha256 "$abort_sha"
 --linux-v13-started-receipt "$linux" --linux-v13-started-receipt-sha256 "$linux_sha" --bubblewrap-sha256 "$vf"
 --installed-viewflow-sha256 "$vf" --installed-viewflow-unit-sha256 "$vf" --deployment-marker-candidate "$candidate"
 --deployment-marker-sha256 "$(sha256sum "$candidate"|awk '{print $1}')" --prepare-script "$prepare" --prepare-script-sha256 "$(sha256sum "$prepare"|awk '{print $1}')"
 --collector-script "$collector" --collector-script-sha256 "$(sha256sum "$collector"|awk '{print $1}')" --bridge-root "$root/bridges/$op")

/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${args[@]}" >/dev/null
printf X | dd of="$abort" bs=1 seek=352 conv=notrunc status=none
if /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${args[@]}" >/dev/null 2>&1; then
    printf 'error: corrupt VFDQA checksum was accepted\n' >&2; exit 1
fi
printf 'abort-terminal to fresh-v2.1 input fixture passed\n'
