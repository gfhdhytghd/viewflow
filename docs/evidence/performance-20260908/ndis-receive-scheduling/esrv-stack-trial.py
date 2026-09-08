from pathlib import Path
import subprocess,base64,json,os,hashlib
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();task='ViewflowPerf-RestoreEsrvStack';state=Path('/tmp/viewflow-esrv-stack-state.json')
def ps(code):
 code="$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); "+code
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(code.encode('utf-16le')).decode()],capture_output=True,timeout=40)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode(errors='replace'))
 return r.stdout.decode(errors='replace')
initial=json.loads(ps("$p=Get-Process -Id 8108; $t=@($p.Threads | Where-Object Id -eq 10144); $s=Get-CimInstance Win32_Service -Filter \"Name='ESRV_SVC_QUEENCREEK'\"; if($p.Path -ne 'C:\\Program Files\\Intel\\SUR\\QUEENCREEK\\x64\\esrv_svc.exe' -or $s.ProcessId -ne $p.Id -or $p.PriorityClass -ne 'High' -or $t.Count -ne 1 -or $t[0].PriorityLevel -ne 'TimeCritical'){throw 'unexpected original process or thread'}; if(Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue){throw 'restore task already exists'}; @{id=$p.Id;start_ticks=$p.StartTime.ToUniversalTime().Ticks.ToString();priority=$p.PriorityClass.ToString();path=$p.Path;thread_id=$t[0].Id;thread_start_ticks=$t[0].StartTime.ToUniversalTime().Ticks.ToString();thread_priority=$t[0].PriorityLevel.ToString();service_state=$s.State;service_start=$s.StartMode} | ConvertTo-Json"))
data={'initial':initial,'phases':[]};state.write_text(json.dumps(data,indent=2)+'\n')
identity="$p=Get-Process -Id 8108; if($p.StartTime.ToUniversalTime().Ticks.ToString() -ne '"+initial['start_ticks']+"'){throw 'process identity changed'}; $t=@($p.Threads | Where-Object Id -eq 10144); if($t.Count -ne 1 -or $t[0].StartTime.ToUniversalTime().Ticks.ToString() -ne '"+initial['thread_start_ticks']+"'){throw 'thread identity changed'}; "
restore="""$ErrorActionPreference='Stop'
$targetProcess=Get-Process -Id 8108 -ErrorAction SilentlyContinue
if($targetProcess -and $targetProcess.StartTime.ToUniversalTime().Ticks.ToString() -eq 'PTICKS') {
 $targetThread=@($targetProcess.Threads | Where-Object Id -eq 10144)
 if($targetThread.Count -eq 1 -and $targetThread[0].StartTime.ToUniversalTime().Ticks.ToString() -eq 'TTICKS' -and $targetThread[0].PriorityLevel -eq 'Normal') { $targetThread[0].PriorityLevel='TimeCritical' }
 if($targetProcess.PriorityClass -eq 'Normal') { $targetProcess.PriorityClass='High' }
 $targetProcess.Refresh(); $targetThread=@($targetProcess.Threads | Where-Object Id -eq 10144)
 @{id=$targetProcess.Id;priority=$targetProcess.PriorityClass.ToString();start_ticks=$targetProcess.StartTime.ToUniversalTime().Ticks.ToString();thread_priority=$targetThread[0].PriorityLevel.ToString();thread_base_priority=$targetThread[0].BasePriority;time=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -Encoding UTF8 'ROOT\\esrv-stack-restored.json'
}
""".replace('PTICKS',initial['start_ticks']).replace('TTICKS',initial['thread_start_ticks']).replace('ROOT',root)
Path('/tmp/viewflow-restore-esrv-stack.ps1').write_text(restore);registered=False
watchdog=("$p=Get-Process -Id 8108 -ErrorAction SilentlyContinue;if($p -and $p.StartTime.ToUniversalTime().Ticks -eq "+initial['start_ticks']+"){ $t=@($p.Threads|Where-Object Id -eq 10144);if($t.Count -eq 1 -and $t[0].StartTime.ToUniversalTime().Ticks -eq "+initial['thread_start_ticks']+" -and $t[0].PriorityLevel -eq 'Normal'){$t[0].PriorityLevel='TimeCritical'};if($p.PriorityClass -eq 'Normal'){$p.PriorityClass='High'}}")

try:
 ps("$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -EncodedCommand "+base64.b64encode(watchdog.encode('utf-16le')).decode()+"'; $t=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10); Register-ScheduledTask -TaskName '"+task+"' -Action $a -Trigger $t -User 'SYSTEM' -RunLevel Highest | Out-Null; (Get-ScheduledTask -TaskName '"+task+"').State");registered=True
 paths=['target/release/vf-media-peer','crates/viewflowd/src/atlas_socket_trace.rs','platform/nvenc-encoder/gpu_dmabuf_encoder.cu'];Path('/tmp/viewflow-esrv-stack-trial-source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
 for label,priority in [('4k-udp-stack-normal','Normal')]:
  before=json.loads(ps(identity+"$p.PriorityClass='Normal'; $t[0].PriorityLevel='"+priority+"'; $p.Refresh(); $t=@($p.Threads | Where-Object Id -eq 10144); if($p.PriorityClass -ne 'Normal' -or $t[0].PriorityLevel -ne '"+priority+"'){throw 'priority did not apply'}; @{id=$p.Id;priority=$p.PriorityClass.ToString();thread_priority=$t[0].PriorityLevel.ToString();thread_base_priority=$t[0].BasePriority;time=(Get-Date).ToString('o')} | ConvertTo-Json"))
  print('BEGIN',label,before,flush=True);phase={'label':label,'before':before};data['phases'].append(phase);state.write_text(json.dumps(data,indent=2)+'\n')
  env=dict(os.environ,VIEWFLOW_OBSERVE_FRAMES='0',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE='1');env.pop('VIEWFLOW_QUIC_BURST_PACKETS',None)
  with open('/tmp/'+label+'.log','w') as log:r=subprocess.run(['python3','/tmp/viewflow-udp-stack-normal-trial.py'],env=env,stdout=log,stderr=subprocess.STDOUT)
  after=json.loads(ps(identity+"@{id=$p.Id;priority=$p.PriorityClass.ToString();thread_priority=$t[0].PriorityLevel.ToString();thread_base_priority=$t[0].BasePriority;time=(Get-Date).ToString('o')} | ConvertTo-Json"));phase.update(after=after,exit=r.returncode);state.write_text(json.dumps(data,indent=2)+'\n');print('END',label,'exit',r.returncode,after,flush=True)
  assert after['priority']=='Normal' and after['thread_priority']==priority,'priority changed during trial';assert r.returncode==0
finally:
 if registered:
  data['restored']=json.loads(ps(restore+"\nGet-Content '"+root+"\\esrv-stack-restored.json' -Raw"));state.write_text(json.dumps(data,indent=2)+'\n');assert data['restored']['priority']==initial['priority'] and data['restored']['thread_priority']==initial['thread_priority']
  ps("Unregister-ScheduledTask -TaskName '"+task+"' -Confirm:$false; if(Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue){throw 'restore task remains'}");data['restore_task_removed']=True;state.write_text(json.dumps(data,indent=2)+'\n')
