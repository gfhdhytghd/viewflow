#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
gate=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2-gate.py
manifest=$root/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2-manifest.json
hermetic=$root/deploy/tests/failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2-hermetic.py
checker=$root/deploy/check-failed-v21-post-permit-rollback-schema5-abort-442fe737-successor-v2.sh
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

bash "$checker" >/dev/null
python3 "$hermetic" >/dev/null

source_contract() {
  local candidate=$1
  [[ $(grep -Fc -- '"marker_cli_candidate"})' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'if not authorization_exists:' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fxc -- '        run_coordinator(manifest)' "$candidate" || true) == 2 ]] || return 1
  [[ $(grep -Fc -- 'value.get("force_release_executed") is False' "$candidate" || true) == 2 ]] || return 1
  [[ $(grep -Fc -- 'value.get("rollback_performed") is True' "$candidate" || true) == 2 ]] || return 1
  [[ $(grep -Fxc -- '        validate_linux_live_census(linux)' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fxc -- '        validate_windows_live_census(windows, manifest)' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'timeout=120' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'gzip.compress(script.encode("ascii"), compresslevel=9, mtime=0)' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'bootstrap.encode("utf-16le")' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'GzipStream' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- '[IO.Compression.CompressionMode]::Decompress' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- '"-NonInteractive", "-EncodedCommand", encoded' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- '"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}, stdin=subprocess.DEVNULL,' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'len(encoded) > 6_800' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'sum(len(item) + 1 for item in command) > 7_000' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'validate_powershell_progress_stderr(result.stderr)' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'child.attrib.get("S") != "progress"' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'element.attrib.get("S") == "Error"' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'execution_approval_may_exist and path == value["approval_path"]' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'failed_approval_raw = read_spec(failed["approval"]' "$candidate" || true) == 1 ]] || return 1
  [[ $(grep -Fc -- 'failed["approval"]["path"] in value["required_absent"]' "$candidate" || true) == 1 ]] || return 1
  ! grep -Fq -- 'ReadToEnd' "$candidate"
}

reject_source() {
  local name=$1 expression=$2 candidate
  candidate=$temporary/$name.py
  cp -- "$gate" "$candidate"
  CANDIDATE=$candidate python3 - "$expression" <<'PY'
import os
import pathlib
import sys
path = pathlib.Path(os.environ["CANDIDATE"])
source = path.read_text()
old, new, count = eval(sys.argv[1])
if source.count(old) != count:
    raise SystemExit("mutation source anchor count differs")
path.write_text(source.replace(old, new, count))
PY
  if source_contract "$candidate" && VF_OP442_GATE=$candidate python3 "$hermetic" >/dev/null 2>&1; then
    echo "negative mutation accepted: $name" >&2
    exit 1
  fi
}

reject_manifest() {
  local name=$1 filter=$2 candidate
  candidate=$temporary/$name.json
  jq "$filter" "$manifest" >"$candidate"
  chmod 600 "$candidate"
  if cmp -s "$candidate" "$manifest"; then
    echo "manifest mutation was a no-op: $name" >&2
    exit 1
  fi
  if VF_OP442_MANIFEST=$candidate python3 "$hermetic" >/dev/null 2>&1; then
    echo "negative manifest mutation accepted: $name" >&2
    exit 1
  fi
}

source_contract "$gate"
reject_source candidate_treated_as_json \
  '("\"marker_cli_candidate\"})", "\"old_schema1_vfdqa\"})", 1)'
reject_source candidate_hash_gate_bypass \
  '("raw = stable_read(spec[\"path\"], spec[\"sha256\"], int(str(spec[\"mode\"]), 8),", "raw = stable_read(spec[\"path\"], digest(Path(spec[\"path\"]).read_bytes()), int(str(spec[\"mode\"]), 8),", 1)'
reject_source unknown_key_gate_bypass \
  '("if not isinstance(value, dict) or set(value) != set(expected):", "if False:", 1)'
reject_source force_release_truth_bypass \
  '("value.get(\"force_release_executed\") is False", "value.get(\"force_release_executed\") in (False, True)", 2)'
reject_source rollback_truth_bypass \
  '("value.get(\"rollback_performed\") is True", "value.get(\"rollback_performed\") in (False, True)", 2)'
reject_source resume_redispatch \
  '("if not authorization_exists:", "if True:  # unsafe redispatch", 1)'
