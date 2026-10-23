"""Match actual CPU copy/selection QPC stamps, not WGC timestamp offsets."""
import collections,json,re,sys,statistics
from pathlib import Path
captures=collections.defaultdict(list);selected=[]
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line.startswith(('profile_capture ','profile_shared_capture ')):continue
    d={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
    if d.get('width')!=6144 or d.get('height')!=3456:continue
    key=(d['id'],d['capture'])
    if line.startswith('profile_capture '):captures[key].append(d['copied'])
    else:selected.append((key,d['enqueued']))
values=[];ambiguous=missing=0
for key,enqueued in selected:
    candidates=captures.get(key,[])
    if not candidates:missing+=1
    elif len(candidates)!=1:ambiguous+=1
    else:values.append((enqueued-candidates[0])/10000)
values.sort()
print(json.dumps({'scope':'CPU copied-to-enqueued QPC; unique id plus WGC stamp match; copied QPC captured after source state publication; newer builds record it before unlock/notification and emit log after unlock',
    'missing':missing,'ambiguous':ambiguous,'copied_to_enqueue_ms':{'n':len(values),'p50':statistics.median(values),'p95':values[min(len(values)-1,len(values)*95//100)],'min':values[0],'max':values[-1]} if values else None},indent=2))
