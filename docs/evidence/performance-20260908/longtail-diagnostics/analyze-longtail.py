from pathlib import Path
import sys,bisect,json,re
sys.path.insert(0,'tools')
from profile_atlas_timeline import rows,numbers,stats,export
label=sys.argv[1] if len(sys.argv)>1 else '4k-longtail-stages'
p=Path('/tmp/viewflow-integrated-pair');s=(p/f'source-{label}.log').read_text();r=(p/f'receiver-{label}.log').read_text()
t,c=export(s,r,(p/f'desktop-{label}.log').read_text());Path('/tmp/'+label+'-stages.json').write_text(json.dumps(c,indent=2))
clocks=[numbers(x) for x in rows(s,'atlas-clock-mapping ')];times=[x['source_ns'] for x in clocks]
st={int(x['frame']):numbers(x) for x in rows(s,'atlas-source-timing ')}
rx={int(x['frame']):numbers(x) for x in rows(r,'atlas-receive-stages ')}
qs={}
for x in rows(s,'atlas-quic-state '):qs.setdefault(int(x['frame']),{})[x['stage']]=numbers(x)
wire=rows(s,'atlas-wire-timing '); valid_wire=[x for x in wire if all(k in x and x[k].isdigit() for k in ['frame','feedback_us','total_us'])]; print('rejected_wire',len(wire)-len(valid_wire))
slow=sorted(valid_wire,key=lambda x:int(x['feedback_us']),reverse=True)[:12]
for row in slow:
 f=int(row['frame']);a=st.get(f);b=rx.get(f)
 if not a or not b:continue
 cl=clocks[bisect.bisect_right(times,a['encoded_ns'])-1];encoded=a['encoded_ns']+cl['remote_offset_ns'];d={k:round((v-encoded)/1e6,3) for k,v in b.items() if k.endswith('_ns')}
 q=qs[f];begin=q['begin'];end=q['feedback_received'];d.update({k:end[k]-begin[k] for k in ['lost_packets','congestion_events','sent_packets','udp_rx']});d.update(rtt_start=begin['rtt_us'],rtt_end=end['rtt_us'],cwnd_start=begin['cwnd'],cwnd_end=end['cwnd'],feedback_us=row['feedback_us'],packet_count=row['packets'],encode_ms=round((a['encoded_ns']-a['encode_start_ns'])/1e6,3))
 print('frame',f,d)
 print('quic',q)
for x in sorted([x for x in s.splitlines() if x.startswith('GPU encode-detail')],key=lambda x:int(re.search(r'return:(\d+)',x)[1]),reverse=True)[:6]:print(x)
print('stages',c['wall_stage_ms'])
