#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
source_file=${EARLY_BOOTSTRAP_GATE_ABORT_SOURCE:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort.py}
checker=${EARLY_BOOTSTRAP_GATE_ABORT_CHECKER:-/home/wilf/data/viewflow/deploy/check-early-bootstrap-gate-abort.sh}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

"$checker" "$source_file" >/dev/null
mutate_rejected() {
    local name=$1 old=$2 new=$3 copy
    copy=$tmp/$name.py
    python3 - "$source_file" "$copy" "$old" "$new" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text();old=sys.argv[3];new=sys.argv[4]
if source.count(old) != 1: raise SystemExit('mutation anchor count differs')
Path(sys.argv[2]).write_text(source.replace(old,new))
PY
    if "$checker" "$copy" >/dev/null 2>&1; then
        printf 'static negative accepted mutation: %s\n' "$name" >&2
        exit 1
    fi
}

mutate_rejected failure-phase '"failure_phase": None, "mutation_possible": False' '"failure_phase": "WINDOWS_STARTED", "mutation_possible": False'
mutate_rejected worker-created '"bootstrap_worker_created": False' '"bootstrap_worker_created": True'
mutate_rejected installer-count '"installer_process_count": 0' '"installer_process_count": 1'
mutate_rejected windows-census-unknown 'exact_keys(value, keys, f"{label} Windows snapshot")' 'pass # unknown Windows snapshot field accepted'
mutate_rejected windows-census-removed '"viewflowd_process_count", "wrapper_sha256"' '"wrapper_sha256"'
mutate_rejected windows-census-value2 '"viewflowd_process_count": 1,' '"viewflowd_process_count": 2,'
mutate_rejected deskflow-started '"linux_deskflow_started": False' '"linux_deskflow_started": True'
mutate_rejected no-replace 'libc.renameat2' 'libc.rename'
mutate_rejected post-auth-check 'post-authorization stable tuple changed before abort' 'unchecked tuple before abort'
mutate_rejected terminal-replay 'if replay_if_terminal(manifest):' 'if skip_terminal_replay(manifest):'
mutate_rejected reviewed-candidate-call '    validate_reviewed_marker_candidate(execution["marker_candidate"])' '    read_exact(execution["marker_candidate"], "unchecked marker candidate")'
mutate_rejected reviewed-provenance-state 'viewflow-deployment-marker-reviewed-build' 'viewflow-deployment-marker-unreviewed-build'
mutate_rejected reviewed-release-command 'cargo build --release -p viewflow-deployment-marker --bin viewflow-deployment-marker' 'cargo build -p viewflow-deployment-marker'
mutate_rejected reviewed-host-binding 're.escape(host_target)' 're.escape("x86_64-unknown-linux-gnu")'
mutate_rejected reviewed-version-match 'release_build["cargo_version"].split()[1]' 'release_build["rustc_version"].split()[1]'
mutate_rejected vfdqa-checksum 'raw[352:384] != hashlib.sha256(raw[:352]).digest()' 'raw[352:384] == hashlib.sha256(raw[:352]).digest()'
mutate_rejected vfdqa-auth-binding 'raw[304:336].hex() != auth_sha' 'raw[304:336].hex() == auth_sha'
mutate_rejected resume-abort '"abort", *common_args' '"query", *common_args'
mutate_rejected post-abort-snapshot 'validate_persisted_snapshots(manifest, require_post=require_post)' 'validate_persisted_snapshots(manifest, require_post=False)'
mutate_rejected active-prefix-hole 'if present != set(ACTIVE_OUTPUT_PREFIX[:length]):' 'if False:'
mutate_rejected active-prefix-extra 'forbidden = present - set(ACTIVE_OUTPUT_PREFIX)' 'forbidden = set()'
mutate_rejected receiptless-adoption 'started["state"] = "viewflow-early-gate-start-viewflow"' 'started["state"] = live["state"]'
mutate_rejected check-only-live-census 'boundary = current_resume_boundary(helper_fd, manifest_fd, manifest,' 'boundary = "unchecked" # current_resume_boundary(helper_fd, manifest_fd, manifest,'
mutate_rejected resumed-authorization 'if auth != expected_auth or auth_raw != expected_raw:' 'if False:'
mutate_rejected dirfd-cleanup 'os.unlink(temporary, dir_fd=parent)' 'os.unlink(str(target.parent / temporary))'
printf 'early bootstrap gate abort static negative test passed\n'
