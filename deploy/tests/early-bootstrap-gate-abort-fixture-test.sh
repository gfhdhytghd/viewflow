#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
tool=${EARLY_BOOTSTRAP_GATE_ABORT_SOURCE:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort.py}

python3 - "$root" <<'PY'
import hashlib,json,os,stat,subprocess,sys,uuid
from pathlib import Path
r=Path(sys.argv[1]); op='2ca3'+'1'*28; opdir=r/op; opdir.mkdir()
def raw(path,data,mode=0o600):
 path.write_bytes(data);path.chmod(mode);return {'path':str(path),'sha256':hashlib.sha256(data).hexdigest(),'mode':int(oct(mode)[2:])}
def doc(name,value):return raw(r/name,(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode())
identity={'coordinator_instance_id':'33333333-3333-3333-3333-333333333333','source_display_id':'11111111-1111-1111-1111-111111111111','target_device_id':'22222222-2222-2222-2222-222222222222','marker_generation':'1'}
installed={name:raw(r/name,(name+' old bytes\n').encode(),0o755 if name!='viewflow_unit' else 0o644) for name in ('viewflowd','deskflow','deskflow_core','viewflow_unit')}
baseline={name:hashlib.sha256(name.encode()).hexdigest() for name in ('viewflowd_sha256','wrapper_sha256','task_xml_sha256','task_action_sha256','task_principal_sha256','rollback_sha256','command_line_sha256')};baseline.update(user_sid='S-1-5-21-1000',executable_path='C:\\Users\\wilf\\AppData\\Local\\Programs\\Viewflow\\viewflowd.exe',new_operation_root_path='C:\\Users\\wilf\\AppData\\Local\\Viewflow\\deployments\\'+op)
h=doc('marker-handoff.json',{'schema_version':1,'state':'viewflow-v13-marker-handoff-prepared','operation_id':op,'deskflow_executable_sha256':installed['deskflow']['sha256'],'deskflow_core_executable_sha256':installed['deskflow_core']['sha256'],'deskflow_unit_active_state':'inactive','deskflow_exact_process_count':0,'deskflow_core_exact_process_count':0,'deskflow_tcp_listener_count':0,'runtime_marker_present':False})
b=doc('linux-frozen.json',{'schema_version':1,'state':'viewflow-v13-bootstrap-frozen','operation_id':op,'daemon':{'sha256':installed['viewflowd']['sha256']},'pre_stop':{'deskflow_unit_active_state':'inactive','deskflow_exact_process_count':0,'deskflow_core_exact_process_count':0,'deskflow_tcp_24800_listener_count':0},'post_stop':{'unit_active_state':'inactive','main_pid':0,'exact_process_count':0}})
request=doc('windows-bootstrap-request.json',{'schema_version':1,'state':'request','operation_id':op})
marker=bytearray(256);marker[:8]=b'VFDQT001';marker[8:14]=bytes((1,1,2,1,1,len(op)));marker[16:16+len(op)]=op.encode();marker[144:160]=uuid.UUID(identity['source_display_id']).bytes;marker[160:176]=uuid.UUID(identity['target_device_id']).bytes;marker[176:192]=uuid.UUID(identity['coordinator_instance_id']).bytes;marker[192:200]=(1).to_bytes(8,'little');marker[200:208]=(1).to_bytes(8,'little')
marker_spec=raw(r/'deployment-quarantine.v1',bytes(marker)); marker_sha=marker_spec['sha256']
publish=doc('deployment-publish.json',{'schema_version':1,'state':'deployment-quarantine-published','protocol_version':'2.1','operation_id':op,**{k:identity[k] for k in ('source_display_id','target_device_id','coordinator_instance_id')},'marker_generation':'1','marker_path':marker_spec['path'],'marker_sha256':marker_sha,'created_at_unix_ms':'1','created_at_utc':'2026-08-31T00:00:00.000Z'})
stop=doc('windows-stop.json',{'schema_version':1,'state':'viewflow-windows-bootstrap-no-worker-stopped','operation_id':op,'request_sha256':request['sha256'],'status_sha256':'0'*64})
outputs={name:str(opdir/(name+'.json')) for name in ('windows_live','linux_started','windows_started','authenticated_peer','authorization','abort_receipt','pre_abort_reattest','post_abort_reattest','terminal')}
input_names=('marker_handoff','linux_frozen','publish_receipt','linux_viewflow','linux_marker_cli','linux_deskflow','linux_deskflow_core','linux_provenance','linux_viewflow_unit','linux_deskflow_dropin','windows_launcher','windows_installer','windows_viewflow','windows_wrapper','windows_rollback')
inputs={name:{'path':str(r/('input-'+name)),'sha256':hashlib.sha256(name.encode()).hexdigest()} for name in input_names};inputs['marker_handoff']={'path':h['path'],'sha256':h['sha256']};inputs['linux_frozen']={'path':b['path'],'sha256':b['sha256']};inputs['publish_receipt']={'path':publish['path'],'sha256':publish['sha256']}
output_names=('request','prepared','permit','force_envelope','linux_stage','windows_install','windows_exit','linux_finalize','release','cross_chain','post_release','windows_restart','cpp_status','cpp_arm','cpp_cleanup','rust_arm','rust_query','recovery_publish','linux_deactivation_proof','linux_deactivation_transcript','linux_containment','windows_validation','windows_rollback','recovery_bundle','windows_stop_evidence','recovery_publish_intent','windows_restart_intent')
local_outputs={name:str(r/('out-'+name)) for name in output_names};local_outputs['request']=request['path'];local_outputs['windows_stop_evidence']=stop['path']
remote_names=('operation_root','request','prepared','permit','force_envelope','linux_stage','windows_install','exit','readiness_receipt','readiness_lock','commit_request','rollback_manifest','rollback_token','recovery_bundle','recovery_force_release','rollback_receipt','rollback_claim','restart_intent','restart_claim','restart_terminal')
remote={name:baseline['new_operation_root_path']+(('\\'+name) if name!='operation_root' else '') for name in remote_names};remote['operation_root']=baseline['new_operation_root_path']
full_identity={**identity,'recovery_marker_generation':'2','windows_user_sid':baseline['user_sid'],'windows_task_xml_sha256_override':baseline['task_xml_sha256']}
contract={'identity':full_identity,'inputs':inputs,'outputs':local_outputs,'remote':remote}
committed={'marker_handoff':h['sha256'],'linux_frozen':b['sha256'],'publish_receipt':publish['sha256'],'bootstrap_request':request['sha256'],'windows_stop_evidence':stop['sha256']}
state=doc('coordinator-state.json',{'schema_version':2,'state':'viewflow-cross-host-bootstrap','operation_id':op,'phase':'LINUX_RECOVERED','recovery':{'failure_phase':None,'mutation_possible':False},'committed_artifacts':committed,'contract':contract})
helper_source=r'''import json,os,signal,sys,time
m=json.load(open(sys.argv[2]));a=sys.argv[1];root=os.path.dirname(os.path.dirname(m['outputs']['windows_live']));active_path=root+'/fixture-active';active=os.path.exists(active_path)
if a=='preflight' and active: raise SystemExit(1)
if a=='start-viewflow':
 open(active_path,'w').close();active=True;fault=root+'/fault-after-start'
 if os.path.exists(fault): os.unlink(fault);os.kill(os.getppid(),signal.SIGKILL);time.sleep(1);raise SystemExit(99)
elif a!='preflight' and not active: raise SystemExit(1)
if a=='pre-abort-reattest':
 fault=root+'/fault-after-authorization'
 if os.path.exists(fault): os.unlink(fault);os.kill(os.getppid(),signal.SIGKILL);time.sleep(1);raise SystemExit(99)
b=m['windows_baseline'];w={'task_path':'\\','task_name':'Viewflow Peer','task_state':'Running','task_xml_sha256':b['task_xml_sha256'],'task_action_sha256':b['task_action_sha256'],'task_principal_sha256':b['task_principal_sha256'],'request_sha256':m['artifacts']['bootstrap_request']['sha256'],'viewflowd_sha256':b['viewflowd_sha256'],'viewflowd_process_count':1,'wrapper_sha256':b['wrapper_sha256'],'rollback_sha256':b['rollback_sha256'],'pid':4242,'parent_pid':4000,'process_start_filetime_utc':'133700000000000000','session_id':1,'user_sid':b['user_sid'],'executable_path':b['executable_path'],'command_line_sha256':b['command_line_sha256'],'new_operation_root_path':b['new_operation_root_path'],'new_operation_root_present':False,'new_task_path':'\\','new_task_name':'Viewflow Deployment '+m['operation_id'],'new_task_present':False,'bootstrap_worker_created':False,'installer_process_count':0,'mutation_permit_published':False,'initial_force_release_executed':False,'force_release_executed':False,'rollback_performed':False,'windows_rollback_receipt_sha256':None,'protocol_2_1':False};l={'viewflow_unit':m['execution']['viewflow_unit'],'viewflow_unit_state':'active' if active else 'inactive','viewflow_main_pid':31337 if active else 0,'viewflow_start_ticks':777 if active else 0,'viewflow_invocation_id':'a'*32 if active else '','viewflow_control_group':'/fixture/'+m['execution']['viewflow_unit'] if active else '','viewflow_exec_start_sha256':'b'*64 if active else None,'viewflowd_sha256':m['installed']['viewflowd']['sha256'],'viewflow_process_count':1 if active else 0,'viewflow_udp_listener_count':1 if active else 0,'viewflow_sidecar_listener_count':1 if active else 0,'deskflow_unit_state':'inactive','deskflow_unit_main_pid':0,'deskflow_process_count':0,'deskflow_core_process_count':0,'deskflow_tcp_listener_count':0,'runtime_marker_present':False,'input_producer_count':0};print(json.dumps({'schema_version':1,'state':'viewflow-early-gate-'+a,'operation_id':m['operation_id'],'marker_sha256':m['marker']['sha256'],'marker_generation':'1','linux':l,'windows':w},sort_keys=True,separators=(',',':')))'''
helper=raw(r/'helper.py',helper_source.encode(),0o700)
marker_cli_source=r'''#!/usr/bin/python3
import hashlib,json,os,sys
a=sys.argv;query=a[1]=='query';auth_path=a[a.index('--abort-authorization-path')+1];auth=json.load(open(auth_path));root=os.path.dirname(os.path.dirname(auth_path));marker=root+'/deployment-quarantine.v1';claim=root+'/deployment-quarantine.v1.abort-claim';auth_sha=hashlib.sha256(open(auth_path,'rb').read()).hexdigest();durable=root+'/.deployment-quarantine.v1.abort-receipt.'+auth['marker_sha256']+'.'+auth_sha+'.v1'
if query and (os.path.exists(claim) or not os.path.exists(durable)):raise SystemExit(78)
if not query:
 count_path=root+'/fake-abort-count';count=int(open(count_path).read()) if os.path.exists(count_path) else 0;open(count_path,'w').write(str(count+1))
 fault=root+'/fault-after-claim'
 if os.path.exists(fault):os.rename(marker,claim);os.unlink(fault);raise SystemExit(75)
 marker_bytes_before=open(marker if os.path.exists(marker) else claim,'rb').read() if (os.path.exists(marker) or os.path.exists(claim)) else None
 if os.path.exists(marker):os.unlink(marker)
 if os.path.exists(claim):os.unlink(claim)
 if not os.path.exists(durable):
  marker_bytes=marker_bytes_before
  if len(marker_bytes)!=256:raise SystemExit(76)
  d=bytearray(384);d[:8]=b'VFDQA001';d[8:13]=bytes((1,1,1,3,1));d[16:272]=marker_bytes;d[272:304]=hashlib.sha256(marker_bytes).digest();d[304:336]=bytes.fromhex(auth_sha);d[336:344]=(2).to_bytes(8,'little');d[352:384]=hashlib.sha256(d[:352]).digest();open(durable,'wb').write(d);os.chmod(durable,0o600)
common={'schema_version':3,'state':'deployment-quarantine-aborted','protocol_version':'1.3','protocol_2_1':False,'operation_id':auth['operation_id'],'source_display_id':'11111111-1111-1111-1111-111111111111','target_device_id':'22222222-2222-2222-2222-222222222222','coordinator_instance_id':auth['coordinator_instance_id'],'marker_generation':'1','marker_path':marker,'abort_claim_path':root+'/deployment-quarantine.v1.abort-claim','abort_receipt_path':durable,'abort_authorization_path':auth_path,'abort_authorization_sha256':auth_sha,'aborted_marker_sha256':auth['marker_sha256'],'marker_created_at_unix_ms':'1','abort_committed_at_unix_ms':'2','abort_committed_at_utc':'1970-01-01T00:00:00.002Z','abort_point':'abort-claim-unlink-and-parent-directory-fsync','deployment_release_claimed':False,'replayed':query,'authorization_state':auth['state']};extras=('coordinator_terminal_state_sha256','coordinator_failure_phase','coordinator_mutation_possible','marker_handoff_receipt_sha256','deployment_publish_receipt_sha256','linux_frozen_evidence_sha256','bootstrap_request_sha256','windows_stop_evidence_sha256','windows_live_proof_sha256','linux_v13_started_receipt_sha256','windows_v13_started_receipt_sha256','authenticated_v13_peer_receipt_sha256','windows_bootstrap_worker_created','windows_new_operation_root_present','windows_new_task_present','windows_installer_process_count','mutation_permit_published','force_release_executed','rollback_performed','windows_rollback_receipt_sha256','initial_force_release_executed','linux_deskflow_started','input_producer_count');common.update((k,auth[k]) for k in extras);print(json.dumps(common,sort_keys=True,separators=(',',':')))'''
driver=raw(r/'marker-cli-driver.py',marker_cli_source.encode(),0o700)
c_source='#include <unistd.h>\n#include <stdlib.h>\nint main(int c,char**v){char**a=calloc((size_t)c+2,sizeof(char*));if(!a)return 111;a[0]="/usr/bin/python3";a[1]="'+driver['path']+'";for(int i=1;i<c;i++)a[i+1]=v[i];execv(a[0],a);return 111;}\n'
(r/'marker-cli.c').write_text(c_source);subprocess.run(['/usr/bin/cc','-O2','-o',str(r/'marker-cli'),str(r/'marker-cli.c')],check=True);candidate=raw(r/'marker-cli',(r/'marker-cli').read_bytes(),0o755)
crate=r/'fixture-repo/crates/viewflow-deployment-marker';(crate/'src').mkdir(parents=True)
main=raw(crate/'src/main.rs',b'fn main() {}\n');library=raw(crate/'src/lib.rs',b'pub fn fixture() {}\n');package=raw(crate/'Cargo.toml',b'[package]\nname="viewflow-deployment-marker"\nversion="0.0.0"\n');lock=raw(r/'fixture-repo/Cargo.lock',b'version = 4\n')
matrix={'cargo_fmt':'cargo fmt --all -- --check','cargo_test':'cargo test -p viewflow-deployment-marker --bin viewflow-deployment-marker','cargo_clippy':'cargo clippy -p viewflow-deployment-marker --bin viewflow-deployment-marker -- -D warnings','cargo_fmt_passed':True,'cargo_test_passed':True,'cargo_clippy_passed':True}
release_build={'command':'cargo build --release -p viewflow-deployment-marker --bin viewflow-deployment-marker','cargo_version':'cargo 1.98.0 (797e8a9bc 2026-08-05)','rustc_version':'rustc 1.98.0 (88d9e12ae 2026-08-18)','toolchain':'stable-x86_64-unknown-linux-gnu','host_target':'x86_64-unknown-linux-gnu'}
provenance_value={'schema_version':1,'state':'viewflow-deployment-marker-reviewed-build','candidate':candidate,'rust_sources':{'main':main,'library':library},'package_manifest':package,'cargo_lock':lock,'release_build':release_build,'test_matrix':matrix}
assert set(provenance_value)=={'schema_version','state','candidate','rust_sources','package_manifest','cargo_lock','release_build','test_matrix'}
assert set(release_build)=={'command','cargo_version','rustc_version','toolchain','host_target'}
provenance=doc('marker-reviewed-build.json',provenance_value);candidate={**candidate,'reviewed_build_manifest':provenance}
manifest={'schema_version':1,'state':'viewflow-early-bootstrap-gate-abort-manifest','operation_id':op,'identity':identity,'artifacts':{'coordinator_state':state,'marker_handoff':h,'linux_frozen':b,'deployment_publish':publish,'bootstrap_request':request,'windows_stop_evidence':stop},'installed':installed,'marker':marker_spec,'windows_baseline':baseline,'runtime_helper':helper,'execution':{'marker_candidate':candidate,'viewflow_unit':'viewflow-v13-early-'+op+'.service','marker_path':marker_spec['path'],'runtime_marker_path':str(r/'deskflow-quarantine.v2'),'abort_claim_path':str(r/'deployment-quarantine.v1.abort-claim'),'release_claim_path':str(r/'deployment-quarantine.v1.release-claim')},'outputs':outputs,'required_absent':[str(r/'deskflow-quarantine.v2'),str(r/'deployment-quarantine.v1.abort-claim'),str(r/'deployment-quarantine.v1.release-claim'),str(r/'durable-vfdqa-before-abort')]}
raw(r/'manifest.json',(json.dumps(manifest,sort_keys=True,separators=(',',':'))+'\n').encode())
PY

manifest=$root/manifest.json
manifest_sha=$(sha256sum -- "$manifest" | cut -d ' ' -f 1)
opdir="$root/2ca3$(printf '1%.0s' {1..28})"
python3 - "$manifest" "$root/non-elf-marker" "$root/non-elf-manifest.json" <<'PY'
import hashlib,json,os,sys
m=json.load(open(sys.argv[1]));data=b'#!/usr/bin/python3\n';open(sys.argv[2],'wb').write(data);os.chmod(sys.argv[2],0o755)
m['execution']['marker_candidate']={'path':sys.argv[2],'sha256':hashlib.sha256(data).hexdigest(),'mode':755,'reviewed_build_manifest':m['execution']['marker_candidate']['reviewed_build_manifest']}
raw=(json.dumps(m,sort_keys=True,separators=(',',':'))+'\n').encode();open(sys.argv[3],'wb').write(raw);os.chmod(sys.argv[3],0o600)
PY
bad_manifest_sha=$(sha256sum -- "$root/non-elf-manifest.json" | cut -d ' ' -f 1)
if python3 "$tool" --manifest "$root/non-elf-manifest.json" --manifest-sha256 "$bad_manifest_sha" --check-only >/dev/null 2>&1; then
    printf 'production manifest accepted a non-ELF marker candidate\n' >&2
    exit 1
fi
python3 - "$manifest" "$root" <<'PY'
import hashlib,json,os,sys
from pathlib import Path
m=json.load(open(sys.argv[1]));r=Path(sys.argv[2]);source=Path(m['runtime_helper']['path']).read_text()
variants={
 'unknown':source.replace("'viewflowd_process_count':1", "'unexpected_global_census':0,'viewflowd_process_count':1",1),
 'removed':source.replace("'viewflowd_process_count':1,", "",1),
 'value2':source.replace("'viewflowd_process_count':1", "'viewflowd_process_count':2",1),
}
for name,data in variants.items():
 if data==source: raise SystemExit('Windows census fixture mutation anchor differs')
 helper=r/('helper-'+name+'.py');helper.write_text(data);helper.chmod(0o700)
 candidate=json.loads(json.dumps(m));raw=data.encode();candidate['runtime_helper']={'path':str(helper),'sha256':hashlib.sha256(raw).hexdigest(),'mode':700}
 manifest=r/('manifest-'+name+'.json');encoded=(json.dumps(candidate,sort_keys=True,separators=(',',':'))+'\n').encode();manifest.write_bytes(encoded);manifest.chmod(0o600)
PY
for census_variant in unknown removed value2; do
    census_manifest="$root/manifest-$census_variant.json"
    census_sha=$(sha256sum -- "$census_manifest" | cut -d ' ' -f 1)
    if python3 "$tool" --manifest "$census_manifest" --manifest-sha256 "$census_sha" --check-only >/dev/null 2>&1; then
        printf 'Windows census variant was accepted: %s\n' "$census_variant" >&2
        exit 1
    fi
done
python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --check-only
[[ -z $(find "$opdir" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
    printf 'check-only created an output before abort\n' >&2; exit 1;
}
touch "$root/fault-after-start" "$root/fault-after-authorization"
touch "$root/fault-after-claim"
if python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --execute >/dev/null 2>&1; then
    printf 'post-systemd-run pre-receipt fault unexpectedly completed\n' >&2; exit 1
fi
[[ -e $root/fixture-active && -e $opdir/windows_live.json && ! -e $opdir/linux_started.json ]] || {
    printf 'post-systemd-run pre-receipt boundary differs\n' >&2; exit 1
}
touch "$opdir/windows_started.json"
if python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --check-only >/dev/null 2>&1; then
    printf 'check-only accepted a journal hole\n' >&2; exit 1
fi
rm -- "$opdir/windows_started.json"
before_resume=$(find "$opdir" -maxdepth 1 -type f -printf '%f ' -exec sha256sum -- {} \; | sort)
resume_report=$(python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --check-only)
[[ $resume_report == *'resumable at windows_live'* && $resume_report == *'boundary is active'* ]] || {
    printf 'check-only did not report exact active resume boundary\n' >&2; exit 1
}
after_resume=$(find "$opdir" -maxdepth 1 -type f -printf '%f ' -exec sha256sum -- {} \; | sort)
[[ $before_resume == "$after_resume" && -e $root/deployment-quarantine.v1 ]] || {
    printf 'check-only mutated the active resume boundary\n' >&2; exit 1
}
if python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --execute >/dev/null 2>&1; then
    printf 'post-authorization pre-abort fault unexpectedly completed\n' >&2; exit 1
fi
[[ -e $opdir/authorization.json && ! -e $opdir/pre_abort_reattest.json && -e $root/deployment-quarantine.v1 ]] || {
    printf 'post-authorization pre-abort boundary differs\n' >&2; exit 1
}
before_auth_check=$(find "$opdir" -maxdepth 1 -type f -printf '%f ' -exec sha256sum -- {} \; | sort)
auth_report=$(python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --check-only)
after_auth_check=$(find "$opdir" -maxdepth 1 -type f -printf '%f ' -exec sha256sum -- {} \; | sort)
[[ $auth_report == *'resumable at authorization'* && $before_auth_check == "$after_auth_check" ]] || {
    printf 'authorization check-only was not read-only/resumable\n' >&2; exit 1
}
if python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --execute >/dev/null 2>&1; then
    printf 'claim-only fault unexpectedly completed\n' >&2; exit 1
fi
[[ -e $root/deployment-quarantine.v1.abort-claim && ! -e $root/deployment-quarantine.v1 && -e $opdir/authorization.json ]] || {
    printf 'claim-only crash boundary differs\n' >&2; exit 1
}
if python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --check-only >/dev/null 2>&1; then
    printf 'check-only advanced a claim-only abort\n' >&2; exit 1
fi
[[ -e $root/deployment-quarantine.v1.abort-claim ]] || { printf 'check-only removed abort claim\n' >&2; exit 1; }
python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --execute
local_abort_sha=$(sha256sum -- "$opdir/abort_receipt.json" | cut -d ' ' -f 1)
rm -f -- "$opdir/terminal.json" "$opdir/post_abort_reattest.json"
touch "$root/deployment-quarantine.v1.abort-claim"
if python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --check-only >/dev/null 2>&1; then
    printf 'check-only advanced a claim-plus-durable abort\n' >&2; exit 1
fi
[[ ! -e $opdir/terminal.json && ! -e $opdir/post_abort_reattest.json ]] || {
    printf 'check-only mutated the partial-abort recovery boundary\n' >&2; exit 1;
}
python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --execute
[[ $(sha256sum -- "$opdir/abort_receipt.json" | cut -d ' ' -f 1) == "$local_abort_sha" ]] || {
    printf 'resume overwrote the original local abort receipt\n' >&2; exit 1;
}
[[ $(<"$root/fake-abort-count") == 3 ]] || {
    printf 'resume did not replay the abort transaction before query\n' >&2; exit 1;
}
python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --execute

cp -- "$root/coordinator-state.json" "$root/coordinator-state.saved"
printf 'x' >>"$root/coordinator-state.json"
if python3 "$tool" --manifest "$manifest" --manifest-sha256 "$manifest_sha" --check-only >/dev/null 2>&1; then
    printf 'terminal replay bypassed immutable manifest validation\n' >&2
    exit 1
fi
mv -- "$root/coordinator-state.saved" "$root/coordinator-state.json"

python3 - "$root" <<'PY'
import json,sys
from pathlib import Path
r=Path(sys.argv[1]);op='2ca3'+'1'*28;t=json.load(open(r/op/'terminal.json'));a=json.load(open(r/op/'authorization.json'))
assert t['state']=='viewflow-early-bootstrap-gate-abort-terminal'
assert t['deskflow_process_count']==t['deskflow_core_process_count']==t['deskflow_tcp_listener_count']==0
assert a['schema_version']==3 and a['coordinator_failure_phase'] is None and a['coordinator_mutation_possible'] is False
assert a['windows_bootstrap_worker_created'] is False and a['windows_installer_process_count']==0
assert a['mutation_permit_published'] is False and a['force_release_executed'] is False
assert not (r/'deployment-quarantine.v1').exists()
PY
printf 'early bootstrap gate abort isolated fixture passed\n'
