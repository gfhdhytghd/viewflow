from pathlib import Path
import subprocess,base64,json
b=Path(__file__).resolve().parent
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\display-4k-baseline-20260908'
def ps(s,timeout=120):
 return subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
plan=json.loads((b/'mode-change-plan.json').read_text());ready=json.loads((b/'mode-ready.json').read_text())
s=r'''$r='ROOT';$config='C:\VirtualDisplayDriver\vdd_settings.xml';$backup=$r+'\vdd-original.xml';$new=$r+'\vdd-with-4k.xml';$exe=$r+'\set-4k.exe';$task='ViewflowPerf-Set4K';$registered=$false;$changed=$false;$ok=$false;$code=-1;
if((Get-FileHash $config).Hash -ne 'OLD' -or (Get-FileHash $new).Hash -ne 'NEW' -or (Get-FileHash $exe).Hash -ne 'EXEHASH'){throw 'identity changed before application'};
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'existing apply task'};if((Test-Path $backup) -and (Get-FileHash $backup).Hash -ne 'OLD'){throw 'backup identity changed'};
if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}).Count){throw 'test process still active'};
if(-not (Test-Path $backup)){Copy-Item $config $backup};
try {
 Copy-Item $new $config -Force;$changed=$true;
 & pnputil.exe /restart-device 'ROOT\DISPLAY\0000' *> ($r+'\restart-vdd.log');if($LASTEXITCODE -ne 0){throw 'VDD restart failed'};
 Start-Sleep -Seconds 3;
 $principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;
 Register-ScheduledTask -TaskName $task -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument ('"'+$r+'\set-4k.log"') -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1))|Out-Null;$registered=$true;Start-ScheduledTask -TaskName $task;
 Start-Sleep -Seconds 2;$start=Get-Date;while((Get-ScheduledTask -TaskName $task).State -eq 'Running'){if(((Get-Date)-$start).TotalSeconds -gt 30){throw 'display mode application operation timeout'};Start-Sleep -Milliseconds 250};
 $code=(Get-ScheduledTaskInfo -TaskName $task).LastTaskResult;if($code -ne 0){throw ('mode tool failed '+$code)};$ok=$true;
} catch {
 $_|Out-String|Set-Content ($r+'\apply-error.txt');
 if($changed -and (Get-FileHash $config).Hash -eq 'NEW'){Copy-Item $backup $config -Force;& pnputil.exe /restart-device 'ROOT\DISPLAY\0000' *> ($r+'\rollback-vdd.log')};
} finally {
 if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};
 [pscustomobject]@{ok=$ok;tool_exit=$code;config_hash=(Get-FileHash $config).Hash;backup_hash=(Get-FileHash $backup).Hash;remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count;device=(Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000').Status}|ConvertTo-Json
}
'''.replace("'ROOT'","'"+root+"'").replace('OLD',plan['old_sha256'].upper()).replace('NEW',plan['new_sha256'].upper()).replace('EXEHASH',ready['mode_tool'])
(b/'apply-mode.ps1').write_text(s)
r=ps(s);(b/'apply-state.json').write_bytes(r.stdout);(b/'apply-stderr.txt').write_bytes(r.stderr)
for n in ['restart-vdd.log','rollback-vdd.log','set-4k.log','apply-error.txt']:
 subprocess.run(['scp','-q','wilf@172.16.105.70:'+root.replace('\\','/')+'/'+n,str(b/n)],capture_output=True)
print(r.stdout.decode(errors='replace'));
if r.returncode:raise RuntimeError(r.stderr.decode(errors='replace'))
assert json.loads(r.stdout)['ok'], (b/'apply-error.txt').read_text(errors='replace')
