#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
repo=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
source_script=$repo/deploy/linux/prepare-normal-v21-coordinator-successor.sh
formal_state=/home/wilf/.local/state/viewflow
op=305058f7deb84c198bad4103d6c4f946
coord=856cee25-57c7-4b8a-82da-1501d150d4de
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_fixture() {
    local name=$1
    local root=$tmp/$name
    local state=$root/state
    local op_root=$state/deployments/$op
    local cand=$state/candidates/v21-operation-$op
    mkdir -p "$op_root" "$cand" "$state/candidates/rejected" "$root/bin" "$root/successor/source-stage/deploy"
    chmod 700 "$root" "$state" "$state/deployments" "$op_root" "$state/candidates" "$state/candidates/rejected" "$cand" "$root/bin" "$root/successor" "$root/successor/source-stage" "$root/successor/source-stage/deploy"
    cp -- "$source_script" "$root/producer.sh"
    cp -- "$repo/deploy/coordinated-v13-to-v2.sh" "$root/successor/source-stage/deploy/coordinated-v13-to-v2.sh"
    chmod 755 "$root/producer.sh" "$root/successor/source-stage/deploy/coordinated-v13-to-v2.sh"
    cp -- "$formal_state/deployment-quarantine.v1" "$state/deployment-quarantine.v1"; chmod 600 "$state/deployment-quarantine.v1"
    python3 - "$root" "$formal_state" "$op" <<'PY'
import hashlib,json,os,shutil,sys
r,state,op=sys.argv[1:]; oldroot=f"{state}/deployments/{op}"; root=f"{r}/state/deployments/{op}"
oldcand=f"{state}/candidates/v21-operation-{op}"; cand=f"{r}/state/candidates/v21-operation-{op}"
def load(p): return json.load(open(p),object_pairs_hook=dict)
def write(p,v,mode=0o600):
 data=(json.dumps(v,separators=(',',':'))+'\n').encode(); open(p,'wb').write(data); os.chmod(p,mode); return hashlib.sha256(data).hexdigest()
def sha(p): return hashlib.sha256(open(p,'rb').read()).hexdigest()
p=load(oldroot+'/deployment-publish.json'); p['marker_path']=r+'/state/deployment-quarantine.v1'; psha=write(root+'/deployment-publish.json',p)
h=load(oldroot+'/marker-handoff.json'); h['deployment_marker_path']=p['marker_path']; h['deployment_publish_receipt_path']=root+'/deployment-publish.json'; h['deployment_publish_receipt_sha256']=psha; hsha=write(root+'/marker-handoff.json',h)
shutil.copy2(oldroot+'/linux-frozen.json',root+'/linux-frozen.json'); os.chmod(root+'/linux-frozen.json',0o600); fsha=sha(root+'/linux-frozen.json')
t=load(oldroot+'/candidate-retirement-terminal.json'); oldsha=t['old_candidate']['manifest_sha256']; archive=f"{r}/state/candidates/rejected/v21-operation-{op}.rejected-{oldsha}"
shutil.copytree(t['old_candidate']['archive_path'],archive,copy_function=shutil.copy2); os.chmod(archive,0o700)
t['operation_root']=root;t['candidate_root']=cand;t['old_candidate']['canonical_path']=cand;t['old_candidate']['archive_path']=archive
t['fresh_boundary'].update(deployment_publish_path=root+'/deployment-publish.json',deployment_publish_sha256=psha,marker_handoff_path=root+'/marker-handoff.json',marker_handoff_sha256=hsha,linux_frozen_path=root+'/linux-frozen.json',linux_frozen_sha256=fsha,deployment_marker_path=p['marker_path'])
t['pre_retirement']['coordinator_state_path']=root+'/coordinator-state.json'; tsha=write(root+'/candidate-retirement-terminal.json',t)
i=load(oldroot+'/normal-v21-candidate-retirement.intent.json'); i.update(operation_root=root,candidate_root=cand,archive_path=archive,terminal_path=root+'/candidate-retirement-terminal.json',terminal_receipt=t); write(root+'/normal-v21-candidate-retirement.intent.json',i)
for leaf in ['windows-native-provenance.json','windows-source.manifest.sha256','windows-source.tar.gz','windows-source.tar.gz.sha256','windows-viewflowd.exe']:
 shutil.copy2(oldcand+'/'+leaf,cand+'/'+leaf); os.chmod(cand+'/'+leaf,0o700 if leaf.endswith('.exe') else 0o600)
m=load(oldcand+'/candidate-manifest.json'); m['fresh_boundary'].update(root=root,deployment_publish_receipt_sha256=psha,marker_handoff_sha256=hsha,linux_frozen_sha256=fsha,deployment_marker=p['marker_path'])
m['candidate_replacement']['retirement_terminal_path']=root+'/candidate-retirement-terminal.json';m['candidate_replacement']['retirement_terminal_sha256']=tsha
m['windows']['viewflowd']=cand+'/windows-viewflowd.exe';m['windows']['native_provenance']=cand+'/windows-native-provenance.json'; msha=write(cand+'/candidate-manifest.json',m)
d=hashlib.sha256()
for leaf in sorted(os.listdir(cand)):
 mode=0o700 if leaf.endswith('.exe') else 0o600; data=open(cand+'/'+leaf,'rb').read(); hs=hashlib.sha256(data).hexdigest(); d.update((leaf+'\0'+format(mode,'04o')+'\0'+str(len(data))+'\0'+hs+'\n').encode())
c=load(oldroot+'/candidate-replacement-commit.json'); c.update(operation_root=root,candidate_root=cand,candidate_manifest_path=cand+'/candidate-manifest.json',candidate_manifest_sha256=msha,candidate_tree_sha256=d.hexdigest(),retirement_terminal_path=root+'/candidate-retirement-terminal.json',retirement_terminal_sha256=tsha,old_candidate_archive_path=archive,fresh_boundary=t['fresh_boundary']); write(root+'/candidate-replacement-commit.json',c)
shutil.copy2(oldroot+'/launch-normal-v21.sh',root+'/launch-normal-v21.sh');os.chmod(root+'/launch-normal-v21.sh',0o500)
succ=r+'/successor/source-stage/deploy/coordinated-v13-to-v2.sh'; ssha=sha(succ)
prov={'schema_version':2,'kind':'viewflow-linux-rust-release-provenance','protocol_version':'2.1','sidecar_protocol_version':3,'source':{'root':r,'files':[{'path':'successor/source-stage/deploy/coordinated-v13-to-v2.sh','sha256':ssha}]}}
write(r+'/successor/provenance.json',prov)
PY
    cat >"$root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'inactive\n0\n'
EOF
    cat >"$root/bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ -e $(dirname -- "$0")/export-fail ]]; then exit 72; fi
printf x >>"$(dirname -- "$0")/ssh.calls"
if [[ -e $(dirname -- "$0")/windows-present ]]; then
  printf '%s\n' '{"operation_root_present":true,"operation_bound_tasks":[],"operation_bound_processes":[]}'
  exit 0
fi
printf '%s\n' '{"operation_root_present":false,"operation_bound_tasks":[],"operation_bound_processes":[]}'
EOF
    chmod 755 "$root/bin/"*
    sed -i \
      -e "s|STATE=\"/home/wilf/.local/state/viewflow\"|STATE=\"$state\"|" \
      -e "s|SSH=\"/usr/bin/ssh\"|SSH=\"$root/bin/ssh\"|" \
      -e "s|SYSTEMCTL=\"/usr/bin/systemctl\"|SYSTEMCTL=\"$root/bin/systemctl\"|" \
      -e "s|SS=\"/usr/bin/ss\"|SS=\"$root/bin/ss\"|" "$root/producer.sh"
    python3 - "$root" <<'PY'
import hashlib,json,os,sys
r=sys.argv[1]; p=r+'/successor/provenance.json'; v=json.load(open(p)); data=open(r+'/producer.sh','rb').read()
v['source']['files'].append({'path':'producer.sh','sha256':hashlib.sha256(data).hexdigest()})
out=(json.dumps(v,separators=(',',':'))+'\n').encode(); open(p,'wb').write(out); os.chmod(p,0o600)
PY
    printf '%s\n' "$root"
}

