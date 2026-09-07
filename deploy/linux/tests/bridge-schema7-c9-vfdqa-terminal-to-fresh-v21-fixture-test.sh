#!/usr/bin/env bash
set -Eeuo pipefail
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly BRIDGE=$HERE/../bridge-schema7-c9-vfdqa-terminal-to-fresh-v21.py
root=$(mktemp -d --tmpdir 'viewflow-c9-schema7-bridge.XXXXXX')
trap 'rm -rf -- "$root"' EXIT
ROOT="$root" BRIDGE_PATH="$BRIDGE" python3 -I - <<'PY'
import hashlib,importlib.util,json,os,stat,subprocess,sys
root=os.environ["ROOT"]; source=os.environ["BRIDGE_PATH"]
fm=bytearray(256);fm[:8]=b"VFDQT001";fm[8:13]=bytes((1,1,2,1,1));fm[13]=32;fm[16:48]="c9b05e9bea4140d69f9d137a0f992ba0".encode();fm[144:160]=__import__("uuid").UUID("00000000-0000-0000-0000-000000000101").bytes;fm[160:176]=__import__("uuid").UUID("00000000-0000-0000-0000-000000000002").bytes;fm[176:192]=__import__("uuid").UUID("86c03003-2b67-451d-a990-396e1a66b406").bytes;fm[192:200]=(1).to_bytes(8,"little");fm[200:208]=(1).to_bytes(8,"little");fixture_marker=hashlib.sha256(bytes(fm)).hexdigest()
copy=root+"/bridge.py"; text=open(source).read(); text=text.replace('C9_MARKER_SHA = "9bc030e47e4d148341cf3cf540f318d291614b39769590a1035e2dcbc336f90a"','C9_MARKER_SHA = "'+fixture_marker+'"'); open(copy,"w").write(text); source=copy
spec=importlib.util.spec_from_file_location("bridge",source); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
state=root+"/state"; old=m.OLD_OP; fresh="11111111111111111111111111111111"; coord="11111111-1111-4111-8111-111111111111"
for p in (state,state+"/deployments",state+"/deployments/"+old,state+"/deployments/"+fresh):
 os.makedirs(p,exist_ok=True);os.chmod(p,0o700)
d=state+"/deployments/"+old
H=lambda c:c*64
def write(path,value=None,raw=None):
 if raw is None: raw=(json.dumps(value,separators=(",",":"))+"\n").encode()
 open(path,"wb").write(raw);os.chmod(path,0o600);return path,hashlib.sha256(raw).hexdigest()
auth={k:H("a") for k in m.AUTH}
auth.update(**m.C9_ARTIFACTS,**m.C9_OLD,schema_version=7,state="viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized",operation_id=old,coordinator_instance_id=m.OLD_COORD,authorization_receipt_path=d+"/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-authorization.json",marker_generation="1",coordinator_terminal_state_sha256=m.C9_STATE_SHA,fresh_operation_lineage_receipt_sha256=m.C9_LINEAGE_SHA,force_release_executed=True,rollback_performed=True,linux_stage_committed=False,windows_install_committed=False,windows_installer_exit_present=False,initial_force_release_executed=True,second_force_release_executed=False,rollback_token_consumed=True,mutation_permit_published=True,coordinator_mutation_possible=True,protocol_2_1=False)
ap,ash=write(auth["authorization_receipt_path"],auth)
r={k:H("b") for k in m.RECEIPT}
r.update(schema_version=7,state="deployment-quarantine-aborted",operation_id=old,coordinator_instance_id=m.OLD_COORD,abort_authorization_sha256=ash,force_release_executed=True,rollback_performed=True,linux_stage_committed=False,windows_install_committed=False,windows_installer_exit_present=False,replayed=False)
rp,rsh=write(d+"/receipt.json",r);q=dict(r);q["replayed"]=True;qp,qsh=write(d+"/query.json",q)
marker=bytearray(256);marker[:8]=b"VFDQT001";marker[8:13]=bytes((1,1,2,1,1));marker[13]=32;marker[16:48]=old.encode();marker[144:160]=__import__("uuid").UUID("00000000-0000-0000-0000-000000000101").bytes;marker[160:176]=__import__("uuid").UUID("00000000-0000-0000-0000-000000000002").bytes;marker[176:192]=__import__("uuid").UUID(m.OLD_COORD).bytes;marker[192:200]=(1).to_bytes(8,"little");marker[200:208]=(1).to_bytes(8,"little");marker=bytes(marker); marker_sha=hashlib.sha256(marker).hexdigest();auth["marker_sha256"]=marker_sha
# Rewrite auth and receipts after their marker binding is known.
ap,ash=write(ap,auth)
for x,replay,path in ((r,False,rp),(q,True,qp)):
 for k in (m.AUTH & m.RECEIPT)-{"state","schema_version","authorization_receipt_path"}: x[k]=auth[k]
 x.update(abort_authorization_path=auth["authorization_receipt_path"],abort_authorization_sha256=ash,authorization_state=auth["state"],marker_generation="1",aborted_marker_sha256=marker_sha,marker_path=state+"/deployment-quarantine.v1",abort_claim_path=state+"/deployment-quarantine.v1.abort-claim",abort_receipt_path=state+"/.deployment-quarantine.v1.abort-receipt."+marker_sha+"."+ash+".v1",abort_point="abort-claim-atomic-retire-and-parent-directory-fsync",marker_created_at_unix_ms="1",abort_committed_at_unix_ms="2",abort_committed_at_utc="1970-01-01T00:00:00.002Z",source_display_id="00000000-0000-0000-0000-000000000101",target_device_id="00000000-0000-0000-0000-000000000002",protocol_version="1.3",deployment_release_claimed=False,initial_force_release_executed=True,second_force_release_executed=False,rollback_token_consumed=True,mutation_permit_published=True,coordinator_mutation_possible=True,protocol_2_1=False)
 x["replayed"]=replay
 write(path,x)
