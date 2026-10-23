"""Preserve the initial CQP capacity failure and verify the two emitted streams."""
from pathlib import Path
import hashlib,json,subprocess
b=Path(__file__).resolve().parent.parent
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=read(b/'method/source-sha256.json');assert m==read(b/'method/remote-source-sha256.json') and all(sha(b/'source'/k)==v for k,v in m.items())
decoder=Path('/tmp/viewflow-reverse-baseline-linux/viewflow_reverse_decoder_probe')
records=[]
for label in ['cbr-a1','gpb-off-b1','cqp-c1']:
 p=b/'runs'/label;s=read(p/'state.json');status=read(p/'status.json')
 assert s['main']=='Ready' and not s['processes'] and s['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB'
 if label=='cqp-c1':
  assert status['exit']==1 and (p/'probe.es').stat().st_size==0
  assert 'bufferkb=31850' in (p/'probe.log').read_text() and 'encode status=-5' in (p/'probe.log').read_text()
 else:
  assert status['exit']==0
  with (p/'decode.log').open('w') as f:subprocess.run([str(decoder),str(p/'probe.es'),'2','6144','3456'],stdout=f,stderr=subprocess.STDOUT,check=True)
  assert 'units=120 decoded=120 gl_error=0' in (p/'decode.log').read_text()
 records.append(dict(label=label,native=s['native'],exit=status['exit'],stream_bytes=(p/'probe.es').stat().st_size,stream_sha256=sha(p/'probe.es')))
assert len({r['native'] for r in records})==1
(b/'method/results.json').write_text(json.dumps(dict(records=records,decoder_sha256=sha(decoder),cqp_failure='runtime requires a larger bitstream capacity before encoding'),indent=2)+'\n')
print('Two initial streams decoded; initial CQP capacity failure preserved')
