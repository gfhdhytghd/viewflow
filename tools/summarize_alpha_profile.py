#!/usr/bin/env python3
"""Join opt-in alpha copy/compare costs by exact source frame identity."""
import argparse,collections,json,re,statistics
from pathlib import Path

def stats(v):
 v=sorted(v)
 return {'n':len(v),'median':statistics.median(v),'p95':v[min(len(v)-1,int(len(v)*.95))],'sum':sum(v)} if v else {'n':0}

def summarize(text, expected=None):
 data=collections.defaultdict(lambda:collections.defaultdict(list));rejected=collections.Counter()
 for line in text.splitlines():
  if line.startswith('alpha-copy-profile '):
   row=dict(re.findall(r'(\w+)=([^\s]+)',line));required=['frame','stage','bytes','start_ns','end_ns','cpu_ns','clocks_valid']
   if not all(k in row for k in required) or any(not re.fullmatch(r'\d+',row[k]) for k in required if k!='stage'):rejected['malformed_copy']+=1;continue
   if row['clocks_valid']!='1':rejected['invalid_copy_clock']+=1;continue
   frame=int(row['frame']);wall=int(row['end_ns'])-int(row['start_ns']);cpu=int(row['cpu_ns']);stage=row['stage']
  elif line.startswith('alpha-cache-profile '):
   row=dict(re.findall(r'(\w+)=([^\s]+)',line));required=['frame','bytes','wall_ns','cpu_ns','cpu_valid','hit']
   if not all(k in row for k in required) or any(not re.fullmatch(r'\d+',row[k]) for k in required if k not in ['cpu_valid','hit']):rejected['malformed_cache']+=1;continue
   if row['cpu_valid']!='true':rejected['invalid_cache_clock']+=1;continue
   frame=int(row['frame']);wall=int(row['wall_ns']);cpu=int(row['cpu_ns']);stage='cache_compare'
  else:continue
  if frame<4:continue
  if wall<0 or cpu<0:rejected['negative_duration']+=1;continue
  data[stage][frame].append((wall/1e6,cpu/1e6,int(row['bytes'])))
 stages={};valid={}
 for stage,frames in data.items():
  valid[stage]={f:v[0] for f,v in frames.items() if len(v)==1}
  rejected['duplicate_'+stage]=sum(len(v)!=1 for v in frames.values())
  v=list(valid[stage].values());stages[stage]={'wall_ms':stats([r[0] for r in v]),'thread_cpu_ms':stats([r[1] for r in v]),'bytes':sorted({r[2] for r in v})}
 expected=expected or ['pinned_to_vector','cabi_to_rust','cache_compare']
 common=set.intersection(*(set(valid.get(k,{})) for k in expected))
 totals=[(sum(valid[k][f][0] for k in expected),sum(valid[k][f][1] for k in expected)) for f in sorted(common)]
 return {'expected_stages':expected,'stages':stages,'rejected':dict(rejected),'same_frame_total_wall_ms':stats([a for a,b in totals]),'same_frame_total_thread_cpu_ms':stats([b for a,b in totals]),'scope':'Only the selected nonoverlapping operations; not GPU readback, NVENC, total process CPU, or memory allocation elsewhere.'}
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('--output',type=Path,required=True);p.add_argument('--stages',help='Comma-separated stages to join; default includes both copies and comparison');a=p.parse_args();result=summarize(a.source.read_text(),a.stages.split(',') if a.stages else None);a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
