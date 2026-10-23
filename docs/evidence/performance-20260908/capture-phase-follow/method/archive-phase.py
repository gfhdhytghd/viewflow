from pathlib import Path
import json,hashlib,gzip,shutil
base=Path('docs/evidence/performance-20260908/capture-phase-follow');root=Path('/tmp/viewflow-full-glass-9hp_jra7');nested=Path('/tmp/viewflow-phase-follow-nested.b1j4agyr')
def gz(p,target):
 with target.open('wb') as out:
  with gzip.GzipFile(filename='',mode='wb',fileobj=out,mtime=0) as z:z.write(p.read_bytes())
for label in ['phase-grid-a1','phase-follow-b1','phase-follow-b2','phase-grid-a2']:
 d=base/'runs'/label;d.mkdir(parents=True,exist_ok=True)
 for name in ['source.log','fixture.log','isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log','desktop-marker.log','timeline.json']:gz(root/label/name,d/(name+'.gz'))
 for name in ['analysis.json','state.json','runtime.lua']:shutil.copyfile(root/label/name,d/name)
shutil.copyfile(root/'phase-comparison.json',base/'comparison.json')
d=base/'nested';d.mkdir(exist_ok=True)
for name in ['state.json','smoke.json','output-cleanup.json','hyprland.lua','launcher.py','launch.py','inner.py']:
 if (nested/name).exists():shutil.copyfile(nested/name,d/name)
for name in ['compositor.log','fixture-0.log','fixture-1.log']:gz(nested/name,d/(name+'.gz'))
for p in Path('/tmp').glob('viewflow-phase-follow-*.log'):gz(p,base/'method'/(p.name+'.gz'))
shutil.copyfile(Path('docs/evidence/performance-20260908/full-glass-retest/method/fixture/main.cpp'),base/'method/fixture.cpp')
shutil.copyfile(Path('docs/evidence/performance-20260908/full-glass-retest/method/fixture/CMakeLists.txt'),base/'method/fixture-CMakeLists.txt')
print('phase archive collected')
