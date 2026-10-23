"""Offline verification only: this script never creates a desktop window."""
from pathlib import Path
import hashlib, json, re, struct
from PIL import Image
b = Path(__file__).resolve().parent.parent
m = b/'method'
data = (m/'host-blur-panels.bgra').read_bytes()
w,h = struct.unpack('<II',data[:8])
assert (w,h)==(768,256) and len(data)==8+w*h*4
pixels=data[8:]
assert Image.open(m/'host-blur-panels.png').convert('RGB').tobytes()==Image.frombytes('RGB',(w,h),pixels,'raw','BGRX').tobytes()
def sample(panel,x,y,c):
    return pixels[(y*w+panel*256+x)*4+c]
mismatches=sum(abs(sample(0,x,y,c)-sample(1,x,y,c))>2 for y in range(256) for x in range(256) for c in range(3))
blur_difference=sum(abs(sample(0,x,y,c)-sample(2,x,y,c))>5 for y in range(32,224) for x in range(32,224) for c in range(3))
assert mismatches==0 and blur_difference==110592
log=(m/'host-backdrop-result.log').read_text()
assert 'hit_queries=4 owned_hits=0 input_injected=0' in log
assert 'output=0,0,3840,2400 exact4k=1' in log
for phase in range(4):
    assert f'phase={phase} verified=1 mismatched_channels=0 foreground_unchanged=1' in log
assert 'background_response=80 blurred_difference_channels=110592' in log
state=json.loads((m/'state.json').read_text())
assert state['exit']==state['remaining']==state['tasks']==0
assert state['esrv_before']==state['esrv_after']
linux=json.loads((m/'passive-fixture-state.json').read_text())
assert linux['exit']==0 and linux['frames_rendered']==276 and linux['empty_input_regions']
protocol=(m/'passive-fixture.log').read_text()
for region in linux['empty_input_regions']:
    assert re.search(r'create_region\(new id wl_region[#@]'+region+r'\)',protocol)
    assert re.search(r'set_input_region\(wl_region[#@]'+region+r'\)',protocol)
    assert not re.search(r'wl_region[#@]'+region+r'\.add\(',protocol)
assert not linux['configerrors'] and linux['before_plugins']==linux['after_plugins']
before={x['name']:x for x in linux['before_monitors']}
after={x['name']:x for x in linux['after_monitors']}
assert before.keys()==after.keys() and linux['owned_output'] not in after
for name in before:
    for key in ['x','y','width','height','scale','transform','refreshRate']:
        assert before[name][key]==after[name][key]
    prior=before[name]
    assert linux['monitor']['x']-(prior['x']+prior['width']/prior['scale'])>=32768
    assert linux['monitor']['y']-(prior['y']+prior['height']/prior['scale'])>=32768
for key in ['before_focus','during_focus','after_focus']:
    assert linux[key].get('address')!=linux['client']['address']
audit=json.loads((m/'remote-audit.json').read_text())
assert not audit['processes'] and not audit['tasks'] and not audit['port']
assert audit['esrv']==state['esrv_after']
assert audit['config_hash']==json.loads((b.parent/'background-cache-ablation/method/final-state.json').read_text())['config_hash']
local=json.loads((m/'source-sha256.json').read_text())
assert {x['path']:x['hash'].lower() for x in audit['sources']}==local
assert any(x['hash']==state['exe']['Hash'] for x in audit['binaries'])
for name,digest in local.items():
    assert hashlib.sha256((b/'source'/name).read_bytes()).hexdigest()==digest,name
manifest=json.loads((b/'sha256.json').read_text())
for name,digest in manifest.items():
    assert hashlib.sha256((b/name).read_bytes()).hexdigest()==digest,name
print('PASS saved blur pixels, PNG fidelity, passive input evidence, source identity, cleanup and',len(manifest),'archive hashes; no performance claim')
