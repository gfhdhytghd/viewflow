from pathlib import Path
import subprocess,json,hashlib,tempfile
b=Path(__file__).resolve().parent
for relative in ['fixed-4k/method/analyze.py','hyprland-30/method/analyze.py','hyprland-oracle/compare.py']:
 p=b/relative;out=p.parent/('comparison.json')
 before=out.read_bytes();subprocess.run(['python',str(p)],check=True,capture_output=True);assert out.read_bytes()==before,relative
with tempfile.TemporaryDirectory(prefix='viewflow-background-geometry-') as tmp:
 exe=Path(tmp)/'region-test';subprocess.run(['c++','-std=c++20','-O2',str(b/'hyprland-30/method/region-test.cpp'),'-o',str(exe)],check=True);subprocess.run([str(exe)],check=True)
state=json.loads((b/'method/final-state.json').read_text(encoding='utf-8-sig'));assert not state['owned_processes'] and not state['owned_tasks']
locations={'background-buffer-20260908':b/'source','background-buffer-fixed-4k-20260908':b/'fixed-4k/source','background-buffer-hyprland-30-20260908':b/'hyprland-30/source'}
verified=0;exe_hashes={}
for r in state['hashes']:
 parts=r['Path'].split('\\');folder,name=parts[-2:]
 if folder in locations and name.endswith(('.h','.cpp')):
  p=locations[folder]/name;assert hashlib.sha256(p.read_bytes()).hexdigest()==r['Hash'].lower(),str(p);verified+=1
 if name.endswith('.exe'):exe_hashes[folder]=r['Hash']
for folder in ['fixed-4k','hyprland-30']:
 rows=json.loads((b/folder/'method/comparison.json').read_text());assert len(rows)==4
 remote='background-buffer-'+('fixed-4k' if folder=='fixed-4k' else 'hyprland-30')+'-20260908'
 assert all(r['state']['probe_hash']==exe_hashes[remote] for r in rows)
for prefix,source in [('initial','probe-initial.cpp'),('refresh','probe-refresh.cpp'),('overscan','probe-overscan.cpp'),('cover','probe-cover.cpp')]:
 st=json.loads((b/'method'/(prefix+'-state.json')).read_text(encoding='utf-8-sig'));assert hashlib.sha256((b/'method'/source).read_bytes()).hexdigest()==st['source']['Hash'].lower()
manifest=json.loads((b/'sha256.json').read_text())
for name,expected in manifest.items():assert hashlib.sha256((b/name).read_bytes()).hexdigest()==expected,name
actual={str(p.relative_to(b)) for p in b.rglob('*') if p.is_file() and p.name!='sha256.json' and '__pycache__' not in p.parts}
assert actual==set(manifest)
print('PASS repeated analyses, geometry, source identity',verified,'files; archived hashes',len(manifest),'; no owned runtime/task remains')
