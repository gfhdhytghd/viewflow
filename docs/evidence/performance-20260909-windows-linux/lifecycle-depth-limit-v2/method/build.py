from pathlib import Path
import base64,subprocess,json,hashlib,tarfile,tempfile
b=Path(__file__).resolve().parent.parent;remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-lifecycle-depth-limit-v2-20260909'
def ps(s,timeout=30):
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError((r.returncode,(r.stdout+r.stderr).decode(errors='replace')))
 return r.stdout.decode(errors='replace')
files=[b/'source/lifecycle_fixture.cpp',b/'source/lifecycle_runner.cpp',b/'method/build.cmd'];m={str(p.relative_to(b)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files};(b/'method/windows-source-sha256.json').write_text(json.dumps(m,indent=2)+'\n');temp=Path(tempfile.mkdtemp(prefix='viewflow-lifecycle-stage-'))/'source.tar'
with tarfile.open(temp,'w') as t:
 for p in files:t.add(p,arcname=str(p.relative_to(b)))
ps("if(Test-Path '"+remote+"'){throw 'lifecycle stage exists'};New-Item -ItemType Directory '"+remote+"'|Out-Null")
subprocess.run(['scp','-q',str(temp),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/source.tar'],check=True,timeout=30)
ps("Set-Location '"+remote+"';tar.exe -xf source.tar;if($LASTEXITCODE){throw 'tar failed'}")
paths=','.join("'"+k.replace('/','\\')+"'" for k in m)
x=json.loads(ps("Set-Location '"+remote+"';@("+paths+")|ForEach-Object{[pscustomobject]@{path=$_.Replace('\\','/');hash=(Get-FileHash $_).Hash}}|ConvertTo-Json"));actual={v['path']:v['hash'].lower() for v in x};assert m==actual;(b/'method/windows-remote-source-sha256.json').write_text(json.dumps(actual,indent=2)+'\n')
log=ps("Set-Location '"+remote+"';cmd.exe /d /c 'method\\build.cmd > build.log 2>&1';$code=$LASTEXITCODE;Get-Content build.log;exit $code",150);(b/'method/windows-build.log').write_text(log);print(log[-2500:])
