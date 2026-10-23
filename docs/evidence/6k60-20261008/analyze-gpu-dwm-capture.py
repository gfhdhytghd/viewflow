"""Temporal compositor correlation, without claiming per-window attribution."""
import re,json,bisect,statistics,collections
from pathlib import Path
r=Path(__file__).resolve().parent;t='physical-pixel-progressive9'
def fields(s):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',s)}
gpu={};caps={};callbacks={};stamps=[];starts=collections.defaultdict(list)
for line in (r/f'{t}-generator.log').read_text().splitlines():
 if line.startswith('motion-gpu '):
  d=fields(line);gpu[(d['sequence'],d['generated'])]=d
for line in (r/f'{t}-guest.log').read_text().splitlines():
 d=fields(line)
 if line.startswith('profile_capture '):callbacks[(d['id'],d['capture'])]=d
 if line.startswith('profile_shared_capture '):caps[d['pts']]=d
 if line.startswith('profile_pixel_stamp '):stamps.append(d)
for line in (r/'progressive9-dwm-raw.txt').read_text().splitlines():
 d=fields(line)
 if d['id']==10:starts[(d['pid'],d['tid'])].append(d['timestamp'])
rows=collections.defaultdict(list)
for key,times in starts.items():
 times.sort()
 for s in stamps:
  g=gpu.get((s['sequence'],s['generated_qpc_100ns']));c=caps.get(s['pts'])
  if not g or not c or (c['width'],c['height'])!=(6144,3456):continue
  cb=callbacks.get((c['id'],c['capture']),{}).get('wgc_entered',0)
  if not cb:continue
  a=bisect.bisect_left(times,g['observed']);b=bisect.bisect_right(times,cb)
  if a>=len(times):continue
  rows[str(key)].append({'sequence':s['sequence'],'gpu_observed_to_next_dwm_start_ms':(times[a]-g['observed'])/10000,'next_dwm_start_to_callback_ms':(cb-times[a])/10000,'dwm_starts_before_callback':max(0,b-a)})
def stats(v):
 v=sorted(v);return {'n':len(v),'p50':statistics.median(v),'p95':v[int(.95*len(v))],'min':v[0],'max':v[-1]}
print(json.dumps({'scope':'temporal proximity only; compositor frame not linked to fixture surface; negative offsets retained; heavy ETW control','threads':{k:{name:stats([x[name] for x in v]) for name in v[0] if name!='sequence'} for k,v in rows.items()},'rows':rows},indent=2))