run() {
    local root=$1 mode=$2
    local succ=$root/successor/source-stage/deploy/coordinated-v13-to-v2.sh
    local prov=$root/successor/provenance.json
    "$root/producer.sh" "$mode" --operation-id "$op" --coordinator-instance-id "$coord" \
      --successor-coordinator "$succ" --successor-coordinator-sha256 "$(sha256sum "$succ"|cut -d' ' -f1)" \
      --successor-provenance "$prov" --successor-provenance-sha256 "$(sha256sum "$prov"|cut -d' ' -f1)"
}

normal=$(make_fixture normal)
run "$normal" --check-only >/dev/null
run "$normal" --execute >/dev/null
run "$normal" --replay >/dev/null
[[ $(find "$normal/state/deployments/$op" -maxdepth 1 -type f | wc -l) -eq 9 ]]
[[ $(wc -c <"$normal/bin/ssh.calls") -eq 1 ]]
echo 'normal execute/replay PASS'

crash=$(make_fixture crash)
sentinel=$crash/killed-once
python3 - "$crash/producer.sh" "$sentinel" <<'PY'
import sys
p,s=sys.argv[1:];t=open(p).read();old='publish(rootfd,WPROOF_LEAF,canonical_bytes(w),"Windows prestate"); have_w=True'
new='publish(rootfd,WPROOF_LEAF,canonical_bytes(w),"Windows prestate");\n        if not os.path.exists('+repr(s)+'):\n            open('+repr(s)+',"x").close(); os.kill(os.getpid(),9)\n        have_w=True'
assert old in t;open(p,'w').write(t.replace(old,new))
PY
python3 - "$crash" <<'PY'
import hashlib,json,os,sys
r=sys.argv[1]; p=r+'/successor/provenance.json'; v=json.load(open(p)); sha=hashlib.sha256(open(r+'/producer.sh','rb').read()).hexdigest()
for record in v['source']['files']:
    if record['path']=='producer.sh': record['sha256']=sha
