"""Capability audit only; SyncQPCTime is not automatically a frame display time."""
import re,json,sys,collections
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1];rows=[]
for line in (r/f'{t}-generator.log').read_text().splitlines():
 if not line.startswith('motion-media '):continue
 rows.append({k:int(v,16) if v.startswith('0x') else int(v) for k,v in re.findall(r'(\w+)=(0x[0-9a-fA-F]+|-?\d+)',line)})
success=[d for d in rows if d['hr']==0]
print(json.dumps({'scope':'capability and observed counter updates only; no inferred per-frame composition or photon timestamps','records':len(rows),'status_counts':dict(collections.Counter(hex(d['hr']) for d in rows)),'last_present_status_counts':dict(collections.Counter(hex(d['last_hr']) for d in rows)),'success_records':len(success),'nonzero_sync_qpc':sum(d['sync_qpc']!=0 for d in success),'distinct_present_counts':len({d['count'] for d in success}),'distinct_sync_qpc':len({d['sync_qpc'] for d in success}),'first':rows[:3],'last':rows[-3:]},indent=2))
