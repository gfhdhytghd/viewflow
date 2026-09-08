from pathlib import Path
import struct,json,hashlib,subprocess
root=Path(__file__).parent
packets={}
for label in ['auto-a1','four-b1','disabled','auto-a2']:
 b=(root/(label+'.vfc')).read_bytes();magic,w,h=struct.unpack_from('<III',b);assert magic==0x56464342 and (w,h)==(3968,2432);i=12;p=[]
 while i<len(b):
  n,flags=struct.unpack_from('<II',b,i);i+=8;assert 0<n<=32*1024*1024 and i+n<=len(b);p.append(b[i:i+n]);i+=n
 assert i==len(b) and len(p)==330
 packets[label]=p;(root/(label+'.obu')).write_bytes(b''.join(p));(root/(label+'-first.obu')).write_bytes(p[0])
 with (root/(label+'-headers.log')).open('w') as log:subprocess.run(['ffmpeg','-hide_banner','-loglevel','info','-f','obu','-i',str(root/(label+'-first.obu')),'-frames:v','1','-c','copy','-bsf:v','trace_headers','-f','null','-'],stdout=log,stderr=subprocess.STDOUT,check=True)
result={label:dict(packets=len(ps),different_from_auto=sum(a!=b for a,b in zip(ps,packets['auto-a1'])),bytes=sum(map(len,ps))) for label,ps in packets.items()};(root/'packet-comparison.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
