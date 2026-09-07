#!/usr/bin/env bash
set -euo pipefail

root=/home/wilf/data/viewflow
checker=$root/deploy/check-failed-pre-mutation-abort-305058f7-no-retry.py
gate=$root/deploy/gate-failed-pre-mutation-abort-305058f7-no-retry-successor1.py
manifest=$root/deploy/failed-pre-mutation-abort-305058f7-no-retry-successor1-manifest.json
launcher=$root/deploy/launch-failed-pre-mutation-abort-305058f7-no-retry-successor1.sh
publisher=$root/deploy/publish-failed-pre-mutation-abort-305058f7-no-retry-successor1-approval.py
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

expect_reject() {
  cp -- "$launcher" "$tmp/launcher.sh"
  cp -- "$publisher" "$tmp/publisher.py"
  gate_sha=$(sha256sum -- "$tmp/gate.py"); gate_sha=${gate_sha%% *}
  manifest_sha=$(sha256sum -- "$tmp/manifest.json"); manifest_sha=${manifest_sha%% *}
  sed -i -E "s/(GATE_SHA = \x22)[0-9a-f]{64}(\x22)/\1${gate_sha}\2/;s/(MANIFEST_SHA = \x22)[0-9a-f]{64}(\x22)/\1${manifest_sha}\2/" "$tmp/launcher.sh"
  launcher_sha=$(sha256sum -- "$tmp/launcher.sh"); launcher_sha=${launcher_sha%% *}
  sed -i -E "s/(GATE_SHA = \x22)[0-9a-f]{64}(\x22)/\1${gate_sha}\2/;s/(MANIFEST_SHA = \x22)[0-9a-f]{64}(\x22)/\1${manifest_sha}\2/;s/(LAUNCHER_SHA = \x22)[0-9a-f]{64}(\x22)/\1${launcher_sha}\2/" "$tmp/publisher.py"
  if "$checker" --gate "$tmp/gate.py" --manifest "$tmp/manifest.json" --launcher "$tmp/launcher.sh" --publisher "$tmp/publisher.py" >/dev/null 2>&1; then
    echo "checker accepted unsafe mutation: $1" >&2
    exit 1
  fi
}

cp -- "$gate" "$tmp/gate.py"
cp -- "$manifest" "$tmp/manifest.json"
sed -i 's/run_sealed_marker_cli(manifest, "abort"/run_sealed_marker_cli(manifest, "query"/' "$tmp/gate.py"
expect_reject abort-before-query

cp -- "$gate" "$tmp/gate.py"
sed -i '0,/"--coordinator-instance-id"/s//"--coordinator-instance-id", "duplicate", "--coordinator-instance-id"/' "$tmp/gate.py"
expect_reject duplicate-native-argv

cp -- "$gate" "$tmp/gate.py"
sed -i 's/"marker_absent": True/"marker_absent": False/' "$tmp/gate.py"
expect_reject terminal-marker-absence-claim

cp -- "$gate" "$tmp/gate.py"
sed -i 's/"coordinator_mutation_possible": False/"coordinator_mutation_possible": True/' "$tmp/gate.py"
expect_reject terminal-mutation-possible-claim

cp -- "$gate" "$tmp/gate.py"
sed -i 's/"linux_viewflow_started": False/"linux_viewflow_started": True/' "$tmp/gate.py"
expect_reject terminal-linux-viewflow-started-claim

cp -- "$gate" "$tmp/gate.py"
sed -i 's/"input_producer_count": 0/"input_producer_count": 1/' "$tmp/gate.py"
expect_reject terminal-input-producer-count

cp -- "$gate" "$tmp/gate.py"
sed -i 's/and result\["global_relevant_processes"\] == \[\]/and True/' "$tmp/gate.py"
expect_reject linux-relevant-process-census

cp -- "$gate" "$tmp/gate.py"
sed -i 's/"global_relevant_processes": baseline\["global_relevant_processes"\]/"global_relevant_processes": []/' "$tmp/gate.py"
expect_reject windows-global-process-binding

cp -- "$gate" "$tmp/gate.py"
sed -i 's/|Sort-Object ProcessId|ForEach-Object/|ForEach-Object/' "$tmp/gate.py"
expect_reject windows-global-process-ordering

