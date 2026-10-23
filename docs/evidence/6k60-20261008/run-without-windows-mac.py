"""Isolate Windows IVSHMEM capture from the optional Windows/Mac tasks."""
import base64,subprocess,os,json
from pathlib import Path
root=Path(__file__).resolve().parent
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(s):
    return subprocess.check_output(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(('$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";'+s).encode('utf-16le')).decode()],text=True)
snapshot=remote("Get-ScheduledTask -TaskName 'ViewflowWindowsMacSource','ViewflowWindowsMacReceiver' | Select TaskName,State | ConvertTo-Json -Compress")
(root/'windows-no-mac-tasks-before.json').write_text(snapshot)
running=[t['TaskName'] for t in json.loads(snapshot) if t['State']==4]
try:
    for name in running:remote("Stop-ScheduledTask -TaskName '"+name+"'")
    (root/'windows-no-mac-tasks-during.json').write_text(remote("Get-ScheduledTask -TaskName 'ViewflowWindowsMacSource','ViewflowWindowsMacReceiver' | Select TaskName,State | ConvertTo-Json -Compress"))
    subprocess.run(['python',str(root/'run-wgc4ms-timer.py')],env=os.environ|{'DEADLINE_RUN_SUFFIX':'windows-no-mac'},check=True)
finally:
    for name in running:remote("Start-ScheduledTask -TaskName '"+name+"'")
    (root/'windows-no-mac-tasks-after.json').write_text(remote("Get-ScheduledTask -TaskName 'ViewflowWindowsMacSource','ViewflowWindowsMacReceiver' | Select TaskName,State | ConvertTo-Json -Compress"))
