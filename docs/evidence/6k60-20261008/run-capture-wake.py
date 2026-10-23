import subprocess,base64,os
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(s):
 subprocess.run(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(('$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";'+s).encode('utf-16le')).decode()],check=True)
remote(r'''
$r='C:\Users\wilf\Viewflow\fusion-20261007'
Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';Start-Sleep 2
try {Copy-Item "$r\build-16k\Release\viewflow_windows_reverse.exe" "$r\build-banks\Release\viewflow_windows_reverse.exe" -Force}
finally {Start-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM'}
''')
try:
 remote(r'''
$p='C:\Users\wilf\Viewflow\ivshmem-20261007\windows-linux.ps1'
Copy-Item $p "$p.before-capture-wake" -Force
[IO.File]::WriteAllText($p,"$"+"env:VIEWFLOW_SHM_CAPTURE_WAKE='1'`r`n`$env:VIEWFLOW_SHM_COPY_THREADS='4'`r`n"+[IO.File]::ReadAllText($p))
''')
 subprocess.run(['python','docs/evidence/6k60-20261008/run-physical-deadline.py','enabled','3'],env=os.environ|{'DEADLINE_RUN_SUFFIX':'capture-wake'},check=True)
finally:
 remote(r'''
$p='C:\Users\wilf\Viewflow\ivshmem-20261007\windows-linux.ps1'
Copy-Item "$p.before-capture-wake" $p -Force
Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';Start-Sleep 2;Start-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM'
''')
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
