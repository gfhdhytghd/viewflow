from pathlib import Path
import hashlib,json,re
root=Path('docs/evidence')
files=list(root.glob('weak-network-bbr-*.txt'))
rows=0
for p in files:
 for l in p.read_text().splitlines():
  if not l.startswith('NETEM_RESULT '): continue
  r=json.loads(l[13:]); rows+=1
  assert r['survived'] and r['complete']>0 and r['seconds']>=30, (p,r)
  assert r['send_error'] is None and r['receive_error'] is None,p
  assert r['sent']==r['complete']+r['frames_lost'],(p,r['sent'],r['complete'],r['frames_lost'])
  if r['scenario']=='burst': assert r['complete_by_10s_phase'][2]>0,p
final=['final','cubic-wifi-repeat','stock-wifi-repeat','stock-cap20-repeat','final-wifi-repeat','final-cap8-repeat','final-hq-repeat','final-recovery']
binaries=set()
for name in final:
 p=root/('weak-network-bbr-'+name+'.txt'); s=p.read_text()
 assert 'NETEM_RESULT ' in s,p
 for digest,path in re.findall(r'^([0-9a-f]{64})  (.+)$',s,re.M):
  if path=='test executable': binaries.add(digest)
  else: assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest,(p,path)
assert len(binaries)==1,binaries
print('All completed NETEM_RESULT rows:',rows,'survived, errors null, duration >=30s, complete>0, frame conservation, burst recovery passed')
print('Final matrix + seven repeats: current source hashes match; same executable SHA256:',next(iter(binaries)))
