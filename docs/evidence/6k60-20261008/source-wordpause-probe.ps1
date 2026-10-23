$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$Mode='capture-wordpause'
$originalText=(& powercfg /getactivescheme | Out-String)
if($LASTEXITCODE){throw 'read power scheme failed'}
$original=[regex]::Match($originalText,'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
if(!$original){throw 'power scheme GUID missing'}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WordProbePause {
 [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr OpenProcess(uint rights,bool inherit,uint pid);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
 [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
 [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
}
'@
$word=Get-Process -Id 8456 -ErrorAction Stop
if($word.ProcessName -ne 'WINWORD'){throw 'Word PID identity changed'}
$wordHandle=[WordProbePause]::OpenProcess(0x800,$false,8456)
if($wordHandle -eq [IntPtr]::Zero){throw 'Word process handle unavailable'}
$wordSuspended=$false
$running=@()
try {
 if([WordProbePause]::NtSuspendProcess($wordHandle) -ne 0){throw 'Word suspend failed'}
 $wordSuspended=$true
 "suspended_pid=8456 start=$($word.StartTime.ToUniversalTime().ToString('o'))" | Set-Content "$r\self-$Mode-word.txt"
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
 if($wordSuspended){$resume=[WordProbePause]::NtResumeProcess($wordHandle);"resume_status=$resume" | Add-Content "$r\self-$Mode-word.txt"}
 [void][WordProbePause]::CloseHandle($wordHandle)
 & powercfg /setactive $original
 $restoreExit=$LASTEXITCODE
 $restored=(& powercfg /getactivescheme | Out-String)
 "restore_exit=$restoreExit`nrestored=$restored" | Add-Content "$r\self-$Mode-power.txt"
 foreach($name in $running){Start-ScheduledTask -TaskName $name}
 if($restoreExit -or $restored -notmatch $original){throw "power scheme restore failed"}
}