out=(json.dumps(v,separators=(',',':'))+'\n').encode();open(p,'wb').write(out);os.chmod(p,0o600)
PY
set +e; run "$crash" --execute >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 137 && -f $crash/state/deployments/$op/coordinator-successor-windows-prestate.json && ! -e $crash/state/deployments/$op/coordinator-successor-receipt.json ]]
touch "$crash/bin/windows-present"
if run "$crash" --resume >/dev/null 2>&1; then echo 'unexpected stale Windows prestate resume acceptance' >&2; exit 1; fi
[[ ! -e $crash/state/deployments/$op/coordinator-successor-receipt.json ]]
rm "$crash/bin/windows-present"
run "$crash" --resume >/dev/null
run "$crash" --replay >/dev/null
[[ $(wc -c <"$crash/bin/ssh.calls") -eq 3 ]]
echo 'SIGKILL after proof/resume/replay PASS'

export_fail=$(make_fixture export-fail)
touch "$export_fail/bin/export-fail"
if run "$export_fail" --execute >/dev/null 2>&1; then echo 'unexpected task export failure acceptance' >&2; exit 1; fi
[[ ! -e $export_fail/state/deployments/$op/coordinator-successor-windows-prestate.json && ! -e $export_fail/state/deployments/$op/coordinator-successor-receipt.json ]]
echo 'task XML export failure fail-closed PASS'

bad=$(make_fixture bad)
mkdir "$bad/state/deployments/$op/coordinator-state.json"
if run "$bad" --check-only >/dev/null 2>&1; then echo 'unexpected normal-output acceptance' >&2; exit 1; fi
echo 'normal-output directory fail-closed PASS'

swap=$(make_fixture swap)
mv "$swap/state/deployments/$op/coordinator-successor-windows-prestate.json" "$swap/nope" 2>/dev/null || true
ln -s /dev/null "$swap/state/deployments/$op/coordinator-successor-windows-prestate.json"
if run "$swap" --resume >/dev/null 2>&1; then echo 'unexpected symlink proof acceptance' >&2; exit 1; fi
echo 'proof symlink/no-clobber PASS'
echo 'coordinator successor hermetic tests passed'
