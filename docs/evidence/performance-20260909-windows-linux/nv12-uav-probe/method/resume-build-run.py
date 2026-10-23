from pathlib import Path
import subprocess,base64,json,hashlib
b=Path(__file__).resolve().parent.parent;remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-nv12-uav-probe-20260909'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def ps(s,timeout=40):
 c="[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s
 return subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(c.encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
assert not (b/'method/state.json').exists()
s=ps("[pscustomobject]@{source=(Get-FileHash '"+remote+"\\source\\probe.cpp').Hash;binary=(Test-Path '"+remote+"\\probe.exe');main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString()}|ConvertTo-Json");assert s.returncode==0;v=json.loads(s.stdout);assert v['source'].lower()==json.loads((b/'method/initial-source-sha256.json').read_text())['probe.cpp'] and not v['binary'] and v['main']=='Ready'
subprocess.run(['scp','-q',str(b/'source/probe.cpp'),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/source/probe.cpp'],check=True)
s=ps("(Get-FileHash '"+remote+"\\source\\probe.cpp').Hash");assert s.returncode==0 and s.stdout.decode().strip().lower()==sha(b/'source/probe.cpp')
m={'probe.cpp':sha(b/'source/probe.cpp')}
for n in ['source-sha256.json','remote-source-sha256.json']:(b/'method'/n).write_text(json.dumps(m,indent=2)+'\n')
s=ps("Set-Location '"+remote+"';cmd.exe /d /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code",90);(b/'method/build.log').write_bytes(s.stdout+s.stderr);assert s.returncode==0
s=ps("Set-Location '"+remote+"';cmd.exe /d /c 'probe.exe > probe.log 2>&1';$code=$LASTEXITCODE;Get-Content probe.log;exit $code");(b/'method/probe.log').write_bytes(s.stdout+s.stderr);assert s.returncode==0
s=ps("[pscustomobject]@{native=(Get-FileHash '"+remote+"\\probe.exe').Hash;installed=(Get-FileHash 'C:\\Users\\wilf\\Viewflow\\desktop-test\\viewflow_windows_reverse.exe').Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -like '*reverse-nv12-uav-probe-20260909*'}|Select-Object ProcessId,ExecutablePath)}|ConvertTo-Json -Depth 4");assert s.returncode==0;v=json.loads(s.stdout);assert v['main']=='Ready' and not v['processes'] and v['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB';(b/'method/state.json').write_text(json.dumps(v,indent=2)+'\n');print((b/'method/probe.log').read_text())
