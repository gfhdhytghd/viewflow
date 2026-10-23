"""Correlate source tail with explicit query and poll-gap observations."""
import re,json,sys,statistics
from pathlib import Path
caps={};cb={};outs={};ready={};bands={};diagnostics={}
for l in Path(sys.argv[1]).read_text().splitlines():
 d={k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',l)}
 if l.startswith('profile_capture '):cb[int(d['capture'])]=d
 if l.startswith('profile_shared_capture '):caps[int(d['pts'])]=d
 if l.startswith('profile_output '):outs[int(d['pts'])]=d
 if l.startswith('profile_shared_ready '):ready[int(d['pts'])]=d
 if l.startswith('profile_band_overlap '):bands[int(d['pts'])]=d
 if l.startswith('profile_band_diagnostic '):diagnostics[int(d['pts'])]=d
rows=[]
for p,c in caps.items():
 if p not in outs or p not in bands or int(c['capture']) not in cb:continue
 b=cb[int(c['capture'])];o=outs[p]
 rows.append({'pts':p,'callback_to_write_ms':(o['write_end']-b['callback_qpc'])/10000,'callback_to_copy_submit_ms':(b['copied']-b['callback_qpc'])/10000,'copy_submit_to_adopt_ms':(c['enqueued']-b['copied'])/10000,'adopt_to_write_ms':(o['write_end']-c['enqueued'])/10000,'query_max_ms':bands[p].get('query_max_ms'),'poll_gap_max_ms':bands[p].get('poll_gap_max_ms'),'publish_ms':ready.get(p,{}).get('publish_ms'),'map_ms':ready.get(p,{}).get('map_ms'),'first_poll_ms':bands[p].get('first_poll_ms'),'unmap_max_ms':bands[p].get('unmap_max_ms'),'diagnostic_ms':diagnostics.get(p,{}).get('pre_publish_ms'),'deferred_diagnostic_ms':diagnostics.get(p,{}).get('deferred_ms')})
rows.sort(key=lambda x:x['callback_to_write_ms'],reverse=True)
def stats(k):
 v=sorted(d[k] for d in rows if d[k] is not None);return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(.95*len(v)))],'max':v[-1]} if v else {'n':0}
print(json.dumps({'scope':'same source frame; poll gap includes previous poll work; first_poll measures publication construction to first poll; diagnostic measures pre-publish logs and lease cleanup','summary':{k:stats(k) for k in ['callback_to_write_ms','adopt_to_write_ms','query_max_ms','poll_gap_max_ms','publish_ms','map_ms','first_poll_ms','unmap_max_ms','diagnostic_ms','deferred_diagnostic_ms']},'worst_20':rows[:20]},indent=2))
