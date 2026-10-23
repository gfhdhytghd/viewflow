"""Sequential bounded self-capture attribution; guest finally restores tasks."""
import base64,json,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parent
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(s):
 p='$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";$r="C:\\Users\\wilf\\Viewflow\\fusion-20261007";'
 return subprocess.check_output(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode((p+s).encode('utf-16le')).decode()],text=True)
for mode in ('capture-resumeclock1',):
 name='Viewflow-Self-'+mode+'-20261008'
 remote("$name='"+name+"';"+r'''
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'task exists'}
$a=New-ScheduledTaskAction -Execute "$r\build-16k\Release\viewflow_fusion_launcher.exe" -Argument ('-File "'+$r+'\source-resumeclock1-probe.ps1"')
$p=New-ScheduledTaskPrincipal -UserId 'wilf' -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $name -Action $a -Principal $p | Out-Null
Start-ScheduledTask -TaskName $name
''')
 while True:
  state=remote("[string](Get-ScheduledTask -TaskName '"+name+"').State").strip()
  if state not in ('Running','Queued'):break
  time.sleep(3)
 result=remote("$n='"+name+"';Get-ScheduledTaskInfo -TaskName $n | Select LastTaskResult | ConvertTo-Json -Compress;Unregister-ScheduledTask -TaskName $n -Confirm:$false")
 (root/('self-'+mode+'-result.json')).write_text(result)
 subprocess.run(['scp','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24:Viewflow/fusion-20261007/self-'+mode+'-fixture.log',str(root/('self-'+mode+'-fixture.log'))],check=True)
 print(mode,result,flush=True)
 if json.loads(result)['LastTaskResult']!=0:raise RuntimeError('fixture failed')
subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
