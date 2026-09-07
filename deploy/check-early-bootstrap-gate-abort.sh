#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
source_file=${1:-/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort.py}
die() { printf 'early gate checker: %s\n' "$*" >&2; exit 1; }
[[ -f $source_file && ! -L $source_file ]] || die 'source must be a regular non-symlink'
python3 -m py_compile "$source_file" || die 'Python source does not compile'

require() { grep -F -- "$1" "$source_file" >/dev/null || die "missing contract: $2"; }
reject() { ! grep -E -- "$1" "$source_file" >/dev/null || die "forbidden construct: $2"; }

require '"phase"] == "LINUX_RECOVERED"' 'early terminal phase'
require '"failure_phase": None, "mutation_possible": False' 'null failure phase and no mutation'
require '"coordinator_state", "marker_handoff", "linux_frozen",' 'exact state/H/B artifact set'
require '"deployment_publish", "bootstrap_request", "windows_stop_evidence"' 'exact publish/request/stop set'
require '{"identity", "inputs", "outputs", "remote"}' 'full coordinator contract'
require 'uncommitted local coordinator output exists' 'derived absent local outputs'
require '"viewflow-windows-bootstrap-no-worker-stopped"' 'no-worker stop evidence'
require '"status_sha256": "0" * 64' 'unique zero stop-status sentinel'
require '"task_path": "\\", "task_name": "Viewflow Peer"' 'canonical old task path/name split'
require '"task_action_sha256"' 'old task action binding'
require '"task_principal_sha256"' 'old task principal binding'
require '"parent_pid", "executable_path", "command_line_sha256"' 'complete old Windows process identity'
require '"viewflowd_process_count", "wrapper_sha256"' 'global Windows Viewflow census field'
require 'exact_keys(value, keys, f"{label} Windows snapshot")' 'unknown Windows census fields rejected'
require '"viewflowd_process_count": 1,' 'exactly one global Windows Viewflow process'
require 'type(value["viewflowd_process_count"]) is not int' 'Windows Viewflow census rejects bool/non-integer'
require '"new_operation_root_present": False' 'new operation root absent'
require '"new_task_present": False' 'new task absent'
require '"bootstrap_worker_created": False' 'worker absent'
require '"installer_process_count": 0' 'installer absent'
require '"mutation_permit_published": False' 'mutation permit absent'
require '"initial_force_release_executed": False' 'initial force release absent'
require '"force_release_executed": False' 'force release absent'
require '"rollback_performed": False' 'rollback absent'
require '"windows_rollback_receipt_sha256": None' 'rollback receipt absent'
require '"linux_deskflow_started": False' 'Deskflow never started'
require '"input_producer_count": 0' 'zero input producers'
require 'run_helper(helper_fd, manifest_fd, "pre-abort-reattest")' 'post-authorization reattestation'
require 'run_helper(helper_fd, manifest_fd, "post-abort-reattest")' 'post-abort reattestation'
require 'post-authorization stable tuple changed before abort' 'stable tuple comparison'
require 'os.memfd_create' 'sealed FD creation'
require 'fcntl.F_ADD_SEALS' 'sealed FD enforcement'
require 'libc.renameat2' 'no-replace publication'
require 'RENAME_NOREPLACE' 'create-once publication flag'
require 'os.fsync(parent)' 'parent fsync'
require 'if replay_if_terminal(manifest):' 'terminal replay validation'
require 'marker_absent' 'terminal marker absence'
require 'abort_claim_absent' 'terminal abort-claim absence'
require 'release_claim_absent' 'terminal release-claim absence'
require 'runtime_marker_absent' 'terminal VFQST absence'
require '"query", "--operation-id"' 'pinned marker CLI VFDQA query'
require 'marker candidate must be native owner mode 0755' 'native-only marker CLI'
require 'candidate_bytes[:4] != b"\x7fELF"' 'native ELF marker CLI proof'
require 'viewflow-deployment-marker-reviewed-build' 'reviewed marker build provenance class'
require 'provenance["candidate"] != candidate_spec' 'reviewed provenance binds candidate identity'
require 'provenance["test_matrix"] != REVIEWED_TEST_MATRIX' 'reviewed provenance binds test matrix'
require '"package_manifest", "cargo_lock", "release_build", "test_matrix"' 'reviewed provenance exact top-level schema'
require 'REVIEWED_RELEASE_BUILD_COMMAND' 'fixed reviewed release-build command'
require '"cargo build --release -p viewflow-deployment-marker --bin viewflow-deployment-marker"' 'exact reviewed release-build command'
require '"command", "cargo_version", "rustc_version", "toolchain",' 'reviewed toolchain identity schema'
require 're.escape(host_target)' 'reviewed toolchain binds host target'
require 'release_build["cargo_version"].split()[1]' 'reviewed cargo/rustc release match'
candidate_call_count=$(grep -F -o 'validate_reviewed_marker_candidate(' "$source_file" | wc -l)
[[ $candidate_call_count == 5 ]] || die 'all marker candidate execution paths must use reviewed provenance validation'
require '"committed durable VFDQA")' 'committed query independently decodes VFDQA'
require '"resumed durable VFDQA")' 'resume independently decodes VFDQA'
require '"fresh durable VFDQA")' 'fresh abort independently decodes VFDQA'
require 'raw[352:384] != hashlib.sha256(raw[:352]).digest()' 'VFDQA self-checksum decode'
require 'raw[304:336].hex() != auth_sha' 'VFDQA authorization binding'
require 'marker_sha.hex() != manifest["marker"]["sha256"]' 'VFDQA marker binding'
require 'validate_persisted_snapshots(manifest, require_post=require_post)' 'full persisted snapshot replay validation'
require 'ACTIVE_OUTPUT_PREFIX = (' 'durable active-phase prefix declaration'
require 'active marker output journal has a hole or extra phase' 'active phase holes/extras rejected'
require 'active marker has post-abort/terminal output' 'active phase post-abort outputs rejected'
require 'if present != set(ACTIVE_OUTPUT_PREFIX[:length]):' 'active phase exact-prefix equality'
require 'forbidden = present - set(ACTIVE_OUTPUT_PREFIX)' 'active phase post-abort set subtraction'
require 'validate_active_journal(manifest)' 'persisted active journal validation'
require 'adopt_or_start_linux(helper_fd, manifest_fd, manifest, snapshots)' 'receipt-less transient adoption path'
require 'started["state"] = "viewflow-early-gate-start-viewflow"' 'adopted exact live tuple relabel'
require 'current_resume_boundary(helper_fd, manifest_fd, manifest,' 'check-only live resume census'
require 'no mutation performed' 'check-only reports read-only resume'
require 'if auth != expected_auth or auth_raw != expected_raw:' 'resumed authorization exact-byte binding'
require '"abort", *common_args' 'resume replays abort transaction'
require '"query", *common_args' 'resume queries durable abort after completion'
require 'dir_fd=parent' 'dirfd-relative output operations'
require 'os.unlink(temporary, dir_fd=parent)' 'dirfd-relative temporary cleanup'
require 'reattest_parent(target.parent, parent, parent_stat)' 'parent inode reattestation'
reject 'systemctl[^\n]*(start|restart)[^\n]*deskflow|start-deskflow|ssh[_ -]' 'tool must expose neither Deskflow start nor SSH'

python3 - "$source_file" <<'PY' || die 'check-only/replay/resume ordering differs'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text();m=s.index('def main():');s=s[m:]
validate=s.index('validate_manifest(manifest, args.manifest')
check=s.index('if args.check_only:')
replay=s.index('if terminal_exists:')
resume=s.index('if committed_abort:', replay)
raise SystemExit(0 if validate < check < replay < resume else 1)
PY

require 'value == "0" * 64' 'nonzero evidence-hash guard'
zero_count=$(grep -F -o '"0" * 64' "$source_file" | wc -l)
[[ $zero_count == 2 ]] || die 'all-zero SHA may occur only in rejection guard and stop.status_sha256'
printf 'early bootstrap gate abort source checker passed\n'
