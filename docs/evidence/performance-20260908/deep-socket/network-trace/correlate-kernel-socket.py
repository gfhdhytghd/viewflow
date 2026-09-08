from pathlib import Path
import json,sys,bisect,collections
sys.path.insert(0,'tools');from profile_atlas_timeline import stats,rows,numbers
s=json.loads(Path('/tmp/viewflow-4k-deep-network-socket-summary.json').read_text());events=[json.loads(l) for l in Path('/tmp/viewflow-deep-network.jsonl').read_text().splitlines()]
a=s['anchors']['receiver'];qpc_socket_origin=a['ticks']*1e9/a['frequency']-(a['before_ns']+a['after_ns'])/2
rx=[dict(r,socket_ns=r['qpc']*1e9/a['frequency']-qpc_socket_origin) for r in events if r['name']=='UdpIp/Recv' and r['payload']['dport']=='49073' and r['payload']['saddr']=='172.16.105.62']
text=Path('/tmp/viewflow-integrated-pair/receiver-4k-deep-network.log').read_text();calls=[numbers(r)|{'op':r['op'],'status':r['status']} for r in rows(text,'atlas-socket ')];ok=[r for r in calls if r['op']=='recv_syscall' and r['status']=='ok']
# A controlled single UDP connection; compare full ordered byte-length sequences, never assume count equality is sufficient.
assert len(rx)==len(ok),(len(rx),len(ok));assert all(int(r['payload']['size'])==c['bytes'] for r,c in zip(rx,ok));deltas=[(c['after_ns']-r['socket_ns'])/1e6 for r,c in zip(rx,ok)]
result={'events_lost':json.loads(Path('/tmp/viewflow-deep-network.jsonl.summary.json').read_text())['events_lost'],'kernel_rx_count':len(rx),'successful_receive_calls':len(ok),'ordered_lengths_match':True,'kernel_event_to_receive_completion_ms':stats(deltas),'clock_anchor_width_us':(a['after_ns']-a['before_ns'])/1000,'slow_frames':[]}
assert result['events_lost']==0
for f in s['slow_frames']:
 data=f['roles']['receiver'];first=data['calls'][0];encoded_socket_ns=first['before_ns']-first['relative_ms']*1e6
 selected=[dict(r,relative_ms=(r['socket_ns']-encoded_socket_ns)/1e6) for r in rx if -2<=(r['socket_ns']-encoded_socket_ns)/1e6<=f['feedback_ms']+2]
 groups=[];g=[]
 for r in selected:
  if g and r['relative_ms']-g[-1]['relative_ms']>1:
   groups.append({'begin_ms':g[0]['relative_ms'],'end_ms':g[-1]['relative_ms'],'datagrams':len(g),'bytes':sum(int(x['payload']['size']) for x in g)});g=[]
  g.append(r)
 if g:groups.append({'begin_ms':g[0]['relative_ms'],'end_ms':g[-1]['relative_ms'],'datagrams':len(g),'bytes':sum(int(x['payload']['size']) for x in g)})
 result['slow_frames'].append({'frame':f['frame'],'feedback_ms':f['feedback_ms'],'kernel_groups':groups,'socket_groups':[r for r in data['groups'] if r['op']=='recv'],'pending_intervals':data['pending_intervals']})
 print('FRAME',f['frame'],f['feedback_ms']);print('KERNEL',groups[:25]);print('SOCKET',[r for r in data['groups'] if r['op']=='recv'][:25])
print({k:v for k,v in result.items() if k!='slow_frames'})
Path('/tmp/viewflow-deep-network-kernel-correlation.json').write_text(json.dumps(result,indent=2)+'\n')
