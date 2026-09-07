#!/usr/bin/env bash
# Hermetic crash/replay coverage for the P/H preparation helper.  The helper
# itself is copied into a private root and its fixed paths are rewritten; no
# live marker, user unit, or network endpoint is touched.

set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly source_script=${1:-$script_dir/../prepare-v13-marker-handoff.sh}

fail() { printf 'prepare handoff resume fixture failed: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | awk '{print tolower($1)}'; }

[[ $(id -u) == 1000 && $HOME == /home/wilf ]] || fail 'fixture requires production uid/HOME'
[[ -f $source_script && ! -L $source_script ]] || fail 'unsafe helper source'

fixture_root=$(mktemp -d)
chmod 0700 "$fixture_root"
trap 'rm -rf -- "$fixture_root"' EXIT

operation=resume-handoff-0001
source_id=00000000-0000-0000-0000-000000000101
target_id=00000000-0000-0000-0000-000000000002
coordinator_id=11111111-1111-1111-1111-111111111111

case_root='' helper='' candidate='' candidate_sha='' marker='' intent='' receipt='' handoff=''

make_case() {
    local name=$1 root
    root=$fixture_root/$name
    mkdir -p "$root/lib/deskflow" "$root/state" "$root/receipt" "$root/bin"
    chmod 0755 "$root/lib"
    chmod 0700 "$root/state" "$root/receipt"
    cp -- /usr/bin/true "$root/lib/deskflow/deskflow"
    cp -- /usr/bin/true "$root/lib/deskflow/deskflow-core"
    chmod 0755 "$root/lib/deskflow/deskflow" "$root/lib/deskflow/deskflow-core"
    cat >"$root/bin/systemctl" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *' is-active '* ]]; then printf 'inactive\n'; exit 3; fi
if [[ " $* " == *' MainPID '* ]]; then printf '0\n'; exit 0; fi
exit 64
SH
    cat >"$root/bin/ss" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat >"$root/bin/mv" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source_path=${@: -2:1}
if [[ ${RACE_SWAP_SOURCE:-0} == 1 && $source_path == *'.viewflow-publish.'* ]]; then
    /usr/bin/mv -- "$source_path" "$source_path.race-original"
    printf 'replacement-dentry\n' >"$source_path"
    chmod 0600 "$source_path"
fi
if [[ ${RACE_MUTATE_MARKER:-0} == 1 && $source_path == *'.viewflow-publish.'* ]]; then
    printf '\001' | dd of="$MOCK_DEPLOYMENT_MARKER" bs=1 seek=160 conv=notrunc status=none
fi
if [[ ${RACE_SWAP_CANDIDATE:-0} == 1 && $source_path == *'.viewflow-marker-cli.'* ]]; then
    /usr/bin/mv -- "$source_path" "$source_path.race-original"
    printf 'replacement-cli-dentry\n' >"$source_path"
    chmod 0755 "$source_path"
fi
exec /usr/bin/mv "$@"
SH
    chmod 0755 "$root/bin/systemctl" "$root/bin/ss" "$root/bin/mv"
    candidate=$root/candidate-marker
    cat >"$candidate" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == publish ]] || exit 64
shift
operation='' source='' target='' coordinator='' generation=''
while (($#)); do
    case $1 in
        --operation-id) operation=$2; shift 2 ;;
        --source-display-id) source=$2; shift 2 ;;
        --target-device-id) target=$2; shift 2 ;;
        --coordinator-instance-id) coordinator=$2; shift 2 ;;
        --marker-generation) generation=$2; shift 2 ;;
        *) exit 64 ;;
    esac
done
python3 - "$MOCK_DEPLOYMENT_MARKER" "$operation" "$source" "$target" "$coordinator" "$generation" <<'PY'
import hashlib, json, os, sys
path, op, source, target, coordinator, generation = sys.argv[1:]
data = bytearray(256)
data[:13] = b'VFDQT001\x01\x01\x02\x01\x01'
data[13] = len(op)
data[16:16+len(op)] = op.encode('ascii')
data[144:160] = bytes.fromhex(source.replace('-', ''))
data[160:176] = bytes.fromhex(target.replace('-', ''))
data[176:192] = bytes.fromhex(coordinator.replace('-', ''))
created = 1788048000123
data[192:200] = created.to_bytes(8, 'little')
data[200:208] = int(generation).to_bytes(8, 'little')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as f:
    f.write(data); f.flush(); os.fsync(f.fileno())
