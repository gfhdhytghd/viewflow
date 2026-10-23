"""Verify and archive the isolated two-frame outer admission-limit experiment."""
from pathlib import Path
import json,hashlib,re,subprocess,shutil
b=Path(__file__).resolve().parent.parent;p=b/'depth-combined'
read=lambda p:json.loads(p.read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and len(m)==69 and all(sha(p/'source'/k)==v for k,v in m.items());assert '100% tests passed, 0 tests failed out of 6' in (p/'method/build.log').read_text()
records=[];table=['| Trial | WGC interval us | Outer limit | FPS | Median upper ms | P95 upper ms | Max upper ms |','|---|---:|---:|---:|---:|---:|---:|']
for name in ['combinedzero-four-a1','combineddefault-two-b1','combineddefault-two-b2','combinedzero-four-a2','combinedzero-two-c1','combinedzero-two-c2']:
 d=b/'transport/runs'/name;s=read(d/'state.json');r=read(d/'summary.json');assert r['run_qualified'] and s['native_hash_before']==s['native_hash_after']
 assert not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies'] and s['before']['installed']==s['after']['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB'
 assert s['mode_restored']['mode']==s['mode_before']['mode'] and s['mode_selected']['max_pending']==s['max_pending']
 source=Path(s['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients'];target=b/'transport/nested'/name;target.mkdir(exist_ok=True,parents=True)
 for f in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
  if (source/f).exists():shutil.copy2(source/f,target/f)
 text=(d/'source.log').read_text(errors='replace');limit=s['max_pending'];assert f'reverse_performance mode={s["performance_mode"]} max_pending={limit}' in text and 'async=2 ' in text and 'encoder_vpl_pool depth=2 minimum=3 suggested=3 allocated=3' in text
 pending=[int(x) for x in re.findall(r'profile_submit .*?pending=(\d+)',text)];assert pending and max(pending)<limit
 subprocess.run(['python3',str(b/'method/check-encoder-accounting.py'),str(d),'--bounded-stop'],check=True)
 assert f"requested_us={s['wgc_interval_us']}" in text and f"actual_100ns={s['wgc_interval_us']*10}" in text
 records.append({'trial':name,'interval_us':s['wgc_interval_us'],'limit':limit,'before_submit_counts':{str(i):pending.count(i) for i in set(pending)},'native_sha256':s['native_hash_before'],'summary':r});t=r['latency_high_ms'];table.append(f"| {name} | {s['wgc_interval_us']} | {limit} | {r['desktop_distinct_hz']:.3f} | {t['median']:.3f} | {t['p95']:.3f} | {t['max']:.3f} |")
assert len({r['native_sha256'] for r in records})==1
(b/'transport/depth-combined-comparison.json').write_text(json.dumps(records,indent=2)+'\n')
(p/'README.md').write_text('# Deferred drains with explicit WGC cadence\n\nThis candidate combines the qualified deferred-drain gate and two/four admission bounds with the isolated WGC minimum-interval override. All six runs use the same executable. The source logs prove the requested and actual interval, VPL depth two, three input surfaces and admission limit.\n\n'+'\n'.join(table)+'\n\nBoth zero-interval/four-frame trials meet the unchanged 30 FPS and upper-envelope P95 at most 60 ms criterion, at 57.11/59.06 FPS and P95 58.42/58.96 ms. The first run still has a 274.21 ms maximum; no hard delay bound is claimed. The two-frame settings are variable and do not meet the criterion in these samples. Longer observation and the explicit reverse-only cadence API candidate are being validated before deployment.\n\n69 local/remote inputs match, six Windows CTests pass, every transport output is the exact ordered accepted prefix, and the bounded-stop tails are recorded. Native identities, restored modes and private cleanup pass. Installed C914 remains unchanged. These results exclude physical scanout.\n')
for f,heading,body in [(b/'README.md','## 排空与采集间隔组合','累计 112 轮有效完整链路。四帧上限加零采集间隔的两轮达到 57.11／59.06 FPS、P95 58.42／58.96 ms，符合当前测试判据；第一轮仍有 274.21 ms 最大值。两帧模式仍波动，正在补充较长观测与正式接口版本验证。[组合试验](depth-combined/README.md)。'),(b/'transport/README.md','## Combined drain and capture cadence','Six qualified trials bring the total to 112. Both zero-interval/four-frame trials meet the operational P95 criterion, while the two-frame runs remain variable. Long-duration and lifecycle validation are still required before deployment. [All six trials](../depth-combined/README.md).')]:
 t=f.read_text();assert heading not in t;f.write_text(t+'\n'+heading+'\n\n'+body+'\n')
print('Six combined trials verified and archived')
