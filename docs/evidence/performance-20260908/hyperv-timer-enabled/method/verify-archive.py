"""Recompute the four recorded measurements offline; never launch a window."""
from pathlib import Path
import gzip, hashlib, json, os, shutil, subprocess, tempfile
b=Path(__file__).resolve().parent.parent
rows=json.loads((b/'comparison.json').read_text())
labels=['hyperv-v2-'+s for s in ['off-a1','on-b1','on-b2','off-a2']]
assert [r['label'] for r in rows]==labels
assert [r['direct_output'] for r in rows]==[0,1,1,0]
with tempfile.TemporaryDirectory(prefix='viewflow-direct-output-verify-') as name:
    root=Path(name)
    for label in labels:
        p=root/label;p.mkdir()
        for f in (b/'runs'/label).iterdir():
            if f.suffix=='.gz':(p/f.stem).write_bytes(gzip.decompress(f.read_bytes()))
            elif f.name=='state.json':shutil.copy2(f,p/f.name)
    subprocess.run(['python',str(b/'method/analyze-integrated.py'),str(root),*labels],check=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),stdout=subprocess.DEVNULL)
    assert json.loads((root/'direct-output-comparison.json').read_text())==rows
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
audit=json.loads((b/'method/remote-audit.json').read_text())
for s in [state,audit]:
    assert not s['processes'] and not s['tasks'] and not s['port']
    assert s['config_hash']==hashlib.sha256((b/'method/vdd-before.xml').read_bytes()).hexdigest().upper()
    assert s['esrv']==[{k:v[k] for k in ['Id','PriorityClass']} for v in reference['before']['esrv']]
source=json.loads((b/'method/source-sha256.json').read_text())
assert {x['path']:x['hash'].lower() for x in audit['sources']}==source
for name,digest in source.items():
    assert hashlib.sha256((b/'source'/name).read_bytes()).hexdigest()==digest,name
for x in audit['binaries']:
    match=[r for r in reference['windows_binaries'] if r['Path']==x['path']]
    if match:assert match[0]['Hash']==x['hash']
host=json.loads((b/'method/host-oracle-state.json').read_text())
assert host['exit']==host['remaining']==host['tasks']==0
assert host['esrv_before']==host['esrv_after']
text=(b/'method/host-backdrop-result.log').read_text()
assert text.count('verified=1 mismatched_channels=0 foreground_unchanged=1')==4
assert 'background_response=80 blurred_difference_channels=110592' in text
assert 'hit_queries=4 owned_hits=0 input_injected=0' in text
assert any(x['path']==host['exe']['Path'] and x['hash']==host['exe']['Hash'] for x in audit['binaries'])
style=(b/'method/style-probe.log').read_text().splitlines()
assert len([x for x in style if x.startswith('style-sample ')])==60
for line in style:
    if not line.startswith('style-sample '):continue
    values=dict(x.split('=',1) for x in line.split()[1:])
    assert values['rgb']==['0000ff','00ff00','ff0000'][int(values['mode'])]
    assert values['owned_hit']=='0' and values['foreground_unchanged']=='1'
wait=json.loads((b/'method/state.json').read_text(encoding='utf-8-sig'))
before_wait=json.loads((b.parent/'wait-resolution-probe/method/state.json').read_text(encoding='utf-8-sig'))
assert wait['binary']['Hash']==before_wait['binary']['Hash']
assert wait['result']==wait['remaining']==wait['tasks']==0
assert wait['before_esrv']==wait['after_esrv']
expected=json.loads((b/'wait-comparison.json').read_text())
subprocess.run(['python',str(b/'method/analyze.py')],check=True,stdout=subprocess.DEVNULL)
assert json.loads((b/'wait-comparison.json').read_text())==expected
manifest=json.loads((b/'sha256.json').read_text())
for name,digest in manifest.items():
    assert hashlib.sha256((b/name).read_bytes()).hexdigest()==digest,name
print('PASS four raw-log analyses, passive 4K observations, blur selection, source identities, cleanup and',len(manifest),'hashes; first-present timing and 4K60 remain unverified')
