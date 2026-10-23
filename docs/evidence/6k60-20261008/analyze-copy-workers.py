import re,json,statistics,sys
from pathlib import Path
rows=[]
for line in Path(sys.argv[1]).read_text().splitlines():
 if not line.startswith('shared-copy-workers '):continue
 d={k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',line)}
 if d.get('bytes')!=84934656:continue
 rows.append(d)
def stats(v):
 v=sorted(v);return {'n':len(v),'p50_ms':statistics.median(v),'p95_ms':v[min(len(v)-1,len(v)*95//100)],'max_ms':max(v)} if v else {'n':0}
result={'scope':'Sparse CPU-wall samples every120copies; start includes wake/dispatch, copy includes descheduling; not pure bandwidth','samples':len(rows),'workers':{}}
for i in range(4):result['workers'][i]={k:stats([r[f'worker{i}_{k}_ms'] for r in rows]) for k in ['start','copy']}
result['max_start_per_copy']=stats([max(r[f'worker{i}_start_ms'] for i in range(4)) for r in rows])
result['copy_spread_per_copy']=stats([max(r[f'worker{i}_copy_ms'] for i in range(4))-min(r[f'worker{i}_copy_ms'] for i in range(4)) for r in rows])
print(json.dumps(result,indent=2))
