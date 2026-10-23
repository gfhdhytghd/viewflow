$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$Mode='capture-powerperf'
$originalText=(& powercfg /getactivescheme | Out-String)
if($LASTEXITCODE){throw 'read power scheme failed'}
$original=[regex]::Match($originalText,'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
if(!$original){throw 'power scheme GUID missing'}
$running=@()
try {
 & powercfg /setactive SCHEME_MIN
 if($LASTEXITCODE){throw 'set high performance failed'}
 $actual=(& powercfg /getactivescheme | Out-String)
 if($LASTEXITCODE -or $actual -notmatch '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'){throw 'high performance readback mismatch'}
 "original=$original`nactive=$actual" | Set-Content "$r\self-$Mode-power.txt"
 foreach($name in @('Viewflow-Windows-Linux-IVSHMEM','ViewflowWindowsMacSource','ViewflowWindowsMacReceiver')) {
  if((Get-ScheduledTask -TaskName $name).State -eq 'Running'){$running+=$name;Stop-ScheduledTask -TaskName $name}
 }
 $env:VIEWFLOW_WGC_INTERVAL_US="4000"
 Start-Sleep -Seconds 3
 $p=Start-Process -FilePath "$r\build-16k\Release\viewflow_motion_fixture.exe" -ArgumentList @("30","capture-worker") -NoNewWindow -Wait -PassThru -RedirectStandardError "$r\self-$Mode-fixture.log"
 if($p.ExitCode){throw "fixture exit $($p.ExitCode)"}
} finally {
 & powercfg /setactive $original
 $restoreExit=$LASTEXITCODE
 $restored=(& powercfg /getactivescheme | Out-String)
 "restore_exit=$restoreExit`nrestored=$restored" | Add-Content "$r\self-$Mode-power.txt"
 foreach($name in $running){Start-ScheduledTask -TaskName $name}
 if($restoreExit -or $restored -notmatch $original){throw "power scheme restore failed"}
}
