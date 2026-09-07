#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
gate=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-gate.py
manifest=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-manifest.json
hermetic=$root/deploy/tests/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-hermetic.py
checker=$root/deploy/check-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh
launcher=$root/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

bash "$checker" >/dev/null
python3 "$hermetic" >/dev/null

source_contract() {
  local candidate=$1
  ! grep -Fq 'run_coordinator' "$candidate" || return 1
  ! grep -Fq 'ReadToEnd' "$candidate" || return 1
  [[ $(grep -Fc 'predecessor["run_query"]' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'coordinator_redispatched": False' "$candidate" || true) == 2 ]] || return 1
  [[ $(grep -Fc 'create_once(query_path, envelope_raw)' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'if envelope_raw != canonical(envelope):' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'marker_query_raw, v2_manifest, authorization_sha, True)' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'envelope, marker_query_raw = validate_query_envelope(' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'if terminal_exists and not query_exists:' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'if stage == "terminal-replay":' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'terminal reattested after handoff; no live census or dispatch' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fxc '        validate_query_envelope(manifest, predecessor, v2_manifest, envelope_raw)' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'validate_terminal(manifest, terminal_raw, args.manifest_sha256, args.gate_sha256,' "$candidate" || true) == 2 ]] || return 1
  [[ $(grep -Fc 'create_once(terminal_path, terminal_raw)' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'allow_approval and path == expected_approval' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'predecessor["validate_post_state"]' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'validate_linux_live(linux, documents)' "$candidate" || true) == 2 ]] || return 1
  [[ $(grep -Fc 'validate_windows_live(windows, manifest, documents)' "$candidate" || true) == 2 ]] || return 1
  [[ $(grep -Fc 'value["deployment_worker_count"] == 0' "$candidate" || true) == 1 ]] || return 1
}

