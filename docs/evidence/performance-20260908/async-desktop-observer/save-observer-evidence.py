from pathlib import Path
import json,gzip,shutil,hashlib,subprocess,base64
out=Path('docs/evidence/performance-20260908/async-desktop-observer');out.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair')
comparisons=json.loads(Path('/tmp/viewflow-observer-control-comparison.json').read_text())
for c in comparisons:
 label=c['label'];p=out/label;p.mkdir(exist_ok=True)
 for n in ['source','receiver','desktop','runner','cleanup']:
  with gzip.open(p/(n+'.log.gz'),'wb') as z:z.write((raw/f'{n}-{label}.log').read_bytes())
 with gzip.open(p/'producer.log.gz','wb') as z:z.write(Path('/tmp/viewflow-frame-fixture-first/'+label+'-source.log').read_bytes())
 shutil.copy(raw/f'fixture-{label}.json',p/'fixture.json')
 with gzip.open(p/'identity-pairs.json.gz','wb') as z:z.write(json.dumps(c['identity_pairs']).encode())
 (p/'summary.json').write_text(json.dumps({k:v for k,v in c.items() if k!='identity_pairs'},indent=2)+'\n')
(out/'comparison.json').write_text(json.dumps([{k:v for k,v in c.items() if k!='identity_pairs'} for c in comparisons],indent=2)+'\n')
for n in ['summarize-observer-controls.py','save-observer-evidence.py','esrv-observer-trials.py','esrv-observer-state.json','esrv-observer-trial-source-sha256.json','restore-esrv-observer.ps1','owned-output-esrv-observer.py','owned-output-esrv-observer-state.json','observe-frames.py','observer-controls-build.cmd','observer-controls-build.log','async-observer-build.log','observer-sync-backup.txt','windows-frame-observer-sync.cpp']:
 shutil.copy('/tmp/viewflow-'+n,out/n)
shutil.copy('tools/windows_frame_observer.cpp',out/'windows-frame-observer-async.cpp')
with gzip.open(out/'owned-output-esrv-observer.log.gz','wb') as z:z.write(Path('/tmp/viewflow-owned-output-esrv-observer.log').read_bytes())
with gzip.open(out/'comparison.log.gz','wb') as z:z.write(Path('/tmp/viewflow-observer-control-comparison.log').read_bytes())
f=out/'placement-failure';f.mkdir(exist_ok=True)
for n in ['esrv-observer-state.json','owned-output-esrv-observer-state.json','owned-output-esrv-observer.log','esrv-observer-trials.py']:
 shutil.copy('/tmp/viewflow-'+n+'.placement-failure',f/n)
shutil.copy(raw/'desktop-4k-observer-sync-a1.log',f/'desktop.log')
s=json.loads((out/'owned-output-esrv-observer-state.json').read_text());assert s['before_monitors']==s['after_monitors'] and not s['remaining_owned_output_clients'];assert all(s[k].get('address')==s['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
s=json.loads((out/'esrv-observer-state.json').read_text());assert s['restored']['priority']=='High' and s['restored']['thread_priority']=='TimeCritical' and s['restore_task_removed'];assert len(s['phases'])==4 and all(x['exit']==0 and all(x[k]['priority']=='Normal' and x[k]['thread_priority']=='Normal' for k in ['before','after']) for x in s['phases'])
ledger=json.loads((out/'esrv-observer-trial-source-sha256.json').read_text());assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in ledger.items());(out/'verified-final-source-sha256.json').write_text(json.dumps(ledger,indent=2)+'\n')
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
script="$ErrorActionPreference='Stop'; $r='"+root+"'; $p=Get-Process -Id 8108; $t=@($p.Threads|Where-Object Id -eq 10144); $s=Get-CimInstance Win32_Service -Filter \"Name='ESRV_SVC_QUEENCREEK'\"; $owned=@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)}); $tasks=@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver','ViewflowPerf-RestoreEsrvObserver','ViewflowPerf-FrameObserver' -ErrorAction SilentlyContinue); if($p.PriorityClass -ne 'High' -or $t[0].PriorityLevel -ne 'TimeCritical' -or $s.State -ne 'Running' -or $s.StartMode -ne 'Auto' -or $owned.Count -ne 0 -or $tasks.Count -ne 0){throw 'final state mismatch'}; @{process_id=$p.Id;process_start_ticks=$p.StartTime.ToUniversalTime().Ticks.ToString();process_priority=$p.PriorityClass.ToString();thread_id=$t[0].Id;thread_priority=$t[0].PriorityLevel.ToString();thread_base_priority=$t[0].BasePriority;service_state=$s.State;service_start=$s.StartMode;owned_processes=$owned.Count;owned_tasks=$tasks.Count;hashes=@(Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe'),($r+'\\native-build\\Release\\viewflow_windows_frame_observer.exe'),($r+'\\native-build\\Release\\viewflow_windows_frame_observer_sync.exe'),($r+'\\observer-async-control.cpp'),($r+'\\observer-sync-control.cpp') -Algorithm SHA256 | Select-Object Path,Hash)} | ConvertTo-Json -Depth 4"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();v=json.loads(r.stdout.decode('utf-8-sig'));(out/'windows-final-state.json').write_text(json.dumps(v,indent=2)+'\n')
hashes={x['Path'].split('\\')[-1]:x['Hash'].lower() for x in v['hashes']}
assert hashes['observer-async-control.cpp']==hashlib.sha256(Path('tools/windows_frame_observer.cpp').read_bytes()).hexdigest()
assert hashes['observer-sync-control.cpp']==hashlib.sha256((out/'windows-frame-observer-sync.cpp').read_bytes()).hexdigest()
old=json.loads(Path('docs/evidence/performance-20260908/ndis-receive-scheduling/windows-final-state.json').read_text())
for x in old['hashes']:
 name=x['Path'].split('\\')[-1]
 if name in hashes:assert hashes[name]==x['Hash'].lower()
for p in out.rglob('*.log'):
 with gzip.open(p.with_name(p.name+'.gz'),'wb') as z:z.write(p.read_bytes())
 p.unlink()
print('saved and verified',out)
