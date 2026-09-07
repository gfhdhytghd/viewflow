#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

launcher=${EARLY_BOOTSTRAP_GATE_4FBA_LAUNCHER_SOURCE:-/home/wilf/data/viewflow/deploy/launch-early-bootstrap-gate-abort-4fba4c83.sh}
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
/usr/bin/python3 -I - "$launcher" "$root" <<'PY'
import ast,hashlib,json,os,subprocess,sys
from pathlib import Path

launcher=Path(sys.argv[1]);fixture=Path(sys.argv[2]);op='4fba4c832389436ba980efaa4540f6bf'
wrapper=launcher.read_text(encoding='utf-8');bootstrap=wrapper.split("<<'PY'\n",1)[1].rsplit('\nPY\n',1)[0]
tree=ast.parse(bootstrap);values={}
for node in tree.body:
    if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name):
        try: values[node.targets[0].id]=ast.literal_eval(node.value)
        except (ValueError,TypeError): pass
base=Path(values['BASE']).read_bytes();assert hashlib.sha256(base).hexdigest()==values['BASE_SHA']
for old,new,count in values['replacements']:
    oldb=old.encode();newb=new.encode();assert base.count(oldb)==count
    base=base.replace(oldb,newb);assert oldb not in base
derived=base.decode();blocks=derived.split("<<'PY'\n")
embedded=blocks[1].split('\nPY\n',1)[0]
sealed_core=blocks[2].split('\nPY\n',1)[0]
compile(embedded,'4fba-manifest-generator','exec');compile(sealed_core,'4fba-sealed-core','exec')

oproot=fixture/op;oproot.mkdir(mode=0o700)
embedded=embedded.replace("root=Path('/home/wilf/.local/state/viewflow/deployments')/op",f"root=Path({str(fixture)!r})/op")
candidate='/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/viewflow-deployment-marker'
candidate_sha='8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54'
provenance='/home/wilf/.local/state/viewflow/candidates/early-abort-v3-2ca3f466-v2/marker-reviewed-build.json'
provenance_sha='995e2a7940de17f82ef33e48ea165a8df8ba44a641c80072d711a4b0dcaefc4d'
shadow=fixture/'shadow';shadow.mkdir(mode=0o700)
for name in ('hashlib','json','pathlib','os','stat','ctypes'):
    (shadow/(name+'.py')).write_text("raise AssertionError('shadow module imported')\n",encoding='utf-8')
poison={'PATH':'/usr/bin:/bin','PYTHONPATH':str(shadow),'PYTHONHOME':str(shadow)}
def run(source,target):
    return subprocess.run(['/usr/bin/python3','-I','-c',source,str(target),candidate,candidate_sha,provenance,provenance_sha],
                          cwd=shadow,env=poison,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)

manifest=oproot/'early-bootstrap-gate-abort-manifest.4fba.v1.json'
first=run(embedded,manifest);second=run(embedded,manifest)
assert first.returncode==second.returncode==0 and first.stdout==second.stdout
assert first.stdout==hashlib.sha256(manifest.read_bytes()).hexdigest()+'\n'
value=json.loads(manifest.read_text())
assert value['operation_id']==op
assert value['identity']=={'coordinator_instance_id':'e306c15a-2a70-4fd3-9ca6-5a03ac23adfb','source_display_id':'00000000-0000-0000-0000-000000000101','target_device_id':'00000000-0000-0000-0000-000000000002','marker_generation':'1'}
assert value['artifacts']['coordinator_state']['sha256']=='1b737f18e97f0b9e4a4601febd0d301fcfa0eb222ab2a0995ec4fecfc62f92b2'
assert value['artifacts']['marker_handoff']['sha256']=='72dbf31cb148267afa6c7066ec0271af54f807ac1b9c4623f753875d85c9ee03'
assert value['artifacts']['linux_frozen']['sha256']=='923ffe9ca469b16555f10659dc8cdad60ad2841e82a81b69c35cff93ee712cbb'
assert value['artifacts']['deployment_publish']['sha256']=='61c47e7fce77247ac9c5f4be3ca0cf059c77d23e61175050371b13b3c444bbac'
assert value['artifacts']['bootstrap_request']['sha256']=='1587817d4f0e589e5d1c931df345b16002892ad658386bb23f98d21de5dac085'
assert value['artifacts']['windows_stop_evidence']['sha256']=='e3bd88a07453f54607eedbb398c31175ce77548b7d574f94359e7bdc1888ce81'
assert value['marker']['sha256']=='7b8744179ac3cdcecf01a4d7a85ac5f655b217f3b4828866681bc6775ad8ab04'
assert value['runtime_helper']=={'path':'/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper-4fba4c83.py','sha256':'5f160911c6ea894daca7dfe103b560c53e6d60fd5633673169158f93c921cba5','mode':755}
assert value['execution']['marker_candidate']=={'path':candidate,'sha256':candidate_sha,'mode':755,'reviewed_build_manifest':{'path':provenance,'sha256':provenance_sha,'mode':600}}
assert value['execution']['viewflow_unit']=='viewflow-v13-early-'+op+'.service'
assert value['windows_baseline']['new_operation_root_path'].endswith(op)
assert len(value['outputs'])==9 and len(set(value['outputs'].values()))==9
assert set(value['outputs'].values()).isdisjoint(value['required_absent'])
assert (manifest.stat().st_mode&0o777)==0o600 and manifest.stat().st_nlink==1

# Existing conflicting, symlinked, multi-link, or wrong-mode targets must be
# rejected without replacement or metadata repair.
def conflict(name,prepare):
    target=oproot/name;prepare(target);before=target.read_bytes() if target.is_file() else None
    result=run(embedded,target);assert result.returncode!=0
    if before is not None: assert target.read_bytes()==before
    return result
conflict('conflict.json',lambda p:(p.write_bytes(b'conflict\n'),p.chmod(0o600)))
conflict('wrong-mode.json',lambda p:(p.write_bytes(manifest.read_bytes()),p.chmod(0o644)))
def linked(p):
    p.write_bytes(manifest.read_bytes());p.chmod(0o600);os.link(p,p.with_suffix('.alias'))
linked_result=conflict('linked.json',linked)
assert 'existing manifest differs' in linked_result.stderr
link_target=oproot/'symlink-target';link_target.write_bytes(b'keep\n');link_target.chmod(0o600)
symlink=oproot/'symlink.json';symlink.symlink_to(link_target)
symlink_result=run(embedded,symlink);assert symlink_result.returncode!=0 and link_target.read_bytes()==b'keep\n'

# A stale random-name predecessor cannot block create-once publication.
stale_target=oproot/'stale.json';stale=oproot/('.'+stale_target.name+'.tmp.interrupted')
stale.write_bytes(b'incomplete');stale.chmod(0o600)
stale_result=run(embedded,stale_target);assert stale_result.returncode==0 and stale.exists()

# Crash immediately after rename: committed bytes survive and exact replay is
# accepted, proving the rename boundary is no-clobber and crash-resumable.
crash_target=oproot/'crash.json'
crash_source=embedded.replace("  else:\n   os.fsync(parent_fd)\n   reattest_parent(parent_stat)",
                             "  else:\n   os.fsync(parent_fd)\n   os._exit(90)\n   reattest_parent(parent_stat)",1)
crashed=run(crash_source,crash_target);assert crashed.returncode==90 and crash_target.exists()
assert run(embedded,crash_target).returncode==0
print('4fba launcher hermetic manifest fixture passed')
PY
