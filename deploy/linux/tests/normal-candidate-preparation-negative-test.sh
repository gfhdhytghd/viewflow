#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GEN="$HERE/../prepare-normal-v21-operation-candidate.sh"
STATE=/home/wilf/.local/state/viewflow
OP=$(openssl rand -hex 16); COORD=792da663-4417-4674-a69c-0551a8a91a71; ROOT="$STATE/deployments/$OP"; CAND="$STATE/candidates/v21-operation-$OP"
MARKER="$ROOT/marker.bin"
trap 'rm -rf -- "$ROOT" "$CAND"' EXIT
mkdir -m 700 -- "$ROOT"; printf marker >"$MARKER"; chmod 600 "$MARKER"
python3 - "$ROOT" "$OP" "$COORD" "$MARKER" <<'PY'
import hashlib,json,os,sys
root,op,coord,marker=sys.argv[1:]; sha=lambda p:hashlib.sha256(open(p,'rb').read()).hexdigest()
dump=lambda p,x:(open(p,'w',encoding='utf-8').write(json.dumps(x,separators=(',',':'))+'\n'),os.chmod(p,0o600))
publish=root+'/deployment-publish.json'
p={"coordinator_instance_id":coord,"created_at_unix_ms":"1788495837814","created_at_utc":"2026-09-04T04:23:57.814Z","marker_generation":"1","marker_path":marker,"marker_sha256":sha(marker),"operation_id":op,"protocol_version":"2.1","schema_version":1,"source_display_id":"00000000-0000-0000-0000-000000000101","state":"deployment-quarantine-published","target_device_id":"00000000-0000-0000-0000-000000000002"}; dump(publish,p)
h={"schema_version":1,"state":"viewflow-v13-marker-handoff-prepared","protocol_version":"2.1","operation_id":op,"source_display_id":p["source_display_id"],"target_device_id":p["target_device_id"],"coordinator_instance_id":coord,"marker_generation":"1","marker_cli_path":"/home/wilf/.local/lib/viewflow/viewflow-deployment-marker","marker_cli_sha256":"e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5","deployment_marker_path":marker,"deployment_marker_sha256":sha(marker),"deployment_publish_receipt_path":publish,"deployment_publish_receipt_sha256":sha(publish),"deskflow_unit":"deskflow.service","deskflow_unit_active_state":"inactive","deskflow_unit_main_pid":0,"deskflow_executable_path":"/fixture/deskflow","deskflow_executable_sha256":"0"*64,"deskflow_exact_process_count":0,"deskflow_core_executable_path":"/fixture/deskflow-core","deskflow_core_executable_sha256":"1"*64,"deskflow_core_exact_process_count":0,"deskflow_tcp_port":24800,"deskflow_tcp_listener_count":0,"runtime_marker_path":"/home/wilf/.local/state/viewflow/deskflow-quarantine.v2","runtime_marker_present":False,"observed_at_utc":"2026-09-04T04:23:58.000Z"}; dump(root+'/marker-handoff.json',h)
f={"schema_version":1,"state":"viewflow-v13-bootstrap-frozen","operation_id":op,"daemon":{"boot_id":"b","daemon_instance_id":"d","executable":"/fixture/viewflowd","pid":1,"sha256":"2"*64,"start_ticks":1,"systemd_invocation_id":"i"},"journal":{"counts":{"cleanup_or_release_error":0,"input_event":0,"input_sidecar_activation":0,"lease_offered":0,"protocol_1_3_startup":1},"end_cursor":"e","end_realtime_timestamp_us":1,"entry_count":1,"protocol_startup_cursor":"p","protocol_startup_realtime_timestamp_us":1,"query_boot_id":"b","query_pid":"1","query_systemd_invocation_id":"i","slice_sha256":"3"*64,"start_cursor":"s","start_realtime_timestamp_us":1},"pre_stop":{"deskflow_core_exact_process_count":0,"deskflow_exact_process_count":0,"deskflow_main_pid":0,"deskflow_tcp_24800_listener_count":0,"deskflow_unit_active_state":"inactive"},"post_stop":{"command_output_format":"fixture","command_output_sha256":"4"*64,"command_outputs":{"exact_viewflow_pids":"","original_daemon_pid_present":"false","sidecar_socket_present":"false","systemctl_is_active":"inactive","systemctl_main_pid":"0","udp_44119_listeners":""},"exact_process_count":0,"main_pid":0,"original_daemon_pid_present":False,"sidecar_socket_present":False,"udp_44119_listener_count":0,"unit_active_state":"inactive"},"completed_at_unix_ms":1}; dump(root+'/linux-frozen.json',f)
PY
TERM="$ROOT/candidate-retirement-terminal.json"
python3 - "$ROOT" "$OP" "$COORD" "$TERM" <<'PY'
import hashlib,json,os,shutil,stat,sys
from pathlib import Path
root,op,coord,term=sys.argv[1:]; seed=Path('/home/wilf/.local/state/viewflow/candidates/v21-normal-seed-v3-20260904T123027Z-oZ1vdq'); archive=Path(root)/'retired-candidate-archive'; archive.mkdir(mode=0o700); files=[]
for src in sorted(seed.iterdir()):
 if src.is_file() and not src.is_symlink():
  dst=archive/src.name; shutil.copy2(src,dst); os.chmod(dst,stat.S_IMODE(os.stat(src).st_mode)); st=os.stat(src); files.append({'name':src.name,'mode':format(stat.S_IMODE(st.st_mode),'04o'),'size_bytes':st.st_size,'sha256':hashlib.sha256(src.read_bytes()).hexdigest()})
