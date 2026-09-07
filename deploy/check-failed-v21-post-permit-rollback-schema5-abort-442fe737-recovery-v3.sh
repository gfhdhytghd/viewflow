#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
manifest=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-manifest.json
gate=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-gate.py
launcher=$root/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh
publisher=$root/deploy/publish-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-approval.py
op=442fe737e67f43b89d85a7e33149a072

python3 - "$gate" "$publisher" <<'PY'
import pathlib,sys
for path in sys.argv[1:]:
    compile(pathlib.Path(path).read_bytes(), path, "exec")
source = pathlib.Path(sys.argv[1]).read_text()
terminal = source.index('    if stage == "terminal-replay":')
post_terminal_live = source.rindex('    linux = linux_live_census(documents)')
if terminal >= post_terminal_live or '        return\n    linux = linux_live_census(documents)' not in source:
    raise SystemExit("terminal replay is not isolated from mutable live census")
PY
bash -n "$launcher"
[[ $(grep -Fxc 'launcher=/home/wilf/data/viewflow/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh' "$launcher") == 1 ]]
[[ $(grep -Fxc 'EXPECTED_LAUNCHER_PATH = "/home/wilf/data/viewflow/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh"' "$launcher") == 1 ]]
rg -F --quiet 'if launcher_path != EXPECTED_LAUNCHER_PATH:' "$launcher"

jq -e --arg op "$op" '
  keys == ["approval_path","committed_v1_outputs","execution_authorized","operation_id",
           "outputs","post_abort","predecessor_v2","required_absent","schema_version",
           "state","windows_live"] and
  .schema_version == 3 and
  .state == "viewflow-op442-schema5-abort-post-commit-recovery-v3-command-manifest" and
  .execution_authorized == false and .operation_id == $op and
  (.predecessor_v2 | keys == ["approval","gate","launcher","manifest"]) and
  .predecessor_v2.approval.sha256 == "e741232ce133ac10fc0dafa7b130caa5ec2ba7b2132f8374eb01bf82ac66518e" and
  .predecessor_v2.manifest.sha256 == "8f32caf593fd1a4255ef24e0dde08d8c65be424848d2310d96b3155d67c2ada6" and
  .predecessor_v2.gate.sha256 == "4d626a8db720d4152b99381d14d09f6c95a0ffdb145457a325a986f9125c27d6" and
  .predecessor_v2.launcher.sha256 == "094f0fac1a6285f03bd791eea4682a6f9e625c43fe29ac937fa6c7e427399f39" and
  (.committed_v1_outputs | keys == ["abort_receipt","authenticated_v13_peer",
    "authorization","linux_v13_started","transition","windows_v13_started"]) and
  .post_abort.durable_vfdqa.sha256 == "c5a4b7b0900f8907087c65724f630b474facd894d4bf23749b562ea7af967b19" and
  .post_abort.retired_claim.sha256 == "a336070106802153c9834154ab493b22a19eeb434ebed1e77000e44aa9ba5000" and
  .post_abort.public_absent == [.post_abort.marker_path,
    (.post_abort.marker_path + ".abort-claim"),(.post_abort.marker_path + ".release-claim")] and
  .outputs == {query:("/home/wilf/.local/state/viewflow/deployments/"+$op+
    "/schema5-abort-442fe737-recovery-v3-query.json"),terminal:("/home/wilf/.local/state/viewflow/deployments/"+$op+
    "/schema5-abort-442fe737-recovery-v3-terminal.json")} and
  (.predecessor_v2.approval.path as $old | .required_absent | index($old)) == null
' "$manifest" >/dev/null

for token in \
  'predecessor["run_query"]' \
  'coordinator_redispatched": False' \
  'marker_query_replayed": True' \
  'create_once(query_path, envelope_raw)' \
  'def validate_query_envelope' \
  'if envelope_raw != canonical(envelope):' \
  'marker_query_raw, v2_manifest, authorization_sha, True)' \
  'envelope, marker_query_raw = validate_query_envelope(' \
  'def recovery_stage' \
  'if terminal_exists and not query_exists:' \
  'if stage == "terminal-replay":' \
  'validate_terminal(manifest, terminal_raw' \
  'terminal reattested after handoff; no live census or dispatch' \
  'create_once(terminal_path, terminal_raw)' \
  'validate_recovery_approval' \
  'validate_post_state' \
  'durable VFDQA' \
  'retired claim' \
  'allow_approval and path == expected_approval' \
  'gzip.compress' \
  '[IO.Compression.CompressionMode]::Decompress' \
  'stdin=subprocess.DEVNULL' \
  'timeout=120'; do
  rg -F --quiet "$token" "$gate"
done
if rg -F --quiet 'run_coordinator' "$gate"; then
  echo 'recovery-v3 gate contains forbidden coordinator dispatch' >&2
  exit 1
fi
if rg -F --quiet 'ReadToEnd' "$gate"; then
  echo 'recovery-v3 gate contains forbidden PowerShell stdin reader' >&2
  exit 1
fi

while IFS=$'\t' read -r path expected mode size; do
  [[ -f $path && ! -L $path ]]
  [[ $(sha256sum "$path" | cut -d' ' -f1) == "$expected" ]]
  [[ $(stat -c '%u:%a:%h:%s' -- "$path") == "1000:$mode:1:$size" ]]
done < <(jq -r '
  (.predecessor_v2[] | [.path,.sha256,(.mode|tostring),(.size|tostring)]),
  (.committed_v1_outputs[] | [.path,.sha256,(.mode|tostring),(.size|tostring)]),
  (.post_abort.durable_vfdqa | [.path,.sha256,(.mode|tostring),(.size|tostring)]),
  (.post_abort.retired_claim | [.path,.sha256,(.mode|tostring),(.size|tostring)]) | @tsv
' "$manifest")

while IFS= read -r path; do [[ ! -e $path && ! -L $path ]]; done \
  < <(jq -r '.post_abort.public_absent[],.required_absent[]' "$manifest")

manifest_sha=$(sha256sum "$manifest" | cut -d' ' -f1)
gate_sha=$(sha256sum "$gate" | cut -d' ' -f1)
launcher_sha=$(sha256sum "$launcher" | cut -d' ' -f1)
[[ $manifest_sha == 1038b5add1d420210befe78756d0daa9963febf0daa878fc2079d4011dc0806d ]]
rg -F --quiet "MANIFEST_SHA = \"$manifest_sha\"" "$launcher" "$publisher"
rg -F --quiet "GATE_SHA = \"$gate_sha\"" "$launcher" "$publisher"
rg -F --quiet "LAUNCHER_SHA = \"$launcher_sha\"" "$publisher"

"$launcher" --offline-check
"$publisher" --check-only
echo '442fe737 schema5 abort recovery-v3 static checker passed'
