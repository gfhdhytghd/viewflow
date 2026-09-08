from pathlib import Path
import json,gzip,shutil,hashlib,subprocess,base64,sys
sys.path.insert(0,'tools');import profile_atlas_timeline as t
out=Path('docs/evidence/performance-20260908/ndis-receive-scheduling');out.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair')
comparisons=json.loads(Path('/tmp/viewflow-esrv-control-comparison.json').read_text());bylabel={x['label']:x for x in comparisons}
labels=list(bylabel)+['4k-udp-stack','4k-udp-stack-normal']
for label in labels:
 p=out/label;p.mkdir(exist_ok=True);texts={}
 for n in ['source','receiver','runner','cleanup']:
  texts[n]=(raw/f'{n}-{label}.log').read_text()
  with gzip.open(p/(n+'.log.gz'),'wb') as z:z.write(texts[n].encode())
 with gzip.open(p/'producer.log.gz','wb') as z:z.write(Path('/tmp/viewflow-frame-fixture-first/'+label+'-source.log').read_bytes())
 shutil.copy(raw/f'fixture-{label}.json',p/'fixture.json')
 if label in bylabel:
  summary=bylabel[label];shutil.copy('/tmp/'+label+'-esrv-stages.json',p/'clock-and-stages.json')
 else:
  _,stages=t.export(texts['source'],texts['receiver'],'');(p/'clock-and-stages.json').write_text(json.dumps(stages,indent=2)+'\n')
  ns=[t.numbers(x) for x in t.rows(texts['receiver'],'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
  wire=[t.numbers(x) for x in t.rows(texts['source'],'atlas-wire-timing ') if x.get('feedback_us','').isdigit() and int(x['frame'])>=30]
  summary={'native_commit_hz':(len(ns)-1)*ns[0]['frequency']/(ns[-1]['qpc']-ns[0]['qpc']),'feedback_ms':t.stats([x['feedback_us']/1000 for x in wire]),'desktop_observation':False,'wall_stage_ms':stages['wall_stage_ms']}
 (p/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(label,summary['native_commit_hz'],flush=True)
for n in ['udp-stack','udp-stack-normal']:
 p=out/n;p.mkdir(exist_ok=True)
 with gzip.open(p/'events.jsonl.gz','wb') as z:z.write(Path('/tmp/viewflow-'+n+'.jsonl').read_bytes())
 for suffix,dest in [('.jsonl.summary.json','events-summary.json'),('-correlation.json','correlation.json'),('-correlation.log','correlation.log'),('-trial-source-sha256.json','trial-source-sha256.json')]:shutil.copy('/tmp/viewflow-'+n+suffix,p/dest)
 assert all(f['source_end_ns']<=f['source_clock_mapping_valid_until_ns'] for f in json.loads((p/'correlation.json').read_text())['slow_frames'])
for n in ['esrv-control-comparison.json','esrv-control-comparison.log','esrv-priority-state.json','esrv-thread-state.json','esrv-stack-state.json','esrv-priority-trial-source-sha256.json','esrv-thread-trial-source-sha256.json','esrv-stack-trial.py','esrv-priority-trials.py','esrv-thread-trials.py','restore-esrv-priority.ps1','restore-esrv-thread.ps1','restore-esrv-stack.ps1','esrv-restore-action.json','esrv-ndis-thread-priorities.txt','udp-stack-interrupted-processes-current.json','udp-stack.wprp','udp-stack-profile-validation.log','udp-stack-reader-build.log','udp-stack-trial.py','udp-stack-normal-trial.py','run-udp-stack-reader.py','run-udp-stack-normal-reader.py','correlate-udp-stacks.py','correlate-udp-stacks-normal.py','summarize-esrv-controls.py','save-scheduler-evidence.py','tcpip-udp-events.json']:
 shutil.copy('/tmp/viewflow-'+n,out/n)
# Keep the first orchestration version as historical text; the normal .py file
# is the corrected command-based restoration harness for future reproduction.
shutil.copy('/tmp/viewflow-esrv-priority-trials-recorded.py',out/'esrv-priority-trials.py.recorded')
shutil.copy('/tmp/viewflow-udp-stack-reader/Program.cs',out/'udp-stack-reader.cs');shutil.copy('/tmp/viewflow-udp-stack-reader/reader.csproj',out/'udp-stack-reader.csproj')
with gzip.open(out/'esrv-readonly.txt.gz','wb') as z:z.write(Path('/tmp/viewflow-udp-stack-esrv-readonly.txt').read_bytes())
for n in ['udp-stack','esrv-priority','esrv-thread','esrv-stack']:
 for suffix in ['.py','-state.json']:shutil.copy('/tmp/viewflow-owned-output-'+n+suffix,out/('owned-output-'+n+suffix))
 with gzip.open(out/('owned-output-'+n+'.log.gz'),'wb') as z:z.write(Path('/tmp/viewflow-owned-output-'+n+'.log').read_bytes())
 s=json.loads((out/('owned-output-'+n+'-state.json')).read_text());assert s['before_monitors']==s['after_monitors'] and not s['remaining_owned_output_clients'];assert all(s[k].get('address')==s['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
for n in ['esrv-priority','esrv-thread','esrv-stack']:
 s=json.loads((out/(n+'-state.json')).read_text());assert s['restored']['priority']=='High' and s['restore_task_removed']
 if n!='esrv-priority':assert s['restored']['thread_priority']=='TimeCritical'
failed=out/'setup-failure';failed.mkdir(exist_ok=True)
for n in ['owned-output-esrv-thread.log','owned-output-esrv-thread-state.json','esrv-thread-state.json']:shutil.copy('/tmp/viewflow-'+n+'.setup-failure',failed/n)
ledger=json.loads(Path('/tmp/viewflow-udp-stack-trial-source-sha256.json').read_text());assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in ledger.items());(out/'verified-final-source-sha256.json').write_text(json.dumps(ledger,indent=2)+'\n')
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
script="$ErrorActionPreference='Stop'; $r='"+root+"'; $p=Get-Process -Id 8108; $t=@($p.Threads|Where-Object Id -eq 10144); $s=Get-CimInstance Win32_Service -Filter \"Name='ESRV_SVC_QUEENCREEK'\"; $owned=@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)}); $tasks=@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver','ViewflowPerf-RestoreEsrvPriority','ViewflowPerf-RestoreEsrvThread','ViewflowPerf-RestoreEsrvStack' -ErrorAction SilentlyContinue); if($p.PriorityClass -ne 'High' -or $t[0].PriorityLevel -ne 'TimeCritical' -or $s.State -ne 'Running' -or $s.StartMode -ne 'Auto' -or $owned.Count -ne 0 -or $tasks.Count -ne 0){throw 'final state mismatch'}; @{process_id=$p.Id;process_start_ticks=$p.StartTime.ToUniversalTime().Ticks.ToString();process_priority=$p.PriorityClass.ToString();thread_id=$t[0].Id;thread_priority=$t[0].PriorityLevel.ToString();thread_base_priority=$t[0].BasePriority;service_state=$s.State;service_start=$s.StartMode;owned_processes=$owned.Count;owned_tasks=$tasks.Count;execution_policy=(Get-ExecutionPolicy).ToString();hashes=@(Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe'),($r+'\\udp-stack-reader\\reader.exe') -Algorithm SHA256 | Select-Object Path,Hash)} | ConvertTo-Json -Depth 4"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();v=json.loads(r.stdout.decode('utf-8-sig'));(out/'windows-final-state.json').write_text(json.dumps(v,indent=2)+'\n')
script='wpr -status; pktmon status; pktmon filter list; netsh trace show status; exit 0';r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();(out/'recording-final-state.txt').write_bytes(r.stdout)
print('saved',out)

for log_path in out.rglob("*.log"):
 with gzip.open(log_path.with_name(log_path.name+".gz"),"wb") as z:z.write(log_path.read_bytes())
 log_path.unlink()
