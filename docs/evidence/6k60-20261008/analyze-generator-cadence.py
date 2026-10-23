"""Measured generator intervals, independently of receiver sampling."""
import json,re,statistics,sys
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
text=(r/f'{t}-generator.log').read_text()
rows=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',l)} for l in text.splitlines() if l.startswith('motion-present ')]
start=min(d['generated'] for d in rows)
gaps=[(b['generated']-a['generated'])/10000 for a,b in zip(rows,rows[1:]) if 100000000<=a['generated']-start<250000000]
v=sorted(gaps)
all_gaps=[{'sequence':b['sequence'],'seconds':(b['generated']-start)/1e7,'gap_ms':(b['generated']-a['generated'])/10000} for a,b in zip(rows,rows[1:])]
whole={'n':len(all_gaps),'max_ms':max(x['gap_ms'] for x in all_gaps),'over25ms':sum(x['gap_ms']>25 for x in all_gaps),'largest_gaps':sorted(all_gaps,key=lambda x:x['gap_ms'],reverse=True)[:5]}
print(json.dumps({'whole_run':whole,'scope':'generator10-25seconds; elapsed CPU timestamps not display cadence','high_resolution_timer_logged':'motion-pacing high_resolution_timer=1' in text,'n':len(v),'min_ms':min(v),'p50_ms':statistics.median(v),'p95_ms':v[int(len(v)*.95)],'max_ms':max(v),'under8ms':sum(x<8 for x in v),'over25ms':sum(x>25 for x in v)},indent=2))
