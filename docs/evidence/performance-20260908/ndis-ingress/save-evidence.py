from pathlib import Path
import sys,json,gzip,shutil,hashlib,subprocess,base64
sys.path.insert(0,'tools');import profile_atlas_timeline as t
out=Path('docs/evidence/performance-20260908/ndis-ingress');out.mkdir(exist_ok=True);trial=out/'4k-ndis-network';trial.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');label='4k-ndis-network';texts={}
for n in ['source','receiver','runner','cleanup']:
 texts[n]=(raw/f'{n}-{label}.log').read_text()
 with gzip.open(trial/(n+'.log.gz'),'wb') as z:z.write(texts[n].encode())
with gzip.open(trial/'producer.log.gz','wb') as z:z.write(Path('/tmp/viewflow-frame-fixture-first/4k-ndis-network-source.log').read_bytes())
shutil.copy(raw/f'fixture-{label}.json',trial/'fixture.json');_,stages=t.export(texts['source'],texts['receiver'],'')
ns=[t.numbers(x) for x in t.rows(texts['receiver'],'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
summary={'native_commit_hz':(len(ns)-1)*ns[0]['frequency']/(ns[-1]['qpc']-ns[0]['qpc']),'desktop_observation':False,'wall_stage_ms':stages['wall_stage_ms']}
for n,v in [('summary',summary),('clock-and-stages',stages)]: (trial/(n+'.json')).write_text(json.dumps(v,indent=2)+'\n')
for n,d in [('4k-ndis-network-socket-summary.json','socket-summary.json'),('ndis-network-correlation.json','correlation.json'),('ndis-network-trial-source-sha256.json','trial-source-sha256.json'),('owned-output-ndis-network-state.json','owned-output-state.json'),('analyze-deep-socket.py','analyze-socket.py'),('correlate-ndis-network.py','correlate-ndis-network.py'),('ndis-network-trial.py','run-trial.py'),('owned-output-ndis-network.py','owned-output.py'),('save-ndis-evidence.py','save-evidence.py'),('network-only.wprp','network-only.wprp'),('tcpip-provider-inspect.txt','tcpip-provider-inspect.txt'),('tcpip-nrt-events.txt','tcpip-nrt-events.txt')]:shutil.copy('/tmp/viewflow-'+n,out/d)
for n in ['ndis-network','ndis-kernel']:
 with gzip.open(out/(n+'.jsonl.gz'),'wb') as z:z.write(Path('/tmp/viewflow-'+n+'.jsonl').read_bytes())
 shutil.copy('/tmp/viewflow-'+n+'.jsonl.summary.json',out/(n+'-events.json'))
for n in ['owned-output-ndis-network','ndis-network-correlation','ndis-network-socket-analysis','ndis-reader-build']:
 with gzip.open(out/(n+'.log.gz'),'wb') as z:z.write(Path('/tmp/viewflow-'+n+'.log').read_bytes())
probe=out/'probe';probe.mkdir(exist_ok=True)
for n in ['ndis-probe.py','ndis-probe.log','ndis-reader-probe.log','validate-ndis-probe.py','ndis-probe-validation.json','udp-burst-ndis-source.json','udp-burst-ndis-receiver.log','run-ndis-reader.py']:
 shutil.copy('/tmp/viewflow-'+n,probe/n)
shutil.copy('/tmp/viewflow-ndis-reader/Program.cs',probe/'ndis-reader.cs');shutil.copy('/tmp/viewflow-ndis-reader/reader.csproj',probe/'ndis-reader.csproj')
with gzip.open(probe/'probe-ndis.jsonl.gz','wb') as z:z.write(Path('/tmp/viewflow-probe-ndis.jsonl').read_bytes())
shutil.copy('/tmp/viewflow-probe-ndis.jsonl.summary.json',probe/'events.json')
ledger=json.loads((out/'trial-source-sha256.json').read_text());assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==v for p,v in ledger.items());state=json.loads((out/'owned-output-state.json').read_text());assert state['before_monitors']==state['after_monitors'] and not state['remaining_owned_output_clients']
for k in ['before_focus','after_create_focus','after_focus']:assert state[k].get('address')==state['before_focus'].get('address')
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
s="$ProgressPreference='SilentlyContinue'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $r='"+root+"'; Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe') -Algorithm SHA256 | Format-List Path,Hash; $p=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[System.StringComparison]::OrdinalIgnoreCase) }); Write-Output ('owned_processes='+$p.Count); Write-Output ('owned_tasks='+@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver' -ErrorAction SilentlyContinue).Count); wpr -status; pktmon status; pktmon filter list; netsh trace show status; Get-NetAdapter | Select-Object ifIndex,Name,InterfaceDescription | Format-Table; pktmon list --json; exit 0"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();(out/'windows-final-state.txt').write_bytes(r.stdout)
print('native_commit_hz',summary['native_commit_hz'])
