"""Measure actual source latency conditional on admission occupancy."""
from pathlib import Path
import re,json,statistics,math
b=Path(__file__).resolve().parents[2]
def stats(v):
 v=sorted(v);return dict(n=len(v),median=statistics.median(v),p95=v[math.ceil(.95*len(v))-1],max=v[-1])
result=[]
for label in ['combinedzero-four-a1','combinedzero-four-a2','combinedzero-two-c1','combinedzero-two-c2','mode-combined-long-frame-a1r']:
 p=b/'transport/runs'/label;text=(p/'source.log').read_text()
 def rows(prefix):return [dict((k,int(v)) for k,v in re.findall(r'(\w+)=(-?\d+)',s)) for s in text.splitlines() if s.startswith(prefix+' ')]
 submits=rows('profile_submit');by_pts={x['pts']:x for x in submits};colors=rows('profile_color_ready');start=submits[0]['submit_begin']+30_000_000
 pairs=[dict(pending=by_pts[x['pts']]['pending'],ms=(x['at']-by_pts[x['pts']]['submit_begin'])/10000,at=by_pts[x['pts']]['submit_begin']) for x in colors if x['pts'] in by_pts and by_pts[x['pts']]['submit_begin']>=start]
 grouped={str(n):stats([x['ms'] for x in pairs if x['pending']==n]) for n in sorted({x['pending'] for x in pairs})}
 bins=[]
 for n in range((max(x['at'] for x in pairs)-start)//100_000_000+1):
  group=[x for x in pairs if n*100_000_000<=x['at']-start<(n+1)*100_000_000]
  if group:bins.append(dict(seconds_after_source_warmup=n*10,latency_ms=stats([x['ms'] for x in group]),pending_two_or_more_fraction=sum(x['pending']>=2 for x in group)/len(group)))
 result.append(dict(trial=label,source_warmup_seconds=3,source_submit_to_color_ready_ms=stats([x['ms'] for x in pairs]),by_before_submit_pending=grouped,bins=bins))
(b/'mode-combined/method/occupancy-results.json').write_text(json.dumps(result,indent=2)+'\n')
for r in result:print(r['trial'],r['source_submit_to_color_ready_ms'],r['by_before_submit_pending'])