launcher_contract() {
  local candidate=$1 expected=/home/wilf/data/viewflow/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh
  [[ $(grep -Fxc "launcher=$expected" "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fxc "EXPECTED_LAUNCHER_PATH = \"$expected\"" "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc 'if launcher_path != EXPECTED_LAUNCHER_PATH:' "$candidate" || true) == 1 ]] || return 1
}

reject_launcher() {
  local name=$1 old=$2 new=$3 candidate
  candidate=$temporary/$name.sh
  cp -- "$launcher" "$candidate"
  [[ $(grep -Fc "$old" "$candidate" || true) == 1 ]] || { echo "launcher mutation anchor differs" >&2; exit 1; }
  sed -i "s|$old|$new|" "$candidate"
  if launcher_contract "$candidate"; then
    echo "recovery-v3 launcher mutation accepted: $name" >&2
    exit 1
  fi
}

reject_source() {
  local name=$1 expression=$2 candidate
  candidate=$temporary/$name.py
  cp -- "$gate" "$candidate"
  CANDIDATE=$candidate python3 - "$expression" <<'PY'
import os,pathlib,sys
p=pathlib.Path(os.environ["CANDIDATE"]); source=p.read_text()
old,new,count=eval(sys.argv[1])
if source.count(old) != count: raise SystemExit("mutation source anchor count differs")
p.write_text(source.replace(old,new,count))
PY
  if source_contract "$candidate" && VF_OP442_RECOVERY_V3_GATE=$candidate python3 "$hermetic" >/dev/null 2>&1; then
    echo "recovery-v3 negative mutation accepted: $name" >&2
    exit 1
  fi
}

reject_manifest() {
  local name=$1 filter=$2 candidate
  candidate=$temporary/$name.json
  jq "$filter" "$manifest" >"$candidate"; chmod 600 "$candidate"
  cmp -s "$candidate" "$manifest" && { echo "recovery-v3 manifest mutation no-op: $name" >&2; exit 1; }
  if VF_OP442_RECOVERY_V3_MANIFEST=$candidate python3 "$hermetic" >/dev/null 2>&1; then
    echo "recovery-v3 negative manifest mutation accepted: $name" >&2
    exit 1
  fi
}

source_contract "$gate"
launcher_contract "$launcher"
reject_launcher self_path_to_v2 \
  'launcher=/home/wilf/data/viewflow/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh' \
  'launcher=/home/wilf/data/viewflow/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2.sh'
reject_launcher self_path_comparison_removed \
  'if launcher_path != EXPECTED_LAUNCHER_PATH:' \
  'if False:'
reject_source coordinator_dispatch_injected \
  '("marker_query_raw = predecessor[\"run_query\"](v2_manifest, authorization_sha)", "marker_query_raw = predecessor[\"run_coordinator\"](v2_manifest)", 1)'
reject_source query_attribution_true \
  '("coordinator_redispatched\": False", "coordinator_redispatched\": True", 2)'
reject_source query_create_once_bypass \
  '("        create_once(query_path, envelope_raw)", "        pass  # query publication bypass", 1)'
reject_source persisted_query_canonical_bypass \
  '("if envelope_raw != canonical(envelope):", "if False:", 1)'
reject_source nested_replay_receipt_validation_bypass \
  '("        predecessor[\"validate_receipt\"](\n            marker_query_raw, v2_manifest, authorization_sha, True)", "        (lambda *_args: None)(\n            marker_query_raw, v2_manifest, authorization_sha, True)", 1)'
reject_source merged_query_validation_bypass \
  '("    envelope, marker_query_raw = validate_query_envelope(\n        manifest, predecessor, v2_manifest, envelope_raw)", "    envelope = strict_json(envelope_raw, \"unsafe persisted envelope\")\n    marker_query_raw = canonical(envelope.get(\"marker_query\"))", 1)'
reject_source terminal_missing_query_gate_bypass \
  '("if terminal_exists and not query_exists:", "if False:", 1)'
reject_source terminal_replay_fast_path_bypass \
  '("if stage == \"terminal-replay\":", "if False:", 1)'
reject_source terminal_replay_query_validation_bypass \
  '("        validate_query_envelope(manifest, predecessor, v2_manifest, envelope_raw)", "        pass  # persisted query validation bypass", 1)'
reject_source terminal_replay_terminal_validation_bypass \
  '("        validate_terminal(manifest, terminal_raw, args.manifest_sha256, args.gate_sha256,", "        (lambda *_args, **_kwargs: None)(manifest, terminal_raw, args.manifest_sha256, args.gate_sha256,", 1)'
reject_source terminal_create_once_bypass \
  '("    create_once(terminal_path, terminal_raw)", "    pass  # terminal publication bypass", 1)'
reject_source approval_absence_bug \
  '("allow_approval and path == expected_approval", "False", 1)'
reject_source post_state_validation_bypass \
  '("vfdqa_sha, retired = predecessor[\"validate_post_state\"](", "vfdqa_sha, retired = (post[\"durable_vfdqa\"][\"sha256\"], post[\"retired_claim\"][\"path\"])  # bypass\n    if False: predecessor[\"validate_post_state\"](", 1)'
reject_source Linux_live_validation_bypass \
  '("    validate_linux_live(linux, documents)", "    pass  # Linux live bypass", 2)'
reject_source Windows_live_validation_bypass \
  '("    validate_windows_live(windows, manifest, documents)", "    pass  # Windows live bypass", 2)'
reject_source predecessor_approval_schema_bypass \
  '("\"schema_version\": 3,\n        \"state\": \"viewflow-op442-schema5-abort-recovery-v3-execution-approved\"", "\"schema_version\": 2,\n        \"state\": \"viewflow-failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2-execution-approved\"", 1)'
reject_source windows_timeout_reduced '("timeout=120", "timeout=10", 1)'
reject_source windows_worker_gate_bypass \
  '("value[\"deployment_worker_count\"] == 0", "value[\"deployment_worker_count\"] >= 0", 1)'
reject_source windows_stdin_reader \
  '("result = subprocess.run(command, env=ENV, stdin=subprocess.DEVNULL,\n                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)", "result = subprocess.run(command, env=ENV, input=script.encode(\"ascii\"),  # ReadToEnd\n                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)", 1)'

reject_manifest predecessor_v2_approval_hash '.predecessor_v2.approval.sha256 = ("1" * 64)'
reject_manifest predecessor_v2_manifest_hash '.predecessor_v2.manifest.sha256 = ("2" * 64)'
reject_manifest committed_receipt_hash '.committed_v1_outputs.abort_receipt.sha256 = ("3" * 64)'
reject_manifest durable_vfdqa_hash '.post_abort.durable_vfdqa.sha256 = ("4" * 64)'
reject_manifest retired_claim_hash '.post_abort.retired_claim.sha256 = ("5" * 64)'
reject_manifest public_marker_not_absent '.post_abort.public_absent = .post_abort.public_absent[1:]'
reject_manifest reuse_v2_approval '.approval_path = .predecessor_v2.approval.path | .required_absent[2] = .predecessor_v2.approval.path'
reject_manifest overwrite_v1_query '.outputs.query = .required_absent[0] | .required_absent[3] = .required_absent[0]'
reject_manifest unknown_key '.unexpected = true'
reject_manifest windows_task_state '.windows_live.deployment_task_state = "Ready"'

echo '442fe737 schema5 abort recovery-v3 static-negative tests passed'
