#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
checker=$root/deploy/check-failed-v21-rollback-abort-845ce422-v2.sh
manifest=$root/deploy/failed-v21-rollback-abort-845ce422-v2-manifest.json
gate=$root/deploy/failed-v21-rollback-abort-845ce422-v2-gate.py
launcher=$root/deploy/launch-failed-v21-rollback-abort-845ce422-v2.sh
publisher=$root/deploy/publish-failed-v21-rollback-abort-845ce422-v2-approval.py
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

reset_set() {
  cp -- "$manifest" "$tmp/manifest"
  cp -- "$gate" "$tmp/gate"
  cp -- "$launcher" "$tmp/launcher"
  cp -- "$publisher" "$tmp/publisher"
}

must_change() {
  local file=$1 old=$2 new=$3 before after
  before=$(sha256sum "$file" | cut -d' ' -f1)
  sed -i "s|$old|$new|" "$file"
  after=$(sha256sum "$file" | cut -d' ' -f1)
  [[ $before != "$after" ]] || { echo "no-op mutation: $old" >&2; exit 1; }
}

expect_reject() {
  if VF_ABORT_MANIFEST=$tmp/manifest VF_ABORT_GATE=$tmp/gate \
      VF_ABORT_LAUNCHER=$tmp/launcher VF_ABORT_PUBLISHER=$tmp/publisher \
      "$checker" >/dev/null 2>&1; then
    echo 'checker accepted mutated abort set' >&2
    exit 1
  fi
}

expect_parser_reject() {
  if VF_ABORT_PARSER_ONLY=1 VF_ABORT_MANIFEST=$tmp/manifest \
      VF_ABORT_GATE=$tmp/gate VF_ABORT_LAUNCHER=$tmp/launcher \
      VF_ABORT_PUBLISHER=$tmp/publisher "$checker" >/dev/null 2>&1; then
    echo 'real coordinator parser accepted mutated abort argv' >&2
    exit 1
  fi
}

resign_gate_and_launcher() {
  local gate_sha launcher_sha
  gate_sha=$(sha256sum "$tmp/gate" | cut -d' ' -f1)
  sed -Ei "s|^GATE_SHA = \"[0-9a-f]{64}\"|GATE_SHA = \"$gate_sha\"|" "$tmp/launcher" "$tmp/publisher"
  launcher_sha=$(sha256sum "$tmp/launcher" | cut -d' ' -f1)
  sed -Ei "s|^LAUNCHER_SHA = \"[0-9a-f]{64}\"|LAUNCHER_SHA = \"$launcher_sha\"|" "$tmp/publisher"
}

resign_launcher() {
  local launcher_sha
  launcher_sha=$(sha256sum "$tmp/launcher" | cut -d' ' -f1)
  sed -Ei "s|^LAUNCHER_SHA = \"[0-9a-f]{64}\"|LAUNCHER_SHA = \"$launcher_sha\"|" "$tmp/publisher"
}

resign_manifest_and_launcher() {
  local manifest_sha launcher_sha
  manifest_sha=$(sha256sum "$tmp/manifest" | cut -d' ' -f1)
  sed -Ei "s|^MANIFEST_SHA = \"[0-9a-f]{64}\"|MANIFEST_SHA = \"$manifest_sha\"|" "$tmp/launcher" "$tmp/publisher"
  launcher_sha=$(sha256sum "$tmp/launcher" | cut -d' ' -f1)
  sed -Ei "s|^LAUNCHER_SHA = \"[0-9a-f]{64}\"|LAUNCHER_SHA = \"$launcher_sha\"|" "$tmp/publisher"
}

reset_set
must_change "$tmp/manifest" '6e50c84886895959b954c7b4fa682258c4484e47f3663741ead4d1fb5f74b995' "$(printf '0%.0s' {1..64})"
expect_reject

reset_set
python3 - "$tmp/manifest" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_bytes())
value["argv"].append("--definitely-unknown-v2-option")
path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
PY
expect_parser_reject

reset_set
must_change "$tmp/manifest" '"old_task_pre_state": "Ready"' '"old_task_pre_state": "Running"'
expect_reject

reset_set
must_change "$tmp/manifest" '"deployment_task_state": "Disabled"' '"deployment_task_state": "Ready"'
expect_reject

reset_set
must_change "$tmp/manifest" '"size": 5643' '"size": 5644'
resign_manifest_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'never redispatch' 'always redispatch'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" '0101010301000000' '0101010302000000'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'committed_ms == int(receipt\["abort_committed_at_unix_ms"\])' 'committed_ms != int(receipt["abort_committed_at_unix_ms"])'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'raw\[344:352\] == b"\\0" \* 8' 'raw[344:352] != b"\\0" * 8'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'if os.path.lexists(outputs\["authorization"\]):' 'if False and os.path.lexists(outputs["authorization"]):'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'locked_hook()' 'locked_hook(); return'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" '"LogLevel=ERROR"' '"LogLevel=INFO"'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'input=script' 'input=b""'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'result.returncode != 0 or result.stderr' 'result.returncode != 0 or False'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'members == w\["exact_members"\]' 'set(names) == set(w["required_members"])'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/gate" 'Windows operation root changed across abort' 'Windows operation root ignored'
resign_gate_and_launcher
expect_reject

reset_set
must_change "$tmp/launcher" 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' 'DBUS_SESSION_BUS_ADDRESS=disabled'
resign_launcher
expect_reject

reset_set
must_change "$tmp/publisher" 'renameat2' 'renameat'
expect_reject

"$checker"
echo '845ce422 abort v2 static negative mutations passed'
