from pathlib import Path
import json,subprocess,hashlib
b=Path(__file__).resolve().parent.parent;inputs=json.loads((b/'method/inputs.json').read_text());probe=Path(inputs['probe']);assert hashlib.sha256(probe.read_bytes()).hexdigest()==inputs['probe_sha256'];results={}
for name,expected in inputs['inputs'].items():
 stream=b.parent/name/'runs/stream.vfrv';assert hashlib.sha256(stream.read_bytes()).hexdigest()==expected
 log=b/(name+'.log');assert not log.exists(),name
 with log.open('w') as out:r=subprocess.run([str(probe),str(stream),'2','6144','3456',str(b/'method/markers.txt')],stdout=out,stderr=subprocess.STDOUT,timeout=120)
 results[name]={'exit':r.returncode};(b/'method/results.json').write_text(json.dumps(results,indent=2)+'\n');assert r.returncode==0,(name,r.returncode);print('GPU full-frame quality validated',name,flush=True)
assert hashlib.sha256(probe.read_bytes()).hexdigest()==inputs['probe_sha256']
