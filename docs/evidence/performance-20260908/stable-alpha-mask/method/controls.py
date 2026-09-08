from pathlib import Path
import subprocess,base64,json,hashlib
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc'
local=Path('/tmp/viewflow-mask-update-probe');local.mkdir(exist_ok=True)
state=local/'controls-state.json'
def ps(code):
 code="$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new();"+code
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(code.encode('utf-16le')).decode()],capture_output=True,timeout=45)
 if r.returncode:raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
 return r.stdout.decode(errors='replace')
expected=json.loads(Path('/tmp/viewflow-mask-probe-build-success.json').read_text())
assert ps("(Get-FileHash '"+root+"\\viewflow_windows_mask_update_probe.exe').Hash").strip()==expected['Hash']
for n,h in expected['source_hashes'].items():assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==h
code=r'''$s=Get-CimInstance Win32_Service -Filter "Name='ESRV_SVC_QUEENCREEK'";$p=if($s.ProcessId){Get-Process -Id $s.ProcessId}else{$null};@{boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks.ToString();service_state=$s.State;process=if($p){@{id=$p.Id;priority=$p.PriorityClass.ToString();critical=@($p.Threads|Where-Object PriorityLevel -eq 'TimeCritical'|ForEach-Object {$_.Id})}}else{$null};time=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 5'''
initial=json.loads(ps(code));data={'initial':initial,'priority_changes':False,'phases':[]};state.write_text(json.dumps(data,indent=2)+'\n')
for label,mode in [('probe-mask-ab','mask-toggle'),('probe-mask-ba','mask-toggle-reverse')]:
 before=json.loads(ps(code));phase={'label':label,'mode':mode,'before':before};data['phases'].append(phase);state.write_text(json.dumps(data,indent=2)+'\n');print('BEGIN',label,before,flush=True)
 with open(local/(label+'-control.log'),'w') as log:
  r=subprocess.run(['python','docs/evidence/performance-20260908/stable-alpha-mask/method/run.py',label,mode],stdout=log,stderr=subprocess.STDOUT)
 after=json.loads(ps(code));phase.update(after=after,exit=r.returncode);state.write_text(json.dumps(data,indent=2)+'\n');print('END',label,r.returncode,after,flush=True)
 assert r.returncode==0
 assert before['boot']==after['boot']==initial['boot'] and before['service_state']==after['service_state']==initial['service_state'] and before['process']==after['process']==initial['process'], 'external background state changed'
