$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new();
$r='C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc';$label='probe-mask-ab';$mode='mask-toggle';$probe='ViewflowPerf-MaskUpdateProbe';$observer='ViewflowPerf-MaskUpdateProbeObserver';$exe=$r+'\viewflow_windows_mask_update_probe.exe';$dd=$r+'\native-build\Release\viewflow_windows_frame_observer.exe';$pidSeen=0;$registeredProbe=$false;$registeredObserver=$false;$probeResult=-1;$observerResult=-1;
if(Get-ScheduledTask -TaskName $probe,$observer -ErrorAction SilentlyContinue){throw 'probe task already exists'};
if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq $exe -or $_.ExecutablePath -eq $dd}).Count){throw 'probe or observer already running'};
$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;
$desktopUser=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $desktopUser -or $desktopUser.Split('\')[-1] -ne $principal.UserId.Split('\')[-1]){throw 'interactive test user is not logged on; no test task registered'};
try {
 $args=$mode+' 33000 "'+$r+'\'+$label+'-probe.log"';
 Register-ScheduledTask -TaskName $probe -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument $args -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registeredProbe=$true;Start-ScheduledTask -TaskName $probe;
 for($i=0;$i -lt 60;$i++){ $p=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe);if($p.Count -eq 1){$pidSeen=$p[0].ProcessId;break};Start-Sleep -Milliseconds 200 };
 if(-not $pidSeen){$info=Get-ScheduledTaskInfo -TaskName $probe;throw ('probe process did not start; task result='+$info.LastTaskResult)};
 $args=$pidSeen.ToString()+' 30000 "'+$r+'\'+$label+'-desktop.log" physical4k timer1';
 Register-ScheduledTask -TaskName $observer -Principal $principal -Action (New-ScheduledTaskAction -Execute $dd -Argument $args -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registeredObserver=$true;Start-ScheduledTask -TaskName $observer;
 Start-Sleep -Milliseconds 500;
 $started=Get-Date;
 do { $p=Get-Process -Id $pidSeen -ErrorAction SilentlyContinue;$o=Get-ScheduledTask -TaskName $observer; if(-not $p -and $o.State -ne 'Running'){break};if(((Get-Date)-$started).TotalSeconds -gt 70){throw 'probe operation did not finish'};Start-Sleep -Milliseconds 500 } while($true);
 $probeResult=(Get-ScheduledTaskInfo -TaskName $probe).LastTaskResult;$observerResult=(Get-ScheduledTaskInfo -TaskName $observer).LastTaskResult;
 if($probeResult -ne 0 -or $observerResult -ne 0){throw ('probe/observer failed '+$probeResult+'/'+$observerResult)};
} finally {
 if($registeredObserver){if((Get-ScheduledTask -TaskName $observer).State -eq 'Running'){Stop-ScheduledTask -TaskName $observer};Unregister-ScheduledTask -TaskName $observer -Confirm:$false};
 if($registeredProbe){if((Get-ScheduledTask -TaskName $probe).State -eq 'Running'){Stop-ScheduledTask -TaskName $probe};Unregister-ScheduledTask -TaskName $probe -Confirm:$false};
 $owned=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq $exe -or $_.ExecutablePath -eq $dd});
 @{label=$label;mode=$mode;pid=$pidSeen;probe_exit=$probeResult;observer_exit=$observerResult;owned_processes=$owned.Count;owned_tasks=@(Get-ScheduledTask -TaskName $probe,$observer -ErrorAction SilentlyContinue).Count;probe_hash=(Get-FileHash $exe).Hash;observer_hash=(Get-FileHash $dd).Hash;time=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -Encoding UTF8 ($r+'\'+$label+'-state.json');
}
Get-Content ($r+'\'+$label+'-state.json');
