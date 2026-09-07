#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

readonly ROOT=/home/wilf/data/viewflow
readonly OP=55d06e8f96aa4adc9010e53612979374
readonly MANIFEST=$ROOT/deploy/failed-pre-mutation-abort-55d06e8f-schema2-manifest.json
readonly MANIFEST_SHA=916d78ac65862daca2c78aedf3536d67a44ee0c40fe69d420d46b0c5f9954378
readonly LAUNCHER=$ROOT/deploy/launch-failed-pre-mutation-abort-55d06e8f-schema2-formal.sh
readonly LAUNCHER_SHA=c8e4a79e2c91f0fc7ca1abadac655311c8c7d8370ef7cfdb6bbb58bcec52b946
readonly GATE=$ROOT/deploy/gate-failed-pre-mutation-abort-55d06e8f-schema2-formal.py
readonly GATE_SHA=26e0c222882fa8cad15decd36f396e13a84340659f3fbb9853cdf20fcdad40e0
readonly APPROVAL=/home/wilf/.local/state/viewflow/deployments/$OP/failed-pre-mutation-abort-schema2-execution-approval.json

fail() { printf 'schema2 abort offline fixture failed: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d ' ' -f 1; }

[[ $(sha256 "$MANIFEST") == "$MANIFEST_SHA" && $(stat -c '%u:%a:%h' -- "$MANIFEST") == 1000:600:1 ]] ||
    fail 'manifest identity differs'
[[ $(sha256 "$LAUNCHER") == "$LAUNCHER_SHA" && $(stat -c '%u:%a:%h' -- "$LAUNCHER") == 1000:700:1 ]] ||
    fail 'launcher identity differs'
[[ $(sha256 "$GATE") == "$GATE_SHA" && $(stat -c '%u:%a:%h' -- "$GATE") == 1000:700:1 ]] ||
    fail 'gate identity differs'
[[ ! -e $APPROVAL && ! -L $APPROVAL ]] || fail 'approval must remain absent during offline fixture'

jq -e --arg op "$OP" --arg coordinator e15458f3381f4e76b729b8daf158dc70a6eb4487a385ca5350b3486255be46e4 \
    --arg marker e791a290aa112a1484bdfcce1de439a82e181ee5c1b3621f3b142d68e4e40b66 '
    keys == ["active_marker_gate","approval","argv","execution_authorized","fresh_outputs","immutable_terminal_inputs","installed_v13_inputs","marker_candidate","operation_id","required_absent","reviewed_code","schema_version","state","threat_boundary"] and
    .schema_version == 2 and .state == "viewflow-failed-pre-mutation-abort-schema2-command-manifest" and
    .execution_authorized == false and .operation_id == $op and
    .reviewed_code.coordinator.sha256 == $coordinator and .marker_candidate.sha256 == $marker and
    (.immutable_terminal_inputs | length) == 8 and (.installed_v13_inputs | length) == 6 and
    (.fresh_outputs | keys) == ["abort_receipt","authenticated_peer","authorization","linux_started","terminal","windows_live","windows_started"] and
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
printf 'schema2 abort operation-local offline fixture passed\n'
