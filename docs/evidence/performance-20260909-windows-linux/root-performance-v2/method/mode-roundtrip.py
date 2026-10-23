from pathlib import Path
import json,importlib.util,subprocess,base64
r=Path('/home/wilf/data/viewflow');b=r/'docs/evidence/performance-20260909-windows-linux/root-performance-v2/method';spec=importlib.util.spec_from_file_location('control',r/'tools/viewflow-reverse-performance.py');control=importlib.util.module_from_spec(spec);spec.loader.exec_module(control);config=control.load_config(b/'control-config.json')
results=[]
for mode in [None,'latency',None,'frame-rate',None]:
 value=control.request(config,mode);assert value['mode']==('frame-rate' if not results or mode=='frame-rate' or len(results)==4 else 'latency');assert value['max_pending']==(1 if value['mode']=='latency' else 4);results.append({'request':mode,'response':value})
(b/'mode-roundtrip.json').write_text(json.dumps(results,indent=2)+'\n')
s="$ErrorActionPreference='Stop';Get-ChildItem '"+config['native'].rsplit('\\',1)[0]+"' -Filter *.exe|ForEach-Object{[pscustomobject]@{path=$_.FullName;hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json"
out=subprocess.run(['ssh','-o','BatchMode=yes',config['ssh_host'],'powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,check=True,timeout=30)
(b/'build-binaries.json').write_text(json.dumps(json.loads(out.stdout),indent=2)+'\n');(b/'mode-roundtrip.py').write_text(Path(__file__).read_text());print('native settings and atomic controller roundtrip passed')
