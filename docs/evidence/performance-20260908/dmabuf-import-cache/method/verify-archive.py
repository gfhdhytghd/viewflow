from pathlib import Path
import tempfile,gzip,json,subprocess,hashlib,shutil
b=Path(__file__).resolve().parent.parent
labels=['import-identity-baseline-01','import-cache-off-a1','import-cache-on-b1','import-cache-on-b2','import-cache-off-a2']
with tempfile.TemporaryDirectory(prefix='viewflow-import-cache-recompute-') as tmp:
 root=Path(tmp)
 for label in labels:
  dst=root/label;dst.mkdir()
  for p in (b/'runs'/label).glob('*.log.gz'):(dst/p.name[:-3]).write_bytes(gzip.decompress(p.read_bytes()))
  shutil.copy2(b/'runs'/label/'state.json',dst/'state.json')
 for script in ['analyze-import.py','analyze-endpoint.py']:
  subprocess.run(['python3',str(b/'method'/script),str(root),*labels],check=True,stdout=subprocess.DEVNULL)
 for label in labels:
  for name in ['analysis.json','import-analysis.json']:
   assert json.loads((root/label/name).read_text())==json.loads((b/'runs'/label/name).read_text()),(label,name)
  assert json.loads((root/label/'timeline.json').read_text())==json.loads(gzip.decompress((b/'runs'/label/'timeline.json.gz').read_bytes()))
 for p in (b/'method').glob('oracle-v2-*.log'):shutil.copy2(p,root/p.name)
 subprocess.run(['python3',str(b/'method/analyze-oracle.py'),str(root),str(b/'oracle')],check=True,stdout=subprocess.DEVNULL)
 assert json.loads((root/'oracle-comparison.json').read_text())==json.loads((b/'method/oracle-comparison.json').read_text())
for k,v in json.loads((b/'sha256.json').read_text()).items():assert hashlib.sha256((b/k).read_bytes()).hexdigest()==v,k
for p in b.rglob('*'):
 if p.is_file():assert p.suffix not in ('.pem','.key','.pfx','.exe','.dll','.obj'),str(p)
print('five endpoint/import analyses, five timelines, two oracles exactly reproduced; all manifest hashes verified')
