from pathlib import Path
import subprocess,base64,json
base=Path('docs/evidence/performance-20260908/native-background-cache');remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\native-background-cache-20260908'
def ps(s,timeout=35):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 return r
for name in ['background_capture_host.h','background_region_test.cpp','Hyprland-LICENSE','CMakeLists.txt','native_background_cache_test.cpp','main.cpp','background_buffer.h','native_background_cache.h','background_region.h','sparse_shared_visuals.h','hyprland_blur.h','hyprland_blur_shader.h']:
 subprocess.run(['scp','-q','platform/windows-composition-preview/'+name,'wilf@172.16.105.70:'+(remote+'\\integrated-source\\platform\\windows-composition-preview\\'+name).replace('\\','/')],check=True)
cmake=r'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe';ffmpeg=r'C:\Users\wilf\AppData\Local\Temp\viewflow-codec-bench\ffmpeg-n8.1-latest-win64-lgpl-shared-8.1'
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
"__CMAKE__" -S integrated-source\\platform\\windows-composition-preview -B native-build -G "Visual Studio 17 2022" -A x64 "-DVIEWFLOW_FFMPEG_ROOT=__FFMPEG__"
if errorlevel 1 exit /b %errorlevel%
"__CMAKE__" --build native-build --config Release --target viewflow_windows_composition_preview viewflow_native_background_cache_test viewflow_background_region_test viewflow_sparse_coalesce_test viewflow_sparse_opaque_test --parallel 2
if errorlevel 1 exit /b %errorlevel%
exit /b %errorlevel%
'''.replace('__CMAKE__',cmake).replace('__FFMPEG__',ffmpeg)
p=base/'method/build-integrated.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode());subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/build-integrated.cmd'],check=True)
r=ps("Set-Location '"+remote+"';cmd.exe /d /c 'build-integrated.cmd > incremental-build.log 2>&1';$code=$LASTEXITCODE;Get-Content incremental-build.log;exit $code",300);(base/'method/incremental-build.log').write_bytes(r.stdout+r.stderr);print('\n'.join(line for line in r.stdout.decode(errors='replace').splitlines() if 'error ' in line or '.exe' in line));
if r.returncode:raise SystemExit(r.returncode)