#!/usr/bin/env bash
set -euo pipefail
root=/home/wilf/data/viewflow
stem=failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9
manifest=${VF_C9_SCHEMA7_MANIFEST:-$root/deploy/$stem-manifest.json}
gate=${VF_C9_SCHEMA7_GATE:-$root/deploy/$stem-gate.py}
launcher=$root/deploy/launch-$stem.sh
publisher=$root/deploy/publish-$stem-approval.py
hermetic=$root/deploy/tests/$stem-hermetic.py
op=c9b05e9bea4140d69f9d137a0f992ba0

if [[ ${1:-} == --post-state-contract-only && $# == 1 ]]; then
  VF_C9_SCHEMA7_GATE=$gate VF_C9_SCHEMA7_MANIFEST=$manifest \
    python3 "$hermetic" --post-state-only
  exit
fi
(( $# == 0 )) || exit 64

python3 - "$gate" "$publisher" <<'PY'
import pathlib,sys
for name in sys.argv[1:]: compile(pathlib.Path(name).read_bytes(),name,"exec")
PY
bash -n "$launcher"

# Stop a temporary coordinator image at its parser boundary: no preflight,
# systemd, SSH, marker access, or output publication can be reached.
python3 - "$manifest" <<'PY'
import json,os,pathlib,subprocess,sys,tempfile
m=json.loads(pathlib.Path(sys.argv[1]).read_bytes()); p=pathlib.Path(m["coordinator"]["path"])
s=p.read_text(encoding="utf-8"); needle="\ndone\n\nreplacement_flag_count=0"
if s.count(needle)!=1: raise SystemExit("coordinator parser boundary differs")
fd,name=tempfile.mkstemp(prefix="viewflow-c9-schema7-parser-",suffix=".sh")
try:
 os.fchmod(fd,0o700)
 with os.fdopen(fd,"w",encoding="utf-8",newline="\n") as out:
  out.write(s.replace(needle,"\ndone\nexit 0\n\nreplacement_flag_count=0",1));out.flush();os.fsync(out.fileno())
 r=subprocess.run(["/usr/bin/bash",name,*m["argv"][1:]],stdin=subprocess.DEVNULL,
  stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15,
  env={"HOME":"/home/wilf","USER":"wilf","LOGNAME":"wilf","PATH":"/usr/bin:/bin","LANG":"C.UTF-8","LC_ALL":"C.UTF-8"})
 if r.returncode: raise SystemExit("coordinator rejected schema7 argv: "+r.stderr.decode("utf-8","replace"))
finally:
 try: os.unlink(name)
 except FileNotFoundError: pass
PY

jq -e --arg op "$op" '
 def av($k):.argv as $a|($a|index($k))as$i|if $i==null then null else $a[$i+1] end;
 keys==["active_marker","approval_path","argv","coordinator","coordinator_instance_id","execution_authorized",
  "immutable_inputs","installed_linux","marker_generation","old_operation_id","operation_id","outputs",
  "post_state_contract","recovery_boundary","recovery_marker_generation","required_absent","schema_version","source_display_id",
  "state","target_device_id","windows_expected"] and .schema_version==1 and
 .state=="viewflow-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-command-manifest" and
 .execution_authorized==false and .operation_id==$op and .old_operation_id=="305058f7deb84c198bad4103d6c4f946" and
 .coordinator_instance_id=="86c03003-2b67-451d-a990-396e1a66b406" and
 .recovery_boundary=={phase:"WINDOWS_ROLLED_BACK",failure_phase:"WINDOWS_FORCE_ATTESTED",mutation_possible:true,
  force_release_executed:true,rollback_performed:true,linux_stage_committed:false,
  windows_install_committed:false,windows_installer_exit_present:false} and
 .active_marker.sha256=="9bc030e47e4d148341cf3cf540f318d291614b39769590a1035e2dcbc336f90a" and
 .immutable_inputs.coordinator_state.sha256=="066ef1bfa69aa09989204245c16d15c19eb66003a8a715f553c70b76976d7e8f" and
 .immutable_inputs.fresh_lineage.sha256=="6cc134872971fd1b25608c53e5e24d27ae5516ca1d457443ddeba91bda9fa982" and
 .immutable_inputs.marker_handoff.sha256=="28446fd53ca7b1d25e450f101184b233c3fcef37e1d58963521ba34e1a1a2076" and
 .immutable_inputs.deployment_publish.sha256=="fad236ea6eed12e2e132a977ba9d2fed625e54d1559045d66dff7899129a6335" and
 .immutable_inputs.linux_frozen.sha256=="39e5542fb275527e4420c80475e3339781d7d1e61c58c2728fe4a2b4a76aff4a" and
 .immutable_inputs.windows_request.sha256=="d03c7293236521937c0de597f0e59cd05965ed90276c58bb3baf6502b1547135" and
 .immutable_inputs.windows_prepared.sha256=="a11b2eabeebf4d0d9aa76e11a5af142701b16eaef87756f916ab0bbf6337054b" and
 .immutable_inputs.mutation_permit.sha256=="87e1e992872646b7e20600491b89aa599dd77465c8582f978e06d42973dfdc27" and
 .immutable_inputs.force_envelope.sha256=="70ea5caa3000f2577aed5fce8addeee78fa9ddfde628a4008d474db5358237d2" and
 .immutable_inputs.windows_stop.sha256=="f82b580dcaf51ea39df69499e6070472f8d31f043480d94b6b62ce72601dbf2f" and
 .windows_expected.deployment_task_state=="Disabled" and
 .windows_expected.deployment_task_claimed_pre_disable_xml_sha256=="d4cc1972a562c2a18c8a1995a23b70ac32369d42021898a7a2b06f4e72c5372c" and
 .windows_expected.deployment_task_xml_sha256=="f247c5766e1e5011816510d5b52174574e482aab0cee15f5db06de675bacbbd2" and
 .windows_expected.deployment_task_xml_sha256!=.windows_expected.deployment_task_claimed_pre_disable_xml_sha256 and
 .immutable_inputs.recovery_bundle.sha256=="77b68f5a6a084d48b59811f849f98e0aba6e471746ab1f69735f60586fd35e48" and
 .immutable_inputs.linux_deactivation.sha256=="7c5245a5ea6dffa2a9d72fc3356ba198c2365e26cbccbaf758581a34bd8f00be" and
 .immutable_inputs.linux_deactivation_transcript.sha256=="47611f2811baa4d31715274a8bccfdb7d40be2f3e3e6e8eff690ed5905bc1df3" and
 .immutable_inputs.windows_rollback.sha256=="ca74763dd4579323ab495aa164931892929cebd0aa05e6624d07233d0bbf4cc1" and
 .immutable_inputs.marker_cli_candidate.sha256=="266e052177aad1189b7a3b86f6e341347867aa1acd07f14dc64054bd4460d8cf" and
 .immutable_inputs.marker_cli_provenance.sha256=="a6fe424ecb5f050d7e7faaa9ec53c60b51b06758cf74a8dbb3352b4bc18051da" and
 .post_state_contract=={abi_magic:"VFDQA001",abi_size:384,durable_kind:"abort-receipt",
  retired_kind:"abort-retired",terminal_retired_field:"retired_claim_path",
  terminal_sha256_field:"vfdqa_binary_sha256",validator:"validate_post_state"} and
 av("--fresh-operation-lineage-receipt-sha256")==.immutable_inputs.fresh_lineage.sha256 and
 av("--post-force-abort-marker-cli-candidate")==.immutable_inputs.marker_cli_candidate.path and
 av("--post-force-abort-marker-cli-sha256")==.immutable_inputs.marker_cli_candidate.sha256 and
 av("--old-coordinator-state-sha256")==.immutable_inputs.coordinator_state.sha256 and
 (.argv|index("--failed-v13-original-generation-only"))!=null and
 (.argv|index("--release-deployment-marker"))==null and (.argv|index("--resume"))==null and
 ([.outputs[]]|length==(unique|length)) and (.approval_path as$p|.required_absent|index($p))!=null
' "$manifest" >/dev/null

for token in 'WINDOWS_FORCE_ATTESTED' 'fresh_operation_lineage_receipt_sha256' \
 'windows_force_envelope_sha256' 'linux_stage_committed' 'windows_install_committed' \
 'windows_installer_exit_present' 'abort-claim-atomic-retire-and-parent-directory-fsync' \
 'stable_generated_read' 'run_coordinator(manifest)' 'F_SEAL_WRITE' 'RENAME_NOREPLACE'; do
 rg -F --quiet "$token" "$gate" "$launcher"
done
! rg -F --quiet 'ReadToEnd' "$gate"
VF_C9_SCHEMA7_GATE=$gate VF_C9_SCHEMA7_MANIFEST=$manifest \
  python3 "$hermetic" --post-state-only >/dev/null

manifest_sha=$(sha256sum "$manifest"|cut -d' ' -f1); gate_sha=$(sha256sum "$gate"|cut -d' ' -f1)
launcher_sha=$(sha256sum "$launcher"|cut -d' ' -f1)
[[ $manifest_sha == 38fb016510df2964c7b7bf21d80facea67cfb0428d720885246bb5e01e0511a2 ]]
rg -F --quiet "MANIFEST_SHA = \"$manifest_sha\"" "$launcher" "$publisher"
rg -F --quiet "GATE_SHA = \"$gate_sha\"" "$launcher" "$publisher"
rg -F --quiet "LAUNCHER_SHA = \"$launcher_sha\"" "$publisher"
while IFS=$'\t' read -r path expected mode size; do
 [[ -f $path && ! -L $path && $(sha256sum "$path"|cut -d' ' -f1) == "$expected" ]]
 [[ $(stat -c '%u:%a:%h:%s' -- "$path") == "1000:$mode:1:$size" ]]
done < <(jq -r '(.coordinator|[.path,.sha256,(.mode|tostring),(.size|tostring)]),
 (.immutable_inputs[]|[.path,.sha256,(.mode|tostring),(.size|tostring)]),
 (.installed_linux[]|[.path,.sha256,(.mode|tostring),(.size|tostring)])|@tsv' "$manifest")
[[ ! -e $(jq -r .approval_path "$manifest") ]]
while IFS= read -r path; do [[ ! -e $path && ! -L $path ]]; done < <(jq -r '.outputs[]' "$manifest")
"$launcher" --offline-check
"$publisher" --check-only
echo 'c9b05e9 schema7 sealed-set static checker passed'
