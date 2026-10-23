from pathlib import Path
import json,gzip,hashlib,subprocess,base64,shutil,os
b=Path(__file__).resolve().parent.parent
local=Path(json.loads(Path('/tmp/viewflow-full-glass-work.json').read_text())['local'])
labels=['exact4k-v1-off-a1','exact4k-v1-off-a2']
subprocess.run(['python',str(b/'method/analyze-integrated.py'),str(local),*labels],check=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
for label in labels:
 src=local/label;dst=b/'runs'/label;dst.mkdir(parents=True,exist_ok=True)
 for n in ['source.log','fixture.log','desktop-marker.log','isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log']:(dst/(n+'.gz')).write_bytes(gzip.compress((src/n).read_bytes(),mtime=0))
 for n in ['state.json','analysis.json','timeline.json']:shutil.copy2(src/n,dst/n)
shutil.copy2(local/'background-cache-comparison.json',b/'comparison.json')
shutil.copy2('/tmp/viewflow-display-4k-baseline/integrated-control-state-exact4k-v1-30.json',b/'method/control-state.json')
s="[pscustomobject]@{config_hash=(Get-FileHash 'C:\\VirtualDisplayDriver\\vdd_settings.xml').Hash;processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}|Select-Object ProcessId,ExecutablePath);tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -like 'ViewflowPerf-*'}|Select-Object TaskName,State);port=@(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue).Count;esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass)}|ConvertTo-Json -Depth 4"
r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=35)
if r.returncode:raise RuntimeError(r.stderr.decode(errors='replace'))
state=json.loads(r.stdout);assert not state['processes'] and not state['tasks'] and not state['port']
assert state['config_hash']==hashlib.sha256((b/'method/vdd-before.xml').read_bytes()).hexdigest().upper()
(b/'method/final-state.json').write_text(json.dumps(state,indent=2)+'\n')
print('PASS two exact 4K runs archived; test cleanup verified; VDD configuration restored')
