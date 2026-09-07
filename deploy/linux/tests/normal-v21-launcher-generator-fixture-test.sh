#!/usr/bin/env bash
# Hermetic success fixture.  It rewrites only a private copy of the generator
# so the source-pinned candidates remain the production ones.
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SOURCE="$HERE/../generate-normal-v21-launcher.sh"
readonly OP=11111111111111111111111111111111
readonly COORD=792da663-4417-4674-a69c-0551a8a91a71
readonly SEED=/home/wilf/.local/state/viewflow/candidates/v21-normal-seed-v3-20260904T123027Z-oZ1vdq
readonly RUST=/home/wilf/.local/state/viewflow/candidates/linux-rust-release-cleanenv-v3-20260904T123027Z-oZ1vdq
env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$RUST/source-stage/deploy/linux/check-viewflow-release-provenance.sh" \
    --manifest "$RUST/viewflow-linux-rust-release-provenance.json" \
    --manifest-sha256 53c1155422f141af639058d767a42eebcc76e59a7aa71951b913b0ddaf22ee47 >/dev/null
root=$(mktemp -d --tmpdir 'viewflow-normal-launcher.XXXXXX')
if [[ ${VIEWFLOW_FIXTURE_KEEP_ROOT:-0} == 1 ]]; then
    trap ':' EXIT
else
    trap 'rm -rf -- "$root"' EXIT
