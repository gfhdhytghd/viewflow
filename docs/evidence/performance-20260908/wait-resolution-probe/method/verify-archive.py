from pathlib import Path
import hashlib,json,shutil,subprocess,tempfile
b=Path(__file__).resolve().parent.parent
expected=json.loads((b/'comparison.json').read_text())
with tempfile.TemporaryDirectory(prefix='viewflow-wait-verify-') as name:
    root=Path(name);m=root/'method';m.mkdir()
    for n in ['analyze.py','wait-resolution.log','state.json']:shutil.copy2(b/'method'/n,m/n)
    subprocess.run(['python',str(m/'analyze.py')],check=True,stdout=subprocess.DEVNULL)
    assert json.loads((root/'comparison.json').read_text())==expected
state=json.loads((b/'method/state.json').read_text(encoding='utf-8-sig'))
binaries=json.loads((b/'method/binary-hashes.json').read_text())
assert state['binary'] in binaries
guest=json.loads((b/'method/guest-hypervisor.json').read_text())
assert guest['vendor']=='KVMKVMKVM' and guest['max_hypervisor_leaf']==0x40000001
proposal=json.loads((b/'method/proposed-cpu-change.json').read_text())
assert not proposal['applied'] and proposal['requires_vm_restart']
paused=json.loads((b/'method/paused-qemu-validation.json').read_text())
assert paused['exit']==0 and not paused['status']['return']['running']
assert paused['properties']==dict.fromkeys(['hv-vpindex','hv-time','hv-synic','hv-stimer'],True)
assert '-S' in paused['command'] and '-nodefaults' in paused['command']
assert not any(x in paused['command'] for x in ['-drive','-blockdev','-hda','-device'])
final=json.loads((b/'method/host-final-state.json').read_text())
assert final['unit_sha256']==proposal['before_sha256'] and final['running_cpu_argument']=='host'
access=json.loads((b/'method/live-qmp-access.json').read_text());assert not access['queried']
manifest=json.loads((b/'sha256.json').read_text())
for n,h in manifest.items():assert hashlib.sha256((b/n).read_bytes()).hexdigest()==h,n
print('PASS 2048 recorded waits, policy restoration, guest identity, isolated paused CPU validation, unapplied proposal and',len(manifest),'archive hashes; no end-to-end performance claim')
