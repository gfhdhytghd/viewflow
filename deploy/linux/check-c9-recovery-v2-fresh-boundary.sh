#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
readonly SOURCE=${1:-"$HERE/c9-recovery-v2-fresh-boundary.py"}
[[ -f $SOURCE && ! -L $SOURCE ]] || { echo 'error: lifecycle source missing' >&2; exit 1; }
python3 -I -m py_compile "$SOURCE"
python3 -I "$HERE/tests/c9-recovery-v2-fresh-boundary-step-recovery-hermetic-test.py"
python3 -I "$HERE/tests/c9-recovery-v2-failed-successor-closure-hermetic-test.py" "$SOURCE"
python3 -I - "$SOURCE" <<'PY'
import ast
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
for token in ('OLD="c9b05e9bea4140d69f9d137a0f992ba0"','NEW="902bd39e80df420394cfa3ece89e2136"','COORD="d3ac8fa1-b623-49c4-9e97-513012a1328d"','FINAL_BRIDGE="/home/wilf/data/viewflow/deploy/linux/bridge-schema7-c9-vfdqa-terminal-to-fresh-v21.py"','FINAL_BRIDGE_SHA="6bec4fcbe41576ff3f159f06734d2f4de8e5e7e6da422369f209d6e2226fbca0"','final bridge path/SHA is not the ABI-reviewed c9 schema7 bridge','lifecycle output paths differ','retire_deskflow','retire_viewflow','retire-step-complete','fresh frozen receipt does not bind persistent receipt','TRANSITION_KEYS','transition Deskflow unit/cgroup differs','docs["abort_query"]!=q','process_executable','TRANSIENT_VIEWFLOW_MEMFD="/memfd:viewflow-verified-elf (deleted)"','EXPECTED_VIEWFLOW_V13_ARGV','transient_viewflow_pids','transient_viewflow_argv','observed_exec_start_sha256','transient_viewflow_exec_start','transient_deskflow_exec_start','transient_viewflow_census','org.freedesktop.systemd1.Service","ExecStart','transient Viewflow receipt hash differs','transient Viewflow fd-gate ExecStart binding differs','transient Deskflow ExecStart binding differs','transient Viewflow memfd census differs','transient Viewflow final v1.3 argv differs','transient Deskflow systemd tuple differs','transient Viewflow PID/start/cgroup tuple differs','frozen_viewflow_network','Viewflow socket ownership/peer state differs','systemctl","--user","freeze"','FreezerState','stable_deskflow_log_slice','legacy_route_outcome','returned-local','core_environment_snapshot','read_fd_to_eof','frozen_core_log_pipes','FIONREAD','Viewflow sidecar active for Deskflow screen','switch from ','viewflow-c9-recovery-v2-legacy-frozen-no-active-route','viewflow-c9-recovery-v2-legacy-frozen-returned-local','acceptance socket appeared before frozen no-route proof','--publish-execution-approval','create_once','os.O_TMPFILE','AT_EMPTY_PATH','linkat(out,b"",fd,os.fsencode(leaf),AT_EMPTY_PATH)','create-once output dentry changed before fsync','os.O_NOFOLLOW','expected_terminal','recovery terminal approval binding differs','viewflow-c9-recovery-v2-transient-retired','viewflow-c9-recovery-v2-persistent-v13-authenticated','viewflow-c9-recovery-v2-systemd-mask-dropin-preimage','assert_systemd_record','--deployment-marker-candidate','--evidence-output','--publish-final','Deskflow boundary is not zero','fresh authenticated Windows peer'):
    if token not in s: raise SystemExit('error: missing lifecycle contract anchor: '+token)
