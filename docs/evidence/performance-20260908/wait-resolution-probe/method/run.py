from pathlib import Path
import base64,json,subprocess,sys
b=Path(__file__).resolve().parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\wait-resolution-probe-20260909'
def ps(script,timeout=45):
    s="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+script
    r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=timeout,check=True)
    return r.stdout
if '--resume-build' in sys.argv:
    ps("if(Test-Path '"+remote+"\\wait-resolution-probe.exe'){throw 'do not overwrite a successful probe'}")
else:
    ps("if(Test-Path '"+remote+"'){throw 'probe directory exists'};New-Item -ItemType Directory -Path '"+remote+"'|Out-Null")
cmd=r'''@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE wait-resolution-probe.cpp /Fe:wait-resolution-probe.exe /link /SUBSYSTEM:WINDOWS shell32.lib user32.lib winmm.lib
exit /b %errorlevel%
'''
(b/'build.cmd').write_bytes(cmd.replace('\n','\r\n').encode())
for p in [b/'build.cmd',b/'wait-resolution-probe.cpp']:
    subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+p.name],check=True)
result=ps("Set-Location '"+remote+"';cmd /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code",120)
(b/'build.log').write_bytes(result);print(result.decode(errors='replace'),flush=True)
s=r'''
$root='__ROOT__';$name='ViewflowPerf-WaitResolution';$state=@{};
$state.before_esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);
$state.binary=Get-FileHash ($root+'\wait-resolution-probe.exe')|Select-Object Path,Hash;
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'task exists'}
try {
 $principal=(Get-ScheduledTask -TaskName 'ViewflowMain-Active').Principal;
 $action=New-ScheduledTaskAction -Execute ($root+'\wait-resolution-probe.exe') -Argument ('"'+$root+'\wait-resolution.log"') -WorkingDirectory $root;
 Register-ScheduledTask -TaskName $name -Principal $principal -Action $action -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1))|Out-Null;
 Start-ScheduledTask -TaskName $name;
 $deadline=(Get-Date).AddSeconds(40);
 do {Start-Sleep -Milliseconds 250;$task=Get-ScheduledTask -TaskName $name;$info=Get-ScheduledTaskInfo -TaskName $name} while (($task.State -eq 'Running' -or $info.LastTaskResult -eq 267011) -and (Get-Date) -lt $deadline);
 $state.result=$info.LastTaskResult;
 if($task.State -eq 'Running'){throw 'probe did not terminate'};
 if($state.result -ne 0){throw ('probe failed '+$state.result)};
} finally {
 $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;
 if($task){if($task.State -eq 'Running'){Stop-ScheduledTask -TaskName $name};Unregister-ScheduledTask -TaskName $name -Confirm:$false};
 $state.remaining=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq ($root+'\wait-resolution-probe.exe')}).Count;
 $state.tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -eq $name}).Count;
 $state.after_esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);
 $state|ConvertTo-Json -Depth 5|Set-Content -Encoding utf8 ($root+'\state.json');
}
'''.replace('__ROOT__',remote)
(b/'run.ps1').write_text(s)
error=None
try:ps(s,60)
except Exception as e:error=e
for name in ['wait-resolution.log','state.json']:
    subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+name,str(b/name)],check=True)
if error:raise error
state=json.loads((b/'state.json').read_text(encoding='utf-8-sig'))
assert state['result']==state['remaining']==state['tasks']==0
assert state['before_esrv']==state['after_esrv']
print('PASS probe exit and cleanup; original ESRV identity/priority preserved')
