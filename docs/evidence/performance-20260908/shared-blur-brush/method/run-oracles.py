from pathlib import Path
import subprocess,base64,json
b=Path(__file__).resolve().parent.parent
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\shared-blur-brush-20260909'
exe=root+r'\native-build\Release\viewflow_sparse_host_backdrop_test.exe'
def ps(s,timeout=90):
 return subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
summary=[]
for label,arg in [('baseline',''),('shared','shared')]:
 out=b/'oracles'/label;out.mkdir(parents=True,exist_ok=False);rd=root+'\\oracle-v2-'+label
 s=r'''
$r='ROOT';$exe='EXE';$task='ViewflowPerf-SharedBlurOracle';$registered=$false;$code=-1;
if(Test-Path $r){throw 'oracle output exists'};
if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}).Count){throw 'another private measurement is running'};
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'task exists'};
$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;
$desktopUser=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $desktopUser -or $desktopUser.Split('\')[-1] -ne $principal.UserId.Split('\')[-1]){throw 'interactive user mismatch'};
$before=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);
New-Item -ItemType Directory -Path $r|Out-Null;
try {
 $action=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $r ACTION_ARG;
 Register-ScheduledTask -TaskName $task -Principal $principal -Action $action -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registered=$true;Start-ScheduledTask -TaskName $task;
 Start-Sleep -Seconds 2;$started=Get-Date;
 while((Get-ScheduledTask -TaskName $task).State -eq 'Running'){if(((Get-Date)-$started).TotalSeconds -gt 45){throw 'probe timeout'};Start-Sleep -Milliseconds 500};$code=(Get-ScheduledTaskInfo -TaskName $task).LastTaskResult;
} finally {
 if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};
 [pscustomobject]@{exit=$code;exe=(Get-FileHash $exe|Select-Object Path,Hash);remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count;esrv_before=$before;esrv_after=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);has_panels=(Test-Path ($r+'\host-blur-panels.bgra'))}|ConvertTo-Json -Depth 5
};exit $code
'''.replace('ROOT',rd).replace('EXE',exe).replace('ACTION_ARG',"-Argument 'shared'" if arg else '')
 (out/'run.ps1').write_text(s);r=ps(s);(out/'state.json').write_bytes(r.stdout);(out/'ssh-stderr.log').write_bytes(r.stderr)
 state=json.loads(r.stdout)
 for n in ['host-backdrop-result.log']+(['host-blur-panels.bgra'] if state['has_panels'] else []):
  subprocess.run(['scp','-q','wilf@172.16.105.70:'+rd.replace('\\','/')+'/'+n,str(out/n)],check=True)
 print(label,json.dumps(state),flush=True);print((out/'host-backdrop-result.log').read_text(),flush=True)
 assert not state['remaining'] and not state['tasks'];assert state['esrv_before']==state['esrv_after']
 summary.append(dict(label=label,**state));(b/'oracle-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 if r.returncode or state['exit']:raise SystemExit(r.returncode or state['exit'])
