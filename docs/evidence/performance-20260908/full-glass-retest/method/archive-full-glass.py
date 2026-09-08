from pathlib import Path
import gzip,json,hashlib,shutil
root=Path('/tmp/viewflow-full-glass-9hp_jra7');dest=Path('docs/evidence/performance-20260908/full-glass-retest')
for label in ['full-glass-01','full-glass-02','full-glass-03','full-glass-04','full-glass-05','full-glass-06']:
 src=root/label;target=dest/('runs' if label in ['full-glass-04','full-glass-06'] else 'setup-attempts')/label;target.mkdir(parents=True,exist_ok=True)
 for name in ['source.log','fixture.log','isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log','desktop-marker.log','timeline.json']:
  p=src/name
  if p.exists():
   with (target/(name+'.gz')).open('wb') as o:
    with gzip.GzipFile(filename='',fileobj=o,mode='wb',mtime=0) as z:z.write(p.read_bytes())
 for name in ['state.json','analysis.json','runtime.lua']:
  if (src/name).exists():shutil.copyfile(src/name,target/name)
shutil.copyfile(root/'comparison.json',dest/'comparison.json')
for name in ['profile_atlas_timeline.py','summarize_desktop_markers.py']:shutil.copyfile(Path('tools')/name,dest/'method'/name)
# Private CA and endpoint keys remain solely in the private test directories.
print('archived logs and analysis; no certificates, keys or configs copied')
