from pathlib import Path
import subprocess,base64,json,gzip,hashlib
b=Path(__file__).resolve().parent.parent
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\approximate-blur-prefilter-20260908'
def ps(s,timeout=40):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 return r
r=ps("if(Test-Path '"+root+"'){throw 'experiment directory exists'};New-Item -ItemType Directory '"+root+"'|Out-Null");r.check_returncode()
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX approximate_blur_probe.cpp /Fe:approximate_blur_probe.exe /Fo:approximate_blur_probe.obj /link d3d11.lib d2d1.lib dxgi.lib windowsapp.lib ole32.lib
exit /b %errorlevel%
'''
p=b/'method/build.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
for src,name in [(p,'build.cmd'),(b/'source/approximate_blur_probe.cpp','approximate_blur_probe.cpp')]:subprocess.run(['scp','-q',str(src),'wilf@172.16.105.70:'+root.replace('\\','/')+'/'+name],check=True)
r=ps("Set-Location '"+root+"';cmd /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code",240);(b/'method/build.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode('gb18030',errors='replace'),flush=True);r.check_returncode()
s="Set-Location '"+root+"';$before=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass); & .\\approximate_blur_probe.exe '"+root+"\\probe';$code=$LASTEXITCODE;[pscustomobject]@{exit=$code;time=(Get-Date).ToString('o');esrv_before=$before;esrv_after=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass);exe=(Get-FileHash approximate_blur_probe.exe|Select-Object Path,Hash);source=(Get-FileHash approximate_blur_probe.cpp|Select-Object Path,Hash);remaining=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq '"+root+"\\approximate_blur_probe.exe'}).Count}|ConvertTo-Json -Depth 5;exit $code"
r=ps(s,180);(b/'method/state.json').write_bytes(r.stdout);print(r.stdout.decode(errors='replace'),flush=True);r.check_returncode()
state=json.loads(r.stdout);assert state['remaining']==0 and state['esrv_before']==state['esrv_after'];assert state['source']['Hash'].lower()==hashlib.sha256((b/'source/approximate_blur_probe.cpp').read_bytes()).hexdigest()
for name in ['probe.csv']+['probe-mode'+str(i)+'.bgra' for i in range(5)]:
 dst=b/('pixels' if name.endswith('.bgra') else 'method')/name
 subprocess.run(['scp','-q','wilf@172.16.105.70:'+root.replace('\\','/')+'/'+name,str(dst)],check=True)
 if name.endswith('.bgra'):dst.with_suffix('.bgra.gz').write_bytes(gzip.compress(dst.read_bytes(),mtime=0));dst.unlink()
print('PASS approximate blur GPU probe, images downloaded',flush=True)
