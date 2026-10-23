from pathlib import Path
import json,gzip,hashlib,subprocess,base64,shutil,os
b=Path(__file__).resolve().parent.parent
local=Path(json.loads(Path('/tmp/viewflow-full-glass-work.json').read_text())['local'])
labels=['esrv-hv-v1-'+x for x in ['original-a1','normal-b1','normal-b2','original-a2']]
subprocess.run(['python',str(b/'method/analyze-integrated.py'),str(local),*labels],check=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
for label in labels:
 src=local/label;dst=b/'runs'/label;dst.mkdir(parents=True,exist_ok=True)
 for n in ['source.log','fixture.log','desktop-marker.log','isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log']:(dst/(n+'.gz')).write_bytes(gzip.compress((src/n).read_bytes(),mtime=0))
 for n in ['state.json','analysis.json','timeline.json']:shutil.copy2(src/n,dst/n)
shutil.copy2(local/'commit-wakeup-comparison.json',b/'comparison.json')
nested_state=json.loads(Path('/tmp/viewflow-esrv-hyperv-nested-latest.json').read_text())
assert nested_state['ab_trials']=='passed' and nested_state['nested_stopped']
nested=Path(nested_state['root']);d=b/'nested';d.mkdir(exist_ok=True)
for name in ['state.json','smoke.json','hyprland.lua','launch.py','inner.py']:
 if (nested/name).exists():shutil.copy2(nested/name,d/name)
for name in ['compositor.log','fixture-0.log','fixture-1.log']:(d/(name+'.gz')).write_bytes(gzip.compress((nested/name).read_bytes(),mtime=0))
(b/'method/driver.log.gz').write_bytes(gzip.compress(Path('/tmp/viewflow-esrv-hyperv-driver.log').read_bytes(),mtime=0))
s="[pscustomobject]@{config_hash=(Get-FileHash 'C:\\VirtualDisplayDriver\\vdd_settings.xml').Hash;processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}|Select-Object ProcessId,ExecutablePath);tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -like 'ViewflowPerf-*'}|Select-Object TaskName,State);port=@(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue).Count;esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass)}|ConvertTo-Json -Depth 4"
r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=35)
if r.returncode:raise RuntimeError(r.stderr.decode(errors='replace'))
state=json.loads(r.stdout);assert not state['processes'] and not state['tasks'] and not state['port']
assert state['config_hash']==hashlib.sha256((b/'method/vdd-before.xml').read_bytes()).hexdigest().upper()
(b/'method/final-state.json').write_text(json.dumps(state,indent=2)+'\n')
print('PASS four passive exact 4K runs archived; cleanup and original VDD configuration verified')
