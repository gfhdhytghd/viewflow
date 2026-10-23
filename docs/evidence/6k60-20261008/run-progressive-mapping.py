"""Bounded CPU cross-VM probe; normal endpoint binaries/config remain unchanged."""
import base64, subprocess, time, os
from pathlib import Path
root=Path(__file__).resolve().parent
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def command(s):
 return ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(('$ErrorActionPreference="Stop";'+s).encode('utf-16le')).decode()]
def remote(s):
 return subprocess.run(command(s),check=True,capture_output=True,text=True,errors="replace",timeout=45).stdout
unit='viewflow-ivshmem-windows.service'; task='Viewflow-Windows-Linux-IVSHMEM'
assert subprocess.run(['systemctl','--user','is-active','--quiet',unit]).returncode==0
assert 'Running' in remote(f"(Get-ScheduledTask -TaskName '{task}').State")
epoch=time.time_ns(); reader=None; writer=None
try:
 remote(f"Stop-ScheduledTask -TaskName '{task}';Start-Sleep -Seconds 2")
 subprocess.run(['systemctl','--user','stop',unit],check=True)
 reader=subprocess.Popen([os.environ.get('VIEWFLOW_MAPPING_PROBE','build/ivshmem-linux/progressive-mapping-probe'),'/dev/shm/viewflow-frames',str(epoch)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,errors="replace")
 writer=subprocess.Popen(command(f"& 'C:\\Users\\wilf\\Viewflow\\fusion-20261007\\build-16k\\Release\\viewflow_progressive_mapping_probe.exe' 0 {epoch};exit $LASTEXITCODE"),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,errors="replace")
 wo,we=writer.communicate(timeout=40);ro,re=reader.communicate(timeout=5)
 report=f'epoch={epoch}\nwriter_exit={writer.returncode}\n{wo}{we}\nreader_exit={reader.returncode}\n{ro}{re}'
 (root/f'progressive-mapping-{epoch}.log').write_text(report)
 print(report)
 assert writer.returncode==reader.returncode==0
finally:
 for p in (writer,reader):
  if p is not None and p.poll() is None:
   p.terminate();p.wait(timeout=5)
 # Guest probe has its own 30s deadline even if SSH transport is interrupted.
 try:
  remote(f"Start-ScheduledTask -TaskName '{task}';(Get-ScheduledTask -TaskName '{task}').State")
 finally:
  subprocess.run(['systemctl','--user','start',unit],check=True)
 subprocess.run(['systemctl','--user','is-active',unit],check=True)
