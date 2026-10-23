from pathlib import Path
import tempfile,gzip,json,subprocess,hashlib,shutil,re
b=Path(__file__).resolve().parent.parent
labels=['pool-off-a1','pool-on-b1','pool-on-b2','pool-off-a2']
with tempfile.TemporaryDirectory(prefix='viewflow-output-pool-recompute-') as tmp:
 root=Path(tmp)
 for label in labels:
  d=root/label;d.mkdir()
  for p in (b/'runs'/label).glob('*.log.gz'):(d/p.name[:-3]).write_bytes(gzip.decompress(p.read_bytes()))
  shutil.copy2(b/'runs'/label/'state.json',d/'state.json')
 subprocess.run(['python3',str(b/'method/analyze-integrated.py'),str(root),*labels],check=True,stdout=subprocess.DEVNULL)
 for label in labels:
  assert json.loads((root/label/'analysis.json').read_text())==json.loads((b/'runs'/label/'analysis.json').read_text())
  assert json.loads((root/label/'timeline.json').read_text())==json.loads(gzip.decompress((b/'runs'/label/'timeline.json.gz').read_bytes()))
 assert json.loads((root/'output-pool-comparison.json').read_text())==json.loads((b/'comparison.json').read_text())
checks={}
for mode in ['off','on']:
 log=(b/'method'/('decoder-'+mode+'.log')).read_text();assert 'PASS decoder_integration' in log
 hashes={}
 for id,value in re.findall(r'readback id=(\d+) alpha_exact=1 bgra_fnv64=(\d+)',log):
  if id in hashes:assert hashes[id]==value
  hashes[id]=value
 assert set(hashes)=={str(i) for i in range(1,25)};checks[mode]=hashes
assert checks['off']==checks['on']==json.loads((b/'method/decoder-comparison.json').read_text())['checksums']
assert b'PASS output_surface_pool_all_tests' in (b/'method/test-pool.log').read_bytes()
for k,v in json.loads((b/'method/integrated-source-sha256.json').read_text()).items():assert hashlib.sha256((b/'source'/k).read_bytes()).hexdigest()==v,k
manifest=json.loads((b/'sha256.json').read_text())
actual={str(p.relative_to(b)) for p in b.rglob('*') if p.is_file() and p.name!='sha256.json' and '__pycache__' not in p.parts}
assert actual==set(manifest)
for k,v in manifest.items():assert hashlib.sha256((b/k).read_bytes()).hexdigest()==v,k
for p in b.rglob('*'):
 if p.is_file():assert p.suffix not in ('.pem','.key','.pfx','.exe','.dll','.obj'),str(p)
print('4 analyses and timelines exactly reproduced; 24 decoder alpha/checksum records verified; GPU tests and all archive/source hashes verified')
