"""CPU-side CUDA/GL interop call durations, grouped by actual extent."""
import collections,json,re,statistics,sys
from pathlib import Path
groups=collections.defaultdict(list)
for line in Path(sys.argv[1]).read_text().splitlines():
    if 'ivshmem-cuda-upload ' not in line:continue
    d={k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',line)}
    groups[(int(d['width']),int(d['height']))].append(d)
def stats(values):
    v=sorted(values);return {'n':len(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,len(v)*95//100)],'max':v[-1]}
print(json.dumps({'scope':'CPU wall durations including implicit synchronization; not GPU execution; excludes host registration before map', 'extents':{f'{w}x{h}':{k:stats([d[k] for d in rows]) for k in ('map_ms','array_ms','copy_ms','unmap_ms')} for (w,h),rows in groups.items()}},indent=2))
