from pathlib import Path
import subprocess,base64,json
b=Path(__file__).resolve().parent
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\hyprland-blur-oracle-20260908'
def ps(s,timeout=120):
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 return r
r=ps("New-Item -ItemType Directory -Force '"+root+"'|Out-Null");r.check_returncode()
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX windows.cpp /Fe:oracle.exe /Fo:oracle.obj /link d3d11.lib d3dcompiler.lib dxgi.lib windowsapp.lib ole32.lib
exit /b %errorlevel%
'''
(b/'build.cmd').write_bytes(cmd.replace('\n','\r\n').encode())
sources=[b/'build.cmd',b/'windows.cpp']+[b.parent/'hyprland-30/source'/p for p in ['hyprland_blur.h','hyprland_blur_shader.h','Hyprland-LICENSE']]
subprocess.run(['scp','-q']+[str(p) for p in sources]+['wilf@172.16.105.70:'+root.replace('\\','/')+'/'],check=True)
r=ps("Set-Location '"+root+"';cmd /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code");(b/'build.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode('gb18030',errors='replace'),flush=True);r.check_returncode()
r=ps("Set-Location '"+root+"'; & .\\oracle.exe windows.rgba;exit $LASTEXITCODE");(b/'windows.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode(errors='replace'),flush=True);r.check_returncode()
subprocess.run(['scp','-q','wilf@172.16.105.70:'+root.replace('\\','/')+'/windows.rgba',str(b/'windows.rgba')],check=True)
r=ps("Get-ChildItem '"+root+"' -File|Where-Object {$_.Extension -in '.exe','.h','.cpp'}|Get-FileHash|Select-Object Path,Hash|ConvertTo-Json");r.check_returncode();(b/'hashes.json').write_bytes(r.stdout)
