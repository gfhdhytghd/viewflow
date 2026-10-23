from pathlib import Path
import numpy as np,json,gzip
b=Path(__file__).resolve().parent
def read(name):
 p=b/name
 return p.read_bytes() if p.exists() else gzip.decompress(p.with_suffix(p.suffix+'.gz').read_bytes())
a=np.frombuffer(read('reference.rgba'),np.uint8).reshape(1024,1024,4).astype(np.int16)
c=np.frombuffer(read('windows.rgba'),np.uint8).reshape(a.shape).astype(np.int16)
d=np.abs(a-c);r={'width':1024,'height':1024,'noise':0,'hdr':False,'kernel_support_margin':182,'input_definition':'same integer RGB pattern in reference.cpp and windows.cpp'}
for name,region in [('whole',d),('interior',d[182:-182,182:-182])]:
 v=region[:,:,:3];r[name]={'pixels':region.shape[0]*region.shape[1],'mean_rgb_difference':float(v.mean()),'max_rgb_difference':int(v.max()),'rgb_components_above_1':int((v>1).sum()),'rgb_components_above_3':int((v>3).sum()),'alpha_mismatches':int((region[:,:,3]!=0).sum())}
assert r['interior']['max_rgb_difference']<=1 and r['interior']['alpha_mismatches']==0
print(json.dumps(r,indent=2));(b/'comparison.json').write_text(json.dumps(r,indent=2)+'\n')
