from pathlib import Path
import base64,subprocess,json,time,sys,hashlib
b=Path(__file__).resolve().parent.parent;label=sys.argv[1];variants={'1':'vpl-depth-v5','2':'vpl-depth-v5'};assert label in variants
stage=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-depth-quality-20260909';remote=stage+'\\runs\\'+label;candidate=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-'+variants[label]+r'-20260909\build\Release\viewflow_windows_reverse.exe';out=b/'runs'/label;out.mkdir(parents=True);task='ViewflowPerf-ReverseDepthQuality-'+label;created=False
expected=next(x['hash'] for x in json.loads((b.parent/variants[label]/'method/build-binaries.json').read_text()) if x['path'].endswith('viewflow_windows_reverse.exe'))
def ps(s,timeout=30):
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError((r.returncode,(r.stdout+r.stderr).decode(errors='replace')))
 return r.stdout.decode(errors='replace').strip()
def state():return json.loads(ps("[pscustomobject]@{installed=(Get-FileHash 'C:\\Users\\wilf\\Viewflow\\desktop-test\\viewflow_windows_reverse.exe').Hash;config=(Get-FileHash 'C:\\Users\\wilf\\Viewflow\\desktop-test\\receive.json').Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -like '*reverse-depth-quality-20260909*'}|Select-Object ProcessId,ExecutablePath)}|ConvertTo-Json -Depth 4"))
report={'label':label,'before':state(),'candidate_source':candidate,'expected_native_hash':expected}
def save():(out/'state.json').write_text(json.dumps(report,indent=2)+'\n')
assert not report['before']['processes'];assert ps("(Get-FileHash '"+candidate+"').Hash")==expected;save()
ps("if(Test-Path '"+remote+"'){throw 'lifecycle run exists'};New-Item -ItemType Directory '"+remote+"\\build\\Release' -Force|Out-Null;Copy-Item '"+candidate+"' '"+remote+"\\build\\Release\\viewflow_windows_reverse.exe';Copy-Item '"+stage+"\\viewflow_reverse_perf_fixture.exe' '"+remote+"\\build\\Release\\viewflow_reverse_perf_fixture.exe';Copy-Item '"+stage+"\\viewflow_reverse_perf_runner.exe' '"+remote+"\\build\\Release\\viewflow_reverse_perf_runner.exe'")
report['binaries']=json.loads(ps("Get-ChildItem '"+remote+"\\build\\Release\\*.exe'|ForEach-Object{[pscustomobject]@{path=$_.FullName;hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json"));assert next(x['hash'] for x in report['binaries'] if x['path'].endswith('viewflow_windows_reverse.exe'))==expected;save()
try:
 ps("if(Get-ScheduledTask '"+task+"' -ErrorAction SilentlyContinue){throw 'task exists'};$principal=(Get-ScheduledTask 'ViewflowMain-Active').Principal;$action=New-ScheduledTaskAction -Execute '"+remote+"\\build\\Release\\viewflow_reverse_perf_runner.exe' -Argument '\""+remote+"\" "+label+"' -WorkingDirectory '"+remote+"';Register-ScheduledTask -TaskName '"+task+"' -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1))|Out-Null")
 created=True;ps("Start-ScheduledTask '"+task+"'");print('quality source scheduled',label,flush=True)
 deadline=time.monotonic()+75
 while time.monotonic()<deadline:
  time.sleep(2);info=json.loads(ps("$t=Get-ScheduledTask '"+task+"';[pscustomobject]@{state=$t.State.ToString();result=(Get-ScheduledTaskInfo $t).LastTaskResult}|ConvertTo-Json"));report['task']=info;save()
  if info['state']!='Running':break

 else:raise RuntimeError('lifecycle observation deadline')
 assert info['result']==0 and info['state']=='Ready',info
finally:
 if created:ps("if((Get-ScheduledTask '"+task+"').State -eq 'Running'){Stop-ScheduledTask '"+task+"'};Unregister-ScheduledTask '"+task+"' -Confirm:$false")
 report['after']=state();report['native_hash_after']=ps("(Get-FileHash '"+remote+"\\build\\Release\\viewflow_windows_reverse.exe').Hash");save()
 if created:
  for name in ['source.log','fixture.log','status.log','stream.vfrv']:subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+name,str(out/name)],check=True,timeout=30)
assert not report['after']['processes'] and report['before']==report['after'] and report['native_hash_after']==expected;print('quality source normal exit and cleanup passed',flush=True)
