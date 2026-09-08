from pathlib import Path
import json,collections,sys,struct
sys.path.insert(0,'tools');from profile_atlas_timeline import stats,rows,numbers
s=json.loads(Path('/tmp/viewflow-4k-ndis-network-socket-summary.json').read_text());groups=collections.defaultdict(list)
for line in Path('/tmp/viewflow-ndis-network.jsonl').read_text().splitlines():
 r=json.loads(line)
 if r['id']!=1001:continue
 b=bytes.fromhex(r['payload']['Fragment']);assert b[12:14]==b'\x08\x00' and b[23]==17 and b[14]&15==5
 assert b[26:30]==bytes([172,16,105,62]) and b[30:34]==bytes([172,16,105,70]) and int.from_bytes(b[36:38],'big')==49073
 assert r['payload']['MiniportIfIndex']=='12';layer=int(r['payload']['LowerIfIndex']);groups[layer].append({'qpc':r['qpc'],'size':int.from_bytes(b[38:40],'big')-8,'fragment':b.hex()})
assert set(groups)=={12,16,17,18}
for g in groups.values():g.sort(key=lambda r:r['qpc'])
base=groups[12];assert len({r['fragment'] for r in base})==len(base),'duplicate truncated packet identities'
for layer,g in groups.items():assert [r['fragment'] for r in g]==[r['fragment'] for r in base],('layer order/packet identity',layer,len(g),len(base))
kernel=[json.loads(l) for l in Path('/tmp/viewflow-ndis-kernel.jsonl').read_text().splitlines()];kernel=[r for r in kernel if r['name']=='UdpIp/Recv' and r['payload']['dport']=='49073' and r['payload']['saddr']=='172.16.105.62'];kernel.sort(key=lambda r:r['qpc'])
text=Path('/tmp/viewflow-integrated-pair/receiver-4k-ndis-network.log').read_text();calls=[numbers(r)|{'op':r['op'],'status':r['status']} for r in rows(text,'atlas-socket ')];ok=[r for r in calls if r['op']=='recv_syscall' and r['status']=='ok'];ok.sort(key=lambda r:r['before_ns'])
assert len(base)==len(kernel)==len(ok),(len(base),len(kernel),len(ok))
assert [r['size'] for r in base]==[int(r['payload']['size']) for r in kernel]==[r['bytes'] for r in ok],'ordered byte lengths differ'
a=s['anchors']['receiver'];freq=a['frequency'];origin=a['ticks']*1e9/freq-(a['before_ns']+a['after_ns'])/2
result={'counts':{str(k):len(v) for k,v in groups.items()}|{'kernel':len(kernel),'socket':len(ok)},'ndis_events_lost':json.loads(Path('/tmp/viewflow-ndis-network.jsonl.summary.json').read_text())['events_lost'],'kernel_events_lost':json.loads(Path('/tmp/viewflow-ndis-kernel.jsonl.summary.json').read_text())['events_lost'],'ndis_packet_identity_and_order_match':True,'all_ordered_lengths_match':True,'stage_ms':{},'slow_frames':[]}
assert result['ndis_events_lost']==0 and result['kernel_events_lost']==0
for left,right in [(12,16),(16,17),(17,18)]:
 ds=[(b['qpc']-a['qpc'])*1000/freq for a,b in zip(groups[left],groups[right])];assert min(ds)>=0;result['stage_ms'][f'{left}->{right}']=stats(ds)
for name,ds in [('18->kernel',[(k['qpc']-r['qpc'])*1000/freq for r,k in zip(groups[18],kernel)]),('12->kernel',[(k['qpc']-r['qpc'])*1000/freq for r,k in zip(base,kernel)]),('kernel->socket',[(r['after_ns']+origin-k['qpc']*1e9/freq)/1e6 for k,r in zip(kernel,ok)])]:
 assert min(ds)>-.02,(name,min(ds));result['stage_ms'][name]=stats(ds)
for f in s['slow_frames']:
 call=f['roles']['receiver']['calls'][0];encoded_socket_ns=call['before_ns']-call['relative_ms']*1e6
 frame={'frame':f['frame'],'feedback_ms':f['feedback_ms'],'groups':{}}
 for name,g in list(groups.items())+[('kernel',kernel)]:
  selected=[dict(r,relative_ms=(r['qpc']*1e9/freq-origin-encoded_socket_ns)/1e6) for r in g if -2<=(r['qpc']*1e9/freq-origin-encoded_socket_ns)/1e6<=f['feedback_ms']+2]
  batches=[];batch=[]
  for r in selected:
   if batch and r['relative_ms']-batch[-1]['relative_ms']>1:
    batches.append({'begin_ms':batch[0]['relative_ms'],'end_ms':batch[-1]['relative_ms'],'packets':len(batch)});batch=[]
   batch.append(r)
  if batch:batches.append({'begin_ms':batch[0]['relative_ms'],'end_ms':batch[-1]['relative_ms'],'packets':len(batch)})
  frame['groups'][str(name)]=batches
 result['slow_frames'].append(frame)
 print('FRAME',frame['frame'],frame['feedback_ms'])
 for k,v in frame['groups'].items():print(k,v)
print(json.dumps({k:v for k,v in result.items() if k!='slow_frames'},indent=2))
Path('/tmp/viewflow-ndis-network-correlation.json').write_text(json.dumps(result,indent=2)+'\n')
