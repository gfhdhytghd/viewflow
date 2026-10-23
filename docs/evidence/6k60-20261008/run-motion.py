"""Nonactivating fixture; no input injection. Run all timed steps together."""
import subprocess,time,base64,os,json,importlib.util
from pathlib import Path
root=Path(__file__).resolve().parent
repo=root.parents[2]
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
tag=os.environ.get('MOTION_TAG','exact-motion-repeat')
def remote(script):
 return subprocess.run(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(('$ErrorActionPreference="Stop";'+script).encode('utf-16le')).decode()],check=True,capture_output=True).stdout
spec=importlib.util.spec_from_file_location('fusion',repo/'tools/windows-fusion.py');fusion=importlib.util.module_from_spec(spec);spec.loader.exec_module(fusion)
env=fusion.hyprland_env()
def state(suffix):
 for cmd in ['activewindow','clients','monitors']:
  (root/f'{tag}-{suffix}-{cmd}.json').write_bytes(subprocess.check_output(['hyprctl','-j',cmd],env=env))
def clock(suffix):
 with (root/f'{tag}-clock-{suffix}.json').open('wb') as f:subprocess.run(['python',str(root/'measure-clock.py')],stdout=f,check=True)
start=str(int(time.time()))
state('before');clock('start')
try:
 previous=json.loads(remote("Get-ScheduledTask -TaskName 'Viewflow-6K-Motion-Probe' | Select State | ConvertTo-Json -Compress"))
 if previous['State']==4:raise RuntimeError('motion task already running; observe existing task instead')
 remote("Start-ScheduledTask -TaskName 'Viewflow-6K-Motion-Probe'")
 time.sleep(3)
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
 time.sleep(10);state('during')
 time.sleep(20)
 # Fixed sleep is not task completion. Observe this task until terminal before
 # reading its logs or letting outer restoration replace the running binaries.
 while True:
  observed=json.loads(remote("Get-ScheduledTask -TaskName 'Viewflow-6K-Motion-Probe' | Select State | ConvertTo-Json -Compress"))
  if observed['State']!=4:break
  time.sleep(1)
 result=json.loads(remote("Get-ScheduledTaskInfo -TaskName 'Viewflow-6K-Motion-Probe' | Select LastTaskResult | ConvertTo-Json -Compress"))
 if result['LastTaskResult']!=0:raise RuntimeError('motion task failed: '+str(result))
 clock('end')
 for name,filename in [('guest','motion-source.log'),('generator','motion-fixture.log')]:
  data=remote("[Console]::Write([IO.File]::ReadAllText('C:\\Users\\wilf\\Viewflow\\fusion-20261007\\"+filename+"'))")
  (root/f'{tag}-{name}.log').write_bytes(data)
finally:
 # Wrapper's finally restores the normal task after the fixture exits.
 status=remote("Get-ScheduledTask -TaskName 'Viewflow-6K-Motion-Probe' | Select State | ConvertTo-Json -Compress")
 (root/f'{tag}-task.json').write_bytes(status)
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
 state('after')
 with (root/f'{tag}-host.log').open('wb') as f:
  subprocess.run(['journalctl','--user','-u','viewflow-ivshmem-windows.service','--since','@'+start,'--no-pager','-o','short-precise'],stdout=f,check=True)
print(tag,flush=True)
