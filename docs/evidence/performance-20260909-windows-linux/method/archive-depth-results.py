"""Archive same-binary VPL admission-depth comparisons and buffered-output fix."""
from pathlib import Path
import hashlib,json,re,statistics,shutil,math
from collections import Counter
b=Path(__file__).resolve().parent.parent
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
sets={'vpl-depth':['depth1-a1','depth2-b1','depth2-b2','depth1-a2'],'vpl-depth-v2':['depthv2-1-a1','depthv2-2-b1','depthv2-2-b2','depthv2-1-a2']}
records=[];tables={}
for build,labels in sets.items():
 table=['| Trial | Depth | Distinct FPS | Median upper ms | P95 upper ms | Max upper ms |','|---|---:|---:|---:|---:|---:|']
 for name in labels:
  p=b/'transport/runs'/name;s=read(p/'state.json');r=read(p/'summary.json');assert r['run_qualified']
  assert s['native_hash_before']==s['native_hash_after'] and not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies']
  assert s['before']['installed']==s['after']['installed']=='875E56F9E746B5DAEA37814DC67C54495A9B313CD6F0EB6B2652A59F057F42FE'
  assert s['mode_restored']['mode']==s['mode_before']['mode']
  source=Path(s['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients']
  target=b/'transport/nested'/name;target.mkdir(exist_ok=True,parents=True)
  for file in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
   if (source/file).exists():shutil.copy2(source/file,target/file)
  text=(p/'source.log').read_text(errors='replace');depth=s['vpl_depth'];pool=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in text.splitlines() if line.startswith('encoder_vpl_pool ')]
  assert len(pool)==1 and pool[0]['depth']==depth and pool[0]['allocated']>=pool[0]['suggested']
  assert f'async={depth} ' in text and 'encoder_backend selected=vpl vendor=32902 forced=0' in text
  submissions=[int(x) for x in re.findall(r'^profile_submit .*?pending=(\d+)',text,re.M)];assert submissions and max(submissions)<4
  write(p/'pipeline-occupancy.json',{'before_submit':dict(sorted(Counter(submissions).items())),'configured_max':4,'vpl_depth':depth})
  subs={int(a):int(t) for a,t in re.findall(r'profile_submit pts=(\d+).*?submit_begin=(\d+)',text)}
  elapsed=sorted((int(t)-subs[int(a)])/10000 for a,t in re.findall(r'profile_color_ready pts=(\d+) at=(\d+)',text) if int(a) in subs)
  ins=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in text.splitlines() if line.startswith('encoder_input ')];outs=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in text.splitlines() if line.startswith('encoder_output ')]
  accepted=[v for v in ins if v['mfx_status'] in [0,-10]];mapping={v['token']:v['pts'] for v in accepted};assert len(mapping)==len(accepted)
  assert all(mapping[v['token']]==v['pts'] for v in outs) and [v['pts'] for v in outs]==sorted({v['pts'] for v in outs})
  accounting={'accepted':len(accepted),'output':len(outs),'buffered_input_status_counts':dict(Counter(v['mfx_status'] for v in ins)),'all_output_tokens_match_original_pts':True,'accepted_not_output_before_bounded_stop':len(accepted)-len(outs),'null_input_flushes':len(re.findall(r'^encoder_flush ',text,re.M))};write(p/'encoder-accounting.json',accounting)
  records.append({'trial':name,'build':build,'native_sha256':s['native_hash_before'],'depth':depth,'pool':pool[0],'summary':r,'accounting':accounting,'submit_to_color_ready_ms':{'n':len(elapsed),'median':statistics.median(elapsed),'p95':elapsed[math.ceil(.95*len(elapsed))-1]}})
  t=r['latency_high_ms'];table.append(f"| {name} | {depth} | {r['desktop_distinct_hz']:.3f} | {t['median']:.3f} | {t['p95']:.3f} | {t['max']:.3f} |")
 tables[build]='\n'.join(table)
 p=b/build;m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and len(m)==69 and all(sha(p/'source'/k)==v for k,v in m.items());assert '100% tests passed' in (p/'method/build.log').read_text()
