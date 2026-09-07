#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

readonly ROOT=/home/wilf/data/viewflow
readonly OP=55d06e8f96aa4adc9010e53612979374
readonly MANIFEST=$ROOT/deploy/failed-pre-mutation-abort-55d06e8f-replay6-schema2-manifest.json
readonly MANIFEST_SHA=38764b640df1e304068ff33adc54939986a9b41181edfdcbaabb4a78a000ed3f
readonly LAUNCHER=$ROOT/deploy/launch-failed-pre-mutation-abort-55d06e8f-replay6-schema2-formal.sh
readonly LAUNCHER_SHA=53cc1d6720d4c892beb31e90ae439d9a454816ff2aaf60850d1b67642f716f66
readonly GATE=$ROOT/deploy/gate-failed-pre-mutation-abort-55d06e8f-replay6-schema2-formal.py
readonly GATE_SHA=16978b03509f77dd43bfdb755c3ec3e4cf778dff2eacce10c0c329ee088472a6
readonly APPROVAL=/home/wilf/.local/state/viewflow/deployments/$OP/failed-pre-mutation-abort-replay6-schema2-execution-approval.json
readonly PRIOR_APPROVAL=/home/wilf/.local/state/viewflow/deployments/$OP/failed-pre-mutation-abort-replay5-schema2-execution-approval.json
readonly PRIOR_APPROVAL_SHA=e2e20b047c301db5374eed3e34c0c61aa45bc440b588eee5f3ee361d75a0a1bf
readonly REPLAY2_APPROVAL=/home/wilf/.local/state/viewflow/deployments/$OP/failed-pre-mutation-abort-replay2-schema2-execution-approval.json
readonly REPLAY2_APPROVAL_SHA=c96a4507416767b5f2f1a3631fb79094629e6c4f44ef39aaa567cf2902db7cab
readonly INITIAL_APPROVAL=/home/wilf/.local/state/viewflow/deployments/$OP/failed-pre-mutation-abort-schema2-execution-approval.json
readonly INITIAL_APPROVAL_SHA=f7269f591e96bb518dde595c7d1b8e425d8e2155aec4ba1d32164f4299abcba4
readonly ADOPTED_LINUX=/home/wilf/.local/state/viewflow/deployments/$OP/linux-v13-started.schema2.json
readonly ADOPTED_LINUX_SHA=506281bd59fe982d9d8bdb7e6da6d4322b9b6aff9dfe61f2cbf0804abe728a9f