for token in ('--close-failed-attempt','--check-failed-attempt','FAILED="8310669e11154652bd21ed5020440e92"','FAILED_MANIFEST_SHA="7a9fed3c7d44f827c64745b17e7bd95d046a204fbb24170dbf259d08d06404c7"','FAILED_APPROVAL_SHA="ec3a4d98be7a74a7fac9348abb1efc3933370b834198ec9bf32e7b7db5b12ff0"','FAILED_SYSTEMD_PREIMAGE_SHA="72cb21cd4059d53d374be8d82ad80e6718bceeb1fb5d65513f2f5283251157c0"','FAILED_LIFECYCLE_SHA="03a126f2032daf34c60483df8f65e34ee21d8ddef9b5597bea9a89389dbbcf98"','PREPARE_HELPER_SHA="1b2fff138742e2b210f02eb18dc6caffd053fd9015c9a46222bfeb1bf708c88a"','sources["prepare_script"]["sha256"]!=PREPARE_HELPER_SHA','failed-successor-closure.json','deleted-runtime-path-suffix-unhandled','failed successor bridge leaf set differs','failed successor closure boundary changed','current wl-copy process remains present','current_exact_wl_copy_process_count','historical_auxiliary_process_actions_not_durably_attested','failed successor log is not a complete returned-local cycle','label="marker_candidate" if name=="marker_candidate" else "failed_"+name','assert_failed_systemd_preimage','assert_failed_systemd_preimage(docs["failed_systemd_preimage"],transition)','systemd_preimage_verified','assert_systemd_record("deskflow.service",preimage["deskflow"])','assert_systemd_record(transition["linux_deskflow_unit"],preimage["recovery_deskflow"])','assert_systemd_record("viewflow-peer.service",preimage["viewflow"])','check_failed_attempt','failed successor attempt validated; no mutation','validate_failed_closure(strict(raw,"failed successor check receipt"),digest(raw),False)','--prepare requires failed-closure','failed successor closure path is fixed','sources["failed_closure"]=spec(a.failed_closure,a.failed_closure_sha256,0o600)','validate_failed_closure(stable(a.failed_closure,a.failed_closure_sha256,0o600,"failed_closure",True),a.failed_closure_sha256)','validate_failed_closure(docs["failed_closure"],sources["failed_closure"]["sha256"])','"failed_closure":0o600'):
    if token not in s: raise SystemExit('error: missing failed-successor closure anchor: '+token)
for token in ('legacy_no_route_journal_counts','lease_offered','lease_active','transport_confirmed=true','required_links=2 if label=="marker_candidate" else 1','lifecycle_sha256','"lifecycle_sha256":lifecycle_sha256()'):
    if token not in s: raise SystemExit('error: missing parsed journal denylist: '+token)
for forbidden in ('ssh ', 'paramiko', 'requests.', 'curl ', 'wget '):
    if forbidden in s.lower(): raise SystemExit('error: forbidden remote path: '+forbidden)
if s.count('os.O_NOFOLLOW') < 2: raise SystemExit('error: insufficient nofollow input checks')
if 'order=["viewflow","deskflow"] if legacy else ["deskflow","viewflow"]' not in s or 'for index,name in enumerate(iv["order"]): complete_step(name,index)' not in s:
    raise SystemExit('error: per-step legacy/Viewflow-first retirement order is absent')
tree=ast.parse(s)
def function(name):
    matches=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name==name]
    if len(matches)!=1: raise SystemExit('error: expected one function: '+name)
    return matches[0]
def called(node):
    out=[]
    for n in ast.walk(node):
        if isinstance(n,ast.Call):
            if isinstance(n.func,ast.Name): out.append(n.func.id)
            elif isinstance(n.func,ast.Attribute): out.append(n.func.attr)
    return out
failed_inputs=function('failed_inputs')
failed_inputs_calls=called(failed_inputs)
for name in ('failed_root_leaves','failed_manifest_documents','failed_approval','failed_preimage'):
    if name not in failed_inputs_calls: raise SystemExit('error: failed_inputs missing immutable predecessor validation: '+name)
if not any(isinstance(n,ast.Return) and isinstance(n.value,ast.Tuple) and len(n.value.elts)==2 for n in ast.walk(failed_inputs)):
    raise SystemExit('error: failed_inputs does not return validated sources/docs')
failed_manifest=function('failed_manifest_documents')
manifest_calls=called(failed_manifest)
for name in ('stable','expected_terminal','validate_linux_started','validate_transition'):
    if name not in manifest_calls: raise SystemExit('error: failed manifest validator missing source/cross-binding check: '+name)
stable_loops=[n for n in ast.walk(failed_manifest) if isinstance(n,ast.For) and isinstance(n.iter,ast.Call) and isinstance(n.iter.func,ast.Attribute) and n.iter.func.attr=='items' and isinstance(n.iter.func.value,ast.Name) and n.iter.func.value.id=='FAILED_SOURCE_MODES']
if len(stable_loops)!=1 or 'stable' not in called(stable_loops[0]):
    raise SystemExit('error: failed manifest validator lacks per-source stable-read loop')
if not any(isinstance(n,ast.Return) and isinstance(n.value,ast.Tuple) and len(n.value.elts)==2 and all(isinstance(e,ast.Name) and e.id in ('sources','docs') for e in n.value.elts) for n in ast.walk(failed_manifest)):
    raise SystemExit('error: failed manifest validator does not return validated source/docs bindings')
