from pathlib import Path
import subprocess,sys,base64,json
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc'
local=Path('docs/evidence/performance-20260908/stable-alpha-mask')
mode=sys.argv[1] if len(sys.argv)>1 else 'positive'
assert mode in ['positive','stale-mask','baseline']
expected=0 if mode=='positive' else 1
s=r'''$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$r='__ROOT__';$exe=$r+'\viewflow_sparse_alpha_mask_test.exe';$task='ViewflowPerf-AlphaMaskOracle';$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;$user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user -or $user.Split('\')[-1] -ne $principal.UserId.Split('\')[-1]){throw 'interactive test user is not logged on'};
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'oracle task exists'};if(@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count){throw 'oracle process already exists'};
$registered=$false;$result=-1;
try {
 $a=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $r;
 if('__MODE__' -ne 'positive'){$a=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $r -Argument '__MODE__'};
 Register-ScheduledTask -TaskName $task -Principal $principal -Action $a -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registered=$true;
 $started=Get-Date;Start-ScheduledTask -TaskName $task;Start-Sleep -Milliseconds 500;
 do {$t=Get-ScheduledTask -TaskName $task;$i=Get-ScheduledTaskInfo -TaskName $task;if($t.State -ne 'Running' -and $i.LastRunTime -ge $started.AddSeconds(-2)){break};if(((Get-Date)-$started).TotalSeconds -gt 70){throw 'oracle operation timeout'};Start-Sleep -Milliseconds 250}while($true);
 $result=$i.LastTaskResult;Copy-Item ($r+'\alpha-mask-result.log') ($r+'\alpha-mask-__MODE__.log');if($result -ne __EXPECTED__){throw ('unexpected oracle result '+$result)};
} finally {
 if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};
 @{mode='__MODE__';result=$result;expected=__EXPECTED__;remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count;exe=(Get-FileHash $exe|Select-Object Path,Hash);time=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 4|Set-Content -Encoding UTF8 ($r+'\alpha-mask-__MODE__-state.json');
}
Get-Content ($r+'\alpha-mask-__MODE__-state.json');
'''.replace('__ROOT__',root).replace('__MODE__',mode).replace('__EXPECTED__',str(expected))
script=local/'method'/('run-oracle-'+mode+'.ps1');script.write_text(s)
remote=root.replace('\\','/')
subprocess.run(['scp','-q',str(script),'wilf@172.16.105.70:'+remote+'/'+script.name],check=True)
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',remote+'/'+script.name],capture_output=True,timeout=100)
(local/('oracle-'+mode+'-driver.log')).write_bytes(r.stdout+r.stderr)
print((r.stdout+r.stderr).decode(errors='replace'))
for suffix in ['.log','-state.json']:
 subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote+'/alpha-mask-'+mode+suffix,str(local/('alpha-mask-'+mode+suffix))],check=True)
if r.returncode:raise RuntimeError('Oracle runner failed')
state=json.loads((local/('alpha-mask-'+mode+'-state.json')).read_text(encoding='utf-8-sig'))
assert state['result']==expected and state['remaining']==state['tasks']==0
text=(local/('alpha-mask-'+mode+'.log')).read_text()
if mode=='positive':assert 'PASS retained-alpha mask' in text and text.count('verified=1')==12
elif mode=='stale-mask':assert 'phase=4 verified=0' in text and 'physical HostBackdrop panels differ' in text
else:assert 'phase=10 verified=0' in text
