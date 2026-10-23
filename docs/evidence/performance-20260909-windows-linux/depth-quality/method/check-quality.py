from pathlib import Path
import subprocess,json,hashlib,re,math,statistics
b=Path(__file__).resolve().parent.parent
probe=Path('/tmp/viewflow-reverse-quality/viewflow_reverse_quality_probe')
expected=json.loads((b.parent/'candidate-quality/method/inputs.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(probe)==expected['probe_sha256'] and sha(b/'source/quality-probe-used.cpp')==expected['source_sha256']
report={'probe':str(probe),'probe_sha256':sha(probe),'source_sha256':sha(b/'source/quality-probe-used.cpp'),'scope':'same 90 synthetic markers, every RGB pixel, full 6144x3456; first encoded occurrence','inputs':{}}
markers={}
for name in ['1','2']:
 p=b/'runs'/name;assert json.loads((p/'state.json').read_text())['task']['result']==0
 report['inputs'][name]=sha(p/'stream.vfrv')
 log=p/'decode.log';assert not log.exists()
 with log.open('w') as out:r=subprocess.run([str(probe),str(p/'stream.vfrv'),'2','6144','3456'],stdout=out,stderr=subprocess.STDOUT,timeout=120)
 assert r.returncode==0,(name,r.returncode)
 text=log.read_text();values=[int(x) for x in re.findall(r'record_frame pts=\d+ marker=(\d+)',text)];assert values and values==sorted(values)
 emitted=len(re.findall(r'^profile_output ',(p/'source.log').read_text(errors='replace'),re.M));assert len(values)==emitted
 markers[name]=set(values);print('decoded',name,len(values),len(markers[name]),flush=True)
common=sorted(set.intersection(*markers.values()));common=[x for x in common if 200<=x<=1600];assert len(common)>=90
chosen=[common[round(i*(len(common)-1)/89)] for i in range(90)];assert len(set(chosen))==90
(b/'method/markers.txt').write_text('\n'.join(map(str,chosen))+'\n');report['common_available']=len(common);report['chosen_markers']=chosen;report['results']={}
for name in ['1','2']:
 p=b/'runs'/name;log=p/'quality.log';assert not log.exists()
 with log.open('w') as out:r=subprocess.run([str(probe),str(p/'stream.vfrv'),'2','6144','3456',str(b/'method/markers.txt')],stdout=out,stderr=subprocess.STDOUT,timeout=120)
 assert r.returncode==0,(name,r.returncode)
 rows=[dict(re.findall(r'(\w+)=([^ ]+)',line)) for line in log.read_text().splitlines() if line.startswith('quality_frame ')]
 assert len(rows)==90 and sorted(int(x['marker']) for x in rows)==chosen
 mses=[float(x['mse']) for x in rows];report['results'][name]={'exit':0,'frames':90,'pixels_per_frame':6144*3456,'mse':statistics.mean(mses),'psnr_db':-10*math.log10(statistics.mean(mses)),'max_error':max(float(x['max_error']) for x in rows)}
 print('quality',name,report['results'][name],flush=True)
assert all(sha(b/'runs'/name/'stream.vfrv')==value for name,value in report['inputs'].items()) and sha(probe)==report['probe_sha256']
(b/'method/results.json').write_text(json.dumps(report,indent=2)+'\n')
