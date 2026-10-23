from pathlib import Path
import json,hashlib,gzip,tempfile,subprocess,shutil,os
b=Path(__file__).resolve().parent.parent
env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
rows=json.loads((b/'comparison.json').read_text());labels=[r['label'] for r in rows]
with tempfile.TemporaryDirectory(prefix='viewflow-background-verify-') as name:
 root=Path(name)
 for label in labels:
  src=b/'runs'/label;dst=root/label;dst.mkdir()
  for p in src.iterdir():
   if p.name.endswith('.gz'):(dst/p.stem).write_bytes(gzip.decompress(p.read_bytes()))
   elif p.name=='state.json':shutil.copy2(p,dst/p.name)
 subprocess.run(['python',str(b/'method/analyze-integrated.py'),str(root),*labels],check=True,env=env,stdout=subprocess.DEVNULL)
 assert json.loads((root/'background-cache-comparison.json').read_text())==rows
 for label in labels:
  for n in ['analysis.json','timeline.json']:
   assert json.loads((root/label/n).read_text())==json.loads((b/'runs'/label/n).read_text())
 pixel=root/'pixels';pixel.mkdir()
 for n in ['raw-before.bgra','raw-after.bgra','cache-before.bgra','cache-after.bgra','compare-worker-pixels.py']:shutil.copy2(b/'method'/n,pixel/n)
 subprocess.run(['python',str(pixel/'compare-worker-pixels.py')],check=True,env=env,stdout=subprocess.DEVNULL)
 assert json.loads((pixel/'worker-pixel-comparison.json').read_text())==json.loads((b/'method/worker-pixel-comparison.json').read_text())
 subprocess.run(['c++','-std=c++20','-O2',str(b/'source/platform/windows-composition-preview/background_region_test.cpp'),'-o',str(root/'geometry')],check=True)
 subprocess.run([str(root/'geometry')],check=True)
source=json.loads((b/'method/source-sha256.json').read_text())
for n,h in source.items():assert hashlib.sha256((b/'source'/n).read_bytes()).hexdigest()==h,n
reference=json.loads((b/'runs'/labels[0]/'state.json').read_text())
for label in labels:
 s=json.loads((b/'runs'/label/'state.json').read_text())
 assert s['windows_binaries']==reference['windows_binaries']
 assert s['linux_binaries']==reference['linux_binaries']
 assert not s['cleanup_errors'] and not s['after']['processes'] and not s['after']['port']
 outputs=[x for x in next(r for r in rows if r['label']==label)['monitor_lines'] if x.startswith('output rect=')]
 assert set(outputs)=={'output rect=0,0,6144,3456 client=-4,-4,3848,2408'}
for hz in ['30','15']:
 c=json.loads((b/'method'/('control-state-'+hz+'.json')).read_text())
 assert c['trials']=='completed'
 a={m['name']:m for m in c['before_monitors']};z={m['name']:m for m in c['after_monitors']}
 assert a.keys()==z.keys()
 for n in a:
  for k in ['id','x','y','width','height','scale','transform','refreshRate']:
   assert a[n][k]==z[n][k],(n,k)
 assert c['before_plugins']==c['after_plugins'] and not c['configerrors']
assert sum(r['desktop']['short_marker_span'] for r in rows)==2
assert rows[6]['bounds']['unique_capture_stage_samples']['capture_to_desktop_upper_ms']['n']==0
assert rows[4]['desktop']['marker_span_fraction']<.14
state=json.loads((b/'method/final-state.json').read_text())
assert not state['windows']['processes'] and not state['windows']['tasks'] and not state['windows']['port']
manifest=json.loads((b/'sha256.json').read_text())
for n,h in manifest.items():assert hashlib.sha256((b/n).read_bytes()).hexdigest()==h,n
print(f'PASS eight archived analyses/timelines, pixels, geometry/partitions, {len(source)} sources, identities, display bounds, cleanup and {len(manifest)} hashes; two incomplete observations retained')
