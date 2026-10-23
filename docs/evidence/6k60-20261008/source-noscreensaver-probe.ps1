$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$Mode='capture-noscreensaver'
$originalText=(& powercfg /getactivescheme | Out-String)
if($LASTEXITCODE){throw 'read power scheme failed'}
$original=[regex]::Match($originalText,'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
if(!$original){throw 'power scheme GUID missing'}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SaverProbe {
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SystemParametersInfo(uint action,uint param,out uint value,uint flags);
 [DllImport("user32.dll",SetLastError=true,EntryPoint="SystemParametersInfoW")] public static extern bool Set(uint action,uint param,IntPtr value,uint flags);
}
'@
[uint32]$savedActive=0;[uint32]$savedTimeout=0
if(![SaverProbe]::SystemParametersInfo(16,0,[ref]$savedActive,0)){throw 'screensaver read failed'}
[void][SaverProbe]::SystemParametersInfo(14,0,[ref]$savedTimeout,0)
"active_before=$savedActive timeout_seconds=$savedTimeout" | Set-Content "$r\self-$Mode-saver.txt"
$running=@()
try {
 if(![SaverProbe]::Set(17,0,[IntPtr]::Zero,0)){throw 'screensaver disable failed'}
 [uint32]$actualSaver=1
 if(![SaverProbe]::SystemParametersInfo(16,0,[ref]$actualSaver,0) -or $actualSaver -ne 0){throw 'screensaver disable readback failed'}
 "active_during=$actualSaver" | Add-Content "$r\self-$Mode-saver.txt"
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
 $saverRestored=[SaverProbe]::Set(17,$savedActive,[IntPtr]::Zero,0)
 [uint32]$actualSaver=99
 [void][SaverProbe]::SystemParametersInfo(16,0,[ref]$actualSaver,0)
 "restore_ok=$saverRestored active_after=$actualSaver" | Add-Content "$r\self-$Mode-saver.txt"
 & powercfg /setactive $original
 $restoreExit=$LASTEXITCODE
 $restored=(& powercfg /getactivescheme | Out-String)
 "restore_exit=$restoreExit`nrestored=$restored" | Add-Content "$r\self-$Mode-power.txt"
 foreach($name in $running){Start-ScheduledTask -TaskName $name}
 if($restoreExit -or $restored -notmatch $original){throw "power scheme restore failed"}
}
