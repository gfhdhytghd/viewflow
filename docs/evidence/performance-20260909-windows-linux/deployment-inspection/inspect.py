from pathlib import Path
import subprocess,base64,json
b=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux/deployment-inspection');b.mkdir(exist_ok=True)
s=r"""[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$r=Get-Content 'C:\Users\wilf\Viewflow\desktop-test\receive.json' -Raw|ConvertFrom-Json;[pscustomobject]@{config_path='C:\Users\wilf\Viewflow\desktop-test\receive.json';config_hash=(Get-FileHash 'C:\Users\wilf\Viewflow\desktop-test\receive.json').Hash;reverse=$r.reverse;tasks=@(Get-ScheduledTask -TaskName 'ViewflowMain-Active'|ForEach-Object{[pscustomobject]@{name=$_.TaskName;state=$_.State.ToString();priority=$_.Settings.Priority;actions=@($_.Actions|Select-Object Execute,Arguments,WorkingDirectory)}})}|ConvertTo-Json -Depth 8"""
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30);(b/'windows-inspection.stderr.log').write_bytes(r.stderr);assert r.returncode==0,(r.returncode,r.stderr.decode(errors='replace'));data=json.loads(r.stdout);(b/'windows.json').write_text(json.dumps(data,indent=2)+'\n');print(json.dumps(data,indent=2))
linux=[]
for name in ['desktop-source.json','windows-input-source.json']:
 p=Path.home()/'.config/viewflow'/name;v=json.loads(p.read_text());linux.append({'config_path':str(p),'reverse':v.get('reverse')})
(b/'linux.json').write_text(json.dumps(linux,indent=2)+'\n');(b/'inspect.py').write_text(Path(__file__).read_text())
