"""Bounded full-glass endpoint measurement; no input/focus injection."""
from pathlib import Path
import subprocess,json,time,os,base64,hashlib,traceback,sys
repo=Path('/home/wilf/data/viewflow');work=json.loads(Path('/tmp/viewflow-full-glass-work.json').read_text());local=Path(work['local']);remote=work['remote'];base=work['base'];label=sys.argv[1] if len(sys.argv)>1 else 'full-glass-01'
assert label.replace('-','').isalnum()
out=local/label;out.mkdir()
state={};source=fixture=None;output=None;tasks=[];rule=False
receiver=base+r'\target\release\vf-media-peer.exe';native=base+r'\native-trace-controls-build\Release\viewflow_windows_composition_preview.exe';runner=base+r'\isolated-receiver-runner-trace-minimal.exe';observer=base+r'\native-build\Release\viewflow_windows_frame_observer.exe'
rd=remote+'\\'+label

def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=35)
 if r.returncode:raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
 return r.stdout.decode(errors='replace').strip()
def ctl(*args):return subprocess.check_output(['hyprctl',*args],text=True).strip()
def info(*args):return json.loads(ctl('-j',*args))
def lua(s):
 p=out/'runtime.lua';p.write_text(s+'\n');subprocess.run(['/home/wilf/.codex/skills/hyprland-lua/scripts/check-hyprland-lua.sh',str(p)],check=True,stdout=subprocess.DEVNULL)
 r=ctl('eval',s)
 if r!='ok':raise RuntimeError(r)
def snapshot():
 return json.loads(ps("[pscustomobject]@{user=(Get-CimInstance Win32_ComputerSystem).UserName; processes=@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -like '*perf-isolated-8e97c1b751fc*'} | Select-Object ProcessId,ParentProcessId,ExecutablePath,CommandLine); esrv=@(Get-Process esrv_svc -ErrorAction SilentlyContinue | Select-Object Id,CPU,PriorityClass); port=@(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue).Count}|ConvertTo-Json -Depth 5"))
def task(name,exe,args):
 # Names are private to this measurement; stop only these names in finally.
 ps("if(Get-ScheduledTask -TaskName '"+name+"' -ErrorAction SilentlyContinue){throw 'task already exists'}")
 tasks.append(name)
 ps("$principal=(Get-ScheduledTask -TaskName 'ViewflowMain-Active').Principal;$action=New-ScheduledTaskAction -Execute '"+exe+"' -Argument '"+args+"' -WorkingDirectory '"+rd+"';Register-ScheduledTask -TaskName '"+name+"' -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;Start-ScheduledTask -TaskName '"+name+"'")
