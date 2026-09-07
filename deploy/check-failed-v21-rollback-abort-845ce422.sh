#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
manifest=${VF_ABORT_MANIFEST:-$root/deploy/failed-v21-rollback-abort-845ce422-manifest.json}
gate=${VF_ABORT_GATE:-$root/deploy/failed-v21-rollback-abort-845ce422-gate.py}
launcher=${VF_ABORT_LAUNCHER:-$root/deploy/launch-failed-v21-rollback-abort-845ce422.sh}
publisher=${VF_ABORT_PUBLISHER:-$root/deploy/publish-failed-v21-rollback-abort-845ce422-approval.py}
hermetic=${VF_ABORT_HERMETIC:-$root/deploy/tests/failed-v21-rollback-abort-845ce422-hermetic.py}
op=845ce4223e4f426a8a0015d3355595e8

python3 - "$gate" "$publisher" <<'PY'
import pathlib
import sys
for name in sys.argv[1:]:
    compile(pathlib.Path(name).read_bytes(), name, "exec")
PY
bash -n "$launcher"
jq -e --arg op "$op" '
  keys == ["active_marker","approval_path","argv","coordinator","coordinator_instance_id",
           "execution_authorized","immutable_inputs","installed_linux","marker_generation",
           "operation_id","outputs","recovery_boundary","recovery_marker_generation",
           "required_absent","schema_version","source_display_id","state","target_device_id",
           "windows_expected"] and
  .schema_version == 1 and
  .state == "viewflow-failed-v21-rollback-abort-845ce422-command-manifest" and
  .execution_authorized == false and .operation_id == $op and
  .recovery_boundary == "windows-rolled-back-mutation-possible-original-generation-active" and
  .coordinator.sha256 == "6e50c84886895959b954c7b4fa682258c4484e47f3663741ead4d1fb5f74b995" and
  .coordinator.checker_sha256 == "7250b330771d71e90df5411e90251b69f84c7fe6de72da7d0e2ab89e5bcf68da" and
  .coordinator.semantic_test_sha256 == "a03e37c49c6b761901d17d8054f112c11a3086066a1f12a42b61c278fed4213d" and
  .coordinator.negative_test_sha256 == "93c30a3818246b0ddc3d5a152542ea80415a532280e06841590cdb7ac93f2299" and
  .immutable_inputs.coordinator_state.sha256 == "6653e38910c957775fca6beea08b07fcd3e6b64d678694e53d9f5bbd2e4b406c" and
  .immutable_inputs.fresh_lineage.sha256 == "0c32f1f3524945355c20dfdf5cd7ce6a15e5d02a0331362288a9d8c22646aa78" and
  .immutable_inputs.old_abort_terminal.sha256 == "d1376cb7c98286970d4f5f28251bd5546e88cb7e98d29d7f2eee6b7170063ca9" and
  .immutable_inputs.old_abort_authorization.sha256 == "2e5c1b924344d38569183240d5a7711100d41c36a359c875da41cfb14e820062" and
  .immutable_inputs.old_abort_receipt.sha256 == "8d4179406bd5456f88e5c9d469d7afeedb35f41d011d677c297f6605eda66a2e" and
  .immutable_inputs.old_abort_query.sha256 == .immutable_inputs.old_abort_receipt.sha256 and
  .immutable_inputs.old_vfdqa.sha256 == "62f290a0a3ec9e7413dece5a09e2f06e79fa5f4520d4e25d3de5b2d70423e862" and
  .immutable_inputs.old_durable_vfdqa.sha256 == .immutable_inputs.old_vfdqa.sha256 and
  .immutable_inputs.bridge_persistent_started.sha256 == "d57ade1d7d53bbb8a736a23b437acde6c1d74ce9e1fd7d7f3fac629fff81fa1d" and
  .active_marker.magic == "VFDQT001" and .active_marker.size == 256 and
  .windows_expected.old_task_pre_state == "Ready" and
  .windows_expected.old_task_post_state == "Running" and
  .windows_expected.deployment_task_state == "Disabled" and
  .windows_expected.deployment_task_xml_sha256 == "6de080cc53d16febf69147f0f19e66c46f068bee1c244bd15cf47fd41569135f" and
  (.windows_expected.exact_members | length == 26 and . == sort_by(.name) and
    ([.[].name] | length == (unique | length)) and
    all(.[]; keys == ["name","sha256","size"] and (.sha256 | test("^[0-9a-f]{64}$")) and
        (.size | type == "number") and .size >= 0)) and
  (.windows_expected.exact_members | map(.name) |
    index("linux-v13-frozen-evidence.consumed.845ce4223e4f426a8a0015d3355595e8.json")) != null and
  (.windows_expected.operation_root | endswith($op)) and
  (.argv[0] == .coordinator.path) and .argv[1] == "--abort-failed-v13" and
  (.argv | index("--fresh-operation-lineage-receipt")) != null and
  (.argv | index("--failed-v13-original-generation-only")) != null and
  (.argv | index("--release-deployment-marker")) == null and
  ([.outputs[]] | length == (unique | length))