fi
mkdir -m 700 "$root/fresh" "$root/candidate"
printf 'fixture marker\n' >"$root/marker"
chmod 600 "$root/marker"
for leaf in windows-viewflowd.exe windows-native-provenance.json windows-source.manifest.sha256 windows-source.tar.gz windows-source.tar.gz.sha256; do cp -- "$SEED/$leaf" "$root/candidate/$leaf"; done
chmod 600 "$root/candidate"/*
chmod 700 "$root/candidate/windows-viewflowd.exe"
python3 - "$root" "$SEED/candidate-manifest.json" "$OP" "$COORD" <<'PY'
import hashlib,json,os,sys
root,seed,op,coord=sys.argv[1:]
fresh=root+'/fresh'; marker=root+'/marker'; cand=root+'/candidate'
sha=lambda p:hashlib.sha256(open(p,'rb').read()).hexdigest()
old=root+'/old-candidate-archive'; os.mkdir(old,0o700)
for name in ('windows-viewflowd.exe','windows-native-provenance.json','windows-source.manifest.sha256','windows-source.tar.gz','windows-source.tar.gz.sha256'):
 with open(old+'/'+name,'wb') as out: out.write(b'old-'+name.encode())
 os.chmod(old+'/'+name,0o700 if name=='windows-viewflowd.exe' else 0o600)
with open(old+'/candidate-manifest.json','w',encoding='utf-8') as out: out.write('{"old":true}\n')
os.chmod(old+'/candidate-manifest.json',0o600)
old_manifest_sha=sha(old+'/candidate-manifest.json')
def tree_records(root):
 out=[]
 for name in sorted(os.listdir(root)):
  p=root+'/'+name; st=os.lstat(p); out.append({"name":name,"mode":format(st.st_mode & 0o7777,'04o'),"size_bytes":st.st_size,"sha256":sha(p)})
 raw=b''.join((x['name']+'\0'+x['mode']+'\0'+str(x['size_bytes'])+'\0'+x['sha256']+'\n').encode() for x in out)
 return out,hashlib.sha256(raw).hexdigest()
base={"schema_version":1,"state":"deployment-quarantine-published","protocol_version":"2.1","operation_id":op,"coordinator_instance_id":coord,"marker_generation":"1","source_display_id":"00000000-0000-0000-0000-000000000101","target_device_id":"00000000-0000-0000-0000-000000000002","marker_path":marker,"marker_sha256":sha(marker),"created_at_unix_ms":"1788495837814","created_at_utc":"2026-09-04T04:23:57.814Z"}
dump=lambda p,x:open(p,'w',encoding='utf-8').write(json.dumps(x,sort_keys=False,separators=(',',':'))+'\n')
publish=fresh+'/deployment-publish.json'; dump(publish,base)
h={"schema_version":1,"state":"viewflow-v13-marker-handoff-prepared","protocol_version":"2.1","operation_id":op,"coordinator_instance_id":coord,"marker_generation":"1","source_display_id":base["source_display_id"],"target_device_id":base["target_device_id"],"deployment_marker_path":marker,"deployment_marker_sha256":sha(marker),"deployment_publish_receipt_path":publish,"deployment_publish_receipt_sha256":sha(publish),"marker_cli_path":"/home/wilf/.local/lib/viewflow/viewflow-deployment-marker","marker_cli_sha256":"e3c981f57a775d343c9e62a7d604a3d4aa3e79f3014e64c9ed8c9e6bbf1581f5","runtime_marker_path":"/home/wilf/.local/state/viewflow/deskflow-quarantine.v2","runtime_marker_present":False,"deskflow_unit":"deskflow.service","deskflow_unit_active_state":"inactive","deskflow_unit_main_pid":0,"deskflow_tcp_port":24800,"deskflow_tcp_listener_count":0,"deskflow_executable_path":"/fixture/deskflow","deskflow_executable_sha256":"0"*64,"deskflow_exact_process_count":0,"deskflow_core_executable_path":"/fixture/deskflow-core","deskflow_core_executable_sha256":"1"*64,"deskflow_core_exact_process_count":0,"observed_at_utc":"2026-09-04T04:23:58.000Z"}
handoff=fresh+'/marker-handoff.json'; dump(handoff,h)
f={"schema_version":1,"state":"viewflow-v13-bootstrap-frozen","operation_id":op,"daemon":{"boot_id":"b","daemon_instance_id":"d","executable":"/fixture/viewflowd","pid":1,"sha256":"2"*64,"start_ticks":1,"systemd_invocation_id":"i"},"journal":{"counts":{"cleanup_or_release_error":0,"input_event":0,"input_sidecar_activation":0,"lease_offered":0,"protocol_1_3_startup":1},"end_cursor":"e","end_realtime_timestamp_us":1,"entry_count":1,"protocol_startup_cursor":"p","protocol_startup_realtime_timestamp_us":1,"query_boot_id":"b","query_pid":"1","query_systemd_invocation_id":"i","slice_sha256":"3"*64,"start_cursor":"s","start_realtime_timestamp_us":1},"pre_stop":{"deskflow_core_exact_process_count":0,"deskflow_exact_process_count":0,"deskflow_main_pid":0,"deskflow_tcp_24800_listener_count":0,"deskflow_unit_active_state":"inactive"},"post_stop":{"command_output_format":"fixture","command_output_sha256":"4"*64,"command_outputs":{"exact_viewflow_pids":"","original_daemon_pid_present":"false","sidecar_socket_present":"false","systemctl_is_active":"inactive","systemctl_main_pid":"0","udp_44119_listeners":""},"exact_process_count":0,"main_pid":0,"original_daemon_pid_present":False,"sidecar_socket_present":False,"udp_44119_listener_count":0,"unit_active_state":"inactive"},"completed_at_unix_ms":1}
frozen=fresh+'/linux-frozen.json'; dump(frozen,f)
m=json.load(open(seed,encoding='utf-8')); m['operation_id']=op; m['coordinator_instance_id']=coord
m['fresh_boundary']={"root":fresh,"deployment_marker":marker,"deployment_marker_sha256":sha(marker),"deployment_publish_receipt_sha256":sha(publish),"marker_handoff_sha256":sha(handoff),"linux_frozen_sha256":sha(frozen)}
m['windows']['viewflowd']=cand+'/windows-viewflowd.exe'; m['windows']['native_provenance']=cand+'/windows-native-provenance.json'
schema1=json.loads(json.dumps(m))
term_path=fresh+'/candidate-retirement-terminal.json'; commit_path=fresh+'/candidate-replacement-commit.json'
old_files,old_tree_sha=tree_records(old)
term={"schema_version":1,"state":"viewflow-normal-v21-candidate-retired","operation_id":op,"coordinator_instance_id":coord,"replacement_ordinal":1,"created_at_unix_ms":1788495837814,"created_at_utc":"2026-09-04T04:23:57.814Z","operation_root":fresh,"candidate_root":cand,"old_candidate":{"canonical_path":cand,"archive_path":old,"manifest_sha256":old_manifest_sha,"tree_sha256":old_tree_sha,"files":old_files},"fresh_boundary":{"deployment_publish_path":publish,"deployment_publish_sha256":sha(publish),"marker_handoff_path":handoff,"marker_handoff_sha256":sha(handoff),"linux_frozen_path":frozen,"linux_frozen_sha256":sha(frozen),"deployment_marker_path":marker,"deployment_marker_sha256":sha(marker)},"authorized_seed":{"root":os.path.dirname(seed),"candidate_manifest_path":seed,"candidate_manifest_sha256":sha(seed)},"pre_retirement":{"coordinator_state_path":fresh+'/coordinator-state.json',"coordinator_state_absent":True,"standard_normal_outputs_absent":True}}
dump(term_path,term); term_sha=sha(term_path)
replacement={"retirement_terminal_path":term_path,"retirement_terminal_sha256":term_sha,"old_candidate_manifest_sha256":old_manifest_sha,"replacement_ordinal":1,"authorized_seed_manifest_sha256":sha(seed)}
ordered={}
for key in m:
 ordered[key]=m[key]
 if key=='fresh_boundary': ordered['candidate_replacement']=replacement
m=ordered; m['schema_version']=2
dump(cand+'/candidate-manifest.json',m)
dump(root+'/candidate-manifest-schema1.json',schema1)
dump(root+'/candidate-manifest-schema2.json',m)
candidate_files,candidate_tree_sha=tree_records(cand)
commit={"schema_version":1,"state":"viewflow-normal-v21-candidate-replacement-committed","operation_id":op,"coordinator_instance_id":coord,"replacement_ordinal":1,"created_at_unix_ms":1788495837814,"created_at_utc":"2026-09-04T04:23:57.814Z","operation_root":fresh,"candidate_root":cand,"candidate_manifest_path":cand+'/candidate-manifest.json',"candidate_manifest_sha256":sha(cand+'/candidate-manifest.json'),"candidate_tree_sha256":candidate_tree_sha,"retirement_terminal_path":term_path,"retirement_terminal_sha256":term_sha,"old_candidate_archive_path":old,"old_candidate_manifest_sha256":old_manifest_sha,"authorized_seed_manifest_sha256":sha(seed),"fresh_boundary":term['fresh_boundary']}
dump(commit_path,commit)
for name in ('deployment-publish.json','marker-handoff.json','linux-frozen.json'):
 os.chmod(fresh+'/'+name,0o600)
os.chmod(cand+'/candidate-manifest.json',0o600)
os.chmod(root+'/candidate-manifest-schema1.json',0o600)
os.chmod(root+'/candidate-manifest-schema2.json',0o600)
PY
GENERATOR="$root/generator.sh"
python3 - "$SOURCE" "$GENERATOR" "$root/candidate" <<'PY'
import sys
text=open(sys.argv[1],encoding='utf-8').read(); cand=sys.argv[3]
text=text.replace('readonly CAND="$STATE_ROOT/candidates/v21-operation-$operation_id"', 'readonly CAND='+repr(cand))
text=text.replace('readonly CAND="/home/wilf/.local/state/viewflow/candidates/v21-operation-$OP"', 'readonly CAND='+repr(cand))
open(sys.argv[2],'w',encoding='utf-8').write(text)
PY
chmod 700 "$GENERATOR"
readonly OUTPUT_SCHEMA1="$root/launch-normal-v21-schema1.sh"
cp -- "$root/candidate-manifest-schema1.json" "$root/candidate/candidate-manifest.json"
chmod 600 "$root/candidate/candidate-manifest.json"
schema1_sha=$(sha256sum -- "$root/candidate/candidate-manifest.json" | awk '{print $1}')
bash "$GENERATOR" --operation-id "$OP" --coordinator-uuid "$COORD" --candidate-manifest-sha256 "$schema1_sha" --fresh-root "$root/fresh" --handoff "$root/fresh/marker-handoff.json" --frozen "$root/fresh/linux-frozen.json" --publish "$root/fresh/deployment-publish.json" --output "$OUTPUT_SCHEMA1"
env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$OUTPUT_SCHEMA1" --check-only >/dev/null
cp -- "$root/candidate-manifest-schema2.json" "$root/candidate/candidate-manifest.json"
chmod 600 "$root/candidate/candidate-manifest.json"
manifest_sha=$(sha256sum -- "$root/candidate/candidate-manifest.json" | awk '{print $1}')
readonly OUTPUT="$root/launch-normal-v21.sh"
bash "$GENERATOR" --operation-id "$OP" --coordinator-uuid "$COORD" --candidate-manifest-sha256 "$manifest_sha" --fresh-root "$root/fresh" --handoff "$root/fresh/marker-handoff.json" --frozen "$root/fresh/linux-frozen.json" --publish "$root/fresh/deployment-publish.json" --output "$OUTPUT"
[[ $(stat -c '%a:%u:%h' -- "$OUTPUT") == 500:1000:1 ]]
bash -n "$OUTPUT"
shellcheck -s bash "$OUTPUT"
env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$OUTPUT" --check-only >/dev/null
rg -Fq -- 'usage: launch-normal-v21.sh [--check-only|--execute|--resume]' "$OUTPUT"
rg -Fq -- 'coordinator_mode+=(--resume)' "$OUTPUT"
for token in '--candidate-retirement-terminal' '--candidate-retirement-terminal-sha256' '--candidate-replacement-commit' '--candidate-replacement-commit-sha256'; do
    rg -Fq -- "$token" "$OUTPUT" || { printf 'missing generated replacement token: %s\n' "$token" >&2; exit 1; }
done
# Route one private execute through a parser stub so the fixture exercises the
# four schema-2 replacement argv fields, including fail-closed missing-field
# behavior, without invoking the production coordinator or touching services.
readonly PARSER="$root/coordinator-parser.sh"
python3 - "$PARSER" <<'PY'
import sys
p=sys.argv[1]
open(p,'w',encoding='utf-8').write('''#!/usr/bin/env bash
set -Eeuo pipefail
seen=()
while (($#)); do
    case $1 in
        --candidate-retirement-terminal|--candidate-retirement-terminal-sha256|--candidate-replacement-commit|--candidate-replacement-commit-sha256)
            (($# >= 2)) || exit 64
            seen+=("$1")
            shift 2
            ;;
        *) shift ;;
    esac
done
for flag in --candidate-retirement-terminal --candidate-retirement-terminal-sha256 --candidate-replacement-commit --candidate-replacement-commit-sha256; do
    count=0
    for got in "${seen[@]}"; do [[ $got == "$flag" ]] && ((count+=1)); done
    [[ $count == 1 ]] || exit 64
done
exit 0
''')
PY
chmod 700 "$PARSER"
chmod 600 "$OUTPUT"
python3 - "$OUTPUT" "$PARSER" <<'PY'
import hashlib,sys
out,parser=sys.argv[1:]
text=open(out,encoding='utf-8').read()
old='readonly COORDINATOR="$SRC/deploy/coordinated-v13-to-v2.sh"'
assert text.count(old)==1
text=text.replace(old,'readonly COORDINATOR='+repr(parser),1)
old='check_file "$COORDINATOR" 986f4ce5d86cb9e049328705fecc1be27e26c348176e4ff5b41235e675ae4970'
assert text.count(old)==1
text=text.replace(old,'check_file "$COORDINATOR" '+hashlib.sha256(open(parser,'rb').read()).hexdigest(),1)
open(out,'w',encoding='utf-8').write(text)
PY
chmod 500 "$OUTPUT"
env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$OUTPUT" --execute >/dev/null
readonly MISSING="$root/launch-normal-v21-missing-replacement.sh"
cp -- "$OUTPUT" "$MISSING"
chmod 600 "$MISSING"
python3 - "$MISSING" <<'PY'
import sys
p=sys.argv[1]; text=open(p,encoding='utf-8').read()
needle='--candidate-replacement-commit-sha256 "$REPLACEMENT_COMMIT_SHA"'
assert text.count(needle)==1
open(p,'w',encoding='utf-8').write(text.replace(needle,'--missing-replacement-commit-sha256',1))
PY
chmod 500 "$MISSING"
if env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$MISSING" --execute >/dev/null 2>&1; then
    printf 'coordinator parser accepted missing replacement field\n' >&2
    exit 1
fi
before=$(sha256sum -- "$OUTPUT" | awk '{print $1}')
if bash "$GENERATOR" --operation-id "$OP" --coordinator-uuid "$COORD" --candidate-manifest-sha256 "$manifest_sha" --fresh-root "$root/fresh" --handoff "$root/fresh/marker-handoff.json" --frozen "$root/fresh/linux-frozen.json" --publish "$root/fresh/deployment-publish.json" --output "$OUTPUT" >/dev/null 2>&1; then printf 'create-once output was replaced\n' >&2; exit 1; fi
[[ $(sha256sum -- "$OUTPUT" | awk '{print $1}') == "$before" ]]
[[ ${VIEWFLOW_FIXTURE_KEEP_ROOT:-0} == 1 ]] && printf 'fixture-root=%s\n' "$root"
printf 'normal v2.1 launcher generator fixture passed\n'
