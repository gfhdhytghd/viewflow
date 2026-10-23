"""Partition the same sampled frame; never subtract independent percentiles."""
import json,re,sys,statistics
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
stamps={};captures={};callbacks={};outputs={};early=set()
for line in (r/f'{t}-guest.log').read_text().splitlines():
 d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
 if line.startswith('profile_pixel_stamp '):stamps[d['pts']]=d
 if line.startswith('profile_shared_capture '):captures[d['pts']]=d
 if line.startswith('profile_capture ') and 'callback_qpc' in d:callbacks[(d['id'],d['capture'])]=d['callback_qpc']
 if line.startswith('profile_output '):outputs[d['pts']]=d
 if line.startswith('profile_shared_announced '):early.add(d['pts'])
cals=[json.loads((r/f'{t}-clock-{x}.json').read_text()) for x in ('start','end')]
lo=min(c['best']['offset_low_ns'] for c in cals);hi=max(c['best']['offset_high_ns'] for c in cals);offset=(lo+hi)/2
begin=min(c['best']['host_start_ns'] for c in cals);end=max(c['best']['host_end_ns'] for c in cals)
host_stages={}
for line in (r/f'{t}-host.log').read_text().splitlines():
 m=re.search(r'ivshmem-host-frame stage=(\w+) pts=(\d+) monotonic_ns=(\d+)',line)
 if m:host_stages.setdefault(int(m[2]),{})[m[1]]=int(m[3])
rows=[];seen=set()
for line in (r/f'{t}-host.log').read_text().splitlines():
 m=re.search(r'ivshmem-clock-sample output=(\S+) id=(\d+) atlas_submit_qpc_100ns=(\d+) presented_monotonic_ns=(\d+) clock_id=(\d+)',line)
 if not m or m[5]!='1':continue
 pts=int(m[3]);when=int(m[4]);s=stamps.get(pts);c=captures.get(pts);o=outputs.get(pts)
 if not s or not c or not o or c['id']!=int(m[2]) or not begin<=when<=end:continue
 if (c.get('width'),c.get('height'))!=(6144,3456):continue
 cb=callbacks.get((c['id'],c['capture']));key=(m[1],c['id'],s['sequence'])
 if cb is None or key in seen or s['generated_qpc_100ns']*100+offset<begin:continue
 seen.add(key)
 rows.append({'frame_identity':{'pts':pts,'sequence':s['sequence'],'source_protocol':'shm2' if pts in early else 'shm1'},'generation_to_callback_ms':(cb-s['generated_qpc_100ns'])/10000,'callback_to_write_ms':(o['write_end']-cb)/10000,'write_to_feedback_ms':(when-o['write_end']*100-offset)/1e6,'total_ms':(when-s['generated_qpc_100ns']*100-offset)/1e6})
 h=host_stages.get(pts,{})
 if all(k in h for k in ('ready','accept_begin','accept_end')):
  rows[-1].update(callback_to_host_accept_end_ms=(h['accept_end']-cb*100-offset)/1e6,generation_to_host_accept_end_ms=(h['accept_end']-s['generated_qpc_100ns']*100-offset)/1e6,write_to_ready_ms=(h['ready']-o['write_end']*100-offset)/1e6,host_queue_ms=(h['accept_begin']-h['ready'])/1e6,host_accept_ms=(h['accept_end']-h['accept_begin'])/1e6,host_accept_end_to_feedback_ms=(when-h['accept_end'])/1e6)
def stats(v):
 v=sorted(v);return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,int(len(v)*.95))],'min':v[0],'max':v[-1]} if v else {'n':0}
def summarize(selected):
 return {k:stats([d[k] for d in selected if k in d]) for k in sorted(set().union(*(d.keys() for d in selected))) if k!='frame_identity'} if selected else {}
print(json.dumps({'scope':'same pixel-identified frame partitions, actual atlas6144x3456, sampled software feedback not photon; protocol groups do not exclude startup from overall results','stages':summarize(rows),'by_protocol':{protocol:summarize([d for d in rows if d['frame_identity']['source_protocol']==protocol]) for protocol in sorted({d['frame_identity']['source_protocol'] for d in rows})},'rows':rows},indent=2))
