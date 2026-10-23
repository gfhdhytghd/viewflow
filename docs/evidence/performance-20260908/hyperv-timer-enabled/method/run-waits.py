"""Rerun the unchanged pre-reboot wait probe; preserve earlier logs."""
from pathlib import Path
import base64, json, subprocess
b=Path(__file__).resolve().parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\hyperv-timer-enabled-20260909'
original=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\wait-resolution-probe-20260909'
def ps(s,timeout=40):
    s="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s
    r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
    if r.returncode: raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
    return r.stdout
expected=json.loads((b.parent.parent/'wait-resolution-probe/method/state.json').read_text(encoding='utf-8-sig'))['binary']['Hash']
s="if(Test-Path '"+remote+"'){throw 'do not overwrite an earlier run'};New-Item -ItemType Directory '"+remote+"'|Out-Null;Copy-Item '"+original+"\\wait-resolution-probe.exe' '"+remote+"\\wait-resolution-probe.exe';Get-FileHash '"+remote+"\\wait-resolution-probe.exe'|Select-Object Path,Hash|ConvertTo-Json"
identity=json.loads(ps(s));assert identity['Hash']==expected
(b/'wait-binary.json').write_text(json.dumps(identity,indent=2)+'\n')
error=None
try: ps((b/'run-waits.ps1').read_text(),60)
except Exception as e: error=e
for name in ['wait-resolution.log','state.json']:
    subprocess.run(['scp','-q','wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+name,str(b/name)],check=True)
if error: raise error
state=json.loads((b/'state.json').read_text(encoding='utf-8-sig'))
assert state['result']==state['remaining']==state['tasks']==0
assert state['binary']==identity and state['before_esrv']==state['after_esrv']
print('PASS identical wait probe, successful execution and cleanup')
