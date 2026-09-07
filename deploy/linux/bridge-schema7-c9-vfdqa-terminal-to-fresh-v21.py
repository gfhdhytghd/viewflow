#!/usr/bin/env python3
"""Offline, fail-closed c9 schema7 VFDQA terminal -> fresh v2.1 bridge."""
from __future__ import annotations
import argparse, ctypes, errno, fcntl, hashlib, json, os, re, stat, sys, uuid

OLD_OP = "c9b05e9bea4140d69f9d137a0f992ba0"
OLD_COORD = "86c03003-2b67-451d-a990-396e1a66b406"
C9_MARKER_SHA = "9bc030e47e4d148341cf3cf540f318d291614b39769590a1035e2dcbc336f90a"
C9_COORDINATOR_SHA = "8248f1ce2e6fe8b642f059ab1019314094bb20272a10295875aacf3c93823fe8"
C9_STATE_SHA = "066ef1bfa69aa09989204245c16d15c19eb66003a8a715f553c70b76976d7e8f"
C9_LINEAGE_SHA = "6cc134872971fd1b25608c53e5e24d27ae5516ca1d457443ddeba91bda9fa982"
C9_MARKER_CLI_SHA = "266e052177aad1189b7a3b86f6e341347867aa1acd07f14dc64054bd4460d8cf"
C9_MANIFEST_SHA = "919bd49f40f4fe5cb140f22576613bc3e76a4489456e780956999c0cbfdd5d83"
C9_GATE_SHA = "a897d0d0f9084d1c2b0f8429ada1da8a5621d796cd3458be1b4a37d6b62b9a0e"
C9_LAUNCHER_SHA = "4450805d8a31c5c3194a687590088bd65255061e649b97983f87806cd5aeb657"
C9_ARTIFACTS = {"marker_handoff_receipt_sha256":"28446fd53ca7b1d25e450f101184b233c3fcef37e1d58963521ba34e1a1a2076","deployment_publish_receipt_sha256":"fad236ea6eed12e2e132a977ba9d2fed625e54d1559045d66dff7899129a6335","linux_frozen_evidence_sha256":"39e5542fb275527e4420c80475e3339781d7d1e61c58c2728fe4a2b4a76aff4a","bootstrap_request_sha256":"d03c7293236521937c0de597f0e59cd05965ed90276c58bb3baf6502b1547135","windows_prepared_receipt_sha256":"a11b2eabeebf4d0d9aa76e11a5af142701b16eaef87756f916ab0bbf6337054b","mutation_permit_receipt_sha256":"87e1e992872646b7e20600491b89aa599dd77465c8582f978e06d42973dfdc27","windows_force_envelope_sha256":"70ea5caa3000f2577aed5fce8addeee78fa9ddfde628a4008d474db5358237d2","windows_stop_evidence_sha256":"f82b580dcaf51ea39df69499e6070472f8d31f043480d94b6b62ce72601dbf2f","recovery_bundle_sha256":"77b68f5a6a084d48b59811f849f98e0aba6e471746ab1f69735f60586fd35e48","linux_deactivation_proof_sha256":"7c5245a5ea6dffa2a9d72fc3356ba198c2365e26cbccbaf758581a34bd8f00be","linux_deactivation_transcript_sha256":"47611f2811baa4d31715274a8bccfdb7d40be2f3e3e6e8eff690ed5905bc1df3","windows_rollback_receipt_sha256":"ca74763dd4579323ab495aa164931892929cebd0aa05e6624d07233d0bbf4cc1"}
C9_OLD = {"old_linux_viewflowd_sha256":"d142fbbc65e311fa17b3307c252689afbb3963dda3e265cedc3bca7887daf96d","old_linux_deskflow_sha256":"033065b0495a2b996a6731ecf6e47c2af476e1c120ab5d62dafb8b8aa3394c3f","old_linux_deskflow_core_sha256":"e2ebbfe39a1b7f5f3e30953340c000e5b249e8d957ceda5fb0e9c4efad0ffd52","old_windows_viewflowd_sha256":"f4f29e16ccf678a75199b4af1c1ec3975434991bd54ca9688e961262466fcc26","old_windows_wrapper_sha256":"3ca9b5f498a5b80a8a54c98666e62ea84019a41fab08d2dbd8fb6f0307f47698"}
STATE = os.environ.get("VIEWFLOW_BRIDGE_STATE", "/home/wilf/.local/state/viewflow")
HEX = re.compile(r"[0-9a-f]{64}\Z")
OP = re.compile(r"[0-9a-f]{32}\Z")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
RENAME_NOREPLACE = 1
class Fail(RuntimeError): pass
def fail(s): raise Fail(s)
def pairs(xs):
    d = {}
    for k,v in xs:
        if k in d: raise ValueError("duplicate key")
        d[k]=v
    return d
