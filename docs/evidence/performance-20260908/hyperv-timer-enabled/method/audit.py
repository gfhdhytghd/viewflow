"""Read back the exact remote source, executables and cleanup state; launch nothing."""
from pathlib import Path
import base64, hashlib, json, subprocess
b = Path(__file__).resolve().parent.parent
remote = r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\hyperv-timer-enabled-20260909'
s = r"""
$ErrorActionPreference='Stop';$root='__ROOT__';$src=$root+'\integrated-source';
[pscustomobject]@{
 sources=@(Get-ChildItem $src -Recurse -File|ForEach-Object {[pscustomobject]@{path=$_.FullName.Substring($src.Length+1).Replace('\','/');hash=(Get-FileHash $_.FullName).Hash}});
 binaries=@(Get-ChildItem ($root+'\native-build\Release\*.exe')|ForEach-Object {[pscustomobject]@{path=$_.FullName;hash=(Get-FileHash $_.FullName).Hash}});
 config_hash=(Get-FileHash 'C:\VirtualDisplayDriver\vdd_settings.xml').Hash;
 processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}|Select-Object ProcessId,ExecutablePath);
 tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -like 'ViewflowPerf-*'}|Select-Object TaskName,State);
 port=@(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue).Count;
 esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass)
}|ConvertTo-Json -Depth 5
""".replace('__ROOT__', remote)
r = subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=40,check=True)
state = json.loads(r.stdout)
expected = json.loads((b/'method/source-sha256.json').read_text())
assert {x['path']:x['hash'].lower() for x in state['sources']} == expected
for name, digest in expected.items():
    assert hashlib.sha256((b/'source'/name).read_bytes()).hexdigest() == digest, name
assert not state['processes'] and not state['tasks'] and not state['port']
assert state['config_hash'] == hashlib.sha256((b/'method/vdd-before.xml').read_bytes()).hexdigest().upper()
(b/'method/remote-audit.json').write_text(json.dumps(state,indent=2)+'\n')
print('PASS',len(expected),'remote sources match; binaries recorded; diagnostic processes/tasks/port cleared; VDD restored')
