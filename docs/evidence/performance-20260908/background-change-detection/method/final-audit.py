from pathlib import Path
import subprocess,base64,json,hashlib
b=Path(__file__).resolve().parent.parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\background-change-detection-20260908'
def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=35);r.check_returncode();return json.loads(r.stdout)
src=json.loads((b/'method/source-sha256.json').read_text())
expected={remote+'\\integrated-source\\'+n.replace('/','\\'):h.upper() for n,h in src.items()}
actual=ps("Get-ChildItem -File -Recurse '"+remote+"\\integrated-source'|ForEach-Object{Get-FileHash -Algorithm SHA256 $_.FullName}|Select-Object Path,Hash|ConvertTo-Json")
assert len(actual)==len(expected)
for r in actual:assert r['Hash']==expected[r['Path']],r
(b/'method/remote-source-hashes.json').write_text(json.dumps(actual,indent=2)+'\n')
windows=ps("[pscustomobject]@{processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'}|Select-Object ProcessId,ExecutablePath);tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -like 'ViewflowPerf-*'}|Select-Object TaskName,State);port=@(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue).Count;esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue|Select-Object Id,PriorityClass)}|ConvertTo-Json -Depth 5")
assert not windows['processes'] and not windows['tasks'] and not windows['port']
def ctl(*a):return subprocess.check_output(['hyprctl',*a],text=True).strip()
linux={'monitors':json.loads(ctl('-j','monitors','all')),'plugins':json.loads(ctl('-j','plugin','list')),'configerrors':ctl('configerrors'),'fixture_rule':ctl('repl','return type(_G.viewflow_full_glass_fixture_rule)')}
assert not linux['configerrors'] and linux['fixture_rule']=='nil'
(b/'method/final-state.json').write_text(json.dumps({'windows':windows,'linux':linux},indent=2)+'\n')
print('PASS remote source identity',len(actual),'files; no owned Windows processes/tasks/port, Linux rule absent, no config errors')
