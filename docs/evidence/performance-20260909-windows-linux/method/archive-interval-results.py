"""Archive isolated WGC MinUpdateInterval trials without rewriting prior evidence."""
from pathlib import Path
import hashlib,json,re,statistics,shutil
b=Path(__file__).resolve().parent.parent
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
labels=['interval0-a1','interval32-b1','interval32-b2','interval0-a2','interval16-c1','interval0-d1','interval0-d2','interval16-c2']
rows=[]
for name in labels:
 p=b/'transport/runs'/name;s=read(p/'state.json');r=read(p/'summary.json');assert r['run_qualified']
 assert s['native_hash_before']==s['native_hash_after'] and not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies']
 assert s['before']['installed']==s['after']['installed']=='875E56F9E746B5DAEA37814DC67C54495A9B313CD6F0EB6B2652A59F057F42FE'
 assert s['mode_restored']['mode']==s['mode_before']['mode']
 source=Path(s['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients']
 target=b/'transport/nested'/name;target.mkdir(parents=True,exist_ok=True)
 for file in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
  if (source/file).exists():shutil.copy2(source/file,target/file)
 text=(p/'source.log').read_text(errors='replace');events=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in text.splitlines() if line.startswith('wgc_interval ')]
 assert events and all(e['supported']==1 and e['before_100ns']==160000 and e['actual_100ns']==e['requested_us']*10 for e in events)
 subs={int(a):int(t) for a,t in re.findall(r'profile_submit pts=(\d+).*?submit_begin=(\d+)',text)}
 elapsed=sorted((int(t)-subs[int(a)])/10000 for a,t in re.findall(r'profile_color_ready pts=(\d+) at=(\d+)',text) if int(a) in subs)
 rows.append({'trial':name,'native_sha256':s['native_hash_before'],'session_intervals':events,'summary':r,'submit_to_color_ready_ms':{'n':len(elapsed),'median':statistics.median(elapsed),'p95':elapsed[int(.95*(len(elapsed)-1))]}})
write(b/'transport/interval-comparison.json',rows)
for name in ['wgc-interval','wgc-interval-v2']:
 p=b/name;m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and all(sha(p/'source'/k)==v for k,v in m.items())
 if name.endswith('v2'):assert '100% tests passed, 0 tests failed out of 6' in (p/'method/build.log').read_text()
 table=['| Trial | Requested us | Distinct FPS | Median upper ms | P95 upper ms | Max upper ms |','|---|---:|---:|---:|---:|---:|']
 for row in rows:
  s=row['summary'];t=s['latency_high_ms'];table.append(f"| {row['trial']} | {row['session_intervals'][0]['requested_us']} | {s['desktop_distinct_hz']:.3f} | {t['median']:.3f} | {t['p95']:.3f} | {t['max']:.3f} |")
 if name.endswith('v2'):
  (p/'README.md').write_text('# WGC minimum update interval experiment\n\nIsolated snapshot of the installed VPL source, changing only the optional capture-session interval API. All 69 local/remote inputs match; six Windows CTests pass. Before StartCapture, QueryInterface for IGraphicsCaptureSession5 succeeds on this Windows/SDK. The actual default getter is **160000 100ns units = 16 ms**, so explicit zero is not the installed default. Every run logs requested, before and actual getter values. Unsupported/error branches retain the normal capture path; no production code was changed or installed.\n\n'+ '\n'.join(table)+'\n\nThe first A/B/B/A series compares explicit 0/32 ms. 32 ms yields only 29.61–29.79 FPS; its second P95 rises to 104.10 ms, so the first good latency observation is not repeatable. The second A/B/B/A compares the installed 16 ms default with zero. Median/P95 distributions cross and do not establish a stable benefit. Both changes are rejected for deployment. Latency is fixture pre-draw to nested desktop observation with a clock envelope, not physical scanout. These eight runs bring the completed full-route total from 51 to 59. Every trial exits normally and removes its private proxy, task and nested compositor.\n\nSource documentation: [Microsoft MinUpdateInterval](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval?view=winrt-28000). Longer update intervals can reduce capture rate; the API is optional and not an authorization or session-liveness limit.\n')
 else:
  (p/'README.md').write_text('# Initial WGC interval build failure\n\nThe isolated initial snapshot used std::getenv in the shared capture module. MSVC /WX rejected the deprecated CRT function with C4996. No executable was run or installed. Source maps and the failed build log are retained. The separately named [v2 snapshot](../wgc-interval-v2/README.md) uses GetEnvironmentVariableA and strict integer parsing.\n')
for p,title,body in [(b/'README.md','## WGC 采集间隔对照','新增八轮有效完整链路记录，总计 59 轮。实际默认采集间隔读回为 16 ms；取消默认间隔没有稳定收益，32 ms 间隔的帧率只有 29.61–29.79，第二轮 P95 达到 104.10ms。因此两项实验均未部署，已安装 VPL 最优版本保持。继续检查 Linux 接收与呈现耗时。[原始对照与失败构建](wgc-interval-v2/README.md)。'),(b/'transport/README.md','## WGC capture interval comparisons','Eight further qualified full-route trials compare explicit zero/32 ms, then installed-default 16 ms/zero. Getter values, raw latency maxima and cleanup are retained in [the interval experiment](../wgc-interval-v2/README.md). Neither setting establishes a repeatable benefit; the production default remains. Total: 59 qualified runs.')]:
 t=p.read_text();assert title not in t;p.write_text(t+'\n'+title+'\n\n'+body+'\n')
for name in ['transport','wgc-interval','wgc-interval-v2']:
 p=b/name;write(p/'sha256.json',{str(f.relative_to(p)):sha(f) for f in sorted(p.rglob('*')) if f.is_file() and '__pycache__' not in f.parts and f!=p/'sha256.json'})
files=[b/'README.md',*sorted((b/'method').glob('*.py')),*sorted((b/'method').glob('vpl-*.json')),*sorted(b.glob('*/sha256.json'))]
write(b/'method/index-sha256.json',{str(f.relative_to(b)):sha(f) for f in files})
for manifest in b.glob('*/sha256.json'):
 for path,h in read(manifest).items():assert sha(manifest.parent/path)==h,(manifest,path)
print('WGC eight trials archived; all manifest hashes verified')
