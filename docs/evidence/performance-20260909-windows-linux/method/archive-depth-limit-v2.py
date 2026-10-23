"""Verify deferred drain start, admission limits, and lifecycle accounting."""
from pathlib import Path
import json,hashlib,re,subprocess,shutil
b=Path(__file__).resolve().parent.parent;p=b/'depth-limit-v2'
read=lambda p:json.loads(p.read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and len(m)==69 and all(sha(p/'source'/k)==v for k,v in m.items());assert '100% tests passed, 0 tests failed out of 6' in (p/'method/build.log').read_text()
records=[];table=['| Trial | Outer limit | FPS | Median upper ms | P95 upper ms | Max upper ms |','|---|---:|---:|---:|---:|---:|']
for name in ['depthlimitv2-four-a1','depthlimitv2-two-b1','depthlimitv2-two-b2','depthlimitv2-four-a2']:
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
(b/'transport/depth-limit-v2-comparison.json').write_text(json.dumps(records,indent=2)+'\n')
(p/'README.md').write_text('# Defer drain start until active encoder tasks complete\n\nThis isolated candidate retains VPL async depth two and three surfaces, sets the latency admission limit to two, and defers request_output until pending GPU tasks have completed. Once draining begins, new input remains paused until the null-input completion barrier. This removes premature drains triggered while an ordinary output could shortly free an admission slot. The 20 ms idle coalescing behavior is retained.\n\n69 local and remote source hashes match and six Windows CTests pass. All four transport runs use the same native binary with actual four/two/two/four mode readback.\n\n'+'\n'.join(table)+'\n\nThe two-frame runs have P95 70.47 and 72.78 ms, improving the earlier standalone two-frame candidate (81.85 and 85.09 ms). FPS remains variable at 48.62 and 53.46, and neither run meets the P95 60 ms criterion. Four-frame controls reach 54.23–54.98 FPS. This candidate is not installed.\n\nThe separate lifecycle fixture passes all seven phases, 21 GPU-decoded frames with exact alpha, three runtime mode changes, and complete ordered drain accounting. Full transport tests have explicit bounded stop tails. No physical input was injected and physical scanout remains unmeasured. [Lifecycle evidence](../lifecycle-depth-limit-v2/README.md).\n')
life=b/'lifecycle-depth-limit-v2';run=life/'runs/depth-limit-v2'
lm=read(life/'method/windows-source-sha256.json');assert lm==read(life/'method/windows-remote-source-sha256.json')
for k,v in lm.items():assert sha(life/k)==v
lr=read(run/'summary.json');assert lr['qualified'] and lr['frames']==lr['decoded']==21
subprocess.run(['python3',str(b/'method/check-encoder-accounting.py'),str(run)],check=True)
(life/'README.md').write_text('# Deferred drain lifecycle validation\n\nThe same 01A82E3C candidate used for the four transport runs produces 21 of 21 accepted frames, decoded through NVDEC/CUDA/GLES with exact alpha verification. Static updates, rename, movement, second window, resize, removal and empty atlas all appear. Actual admission modes are 4, 2, 4, 2. All 20 drain cycles end, each null input follows completed GPU tasks, and no fresh input is interleaved during drain. Foreground samples remain unchanged; private tasks and processes are removed. See runs/depth-limit-v2/summary.json and encoder-accounting.json for bounded assertions and timing limitations.\n')
for f,heading,body in [(b/'README.md','## 推迟不必要的编码器排空','四轮新对照把累计有效完整链路增加到 101 轮。二帧模式 P95 降到 70.47–72.78 ms，仍未达到 60 ms；21 帧生命周期和模式切换通过，尚未部署。[源代码与验证](depth-limit-v2/README.md)。'),(b/'transport/README.md','## Deferred drain admission experiment','Four qualified trials bring the total to 101. Deferring drain start reduces premature drains and improves the two-frame P95 relative to the previous limit-two candidate; FPS remains variable. [Candidate and lifecycle evidence](../depth-limit-v2/README.md).')]:
    t=f.read_text();assert heading not in t;f.write_text(t+'\n'+heading+'\n\n'+body+'\n')
print('Deferred drain candidate and lifecycle archived')
