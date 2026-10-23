"""Estimated overlap only: source copy is reconstructed backwards from pack_begin.
The unmeasured unmap/log gap prevents treating this as a causal or exact DMA trace.
"""
import json,re,statistics,sys
from pathlib import Path
root=Path(__file__).resolve().parent; tag=sys.argv[1]
def fields(line):return {k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',line)}
cal=[json.loads((root/f'{tag}-clock-{s}.json').read_text())['best'] for s in ('start','end')]
offset=(min(c['offset_low_ns'] for c in cal)+max(c['offset_high_ns'] for c in cal))/2
ready={};pub={};uploads={};accept={}
for line in (root/f'{tag}-guest.log').read_text().splitlines():
 d=fields(line)
 if line.startswith('profile_shared_ready '):ready[int(d['pts'])]=d
 if line.startswith('profile_output '):pub[int(d['pts'])]=d
for line in (root/f'{tag}-host.log').read_text().splitlines():
 d=fields(line)
 if 'ivshmem-cuda-upload ' in line and d.get('width')==6144 and d.get('height')==3456:uploads[int(d['pts'])]=d
 if 'ivshmem-host-frame stage=accept_begin ' in line:accept[int(d['pts'])]=d['monotonic_ns']/1e6
intervals=[((p['pack_begin']*100+offset)/1e6-ready[pts]['publish_ms'],(p['pack_begin']*100+offset)/1e6) for pts,p in pub.items() if pts in ready]
def stats(v):
 v=sorted(v);return {'n':len(v),'median_ms':statistics.median(v),'p95_ms':v[min(len(v)-1,len(v)*95//100)]} if v else {'n':0}
result={}
for shift in (-1.,-.5,0.):
 groups={'overlap_gt_0p5ms':[],'overlap_le_0p5ms':[]}
 for pts,u in uploads.items():
  if pts not in accept:continue
  start=accept[pts]+u['map_ms']+u['array_ms'];end=start+u['copy_ms']
  overlap=sum(max(0,min(end,b+shift)-max(start,a+shift)) for a,b in intervals)
  groups['overlap_gt_0p5ms' if overlap>.5 else 'overlap_le_0p5ms'].append(u['copy_ms'])
 result[str(shift)]={k:stats(v) for k,v in groups.items()}
print(json.dumps({'scope':'Estimated intervals; source end precedes pack by unknown unmap/log gap; host start omits pre-map setup. Shift sensitivity is not a bound. Correlation is not causation.', 'source_end_shift_ms':result},indent=2))
