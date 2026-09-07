#!/usr/bin/env bash
set -Eeuo pipefail
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly CHECK=$HERE/../check-bridge-schema7-c9-vfdqa-terminal-to-fresh-v21.sh
readonly SOURCE=$HERE/../bridge-schema7-c9-vfdqa-terminal-to-fresh-v21.py
tmp=$(mktemp -d --tmpdir 'viewflow-c9-bridge-negative.XXXXXX')
trap 'rm -rf -- "$tmp"' EXIT
for needle in 'os.O_NOFOLLOW' 'os.memfd_create' 'RENAME_NOREPLACE = 1' 'C9_ARTIFACTS =' 'def validate_fresh_marker' 'vp[344:352]' 'canonical producer JSON' 'authorization persistent proof closure differs' 'linux_stage_committed=False' 'windows_install_committed=False'; do
 cp -- "$SOURCE" "$tmp/bridge.py"
 python3 -I - "$tmp/bridge.py" "$needle" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); needle=sys.argv[2]; s=p.read_text()
if needle not in s: raise SystemExit('missing baseline mutation anchor')
p.write_text(s.replace(needle,'REMOVED',1))
PY
 if "$CHECK" "$tmp/bridge.py" >/dev/null 2>&1; then echo "error: accepted mutation: $needle" >&2; exit 1; fi
done
echo 'c9 schema7 bridge negative test passed'
