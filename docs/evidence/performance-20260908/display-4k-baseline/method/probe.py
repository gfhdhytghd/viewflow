from pathlib import Path
import subprocess,base64,json
b=Path(__file__).resolve().parent
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\display-4k-baseline-20260908'
def ps(s,timeout=90):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout);return r
r=ps("New-Item -ItemType Directory -Force '"+root+"'|Out-Null");r.check_returncode()
cmd='@echo off\ncall "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"\nif errorlevel 1 exit /b %errorlevel%\ncl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE display-probe.cpp /Fe:display-probe.exe /Fo:display-probe.obj /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib\nexit /b %errorlevel%\n'
p=b/'build-probe.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
for p in [p,b/'display-probe.cpp']:subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+root.replace('\\','/')+'/'+p.name],check=True)
r=ps("Set-Location '"+root+"';cmd /c 'build-probe.cmd > build-probe.log 2>&1';$code=$LASTEXITCODE;Get-Content build-probe.log;exit $code",120);(b/'build-probe.log').write_bytes(r.stdout+r.stderr);r.check_returncode()
s=r'''$task='ViewflowPerf-DisplayProbe';$r='ROOT';$exe=$r+'\display-probe.exe';
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'task exists'};
$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;$registered=$false;$code=-1;
try {Register-ScheduledTask -TaskName $task -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument ('"'+$r+'\display-probe.log"') -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1))|Out-Null;$registered=$true;Start-ScheduledTask -TaskName $task;Start-Sleep -Seconds 2;$start=Get-Date;while((Get-ScheduledTask -TaskName $task).State -eq 'Running'){if(((Get-Date)-$start).TotalSeconds -gt 30){throw 'read-only topology probe operation timeout'};Start-Sleep -Milliseconds 250};$code=(Get-ScheduledTaskInfo -TaskName $task).LastTaskResult;}
finally {if($registered){if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){Stop-ScheduledTask -TaskName $task};Unregister-ScheduledTask -TaskName $task -Confirm:$false};[pscustomobject]@{exit=$code;hash=(Get-FileHash $exe).Hash;remaining=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;tasks=@(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Count}|ConvertTo-Json};exit $code
'''.replace('ROOT',root)
r=ps(s);(b/'probe-state.json').write_bytes(r.stdout);r.check_returncode();assert json.loads(r.stdout)['exit']==0, r.stdout.decode(errors='replace');subprocess.run(['scp','-q','wilf@172.16.105.70:'+root.replace('\\','/')+'/display-probe.log',str(b/'display-probe.log')],check=True);print((b/'display-probe.log').read_text())
