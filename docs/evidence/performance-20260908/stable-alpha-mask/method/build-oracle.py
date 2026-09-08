from pathlib import Path
import subprocess,runpy,sys,json,hashlib
sys.argv=['native-probe.py','audit'];m=runpy.run_path('docs/evidence/performance-20260908/full-glass-kernel/method/native-probe.py')
root=m['root'];remote=root.replace('\\','/');p=Path('platform/windows-composition-preview/sparse_alpha_mask_test.cpp')
subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote+'/'+str(p)],check=True)
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
if not exist alpha-mask-objects mkdir alpha-mask-objects
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX /Iplatform\\windows-video-compositor platform\\windows-composition-preview\\sparse_alpha_mask_test.cpp platform\\windows-video-compositor\\video_compositor.cpp platform\\windows-composition-preview\\vfgp_parser.cpp /Fo:alpha-mask-objects\\ /Fe:viewflow_sparse_alpha_mask_test.exe /link /SUBSYSTEM:WINDOWS d3d11.lib d2d1.lib dxgi.lib dwmapi.lib windowsapp.lib mfplat.lib mfuuid.lib ole32.lib wmcodecdspuuid.lib d3dcompiler.lib winmm.lib advapi32.lib imm32.lib shell32.lib propsys.lib gdi32.lib user32.lib
exit /b %errorlevel%
'''
local=Path('docs/evidence/performance-20260908/stable-alpha-mask');build=local/'method/build-oracle.cmd';build.write_bytes(cmd.replace('\n','\r\n').encode())
subprocess.run(['scp','-q',str(build),'wilf@172.16.105.70:'+remote+'/alpha-mask-oracle-build.cmd'],check=True)
r=m['ps']("Set-Location '"+root+"';cmd /c 'alpha-mask-oracle-build.cmd > alpha-mask-oracle-build.log 2>&1';$code=$LASTEXITCODE;Get-Content alpha-mask-oracle-build.log;if($code){exit $code};Get-FileHash viewflow_sparse_alpha_mask_test.exe|Select-Object Path,Hash|ConvertTo-Json",240)
(local/'oracle-build.log').write_bytes(r);print(r.decode(errors='replace'))
# Include all headers transitively available to the include-main oracle.
files=[f for folder in ['platform/windows-composition-preview','platform/windows-video-compositor'] for f in Path(folder).glob('*') if f.suffix in ['.h','.hpp']]+[p,Path('platform/windows-composition-preview/main.cpp'),Path('platform/windows-composition-preview/vfgp_parser.cpp'),Path('platform/windows-video-compositor/video_compositor.cpp')]
(local/'method/oracle-source-sha256.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2)+'\n')
