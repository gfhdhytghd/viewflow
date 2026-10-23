$r='C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\display-4k-baseline-20260908';$config='C:\VirtualDisplayDriver\vdd_settings.xml';$backup=$r+'\vdd-original.xml';$new=$r+'\vdd-with-4k.xml';$exe=$r+'\set-4k.exe';$task='ViewflowPerf-Set4K';$registered=$false;$changed=$false;$ok=$false;$code=-1;
if((Get-FileHash $config).Hash -ne '25207E831EAFE3A54F897EDB6F464E9CDC9CBC8F79482F6DC75B24D6AB98C339' -or (Get-FileHash $new).Hash -ne '33B7CA94379CEA039C4B6D66801654772FEE2A3F6669395F61664E04A1D743A1' -or (Get-FileHash $exe).Hash -ne 'C0629C272735B2199728E61108B56A79D7045BFDC9DE9E13ADD9AC8238B7F6D1'){throw 'identity changed before application'};
if((Test-Path $backup) -or (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)){throw 'existing apply state'};
if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}).Count){throw 'test process still active'};
Copy-Item $config $backup;
try {
 Copy-Item $new $config -Force;$changed=$true;
 & pnputil.exe /restart-device 'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\display-4k-baseline-20260908\DISPLAY\0000' *> ($r+'\restart-vdd.log');if($LASTEXITCODE -ne 0){throw 'VDD restart failed'};
 Start-Sleep -Seconds 3;
 $principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;
 Register-ScheduledTask -TaskName $task -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument ('"'+$r+'\set-4k.log"') -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1))|Out-Null;$registered=$true;Start-ScheduledTask -TaskName $task;
 Start-Sleep -Seconds 2;$start=Get-Date;while((Get-ScheduledTask -TaskName $task).State -eq 'Running'){if(((Get-Date)-$start).TotalSeconds -gt 30){throw 'display mode application operation timeout'};Start-Sleep -Milliseconds 250};
 $code=(Get-ScheduledTaskInfo -TaskName $task).LastTaskResult;if($code -ne 0){throw ('mode tool failed '+$code)};$ok=$true;
} catch {
 $_|Out-String|Set-Content ($r+'\apply-error.txt');
 if($changed -and (Get-FileHash $config).Hash -eq '33B7CA94379CEA039C4B6D66801654772FEE2A3F6669395F61664E04A1D743A1'){Copy-Item $backup $config -Force;& pnputil.exe /restart-device 'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\display-4k-baseline-20260908\DISPLAY\0000' *> ($r+'\rollback-vdd.log')};
} finally {
 if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};
 [pscustomobject]@{ok=$ok;tool_exit=$code;config_hash=(Get-FileHash $config).Hash;backup_hash=(Get-FileHash $backup).Hash;remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count;device=(Get-PnpDevice -InstanceId 'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\display-4k-baseline-20260908\DISPLAY\0000').Status}|ConvertTo-Json
}
