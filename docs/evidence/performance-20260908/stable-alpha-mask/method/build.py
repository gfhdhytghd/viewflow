from pathlib import Path
import subprocess,base64,json,hashlib
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc'
files=['tools/windows_mask_update_probe.cpp','tools/windows_observer_timer.h','platform/windows-composition-preview/timer_resolution_guard.h','platform/windows-composition-preview/atlas_record.h','platform/windows-composition-preview/sparse_shared_visuals.h']
Path('/tmp/viewflow-mask-update-probe-source-sha256.json').write_text(json.dumps({n:hashlib.sha256(Path(n).read_bytes()).hexdigest() for n in files},indent=2)+'\n')
# Existing tree has the exact observer/timer headers. Upload the new diagnostic source only.
for n in files:
 subprocess.run(['scp','-q','-o','BatchMode=yes',n,'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/'+n],check=True)
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX tools\\windows_mask_update_probe.cpp /Fe:viewflow_windows_mask_update_probe.exe /Fo:mask-update-probe.obj /link /SUBSYSTEM:WINDOWS d3d11.lib d3dcompiler.lib d2d1.lib dcomp.lib dwmapi.lib dxgi.lib windowsapp.lib user32.lib shell32.lib winmm.lib ole32.lib
exit /b %errorlevel%
'''
p=Path('/tmp/viewflow-mask-update-probe-build.cmd');p.write_bytes(cmd.replace('\n','\r\n').encode())
subprocess.run(['scp','-q','-o','BatchMode=yes',str(p),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/mask-update-probe-build.cmd'],check=True)
s="$ErrorActionPreference='Stop';Set-Location '"+root+"'; if(@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -eq (Get-Location).Path+'\\viewflow_windows_mask_update_probe.exe'}).Count){throw 'probe running'}; cmd.exe /d /c 'mask-update-probe-build.cmd > mask-update-probe-build.log 2>&1';$code=$LASTEXITCODE;Get-Content mask-update-probe-build.log;exit $code"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=240);Path('/tmp/viewflow-mask-update-probe-build.log').write_bytes(r.stdout+r.stderr);print(r.returncode,r.stdout.decode(errors='replace'));r.check_returncode()
