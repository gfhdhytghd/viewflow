from pathlib import Path
import subprocess,json,os,re,hashlib
b=Path(__file__).resolve().parent.parent;probe=Path('/tmp/viewflow-reverse-cuvid-probe/viewflow_reverse_decoder_probe');records=[]
for decoder in ['native','cuvid']:
 env=os.environ.copy();env['VIEWFLOW_REVERSE_DECODER']=decoder
 r=subprocess.run([str(probe),str(b/'method/first-frame.hevc'),'2','6144','3456'],env=env,capture_output=True)
 (b/f'method/{decoder}-first.log').write_bytes(r.stdout+r.stderr);m=re.search(rb'units=(\d+) decoded=(\d+) gl_error=(\d+)',r.stderr);assert m
 record={'decoder':decoder,'exit':r.returncode,'units':int(m[1]),'decoded':int(m[2]),'gl_error':int(m[3])};assert record['units']==1 and record['gl_error']==0 and r.returncode==7
 assert record['decoded']==(1 if decoder=='native' else 0);records.append(record)
(b/'method/static-results.json').write_text(json.dumps({'probe':str(probe),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest(),'runs':records,'note':'Exit 7 is the old generic probe minimum-of-59-output threshold, expected for this one-unit test; counts determine this diagnosis.'},indent=2)+'\n');print(json.dumps(records))
