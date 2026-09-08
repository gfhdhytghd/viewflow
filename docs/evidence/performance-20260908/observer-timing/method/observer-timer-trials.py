from pathlib import Path
import subprocess,base64,json,os,hashlib
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();task='ViewflowPerf-RestoreObserverTimers';state=Path('/tmp/viewflow-observer-timer-state.json')
def ps(code):
 code="$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); "+code
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(code.encode('utf-16le')).decode()],capture_output=True,timeout=40)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode(errors='replace'))
 return r.stdout.decode(errors='replace')
initial=json.loads(ps("$s=Get-CimInstance Win32_Service -Filter \"Name='ESRV_SVC_QUEENCREEK'\"; $p=Get-Process -Id $s.ProcessId; $t=@($p.Threads | Where-Object PriorityLevel -eq 'TimeCritical'); if($p.Path -ne 'C:\\Program Files\\Intel\\SUR\\QUEENCREEK\\x64\\esrv_svc.exe' -or $s.State -ne 'Running' -or $p.PriorityClass -ne 'High' -or $t.Count -lt 1 -or $t.Count -gt 4){throw 'unexpected process/thread baseline'}; if(Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue){throw 'restore task already exists'}; @{id=$p.Id;start_ticks=$p.StartTime.ToUniversalTime().Ticks.ToString();priority=$p.PriorityClass.ToString();path=$p.Path;threads=@($t|ForEach-Object {@{id=$_.Id;start_ticks=$_.StartTime.ToUniversalTime().Ticks.ToString();priority=$_.PriorityLevel.ToString()}});service_state=$s.State;service_start=$s.StartMode} | ConvertTo-Json -Depth 4"))
identities='@{'+ ';'.join(str(t['id'])+"='"+t['start_ticks']+"'" for t in initial['threads'])+'}'
identity="$p=Get-Process -Id "+str(initial['id'])+"; if($p.StartTime.ToUniversalTime().Ticks.ToString() -ne '"+initial['start_ticks']+"'){throw 'process identity changed'}; $ids="+identities+"; $t=@($p.Threads|Where-Object {$ids.ContainsKey($_.Id)}); if($t.Count -ne $ids.Count){throw 'controlled thread disappeared'}; foreach($x in $t){if($x.StartTime.ToUniversalTime().Ticks.ToString() -ne $ids[$x.Id]){throw 'thread identity changed'}}; "
report="@{id=$p.Id;priority=$p.PriorityClass.ToString();threads=@($t | ForEach-Object {@{id=$_.Id;priority=$_.PriorityLevel.ToString();base_priority=$_.BasePriority}});other_critical=@($p.Threads|Where-Object PriorityLevel -eq 'TimeCritical').Count;time=(Get-Date).ToString('o')} | ConvertTo-Json -Depth 4"
restore="$p=Get-Process -Id "+str(initial['id'])+" -ErrorAction SilentlyContinue; if($p -and $p.StartTime.ToUniversalTime().Ticks.ToString() -eq '"+initial['start_ticks']+"'){$ids="+identities+"; foreach($t in $p.Threads){if($ids.ContainsKey($t.Id) -and $t.StartTime.ToUniversalTime().Ticks.ToString() -eq $ids[$t.Id] -and $t.PriorityLevel -eq 'Normal'){$t.PriorityLevel='TimeCritical'}};if($p.PriorityClass -eq 'Normal'){$p.PriorityClass='High'}}"
Path('/tmp/viewflow-restore-observer-timers.ps1').write_text(restore)
data={'initial':initial,'phases':[]};state.write_text(json.dumps(data,indent=2)+'\n');registered=False
try:
 ps("$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -EncodedCommand "+base64.b64encode(restore.encode('utf-16le')).decode()+"'; $t=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10); Register-ScheduledTask -TaskName '"+task+"' -Action $a -Trigger $t -User 'SYSTEM' -RunLevel Highest | Out-Null");registered=True
 paths=['target/release/vf-media-peer','crates/viewflowd/src/atlas_socket_trace.rs','platform/nvenc-encoder/gpu_dmabuf_encoder.cu','platform/windows-video-compositor/video_compositor.cpp','tools/windows_frame_observer.cpp','tools/windows_window_frame_observer.cpp','tools/windows_observer_timer.h'];Path('/tmp/viewflow-observer-timer-trial-source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
 for label,value in [('4k-observer-timer0-a1','0'),('4k-observer-timer1-b1','1'),('4k-observer-timer1-b2','1'),('4k-observer-timer0-a2','0')]:
  before=json.loads(ps(identity+"$p.PriorityClass='Normal';foreach($x in $t){$x.PriorityLevel='Normal'}; $p.Refresh(); $t=@($p.Threads|Where-Object {$ids.ContainsKey($_.Id)}); "+report))
  assert before['priority']=='Normal' and all(t['priority']=='Normal' and t['base_priority']==8 for t in before['threads']) and before['other_critical']==0
  phase={'label':label,'observer_timer':value,'before':before};data['phases'].append(phase);state.write_text(json.dumps(data,indent=2)+'\n');print('BEGIN',label,before,flush=True)
  env=dict(os.environ,VIEWFLOW_OBSERVE_FRAMES='1',VIEWFLOW_OBSERVE_PHYSICAL4K='1',VIEWFLOW_OBSERVER_EXE='viewflow_windows_frame_observer.exe',VIEWFLOW_OBSERVER_TIMER=value,VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE='1');env.pop('VIEWFLOW_QUIC_BURST_PACKETS',None)
  with open('/tmp/'+label+'.log','w') as log:r=subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py',label],env=env,stdout=log,stderr=subprocess.STDOUT)
  after=json.loads(ps(identity+report));phase.update(after=after,exit=r.returncode);state.write_text(json.dumps(data,indent=2)+'\n');print('END',label,r.returncode,after,flush=True)
  assert r.returncode==0 and after['priority']=='Normal' and after['other_critical']==0 and all(t['priority']=='Normal' and t['base_priority']==8 for t in after['threads'])
  desktop=Path('/tmp/viewflow-integrated-pair/desktop-'+label+'.log').read_text();assert 'exit=0' in desktop and 'desktop-marker ' in desktop
finally:
 if registered:
  ps(restore)
  data['restored']=json.loads(ps(identity+report));state.write_text(json.dumps(data,indent=2)+'\n')
  assert data['restored']['priority']==initial['priority'] and all(t['priority']=='TimeCritical' for t in data['restored']['threads'])
  ps("Unregister-ScheduledTask -TaskName '"+task+"' -Confirm:$false; if(Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue){throw 'restore task remains'}");data['restore_task_removed']=True;state.write_text(json.dumps(data,indent=2)+'\n')
