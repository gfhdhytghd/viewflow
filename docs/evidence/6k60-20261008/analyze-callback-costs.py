"""WGC callback CPU wall-clock intervals; phase labels include intervening work."""
import json,re,statistics,sys
from pathlib import Path
r=Path(__file__).resolve().parent
rows=[]
for line in (r/f'{sys.argv[1]}-guest.log').read_text().splitlines():
    if not line.startswith('profile_capture '):continue
    d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
    if d.get('width')==6144 and d.get('height')==3456:rows.append(d)
def stats(values):
    v=sorted(values)
    return {'n':len(v),'p50_ms':statistics.median(v),'p95_ms':v[int(len(v)*.95)],'max_ms':max(v),'over_16_7ms':sum(x>16.7 for x in v)} if v else {'n':0}
phases={'delivery_lock':('wgc_entered','wgc_locked'),'acquire':('wgc_locked','wgc_acquired'),'acquired_to_geometry_including_diagnostics':('wgc_acquired','wgc_geometry_done'),'surface':('wgc_geometry_done','wgc_surface_ready'),'consumer':('callback_qpc','copied')}
print(json.dumps({k:stats([(d[b]-d[a])/10000 for d in rows if d.get(a,0)>0 and d.get(b,0)>=d[a]]) for k,(a,b) in phases.items()},indent=2))
