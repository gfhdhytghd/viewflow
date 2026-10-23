from pathlib import Path
import json,hashlib,gzip,shutil,tempfile,subprocess,os
b=Path(__file__).resolve().parent.parent
rows=json.loads((b/'comparison.json').read_text());assert len(rows)==2
labels=[r['label'] for r in rows]
with tempfile.TemporaryDirectory(prefix='viewflow-exact4k-verify-') as name:
 root=Path(name)
 for label in labels:
  p=root/label;p.mkdir()
  for f in (b/'runs'/label).iterdir():
   if f.suffix=='.gz':(p/f.stem).write_bytes(gzip.decompress(f.read_bytes()))
   elif f.name=='state.json':shutil.copy2(f,p/f.name)
 subprocess.run(['python',str(b/'method/analyze-integrated.py'),str(root),*labels],env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),check=True,stdout=subprocess.DEVNULL)
 assert json.loads((root/'background-cache-comparison.json').read_text())==rows
 for label in labels:
  for n in ['analysis.json','timeline.json']:assert json.loads((root/label/n).read_text())==json.loads((b/'runs'/label/n).read_text())
reference=json.loads((b/'runs'/labels[0]/'state.json').read_text())
for row in rows:
 s=json.loads((b/'runs'/row['label']/'state.json').read_text())
 assert s['windows_binaries']==reference['windows_binaries'] and s['linux_binaries']==reference['linux_binaries']
 assert not s.get('error') and not s['cleanup_errors'] and not s['after']['processes'] and not s['after']['port']
 assert json.loads(s['observer_result'])['LastTaskResult']==0 and row['desktop']['marker_span_fraction']>.99
 assert [x for x in row['monitor_lines'] if x.startswith('output rect=')]==['output rect=0,0,3840,2400 client=-4,-4,3848,2408']
 assert row['bounds']['unique_capture_stage_samples']['capture_to_desktop_upper_ms']['n']>1400
c=json.loads((b/'method/control-state.json').read_text());assert c['trials']=='completed' and not c['configerrors'] and c['before_plugins']==c['after_plugins']
a={m['name']:m for m in c['before_monitors']};z={m['name']:m for m in c['after_monitors']};assert a.keys()==z.keys()
for n in a:
 for k in ['id','x','y','width','height','scale','transform','refreshRate']:assert a[n][k]==z[n][k],(n,k)
s=json.loads((b/'method/final-state.json').read_text());assert not s['processes'] and not s['tasks'] and not s['port']
assert s['config_hash']==hashlib.sha256((b/'method/vdd-before.xml').read_bytes()).hexdigest().upper()
manifest=json.loads((b/'sha256.json').read_text())
for n,h in manifest.items():assert hashlib.sha256((b/n).read_bytes()).hexdigest()==h,n
print('PASS two exact 4K analyses/timelines, complete dynamic observations, identities, cleanup, original VDD configuration and',len(manifest),'archive hashes')
