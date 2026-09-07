#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

launcher=${EARLY_BOOTSTRAP_GATE_2CA3_LAUNCHER_SOURCE:-/home/wilf/data/viewflow/deploy/launch-early-bootstrap-gate-abort-2ca3f466.sh}
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
/usr/bin/python3 -I - "$launcher" "$root" <<'PY'
import hashlib,importlib.util,json,os,subprocess,sys
from pathlib import Path
launcher=Path(sys.argv[1]);fixture=Path(sys.argv[2]);op='2ca3f46635b65615a1cffc1970d73911'
oproot=fixture/op;oproot.mkdir(mode=0o700)
s=launcher.read_text(encoding='utf-8')
blocks=s.split("<<'PY'\n")
embedded=blocks[1].split('\nPY\n',1)[0]
sealed_core_wrapper=blocks[2].split('\nPY\n',1)[0]
embedded=embedded.replace("root=Path('/home/wilf/.local/state/viewflow/deployments')/op",f"root=Path({str(fixture)!r})/op")
manifest=oproot/'manifest.json';candidate='/fixture/reviewed-native-marker';sha='9'*64
provenance='/fixture/reviewed-build.json';provenance_sha='8'*64

# Run every extracted bootstrap under a hostile cwd/PYTHONPATH.  Isolated
# interpreters must ignore these shadow modules and use only the system stdlib.
shadow=fixture/'shadow';shadow.mkdir(mode=0o700)
for name in ('hashlib','json','pathlib','os','stat','fcntl'):
    (shadow/(name+'.py')).write_text("raise AssertionError('shadow module imported')\n",encoding='utf-8')
poison_env={'PATH':'/usr/bin:/bin','PYTHONPATH':str(shadow),'PYTHONHOME':str(shadow)}

# After the wrapper has attested the source path and sealed its bytes, swap the
# path with different code immediately before exec.  The original bytes must
# still execute from the inherited sealed memfd.
core_source=fixture/'stable-core.py'
core_source.write_text("import os\nassert os.environ.get('PATH')=='/usr/bin:/bin' and set(os.environ)<= {'PATH','LC_CTYPE'}\nprint('original-core')\n",encoding='utf-8')
os.chmod(core_source,0o755)
core_sha=hashlib.sha256(core_source.read_bytes()).hexdigest()
swap_wrapper=sealed_core_wrapper.replace(
    "  os.execve('/usr/bin/python3'",
    "  try: os.write(memfd,b'forbidden mutation')\n"
    "  except OSError: pass\n"
    "  else: raise SystemExit('sealed core accepted a write')\n"
    "  os.rename(core_path,core_path+'.moved')\n"
    "  with open(core_path,'wb') as swapped: swapped.write(b\"print('swapped-core')\\n\")\n"
    "  os.chmod(core_path,0o755)\n"
    "  os.execve('/usr/bin/python3'",1)
