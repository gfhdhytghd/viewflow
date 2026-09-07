#!/usr/bin/env bash
set -euo pipefail
root=/home/wilf/data/viewflow
stem=failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9
gate=$root/deploy/$stem-gate.py
manifest=$root/deploy/$stem-manifest.json
hermetic=$root/deploy/tests/$stem-hermetic.py
checker=$root/deploy/check-$stem.sh
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
bash "$checker" >/dev/null
python3 "$hermetic" >/dev/null

source_contract() {
  local p=$1
  python3 -m py_compile "$p" || return 1
  [[ $(grep -Fc -- 'before.st_nlink == 1' "$p") == 2 ]] || return 1
  [[ $(grep -Fc -- 'identity(before) == identity(named)' "$p") == 2 ]] || return 1
  [[ $(grep -Fc -- 'identity(os.fstat(fd)) != identity(before)' "$p") == 2 ]] || return 1
  [[ $(grep -Fc -- 'digest(raw) != expected' "$p") == 2 ]] || return 1
  [[ $(grep -Fc -- 'and provenance.get("candidate", {}).get("sha256") == candidate_spec["sha256"]' "$p") == 1 ]] || return 1
  [[ $(grep -Fc -- 'and provenance.get("source_sha256") == {' "$p") == 1 ]] || return 1
  [[ $(grep -Fc -- 'if coordinator_dispatch_required(terminal_exists, authorization_exists):' "$p") == 1 ]] || return 1
  [[ $(grep -Fc -- 'if not HEX.fullmatch(args.approval_sha256):' "$p") == 1 ]] || return 1
  [[ $(grep -Fc -- 'raw = stable_read(spec["path"], spec["sha256"], 0o755, spec["size"], "marker candidate")' "$p") == 1 ]] || return 1
  for token in 'value.get("schema_version") == 7' \
    'value.get("coordinator_failure_phase") == "WINDOWS_FORCE_ATTESTED"' \
    'value.get("force_release_executed") is True' \
    'value.get("linux_stage_committed") is False' \
    'value.get("windows_install_committed") is False' \
    'value.get("windows_installer_exit_present") is False' \
    '"fresh_operation_lineage_receipt_sha256": "fresh_lineage"' \
    '"windows_force_envelope_sha256": "force_envelope"'; do
    [[ $(grep -Fc -- "$token" "$p") == 2 ]] || return 1
  done
  local token
  for token in \
    'candidate_spec["sha256"]' \
    'provenance.get("source_sha256") == {' \
    'value.get("schema_version") == 7' \
    'value.get("coordinator_failure_phase") == "WINDOWS_FORCE_ATTESTED"' \
    'value.get("force_release_executed") is True' \
    'value.get("linux_stage_committed") is False' \
    'value.get("windows_install_committed") is False' \
    'value.get("windows_installer_exit_present") is False' \
    '"fresh_operation_lineage_receipt_sha256": "fresh_lineage"' \
    '"windows_force_envelope_sha256": "force_envelope"' \
    'validate_linux_live_census(linux)' \
    'validate_windows_live_census(windows, manifest)' \
    'run_coordinator(manifest)' 'F_SEAL_WRITE' 'RENAME_NOREPLACE'; do
    rg -F --quiet "$token" "$p" || return 1
  done
  ! rg -F --quiet 'ReadToEnd' "$p"
}

reject_source() {
  local name=$1 old=$2 new=$3 count=${4:-1} p
  p=$temporary/$name.py
  cp -- "$gate" "$p"
  CANDIDATE=$p OLD=$old NEW=$new COUNT=$count python3 - <<'PY'
import os,pathlib
p=pathlib.Path(os.environ["CANDIDATE"]); s=p.read_text(); old=os.environ["OLD"]
count=int(os.environ["COUNT"])
if s.count(old)!=count: raise SystemExit("mutation anchor count differs: "+old)
p.write_text(s.replace(old,os.environ["NEW"],count))
PY
  if source_contract "$p" && VF_C9_SCHEMA7_GATE=$p python3 "$hermetic" >/dev/null 2>&1; then
    echo "negative source mutation accepted: $name" >&2; exit 1
  fi
}

