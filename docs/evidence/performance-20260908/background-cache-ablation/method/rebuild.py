from pathlib import Path
import subprocess,base64,json
base=Path('docs/evidence/performance-20260908/background-cache-ablation');remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\background-cache-ablation-20260908'
def ps(s,timeout=35):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 return r
p=base/'source/platform/windows-composition-preview/native_background_cache.h'
subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/integrated-source/platform/windows-composition-preview/'+p.name],check=True)
r=ps("Set-Location '"+remote+"';cmd.exe /d /c 'build-integrated.cmd > refinement-build.log 2>&1';$code=$LASTEXITCODE;Get-Content refinement-build.log;exit $code",300)
(base/'method/refinement-build.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode(errors='replace'));r.check_returncode()
r=ps("$r='"+remote+"\\integrated-source';Get-ChildItem $r -Recurse -File|ForEach-Object{[pscustomobject]@{path=$_.FullName.Substring($r.Length+1).Replace('\\','/');hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json")
r.check_returncode();(base/'method/remote-source-hashes.json').write_bytes(r.stdout)
local=json.loads((base/'method/source-sha256.json').read_text());actual={x['path']:x['hash'].lower() for x in json.loads(r.stdout)};assert local==actual
print('PASS all remote source hashes match final source')
