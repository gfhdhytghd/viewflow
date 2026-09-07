#!/usr/bin/env bash
set -Eeuo pipefail
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target=${1:-"$HERE/bridge-schema7-c9-vfdqa-terminal-to-fresh-v21.py"}
[[ -f $target && ! -L $target ]] || { echo 'error: bridge missing' >&2; exit 1; }
python3 -I -m py_compile "$target"
python3 -I - "$target" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
for token in ('OLD_OP = "c9b05e9bea4140d69f9d137a0f992ba0"','OLD_COORD = "86c03003-2b67-451d-a990-396e1a66b406"','C9_ARTIFACTS =','C9_OLD =','C9_MANIFEST_SHA =','validate_fresh_marker','raw[14:16]','raw[48:144]','vp[344:352]','fresh VFDQT identity differs','VFDQA001','os.memfd_create','F_ADD_SEALS','renameat2','RENAME_NOREPLACE = 1','viewflow-v4-inactive-terminal-to-fresh-v21','canonical producer JSON','authorization persistent proof closure differs','timestamp/path differs','linux_stage_committed=False','windows_install_committed=False','windows_installer_exit_present=False'):
 if token not in s: raise SystemExit('error: missing bridge anchor: '+token)
if s.count('os.O_NOFOLLOW') < 2: raise SystemExit('error: missing stable input/output nofollow anchors')
for bad in ('subprocess','systemctl','ssh '):
 if bad in s.lower(): raise SystemExit('error: live path in offline bridge: '+bad)
print('c9 schema7 bridge static contract passed')
PY
