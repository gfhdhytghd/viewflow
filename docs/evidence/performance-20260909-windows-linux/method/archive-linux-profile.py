"""Archive separate-stream Linux timing and retain the rejected mixed-log run."""
from pathlib import Path
import hashlib,json,shutil
b=Path(__file__).resolve().parent.parent
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
for name in ['linux-profile-a1','linux-profile-v2-a1']:
 p=b/'transport/runs'/name;s=read(p/'state.json');assert s['native_hash_before']==s['native_hash_after'] and not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies']
 assert s['before']['installed']==s['after']['installed']=='875E56F9E746B5DAEA37814DC67C54495A9B313CD6F0EB6B2652A59F057F42FE'
 source=Path(s['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients']
 target=b/'transport/nested'/name;target.mkdir(exist_ok=True,parents=True)
 for file in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
  if (source/file).exists():shutil.copy2(source/file,target/file)
 for path,h in s['linux_binaries'].items():assert sha(Path(path))==h
 if name=='linux-profile-a1':assert not read(p/'analysis-rejection.json')['run_qualified'] and not (p/'summary.json').exists()
 else:assert read(p/'summary.json')['run_qualified']
for name in ['linux-profile','linux-profile-v2']:
 p=b/name;m=read(p/'method/source-sha256.json');assert all(sha(p/'source'/f)==h for f,h in m.items())
 assert '100% tests passed' in (p/'method/ctest.log').read_text() and 'out of 2' in (p/'method/ctest.log').read_text()
(b/'linux-profile/README.md').write_text('# Initial Linux profiling trial\n\nThe isolated presenter adds CPU timestamps for receive, decode, CUDA upload, alpha, draw/swap and geometry IPC. It builds and passes two CTests, and the trial exits normally with full nested cleanup. Native stderr shared the parent log: 1 reverse_clock record became interleaved, so the unchanged full-route analyzer failed. The raw log and explicit analysis-rejection.json are preserved. No end-to-end result is certified and this trial is excluded from the qualified count. See [the separate-log repeat](../linux-profile-v2/README.md). No production files were changed.\n')
s=read(b/'transport/runs/linux-profile-v2-a1/summary.json');st=read(b/'transport/runs/linux-profile-v2-a1/linux-stages.json')['stages']
table=['| CPU wall-time interval | Median ms | P95 ms | Maximum ms |','|---|---:|---:|---:|']
for k,r in st.items():table.append(f"| {k} | {r['median_ms']:.4f} | {r['p95_ms']:.4f} | {r['max_ms']:.4f} |")
(b/'linux-profile-v2/README.md').write_text('# Linux receive, decode and presentation timing\n\nA separate native stderr file prevents diagnostics from interleaving with the parent clock protocol. The 14 build inputs and actual Linux executable hashes are retained. Build and two CTests pass. The repeat qualifies under the unchanged full-route analyzer, exits normally and removes its private nested compositor. Windows uses the current canonical VPL executable, with its pre/post identity checked.\n\nAfter a 3-second warmup, 1158 presented samples give:\n\n'+'\n'.join(table)+f"\n\nFull-route result: {s['desktop_distinct_hz']:.3f} distinct FPS, upper-envelope latency median {s['latency_high_ms']['median']:.3f} ms, P95 {s['latency_high_ms']['p95']:.3f} ms, max {s['latency_high_ms']['max']:.3f} ms. This is a diagnostic run, not a new optimization or physical scanout measurement. CPU intervals include API synchronization; CUDA subintervals are not independent GPU work durations. Logging overhead is not subtracted.\n\nTexture upload and ordinary geometry polling do not account for the missing tens of milliseconds; their measured medians are below 0.3 ms. Receive-to-accept is also short, while decoder submission averages around 4.6 ms at the median. The 8.16 ms worst geometry sample is retained. No queue, memory or geometry behavior was changed in production. The full-route total is now 60 qualified trials, plus the explicitly rejected mixed-log profiling trial.\n")
for p,title,body in [(b/'README.md','## Linux 接收与呈现分段计时','独立测量中，接收后等待中位 0.024ms、解码 4.60ms、纹理上传 0.071ms、绘制提交 0.382ms，普通几何查询中位 0.218ms。未发现这些环节存在持续积压；这组 CPU 计时不代表物理呈现完成。新增一轮有效完整链路结果为 41.10FPS、中位 69.71ms、P95 86.65ms；另有一轮日志交错已明确拒绝端到端分析。[分段数据与原始记录](linux-profile-v2/README.md)。'),(b/'transport/README.md','## Linux stage profiling','The separate-native-log repeat adds one qualified full-route trial (total 60). One preceding mixed-log trial is explicitly unqualified because a clock record interleaved with diagnostics. [Linux CPU stage timings and limits](../linux-profile-v2/README.md). No production behavior was changed.')]:
 t=p.read_text();assert title not in t;p.write_text(t+'\n'+title+'\n\n'+body+'\n')
print('Linux profiling narratives and nested records archived; refresh manifests after live trials finish')
