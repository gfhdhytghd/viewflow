from pathlib import Path
import json,gzip,shutil,hashlib,subprocess,base64
out=Path('docs/evidence/performance-20260908/udp-pacing-rejected');out.mkdir(exist_ok=True)
labels=['4k-pacing-off-a1','4k-pacing-eight-b1','4k-pacing-eight-b2','4k-pacing-off-a2'];raw=Path('/tmp/viewflow-integrated-pair')
for label in labels:
 p=out/label;p.mkdir(exist_ok=True)
 for n in ['source','receiver','runner','cleanup']:
  with gzip.open(p/(n+'.log.gz'),'wb') as z:z.write((raw/f'{n}-{label}.log').read_bytes())
 with gzip.open(p/'producer.log.gz','wb') as z:z.write(Path('/tmp/viewflow-frame-fixture-first/'+label+'-source.log').read_bytes())
 shutil.copy(raw/f'fixture-{label}.json',p/'fixture.json');shutil.copy('/tmp/'+label+'-pacing-stages.json',p/'clock-and-stages.json')
for n in ['udp-pacing-comparison.json','udp-pacing-comparison.log','udp-pacing-trial-source-sha256.json','udp-pacing-trials.py','owned-output-udp-pacing.py','owned-output-udp-pacing-state.json','udp-pacing-tests.log','udp-pacing-build.log','udp-pacing-restored-build.log','summarize-udp-pacing.py','save-pacing-evidence.py']:
 shutil.copy('/tmp/viewflow-'+n,out/n)
with gzip.open(out/'owned-output.log.gz','wb') as z:z.write(Path('/tmp/viewflow-owned-output-udp-pacing.log').read_bytes())
# These source files are archived as the actual compiled trial inputs, not active code.
ledger=json.loads((out/'udp-pacing-trial-source-sha256.json').read_text())
for n in ['atlas_socket_trace.rs','atlas_udp_pacing.rs','lib.rs']:assert hashlib.sha256((out/(n+'.trial')).read_bytes()).hexdigest()==ledger['crates/viewflowd/src/'+n]
restored=json.loads(Path('/tmp/viewflow-ndis-network-trial-source-sha256.json').read_text());assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in restored.items());(out/'restored-source-sha256.json').write_text(json.dumps(restored,indent=2)+'\n')
s=json.loads((out/'owned-output-udp-pacing-state.json').read_text());assert s['before_monitors']==s['after_monitors'] and not s['remaining_owned_output_clients'];assert all(s[k].get('address')==s['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();script="$ErrorActionPreference='Stop'; $r='"+root+"'; Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe') -Algorithm SHA256 | Format-List Path,Hash; Write-Output ('owned_processes='+@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase) }).Count); Write-Output ('owned_tasks='+@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver' -ErrorAction SilentlyContinue).Count); wpr -status; netsh trace show status; exit 0"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();(out/'windows-final-state.txt').write_bytes(r.stdout);assert b'owned_processes=0' in r.stdout and b'owned_tasks=0' in r.stdout
print('saved',out)

for log_path in out.rglob("*.log"):
 with gzip.open(log_path.with_name(log_path.name+".gz"),"wb") as z:z.write(log_path.read_bytes())
 log_path.unlink()