def sha(b): return hashlib.sha256(b).hexdigest()
def ident(s): return (s.st_dev,s.st_ino,s.st_size,s.st_mode,s.st_uid,s.st_nlink)
def load(path, expected, label):
    if not path.startswith("/") or not HEX.fullmatch(expected): fail(label+" pin differs")
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd); named=os.lstat(path)
        if not(stat.S_ISREG(before.st_mode) and before.st_uid==os.geteuid()
               and stat.S_IMODE(before.st_mode)==0o600 and before.st_nlink==1
               and ident(before)==ident(named)): fail(label+" metadata differs")
        raw=b""
        while True:
            chunk=os.read(fd,1<<20)
            if not chunk: break
            raw+=chunk
        if ident(os.fstat(fd))!=ident(before) or sha(raw)!=expected: fail(label+" changed")
    finally: os.close(fd)
    mfd=os.memfd_create("viewflow-c9-schema7-bridge",os.MFD_CLOEXEC|os.MFD_ALLOW_SEALING)
    try:
        os.write(mfd,raw); os.lseek(mfd,0,os.SEEK_SET)
        seals=fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL
        fcntl.fcntl(mfd,fcntl.F_ADD_SEALS,seals)
        if fcntl.fcntl(mfd,fcntl.F_GET_SEALS)!=seals or os.read(mfd,len(raw)+1)!=raw: fail(label+" sealed copy differs")
    finally: os.close(mfd)
    if label in ("vfdqa","fresh_marker"): return raw
    try:
        text=raw.decode("utf-8","strict")
        value,end=json.JSONDecoder(object_pairs_hook=pairs,parse_float=lambda _:(_ for _ in ()).throw(ValueError()),parse_constant=lambda _:(_ for _ in ()).throw(ValueError())).raw_decode(text)
    except Exception as e: raise Fail(label+" strict JSON differs") from e
    if type(value) is not dict or text[end:].strip(): fail(label+" must be one JSON object")
    if label in ("terminal","abort_query") and raw != (json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode(): fail(label+" is not canonical producer JSON")
    return value
def keys(v, wanted, label):
    if set(v)!=set(wanted): fail(label+" keys differ")
def publish(path, raw):
    parent,leaf=os.path.dirname(path),os.path.basename(path)
    dfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW); temp="."+leaf+".tmp."+str(os.getpid())
    try:
        ds=os.fstat(dfd)
        if ds.st_uid!=os.geteuid() or stat.S_IMODE(ds.st_mode)!=0o700: fail("output parent differs")
        try: os.stat(leaf,dir_fd=dfd,follow_symlinks=False); fail("create-once output exists")
        except FileNotFoundError: pass
        fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC,0o600,dir_fd=dfd)
        try: os.write(fd,raw);os.fsync(fd)
        finally: os.close(fd)
        libc=ctypes.CDLL(None,use_errno=True)
        if libc.renameat2(dfd,os.fsencode(temp),dfd,os.fsencode(leaf),RENAME_NOREPLACE):
            if ctypes.get_errno()==errno.EEXIST: fail("create-once output exists")
            raise OSError(ctypes.get_errno(),"renameat2")
        os.fsync(dfd)
    finally:
        try: os.unlink(temp,dir_fd=dfd)
        except FileNotFoundError: pass
        os.close(dfd)

