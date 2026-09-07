#!/usr/bin/env python3
"""Offline schema and no-control checks for the sealed failed-successor path."""
from __future__ import annotations
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

SOURCE=Path(sys.argv[1]).resolve() if len(sys.argv)==2 else Path(__file__).parents[1]/"c9-recovery-v2-fresh-boundary.py"
spec=importlib.util.spec_from_file_location("c9_failed_closure",SOURCE)
assert spec and spec.loader
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# The transient is deliberately an exact memfd process, distinct from
# installed-path persistent Viewflow.  Its final exec argv is the old v1.3
# server argv; the fd gate belongs to the systemd ExecStart record instead.
expected_argv=(
    b"/home/wilf/.local/lib/viewflow/viewflowd", b"serve", b"--bind", b"0.0.0.0:44119",
    b"--cert", b"/home/wilf/.local/share/viewflow/identity/peer.pem",
    b"--key", b"/home/wilf/.local/share/viewflow/identity/peer.key",
    b"--ca", b"/home/wilf/.local/share/viewflow/identity/ca.pem",
    b"--device-id", b"00000000000000000000000000000001",
    b"--sidecar-socket", b"/run/user/1000/viewflow/deskflow.sock",
    b"--sidecar-peer", b"172.16.105.70",
    b"--sidecar-target-device", b"00000000000000000000000000000002",
)
assert m.EXPECTED_VIEWFLOW_V13_ARGV==expected_argv
argv=list(expected_argv)
assert m.transient_viewflow_argv(argv)==__import__("hashlib").sha256(b"\0".join(argv)+b"\0").hexdigest()
for argv in (argv[:-1],argv+[b"--fd-gate"],argv[:1]+[b"viewflowd"]+argv[1:]):
    try: m.transient_viewflow_argv(argv)
    except m.Error: pass
    else: raise AssertionError("transient final v1.3 argv mismatch accepted")

