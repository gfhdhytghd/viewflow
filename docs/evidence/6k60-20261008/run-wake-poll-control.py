"""Bounded existing raw-path scheduling control; restore guest wrapper in finally."""
import base64,subprocess,os
from pathlib import Path
root=Path(__file__).resolve().parent
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(s):
 subprocess.run(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(('$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";'+s).encode('utf-16le')).decode()],check=True)
p=r'C:\Users\wilf\Viewflow\ivshmem-20261007\windows-linux.ps1';backup=p+'.before-wake-poll-control1'
remote(f"$p='{p}';$b='{backup}';if(Test-Path $b){{throw 'backup already exists'}};Copy-Item $p $b")
try:
 remote(f'''$p='{p}';[IO.File]::WriteAllText($p,"`$env:VIEWFLOW_SHM_CAPTURE_WAKE='1'`r`n`$env:VIEWFLOW_SHM_POLL_US='250'`r`n"+[IO.File]::ReadAllText($p))''')
 subprocess.run(['python3',str(root/'run-physical-deadline.py'),'enabled','5'],env=os.environ|{'DEADLINE_RUN_SUFFIX':'wake-poll-control1'},check=True)
finally:
 remote(f"Copy-Item '{backup}' '{p}' -Force;Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';Start-Sleep 2;Start-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';if((Get-FileHash '{p}').Hash -ne (Get-FileHash '{backup}').Hash){{throw 'restore mismatch'}}")
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
