from pathlib import Path
import sys,json,gzip,shutil,hashlib,subprocess,base64
sys.path.insert(0,'tools');import profile_atlas_timeline as t
out=Path('docs/evidence/performance-20260908/active-udp-controls');out.mkdir(exist_ok=True)
for label in ['4k-active-interactive-udp-v2','4k-paired-ecn']:
 p=out/label;p.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');texts={}
 for n in ['source','receiver','runner','cleanup']:
  texts[n]=(raw/f'{n}-{label}.log').read_text()
  with gzip.open(p/(n+'.log.gz'),'wb') as z:z.write(texts[n].encode())
 with gzip.open(p/'producer.log.gz','wb') as z:z.write(Path('/tmp/viewflow-frame-fixture-first/'+label+'-source.log').read_bytes())
 shutil.copy(raw/f'fixture-{label}.json',p/'fixture.json');_,stages=t.export(texts['source'],texts['receiver'],'')
 ns=[t.numbers(x) for x in t.rows(texts['receiver'],'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
 summary={'native_commit_hz':(len(ns)-1)*ns[0]['frequency']/(ns[-1]['qpc']-ns[0]['qpc']),'desktop_observation':False,'wall_stage_ms':stages['wall_stage_ms']}
 (p/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');(p/'clock-and-stages.json').write_text(json.dumps(stages,indent=2)+'\n')
 shutil.copy('/tmp/viewflow-'+label+'-socket-summary.json',p/'socket-summary.json');print(label,summary['native_commit_hz'])
for name in ['active-nonblocking-v2','active-blocking-v2','paired-ecn0','paired-ecn2']:
 p=out/name;p.mkdir(exist_ok=True)
 for n in ['source.json','probe-output.log','probe-status.log','process-sessions.json']:
  src=Path('/tmp/viewflow-interactive-udp-'+name)/n
  if n.endswith('.log'):
   with gzip.open(p/(n+'.gz'),'wb') as z:z.write(src.read_bytes())
  else:shutil.copy(src,p/n)
for n in ['active-udp-summary.json','active-udp-summary.log','summarize-paired-udp.py','analyze-deep-socket.py','udp-parity-probe.cpp','udp-interactive-runner.cpp','udp-interactive-build.cmd','udp-paired-probe.cpp','udp-paired-runner.cpp','udp-paired-build.cmd','udp-paired-build.log','run-interactive-udp.py','run-paired-udp.py','active-interactive-udp-v2.py','active-paired-ecn.py','owned-output-active-interactive-udp-v2.py','owned-output-paired-ecn.py','owned-output-active-interactive-udp-v2-state.json','owned-output-paired-ecn-state.json','save-active-udp-evidence.py']:
 shutil.copy('/tmp/viewflow-'+n,out/n)
for n in ['owned-output-active-interactive-udp-v2','owned-output-paired-ecn','active-interactive-socket-analysis','paired-ecn-socket-analysis']:
 with gzip.open(out/(n+'.log.gz'),'wb') as z:z.write(Path('/tmp/viewflow-'+n+'.log').read_bytes())
for n in ['owned-output-active-interactive-udp-v2-state.json','owned-output-paired-ecn-state.json']:
 s=json.loads((out/n).read_text());assert s['before_monitors']==s['after_monitors'] and not s['remaining_owned_output_clients'];assert all(s[k].get('address')==s['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
ledger=json.loads(Path('/tmp/viewflow-ndis-network-trial-source-sha256.json').read_text());assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==v for p,v in ledger.items());(out/'source-sha256.json').write_text(json.dumps({'verified_after_trial':ledger,'reference_ledger':'../ndis-ingress/trial-source-sha256.json','note':'These sources and binary still match the prior NDIS trial ledger; no fresh pretrial ledger was recorded for these probe trials.'},indent=2)+'\n')
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
s="$ProgressPreference='SilentlyContinue'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $r='"+root+"'; Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe'),($r+'\\udp-parity-probe.exe'),($r+'\\udp-interactive-runner.exe'),($r+'\\udp-paired-probe.exe'),($r+'\\udp-paired-runner.exe') -Algorithm SHA256 | Format-List Path,Hash; $p=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[System.StringComparison]::OrdinalIgnoreCase) }); Write-Output ('owned_processes='+$p.Count); Write-Output ('owned_tasks='+@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver','ViewflowPerf-InteractiveUDPProbe','ViewflowPerf-PairedUDPProbe-49101','ViewflowPerf-PairedUDPProbe-49102' -ErrorAction SilentlyContinue).Count); wpr -status; pktmon status; pktmon filter list; netsh trace show status; Get-Content ($r+'\\udp-interactive-build.log') -ErrorAction SilentlyContinue; exit 0"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();(out/'windows-final-state.txt').write_bytes(r.stdout);assert b'owned_processes=0' in r.stdout and b'owned_tasks=0' in r.stdout
print('saved',out)