reject_post_state_source() {
  local name=$1 old=$2 new=$3 count=${4:-1} p
  p=$temporary/$name.py
  cp -- "$gate" "$p"
  CANDIDATE=$p OLD=$old NEW=$new COUNT=$count python3 - <<'PY'
import os,pathlib
p=pathlib.Path(os.environ["CANDIDATE"]); s=p.read_text(); old=os.environ["OLD"]
count=int(os.environ["COUNT"])
if s.count(old)!=count: raise SystemExit("mutation anchor count differs: "+old)
p.write_text(s.replace(old,os.environ["NEW"],count))
PY
  if VF_C9_SCHEMA7_GATE=$p bash "$checker" --post-state-contract-only >/dev/null 2>&1; then
    echo "negative post-state execution mutation accepted: $name" >&2; exit 1
  fi
}

reject_manifest() {
  local name=$1 filter=$2 p
  p=$temporary/$name.json
  jq "$filter" "$manifest" >"$p"; chmod 600 "$p"
  ! cmp -s "$p" "$manifest" || { echo "no-op manifest mutation: $name" >&2; exit 1; }
  if VF_C9_SCHEMA7_MANIFEST=$p python3 "$hermetic" >/dev/null 2>&1; then
    echo "negative manifest mutation accepted: $name" >&2; exit 1
  fi
}

reject_source nlink_bypass 'before.st_nlink == 1' 'before.st_nlink >= 1' 2
reject_source named_inode_bypass 'and before.st_size == size and identity(before) == identity(named)' 'and before.st_size == size' 1
reject_source fd_reread_bypass 'or identity(os.fstat(fd)) != identity(before) or digest(raw) != expected' 'or digest(raw) != expected' 1
reject_source candidate_hash_bypass 'and provenance.get("candidate", {}).get("sha256") == candidate_spec["sha256"]' 'and True' 1
reject_source provenance_sources_bypass 'and provenance.get("source_sha256") == {' 'and provenance.get("source_sha256") != {' 1
reject_source schema7_auth_bypass 'value.get("schema_version") == 7' 'value.get("schema_version") in (5, 7)' 2
reject_source phase_bypass 'value.get("coordinator_failure_phase") == "WINDOWS_FORCE_ATTESTED"' 'True' 2
reject_source force_truth_bypass 'value.get("force_release_executed") is True' 'True' 2
reject_source linux_stage_truth_bypass 'value.get("linux_stage_committed") is False' 'True' 2
reject_source windows_install_truth_bypass 'value.get("windows_install_committed") is False' 'True' 2
reject_source installer_exit_truth_bypass 'value.get("windows_installer_exit_present") is False' 'True' 2
reject_source lineage_binding_bypass '"fresh_operation_lineage_receipt_sha256": "fresh_lineage"' '"fresh_operation_lineage_receipt_sha256": "coordinator_state"' 2
reject_source force_binding_bypass '"windows_force_envelope_sha256": "force_envelope"' '"windows_force_envelope_sha256": "windows_prepared"' 2
reject_source exact_keys_bypass 'if not isinstance(value, dict) or set(value) != set(expected):' 'if False:' 1
reject_source linux_live_bypass '        validate_linux_live_census(linux)' '        pass  # bypass' 1
reject_source windows_live_bypass '        validate_windows_live_census(windows, manifest)' '        pass  # bypass' 1
reject_source coordinator_dispatch_bypass '    if coordinator_dispatch_required(terminal_exists, authorization_exists):' '    if False:' 1
reject_source approval_gate_bypass '    if not HEX.fullmatch(args.approval_sha256):' '    if False:' 1
reject_source marker_query_hash_bypass 'raw = stable_read(spec["path"], spec["sha256"], 0o755, spec["size"], "marker candidate")' 'raw = pathlib.Path(spec["path"]).read_bytes()' 1
reject_source stdin_transport 'stdin=subprocess.DEVNULL,' 'input=b"ReadToEnd",' 4
reject_source linux_producer_state_invented \
  '"linux_v13_started": "viewflow-linux-v1.3-started-under-deployment-quarantine"' \
  '"linux_v13_started": "viewflow-v13-linux-started-frozen"'