write(b/'transport/depth-comparison.json',records)
(b/'vpl-depth/README.md').write_text('# Two asynchronous VPL tasks: initial performance experiment\n\n69 local/remote inputs match and six Windows CTests pass. The same executable compares AsyncDepth 1 and 2, with input surfaces allocated from QueryIOSurf recommendations and held until Data.Locked is zero. Output tasks have separate bitstreams/sync handles. Actual output timestamps map back to the accepted original PTS instead of assuming the newest input produced the current output.\n\n'+tables['vpl-depth']+'\n\nDepth 2 improves throughput in both repeats. **This first candidate is not suitable for deployment.** Real EncodeFrameAsync calls return MORE_DATA for an accepted input before later output. Code inspection showed a pending last input could then block the one-frame mode or atlas resize, or delay a static final update. The performance workload kept submitting new frames, so these full-route metrics do not qualify lifecycle behavior. The [v2 candidate](../vpl-depth-v2/README.md) explicitly requests buffered output when the source cannot feed more frames. No production file was changed for this first candidate.\n')
(b/'vpl-depth-v2/README.md').write_text('# VPL depth comparison with buffered output recovery\n\nThis isolated candidate adds nonblocking request_output to the encoder wrapper. On a full public admission limit, unchanged source frame or atlas reconfiguration, it queues null-input EncodeFrameAsync output for accepted timestamps that do not yet have sync tasks. Polling completes them in order without resetting the session. The Media Foundation path treats this request as a no-op. Input textures, bitstream buffers and original timestamps remain independently owned. The two-depth comparison uses the same binary and still validates actual GetVideoParam depth and QueryIOSurf counts.\n\n'+tables['vpl-depth-v2']+'\n\nThe [21-frame lifecycle test](../lifecycle-depth-v2/README.md) also exercises three live performance-mode changes. All accepted timestamps produce output once and in order, including every static buffered input. These are CPU-observed pre-draw to nested desktop latency envelopes, not physical scanout times; the 60 ms P95 target remains unmet. The installed executable was kept unchanged throughout these trials.\n\nAPI basis: [Intel VPL encoding functions](https://intel.github.io/libvpl/latest/API_ref/VPL_func_vid_encode.html) documents MORE_DATA input consumption, null-input draining and surface ownership.\n')
p=b/'lifecycle-depth-v2';r=read(p/'runs/depth-v2/summary.json');a=read(p/'runs/depth-v2/encoder-accounting.json');assert r['qualified'] and r['frames']==21 and a['accepted']==a['output']==21 and a['successful_flush_events']==21
(p/'README.md').write_text('# Buffered VPL output, static updates and live mode switching\n\nThe depth-2 candidate passes all seven owned-window phases: static first frame, title, move, second window, resize, hide and close. 21 recorded frames pass Linux NVDEC/CUDA/GLES upload, exact alpha and metadata checks. Every accepted PTS is output exactly once, in order; 21 accepted MORE_DATA inputs are completed through 21 successful nonblocking null-input requests. Thus static output does not depend on the fixture producing another frame.\n\nThree live switches produce frame-rate → latency → frame-rate → latency (public limits 4 → 1 → 4 → 1) without a process restart. The sampled foreground stays unchanged and tasks/processes exit normally. Windows installed hash/configuration and main-task state are unchanged. This is source-recording lifecycle qualification, not physical-input or live Wayland lifecycle acceptance. Raw signed phase diagnostics and startup/resize effects remain in summary.json.\n')
for path,title,body in [(b/'README.md','## VPL 两帧并行与缓存帧输出','新增八轮有效完整链路对照，总计 68 轮；同一程序分别验证一帧和两帧并行。第一版发现 MORE_DATA 缓存会影响静止输出、缩放和单帧模式，未部署。修正版显式请求缓存帧输出，21 帧生命周期和三次运行中模式切换均通过。完整链路结果、最大时延与实际深度读回见 [候选对照](vpl-depth-v2/README.md)。'),(b/'transport/README.md','## VPL asynchronous depth and buffered output','Two four-run comparisons bring the qualified full-route total to 68. The first candidate is rejected for deployment because its buffered-input handling is incomplete. The second adds explicit output requests and passes the 21-frame lifecycle and live-mode test. Both same-binary comparisons, actual depths, original PTS mapping, queue occupancy and all raw maxima are preserved in [the corrected candidate](../vpl-depth-v2/README.md).')]:
 t=path.read_text();assert title not in t;path.write_text(t+'\n'+title+'\n\n'+body+'\n')
print('Eight depth trials and buffered-output lifecycle archived; refresh manifests after all live work finishes')
