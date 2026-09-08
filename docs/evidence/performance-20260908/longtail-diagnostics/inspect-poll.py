from pathlib import Path
import sys,bisect,re,json
sys.path.insert(0,'tools')
from profile_atlas_timeline import rows,numbers,stats
p=Path('/tmp/viewflow-integrated-pair');label=sys.argv[1] if len(sys.argv)>1 else '4k-longtail-poll';s=(p/f'source-{label}.log').read_text();r=(p/f'receiver-{label}.log').read_text()
clocks=[numbers(x) for x in rows(s,'atlas-clock-mapping ')];times=[x['source_ns'] for x in clocks]
st={int(x['frame']):numbers(x) for x in rows(s,'atlas-source-timing ')}
rx={int(x['frame']):numbers(x) for x in rows(r,'atlas-receive-stages ')}
ss=[numbers(x) for x in rows(s,'atlas-quic-sample ')];rr=[numbers(x) for x in rows(r,'atlas-quic-sample ')]
print('source sample gap',stats([x['gap_ns']/1e6 for x in ss]));print('receiver sample gap',stats([x['gap_ns']/1e6 for x in rr]))
wire=rows(s,'atlas-wire-timing '); valid_wire=[x for x in wire if all(k in x and x[k].isdigit() for k in ['frame','feedback_us','total_us'])]; print('rejected_wire',len(wire)-len(valid_wire))
for row in sorted(valid_wire,key=lambda x:int(x['feedback_us']),reverse=True)[:5]:
 f=int(row['frame']);a=st.get(f);b=rx.get(f)
 if not a or not b:continue
 cl=clocks[bisect.bisect_right(times,a['encoded_ns'])-1];offset=cl['remote_offset_ns'];start=a['encoded_ns'];end=start+int(row['total_us'])*1000
 print('FRAME',f,'feedback',row['feedback_us'],'rx_rel_ms',{k:round((v-start-offset)/1e6,2) for k,v in b.items() if k.endswith('_ns')})
 for label,data,off in [('source',ss,0),('receiver',rr,offset)]:
  selected=[x for x in data if start-6e6<=x['before_ns']-off<=end+5e6]
  print(label,'deltaTimes ms / tx / rx / queueSpace / rtt us')
  for x in selected: print([round((x['before_ns']-off-start)/1e6,2),x['udp_tx'],x['udp_rx'],x['send_buffer_space'],x['rtt_us']])
