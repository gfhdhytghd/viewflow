#!/usr/bin/env bash
# shellcheck disable=SC2016
# Hermetic schema fixture for the V4 terminal consumer.  It executes only the
# bridge's --validate-inputs-only path against a private state tree.
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); readonly HERE
LINUX=$(cd -- "$HERE/.." && pwd); readonly LINUX
readonly SOURCE=$LINUX/bridge-v4-a186-inactive-terminal-to-fresh-v21.sh
root=$(mktemp -d --tmpdir 'viewflow-v4-bridge-input.XXXXXX')
cleanup() { chmod -R u+w -- "$root" 2>/dev/null || true; rm -rf -- "$root"; }
trap cleanup EXIT

op=a18635e6e23f4304afaca816333f3455
coord=dfab52d5-4f02-496d-8d7a-2668ac42a376
state=$root/state
bridge_root=$state/v4-inactive-bridges/$op
deployment=$state/deployments/$op
mkdir -p -- "$bridge_root" "$deployment"
chmod 0700 "$state" "$state/deployments" "$state/v4-inactive-bridges" "$bridge_root" "$deployment"

candidate=$root/viewflow-deployment-marker
v4_cli=$root/no-retry-v4-marker-cli
provenance=$root/no-retry-v4-marker-provenance.json
prepare=$root/prepare-v13-marker-handoff.sh
collector=$root/collect-viewflow-v13-bootstrap-evidence.sh
printf 'fixture marker candidate\n' >"$candidate"
printf 'fixture V4 marker CLI\n' >"$v4_cli"
printf '#!/usr/bin/env bash\nexit 0\n' >"$prepare"
cp -- "$prepare" "$collector"
chmod 0755 "$candidate" "$prepare" "$collector"
chmod 0700 "$v4_cli"
candidate_sha=$(sha256sum "$candidate" | awk '{print $1}')
v4_cli_sha=$(sha256sum "$v4_cli" | awk '{print $1}')

terminal=$deployment/no-retry-v4-abort-terminal.json
approval=$deployment/failed-pre-mutation-abort-a18635e6-no-retry-recovery1-execution-approval.json
authorization=$deployment/no-retry-v4-abort-authorization.json
abort_receipt=$deployment/no-retry-v4-abort-receipt.json
abort_query=$deployment/no-retry-v4-abort-query-receipt.json
marker=$root/deployment-marker.bin
vfdqa=$state/.deployment-quarantine.v1.abort-receipt.fixture.v1

/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$marker" "$vfdqa" "$terminal" "$approval" "$authorization" "$abort_receipt" "$abort_query" "$provenance" "$op" "$coord" "$candidate" "$candidate_sha" "$v4_cli" "$v4_cli_sha" <<'PY'
import hashlib,json,os,sys,uuid
(marker_path,vfdqa_path,terminal_path,approval_path,auth_path,receipt_path,query_path,provenance_path,
 op,coord,candidate,candidate_sha,v4_cli,v4_cli_sha)=sys.argv[1:]
