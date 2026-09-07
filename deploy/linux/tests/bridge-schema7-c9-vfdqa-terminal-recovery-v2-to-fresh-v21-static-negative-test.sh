#!/usr/bin/env bash
set -Eeuo pipefail
source=${1:?source required}
tmp=$(mktemp -d --tmpdir viewflow-c9-final-v2-negative.XXXXXX)
cleanup() { rm -rf -- "$tmp"; }; trap cleanup EXIT
checker=$(cd -- "$(dirname -- "$source")" && pwd)/check-bridge-schema7-c9-vfdqa-terminal-recovery-v2-to-fresh-v21.sh
python3 -I - "$source" "$tmp/bad.py" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
s=s.replace('viewflow-linux-v1.3-started-under-deployment-quarantine','viewflow-v13-linux-started-frozen',1)
Path(sys.argv[2]).write_text(s)
PY
if python3 -I "$tmp/bad.py" --validate-inputs-only >/dev/null 2>&1; then
 echo 'error: old frozen Linux receipt state was accepted' >&2; exit 1
fi
python3 -I - "$source" "$tmp" <<'PY'
import ast,sys
from pathlib import Path
source,out=Path(sys.argv[1]),Path(sys.argv[2]); text=source.read_text(); tree=ast.parse(text)
for name in ('c9_sources','lifecycle','require_approval','current_linux_zero'):
 node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name==name)
 lines=text.splitlines(keepends=True); start=sum(map(len,lines[:node.lineno-1])); end=sum(map(len,lines[:node.end_lineno]))
 mutated=text[:start]+f'def {name}(*_args, **_kwargs):\n    return None\n'+text[end:]
 path=out/(name+'-noop.py'); path.write_text(mutated); path.chmod(0o755)
PY
for name in c9_sources lifecycle require_approval current_linux_zero; do
 if VIEWFLOW_BRIDGE_NEGATIVE_CHILD=1 "$checker" "$tmp/$name-noop.py" >/dev/null 2>&1; then
  echo "error: checker accepted $name no-op mutation" >&2; exit 1
 fi
done
python3 -I - "$source" <<'PY'
from pathlib import Path
import ast,sys
s=Path(sys.argv[1]).read_text(); t=ast.parse(s)
f=next(n for n in t.body if isinstance(n,ast.FunctionDef) and n.name=='current_linux_zero')
needed={'systemctl','ss','/proc','deskflow.sock','/run/user/1000/deskflow/viewflow-acceptance.sock','/run/user/1000/viewflow/deskflow-acceptance.sock','/run/user/1000/viewflow/post-release-acceptance.sock','deskflow-quarantine.v2','/tmp/viewflow-deskflow-recovery/deskflow','/tmp/viewflow-deskflow-recovery/deskflow-core','/memfd:viewflow-'}
if not all(x in ast.get_source_segment(s,f) for x in needed): raise SystemExit('current Linux zero gate was weakened')
g=next(n for n in t.body if isinstance(n,ast.FunctionDef) and n.name=='self_source_sha')
if not all(x in ast.get_source_segment(s,g) for x in ('O_NOFOLLOW','st_nlink','ident','BRIDGE_PATH')): raise SystemExit('self source pin was weakened')
def calls(fn):
 out=[]
 for n in ast.walk(fn):
  if isinstance(n,ast.Call):
   out.append(n.func.id if isinstance(n.func,ast.Name) else n.func.attr if isinstance(n.func,ast.Attribute) else '')
 return out
required={
 'c9_sources':{'read','keys','must','digest'},
 'lifecycle':{'read','keys','must','UUID'},
 'require_approval':{'read','approval_document','die'},
 'current_linux_zero':{'run','lexists','iterdir','readlink','die'},
}
for name,need in required.items():
 fn=next((n for n in t.body if isinstance(n,ast.FunctionDef) and n.name==name),None)
 if fn is None or not need.issubset(calls(fn)): raise SystemExit(name+' was made a no-op or lost a required gate')
main=next(n for n in t.body if isinstance(n,ast.FunctionDef) and n.name=='main')
if not {'c9_sources','lifecycle','require_approval','current_linux_zero','create_once'}.issubset(calls(main)): raise SystemExit('main lost a final publication gate')
print('c9 final bridge v2 static-negative test passed')
PY
