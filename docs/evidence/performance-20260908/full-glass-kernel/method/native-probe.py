from pathlib import Path
import subprocess,base64,json,hashlib,sys,gzip
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc'
local=Path('docs/evidence/performance-20260908/full-glass-kernel')
def ps(code,timeout=120):
 p="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+code
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(p.encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
 return r.stdout
remote=root.replace('\\','/')
if sys.argv[1]=='build':
 source=Path('tools/windows_blur_kernel_probe.cpp')
 subprocess.run(['scp','-q',str(source),'wilf@172.16.105.70:'+remote+'/tools/'+source.name],check=True)
 cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX tools\\windows_blur_kernel_probe.cpp /Fe:viewflow_blur_kernel_probe.exe /Fo:blur-kernel-probe.obj /link d3d11.lib d2d1.lib dxgi.lib windowsapp.lib ole32.lib
exit /b %errorlevel%
'''
 build=local/'method/build.cmd';build.write_bytes(cmd.replace('\n','\r\n').encode())
 subprocess.run(['scp','-q',str(build),'wilf@172.16.105.70:'+remote+'/blur-kernel-build.cmd'],check=True)
 output=ps("Set-Location '"+root+"'; cmd /c 'blur-kernel-build.cmd > blur-kernel-build.log 2>&1';$exit=$LASTEXITCODE;Get-Content blur-kernel-build.log;if($exit -ne 0){exit $exit};Get-FileHash viewflow_blur_kernel_probe.exe|Select-Object Path,Hash|ConvertTo-Json",240)
 (local/'build.log').write_bytes(output);print(output.decode(errors='replace'))
 (local/'method/source-sha256.json').write_text(json.dumps({str(source):hashlib.sha256(source.read_bytes()).hexdigest()},indent=2)+'\n')
elif sys.argv[1]=='run':
 output=ps("Set-Location '"+root+"';$before=@(Get-Process esrv -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass,StartTime); & .\\viewflow_blur_kernel_probe.exe '"+root+"\\glass-kernel';$exit=$LASTEXITCODE;@{exit=$exit;time=(Get-Date).ToString('o');esrv_before=$before;esrv_after=@(Get-Process esrv -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass,StartTime);exe=(Get-FileHash viewflow_blur_kernel_probe.exe|Select-Object Path,Hash);source=(Get-FileHash tools\\windows_blur_kernel_probe.cpp|Select-Object Path,Hash);remaining=@(Get-Process viewflow_blur_kernel_probe -ErrorAction SilentlyContinue).Count}|ConvertTo-Json -Depth 5;if($exit -ne 0){exit $exit}",180)
 (local/'state.json').write_bytes(output);print(output.decode(errors='replace'))
 for suffix in ['.csv','-mode0.bgra','-mode1.bgra','-mode2.bgra']:
  subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote+'/glass-kernel'+suffix,str(local/('glass-kernel'+suffix))],check=True)

 if sys.argv[1]=='run':
  for f in local.glob('*.bgra'):
   f.with_suffix(f.suffix+'.gz').write_bytes(gzip.compress(f.read_bytes(),mtime=0));f.unlink()
