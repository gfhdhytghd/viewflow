import subprocess,time,json,os
from pathlib import Path
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(s): subprocess.run(ssh+['powershell -NoProfile -Command '+s],check=True,stdout=subprocess.DEVNULL)
root=Path('docs/evidence/6k60-20261008')
tag=os.environ.get('PROBE_TAG','baseline')
subprocess.run(['systemctl','--user','stop','viewflow-ivshmem-windows.service'],check=True)
try:
 remote("Stop-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM'")
 time.sleep(2)
 with (root/(tag+'-linux.log')).open('wb') as ll,(root/(tag+'-windows.log')).open('wb') as wl:
  receiver=subprocess.Popen(['build/ivshmem-linux/viewflow_shared_probe','/dev/shm/viewflow-frames']+(['--performance'] if '--performance' in os.environ.get('PROBE_ARGS','--performance') else []),stdin=subprocess.PIPE,stdout=ll,stderr=ll)
  sender=subprocess.Popen(ssh+['C:/Users/wilf/Viewflow/fusion-20261007/build-banks/Release/viewflow_shared_probe.exe '+os.environ.get('PROBE_ARGS','6144 3456 300 0 --performance')],stdout=receiver.stdin,stderr=wl)
  receiver.stdin.close()
  try:
   a=sender.wait(timeout=90);b=receiver.wait(timeout=90)
   print(json.dumps({'sender':a,'receiver':b}))
  finally:
   for p in [sender,receiver]:
    if p.poll() is None:p.terminate();p.wait()
finally:
 remote("Start-ScheduledTask -TaskName 'Viewflow-Windows-Linux-IVSHMEM'")
 subprocess.run(['systemctl','--user','start','viewflow-ivshmem-windows.service'],check=True)
for p in root.glob(tag+'-*.log'):print(p, p.read_text())
