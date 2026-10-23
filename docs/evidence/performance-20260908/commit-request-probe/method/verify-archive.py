from pathlib import Path
import tempfile,gzip,json,subprocess,hashlib,shutil
b=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='viewflow-request-recompute-') as tmp:
 root=Path(tmp)
 for group,labels in [('integrated',['request-off-a1-v2','request-on-b1-v2','request-on-b2-v2','request-off-a2-v2'])]:
  dst=root/group;dst.mkdir()
  for label in labels:
   d=dst/label;d.mkdir()
   for p in (b/group/label).glob('*.log.gz'):
    (d/p.name[:-3]).write_bytes(gzip.decompress(p.read_bytes()))
   shutil.copy2(b/group/label/'state.json',d/'state.json')
  subprocess.run(['python3',str(b/'method/analyze-integrated.py'),str(dst),*labels],check=True,stdout=subprocess.DEVNULL)
  for label in labels:
   assert json.loads((dst/label/'timeline.json').read_text())==json.loads(gzip.decompress((b/group/label/'timeline.json.gz').read_bytes()))
  original=json.loads((b/group/'comparison.json').read_text());derived=json.loads((dst/'integrated-request-comparison.json').read_text());assert derived==original
 dst=root/'independent';dst.mkdir()
 for p in (b/'independent').iterdir():
  if p.name.endswith('.log.gz'):(dst/p.name[:-3]).write_bytes(gzip.decompress(p.read_bytes()))
  elif p.name.endswith('-state.json'):shutil.copy2(p,dst/p.name)
 subprocess.run(['python3',str(b/'method/analyze.py'),str(dst),'probe-request-ab','probe-request-ba'],check=True,stdout=subprocess.DEVNULL)
 assert json.loads((dst/'request-comparison.json').read_text())==json.loads((b/'independent/comparison.json').read_text())
for k,v in json.loads((b/'sha256.json').read_text()).items():assert hashlib.sha256((b/k).read_bytes()).hexdigest()==v,k
# Configs/private pairing files are intentionally absent.
for p in b.rglob('*'):
 if not p.is_file() or '__pycache__' in p.parts:continue
 assert p.suffix not in ('.key','.pem','.pfx','.exe','.dll','.obj'),str(p)
print('independent and 4 integrated analyses exactly reproduced; all archive hashes valid; no credential/binary files')