AUTH = set("""authenticated_v13_peer_receipt_sha256 authorization_receipt_path bootstrap_request_sha256 coordinator_failure_phase coordinator_instance_id coordinator_mutation_possible coordinator_terminal_state_sha256 deployment_publish_receipt_sha256 force_release_executed fresh_operation_lineage_receipt_sha256 initial_force_release_executed linux_deactivation_proof_sha256 linux_deactivation_transcript_sha256 linux_frozen_evidence_sha256 linux_stage_committed linux_v13_started_receipt_sha256 marker_generation marker_handoff_receipt_sha256 marker_sha256 mutation_permit_published mutation_permit_receipt_sha256 old_linux_deskflow_core_sha256 old_linux_deskflow_sha256 old_linux_viewflowd_sha256 old_windows_viewflowd_sha256 old_windows_wrapper_sha256 operation_id protocol_2_1 recovery_bundle_sha256 rollback_performed rollback_token_consumed schema_version second_force_release_executed state windows_force_envelope_sha256 windows_install_committed windows_installer_exit_present windows_prepared_receipt_sha256 windows_rollback_receipt_sha256 windows_stop_evidence_sha256 windows_v13_started_receipt_sha256""".split())
TERM = set("""abort_claim_absent abort_receipt_sha256 approval_sha256 authenticated_v13_peer_sha256 authorization_sha256 coordinator_redispatched durable_vfdqa_sha256 gate_sha256 launcher_sha256 linux_v13_started_sha256 manifest_sha256 marker_abort_redispatched marker_absent operation_id predecessor_approval_sha256 query_sha256 release_claim_absent retired_claim_sha256 schema_version state transition_sha256 windows_v13_started_sha256""".split())
RECOVERY_QUERY = set("""abort_receipt_sha256 authorization_sha256 coordinator_redispatched durable_vfdqa_sha256 marker_abort_redispatched marker_query marker_query_sha256 operation_id predecessor_approval_sha256 query_source schema_version state""".split())
RECOVERY_APPROVAL = set("""abort_receipt_sha256 abort_redispatch_forbidden approved approved_at_utc authenticated_v13_peer_sha256 authorization_sha256 coordinator_dispatch_forbidden durable_vfdqa_sha256 gate_sha256 launcher_sha256 linux_v13_started_sha256 manifest_sha256 only_pinned_marker_query operation_id predecessor_approval_sha256 publication_method retired_claim_sha256 schema_version state transition_sha256 windows_v13_started_sha256""".split())
RECEIPT = set("""abort_authorization_path abort_authorization_sha256 abort_claim_path abort_committed_at_unix_ms abort_committed_at_utc abort_point abort_receipt_path aborted_marker_sha256 authenticated_v13_peer_receipt_sha256 authorization_state bootstrap_request_sha256 coordinator_failure_phase coordinator_instance_id coordinator_mutation_possible coordinator_terminal_state_sha256 deployment_publish_receipt_sha256 deployment_release_claimed force_release_executed fresh_operation_lineage_receipt_sha256 initial_force_release_executed linux_deactivation_proof_sha256 linux_deactivation_transcript_sha256 linux_frozen_evidence_sha256 linux_stage_committed linux_v13_started_receipt_sha256 marker_created_at_unix_ms marker_generation marker_handoff_receipt_sha256 marker_path mutation_permit_published mutation_permit_receipt_sha256 operation_id protocol_2_1 protocol_version recovery_bundle_sha256 replayed rollback_performed rollback_token_consumed schema_version second_force_release_executed source_display_id state target_device_id windows_force_envelope_sha256 windows_install_committed windows_installer_exit_present windows_prepared_receipt_sha256 windows_rollback_receipt_sha256 windows_stop_evidence_sha256 windows_v13_started_receipt_sha256""".split())
def parser():
    p=argparse.ArgumentParser()
    x=p.add_mutually_exclusive_group(required=True);x.add_argument("--validate-inputs-only",action="store_true");x.add_argument("--publish-final",action="store_true")
    for n in ("terminal","recovery-approval","authorization","abort-receipt","abort-query","vfdqa","linux-v13-started","windows-v13-started","authenticated-v13-peer","transition","deployment-publish","marker-handoff","linux-frozen"):
        p.add_argument("--"+n,required=True);p.add_argument("--"+n+"-sha256",required=True)
    for n in ("old-operation-id","old-coordinator-uuid","fresh-operation-id","fresh-coordinator-uuid","fresh-root","output"):p.add_argument("--"+n,required=True)
    return p.parse_args()
