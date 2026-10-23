from pathlib import Path
import hashlib,json,re,statistics,subprocess,math
b=Path(__file__).resolve().parent.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text())
m=read(b/'method/source-sha256.json');assert m==read(b/'method/remote-source-sha256.json') and all(sha(b/'source'/k)==v for k,v in m.items())
probe=Path('/tmp/viewflow-reverse-baseline-linux/viewflow_reverse_decoder_probe');records=[]
labels=['cbr-a1','gpb-off-b1','cqp-c1','cqp-gpb-off-d1','cqp-gpb-off-d2','cqp-c2','gpb-off-b2','cbr-a2']
for label in labels:
 p=b/'runs'/label;s=read(p/'state.json');status=read(p/'status.json');assert status['exit']==0 and s['main']=='Ready' and not s['processes'] and s['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB'
 with (p/'decode.log').open('w') as f:subprocess.run([str(probe),str(p/'probe.es'),'2','6144','3456'],stdout=f,stderr=subprocess.STDOUT,check=True)
 assert 'units=120 decoded=120 gl_error=0' in (p/'decode.log').read_text()
 text=(p/'probe.log').read_text();frames=[dict((k,float(v)) for k,v in re.findall(r'(frame|prepare|submit|sync|total|bytes|pts)=([0-9.]+)',line)) for line in text.splitlines() if line.startswith('frame=')];assert len(frames)==120 and [x['pts'] for x in frames]==[i*1500 for i in range(120)]
 controls=dict((k,int(v)) for k,v in re.findall(r'(\w+)=(\d+)',next(x for x in text.splitlines() if x.startswith('actual_controls '))))
 e=status['experiment'];assert controls['experiment']==e and controls['rate']==(3 if e>=2 else 1) and controls['gpb']==(32 if e%2 else 16)
 if e>=2:assert all(controls[k]==26 for k in ['qpi','qpp','qpb'])
 values=sorted(f['total'] for f in frames[20:]);records.append({'label':label,'native_sha256':s['native'],'experiment':e,'actual_controls':controls,'n':len(values),'median_ms':statistics.median(values),'p95_ms':values[math.ceil(.95*len(values))-1],'max_ms':max(values),'stream_bytes':(p/'probe.es').stat().st_size,'stream_sha256':sha(p/'probe.es')})
assert len({r['native_sha256'] for r in records})==1
for e in range(4):assert len({r['stream_sha256'] for r in records if r['experiment']==e})==1
(b/'method/results.json').write_text(json.dumps({'decoder':str(probe),'decoder_sha256':sha(probe),'runs':records,'repeat_bitstreams_identical_per_configuration':True,'cross_configuration_quality_equivalence_established':False},indent=2)+'\n');print(json.dumps(records,indent=2))
