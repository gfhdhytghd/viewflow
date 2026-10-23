from pathlib import Path
import subprocess,base64,xml.etree.ElementTree as ET,hashlib,json
b=Path(__file__).resolve().parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\hyperv-timer-enabled-20260909'
def ps(s,timeout=120):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
 return r.stdout
cmd='@echo off\ncall "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"\nif errorlevel 1 exit /b %errorlevel%\ncl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN window-style-probe.cpp /Fe:window-style-probe.exe /Fo:window-style-probe.obj /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib d3d11.lib dxgi.lib winmm.lib dwmapi.lib windowsapp.lib CoreMessaging.lib gdi32.lib\nexit /b %errorlevel%\n'
p=b/'build-style-probe.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
for p in [p,b/'window-style-probe.cpp']:
 subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+p.name],check=True)
r=ps("Set-Location '"+remote+"';cmd /c 'build-style-probe.cmd > build-style-probe.log 2>&1';$code=$LASTEXITCODE;Get-Content build-style-probe.log;exit $code");(b/'build-style-probe.log').write_bytes(r)
r=ps("Get-FileHash '"+remote+"\\window-style-probe.exe'|Select-Object Path,Hash|ConvertTo-Json")
(b/'style-probe-hash.json').write_bytes(r);print(r.decode())
