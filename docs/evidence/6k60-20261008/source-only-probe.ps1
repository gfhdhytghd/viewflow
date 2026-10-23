$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$running=@()
try {
 foreach($name in @('Viewflow-Windows-Linux-IVSHMEM','ViewflowWindowsMacSource','ViewflowWindowsMacReceiver')) {
  if((Get-ScheduledTask -TaskName $name).State -eq 'Running'){$running+=$name;Stop-ScheduledTask -TaskName $name}
 }
 Start-Sleep -Seconds 3
 $p=Start-Process -FilePath "$r\build-16k\Release\viewflow_motion_fixture.exe" -ArgumentList @("30") -NoNewWindow -Wait -PassThru -RedirectStandardError "$r\source-only-fixture-native.log"
 if($p.ExitCode){throw "fixture exit $($p.ExitCode)"}
} finally {
 foreach($name in $running){Start-ScheduledTask -TaskName $name}
}
