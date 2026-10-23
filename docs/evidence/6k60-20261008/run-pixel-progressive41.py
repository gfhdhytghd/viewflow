"""Bounded existing raw-path scheduling control; restore guest wrapper in finally."""
import base64,subprocess,os,fcntl,contextlib
from pathlib import Path
root=Path(__file__).resolve().parent
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(s):
 subprocess.run(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(('$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";'+s).encode('utf-16le')).decode()],check=True)
p=r'C:\Users\wilf\Viewflow\ivshmem-20261007\windows-linux.ps1';backup=p+'.before-pixel-progressive41'
remote(f"$p='{p}';$b='{backup}';if(Test-Path $b){{throw 'backup already exists'}};Copy-Item $p $b")
native=r'C:\Users\wilf\Viewflow\fusion-20261007\build-banks\Release\viewflow_windows_reverse.exe'
new=r'C:\Users\wilf\Viewflow\fusion-20261007\build-16k\Release\viewflow_windows_reverse.exe'
old=native+'.before-pixel-progressive41'
remote(f"if(Test-Path '{old}'){{throw 'native backup exists'}};Copy-Item '{native}' '{old}'")
probe=r'C:\Users\wilf\Viewflow\fusion-20261007\motion-probe.ps1'
probe_backup=probe+'.before-pixel-progressive41'
remote(f"if(Test-Path '{probe_backup}'){{throw 'probe backup exists'}};Copy-Item '{probe}' '{probe_backup}'")
try:
 remote(f'''$text=[IO.File]::ReadAllText('{probe}');if(-not $text.Contains("-ArgumentList '30'")){{throw 'fixture argument not found'}};$text=$text.Replace("-ArgumentList '30'","-ArgumentList '30 waitable present-zero'");[IO.File]::WriteAllText('{probe}',"`$env:VIEWFLOW_SHM_IMMEDIATE_POLL='1'`r`n`$env:VIEWFLOW_FIXTURE_PHASE_EIGHTH='7'`r`n`$env:VIEWFLOW_FIXTURE_OPAQUE='0'`r`n`$env:VIEWFLOW_FIXTURE_HIGH_RES_TIMER='1'`r`n`$env:VIEWFLOW_FIXTURE_GPU_TRACE='1'`r`n`$env:VIEWFLOW_WGC_DELIVERY_TRACE='1'`r`n`$env:VIEWFLOW_WGC_POLL_READY='0'`r`n`$env:VIEWFLOW_WGC_GPU_PRIORITY='0'`r`n`$env:VIEWFLOW_WGC_INTERVAL_US='0'`r`n`$env:VIEWFLOW_SHM_PROGRESSIVE='1'`r`n`$env:VIEWFLOW_ASYNC_TRACE='1'`r`n`$env:VIEWFLOW_FIXTURE_PIXEL_STAMP='1'`r`n`$env:VIEWFLOW_SHM_CAPTURE_BANDS='2'`r`n`$env:VIEWFLOW_SHM_BAND_TRACE='1'`r`n`$env:VIEWFLOW_SHM_BAND_FLUSH='1'`r`n"+$text)''')
 remote(f"Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';Start-Sleep 2;Copy-Item '{new}' '{native}' -Force;Start-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM'")
 remote(f'''$p='{p}';[IO.File]::WriteAllText($p,"`$env:VIEWFLOW_SHM_IMMEDIATE_POLL='1'`r`n`$env:VIEWFLOW_FIXTURE_PHASE_EIGHTH='7'`r`n`$env:VIEWFLOW_FIXTURE_OPAQUE='0'`r`n`$env:VIEWFLOW_FIXTURE_HIGH_RES_TIMER='1'`r`n`$env:VIEWFLOW_FIXTURE_GPU_TRACE='1'`r`n`$env:VIEWFLOW_WGC_DELIVERY_TRACE='1'`r`n`$env:VIEWFLOW_WGC_POLL_READY='0'`r`n`$env:VIEWFLOW_WGC_GPU_PRIORITY='0'`r`n`$env:VIEWFLOW_WGC_INTERVAL_US='0'`r`n`$env:VIEWFLOW_SHM_PROGRESSIVE='1'`r`n`$env:VIEWFLOW_ASYNC_TRACE='1'`r`n`$env:VIEWFLOW_FIXTURE_PIXEL_STAMP='1'`r`n`$env:VIEWFLOW_SHM_CAPTURE_BANDS='2'`r`n`$env:VIEWFLOW_SHM_BAND_TRACE='1'`r`n`$env:VIEWFLOW_SHM_BAND_FLUSH='1'`r`n"+[IO.File]::ReadAllText($p))''')
 subprocess.run(['python3',str(root/'run-visible-baseline.py')],env=os.environ|{'MOTION_TAG':'physical-pixel-progressive41'},check=True)
finally:
 subprocess.run(['systemctl','--user','stop','viewflow-ivshmem-windows.service'],check=True)
 remote("Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';Start-Sleep 2")
 # Host locks exclude every host Mapping; guest utility owns writer mutex.
 with contextlib.ExitStack() as locks:
  for suffix in ['', '.slot0', '.slot1', '.slot2', '.slot3']:
   f=locks.enter_context(open('/dev/shm/viewflow-frames'+suffix,'r+b'))
   fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
  remote("& 'C:\\Users\\wilf\\Viewflow\\fusion-20261007\\build-16k\\Release\\viewflow_shared_recovery.exe' --host-mappings-locked;if($LASTEXITCODE){throw 'shared recovery failed'}")
 remote(f"Copy-Item '{probe_backup}' '{probe}' -Force;if((Get-FileHash '{probe}').Hash -ne (Get-FileHash '{probe_backup}').Hash){{throw 'probe restore mismatch'}}")
 remote(f"Copy-Item '{backup}' '{p}' -Force;Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';Start-Sleep 2;Copy-Item '{old}' '{native}' -Force;Start-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM';if((Get-FileHash '{old}').Hash -ne (Get-FileHash '{native}').Hash){{throw 'binary restore mismatch'}};if((Get-FileHash '{p}').Hash -ne (Get-FileHash '{backup}').Hash){{throw 'restore mismatch'}}")
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
