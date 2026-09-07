#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/generate-normal-v21-successor-launcher.sh
tmp=$(mktemp -d --tmpdir successor-negative.XXXXXX); trap 'rm -rf -- "$tmp"' EXIT
cp -- "$src" "$tmp/generator"
reject(){ if bash "$tmp/generator" "$@" >/dev/null 2>&1; then echo "accepted $*" >&2; exit 1; fi; }
reject --operation-id BAD --coordinator-uuid BAD
for old in 'actual==bsha' 'receipt v4 closure' 'operation_bound_task_count' 'os.O_NOFOLLOW' 'Export-ScheduledTask' 'coordinator-successor-receipt-sha256'; do rg -Fq "$old" "$src" || { echo "missing negative anchor $old" >&2; exit 1; }; done
checker="$(dirname "$src")/check-normal-v21-successor-launcher-generator.sh"
for needle in 'actual==bsha' "manifest,msha=doc(cm['path'],0o600); req(msha==cm['sha256'],'receipt predecessor candidate manifest SHA')" "['viewflowd','viewflowd_sha256','native_provenance','native_provenance_sha256','wrapper'" "sid=re.search(r'--windows-user-sid" "type(win['old_task_xml_sha256']) is str" 'check_file "$SUCCESSOR_COORDINATOR"' 'check_file "$SUCCESSOR_RECEIPT"' 'powershell -NoProfile -EncodedCommand' '-o StrictHostKeyChecking=yes' 'Export-ScheduledTask' 'active VFDQT changed' "[[ \${q[*]} == 'inactive 0' ]]" 'if [[ $mode == --resume ]]; then successor_resume_state' 'os.O_EXCL' '/run/user/1000' 'durable successor output is forbidden' 'coordinator_replacement=(--candidate-retirement-terminal' "--candidate-replacement-commit '+repr(commit)" " --windows-task-xml-sha256 '+repr(taskxmlsha)" 'exec {render_fd}<' 'bash "/proc/self/fd/$render_fd"'; do
    cp -- "$src" "$tmp/generator"
    python3 - "$tmp/generator" "$needle" <<'PY'
import sys
p,n=sys.argv[1:]; s=open(p,encoding='utf-8').read()
if n not in s: raise SystemExit('missing mutation needle')
open(p,'w',encoding='utf-8').write(s.replace(n,'REMOVED_CONTRACT',1))
PY
    if bash "$checker" "$tmp/generator" >/dev/null 2>&1; then echo "checker accepted removed $needle" >&2; exit 1; fi
done
echo 'normal v2.1 successor launcher static-negative test passed'
