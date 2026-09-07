#!/usr/bin/env python3
"""Pure filesystem contract tests; never invoke the lifecycle execute path."""
import contextlib, hashlib, importlib.util, io, json, os, stat, tempfile
from pathlib import Path
from types import SimpleNamespace

source=Path(__file__).resolve().parents[1]/"c9-recovery-v2-fresh-boundary.py"
spec=importlib.util.spec_from_file_location("life",source); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def put(root,name,data,mode):
    p=root/name; p.write_bytes(data); os.chmod(p,mode); return p
def h(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix="viewflow-c9-lifecycle.") as td:
    root=Path(td); bridge=root/"bridge";fresh=root/"fresh";bridge.mkdir(0o700);fresh.mkdir(0o700)
    m.ROOT=bridge;m.FRESH=fresh
    q=put(root,"query.json",b'{}\n',0o600)
    terminal={"schema_version":2,"state":"viewflow-c9b05e9-schema7-vfdqa-abort-recovery-v2-terminal","operation_id":m.OLD,"manifest_sha256":"a"*64,"gate_sha256":"b"*64,"launcher_sha256":"c"*64,"approval_sha256":"d"*64,"predecessor_approval_sha256":"e"*64,"authorization_sha256":"f"*64,"abort_receipt_sha256":"1"*64,"transition_sha256":"2"*64,"linux_v13_started_sha256":"3"*64,"windows_v13_started_sha256":"4"*64,"authenticated_v13_peer_sha256":"5"*64,"durable_vfdqa_sha256":"6"*64,"retired_claim_sha256":"7"*64,"query_sha256":h(q),"coordinator_redispatched":False,"marker_abort_redispatched":False,"marker_absent":True,"abort_claim_absent":True,"release_claim_absent":True}
    t=put(root,"terminal.json",m.canonical(terminal),0o600)
    files={"recovery_terminal":t,"recovery_query":q}
    for n in ("recovery_approval","authorization","abort_receipt","abort_query","vfdqa","windows_v13_started","authenticated_v13_peer"):
        files[n]=put(root,n+(".bin" if n=="vfdqa" else ".json"),b'{}\n' if n!="vfdqa" else b'vfdqa',0o600)
    transient={"control_group":"/user.slice/viewflow-v13-recovery-"+m.OLD+".service","deployment_marker_sha256":"a"*64,"exec_start_sha256":"b"*64,"expected_exec_start_sha256":"b"*64,"fd_gate_payload_sha256":"c"*64,"invocation_id":"d"*32,"kill_mode":"control-group","main_pid":1,"operation_id":m.OLD,"protocol_version":"1.3","schema_version":1,"start_ticks":1,"state":"viewflow-linux-v1.3-started-under-deployment-quarantine","transient":True,"unit":"viewflow-v13-recovery-"+m.OLD+".service","unit_active_state":"active","viewflowd_sha256":"0"*64}
    files["linux_v13_started"]=put(root,"linux.json",m.canonical(transient),0o600)
    for n in ("marker_candidate","prepare_script","collector_script","final_bridge","viewflow","deskflow","deskflow_core"):
        files[n]=put(root,n,b'#!/bin/true\n',0o755)
    marker_link=root/"marker-candidate-provenance-link"; os.link(files["marker_candidate"],marker_link)
    m.FINAL_BRIDGE=str(files["final_bridge"]);m.FINAL_BRIDGE_SHA=h(files["final_bridge"])
    files["viewflow_unit"]=put(root,"viewflow.service",b'[Service]\n',0o644)
    transient["viewflowd_sha256"]=h(files["viewflow"]);put(root,"linux.json",m.canonical(transient),0o600)
    transition={"abort_authorization_sha256":h(files["authorization"]),"authenticated_v13_peer_receipt_sha256":h(files["authenticated_v13_peer"]),"bubblewrap_sha256":"8"*64,"deployment_abort_receipt_sha256":h(files["abort_receipt"]),"deployment_marker_sha256":"9"*64,"fd_gate_payload_sha256":"d"*64,"linux_deskflow_control_group":"/user.slice/deskflow-v13-recovery-"+m.OLD+".service","linux_deskflow_core_executable_sha256":h(files["deskflow_core"]),"linux_deskflow_core_pid":3,"linux_deskflow_core_runtime_path":"/tmp/viewflow-deskflow-recovery/deskflow-core","linux_deskflow_core_start_ticks":3,"linux_deskflow_exec_start_sha256":"b"*64,"linux_deskflow_executable_sha256":h(files["deskflow"]),"linux_deskflow_expected_exec_start_sha256":"b"*64,"linux_deskflow_invocation_id":"c"*32,"linux_deskflow_main_pid":1,"linux_deskflow_main_start_ticks":1,"linux_deskflow_runtime_path":"/tmp/viewflow-deskflow-recovery/deskflow","linux_deskflow_runtime_pid":2,"linux_deskflow_runtime_start_ticks":2,"linux_deskflow_unit":"deskflow-v13-recovery-"+m.OLD+".service","linux_deskflow_unit_state":"active","linux_v13_started_receipt_sha256":h(files["linux_v13_started"]),"linux_viewflow_unit_state":"active","normal_deployment_release":False,"old_coordinator_terminal_state_sha256":"066ef1bfa69aa09989204245c16d15c19eb66003a8a715f553c70b76976d7e8f","operation_id":m.OLD,"protocol_2_1":False,"protocol_version":"1.3","schema_version":1,"sealed_sibling_directory_read_only":True,"state":"viewflow-failed-v1.3-bootstrap-abort-terminal","windows_v13_started_receipt_sha256":h(files["windows_v13_started"])}
    files["transition"]=put(root,"transition.json",m.canonical(transition),0o600)
    qdoc={"abort_receipt_sha256":h(files["abort_receipt"]),"authorization_sha256":h(files["authorization"]),"coordinator_redispatched":False,"durable_vfdqa_sha256":h(files["vfdqa"]),"marker_abort_redispatched":False,"marker_query":{"fixture":True},"marker_query_sha256":h(put(root,"marker-query.json",m.canonical({"fixture":True}),0o600)),"operation_id":m.OLD,"predecessor_approval_sha256":"a"*64,"query_source":"sealed-marker-cli-query","schema_version":2,"state":"viewflow-c9b05e9-schema7-abort-recovery-v2-query-committed"}
    q=put(root,"query.json",m.canonical(qdoc),0o600);files["recovery_query"]=q;files["abort_query"]=q
    approval={"abort_receipt_sha256":h(files["abort_receipt"]),"abort_redispatch_forbidden":True,"approved":True,"approved_at_utc":"2026-09-04T00:00:00.000Z","authenticated_v13_peer_sha256":h(files["authenticated_v13_peer"]),"authorization_sha256":h(files["authorization"]),"coordinator_dispatch_forbidden":True,"durable_vfdqa_sha256":h(files["vfdqa"]),"gate_sha256":"a"*64,"launcher_sha256":"b"*64,"linux_v13_started_sha256":h(files["linux_v13_started"]),"manifest_sha256":"c"*64,"only_pinned_marker_query":True,"operation_id":m.OLD,"predecessor_approval_sha256":"d"*64,"publication_method":"create-once-no-replace-and-parent-fsync","retired_claim_sha256":"e"*64,"schema_version":2,"state":"viewflow-c9b05e9-schema7-abort-recovery-v2-execution-approved","transition_sha256":h(files["transition"]),"windows_v13_started_sha256":h(files["windows_v13_started"])}
    files["recovery_approval"]=put(root,"recovery_approval.json",m.canonical(approval),0o600)
    # Align the terminal's pins to the fixture source bytes.
    for field,name in (("authorization_sha256","authorization"),("abort_receipt_sha256","abort_receipt"),("durable_vfdqa_sha256","vfdqa"),("transition_sha256","transition"),("linux_v13_started_sha256","linux_v13_started"),("windows_v13_started_sha256","windows_v13_started"),("authenticated_v13_peer_sha256","authenticated_v13_peer")):
        terminal[field]=h(files[name])
    terminal["approval_sha256"]=h(files["recovery_approval"]);terminal["query_sha256"]=h(q);put(root,"terminal.json",m.canonical(terminal),0o600)
    files["recovery_terminal"]=root/"terminal.json"
    # The new lifecycle cannot prepare without the sealed failed-successor
    # closure.  This generic plan fixture pins a strict owner-only source;
    # the closure's full immutable-old-root schema is exercised separately.
    files["failed_closure"]=put(root,"failed-successor-closure.json",m.canonical({"fixture":"failed-closure"}),0o600)
    old_failed_closure=m.FAILED_CLOSURE; m.FAILED_CLOSURE=files["failed_closure"]
    a=SimpleNamespace(manifest=str(bridge/"manifest.json"),recovery_terminal=str(files["recovery_terminal"]),recovery_terminal_sha256=h(files["recovery_terminal"]),recovery_query=str(q),recovery_query_sha256=h(q),**{n:str(p) for n,p in files.items() if n not in ("recovery_terminal","recovery_query")},**{n+"_sha256":h(p) for n,p in files.items() if n not in ("recovery_terminal","recovery_query")})
    closure_calls=[]; old_validate_closure=m.validate_failed_closure
    try:
        m.validate_failed_closure=lambda v,sha: closure_calls.append((v,sha))
        plan=m.plan_from_args(a)
        assert plan["sources"]["failed_closure"]==m.spec(str(files["failed_closure"]),h(files["failed_closure"]),0o600)
        m.validate_plan(plan,"9"*64)
        assert transient["fd_gate_payload_sha256"]!=transition["fd_gate_payload_sha256"], "cross-role fd gates unexpectedly share a fixture value"
        for doc,validator in ((dict(transient),m.validate_linux_started),(dict(transition),m.validate_transition)):
            doc["fd_gate_payload_sha256"]="not-a-sha256"
            try: validator(doc,plan["sources"])
            except m.Error: pass
            else: raise AssertionError("invalid role-specific fd-gate payload SHA accepted")
        assert closure_calls==[( {"fixture":"failed-closure"},h(files["failed_closure"])),({"fixture":"failed-closure"},h(files["failed_closure"]))], closure_calls
    finally:
        m.validate_failed_closure=old_validate_closure
    os.unlink(marker_link)
    try: m.validate_plan(plan,"9"*64); raise AssertionError("single-link marker candidate accepted")
    except m.Error: pass
    os.link(files["marker_candidate"],marker_link)
    bad=dict(plan); bad["new_operation_id"]="0"*32
    try: m.validate_plan(bad,"9"*64); raise AssertionError("identity mutation accepted")
    except m.Error: pass
    Path(files["viewflow"]).write_bytes(b'changed')
    try: m.validate_plan(plan,"9"*64); raise AssertionError("source mutation accepted")
    except m.Error: pass

    # Legacy proof accepts either an untouched local session or fully paired
    # sidecar return cycles.  An activation/leave without the final local
    # return is deliberately a terminal uncertainty.
    log=root/"deskflow.log"; anchor="IPC: started server, waiting for clients\n"
    log.write_text(anchor,encoding="utf-8"); os.chmod(log,0o600)
    assert m.stable_deskflow_log_slice(str(log))["legacy_route_outcome"]=="never-left-local"
    log.write_text(anchor+'INFO: Viewflow sidecar active for Deskflow screen "WindowsVM"\nINFO: switch from "SuperPower" to "WindowsVM"\nINFO: leaving screen\nINFO: switch from "WindowsVM" to "SuperPower"\nINFO: entering screen\n',encoding="utf-8")
    assert m.stable_deskflow_log_slice(str(log))["legacy_route_outcome"]=="returned-local"
    log.write_text(anchor+'INFO: Viewflow sidecar active for Deskflow screen "WindowsVM"\nINFO: switch from "SuperPower" to "WindowsVM"\nINFO: leaving screen\n',encoding="utf-8")
    try: m.stable_deskflow_log_slice(str(log)); raise AssertionError("unreturned legacy route accepted")
    except m.Error: pass

    # --prepare is a plan publication boundary only.  Exercise its control
    # path with every mutating runtime primitive replaced by a hard failure.
    # This protects the promise that prepare cannot stop/start a unit, query a
    # sidecar, or publish/erase a marker.
    events=[]; old_parser=m.parser; old_require=m.require_dir; old_create=m.create_once; old_plan=m.plan_from_args; old_cmd=m.cmd
    try:
        m.STATE=root/"state"; m.ROOT=bridge; m.FRESH=root/"prepare-fresh"
        m.parser=lambda: SimpleNamespace(prepare=True,check_failed_attempt=False,close_failed_attempt=False,manifest=str(bridge/"manifest.json"))
        m.require_dir=lambda path,label,missing=False: events.append(("dir",str(path),label,missing))
        m.plan_from_args=lambda _: {"fixture":"plan"}
        m.create_once=lambda path,raw: events.append(("create",str(path),raw))
        m.cmd=lambda *_args,**_kwargs: (_ for _ in ()).throw(AssertionError("prepare invoked a runtime command"))
        with contextlib.redirect_stdout(io.StringIO()): m.main()
        assert [x[0] for x in events].count("create")==1 and events[-1][1]==str(bridge/"manifest.json"), events
        assert not any(x[0] in ("stop","start","marker") for x in events), events
    finally:
        m.parser=old_parser; m.require_dir=old_require; m.create_once=old_create; m.plan_from_args=old_plan; m.cmd=old_cmd
    m.FAILED_CLOSURE=old_failed_closure
print("c9 recovery-v2 fresh-boundary hermetic tests passed")
