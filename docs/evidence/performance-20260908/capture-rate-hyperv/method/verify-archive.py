"""Recompute the four recorded measurements offline; never launch a window."""
from pathlib import Path
import gzip, hashlib, json, os, shutil, subprocess, tempfile
b=Path(__file__).resolve().parent.parent
rows=json.loads((b/'comparison.json').read_text())
labels=['rate-v1-'+s for s in ['60-a1','90-b1','90-b2','60-a2']]
assert [r['label'] for r in rows]==labels
assert [r['direct_output'] for r in rows]==[0,0,0,0]
assert [r['capture_fps'] for r in rows]==[60,90,90,60]
with tempfile.TemporaryDirectory(prefix='viewflow-direct-output-verify-') as name:
    root=Path(name)
    for label in labels:
        p=root/label;p.mkdir()
        for f in (b/'runs'/label).iterdir():
            if f.suffix=='.gz':(p/f.stem).write_bytes(gzip.decompress(f.read_bytes()))
            elif f.name=='state.json':shutil.copy2(f,p/f.name)
    subprocess.run(['python',str(b/'method/analyze-integrated.py'),str(root),*labels],check=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),stdout=subprocess.DEVNULL)
    assert json.loads((root/'capture-rate-comparison.json').read_text())==rows
    for label in labels:
        for n in ['analysis.json','timeline.json']:
            assert json.loads((root/label/n).read_text())==json.loads((b/'runs'/label/n).read_text())
reference=json.loads((b/'runs'/labels[0]/'state.json').read_text())
for r in rows:
    s=json.loads((b/'runs'/r['label']/'state.json').read_text())
    assert not s.get('error') and not s['cleanup_errors'] and not s['after']['port']
    if s['after']['processes']:
        assert r['cleanup_following_trial']==labels[labels.index(r['label'])+1]
        following=json.loads((b/'runs'/r['cleanup_following_trial']/'state.json').read_text())
        assert not following['before']['processes'] and not following['before']['port']
    else:assert r['cleanup_following_trial'] is None
    assert s['windows_binaries']==reference['windows_binaries'] and s['linux_binaries']==reference['linux_binaries']
    assert json.loads(s['observer_result'])['LastTaskResult']==0
    assert r['quality_pass']==(r['frame_validation']['invalid']==0)
    if not r['direct_output']:assert r['quality_pass']
    assert r['desktop']['marker_span_fraction']>.99
    assert r['desktop']['requested_seconds']==30
    assert r['desktop']['changes_per_requested_second']==r['desktop']['observed_changes']/30
    assert s['linux_during']['focus'].get('address')!=s['fixture_client']['address']
    assert 'passive_proxy styles_verified=1 hit_queries=5 owned_hits=0 input_injected=0' in r['monitor_lines']
c=json.loads((b/'method/control-state.json').read_text())
assert c['trials']=='completed' and not c.get('error') and not c['configerrors']
assert c['before_plugins']==c['after_plugins']
before={m['name']:m for m in c['before_monitors']};after={m['name']:m for m in c['after_monitors']}
assert before.keys()==after.keys() and c['owned_output'] not in after
for name in before:
    for key in ['id','x','y','width','height','scale','transform','refreshRate']:
        assert before[name][key]==after[name][key]
    m=before[name]
    assert c['owned_monitor']['x']-(m['x']+m['width']/m['scale'])>=32768
    assert c['owned_monitor']['y']-(m['y']+m['height']/m['scale'])>=32768
state=json.loads((b/'method/final-state.json').read_text())
assert not state['processes'] and not state['tasks'] and not state['port']
assert state['config_hash']==hashlib.sha256((b/'method/vdd-before.xml').read_bytes()).hexdigest().upper()
previous=json.loads((b.parent/'hyperv-timer-enabled/runs/hyperv-v2-off-a2/state.json').read_text())
assert reference['windows_binaries']==previous['windows_binaries']
assert reference['linux_binaries']==previous['linux_binaries']
for label in labels:
    s=json.loads((b/'runs'/label/'state.json').read_text())
    assert s['before']['esrv']==s['after']['esrv']==[]
manifest=json.loads((b/'sha256.json').read_text())
for name,digest in manifest.items():
    assert hashlib.sha256((b/name).read_bytes()).hexdigest()==digest,name
print('PASS four raw-log analyses, passive 4K observations, unchanged binary identities, cleanup and',len(manifest),'hashes; first-present timing and 4K60 remain unverified')
