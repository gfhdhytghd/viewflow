from pathlib import Path
import csv,json,hashlib,gzip
import numpy as np
from PIL import Image
p=Path(__file__).resolve().parents[1]
text=(p/'glass-kernel.csv').read_text()
assert text.rstrip().endswith('# exit=0')
rows=list(csv.DictReader(x for x in text.splitlines() if not x.startswith('#')))
assert len(rows)==420
names={0:'speed',1:'balanced',2:'quality'}
def stats(a):
 a=np.asarray(a,dtype=float)
 return {'n':len(a),'median':float(np.median(a)),'p95':float(np.quantile(a,.95,method='higher')),'max':float(np.max(a))}
result={'scope':'Offscreen full-image Direct2D GaussianBlur GPU interval; not HostBackdrop, DWM or remote latency','warmup_per_block':10,'blocks':[],'modes':{},'pixels':{}}
for block in range(6):
 r=[x for x in rows if int(x['block'])==block]
 assert [int(x['sample']) for x in r]==list(range(70))
 assert all(int(x['disjoint'])==0 and int(x['frequency'])>0 and float(x['gpu_ms'])>=0 for x in r)
 result['blocks'].append({'block':block,'mode':names[int(r[0]['mode'])],'gpu_ms':stats([float(x['gpu_ms']) for x in r[10:]])})
for mode,name in names.items():
 result['modes'][name]=stats([float(x['gpu_ms']) for x in rows if int(x['mode'])==mode and int(x['sample'])>=10])
images={m:np.frombuffer(gzip.decompress((p/f'glass-kernel-mode{m}.bgra.gz').read_bytes()),np.uint8).reshape(2160,3840,4) for m in names}
base=images[1].astype(np.int16)
for mode,name in names.items():
 a=images[mode];d=np.abs(a.astype(np.int16)-base)
 assert np.all(a[:,:,3]==255)
 result['pixels'][name]={'max_rgb_error':int(d[:,:,:3].max()),'mean_rgb_error':float(d[:,:,:3].mean()),'differing_rgb_channels':int(np.count_nonzero(d[:,:,:3])),'channels_error_over_2':int(np.count_nonzero(d[:,:,:3]>2)),'alpha_error':int(d[:,:,3].max())}
 Image.fromarray(a[:,:,[2,1,0]],'RGB').save(p/f'{name}.png')
# Zoomed center crop shows blur quality; same coordinates in each mode.
canvas=Image.new('RGB',(1024,384))
for i,m in enumerate([1,0]):canvas.paste(Image.fromarray(images[m][888:1272,1664:2176,[2,1,0]],'RGB'),(512*i,0))
canvas.save(p/'balanced-speed-crop.png')
(p/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
