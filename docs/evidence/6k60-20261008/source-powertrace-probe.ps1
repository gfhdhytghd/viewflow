$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$Mode='capture-powertrace'
$originalText=(& powercfg /getactivescheme | Out-String)
if($LASTEXITCODE){throw 'read power scheme failed'}
$original=[regex]::Match($originalText,'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
if(!$original){throw 'power scheme GUID missing'}
$running=@()
$traceStarted=$false
try {
 & logman start ViewflowPowerProbe -p Microsoft-Windows-Kernel-Power 0xffffffffffffffff 5 -o "$r\power-probe.etl" -f bincirc -max 16 -ets
 if($LASTEXITCODE){throw 'power trace start failed'}
 $traceStarted=$true
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
 if($traceStarted){& logman stop ViewflowPowerProbe -ets}
 & powercfg /setactive $original
 $restoreExit=$LASTEXITCODE
 $restored=(& powercfg /getactivescheme | Out-String)
 "restore_exit=$restoreExit`nrestored=$restored" | Add-Content "$r\self-$Mode-power.txt"
 foreach($name in $running){Start-ScheduledTask -TaskName $name}
 if($restoreExit -or $restored -notmatch $original){throw "power scheme restore failed"}
}

& tracerpt "$r\power-probe.etl" -o "$r\power-probe.xml" -of XML -y
if($LASTEXITCODE){throw "power trace decode failed"}
