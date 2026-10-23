"""Guest-owned timeout/restore guard encloses the physical 6K experiment."""
import base64,json,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parent
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(script):
    pre=r'''$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$r='C:\Users\wilf\Viewflow\fusion-20261007';$work="$r\refresh120";$name='Viewflow-Refresh120-Guard-20261008';'''
    return subprocess.check_output(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode((pre+script).encode('utf-16le')).decode()],text=True)
remote(r'''
if(Test-Path $work){throw 'previous refresh test directory exists; inspect it'}
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'guard task exists'}
$parseErrors=$null;$tokens=$null
[Management.Automation.Language.Parser]::ParseFile("$r\refresh120-session.ps1",[ref]$tokens,[ref]$parseErrors) | Out-Null
if($parseErrors.Count){throw ($parseErrors | Out-String)}
$action=New-ScheduledTaskAction -Execute "$r\build-16k\Release\viewflow_fusion_launcher.exe" -Argument ('-File "'+$r+'\refresh120-session.ps1"')
$principal=New-ScheduledTaskPrincipal -UserId 'wilf' -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $name
''')
try:
    for _ in range(45):
        status=remote(r'''if(Test-Path "$work\done"){'DONE'}elseif(Test-Path "$work\ready"){'READY'}else{(Get-ScheduledTask -TaskName $name).State}''').strip()
        if status=='READY':break
        if status=='DONE':raise RuntimeError('guest preparation ended before ready; inspect restoration logs')
        if status not in ('Running','Queued'):raise RuntimeError('guard not running before ready: '+status)
        time.sleep(1)
    else:raise RuntimeError('mode preparation observation timed out; guard retains automatic restore')
    subprocess.run(['python',str(root/'run-refresh120-transport.py')],check=True)
finally:
    remote(r'''if(Test-Path $work){'finish' | Set-Content "$work\finish"}''')
    for _ in range(45):
        status=remote(r'''if(Test-Path "$work\done"){'DONE'}else{(Get-ScheduledTask -TaskName $name).State}''').strip()
        if status=='DONE':break
        if status not in ('Running','Queued'):break
        time.sleep(1)
    result=remote(r'''
$task=Get-ScheduledTask -TaskName $name
$info=Get-ScheduledTaskInfo -TaskName $name
$result=@{state="$($task.State)";last_result=$info.LastTaskResult;done=(Test-Path "$work\done");errors=$(if(Test-Path "$work\errors.json"){[string](Get-Content "$work\errors.json" -Raw)}else{'missing'})}
$result | ConvertTo-Json -Compress
if($task.State -ne 'Running'){Unregister-ScheduledTask -TaskName $name -Confirm:$false}
''')
    (root/'refresh120-guard-result.json').write_text(result)
    for name in ['session.log','before.json','during.json','after.json','dpi-before.json','original.xml','original.sha256','errors.json']:
        subprocess.run(['scp','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows',f'wilf@172.16.105.24:Viewflow/fusion-20261007/refresh120/{name}',str(root/f'refresh120-{name}')],check=False,stdout=subprocess.DEVNULL)
    subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
    print(result)