cp -- "$gate" "$tmp/gate.py"
sed -i "s/-TaskName ('Viewflow Deployment '+\\\$op)/-TaskName 'Viewflow Deployment '+\\\$op/g" "$tmp/gate.py"
expect_reject powershell-task-name-expression

cp -- "$gate" "$tmp/gate.py"
sed -i 's/baseline\["deployment_task_live_xml_sha256"\]/baseline["deployment_task_xml_sha256"]/' "$tmp/gate.py"
expect_reject live-task-xml-binding

cp -- "$gate" "$tmp/gate.py"
sed -i '/def marker_cli_args/i\def abort_transaction():\n    return None\n' "$tmp/gate.py"
expect_reject python-transaction

cp -- "$gate" "$tmp/gate.py"
cp -- "$manifest" "$tmp/manifest.json"
sed -i 's/coordinator-state.json.pre-mutation-retry.json/pre-mutation-retry.json/' "$tmp/manifest.json"
expect_reject retry-absence-path

cp -- "$manifest" "$tmp/manifest.json"
sed -i 's/cooperating-crash-same-uid-concurrency-path-swap-and-non-owner/cooperating-crash-and-non-owner/' "$tmp/manifest.json"
expect_reject threat-boundary

cp -- "$manifest" "$tmp/manifest.json"
sed -i '0,/c237736c4d8d4db6ba6e118ac46dc083bdf3d8ae99a0b08716bc5d3206fc6c57/s//0000000000000000000000000000000000000000000000000000000000000000/' "$tmp/manifest.json"
expect_reject candidate-hash

cp -- "$gate" "$tmp/gate.py"
cp -- "$manifest" "$tmp/manifest.json"
sed -i 's/"successor_authorization_consumed": True/"successor_authorization_consumed": False/' "$tmp/gate.py"
expect_reject successor-consumed-terminal

cp -- "$gate" "$tmp/gate.py"
cp -- "$manifest" "$tmp/manifest.json"
sed -i 's/state\["committed_artifacts"\] == expected_committed/state["committed_artifacts"] == state["committed_artifacts"]/' "$tmp/gate.py"
expect_reject committed-artifact-self-comparison

cp -- "$gate" "$tmp/gate.py"
sed -i 's/viewflow-normal-v21-coordinator-successor-authorized/viewflow-normal-v21-coordinator-successor-bypassed/' "$tmp/gate.py"
expect_reject successor-receipt-state

cp -- "$gate" "$tmp/gate.py"
cp -- "$manifest" "$tmp/manifest.json"
sed -i '0,/8b8409f39ffa29182cb19cd5e357b447d8b6bcaf4778246189a308360a72bb68/s//0000000000000000000000000000000000000000000000000000000000000000/' "$tmp/manifest.json"
expect_reject successor-receipt-hash

cp -- "$manifest" "$tmp/manifest.json"
sed -i '0,/6ee007340aca8b9f2fafb2b945743d941d0e8313a71ffa1b6069e8a610992648/s//0000000000000000000000000000000000000000000000000000000000000000/' "$tmp/manifest.json"
expect_reject candidate-tree-hash

cp -- "$manifest" "$tmp/manifest.json"
sed -i '0,/0e310964e2bb89a2d7ec4e6b61a688ca365a5dc5bf875c97191e5d234b6fcb06/s//0000000000000000000000000000000000000000000000000000000000000000/' "$tmp/manifest.json"
expect_reject inventory-hash

cp -- "$gate" "$tmp/gate.py"
cp -- "$manifest" "$tmp/manifest.json"
cp -- "$launcher" "$tmp/launcher.sh"
cp -- "$publisher" "$tmp/publisher.py"
sed -i 's/"successor_authorization_consumed": True/"successor_authorization_consumed": False/' "$tmp/publisher.py"
if "$checker" --gate "$tmp/gate.py" --manifest "$tmp/manifest.json" --launcher "$tmp/launcher.sh" --publisher "$tmp/publisher.py" >/dev/null 2>&1; then
  echo "checker accepted unsafe mutation: publisher-successor-consumed" >&2
  exit 1
fi

echo 'op305 no-retry V4 static negative mutations passed'