try:
 state['before']=snapshot();assert state['before']['user']=='WINDOWSVM\\wilf';assert not state['before']['processes'] and not state['before']['port']
 state['linux_before']={'monitors':info('monitors','all'),'focus':info('activewindow'),'plugins':info('plugin','list'),'configerrors':ctl('configerrors')}
 assert ctl('repl','return type(_G.viewflow_full_glass_fixture_rule)')=='nil'
 expected={native:'DF6EB3FAD88B8DADEC5EC0C0427DE395428E3731D36DF0658AA8C071324A6F2B',receiver:'A39CB1F4BD003EC3EE1237AF05D9915316E86119DC21FBE1C9F626CE61B3C30A',runner:'6E4C207E9F60EF54DBDB3EECCE9C3ED8F208CDFB5FD07F8174204957BBCC8118'}
 hashes=json.loads(ps('@('+','.join("'"+x+"'" for x in [*expected,observer])+')|ForEach-Object{Get-FileHash -Algorithm SHA256 $_}|Select-Object Path,Hash|ConvertTo-Json'))
 state['windows_binaries']=hashes
 for h in hashes:
  if h['Path'] in expected:assert h['Hash']==expected[h['Path']],h
 state['linux_binaries']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [repo/'target/release/vf-media-peer',local/'fixture-build/viewflow_linux_frame_fixture']}
 ps("if(Test-Path '"+rd+"'){throw 'trial dir exists'};New-Item -ItemType Directory -Path '"+rd+"'|Out-Null")
 before=state['linux_before']['monitors'];names={m['name'] for m in before};ctl('output','create','headless');created=[m for m in info('monitors','all') if m['name'] not in names];assert len(created)==1;output=created[0]['name']
 # Position wholly to the right of all existing output rectangles.
 x=max(round(m['x']+m['width']/m['scale']) for m in before)
 lua('hl.monitor({output='+json.dumps(output)+',mode="3840x2400@60",position='+json.dumps(str(x)+'x0')+',scale=2})')
 for _ in range(40):
  m=next(m for m in info('monitors','all') if m['name']==output)
  if (m['width'],m['height'],m['scale'])==(3840,2400,2):break
  time.sleep(.1)
 else:raise RuntimeError('output mode did not settle: '+str(m))
 lua('_G.viewflow_full_glass_fixture_rule=hl.window_rule({name="viewflow-full-glass-fixture-owned",match={class="^viewflow-full-glass-fixture$"},monitor='+json.dumps(output)+',workspace='+json.dumps(str(m['activeWorkspace']['id'])+' silent')+',float=true,size="1920 1200",move="0 0",no_initial_focus=true,no_focus=true,no_anim=true,no_shadow=true,no_blur=true,border_size=0,rounding=0})');rule=True
 env=os.environ.copy();env['QT_QPA_PLATFORM']='wayland'
 state['before_fixture_focus']=info('activewindow')
 with (out/'fixture.log').open('w') as log:fixture=subprocess.Popen([str(local/'fixture-build/viewflow_linux_frame_fixture'),output,'150000'],env=env,stdout=log,stderr=subprocess.STDOUT)
 for _ in range(100):
  if fixture.poll() is not None:raise RuntimeError('fixture exited')
  c=[c for c in info('clients') if c['pid']==fixture.pid and c['class']=='viewflow-full-glass-fixture']
  if len(c)==1:break
  time.sleep(.1)
 else:raise RuntimeError('fixture did not map')
 state['fixture_client']=c[0];state['linux_during']={'monitors':info('monitors','all'),'focus':info('activewindow')};assert c[0]['size']==[1920,1200]
 state['focus_changed_during_setup']=state['linux_during']['focus'].get('address')!=state['linux_before']['focus'].get('address')
 assert state['linux_during']['focus'].get('address')!=c[0]['address'],'fixture unexpectedly accepted focus'
 instances=info('instances');instance=next(i for i in instances if i['instance']==os.environ['HYPRLAND_INSTANCE_SIGNATURE']);pid=instance['pid']
 probe=json.loads(subprocess.check_output([str(repo/'target/release/vf-media-peer'),'probe','--compositor-pid',str(pid),'--window',c[0]['address']]))
 state['probe']=probe;assert probe['width']==3848 and probe['height']==2408
 s=json.loads((local/'send.json').read_text());s['compositor_pid']=pid;s['windows'][0].update(address=c[0]['address'],width=probe['width'],height=probe['height'],geometry_epoch=probe['geometry_epoch']);config=out/'send.json';config.write_text(json.dumps(s,indent=2)+'\n');state['send_config_sha256']=hashlib.sha256(config.read_bytes()).hexdigest()
 subprocess.run([str(repo/'target/release/vf-media-peer'),'validate-send','--config',str(config)],check=True)
 task('ViewflowPerf-FullGlassReceiver',runner,'"'+receiver+'" "'+remote+'\\receive.json" "'+rd+'"')
 for _ in range(20):
  if 'atlas-peer-listening' in ps("if(Test-Path '"+rd+"\\isolated-receiver-stderr.log'){Get-Content '"+rd+"\\isolated-receiver-stderr.log' -Tail 5}"):break
  time.sleep(.25)
 else:raise RuntimeError('receiver not listening')
 env=os.environ.copy()
 env.update({k:'0' for k in ['VIEWFLOW_CLIPBOARD','VIEWFLOW_GPU_TIMINGS','VIEWFLOW_ALPHA_COPY_PROFILE','VIEWFLOW_ALPHA_OUTPUT_COPY','VIEWFLOW_GPU_TILE_COPY','VIEWFLOW_QUIC_POLL','VIEWFLOW_QUIC_SOCKET_TRACE']});env.update(VIEWFLOW_ATLAS_TIMINGS='all',VIEWFLOW_CAPTURE_EVENTS='1',VIEWFLOW_GPU_FIXTURE_MARKER='1');env.pop('VIEWFLOW_QUIC_BURST_PACKETS',None)
 with (out/'source.log').open('w') as log:source=subprocess.Popen(['timeout','--signal=TERM','--kill-after=5s','55s',str(repo/'target/release/vf-media-peer'),'send','--config',str(config)],env=env,stdout=log,stderr=subprocess.STDOUT)
 for _ in range(20):
  if source.poll() is not None:raise RuntimeError('source exited before observer')
  p=ps("$p=@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -eq '"+native+"'});if($p.Count -eq 1){$p[0].ProcessId}")
  if p.isdigit():break
  time.sleep(.2)
 else:raise RuntimeError('native presenter not found')
 state['native_pid']=int(p)
 task('ViewflowPerf-FullGlassObserver',observer,p+' 30000 "'+rd+'\\desktop-marker.log" physical4k timer1')
 print('full-glass source and desktop observer running',flush=True)
 source.wait(timeout=65);state['source_exit']=source.returncode
 state['observer_result']=ps("Get-ScheduledTaskInfo -TaskName 'ViewflowPerf-FullGlassObserver'|Select-Object LastTaskResult|ConvertTo-Json")
 time.sleep(2)
 state['after_stream']=snapshot()