rsh=hashlib.sha256(open(rp,"rb").read()).hexdigest();qsh=hashlib.sha256(open(qp,"rb").read()).hexdigest()
v=bytearray(384);v[:8]=b"VFDQA001";v[8:16]=bytes.fromhex("0101010301000000");v[16:272]=marker;v[272:304]=hashlib.sha256(marker).digest();v[304:336]=bytes.fromhex(ash);v[336:344]=(2).to_bytes(8,"little");v[352:]=hashlib.sha256(v[:352]).digest()
vp,vsh=write(state+"/vfdqa",raw=bytes(v))
outs={}
for n,s in (("linux_v13_started","viewflow-v13-linux-started-frozen"),("windows_v13_started","viewflow-v13-windows-started-frozen"),("authenticated_v13_peer","viewflow-v13-authenticated-peer-validated")):
 outs[n]=write(d+"/"+n+".json",{"schema_version":1,"state":s,"operation_id":old})
auth["linux_v13_started_receipt_sha256"]=outs["linux_v13_started"][1];auth["windows_v13_started_receipt_sha256"]=outs["windows_v13_started"][1];auth["authenticated_v13_peer_receipt_sha256"]=outs["authenticated_v13_peer"][1]
ap,ash=write(ap,auth)
for x,replay,path in ((r,False,rp),(q,True,qp)):
 for k in (m.AUTH & m.RECEIPT)-{"state","schema_version","authorization_receipt_path"}: x[k]=auth[k]
 x.update(abort_authorization_sha256=ash,abort_receipt_path=state+"/.deployment-quarantine.v1.abort-receipt."+marker_sha+"."+ash+".v1",replayed=replay);write(path,x)
