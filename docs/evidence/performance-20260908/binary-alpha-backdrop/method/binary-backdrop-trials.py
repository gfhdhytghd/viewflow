from pathlib import Path
import subprocess,base64,json,os,hashlib
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();task='ViewflowPerf-RestoreBinaryBackdrop';state=Path('/tmp/viewflow-binary-backdrop-state.json')
def ps(code):
 code="$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); "+code
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(code.encode('utf-16le')).decode()],capture_output=True,timeout=40)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode(errors='replace'))
 return r.stdout.decode(errors='replace')
expected=json.loads(Path('/tmp/viewflow-binary-backdrop-build-success.json').read_text())
for n,h in expected['source_hashes'].items():assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==h,n
for entry in expected['hashes']:
 actual=ps("(Get-FileHash '"+entry['Path']+"').Hash").strip();assert actual==entry['Hash'],entry['Path']
initial=json.loads(ps("$s=Get-CimInstance Win32_Service -Filter \"Name='ESRV_SVC_QUEENCREEK'\"; $p=Get-Process -Id $s.ProcessId; $t=@($p.Threads | Where-Object PriorityLevel -eq 'TimeCritical'); if($p.Path -ne 'C:\\Program Files\\Intel\\SUR\\QUEENCREEK\\x64\\esrv_svc.exe' -or $s.State -ne 'Running' -or $p.PriorityClass -ne 'High' -or $t.Count -lt 1 -or $t.Count -gt 4){throw 'unexpected process/thread baseline'}; if(Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue){throw 'restore task already exists'}; @{id=$p.Id;start_ticks=$p.StartTime.ToUniversalTime().Ticks.ToString();priority=$p.PriorityClass.ToString();path=$p.Path;threads=@($t|ForEach-Object {@{id=$_.Id;start_ticks=$_.StartTime.ToUniversalTime().Ticks.ToString();priority=$_.PriorityLevel.ToString()}});service_state=$s.State;service_start=$s.StartMode} | ConvertTo-Json -Depth 4"))
identities='@{'+ ';'.join(str(t['id'])+"='"+t['start_ticks']+"'" for t in initial['threads'])+'}'
identity="$p=Get-Process -Id "+str(initial['id'])+"; if($p.StartTime.ToUniversalTime().Ticks.ToString() -ne '"+initial['start_ticks']+"'){throw 'process identity changed'}; $ids="+identities+"; $t=@($p.Threads|Where-Object {$ids.ContainsKey($_.Id)}); if($t.Count -ne $ids.Count){throw 'controlled thread disappeared'}; foreach($x in $t){if($x.StartTime.ToUniversalTime().Ticks.ToString() -ne $ids[$x.Id]){throw 'thread identity changed'}}; "
report="@{id=$p.Id;priority=$p.PriorityClass.ToString();threads=@($t | ForEach-Object {@{id=$_.Id;priority=$_.PriorityLevel.ToString();base_priority=$_.BasePriority}});other_critical=@($p.Threads|Where-Object PriorityLevel -eq 'TimeCritical').Count;time=(Get-Date).ToString('o')} | ConvertTo-Json -Depth 4"
restore="$p=Get-Process -Id "+str(initial['id'])+" -ErrorAction SilentlyContinue; if($p -and $p.StartTime.ToUniversalTime().Ticks.ToString() -eq '"+initial['start_ticks']+"'){$ids="+identities+"; foreach($t in $p.Threads){if($ids.ContainsKey($t.Id) -and $t.StartTime.ToUniversalTime().Ticks.ToString() -eq $ids[$t.Id] -and $t.PriorityLevel -eq 'Normal'){$t.PriorityLevel='TimeCritical'}};if($p.PriorityClass -eq 'Normal'){$p.PriorityClass='High'}}"
Path('/tmp/viewflow-restore-binary-backdrop.ps1').write_text(restore)
send_path=Path('/tmp/viewflow-integrated-pair/send.json');receive_path=Path('/tmp/viewflow-integrated-pair/receive.json')
original_send=Path('/tmp/viewflow-codec-restore-send.json').read_bytes();original_receive=Path('/tmp/viewflow-codec-restore-receive.json').read_bytes()
original_remote=Path('/tmp/viewflow-codec-restore-receive-remote.json')
data={'initial':initial,'phases':[]};state.write_text(json.dumps(data,indent=2)+'\n');registered=False
try:
 ps("$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -EncodedCommand "+base64.b64encode(restore.encode('utf-16le')).decode()+"'; $t=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10); Register-ScheduledTask -TaskName '"+task+"' -Action $a -Trigger $t -User 'SYSTEM' -RunLevel Highest | Out-Null");registered=True
 paths=['crates/viewflowd/src/atlas_source.rs', 'crates/viewflowd/src/gpu_atlas_capture.rs', 'crates/viewflowd/src/gpu_atlas_device.rs', 'crates/viewflowd/src/gpu_atlas_session.rs', 'crates/viewflowd/src/hyprcapture_gpu_socket.rs', 'platform/windows-composition-preview/main.cpp', 'platform/windows-composition-preview/sparse_opaque.h', 'platform/windows-composition-preview/atlas_frame_bindings.h', 'platform/windows-composition-preview/sparse_shared_visuals.h', 'platform/windows-video-compositor/gpu_timestamp_probe.h', 'target/release/vf-media-peer', 'tools/windows_frame_observer.cpp', 'tools/windows_observer_timer.h', 'platform/viewflow-capture/src/main.cpp', 'platform/viewflow-capture/src/capture_cadence.hpp', 'platform/viewflow-capture/CMakeLists.txt'];Path('/tmp/viewflow-binary-backdrop-trial-source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
 for label,codec,value,disabled in [('4k-binary-disabled-a1','h264','minimal','1'),('4k-binary-enabled-b1','h264','minimal','0'),('4k-binary-enabled-b2','h264','minimal','0'),('4k-binary-disabled-a2','h264','minimal','1')]:
  capture_events='1'
  send=json.loads(send_path.read_text());receive=json.loads(original_receive);send['media']['color_codec']=codec;receive['color_codec']=codec;receive['native_presenter']=root+'\\native-binary-backdrop-build\\Release\\viewflow_windows_composition_preview.exe'
  send_path.write_text(json.dumps(send,indent=2)+'\n');receive_path.write_text(json.dumps(receive,indent=2)+'\n')
  subprocess.run(['scp','-q','-o','BatchMode=yes',str(receive_path),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/isolated-receive.json'],check=True)
  before=json.loads(ps(identity+"$p.PriorityClass='Normal';foreach($x in $t){$x.PriorityLevel='Normal'}; $p.Refresh(); $t=@($p.Threads|Where-Object {$ids.ContainsKey($_.Id)}); "+report))
  assert before['priority']=='Normal' and all(t['priority']=='Normal' and t['base_priority']==8 for t in before['threads']) and before['other_critical']==0
  phase={'label':label,'codec':codec,'diagnostic_mode':value,'capture_events':capture_events,'binary_backdrop_disabled':disabled,'before':before};data['phases'].append(phase);state.write_text(json.dumps(data,indent=2)+'\n');print('BEGIN',label,before,flush=True)
  env=dict(os.environ,VIEWFLOW_TRIAL_BINARY_BACKDROP_DISABLED=disabled,VIEWFLOW_CAPTURE_EVENTS=capture_events,VIEWFLOW_OBSERVE_FRAMES='1',VIEWFLOW_OBSERVE_PHYSICAL4K='1',VIEWFLOW_OBSERVER_EXE='viewflow_windows_frame_observer.exe',VIEWFLOW_OBSERVER_TIMER='1',VIEWFLOW_TRIAL_TRACE_MODE=value,VIEWFLOW_OBSERVER_NATIVE_DIR='native-binary-backdrop-build',VIEWFLOW_ALPHA_COPY_PROFILE=('0' if value=='minimal' else '1'),VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS=('0' if value=='minimal' else 'all'),VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE=('0' if value=='minimal' else '1'));env.pop('VIEWFLOW_QUIC_BURST_PACKETS',None)
  with open('/tmp/'+label+'.log','w') as log:r=subprocess.run(['python3','/tmp/viewflow-binary-full-resolution-trial.py',label],env=env,stdout=log,stderr=subprocess.STDOUT)
  after=json.loads(ps(identity+report));phase.update(after=after,exit=r.returncode);state.write_text(json.dumps(data,indent=2)+'\n');print('END',label,r.returncode,after,flush=True)
  assert r.returncode==0 and after['priority']=='Normal' and after['other_critical']==0 and all(t['priority']=='Normal' and t['base_priority']==8 for t in after['threads'])
  desktop=Path('/tmp/viewflow-integrated-pair/desktop-'+label+'.log').read_text();assert 'exit=0' in desktop and 'desktop-marker ' in desktop
  source=Path('/tmp/viewflow-integrated-pair/source-'+label+'.log').read_text()
  controls=[line for line in source.splitlines() if line.startswith('GPU nvenc-split ')]
  receiver=Path('/tmp/viewflow-integrated-pair/receiver-'+label+'.log').read_text()
  if codec=='av1':
   assert controls and all(('requested='+value+' set_status=0 read_status=0 observed='+('4' if value=='4' else '0')) in x for x in controls)
   assert 'atlas-color-decoder codec=av1 backend=ffmpeg-d3d11va hardware_required=true' in receiver
  else:
   assert not controls and 'atlas-color-decoder codec=av1' not in receiver
  expected='1' if value=='full' else '0'
  assert 'atlas-gpu-queries enabled='+expected in receiver
  if value=='full':assert 'atlas-gpu-copy-completion ' in receiver and 'atlas-gpu-timestamp ' in receiver
  else:assert 'atlas-gpu-copy-completion ' not in receiver and 'atlas-gpu-timestamp ' not in receiver
  if value=='minimal':
   assert 'atlas-socket-anchor ' not in receiver and 'atlas-socket-anchor ' not in source
   assert 'GPU encode timing ' not in source and 'alpha-copy-profile ' not in source
  else:assert 'atlas-socket-anchor ' in receiver and 'atlas-socket-anchor ' in source
  assert ('atlas-capture-wait events_enabled='+('true' if capture_events=='1' else 'false')) in source
  assert 'atlas-capture-readiness fallback=' not in source
  nodes=[line for line in receiver.splitlines() if line.startswith('atlas-sparse-nodes ')];assert nodes and all('binary_alpha=1' in line and 'backdrop_muted='+('0' if disabled=='1' else '1') in line for line in nodes),nodes[:3]
  assert 'atlas-native-mutation ' in receiver and 'GPU fixture-marker ' in source and 'atlas-source-timing ' in source
finally:
 try:
  send_path.write_bytes(original_send);receive_path.write_bytes(original_receive)
  subprocess.run(['scp','-q','-o','BatchMode=yes',str(original_remote),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/isolated-receive.json'],check=True)
  data['configs_restored']=True;state.write_text(json.dumps(data,indent=2)+'\n')
 finally:
  if registered:
   ps(restore)
   data['restored']=json.loads(ps(identity+report));state.write_text(json.dumps(data,indent=2)+'\n')
   assert data['restored']['priority']==initial['priority'] and all(t['priority']=='TimeCritical' for t in data['restored']['threads'])
   ps("Unregister-ScheduledTask -TaskName '"+task+"' -Confirm:$false; if(Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue){throw 'restore task remains'}");data['restore_task_removed']=True;state.write_text(json.dumps(data,indent=2)+'\n')
