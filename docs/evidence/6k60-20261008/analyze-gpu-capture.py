"""Pixel-correlated CPU observation of GPU fence; not exact GPU or photon time."""
import json,re,sys,statistics
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
def fields(line):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
gpu={};summaries=[]
for line in (r/f'{t}-generator.log').read_text().splitlines():
 if line.startswith('motion-gpu-summary '):summaries.append(line)
 if line.startswith('motion-gpu '):
  d=fields(line);gpu[(d['sequence'],d['generated'])]=d
stamps={};caps={};callbacks={}
for line in (r/f'{t}-guest.log').read_text().splitlines():
 d=fields(line)
 if line.startswith('profile_pixel_stamp '):stamps[d['pts']]=d
 if line.startswith('profile_shared_capture '):caps[d['pts']]=d
 if line.startswith('profile_capture '):callbacks[(d['id'],d['capture'])]=d
rows=[];excluded_extent=0;matched_extents={};capture_times=[]
for pts,s in stamps.items():
 g=gpu.get((s['sequence'],s['generated_qpc_100ns']));c=caps.get(pts)
 if not g or not c:continue
 b=callbacks.get((c['id'],c['capture']))
 if not b or not b.get('wgc_entered'):continue
 extent=(c['width'],c['height']);matched_extents[str(extent)]=matched_extents.get(str(extent),0)+1
 if extent!=(6144,3456) or (b.get('width'),b.get('height'))!=(6144,3456):excluded_extent+=1;continue
 capture_times.append(b['wgc_entered'])
 rows.append({'pts':pts,'sequence':s['sequence'],'generation_to_observed_gpu_ms':(g['observed']-g['generated'])/10000,'fence_submit_to_observed_ms':(g['observed']-g['submitted'])/10000,'observed_gpu_to_wgc_ms':(b['wgc_entered']-g['observed'])/10000,'generation_to_wgc_ms':(b['wgc_entered']-g['generated'])/10000})
def stats(k):
 v=sorted(d[k] for d in rows);return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(.95*len(v)))],'min':v[0],'max':v[-1]} if v else {'n':0}
print(json.dumps({'scope':'fence follows fixture drawing before Present; observed time includes CPU scheduling/poll delay and is an upper bound; observed-to-WGC gap is a lower bound on actual completion-to-WGC gap; negative values retained','gpu_summaries':summaries,'gpu_records':len(gpu),'matched_atlas_extents':matched_extents,'excluded_non_6k':excluded_extent,'matched_6k_span_ms':(max(capture_times)-min(capture_times))/10000 if capture_times else None,'summary':{k:stats(k) for k in ['generation_to_observed_gpu_ms','fence_submit_to_observed_ms','observed_gpu_to_wgc_ms','generation_to_wgc_ms']},'worst_20':sorted(rows,key=lambda d:d['generation_to_wgc_ms'],reverse=True)[:20]},indent=2))