# Reproduce the handoff's busctl/jq canonicalization without consulting a live
# bus.  The receipt-bound fd gate is accepted only through this ExecStart hash.
unit="viewflow-v13-recovery-"+m.OLD+".service"
exec_value=["/launcher",["/launcher","--fd-gate","a"*64],False,0,0,0,0,0,0,0]
expected_exec=__import__("hashlib").sha256(m.json.dumps({"argv":exec_value[1],"ignore_errors":False,"path":"/launcher"},sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
calls=[]; old_cmd=m.cmd
try:
    def fake_cmd(command,*_args,**_kwargs):
        calls.append(command)
        if "GetUnit" in command: return m.json.dumps({"type":"o","data":["/org/freedesktop/systemd1/unit/test"]})+"\n"
        return m.json.dumps({"type":"a(sasbttttuii)","data":[exec_value]})+"\n"
    m.cmd=fake_cmd
    assert m.observed_exec_start_sha256(unit)==expected_exec
    assert m.transient_viewflow_exec_start({"unit":unit,"exec_start_sha256":expected_exec,"expected_exec_start_sha256":expected_exec})==expected_exec
    desk_transition={"linux_deskflow_unit":"deskflow-v13-recovery-"+m.OLD+".service","linux_deskflow_exec_start_sha256":expected_exec,"linux_deskflow_expected_exec_start_sha256":expected_exec}
    assert m.transient_deskflow_exec_start(desk_transition)==expected_exec
    for changed in ({"type":"o","data":[]},{"type":"a(sasbttttuii)","data":[exec_value[:-1]]}):
        m.cmd=lambda *_args,changed=changed,**_kwargs: m.json.dumps(changed)+"\n"
        try: m.observed_exec_start_sha256(unit)
        except m.Error: pass
        else: raise AssertionError("malformed systemd D-Bus response accepted")
    m.cmd=fake_cmd
    try: m.transient_viewflow_exec_start({"unit":unit,"exec_start_sha256":"0"*64,"expected_exec_start_sha256":expected_exec})
    except m.Error: pass
    else: raise AssertionError("mismatched receipt ExecStart SHA accepted")
    try: m.transient_deskflow_exec_start({**desk_transition,"linux_deskflow_expected_exec_start_sha256":"0"*64})
    except m.Error: pass
    else: raise AssertionError("mismatched Deskflow receipt ExecStart SHA accepted")
    assert all(command[0]=="/usr/bin/busctl" and "--user" in command for command in calls)
finally:
    m.cmd=old_cmd

# This runs against SOURCE (including a checker candidate): the failed-manifest
# validator must independently stable-read every declared predecessor source.
# A forged/no-op implementation cannot accept a mismatched first source hash.
with tempfile.TemporaryDirectory(prefix="viewflow-c9-failed-manifest-source.") as d:
    root=Path(d)
    sources={}
    for name,mode in m.FAILED_SOURCE_MODES.items():
        p=root/name; p.write_bytes(b"wrong pinned source\n"); os.chmod(p,mode)
        sources[name]=m.spec(str(p),"0"*64,mode)
    manifest={"schema_version":1,"state":"viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-plan","execution_authorized":False,"old_operation_id":m.OLD,"new_operation_id":m.FAILED,"new_coordinator_instance_id":m.FAILED_COORD,"bridge_root":str(m.FAILED_ROOT),"fresh_root":str(m.FAILED_FRESH),"outputs":m.failed_outputs(),"sources":sources}
    try: m.failed_manifest_documents(manifest)
    except m.Error: pass
    else: raise AssertionError("failed manifest accepted mismatched pinned source bytes/hash")

# The old failed manifest's cleanenv marker source is the sole two-link input.
# Exercise the live filesystem metadata shape directly: one link is rejected,
# while the exact provenance-pair nlink=2 shape is accepted.
with tempfile.TemporaryDirectory(prefix="viewflow-c9-failed-marker-links.") as d:
    root=Path(d); marker=root/"marker-candidate"; marker.write_bytes(b"marker\n"); os.chmod(marker,0o755)
    marker_sha=__import__("hashlib").sha256(marker.read_bytes()).hexdigest()
    try: m.stable(str(marker),marker_sha,0o755,"marker_candidate")
    except m.Error: pass
    else: raise AssertionError("one-link failed marker candidate accepted")
    os.link(marker,root/"marker-candidate-provenance")
    assert m.stable(str(marker),marker_sha,0o755,"marker_candidate")==b"marker\n"

# The failed manifest's prepare_script is a P/H helper, not the historical
# lifecycle itself.  A source map with a wrong helper SHA must fail at that
# explicit pin before receipt-document cross-binding begins.
fixture_sources={name:m.spec("/fixture/"+name,"a"*64,mode) for name,mode in m.FAILED_SOURCE_MODES.items()}
fixture_sources["final_bridge"]=m.spec(m.FINAL_BRIDGE,m.FINAL_BRIDGE_SHA,0o755)
fixture_sources["prepare_script"]=m.spec("/fixture/prepare","0"*64,0o755)
fixture_manifest={"schema_version":1,"state":"viewflow-c9-recovery-v2-to-fresh-v21-lifecycle-plan","execution_authorized":False,"old_operation_id":m.OLD,"new_operation_id":m.FAILED,"new_coordinator_instance_id":m.FAILED_COORD,"bridge_root":str(m.FAILED_ROOT),"fresh_root":str(m.FAILED_FRESH),"outputs":m.failed_outputs(),"sources":fixture_sources}
old_stable=m.stable
try:
    m.stable=lambda path,sha,mode,label,json_document=False: {} if json_document else b"fixture"
    try: m.failed_manifest_documents(fixture_manifest)
    except m.Error as e: assert str(e)=="failed successor prepare helper source hash differs"
    else: raise AssertionError("wrong failed prepare helper SHA accepted")
finally:
    m.stable=old_stable

live={
 "viewflow":{"unit":"viewflow-v13-recovery-"+m.OLD+".service","pid":2628788,"start_ticks":6353894,"invocation_id":"b58c1b47e9e44e0db9237dd2054471ed","control_group":"/fixture/viewflow","runtime_executable":"/memfd:viewflow-verified-elf (deleted)","runtime_sha256":"d"*64,"argv_sha256":"e"*64,"exec_start_sha256":"f"*64,"fd_gate_payload_sha256":"f"*64},
 "deskflow":{"unit":"deskflow-v13-recovery-"+m.OLD+".service","main_pid":2641607,"main_start_ticks":6355585,"runtime_pid":2641625,"runtime_start_ticks":6355588,"core_pid":2641700,"core_start_ticks":6355614,"invocation_id":"57ec0e3c566c4c6391e1a4fbbec243dd","control_group":"/fixture/deskflow"},
 "listeners":{"udp_44119":{"count":1,"owner_pid":2628788,"sha256":"a"*64},"tcp_24800":{"count":1,"owner_pid":2641700,"sha256":"b"*64}},
 "sidecar":{"path":"/run/user/1000/viewflow/deskflow.sock","inode":1,"owner_pid":2628788,"listener_count":1},
 "acceptance_sockets":{"deskflow":False,"viewflow":False,"post_release":False},"markers":{"vfqst":False,"vfdqt":False},"persistent_units":{"deskflow":False,"viewflow":False},"systemd_preimage_verified":{"deskflow":True,"recovery_deskflow":True,"viewflow":True},
 "deskflow_log":{"dev":1,"ino":2,"size":3,"mtime_ns":4,"sha256":"c"*64,"startup_anchor_offset":0,"legacy_route_outcome":"returned-local","route_event_sequence":["sidecar-active","switch-to-remote","leaving-local","switch-to-local","entered-local"]},
 "auxiliary_process_absence":{"current_exact_wl_copy_process_count":0,"current_relevant_process_census":{"transient_viewflow_memfd_exact_process_count":1,"deskflow_runtime_exact_process_count":1,"deskflow_core_exact_process_count":1},"historical_auxiliary_process_actions_not_durably_attested":True},
}

# The schema validator normally reopens real immutable leaves.  Stub only that
# final filesystem reopening here so the fixture stays hermetic; all receipt
# identity and binding checks still execute.
old_inputs=m.failed_inputs; old_require=m.require_dir; old_fresh=m.FAILED_FRESH; old_candidate=m.FAILED_CANDIDATE; old_closure=m.FAILED_CLOSURE
with tempfile.TemporaryDirectory(prefix="viewflow-c9-failed-close.") as d:
    root=Path(d); m.FAILED_FRESH=root/"fresh"; m.FAILED_FRESH.mkdir(); m.FAILED_CANDIDATE=root/"candidate"
    fake_docs={"linux_v13_started":{"unit":live["viewflow"]["unit"],"control_group":live["viewflow"]["control_group"],"viewflowd_sha256":live["viewflow"]["runtime_sha256"],"exec_start_sha256":live["viewflow"]["exec_start_sha256"],"fd_gate_payload_sha256":live["viewflow"]["fd_gate_payload_sha256"]},"transition":{"linux_deskflow_unit":live["deskflow"]["unit"],"linux_deskflow_control_group":live["deskflow"]["control_group"]}}
    m.failed_inputs=lambda include: ({}, fake_docs)
    m.require_dir=lambda path,label,missing=False: None
    receipt=m.failed_closure(live)
    m.validate_failed_closure(receipt,"c"*64)
    for mutate in (
        lambda x: x.__setitem__("error","other"),
        lambda x: x["live"]["viewflow"].__setitem__("pid",1),
        lambda x: x["live"]["viewflow"].__setitem__("runtime_executable","/tmp/viewflowd"),
        lambda x: x["live"]["viewflow"].__setitem__("exec_start_sha256","0"*64),
        lambda x: x["live"]["listeners"]["tcp_24800"].__setitem__("owner_pid",1),
        lambda x: x["live"].__setitem__("markers",{"vfqst":False,"vfdqt":True}),
        lambda x: x["live"]["auxiliary_process_absence"].__setitem__("current_exact_wl_copy_process_count",1),
    ):
        bad=__import__("copy").deepcopy(receipt); mutate(bad)
        try: m.validate_failed_closure(bad,"c"*64)
        except m.Error: pass
        else: raise AssertionError("closure field mutation accepted")
    # A stale candidate and a nonempty failed fresh root are both hard gates.
    m.failed_inputs=lambda include: ({}, fake_docs)
    m.FAILED_CANDIDATE.mkdir()
    try: m.validate_failed_closure(receipt,"c"*64)
    except m.Error: pass
    else: raise AssertionError("candidate-presence mutation accepted")
    m.FAILED_CANDIDATE.rmdir(); (m.FAILED_FRESH/"unexpected").write_text("x")
    try: m.validate_failed_closure(receipt,"c"*64)
    except m.Error: pass
    else: raise AssertionError("fresh-root mutation accepted")
with tempfile.TemporaryDirectory(prefix="viewflow-c9-failed-noop.") as d:
    m.FAILED_CLOSURE=Path(d)/"failed-successor-closure.json"; m.FAILED_CLOSURE.write_text("already")
    calls=[]; old_inputs2=m.failed_inputs; old_live=m.failed_live; old_create=m.create_once
    m.failed_inputs=lambda include: calls.append("inputs")
    m.failed_live=lambda sources,docs: calls.append("live")
    m.create_once=lambda path,raw: calls.append("create")
    try: m.close_failed_attempt()
    except m.Error: pass
    else: raise AssertionError("existing closure unexpectedly accepted")
    assert calls==[], "existing closure was not a no-op"
    m.failed_inputs=old_inputs2; m.failed_live=old_live; m.create_once=old_create
m.failed_inputs=old_inputs; m.require_dir=old_require; m.FAILED_FRESH=old_fresh; m.FAILED_CANDIDATE=old_candidate; m.FAILED_CLOSURE=old_closure

# `--check-failed-attempt` exercises the close gate but must not create a
# receipt.  Substitute only pure checks and reject any writer call.
with tempfile.TemporaryDirectory(prefix="viewflow-c9-failed-check.") as d:
    root=Path(d); fresh=root/"fresh"; fresh.mkdir(); old_fresh=m.FAILED_FRESH; old_candidate=m.FAILED_CANDIDATE; old_closure=m.FAILED_CLOSURE
    old_inputs=m.failed_inputs; old_live=m.failed_live; old_validate=m.validate_failed_closure; old_require=m.require_dir; old_create=m.create_once
    calls=[]; m.FAILED_FRESH=fresh; m.FAILED_CANDIDATE=root/"absent-candidate"; m.FAILED_CLOSURE=root/"absent-closure"
    m.failed_inputs=lambda include: ({},{}); m.failed_live=lambda sources,docs: live; m.validate_failed_closure=lambda receipt,sha,include_closure=True: calls.append((sha,include_closure)); m.require_dir=lambda *args,**kwargs: None; m.create_once=lambda *args,**kwargs: (_ for _ in ()).throw(AssertionError("check wrote output"))
    try:
        m.check_failed_attempt()
        assert calls and calls[-1][1] is False
    finally:
        m.FAILED_FRESH=old_fresh; m.FAILED_CANDIDATE=old_candidate; m.FAILED_CLOSURE=old_closure; m.failed_inputs=old_inputs; m.failed_live=old_live; m.validate_failed_closure=old_validate; m.require_dir=old_require; m.create_once=old_create

# A real target-dentry race at the O_TMPFILE publication point must fail
# closed.  Exercise all receipt classes used by this lifecycle: closure,
# approval, and a retirement receipt.  The attacker's target is never removed
# or overwritten, and the later uncontended publication is the exact bytes.
with tempfile.TemporaryDirectory(prefix="viewflow-c9-create-once-race.") as d:
    parent=Path(d); os.chmod(parent,0o700)
    for leaf in ("failed-successor-closure.json","execution-approval.json","retire-viewflow.json"):
        target=parent/leaf; attacker=b"attacker\n"; expected=(leaf+"\n").encode()
        def race(dirfd,name):
            fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC,0o600,dir_fd=dirfd)
            try: os.write(fd,attacker); os.fsync(fd)
            finally: os.close(fd)
        try: m.create_once(target,expected,race)
        except m.Error: pass
        else: raise AssertionError("concurrent output dentry accepted")
        assert target.read_bytes()==attacker, "race cleanup removed/replaced attacker dentry"
        target.unlink()
        m.create_once(target,expected)
        assert target.read_bytes()==expected
        try: m.create_once(target,b"replacement\n")
        except m.Error: pass
        else: raise AssertionError("create-once replacement accepted")
        assert target.read_bytes()==expected

# Closing must compare every effective unit record to its sealed preimage.
# A missing call or any record mismatch is a hard failure, not a historical
# assertion inferred from the successful closure schema.
seen=[]; old_assert=m.assert_systemd_record
preimage={"deskflow":{"record":"desk"},"recovery_deskflow":{"record":"recovery"},"viewflow":{"record":"view"}}
transition={"linux_deskflow_unit":"deskflow-v13-recovery-"+m.OLD+".service"}
try:
    m.assert_systemd_record=lambda unit,record: seen.append((unit,record))
    assert m.assert_failed_systemd_preimage(preimage,transition)=={"deskflow":True,"recovery_deskflow":True,"viewflow":True}
    assert seen==[("deskflow.service",preimage["deskflow"]),(transition["linux_deskflow_unit"],preimage["recovery_deskflow"]),("viewflow-peer.service",preimage["viewflow"])]
    m.assert_systemd_record=lambda unit,record: (_ for _ in ()).throw(m.Error("systemd mask/drop-in preimage changed"))
    try: m.assert_failed_systemd_preimage(preimage,transition)
    except m.Error: pass
    else: raise AssertionError("systemd configuration drift accepted")
finally:
    m.assert_systemd_record=old_assert

text=SOURCE.read_text(encoding="utf-8")
start=text.index("def close_failed_attempt():"); end=text.index("\ndef main():",start)
close=text[start:end]
for forbidden in ("systemctl", "freeze", "stop", "deployment-marker", "--evidence-output", "P/H/F", "unlink", "kill"):
    assert forbidden not in close, "failed closure unexpectedly controls lifecycle: "+forbidden
assert 'm.add_argument("--close-failed-attempt",action="store_true")' in text
assert 'p.add_argument("--failed-closure")' in text
assert 'die("--prepare requires failed-closure")' in text
assert 'validate_failed_closure(stable(a.failed_closure,a.failed_closure_sha256,0o600,"failed_closure",True),a.failed_closure_sha256)' in text
assert 'sources["failed_closure"]=spec(a.failed_closure,a.failed_closure_sha256,0o600)' in text
assert 'assert_failed_systemd_preimage(docs["failed_systemd_preimage"],transition)' in text
assert '"systemd_preimage_verified":systemd_preimage_verified' in text
assert 'os.O_TMPFILE' in text and 'linkat(out,b"",fd,os.fsencode(leaf),AT_EMPTY_PATH)' in text
assert 'm.add_argument("--check-failed-attempt",action="store_true")' in text
check_start=text.index("def check_failed_attempt():"); check_end=text.index("\ndef main():",check_start)
for forbidden in ("create_once", "os.open", "os.unlink", "systemctl", "freeze", "stop"):
    assert forbidden not in text[check_start:check_end], "read-only failed check controls state: "+forbidden
assert 'exe+" (deleted)"' in text and 'path not in (t[pathk],t[pathk]+" (deleted)")' in text
print("c9 failed-successor closure hermetic/negative fixture passed")
