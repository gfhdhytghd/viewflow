#!/usr/bin/env bash
set -euo pipefail
root=/home/wilf/data/viewflow
stem=failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2
gate=$root/deploy/$stem-gate.py; manifest=$root/deploy/$stem-manifest.json
hermetic=$root/deploy/tests/$stem-hermetic.py; checker=$root/deploy/check-$stem.sh
temporary=$(mktemp -d); trap 'rm -rf -- "$temporary"' EXIT
bash "$checker" >/dev/null; python3 "$hermetic" >/dev/null

reject_manifest(){ local name=$1 filter=$2 p=$temporary/$1.json; jq "$filter" "$manifest">"$p"; chmod 600 "$p"; ! cmp -s "$p" "$manifest" || exit 1; if VF_C9_RECOVERY_V2_MANIFEST=$p python3 "$hermetic" >/dev/null 2>&1; then echo "manifest mutation accepted: $name" >&2; exit 1; fi; }
reject_source(){ local name=$1 old=$2 new=$3 p=$temporary/$1.py; cp -- "$gate" "$p"; CANDIDATE=$p OLD=$old NEW=$new python3 - <<'PY'
import os,pathlib
p=pathlib.Path(os.environ["CANDIDATE"]);s=p.read_text();old=os.environ["OLD"]
if s.count(old)!=1: raise SystemExit("mutation anchor differs")
p.write_text(s.replace(old,os.environ["NEW"],1))
PY
 if VF_C9_RECOVERY_V2_GATE=$p python3 "$hermetic" >/dev/null 2>&1; then echo "source mutation accepted: $name" >&2; exit 1; fi; }
reject_function_noop(){ local function=$1 p=$temporary/noop-$1.py; cp -- "$gate" "$p"; CANDIDATE=$p FUNCTION=$function python3 - <<'PY'
import ast,os,pathlib
p=pathlib.Path(os.environ["CANDIDATE"]);s=p.read_text();tree=ast.parse(s)
nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name==os.environ["FUNCTION"]]
if len(nodes)!=1: raise SystemExit("function anchor differs")
n=nodes[0];lines=s.splitlines(keepends=True);indent=" "*(n.col_offset+4)
lines[n.body[0].lineno-1:n.end_lineno]=[indent+"return None\n"]
p.write_text("".join(lines))
PY
 if VF_C9_RECOVERY_V2_GATE=$p python3 "$hermetic" >/dev/null 2>&1; then echo "no-op function accepted: $function" >&2; exit 1; fi; }

reject_manifest old_approval '.predecessor.approval.sha256=("1"*64)'
reject_manifest authorization '.committed.authorization.sha256=("2"*64)'
reject_manifest abort_receipt '.committed.abort_receipt.sha256=("3"*64)'
reject_manifest transition '.committed.transition.sha256=("4"*64)'
reject_manifest linux_started '.committed.linux_v13_started.sha256=("5"*64)'
reject_manifest windows_started '.committed.windows_v13_started.sha256=("6"*64)'
reject_manifest peer '.committed.authenticated_v13_peer.sha256=("7"*64)'
reject_manifest vfdqa '.post_abort.durable_vfdqa.sha256=("8"*64)'
reject_manifest retired '.post_abort.retired_claim.sha256=("9"*64)'
reject_manifest marker_present '.post_abort.public_absent=.post_abort.public_absent[1:]'
reject_manifest dispatch_allowed '.recovery_policy.coordinator_dispatch_forbidden=false'
reject_manifest abort_allowed '.recovery_policy.abort_redispatch_forbidden=false'
reject_manifest unpinned_query '.recovery_policy.only_pinned_marker_query=false'
reject_manifest local_rebuild '.recovery_policy.local_receipt_reconstruction_enabled=true'
reject_manifest reuse_old_approval '.approval_path=.predecessor.approval.path'
reject_manifest overwrite_old_query '.outputs.query=.required_absent[0]'
reject_manifest unknown_key '.unexpected=true'

reject_source coordinator_injected 'marker_query_raw = run_marker_query(manifest, digest(raws["authorization"]))' 'marker_query_raw = run_coordinator(manifest)'
reject_source query_attribution '"operation_id": OP, "coordinator_redispatched": False,' '"operation_id": OP, "coordinator_redispatched": True,'
reject_source abort_attribution '"marker_abort_redispatched": False, "query_source": "sealed-marker-cli-query"' '"marker_abort_redispatched": True, "query_source": "sealed-marker-cli-query"'
reject_source query_publish_bypass '        create_once(manifest["outputs"]["query"], query_raw)' '        pass  # query publish bypass'
reject_source terminal_publish_bypass '    create_once(manifest["outputs"]["terminal"], terminal_raw)' '    pass  # terminal publish bypass'
reject_function_noop validate_vfdqa
reject_function_noop validate_committed
reject_function_noop validate_authorization
reject_function_noop validate_receipt
reject_source authorization_call_deleted '    validated_authorization = validate_authorization(documents["authorization"], manifest)' '    validated_authorization = documents["authorization"]'
reject_source receipt_call_deleted $'    validated_receipt = validate_receipt(\n        documents["abort_receipt"], manifest, authorization_sha, False)' '    validated_receipt = documents["abort_receipt"]'
reject_source committed_call_deleted '    committed_hashes = validate_committed(manifest, documents)' '    committed_hashes = {name: manifest["committed"][name]["sha256"] for name in manifest["committed"]}'
reject_source vfdqa_call_deleted $'    vfdqa_sha, retired_path = validate_vfdqa(\n        manifest, documents["abort_receipt"], authorization_sha)' $'    vfdqa_sha = manifest["post_abort"]["durable_vfdqa"]["sha256"]\n    retired_path = manifest["post_abort"]["retired_claim"]["path"]'

echo 'c9b05e9 committed-abort recovery-v2 static-negative tests passed'
