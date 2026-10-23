from pathlib import Path
import subprocess,base64,json
b=Path(__file__).resolve().parent
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\display-4k-baseline-20260908'
def ps(s,timeout=90):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout);return r
s=r'''$task='ViewflowPerf-CacheDisplayProbe';$r='ROOT';$exe=$r+'\display-probe.exe';
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'task exists'};
$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;$registered=$false;$code=-1;
try {Register-ScheduledTask -TaskName $task -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument ('"'+$r+'\display-ablation-probe-before.log"') -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1))|Out-Null;$registered=$true;Start-ScheduledTask -TaskName $task;Start-Sleep -Seconds 2;$start=Get-Date;while((Get-ScheduledTask -TaskName $task).State -eq 'Running'){if(((Get-Date)-$start).TotalSeconds -gt 30){throw 'read-only topology probe operation timeout'};Start-Sleep -Milliseconds 250};$code=(Get-ScheduledTaskInfo -TaskName $task).LastTaskResult;}
finally {if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};[pscustomobject]@{exit=$code;hash=(Get-FileHash $exe).Hash;remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count}|ConvertTo-Json};exit $code
'''.replace('ROOT',root)
r=ps(s);(b/'probe-state.json').write_bytes(r.stdout);r.check_returncode();assert json.loads(r.stdout)['exit']==0, r.stdout.decode(errors='replace');subprocess.run(['scp','-q','wilf@172.16.105.70:'+root.replace('\\','/')+'/display-ablation-probe-before.log',str(b/'display-ablation-probe-before.log')],check=True);print((b/'display-ablation-probe-before.log').read_text())
