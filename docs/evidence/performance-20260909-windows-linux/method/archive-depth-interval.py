"""Archive the interaction of two-task encoding and optional WGC update interval."""
from pathlib import Path
import json,hashlib,re,subprocess,shutil
b=Path(__file__).resolve().parent.parent;p=b/'depth-interval'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();read=lambda p:json.loads(p.read_text())
m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and len(m)==69 and all(sha(p/'source'/k)==h for k,h in m.items());assert '100% tests passed, 0 tests failed out of 6' in (p/'method/build.log').read_text()
records=[];table=['| Trial | Interval us | FPS | Median upper ms | P95 upper ms | Max upper ms |','|---|---:|---:|---:|---:|---:|']
for name in ['depthinterval-default-a1','depthinterval-zero-b1','depthinterval-zero-b2','depthinterval-default-a2']:
 d=b/'transport/runs'/name;s=read(d/'state.json');r=read(d/'summary.json');assert r['run_qualified'] and s['native_hash_before']==s['native_hash_after']
 assert not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies'] and s['before']['installed']==s['after']['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB'
 assert s['mode_restored']['mode']==s['mode_before']['mode']
 source=Path(s['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients'];target=b/'transport/nested'/name;target.mkdir(exist_ok=True,parents=True)
 for f in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
  if (source/f).exists():shutil.copy2(source/f,target/f)
 text=(d/'source.log').read_text(errors='replace');v=s['wgc_interval_us'];assert f'wgc_interval supported=1 requested_us={v} before_100ns=160000 actual_100ns={v*10}' in text and 'async=2 ' in text and 'encoder_vpl_pool depth=2 minimum=3 suggested=3 allocated=3' in text
 subprocess.run(['python3',str(b/'method/check-encoder-accounting.py'),str(d),'--bounded-stop'],check=True)
 records.append({'trial':name,'interval_us':v,'native_sha256':s['native_hash_before'],'summary':r});t=r['latency_high_ms'];table.append(f"| {name} | {v} | {r['desktop_distinct_hz']:.3f} | {t['median']:.3f} | {t['p95']:.3f} | {t['max']:.3f} |")
assert len({r['native_sha256'] for r in records})==1
(b/'transport/depth-interval-comparison.json').write_text(json.dumps(records,indent=2)+'\n')
(p/'README.md').write_text('# Two VPL tasks and capture interval interaction\n\nSame-binary A/B/B/A rechecks the optional WGC update interval after the canonical encoder moved from one task to two. Local/remote 69-file source maps match and six Windows CTests pass. The only source change from C914CC47 is the optional interval API and its diagnostic log. Runtime readback confirms initial 16 ms and actual requested 16 ms/zero in every arm. The VPL depth remains two with three input surfaces and public frame-rate limit four.\n\n'+'\n'.join(table)+'\n\nZero interval improves distinct throughput to 58.47–59.76 FPS versus 53.46–54.46, but raises observed P95 to 68.14–74.09 ms versus 63.95–66.77. It therefore offers a measured throughput/latency tradeoff, without meeting the 60 ms P95 target. It has not been deployed; the public-mode combination requires qualification before adoption. The earlier one-task interval result cannot substitute for this interaction test.\n\nAll measurements cover the complete 6144×3456 route through QUIC, GPU decode/upload/draw and nested desktop observation, excluding physical scanout. Ordered output and drain barriers pass diagnostic accounting; private tasks, windows and compositors are removed. Installed source/configuration remains unchanged. [Microsoft API reference](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval?view=winrt-28000).\n')
for f,heading,body in [(b/'README.md','## 双任务编码与采集间隔组合','双任务后重新交叉验证：默认 16ms 采集间隔为 53.46–54.46FPS、P95 63.95–66.77ms；零间隔为 58.47–59.76FPS、P95 68.14–74.09ms。帧率提高但延迟升高，尚未部署；继续验证公开模式组合。累计 93 轮有效完整链路。[记录](depth-interval/README.md)。'),(b/'transport/README.md','## Two-task capture interval interaction','Four new qualified trials bring the total to 93. Zero interval improves throughput but increases P95 in both repeats. Actual API readback, two-task pool counts and drain accounting are retained. [Interaction results](../depth-interval/README.md).')]:
 t=f.read_text();assert heading not in t;f.write_text(t+'\n'+heading+'\n\n'+body+'\n')
print('Four interval/depth interaction runs archived')
