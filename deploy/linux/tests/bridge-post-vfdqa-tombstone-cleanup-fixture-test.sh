#!/usr/bin/env bash
set -Eeuo pipefail
readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SOURCE=$(cd -- "$HERE/.." && pwd)/bridge-post-vfdqa-tombstone-to-fresh-v21.sh
root=$(mktemp -d --tmpdir viewflow-post-vfdqa-cleanup.XXXXXX); trap 'rm -rf -- "$root"' EXIT
python3 - "$root" <<'PY'
import ctypes,errno,hashlib,os,stat,sys
r=sys.argv[1]; src=os.path.join(r,'stage'); dst=os.path.join(r,'receipt'); open(src,'wb').write(b'x'); os.chmod(src,0o600)
libc=ctypes.CDLL(None,use_errno=True); RENAME_NOREPLACE=1
assert libc.renameat2(-100,src.encode(),-100,dst.encode(),RENAME_NOREPLACE)==0
s=os.lstat(dst); assert stat.S_ISREG(s.st_mode) and s.st_nlink==1 and stat.S_IMODE(s.st_mode)==0o600
open(src,'wb').write(b'y'); assert libc.renameat2(-100,src.encode(),-100,dst.encode(),RENAME_NOREPLACE)!=0 and ctypes.get_errno()==errno.EEXIST
os.unlink(src); os.symlink('/dev/null',src)
try:
 fd=os.open(src,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW); raise AssertionError('symlink accepted')
except OSError: pass
os.unlink(src); open(src,'wb').write(b'z'); peer=os.path.join(r,'peer'); os.link(src,peer); assert os.lstat(src).st_nlink==2
# The production owner/link tuple rejects this before publication.
assert not (os.lstat(src).st_nlink==1)
mask=os.path.join(r,'mask'); os.symlink('/dev/null',mask); st=os.lstat(mask); assert st.st_nlink==1 and os.readlink(mask)=='/dev/null'
os.unlink(mask); os.symlink('/tmp/not-null',mask); assert os.readlink(mask)!='/dev/null'
PY
grep -Fq 'RENAME_NOREPLACE=1' "$SOURCE"; grep -Fq 'st.st_uid!=1000 or st.st_nlink!=1' "$SOURCE"
grep -Fq "data!=b'/dev/null'" "$SOURCE"; grep -Fq "if os.path.lexists(src) and os.path.lexists(dst)" "$SOURCE"
stop=$(grep -nF 'systemctl --user stop "$du"; systemctl --user stop "$vu"' "$SOURCE"|cut -d: -f1)
[[ $stop =~ ^[1-9][0-9]*$ ]] || { echo 'error: Deskflow-before-Viewflow ordering absent' >&2; exit 1; }
grep -Fq '! -e $RUNTIME_MARKER' "$SOURCE"; grep -Fq "sport = :44119" "$SOURCE"; grep -Fq "sport = :24800" "$SOURCE"

