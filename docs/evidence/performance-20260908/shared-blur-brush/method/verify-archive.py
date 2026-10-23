"""Recompute the four recorded measurements offline; never launch a window."""
from pathlib import Path
import gzip, hashlib, json, os, shutil, subprocess, tempfile
b=Path(__file__).resolve().parent.parent
rows=json.loads((b/'comparison.json').read_text())
labels=['sharedblur-v1-'+s for s in ['off-a1','on-b1','on-b2','off-a2']]
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
    subprocess.run(['python',str(b/'method/analyze-import.py'),str(root),*labels],check=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),stdout=subprocess.DEVNULL)
    assert json.loads((root/'import-comparison.json').read_text())==json.loads((b/'import-comparison.json').read_text())
    for label in labels:
        for n in ['analysis.json','timeline.json','import-analysis.json']:
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
expected=json.loads((b/'method/integrated-binary-hashes.json').read_text())
for item in expected:assert item in reference['windows_binaries']
old_windows={i['Path']:i['Hash'] for i in previous['windows_binaries']}
for item in reference['windows_binaries']:
    if item['Path'] in old_windows:assert item['Hash']==old_windows[item['Path']]
assert reference['linux_binaries']==json.loads((b/'method/linux-binaries.json').read_text())
assert [r['import_cache_mode'] for r in rows]==['1','1','1','1']
assert [r['shared_blur_mode'] for r in rows]==['0','1','1','0']
initial=reference['before']['esrv']
assert len(initial)==1 and initial[0]['PriorityClass']==128
for row in rows:
    sr=json.loads((b/'runs'/row['label']/'state.json').read_text())
    assert sr['status_script_sha256']=='bd402aa49166d2f29298cd7d44ce94c72edd9f60f4d433c6f60b7126c5aae250'
    for moment in ['before','after']:
        observed=[{key:process[key] for key in ['Id','PriorityClass']} for process in sr[moment]['esrv']]
        assert observed==[{'Id':initial[0]['Id'],'PriorityClass':128}]
    assert sr['after']['esrv'][0]['CPU']>=sr['before']['esrv'][0]['CPU']
assert state['esrv']==[{'Id':initial[0]['Id'],'PriorityClass':128}]
source_hashes=json.loads((b/'method/source-sha256.json').read_text())
for n,h in source_hashes.items():assert hashlib.sha256((b/'source'/n).read_bytes()).hexdigest()==h,n
before_source=json.loads((b/'method/source-before-sha256.json').read_text())
assert [n for n in source_hashes if source_hashes[n]!=before_source[n]]==['platform/windows-composition-preview/sparse_host_backdrop_test.cpp','platform/windows-composition-preview/sparse_shared_visuals.h']
for label,mode in [('baseline',0),('shared',1)]:
    oracle=json.loads((b/'oracles'/label/'state.json').read_text())
    assert oracle['exit']==oracle['remaining']==oracle['tasks']==0
    assert oracle['esrv_before']==oracle['esrv_after']
    log=(b/'oracles'/label/'host-backdrop-result.log').read_text()
    for phase in range(4):
        assert f'shared-blur-test phase={phase} actual_shared={mode} masked_nodes=2' in log
        assert f'host-test phase={phase} verified=1 mismatched_channels=0 foreground_unchanged=1' in log
    assert 'host-test hit_queries=4 owned_hits=0 input_injected=0' in log
import struct
pixel_summary=json.loads((b/'oracle-pixels.json').read_text())
panel_bytes={}
for label in ['baseline','shared']:
    raw=(b/'oracles'/label/'host-blur-panels.bgra').read_bytes();panel_bytes[label]=raw
    w,h=struct.unpack('<II',raw[:8]);assert (w,h)==(768,256) and len(raw)==8+w*h*4
    data=raw[8:];total=peak=over=0
    for y in range(h):
        for x in range(256):
            for channel in range(3):
                delta=abs(data[(y*w+x)*4+channel]-data[(y*w+x+256)*4+channel])
                total+=delta;peak=max(peak,delta);over+=delta>2
    assert pixel_summary[label]==dict(width=w,height=h,reference_candidate_max_rgb_delta=peak,reference_candidate_mean_rgb_delta=total/(256*h*3),rgb_channels_over_2=over)
assert pixel_summary['baseline_shared_panel_bytes_identical']==(panel_bytes['baseline']==panel_bytes['shared'])==True
assert {item['name']:item['hash'].lower() for item in json.loads((b/'method/remote-source-audit.json').read_text())}==source_hashes
manifest=json.loads((b/'sha256.json').read_text())
for name,digest in manifest.items():
    assert hashlib.sha256((b/name).read_bytes()).hexdigest()==digest,name
print('PASS four raw-log analyses, passive 4K observations, unchanged binary identities, cleanup and',len(manifest),'hashes; first-present timing and 4K60 remain unverified')
