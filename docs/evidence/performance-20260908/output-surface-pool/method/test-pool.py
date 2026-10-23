from pathlib import Path
import subprocess,base64,json
base=Path(__file__).resolve().parent.parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\output-surface-pool-20260908'
def ps(s,timeout=60):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 return r
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 integrated-source\\tools\\output-pool-test.cpp /Fe:output-pool-test.exe /Fo:output-pool-test.obj /link d3d11.lib dxgi.lib
if errorlevel 1 exit /b %errorlevel%
output-pool-test.exe
exit /b %errorlevel%
'''
p=base/'method/test-pool.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
for path,target in [(p,'test-pool.cmd'),(base/'source/tools/output-pool-test.cpp',r'integrated-source\tools\output-pool-test.cpp')]:
 subprocess.run(['scp','-q',str(path),'wilf@172.16.105.70:'+(remote+'\\'+target).replace('\\','/')],check=True)
r=ps("Set-Location '"+remote+"';cmd.exe /d /c 'test-pool.cmd > test-pool.log 2>&1';$code=$LASTEXITCODE;Get-Content test-pool.log;exit $code",180)
(base/'method/test-pool.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode('gb18030',errors='replace'));r.check_returncode()
