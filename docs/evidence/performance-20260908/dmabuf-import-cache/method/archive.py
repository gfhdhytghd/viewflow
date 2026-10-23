from pathlib import Path
import gzip,hashlib,json,shutil
b=Path(__file__).resolve().parent.parent;root=Path('/tmp/viewflow-full-glass-9hp_jra7')
labels=['import-identity-baseline-01','import-cache-off-a1','import-cache-on-b1','import-cache-on-b2','import-cache-off-a2']
def copy(src,dst,compress=False):
 dst.parent.mkdir(parents=True,exist_ok=True)
 if compress:
  with src.open('rb') as i,dst.open('wb') as o:
   with gzip.GzipFile(filename='',fileobj=o,mode='wb',mtime=0) as z:shutil.copyfileobj(i,z)
 else:shutil.copy2(src,dst)
for label in labels:
 for name in ['source.log','fixture.log','isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log','desktop-marker.log','state.json','analysis.json','import-analysis.json','timeline.json']:
  compress=name.endswith('.log') or name=='timeline.json';copy(root/label/name,b/'runs'/label/(name+'.gz' if compress else name),compress)
for kind,name in [('analysis.json','comparison.json'),('import-analysis.json','import-comparison.json')]:
 (b/name).write_text(json.dumps([json.loads((root/l/kind).read_text()) for l in labels[1:]],indent=2)+'\n')
copy(Path('/tmp/viewflow-import-cache-probe/integrated-control-state.json'),b/'method/integrated-control-state.json')
for name in ['viewflow-import-cache-driver.log','viewflow-import-identity-driver.log']:copy(Path('/tmp')/name,b/'method'/(name+'.gz'),True)
for mode in ['off','on']:
 copy(Path('/home/wilf/.cache/viewflow-perf-import-cache-20260908')/('oracle-v2-'+mode+'.h264'),b/'oracle'/('oracle-v2-'+mode+'.h264.gz'),True)
files={str(p.relative_to(b)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(b.rglob('*')) if p.is_file() and p.name!='sha256.json' and '__pycache__' not in p.parts}
(b/'sha256.json').write_text(json.dumps(files,indent=2)+'\n');print('archived',len(files),'files')