# Execute production marker/H recovery after a simulated crash immediately
# after the marker became durable. The second call must adopt, not republish.
state=$root/state; fresh=$root/fresh; bin=$root/bin; mkdir -p "$state" "$fresh" "$bin"; chmod 0700 "$state" "$fresh" "$bin"
printf marker-cli >"$bin/viewflow-deployment-marker"; printf deskflow >"$bin/deskflow"; printf core >"$bin/deskflow-core"; chmod 0755 "$bin/viewflow-deployment-marker" "$bin/deskflow" "$bin/deskflow-core"
cli_sha=$(sha256sum "$bin/viewflow-deployment-marker"|awk '{print $1}'); gui_sha=$(sha256sum "$bin/deskflow"|awk '{print $1}'); core_sha=$(sha256sum "$bin/deskflow-core"|awk '{print $1}')
op=11111111111111111111111111111111; coord=22222222-2222-2222-2222-222222222222
inventory=$root/recovery-inventory.json; jq -cn --arg gui "$gui_sha" --arg core "$core_sha" '{processes:{deskflow:[{role:"gui",exe_sha256:$gui},{role:"core",exe_sha256:$core}]}}' >"$inventory"; chmod 0600 "$inventory"
python3 - "$state/deployment-quarantine.v1" "$op" "$coord" <<'PY'
import sys,uuid
b=bytearray(256); op=sys.argv[2].encode(); b[:13]=b'VFDQT001\x01\x01\x02\x01\x01'; b[13]=len(op); b[16:16+len(op)]=op
b[144:160]=uuid.UUID('00000000-0000-0000-0000-000000000101').bytes; b[160:176]=uuid.UUID('00000000-0000-0000-0000-000000000002').bytes; b[176:192]=uuid.UUID(sys.argv[3]).bytes; b[192:200]=(1).to_bytes(8,'little'); b[200:208]=(1).to_bytes(8,'little'); open(sys.argv[1],'wb').write(b)
PY
chmod 0600 "$state/deployment-quarantine.v1"
marker_harness=$root/marker-harness.sh
python3 - "$SOURCE" "$marker_harness" "$root" "$op" "$coord" "$cli_sha" "$inventory" <<'PY'
import pathlib,shlex,sys
src,dst,root,op,coord,cli,inventory=sys.argv[1:]
s=pathlib.Path(src).read_text()
repl={'/home/wilf/.local/state/viewflow':root+'/state','/home/wilf/.local/lib/viewflow/viewflow-deployment-marker':root+'/bin/viewflow-deployment-marker','/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core':root+'/bin/deskflow-core','/home/wilf/.local/lib/deskflow-scale-fix/deskflow':root+'/bin/deskflow'}
for a,b in repl.items(): s=s.replace(a,b)
q=shlex.quote
h=f'''new_operation={q(op)}
new_coordinator={q(coord)}
marker_candidate_sha={q(cli)}
linux_inventory={q(inventory)}
fresh_root={q(root+'/fresh')}
publish_receipt=$fresh_root/deployment-publish.json
handoff_receipt=$fresh_root/marker-handoff.json
bridge_root={q(root)}
unit_prop() {{ printf '0\\n'; }}
exact_pids() {{ return 0; }}
ss() {{ return 0; }}
recover_partial_handoff
first_marker=$(sha256 "$MARKER"); first_h=$(sha256 "$handoff_receipt"); first_publish=$(sha256 "$publish_receipt")
recover_partial_handoff
[[ $(sha256 "$MARKER") == "$first_marker" && $(sha256 "$handoff_receipt") == "$first_h" && $(sha256 "$publish_receipt") == "$first_publish" ]]
cp "$MARKER" "$MARKER.good"
printf X | dd of="$MARKER" bs=1 seek=32 conv=notrunc status=none
if (recover_partial_handoff) >/dev/null 2>&1; then exit 70; fi
mv "$MARKER.good" "$MARKER"
printf 'MARKER_RECOVERY_OK\\n'
'''
if s.count('\nmain\n')!=1: raise SystemExit('main anchor differs')
pathlib.Path(dst).write_text(s.replace('\nmain\n','\n'+h+'\n'))
PY
chmod 0700 "$marker_harness"
/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$marker_harness" | grep -Fqx MARKER_RECOVERY_OK

