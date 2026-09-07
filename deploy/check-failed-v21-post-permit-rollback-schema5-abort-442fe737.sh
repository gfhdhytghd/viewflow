#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
manifest=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-manifest.json
gate=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-gate.py
launcher=$root/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737.sh
publisher=$root/deploy/publish-failed-v21-post-permit-rollback-schema5-abort-442fe737-approval.py
op=442fe737e67f43b89d85a7e33149a072

python3 - "$gate" "$publisher" <<'PY'
import pathlib
import sys
for name in sys.argv[1:]:
    compile(pathlib.Path(name).read_bytes(), name, "exec")
PY
bash -n "$launcher"

# Exercise the real option parser in a temporary copy that exits exactly at the
# parser boundary.  It cannot reach preflight, systemd, SSH, or marker code.
python3 - "$manifest" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import tempfile

manifest = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
coordinator = pathlib.Path(manifest["coordinator"]["path"])
argv = manifest["argv"]
source = coordinator.read_text(encoding="utf-8")
needle = "\ndone\n\nrequire_windows_absolute_path() {"
if source.count(needle) != 1:
    raise SystemExit("coordinator parser boundary differs")
probe = source.replace(needle, "\ndone\nexit 0\n\nrequire_windows_absolute_path() {", 1)
fd, name = tempfile.mkstemp(prefix="viewflow-op442-parser-", suffix=".sh")
try:
    os.fchmod(fd, 0o700)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(probe)
        handle.flush()
        os.fsync(handle.fileno())
    result = subprocess.run(["/usr/bin/bash", name, *argv[1:]],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=15, env={"HOME": "/home/wilf", "USER": "wilf", "LOGNAME": "wilf",
                         "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"})
    if result.returncode != 0:
        raise SystemExit("coordinator rejected sealed manifest argv: "
                         + result.stderr.decode("utf-8", "replace"))
finally:
    try:
        os.unlink(name)
    except FileNotFoundError:
        pass
PY

jq -e --arg op "$op" '
  def argv_value($option): .argv as $items | ($items | index($option)) as $index |
    if $index == null then null else $items[$index + 1] end;
  keys == ["active_marker","approval_path","argv","coordinator","coordinator_instance_id",
           "execution_authorized","immutable_inputs","installed_linux","marker_generation",
           "old_operation_id","operation_id","outputs","recovery_boundary",
           "recovery_marker_generation","required_absent","schema_version","source_display_id",
           "state","target_device_id","windows_expected"] and
  .schema_version == 1 and
  .state == "viewflow-failed-v21-post-permit-rollback-schema5-abort-442fe737-command-manifest" and
  .execution_authorized == false and .operation_id == $op and
  .old_operation_id == "845ce4223e4f426a8a0015d3355595e8" and
  .recovery_boundary == {phase:"WINDOWS_ROLLED_BACK",failure_phase:"MUTATION_PERMITTED",
    mutation_possible:true,force_release_executed:false,rollback_performed:true} and
  .active_marker.magic == "VFDQT001" and .active_marker.size == 256 and
  .immutable_inputs.marker_cli_candidate.sha256 == "82cf372aacfc0d7be9de9fb7552c7ef073c64699e8ee700f7933e4adf1c64d65" and
  .immutable_inputs.marker_cli_provenance.sha256 == "77b8ddee494c6064d49825df5032d80fc12f26b144d8f4604b225fa027858092" and
  argv_value("--schema1-handoff-lineage-receipt-sha256") == .immutable_inputs.schema1_handoff_lineage.sha256 and
  argv_value("--schema1-handoff-abort-marker-cli-candidate") == .immutable_inputs.marker_cli_candidate.path and
  argv_value("--schema1-handoff-abort-marker-cli-sha256") == .immutable_inputs.marker_cli_candidate.sha256 and
  argv_value("--old-coordinator-state-sha256") == .immutable_inputs.coordinator_state.sha256 and
  (.argv | index("--failed-v13-original-generation-only")) != null and
  (.argv | index("--release-deployment-marker")) == null and
  (.argv | index("--resume")) == null and
  ([.outputs[]] | length == (unique | length)) and
  all(.outputs[]; startswith("/home/wilf/.local/state/viewflow/deployments/" + $op +
                            "/schema5-abort-442fe737-"))