fail() { printf 'schema2 abort offline fixture failed: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d ' ' -f 1; }

[[ $(sha256 "$MANIFEST") == "$MANIFEST_SHA" && $(stat -c '%u:%a:%h' -- "$MANIFEST") == 1000:600:1 ]] ||
    fail 'manifest identity differs'
[[ $(sha256 "$LAUNCHER") == "$LAUNCHER_SHA" && $(stat -c '%u:%a:%h' -- "$LAUNCHER") == 1000:700:1 ]] ||
    fail 'launcher identity differs'
[[ $(sha256 "$GATE") == "$GATE_SHA" && $(stat -c '%u:%a:%h' -- "$GATE") == 1000:700:1 ]] ||
    fail 'gate identity differs'
[[ ! -e $APPROVAL && ! -L $APPROVAL ]] || fail 'approval must remain absent during offline fixture'
[[ $(sha256 "$PRIOR_APPROVAL") == "$PRIOR_APPROVAL_SHA" && $(stat -c '%u:%a:%h' -- "$PRIOR_APPROVAL") == 1000:600:1 ]] ||
    fail 'prior approval identity differs'
[[ $(sha256 "$REPLAY2_APPROVAL") == "$REPLAY2_APPROVAL_SHA" && $(stat -c '%u:%a:%h' -- "$REPLAY2_APPROVAL") == 1000:600:1 ]] ||
    fail 'replay2 approval identity differs'
[[ $(sha256 "$INITIAL_APPROVAL") == "$INITIAL_APPROVAL_SHA" && $(stat -c '%u:%a:%h' -- "$INITIAL_APPROVAL") == 1000:600:1 ]] ||
    fail 'initial approval identity differs'
[[ $(sha256 "$ADOPTED_LINUX") == "$ADOPTED_LINUX_SHA" && $(stat -c '%u:%a:%h' -- "$ADOPTED_LINUX") == 1000:600:1 ]] ||
    fail 'adopted Linux receipt identity differs'

jq -e --arg op "$OP" --arg coordinator 0bad017d72c3d8e133fe810855cb538628edd44f4e198873d98aa5d30c9f5892 \
    --arg marker e791a290aa112a1484bdfcce1de439a82e181ee5c1b3621f3b142d68e4e40b66 '
    keys == ["active_marker_gate","adopted_outputs","approval","argv","execution_authorized","fresh_outputs","immutable_terminal_inputs","initial_approval","installed_v13_inputs","marker_candidate","operation_id","prior_approval","replay2_approval","required_absent","reviewed_code","schema_version","state","superseded_replay3","superseded_replay4","superseded_replay5","threat_boundary"] and
    .schema_version == 2 and .state == "viewflow-failed-pre-mutation-abort-replay6-schema2-command-manifest" and
    .execution_authorized == false and .operation_id == $op and
    .reviewed_code.coordinator.sha256 == $coordinator and .marker_candidate.sha256 == $marker and
    (.immutable_terminal_inputs | length) == 8 and (.installed_v13_inputs | length) == 6 and
    .prior_approval == {path:"/home/wilf/.local/state/viewflow/deployments/55d06e8f96aa4adc9010e53612979374/failed-pre-mutation-abort-replay5-schema2-execution-approval.json",sha256:"e2e20b047c301db5374eed3e34c0c61aa45bc440b588eee5f3ee361d75a0a1bf",mode:600} and
    .replay2_approval == {path:"/home/wilf/.local/state/viewflow/deployments/55d06e8f96aa4adc9010e53612979374/failed-pre-mutation-abort-replay2-schema2-execution-approval.json",sha256:"c96a4507416767b5f2f1a3631fb79094629e6c4f44ef39aaa567cf2902db7cab",mode:600} and
    .initial_approval == {path:"/home/wilf/.local/state/viewflow/deployments/55d06e8f96aa4adc9010e53612979374/failed-pre-mutation-abort-schema2-execution-approval.json",sha256:"f7269f591e96bb518dde595c7d1b8e425d8e2155aec4ba1d32164f4299abcba4",mode:600} and
    .superseded_replay3.state == "viewflow-failed-pre-mutation-abort-replay3-never-approved" and
    .superseded_replay3.approval_required_absent == true and
    .superseded_replay3.fresh_outputs_required_absent == true and
    (.superseded_replay3.fresh_outputs | length) == 6 and
    .superseded_replay4.state == "viewflow-failed-pre-mutation-abort-replay4-never-approved" and
    .superseded_replay4.approval_required_absent == true and
    .superseded_replay4.fresh_outputs_required_absent == true and
    (.superseded_replay4.fresh_outputs | length) == 6 and
    .superseded_replay5.state == "viewflow-failed-pre-mutation-abort-replay5-approved-no-fresh-output" and
    .superseded_replay5.approval == .prior_approval and
    .superseded_replay5.fresh_outputs_required_absent == true and
    (.superseded_replay5.fresh_outputs | length) == 6 and
    .adopted_outputs.linux_started.sha256 == "506281bd59fe982d9d8bdb7e6da6d4322b9b6aff9dfe61f2cbf0804abe728a9f" and
    .adopted_outputs.linux_started.live_tuple.main_pid == 3202576 and
    .adopted_outputs.linux_started.live_tuple.invocation_id == "535f70190afe49ff89b69e93cc389358" and
    (.fresh_outputs | keys) == ["abort_receipt","authenticated_peer","authorization","terminal","windows_live","windows_started"] and
    .argv[1] == "--abort-failed-v13-pre-mutation" and
    (.argv | index("--abort-failed-v13")) == null and (.argv | index("--failed-v13-original-generation-only")) != null
' "$MANIFEST" >/dev/null || fail 'manifest exact schema/branch binding differs'

grep -Fq -- '"--dev",' "$GATE" || fail 'gate omits private /dev construction'
grep -Fq -- '"/dev",' "$GATE" || fail 'gate omits /dev mount target'
grep -Fq -- '"--ro-bind-data",' "$GATE" || fail 'gate omits sealed launcher transfer into bwrap'
grep -Fq -- 'clean_env = {"HOME": "/home/wilf", "PATH": "/usr/bin:/bin"}' "$GATE" ||
    fail 'gate omits clean loader environment'
grep -Fq -- 'os.execve("/usr/bin/bash",["/usr/bin/bash",f"/proc/self/fd/{coordinator_fd}",*argv[1:]],runtime_env)' "$LAUNCHER" ||
    fail 'launcher does not execute the sealed coordinator FD'

/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin GATE="$GATE" GATE_SHA="$GATE_SHA" \
    /usr/bin/python3.14 -I -E - <<'PY'
import fcntl
import hashlib
import os
import subprocess

gate_path = os.environ["GATE"]
gate_sha = os.environ["GATE_SHA"]
fd = os.open(gate_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
data = b""
while True:
    chunk = os.read(fd, 1048576)
    if not chunk:
        break
    data += chunk
os.close(fd)
if hashlib.sha256(data).hexdigest() != gate_sha:
    raise SystemExit(65)
sealed = os.memfd_create("viewflow-schema2-abort-gate", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
os.write(sealed, data)
os.fsync(sealed)
os.lseek(sealed, 0, os.SEEK_SET)
required = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
fcntl.fcntl(sealed, fcntl.F_ADD_SEALS, required)
if fcntl.fcntl(sealed, fcntl.F_GET_SEALS) != required:
    raise SystemExit(74)
os.set_inheritable(sealed, True)
subprocess.run(
    [
        "/usr/bin/python3.14",
        f"/proc/self/fd/{sealed}",
        "--offline-preflight",
        "--gate-sha256",
        gate_sha,
    ],
    env={"HOME": "/home/wilf", "PATH": "/usr/bin:/bin"},
    pass_fds=(sealed,),
    check=True,
)
PY

[[ ! -e $APPROVAL && ! -L $APPROVAL ]] || fail 'offline preflight published approval'
while IFS= read -r output; do
    [[ ! -e $output && ! -L $output ]] || fail "offline preflight published output: $output"
done < <(jq -r '.fresh_outputs[]' "$MANIFEST")
while IFS= read -r stale; do
    [[ ! -e $stale && ! -L $stale ]] || fail "superseded never-approved artifact exists: $stale"
done < <(jq -r '.superseded_replay3.approval_path,.superseded_replay4.approval_path,.superseded_replay3.fresh_outputs[],.superseded_replay4.fresh_outputs[],.superseded_replay5.fresh_outputs[]' "$MANIFEST")
printf 'schema2 abort operation-local offline fixture passed\n'
