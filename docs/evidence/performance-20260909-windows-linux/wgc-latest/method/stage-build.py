from pathlib import Path
import tarfile,subprocess,base64,json,hashlib
b=Path(__file__).resolve().parent.parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-wgc-latest-20260909'
def ps(s,timeout=35):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError((r.returncode,(r.stdout+r.stderr).decode(errors='replace')))
 return r.stdout.decode(errors='replace')
m={str(p.relative_to(b/'source')):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((b/'source').rglob('*')) if p.is_file()}
(b/'method/source-sha256.json').write_text(json.dumps(m,indent=2)+'\n')
with tarfile.open('/tmp/viewflow-reverse-profile-source.tar','w') as t:
 t.add(b/'source',arcname='source');t.add(b/'method/build.cmd',arcname='build.cmd')
ps("if(Test-Path '"+remote+"'){throw 'profile stage already exists'};New-Item -ItemType Directory '"+remote+"'|Out-Null")
subprocess.run(['scp','-q','/tmp/viewflow-reverse-profile-source.tar','wilf@172.16.105.70:'+remote.replace('\\','/')+'/source.tar'],check=True,timeout=60)
ps("Set-Location '"+remote+"';tar.exe -xf source.tar;if($LASTEXITCODE){throw 'tar failed'}")
checks=ps("Set-Location '"+remote+"';Get-ChildItem source -File -Recurse|ForEach-Object{[pscustomobject]@{path=$_.FullName.Substring((Join-Path $PWD 'source').Length+1).Replace('\\','/');hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json")
r={x['path']:x['hash'].lower() for x in json.loads(checks)};assert r==m;(b/'method/remote-source-sha256.json').write_text(json.dumps(r,indent=2)+'\n')
print('stage_verified',len(m),flush=True)
log=ps("Set-Location '"+remote+"';cmd.exe /d /c 'build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code",600)
(b/'method/build.log').write_text(log);print(log[-4500:],flush=True)
