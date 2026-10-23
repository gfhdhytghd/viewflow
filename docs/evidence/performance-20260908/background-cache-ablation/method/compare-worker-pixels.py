from pathlib import Path
import struct, hashlib, json
from PIL import Image
b=Path(__file__).resolve().parent
result={}
for prefix in ['raw','cache']:
 a=(b/(prefix+'-before.bgra')).read_bytes();z=(b/(prefix+'-after.bgra')).read_bytes()
 assert a[:8]==z[:8]
 w,h=struct.unpack('<II',a[:8]);assert len(a)==len(z)==8+w*h*4
 dif=[abs(x-y) for x,y in zip(a[8:],z[8:])]
 result[prefix]={'dimensions':[w,h],'byte_identical':a==z,'max_code_difference':max(dif),'mean_code_difference':sum(dif)/len(dif),'sha_before':hashlib.sha256(a).hexdigest(),'sha_after':hashlib.sha256(z).hexdigest()}
 assert max(dif)<=1 and len(set(a[8:]))>20
 for suffix,data in [('before',a),('after',z)]:Image.frombytes('RGBA',(w,h),data[8:],'raw','BGRA').save(b/(prefix+'-'+suffix+'.png'))
(b/'worker-pixel-comparison.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
