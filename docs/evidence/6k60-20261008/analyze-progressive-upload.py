"""CPU observed upload phases; optional exact PTS identity, not GPU timestamps."""
import json,re,statistics,sys
from pathlib import Path
text=(Path(__file__).resolve().parent/f'{sys.argv[1]}-host.log').read_text()
rows=[];releases={}
for line in text.splitlines():
 if 'progressive-release ' in line:
  m=re.search(r'pts=(-?\d+) cleanup_cpu_ms=([\d.]+)',line)
  if m:releases[int(m[1])]=float(m[2])
 if 'progressive-texture ' not in line:continue
 d={k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',line)}
 m=re.search(r'\bpts=(-?\d+)',line)
 if m:d['pts']=int(m[1])
 if (d.get('width'),d.get('height'))==(6144,3456):rows.append(d)
def stats(values):
 v=sorted(values)
 return {'n':len(v),'p50':statistics.median(v),'p95':v[int(len(v)*.95)],'max':max(v)} if v else {'n':0}
print(json.dumps({'scope':'CPU wall intervals including scheduling, not GPU execution; older logs lack PTS; identity-bearing rows support exact joins','identity_records':sum('pts' in d for d in rows),'cleanup_cpu_ms':stats([releases[d['pts']] for d in rows if 'pts' in d and d['pts'] in releases]),'stages':{k:stats([d[k] for d in rows]) for k in ['submissions','setup_ms','pin_ms','submit_cpu_ms','final_event_wait_ms','total_ms']},'notify_fallback_records':text.count('progressive-notify fallback=')},indent=2))
