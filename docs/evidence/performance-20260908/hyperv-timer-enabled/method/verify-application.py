"""Verify recorded application and restart evidence; --live checks unit files."""
from pathlib import Path
import hashlib, json, sys
b=Path(__file__).resolve().parent.parent
def read(name): return json.loads((b/'method'/name).read_text())
application=read('application.json')
before=read('qmp-before.json');after=read('qmp-after.json')
assert all(v['return'] is False for v in before['properties'].values())
assert all(v['return'] is True for v in after['properties'].values())
assert set(after['properties'])=={'hv-vpindex','hv-time','hv-synic','hv-stimer'}
assert before['cpu_count']==after['cpu_count']==10
runtime=read('runtime-after.json')
assert runtime['argv_selected']['-cpu']=='host,hv-vpindex=on,hv-time=on,hv-synic=on,hv-stimer=on'
assert runtime['argv_selected']['-smp']=='10,sockets=1,cores=10,threads=1'
assert runtime['argv_selected']['-m']=='24576'
old=read('guest-after-boot.json');new=read('guest-after-restart.json')
assert old['boot']!=new['boot']
assert old['hypervisor']['qpc_frequency']==100000000
assert new['hypervisor']['qpc_frequency']==10000000
assert new['hypervisor']['vendor']=='Microsoft Hv'
assert new['hypervisor']['max_hypervisor_leaf']==0x40000005
shutdown=read('shutdown-state.json')[-1]
assert shutdown['MainPID']=='0' and shutdown['Result']=='success' and shutdown['ExecMainStatus']=='0'
assert read('powerdown.json')['forced'] is False
# The archived file concatenates JSON stdout and localized SSH/PowerShell stderr.
restart,_=json.JSONDecoder().raw_decode((b/'method/guest-restart-request.log').read_bytes().decode('gb18030').lstrip())
assert restart['forced'] is False and restart['exit']==0
assert application['applied'] is True
assert hashlib.sha256((b/'method/service-before.txt').read_bytes()).hexdigest()==application['before_sha256']
assert hashlib.sha256((b/'method/candidate.service').read_bytes()).hexdigest()==application['after_sha256']
if '--live' in sys.argv:
    assert hashlib.sha256(Path(application['unit']).read_bytes()).hexdigest()==application['after_sha256']
    assert hashlib.sha256(Path(application['backup']).read_bytes()).hexdigest()==application['before_sha256']
manifest=json.loads((b/'sha256.json').read_text())
for name,digest in manifest.items():
    assert hashlib.sha256((b/name).read_bytes()).hexdigest()==digest,name
print('PASS applied CPU options, graceful QEMU exit, fresh Windows kernel, CPUID/QPC, backup and',len(manifest),'hashes; no performance claim')
