from pathlib import Path
import json,shutil,gzip,hashlib,sys,re,statistics,subprocess,base64
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
import summarize_desktop_markers as d
out=Path('docs/evidence/performance-20260908/deep-socket');out.mkdir(exist_ok=True)
label='4k-deep-socket';trial=out/label;trial.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');texts={}
for name in ['source','receiver','desktop','runner','cleanup']:
 texts[name]=(raw/f'{name}-{label}.log').read_text() if name!='desktop' else ''
 with gzip.open(trial/(name+'.log.gz'),'wb') as z:z.write(texts[name].encode())
producer=(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')).read_text()
with gzip.open(trial/'producer.log.gz','wb') as z:z.write(producer.encode())
shutil.copy(raw/f'fixture-{label}.json',trial/'fixture.json')
_,c=t.export(texts['source'],texts['receiver'],texts['desktop']);b={'available':False,'reason':'desktop observer disabled'}
n=[t.numbers(x) for x in t.rows(texts['receiver'],'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
summary={'native_commit_hz':(len(n)-1)*n[0]['frequency']/(n[-1]['qpc']-n[0]['qpc']), 'capture_to_mutation_upper_ms':None, 'capture_to_desktop_upper_ms':None, 'wall_stage_ms':c['wall_stage_ms']}
for name,value in [('summary',summary),('clock-and-stages',c),('desktop',b)]: (trial/(name+'.json')).write_text(json.dumps(value,indent=2)+'\n')
for source,dest in [('/tmp/viewflow-4k-deep-socket-socket-summary.json','socket-summary.json'),('/tmp/viewflow-analyze-deep-socket.py','analyze-deep-socket.py'),('/tmp/viewflow-owned-output-deep-socket-state.json','owned-output-state.json')]:shutil.copy(source,out/dest)
for name in ['deep-socket-linux-build','deep-socket-linux-tests','deep-socket-windows-build','deep-socket-analysis','owned-output-deep-socket']:
 shutil.copy('/tmp/viewflow-'+name+'.log',out/(name+'.log'))
# Exact current local sources and instrumented executable, after the run.
paths=['crates/viewflowd/Cargo.toml','crates/viewflowd/src/atlas_socket_trace.rs','crates/viewflowd/src/lib.rs','crates/viewflowd/src/atlas_source.rs','crates/viewflowd/src/atlas_peer.rs','platform/nvenc-encoder/gpu_dmabuf_encoder.cu','target/release/vf-media-peer']
(out/'source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
s="$ProgressPreference='SilentlyContinue'; $r='"+root+"'; Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe') -Algorithm SHA256 | Format-List Path,Hash; $p=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[System.StringComparison]::OrdinalIgnoreCase) }); Write-Output ('owned_processes='+$p.Count); Write-Output ('owned_tasks='+@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver' -ErrorAction SilentlyContinue).Count); pktmon status; pktmon filter list; wpr -status"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30)
r.check_returncode(); (out/'windows-final-state.txt').write_bytes(r.stdout)
state=json.loads((out/'owned-output-state.json').read_text()); assert state['before_monitors']==state['after_monitors']; assert not state['remaining_owned_output_clients']
for k in ['before_focus','after_create_focus','after_focus']: assert state[k].get('address')==state['before_focus'].get('address')
for p in ['deep-socket-trial.py','owned-output-deep-socket.py']: shutil.copy('/tmp/viewflow-'+p,out/p)
print(json.dumps(summary,indent=2))
