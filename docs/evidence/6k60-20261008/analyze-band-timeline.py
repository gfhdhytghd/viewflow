"""Cross-clock CPU prefix/enqueue correlation, never a DMA-overlap assertion."""
import re,json,sys,statistics
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1];bands={};uploads={}
def fields(l):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',l)}
for l in (r/f'{t}-guest.log').read_text().splitlines():
 if l.startswith('profile_band_publish '):
  d=fields(l);bands.setdefault(d['pts'],[]).append(d)
for l in (r/f'{t}-host.log').read_text().splitlines():
 if 'progressive-submit ' in l:
  d=fields(l);uploads.setdefault(d['pts'],[]).append(d)
cals=[json.loads((r/f'{t}-clock-{x}.json').read_text()) for x in ['start','end']]
lo=min(x['best']['offset_low_ns'] for x in cals);hi=max(x['best']['offset_high_ns'] for x in cals);mid=(lo+hi)/2
rows=[]
for pts,bs in bands.items():
 us=uploads.get(pts)
 if not us or len(bs)!=2:continue
 bs=sorted(bs,key=lambda b:b['row_begin']);us=sorted(us,key=lambda b:b['row_begin']);u=us[0]
 if u['row_begin']!=0 or u['row_end']!=bs[0]['row_end']:continue
 first=bs[0]['published_qpc']*100;last=bs[1]['published_qpc']*100
 rows.append({'pts':pts,'prefix_to_enqueue_ms':(u['begin_monotonic_ns']-first-mid)/1e6,'enqueue_before_final_publish_ms':(last+mid-u['end_monotonic_ns'])/1e6,'definitely_enqueued_before_final_publish':u['end_monotonic_ns']<last+lo,'clock_order_violation':u['begin_monotonic_ns']<first+lo})
def stats(v):
 v=sorted(v);return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(.95*len(v)))],'min':v[0],'max':v[-1]} if v else {'n':0}
print(json.dumps({'scope':'two source bands with matching first upload row extent; CPU enqueue only, no proof DMA execution overlap; published timestamp follows actual release store; clock-order violations retained','matched':len(rows),'clock_halfwidth_ms':(hi-lo)/2e6,'enqueued_before_final_publish_conservative':sum(x['definitely_enqueued_before_final_publish'] for x in rows),'clock_order_violations':sum(x['clock_order_violation'] for x in rows),'summary':{k:stats([x[k] for x in rows]) for k in ['prefix_to_enqueue_ms','enqueue_before_final_publish_ms']}},indent=2))
