"""Verify and archive the isolated two-frame outer admission-limit experiment."""
from pathlib import Path
import json,hashlib,re,subprocess,shutil
b=Path(__file__).resolve().parent.parent;p=b/'depth-limit'
read=lambda p:json.loads(p.read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and len(m)==69 and all(sha(p/'source'/k)==v for k,v in m.items());assert '100% tests passed, 0 tests failed out of 6' in (p/'method/build.log').read_text()
records=[];table=['| Trial | Outer limit | FPS | Median upper ms | P95 upper ms | Max upper ms |','|---|---:|---:|---:|---:|---:|']
for name in ['depthlimit-four-a1','depthlimit-two-b1','depthlimit-two-b2','depthlimit-four-a2']:
 d=b/'transport/runs'/name;s=read(d/'state.json');r=read(d/'summary.json');assert r['run_qualified'] and s['native_hash_before']==s['native_hash_after']
 assert not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies'] and s['before']['installed']==s['after']['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB'
 assert s['mode_restored']['mode']==s['mode_before']['mode'] and s['mode_selected']['max_pending']==s['max_pending']
 source=Path(s['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients'];target=b/'transport/nested'/name;target.mkdir(exist_ok=True,parents=True)
 for f in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
  if (source/f).exists():shutil.copy2(source/f,target/f)
 text=(d/'source.log').read_text(errors='replace');limit=s['max_pending'];assert f'reverse_performance mode={s["performance_mode"]} max_pending={limit}' in text and 'async=2 ' in text and 'encoder_vpl_pool depth=2 minimum=3 suggested=3 allocated=3' in text
 pending=[int(x) for x in re.findall(r'profile_submit .*?pending=(\d+)',text)];assert pending and max(pending)<limit
 subprocess.run(['python3',str(b/'method/check-encoder-accounting.py'),str(d),'--bounded-stop'],check=True)
 records.append({'trial':name,'limit':limit,'before_submit_counts':{str(i):pending.count(i) for i in set(pending)},'native_sha256':s['native_hash_before'],'summary':r});t=r['latency_high_ms'];table.append(f"| {name} | {limit} | {r['desktop_distinct_hz']:.3f} | {t['median']:.3f} | {t['p95']:.3f} | {t['max']:.3f} |")
assert len({r['native_sha256'] for r in records})==1
(b/'transport/depth-limit-comparison.json').write_text(json.dumps(records,indent=2)+'\n')
(p/'README.md').write_text('# Two-frame outer limit with a two-task encoder\n\nAn isolated copy changes the public latency mode admission limit from one to two, leaving frame-rate at four. The one corresponding expected-value test is updated. All other source files match the installed canonical snapshot; 69 local/remote inputs match and six Windows CTests pass. The same executable runs four/two/two/four, using actual controller readback, source mode logs, queue occupancy and the same VPL depth-two pool.\n\n'+'\n'.join(table)+'\n\nThe two-frame limit falls to 48.46–48.51 FPS and raises P95 to 81.85–85.09 ms; four-frame controls are 53.99–54.46 FPS with P95 63.80–75.75 ms. It is rejected for deployment. Normal drain requests can limit overlap when the outer queue is full; exact causal GPU scheduling is not proven by these logs. The current public limits remain four and one.\n\nAll complete 6K transport trials qualify and drain/PTS accounting passes. Bounded transport stop tails remain explicitly counted. The installed source, mode configuration and unrelated desktop/input services are unchanged, with private tasks, proxies and nested compositors removed. No physical scanout or physical input acceptance is claimed.\n')
for f,heading,body in [(b/'README.md','## 两个在途画面的外层上限','将外层在途上限从四降到二后，两轮只有 48.46–48.51FPS，P95 升到 81.85–85.09ms；未采用，现有两种模式上限保持四／一。累计 97 轮有效完整链路。[隔离对照](depth-limit/README.md)。'),(b/'transport/README.md','## Two-frame outer admission limit','Four additional qualified trials bring the total to 97. The limit-two candidate is slower than both four-frame controls and is rejected. [Source, actual mode readback, occupancy and latency](../depth-limit/README.md).')]:
 t=f.read_text();assert heading not in t;f.write_text(t+'\n'+heading+'\n\n'+body+'\n')
print('Four admission-limit trials verified and archived')
