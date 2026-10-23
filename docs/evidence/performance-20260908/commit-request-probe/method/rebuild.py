from pathlib import Path
import subprocess,base64,json,hashlib
base=Path('docs/evidence/performance-20260908/commit-request-probe');src=base/'source';remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\commit-request-probe-20260908'
subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote.replace('\\','/')+'/build.log',str(base/'method/build-initial-failed.log')],check=True)
p=src/'tools/windows_commit_request_probe.cpp';subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/tools/'+p.name],check=True)
s="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-Location '"+remote+"';if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq '"+remote+"\\viewflow_windows_commit_request_probe.exe'}).Count){throw 'probe running'};cmd.exe /d /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=240);(base/'method/build.log').write_bytes(r.stdout+r.stderr);print(r.returncode,r.stdout.decode('gb18030',errors='replace'));r.check_returncode()
s="Get-ChildItem '"+remote+"' -Recurse -File|Where-Object {$_.Extension -in '.cpp','.h','.exe'}|Get-FileHash -Algorithm SHA256|Select-Object Path,Hash|ConvertTo-Json"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=35);r.check_returncode();hashes=json.loads(r.stdout);(base/'method/remote-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
local={str(p.relative_to(src)):hashlib.sha256(p.read_bytes()).hexdigest() for p in src.rglob('*') if p.is_file()}
for h in hashes:
 rel=h['Path'][len(remote)+1:].replace('\\','/')
 if rel in local:assert h['Hash'].lower()==local[rel]
(base/'method/source-sha256.json').write_text(json.dumps(local,indent=2)+'\n');print('native source hashes verified')