manifest='d628b3169232947a702d8ba95b6343985d02a8c05c7a450965d4086379e19c49'
gate='f8eee3443adfeb1adca67a96dd03ba835e6fd1e3d0758536c1724cb2659acae3'
launcher='ba3d055108e983b3eac66ad0701551c7e01bed96d8d2e030db76133d8650ef35'
H=lambda char:char*64
def write(path,value):
 data=(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
 with open(path,'wb') as stream: stream.write(data)
 os.chmod(path,0o600)
 return hashlib.sha256(data).hexdigest()

embedded=bytearray(256);raw=op.encode()
embedded[:8]=b'VFDQT001';embedded[8:13]=bytes((1,1,2,1,1));embedded[13]=len(raw);embedded[16:16+len(raw)]=raw
embedded[144:160]=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes
embedded[160:176]=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes
embedded[176:192]=uuid.UUID(coord).bytes;embedded[192:200]=(1000).to_bytes(8,'little');embedded[200:208]=(1).to_bytes(8,'little')
open(marker_path,'wb').write(embedded);os.chmod(marker_path,0o600)
marker_sha=hashlib.sha256(embedded).hexdigest()

approval={'schema_version':4,'state':'viewflow-failed-pre-mutation-no-retry-abort-execution-approved','approved':True,
 'operation_id':op,'manifest_sha256':manifest,'gate_sha256':gate,'launcher_sha256':launcher,
 'coordinator_state_sha256':H('c'),'marker_sha256':marker_sha,'v4_marker_cli_sha256':v4_cli_sha,
 'v4_marker_cli_provenance_sha256':'', 'transaction_implementation':'sealed-fd-native-rust-v4-abort-then-query',
 'approved_at_utc':'2026-09-03T20:00:00.000Z'}
provenance={'schema_version':1,'state':'viewflow-no-retry-v4-marker-candidate-provenance','operation_id':op,
 'built_at_utc':'2026-09-03T20:00:00.000Z','toolchain':{},'target':'x86_64-unknown-linux-gnu','standalone':True,
 'base':{},'candidate':{'path':v4_cli,'sha256':v4_cli_sha,'mode':'0700','owner_uid':1000,'owner_gid':1000,
 'link_count':1,'size':os.stat(v4_cli).st_size,'build_id':'fixture-build-id'},'verification':{}}
provenance_sha=write(provenance_path,provenance)
approval['v4_marker_cli_provenance_sha256']=provenance_sha
approval_sha=write(approval_path,approval)

auth={'schema_version':4,'state':'viewflow-deployment-quarantine-failed-pre-mutation-no-retry-abort-authorized',
 'operation_id':op,'coordinator_instance_id':coord,'marker_generation':'1','marker_sha256':marker_sha,
 'authorization_receipt_path':auth_path,'coordinator_terminal_state_sha256':H('c'),'coordinator_failure_phase':'WINDOWS_STARTED',
 'coordinator_mutation_possible':False,'marker_handoff_receipt_sha256':H('1'),'deployment_publish_receipt_sha256':H('2'),
 'linux_frozen_evidence_sha256':H('3'),'bootstrap_request_sha256':H('4'),'installer_exit_receipt_sha256':H('5'),
 'windows_stop_evidence_sha256':H('6'),'linux_inactive_proof_sha256':H('7'),'windows_old_peer_live_proof_sha256':H('8'),
 'windows_operation_root_inventory_sha256':H('9'),'old_linux_viewflowd_sha256':H('a'),'old_linux_deskflow_sha256':H('b'),
 'old_linux_deskflow_core_sha256':H('c'),'old_windows_viewflowd_sha256':H('d'),'old_windows_wrapper_sha256':H('e'),
 'old_windows_task_xml_sha256':H('f'),'old_windows_rollback_sha256':H('1'),'windows_operation_root_present':True,
 'windows_deployment_task_present':True,'windows_deployment_task_state':'Disabled','windows_bootstrap_worker_count':0,
 'windows_installer_process_count':0,'mutation_outputs_absent':True,'linux_viewflow_started':False,
 'linux_deskflow_started':False,'input_producer_count':0,'initial_force_release_executed':False,'rollback_performed':False,
 'windows_rollback_receipt_sha256':None,'protocol_2_1':False}
auth_sha=write(auth_path,auth)

vfdqa_path=os.path.join(os.path.dirname(vfdqa_path),'.deployment-quarantine.v1.abort-receipt.'+marker_sha+'.'+auth_sha+'.v1')
durable=bytearray(384);durable[:8]=b'VFDQA001';durable[8:13]=bytes((1,1,1,3,1));durable[16:272]=embedded
durable[272:304]=bytes.fromhex(marker_sha);durable[304:336]=bytes.fromhex(auth_sha);durable[336:344]=(2010).to_bytes(8,'little')
durable[352:384]=hashlib.sha256(durable[:352]).digest();open(vfdqa_path,'wb').write(durable);os.chmod(vfdqa_path,0o600)
vfdqa_sha=hashlib.sha256(durable).hexdigest()

receipt_keys='''abort_authorization_path abort_authorization_sha256 abort_claim_path abort_committed_at_unix_ms abort_committed_at_utc abort_point abort_receipt_path aborted_marker_sha256 authorization_state bootstrap_request_sha256 coordinator_failure_phase coordinator_instance_id coordinator_mutation_possible coordinator_terminal_state_sha256 deployment_publish_receipt_sha256 deployment_release_claimed initial_force_release_executed input_producer_count installer_exit_receipt_sha256 linux_deskflow_started linux_frozen_evidence_sha256 linux_inactive_proof_sha256 linux_viewflow_started marker_created_at_unix_ms marker_generation marker_handoff_receipt_sha256 marker_path mutation_outputs_absent old_linux_deskflow_core_sha256 old_linux_deskflow_sha256 old_linux_viewflowd_sha256 old_windows_rollback_sha256 old_windows_task_xml_sha256 old_windows_viewflowd_sha256 old_windows_wrapper_sha256 operation_id protocol_2_1 protocol_version replayed rollback_performed schema_version source_display_id state target_device_id windows_bootstrap_worker_count windows_deployment_task_present windows_deployment_task_state windows_installer_process_count windows_old_peer_live_proof_sha256 windows_operation_root_inventory_sha256 windows_operation_root_present windows_rollback_receipt_sha256 windows_stop_evidence_sha256'''.split()
receipt={key:auth[key] for key in receipt_keys if key in auth}
receipt.update({'abort_authorization_path':auth_path,'abort_authorization_sha256':auth_sha,
 'abort_claim_path':'/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim','abort_committed_at_unix_ms':'2010',
 'abort_committed_at_utc':'1970-01-01T00:00:02.01Z','abort_point':'abort-claim-unlink-and-parent-directory-fsync',
 'abort_receipt_path':vfdqa_path,'aborted_marker_sha256':marker_sha,'authorization_state':auth['state'],
 'deployment_release_claimed':False,'marker_created_at_unix_ms':'1000','marker_path':'/home/wilf/.local/state/viewflow/deployment-quarantine.v1',
 'protocol_version':'1.3','replayed':False,'schema_version':4,'source_display_id':'00000000-0000-0000-0000-000000000101',
 'state':'deployment-quarantine-aborted','target_device_id':'00000000-0000-0000-0000-000000000002'})
assert set(receipt)==set(receipt_keys)
receipt_sha=write(receipt_path,receipt)
query=dict(receipt);query['replayed']=True;query_sha=write(query_path,query)

terminal={'schema_version':4,'state':'viewflow-failed-pre-mutation-no-retry-vfdqa-abort-terminal','operation_id':op,
 'coordinator_terminal_state_sha256':H('c'),'coordinator_failure_phase':'WINDOWS_STARTED','coordinator_mutation_possible':False,
 'authorization_sha256':auth_sha,'abort_receipt_sha256':receipt_sha,'abort_query_receipt_sha256':query_sha,'vfdqa_binary_sha256':vfdqa_sha,
 'execution_approval_sha256':approval_sha,'manifest_sha256':manifest,'gate_sha256':gate,'launcher_sha256':launcher,
 'v4_marker_cli_sha256':v4_cli_sha,'v4_marker_cli_provenance_sha256':provenance_sha,'linux_inactive_pre_sha256':H('7'),
 'windows_old_peer_live_sha256':H('8'),'windows_operation_root_inventory_sha256':H('9'),'linux_inactive_post_sha256':H('a'),
 'windows_old_peer_post_sha256':H('b'),'marker_absent':True,'abort_claim_absent':True,'release_claim_absent':True,
 'runtime_marker_absent':True,'linux_viewflow_started':False,'linux_deskflow_started':False,'input_producer_count':0,
 'windows_old_peer_unchanged':True,'windows_operation_root_present':True,'windows_operation_root_unchanged':True,
 'windows_deployment_task_state':'Disabled','mutation_outputs_absent':True,'protocol_2_1':False}
write(terminal_path,terminal)
PY

provenance_sha=$(sha256sum "$provenance" | awk '{print $1}')
vfdqa=$(find "$state" -maxdepth 1 -type f -name '.deployment-quarantine.v1.abort-receipt.*.v1' -print -quit)
[[ -n $vfdqa ]] || { printf 'error: fixture VFDQA was not created\n' >&2; exit 1; }
terminal_sha=$(sha256sum "$terminal" | awk '{print $1}')
auth_sha=$(sha256sum "$authorization" | awk '{print $1}')
receipt_sha=$(sha256sum "$abort_receipt" | awk '{print $1}')
query_sha=$(sha256sum "$abort_query" | awk '{print $1}')
vfdqa_sha=$(sha256sum "$vfdqa" | awk '{print $1}')

copy=$root/bridge.sh
/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$SOURCE" "$copy" "$state" "$candidate" "$candidate_sha" "$v4_cli_sha" "$provenance_sha" "$v4_cli" <<'PY'
from pathlib import Path
import sys
source,target,state,candidate,candidate_sha,v4_sha,provenance_sha,v4=sys.argv[1:]
text=Path(source).read_text()
text=text.replace('readonly STATE=/home/wilf/.local/state/viewflow','readonly STATE='+state)
text=text.replace('readonly MARKER_CLI=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker','readonly MARKER_CLI='+candidate)
text=text.replace('readonly REVIEWED_MARKER_SHA=8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54','readonly REVIEWED_MARKER_SHA='+candidate_sha)
text=text.replace('readonly V4_MARKER_CLI_SHA=c237736c4d8d4db6ba6e118ac46dc083bdf3d8ae99a0b08716bc5d3206fc6c57','readonly V4_MARKER_CLI_SHA='+v4_sha)
text=text.replace('readonly V4_PROVENANCE_SHA=86c91f2f97e26b2f5c9f81207700c76207430e696a16a911389dc498e2dbe454','readonly V4_PROVENANCE_SHA='+provenance_sha)
text=text.replace("p['candidate']['size']==1003088", "p['candidate']['size']==%d" % Path(v4).stat().st_size)
text=text.replace("p['candidate']['build_id']=='6b116abd3f6f7b33cf84deb1e404056741388685'", "p['candidate']['build_id']=='fixture-build-id'")
Path(target).write_text(text)
PY
chmod 0755 "$copy"

args=(--validate-inputs-only --old-operation-id "$op" --v4-abort-terminal "$terminal" --v4-abort-terminal-sha256 "$terminal_sha"
 --abort-authorization "$authorization" --abort-authorization-sha256 "$auth_sha" --abort-receipt "$abort_receipt" --abort-receipt-sha256 "$receipt_sha"
 --abort-query-receipt "$abort_query" --abort-query-receipt-sha256 "$query_sha" --vfdqa "$vfdqa" --vfdqa-sha256 "$vfdqa_sha"
 --v4-marker-cli "$v4_cli" --v4-marker-cli-sha256 "$v4_cli_sha" --v4-marker-cli-provenance "$provenance" --v4-marker-cli-provenance-sha256 "$provenance_sha"
 --installed-viewflow-sha256 "$(printf 'a%.0s' {1..64})" --installed-viewflow-unit-sha256 "$(printf 'b%.0s' {1..64})"
 --deployment-marker-candidate "$candidate" --deployment-marker-sha256 "$candidate_sha" --prepare-script "$prepare" --prepare-script-sha256 "$(sha256sum "$prepare" | awk '{print $1}')"
 --collector-script "$collector" --collector-script-sha256 "$(sha256sum "$collector" | awk '{print $1}')" --bridge-root "$bridge_root")

output=$(/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${args[@]}")
[[ $output == 'schema4 no-retry/inactive abort inputs validated' ]] || { printf 'error: baseline fixture validation differs\n' >&2; exit 1; }

# Native Rust writes a shortest decimal UTC fraction, so .01Z is valid for
# 2010 ms; a different fraction must still be rejected by exact millisecond
# binding rather than merely by format.
time_receipt=$root/mutated-time-receipt.json
time_query=$root/mutated-time-query.json
jq '.abort_committed_at_utc="1970-01-01T00:00:02.011Z"' "$abort_receipt" >"$time_receipt"
jq '.abort_committed_at_utc="1970-01-01T00:00:02.011Z"' "$abort_query" >"$time_query"
chmod 0600 "$time_receipt" "$time_query"
time_receipt_sha=$(sha256sum "$time_receipt" | awk '{print $1}')
time_query_sha=$(sha256sum "$time_query" | awk '{print $1}')
time_terminal=$root/mutated-time-terminal.json
jq --arg receipt "$time_receipt_sha" --arg query "$time_query_sha" \
  '.abort_receipt_sha256=$receipt | .abort_query_receipt_sha256=$query' "$terminal" >"$time_terminal"
chmod 0600 "$time_terminal"
bad=("${args[@]}"); bad[4]=$time_terminal; bad[6]=$(sha256sum "$time_terminal" | awk '{print $1}')
bad[12]=$time_receipt; bad[14]=$time_receipt_sha; bad[16]=$time_query; bad[18]=$time_query_sha
if /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${bad[@]}" >/dev/null 2>&1; then
    printf 'error: UTC/millisecond mismatch was accepted\n' >&2; exit 1
fi

for field in execution_approval_sha256 manifest_sha256 gate_sha256 launcher_sha256; do
    mutated=$root/mutated-$field.json
    jq --arg field "$field" '.[$field]=("0"*64)' "$terminal" >"$mutated"
    chmod 0600 "$mutated"
    bad=("${args[@]}"); bad[4]=$mutated; bad[6]=$(sha256sum "$mutated" | awk '{print $1}')
    if /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${bad[@]}" >/dev/null 2>&1; then
        printf 'error: terminal %s binding mutation was accepted\n' "$field" >&2; exit 1
    fi
done

mutated_approval=$root/mutated-approval.json
jq '.gate_sha256=("0"*64)' "$approval" >"$mutated_approval"
chmod 0600 "$mutated_approval"
cp -- "$mutated_approval" "$approval"
chmod 0600 "$approval"
mutated_approval_sha=$(sha256sum "$approval" | awk '{print $1}')
mutated_terminal=$root/mutated-approval-terminal.json
jq --arg sha "$mutated_approval_sha" '.execution_approval_sha256=$sha' "$terminal" >"$mutated_terminal"
chmod 0600 "$mutated_terminal"
bad=("${args[@]}"); bad[4]=$mutated_terminal; bad[6]=$(sha256sum "$mutated_terminal" | awk '{print $1}')
if /usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$copy" "${bad[@]}" >/dev/null 2>&1; then
    printf 'error: execution approval content mutation was accepted\n' >&2; exit 1
fi

printf 'V4 inactive-terminal input fixture passed\n'
