"""Archive qualified drain-barrier implementation, quality equivalence and canonical runs."""
from pathlib import Path
import json,hashlib,re,subprocess,shutil
b=Path(__file__).resolve().parent.parent
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sets={'vpl-depth-v5':['depthv5-1-a1','depthv5-2-b1','depthv5-2-b2','depthv5-1-a2'],'root-depth':['root-depth-frame-a1','root-depth-latency-b1','root-depth-latency-b2','root-depth-frame-a2']}
records=[]
for build,labels in sets.items():
 p=b/build;m=read(p/'method/source-sha256.json');assert m==read(p/'method/remote-source-sha256.json') and len(m)==69 and all(sha(p/'source'/k)==v for k,v in m.items());assert '100% tests passed, 0 tests failed out of 6' in (p/'method/build.log').read_text()
 native=next(x for x in read(p/'method/build-binaries.json') if x['path'].endswith('viewflow_windows_reverse.exe'))
 table=['| Trial | FPS | Median upper ms | P95 upper ms | Max upper ms |','|---|---:|---:|---:|---:|']
 for name in labels:
  d=b/'transport/runs'/name;s=read(d/'state.json');r=read(d/'summary.json');assert r['run_qualified']
  assert s['native_hash_before']==s['native_hash_after']==native['hash'] and not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies']
  assert s['before']['installed']==s['after']['installed']=='875E56F9E746B5DAEA37814DC67C54495A9B313CD6F0EB6B2652A59F057F42FE'
  assert s['mode_restored']['mode']==s['mode_before']['mode']
  source=Path(s['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and n['transport_trial']=='passed' and not n['remaining_clients']
  target=b/'transport/nested'/name;target.mkdir(exist_ok=True,parents=True)
  for file in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:
   if (source/file).exists():shutil.copy2(source/file,target/file)
  subprocess.run(['python3',str(b/'method/check-encoder-accounting.py'),str(d),'--bounded-stop'],check=True)
  log=(d/'source.log').read_text(errors='replace');depth=s.get('vpl_depth',2)
  assert f'async={depth} ' in log and f'encoder_vpl_pool depth={depth} minimum={1 if depth==1 else 3} suggested={1 if depth==1 else 3} allocated={depth+1}' in log and 'encoder_backend selected=vpl vendor=32902 forced=0' in log
  t=r['latency_high_ms'];table.append(f"| {name} | {r['desktop_distinct_hz']:.3f} | {t['median']:.3f} | {t['p95']:.3f} | {t['max']:.3f} |")
  records.append({'build':build,'trial':name,'native_sha256':native['hash'],'depth':depth,'summary':r,'encoder_accounting':read(d/'encoder-accounting.json')})
 body='Before null-input drain, existing encode tasks must complete; fresh input is blocked until the drain has returned MORE_DATA and all accepted PTS have output. A 20 ms idle coalescing interval avoids asking to drain during ordinary capture catch-up. Public admission limits and resize request output immediately. These changes were tested together; their separate causal contributions are not established. No new session age cutoff is introduced. Input textures remain owned until the driver releases them.\n\n'
 if build=='root-depth':body+='The canonical implementation defaults to two VPL tasks and allocates max(depth+1, QueryIOSurf minimum, QueryIOSurf suggested) surfaces. Actual readback is AsyncDepth=2 with three surfaces in both public modes; their outer admission limits are 4 and 1. All 69 local/remote build inputs match and six Windows CTests pass.\n\n'
 else:body+='Same-binary A/B/B/A compares explicit VPL depths one and two with a public frame-rate admission limit of four. The canonical integration changes the default to two. All 69 local/remote build inputs match and six Windows CTests pass.\n\n'
 (p/'README.md').write_text('# '+('Canonical two-task VPL encoder' if build=='root-depth' else 'Ordered VPL drain and capture-idle coalescing')+'\n\n'+body+'\n'.join(table)+'\n\nMeasurements cover full 6144×3456 through paired QUIC, Linux GPU decode/upload/draw and nested desktop observation. Values are upper clock-envelope estimates of fixture pre-draw to observation; physical scanout is unmeasured. All raw maxima are preserved. The 60 ms P95 target is not met by this series.\n')
for name,label in [('lifecycle-depth-v5','depth-v5'),('lifecycle-root-depth','root-depth')]:
 p=b/name;d=p/'runs'/label;r=read(d/'summary.json');assert r['qualified'] and r['decoded']==r['frames']
 subprocess.run(['python3',str(b/'method/check-encoder-accounting.py'),str(d)],check=True)
 (p/'README.md').write_text(f"# Drain barrier and window lifecycle\n\nAll seven owned-window phases pass: static first frame, title, move, second window, resize, hide and close. All {r['frames']} frames pass Linux NVDEC/CUDA/GLES upload, exact alpha and metadata checks. Every accepted PTS outputs once in order, every null-input request starts after existing encode tasks finish, and all drain cycles complete without interleaved fresh inputs. Three live mode changes retain the same process. Foreground samples remain unchanged; normal exit and private cleanup pass. This recording test excludes physical input and live Wayland lifecycle acceptance. See raw signed phase timing in runs/{label}/summary.json.\n")
# Qualify quality reuse by identical processing functions, with only canonical default/pool policy changes.
a=b/'vpl-depth-v5/source/platform/windows-reverse';z=b/'root-depth/source/platform/windows-reverse'
assert (a/'vpl_encoder.cpp').read_text().split('HRESULT VplEncoder::can_submit()')[1]==(z/'vpl_encoder.cpp').read_text().split('HRESULT VplEncoder::can_submit()')[1]
assert (a/'main.cpp').read_text().replace('#include <optional>\n','')==(z/'main.cpp').read_text().replace('#include <optional>\n','')
for f in ['hardware_encoder.cpp','hardware_encoder.hpp']:assert sha(a/f)==sha(z/f)
q=read(b/'depth-quality/method/results.json');assert q['results']['1']['frames']==q['results']['2']['frames']==90
(b/'depth-quality/README.md').write_text('# One-task and two-task quality comparison\n\nThe same v5 source binary produced 1235 and 1542 recorded frames at explicit depths one and two. All recorded frames passed marker and exact-alpha GPU decode checks. Ninety common markers were compared at every RGB pixel of the complete 6144×3456 image. PSNR is 41.915864 versus 41.916378 dB, MSE 6.433001e-5 versus 6.432240e-5; maximum pixel error is the same. This synthetic grid comparison does not certify natural images or fine text.\n\nThe canonical encoder has identical can_submit, submit, drain and poll processing; main differs only by an explicit optional header. Canonical startup changes the default to two and removes an arbitrary allocation cap, while actual QueryIOSurf readback remains three surfaces, identical to the tested two-task variant. The hardware wrapper is byte-identical. Thus quality results apply to the same processing path, with both public modes retaining bitrate, dimensions, format and alpha.\n')
(b/'transport/depth-v5-comparison.json').write_text(json.dumps(records,indent=2)+'\n')
print('V5 and canonical depth archives validated')
