"""Match actual DXGI present count; surface identity remains a candidate without HWND binding."""
from pathlib import Path
import re,sys,struct,json,collections,statistics
r=Path(__file__).resolve().parent;t=sys.argv[1];raw=sys.argv[2]
def fields(s):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',s)}
present={};media={};callbacks={};caps={};stamps=[];surfaces=collections.defaultdict(dict)
for l in (r/f'{t}-generator.log').read_text().splitlines():
 d=fields(l)
 if l.startswith('motion-present '):present[d['sequence']]=d
 if l.startswith('motion-media ') and 'last_hr=0x00000000' in l:media[d['sequence']]=d['last']
active_frames={};frame_ends={}
for l in (r/raw).read_text().splitlines():
 d=fields(l);thread=(d['pid'],d['tid'])
 if d['id']==10:active_frames[thread]=d['timestamp']
 if d['id']==12:
  begin=active_frames.pop(thread,None)
  if begin is not None:frame_ends[(thread,begin)]=d['timestamp']
 if not l.startswith('event id=196 '):continue
 b=bytes.fromhex(l.split('payload=')[1]);d=fields(l)
 if len(b)<32:continue
 luid,bind,count,fence=struct.unpack_from('<QQQQ',b)
 surfaces[(luid,bind)].setdefault(count,[]).append({'timestamp':d['timestamp'],'thread':thread,'frame_begin':active_frames.get(thread)})
for l in (r/f'{t}-guest.log').read_text().splitlines():
 d=fields(l)
 if l.startswith('profile_capture '):callbacks[(d['id'],d['capture'])]=d
 if l.startswith('profile_shared_capture '):caps[d['pts']]=d
 if l.startswith('profile_pixel_stamp '):stamps.append(d)
def stats(v):
 v=sorted(v);return {'n':len(v),'p50':statistics.median(v),'p95':v[int(len(v)*.95)],'min':v[0],'max':v[-1]} if v else {'n':0}
out=[]
for key,updates in surfaces.items():
 rows=[];ambiguous=0
 for s in stamps:
  seq=s['sequence'];p=present.get(seq);count=media.get(seq);c=caps.get(s['pts']);u=updates.get(count,[])
  if not p or p['generated']!=s['generated_qpc_100ns'] or not c or (c['width'],c['height'])!=(6144,3456):continue
  cb=callbacks.get((c['id'],c['capture']),{}).get('wgc_entered')
  if not cb or not u:continue
  if len(u)!=1:ambiguous+=1;continue
  update=u[0];when=update['timestamp'];end=frame_ends.get((update['thread'],update['frame_begin']))
  row={'sequence':seq,'count':count,'generation_to_update_ms':(when-p['generated'])/10000,'update_to_callback_ms':(cb-when)/10000}
  if end is not None:row.update(update_to_frame_end_ms=(end-when)/10000,frame_end_to_callback_ms=(cb-end)/10000)
  rows.append(row)
 out.append({'luid':hex(key[0]),'bind':key[1],'ambiguous':ambiguous,'stages':{k:stats([d[k] for d in rows if k in d]) for k in ['generation_to_update_ms','update_to_callback_ms','update_to_frame_end_ms','frame_end_to_callback_ms']},'rows':rows})
print(json.dumps({'scope':'candidate surface by actual PresentCount and temporal consistency; not independent HWND identity; negative offsets retained','candidates':out},indent=2))
