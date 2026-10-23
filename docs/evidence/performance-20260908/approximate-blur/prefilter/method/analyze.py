from pathlib import Path
import gzip,json,csv,io
import numpy as np
from PIL import Image,ImageDraw
b=Path(__file__).resolve().parent.parent
raw=(b/'method/probe.csv').read_text();assert '# exit=0' in raw
rows=list(csv.DictReader(io.StringIO('\n'.join(l for l in raw.splitlines() if not l.startswith('#')))))
assert len(rows)==500 and all(int(r['frequency'])>0 and int(r['disjoint'])==0 for r in rows)
names=['Balanced','Quarter Linear','Quarter Multisample','Eighth Multisample','Quarter Anisotropic'];images=[];result=[]
base=None
for mode in range(5):
 raw=gzip.decompress((b/'pixels'/f'probe-mode{mode}.bgra.gz').read_bytes());assert len(raw)==3840*2160*4
 pixels=np.frombuffer(raw,dtype=np.uint8).reshape(2160,3840,4)
 if base is None:base=pixels.astype(np.int16)
 diff=np.abs(pixels.astype(np.int16)-base);rgb=diff[:,:,:3]
 v=sorted(float(r['gpu_ms']) for r in rows if int(r['mode'])==mode and int(r['sample'])>=10);assert len(v)==80
 image=Image.fromarray(pixels[:,:,[2,1,0,3]],'RGBA').convert('RGB');image.save(b/'pixels'/f'mode{mode}.png');images.append(image)
 result.append(dict(mode=mode,name=names[mode],n=len(v),gpu_ms=dict(median=float(np.median(v)),p95=v[int(len(v)*.95)],min=v[0],max=v[-1]),rgb_diff=dict(max=int(rgb.max()),mean=float(rgb.mean()),p95=float(np.percentile(rgb,95)),over2=int((rgb>2).sum()),over8=int((rgb>8).sum())),alpha_diff_max=int(diff[:,:,3].max())))
canvas=Image.new('RGB',(5*384,280),(24,26,30));draw=ImageDraw.Draw(canvas)
for mode,im in enumerate(images):
 draw.text((mode*384+8,7),names[mode],fill='white');draw.text((mode*384+8,24),f"{result[mode]['gpu_ms']['median']:.3f} ms",fill='white')
 canvas.paste(im.resize((384,216),Image.Resampling.LANCZOS),(mode*384,55))
canvas.save(b/'pixels/overview.png')
canvas=Image.new('RGB',(5*384,820),(24,26,30));draw=ImageDraw.Draw(canvas)
for mode,im in enumerate(images):
 draw.text((mode*384+8,7),names[mode],fill='white')
 canvas.paste(im.crop((1664,864,2048,1248)),(mode*384,28))
 canvas.paste(im.crop((0,0,384,384)),(mode*384,432))
canvas.save(b/'pixels/center-and-edge.png')
(b/'summary.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
