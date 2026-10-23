"""Archive only benchmark logs and source identities; never archive peer configs."""
from pathlib import Path
import gzip,json,shutil,hashlib,subprocess,os
b=Path(__file__).resolve().parent.parent
work=json.loads(Path('/tmp/viewflow-full-glass-work.json').read_text())
root=Path(work['local'])
labels=['display-diff-v1-'+n for n in ['off-a1','diff30-b1','diff30-b2','off-a2','off-c1','diff15-d1','diff15-d2','off-c2']]
subprocess.run(['python',str(b/'method/analyze-integrated.py'),str(root),*labels],check=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
for label in labels:
 src=root/label;dst=b/'runs'/label;dst.mkdir(parents=True,exist_ok=True)
 for n in ['source.log','fixture.log','desktop-marker.log','isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log']:
  (dst/(n+'.gz')).write_bytes(gzip.compress((src/n).read_bytes(),mtime=0))
 for n in ['state.json','analysis.json','timeline.json']:shutil.copy2(src/n,dst/n)
shutil.copy2(root/'background-cache-comparison.json',b/'comparison.json')
for hz in ['30','15']:
 shutil.copy2('/tmp/viewflow-background-change-detection/integrated-control-state-display-diff-v1-'+hz+'.json',b/('method/control-state-'+hz+'.json'))
for p in b.rglob('__pycache__'):
 raise RuntimeError('unexpected Python cache: '+str(p))
manifest={str(p.relative_to(b)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(b.rglob('*')) if p.is_file() and p!=b/'sha256.json'}
(b/'sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('archived',len(labels),'trials and',len(manifest),'files')