print(json.dumps({
  'schema_version': 1, 'state': 'deployment-quarantine-published',
  'protocol_version': '2.1', 'operation_id': op, 'source_display_id': source,
  'target_device_id': target, 'coordinator_instance_id': coordinator,
  'marker_generation': generation, 'marker_path': path,
  'marker_sha256': hashlib.sha256(data).hexdigest(),
  'created_at_unix_ms': str(created), 'created_at_utc': '2026-08-29T20:00:00.123Z'}))
PY
SH
    chmod 0755 "$candidate"
    candidate_sha=$(sha256 "$candidate")
    helper=$root/prepare.sh
    cp -- "$source_script" "$helper"
    marker=$root/state/viewflow/deployment-quarantine.v1
    sed -i \
        -e "s|^readonly MARKER_CLI=.*|readonly MARKER_CLI=$root/lib/viewflow/viewflow-deployment-marker|" \
        -e "s|^readonly MARKER_CLI_DIR=.*|readonly MARKER_CLI_DIR=$root/lib/viewflow|" \
        -e "s|^readonly MARKER_CLI_PARENT=.*|readonly MARKER_CLI_PARENT=$root/lib|" \
        -e "s|^readonly DEPLOYMENT_MARKER=.*|readonly DEPLOYMENT_MARKER=$marker|" \
        -e "s|^readonly MARKER_STATE_DIR=.*|readonly MARKER_STATE_DIR=$root/state/viewflow|" \
        -e "s|^readonly MARKER_STATE_PARENT=.*|readonly MARKER_STATE_PARENT=$root/state|" \
        -e "s|^readonly RUNTIME_MARKER=.*|readonly RUNTIME_MARKER=$root/state/viewflow/deskflow-quarantine.v2|" \
        -e "s|^readonly DESKFLOW_INSTALLED=.*|readonly DESKFLOW_INSTALLED=$root/lib/deskflow/deskflow|" \
        -e "s|^readonly DESKFLOW_CORE_INSTALLED=.*|readonly DESKFLOW_CORE_INSTALLED=$root/lib/deskflow/deskflow-core|" \
        -e "s|^readonly PATH=.*|readonly PATH=$root/bin:/usr/bin:/bin|" "$helper"
    chmod 0700 "$helper"
    receipt=$root/receipt/publish.json
    handoff=$root/receipt/handoff.json
    intent=$root/state/viewflow/.prepare-v13-marker-handoff.$(
        printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\n' \
            "$operation" "$source_id" "$target_id" "$coordinator_id" 1 "$candidate_sha" "$receipt" "$handoff" |
            sha256sum | awk '{print tolower($1)}').intent.json
    export MOCK_DEPLOYMENT_MARKER=$marker
}

run_helper() {
    "$helper" --deployment-marker-candidate "$candidate" --deployment-marker-sha256 "$candidate_sha" \
        --operation-id "$operation" --source-display-id "$source_id" --target-device-id "$target_id" \
        --coordinator-instance-id "$coordinator_id" --marker-generation 1 \
        --deployment-publish-receipt "$receipt" --bootstrap-handoff-receipt "$handoff"
}

run_killed_after_marker() {
    local killed=$case_root/killed-after-marker.sh status
    cp -- "$helper" "$killed"
    sed -i '/--marker-generation "\$marker_generation" >"\$receipt_temp"/a kill -KILL "$$"' "$killed"
    chmod 0700 "$killed"
    set +e
    "$killed" --deployment-marker-candidate "$candidate" --deployment-marker-sha256 "$candidate_sha" \
        --operation-id "$operation" --source-display-id "$source_id" --target-device-id "$target_id" \
        --coordinator-instance-id "$coordinator_id" --marker-generation 1 \
        --deployment-publish-receipt "$receipt" --bootstrap-handoff-receipt "$handoff" >/dev/null 2>&1
    status=$?
    set -e
    [[ $status == 137 ]] || fail "marker-window SIGKILL exit is $status"
}

run_killed_after_p() {
    local killed=$case_root/killed-after-p.sh status
    cp -- "$helper" "$killed"
    sed -i '/^publish_bootstrap_handoff_receipt$/s/.*/kill -KILL "$$"/' "$killed"
    chmod 0700 "$killed"
    set +e
    "$killed" --deployment-marker-candidate "$candidate" --deployment-marker-sha256 "$candidate_sha" \
        --operation-id "$operation" --source-display-id "$source_id" --target-device-id "$target_id" \
        --coordinator-instance-id "$coordinator_id" --marker-generation 1 \
        --deployment-publish-receipt "$receipt" --bootstrap-handoff-receipt "$handoff" >/dev/null 2>&1
    status=$?
    set -e
    [[ $status == 137 ]] || fail "P-window SIGKILL exit is $status"
}

