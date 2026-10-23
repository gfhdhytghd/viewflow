"""Archive output-flush cadence and D3D command submission comparisons."""
from pathlib import Path
import hashlib,json,re,statistics,shutil,math
from collections import Counter
b=Path(__file__).resolve().parent.parent
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def stats(v):
 a=sorted(v);return {'n':len(a),'median':statistics.median(a),'p95':a[math.ceil(.95*len(a))-1],'max':a[-1]}
sets={'vpl-depth-v3':['flush0-a1','flush5-b1','flush5-b2','flush0-a2'],'vpl-depth-v4':['copyflush-off-a1','copyflush-on-b1','copyflush-on-b2','copyflush-off-a2']}
records=[];tables={}
for build,labels in sets.items():
 table=['| Trial | Idle request delay ms | Capture Flush | Distinct FPS | Median upper ms | P95 upper ms | P99 upper ms | Maximum upper ms |','|---|---:|---:|---:|---:|---:|---:|---:|']
 for name in labels:
  p=b/'transport/runs'/name;s=read(p/'state.json');r=read(p/'summary.json');assert r['run_qualified']
  assert s['native_hash_before']==s['native_hash_after'] and not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies']
  assert s['before']['installed']==s['after']['installed']=='875E56F9E746B5DAEA37814DC67C54495A9B313CD6F0EB6B2652A59F057F42FE'
  source=Path(s['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients']
  target=b/'transport/nested'/name;target.mkdir(exist_ok=True,parents=True)
  for file in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
   if (source/file).exists():shutil.copy2(source/file,target/file)
  text=(p/'source.log').read_text(errors='replace');d={key:[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in text.splitlines() if line.startswith(key+' ')] for key in ['profile_capture','profile_wgc_delivery','encoder_flush','profile_submit']}
  stages={}
  for key,a,z in [('profile_capture','callback_enter','callback_locked'),('profile_capture','copy_begin','copied'),('profile_wgc_delivery','arrival','locked'),('profile_wgc_delivery','locked','retrieved'),('profile_wgc_delivery','retrieved','dispatch'),('profile_wgc_delivery','dispatch','end'),('encoder_flush','begin','end')]:
   stages[key+':'+a+'->'+z]=stats([(v[z]-v[a])/10000 for v in d[key]])
  gaps=[(y['arrival']-x['arrival'])/10000 for x,y in zip(d['profile_wgc_delivery'],d['profile_wgc_delivery'][1:])];stages['wgc_arrival_gap_ms']=stats(gaps)
  stages['wgc_arrival_gaps_above_100ms']=sum(x>100 for x in gaps);stages['wgc_arrival_gaps_above_450ms']=sum(x>450 for x in gaps)
  stages['output_request_statuses']=dict(Counter(v['mfx_status'] for v in d['encoder_flush']))
  if 'capture_flush' in s:
   assert all(x['flush']==s['capture_flush'] for x in d['profile_capture']);stages['capture_flush_call_ms']=stats([(x['copied']-x['copy_queued'])/10000 for x in d['profile_capture']])
  write(p/'capture-stages.json',{'scope':'CPU timestamps around callbacks/API calls; command completion and physical scanout are not measured. The final delivery-log write itself is outside its timestamp.','stages':stages})
  write(p/'pipeline-occupancy.json',{'configured_max':4,'vpl_depth':2,'before_submit':dict(Counter(x['pending'] for x in d['profile_submit']))})
  records.append({'trial':name,'build':build,'native_sha256':s['native_hash_before'],'idle_flush_ms':s['idle_flush_ms'],'capture_flush':s.get('capture_flush',0),'summary':r,'stages':stages})
  t=r['latency_high_ms'];table.append(f"| {name} | {s['idle_flush_ms']} | {s.get('capture_flush',0)} | {r['desktop_distinct_hz']:.3f} | {t['median']:.3f} | {t['p95']:.3f} | {t['p99']:.3f} | {t['max']:.3f} |")
 tables[build]='\n'.join(table)
 p=b/build;m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and len(m)==69 and all(sha(p/'source'/k)==v for k,v in m.items());assert '100% tests passed' in (p/'method/build.log').read_text()
write(b/'transport/flush-comparison.json',records)
(b/'vpl-depth-v3/README.md').write_text('# Idle buffered-output request cadence and capture instrumentation\n\nAdds CPU timestamps for WGC event arrival, delivery lock, frame retrieval, callback dispatch, source mutex acquisition, copy submission and null-input encoder calls. Compare immediate output requests with a 5 ms wait after the source first appears unchanged; full admission limits and resize still request output immediately.\n\n'+tables['vpl-depth-v3']+'\n\nThe 5 ms delay does not remove the long tails and is rejected. All raw maxima are preserved. During the long gaps, the Windows fixture continues drawing. The instrumented locks, copy submission and null-input API calls do not themselves account for the half-second gaps; WGC event arrival and encode completion both pause. These observations narrow the investigation but do not prove a driver-level cause. Extra diagnostic logging may also perturb timing. [D3D command submission experiment](../vpl-depth-v4/README.md). No version in this comparison was deployed.\n')
(b/'vpl-depth-v4/README.md').write_text('# Explicit submission of owned capture copies\n\nSame-binary A/B/B/A comparison, holding AsyncDepth 2 and immediate buffered-output requests fixed. The enabled arm calls ID3D11DeviceContext::Flush after copying the borrowed WGC surface into the application-owned texture, before returning the callback. It requests GPU command submission without waiting for completion. Input ownership, alpha and original timestamps are unchanged. Both arms retain identical stage instrumentation.\n\n'+tables['vpl-depth-v4']+'\n\nPer-trial capture-stages.json includes WGC arrival gaps, callback/API CPU durations and the actual enable flag. This is an experiment on command submission, not proof of zero-copy or an independent GPU timing measurement. The production executable remains unchanged during these trials.\n\n[Microsoft Flush documentation](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-flush) describes asynchronous command submission and its overhead.\n')
for p,title,body in [(b/'README.md','## 异常长尾与 GPU 命令提交对照','新增八轮有效完整链路记录，总计 76 轮。两帧并行出现半秒以上长尾，5 ms 空闲合并并未消除。进一步增加 WGC 回调和 API 调用计时，并对照是否在自有纹理复制后立即提交 GPU 命令。所有最大值和异常间断均保留；尚未据此覆盖已部署版本。[诊断与对照](vpl-depth-v4/README.md)。'),(b/'transport/README.md','## Idle output requests and capture command submission','Eight more same-binary trials bring the qualified count to 76. The idle delay experiment fails to remove long tails; the following A/B/B/A toggles D3D command submission after the owned capture copy. All maxima, WGC event gaps and CPU subintervals remain in [the experiment](../vpl-depth-v4/README.md).')]:
 t=p.read_text();assert title not in t;p.write_text(t+'\n'+title+'\n\n'+body+'\n')
print('Eight flush trials archived; manifest refresh remains after live work')
