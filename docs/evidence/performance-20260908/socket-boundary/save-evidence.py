from pathlib import Path
import json,shutil,gzip,hashlib,sys,re,statistics,subprocess,base64
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
import summarize_desktop_markers as d
out=Path('docs/evidence/performance-20260908/socket-boundary');out.mkdir(exist_ok=True)
label='4k-socket-boundary';trial=out/label;trial.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');texts={}
for name in ['source','receiver','desktop','runner','cleanup']:
 texts[name]=(raw/f'{name}-{label}.log').read_text()
 with gzip.open(trial/(name+'.log.gz'),'wb') as z:z.write(texts[name].encode())
producer=(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')).read_text()
with gzip.open(trial/'producer.log.gz','wb') as z:z.write(producer.encode())
shutil.copy(raw/f'fixture-{label}.json',trial/'fixture.json')
_,c=t.export(texts['source'],texts['receiver'],texts['desktop']);b=d.latency_bounds(texts['desktop'],texts['source'],producer,texts['receiver'])
n=[t.numbers(x) for x in t.rows(texts['receiver'],'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
summary={'native_commit_hz':(len(n)-1)*n[0]['frequency']/(n[-1]['qpc']-n[0]['qpc']), 'capture_to_mutation_upper_ms':b['unique_capture_stage_samples']['capture_to_mutation_upper_ms'], 'capture_to_desktop_upper_ms':b['unique_capture_stage_samples']['capture_to_desktop_upper_ms'], 'wall_stage_ms':c['wall_stage_ms']}
for name,value in [('summary',summary),('clock-and-stages',c),('desktop',b)]: (trial/(name+'.json')).write_text(json.dumps(value,indent=2)+'\n')
for source,dest in [('/tmp/viewflow-4k-socket-boundary-socket-summary.json','socket-summary.json'),('/tmp/viewflow-analyze-socket-boundary.py','analyze-socket-boundary.py'),('/tmp/viewflow-owned-output-socket-state.json','owned-output-state.json')]:shutil.copy(source,out/dest)
for name in ['socket-trace-linux-build','socket-trace-linux-test','socket-trace-windows-build','socket-trace-runner-build','socket-boundary-analysis','socket-boundary-stages','owned-output-socket-trial']:
 shutil.copy('/tmp/viewflow-'+name+'.log',out/(name+'.log'))
# Independent UDP runs, completed before the socket trial.
probe=out/'plain-udp';probe.mkdir(exist_ok=True);probes={}
for label in ['a1','port49101-idle','active']:
 rec=Path('/tmp/viewflow-udp-burst-'+label+'-receiver.log').read_text();src=json.loads(Path('/tmp/viewflow-udp-burst-'+label+'-source.json').read_text());freq=int(re.search(r'frequency=(\d+)',rec)[1]);groups={}
 for batch,seq,qpc in re.findall(r'probe-packet batch=(\d+) sequence=(\d+) qpc=(\d+)',rec):groups.setdefault(int(batch),[]).append((int(seq),int(qpc)))
 rows=[]
 for row in src:
  group=groups[row['batch']];assert len(group)==row['packets'] and len({seq for seq,_ in group})==row['packets']
  qpcs=[q for _,q in group]
  rows.append(dict(row,receive_span_ms=(max(qpcs)-min(qpcs))*1000/freq,max_receive_gap_ms=max(b-a for a,b in zip(qpcs,qpcs[1:]))*1000/freq))
 probes[label]={'rows':rows,'rtt_ms':{str(size):t.stats([r['round_trip_us']/1000 for r in rows if r['packets']==size]) for size in [20,150]}}
 with gzip.open(probe/(label+'-receiver.log.gz'),'wb') as z:z.write(rec.encode())
 (probe/(label+'-source.json')).write_text(json.dumps(src,indent=2)+'\n')
for name in ['udp-burst-probe.cpp','udp-burst-build.cmd','run-udp-burst.py','active-udp-trial.py','owned-output-udp-trial.py','owned-output-udp-state.json']:
 shutil.copy('/tmp/viewflow-'+name,probe/name)
(probe/'summary.json').write_text(json.dumps(probes,indent=2)+'\n')
active=probe/'4k-active-stream';active.mkdir(exist_ok=True)
for name in ['source','receiver','desktop','runner','cleanup']:
 with gzip.open(active/(name+'.log.gz'),'wb') as z:z.write((raw/f'{name}-4k-scratch-active-udp.log').read_bytes())
shutil.copy(raw/'fixture-4k-scratch-active-udp.json',active/'fixture.json')
# Exact current local sources and instrumented executable, after the run.
paths=['crates/viewflowd/Cargo.toml','crates/viewflowd/src/atlas_socket_trace.rs','crates/viewflowd/src/lib.rs','crates/viewflowd/src/atlas_source.rs','crates/viewflowd/src/atlas_peer.rs','platform/nvenc-encoder/gpu_dmabuf_encoder.cu','target/release/vf-media-peer']
(out/'source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
s="$ProgressPreference='SilentlyContinue'; $r='"+root+"'; Get-FileHash ($r+'\\target\\release\\vf-media-peer.exe'),($r+'\\native-build\\Release\\viewflow_windows_composition_preview.exe') -Algorithm SHA256 | Format-List Path,Hash; $p=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[System.StringComparison]::OrdinalIgnoreCase) }); Write-Output ('owned_processes='+$p.Count); Write-Output ('owned_tasks='+@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver' -ErrorAction SilentlyContinue).Count); pktmon status; pktmon filter list; wpr -status"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30)
(out/'windows-final-state.txt').write_bytes(r.stdout+r.stderr)
print(json.dumps(summary,indent=2))
