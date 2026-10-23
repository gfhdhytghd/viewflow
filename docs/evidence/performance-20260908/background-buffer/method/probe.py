from pathlib import Path
import subprocess,base64,json
b=Path(__file__).resolve().parent.parent
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\background-buffer-20260908'
def ps(s,timeout=60):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 return r
r=ps("New-Item -ItemType Directory -Force '"+root+"'|Out-Null");r.check_returncode()
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX background_capture_probe.cpp /Fe:background_capture_probe.exe /Fo:background_capture_probe.obj /link /SUBSYSTEM:WINDOWS d3d11.lib d3dcompiler.lib d2d1.lib dcomp.lib dwmapi.lib dxgi.lib windowsapp.lib user32.lib shell32.lib ole32.lib
exit /b %errorlevel%
'''
p=b/'method/build.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
for src in [p]+list((b/'source').iterdir()):subprocess.run(['scp','-q',str(src),'wilf@172.16.105.70:'+root.replace('\\','/')+'/'+src.name],check=True)
r=ps("Set-Location '"+root+"';cmd /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code",240);(b/'method/build.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode('gb18030',errors='replace'),flush=True);r.check_returncode()
s=r'''
$r='ROOT';$task='ViewflowPerf-BackgroundBufferProbe';$exe=$r+'\background_capture_probe.exe';$registered=$false;
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'task exists'};
if(@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count){throw 'probe already running'};
$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;
$desktopUser=(Get-CimInstance Win32_ComputerSystem).UserName;if(-not $desktopUser -or $desktopUser.Split('\')[-1] -ne $principal.UserId.Split('\')[-1]){throw 'interactive user mismatch'};
$before=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);$code=-1;
try {
 Register-ScheduledTask -TaskName $task -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument ('"'+$r+'\probe.log"') -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registered=$true;Start-ScheduledTask -TaskName $task;
 Start-Sleep -Seconds 2;$started=Get-Date;
 while((Get-ScheduledTask -TaskName $task).State -eq 'Running'){if(((Get-Date)-$started).TotalSeconds -gt 45){throw 'probe timeout'};Start-Sleep -Milliseconds 500};$code=(Get-ScheduledTaskInfo -TaskName $task).LastTaskResult;
} finally {
 if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};
 [pscustomobject]@{exit=$code;exe=(Get-FileHash $exe|Select-Object Path,Hash);source=(Get-FileHash ($r+'\background_capture_probe.cpp')|Select-Object Path,Hash);remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count;esrv_before=$before;esrv_after=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass)}|ConvertTo-Json -Depth 5
};exit $code
'''.replace('ROOT',root)
(b/'method/run.ps1').write_text(s)
r=ps(s,90);(b/'method/state.json').write_bytes(r.stdout);print(r.stdout.decode(errors='replace'),flush=True)
subprocess.run(['scp','-q','wilf@172.16.105.70:'+root.replace('\\','/')+'/probe.log',str(b/'method/probe.log')],check=True)
print((b/'method/probe.log').read_text(),flush=True);r.check_returncode()
