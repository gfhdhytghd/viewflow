#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
readonly SOURCE=$HERE/../c9-recovery-v2-fresh-boundary.py
readonly CHECK=$HERE/../check-c9-recovery-v2-fresh-boundary.sh
root=$(mktemp -d /tmp/viewflow-c9-lifecycle-negative.XXXXXX)
trap 'rm -rf -- "$root"' EXIT
cp -- "$SOURCE" "$root/source.py"; chmod 0700 "$root/source.py"
"$CHECK" "$root/source.py" >/dev/null
for needle in 'expected_terminal' 'FINAL_BRIDGE_SHA' 'TRANSITION_KEYS' 'docs["abort_query"]!=q' 'required_links=2 if label=="marker_candidate" else 1' 'lifecycle_sha256' 'legacy_no_route_journal_counts' 'lease_offered' 'stable_deskflow_log_slice' 'frozen_core_log_pipes' 'create_once' 'os.O_TMPFILE' 'AT_EMPTY_PATH' 'linkat(out,b"",fd,os.fsencode(leaf),AT_EMPTY_PATH)' 'create-once output dentry changed before fsync' 'assert_systemd_record' 'Deskflow boundary is not zero' 'fresh authenticated Windows peer' '--publish-final' '--check-failed-attempt' 'check_failed_attempt' 'validate_failed_closure(strict(raw,"failed successor check receipt"),digest(raw),False)' '--prepare requires failed-closure' 'sources["failed_closure"]=spec(a.failed_closure,a.failed_closure_sha256,0o600)' 'validate_failed_closure(stable(a.failed_closure,a.failed_closure_sha256,0o600,"failed_closure",True),a.failed_closure_sha256)' 'validate_failed_closure(docs["failed_closure"],sources["failed_closure"]["sha256"])' '"failed_closure":0o600' 'TRANSIENT_VIEWFLOW_MEMFD="/memfd:viewflow-verified-elf (deleted)"' 'EXPECTED_VIEWFLOW_V13_ARGV' 'transient_viewflow_pids()' 'transient_viewflow_argv(argv)' 'observed_exec_start_sha256(unit)' 'transient_viewflow_exec_start(started)' 'transient_deskflow_exec_start(transition)' 'transient_viewflow_census(started)' 'if exact_pids(viewflow) or transient_viewflow_pids()' 'current_exact_wl_copy_process_count' 'historical_auxiliary_process_actions_not_durably_attested' 'label="marker_candidate" if name=="marker_candidate" else "failed_"+name' 'PREPARE_HELPER_SHA="1b2fff138742e2b210f02eb18dc6caffd053fd9015c9a46222bfeb1bf708c88a"' 'sources["prepare_script"]["sha256"]!=PREPARE_HELPER_SHA' 'assert_failed_systemd_preimage(docs["failed_systemd_preimage"],transition)' 'assert_systemd_record("deskflow.service",preimage["deskflow"])' 'assert_systemd_record(transition["linux_deskflow_unit"],preimage["recovery_deskflow"])' 'assert_systemd_record("viewflow-peer.service",preimage["viewflow"])' '"systemd_preimage_verified":systemd_preimage_verified' 'failed_root_leaves(include_closure)' 'failed_manifest_documents(manifest)' 'failed_approval(approval_doc)' 'failed_preimage(preimage)'; do
    candidate=$root/$(printf '%s' "$needle" | sha256sum | awk '{print $1}').py
    python3 -I - "$SOURCE" "$candidate" "$needle" <<'PY'
from pathlib import Path
import sys
source,candidate,needle=sys.argv[1:]
raw=Path(source).read_text(encoding="utf-8")
if needle not in raw: raise SystemExit("negative needle missing")
Path(candidate).write_text(raw.replace(needle,"MUTATED_ANCHOR"),encoding="utf-8")
PY
    chmod 0700 "$candidate"
    if "$CHECK" "$candidate" >/dev/null 2>&1; then echo "mutation accepted: $needle" >&2; exit 1; fi
