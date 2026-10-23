
$r='C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\passive-blur-validation-20260908';$task='ViewflowPerf-PassiveBlurOracle';$exe=$r+'\native-build\Release\viewflow_sparse_host_backdrop_test.exe';$registered=$false;
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'task exists'};
if(@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count){throw 'probe already running'};
$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;
$desktopUser=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $desktopUser -or $desktopUser.Split('\')[-1] -ne $principal.UserId.Split('\')[-1]){throw 'interactive user mismatch'};
$before=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);$code=-1;
try {
 Register-ScheduledTask -TaskName $task -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registered=$true;Start-ScheduledTask -TaskName $task;
 Start-Sleep -Seconds 2;$started=Get-Date;
 while((Get-ScheduledTask -TaskName $task).State -eq 'Running'){if(((Get-Date)-$started).TotalSeconds -gt 45){throw 'probe timeout'};Start-Sleep -Milliseconds 500};$code=(Get-ScheduledTaskInfo -TaskName $task).LastTaskResult;
} finally {
 if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};
 [pscustomobject]@{exit=$code;exe=(Get-FileHash $exe|Select-Object Path,Hash);remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count;esrv_before=$before;esrv_after=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass)}|ConvertTo-Json -Depth 5
};exit $code
