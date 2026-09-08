from pathlib import Path
import sys,bisect,json
sys.path.insert(0,'tools')
from profile_atlas_timeline import rows,numbers,stats,export
label=sys.argv[1] if len(sys.argv)>1 else '4k-socket-boundary';p=Path('/tmp/viewflow-integrated-pair')
s=(p/f'source-{label}.log').read_text();r=(p/f'receiver-{label}.log').read_text()
a={name:numbers(rows(text,'atlas-socket-anchor ')[0]) for name,text in [('source',s),('receiver',r)]}
b=numbers(rows(r,'atlas-receiver-clock-anchor ')[0]);freq=b['frequency'];clock_mid=(b['before_ns']+b['after_ns'])/2
origins={'source':a['source']['ticks']*1e9/a['source']['frequency']-(a['source']['before_ns']+a['source']['after_ns'])/2,
'receiver':(a['receiver']['ticks']-b['qpc'])*1e9/freq+clock_mid-(a['receiver']['before_ns']+a['receiver']['after_ns'])/2}
traces={role:sorted([dict(x, **numbers(x)) for x in rows(text,'atlas-socket ')],key=lambda x:x['before_ns']) for role,text in [('source',s),('receiver',r)]}
ends={role:numbers(rows(text,'atlas-socket-end ')[0]) for role,text in [('source',s),('receiver',r)]}
for role in ends:
 assert ends[role]['omitted']==0 and ends[role]['records']==len(traces[role]),(role,ends[role],len(traces[role]))
clocks=[numbers(x) for x in rows(s,'atlas-clock-mapping ')];times=[x['source_ns'] for x in clocks]
st={int(x['frame']):numbers(x) for x in rows(s,'atlas-source-timing ')}
rx={int(x['frame']):numbers(x) for x in rows(r,'atlas-receive-stages ')}
wire=rows(s,'atlas-wire-timing ');valid=[numbers(x) for x in wire if all(k in x and x[k].isdigit() for k in ['frame','feedback_us','total_us'])]
result={'anchors':a,'receiver_clock_anchor':b,'origins':origins,'counts':ends,'rejected_wire':len(wire)-len(valid),'slow_frames':[]}
for row in sorted(valid,key=lambda x:x['feedback_us'],reverse=True)[:8]:
 f=row['frame'];start=st[f]['encoded_ns'];i=bisect.bisect_right(times,start)-1;assert i>=0;cl=clocks[i];offset=cl['remote_offset_ns'];end=start+row['total_us']*1000
 out={'frame':f,'feedback_ms':row['feedback_us']/1000,'packets':row['packets'],'receiver_relative_ms':{k:round((v-offset-start)/1e6,3) for k,v in rx[f].items() if k.endswith('_ns')},'roles':{}}
 for role,data in traces.items():
  origin=origins[role]-(offset if role=='receiver' else 0)
  selected=[dict(x,relative_ms=(x['before_ns']+origin-start)/1e6,duration_us=(x['after_ns']-x['before_ns'])/1000) for x in data if start-2e6 <= x['before_ns']+origin <= end+2e6]
  groups=[]
  for op in ['send','recv']:
   hits=[x for x in selected if x['op']==op and x['status']=='ok'];batch=[]
   for x in hits:
    if batch and x['relative_ms']-batch[-1]['relative_ms']>1:
     groups.append(dict(op=op,begin_ms=batch[0]['relative_ms'],end_ms=(batch[-1]['after_ns']+origin-start)/1e6,datagrams=sum(x['datagrams'] for x in batch),bytes=sum(x['bytes'] for x in batch)));batch=[]
    batch.append(x)
   if batch:groups.append(dict(op=op,begin_ms=batch[0]['relative_ms'],end_ms=(batch[-1]['after_ns']+origin-start)/1e6,datagrams=sum(x['datagrams'] for x in batch),bytes=sum(x['bytes'] for x in batch)))
  states={f'{op}/{state}':sum(x['op']==op and x['status']==state for x in selected) for op in ['send','recv','writable'] for state in ['ok','pending','would_block','error']}
  out['roles'][role]={'groups':sorted(groups,key=lambda x:x['begin_ms']),'states':states,'calls':selected,'duration_us':stats([x['duration_us'] for x in selected])}
 result['slow_frames'].append(out)
 print('FRAME',f,'feedback',out['feedback_ms'],'RX',out['receiver_relative_ms'])
 for role,data in out['roles'].items():
  print(role,data['states'],'call time',data['duration_us'])
  for x in data['groups']:print('  ',x)
result['socket_calls']={role:{op:{'durations_us':stats([(x['after_ns']-x['before_ns'])/1000 for x in data if x['op']==op]),'states':{state:sum(x['op']==op and x['status']==state for x in data) for state in ['ok','pending','would_block','error']}} for op in ['send','recv','writable']} for role,data in traces.items()}
Path('/tmp/viewflow-'+label+'-socket-summary.json').write_text(json.dumps(result,indent=2)+'\n')
