from pathlib import Path
import subprocess,base64,json
base=Path('docs/evidence/performance-20260908/passive-dwm-flush');remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\passive-dwm-flush-20260908'
def ps(s,timeout=35):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 return r
p=base/'method/background-cache-runner.cpp'
subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+p.name],check=True)
cmd='@echo off\ncall "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"\nif errorlevel 1 exit /b %errorlevel%\ncl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE background-cache-runner.cpp /Fe:background-cache-runner.exe /Fo:background-cache-runner.obj /link /SUBSYSTEM:WINDOWS shell32.lib\nexit /b %errorlevel%\n'
p=base/'method/build-runner.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+p.name],check=True)
r=ps("Set-Location '"+remote+"';cmd /c 'build-runner.cmd > build-runner.log 2>&1';$code=$LASTEXITCODE;Get-Content build-runner.log;exit $code",120)
(base/'method/build-runner.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode(errors='replace'));r.check_returncode()
r=ps("@('"+remote+"\\native-build\\Release\\viewflow_windows_composition_preview.exe','"+remote+"\\background-cache-runner.exe')|ForEach-Object{Get-FileHash -Algorithm SHA256 $_}|Select-Object Path,Hash|ConvertTo-Json")
r.check_returncode();(base/'method/integrated-binary-hashes.json').write_bytes(r.stdout)