rsh=hashlib.sha256(open(rp,"rb").read()).hexdigest();qsh=hashlib.sha256(open(qp,"rb").read()).hexdigest()
v[304:336]=bytes.fromhex(ash);v[352:]=hashlib.sha256(v[:352]).digest();vp,vsh=write(vp,raw=bytes(v))
tp,tsh=write(d+"/transition.json",{"schema_version":1,"operation_id":old,"protocol_2_1":False,"normal_deployment_release":False,"old_coordinator_terminal_state_sha256":m.C9_STATE_SHA,"deployment_marker_sha256":marker_sha})
recovery_q={"schema_version":2,"state":"viewflow-c9b05e9-schema7-abort-recovery-v2-query-committed","operation_id":old,"coordinator_redispatched":False,"marker_abort_redispatched":False,"query_source":"sealed-marker-cli-query","predecessor_approval_sha256":"26b75c5187b843db57a0da262f5ebb0f4aec660ee60c4231fb707c034c6d5cb4","authorization_sha256":ash,"abort_receipt_sha256":rsh,"durable_vfdqa_sha256":vsh,"marker_query":q};rqraw=(json.dumps(recovery_q["marker_query"],sort_keys=True,separators=(",",":"))+"\n").encode();recovery_q["marker_query_sha256"]=hashlib.sha256(rqraw).hexdigest();qp,qsh=write(d+"/recovery-query.json",raw=(json.dumps(recovery_q,sort_keys=True,separators=(",",":"))+"\n").encode())
approval={k:H("c") for k in m.RECOVERY_APPROVAL};approval.update(schema_version=2,state="viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved",approved=True,operation_id=old,manifest_sha256=m.C9_MANIFEST_SHA,gate_sha256=m.C9_GATE_SHA,launcher_sha256=m.C9_LAUNCHER_SHA,predecessor_approval_sha256=recovery_q["predecessor_approval_sha256"],coordinator_dispatch_forbidden=True,abort_redispatch_forbidden=True,only_pinned_marker_query=True,authorization_sha256=ash,abort_receipt_sha256=rsh,durable_vfdqa_sha256=vsh,linux_v13_started_sha256=outs["linux_v13_started"][1],windows_v13_started_sha256=outs["windows_v13_started"][1],authenticated_v13_peer_sha256=outs["authenticated_v13_peer"][1],transition_sha256=tsh,retired_claim_sha256=marker_sha,publication_method="create-once-no-replace-and-parent-fsync",approved_at_utc="1970-01-01T00:00:00.000Z");arp,arsh=write(d+"/recovery-approval.json",approval)
t={k:H("c") for k in m.TERM};t.update(schema_version=2,state="viewflow-c9b05e9-schema7-vfdqa-abort-recovery-v2-terminal",operation_id=old,manifest_sha256=m.C9_MANIFEST_SHA,gate_sha256=m.C9_GATE_SHA,launcher_sha256=m.C9_LAUNCHER_SHA,approval_sha256=arsh,predecessor_approval_sha256=recovery_q["predecessor_approval_sha256"],authorization_sha256=ash,abort_receipt_sha256=rsh,transition_sha256=tsh,linux_v13_started_sha256=outs["linux_v13_started"][1],windows_v13_started_sha256=outs["windows_v13_started"][1],authenticated_v13_peer_sha256=outs["authenticated_v13_peer"][1],durable_vfdqa_sha256=vsh,retired_claim_sha256=marker_sha,query_sha256=qsh,coordinator_redispatched=False,marker_abort_redispatched=False,marker_absent=True,abort_claim_absent=True,release_claim_absent=True);term,tsh2=write(d+"/terminal.json",raw=(json.dumps(t,sort_keys=True,separators=(",",":"))+"\n").encode())
fd=state+"/deployments/"+fresh
fresh_marker=bytearray(256);fresh_marker[:8]=b"VFDQT001";fresh_marker[8:13]=bytes((1,1,2,1,1));fresh_marker[13]=32;fresh_marker[16:48]=fresh.encode();fresh_marker[144:160]=__import__("uuid").UUID("00000000-0000-0000-0000-000000000101").bytes;fresh_marker[160:176]=__import__("uuid").UUID("00000000-0000-0000-0000-000000000002").bytes;fresh_marker[176:192]=__import__("uuid").UUID(coord).bytes;fresh_marker[192:200]=(2).to_bytes(8,"little");fresh_marker[200:208]=(1).to_bytes(8,"little");mp,msh=write(state+"/deployment-quarantine.v1",raw=bytes(fresh_marker))
pp,ps=write(fd+"/deployment-publish.json",{"schema_version":1,"state":"deployment-quarantine-published","protocol_version":"2.1","operation_id":fresh,"source_display_id":"00000000-0000-0000-0000-000000000101","target_device_id":"00000000-0000-0000-0000-000000000002","coordinator_instance_id":coord,"marker_generation":"1","marker_path":mp,"marker_sha256":msh,"created_at_unix_ms":"1","created_at_utc":"1970-01-01T00:00:00.001Z"})
hp,hs=write(fd+"/marker-handoff.json",{"schema_version":1,"state":"viewflow-v13-marker-handoff-prepared","protocol_version":"2.1","operation_id":fresh,"source_display_id":"00000000-0000-0000-0000-000000000101","target_device_id":"00000000-0000-0000-0000-000000000002","coordinator_instance_id":coord,"marker_generation":"1","marker_cli_path":"/x","marker_cli_sha256":H("1"),"deployment_marker_path":mp,"deployment_marker_sha256":msh,"deployment_publish_receipt_path":pp,"deployment_publish_receipt_sha256":ps,"deskflow_unit":"deskflow.service","deskflow_unit_active_state":"inactive","deskflow_unit_main_pid":0,"deskflow_executable_path":"/x","deskflow_executable_sha256":H("2"),"deskflow_exact_process_count":0,"deskflow_core_executable_path":"/x","deskflow_core_executable_sha256":H("3"),"deskflow_core_exact_process_count":0,"deskflow_tcp_port":24800,"deskflow_tcp_listener_count":0,"runtime_marker_path":state+"/deskflow-quarantine.v2","runtime_marker_present":False,"observed_at_utc":"1970-01-01T00:00:00.000Z"})
fp,fs=write(fd+"/linux-frozen.json",{"schema_version":1,"state":"viewflow-v13-bootstrap-frozen","operation_id":fresh,"daemon":{},"journal":{},"pre_stop":{"deskflow_unit_active_state":"inactive","deskflow_main_pid":0,"deskflow_exact_process_count":0,"deskflow_core_exact_process_count":0,"deskflow_tcp_24800_listener_count":0},"post_stop":{"exact_process_count":0,"udp_44119_listener_count":0,"sidecar_socket_present":False,"original_daemon_pid_present":False},"completed_at_unix_ms":1})
args=["--old-operation-id",old,"--old-coordinator-uuid",m.OLD_COORD,"--fresh-operation-id",fresh,"--fresh-coordinator-uuid",coord,"--fresh-root",fd,"--output",fd+"/v4-inactive-terminal-to-fresh-v21.json"]
for n,p,s in (("terminal",term,tsh2),("recovery-approval",arp,arsh),("authorization",ap,ash),("abort-receipt",rp,rsh),("abort-query",qp,qsh),("vfdqa",vp,vsh),("linux-v13-started",*outs["linux_v13_started"]),("windows-v13-started",*outs["windows_v13_started"]),("authenticated-v13-peer",*outs["authenticated_v13_peer"]),("transition",tp,tsh),("deployment-publish",pp,ps),("marker-handoff",hp,hs),("linux-frozen",fp,fs)):
 args += ["--"+n,p,"--"+n+"-sha256",s]
