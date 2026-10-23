$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$Mode='capture-longtimeout'
$originalText=(& powercfg /getactivescheme | Out-String)
if($LASTEXITCODE){throw 'read power scheme failed'}
$original=[regex]::Match($originalText,'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
if(!$original){throw 'power scheme GUID missing'}
$raw=(& powercfg /qh SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Out-String)
$v=[regex]::Matches($raw,'0x[0-9a-fA-F]{8}')
if($v.Count -lt 2){throw 'display timeout missing'}
$oldTimeout=[Convert]::ToUInt32($v[$v.Count-2].Value.Substring(2),16)
$running=@()
try {
 & powercfg /setacvalueindex $original SUB_VIDEO VIDEOIDLE 86400
 if($LASTEXITCODE){throw 'timeout set failed'}
 "original_ac_seconds=$oldTimeout experiment_ac_seconds=86400" | Set-Content "$r\self-$Mode-timeout.txt"
 & powercfg /setactive SCHEME_BALANCED
 if($LASTEXITCODE){throw 'set balanced failed'}
 $actual=(& powercfg /getactivescheme | Out-String)
 if($LASTEXITCODE -or $actual -notmatch '381b4222-f694-41f0-9685-ff5bb260df2e'){throw 'balanced readback mismatch'}
 "original=$original`nactive=$actual" | Set-Content "$r\self-$Mode-power.txt"
 foreach($name in @('Viewflow-Windows-Linux-IVSHMEM','ViewflowWindowsMacSource','ViewflowWindowsMacReceiver')) {
  if((Get-ScheduledTask -TaskName $name).State -eq 'Running'){$running+=$name;Stop-ScheduledTask -TaskName $name}
 }
 $env:VIEWFLOW_WGC_INTERVAL_US="4000"
 Start-Sleep -Seconds 3
 $p=Start-Process -FilePath "$r\build-16k\Release\viewflow_motion_fixture.exe" -ArgumentList @("30","capture-worker","probe-topmost","wake-monitor") -NoNewWindow -Wait -PassThru -RedirectStandardError "$r\self-$Mode-fixture.log"
 if($p.ExitCode){throw "fixture exit $($p.ExitCode)"}
} finally {
 & powercfg /setacvalueindex $original SUB_VIDEO VIDEOIDLE $oldTimeout
 "restore_exit=$LASTEXITCODE" | Add-Content "$r\self-$Mode-timeout.txt"
 & powercfg /setactive $original
 $restoreExit=$LASTEXITCODE
 $restored=(& powercfg /getactivescheme | Out-String)
 "restore_exit=$restoreExit`nrestored=$restored" | Add-Content "$r\self-$Mode-power.txt"
 foreach($name in $running){Start-ScheduledTask -TaskName $name}
 if($restoreExit -or $restored -notmatch $original){throw "power scheme restore failed"}
}