except BaseException:
 state['error']=traceback.format_exc();raise
finally:
 errors=[]
 if source and source.poll() is None:
  source.terminate()
  try:source.wait(timeout=10)
  except subprocess.TimeoutExpired:source.kill();source.wait()
 for name in reversed(tasks):
  try:ps("$t=Get-ScheduledTask -TaskName '"+name+"' -ErrorAction SilentlyContinue;if($t){if($t.State -eq 'Running'){Stop-ScheduledTask -TaskName '"+name+"'};Unregister-ScheduledTask -TaskName '"+name+"' -Confirm:$false}")
  except Exception as e:errors.append(str(e))
 if fixture:
  if fixture.poll() is None:fixture.terminate()
  try:fixture.wait(timeout=5)
  except subprocess.TimeoutExpired:fixture.kill();fixture.wait()
 if rule:
  try:lua('if _G.viewflow_full_glass_fixture_rule then _G.viewflow_full_glass_fixture_rule:set_enabled(false);_G.viewflow_full_glass_fixture_rule=nil end')
  except Exception as e:errors.append(str(e))
 if output:
  try:
   if any(c['monitor']==m['id'] for c in info('clients')):raise RuntimeError('remaining clients on owned output; preserved')
   ctl('output','remove',output)
  except Exception as e:errors.append(str(e))
 try:
  state['after']=snapshot();state['linux_after']={'monitors':info('monitors','all'),'focus':info('activewindow'),'plugins':info('plugin','list'),'configerrors':ctl('configerrors')}
  for name in ['isolated-receiver-stderr.log','isolated-receiver-stdout.log','isolated-runner-status.log','desktop-marker.log']:
   subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+rd.replace('\\','/')+'/'+name,str(out/name)],capture_output=True,timeout=30)
 except Exception as e:errors.append(str(e))
 state['cleanup_errors']=errors;(out/'state.json').write_text(json.dumps(state,indent=2)+'\n');print('trial state',str(out/'state.json'),'cleanup_errors',errors,flush=True)
