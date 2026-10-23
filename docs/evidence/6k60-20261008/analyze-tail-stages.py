"""Join exact frame IDs across producer publication and presentation feedback.

CPU upload duration is a subset of post-publication time, not an extra stage.
No sum of independently sampled percentiles and no photon-latency claim.
"""
import json,re,statistics,sys
from pathlib import Path
start,end,host,guest=map(Path,sys.argv[1:])
cals=[json.loads(p.read_text())['best'] for p in (start,end)]
lo=min(c['offset_low_ns'] for c in cals);hi=max(c['offset_high_ns'] for c in cals);offset=(lo+hi)/2
begin=min(c['host_start_ns'] for c in cals);finish=max(c['host_end_ns'] for c in cals)
def fields(line):return {k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',line)}
captures={};published={};uploaded={};host_stages={}
for line in guest.read_text().splitlines():
    d=fields(line)
    if line.startswith('profile_shared_capture ') and (d['width'],d['height'])==(6144,3456):captures[(int(d['pts']),int(d['id']))]=d
    if line.startswith('profile_output '):published[int(d['pts'])]=d
for line in host.read_text().splitlines():
    m=re.search(r'ivshmem-host-frame stage=(\w+) pts=(\d+) monotonic_ns=(\d+)',line)
    if m:host_stages.setdefault(int(m[2]),{})[m[1]]=int(m[3])
    if 'ivshmem-cuda-upload ' in line:
        d=fields(line);uploaded[int(d['pts'])]=sum(d[k] for k in ('map_ms','array_ms','copy_ms','unmap_ms'))
first_capture=min((c['capture'] for c in captures.values()),default=0)
rows=[];seen=set();missing=outside=0
for line in host.read_text().splitlines():
    if 'ivshmem-clock-sample output=DP-4 ' not in line:continue
    d=fields(line);pts=int(d['atlas_submit_qpc_100ns']);ident=int(d['id']);when=d['presented_monotonic_ns']
    if d['clock_id']!=1 or not begin<=when<=finish:outside+=1;continue
    cap=captures.get((pts,ident));pub=published.get(pts)
    if cap is None or pub is None:missing+=1;continue
    key=(ident,cap['capture'])
    if key in seen or cap['capture']*100+offset<begin:continue
    seen.add(key)
    capture_to_publish=(pub['write_end']-cap['capture'])/10000
    publish_to_present=(when-pub['write_end']*100-offset)/1e6
    rows.append(dict(pts=pts,capture_elapsed_s=(cap['capture']-first_capture)/1e7,capture_to_publish_ms=capture_to_publish,publish_to_present_ms=publish_to_present,total_ms=capture_to_publish+publish_to_present,upload_subset_ms=uploaded.get(pts)))
    h=host_stages.get(pts,{})
    if all(k in h for k in ('ready','accept_begin','accept_end')):
        rows[-1].update(publish_to_ready_ms=(h['ready']-pub['write_end']*100-offset)/1e6,queue_ms=(h['accept_begin']-h['ready'])/1e6,accept_ms=(h['accept_end']-h['accept_begin'])/1e6,submit_to_present_ms=(when-h['accept_end'])/1e6)
def stats(v):
    v=sorted(x for x in v if x is not None)
    return {'n':len(v),'mean':statistics.mean(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,len(v)*95//100)],'max':v[-1]} if v else {'n':0}
def summary(rs):return {k:stats([r.get(k) for r in rs]) for k in ('total_ms','capture_to_publish_ms','publish_to_present_ms','upload_subset_ms','publish_to_ready_ms','queue_ms','accept_ms','submit_to_present_ms')}
print(json.dumps({'scope':'6K DP-4 unique sampled captures; post-publication includes transport, receiver and compositor; upload is a subset; not photon','clock_envelope_half_width_ms':(hi-lo)/2e6,'missing':missing,'outside':outside,'all':summary(rows),'over_33p3ms':summary([r for r in rows if r['total_ms']>1000/30]),'worst_10':sorted(rows,key=lambda r:r['total_ms'],reverse=True)[:10]},indent=2))