failed_live=function('failed_live')
for name in ('assert_failed_systemd_preimage','deskflow_live','viewflow_live','exact_pids','stable_deskflow_log_slice'):
    if name not in called(failed_live): raise SystemExit('error: failed_live missing current-state validation: '+name)
transient_live=function('viewflow_live')
if 'transient_viewflow_census' not in called(transient_live): raise SystemExit('error: transient Viewflow live check does not use exact memfd census')
argv_gate=function('transient_viewflow_argv')
argv_source=ast.get_source_segment(s,argv_gate)
if 'argv!=list(EXPECTED_VIEWFLOW_V13_ARGV)' not in argv_source or 'digest(b"\\0".join(argv)+b"\\0")' not in argv_source:
    raise SystemExit('error: transient Viewflow final argv exact gate differs')
exec_gate=function('transient_viewflow_exec_start')
exec_source=ast.get_source_segment(s,exec_gate)
if 'observed_exec_start_sha256' not in called(exec_gate) or 'started["exec_start_sha256"]' not in exec_source or 'started["expected_exec_start_sha256"]' not in exec_source:
    raise SystemExit('error: transient Viewflow ExecStart receipt gate differs')
desk_exec_gate=function('transient_deskflow_exec_start')
desk_exec_source=ast.get_source_segment(s,desk_exec_gate)
if 'observed_exec_start_sha256' not in called(desk_exec_gate) or 'transition["linux_deskflow_exec_start_sha256"]' not in desk_exec_source or 'transition["linux_deskflow_expected_exec_start_sha256"]' not in desk_exec_source:
    raise SystemExit('error: transient Deskflow ExecStart receipt gate differs')
census_gate=function('transient_viewflow_census')
if not all(name in called(census_gate) for name in ('process_argv','transient_viewflow_argv','transient_viewflow_exec_start')):
    raise SystemExit('error: transient Viewflow census omits argv or ExecStart gate')
desk_live=function('deskflow_live')
if 'transient_deskflow_exec_start' not in called(desk_live):
    raise SystemExit('error: transient Deskflow live check omits ExecStart gate')
for name in ('validate_plan','failed_manifest_documents'):
    if 'fd_gate_payload_sha256' in ast.get_source_segment(s,function(name)):
        raise SystemExit('error: cross-role fd-gate payload equality was reintroduced: '+name)
transient_zero=function('viewflow_zero')
if 'transient_viewflow_pids' not in called(transient_zero): raise SystemExit('error: Viewflow zero gate misses transient memfd processes')
failed_validate=function('validate_failed_closure')
if 'failed_inputs' not in called(failed_validate): raise SystemExit('error: failed closure validator does not reopen immutable inputs')
failed_check=function('check_failed_attempt')
failed_check_calls=called(failed_check)
if not all(name in failed_check_calls for name in ('failed_inputs','failed_live','failed_closure','validate_failed_closure')):
    raise SystemExit('error: read-only failed check does not exercise close gates')
if 'create_once' in failed_check_calls or any(token in ast.get_source_segment(s,failed_check) for token in ('os.open','os.unlink','systemctl','freeze','stop')):
    raise SystemExit('error: read-only failed check can mutate runtime or output')
publisher=function('create_once')
publisher_source=ast.get_source_segment(s,publisher)
if not all(x in publisher_source for x in ('os.O_TMPFILE','linkat','AT_EMPTY_PATH')):
    raise SystemExit('error: create-once writer lacks FD-pinned no-replace publication')
if 'os.unlink' in publisher_source:
    raise SystemExit('error: create-once writer unlinks a possibly swapped dentry')
complete=next((n for n in ast.walk(tree) if isinstance(n,ast.FunctionDef) and n.name=='complete_step'),None)
if complete is None: raise SystemExit('error: per-step completion function missing')
existing=next((n for n in ast.walk(complete) if isinstance(n,ast.If) and isinstance(n.test,ast.Call) and isinstance(n.test.func,ast.Attribute) and n.test.func.attr=='exists'),None)
if existing is None: raise SystemExit('error: existing step receipt branch missing')
if len(existing.body)<2 or not isinstance(existing.body[-2],ast.Expr) or not isinstance(existing.body[-2].value,ast.Call) or not isinstance(existing.body[-2].value.func,ast.Name) or existing.body[-2].value.func.id!='target_zero' or len(existing.body[-2].value.args)!=1 or not isinstance(existing.body[-2].value.args[0],ast.Name) or existing.body[-2].value.args[0].id!='name' or not isinstance(existing.body[-1],ast.Return):
    raise SystemExit('error: existing step receipt does not revalidate zero before return')
print('c9 recovery-v2 fresh-boundary static contract passed')
PY