reject_source windows_producer_state_invented \
  '"windows_v13_started": "viewflow-windows-v1.3-started-under-deployment-quarantine"' \
  '"windows_v13_started": "viewflow-v13-windows-started-frozen"'
reject_source peer_producer_state_invented \
  '"authenticated_v13_peer": "viewflow-v1.3-peer-authenticated-under-deployment-quarantine"' \
  '"authenticated_v13_peer": "viewflow-v13-authenticated-peer-validated"'
reject_post_state_source post_state_call_deleted \
  '    vfdqa_sha, retired = validate_post_state(manifest, receipt, auth_sha)' \
  '    vfdqa_sha, retired = ("0" * 64, "/tmp/forged-retired")'
reject_post_state_source post_state_call_noop \
  '    vfdqa_sha, retired = validate_post_state(manifest, receipt, auth_sha)' \
  '    validate_post_state(manifest, receipt, auth_sha); vfdqa_sha, retired = ("0" * 64, "/tmp/forged-retired")'
reject_post_state_source post_state_return_forged \
  '    return digest(raw), retired' \
  '    return "0" * 64, "/tmp/forged-retired"'
reject_post_state_source post_state_retired_forged \
  '    return digest(raw), retired' \
  '    return digest(raw), "/tmp/forged-retired"'

reject_manifest state_hash '.immutable_inputs.coordinator_state.sha256=("1"*64) | .argv[(.argv|index("--old-coordinator-state-sha256"))+1]=("1"*64)'
reject_manifest lineage_hash '.immutable_inputs.fresh_lineage.sha256=("2"*64) | .argv[(.argv|index("--fresh-operation-lineage-receipt-sha256"))+1]=("2"*64)'
reject_manifest marker_hash '.active_marker.sha256=("3"*64)'
reject_manifest candidate_hash '.immutable_inputs.marker_cli_candidate.sha256=("4"*64) | .argv[(.argv|index("--post-force-abort-marker-cli-sha256"))+1]=("4"*64)'
reject_manifest candidate_path '.immutable_inputs.marker_cli_candidate.path="/tmp/other" | .argv[(.argv|index("--post-force-abort-marker-cli-candidate"))+1]="/tmp/other"'
reject_manifest candidate_mode '.immutable_inputs.marker_cli_candidate.mode=700'
reject_manifest candidate_size '.immutable_inputs.marker_cli_candidate.size+=1'
reject_manifest provenance_hash '.immutable_inputs.marker_cli_provenance.sha256=("5"*64)'
reject_manifest force_false '.recovery_boundary.force_release_executed=false'
reject_manifest linux_stage_true '.recovery_boundary.linux_stage_committed=true'
reject_manifest windows_install_true '.recovery_boundary.windows_install_committed=true'
reject_manifest installer_exit_true '.recovery_boundary.windows_installer_exit_present=true'
reject_manifest unknown_key '.unexpected=true'
reject_manifest resume_mode '.argv += ["--resume"]'
reject_manifest release_mode '.argv[1]="--release-deployment-marker"'
reject_manifest approval_reuse '.approval_path=.outputs.authorization'
reject_manifest windows_task_state '.windows_expected.deployment_task_state="Ready"'
reject_manifest windows_current_xml_is_claimed '.windows_expected.deployment_task_xml_sha256=.windows_expected.deployment_task_claimed_pre_disable_xml_sha256'
reject_manifest windows_current_xml_unknown '.windows_expected.deployment_task_xml_sha256=("6"*64)'
reject_manifest windows_claimed_xml_is_current '.windows_expected.deployment_task_claimed_pre_disable_xml_sha256=.windows_expected.deployment_task_xml_sha256'
reject_manifest windows_claimed_xml_unknown '.windows_expected.deployment_task_claimed_pre_disable_xml_sha256=("7"*64)'
reject_manifest windows_process '.windows_expected.global_viewflow_process_count=1'
reject_manifest windows_receipt '.windows_expected.critical_receipts[0].sha256=("6"*64)'

echo 'c9b05e9 schema7 abort static-negative tests passed'
