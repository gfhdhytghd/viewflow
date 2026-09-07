#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1003
set -Eeuo pipefail
umask 077
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source=$here/../generate-normal-v21-successor-launcher.sh
tmp=$(mktemp -d --tmpdir successor-launcher.XXXXXX); trap 'rm -rf -- "$tmp"' EXIT
op=0123456789abcdef0123456789abcdef; coord=11111111-2222-3333-4444-555555555555
state=$tmp/state; root=$state/deployments/$op; mkdir -p "$root"; chmod 700 "$root"
# A copied, compile-time-substituted generator is the only test override.
gen=$tmp/generator.sh; sed "s|^readonly STATE=.*|readonly STATE=$state|" "$source" >"$gen"; chmod 700 "$gen"
base=$root/launch-normal-v21.sh
printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'die(){ exit 1; }' 'check_file(){ [[ -f $1 && ! -L $1 ]]; }' 'readonly OP=0123456789abcdef0123456789abcdef' 'readonly COORD=11111111-2222-3333-4444-555555555555' 'readonly ROOT=ROOT_REPLACE' 'readonly MARKER_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'readonly CAND=/tmp/candidate' 'readonly COORDINATOR=/tmp/v3' '[[ $# -le 1 ]] || die '\''usage: launch-normal-v21.sh [--check-only|--execute|--resume]'\''' 'mode=${1:---check-only}' '[[ $mode == --check-only || $mode == --execute || $mode == --resume ]] || die '\''usage: launch-normal-v21.sh [--check-only|--execute|--resume]'\''' 'outputs=()' 'if [[ $mode == --resume ]]; then' '    resume_state_validator "$ROOT/coordinator-state.json" "$OP"' 'else' '    for leaf in "${outputs[@]}"; do [[ ! -e $ROOT/$leaf && ! -L $ROOT/$leaf ]] || die "fresh output already exists: $ROOT/$leaf"; done' 'fi' '[[ $mode == --check-only ]] && { printf '\''normal v2.1 fresh-boundary checks passed\n'\''; exit 0; }' 'coordinator_mode=()' '[[ $mode == --resume ]] && coordinator_mode+=(--resume)' 'coordinator_replacement=()' 'exec "$COORDINATOR" "${coordinator_mode[@]}" "${coordinator_replacement[@]}" \' ' --operation-id "$OP" --windows-user-sid S-1-5-1' >"$base"
sed -i "s|ROOT_REPLACE|$root|" "$base"
sed -i 's/\\\\$/\\/' "$base"
chmod 500 "$base"
v4=$tmp/v4-coordinator; prov=$tmp/v4-provenance.json; producer=$tmp/v4-producer
printf '#!/usr/bin/env bash\nprintf %%s "$*" >"%s/argv"\n' "$tmp" >"$v4"; chmod 755 "$v4"
printf '{}' >"$prov"; chmod 600 "$prov"; printf '#!/usr/bin/env bash\n' >"$producer"; chmod 755 "$producer"
printf '{"terminal":1}' >"$root/candidate-retirement-terminal.json"
printf '{"commit":1}' >"$root/candidate-replacement-commit.json"
chmod 600 "$root"/candidate-*.json
candidate=$tmp/candidate; mkdir "$candidate"; chmod 700 "$candidate"
python3 - "$root" "$op" "$coord" "$base" "$v4" "$prov" "$producer" "$candidate/candidate-manifest.json" <<'PY'
import hashlib,json,sys
r,op,c,b,v,p,prod,manifest_path=sys.argv[1:]; sha=lambda x:hashlib.sha256(open(x,'rb').read()).hexdigest(); now=1; utc='1970-01-01T00:00:00.001Z'
windows={'viewflowd':'/x','viewflowd_sha256':'0'*64,'native_provenance':'/x','native_provenance_sha256':'0'*64,'wrapper':'/x','wrapper_sha256':'0'*64,'launcher':'/x','launcher_sha256':'0'*64,'installer':'/x','installer_sha256':'0'*64,'rollback_sha256':'0'*64,'old_task_xml_sha256':'9'*64,'new_task_xml_override':None,'session_1_user_sid':'S-1-5-1'}
manifest={'schema_version':1,'kind':'viewflow-v21-cross-host-candidate-set','operation_id':op,'coordinator_instance_id':c,'protocol_version':'2.1','sidecar_protocol_version':3,'marker_generation':1,'recovery_marker_generation':2,'source_display_id':'s','target_device_id':'t','fresh_boundary':{},'coordinator':{},'linux_rust':{},'linux_deskflow':{},'windows':windows}; open(manifest_path,'w').write(json.dumps(manifest,separators=(',',':')))
pred={'deployment_publish':{'path':'/x','sha256':'0'*64},'marker_handoff':{'path':'/x','sha256':'0'*64},'linux_frozen':{'path':'/x','sha256':'0'*64},'retirement_terminal':{'path':r+'/candidate-retirement-terminal.json','sha256':sha(r+'/candidate-retirement-terminal.json')},'replacement_commit':{'path':r+'/candidate-replacement-commit.json','sha256':sha(r+'/candidate-replacement-commit.json')},'candidate_manifest':{'path':manifest_path,'sha256':sha(manifest_path)},'candidate_tree_sha256':'0'*64,'launcher':{'path':b,'sha256':sha(b)},'coordinator':{'path':'/v3','sha256':'0'*64,'provenance_path':'/v3p','provenance_sha256':'0'*64}}
w={'schema_version':1,'state':'viewflow-normal-v21-coordinator-successor-windows-prestate','operation_id':op,'coordinator_instance_id':c,'observed_at_unix_ms':now,'observed_at_utc':utc,'windows_ssh_target':'wilf@172.16.105.70','windows_user_sid':'S-1-5-1','windows_operation_root':'C:\\x','operation_root_present':False,'operation_bound_task_count':0,'operation_bound_tasks':[],'operation_bound_process_count':0,'operation_bound_processes':[],'collector_path':prod,'collector_sha256':sha(prod)}
wp=r+'/coordinator-successor-windows-prestate.json'; open(wp,'w').write(json.dumps(w,separators=(',',':'))); 
rec={'schema_version':1,'state':'viewflow-normal-v21-coordinator-successor-authorized','operation_id':op,'coordinator_instance_id':c,'replacement_ordinal':1,'created_at_unix_ms':now,'created_at_utc':utc,'operation_root':r,'receipt_path':r+'/coordinator-successor-receipt.json','predecessor':pred,'marker_cli_alias_override':{'kind':'marker-cli-path-alias-same-bytes-v1','only_handoff_field':'marker_cli_path','historical_path':'/old','candidate_path':'/new','sha256':'0'*64},'successor':{'coordinator_path':v,'coordinator_sha256':sha(v),'provenance_path':p,'provenance_sha256':sha(p),'receipt_producer_path':prod,'receipt_producer_sha256':sha(prod)},'absence':{'coordinator_state_path':r+'/coordinator-state.json','coordinator_state_absent':True,'normal_output_leaves':[],'normal_outputs_absent':True,'pre_receipt_operation_leaves':[]},'windows_prestate':{'path':wp,'sha256':sha(wp)}}
open(r+'/coordinator-successor-receipt.json','w').write(json.dumps(rec,separators=(',',':')))
PY
chmod 600 "$root"/*.json
chmod 600 "$candidate/candidate-manifest.json"
# Patch only the copied constant after base construction.  Runtime commands are
# locally stubbed; the real SSH target is never contacted.
base_sha=$(sha256sum "$base"|awk '{print $1}'); sed -i "s/readonly BASE_SHA=.*/readonly BASE_SHA=$base_sha/" "$gen"
args=(--operation-id "$op" --coordinator-uuid "$coord" --v4-coordinator "$v4" --v4-coordinator-sha256 "$(sha256sum "$v4"|awk '{print $1}')" --v4-provenance "$prov" --v4-provenance-sha256 "$(sha256sum "$prov"|awk '{print $1}')" --v4-producer "$producer" --v4-producer-sha256 "$(sha256sum "$producer"|awk '{print $1}')" --successor-receipt "$root/coordinator-successor-receipt.json" --successor-receipt-sha256 "$(sha256sum "$root/coordinator-successor-receipt.json"|awk '{print $1}')" --windows-prestate "$root/coordinator-successor-windows-prestate.json" --windows-prestate-sha256 "$(sha256sum "$root/coordinator-successor-windows-prestate.json"|awk '{print $1}')")
bash "$gen" --check-only "${args[@]}" >/dev/null
[[ ! -e $root/launch-normal-v21-successor.sh ]]
manifest=$candidate/candidate-manifest.json; receipt_file=$root/coordinator-successor-receipt.json
cp -- "$manifest" "$tmp/manifest.good"; cp -- "$receipt_file" "$tmp/receipt.good"
printf '{"wrong":true}' >"$manifest"; chmod 600 "$manifest"
if bash "$gen" --check-only "${args[@]}" >/dev/null 2>&1; then echo 'accepted wrong candidate-manifest SHA' >&2; exit 1; fi
cp -- "$tmp/manifest.good" "$manifest"; chmod 600 "$manifest"
mutate_manifest(){
  local field=$1 value=$2
  python3 - "$manifest" "$receipt_file" "$field" "$value" <<'PY'
import hashlib,json,sys
m,r,k,v=sys.argv[1:]; x=json.load(open(m)); x['windows'][k]=v; open(m,'w').write(json.dumps(x,separators=(',',':')))
y=json.load(open(r)); y['predecessor']['candidate_manifest']['sha256']=hashlib.sha256(open(m,'rb').read()).hexdigest(); open(r,'w').write(json.dumps(y,separators=(',',':')))
PY
  chmod 600 "$manifest" "$receipt_file"
}
bad_args=("${args[@]}")
replace_receipt_sha(){ local i; for i in "${!bad_args[@]}"; do [[ ${bad_args[$i]} == --successor-receipt-sha256 ]] && bad_args[i+1]=$(sha256sum "$receipt_file"|awk '{print $1}'); done; return 0; }
mutate_manifest session_1_user_sid S-1-5-999; replace_receipt_sha
if bash "$gen" --check-only "${bad_args[@]}" >/dev/null 2>&1; then echo 'accepted candidate SID mismatch' >&2; exit 1; fi
cp -- "$tmp/manifest.good" "$manifest"; cp -- "$tmp/receipt.good" "$receipt_file"; chmod 600 "$manifest" "$receipt_file"
bad_args=("${args[@]}"); mutate_manifest old_task_xml_sha256 BAD; replace_receipt_sha
if bash "$gen" --check-only "${bad_args[@]}" >/dev/null 2>&1; then echo 'accepted noncanonical old task XML SHA' >&2; exit 1; fi
cp -- "$tmp/manifest.good" "$manifest"; cp -- "$tmp/receipt.good" "$receipt_file"; chmod 600 "$manifest" "$receipt_file"
if bash "$gen" --execute "${args[@]}" >/dev/null 2>&1; then echo 'accepted forbidden durable output' >&2; exit 1; fi
mkdir "$tmp/bin"
printf '#!/usr/bin/env bash\nprintf "inactive\\n0\\n"\n' >"$tmp/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/ss"
printf '#!/usr/bin/env bash\nprintf "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  marker\\n"\n' >"$tmp/bin/sha256sum"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >"%s/ssh-argv"\n' "$tmp" >"$tmp/bin/ssh"
chmod 700 "$tmp/bin"/*
before=$(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
run_before=$(find /run/user/1000 -maxdepth 1 -name '.viewflow-successor.*' -printf '%f\n' | LC_ALL=C sort)
env -i HOME=/home/wilf PATH="$tmp/bin:/usr/bin:/bin" bash "$gen" --run-check-only "${args[@]}" >/dev/null
env -i HOME=/home/wilf PATH="$tmp/bin:/usr/bin:/bin" bash "$gen" --run-execute "${args[@]}" >/dev/null
after=$(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
run_after=$(find /run/user/1000 -maxdepth 1 -name '.viewflow-successor.*' -printf '%f\n' | LC_ALL=C sort)
[[ $before == "$after" && $run_before == "$run_after" && ! -e $root/launch-normal-v21-successor.sh ]] || { echo 'run mode retained launcher leaf' >&2; exit 1; }
rg -Fq -- '--candidate-retirement-terminal' "$tmp/argv"
rg -Fq -- '--candidate-replacement-commit' "$tmp/argv"
rg -Fq -- '--windows-task-xml-sha256 9999999999999999999999999999999999999999999999999999999999999999' "$tmp/argv"
[[ $(rg -o -- '--coordinator-successor-receipt-sha256' "$tmp/argv" | wc -l) == 1 ]]
python3 - "$root/coordinator-state.json" "$op" "$root/coordinator-successor-receipt.json" "$root/coordinator-successor-windows-prestate.json" "$v4" <<'PY'
import hashlib,json,sys
p,op,r,w,c=sys.argv[1:]; s=lambda q:hashlib.sha256(open(q,'rb').read()).hexdigest()
open(p,'w').write(json.dumps({'schema_version':2,'state':'viewflow-cross-host-bootstrap','operation_id':op,'contract':{'inputs':{'coordinator_successor_receipt':{'sha256':s(r)},'coordinator_successor_windows_prestate':{'sha256':s(w)},'coordinator_successor':{'sha256':s(c)}}}},separators=(',',':')))
PY
chmod 600 "$root/coordinator-state.json"
before=$(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
run_before=$(find /run/user/1000 -maxdepth 1 -name '.viewflow-successor.*' -printf '%f\n' | LC_ALL=C sort)
env -i HOME=/home/wilf PATH="$tmp/bin:/usr/bin:/bin" bash "$gen" --run-resume "${args[@]}" >/dev/null
after=$(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
run_after=$(find /run/user/1000 -maxdepth 1 -name '.viewflow-successor.*' -printf '%f\n' | LC_ALL=C sort)
[[ $before == "$after" && $run_before == "$run_after" && ! -e $root/launch-normal-v21-successor.sh ]] || { echo 'resume retained launcher leaf' >&2; exit 1; }
rg -Fq -- '--resume' "$tmp/argv"
printf 'normal v2.1 successor launcher hermetic test passed\n'
