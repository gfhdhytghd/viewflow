"""Decompose existing producer QPC records without mixing clock domains."""
import re,json,sys
from pathlib import Path
capture={};output={};ready={}
for line in Path(sys.argv[1]).read_text().splitlines():
 if line.startswith('profile_shared_ready '):
  timing={k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',line)};ready[int(timing['pts'])]=timing
 d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
 if line.startswith('profile_shared_capture ') and d.get('width')==6144 and d.get('height')==3456:capture[d['pts']]=d
 if line.startswith('profile_output '):output[d['pts']]=d
rows=[]
for pts,c in capture.items():
 if pts not in output:continue
 o=output[pts];rows.append({'capture_to_enqueue_ms':(c['enqueued']-c['capture'])/10000,'enqueue_to_pack_ms':(o['pack_begin']-c['enqueued'])/10000,'pack_ms':(o['pack_end']-o['pack_begin'])/10000,'pipe_write_ms':(o['write_end']-o['pack_end'])/10000,'atlas_to_write_ms':(o['write_end']-pts)/10000})
def stats(v):
 v=sorted(v);return {'n':0} if not v else {'n':len(v),'p50':v[len(v)//2],'p95':v[min(len(v)-1,len(v)*95//100)],'max':v[-1]}
readback={k:stats([v[k] for pts,v in ready.items() if pts in capture and v[k]>=0]) for k in ['ready_ms','map_ms','publish_ms']} if ready else {}
gpu=[v['gpu_copy_ms'] for pts,v in ready.items() if pts in capture and v.get('gpu_copy_ms',-1)>=0]
print(json.dumps({'gpu_copy_sampled':stats(gpu) if gpu else {'n':0},'readback':readback,'scope':'Windows QPC; enqueue-to-pack includes GPU readback, polling and shared publication','stages':{k:stats([r[k] for r in rows]) for k in rows[0]}},indent=2))
