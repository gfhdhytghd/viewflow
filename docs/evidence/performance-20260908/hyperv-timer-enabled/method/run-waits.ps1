
$root='C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\hyperv-timer-enabled-20260909';$name='ViewflowPerf-HypervWaitResolution';$state=@{};
$state.before_esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);
$state.binary=Get-FileHash ($root+'\wait-resolution-probe.exe')|Select-Object Path,Hash;
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'task exists'}
try {
 $principal=(Get-ScheduledTask -TaskName 'ViewflowMain-Active').Principal;
 $action=New-ScheduledTaskAction -Execute ($root+'\wait-resolution-probe.exe') -Argument ('"'+$root+'\wait-resolution.log"') -WorkingDirectory $root;
 Register-ScheduledTask -TaskName $name -Principal $principal -Action $action -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1))|Out-Null;
 Start-ScheduledTask -TaskName $name;
 $deadline=(Get-Date).AddSeconds(40);
 do {Start-Sleep -Milliseconds 250;$task=Get-ScheduledTask -TaskName $name;$info=Get-ScheduledTaskInfo -TaskName $name} while (($task.State -eq 'Running' -or $info.LastTaskResult -eq 267011) -and (Get-Date) -lt $deadline);
 $state.result=$info.LastTaskResult;
 if($task.State -eq 'Running'){throw 'probe did not terminate'};
 if($state.result -ne 0){throw ('probe failed '+$state.result)};
} finally {
 $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;
 if($task){if($task.State -eq 'Running'){Stop-ScheduledTask -TaskName $name};Unregister-ScheduledTask -TaskName $name -Confirm:$false};
 $state.remaining=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq ($root+'\wait-resolution-probe.exe')}).Count;
 $state.tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -eq $name}).Count;
 $state.after_esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);
 $state|ConvertTo-Json -Depth 5|Set-Content -Encoding utf8 ($root+'\state.json');
}
