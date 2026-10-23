"""CPU API durations, not GPU execution time; includes allocation/startup."""
import re,json,statistics,sys
from pathlib import Path
p=Path(__file__).resolve().parent/f'{sys.argv[1]}-guest.log'
rows=[]
for l in p.read_text().splitlines():
 if l.startswith('profile_capture_stages '):
  rows.append({k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',l)})
def summary(v):
 v=sorted(v)
 return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(len(v)*.95))],'max':v[-1]} if v else {'n':0}
keys=['lock_ms','geometry_ms','prepare_ms','copy_ms','end_ms','flush_ms']
print(json.dumps({'scope':'CPU API durations; copy/end/flush sum across bands; not GPU timestamps; includes startup','captured':len(rows),'stages':{k:summary([x[k] for x in rows]) for k in keys},'largest_copy_or_flush':sorted(rows,key=lambda x:x['copy_ms']+x['flush_ms'],reverse=True)[:5]},indent=2))
