"""Seal completed depth/topology artifacts and verify every indexed SHA256."""
from pathlib import Path
import json,hashlib,sys
b=Path(__file__).resolve().parent.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text())
write=lambda p,v:p.write_text(json.dumps(v,indent=2)+'\n')
refresh=['transport','linux-profile','linux-profile-v2','vpl-depth','vpl-depth-v2','lifecycle-depth-v2','vpl-depth-v3','vpl-depth-v4','root-headless','vpl-depth-v5','lifecycle-depth-v5','depth-quality','root-depth','lifecycle-root-depth','depth-deployment','depth-interval','depth-limit','cuvid-probe','vpl-probe-v10','nv12-uav-probe','vpl-probe-v11','depth-limit-v2','lifecycle-depth-limit-v2','marker-profile','vpl-probe-v12','vpl-probe-v13','vpl-probe-v14','depth-combined','mode-combined','lifecycle-mode-combined','long-transport','source-wait-profile']
for m in b.glob('*/sha256.json'):
 if m.parent.name not in refresh:
  for k,h in read(m).items():assert sha(m.parent/k)==h,(m,k)
for name in refresh:
 p=b/name;assert (p/'README.md').exists(),name
 write(p/'sha256.json',{str(f.relative_to(p)):sha(f) for f in sorted(p.rglob('*')) if f.is_file() and '__pycache__' not in f.parts and f!=p/'sha256.json'})
files=[b/'README.md',*sorted((b/'method').glob('*.py')),*sorted((b/'method').glob('vpl-*.json')),*sorted(b.glob('*/sha256.json'))]
write(b/'method/index-sha256.json',{str(f.relative_to(b)):sha(f) for f in files})
count=0
for m in b.glob('*/sha256.json'):
 for k,h in read(m).items():assert sha(m.parent/k)==h,(m,k);count+=1
for k,h in read(b/'method/index-sha256.json').items():assert sha(b/k)==h,k
qualified=[p for p in (b/'transport/runs').glob('*/summary.json') if read(p).get('run_qualified')]
assert len(qualified)==int(sys.argv[1] if len(sys.argv)>1 else 89),len(qualified)
print('Verified',count,'files;',len(read(b/'method/index-sha256.json')),'index entries;',len(qualified),'qualified trials')