swapped=subprocess.run(['/usr/bin/python3','-I','-c',swap_wrapper,str(core_source),core_sha,'--check-only',
                        '/fixture/manifest','0'*64],cwd=shadow,env=poison_env,
                       text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
assert swapped.returncode==0 and swapped.stdout=='original-core\n'
assert core_source.read_text(encoding='utf-8')=="print('swapped-core')\n"

def run(source,path,check=False):
    return subprocess.run(['/usr/bin/python3','-I','-c',source,str(path),candidate,sha,provenance,provenance_sha],
                          cwd=shadow,env=poison_env,check=check,text=True,
                          stdout=subprocess.PIPE,stderr=subprocess.PIPE)

# Simulate a publisher dying immediately after the no-replace rename.  The
# committed target must survive, and a replay must accept its exact bytes.
crash_manifest=oproot/'publish-after-crash.json'
crash_source=embedded.replace("  else:\n   os.fsync(parent_fd)\n   reattest_parent(parent_stat)",
                             "  else:\n   os.fsync(parent_fd)\n   os._exit(90)\n   reattest_parent(parent_stat)",1)
crashed=run(crash_source,crash_manifest)
assert crashed.returncode==90 and crash_manifest.exists()
crash_replay=run(embedded,crash_manifest,check=True)
assert crash_replay.stdout==hashlib.sha256(crash_manifest.read_bytes()).hexdigest()+'\n'

# First publish and existing-identical replay are both successful.
first=run(embedded,manifest,check=True)
second=run(embedded,manifest,check=True)
assert first.stdout==second.stdout
value=json.loads(manifest.read_text())
assert set(value)=={'schema_version','state','operation_id','identity','artifacts','installed','marker','windows_baseline','runtime_helper','execution','outputs','required_absent'}
assert value['operation_id']==op and value['state']=='viewflow-early-bootstrap-gate-abort-manifest'
assert value['artifacts']['coordinator_state']['sha256'].startswith('6eeae66c')
assert value['execution']['marker_candidate']=={'path':candidate,'sha256':sha,'mode':755,
    'reviewed_build_manifest':{'path':provenance,'sha256':provenance_sha,'mode':600}}
assert value['execution']['viewflow_unit']=='viewflow-v13-early-'+op+'.service'
assert len(value['outputs'])==9 and len(set(value['outputs'].values()))==9
assert set(value['outputs'].values()).isdisjoint(set(value['required_absent']))
assert value['execution']['runtime_marker_path'] in value['required_absent']
assert value['execution']['abort_claim_path'] in value['required_absent']
assert value['execution']['release_claim_path'] in value['required_absent']
assert len(value['required_absent'])==3
assert value['windows_baseline']['new_operation_root_path'].endswith(op)
assert value['windows_baseline']['task_xml_sha256']=='89ab8d07d19a99614361900a718e2300f6d239bf8d17b1d32101664369758b33'
assert (manifest.stat().st_mode & 0o777)==0o600 and manifest.stat().st_nlink==1

# An existing conflicting file is rejected and remains byte-for-byte intact:
# this is the fixture's explicit no-clobber assertion.
conflict_manifest=oproot/'conflict-manifest.json'
conflict_manifest.write_bytes(manifest.read_bytes())
os.chmod(conflict_manifest,0o600)
conflict_bytes=b'conflicting manifest must not be replaced\n'
conflict_manifest.write_bytes(conflict_bytes)
conflict=run(embedded,conflict_manifest)
assert conflict.returncode!=0 and 'existing manifest differs' in conflict.stderr
assert conflict_manifest.read_bytes()==conflict_bytes

# Identical bytes with unsafe metadata are rejected as well.
metadata_manifest=oproot/'unsafe-metadata-manifest.json'
metadata_manifest.write_bytes(manifest.read_bytes())
os.chmod(metadata_manifest,0o644)
metadata=run(embedded,metadata_manifest)
assert metadata.returncode!=0 and 'existing manifest differs' in metadata.stderr
assert metadata_manifest.read_bytes()==manifest.read_bytes()

# A stale owner-only temporary left by an interrupted pre-rename publisher is
# harmless; a new random temporary name still publishes successfully.
stale_manifest=oproot/'stale-temp-manifest.json'
stale_name='.'+stale_manifest.name+'.tmp.interrupted'
(oproot/stale_name).write_bytes(b'incomplete')
os.chmod(oproot/stale_name,0o600)
stale=run(embedded,stale_manifest,check=True)
assert stale_manifest.exists() and (oproot/stale_name).exists() and stale.returncode==0

# This fixture is intentionally exact: it mirrors REVIEWED_TEST_MATRIX in the
# core validator so a future reviewed-build producer cannot silently drift from
# the candidate schema that the manifest points to.
reviewed_build={
    'schema_version':1,
    'state':'viewflow-deployment-marker-reviewed-build',
    'candidate':{'path':candidate,'sha256':sha,'mode':755},
    'rust_sources':{'main':{'path':'/fixture/viewflow-deployment-marker/src/main.rs','sha256':'1'*64,'mode':600},
                    'library':{'path':'/fixture/viewflow-deployment-marker/src/lib.rs','sha256':'2'*64,'mode':600}},
    'package_manifest':{'path':'/fixture/viewflow-deployment-marker/Cargo.toml','sha256':'3'*64,'mode':600},
    'cargo_lock':{'path':'/fixture/Cargo.lock','sha256':'4'*64,'mode':600},
    'test_matrix':{
        'cargo_fmt':'cargo fmt --all -- --check',
        'cargo_test':'cargo test -p viewflow-deployment-marker --bin viewflow-deployment-marker',
        'cargo_clippy':'cargo clippy -p viewflow-deployment-marker --bin viewflow-deployment-marker -- -D warnings',
        'cargo_fmt_passed':True,'cargo_test_passed':True,'cargo_clippy_passed':True,
    },
}
assert set(reviewed_build)=={'schema_version','state','candidate','rust_sources','package_manifest','cargo_lock','test_matrix'}
assert set(reviewed_build['rust_sources'])=={'main','library'}
assert reviewed_build['candidate']=={k:value['execution']['marker_candidate'][k] for k in ('path','sha256','mode')}
core_spec=importlib.util.spec_from_file_location('early_bootstrap_gate_abort',launcher.parent/'early-bootstrap-gate-abort.py')
core=importlib.util.module_from_spec(core_spec);core_spec.loader.exec_module(core)
assert reviewed_build['test_matrix']==core.REVIEWED_TEST_MATRIX
print('2ca3 launcher hermetic manifest fixture passed')
PY
