from pathlib import Path
import subprocess,base64,hashlib,json
base=Path(__file__).resolve().parent.parent
root=base/'source'
local={str(p.relative_to(root)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file()}
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\output-surface-pool-20260908\integrated-source'
s="$ErrorActionPreference='Stop';$r='"+remote+"';@(Get-ChildItem -Recurse -File $r)|ForEach-Object{[pscustomobject]@{Path=$_.FullName.Substring($r.Length+1).Replace('\\','/');Hash=(Get-FileHash -Algorithm SHA256 $_.FullName).Hash}}|ConvertTo-Json"
r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,check=True,timeout=40)
rows=json.loads(r.stdout);actual={h['Path']:h['Hash'].lower() for h in rows};assert actual==local, (set(local)-set(actual),set(actual)-set(local),[k for k in local.keys()&actual.keys() if local[k]!=actual[k]])
(base/'method/integrated-source-sha256.json').write_text(json.dumps(local,indent=2)+'\n')
(base/'method/integrated-remote-source-sha256.json').write_text(json.dumps(rows,indent=2)+'\n');print('source files verified:',len(local))
