"""DWM desktop counter deltas; never label these as per-window receive FPS."""
import json,re,sys
from pathlib import Path
b=Path(sys.argv[1]).read_bytes();s=b.decode('utf-16') if b.startswith((b'\xff\xfe',b'\xfe\xff')) else b.decode('utf-8-sig',errors='replace')
rows=[]
for line in s.splitlines():
    if 'motion-dwm ' not in line:continue
    if 'hr=0x00000000' not in line:continue
    d={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)(?:\s|$)',line)}
    if all(k in d for k in ('qpc','frequency','refresh','frame')):rows.append(d)
intervals=[]
for a,b in zip(rows,rows[1:]):
    dt=(b['qpc']-a['qpc'])/b['frequency']
    if dt<=0 or a['frequency']!=b['frequency']:continue
    intervals.append({'seconds':dt,'refresh_counter_per_s':(b['refresh']-a['refresh'])/dt,'composition_counter_per_s':(b['frame']-a['frame'])/dt,'late_delta':b.get('late',0)-a.get('late',0),'missed_raw':b.get('missed'),'dropped_raw':b.get('dropped')})
print(json.dumps({'scope':'desktop DWM timing; counters can be unavailable or inapplicable to composition swap-chain windows; zeros alone do not prove no drops','successful_samples':len(rows),'samples':rows,'intervals':intervals},indent=2))