' "$manifest" >/dev/null

for token in \
  'Once the durable abort receipt exists, never redispatch' \
  'raw[8:16] == bytes.fromhex("0101010301000000")' \
  'committed_ms == int(receipt["abort_committed_at_unix_ms"])' \
  'raw[344:352] == b"\0" * 8' \
  '.deployment-quarantine.v1.abort-receipt.' \
  'validate_abort_receipt' \
  'ensure_abort_receipt' \
  'coordinator redispatch forbidden' \
  'read_named_owned' \
  'dir_fd=parent' \
  'locked_hook' \
  'windows_census(manifest, "Ready", 0)' \
  'windows_census(manifest, "Running", 1)' \
  'operation_root_members' \
  'deployment_task_state' \
  'deployment_worker_count' \
  'global_viewflow_process_count' \
  'terminal_commit' \
  'run_marker_query' \
  'validate_coordinator_outputs' \
  'real old durable VFDQA closure differs' \
  'candidate manifest/state Windows path closure differs' \
  'VFDQA001' \
  'F_SEAL_WRITE' \
  'RENAME_NOREPLACE' \
  'DBUS_SESSION_BUS_ADDRESS' \
  'LogLevel=ERROR' \
  'ScriptBlock]::Create([Console]::In.ReadToEnd())' \
  'input=script' \
  '$ProgressPreference=' \
  'Windows census script is not ASCII' \
  'members == w["exact_members"]' \
  'operation-root exact member identity differs'; do
  rg -F --quiet "$token" "$gate" "$launcher"
done

rg -F --quiet 'old approval reuse is forbidden' "$publisher"
rg -F --quiet 'create-once-no-replace-and-parent-fsync' "$publisher" "$gate"
rg -F --quiet 'renameat2' "$publisher"
rg -F --quiet 'XDG_RUNTIME_DIR=/run/user/1000' "$launcher"
rg -F --quiet 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' "$launcher"

manifest_sha=$(sha256sum "$manifest" | cut -d' ' -f1)
gate_sha=$(sha256sum "$gate" | cut -d' ' -f1)
launcher_sha=$(sha256sum "$launcher" | cut -d' ' -f1)
[[ $manifest_sha == db4b11c511b77f18bca3ccb09e0cce312ce21cfcf8050f374a49440f782a2533 ]]
rg -F --quiet "MANIFEST_SHA = \"$manifest_sha\"" "$launcher" "$publisher"
rg -F --quiet "GATE_SHA = \"$gate_sha\"" "$launcher" "$publisher"
rg -F --quiet "LAUNCHER_SHA = \"$launcher_sha\"" "$publisher"
[[ $(sha256sum "$(jq -r '.coordinator.path' "$manifest")" | cut -d' ' -f1) == $(jq -r '.coordinator.sha256' "$manifest") ]]
[[ $(sha256sum "$(jq -r '.coordinator.checker_path' "$manifest")" | cut -d' ' -f1) == $(jq -r '.coordinator.checker_sha256' "$manifest") ]]
[[ $(sha256sum "$(jq -r '.coordinator.semantic_test_path' "$manifest")" | cut -d' ' -f1) == $(jq -r '.coordinator.semantic_test_sha256' "$manifest") ]]
[[ $(sha256sum "$(jq -r '.coordinator.negative_test_path' "$manifest")" | cut -d' ' -f1) == $(jq -r '.coordinator.negative_test_sha256' "$manifest") ]]

if rg -n '__FINAL_[A-Z0-9_]+__' "$manifest" "$gate" "$launcher" "$publisher"; then
  echo '845ce422 abort set is not fully frozen' >&2
  exit 1
fi

[[ ! -e /home/wilf/.local/state/viewflow/deployments/$op/failed-v21-rollback-abort-845ce422-execution-approval.json ]]
VF_ABORT_GATE=$gate python3 "$hermetic"
echo '845ce422 schema1 abort static checker passed'
