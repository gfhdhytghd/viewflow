from pathlib import Path
import gzip,json,hashlib,shutil
b=Path(__file__).resolve().parent.parent
work=json.loads(Path('/tmp/viewflow-full-glass-work.json').read_text());root=Path(work['local'])
labels=['pool-off-a1','pool-on-b1','pool-on-b2','pool-off-a2']
def copy(src,dst):
 dst.parent.mkdir(parents=True,exist_ok=True)
 if src.suffix=='.log' or src.name=='timeline.json':
  with src.open('rb') as f,(dst.parent/(dst.name+'.gz')).open('wb') as o:
   with gzip.GzipFile(filename='',mode='wb',fileobj=o,mtime=0) as z:shutil.copyfileobj(f,z)
 else:shutil.copy2(src,dst)
for label in labels:
 for name in ['source.log','fixture.log','isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log','desktop-marker.log','state.json','analysis.json','timeline.json']:copy(root/label/name,b/'runs'/label/name)
copy(Path('/tmp/viewflow-output-surface-pool/integrated-control-state.json'),b/'method/integrated-control-state.json')
for p in [Path('/tmp/viewflow-output-pool-integrated-driver.log'),Path('/tmp/viewflow-output-pool-test-driver.log'),Path('/tmp/viewflow-output-surface-pool-build-driver.log'),Path('/tmp/viewflow-output-pool-decoder-driver.log')]:copy(p,b/'method'/p.name)
(b/'comparison.json').write_text(json.dumps([json.loads((root/l/'analysis.json').read_text()) for l in labels],indent=2)+'\n')
files={str(p.relative_to(b)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(b.rglob('*')) if p.is_file() and p.name!='sha256.json' and '__pycache__' not in p.parts}
(b/'sha256.json').write_text(json.dumps(files,indent=2)+'\n');print('archived',len(files),'files')
