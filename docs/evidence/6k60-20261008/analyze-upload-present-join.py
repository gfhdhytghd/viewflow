"""Exact PTS join: sampled presentation and CPU-observed upload/cleanup."""
import json,re,sys,statistics
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1];uploads={};cleanup={}
for line in (r/f'{t}-host.log').read_text().splitlines():
 if 'progressive-texture ' not in line and 'progressive-release ' not in line:continue
 m=re.search(r'\bpts=(-?\d+)',line)
 if not m:continue
 pts=int(m[1]);d={k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',line) if k!='pts'}
 if 'progressive-texture ' in line:uploads[pts]=d
 else:cleanup[pts]=d
rows=[];missing=0
for row in json.loads((r/f'{t}-stages.json').read_text())['rows']:
 if row['frame_identity']['source_protocol']!='shm2':continue
 pts=row['frame_identity']['pts']
 if pts not in uploads:missing+=1;continue
 rows.append({'pts':pts,'total_ms':row['total_ms'],'source_to_callback_ms':row['generation_to_callback_ms'],'accept_to_feedback_ms':row['host_accept_end_to_feedback_ms'],'upload':uploads[pts],'cleanup_cpu_ms':cleanup.get(pts,{}).get('cleanup_cpu_ms')})
def stats(v):
 v=sorted(v);return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(.95*len(v)))],'max':v[-1]} if v else {'n':0}
print(json.dumps({'scope':'same-PTS sampled SHM2 feedback; upload total includes producer-prefix waiting and overlaps source publication; durations not additive, not GPU execution or photons','missing_upload_identity':missing,'matched':len(rows),'summary':{'cleanup_cpu_ms':stats([x['cleanup_cpu_ms'] for x in rows if x['cleanup_cpu_ms'] is not None]),**{k:stats([x['upload'][k] for x in rows]) for k in ['setup_ms','pin_ms','submit_cpu_ms','final_event_wait_ms','total_ms']}},'slowest_feedback_rows':sorted(rows,key=lambda x:x['total_ms'],reverse=True)[:5]},indent=2))