' "$manifest" >/dev/null

for token in \
  'name not in {"old_schema1_vfdqa", "linux_deactivation_transcript",' \
  '"marker_cli_candidate"})' \
  'abort-claim-atomic-retire-and-parent-directory-fsync' \
  'schema5 authorization' \
  'schema5 abort receipt' \
  'stable_generated_read' \
  'run_coordinator(manifest)' \
  'if not authorization_exists' \
  'F_SEAL_WRITE' \
  'RENAME_NOREPLACE'; do
  rg -F --quiet "$token" "$gate" "$launcher"
done
for token in \
  'def linux_live_census' \
  'def validate_linux_live_census' \
  'def powershell_live_census' \
  'def windows_live_census' \
  'def validate_powershell_progress_stderr' \
  'def validate_windows_live_census' \
  '"/usr/bin/ssh", "-oLogLevel=ERROR"' \
  '"wilf@172.16.105.70"' \
  'gzip.compress(script.encode("ascii"), compresslevel=9, mtime=0)' \
  'GzipStream' \
  '[IO.Compression.CompressionMode]::Decompress' \
  'ScriptBlock]::Create(' \
  'bootstrap.encode("utf-16le")' \
  '"-NonInteractive", "-EncodedCommand", encoded' \
  'stdin=subprocess.DEVNULL' \
  'len(encoded) > 6_800' \
  'sum(len(item) + 1 for item in command) > 7_000' \
  'timeout=120' \
  'validate_powershell_progress_stderr(result.stderr)' \
  'child.attrib.get("S") != "progress"' \
  'element.attrib.get("S") == "Error"' \
  'critical_receipts' \
  'exact_process_count' \
  'socket_count(24800, True)' \
  'socket_count(44119, False)'; do
  rg -F --quiet "$token" "$gate" "$manifest"
done
if rg -F --quiet 'ReadToEnd' "$gate"; then
  echo '442fe737 gate contains forbidden stdin PowerShell reader transport' >&2
  exit 1
fi

manifest_sha=$(sha256sum "$manifest" | cut -d' ' -f1)
gate_sha=$(sha256sum "$gate" | cut -d' ' -f1)
launcher_sha=$(sha256sum "$launcher" | cut -d' ' -f1)
[[ $manifest_sha == 187f135df50f75f24e16e3ba81fec545946406b552f96a1b25eb03f4bd2b726b ]]
rg -F --quiet "MANIFEST_SHA = \"$manifest_sha\"" "$launcher" "$publisher"
rg -F --quiet "GATE_SHA = \"$gate_sha\"" "$launcher" "$publisher"
rg -F --quiet "LAUNCHER_SHA = \"$launcher_sha\"" "$publisher"

while IFS=$'\t' read -r path expected mode size; do
  [[ -f $path && ! -L $path ]]
  [[ $(sha256sum "$path" | cut -d' ' -f1) == "$expected" ]]
  [[ $(stat -c '%u:%a:%h:%s' -- "$path") == "1000:$mode:1:$size" ]]
done < <(jq -r '
  (.coordinator | [.path,.sha256,(.mode|tostring),(.size|tostring)]),
  (.immutable_inputs[] | [.path,.sha256,(.mode|tostring),(.size|tostring)]),
  (.installed_linux[] | [.path,.sha256,(.mode|tostring),(.size|tostring)]) |
  @tsv' "$manifest")

[[ ! -e $(jq -r .approval_path "$manifest") ]]
while IFS= read -r output; do [[ ! -e $output && ! -L $output ]]; done < <(jq -r '.outputs[]' "$manifest")
"$launcher" --offline-check
"$publisher" --check-only
echo '442fe737 schema5 abort sealed-set static checker passed'