reject_source linux_live_census_bypass \
  '("        validate_linux_live_census(linux)", "        pass  # Linux live census bypass", 1)'
reject_source windows_live_census_bypass \
  '("        validate_windows_live_census(windows, manifest)", "        pass  # Windows live census bypass", 1)'
reject_source windows_timeout_reduced \
  '("timeout=120", "timeout=10", 1)'
reject_source windows_encoded_command_bypass \
  '("\"-NonInteractive\", \"-EncodedCommand\", encoded", "\"-NonInteractive\", \"-Command\", encoded", 1)'
reject_source windows_utf16le_bypass \
  '("bootstrap.encode(\"utf-16le\")", "bootstrap.encode(\"ascii\")", 1)'
reject_source windows_gzip_determinism_bypass \
  '("gzip.compress(script.encode(\"ascii\"), compresslevel=9, mtime=0)", "script.encode(\"ascii\")", 1)'
reject_source windows_gzip_overload_ambiguity \
  '("[IO.Compression.CompressionMode]::Decompress", "0", 1)'
reject_source windows_stdin_reader_reintroduced \
  '("\"LANG\": \"C.UTF-8\", \"LC_ALL\": \"C.UTF-8\"}, stdin=subprocess.DEVNULL,", "\"LANG\": \"C.UTF-8\", \"LC_ALL\": \"C.UTF-8\"}, input=script.encode(\"ascii\"),  # ReadToEnd stdin transport", 1)'
reject_source windows_argv_bound_bypass \
  '("len(encoded) > 6_800", "False", 1)'
reject_source windows_total_argv_bound_bypass \
  '("sum(len(item) + 1 for item in command) > 7_000", "False", 1)'
reject_source windows_progress_stderr_gate_bypass \
  '("    validate_powershell_progress_stderr(result.stderr)", "    pass  # unsafe stderr bypass", 1)'
reject_source windows_progress_stderr_accept_all \
  '("child.attrib.get(\"S\") != \"progress\"", "False", 1)'
reject_source windows_clixml_error_accept \
  '("element.attrib.get(\"S\") == \"Error\"", "False", 1)'
reject_source successor_approval_still_absent \
  '("execution_approval_may_exist and path == value[\"approval_path\"]", "False", 1)'
reject_source failed_v1_approval_hash_bypass \
  '("failed_approval_raw = read_spec(failed[\"approval\"], \"failed attempt v1 approval\", False)", "failed_approval_raw = pathlib.Path(failed[\"approval\"][\"path\"]).read_bytes()  # unsafe", 1)'
reject_source failed_v1_approval_absence_reintroduced \
  '("or failed[\"approval\"][\"path\"] in value[\"required_absent\"]", "or False", 1)'

reject_manifest manifest_force_true '.recovery_boundary.force_release_executed = true'
reject_manifest manifest_rollback_false '.recovery_boundary.rollback_performed = false'
reject_manifest manifest_candidate_hash '.immutable_inputs.marker_cli_candidate.sha256 = ("1" * 64) | .argv[(.argv | index("--schema1-handoff-abort-marker-cli-sha256")) + 1] = ("1" * 64)'
reject_manifest manifest_lineage_hash '.immutable_inputs.schema1_handoff_lineage.sha256 = ("2" * 64) | .argv[(.argv | index("--schema1-handoff-lineage-receipt-sha256")) + 1] = ("2" * 64)'
reject_manifest manifest_unknown_key '.unexpected = true'
reject_manifest manifest_unsupported_argv '.argv += ["--local-windows-stop-evidence","/tmp/forbidden"]'
reject_manifest manifest_windows_task_state '.windows_expected.deployment_task_state = "Ready"'
reject_manifest manifest_windows_process_count '.windows_expected.global_viewflow_process_count = 1'
reject_manifest manifest_windows_receipt_hash '.windows_expected.critical_receipts[0].sha256 = ("3" * 64)'
reject_manifest manifest_failed_v1_approval_hash '.failed_attempt_v1.approval.sha256 = ("4" * 64)'
reject_manifest manifest_old_approval_reused '.approval_path = .failed_attempt_v1.approval.path | .required_absent[-1] = .failed_attempt_v1.approval.path'
reject_manifest manifest_old_approval_required_absent '.required_absent += [.failed_attempt_v1.approval.path]'

echo '442fe737 schema5 abort successor-v2 static-negative tests passed'
