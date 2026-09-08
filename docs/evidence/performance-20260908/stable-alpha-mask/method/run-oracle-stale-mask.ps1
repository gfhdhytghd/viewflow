$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$r='C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc';$exe=$r+'\viewflow_sparse_alpha_mask_test.exe';$task='ViewflowPerf-AlphaMaskOracle';$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;$user=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $user -or $user.Split('\')[-1] -ne $principal.UserId.Split('\')[-1]){throw 'interactive test user is not logged on'};
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'oracle task exists'};if(@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count){throw 'oracle process already exists'};
$registered=$false;$result=-1;
try {
 $a=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $r;
 if('stale-mask' -ne 'positive'){$a=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $r -Argument 'stale-mask'};
 Register-ScheduledTask -TaskName $task -Principal $principal -Action $a -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registered=$true;
 $started=Get-Date;Start-ScheduledTask -TaskName $task;Start-Sleep -Milliseconds 500;
 do {$t=Get-ScheduledTask -TaskName $task;$i=Get-ScheduledTaskInfo -TaskName $task;if($t.State -ne 'Running' -and $i.LastRunTime -ge $started.AddSeconds(-2)){break};if(((Get-Date)-$started).TotalSeconds -gt 70){throw 'oracle operation timeout'};Start-Sleep -Milliseconds 250}while($true);
 $result=$i.LastTaskResult;Copy-Item ($r+'\alpha-mask-result.log') ($r+'\alpha-mask-stale-mask.log');if($result -ne 1){throw ('unexpected oracle result '+$result)};
} finally {
 if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};
 @{mode='stale-mask';result=$result;expected=1;remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count;exe=(Get-FileHash $exe|Select-Object Path,Hash);time=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 4|Set-Content -Encoding UTF8 ($r+'\alpha-mask-stale-mask-state.json');
}
Get-Content ($r+'\alpha-mask-stale-mask-state.json');
