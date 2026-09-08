#!/usr/bin/env python3
"""Join DxgKrnl queue/DMA events by context and submission identity.

CPU queue -> DMA submission and DMA submission -> completion are distinct.
The latter includes hardware queue residence; it is NOT a GPU timestamp duration.
Reject preempted/multiply submitted records rather than fabricating execution.
"""
import argparse,collections,json,statistics
from pathlib import Path

def stats(v):
 v=sorted(v)
 return {'n':len(v),'median':statistics.median(v),'p95':v[min(len(v)-1,int(len(v)*.95))],'max':v[-1],'sum':sum(v)} if v else {'n':0}

def analyze(events,processes):
 names={r['pid']:r['name'] for r in processes};devices={};contexts={};changed=set()
 for r in events:
  p=r['payload'];n=r['name']
  if n in ['Device/Start','Device/DC_Start']:
   value=(int(p['hProcessId']),p['pDxgAdapter'])
   if p['hDevice'] in devices and devices[p['hDevice']]!=value:changed.add(('device',p['hDevice']))
   devices[p['hDevice']]=value
  if n in ['Context/Start','Context/DC_Start']:
   value=(p['hDevice'],p['NodeOrdinal'])
   if p['hContext'] in contexts and contexts[p['hContext']]!=value:changed.add(('context',p['hContext']))
   contexts[p['hContext']]=value
 starts=collections.defaultdict(list);dmas=collections.defaultdict(list);ends=collections.defaultdict(list);stops=collections.defaultdict(list)
 for r in events:
  p=r['payload'];n=r['name'];ctx=p.get('hContext')
  if n=='QueuePacket/Start' and ctx:starts[(ctx,p['SubmitSequence'])].append(r)
  elif n=='DmaPacket/Start' and ctx:dmas[(ctx,p['ulQueueSubmitSequence'])].append(r)
  elif n=='DmaPacket' and ctx:ends[(ctx,p['ulQueueSubmitSequence'])].append(r)
  elif n=='DmaPacket/Stop' and ctx:stops[(ctx,p['ulQueueSubmitSequence'])].append(r)
 summary=collections.defaultdict(lambda:collections.defaultdict(list));rejected=collections.Counter();packets=[]
 for key,rows in starts.items():
  ctx,sequence=key
  if not dmas[key]:rejected['no_dma_packet_sync_or_trace_edge']+=1;continue
  if len(rows)!=1 or len(dmas[key])!=1 or len(ends[key])!=1 or len(stops[key])!=1:rejected['incomplete_or_multiple']+=1;continue
  start,dma,end,stop=rows[0],dmas[key][0],ends[key][0],stops[key][0]
  if stop['payload'].get('bPreempted')!='False':rejected['preempted']+=1;continue
  if dma['payload']['uliSubmissionId']!=end['payload']['uliCompletionId']:rejected['dma_identity_mismatch']+=1;continue
  if not start['qpc']<=dma['qpc']<=end['qpc']:rejected['timestamp_order']+=1;continue
  if ctx not in contexts:rejected['missing_context']+=1;continue
  dev,node=contexts[ctx]
  if dev not in devices or ('context',ctx) in changed or ('device',dev) in changed:rejected['missing_or_changed_device']+=1;continue
  pid,adapter=devices[dev];name=names.get(pid,str(pid))
  if pid!=start['pid']:rejected['owner_pid_mismatch']+=1;continue
  # Events contain both QPC and ETW-relative ms; use the latter to avoid a frequency assumption.
  queue=dma['time_ms']-start['time_ms'];residence=end['time_ms']-dma['time_ms']
  label=f'{name} pid={pid} adapter={adapter} node={node}'
  summary[label]['cpu_queue_ms'].append(queue);summary[label]['hardware_residence_ms'].append(residence)
  packets.append(dict(process=name,pid=pid,adapter=adapter,node=node,context=ctx,sequence=sequence,submit_qpc=start['qpc'],dma_qpc=dma['qpc'],complete_qpc=end['qpc'],submit_ms=start['time_ms'],dma_ms=dma['time_ms'],complete_ms=end['time_ms'],cpu_queue_ms=queue,hardware_residence_ms=residence))
 return {'scope':'Matched nonpreempted single-DMA packets. Hardware residence includes queued time, not pure execution. No app-frame mapping is inferred.', 'rejected':dict(rejected),'changed_handles':list(changed),'process_engines':{k:{s:stats(v) for s,v in values.items()} for k,values in summary.items()}},packets

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('events',type=Path);p.add_argument('processes',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 events=[json.loads(l) for l in a.events.read_text().splitlines()];report,packets=analyze(events,json.loads(a.processes.read_text()));a.output.mkdir(parents=True,exist_ok=True)
 (a.output/'gpu-queue-summary.json').write_text(json.dumps(report,indent=2)+'\n');(a.output/'gpu-packets.json').write_text(json.dumps(packets))
 for k,v in report['process_engines'].items():
  if 'viewflow' in k or 'dwm ' in k:print(k,v)
 print('rejected',report['rejected'])
