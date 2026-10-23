"""Source callback outcomes; clock-bin counts are not same-frame generation attribution."""
import re,json,sys,collections
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
def fields(s):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',s)}
generated=[fields(l)['generated'] for l in (r/f'{t}-generator.log').read_text().splitlines() if l.startswith('motion-present ')]
entries=[];successful=set();drops=collections.Counter();selected=set()
for l in (r/f'{t}-guest.log').read_text().splitlines():
 d=fields(l)
 if l.startswith('profile_capture_entry '):entries.append(d)
 if l.startswith('profile_capture '):successful.add((d['id'],d['capture']))
 if l.startswith('profile_capture_drop '):drops[(d['id'],d['capture'])]+=1
 if l.startswith('profile_shared_capture '):selected.add((d['id'],d['capture']))
start=min(generated);bins=[]
for i in range(1,5):
 lo=start+i*50000000;hi=lo+50000000
 e=[d for d in entries if lo<=d['callback_qpc']<hi and (d['width'],d['height'])==(6144,3456)]
 keys=[(d['id'],d['capture']) for d in e]
 bins.append({'seconds':[i*5,(i+1)*5],'generated':sum(lo<=x<hi for x in generated),'callback_entries':len(e),'successful':sum(k in successful for k in keys),'pool_busy':sum(k in drops for k in keys),'successful_never_selected':sum(k in successful and k not in selected for k in keys),'unclassified':sum(k not in successful and k not in drops for k in keys)})
print(json.dumps({'scope':'callback-clock bins versus generator-clock bins; failed pool explicitly counted; not per-generated-frame identity proof','intervals':bins,'total_entries':len(entries),'total_pool_drop_records':sum(drops.values())},indent=2))
