from pathlib import Path
import subprocess,json
import numpy as np
results=[]
y,x=np.indices((256,256));bottom=np.zeros((256,256,3),dtype=np.int32);bottom[:,:,2]=np.where(x<128,np.where(y<128,255,128),0);bottom[:,:,1]=np.where(x>=128,np.where(y<128,255,128),0)
red=np.zeros_like(bottom);red[:,:,0]=255
composite=(red*(128/255)+bottom*(127/255)+.5).astype(np.int32)
for split in ['auto','four']:
 for mode in [1,2]:
  p=Path('/tmp/viewflow-nvenc-split-av1-'+split)/('mode-'+str(mode));m=json.loads(p.with_suffix('.json').read_text());w,h=m['width'],m['height'];ref=np.zeros((h,w,3),dtype=np.int32);alpha=np.zeros((h,w),dtype=np.uint8)
  for source,sx,sy,dx,dy,pw,ph in m['patches']:
   src=([bottom,red][source] if mode==1 else composite);ref[dy:dy+ph,dx:dx+pw]=src[sy:sy+ph,sx:sx+pw];alpha[dy:dy+ph,dx:dx+pw]=128 if mode==1 and source==1 else 255
  actual_alpha=np.frombuffer(p.with_suffix('.alpha').read_bytes(),dtype=np.uint8).reshape(h,w);assert np.array_equal(alpha,actual_alpha)
  run=subprocess.run(['ffmpeg','-v','error','-threads','1','-i',str(p.with_suffix('.av1')),'-frames:v','1','-threads','1','-pix_fmt','yuv420p','-f','rawvideo','pipe:1'],capture_output=True,check=True);b=np.frombuffer(run.stdout,dtype=np.uint8);assert b.size==w*h*3//2
  r,g,bl=ref.transpose(2,0,1);Y=((47*r+157*g+16*bl+128)>>8)+16;R=r.reshape(h//2,2,w//2,2).sum((1,3))//4;G=g.reshape(h//2,2,w//2,2).sum((1,3))//4;B=bl.reshape(h//2,2,w//2,2).sum((1,3))//4;U=((-26*R-87*G+112*B+128)>>8)+128;V=((112*R-102*G-10*B+128)>>8)+128
  refbytes=np.concatenate([Y.ravel(),U.ravel(),V.ravel()]);e=b.astype(np.int32)-refbytes;row=dict(split=split,mode=mode,width=w,height=h,samples=e.size,max_yuv_error=int(abs(e).max()),mse=float(np.mean(e*e)),changed_samples=int(np.count_nonzero(e)),exact_alpha=True);results.append(row)
print(json.dumps(results,indent=2));Path('/tmp/viewflow-nvenc-split-sparse-quality.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(r['max_yuv_error']<=4 for r in results)
