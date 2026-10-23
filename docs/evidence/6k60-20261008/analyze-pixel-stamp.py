"""Pixel identities decoded from mapped guest staging; not host pixel validation."""
import json,re,sys,statistics
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
rows=[];publications=0;announcements=0;captures={};callbacks={}
for line in (r/f'{t}-guest.log').read_text().splitlines():
 d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
 if line.startswith('profile_shared_capture '):captures[d['pts']]=d
 if line.startswith('profile_capture ') and 'callback_qpc' in d:callbacks[d['capture']]=d['callback_qpc']
 if line.startswith(('profile_shared_ready ','profile_shared_completed ')):publications+=1
 if line.startswith('profile_shared_announced '):announcements+=1
 if line.startswith('profile_pixel_stamp '):rows.append({k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)})
def stats(v):
 v=sorted(v);return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(len(v)*.95))],'min':v[0],'max':v[-1]} if v else {'n':0}
by_pts={d['pts']:d for d in rows};seen=set();latencies=[]
host_rows=[]
for line in (r/f'{t}-host.log').read_text().splitlines():
 if 'ivshmem-pixel-stamp ' in line:
  host_rows.append({k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line.split('ivshmem-pixel-stamp ',1)[1])})
matched=sum(d['pts'] in by_pts and all(d[k]==by_pts[d['pts']][k] for k in ['sequence','generated_qpc_100ns']) for d in host_rows)
mismatched=sum(d['pts'] in by_pts and any(d[k]!=by_pts[d['pts']][k] for k in ['sequence','generated_qpc_100ns']) for d in host_rows)
unmatched=sum(d['pts'] not in by_pts for d in host_rows)
cals=[json.loads((r/f'{t}-clock-{x}.json').read_text()) for x in ('start','end')]
lo=min(c['best']['offset_low_ns'] for c in cals);hi=max(c['best']['offset_high_ns'] for c in cals);offset=(lo+hi)/2
begin=min(c['best']['host_start_ns'] for c in cals);end=max(c['best']['host_end_ns'] for c in cals)
for line in (r/f'{t}-host.log').read_text().splitlines():
 m=re.search(r'ivshmem-clock-sample output=(\S+) id=(\d+) atlas_submit_qpc_100ns=(\d+) presented_monotonic_ns=(\d+) clock_id=(\d+)',line)
 if not m or m[5]!='1':continue
 d=by_pts.get(int(m[3]));when=int(m[4])
 if d is None or not begin<=when<=end:continue
 key=(m[1],m[2],d['sequence'],d['generated_qpc_100ns'])
 if key in seen:continue
 seen.add(key)
 generated=d['generated_qpc_100ns']*100+offset
 if generated>=begin:latencies.append((when-generated)/1e6)
unique={d['sequence'] for d in rows}
callback_delays=[(callbacks[captures[d['pts']]['capture']]-d['generated_qpc_100ns'])/10000 for d in rows if d['pts'] in captures and captures[d['pts']]['capture'] in callbacks]
origin='before first ClearRenderTargetView' if 'motion-generation-origin before_clear=1 version=2' in (r/f'{t}-generator.log').read_text() else 'legacy after ClearRenderTargetView CPU call, before pixel stamp update'
print(json.dumps({'generation_origin':origin,'scope':'fixture embedded generation timestamp to sampled Wayland feedback; host marker matches reported separately; GPU rendered pixels not validated, excludes photon latency; samples do not establish continuous presentation fps','host_pixel_markers':{'records':len(host_rows),'matched_source':matched,'mismatched_source':mismatched,'unmatched_source':unmatched},'generation_to_callback_ms':stats(callback_delays),'source_publications':publications,'early_announcements':announcements,'decoded_records':len(rows),'unique_sequences':len(unique),'duplicate_records':len(rows)-len(unique),'sequence_gaps':sum(max(0,b-a-1) for a,b in zip(sorted(unique),sorted(unique)[1:])),'generated_to_sampled_feedback_ms':stats(latencies),'clock_envelope_half_width_ms':(hi-lo)/2e6},indent=2))
