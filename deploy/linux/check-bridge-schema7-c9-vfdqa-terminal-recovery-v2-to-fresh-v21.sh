#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE=${1:-$HERE/bridge-schema7-c9-vfdqa-terminal-recovery-v2-to-fresh-v21.py}
python3 -I -m py_compile "$SOURCE"
python3 -I "$HERE/tests/bridge-schema7-c9-vfdqa-terminal-recovery-v2-to-fresh-v21-hermetic.py" "$SOURCE"
if [[ ${VIEWFLOW_BRIDGE_NEGATIVE_CHILD-} != 1 ]]; then
 "$HERE/tests/bridge-schema7-c9-vfdqa-terminal-recovery-v2-to-fresh-v21-static-negative-test.sh" "$SOURCE"
fi
python3 -I - "$SOURCE" <<'PY'
from pathlib import Path
import ast,sys
s=Path(sys.argv[1]).read_text(); t=ast.parse(s)
for x in ('LIFECYCLE_SHA="7a81a0','MANIFEST_SHA="d85feb','LIFECYCLE_APPROVAL_SHA="8bda57','VFDQA_SHA="56ae','viewflow-linux-v1.3-started-under-deployment-quarantine','viewflow-windows-v1.3-started-under-deployment-quarantine','viewflow-v1.3-peer-authenticated-under-deployment-quarantine','os.O_TMPFILE','AT_EMPTY_PATH','execution_authorized=False','self-pinned approval differs','viewflow-v4-inactive-terminal-to-fresh-v21'):
 if x not in s: raise SystemExit('missing recovery bridge anchor: '+x)
if any(x in s.lower() for x in ('ssh ','requests.','curl ','wget ','paramiko')): raise SystemExit('remote path present')
if 'subprocess.run' not in s or 'def current_linux_zero' not in s: raise SystemExit('current Linux zero gate absent')
if s.count('os.O_NOFOLLOW')<2: raise SystemExit('insufficient nofollow reads')
def calls(fn):
 out=[]
 for n in ast.walk(fn):
  if isinstance(n,ast.Call): out.append(n.func.id if isinstance(n.func,ast.Name) else n.func.attr if isinstance(n.func,ast.Attribute) else '')
 return out
for name,need in {'c9_sources':{'read','keys','must','digest'},'lifecycle':{'read','keys','must','UUID'},'require_approval':{'read','approval_document','die'},'current_linux_zero':{'run','lexists','iterdir','readlink','die'}}.items():
 fn=next((n for n in t.body if isinstance(n,ast.FunctionDef) and n.name==name),None)
 if fn is None or not need.issubset(calls(fn)): raise SystemExit('missing non-noop gate: '+name)
print('c9 final bridge v2 static contract passed')
PY
