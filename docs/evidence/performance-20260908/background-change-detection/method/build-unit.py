from pathlib import Path
import subprocess,base64,json
b=Path('docs/evidence/performance-20260908/background-change-detection')
r=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\background-change-detection-20260908'
def ps(s,timeout=180):
 return subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
p=ps("New-Item -ItemType Directory -Force '"+r+"'|Out-Null");p.check_returncode()
cmd='@echo off\ncall "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"\nif errorlevel 1 exit /b %errorlevel%\ncl /nologo /O2 /EHsc /std:c++20 /DNOMINMAX /DWIN32_LEAN_AND_MEAN /DUNICODE /D_UNICODE background_difference_test.cpp /Fe:background-difference-test.exe /Fo:background-difference-test.obj /link d3d11.lib d3dcompiler.lib windowsapp.lib\nif errorlevel 1 exit /b %errorlevel%\nbackground-difference-test.exe\nexit /b %errorlevel%\n'
p=b/'method/build-unit.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
for p in [p,*sorted((b/'source').glob('background_difference*'))]:
 subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+r.replace('\\','/')+'/'+p.name],check=True)
p=ps("Set-Location '"+r+"';cmd.exe /d /c 'build-unit.cmd > unit.log 2>&1';$code=$LASTEXITCODE;Get-Content unit.log;exit $code")
(b/'method/unit.log').write_bytes(p.stdout+p.stderr);print(p.stdout.decode(errors='replace'));p.check_returncode()
