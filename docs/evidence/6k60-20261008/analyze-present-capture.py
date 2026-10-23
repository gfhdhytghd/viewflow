"""Join actual pixel identity to Present and WGC callback on guest QPC only."""
import bisect,json,re,statistics,sys
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
def fields(line):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
presents={}
for line in (r/f'{t}-generator.log').read_text().splitlines():
 if line.startswith('motion-present '):
  d=fields(line);presents[d['sequence']]=d
captures={};callbacks={};stamps=[]
for line in (r/f'{t}-guest.log').read_text().splitlines():
 d=fields(line)
 if line.startswith('profile_capture ') and 'callback_qpc' in d:callbacks[(d['id'],d['capture'])]=d['callback_qpc']
 if line.startswith('profile_shared_capture '):captures[d['pts']]=d
 if line.startswith('profile_pixel_stamp '):stamps.append(d)
ends=sorted((p['end'],seq) for seq,p in presents.items());times=[x[0] for x in ends]
rows=[];seen=set();identity_mismatch=0
for s in stamps:
 c=captures.get(s['pts']);p=presents.get(s['sequence'])
 if not c or not p or (c['width'],c['height'])!=(6144,3456):continue
 cb=callbacks.get((c['id'],c['capture']))
 if cb is None or s['sequence'] in seen:continue
 seen.add(s['sequence'])
 if p['generated']!=s['generated_qpc_100ns']:identity_mismatch+=1;continue
 latest=bisect.bisect_right(times,cb)-1
 rows.append({'sequence':s['sequence'],'generation_to_present_begin_ms':(p['begin']-p['generated'])/10000,'present_call_ms':(p['end']-p['begin'])/10000,'present_end_to_callback_ms':(cb-p['end'])/10000,'generation_to_callback_ms':(cb-p['generated'])/10000,'newer_present_calls_completed':max(0,ends[latest][1]-s['sequence']) if latest>=0 else 0})
def stats(values):
 v=sorted(values)
 return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(len(v)*.95))],'min':v[0],'max':v[-1]} if v else {'n':0}
print(json.dumps({'scope':'same pixel identity guest QPC; Present completion is CPU return, not GPU completion or display; newer completed calls do not prove newer capture-ready frames','identity_mismatch':identity_mismatch,'stages':{k:stats([d[k] for d in rows]) for k in rows[0] if k!='sequence'} if rows else {},'rows':rows},indent=2))
