from pathlib import Path
import json,sys,collections
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
raw=Path('/tmp/viewflow-integrated-pair');results=[]
labels=sys.argv[1:]
for label in labels:
 s=(raw/f'source-{label}.log').read_text();r=(raw/f'receiver-{label}.log').read_text();_,stages=t.export(s,r,'')
 native=[t.numbers(x) for x in t.rows(r,'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
 assert len(native)>2 and len(native)==len({x['frame'] for x in native})
 wires=t.rows(s,'atlas-wire-timing ');valid=[t.numbers(x) for x in wires if all(x.get(k,'').isdigit() for k in ['frame','feedback_us','total_us','packets']) and int(x['frame'])>=30]
 vals=[x['feedback_us']/1000 for x in valid]
 anchors={name:t.numbers(t.rows(text,'atlas-socket-anchor ')[0]) for name,text in [('source',s),('receiver',r)]}
 traceends={name:t.numbers(t.rows(text,'atlas-socket-end ')[0]) for name,text in [('source',s),('receiver',r)]}
 for role,text in [('source',s),('receiver',r)]:
  assert traceends[role]['omitted']==0 and traceends[role]['records']==len(t.rows(text,'atlas-socket '))
 sends=[dict(x,**t.numbers(x)) for x in t.rows(s,'atlas-socket ') if x['op']=='send' and x['status']=='ok']
 groups=[];batch=[]
 for x in sends:
  if batch and x['before_ns']-batch[-1]['before_ns']>1e6:
   groups.append({'datagrams':sum(x['datagrams'] for x in batch),'span_ms':(batch[-1]['after_ns']-batch[0]['before_ns'])/1e6,'begin_ns':batch[0]['before_ns']});batch=[]
  batch.append(x)
 if batch:groups.append({'datagrams':sum(x['datagrams'] for x in batch),'span_ms':(batch[-1]['after_ns']-batch[0]['before_ns'])/1e6,'begin_ns':batch[0]['before_ns']})
 source_ns={int(x['frame']):t.numbers(x)['encoded_ns'] for x in t.rows(s,'atlas-source-timing ')}
 origin=anchors['source']['ticks']*1e9/anchors['source']['frequency']-(anchors['source']['before_ns']+anchors['source']['after_ns'])/2
 slow=[]
 for w in sorted(valid,key=lambda x:x['feedback_us'],reverse=True)[:8]:
  begin=source_ns[w['frame']];end=begin+w['total_us']*1000
  ss=[x for x in sends if begin<=x['before_ns']+origin<end]
  slow.append(dict(**w,successful_connection_socket_sends=len(ss),connection_socket_send_span_ms=(ss[-1]['after_ns']-ss[0]['before_ns'])/1e6 if ss else None))
 row=dict(label=label,source_transport='unchanged; external ESRV scheduling control',native_commit_hz=(len(native)-1)*native[0]['frequency']/(native[-1]['qpc']-native[0]['qpc']),feedback_ms=t.stats(vals),feedback_over_33ms=sum(x>33.333333 for x in vals),feedback_over_100ms=sum(x>100 for x in vals),feedback_excess_over_33ms_sum=sum(max(x-33.333333,0) for x in vals),wall_stage_ms=stages['wall_stage_ms'],trace_counts=traceends,source_send_group_sizes=t.stats([x['datagrams'] for x in groups]),source_send_group_gap_ms=t.stats([(b['begin_ns']-a['begin_ns'])/1e6 for a,b in zip(groups,groups[1:])]),source_successful_socket_calls=len(sends),source_udp_datagrams=sum(x['datagrams'] for x in sends),slow_frames=slow)
 results.append(row);Path('/tmp/'+label+'-esrv-stages.json').write_text(json.dumps(stages,indent=2)+'\n')
 print(label,'Hz',row['native_commit_hz'],'feedback',row['feedback_ms'],'tails',row['feedback_over_33ms'],row['feedback_over_100ms'],'excess',row['feedback_excess_over_33ms_sum'],'group',row['source_send_group_sizes'])
Path('/tmp/viewflow-esrv-control-comparison.json').write_text(json.dumps(results,indent=2)+'\n')
