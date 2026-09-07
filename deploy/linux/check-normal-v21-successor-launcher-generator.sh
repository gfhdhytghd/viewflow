#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
source=${1:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/generate-normal-v21-successor-launcher.sh"}
[[ -f $source && ! -L $source ]] || { echo 'successor generator missing' >&2; exit 1; }
bash -n "$source"; shellcheck -s bash "$source"
for token in 3984cb3185a1165f260e3f0b83a4fbfdba86420da3317dbec615957e858d2146 --v4-coordinator --v4-provenance --v4-producer --successor-receipt --windows-prestate 'os.O_NOFOLLOW' 'actual==bsha' 'viewflow-normal-v21-coordinator-successor-authorized' 'viewflow-normal-v21-coordinator-successor-windows-prestate' "manifest,msha=doc(cm['path'],0o600); req(msha==cm['sha256'],'receipt predecessor candidate manifest SHA')" "['viewflowd','viewflowd_sha256','native_provenance','native_provenance_sha256','wrapper'" "sid=re.search(r'--windows-user-sid" "type(win['old_task_xml_sha256']) is str" --v4-coordinator --windows-task-xml-sha256 'predecessor launcher' 'receipt v4 closure' 'predecessor must retain v3' --offline-check --check-only --run-check-only --run-execute --run-resume 'durable successor output is forbidden' 'coordinator-successor-receipt-sha256' 'coordinator_replacement=(--candidate-retirement-terminal' "--candidate-replacement-commit '+repr(commit)" 'successor_live_recheck' 'Export-ScheduledTask' 'ErrorAction Stop' 'Get-ScheduledTask -ErrorAction Stop' 'powershell -NoProfile -EncodedCommand' '-o StrictHostKeyChecking=yes' 'active VFDQT changed' "[[ \${q[*]} == 'inactive 0' ]]" 'if [[ $mode == --resume ]]; then successor_resume_state' 'successor_runtime_pins' 'check_file "$SUCCESSOR_COORDINATOR"' 'check_file "$SUCCESSOR_RECEIPT"' 'normal v2.1 successor launcher check-only passed' '/run/user/1000' 'exec {render_fd}<' 'bash "/proc/self/fd/$render_fd"' 'runtime successor unlink failed' 'os.O_EXCL' 'os.fsync'; do
  rg -Fq -- "$token" "$source" || { echo "missing successor contract: $token" >&2; exit 1; }
done
! rg -n 'TODO|PLACEHOLDER|rm -rf|scp[[:space:]]' "$source" >/dev/null || { echo 'unsafe placeholder' >&2; exit 1; }
echo 'normal v2.1 successor launcher generator contract passed'
