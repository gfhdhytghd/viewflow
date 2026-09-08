from pathlib import Path
import json,re,sys,statistics
sys.path.insert(0,'tools')
from profile_atlas_timeline import rows,numbers
out={}
for name,label in [('active-nonblocking-v2','4k-active-interactive-udp-v2'),('active-blocking-v2','4k-active-interactive-udp-v2'),('paired-ecn0','4k-paired-ecn'),('paired-ecn2','4k-paired-ecn')]:
 p=Path('/tmp/viewflow-interactive-udp-'+name);d=json.loads((p/'source.json').read_text());log=(p/'probe-output.log').read_text();status=(p/'probe-status.log').read_text();assert 'probe_exit=0 watchdog=0' in status
 sessions=json.loads((p/'process-sessions.json').read_text());assert all(v['SessionId']==1 for v in sessions)
 freq=int(re.search(r'frequency=(\d+)',log).group(1));packets={}
 for b,s,q in re.findall(r'probe-packet batch=(\d+) sequence=(\d+) qpc=(\d+)',log):
  a=packets.setdefault(int(b),[]);a.append((int(s),int(q)))
 source=(Path('/tmp/viewflow-integrated-pair')/f'source-{label}.log').read_text();st={int(x['frame']):numbers(x) for x in rows(source,'atlas-source-timing ')};wire={int(x['frame']):numbers(x) for x in rows(source,'atlas-wire-timing ') if x.get('frame','').isdigit() and x.get('feedback_us','').isdigit()}
 bs=[]
 for b in d['batches']:
  ps=packets[b['batch']];assert len(ps)==b['packets'] and [v[0] for v in ps]==list(range(b['packets']))
  gaps=[dict(after_sequence=ps[i-1][0],gap_ms=(ps[i][1]-ps[i-1][1])*1000/freq) for i in range(1,len(ps)) if ps[i][1]-ps[i-1][1]>freq/1000]
  overlaps=[]
  for f,w in wire.items():
   if f not in st:continue
   begin=st[f]['encoded_ns'];end=begin+w['total_us']*1000
   if w['feedback_us']>33000 and begin<b['source_end_ns'] and end>b['source_begin_ns']:
    overlaps.append(dict(frame=f,encoded_ns=begin,wire_end_ns=end,feedback_ms=w['feedback_us']/1000,packets=w['packets']))
  bs.append(dict(**b,receiver_span_ms=(ps[-1][1]-ps[0][1])*1000/freq,gaps_over_1ms=gaps,overlapping_slow_video_frames=overlaps))
 assert set(packets)=={x['batch'] for x in bs}
 out[name]={k:v for k,v in d.items() if k!='batches'};out[name].update(batch_count=len(bs),received_packets=sum(x['packets'] for x in bs),rtt_median_ms=statistics.median(x['round_trip_us'] for x in bs)/1000,rtt_max_ms=max(x['round_trip_us'] for x in bs)/1000,batches=bs)
for name in ['paired-ecn0','paired-ecn2']:
 other='paired-ecn2' if name=='paired-ecn0' else 'paired-ecn0'
 for b in out[name]['batches']:
  b['overlapping_slow_other_probe']=[x['batch'] for x in out[other]['batches'] if x['round_trip_us']>33000 and b['source_begin_ns']<x['source_end_ns'] and b['source_end_ns']>x['source_begin_ns']]
Path('/tmp/viewflow-active-udp-summary.json').write_text(json.dumps(out,indent=2)+'\n')
for n,d in out.items():
 print(n,'batches',d['batch_count'],'packets',d['received_packets'],'rtt median/max',d['rtt_median_ms'],d['rtt_max_ms'])
 for b in d['batches']:
  if b['round_trip_us']>33000: print(' SLOW',b)
