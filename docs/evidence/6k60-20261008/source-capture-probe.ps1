param([ValidateSet("capture-only","capture-staging","capture-map","capture-copy","capture-worker","capture-worker1","capture-worker2","capture-memcpy","capture-halfcopy","capture-ramcopy")][string]$Mode)
$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$running=@()
try {
 foreach($name in @('Viewflow-Windows-Linux-IVSHMEM','ViewflowWindowsMacSource','ViewflowWindowsMacReceiver')) {
  if((Get-ScheduledTask -TaskName $name).State -eq 'Running'){$running+=$name;Stop-ScheduledTask -TaskName $name}
 }
 $env:VIEWFLOW_WGC_INTERVAL_US="4000"
 Start-Sleep -Seconds 3
 $p=Start-Process -FilePath "$r\build-16k\Release\viewflow_motion_fixture.exe" -ArgumentList @("30",$Mode) -NoNewWindow -Wait -PassThru -RedirectStandardError "$r\self-$Mode-fixture.log"
 if($p.ExitCode){throw "fixture exit $($p.ExitCode)"}
} finally {
 foreach($name in $running){Start-ScheduledTask -TaskName $name}
}
