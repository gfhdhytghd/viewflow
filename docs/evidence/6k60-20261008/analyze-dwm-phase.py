"""Exploratory phase correlation against sparse desktop DWM metadata, not scanout proof."""
import json,re,sys,statistics
from pathlib import Path
r=Path(__file__).resolve().parent
def fields(l):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',l)}
def stats(v):
 v=sorted(v);return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(.95*len(v)))],'min':v[0],'max':v[-1]} if v else {'n':0}
for tag in sys.argv[1:]:
 samples=[];caps={};callbacks={};stamps=[];rows=[];seen=set()
 for l in (r/f'{tag}-generator.log').read_text().splitlines():
  if l.startswith('motion-dwm ') and 'hr=0x00000000' in l:
   d=fields(l)
   if d['frequency']>0 and d['refresh_period_qpc']>0 and d['vblank_qpc']>0:samples.append(d)
 for l in (r/f'{tag}-guest.log').read_text().splitlines():
  d=fields(l)
  if l.startswith('profile_shared_capture '):caps[d['pts']]=d
  if l.startswith('profile_capture '):callbacks[(d['id'],d['capture'])]=d
  if l.startswith('profile_pixel_stamp '):stamps.append(d)
 for s in stamps:
  c=caps.get(s['pts'])
  if not c or not samples:continue
  key=(c['id'],c['capture'],c['version'])
  if key in seen:continue
  seen.add(key);b=callbacks.get(key[:2])
  if not b:continue
  g=s['generated_qpc_100ns'];d=min(samples,key=lambda d:abs(d['qpc']*10000000/d['frequency']-g))
  ticks=g*d['frequency']/10000000
  phase=((ticks-d['vblank_qpc'])%d['refresh_period_qpc'])/d['refresh_period_qpc']
  rows.append({'phase':phase,'latency':(b['callback_qpc']-g)/10000,'sample_distance_ms':abs(ticks-d['qpc'])*1000/d['frequency']})
 result={'scope':'nearest sparse desktop DWM vblank extrapolation; not window-specific or physical scanout; observational correlation cannot establish causality','phase_fraction':stats([x['phase'] for x in rows]),'sample_distance_ms':stats([x['sample_distance_ms'] for x in rows]),'generation_to_callback_ms':stats([x['latency'] for x in rows]),'phase_bins':[{'fraction':[i/8,(i+1)/8],'latency_ms':stats([x['latency'] for x in rows if i/8<=x['phase']<(i+1)/8])} for i in range(8)]}
 (r/f'{tag}-dwm-phase.json').write_text(json.dumps(result,indent=2));print(tag,json.dumps(result))
