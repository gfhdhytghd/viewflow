from pathlib import Path
import json,gzip,shutil,hashlib,subprocess,base64
out=Path('docs/evidence/performance-20260908/gpu-priority-rejected');out.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');comparisons=json.loads(Path('/tmp/viewflow-gpu-priority-comparison.json').read_text())
for c in comparisons:
 label=c['label'];p=out/label;p.mkdir(exist_ok=True)
 for n in ['source','receiver','desktop','runner','cleanup']:
  with gzip.open(p/(n+'.log.gz'),'wb') as z:z.write((raw/f'{n}-{label}.log').read_bytes())
 with gzip.open(p/'producer.log.gz','wb') as z:z.write(Path('/tmp/viewflow-frame-fixture-first/'+label+'-source.log').read_bytes())
 shutil.copy(raw/f'fixture-{label}.json',p/'fixture.json')
 with gzip.open(p/'identity-pairs.json.gz','wb') as z:z.write(json.dumps(c['identity_pairs']).encode())
 assert all(x['present_source_upper_ns']<=x['source_clock_mapping_valid_until_ns'] for x in c['identity_pairs'])
 (p/'summary.json').write_text(json.dumps({k:v for k,v in c.items() if k!='identity_pairs'},indent=2)+'\n')
(out/'comparison.json').write_text(json.dumps([{k:v for k,v in c.items() if k!='identity_pairs'} for c in comparisons],indent=2)+'\n')
for n in ['summarize-gpu-priority.py','save-gpu-priority-evidence.py','gpu-priority-trials.py','gpu-priority-state.json','gpu-priority-trial-source-sha256.json','restore-gpu-priority-control.ps1','owned-output-gpu-priority.py','owned-output-gpu-priority-state.json','gpu-priority-runners-build.cmd','gpu-priority-runners-build.log','native-gpu-priority-build.log','gpu-priority-restored-build.log','before-gpu-priority-native-sha256.json','gpu-priority-experiment-binaries.json','gpu-priority-0-runner.cpp','gpu-priority-7-runner.cpp','build-gpu-priority-runners.py']:
 shutil.copy('/tmp/viewflow-'+n,out/n)
shutil.copy('/tmp/viewflow-video-compositor-gpu-priority-experiment.cpp',out/'video_compositor.cpp.experiment')
shutil.copy('/tmp/viewflow-video-compositor-before-gpu-priority.cpp',out/'video_compositor.cpp.restored')
for n in ['owned-output-gpu-priority.log','gpu-priority-comparison.log']:
 with gzip.open(out/(n+'.gz'),'wb') as z:z.write(Path('/tmp/viewflow-'+n).read_bytes())
s=json.loads((out/'owned-output-gpu-priority-state.json').read_text());assert s['before_monitors']==s['after_monitors'] and not s['remaining_owned_output_clients'];assert all(s[k].get('address')==s['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
s=json.loads((out/'gpu-priority-state.json').read_text());assert s['restore_task_removed'] and s['restored']['priority']==s['initial']['priority'] and all(t['priority']=='TimeCritical' for t in s['restored']['threads']);assert len(s['phases'])==4 and all(x['exit']==0 and all(x[k]['priority']=='Normal' and x[k]['other_critical']==0 and all(t['priority']=='Normal' for t in x[k]['threads']) for k in ['before','after']) for x in s['phases'])
ledger=json.loads((out/'gpu-priority-trial-source-sha256.json').read_text());prod='platform/windows-video-compositor/video_compositor.cpp'
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in ledger.items() if p!=prod)
assert hashlib.sha256((out/'video_compositor.cpp.experiment').read_bytes()).hexdigest()==ledger[prod]
assert Path(prod).read_bytes()==(out/'video_compositor.cpp.restored').read_bytes()
ledger[prod]=hashlib.sha256(Path(prod).read_bytes()).hexdigest();(out/'restored-source-sha256.json').write_text(json.dumps(ledger,indent=2)+'\n')
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
script="$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; $r='"+root+"'; $s=Get-CimInstance Win32_Service -Filter \"Name='ESRV_SVC_QUEENCREEK'\"; $p=Get-Process -Id $s.ProcessId; $owned=@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)}); $tasks=@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver','ViewflowPerf-RestoreGpuPriorityControl','ViewflowPerf-FrameObserver' -ErrorAction SilentlyContinue); if($owned.Count -ne 0 -or $tasks.Count -ne 0){throw 'owned resources remain'}; @{time=(Get-Date).ToString('o');process_id=$p.Id;process_start_ticks=$p.StartTime.ToUniversalTime().Ticks.ToString();process_priority=$p.PriorityClass.ToString();threads=@($p.Threads | Where-Object PriorityLevel -eq 'TimeCritical' | ForEach-Object {@{id=$_.Id;priority=$_.PriorityLevel.ToString();base_priority=$_.BasePriority;start_ticks=$_.StartTime.ToUniversalTime().Ticks.ToString()}});service_state=$s.State;service_start=$s.StartMode;owned_processes=$owned.Count;owned_tasks=$tasks.Count;hashes=@(Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe'),($r+'\\native-build\\Release\\viewflow_windows_frame_observer.exe'),($r+'\\platform\\windows-video-compositor\\video_compositor.cpp') | Select-Object Path,Hash)} | ConvertTo-Json -Depth 5"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,timeout=30)
if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode(errors='replace'))
v=json.loads(r.stdout);(out/'windows-final-state.json').write_text(json.dumps(v,indent=2)+'\n');hashes={x['Path'].split('\\')[-1]:x['Hash'].lower() for x in v['hashes']};assert hashes['video_compositor.cpp']==ledger[prod]
initial=json.loads((out/'before-gpu-priority-native-sha256.json').read_text())[0]['Hash'].lower();print('restored native matches initial binary:',hashes['viewflow_windows_composition_preview.exe']==initial)
for p in out.rglob('*.log'):
 with gzip.open(p.with_name(p.name+'.gz'),'wb') as z:z.write(p.read_bytes())
 p.unlink()
print('saved',out)
