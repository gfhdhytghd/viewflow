from pathlib import Path
import hashlib,json,re,subprocess,statistics,math
b=Path(__file__).resolve().parent.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();read=lambda p:json.loads(p.read_text())
m=read(b/'method/source-sha256.json');assert m==read(b/'method/remote-source-sha256.json') and all(sha(b/'source'/k)==v for k,v in m.items())
records=[]
def stats(xs):
 xs=sorted(xs);return {'n':len(xs),'median':statistics.median(xs),'p95':xs[math.ceil(.95*len(xs))-1],'max':max(xs)}
for label in ['processor-a1','compute-b1','compute-b2','processor-a2']:
 p=b/'runs'/label;v=read(p/'status.json');s=read(p/'state.json');assert v['exit']==0 and s['main']=='Ready' and not s['processes'] and s['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB'
 text=(p/'probe.log').read_text();assert 'input_bind_flags=160 encoder_bind=0' in text
 frames=[{k:float(v) for k,v in re.findall(r'(frame|prepare|submit|sync|total|bytes|pts)=([0-9.]+)',l)} for l in text.splitlines() if l.startswith('frame=')];assert len(frames)==120 and [x['pts'] for x in frames]==[i*1500 for i in range(120)]
 gpu=[{k:float(v) for k,v in re.findall(r'(frame|convert|copy)=([0-9.]+)',l)} for l in text.splitlines() if l.startswith('gpu frame=')];assert len(gpu)==120
 with (p/'decode.log').open('w') as f:subprocess.run(['/tmp/viewflow-reverse-baseline-linux/viewflow_reverse_decoder_probe',str(p/'probe.hevc'),'2','6144','3456'],stdout=f,stderr=subprocess.STDOUT,check=True)
 assert 'units=120 decoded=120 gl_error=0' in (p/'decode.log').read_text()
 records.append({'label':label,'compute':v['compute'],'native_sha256':s['native'],'stream_sha256':sha(p/'probe.hevc'),'warmup_frames':20,'total_ms':stats([x['total'] for x in frames[20:]]),'gpu_conversion_interval_ms':stats([x['convert'] for x in gpu[20:]])})
assert len({r['native_sha256'] for r in records})==1
for mode in [0,1]:assert len({r['stream_sha256'] for r in records if r['compute']==mode})==1
(b/'method/results.json').write_text(json.dumps(records,indent=2)+'\n');print(json.dumps(records,indent=2))
