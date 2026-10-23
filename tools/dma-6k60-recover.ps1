param([string]$RunDirectory)
# Called only after the temporary scheduled task is terminal, outside its GUI job.
$ErrorActionPreference='Stop'
$result=@{status='not-needed';forced_job_cleanup_is_not_graceful=$true}
try {
 $before=Get-Content (Join-Path $RunDirectory 'before.json') -Raw | ConvertFrom-Json
 $normal='Viewflow-Windows-Linux-IVSHMEM'
 if($before.normal_running -and (Get-ScheduledTask -TaskName $normal).State -ne 'Running') {
  $old=Get-Content (Join-Path $RunDirectory 'normal-stop.json') -Raw | ConvertFrom-Json
  $nativePath=Join-Path $RunDirectory 'owned-native.json'
  if(-not (Test-Path $nativePath)){throw 'Missing owned-native identity evidence'}
  $native=@(Get-Content $nativePath -Raw | ConvertFrom-Json)
  $identities=@($old.processes)+$native
  if(-not $old.processes){throw 'Missing original normal process identities'}
  $blocked=Join-Path $RunDirectory 'drain-blocked.json'
  if(Test-Path $blocked){
   $record=Get-Content $blocked -Raw | ConvertFrom-Json
   foreach($pidValue in $record.pids){if(-not @($native | Where-Object {$_.Id -eq $pidValue}).Count){throw "Missing identity for blocked PID $pidValue"}}
  }
  foreach($identity in $identities){
   if(-not $identity.Id -or -not $identity.StartTimeUtcTicks){throw 'Missing PID/start-time identity; refusing PID-only inference'}
   $current=Get-Process -Id $identity.Id -ErrorAction SilentlyContinue
   if($current){
    $null=$current.Handle
    if([string]$current.StartTime.ToUniversalTime().Ticks -eq [string]$identity.StartTimeUtcTicks){
     if(-not $current.WaitForExit(20000)){throw "Original process $($identity.Id) remains alive"}
    }
   }
  }
  Start-ScheduledTask -TaskName $normal
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  do {$state=[string](Get-ScheduledTask -TaskName $normal).State;if($state -eq 'Running'){break};Start-Sleep -Milliseconds 200} while([DateTime]::UtcNow -lt $deadline)
  if($state -ne 'Running'){throw "Normal restore readback $state"}
  $result.status='restored-after-confirmed-original-process-exit';$result.normal_state=$state
 }
} catch {$result.status='blocked';$result.reason=$_.Exception.Message}
$result | ConvertTo-Json -Compress