# Simulate collector death after its immutable intent but before B publication.
bfresh=$root/bfresh; mkdir -p "$bfresh"; chmod 0700 "$bfresh"; boot=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id); inv=33333333333333333333333333333333; fake_pid=4294967294; daemon_sha=$(printf daemon | sha256sum|awk '{print $1}')
intent=$bfresh/collector-intent.json; jq -cn --arg op "$op" --arg boot "$boot" --arg inv "$inv" --arg sha "$daemon_sha" --argjson pid "$fake_pid" '{schema_version:1,state:"viewflow-fresh-v13-collector-intent",operation_id:$op,daemon_pid:$pid,daemon_start_ticks:77,boot_id:$boot,invocation_id:$inv,daemon_sha256:$sha}' >"$intent"; chmod 0600 "$intent"
b_harness=$root/b-harness.sh
python3 - "$SOURCE" "$b_harness" "$root" "$op" "$daemon_sha" "$fake_pid" "$inv" "$boot" <<'PY'
import pathlib,shlex,sys
src,dst,root,op,sha,pid,inv,boot=sys.argv[1:]; s=pathlib.Path(src).read_text().replace('/home/wilf/.local/lib/viewflow/viewflowd',root+'/bin/viewflowd').replace('/run/user/1000/viewflow/deskflow.sock',root+'/state/deskflow.sock'); q=shlex.quote; boot_flat=boot.replace('-','')
h=f'''new_operation={q(op)}
installed_viewflow_sha={q(sha)}
fresh_root={q(root+'/bfresh')}
frozen_evidence=$fresh_root/linux-frozen.json
bridge_root={q(root)}
unit_prop() {{ printf '0\\n'; }}
exact_pids() {{ return 0; }}
ss() {{ return 0; }}
journalctl() {{
 printf '%s\\n' {q('{"_SYSTEMD_INVOCATION_ID":"'+inv+'","_PID":"'+pid+'","_BOOT_ID":"'+boot_flat+'","MESSAGE":"viewflowd protocol 1.3 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged","__CURSOR":"s=1","__REALTIME_TIMESTAMP":"1000"}')} {q('{"_SYSTEMD_INVOCATION_ID":"'+inv+'","_PID":"'+pid+'","_BOOT_ID":"'+boot_flat+'","MESSAGE":"stopped","__CURSOR":"s=2","__REALTIME_TIMESTAMP":"2000"}')}
}}
cp "$fresh_root/collector-intent.json" "$fresh_root/collector-intent.good"
jq '.boot_id="00000000-0000-0000-0000-000000000000"' "$fresh_root/collector-intent.good" >"$fresh_root/collector-intent.json"
if (recover_frozen_after_collector_stop "$fresh_root/collector-intent.json") >/dev/null 2>&1; then exit 77; fi
mv "$fresh_root/collector-intent.good" "$fresh_root/collector-intent.json"
recover_frozen_after_collector_stop "$fresh_root/collector-intent.json"
first=$(sha256 "$frozen_evidence"); validate_frozen; [[ $(sha256 "$frozen_evidence") == "$first" ]]
printf 'B_RECOVERY_OK\\n'
'''
if s.count('\nmain\n')!=1: raise SystemExit('main anchor differs')
pathlib.Path(dst).write_text(s.replace('\nmain\n','\n'+h+'\n'))
PY
chmod 0700 "$b_harness"
b_output=$(/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$b_harness")
grep -Fqx B_RECOVERY_OK <<<"$b_output"

# Exercise exact existing cleanup/final receipt validation: unknown keys,
# duplicate keys and nested/cross hashes must all fail on resume.
rroot=$root/receipts; mkdir -p "$rroot"; chmod 0700 "$rroot"; r_inv=$rroot/inventory.json; r_manifest=$rroot/manifest.json; boot_flat=$(tr -d -- '-' </proc/sys/kernel/random/boot_id); marker_sha=$(printf marker|sha256sum|awk '{print $1}')
jq -cn '{processes:{deskflow:[{role:"core",pid:12,start_ticks:34,exe_sha256:("a"*64)}],viewflow:[{pid:56,start_ticks:78}]}}' >"$r_inv"; jq -cn --arg marker "$marker_sha" '{vfdqa_binary:{marker_sha256:$marker}}' >"$r_manifest"; chmod 0600 "$r_inv" "$r_manifest"
status=$rroot/status.json; jq -cn --arg boot "$boot_flat" --arg runtime "$rroot/deskflow-quarantine.v2" '{core_boot_id:$boot,core_pid:12,core_start_ticks:34,protocol_version:"2.1",receipt_available:false,runtime_marker_path:$runtime,runtime_marker_present:false,schema_version:1,sidecar_configured:true,sidecar_protocol_version:3,state:"deskflow-live-acceptance-status"}' >"$status"; status_sha=$(jq -cS . "$status"|sha256sum|awk '{print $1}')
proof=$rroot/cleanup.json; jq -cn --arg op "$op" --arg sha "$status_sha" --slurpfile status "$status" '{acceptance_status:$status[0],acceptance_status_sha256:$sha,operation_id:$op,pressed_state:"no-active-route",schema_version:1,state:"viewflow-post-vfdqa-retirement-no-active-route"}' >"$proof"; chmod 0600 "$proof"
for f in plan config h b; do printf %s "$f" >"$rroot/$f"; chmod 0600 "$rroot/$f"; done
plan_sha=$(sha256sum "$rroot/plan"|awk '{print $1}'); cleanup_sha=$(sha256sum "$proof"|awk '{print $1}'); config_sha=$(sha256sum "$rroot/config"|awk '{print $1}'); h_sha=$(sha256sum "$rroot/h"|awk '{print $1}'); b_sha=$(sha256sum "$rroot/b"|awk '{print $1}'); raw_sha=$(printf raw|sha256sum|awk '{print $1}'); disposition_sha=$(printf disposition|sha256sum|awk '{print $1}')
raw_path=$rroot/windows-ssh-raw-census.json; upgrade_path=$rroot/windows-legacy-census-transport-upgrade.v1.json; classification_path=$rroot/windows-legacy-census-stderr-classification.v1.json; disposition_path=$rroot/windows-legacy-disposition.json
final=$rroot/final.json; jq -cn --arg old 99999999999999999999999999999999 --arg new "$op" --arg c "$coord" --arg plan "$plan_sha" --arg i "$(printf incident|sha256sum|awk '{print $1}')" --arg t "$(printf tomb|sha256sum|awk '{print $1}')" --arg cleanup "$cleanup_sha" --arg config "$config_sha" --arg h "$h_sha" --arg b "$b_sha" --arg rp "$raw_path" --arg rs "$raw_sha" --arg up "$upgrade_path" --arg cp "$classification_path" --arg dp "$disposition_path" --arg ds "$disposition_sha" '{linux_fresh_boundary:{protocol_version:"2.1",marker_handoff_receipt_sha256:$h,linux_frozen_evidence_sha256:$b},marker_generation:"1",new_coordinator_instance_id:$c,new_operation_id:$new,old_incident:{incident_sha256:$i,invalid_authorization_tombstone_sha256:$t,old_authorization_role:"invalidity-proof-only"},old_operation_id:$old,retirement:{cleanup_proof_sha256:$cleanup,deskflow_stopped_before_viewflow:true,release_all_or_no_route_proven:true,zero_listeners_processes_sockets_vfqst002:true},runtime_config_relocation:{intent_sha256:$config,item_count:5,rename_method:"renameat2-RENAME_NOREPLACE"},schema_version:1,state:"viewflow-post-vfdqa-linux-fresh-v21-bootstrap-boundary-ready",transition_plan_sha256:$plan,windows_evidence:{raw_census:{path:$rp,sha256:$rs},transport_upgrade:{path:$up,sha256:"none"},stderr_classification:{path:$cp,sha256:"none"},legacy_disposition:{path:$dp,sha256:$ds},legacy_isolation_complete:true,fresh_bridge_ready:false}}' >"$final"; chmod 0600 "$final"
receipt_harness=$root/receipt-harness.sh
python3 - "$SOURCE" "$receipt_harness" "$rroot" "$op" "$coord" "$r_inv" "$r_manifest" "$proof" "$final" "$raw_sha" "$disposition_sha" <<'PY'
import pathlib,shlex,sys
src,dst,r,op,coord,inventory,manifest,proof,final,raw,disp=sys.argv[1:]; s=pathlib.Path(src).read_text().replace('/home/wilf/.local/state/viewflow',r); q=shlex.quote
h=f'''new_operation={q(op)}
new_coordinator={q(coord)}
old_operation=99999999999999999999999999999999
incident_sha=$(printf incident|sha256sum|awk '{{print $1}}')
tombstone_sha=$(printf tomb|sha256sum|awk '{{print $1}}')
windows_raw_census_sha={q(raw)}
windows_disposition_sha={q(disp)}
windows_raw_census={q(r+'/windows-ssh-raw-census.json')}
transport_upgrade_path={q(r+'/windows-legacy-census-transport-upgrade.v1.json')}
transport_upgrade_sha=none
stderr_classification_path={q(r+'/windows-legacy-census-stderr-classification.v1.json')}
stderr_classification_sha=none
windows_disposition={q(r+'/windows-legacy-disposition.json')}
linux_inventory={q(inventory)}
manifest={q(manifest)}
bridge_root={q(r)}
cleanup_proof={q(proof)}
final_receipt={q(final)}
plan={q(r+'/plan')}
config_intent={q(r+'/config')}
handoff_receipt={q(r+'/h')}
frozen_evidence={q(r+'/b')}
validate_cleanup_proof
cp "$cleanup_proof" "$cleanup_proof.good"
jq '.unknown=true' "$cleanup_proof.good" >"$cleanup_proof"
if (validate_cleanup_proof) >/dev/null 2>&1; then exit 71; fi
cp "$cleanup_proof.good" "$cleanup_proof"
jq '.acceptance_status_sha256=("0"*64)' "$cleanup_proof.good" >"$cleanup_proof"
if (validate_cleanup_proof) >/dev/null 2>&1; then exit 72; fi
cp "$cleanup_proof.good" "$cleanup_proof"
python3 - "$cleanup_proof" <<'INNER'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); p.write_text(s.replace('{{','{{"schema_version":1,',1))
INNER
if (validate_cleanup_proof) >/dev/null 2>&1; then exit 73; fi
cp "$cleanup_proof.good" "$cleanup_proof"
validate_cleanup_proof
validate_cleanup_proof() {{ :; }}
validate_handoff() {{ :; }}
validate_frozen() {{ :; }}
transients_zero() {{ return 0; }}
validate_final_receipt
cp "$final_receipt" "$final_receipt.good"
jq '.unknown=true' "$final_receipt.good" >"$final_receipt"
if (validate_final_receipt) >/dev/null 2>&1; then exit 74; fi
cp "$final_receipt.good" "$final_receipt"
jq '.transition_plan_sha256=("0"*64)' "$final_receipt.good" >"$final_receipt"
if (validate_final_receipt) >/dev/null 2>&1; then exit 75; fi
cp "$final_receipt.good" "$final_receipt"
python3 - "$final_receipt" <<'INNER'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); p.write_text(s.replace('{{','{{"schema_version":1,',1))
INNER
if (validate_final_receipt) >/dev/null 2>&1; then exit 76; fi
printf 'RECEIPT_RESUME_VALIDATION_OK\\n'
'''
if s.count('\nmain\n')!=1: raise SystemExit('main anchor differs')
pathlib.Path(dst).write_text(s.replace('\nmain\n','\n'+h+'\n'))
PY
chmod 0700 "$receipt_harness"
receipt_output=$(/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin /usr/bin/bash "$receipt_harness")
grep -Fqx RECEIPT_RESUME_VALIDATION_OK <<<"$receipt_output"
printf 'post-VFDQA tombstone cleanup/no-clobber fixture passed\n'
