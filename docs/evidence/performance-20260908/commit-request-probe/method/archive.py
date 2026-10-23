from pathlib import Path
import gzip,json,hashlib,shutil
b=Path(__file__).resolve().parent.parent
probe=Path('/tmp/viewflow-commit-request-probe');integ=Path('/tmp/viewflow-full-glass-9hp_jra7')
def copy(src,dst):
 dst.parent.mkdir(parents=True,exist_ok=True)
 if src.suffix=='.log' or src.name=='timeline.json':
  with src.open('rb') as f,(dst.parent/(dst.name+'.gz')).open('wb') as o:
   with gzip.GzipFile(filename='',mode='wb',fileobj=o,mtime=0) as z:shutil.copyfileobj(f,z)
 else:shutil.copy2(src,dst)
for label in ['probe-request-ab','probe-request-ba']:
 for suffix in ['-probe.log','-desktop.log','-driver.log','-run.ps1','-before.json','-after.json','-state.json','-pairs.json']:
  p=probe/(label+suffix);copy(p,b/'independent'/p.name)
copy(probe/'request-comparison.json',b/'independent/comparison.json')
for prefix,labels in [('integrated',['request-off-a1-v2','request-on-b1-v2','request-on-b2-v2','request-off-a2-v2']),('v1-missing-exit-counter/runs',['request-off-a1','request-on-b1','request-on-b2','request-off-a2'])]:
 for label in labels:
  for name in ['source.log','fixture.log','isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log','desktop-marker.log','state.json','analysis.json','timeline.json']:
   copy(integ/label/name,b/prefix/label/name)
copy(probe/'integrated-control-state.json',b/'method/integrated-control-state.json')
copy(probe/'integrated-driver.log',b/'method/integrated-driver.log')
copy(probe/'integrated-v2-build-driver.log',b/'method/integrated-v2-build-driver.log')
# V1 preliminary and V2 verified counters remain separate.
for folder,labels in [('integrated',['request-off-a1-v2','request-on-b1-v2','request-on-b2-v2','request-off-a2-v2']),('v1-missing-exit-counter',['request-off-a1','request-on-b1','request-on-b2','request-off-a2'])]:
 rows=[json.loads((integ/l/'analysis.json').read_text()) for l in labels]
 (b/folder/'comparison.json').write_text(json.dumps(rows,indent=2)+'\n')
files={str(p.relative_to(b)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(b.rglob('*')) if p.is_file() and p.name!='sha256.json' and '__pycache__' not in p.parts}
(b/'sha256.json').write_text(json.dumps(files,indent=2)+'\n');print('archived',len(files),'files')
