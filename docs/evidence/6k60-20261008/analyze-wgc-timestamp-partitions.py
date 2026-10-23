"""Same-identity WGC timestamp partitions; timestamps do not imply GPU completion."""
import json,re,statistics,sys
from pathlib import Path
r=Path(__file__).resolve().parent
for tag in sys.argv[1:]:
 captures={};callbacks={};stamps={};seen=set();rows=[]
 for line in (r/f'{tag}-guest.log').read_text().splitlines():
  d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
  if line.startswith('profile_shared_capture '):captures[d['pts']]=d
  if line.startswith('profile_capture '):callbacks[(d['id'],d['capture'])]=d
  if line.startswith('profile_pixel_stamp '):stamps[d['pts']]=d
 for pts,s in stamps.items():
  c=captures.get(pts)
  if not c:continue
  key=(c['id'],c['capture'],c['version'])
  if key in seen:continue
  seen.add(key);b=callbacks.get(key[:2])
  if not b or not b.get('wgc_entered'):continue
  rows.append({'sequence':s['sequence'],'capture':c['capture'],'generation_to_frame_timestamp_ms':(c['capture']-s['generated_qpc_100ns'])/10000,'frame_timestamp_to_callback_entry_ms':(b['wgc_entered']-c['capture'])/10000,'callback_entry_to_consumer_ms':(b['callback_qpc']-b['wgc_entered'])/10000})
 def stats(k):
  v=sorted(x[k] for x in rows)
  return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(len(v)*.95))],'min':v[0],'max':v[-1]} if v else {'n':0}
 result={'scope':'unique source capture identity; WGC SystemRelativeTime is metadata, not GPU completion or photon timestamp; negative values retained','summary':{k:stats(k) for k in ['generation_to_frame_timestamp_ms','frame_timestamp_to_callback_entry_ms','callback_entry_to_consumer_ms']}}
 (r/f'{tag}-wgc-partitions.json').write_text(json.dumps(result,indent=2));print(tag,json.dumps(result))