env={"PATH":"/usr/bin:/bin","VIEWFLOW_BRIDGE_STATE":state}
original_p=open(pp,"rb").read();original_h=open(hp,"rb").read();original_m=open(mp,"rb").read();bad_m=bytearray(original_m);bad_m[14]=1;_,bad_msh=write(mp,raw=bytes(bad_m));bad_p=json.loads(original_p);bad_p["marker_sha256"]=bad_msh;_,bad_ps=write(pp,bad_p);bad_h=json.loads(original_h);bad_h["deployment_marker_sha256"]=bad_msh;bad_h["deployment_publish_receipt_sha256"]=bad_ps;_,bad_hs=write(hp,bad_h);bad=list(args);bad[bad.index("--deployment-publish-sha256")+1]=bad_ps;bad[bad.index("--marker-handoff-sha256")+1]=bad_hs
if subprocess.run([sys.executable,"-I",source,"--validate-inputs-only",*bad],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE).returncode==0: raise SystemExit("self-consistent fresh marker reserved-byte mutation accepted")
write(mp,raw=original_m);write(pp,raw=original_p);write(hp,raw=original_h)
for mode in ("--validate-inputs-only","--publish-final"):
 subprocess.run([sys.executable,"-I",source,mode,*args],env=env,check=True,stdout=subprocess.PIPE)
final=fd+"/v4-inactive-terminal-to-fresh-v21.json"
if not os.path.isfile(final):raise SystemExit("final missing")
outer=json.load(open(final))
if list(outer)!=["schema_version","state","old_operation_id","new_operation_id","new_coordinator_instance_id","marker_generation","inactive_source","persistent_v13","fresh_boundary"] or outer["state"]!="viewflow-v4-inactive-terminal-to-fresh-v21" or outer["new_operation_id"]!=fresh: raise SystemExit("normal-pipeline outer receipt differs")
again=subprocess.run([sys.executable,"-I",source,"--publish-final",*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
if again.returncode==0:raise SystemExit("create-once overwritten")
print("c9 schema7 bridge fixture passed")
PY
