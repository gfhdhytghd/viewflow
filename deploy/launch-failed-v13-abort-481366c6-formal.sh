#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

readonly OPERATION_ID=481366c6c9654a679a96d4b6b1447ecb
readonly LAUNCHER=/home/wilf/data/viewflow/deploy/launch-failed-v13-abort-481366c6-formal.sh
readonly PLAN=/home/wilf/data/viewflow/deploy/failed-v13-abort-481366c6-args.json
readonly PLAN_SHA256=8f029bbb3d18abeaf5fe70d8bafcfbe3381e0aa84dbb88826f382032d6363b3d
readonly COORDINATOR=/home/wilf/data/viewflow/deploy/coordinated-v13-to-v2.sh
readonly COORDINATOR_SHA256=f33cb08a6c13cdbe6aceea5356b4b453a2c8e48a40d63edf7984cefbe25c6a7c
readonly CHECKER=/home/wilf/data/viewflow/deploy/check-cross-host-coordinator.sh
readonly CHECKER_SHA256=757f884d0b370814c5059f0d5a90cb9a546cd0b932efc02cccb3399d63deeca7
readonly APPROVAL=/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/failed-v13-abort-execution-approval.json
readonly TERMINAL_STATE=/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/coordinator-state.json
readonly TERMINAL_STATE_SHA256=83922f9e26a8e6c09d8363eab646f3143357b7859514e801f83d6f84b6128b8a
readonly SLOT_CLEANUP=/home/wilf/.local/state/viewflow/deployments/481366c6c9654a679a96d4b6b1447ecb/cleanup-attempt3-exchange-slots-complete.json
readonly SLOT_CLEANUP_SHA256=7c995aee63c51d12d0c1fc8436161b94f42161cbf21f435ffeb29548477bc96e
readonly ACTIVE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly ACTIVE_MARKER_SHA256=0adec6f0c87081b352dacfef0d5ab2158145a149e4583b48239cc51fa55065e8

approval_sha256=''

die() { printf 'failed-v13 formal launcher: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d ' ' -f 1; }
require_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]] || die 'approval SHA must be lowercase SHA-256'; }
strict_json() {
    python3 -c 'import json,sys
def hook(pairs):
    out={}
    for key,value in pairs:
        if key in out: raise ValueError("duplicate key")
        out[key]=value
    return out
with open(sys.argv[1],"rb") as stream:
    data=stream.read()
if not data.endswith(b"\n") or data[:-1].endswith(b"\n"):
    raise SystemExit("noncanonical JSON framing")
json.loads(data.decode("utf-8"),object_pairs_hook=hook)' "$1" || die "$2 is not strict JSON"
}
require_regular_path_fd() {
    local label=$1 artifact_path=$2 fd=$3 expected_sha=$4 path_identity fd_identity
    [[ -f $artifact_path && ! -L $artifact_path ]] || die "$label path is absent or unsafe"
    path_identity=$(stat -c '%u:%h:%d:%i' -- "$artifact_path")
    fd_identity=$(stat -Lc '%u:%h:%d:%i' -- "/proc/$$/fd/$fd")
    [[ $path_identity == "$fd_identity" && $fd_identity == 1000:1:* ]] || die "$label FD/path identity differs"
    [[ $(sha256 "/proc/$$/fd/$fd") == "$expected_sha" ]] || die "$label SHA differs"
}
require_plan_artifact() {
    local label=$1 artifact_path=$2 expected_sha=$3
    [[ -f $artifact_path && ! -L $artifact_path && $(stat -c '%u:%h' -- "$artifact_path") == 1000:1 ]] ||
        die "$label path is absent or unsafe"
    [[ $(sha256 "$artifact_path") == "$expected_sha" ]] || die "$label SHA differs"
}

