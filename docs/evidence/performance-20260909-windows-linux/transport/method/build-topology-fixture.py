from pathlib import Path
import subprocess,base64
b=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/transport');remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-transport-20260909'
for f in [b/'source/perf_topology_fixture.cpp',b/'method/build-topology-fixture.cmd']:
 subprocess.run(['scp','-q',str(f),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+f.name],check=True,timeout=30)
s="$ErrorActionPreference='Stop';Set-Location '"+remote+"';cmd.exe /d /c 'build-topology-fixture.cmd > topology-fixture-build.log 2>&1';$code=$LASTEXITCODE;Get-Content topology-fixture-build.log;exit $code"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=120);(b/'method/topology-fixture-build.log').write_bytes(r.stdout+r.stderr);assert r.returncode==0;print('runner build passed')
(b/'method/build-topology-fixture.py').write_text(Path(__file__).read_text())
