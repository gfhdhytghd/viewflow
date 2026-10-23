import re,json,statistics,collections
from pathlib import Path
r=Path(__file__).resolve().parent
g=(r/'physical-pixel-progressive9-generator.log').read_text()
generated=[int(x) for x in re.findall(r'motion-present sequence=\d+ generated=(\d+)',g)]
lo,hi=min(generated),max(generated)
starts={};durations=collections.defaultdict(list);sleeps=collections.Counter();unmatched=0
pairs={7:6,9:8,12:10,14:13,16:15}
for line in (r/'progressive9-dwm-raw.txt').read_text().splitlines():
 d={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
 if not lo<=d['timestamp']<=hi:continue
 key=(d['pid'],d['tid'])
 if d['id'] in pairs.values():starts[(key,d['id'])]=d['timestamp']
 if d['id'] in pairs:
  begin=starts.pop((key,pairs[d['id']]),None)
  if begin is None:unmatched+=1
  else:durations[str(pairs[d['id']])+'-'+str(d['id'])].append((d['timestamp']-begin)/10000)
 if d['id']==7:
  payload=bytes.fromhex(line.split('payload=')[1]);sleeps[str((int.from_bytes(payload[:4],'little'),int.from_bytes(payload[4:8],'little')))]+=1
out={}
for k,v in durations.items():
 v.sort();out[k]={'n':len(v),'p50_ms':statistics.median(v),'p95_ms':v[int(len(v)*.95)],'max_ms':v[-1]}
print(json.dumps({'scope':'DWM process thread spans inside fixture interval; not per-window capture latency; QPC10MHz verified in ETL header','pairs':{'6-7':'wait for vblank','8-9':'wait for work','10-12':'process frame','13-14':'render','15-16':'present'},'durations':out,'wait_vblank_sleep_flag_and_value':dict(sleeps),'unmatched_ends':unmatched},indent=2))
