from pathlib import Path
import subprocess,base64
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
cmd='@echo off\r\ncall "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"\r\nif errorlevel 1 exit /b %errorlevel%\r\n'
for mode,queries,socket in [('full','1','1'),('noquery','0','1'),('minimal','0','0')]:
 src=Path('/tmp/viewflow-socket-trace-runner.cpp').read_text().replace('SetEnvironmentVariableW(L"VIEWFLOW_QUIC_SOCKET_TRACE", L"1");',f'SetEnvironmentVariableW(L"VIEWFLOW_QUIC_SOCKET_TRACE", L"{socket}");\n  SetEnvironmentVariableW(L"VIEWFLOW_ATLAS_GPU_QUERIES",L"{queries}");')
 p=Path('/tmp/viewflow-trace-control-'+mode+'-runner.cpp');p.write_text(src)
 subprocess.run(['scp','-q','-o','BatchMode=yes',str(p),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/'+p.name.removeprefix('viewflow-')],check=True)
 cmd+=f'cl /nologo /EHsc /std:c++20 /O2 trace-control-{mode}-runner.cpp /Fe:isolated-receiver-runner-trace-{mode}.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib\r\nif errorlevel 1 exit /b %errorlevel%\r\n'
cmd+='exit /b 0\r\n';p=Path('/tmp/viewflow-trace-control-runners-build.cmd');p.write_text(cmd)
subprocess.run(['scp','-q','-o','BatchMode=yes',str(p),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/trace-control-runners-build.cmd'],check=True)
s="Set-Location '"+root+"'; cmd.exe /d /c 'trace-control-runners-build.cmd > trace-control-runners-build.log 2>&1'; $code=$LASTEXITCODE; Get-Content trace-control-runners-build.log -Tail 10; exit $code"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=180);Path('/tmp/viewflow-trace-control-runners-build.log').write_bytes(r.stdout+r.stderr);print(r.returncode,r.stdout.decode(errors='replace'));r.check_returncode()
