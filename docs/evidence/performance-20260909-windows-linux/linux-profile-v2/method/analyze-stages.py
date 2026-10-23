from pathlib import Path
import re,statistics,json,math
b=Path(__file__).resolve().parents[2];p=b/'transport/runs/linux-profile-v2-a1';lines=p.joinpath('native-profile.log').read_text().splitlines()
keys={'profile_present':{'pts','begin','submit','decoded','upload_begin','uploaded','alpha','swapped'},'profile_gpu_upload':{'pts','begin','mapped','copied','end'},'profile_received':{'pts','at'},'profile_geometry':{'begin','end'}}
data={k:[{a:int(v) for a,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in lines if line.startswith(k+' ')] for k in keys}
for k,rows in data.items():assert rows and all(keys[k]<=r.keys() for r in rows)
rx={r['pts']:r['at'] for r in data['profile_received']};start=data['profile_present'][0]['begin']+3_000_000_000
present=[r for r in data['profile_present'] if r['begin']>=start];gpu=[r for r in data['profile_gpu_upload'] if r['begin']>=start];geometry=[r for r in data['profile_geometry'] if r['begin']>=start];out={}
def report(k,values):
 a=sorted(values);assert a[0]>=0;out[k]={'n':len(a),'median_ms':statistics.median(a),'p95_ms':a[math.ceil(.95*len(a))-1],'max_ms':max(a)}
for k,a,z in [('decode','submit','decoded'),('upload','upload_begin','uploaded'),('alpha','uploaded','alpha'),('draw_swap','alpha','swapped'),('accept_total','begin','swapped')]:report(k,[(r[z]-r[a])/1e6 for r in present])
assert all(r['pts'] in rx for r in present)
report('receive_to_accept',[(r['begin']-rx[r['pts']])/1e6 for r in present]);report('geometry',[(r['end']-r['begin'])/1e6 for r in geometry])
for k,a,z in [('cuda_map','begin','mapped'),('cuda_copy','mapped','copied'),('cuda_unmap','copied','end')]:report(k,[(r[z]-r[a])/1e6 for r in gpu])
result={'warmup_ns':3_000_000_000,'scope':'CPU wall times, including API synchronization; not independent hardware GPU stage timings. Swap completion is submission, not physical scanout.','stages':out};(p/'linux-stages.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(out,indent=2));s=json.loads((p/'summary.json').read_text());print('end-to-end',s['desktop_distinct_hz'],s['latency_high_ms'])
