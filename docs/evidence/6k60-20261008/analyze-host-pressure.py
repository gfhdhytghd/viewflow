"""Summarize sampled counter deltas over the actual benchmark interval."""
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text());rows=d['samples'];a,b=rows[0],rows[-1];seconds=(b['monotonic_ns']-a['monotonic_ns'])/1e9
result={'returncode':d['returncode'],'samples':len(rows),'seconds':seconds,'max_sample_gap_ms':max((y['monotonic_ns']-x['monotonic_ns'])/1e6 for x,y in zip(rows,rows[1:])),'psi_stall_fraction':{},'vmstat_delta':{k:b['vmstat'][k]-v for k,v in a['vmstat'].items()},'min_available_memory_gib':min(r['memory_kib']['MemAvailable'] for r in rows)/1048576}
for kind,fields in a['psi'].items():
    result['psi_stall_fraction'][kind]={k:(b['psi'][kind][k]['total']-v['total'])/(seconds*1e6) for k,v in fields.items()}
first={t['tid']:t for t in a['vcpu']};common=[t for t in b['vcpu'] if t['tid'] in first]
result['vcpu']={'matched_threads':len(common),'run_seconds':sum(t['schedstat'][0]-first[t['tid']]['schedstat'][0] for t in common)/1e9,'runnable_wait_seconds':sum(t['schedstat'][1]-first[t['tid']]['schedstat'][1] for t in common)/1e9}
print(json.dumps(result,indent=2))
