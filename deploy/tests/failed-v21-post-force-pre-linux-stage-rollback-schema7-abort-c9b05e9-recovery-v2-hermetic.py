#!/usr/bin/env python3
"""Hermetic checks for c9 committed-abort recovery-v2."""

import ast,hashlib,importlib.util,json,os,pathlib,tempfile

ROOT=pathlib.Path("/home/wilf/data/viewflow")
GATE=pathlib.Path(os.environ.get("VF_C9_RECOVERY_V2_GATE",ROOT/"deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-gate.py"))
MANIFEST=pathlib.Path(os.environ.get("VF_C9_RECOVERY_V2_MANIFEST",ROOT/"deploy/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2-manifest.json"))
spec=importlib.util.spec_from_file_location("c9_recovery_v2",GATE); gate=importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
manifest=json.loads(MANIFEST.read_bytes())

def must_fail(call,label):
    try: call()
    except (gate.GateError,OSError,ValueError,KeyError,TypeError,AssertionError): return
    raise AssertionError(label+" accepted")

predecessor,raws,documents=gate.validate_manifest(manifest)
source=GATE.read_text()
assert "run_coordinator" not in source and "windows_live" not in source and "/usr/bin/ssh" not in source
tree=ast.parse(source,filename=str(GATE))
functions={node.name:node for node in tree.body if isinstance(node,ast.FunctionDef)}
def call_count(function,name):
    return sum(isinstance(node,ast.Call) and isinstance(node.func,ast.Name)
               and node.func.id==name for node in ast.walk(functions[function]))
assert call_count("validate_manifest","validate_vfdqa")==1
assert call_count("validate_manifest","validate_committed")==1
assert call_count("validate_manifest","validate_authorization")==1
assert call_count("validate_manifest","validate_receipt")==1
assert call_count("validate_query","validate_receipt")==1
assert call_count("main","run_marker_query")==1
assert call_count("main","create_once")==2
assert all(call_count(name,"run_coordinator")==0 for name in functions)
assert manifest["recovery_policy"]=={"abort_redispatch_forbidden":True,"coordinator_dispatch_forbidden":True,"local_receipt_reconstruction_enabled":False,"only_pinned_marker_query":True}
assert hashlib.sha256(pathlib.Path(manifest["predecessor"]["approval"]["path"]).read_bytes()).hexdigest()==manifest["predecessor"]["approval"]["sha256"]
assert hashlib.sha256(pathlib.Path(manifest["post_abort"]["durable_vfdqa"]["path"]).read_bytes()).hexdigest()==manifest["post_abort"]["durable_vfdqa"]["sha256"]
assert documents["linux_v13_started"]["state"]=="viewflow-linux-v1.3-started-under-deployment-quarantine"
assert documents["windows_v13_started"]["state"]=="viewflow-windows-v1.3-started-under-deployment-quarantine"
assert documents["authenticated_v13_peer"]["state"]=="viewflow-v1.3-peer-authenticated-under-deployment-quarantine"

bad_authorization=json.loads(json.dumps(documents["authorization"])); bad_authorization["force_release_executed"]=False
must_fail(lambda:gate.validate_authorization(bad_authorization,manifest),"no-op authorization validator")
bad_receipt=json.loads(json.dumps(documents["abort_receipt"])); bad_receipt["rollback_performed"]=False
must_fail(lambda:gate.validate_receipt(bad_receipt,manifest,manifest["committed"]["authorization"]["sha256"],False),"no-op receipt validator")
bad_documents=json.loads(json.dumps(documents)); bad_documents["linux_v13_started"]["state"]="forged-state"
must_fail(lambda:gate.validate_committed(manifest,bad_documents),"no-op committed validator")

# The forged VFDQA is itself hash-bound in its local manifest.  Only parsing
# its ABI/checksum and retired marker relationship can reject it.
with tempfile.TemporaryDirectory(prefix="viewflow-c9-forged-vfdqa-") as temporary:
    parent=pathlib.Path(temporary); forged_manifest=json.loads(json.dumps(manifest))
    durable_raw=bytearray(pathlib.Path(manifest["post_abort"]["durable_vfdqa"]["path"]).read_bytes())
    durable_raw[8]^=1
    durable=parent/"durable.vfdqa"; retired=parent/"retired.marker"
    durable.write_bytes(durable_raw)
    retired.write_bytes(pathlib.Path(manifest["post_abort"]["retired_claim"]["path"]).read_bytes())
    os.chmod(durable,0o600); os.chmod(retired,0o600)
    forged_manifest["post_abort"]={"marker_path":str(parent/"deployment-quarantine.v1"),
      "public_absent":[str(parent/"deployment-quarantine.v1"),str(parent/"deployment-quarantine.v1.abort-claim"),str(parent/"deployment-quarantine.v1.release-claim")],
      "durable_vfdqa":{"path":str(durable),"sha256":hashlib.sha256(durable_raw).hexdigest(),"mode":600,"size":384},
      "retired_claim":{"path":str(retired),"sha256":hashlib.sha256(retired.read_bytes()).hexdigest(),"mode":600,"size":256}}
    must_fail(lambda:gate.validate_vfdqa(forged_manifest,documents["abort_receipt"],manifest["committed"]["authorization"]["sha256"]),"manifest-bound forged VFDQA")

