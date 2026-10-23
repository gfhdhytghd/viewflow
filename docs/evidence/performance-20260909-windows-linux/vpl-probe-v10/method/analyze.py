from pathlib import Path
import hashlib,json,re,subprocess,statistics,math
b=Path(__file__).resolve().parent.parent
read=lambda p:json.loads(p.read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=read(b/'method/source-sha256.json');assert m==read(b/'method/remote-source-sha256.json') and all(sha(b/'source'/k)==v for k,v in m.items())
records=[]
for label in ['hevc-a1','av1-b1','av1-b2','hevc-a2','av1tiles1-c1']:
 p=b/'runs'/label;v=read(p/'status.json');s=read(p/'state.json');assert v['exit']==0 and s['main']=='Ready' and not s['processes'] and s['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB'
 log=(p/'probe.log').read_text();frames=[dict((k,float(v)) for k,v in re.findall(r'(frame|prepare|submit|sync|total|bytes|pts)=([0-9.]+)',line)) for line in log.splitlines() if line.startswith('frame=')];assert len(frames)==120 and [x['pts'] for x in frames]==[1500*i for i in range(120)]
 assert sum(int(x['bytes']) for x in frames)==(p/'probe.es').stat().st_size
 if not (p/'decode.log').exists():
  cmd=['ffmpeg','-v','verbose','-hwaccel','cuda','-hwaccel_output_format','cuda','-c:v','av1_cuvid','-f','obu','-i',str(p/'probe.es'),'-f','null','-'] if v['codec']==3 else ['/tmp/viewflow-reverse-baseline-linux/viewflow_reverse_decoder_probe',str(p/'probe.es'),'2','6144','3456']
  with (p/'decode.log').open('w') as out:subprocess.run(cmd,stdout=out,stderr=subprocess.STDOUT,check=True)
 decode=(p/'decode.log').read_text()
 if v['codec']==3:assert '120 frames decoded; 0 decode errors' in decode and 'HW: cuda | SW: nv12' in decode and 'w:6144 h:3456 pixfmt:cuda' in decode
 else:assert 'units=120 decoded=120 gl_error=0' in decode
 actual={k:int(x) for k,x in re.findall(r'(columns|rows|slices)=(\d+)',next(l for l in log.splitlines() if l.startswith('tiles ')))}
 values=sorted(f['total'] for f in frames[20:]);record={'label':label,'codec':v['codec'],'native_sha256':s['native'],'requested_tile_columns':v['tile_columns'],'actual_tiles':actual,'warmup_frames':20,'n':100,'median_ms':statistics.median(values),'p95_ms':values[math.ceil(.95*len(values))-1],'max_ms':max(values),'stream_sha256':sha(p/'probe.es')};records.append(record)
assert len({r['native_sha256'] for r in records})==1
assert len({r['stream_sha256'] for r in records if r['codec']==2})==1
assert len({r['stream_sha256'] for r in records if r['codec']==3})==1
(b/'method/results.json').write_text(json.dumps(records,indent=2)+'\n');print(json.dumps(records,indent=2))
