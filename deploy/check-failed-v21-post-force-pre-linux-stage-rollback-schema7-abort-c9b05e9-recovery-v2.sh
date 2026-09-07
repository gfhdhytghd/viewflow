#!/usr/bin/env bash
set -euo pipefail
root=/home/wilf/data/viewflow
stem=failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2
manifest=${VF_C9_RECOVERY_V2_MANIFEST:-$root/deploy/$stem-manifest.json}
gate=${VF_C9_RECOVERY_V2_GATE:-$root/deploy/$stem-gate.py}
launcher=$root/deploy/launch-$stem.sh
publisher=$root/deploy/publish-$stem-approval.py
hermetic=$root/deploy/tests/$stem-hermetic.py
(( $#==0 )) || exit 64
python3 - "$gate" "$publisher" <<'PY'
import pathlib,sys
for p in sys.argv[1:]: compile(pathlib.Path(p).read_bytes(),p,"exec")
s=pathlib.Path(sys.argv[1]).read_text()
for forbidden in ("run_coordinator","/usr/bin/ssh","windows_live_census"):
 if forbidden in s: raise SystemExit("forbidden recovery dispatch: "+forbidden)
PY
bash -n "$launcher"
jq -e '
 keys==["approval_path","committed","coordinator_instance_id","execution_authorized","marker_cli",
 "marker_sha256","operation_id","outputs","post_abort","predecessor","recovery_policy",
 "required_absent","schema_version","state"] and .schema_version==2 and
 .operation_id=="c9b05e9bea4140d69f9d137a0f992ba0" and .execution_authorized==false and
 .predecessor.approval.sha256=="26b75c5187b843db57a0da262f5ebb0f4aec660ee60c4231fb707c034c6d5cb4" and
 .committed.authorization.sha256=="598a11e781506a9cc2267d266d08df0c0a35db056595ff44fd993d8e8c5b45ad" and
 .committed.abort_receipt.sha256=="b9baa81d2b7c356be6c699736db2befdf7e3b4a554b954c99279ace6d57472bd" and
 .committed.transition.sha256=="14345a57e9c94c07916ea5b4bcc390fe8ceae6f207723b9bda414a758e11f0c7" and
 .committed.linux_v13_started.sha256=="0f9d013499dd45e94fc0efbb7e907c965165296f998276bb6505fafb86d78c45" and
 .committed.windows_v13_started.sha256=="e4037a8f6024e49169dba1ee094de7a9a90ff2180636c7b6cf098ebf401003a5" and
 .committed.authenticated_v13_peer.sha256=="39c37a58ad970d21731cfb78e85184d37799e41a3e7cf62b74e67e068aa82e8a" and
 .post_abort.durable_vfdqa.sha256=="56ae0daa3327e2ee469376968d59bd02086f1730b0f3fc1bd0459dca9422a67f" and
 .post_abort.retired_claim.sha256==.marker_sha256 and
 .recovery_policy=={abort_redispatch_forbidden:true,coordinator_dispatch_forbidden:true,
 local_receipt_reconstruction_enabled:false,only_pinned_marker_query:true} and
 (.predecessor.approval.path as$p|.required_absent|index($p))==null
' "$manifest" >/dev/null
for token in 'run_marker_query(manifest' 'coordinator_redispatched": False' \
 'marker_abort_redispatched": False' 'validate_vfdqa(manifest' \
 'validate_committed(manifest' 'create_once(manifest["outputs"]["query"]' \
 'create_once(manifest["outputs"]["terminal"]' 'RENAME_NOREPLACE'; do rg -F --quiet "$token" "$gate"; done
VF_C9_RECOVERY_V2_GATE=$gate VF_C9_RECOVERY_V2_MANIFEST=$manifest python3 "$hermetic" >/dev/null
while IFS=$'\t' read -r path sha mode size; do
 [[ -f $path && ! -L $path && $(sha256sum "$path"|cut -d' ' -f1) == "$sha" ]]
 [[ $(stat -c '%u:%a:%h:%s' "$path") == "1000:$mode:1:$size" ]]
done < <(jq -r '(.predecessor.manifest,.predecessor.approval,.committed[],.post_abort.durable_vfdqa,.post_abort.retired_claim,.marker_cli)|[.path,.sha256,(.mode|tostring),(.size|tostring)]|@tsv' "$manifest")
while IFS= read -r path; do [[ ! -e $path && ! -L $path ]]; done < <(jq -r '.post_abort.public_absent[],.required_absent[]' "$manifest")
manifest_sha=$(sha256sum "$manifest"|cut -d' ' -f1); gate_sha=$(sha256sum "$gate"|cut -d' ' -f1); launcher_sha=$(sha256sum "$launcher"|cut -d' ' -f1)
[[ $manifest_sha == 919bd49f40f4fe5cb140f22576613bc3e76a4489456e780956999c0cbfdd5d83 ]]
rg -F --quiet "MANIFEST_SHA=\"$manifest_sha\"" "$publisher"
rg -F --quiet "MANIFEST_SHA = \"$manifest_sha\"" "$launcher"
rg -F --quiet "GATE_SHA=\"$gate_sha\"" "$publisher"
rg -F --quiet "GATE_SHA = \"$gate_sha\"" "$launcher"
rg -F --quiet "LAUNCHER_SHA=\"$launcher_sha\"" "$publisher"
"$launcher" --offline-check
"$publisher" --check-only
echo 'c9b05e9 committed-abort recovery-v2 checker passed'