run_killed_before_h_link() {
    local killed=$case_root/killed-before-h-link.sh status
    cp -- "$helper" "$killed"
    sed -i "/^    write_create_once_json 'bootstrap handoff receipt'/i kill -KILL \"\$\$\"" "$killed"
    chmod 0700 "$killed"
    set +e
    "$killed" --deployment-marker-candidate "$candidate" --deployment-marker-sha256 "$candidate_sha" \
        --operation-id "$operation" --source-display-id "$source_id" --target-device-id "$target_id" \
        --coordinator-instance-id "$coordinator_id" --marker-generation 1 \
        --deployment-publish-receipt "$receipt" --bootstrap-handoff-receipt "$handoff" >/dev/null 2>&1
    status=$?
    set -e
    [[ $status == 137 ]] || fail "H-temp SIGKILL exit is $status"
}

assert_complete() {
    [[ -f $marker && -f $intent && -f $receipt && -f $handoff ]] || fail 'expected marker/intent/P/H missing'
}

case_root=$fixture_root/clean
make_case clean
run_helper >/dev/null
assert_complete
clean_marker_sha=$(sha256 "$marker")
clean_p_sha=$(sha256 "$receipt")
clean_h_sha=$(sha256 "$handoff")
clean_p_inode=$(stat -Lc '%d:%i' -- "$receipt")
clean_h_inode=$(stat -Lc '%d:%i' -- "$handoff")
run_helper >/dev/null
[[ $(sha256 "$marker") == "$clean_marker_sha" && $(sha256 "$receipt") == "$clean_p_sha" &&
   $(sha256 "$handoff") == "$clean_h_sha" && $(stat -Lc '%d:%i' -- "$receipt") == "$clean_p_inode" &&
   $(stat -Lc '%d:%i' -- "$handoff") == "$clean_h_inode" ]] || fail 'exact replay was not stable/no-clobber'

case_root=$fixture_root/marker-window
make_case marker-window
run_killed_after_marker
[[ -f $marker && -f $intent && ! -e $receipt && ! -e $handoff ]] ||
    fail 'marker-before-P window was not established'
marker_window_sha=$(sha256 "$marker")
run_helper >/dev/null
assert_complete
[[ $(sha256 "$marker") == "$marker_window_sha" ]] || fail 'marker was replaced during P recovery'

case_root=$fixture_root/partial-temp
make_case partial-temp
run_killed_after_marker
run_helper >/dev/null
assert_complete

case_root=$fixture_root/p-window
make_case p-window
run_killed_after_p
[[ -f $marker && -f $intent && -f $receipt && ! -e $handoff ]] || fail 'P-before-H window was not established'
p_window_sha=$(sha256 "$receipt")
run_helper >/dev/null
assert_complete
[[ $(sha256 "$receipt") == "$p_window_sha" ]] || fail 'P was replaced during H recovery'

case_root=$fixture_root/h-temp-window
make_case h-temp-window
run_killed_before_h_link
[[ -f $marker && -f $intent && -f $receipt && ! -e $handoff ]] || fail 'valid H temporary window was not established'
run_helper >/dev/null
assert_complete

case_root=$fixture_root/identity-mismatch
make_case identity-mismatch
run_killed_after_marker
printf '\001' | dd of="$marker" bs=1 seek=160 conv=notrunc status=none
set +e
run_helper >/dev/null 2>&1
status=$?
set -e
[[ $status != 0 && ! -e $receipt && ! -e $handoff ]] || fail 'mismatched active marker was accepted'

case_root=$fixture_root/dentry-swap
make_case dentry-swap
set +e
RACE_SWAP_SOURCE=1 run_helper >/dev/null 2>&1
status=$?
set -e
[[ $status != 0 && -f $receipt && $(<"$receipt") == replacement-dentry ]] ||
    fail 'pre-rename dentry swap was not retained and rejected'

case_root=$fixture_root/same-inode-marker-mutation
make_case same-inode-marker-mutation
set +e
RACE_MUTATE_MARKER=1 run_helper >/dev/null 2>&1
status=$?
set -e
[[ $status != 0 && -f $receipt ]] || fail 'same-inode VFDQT001 content mutation was accepted'

case_root=$fixture_root/candidate-dentry-swap
make_case candidate-dentry-swap
set +e
RACE_SWAP_CANDIDATE=1 run_helper >/dev/null 2>&1
status=$?
set -e
installed_cli=$case_root/lib/viewflow/viewflow-deployment-marker
[[ $status != 0 && -f $installed_cli && $(<"$installed_cli") == replacement-cli-dentry ]] ||
    fail 'candidate CLI dentry swap was not retained and rejected'

printf 'prepare marker handoff resumable SIGKILL fixture passed\n'
