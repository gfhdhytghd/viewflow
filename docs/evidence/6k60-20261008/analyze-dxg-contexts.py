"""Version-specific ETW lifecycle and DMA pairing; no hardware timestamp claim."""
import re,struct,json,collections,statistics,sys
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
processes={d['Id']:d['ProcessName'] for d in json.loads((r/f'{t}-processes.json').read_text(encoding='utf-8-sig'))}
devices={};contexts={};active={};queued={};waits=collections.defaultdict(list);dur=collections.defaultdict(list);submitters=collections.defaultdict(collections.Counter)
for line in (r/f'{t}-dxg-raw.txt').open():
 m=re.match(r'event id=(\d+) opcode=\d+ version=(\d+) pid=(\d+) tid=\d+ timestamp=(\d+) bytes=\d+ payload=(.*)',line)
 if not m:continue
 event,version,pid,ts=map(int,m.group(1,2,3,4));b=bytes.fromhex(m[5])
 if event in (27,29) and version==2 and len(b)>=28:
  devices[struct.unpack_from('<Q',b,20)[0]]=struct.unpack_from('<Q',b)[0]
 if event in (30,32) and version==0 and len(b)>=48:
  dev,node=struct.unpack_from('<QI',b);ctx=struct.unpack_from('<Q',b,40)[0];contexts[ctx]=(dev,node,devices.get(dev))
 if event==31 and version==0 and len(b)>=48:
  ctx=struct.unpack_from('<Q',b,40)[0];contexts.pop(ctx,None)
  for key in [k for k in queued if k[0]==ctx]:queued.pop(key)
 if event==178 and version==1 and len(b)>=16:
  ctx,kind,seq=struct.unpack_from('<QII',b);submitters[ctx][pid]+=1;queued[(ctx,seq)]=(ts,pid,kind)
 if event==175 and version==1 and len(b)>=32:
  ctx=struct.unpack_from('<Q',b)[0];kind=struct.unpack_from('<I',b,16)[0];seq=struct.unpack_from('<I',b,28)[0];active[(ctx,kind,seq)]=(ts,contexts.get(ctx))
  submission=queued.pop((ctx,seq),None)
  if submission and ts>=submission[0]:waits[(ctx,kind,contexts.get(ctx),submission[1],submission[2])].append((ts-submission[0])/10000)
 if event==176 and version==0 and len(b)>=28:
  ctx=struct.unpack_from('<Q',b)[0];kind=struct.unpack_from('<I',b,8)[0];seq,preempt=struct.unpack_from('<II',b,20);start=active.pop((ctx,kind,seq),None)
  if start is not None and not preempt and ts>=start[0]:dur[(ctx,kind,start[1])].append((ts-start[0])/10000)
rows=[]
for (ctx,kind,lifecycle),v in dur.items():
 v.sort();owner=lifecycle[2] if lifecycle else None
 rows.append({'context':hex(ctx),'packet_type':kind,'owner_pid':owner,'owner_name':processes.get(owner),'node':lifecycle[1] if lifecycle else None,'submitter_pids':dict(submitters[ctx]),'submitter_names':{str(p):processes.get(p) for p in submitters[ctx]},'n':len(v),'p50_ms':statistics.median(v),'p95_ms':v[int(len(v)*.95)],'max_ms':max(v)})
queue_rows=[]
for (ctx,kind,lifecycle,pid,queue_kind),v in waits.items():
 v.sort();queue_rows.append({'context':hex(ctx),'dma_packet_type':kind,'queue_packet_type':queue_kind,'owner_pid':lifecycle[2] if lifecycle else None,'submitter_pid':pid,'submitter_name':processes.get(pid),'n':len(v),'p50_ms':statistics.median(v),'p95_ms':v[int(len(v)*.95)],'max_ms':max(v)})
print(json.dumps({'scope':'ETW DMA intervals; lifecycle owner when present, submitter separately; no per-frame capture or GPU hardware timestamp attribution','queue_to_dma_start':sorted(queue_rows,key=lambda x:x['n'],reverse=True),'rows':sorted(rows,key=lambda x:x['n'],reverse=True)},indent=2))
