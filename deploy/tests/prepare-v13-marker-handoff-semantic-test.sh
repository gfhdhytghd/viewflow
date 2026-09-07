#!/usr/bin/env bash

set -euo pipefail
readonly PATH=/usr/bin:/bin
export PATH

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly source_script=${1:-$script_dir/../prepare-v13-marker-handoff.sh}

fail() { printf 'bootstrap marker handoff semantic test failed: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | awk '{print $1}'; }

[[ $(id -u) == 1000 && $HOME == /home/wilf ]] || fail 'fixture requires the production uid/HOME identity'
[[ -f $source_script && ! -L $source_script ]] || fail 'unsafe handoff source'

test_root=$(mktemp -d)
chmod 0700 "$test_root"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/lib/deskflow" "$test_root/state" "$test_root/receipt" "$test_root/bin"
chmod 0755 "$test_root/lib"
chmod 0700 "$test_root/state" "$test_root/receipt"

helper=$test_root/prepare.sh
candidate=$test_root/candidate-marker
installed_dir=$test_root/lib/viewflow
installed=$installed_dir/viewflow-deployment-marker
state_dir=$test_root/state/viewflow
marker=$state_dir/deployment-quarantine.v1
runtime_marker=$state_dir/deskflow-quarantine.v2
deskflow=$test_root/lib/deskflow/deskflow
deskflow_core=$test_root/lib/deskflow/deskflow-core
receipt=$test_root/receipt/deployment-publish.json
handoff=$test_root/receipt/bootstrap-handoff.json
second_receipt=$test_root/receipt/second.json
second_handoff=$test_root/receipt/second-handoff.json

cp -- /usr/bin/true "$deskflow"
cp -- /usr/bin/true "$deskflow_core"
chmod 0755 "$deskflow" "$deskflow_core"

cp -- "$source_script" "$helper"
sed -i \
    -e "s|^readonly MARKER_CLI=.*|readonly MARKER_CLI=$installed|" \
    -e "s|^readonly MARKER_CLI_DIR=.*|readonly MARKER_CLI_DIR=$installed_dir|" \
    -e "s|^readonly MARKER_CLI_PARENT=.*|readonly MARKER_CLI_PARENT=$test_root/lib|" \
    -e "s|^readonly DEPLOYMENT_MARKER=.*|readonly DEPLOYMENT_MARKER=$marker|" \
    -e "s|^readonly MARKER_STATE_DIR=.*|readonly MARKER_STATE_DIR=$state_dir|" \
    -e "s|^readonly MARKER_STATE_PARENT=.*|readonly MARKER_STATE_PARENT=$test_root/state|" \
    -e "s|^readonly RUNTIME_MARKER=.*|readonly RUNTIME_MARKER=$runtime_marker|" \
    -e "s|^readonly DESKFLOW_INSTALLED=.*|readonly DESKFLOW_INSTALLED=$deskflow|" \
    -e "s|^readonly DESKFLOW_CORE_INSTALLED=.*|readonly DESKFLOW_CORE_INSTALLED=$deskflow_core|" \
    -e "s|^readonly PATH=.*|readonly PATH=$test_root/bin:/usr/bin:/bin|" \
    "$helper"
chmod 0700 "$helper"

cat >"$test_root/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' is-active '* ]]; then printf 'inactive\n'; exit 3; fi
if [[ " $* " == *' MainPID '* ]]; then printf '0\n'; exit 0; fi
exit 64
SH
cat >"$test_root/bin/ss" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0755 "$test_root/bin/systemctl" "$test_root/bin/ss"

cat >"$candidate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == publish ]]
shift
operation= source= target= coordinator= generation=
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
[[ ! -e $MOCK_DEPLOYMENT_MARKER ]]
python3 - "$MOCK_DEPLOYMENT_MARKER" "$operation" "$source" "$target" "$coordinator" "$generation" <<'PY'
import os, sys
path, operation, source, target, coordinator, generation = sys.argv[1:]
marker = bytearray(256)
marker[:13] = b'VFDQT001\x01\x01\x02\x01\x01'
marker[13] = len(operation)
marker[16:16 + len(operation)] = operation.encode('ascii')
marker[144:160] = bytes.fromhex(source.replace('-', ''))
marker[160:176] = bytes.fromhex(target.replace('-', ''))
marker[176:192] = bytes.fromhex(coordinator.replace('-', ''))
marker[192:200] = (1788048000123).to_bytes(8, 'little')
marker[200:208] = int(generation).to_bytes(8, 'little')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as output:
    output.write(marker)
    output.flush()
    os.fsync(output.fileno())
PY
marker_sha=$(sha256sum -- "$MOCK_DEPLOYMENT_MARKER" | awk '{print $1}')
jq -cn --arg op "$operation" --arg source "$source" --arg target "$target" \
    --arg coordinator "$coordinator" --arg generation "$generation" \
    --arg path "$MOCK_DEPLOYMENT_MARKER" --arg sha "$marker_sha" \
    '{schema_version:1,state:"deployment-quarantine-published",protocol_version:"2.1",operation_id:$op,source_display_id:$source,target_device_id:$target,coordinator_instance_id:$coordinator,marker_generation:$generation,marker_path:$path,marker_sha256:$sha,created_at_unix_ms:"1788048000000",created_at_utc:"2026-08-29T20:00:00.000Z"}'
SH
chmod 0755 "$candidate"
candidate_sha=$(sha256 "$candidate")
export MOCK_DEPLOYMENT_MARKER=$marker

operation=bootstrap-handoff-0001
source_id=00000000-0000-0000-0000-000000000101
target_id=00000000-0000-0000-0000-000000000002
coordinator_id=11111111-1111-1111-1111-111111111111

run_helper() {
    local output=$1 handoff_output=$2
    "$helper" \
        --deployment-marker-candidate "$candidate" \
        --deployment-marker-sha256 "$candidate_sha" \
        --operation-id "$operation" \
        --source-display-id "$source_id" \
        --target-device-id "$target_id" \
        --coordinator-instance-id "$coordinator_id" \
        --marker-generation 1 \
        --deployment-publish-receipt "$output" \
        --bootstrap-handoff-receipt "$handoff_output"
}

run_helper "$receipt" "$handoff" >/dev/null
[[ -f $installed && ! -L $installed && $(stat -c '%u:%a:%h' -- "$installed") == 1000:755:1 &&
   $(sha256 "$installed") == "$candidate_sha" ]] || fail 'fixed CLI installation proof failed'
[[ -d $state_dir && ! -L $state_dir && $(stat -c '%u:%a' -- "$state_dir") == 1000:700 ]] ||
    fail 'fixed owner-only state directory proof failed'
[[ -f $marker && ! -L $marker && $(stat -c '%u:%a:%h:%s' -- "$marker") == 1000:600:1:256 ]] ||
    fail 'VFDQT001 metadata proof failed'
[[ -f $receipt && ! -L $receipt && $(stat -c '%u:%a:%h' -- "$receipt") == 1000:600:1 ]] ||
    fail 'create-once receipt metadata proof failed'
[[ -f $handoff && ! -L $handoff && $(stat -c '%u:%a:%h' -- "$handoff") == 1000:600:1 ]] ||
    fail 'create-once H receipt metadata proof failed'
jq -e --arg op "$operation" --arg source "$source_id" --arg target "$target_id" \
    --arg coordinator "$coordinator_id" --arg marker "$marker" \
    '.operation_id == $op and .source_display_id == $source and .target_device_id == $target and
     .coordinator_instance_id == $coordinator and .marker_generation == "1" and
     .marker_path == $marker and (.marker_sha256 | test("^[0-9a-f]{64}$"))' \
    "$receipt" >/dev/null || fail 'receipt binding proof failed'
jq -e --arg publish_sha "$(sha256 "$receipt")" --arg deskflow_sha "$(sha256 "$deskflow")" \
    --arg core_sha "$(sha256 "$deskflow_core")" '
    .state == "viewflow-v13-marker-handoff-prepared" and
    .deployment_publish_receipt_sha256 == $publish_sha and
    .deskflow_unit_active_state == "inactive" and .deskflow_unit_main_pid == 0 and
    .deskflow_executable_sha256 == $deskflow_sha and .deskflow_exact_process_count == 0 and
    .deskflow_core_executable_sha256 == $core_sha and .deskflow_core_exact_process_count == 0 and
    .deskflow_tcp_listener_count == 0 and .runtime_marker_present == false
' "$handoff" >/dev/null || fail 'H receipt frozen-boundary proof failed'

marker_sha_before=$(sha256 "$marker")
receipt_sha_before=$(sha256 "$receipt")
handoff_sha_before=$(sha256 "$handoff")
if run_helper "$second_receipt" "$second_handoff" >/dev/null 2>&1; then
    fail 'second generation-1 publication unexpectedly succeeded'
fi
[[ ! -e $second_receipt && ! -e $second_handoff && $(sha256 "$marker") == "$marker_sha_before" &&
   $(sha256 "$receipt") == "$receipt_sha_before" && $(sha256 "$handoff") == "$handoff_sha_before" ]] ||
    fail 'failed duplicate publication mutated the durable handoff'

printf 'bootstrap marker handoff semantic test passed\n'