done
order_candidate=$root/legacy-stop-order.py
python3 -I - "$SOURCE" "$order_candidate" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding="utf-8")
needle='order=["viewflow","deskflow"] if legacy else ["deskflow","viewflow"]'
if needle not in src: raise SystemExit("legacy order missing")
Path(sys.argv[2]).write_text(src.replace(needle,'order=["deskflow","viewflow"]'),encoding="utf-8")
PY
chmod 0700 "$order_candidate"
if "$CHECK" "$order_candidate" >/dev/null 2>&1; then echo 'mutation accepted: legacy stop order' >&2; exit 1; fi
zero_candidate=$root/existing-step-zero.py
python3 -I - "$SOURCE" "$zero_candidate" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding="utf-8")
needle='target_zero(name); return'
if src.count(needle)!=1: raise SystemExit("existing receipt zero anchor differs")
Path(sys.argv[2]).write_text(src.replace(needle,'return'),encoding="utf-8")
PY
chmod 0700 "$zero_candidate"
if "$CHECK" "$zero_candidate" >/dev/null 2>&1; then echo 'mutation accepted: existing step receipt skips zero revalidation' >&2; exit 1; fi
conditional_zero_candidate=$root/existing-step-conditional-zero.py
python3 -I - "$SOURCE" "$conditional_zero_candidate" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding="utf-8")
needle='target_zero(name); return'
if src.count(needle)!=1: raise SystemExit("existing receipt zero anchor differs")
Path(sys.argv[2]).write_text(src.replace(needle,'if False: target_zero(name)\n                return'),encoding="utf-8")
PY
chmod 0700 "$conditional_zero_candidate"
if "$CHECK" "$conditional_zero_candidate" >/dev/null 2>&1; then echo 'mutation accepted: conditional existing step zero revalidation' >&2; exit 1; fi
no_op_candidate=$root/failed-inputs-noop.py
python3 -I - "$SOURCE" "$no_op_candidate" <<'PY'
import ast
from pathlib import Path
import sys
source,candidate=sys.argv[1:]
raw=Path(source).read_text(encoding="utf-8")
tree=ast.parse(raw)
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="failed_inputs")
next_fn=tree.body[tree.body.index(fn)+1]
start=fn.lineno-1; end=next_fn.lineno-1
lines=raw.splitlines(keepends=True)
replacement='def failed_inputs(include_closure=False):\n    # failed_root_leaves failed_manifest_documents failed_approval failed_preimage\n    return {}, {}\n\n'
Path(candidate).write_text(''.join(lines[:start])+replacement+''.join(lines[end:]),encoding="utf-8")
PY
chmod 0700 "$no_op_candidate"
if "$CHECK" "$no_op_candidate" >/dev/null 2>&1; then echo 'mutation accepted: failed_inputs no-op body' >&2; exit 1; fi
manifest_no_op_candidate=$root/failed-manifest-noop.py
python3 -I - "$SOURCE" "$manifest_no_op_candidate" <<'PY'
import ast
from pathlib import Path
import sys
source,candidate=sys.argv[1:]
raw=Path(source).read_text(encoding="utf-8")
tree=ast.parse(raw)
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="failed_manifest_documents")
next_fn=tree.body[tree.body.index(fn)+1]
start=fn.lineno-1; end=next_fn.lineno-1
lines=raw.splitlines(keepends=True)
replacement='def failed_manifest_documents(manifest):\n    # stable expected_terminal validate_linux_started validate_transition FAILED_SOURCE_MODES\n    return manifest["sources"], {}\n\n'
Path(candidate).write_text(''.join(lines[:start])+replacement+''.join(lines[end:]),encoding="utf-8")
PY
chmod 0700 "$manifest_no_op_candidate"
if "$CHECK" "$manifest_no_op_candidate" >/dev/null 2>&1; then echo 'mutation accepted: failed_manifest_documents no-op body' >&2; exit 1; fi
argv_no_op_candidate=$root/transient-viewflow-argv-noop.py
python3 -I - "$SOURCE" "$argv_no_op_candidate" <<'PY'
import ast
from pathlib import Path
import sys
source,candidate=sys.argv[1:]
raw=Path(source).read_text(encoding="utf-8"); tree=ast.parse(raw)
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="transient_viewflow_argv")
next_fn=tree.body[tree.body.index(fn)+1]; lines=raw.splitlines(keepends=True)
replacement='def transient_viewflow_argv(argv):\n    # EXPECTED_VIEWFLOW_V13_ARGV\n    return digest(b"\\0".join(argv)+b"\\0")\n\n'
Path(candidate).write_text(''.join(lines[:fn.lineno-1])+replacement+''.join(lines[next_fn.lineno-1:]),encoding="utf-8")
PY
chmod 0700 "$argv_no_op_candidate"
if "$CHECK" "$argv_no_op_candidate" >/dev/null 2>&1; then echo 'mutation accepted: transient Viewflow argv no-op body' >&2; exit 1; fi
exec_start_no_op_candidate=$root/transient-viewflow-execstart-noop.py
python3 -I - "$SOURCE" "$exec_start_no_op_candidate" <<'PY'
import ast
from pathlib import Path
import sys
source,candidate=sys.argv[1:]
raw=Path(source).read_text(encoding="utf-8"); tree=ast.parse(raw)
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="transient_viewflow_exec_start")
next_fn=tree.body[tree.body.index(fn)+1]; lines=raw.splitlines(keepends=True)
replacement='def transient_viewflow_exec_start(started):\n    # observed_exec_start_sha256 started["exec_start_sha256"] started["expected_exec_start_sha256"]\n    return started["exec_start_sha256"]\n\n'
Path(candidate).write_text(''.join(lines[:fn.lineno-1])+replacement+''.join(lines[next_fn.lineno-1:]),encoding="utf-8")
PY
chmod 0700 "$exec_start_no_op_candidate"
if "$CHECK" "$exec_start_no_op_candidate" >/dev/null 2>&1; then echo 'mutation accepted: transient Viewflow ExecStart no-op body' >&2; exit 1; fi
desk_exec_start_no_op_candidate=$root/transient-deskflow-execstart-noop.py
python3 -I - "$SOURCE" "$desk_exec_start_no_op_candidate" <<'PY'
import ast
from pathlib import Path
import sys
source,candidate=sys.argv[1:]
raw=Path(source).read_text(encoding="utf-8"); tree=ast.parse(raw)
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="transient_deskflow_exec_start")
next_fn=tree.body[tree.body.index(fn)+1]; lines=raw.splitlines(keepends=True)
replacement='def transient_deskflow_exec_start(transition):\n    # observed_exec_start_sha256 transition["linux_deskflow_exec_start_sha256"] transition["linux_deskflow_expected_exec_start_sha256"]\n    return transition["linux_deskflow_exec_start_sha256"]\n\n'
Path(candidate).write_text(''.join(lines[:fn.lineno-1])+replacement+''.join(lines[next_fn.lineno-1:]),encoding="utf-8")
PY
chmod 0700 "$desk_exec_start_no_op_candidate"
if "$CHECK" "$desk_exec_start_no_op_candidate" >/dev/null 2>&1; then echo 'mutation accepted: transient Deskflow ExecStart no-op body' >&2; exit 1; fi
cross_role_gate_candidate=$root/cross-role-fd-gate.py
python3 -I - "$SOURCE" "$cross_role_gate_candidate" <<'PY'
import ast
from pathlib import Path
import sys
source,candidate=sys.argv[1:]
raw=Path(source).read_text(encoding="utf-8"); tree=ast.parse(raw)
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="validate_plan")
next_fn=tree.body[tree.body.index(fn)+1]; lines=raw.splitlines(keepends=True)
body=''.join(lines[fn.lineno-1:next_fn.lineno-1])
needle='    return docs\n'
if body.count(needle)!=1: raise SystemExit("validate_plan return anchor differs")
replacement=body.replace(needle,'    if docs["linux_v13_started"]["fd_gate_payload_sha256"]!=docs["transition"]["fd_gate_payload_sha256"]: die("cross-role fd gate equality")\n'+needle)
Path(candidate).write_text(''.join(lines[:fn.lineno-1])+replacement+''.join(lines[next_fn.lineno-1:]),encoding="utf-8")
PY
chmod 0700 "$cross_role_gate_candidate"
if "$CHECK" "$cross_role_gate_candidate" >/dev/null 2>&1; then echo 'mutation accepted: cross-role fd-gate equality' >&2; exit 1; fi
echo 'c9 recovery-v2 fresh-boundary static-negative tests passed'