marker=dict(documents["abort_receipt"]); marker["replayed"]=True
marker_raw=gate.canonical(marker); gate.validate_receipt(marker,manifest,manifest["committed"]["authorization"]["sha256"],True)
class QueryResult:
    returncode=0; stderr=b""; stdout=marker_raw
observed={}; real_run=gate.subprocess.run
def fake_run(argv,**kwargs): observed["argv"]=argv; observed["kwargs"]=kwargs; return QueryResult()
gate.subprocess.run=fake_run
try: assert gate.run_marker_query(manifest,manifest["committed"]["authorization"]["sha256"])==marker_raw
finally: gate.subprocess.run=real_run
assert observed["argv"][1:4]==["query","--operation-id",gate.OP]
assert "--coordinator-instance-id" in observed["argv"] and "--abort-authorization-sha256" in observed["argv"]
assert observed["kwargs"]["stdin"] is gate.subprocess.DEVNULL and observed["kwargs"]["timeout"]==30
envelope=gate.query_envelope(manifest,marker_raw); envelope_raw=gate.canonical(envelope)
assert gate.validate_query(manifest,envelope_raw)==envelope
assert envelope["coordinator_redispatched"] is False and envelope["marker_abort_redispatched"] is False
bad=dict(envelope); bad["coordinator_redispatched"]=True
must_fail(lambda:gate.validate_query(manifest,gate.canonical(bad)),"coordinator redispatch query")
bad=dict(envelope); bad["marker_abort_redispatched"]=True
must_fail(lambda:gate.validate_query(manifest,gate.canonical(bad)),"abort redispatch query")

ms="6"*64; gs="7"*64; ls="8"*64; aps="9"*64
approval={"schema_version":2,"state":"viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved",
 "approved":True,"operation_id":gate.OP,"manifest_sha256":ms,"gate_sha256":gs,"launcher_sha256":ls,
 "predecessor_approval_sha256":manifest["predecessor"]["approval"]["sha256"],
 "coordinator_dispatch_forbidden":True,"abort_redispatch_forbidden":True,"only_pinned_marker_query":True,
 "authorization_sha256":manifest["committed"]["authorization"]["sha256"],
 "abort_receipt_sha256":manifest["committed"]["abort_receipt"]["sha256"],
 "transition_sha256":manifest["committed"]["transition"]["sha256"],
 "linux_v13_started_sha256":manifest["committed"]["linux_v13_started"]["sha256"],
 "windows_v13_started_sha256":manifest["committed"]["windows_v13_started"]["sha256"],
 "authenticated_v13_peer_sha256":manifest["committed"]["authenticated_v13_peer"]["sha256"],
 "durable_vfdqa_sha256":manifest["post_abort"]["durable_vfdqa"]["sha256"],
 "retired_claim_sha256":manifest["post_abort"]["retired_claim"]["sha256"],
 "publication_method":"create-once-no-replace-and-parent-fsync","approved_at_utc":"2026-09-04T18:00:00.000Z"}
gate.validate_recovery_approval(manifest,gate.canonical(approval),ms,gs,ls)
old_approval=pathlib.Path(manifest["predecessor"]["approval"]["path"]).read_bytes()
must_fail(lambda:gate.validate_recovery_approval(manifest,old_approval,ms,gs,ls),"old approval reuse")
terminal=gate.terminal_document(manifest,ms,gs,ls,aps,envelope_raw); terminal_raw=gate.canonical(terminal)
gate.validate_terminal(manifest,terminal_raw,ms,gs,ls,aps,envelope_raw)
bad_terminal=dict(terminal); bad_terminal["coordinator_redispatched"]=True
must_fail(lambda:gate.validate_terminal(manifest,gate.canonical(bad_terminal),ms,gs,ls,aps,envelope_raw),"terminal redispatch")

real_lexists=gate.os.path.lexists; approval_path=manifest["approval_path"]
gate.os.path.lexists=lambda p:p==approval_path or real_lexists(p)
try: gate.validate_manifest(manifest,True,False)
finally: gate.os.path.lexists=real_lexists

with tempfile.TemporaryDirectory(prefix="viewflow-c9-recovery-v2-") as temp:
    root=pathlib.Path(temp); os.chmod(root,0o700); old_root=gate.ROOT; gate.ROOT=root
    try:
        out=root/"query.json"; gate.create_once(str(out),envelope_raw)
        must_fail(lambda:gate.create_once(str(out),b"forged\n"),"query overwrite")
        assert gate.stable_generated_read(str(out),"query")==envelope_raw
    finally: gate.ROOT=old_root

print("c9b05e9 committed-abort recovery-v2 hermetic tests passed")
