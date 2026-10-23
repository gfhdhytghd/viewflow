#!/usr/bin/env python3
"""Explicitly invoked owned-fixture benchmark runner. No input, VM or bank reconfiguration."""
import argparse,base64,hashlib,importlib.util,json,os,re,subprocess,time
from pathlib import Path
import dma_gpu_guard
import dma_dd_gate


def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True);p.add_argument('--in-flight',type=int,choices=[1,2],default=1);p.add_argument('--native',default='');p.add_argument('--gpu-timing',action='store_true');p.add_argument('--linux-native',type=Path);p.add_argument('--async-alpha',action='store_true');p.add_argument('--high-priority',action='store_true');p.add_argument('--source-pool',action='store_true');p.add_argument('--fullscreen-output',default='');p.add_argument('--seconds',type=int,choices=range(1,61),default=20);a=p.parse_args()
 if a.fullscreen_output and not re.fullmatch(r'\\\\\.\\DISPLAY[1-9][0-9]*',a.fullscreen_output):p.error('--fullscreen-output requires exact GDI name, e.g. \\\\.\\DISPLAY6')
 if a.fullscreen_output and (not a.native or not a.linux_native):p.error('DD fixture requires explicit Windows and Linux candidate binaries')
 if a.native and not re.fullmatch(r'[A-Za-z]:\\[A-Za-z0-9_.\\-]+',a.native):p.error('--native requires an absolute Windows path without whitespace/quotes')
 repo=Path(__file__).resolve().parents[1];out=Path(a.output);out.mkdir(parents=True,exist_ok=False)
 (out/'parameters.json').write_text(json.dumps({'fullscreen_output':a.fullscreen_output,'validation_scope':'owned producer DD route; no Hyprland fullscreen interaction' if a.fullscreen_output else 'WGC fixture','in_flight':a.in_flight,'seconds':a.seconds,'source_pool':a.source_pool,'native_override':a.native,'gpu_timing':a.gpu_timing,'high_priority':a.high_priority,'async_alpha':a.async_alpha,'linux_native':str(a.linux_native) if a.linux_native else None}))
 tag='Viewflow-DMA-6K-'+str(time.time_ns());remote_dir='C:\\Users\\wilf\\Viewflow\\'+tag
 ssh=['ssh','-o','BatchMode=yes','-o','LogLevel=ERROR','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
 def remote(s):
  code=base64.b64encode(('$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";'+s).encode('utf-16le')).decode()
  return subprocess.check_output(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',code],timeout=60).decode('utf-8-sig').strip()
 def ctl(*args):return subprocess.run(['systemctl','--user',*args],check=True,capture_output=True,text=True).stdout
 spec=importlib.util.spec_from_file_location('fusion',repo/'tools/windows-fusion.py');f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f);env=f.hyprland_env()
 def state(phase):
  for key in ['activewindow','clients','monitors']:
   (out/f'{phase}-{key}.json').write_bytes(subprocess.check_output(['hyprctl','-j',key],env=env,timeout=10))
 def clock(phase):
  (out/f'clock-{phase}.json').write_bytes(subprocess.check_output(['python3',str(repo/'docs/evidence/6k60-20261008/measure-clock.py')],timeout=30))
 service='viewflow-ivshmem-windows.service'
 was_active=subprocess.run(['systemctl','--user','is-active','--quiet',service]).returncode==0
 override=Path(os.environ.get('XDG_RUNTIME_DIR',f'/run/user/{os.getuid()}'))/f'systemd/user/{service}.d/{tag}.conf'
 installed=False;registered=False;started=False;start=time.time();aborted=None;last_gpu_sample=0.0
 def guard():
  nonlocal aborted,last_gpu_sample
  if aborted:return False
  if time.monotonic()-last_gpu_sample<1:return True
  last_gpu_sample=time.monotonic();observation=dma_gpu_guard.sample();dma_gpu_guard.write_state(out/'gpu-state.json',observation)
  with (out/'gpu-samples.jsonl').open('a') as log:log.write(json.dumps(observation)+'\n')
  if observation['status']!='available':
   aborted=observation
   (out/'aborted.json').write_text(json.dumps({'status':'aborted','reason':'GPU occupancy guard','observation':observation}))
   if started:remote(f"[IO.File]::WriteAllText('{remote_dir}\\stop.request','GPU occupancy guard')")
   return False
  return True
 if not guard():return
 try:
  state('before');(out/'service-before.txt').write_text(ctl('show',service,'-p','Environment','-p','ExecStart','-p','ActiveState'))
  remote(f"New-Item -ItemType Directory '{remote_dir}' -ErrorAction Stop | Out-Null")
  destination=remote_dir.replace('\\','/')+'/run.ps1'
  subprocess.run(['scp','-o','BatchMode=yes','-o','LogLevel=ERROR','-o','HostKeyAlias=viewflow-windows',str(repo/'tools/dma-6k60-guest.ps1'),'wilf@172.16.105.24:'+destination],check=True,timeout=30)
  override.parent.mkdir(parents=True,exist_ok=True)
  settings='[Service]\nEnvironment=VIEWFLOW_HOST_FRAME_TRACE=1\nEnvironment=VIEWFLOW_PRESENTATION_TRACE=1\nUnsetEnvironment=VIEWFLOW_FIXTURE_PIXEL_STAMP\n'
  settings+=f'Environment=VIEWFLOW_GPU_ALPHA_ASYNC={int(a.async_alpha)}\n'
  if a.fullscreen_output:settings+='Environment=VIEWFLOW_FULLSCREEN_DMA=0\n' # Fixture-only Windows hook owns route; no compositor mutation.
  if a.linux_native:
   native=a.linux_native.resolve(strict=True)
   if not os.access(native,os.X_OK):raise ValueError('Linux candidate is not executable')
   candidate=out.resolve()/'linux-peer.json';config=json.loads((Path.home()/'.config/viewflow/ivshmem/windows.json').read_text());config['backend']['native']=str(native);candidate.write_text(json.dumps(config,indent=2))
   # Test-only ExecStart; normal unit and peer config are never rewritten.
   for path in [candidate,native]:
    if not re.fullmatch(r'[/A-Za-z0-9_.-]+',str(path)):raise ValueError('Test path must not need systemd escaping')
   settings+=f'ExecStart=\nExecStart=/usr/bin/python3 %h/.local/lib/viewflow/ivshmem/session.py --config {candidate} --peer %h/.local/lib/viewflow/ivshmem/vf-window-peer\n'
   (out/'linux-native.json').write_text(json.dumps({'path':str(native),'sha256':hashlib.sha256(native.read_bytes()).hexdigest()}))
  with override.open('x') as h:h.write(settings)
  installed=True;ctl('daemon-reload');ctl('restart',service)
  # Receiver is established before starting the timed generator. No warm-up deletion.
  time.sleep(2)
  if subprocess.run(['systemctl','--user','is-active','--quiet',service]).returncode:raise RuntimeError('Receiver failed to start')
  clock('start')
  remote(f"$a=New-ScheduledTaskAction -Execute 'C:\\Users\\wilf\\Viewflow\\fusion-20261007\\build-final\\Release\\viewflow_fusion_launcher.exe' -Argument '-File {remote_dir}\\run.ps1 -RunDirectory {remote_dir} -InFlight {a.in_flight} -Seconds {a.seconds}{' -GpuTiming' if a.gpu_timing else ''}{' -HighPriority' if a.high_priority else ''}{' -SourcePool' if a.source_pool else ''}{(' -Native '+a.native) if a.native else ''}{(' -FullscreenOutput '+a.fullscreen_output) if a.fullscreen_output else ''}';$p=New-ScheduledTaskPrincipal -UserId 'wilf' -LogonType Interactive -RunLevel Highest;Register-ScheduledTask -TaskName '{tag}' -Action $a -Principal $p | Out-Null")
  registered=True;remote(f"Start-ScheduledTask -TaskName '{tag}'");started=True
  deadline=time.monotonic()+45
  while True:
   if not guard():raise RuntimeError('GPU guard aborted test')
   ready=remote(f"if(Test-Path '{remote_dir}\\peer-ready.json'){{Get-Content '{remote_dir}\\peer-ready.json' -Raw}}")
   if ready:
    (out/'peer-ready.json').write_text(ready);break
   if remote(f"[string](Get-ScheduledTask -TaskName '{tag}').State")!='Running':raise RuntimeError('Guest ended before peer-ready; inspect error.log')
   if time.monotonic()>deadline:raise TimeoutError('Peer startup operation watchdog')
   time.sleep(.25)
  # Break the old QUIC connection only after the new peer is listening.
  ctl('restart',service)
  deadline=time.monotonic()+40
  while True:
   if not guard():raise RuntimeError('GPU guard aborted test')
   source=remote(f"if(Test-Path '{remote_dir}\\source.log'){{Get-Content '{remote_dir}\\source.log' -Tail 200}}")
   if (dma_dd_gate.ready(source) if a.fullscreen_output else re.search(r'profile_(?:capture(?:_entry)?|shared_capture) .*width=6144 height=3456',source)):
    (out/'gate-source-ready.log').write_text(source);break
   if remote(f"[string](Get-ScheduledTask -TaskName '{tag}').State")!='Running':raise RuntimeError('Guest ended before initial 6K capture; inspect logs')
   if time.monotonic()>deadline:raise TimeoutError('Initial 6K source capture unavailable; gate remains closed')
   time.sleep(.25)
  state('gate-ready');clock('start')
  remote(f"[IO.File]::WriteAllText('{remote_dir}\\start.gate','start')")
  (out/'gate-open.json').write_text(json.dumps({'host_monotonic_ns':time.monotonic_ns(),'condition':'completed DD shared-source D12 frame 6144x3456; physical fullscreen presentation not inferred' if a.fullscreen_output else 'guest source confirms 6144x3456 capture; physical presentation not inferred'}))
  state('during')
  while remote(f"[string](Get-ScheduledTask -TaskName '{tag}').State")=='Running':
   guard();time.sleep(1)
  clock('end');state('after-test')
  result=int(remote(f"(Get-ScheduledTaskInfo -TaskName '{tag}').LastTaskResult"))
  (out/'task-result.json').write_text(json.dumps({'exit':result,'status':'aborted' if aborted else 'completed','requested_seconds':a.seconds,'motion_loop_includes_source_startup':False,'timing_origin':'fixture start gate after initial 6K capture','generation_to_present':'unavailable; no pixel stamp','actual_6k_presentation':'requires geometry evidence'}))
  if aborted:raise RuntimeError('GPU occupancy guard aborted benchmark')
  if result:raise RuntimeError(f'Guest task failed: {result}')
 finally:
  try:
   # Let guest finally restore normal task before removing the task registration.
   if started:
    remote(f"[IO.File]::WriteAllText('{remote_dir}\\stop.request','host finalization')")
    while remote(f"[string](Get-ScheduledTask -TaskName '{tag}').State")=='Running':time.sleep(1)
   if registered:
    # Recovery runs outside the exited GUI job and verifies original process identities.
    recovery=(repo/'tools/dma-6k60-recover.ps1').read_text().replace('param([string]$RunDirectory)', "$RunDirectory='"+remote_dir+"'")
    recovery_result=remote(recovery)
    (out/'host-recovery.json').write_text(recovery_result)
    for name in ['parameters.json','aborted.json','cleanup-error.json','peer-ready.json','error.log','fixture.log','source.log','before.json','restore.json','owned-native.json','drain-blocked.json','normal-stop.json','normal-stop-blocked.json']:
     data=remote(f"if(Test-Path '{remote_dir}\\{name}'){{[Convert]::ToBase64String([IO.File]::ReadAllBytes('{remote_dir}\\{name}'))}}")
     if data:(out/('guest-'+name if name in ('aborted.json','parameters.json') else name)).write_bytes(base64.b64decode(data))
    remote(f"Unregister-ScheduledTask -TaskName '{tag}' -Confirm:$false")
  except Exception as cleanup_error:
   (out/'cleanup-unconfirmed.json').write_text(json.dumps({'status':'unconfirmed','reason':str(cleanup_error),'owned_task':tag,'normal_restoration_not_assumed':True}))
   raise
  finally:
   if installed:
    override.unlink();ctl('daemon-reload');ctl('restart' if was_active else 'stop',service)
  state('restored')
  (out/'host.log').write_bytes(subprocess.check_output(['journalctl','--user','-u',service,'--since','@'+str(int(start)),'--no-pager','-o','short-precise']))
 # Join capture→atlas→presentation timestamps; never read framebuffer pixels.
 host=(out/'host.log').read_text(errors='replace');guest=(out/'source.log').read_text(errors='replace')
 mapping={int(pts):int(capture) for pts,capture in re.findall(r'profile_shared_capture pts=(\d+).*? capture=(\d+)',guest)}
 cal=json.loads((out/'clock-start.json').read_text());offset=cal['offset_mid_ns'];samples=[]
 for pts,ns,cid in re.findall(r'ivshmem-clock-sample .*?atlas_submit_qpc_100ns=(\d+) presented_monotonic_ns=(\d+) clock_id=(\d+)',host):
  if int(cid)==1 and int(pts) in mapping:samples.append((int(ns)-(mapping[int(pts)]*100+offset))/1e6)
 samples.sort()
 (out/'latency.json').write_text(json.dumps({'scope':('ALL-SESSION sampled DXGI last-present to Wayland feedback INCLUDING STATIC GATE' if a.fullscreen_output else 'ALL-SESSION sampled WGC capture to Wayland feedback INCLUDING STATIC GATE')+'; not motion-only, generation, or photon','samples':len(samples),'p50_ms':samples[len(samples)//2] if samples else None,'p95_ms':samples[min(len(samples)-1,int(len(samples)*.95))] if samples else None,'clock_uncertainty_ms':cal['uncertainty_ms'],'raw_samples_ms':samples},indent=2))

 subprocess.run(['python3',str(repo/'tools/analyze-dma-6k60.py'),'--run',str(out)],check=True)

if __name__=='__main__':main()