def truth(v, **want):
    return all(v.get(k)==x for k,x in want.items())
def validate_fresh_marker(p, a):
    raw=load(p["marker_path"],p["marker_sha256"],"fresh_marker")
    if not(len(raw)==256 and raw[:8]==b"VFDQT001" and raw[8:13]==bytes((1,1,2,1,1)) and raw[13]==32 and raw[14:16]==b"\0\0" and raw[16:48]==a.fresh_operation_id.encode() and not any(raw[48:144]) and raw[144:160]==uuid.UUID("00000000-0000-0000-0000-000000000101").bytes and raw[160:176]==uuid.UUID("00000000-0000-0000-0000-000000000002").bytes and raw[176:192]==uuid.UUID(a.fresh_coordinator_uuid).bytes and int.from_bytes(raw[192:200],"little")>0 and int.from_bytes(raw[200:208],"little")==1 and not any(raw[208:])): fail("fresh VFDQT identity differs")
def main():
    a=parser()
    if a.old_operation_id!=OLD_OP or a.old_coordinator_uuid!=OLD_COORD: fail("c9 identity differs")
    if not OP.fullmatch(a.fresh_operation_id) or a.fresh_operation_id==OLD_OP or not UUID.fullmatch(a.fresh_coordinator_uuid) or a.fresh_coordinator_uuid==OLD_COORD: fail("fresh canonical identity differs")
    root=os.path.realpath(a.fresh_root)
    if root!=STATE+"/deployments/"+a.fresh_operation_id or a.output!=root+"/v4-inactive-terminal-to-fresh-v21.json": fail("canonical fresh root/output differs")
    rs=os.stat(root)
    if os.path.islink(root) or rs.st_uid!=os.geteuid() or stat.S_IMODE(rs.st_mode)!=0o700: fail("fresh root differs")
    names=("terminal","recovery_approval","authorization","abort_receipt","abort_query","vfdqa","linux_v13_started","windows_v13_started","authenticated_v13_peer","transition","deployment_publish","marker_handoff","linux_frozen")
    v={n:load(getattr(a,n),getattr(a,n+"_sha256"),n) for n in names}
    t=v["terminal"];keys(t,TERM,"terminal")
    if not truth(t,schema_version=2,state="viewflow-c9b05e9-schema7-vfdqa-abort-recovery-v2-terminal",operation_id=OLD_OP,manifest_sha256=C9_MANIFEST_SHA,gate_sha256=C9_GATE_SHA,launcher_sha256=C9_LAUNCHER_SHA,approval_sha256=a.recovery_approval_sha256,predecessor_approval_sha256="26b75c5187b843db57a0da262f5ebb0f4aec660ee60c4231fb707c034c6d5cb4",coordinator_redispatched=False,marker_abort_redispatched=False,marker_absent=True,abort_claim_absent=True,release_claim_absent=True): fail("recovery-v2 terminal truth differs")
    au=v["authorization"];keys(au,AUTH,"authorization")
    c9root=STATE+"/deployments/"+OLD_OP
    if not truth(au,schema_version=7,state="viewflow-deployment-quarantine-post-force-pre-linux-stage-rollback-abort-authorized",operation_id=OLD_OP,coordinator_instance_id=OLD_COORD,authorization_receipt_path=c9root+"/failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-authorization.json",marker_generation="1",marker_sha256=C9_MARKER_SHA,coordinator_terminal_state_sha256=C9_STATE_SHA,fresh_operation_lineage_receipt_sha256=C9_LINEAGE_SHA,force_release_executed=True,rollback_performed=True,linux_stage_committed=False,windows_install_committed=False,windows_installer_exit_present=False,initial_force_release_executed=True,second_force_release_executed=False,rollback_token_consumed=True,mutation_permit_published=True,coordinator_mutation_possible=True,protocol_2_1=False) or t["authorization_sha256"]!=a.authorization_sha256 or any(au[k]!=v for k,v in {**C9_ARTIFACTS,**C9_OLD}.items()): fail("authorization binding differs")
    for n,replayed in (("abort_receipt",False),):
        r=v[n];keys(r,RECEIPT,n)
        if not truth(r,schema_version=7,state="deployment-quarantine-aborted",operation_id=OLD_OP,coordinator_instance_id=OLD_COORD,abort_authorization_path=au["authorization_receipt_path"],abort_authorization_sha256=a.authorization_sha256,authorization_state=au["state"],marker_generation="1",aborted_marker_sha256=C9_MARKER_SHA,marker_path=STATE+"/deployment-quarantine.v1",abort_claim_path=STATE+"/deployment-quarantine.v1.abort-claim",source_display_id="00000000-0000-0000-0000-000000000101",target_device_id="00000000-0000-0000-0000-000000000002",protocol_version="1.3",deployment_release_claimed=False,replayed=replayed,force_release_executed=True,rollback_performed=True,linux_stage_committed=False,windows_install_committed=False,windows_installer_exit_present=False,initial_force_release_executed=True,second_force_release_executed=False,rollback_token_consumed=True,mutation_permit_published=True,coordinator_mutation_possible=True,protocol_2_1=False) or any(r[k]!=au[k] for k in (AUTH & RECEIPT)-{"state","schema_version","authorization_receipt_path"}): fail(n+" truth differs")
        if not (isinstance(r["marker_created_at_unix_ms"],str) and r["marker_created_at_unix_ms"].isdigit() and int(r["marker_created_at_unix_ms"])>0 and isinstance(r["abort_committed_at_unix_ms"],str) and r["abort_committed_at_unix_ms"].isdigit() and int(r["abort_committed_at_unix_ms"])>=int(r["marker_created_at_unix_ms"]) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z",r["abort_committed_at_utc"]) and r["abort_point"]=="abort-claim-atomic-retire-and-parent-directory-fsync" and r["abort_receipt_path"]==STATE+"/.deployment-quarantine.v1.abort-receipt."+C9_MARKER_SHA+"."+a.authorization_sha256+".v1"): fail(n+" timestamp/path differs")
    q=v["abort_query"];keys(q,RECOVERY_QUERY,"recovery-v2 query")
    if not truth(q,schema_version=2,state="viewflow-c9b05e9-schema7-abort-recovery-v2-query-committed",operation_id=OLD_OP,coordinator_redispatched=False,marker_abort_redispatched=False,query_source="sealed-marker-cli-query",predecessor_approval_sha256=t["predecessor_approval_sha256"],authorization_sha256=a.authorization_sha256,abort_receipt_sha256=a.abort_receipt_sha256,durable_vfdqa_sha256=a.vfdqa_sha256) or sha(json.dumps(q["marker_query"],separators=(",",":"),sort_keys=True).encode()+b"\n")!=q["marker_query_sha256"]: fail("recovery-v2 query differs")
    keys(q["marker_query"],RECEIPT,"recovery-v2 marker query")
    if not truth(q["marker_query"],schema_version=7,state="deployment-quarantine-aborted",operation_id=OLD_OP,replayed=True,abort_authorization_sha256=a.authorization_sha256): fail("recovery-v2 embedded query differs")
    if t["abort_receipt_sha256"]!=a.abort_receipt_sha256 or t["query_sha256"]!=a.abort_query_sha256: fail("recovery-v2 terminal query binding differs")
    vp=v["vfdqa"]; embedded=vp[16:272]
    if not(len(vp)==384 and vp[:8]==b"VFDQA001" and vp[8:16]==bytes.fromhex("0101010301000000") and sha(vp[:352])==vp[352:].hex() and vp[304:336].hex()==a.authorization_sha256 and vp[344:352]==b"\0"*8 and sha(embedded)==C9_MARKER_SHA and vp[272:304]==hashlib.sha256(embedded).digest() and embedded[:13]==b"VFDQT001\x01\x01\x02\x01\x01" and embedded[13]==32 and embedded[14:16]==b"\0\0" and embedded[16:48]==OLD_OP.encode() and not any(embedded[48:144]) and embedded[144:160]==uuid.UUID("00000000-0000-0000-0000-000000000101").bytes and embedded[160:176]==uuid.UUID("00000000-0000-0000-0000-000000000002").bytes and embedded[176:192]==uuid.UUID(OLD_COORD).bytes and int.from_bytes(embedded[192:200],"little")>0 and int.from_bytes(embedded[200:208],"little")==1 and not any(embedded[208:]) and t["durable_vfdqa_sha256"]==a.vfdqa_sha256): fail("VFDQA binding differs")
    outputs={"linux_v13_started":a.linux_v13_started_sha256,"windows_v13_started":a.windows_v13_started_sha256,"authenticated_v13_peer":a.authenticated_v13_peer_sha256,"transition":a.transition_sha256}
    if any(au[field] != outputs[name] for field,name in {"linux_v13_started_receipt_sha256":"linux_v13_started","windows_v13_started_receipt_sha256":"windows_v13_started","authenticated_v13_peer_receipt_sha256":"authenticated_v13_peer"}.items()): fail("authorization persistent proof closure differs")
    approval=v["recovery_approval"];keys(approval,RECOVERY_APPROVAL,"recovery-v2 approval")
    if not truth(approval,schema_version=2,state="viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved",approved=True,operation_id=OLD_OP,manifest_sha256=C9_MANIFEST_SHA,gate_sha256=C9_GATE_SHA,launcher_sha256=C9_LAUNCHER_SHA,predecessor_approval_sha256=t["predecessor_approval_sha256"],coordinator_dispatch_forbidden=True,abort_redispatch_forbidden=True,only_pinned_marker_query=True,authorization_sha256=a.authorization_sha256,abort_receipt_sha256=a.abort_receipt_sha256,durable_vfdqa_sha256=a.vfdqa_sha256,linux_v13_started_sha256=a.linux_v13_started_sha256,windows_v13_started_sha256=a.windows_v13_started_sha256,authenticated_v13_peer_sha256=a.authenticated_v13_peer_sha256,transition_sha256=a.transition_sha256,retired_claim_sha256=C9_MARKER_SHA,publication_method="create-once-no-replace-and-parent-fsync") or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z",approval["approved_at_utc"]): fail("recovery-v2 approval differs")
    if not truth(t,authorization_sha256=a.authorization_sha256,durable_vfdqa_sha256=a.vfdqa_sha256,linux_v13_started_sha256=a.linux_v13_started_sha256,windows_v13_started_sha256=a.windows_v13_started_sha256,authenticated_v13_peer_sha256=a.authenticated_v13_peer_sha256,transition_sha256=a.transition_sha256,retired_claim_sha256=C9_MARKER_SHA): fail("recovery-v2 terminal bindings differ")
    for n,s in (("linux_v13_started","viewflow-v13-linux-started-frozen"),("windows_v13_started","viewflow-v13-windows-started-frozen"),("authenticated_v13_peer","viewflow-v13-authenticated-peer-validated")):
        if not truth(v[n],schema_version=1,state=s,operation_id=OLD_OP): fail(n+" differs")
    if not truth(v["transition"],schema_version=1,operation_id=OLD_OP,protocol_2_1=False,normal_deployment_release=False,old_coordinator_terminal_state_sha256=C9_STATE_SHA,deployment_marker_sha256=C9_MARKER_SHA): fail("transition differs")
    p,h,f=v["deployment_publish"],v["marker_handoff"],v["linux_frozen"]
    keys(p,"schema_version state protocol_version operation_id source_display_id target_device_id coordinator_instance_id marker_generation marker_path marker_sha256 created_at_unix_ms created_at_utc".split(),"fresh publish")
    if not truth(p,schema_version=1,state="deployment-quarantine-published",operation_id=a.fresh_operation_id,source_display_id="00000000-0000-0000-0000-000000000101",target_device_id="00000000-0000-0000-0000-000000000002",coordinator_instance_id=a.fresh_coordinator_uuid,protocol_version="2.1",marker_generation="1",marker_path=STATE+"/deployment-quarantine.v1") or not HEX.fullmatch(p["marker_sha256"]) or not(isinstance(p["created_at_unix_ms"],str) and p["created_at_unix_ms"].isdigit() and int(p["created_at_unix_ms"])>0 and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z",p["created_at_utc"])): fail("fresh publish differs")
    validate_fresh_marker(p,a)
    keys(h,"schema_version state protocol_version operation_id source_display_id target_device_id coordinator_instance_id marker_generation marker_cli_path marker_cli_sha256 deployment_marker_path deployment_marker_sha256 deployment_publish_receipt_path deployment_publish_receipt_sha256 deskflow_unit deskflow_unit_active_state deskflow_unit_main_pid deskflow_executable_path deskflow_executable_sha256 deskflow_exact_process_count deskflow_core_executable_path deskflow_core_executable_sha256 deskflow_core_exact_process_count deskflow_tcp_port deskflow_tcp_listener_count runtime_marker_path runtime_marker_present observed_at_utc".split(),"fresh handoff")
    if not truth(h,schema_version=1,state="viewflow-v13-marker-handoff-prepared",operation_id=a.fresh_operation_id,source_display_id=p["source_display_id"],target_device_id=p["target_device_id"],coordinator_instance_id=a.fresh_coordinator_uuid,protocol_version="2.1",marker_generation="1",deployment_marker_path=p["marker_path"],deployment_marker_sha256=p["marker_sha256"],deployment_publish_receipt_path=a.deployment_publish,deployment_publish_receipt_sha256=a.deployment_publish_sha256,deskflow_unit="deskflow.service",deskflow_unit_active_state="inactive",deskflow_unit_main_pid=0,deskflow_exact_process_count=0,deskflow_core_exact_process_count=0,deskflow_tcp_port=24800,deskflow_tcp_listener_count=0,runtime_marker_path=STATE+"/deskflow-quarantine.v2",runtime_marker_present=False) or not all(HEX.fullmatch(h[k]) for k in ("marker_cli_sha256","deskflow_executable_sha256","deskflow_core_executable_sha256")) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.]000Z",h["observed_at_utc"]): fail("fresh handoff differs")
    keys(f,["schema_version","state","operation_id","daemon","journal","pre_stop","post_stop","completed_at_unix_ms"],"fresh frozen")
    if not truth(f,schema_version=1,state="viewflow-v13-bootstrap-frozen",operation_id=a.fresh_operation_id) or not isinstance(f["daemon"],dict) or not isinstance(f["journal"],dict) or not truth(f["pre_stop"],deskflow_unit_active_state="inactive",deskflow_main_pid=0,deskflow_exact_process_count=0,deskflow_core_exact_process_count=0,deskflow_tcp_24800_listener_count=0) or not truth(f["post_stop"],exact_process_count=0,udp_44119_listener_count=0,sidecar_socket_present=False,original_daemon_pid_present=False) or not isinstance(f["completed_at_unix_ms"],int) or f["completed_at_unix_ms"]<=0: fail("fresh frozen differs")
    out={"schema_version":1,"state":"viewflow-v4-inactive-terminal-to-fresh-v21","old_operation_id":OLD_OP,"new_operation_id":a.fresh_operation_id,"new_coordinator_instance_id":a.fresh_coordinator_uuid,"marker_generation":"1","inactive_source":{"source_validation_sha256":a.terminal_sha256,"terminal_sha256":a.terminal_sha256,"authorization_sha256":a.authorization_sha256,"abort_receipt_sha256":a.abort_receipt_sha256,"abort_query_receipt_sha256":a.abort_query_sha256,"vfdqa_sha256":a.vfdqa_sha256,"linux_initially_inactive":True,"windows_old_peer_unchanged":True},"persistent_v13":{"persistent_started_sha256":a.linux_v13_started_sha256,"authenticated_probe_record_sha256":a.authenticated_v13_peer_sha256,"stopped_by_collector":True},"fresh_boundary":{"deployment_publish_sha256":a.deployment_publish_sha256,"marker_handoff_sha256":a.marker_handoff_sha256,"linux_frozen_sha256":a.linux_frozen_sha256,"deployment_marker_sha256":p.get("marker_sha256"),"protocol_version":"2.1"}}
    raw=(json.dumps(out,separators=(",",":"),sort_keys=False)+"\n").encode()
    # Re-open the named marker immediately before publication: P/H JSON cannot
    # be used to bridge a replaced marker after the initial validation.
    if a.publish_final:
        validate_fresh_marker(p,a)
        publish(a.output,raw)
    print("c9 schema7 terminal-to-fresh boundary validated"+(" and published" if a.publish_final else ""))
if __name__=="__main__":
    try: main()
    except (Fail,OSError,ValueError,KeyError) as e: print("error: c9 schema7 bridge: "+str(e),file=sys.stderr);sys.exit(1)
