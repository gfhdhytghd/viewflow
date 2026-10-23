from pathlib import Path
import subprocess,base64,json,hashlib
base=Path('docs/evidence/performance-20260908/commit-request-probe');src=base/'source';remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\commit-request-probe-20260908'
def ps(s,timeout=35):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
 return r.stdout.decode(errors='replace')
state=json.loads(ps("[pscustomobject]@{user=(Get-CimInstance Win32_ComputerSystem).UserName;processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}|Select-Object ProcessId,ExecutablePath);esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass,CPU)}|ConvertTo-Json -Depth 4"));assert state['user']=='WINDOWSVM\\wilf' and not state['processes'];(base/'method/preflight-state.json').write_text(json.dumps(state,indent=2)+'\n')
ps("if(Test-Path '"+remote+"'){throw 'isolated build directory exists'};New-Item -ItemType Directory -Path '"+remote+"\\tools','"+remote+"\\platform\\windows-composition-preview'|Out-Null")
for p in src.rglob('*'):
 if p.is_file():subprocess.run(['scp','-q','-o','BatchMode=yes',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+str(p.relative_to(src))],check=True)
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX tools\\windows_commit_request_probe.cpp /Fe:viewflow_windows_commit_request_probe.exe /Fo:commit-request-probe.obj /link /SUBSYSTEM:WINDOWS d3d11.lib d3dcompiler.lib d2d1.lib dcomp.lib dwmapi.lib dxgi.lib windowsapp.lib user32.lib shell32.lib winmm.lib ole32.lib
exit /b %errorlevel%
''';p=base/'method/build.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode());subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/build.cmd'],check=True)
log=ps("Set-Location '"+remote+"';cmd.exe /d /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code",240);(base/'method/build.log').write_text(log);print(log)
hashes=json.loads(ps("Get-ChildItem '"+remote+"' -Recurse -File|Where-Object {$_.Extension -in '.cpp','.h','.exe'}|Get-FileHash -Algorithm SHA256|Select-Object Path,Hash|ConvertTo-Json"));(base/'method/remote-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n');print('native build complete')
