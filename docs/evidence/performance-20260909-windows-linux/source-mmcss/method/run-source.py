from pathlib import Path
import subprocess,base64,json,time,hashlib
b=Path(__file__).resolve().parent.parent;remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-source-mmcss-20260909';task='ViewflowPerf-Reverse6KSourceMMCSS-20260909'
def ps(s,timeout=35):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError((r.returncode,(r.stdout+r.stderr).decode(errors='replace')))
 return r.stdout.decode(errors='replace').strip()
def state():return json.loads(ps("[pscustomobject]@{processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -like '*reverse-source-mmcss-20260909*'}|Select-Object ProcessId,ParentProcessId,ExecutablePath);main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();installed=(Get-FileHash 'C:\\Users\\wilf\\Viewflow\\desktop-test\\viewflow_windows_reverse.exe').Hash}|ConvertTo-Json -Depth 5"))
def save(): (b/'method/run-state.json').write_text(json.dumps(report,indent=2)+'\n')
report={'before':state()};created=False
assert not report['before']['processes']
# Audit all compiled source immediately before scheduling.
m=json.loads((b/'method/source-sha256.json').read_text());r=json.loads(ps("Set-Location '"+remote+"';Get-ChildItem source -File -Recurse|ForEach-Object{[pscustomobject]@{path=$_.FullName.Substring((Join-Path $PWD 'source').Length+1).Replace('\\','/');hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json"));actual={x['path']:x['hash'].lower() for x in r};assert actual==m;(b/'method/remote-source-sha256.json').write_text(json.dumps(actual,indent=2)+'\n')
report['binaries']=json.loads(ps("Get-ChildItem '"+remote+"\\build\\Release\\*.exe'|ForEach-Object{[pscustomobject]@{path=$_.FullName;hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json"));save()
try:
 ps("if(Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue){throw 'task already exists'};if(Test-Path '"+remote+"\\status.log'){throw 'run already exists'}")
 ps("$principal=(Get-ScheduledTask 'ViewflowMain-Active').Principal;$action=New-ScheduledTaskAction -Execute '"+remote+"\\build\\Release\\viewflow_reverse_perf_runner.exe' -Argument '\""+remote+"\"' -WorkingDirectory '"+remote+"';Register-ScheduledTask -TaskName '"+task+"' -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null")
 created=True;ps("Start-ScheduledTask '"+task+"'");print('source profile scheduled',flush=True)
 deadline=time.monotonic()+75
 while time.monotonic()<deadline:
  time.sleep(3)
  x=json.loads(ps("$task=Get-ScheduledTask '"+task+"';[pscustomobject]@{state=$task.State.ToString();result=(Get-ScheduledTaskInfo $task).LastTaskResult;status=if(Test-Path '"+remote+"\\status.log'){[string](Get-Content '"+remote+"\\status.log' -Raw)}else{''}}|ConvertTo-Json"))
  report['task']=x;save()
  if x['state']!='Running':break
 else:raise RuntimeError('runner observation limit')
 print(x,flush=True)
finally:
 if created:
  ps("$t=Get-ScheduledTask '"+task+"';if($t.State -eq 'Running'){Stop-ScheduledTask '"+task+"'};Unregister-ScheduledTask '"+task+"' -Confirm:$false")
 report['after']=state();save()
 for name in ['status.log','source.log','fixture.log','stream.vfrv']:
  subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+name,str(b/('method' if name=='build-attempt1.log' else 'runs')/name)],check=True,timeout=120)
assert not report['after']['processes'],report['after']
assert report['before']['installed']==report['after']['installed']
assert report['task']['result']==0,report['task']
