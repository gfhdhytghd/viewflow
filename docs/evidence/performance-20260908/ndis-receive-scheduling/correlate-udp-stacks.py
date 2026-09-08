from pathlib import Path
import json,sys,bisect,collections
sys.path.insert(0,'tools');import profile_atlas_timeline as t
source=Path('/tmp/viewflow-integrated-pair/source-4k-udp-stack.log').read_text();receiver=Path('/tmp/viewflow-integrated-pair/receiver-4k-udp-stack.log').read_text()
stackdata=[json.loads(l) for l in Path('/tmp/viewflow-udp-stack.jsonl').read_text().splitlines()];delivery=sorted([x for x in stackdata if 'delivery'in x],key=lambda x:x['delivery']['qpc']);kernel=sorted([x for x in stackdata if x.get('name')=='UdpIp/Recv'],key=lambda x:x['qpc'])
meta=json.loads(Path('/tmp/viewflow-udp-stack.jsonl.summary.json').read_text());assert meta['events_lost']==0 and meta['missing']==0 and meta['selected']==len(delivery)==len(kernel)
for x,y in zip(delivery,kernel):
 p=x['delivery']['payload'];local=bytes.fromhex(p['LocalSockAddr']);remote=bytes.fromhex(p['RemoteSockAddr'])
 assert local[:2]==b'\x02\0' and int.from_bytes(local[2:4],'big')==49073 and local[4:8]==bytes([172,16,105,70]);assert remote[:2]==b'\x02\0' and remote[4:8]==bytes([172,16,105,62])
 assert int(p['NumBytes'])==int(y['payload']['size'])
 names={f['name'] for f in x['stack']};assert 'ndisDoPeriodicReceivesIndication' in names and 'ndisPeriodicReceivesWorker' in names
 x['path']='timer' if 'ndisPeriodicReceivesTimer' in names else 'worker'
 assert x['path']=='timer' or 'ndisReceiveWorkerThread' in names
anchor=t.numbers(t.rows(receiver,'atlas-receiver-clock-anchor ')[0]);frequency=anchor['frequency'];mid=(anchor['before_ns']+anchor['after_ns'])/2
clocks=[t.numbers(x) for x in t.rows(source,'atlas-clock-mapping ')];times=[x['source_ns'] for x in clocks]
st={int(x['frame']):t.numbers(x) for x in t.rows(source,'atlas-source-timing ')}
wire=[t.numbers(x) for x in t.rows(source,'atlas-wire-timing ') if x.get('feedback_us','').isdigit()]
slow=[]
for w in sorted(wire,key=lambda x:x['feedback_us'],reverse=True)[:8]:
 f=w['frame'];start=st[f]['encoded_ns'];i=bisect.bisect_right(times,start)-1;assert i>=0;cl=clocks[i];end=start+w['total_us']*1000
 assert end<=cl['source_ns']+cl['valid_remaining_ns']
 qs=anchor['qpc']+(start+cl['remote_offset_ns']-mid)*frequency/1e9
 qe=qs+w['total_us']*frequency/1e6
 selected=[dict(qpc=x['delivery']['qpc'],relative_ms=(x['delivery']['qpc']-qs)*1000/frequency,path=x['path'],bytes=int(x['delivery']['payload']['NumBytes']),tid=x['delivery']['tid']) for x in delivery if qs-2*frequency/1000<=x['delivery']['qpc']<=qe+2*frequency/1000]
 groups=[];b=[]
 for x in selected:
  if b and x['relative_ms']-b[-1]['relative_ms']>1:
   groups.append(dict(begin_ms=b[0]['relative_ms'],end_ms=b[-1]['relative_ms'],packets=len(b),paths=dict(collections.Counter(x['path'] for x in b)),tids=sorted({x['tid'] for x in b})));b=[]
  b.append(x)
 if b:groups.append(dict(begin_ms=b[0]['relative_ms'],end_ms=b[-1]['relative_ms'],packets=len(b),paths=dict(collections.Counter(x['path'] for x in b)),tids=sorted({x['tid'] for x in b})))
 slow.append(dict(frame=f,feedback_ms=w['feedback_us']/1000,media_packets=w['packets'],clock_uncertainty_ms=cl['uncertainty_ns']/1e6,source_clock_mapping_valid_until_ns=cl['source_ns']+cl['valid_remaining_ns'],source_end_ns=end,paths=dict(collections.Counter(x['path'] for x in selected)),groups=groups,deliveries=selected))
 print('FRAME',f,'feedback',w['feedback_us']/1000,'paths',slow[-1]['paths'])
 for g in groups:print(' ',g)
stackcounts=collections.Counter(tuple(f['module']+'!'+f['name'] for f in x['stack']) for x in delivery)
result=dict(events_lost=meta['events_lost'],missing_stacks=meta['missing'],matched_delivery_kernel_events=len(delivery),ordered_packet_lengths_match=True,paths=dict(collections.Counter(x['path'] for x in delivery)),delivery_to_kernel_ms=t.stats([(y['qpc']-x['delivery']['qpc'])*1000/frequency for x,y in zip(delivery,kernel)]),stacks=[dict(count=n,leaf_to_root=list(s)) for s,n in stackcounts.most_common()],slow_frames=slow)
Path('/tmp/viewflow-udp-stack-correlation.json').write_text(json.dumps(result,indent=2)+'\n');print('PATHS',result['paths'],'DELTA',result['delivery_to_kernel_ms'])
