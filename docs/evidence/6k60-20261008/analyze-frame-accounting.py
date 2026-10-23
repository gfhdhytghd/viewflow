"""Identity accounting in generation-aligned interior intervals, not presentation proof."""
import re,json,sys,collections
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
def fields(s):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',s)}
generated={};stamps={};completed=set();stages=collections.defaultdict(set)
for l in (r/f'{t}-generator.log').read_text().splitlines():
 if l.startswith('motion-present '):
  d=fields(l);generated[d['sequence']]=d['generated']
for l in (r/f'{t}-guest.log').read_text().splitlines():
 d=fields(l)
 if l.startswith('profile_pixel_stamp '):stamps[d['pts']]=d
 if l.startswith(('profile_shared_ready ','profile_shared_completed ')):completed.add(d['pts'])
for l in (r/f'{t}-host.log').read_text().splitlines():
 m=re.search(r'ivshmem-host-frame stage=(\w+) pts=(\d+)',l)
 if m:stages[m[1]].add(int(m[2]))
bins=[];start=min(generated.values())
for i in range(1,5):
 lo=start+i*50000000;hi=lo+50000000
 ps={pts for pts,s in stamps.items() if lo<=s['generated_qpc_100ns']<hi}
 done=ps&completed;announced=ps&stages['announced'];ready=ps&stages['ready'];accepted=ps&stages['accept_end']
 bins.append({'source_seconds':[i*5,(i+1)*5],'generated_sequences':sum(lo<=x<hi for x in generated.values()),'published_unique_sequences':len({stamps[p]['sequence'] for p in done}),'published_records':len(done),'host_announced':len(announced),'host_ready':len(ready),'host_accepted':len(accepted),'published_not_accepted':len(done-accepted),'announced_not_ready':len(announced-ready),'ready_not_accepted':len(ready-accepted),'missing_ready_reasons':{reason:len((announced-ready)&stages[reason]) for reason in ['superseded_active','superseded_queued','producer_aborted','replaced_by_ordinary']}})
print(json.dumps({'scope':'generation-aligned5second interior intervals; PTS set membership across captured log, not deadlines; absent stage does not identify drop reason; accept is not presentation','intervals':bins},indent=2))
