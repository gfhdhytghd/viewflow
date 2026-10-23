from pathlib import Path
import base64,subprocess,json,hashlib
b=Path('docs/evidence/performance-20260909-windows-linux/source-profile');remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-profile-20260909'
p=b/'source/platform/windows-reverse/perf_fixture.cpp';subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/source/platform/windows-reverse/perf_fixture.cpp'],check=True,timeout=30)
s="[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';Set-Location '"+remote+"';Copy-Item build.log build-attempt1.log;cmd.exe /d /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=600);(b/'method/build.log').write_bytes(r.stdout+r.stderr);print('build exit',r.returncode);print(r.stdout.decode(errors='replace')[-2200:]);r.check_returncode()
s={str(p.relative_to(b/'source')):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((b/'source').rglob('*')) if p.is_file()};(b/'method/source-sha256.json').write_text(json.dumps(s,indent=2)+'\n')
