from pathlib import Path
import runpy,sys,json,hashlib
sys.argv=['native-probe.py','audit']
m=runpy.run_path(str(Path(__file__).with_name('native-probe.py')))
ledger=json.loads(Path('docs/evidence/performance-20260908/binary-alpha-backdrop/method/binary-backdrop-production-restored.json').read_text())
local={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in ledger}
assert local==ledger
script="$r='"+m['root']+"';$files=@("+','.join("'"+p.replace('/','\\')+"'" for p in ledger)+");$hashes=@{};foreach($f in $files){$hashes[$f.Replace('\\','/')]=(Get-FileHash ($r+'\\'+$f)).Hash.ToLower()};@{hashes=$hashes;time=(Get-Date).ToString('o');owned_processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -like ($r+'\\*') }|Select-Object ProcessId,ExecutablePath);owned_tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -like 'ViewflowPerf-*'}|Select-Object TaskName,State)}|ConvertTo-Json -Depth 6"
d=json.loads(m['ps'](script));assert d['hashes']==ledger
out={'linux_restored_source_matches':True,'windows':d,'note':'Fresh read-only audit after Linux reboot; historical trial restoration remains in its original ledgers. No current process priority or configuration modified.'}
Path('docs/evidence/performance-20260908/binary-alpha-backdrop/method/post-reboot-restoration-audit.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out,indent=2))
