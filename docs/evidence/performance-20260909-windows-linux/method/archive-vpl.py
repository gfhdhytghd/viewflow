"""Verify and summarize isolated VPL experiments; never deploy anything."""
from pathlib import Path
import hashlib,json,re,statistics
b=Path(__file__).resolve().parent.parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def stats(xs):
 xs=sorted(xs)
 return {'n':len(xs),'median':statistics.median(xs),'p95':xs[int(.95*(len(xs)-1))],'min':xs[0],'max':xs[-1]}
descriptions={
 'vpl-probe':'Preserved initial failure: VPL 2.16 accepts 6144x3456 HEVC low-power, but its internal NV12 texture (bind 520) cannot be a VideoProcessor output view. No frames encoded.',
 'vpl-probe-v2':'VideoProcessor writes a render-target NV12 texture, followed by an explicit GPU copy into a VPL-managed input. Both requested low-power settings encode 120 frames. The OFF query returns warning 5 and changes LowPower back to ON; these are not two distinct hardware modes.',
 'vpl-probe-v3':'Same explicit-copy path with HEVC tile columns 1, 2 and 4 and GPU timestamp queries. Each requested tile count is reported back by the runtime. These are individual exploratory samples, not a repeated proof that two tiles are best.',
 'vpl-probe-v4':'Preserved shared-import failure: the render-target NV12 input is rejected with MFX_ERR_MEMORY_ALLOC (-4), before any frame is encoded.',
 'vpl-probe-v5':'Preserved texture-allocation failure: combining render-target, decoder, video-encoder and shader-resource binding with shared allocation returns E_INVALIDARG before import.',
 'vpl-probe-v6':'Preserved shared-import failures: render-target-only and render-target plus shader-resource NV12 textures, both with SHARED misc flag, still return MFX_ERR_MEMORY_ALLOC (-4).',
 'vpl-probe-v7':'External allocator supplies an application-owned render-target NV12 input. VideoProcessor writes that texture and the encoder consumes it, with no application CopyResource into another input. One- and two-column HEVC cases each encode 120 frames. Each complete output file is byte-identical to the corresponding explicit-copy case. This does not prove the driver performs no internal copy.',
 'vpl-probe-v8':'Preserved capability rejection: HEVC with direct RGB4 input is rejected by Query with MFX_ERR_UNSUPPORTED (-3). No frames encoded.'
}
all_runs=[]
for name,description in descriptions.items():
 p=b/name;local=read(p/'method/source-sha256.json');remote=read(p/'method/remote-source-sha256.json')
 assert local==remote and all(sha(p/'source'/k)==h for k,h in local.items())
 runs=[]
 for run in sorted((p/'runs').iterdir()):
  status=read(run/'status.json');state=read(run/'state.json');text=(run/'probe.log').read_text()
  assert state['main']=='Ready' and state['processes']==[]
  assert state['installed']=='E1543F0754BAE0741955EF5FBD178262ED10AFE05E3845060E28AAC4121B93D0'
  record={'run':str(run.relative_to(b)),'exit':status['exit'],'settings':status,'native_sha256':state['native'],'runtime_sha256':state['runtime'],'encoded_sha256':sha(run/'probe.hevc')}
  if status['exit']==0:
   frames=[{k:float(v) for k,v in re.findall(r'(frame|prepare|submit|sync|total|bytes|pts|type)=([0-9.]+)',line)} for line in text.splitlines() if line.startswith('frame=')]
   assert len(frames)==120 and [x['frame'] for x in frames]==list(range(120))
   assert [x['pts'] for x in frames]==[x*1500 for x in range(120)]
   assert 'units=120 decoded=120 gl_error=0' in (run/'decode.log').read_text()
   steady=frames[20:];record['warmup_frames']=20;record['timings_ms']={key:stats([x[key] for x in steady]) for key in ['prepare','submit','sync','total']}
   gpu=[{k:float(v) for k,v in re.findall(r'(frame|convert|copy)=([0-9.]+)',line)} for line in text.splitlines() if line.startswith('gpu frame=')]
   if gpu:record['gpu_command_intervals_ms']={key:stats([x[key] for x in gpu if x['frame']>=20]) for key in ['convert','copy']}
  else:assert (run/'probe.hevc').stat().st_size==0
  write(run/'summary.json',record);runs.append(record);all_runs.append(record)
 table=['| Trial | Exit | Median path ms | P95 path ms |','|---|---:|---:|---:|']
 for r in runs:
  t=r.get('timings_ms',{}).get('total');table.append(f"| {Path(r['run']).name} | {r['exit']} | {t['median']:.3f} | {t['p95']:.3f} |" if t else f"| {Path(r['run']).name} | {r['exit']} | — | — |")
 (p/'README.md').write_text('# Intel VPL isolated encoder experiment\n\n2026-09-09. '+description+'\n\n'+'\n'.join(table)+'\n\nThe successful probes use 120 changing solid-color GPU frames at full 6144×3456, HEVC Main, 24 Mbps CBR, nominal 60 Hz, target usage 7, asynchronous depth 1 and no B-frame reordering. Timings discard the first 20 frames and include frame preparation, encoder submission and completion; synchronous file writes and stderr logging occur outside each reported per-frame total. They are neither WGC/QUIC/Wayland measurements nor physical scanout latency. GPU timestamp intervals can include driver scheduling and cross-engine dependencies; do not add or subtract them as independent engine costs. A near-zero copy interval in the external-input probe means no application copy was issued, not zero driver work.\n\nAll successful output streams pass Linux NVDEC/CUDA/GLES decoding and expected dimensions for all 120 access units. The probe is bounded and creates no windows or input events. Its process is gone after each run, Windows main remains Ready, and installed reverse SHA256 remains E1543F07… . API headers and MIT license are archived with their upstream revision; local/remote source hashes match. The native probe DLL dispatch loads the existing System32 libvpl.dll.\n\nReferences: [Intel encoding procedures](https://intel.github.io/libvpl/latest/programming_guide/VPL_prg_encoding.html), [HEVC tile structures](https://intel.github.io/libvpl/latest/API_ref/VPL_structs_encode.html), [official D3D11 allocator sample](https://github.com/intel/libvpl-tools/blob/main/tools/legacy/sample_common/src/d3d11_allocator.cpp).\n')
for lhs,rhs in [('vpl-probe-v3/runs/tiles1-a1','vpl-probe-v7/runs/external1-a1'),('vpl-probe-v3/runs/tiles2-b1','vpl-probe-v7/runs/external2-b1')]:
 assert (b/lhs/'probe.hevc').read_bytes()==(b/rhs/'probe.hevc').read_bytes()
write(b/'method/vpl-probes.json',all_runs)
for name in descriptions:
 p=b/name;files=sorted(x for x in p.rglob('*') if x.is_file() and '__pycache__' not in x.parts and x!=p/'sha256.json');write(p/'sha256.json',{str(x.relative_to(p)):sha(x) for x in files})
print('VPL probes verified',len(all_runs))
