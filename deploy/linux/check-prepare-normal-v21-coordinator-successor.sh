#!/usr/bin/env bash
set -Eeuo pipefail
producer=${1:-"$(dirname -- "$0")/prepare-normal-v21-coordinator-successor.sh"}
[[ -f $producer && ! -L $producer ]] || { echo 'successor producer missing or symlinked' >&2; exit 1; }
bash -n "$producer"
python3 - "$producer" <<'PY'
import ast,re,sys
p=sys.argv[1]; text=open(p,encoding="utf-8").read()
try: body=text.split("<<'PY'\n",1)[1].rsplit("\nPY",1)[0]
except Exception: raise SystemExit("embedded Python delimiter missing")
ast.parse(body)
normal=["coordinator-state.json","coordinator-state.json.pre-mutation-retry.json","coordinator-state.json.pre-mutation-start-intent.v1.json","coordinator-state.json.pre-mutation-stop-claim.v1","coordinator-state.json.recovery-bundle.json","coordinator-state.json.windows-restart-intent.json","coordinator-state.json.windows-stop-evidence.json","cpp-arm-response.json","cpp-cleanup-receipt.json","cpp-status-response.json","deployment-release.json","linux-containment.transcript","linux-deactivation-transcript.json","linux-deactivation.json","linux-finalize.json","linux-host-proof.json","linux-stage.json","linux-stage.json.backup","post-release-receipt.json","recovery-deployment-publish.json","recovery-deployment-publish.json.intent.json","rust-acceptance-arm-response.json","rust-acceptance-query-response.json","windows-bootstrap-request.json","windows-force-envelope.json","windows-install.json","windows-installer-exit.json","windows-mutation-permit.json","windows-prepared.json","windows-restart-receipt.json","windows-rollback.json","windows-validation.json"]
pre=["candidate-replacement-commit.json","candidate-retirement-terminal.json","coordinator-successor-windows-prestate.json","deployment-publish.json","launch-normal-v21.sh","linux-frozen.json","marker-handoff.json","normal-v21-candidate-retirement.intent.json"]
tree=ast.parse(body); values={}
for n in tree.body:
    if isinstance(n,ast.Assign) and len(n.targets)==1 and isinstance(n.targets[0],ast.Name) and n.targets[0].id in ("NORMAL","PRE"):
        values[n.targets[0].id]=ast.literal_eval(n.value)
assert values.get("NORMAL")==normal, "normal output array differs"
assert values.get("PRE")==pre, "pre-receipt array differs"
required=[
"--check-only|--execute|--resume|--replay","StrictHostKeyChecking=yes","BatchMode=yes","ConnectTimeout=10",
"Get-ScheduledTask","$x=Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath","Get-CimInstance Win32_Process","-EncodedCommand",
"os.O_TMPFILE","linkat","AT_EMPTY_PATH=0x1000","os.fsync(pfd)","fcntl.LOCK_EX|fcntl.LOCK_NB",
"candidate-successor" if False else "coordinator-successor-receipt.json","candidate-retirement-terminal.json",
"viewflow-normal-v21-coordinator-successor-authorized","viewflow-normal-v21-coordinator-successor-windows-prestate",
"marker-cli-path-alias-same-bytes-v1","only_handoff_field","receipt_producer_sha256","collector_sha256",
"deployment-quarantine.v1.release-claim","deployment-quarantine.v1.abort-claim",
".deployment-quarantine.v1.release-receipt.",".deployment-quarantine.v1.abort-receipt.",
"data[176:192]==uuid.UUID(COORD).bytes","int.from_bytes(data[200:208],\"little\")==1",
"verify_retired_archive(t)","intent.get(\"terminal_receipt\")==t","successor provenance does not bind coordinator bytes",
"successor provenance does not bind receipt producer bytes",
"req(not have_w and not have_r,\"check-only requires fresh successor outputs\")",
"req(not have_w and not have_r,\"execute requires fresh successor outputs\")",
"req(have_w and not have_r,\"resume requires Windows prestate and no receipt\")",
"req(have_w and have_r,\"replay requires both durable outputs\")",
"if MODE==\"--resume\":\n        ps_collect()",
]
for token in required: assert token in text, "missing contract token: "+token
assert text.index("collected=ps_collect()") < text.index("publish(rootfd,WPROOF_LEAF"), "proof publish precedes collection"
assert text.index("publish(rootfd,WPROOF_LEAF") < text.index("publish(rootfd,RECEIPT_LEAF"), "receipt precedes proof"
resume=text.index('if MODE=="--resume":\n        ps_collect()')
assert resume < text.index('if not have_r: publish(rootfd,RECEIPT_LEAF'), "resume recheck follows receipt publication"
assert 'StrictHostKeyChecking=no' not in text and 'os.replace(' not in text and 'shutil.move' not in text and 'catch{}' not in text
print("coordinator successor producer static checker passed")
PY
