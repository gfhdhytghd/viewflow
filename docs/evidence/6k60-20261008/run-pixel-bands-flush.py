"""Bounded existing raw-path scheduling control; restore guest wrapper in finally."""
import base64,subprocess,os
from pathlib import Path
root=Path(__file__).resolve().parent
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(s):
 subprocess.run(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(('$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";'+s).encode('utf-16le')).decode()],check=True)
p=r'C:\Users\wilf\Viewflow\ivshmem-20261007\windows-linux.ps1';backup=p+'.before-pixel-bands-flush1'
remote(f"$p='{p}';$b='{backup}';if(Test-Path $b){{throw 'backup already exists'}};Copy-Item $p $b")
native=r'C:\Users\wilf\Viewflow\fusion-20261007\build-banks\Release\viewflow_windows_reverse.exe'
new=r'C:\Users\wilf\Viewflow\fusion-20261007\build-16k\Release\viewflow_windows_reverse.exe'
old=native+'.before-pixel-bands-flush1'
remote(f"if(Test-Path '{old}'){{throw 'native backup exists'}};Copy-Item '{native}' '{old}'")
probe=r'C:\Users\wilf\Viewflow\fusion-20261007\motion-probe.ps1'
probe_backup=probe+'.before-pixel-bands-flush1'
remote(f"if(Test-Path '{probe_backup}'){{throw 'probe backup exists'}};Copy-Item '{probe}' '{probe_backup}'")
try:
 remote(f'''$text=[IO.File]::ReadAllText('{probe}');if(-not $text.Contains("-ArgumentList '30'")){{throw 'fixture argument not found'}};$text=$text.Replace("-ArgumentList '30'","-ArgumentList '30 waitable present-zero'");[IO.File]::WriteAllText('{probe}',"`$env:VIEWFLOW_FIXTURE_PIXEL_STAMP='1'`r`n`$env:VIEWFLOW_SHM_CAPTURE_BANDS='4'`r`n`$env:VIEWFLOW_SHM_BAND_TRACE='1'`r`n`$env:VIEWFLOW_SHM_BAND_FLUSH='1'`r`n"+$text)''')
 remote(f"Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';Start-Sleep 2;Copy-Item '{new}' '{native}' -Force;Start-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM'")
 remote(f'''$p='{p}';[IO.File]::WriteAllText($p,"`$env:VIEWFLOW_FIXTURE_PIXEL_STAMP='1'`r`n`$env:VIEWFLOW_SHM_CAPTURE_BANDS='4'`r`n`$env:VIEWFLOW_SHM_BAND_TRACE='1'`r`n`$env:VIEWFLOW_SHM_BAND_FLUSH='1'`r`n"+[IO.File]::ReadAllText($p))''')
 subprocess.run(['python3',str(root/'run-visible-baseline.py')],env=os.environ|{'MOTION_TAG':'physical-pixel-bands-flush1'},check=True)
finally:
 remote(f"Copy-Item '{probe_backup}' '{probe}' -Force;if((Get-FileHash '{probe}').Hash -ne (Get-FileHash '{probe_backup}').Hash){{throw 'probe restore mismatch'}}")
 remote(f"Copy-Item '{backup}' '{p}' -Force;Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';Start-Sleep 2;Copy-Item '{old}' '{native}' -Force;Start-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';if((Get-FileHash '{old}').Hash -ne (Get-FileHash '{native}').Hash){{throw 'binary restore mismatch'}};if((Get-FileHash '{p}').Hash -ne (Get-FileHash '{backup}').Hash){{throw 'restore mismatch'}}")
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
