from pathlib import Path
import subprocess,base64
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
cmd='@echo off\r\ncall "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"\r\nif errorlevel 1 exit /b %errorlevel%\r\n'
for value in [0,7]:
 src=Path('/tmp/viewflow-socket-trace-runner.cpp').read_text().replace('  STARTUPINFOW startup',f'  SetEnvironmentVariableW(L"VIEWFLOW_GPU_RELATIVE_PRIORITY", L"{value}");\n  STARTUPINFOW startup')
 p=Path(f'/tmp/viewflow-gpu-priority-{value}-runner.cpp');p.write_text(src)
 subprocess.run(['scp','-q','-o','BatchMode=yes',str(p),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+f'/gpu-priority-{value}-runner.cpp'],check=True)
 cmd+=f'cl /nologo /EHsc /std:c++20 /O2 gpu-priority-{value}-runner.cpp /Fe:isolated-receiver-runner-gpu-priority-{value}.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib\r\nif errorlevel 1 exit /b %errorlevel%\r\n'
cmd+='exit /b 0\r\n';p=Path('/tmp/viewflow-gpu-priority-runners-build.cmd');p.write_text(cmd)
subprocess.run(['scp','-q','-o','BatchMode=yes',str(p),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/gpu-priority-runners-build.cmd'],check=True)
s="Set-Location '"+root+"'; cmd.exe /d /c 'gpu-priority-runners-build.cmd > gpu-priority-runners-build.log 2>&1'; $code=$LASTEXITCODE; Get-Content gpu-priority-runners-build.log -Tail 10; exit $code"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=180);Path('/tmp/viewflow-gpu-priority-runners-build.log').write_bytes(r.stdout+r.stderr);print(r.returncode,r.stdout.decode(errors='replace'));r.check_returncode()
