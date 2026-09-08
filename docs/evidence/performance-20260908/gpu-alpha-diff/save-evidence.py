from pathlib import Path
import json,shutil,hashlib,gzip,subprocess,base64,sys
sys.path.insert(0,'tools');import profile_atlas_timeline as t
out=Path('docs/evidence/performance-20260908/gpu-alpha-diff')
for name in ['gpu-alpha-diff-build','gpu-alpha-diff-sparse-build','gpu-alpha-diff-release','gpu-alpha-diff-ctest','gpu-alpha-diff-4k','gpu-alpha-cpu-4k','gpu-alpha-diff-allocation-fallback','gpu-alpha-diff-pageable','alpha-diff-av1-cpu','alpha-diff-av1-gpu','gpu-alpha-diff-summary','owned-output-alpha-diff','owned-output-no-observer']:
 shutil.copy('/tmp/viewflow-'+name+'.log',out/(name+'.log'))
for name,dest in [('summarize-gpu-alpha-diff.py','summarize-trials.py'),('gpu-alpha-diff-trials.py','run-trials.py'),('owned-output-alpha-diff.py','owned-output.py'),('owned-output-alpha-diff-state.json','owned-output-state.json'),('owned-output-no-observer-state.json','owned-output-no-observer-state.json'),('gpu-alpha-diff-av1-identity.json','av1-identity.json')]:shutil.copy('/tmp/viewflow-'+name,out/dest)
# AV1 initial packets remain bit-identical after the final allocation-order edit.
identity=json.loads((out/'av1-identity.json').read_text())
for key,hashes in identity.items():
 for mode,h in hashes.items():assert hashlib.sha256((Path('/tmp/viewflow-alpha-diff-av1-'+mode)/key).read_bytes()).hexdigest()==h
paths=['platform/nvenc-encoder/gpu_dmabuf_encoder.cu','platform/nvenc-encoder/gpu_dmabuf_encoder_integration_test.cu','platform/nvenc-encoder/gpu_sparse_encoder_test.cpp','target/release/vf-media-peer']
(out/'source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
raw=Path('/tmp/viewflow-integrated-pair');label='4k-alpha-diff-no-observer';trial=out/label;trial.mkdir(exist_ok=True)
for name in ['source','receiver','runner','cleanup']:
 with gzip.open(trial/(name+'.log.gz'),'wb') as z:z.write((raw/f'{name}-{label}.log').read_bytes())
with gzip.open(trial/'producer.log.gz','wb') as z:z.write((Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')).read_bytes())
shutil.copy(raw/f'fixture-{label}.json',trial/'fixture.json')
s=(raw/f'source-{label}.log').read_text();r=(raw/f'receiver-{label}.log').read_text();_,c=t.export(s,r,'')
(trial/'clock-and-stages.json').write_text(json.dumps(c,indent=2)+'\n')
residual=[]
for label in ['4k-alpha-diff-on-b1','4k-alpha-diff-on-b2','4k-alpha-diff-no-observer']:
 s=(raw/f'source-{label}.log').read_text();r=(raw/f'receiver-{label}.log').read_text()
 cm=[t.numbers(x) for x in t.rows(r,'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
 sw=[t.numbers(x) for x in t.rows(s,'atlas-source-timing ') if int(x['frame'])>=30];wire=[t.numbers(x) for x in t.rows(s,'atlas-wire-timing ') if int(x['frame'])>=30]
 result={'label':label,'native_commit_hz':(len(cm)-1)*cm[0]['frequency']/(cm[-1]['qpc']-cm[0]['qpc']),'native_interval_s':(cm[-1]['qpc']-cm[0]['qpc'])/cm[0]['frequency'],'frames':len(cm),'previous_feedback_wait_ms':t.stats([x['previous_feedback_wait_us']/1000 for x in sw]),'feedback_ms':t.stats([x['feedback_us']/1000 for x in wire]),'previous_feedback_total_s':sum(x['previous_feedback_wait_us'] for x in sw)/1e6}
 residual.append(result)
 if label.endswith('no-observer'):(trial/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
(out/'remaining-waits.json').write_text(json.dumps(residual,indent=2)+'\n')
for state in ['owned-output-state.json','owned-output-no-observer-state.json']:
 data=json.loads((out/state).read_text());assert data['before_monitors']==data['after_monitors'] and not data['remaining_owned_output_clients']
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
s="$ProgressPreference='SilentlyContinue'; $r='"+root+"'; Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe') -Algorithm SHA256 | Format-List Path,Hash; $p=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[System.StringComparison]::OrdinalIgnoreCase) }); Write-Output ('owned_processes='+$p.Count); Write-Output ('owned_tasks='+@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver' -ErrorAction SilentlyContinue).Count); pktmon status; pktmon filter list; wpr -status"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();(out/'windows-final-state.txt').write_bytes(r.stdout)
