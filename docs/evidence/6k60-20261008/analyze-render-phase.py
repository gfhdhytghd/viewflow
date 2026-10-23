"""Same-host-clock ordering, not proof a render sampled a particular surface."""
import bisect,json,re,statistics,sys
from pathlib import Path
root=Path(__file__).resolve().parent;tag=sys.argv[1]
plugin=Path(sys.argv[2]) if len(sys.argv)>2 else root/(tag+'-plugin-after.json')
spans=json.loads(plugin.read_text())['render_spans']
spans=sorted(spans);starts=[r[0] for r in spans]
valid=set()
for line in (root/(tag+'-guest.log')).read_text().splitlines():
 m=re.search(r'profile_shared_capture pts=(\d+).* width=6144 height=3456',line)
 if m:valid.add(int(m[1]))
accepted={};rows=[];seen=set()
for line in (root/(tag+'-host.log')).read_text().splitlines():
 m=re.search(r'ivshmem-host-frame stage=accept_end pts=(\d+) monotonic_ns=(\d+)',line)
 if m:accepted[int(m[1])]=int(m[2])
 m=re.search(r'ivshmem-clock-sample output=DP-4 id=(\d+) atlas_submit_qpc_100ns=(\d+) presented_monotonic_ns=(\d+) clock_id=1',line)
 if not m:continue
 pts,when=int(m[2]),int(m[3]);key=(m[1],pts)
 if pts not in valid or pts not in accepted or key in seen:continue
 seen.add(key);end=accepted[pts];i=bisect.bisect_left(starts,end)
 if i>=len(spans) or not starts[0]<=end<=starts[-1] or spans[i][0]>=when:continue
 eligible=[s for s in spans[i:] if s[1]<when]
 rows.append(dict(pts=pts,accept_to_first_render_ms=(spans[i][0]-end)/1e6,first_render_to_feedback_ms=(when-spans[i][0])/1e6,accept_to_feedback_ms=(when-end)/1e6,completed_renders_before_feedback=len(eligible),renders_after_1ms_margin=sum(s[0]>=end+1000000 for s in eligible)))
def stats(key):
 v=sorted(r[key] for r in rows)
 return dict(n=len(v),p50=statistics.median(v),p95=v[min(len(v)-1,int(len(v)*.95))],max=v[-1]) if v else dict(n=0)
print(json.dumps(dict(scope='host accept_end and render ordering only; no surface commit/fence identity; not GPU execution time',render_spans=len(spans),summary={k:stats(k) for k in ('accept_to_first_render_ms','first_render_to_feedback_ms','accept_to_feedback_ms','completed_renders_before_feedback','renders_after_1ms_margin')},rows=rows),indent=2))