while (($#)); do
    case $1 in
        --approval-sha256) (($# >= 2)) || die '--approval-sha256 requires a value'; approval_sha256=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
require_sha256 "$approval_sha256"
[[ $(id -u) == 1000 && $HOME == /home/wilf ]] || die 'run as uid 1000 with HOME=/home/wilf'
for command_name in bash cut jq python3 readlink sha256sum stat; do command -v "$command_name" >/dev/null || die "missing command: $command_name"; done
[[ $(readlink -f -- "${BASH_SOURCE[0]}") == "$LAUNCHER" ]] || die 'launcher path is not canonical'

# Fixed descriptors are retained across the final exec.  Every path is checked
# against the already-open descriptor, then re-attested after the checker.
exec 9<"$COORDINATOR"
exec 8<"$PLAN"
exec 7<"$APPROVAL"
exec 6<"$CHECKER"
require_regular_path_fd coordinator "$COORDINATOR" 9 "$COORDINATOR_SHA256"
require_regular_path_fd plan "$PLAN" 8 "$PLAN_SHA256"
require_regular_path_fd approval "$APPROVAL" 7 "$approval_sha256"
require_regular_path_fd checker "$CHECKER" 6 "$CHECKER_SHA256"
[[ $(stat -c '%a' -- "$APPROVAL") == 600 ]] || die 'approval receipt mode is not 0600'
strict_json "/proc/$$/fd/8" plan
strict_json "/proc/$$/fd/7" approval

launcher_sha256=$(sha256 "$LAUNCHER")
jq -e --arg op "$OPERATION_ID" --arg plan "$PLAN_SHA256" --arg launcher "$launcher_sha256" \
    --arg coordinator "$COORDINATOR_SHA256" --arg checker "$CHECKER_SHA256" \
    --arg terminal "$TERMINAL_STATE_SHA256" --arg cleanup "$SLOT_CLEANUP_SHA256" \
    --arg marker "$ACTIVE_MARKER_SHA256" '
    keys == ["active_marker_sha256","approved","approved_at_utc","coordinator_sha256","launcher_sha256","manifest_sha256","operation_id","publication_method","schema_version","slot_cleanup_receipt_sha256","state","terminal_state_sha256"] and
    .schema_version == 1 and .state == "viewflow-failed-v13-abort-execution-approved" and
    .operation_id == $op and .approved == true and
    .publication_method == "create-once-no-replace-and-parent-fsync" and
    .manifest_sha256 == $plan and .launcher_sha256 == $launcher and
    .coordinator_sha256 == $coordinator and .terminal_state_sha256 == $terminal and
    .slot_cleanup_receipt_sha256 == $cleanup and .active_marker_sha256 == $marker and
    (.approved_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))
' "/proc/$$/fd/7" >/dev/null || die 'approval receipt schema/binding differs'

jq -e --arg op "$OPERATION_ID" --arg launcher "$LAUNCHER" --arg approval "$APPROVAL" \
    --arg coordinator "$COORDINATOR" --arg coordinator_sha "$COORDINATOR_SHA256" \
    --arg checker "$CHECKER" --arg checker_sha "$CHECKER_SHA256" \
    --arg terminal "$TERMINAL_STATE" --arg terminal_sha "$TERMINAL_STATE_SHA256" \
    --arg cleanup "$SLOT_CLEANUP" --arg cleanup_sha "$SLOT_CLEANUP_SHA256" \
    --arg marker "$ACTIVE_MARKER" --arg marker_sha "$ACTIVE_MARKER_SHA256" '
    .schema_version == 1 and .state == "viewflow-failed-v13-abort-command-plan" and
    .execution_authorized == false and .operation_id == $op and
    .formal_launcher.path == $launcher and .formal_launcher.approval_path == $approval and
    .coordinator.path == $coordinator and .coordinator.sha256 == $coordinator_sha and
    .coordinator.checker_path == $checker and .coordinator.checker_sha256 == $checker_sha and
    .terminal_state_gate.path == $terminal and .terminal_state_gate.sha256 == $terminal_sha and
    .terminal_state_gate.phase == "WINDOWS_ROLLED_BACK" and
    .slot_cleanup_gate.path == $cleanup and .slot_cleanup_gate.sha256 == $cleanup_sha and
    .slot_cleanup_gate.state == "viewflow-attempt3-exchange-slot-cleanup-complete" and
    .active_marker_gate.path == $marker and .active_marker_gate.sha256 == $marker_sha and
    .active_marker_gate.generation == "1" and .active_marker_gate.runtime_marker_required_absent == true and
    .argv[0] == $coordinator and .argv[1] == "--abort-failed-v13" and
    (.argv | index("--failed-v13-original-generation-only")) != null
' "/proc/$$/fd/8" >/dev/null || die 'plan identity/gates differ'

require_plan_artifact terminal-state "$TERMINAL_STATE" "$TERMINAL_STATE_SHA256"
require_plan_artifact slot-cleanup "$SLOT_CLEANUP" "$SLOT_CLEANUP_SHA256"
require_plan_artifact active-marker "$ACTIVE_MARKER" "$ACTIVE_MARKER_SHA256"
[[ $(jq -er '.phase' "$TERMINAL_STATE") == WINDOWS_ROLLED_BACK ]] || die 'terminal state phase changed'
[[ $(jq -er '.state' "$SLOT_CLEANUP") == viewflow-attempt3-exchange-slot-cleanup-complete ]] || die 'slot-cleanup state changed'

while IFS=$'\t' read -r artifact_path expected_sha; do
    require_plan_artifact terminal-input "$artifact_path" "$expected_sha"
done < <(jq -r '.terminal_inputs[] | [.path,.sha256] | @tsv' "/proc/$$/fd/8")
while IFS=$'\t' read -r artifact_path expected_sha; do
    require_plan_artifact restored-linux "$artifact_path" "$expected_sha"
done < <(jq -r '.restored_linux_gate[] | [.path,.sha256] | @tsv' "/proc/$$/fd/8")
while IFS= read -r artifact_path; do
    [[ ! -e $artifact_path && ! -L $artifact_path ]] || die "fresh/sentinel path already exists: $artifact_path"
done < <(jq -r '.required_absent_branch_sentinels[],.fresh_outputs[]' "/proc/$$/fd/8")
runtime_marker=$(jq -er '.active_marker_gate.runtime_marker_path' "/proc/$$/fd/8")
[[ ! -e $runtime_marker && ! -L $runtime_marker ]] || die 'runtime quarantine marker appeared'

/usr/bin/bash "/proc/$$/fd/6" "$COORDINATOR" >/dev/null
require_regular_path_fd coordinator "$COORDINATOR" 9 "$COORDINATOR_SHA256"
require_regular_path_fd plan "$PLAN" 8 "$PLAN_SHA256"
require_regular_path_fd approval "$APPROVAL" 7 "$approval_sha256"
mapfile -t exact_argv < <(jq -r '.argv[]' "/proc/$$/fd/8")
[[ ${#exact_argv[@]} -gt 2 && ${exact_argv[0]} == "$COORDINATOR" ]] || die 'exact argv is invalid'
exec /usr/bin/bash "/proc/$$/fd/9" "${exact_argv[@]:1}"
