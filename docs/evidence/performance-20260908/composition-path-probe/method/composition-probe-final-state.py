from pathlib import Path
import subprocess,base64,json,hashlib
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
s=r'''$ErrorActionPreference='Stop';$r='__ROOT__';$s=Get-CimInstance Win32_Service -Filter "Name='ESRV_SVC_QUEENCREEK'";$p=Get-Process -Id $s.ProcessId;$owned=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)});$tasks=@(Get-ScheduledTask -TaskName 'ViewflowPerf-IntegratedReceiver','ViewflowPerf-RestoreCommitCadence','ViewflowPerf-CompositionProbe','ViewflowPerf-CompositionProbeObserver','ViewflowPerf-RestoreCompositionProbe','ViewflowPerf-RestoreCompositionToggleProbe','ViewflowPerf-FrameObserver','ViewflowPerf-CoalescePixels','ViewflowPerf-HostBackdrop' -ErrorAction SilentlyContinue);$paths=@('native-trace-controls-build\Release\viewflow_windows_composition_preview.exe','native-build\Release\viewflow_windows_composition_preview.exe','target\release\vf-media-peer.exe','native-build\Release\viewflow_windows_frame_observer.exe','isolated-receiver-runner-trace-full.exe','isolated-receiver-runner-trace-noquery.exe','isolated-receiver-runner-trace-minimal.exe','isolated-receive.json','platform\windows-composition-preview\main.cpp','platform\windows-video-compositor\gpu_timestamp_probe.h','target\release\vf_media_peer.pdb','native-build\Release\viewflow_windows_composition_preview.pdb');@{time=(Get-Date).ToString('o');process_id=$p.Id;priority=$p.PriorityClass.ToString();threads=@($p.Threads|Where-Object PriorityLevel -eq 'TimeCritical'|Select-Object Id,PriorityLevel,BasePriority);service_state=$s.State;service_start=$s.StartMode;owned_processes=$owned.Count;owned_tasks=$tasks.Count;experimental_header_exists=(Test-Path ($r+'\platform\windows-composition-preview\stable_surface_layout.h'));hashes=@($paths|ForEach-Object {Get-FileHash ($r+'\'+$_)}|Select-Object Path,Hash)}|ConvertTo-Json -Depth 4'''.replace('__ROOT__',root)
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();v=json.loads(r.stdout);h=v['hashes'];b=json.loads(Path('/tmp/viewflow-trace-controls-binaries.json').read_text());assert h[:7]==b['hashes']
assert not v['experimental_header_exists'] and v['owned_processes']==v['owned_tasks']==0 and v['priority']=='High' and v['service_state']=='Running' and v['service_start']=='Auto'
assert len(v['threads'])==2
assert h[7]['Hash'].lower()==hashlib.sha256(Path('/tmp/viewflow-codec-restore-receive-remote.json').read_bytes()).hexdigest()
for i,n in enumerate(['platform/windows-composition-preview/main.cpp','platform/windows-video-compositor/gpu_timestamp_probe.h']):
 assert h[8+i]['Hash'].lower()==hashlib.sha256(Path(n).read_bytes()).hexdigest()
old=json.loads(Path('/tmp/viewflow-nowait-binaries.json').read_text())['hashes'];assert h[10]==old[3] and h[11]==old[4]
for n in ['send','receive']:assert Path('/tmp/viewflow-integrated-pair/'+n+'.json').read_bytes()==Path('/tmp/viewflow-codec-restore-'+n+'.json').read_bytes()
final_source={}
for n,d in json.loads(Path('/tmp/viewflow-commit-cadence-trial-source-sha256.json').read_text()).items():
 candidate=Path('docs/evidence/performance-20260908/capture-commit-cadence/source-prototype')/n if n.startswith('platform/viewflow-capture/') else Path(n)
 current=candidate.read_bytes();assert hashlib.sha256(current).hexdigest()==d,n
 final_source[n]=d
v['trial_source_and_binaries_sha256']=final_source
v['post_trial_source_change']='experimental capture main/CMake restored to original; two new policy/test files removed; tested prototype archived'
v['production_hashes']={}
for n,d in json.loads(Path('/tmp/viewflow-before-commit-cadence-sha256.json').read_text()).items():
 assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==d,n
 v['production_hashes'][n]=d
for n in ['platform/viewflow-capture/src/capture_commit_schedule.hpp','platform/viewflow-capture/tests/capture_commit_schedule_test.cpp']:assert not Path(n).exists()
v['production_source_restored']=True
extra_files=list(json.loads(Path('/tmp/viewflow-composition-probe-build-success.json').read_text())['source_hashes'])+['platform/windows-composition-preview/CMakeLists.txt','viewflow_windows_composition_latency_probe.exe','composition-latency-probe-cmake-build/Release/viewflow_windows_composition_latency_probe.exe']
code="$ErrorActionPreference='Stop';$r='"+root+"';@("+','.join("'"+n+"'" for n in extra_files)+")|ForEach-Object {Get-FileHash ($r+'\\'+$_)}|Select-Object Path,Hash|ConvertTo-Json"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(code.encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();current=json.loads(r.stdout)
for n,entry in zip(extra_files[:6],current[:6]):assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==entry['Hash'].lower(),n
assert current[6]['Hash']==json.loads(Path('/tmp/viewflow-composition-probe-build-success.json').read_text())['Hash']
v['probe_current_source_and_build_hashes']=current
Path('/tmp/viewflow-composition-probe-final-state.json').write_text(json.dumps(v,indent=2)+'\n')
print('original production binaries/PDB/configs and cleanup verified; ESRV restored; current six probe source files and manual probe EXE match; CMake EXE hash recorded')