old_manifest=archive/'candidate-manifest.json'; old_manifest.write_text('old retired manifest\n',encoding='utf-8'); old_sha=hashlib.sha256(old_manifest.read_bytes()).hexdigest()
for item in files:
 if item['name']=='candidate-manifest.json': item['size_bytes']=old_manifest.stat().st_size; item['sha256']=old_sha
tree=hashlib.sha256(''.join('%s\0%s\0%s\0%s\n'%(x['name'],x['mode'],x['size_bytes'],x['sha256']) for x in files).encode()).hexdigest(); p=Path(root)/'deployment-publish.json'; h=Path(root)/'marker-handoff.json'; f=Path(root)/'linux-frozen.json'; m=Path(root)/'marker.bin'; b={'deployment_publish_path':str(p),'deployment_publish_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'marker_handoff_path':str(h),'marker_handoff_sha256':hashlib.sha256(h.read_bytes()).hexdigest(),'linux_frozen_path':str(f),'linux_frozen_sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'deployment_marker_path':str(m),'deployment_marker_sha256':hashlib.sha256(m.read_bytes()).hexdigest()}; old={'canonical_path':str(Path('/home/wilf/.local/state/viewflow/candidates/v21-operation-'+op)),'archive_path':str(archive),'manifest_sha256':old_sha,'tree_sha256':tree,'files':files}; t={'schema_version':1,'state':'viewflow-normal-v21-candidate-retired','operation_id':op,'coordinator_instance_id':coord,'replacement_ordinal':1,'created_at_unix_ms':1,'created_at_utc':'2026-09-04T00:00:00.001Z','operation_root':str(root),'candidate_root':str(Path('/home/wilf/.local/state/viewflow/candidates/v21-operation-'+op)),'old_candidate':old,'fresh_boundary':b,'authorized_seed':{'root':str(seed),'candidate_manifest_path':str(seed/'candidate-manifest.json'),'candidate_manifest_sha256':hashlib.sha256((seed/'candidate-manifest.json').read_bytes()).hexdigest()},'pre_retirement':{'coordinator_state_path':str(Path(root)/'coordinator-state.json'),'coordinator_state_absent':True,'standard_normal_outputs_absent':True}}; Path(term).write_text(json.dumps(t,separators=(',',':'))+'\n'); os.chmod(term,0o600)
PY
TERM_SHA=$(sha256sum "$TERM"|awk '{print $1}')
run_with_term() { local term_path=$1 term_sha=$2; shift 2; bash "$GEN" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$ROOT/marker-handoff.json" --frozen "$ROOT/linux-frozen.json" --publish "$ROOT/deployment-publish.json" --candidate-retirement-terminal "$term_path" --candidate-retirement-terminal-sha256 "$term_sha" "$@"; }
run() { run_with_term "$TERM" "$TERM_SHA" "$@"; }
reject() { if "$@" >/dev/null 2>&1; then echo "accepted unsafe input" >&2; exit 1; fi; }
run_paths() {
 local handoff_path=$1 frozen_path=$2 publish_path=$3
 shift 3
 bash "$GEN" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$handoff_path" --frozen "$frozen_path" --publish "$publish_path" "$@"
}
reject bash "$GEN" --operation-id BAD --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$ROOT/marker-handoff.json" --frozen "$ROOT/linux-frozen.json" --publish "$ROOT/deployment-publish.json" --check-only
ln -s "$ROOT/marker-handoff.json" "$ROOT/handoff-link"
reject bash "$GEN" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$ROOT/handoff-link" --frozen "$ROOT/linux-frozen.json" --publish "$ROOT/deployment-publish.json" --check-only
rm "$ROOT/handoff-link"
jq '.unexpected=true' "$ROOT/marker-handoff.json" >"$ROOT/handoff-mutated"; chmod 600 "$ROOT/handoff-mutated"
reject bash "$GEN" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$ROOT/handoff-mutated" --frozen "$ROOT/linux-frozen.json" --publish "$ROOT/deployment-publish.json" --check-only
jq -c . "$ROOT/deployment-publish.json" | sed '$s/}$/,"schema_version":1}/' >"$ROOT/publish-duplicate.json"; chmod 600 "$ROOT/publish-duplicate.json"
reject run_paths "$ROOT/marker-handoff.json" "$ROOT/linux-frozen.json" "$ROOT/publish-duplicate.json" --check-only
sed 's/"deskflow_unit_main_pid":[[:space:]]*0/"deskflow_unit_main_pid": 0.0/' "$ROOT/marker-handoff.json" >"$ROOT/handoff-float.json"; chmod 600 "$ROOT/handoff-float.json"
reject run_paths "$ROOT/handoff-float.json" "$ROOT/linux-frozen.json" "$ROOT/deployment-publish.json" --check-only
sed 's/"completed_at_unix_ms":[[:space:]]*[0-9][0-9]*/"completed_at_unix_ms": NaN/' "$ROOT/linux-frozen.json" >"$ROOT/frozen-nan.json"; chmod 600 "$ROOT/frozen-nan.json"
reject run_paths "$ROOT/marker-handoff.json" "$ROOT/frozen-nan.json" "$ROOT/deployment-publish.json" --check-only
sed 's/"completed_at_unix_ms":[[:space:]]*[0-9][0-9]*/"completed_at_unix_ms": Infinity/' "$ROOT/linux-frozen.json" >"$ROOT/frozen-infinity.json"; chmod 600 "$ROOT/frozen-infinity.json"
reject run_paths "$ROOT/marker-handoff.json" "$ROOT/frozen-infinity.json" "$ROOT/deployment-publish.json" --check-only
cp "$ROOT/deployment-publish.json" "$ROOT/publish-trailing.json"; printf ' trailing-garbage' >>"$ROOT/publish-trailing.json"
reject run_paths "$ROOT/marker-handoff.json" "$ROOT/linux-frozen.json" "$ROOT/publish-trailing.json" --check-only
python3 -c 'from pathlib import Path; import sys; Path(sys.argv[2]).write_bytes(Path(sys.argv[1]).read_bytes()+b"\xff")' "$ROOT/deployment-publish.json" "$ROOT/publish-invalid-utf8.json"; chmod 600 "$ROOT/publish-invalid-utf8.json"
reject run_paths "$ROOT/marker-handoff.json" "$ROOT/linux-frozen.json" "$ROOT/publish-invalid-utf8.json" --check-only
SEED_ORIG="$STATE/candidates/v21-normal-seed-v3-20260904T123027Z-oZ1vdq"; SEED_TEST="$ROOT/seed"; mkdir -m 700 "$SEED_TEST"; cp -p "$SEED_ORIG"/* "$SEED_TEST/"
GEN_SEED="$ROOT/generator-seed-test.sh"
sed "s#S=Path(\"/home/wilf/.local/state/viewflow\"); SEED=S/\"candidates/v21-normal-seed-v3-20260904T123027Z-oZ1vdq\"#S=Path(\"/home/wilf/.local/state/viewflow\"); SEED=Path(\"$SEED_TEST\")#" "$GEN" >"$GEN_SEED"; chmod 700 "$GEN_SEED"
sed '$s/}$/,"schema_version":1}/' "$SEED_TEST/candidate-manifest.json" >"$SEED_TEST/candidate-manifest-duplicate.json"; mv "$SEED_TEST/candidate-manifest-duplicate.json" "$SEED_TEST/candidate-manifest.json"
reject bash "$GEN_SEED" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$ROOT/marker-handoff.json" --frozen "$ROOT/linux-frozen.json" --publish "$ROOT/deployment-publish.json" --check-only
cp "$TERM" "$ROOT/alternate-terminal.json"; chmod 600 "$ROOT/alternate-terminal.json"
reject run_with_term "$ROOT/alternate-terminal.json" "$TERM_SHA" --check-only
rm -rf -- "$SEED_TEST"
mkdir -m 700 "$SEED_TEST"
cp -p "$SEED_ORIG"/* "$SEED_TEST/"
jq '.windows.viewflowd_sha256 = ("0" * 64)' "$SEED_TEST/candidate-manifest.json" >"$SEED_TEST/candidate-manifest-mutated.json"
mv -- "$SEED_TEST/candidate-manifest-mutated.json" "$SEED_TEST/candidate-manifest.json"
chmod 600 "$SEED_TEST/candidate-manifest.json"
reject bash "$GEN_SEED" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$ROOT/marker-handoff.json" --frozen "$ROOT/linux-frozen.json" --publish "$ROOT/deployment-publish.json" --check-only
run >/dev/null
cp "$CAND/candidate-manifest.json" "$ROOT/manifest.saved"
jq 'del(.candidate_replacement) | .schema_version=1' "$ROOT/manifest.saved" >"$CAND/candidate-manifest.json"; chmod 600 "$CAND/candidate-manifest.json"
reject run --resume
mv "$ROOT/manifest.saved" "$CAND/candidate-manifest.json"
cp "$ROOT/retired-candidate-archive/windows-source.tar.gz" "$ROOT/archive.saved"
printf tampered >>"$ROOT/retired-candidate-archive/windows-source.tar.gz"
reject run --resume
mv "$ROOT/archive.saved" "$ROOT/retired-candidate-archive/windows-source.tar.gz"
ln -s "$ROOT/retired-candidate-archive/candidate-manifest.json" "$ROOT/retired-candidate-archive/extra-link"
reject run --resume
rm "$ROOT/retired-candidate-archive/extra-link"
ln -s "$CAND/windows-viewflowd.exe" "$CAND/extra-link"
reject run --resume
rm "$CAND/extra-link"
cp "$TERM" "$ROOT/term.saved"
printf tampered >>"$TERM"
reject run --resume
mv "$ROOT/term.saved" "$TERM"
COMMIT_SHA=$(sha256sum "$ROOT/candidate-replacement-commit.json"|awk '{print $1}')
run --resume >/dev/null
[[ $(sha256sum "$ROOT/candidate-replacement-commit.json"|awk '{print $1}') == "$COMMIT_SHA" ]]
printf 'normal candidate preparation negative test passed\n'
