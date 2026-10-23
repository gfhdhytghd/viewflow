$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$Mode='capture-notimeout2'
$originalText=(& powercfg /getactivescheme | Out-String)
if($LASTEXITCODE){throw 'read power scheme failed'}
$original=[regex]::Match($originalText,'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
if(!$original){throw 'power scheme GUID missing'}
$running=@()
try {
 foreach($setting in @(@('AC','VIDEOCONLOCK',60),@('DC','VIDEOCONLOCK',60),@('DC','VIDEOIDLE',180))) {
  $raw=(& powercfg /qh SCHEME_CURRENT SUB_VIDEO $setting[1] | Out-String)
  $values=[regex]::Matches($raw,'0x[0-9a-fA-F]{8}')
  if($values.Count -lt 2){throw 'timeout readback missing'}
  $index=if($setting[0] -eq 'AC'){$values.Count-2}else{$values.Count-1}
  if([Convert]::ToInt32($values[$index].Value.Substring(2),16) -ne $setting[2]){throw 'timeout baseline differs'}
 }
 & powercfg /setacvalueindex $original SUB_VIDEO VIDEOCONLOCK 0
 if($LASTEXITCODE){throw 'AC lock timeout set failed'}
 & powercfg /setdcvalueindex $original SUB_VIDEO VIDEOCONLOCK 0
 if($LASTEXITCODE){throw 'DC lock timeout set failed'}
 & powercfg /setdcvalueindex $original SUB_VIDEO VIDEOIDLE 0
 if($LASTEXITCODE){throw 'DC display timeout set failed'}
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
 & powercfg /setacvalueindex $original SUB_VIDEO VIDEOCONLOCK 60
 & powercfg /setdcvalueindex $original SUB_VIDEO VIDEOCONLOCK 60
 & powercfg /setdcvalueindex $original SUB_VIDEO VIDEOIDLE 180
 & powercfg /setactive $original
 $restoreExit=$LASTEXITCODE
 $restored=(& powercfg /getactivescheme | Out-String)
 "restore_exit=$restoreExit`nrestored=$restored" | Add-Content "$r\self-$Mode-power.txt"
 foreach($name in $running){Start-ScheduledTask -TaskName $name}
 if($restoreExit -or $restored -notmatch $original){throw "power scheme restore failed"}
}
