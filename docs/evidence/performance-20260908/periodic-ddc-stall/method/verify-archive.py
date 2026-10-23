"""Recompute the four recorded measurements offline; never launch a window."""
from pathlib import Path
import gzip, hashlib, json, os, shutil, subprocess, tempfile
b=Path(__file__).resolve().parent.parent
rows=json.loads((b/'comparison.json').read_text())
labels=['ddcpoll-v1-'+s for s in ['original-a1','ondemand-b1','ondemand-b2','original-a2']]
assert [r['label'] for r in rows]==labels
assert [r['direct_output'] for r in rows]==[0,0,0,0]
assert [r['commit_mode'] for r in rows]==['commit','commit','commit','commit']
with tempfile.TemporaryDirectory(prefix='viewflow-direct-output-verify-') as name:
    root=Path(name)
    for label in labels:
        p=root/label;p.mkdir()
        for f in (b/'runs'/label).iterdir():
            if f.suffix=='.gz':(p/f.stem).write_bytes(gzip.decompress(f.read_bytes()))
            elif f.name=='state.json':shutil.copy2(f,p/f.name)
    subprocess.run(['python',str(b/'method/analyze-integrated.py'),str(root),*labels],check=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),stdout=subprocess.DEVNULL)
    assert json.loads((root/'commit-wakeup-comparison.json').read_text())==rows
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
c=json.loads((b/'nested/state.json').read_text())
assert c['ab_trials']=='passed' and c['smoke']=='passed' and c['nested_stopped']
assert not c['configerrors'].strip()
assert c['before_plugins']==c['after_plugins']
before={m['name']:m for m in c['before_monitors']};after={m['name']:m for m in c['after_monitors']}
assert before.keys()==after.keys() and c['output'] not in after
for name in before:
    for key in ['id','x','y','width','height','scale','transform','refreshRate']:
        assert before[name][key]==after[name][key]
    v=before[name]
    assert c['outer_monitor']['x']-(v['x']+v['width']/v['scale'])>=32768
    assert c['outer_monitor']['y']-(v['y']+v['height']/v['scale'])>=32768
assert c['test_so_sha256']==json.loads((b/'method/plugin-sha256.json').read_text())['sha256']
compositor=gzip.decompress((b/'nested/compositor.log.gz').read_bytes()).decode(errors='replace')
stops={}
for line in compositor.splitlines():
    if line.startswith('viewflow-capture-cadence stop=1 '):
        values=dict(x.split('=',1) for x in line.split()[1:])
        stops[values['stream']]=values
for row in rows:
    selected=stops[row['capture_selection']['stream']]
    assert selected['mode']==row['commit_mode'] and selected['fps']=='60'
    assert int(selected['attempts'])>1000
    if row['commit_mode']=='commit':assert int(selected['commit_attempts'])>1000
    else:assert int(selected['commit_attempts'])==0
smoke=json.loads((b/'nested/smoke.json').read_text())
assert smoke['passed'] and not smoke.get('cleanup_errors')
assert all(smoke[k] for k in ['held_a_b_progress','survives_peer_stop','restart_after_empty','legacy_grid'])
assert len(smoke['frames'])==169
for row in rows:
    state_row=json.loads((b/'runs'/row['label']/'state.json').read_text())
    assert state_row['linux_before']['plugins']==state_row['linux_after']['plugins']
    assert state_row['performance_mode']==('latency' if row['commit_mode']=='commit' else 'frame-rate')
state=json.loads((b/'method/final-state.json').read_text())
assert not state['processes'] and not state['tasks'] and not state['port']
assert state['config_hash']==hashlib.sha256((b/'method/vdd-before.xml').read_bytes()).hexdigest().upper()
previous=json.loads((b.parent/'hyperv-timer-enabled/runs/hyperv-v2-off-a2/state.json').read_text())
assert reference['windows_binaries']==previous['windows_binaries']
assert reference['linux_binaries']==json.loads((b/'method/linux-binaries.json').read_text())
for label in labels:
    s=json.loads((b/'runs'/label/'state.json').read_text())
    stable=lambda rows:[{k:r[k] for k in ['Id','PriorityClass']} for r in rows]
    assert stable(s['before']['esrv'])==stable(s['after']['esrv'])==stable(reference['before']['esrv'])
assert stable(state['esrv'])==stable(reference['before']['esrv'])
assert [r['ddc_poll_mode'] for r in rows]==['original','ondemand','ondemand','original']
assert c['status_restored']
for r in rows:
    state_r=json.loads((b/'runs'/r['label']/'state.json').read_text())
    expected=b/'method'/('control-panel-status-before.sh' if r['ddc_poll_mode']=='original' else 'control-panel-status-candidate.sh')
    assert state_r['status_script_sha256']==hashlib.sha256(expected.read_bytes()).hexdigest()
recorded=(b/'method/stall-correlation.json').read_bytes()
subprocess.run(['python3',str(b/'method/analyze-stalls.py')],check=True)
assert (b/'method/stall-correlation.json').read_bytes()==recorded
application=json.loads((b/'method/application.json').read_text())
assert application['after_sha256']==hashlib.sha256((b/'method/control-panel-status-candidate.sh').read_bytes()).hexdigest()
assert application['before_sha256']==application['backup_sha256']==hashlib.sha256((b/'method/control-panel-status-before.sh').read_bytes()).hexdigest()
applied=json.loads((b/'method/applied-processes.json').read_text())
assert applied['end_ns']-applied['start_ns']>=23_000_000_000
assert any(p['known_status_helper'] for p in applied['processes'])
assert not any(p['comm']=='ddcutil' for p in applied['processes'])
manifest=json.loads((b/'sha256.json').read_text())
for name,digest in manifest.items():
    assert hashlib.sha256((b/name).read_bytes()).hexdigest()==digest,name
print('PASS four raw-log analyses, passive 4K observations, unchanged binary identities, cleanup and',len(manifest),'hashes; first-present timing and 4K60 remain unverified')
