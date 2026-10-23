"""Audit guest-local WGC timestamps against callback entry; retain raw negatives."""
import json,re,sys,statistics
from pathlib import Path
rows=[]
for line in Path(sys.argv[1]).read_text().splitlines():
 if not line.startswith('profile_capture '):continue
 d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
 if d.get('width')!=6144 or d.get('height')!=3456 or 'callback_qpc' not in d:continue
 rows.append(d)
def stats(v):
 v=sorted(v)
 return {'n':len(v),'min':v[0],'p50':statistics.median(v),'p95':v[min(len(v)-1,int(.95*len(v)))],'max':v[-1]} if v else {'n':0}
print(json.dumps({'scope':'guest-local QPC audit, not capture or photon latency; no clamping or offset correction','frames':len(rows),'wgc_later_than_callback':sum(d['capture']>d['callback_qpc'] for d in rows),'callback_minus_wgc_ms':stats([(d['callback_qpc']-d['capture'])/10000 for d in rows]),'callback_to_copy_submission_ms':stats([(d['copied']-d['callback_qpc'])/10000 for d in rows])},indent=2))
