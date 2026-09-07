#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GEN="$HERE/../prepare-normal-v21-operation-candidate.sh"
STATE=/home/wilf/.local/state/viewflow
OP=$(openssl rand -hex 16)
COORD=792da663-4417-4674-a69c-0551a8a91a71
ROOT="$STATE/deployments/$OP"
CAND="$STATE/candidates/v21-operation-$OP"
MARKER="$ROOT/marker.bin"
trap 'rm -rf -- "$ROOT" "$CAND"' EXIT
mkdir -m 700 -- "$ROOT"
printf marker >"$MARKER"; chmod 600 "$MARKER"
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
root,op,coord,term=sys.argv[1:]; seed=Path('/home/wilf/.local/state/viewflow/candidates/v21-normal-seed-v3-20260904T123027Z-oZ1vdq'); archive=Path(root)/'retired-candidate-archive'; archive.mkdir(mode=0o700)
files=[]
for src in sorted(seed.iterdir()):
 if not src.is_file() or src.is_symlink(): continue
 dst=archive/src.name; shutil.copy2(src,dst); os.chmod(dst,stat.S_IMODE(os.stat(src).st_mode)); h=hashlib.sha256(src.read_bytes()).hexdigest(); st=os.stat(src)
 files.append({'name':src.name,'mode':format(stat.S_IMODE(st.st_mode),'04o'),'size_bytes':st.st_size,'sha256':h})
old_manifest=archive/'candidate-manifest.json'; old_manifest.write_text('old retired manifest\n',encoding='utf-8'); old_sha=hashlib.sha256(old_manifest.read_bytes()).hexdigest()
for item in files:
 if item['name']=='candidate-manifest.json': item['size_bytes']=old_manifest.stat().st_size; item['sha256']=old_sha
payload=''.join('%s\0%s\0%s\0%s\n'%(x['name'],x['mode'],x['size_bytes'],x['sha256']) for x in files).encode(); tree=hashlib.sha256(payload).hexdigest()
publish=Path(root)/'deployment-publish.json'; handoff=Path(root)/'marker-handoff.json'; frozen=Path(root)/'linux-frozen.json'; marker=Path(root)/'marker.bin'; b={'deployment_publish_path':str(publish),'deployment_publish_sha256':hashlib.sha256(publish.read_bytes()).hexdigest(),'marker_handoff_path':str(handoff),'marker_handoff_sha256':hashlib.sha256(handoff.read_bytes()).hexdigest(),'linux_frozen_path':str(frozen),'linux_frozen_sha256':hashlib.sha256(frozen.read_bytes()).hexdigest(),'deployment_marker_path':str(marker),'deployment_marker_sha256':hashlib.sha256(marker.read_bytes()).hexdigest()}
t={'schema_version':1,'state':'viewflow-normal-v21-candidate-retired','operation_id':op,'coordinator_instance_id':coord,'replacement_ordinal':1,'created_at_unix_ms':1,'created_at_utc':'2026-09-04T00:00:00.001Z','operation_root':str(root),'candidate_root':str(Path('/home/wilf/.local/state/viewflow/candidates/v21-operation-'+op)),'old_candidate':{'canonical_path':str(Path('/home/wilf/.local/state/viewflow/candidates/v21-operation-'+op)),'archive_path':str(archive),'manifest_sha256':old_sha,'tree_sha256':tree,'files':files},'fresh_boundary':b,'authorized_seed':{'root':str(seed),'candidate_manifest_path':str(seed/'candidate-manifest.json'),'candidate_manifest_sha256':hashlib.sha256((seed/'candidate-manifest.json').read_bytes()).hexdigest()},'pre_retirement':{'coordinator_state_path':str(Path(root)/'coordinator-state.json'),'coordinator_state_absent':True,'standard_normal_outputs_absent':True}}
with open(term,'w',encoding='utf-8') as f: json.dump(t,f,separators=(',',':')); f.write('\n')
os.chmod(term,0o600)
PY
TERM_SHA=$(sha256sum "$TERM"|awk '{print $1}')
run() { bash "$GEN" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$ROOT/marker-handoff.json" --frozen "$ROOT/linux-frozen.json" --publish "$ROOT/deployment-publish.json" --candidate-retirement-terminal "$TERM" --candidate-retirement-terminal-sha256 "$TERM_SHA" "$@"; }
reject() { if "$@" >/dev/null 2>&1; then echo "accepted unsafe JSON" >&2; exit 1; fi; }
run_paths() {
 local handoff_path=$1 frozen_path=$2 publish_path=$3
 shift 3
 bash "$GEN" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$handoff_path" --frozen "$frozen_path" --publish "$publish_path" --candidate-retirement-terminal "$TERM" --candidate-retirement-terminal-sha256 "$TERM_SHA" "$@"
}
run --check-only >/dev/null
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
reject bash "$GEN_SEED" --operation-id "$OP" --coordinator-uuid "$COORD" --fresh-root "$ROOT" --handoff "$ROOT/marker-handoff.json" --frozen "$ROOT/linux-frozen.json" --publish "$ROOT/deployment-publish.json" --candidate-retirement-terminal "$TERM" --candidate-retirement-terminal-sha256 "$TERM_SHA" --check-only
run >/dev/null
[[ -d "$CAND" && ! -L "$CAND" && $(stat -c '%a:%u:%h' "$CAND") == 700:1000:1 ]]
[[ $(find "$CAND" -maxdepth 1 -type f | wc -l) -eq 6 ]]
[[ -f "$ROOT/candidate-replacement-commit.json" ]]
jq -e --arg term "$TERM" --arg sha "$TERM_SHA" '.schema_version==2 and .candidate_replacement.retirement_terminal_path==$term and .candidate_replacement.retirement_terminal_sha256==$sha and .candidate_replacement.replacement_ordinal==1' "$CAND/candidate-manifest.json" >/dev/null
jq -e --arg op "$OP" --arg c "$COORD" --arg root "$ROOT" --arg m "$MARKER"   '.operation_id==$op and .coordinator_instance_id==$c and .protocol_version=="2.1" and .sidecar_protocol_version==3 and .fresh_boundary.root==$root and .fresh_boundary.deployment_marker==$m and (.windows.viewflowd|endswith("/v21-operation-"+$op+"/windows-viewflowd.exe"))'   "$CAND/candidate-manifest.json" >/dev/null
ln -s "$ROOT/retired-candidate-archive/candidate-manifest.json" "$ROOT/retired-candidate-archive/fixture-extra-link"
reject run --resume
rm "$ROOT/retired-candidate-archive/fixture-extra-link"
ln -s "$CAND/windows-viewflowd.exe" "$CAND/fixture-extra-link"
reject run --resume
rm "$CAND/fixture-extra-link"
M=$(sha256sum "$CAND/candidate-manifest.json"|awk '{print $1}')
if run >/dev/null 2>&1; then echo collision accepted >&2; exit 1; fi
[[ $(sha256sum "$CAND/candidate-manifest.json"|awk '{print $1}') == "$M" ]]
COMMIT_SHA=$(sha256sum "$ROOT/candidate-replacement-commit.json"|awk '{print $1}')
rm "$ROOT/candidate-replacement-commit.json"
run --resume >/dev/null
COMMIT_RESUMED=$(sha256sum "$ROOT/candidate-replacement-commit.json"|awk '{print $1}')
[[ -n "$COMMIT_RESUMED" ]]
run --resume >/dev/null
[[ $(sha256sum "$ROOT/candidate-replacement-commit.json"|awk '{print $1}') == "$COMMIT_RESUMED" ]]
printf 'normal candidate preparation fixture passed (manifest=%s)\n' "$M"
