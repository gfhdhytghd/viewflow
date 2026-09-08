import os,json,pathlib,subprocess,time,tempfile,signal,sys,hashlib
root=pathlib.Path(tempfile.mkdtemp(prefix='viewflow-commit-nested.')); runtime=pathlib.Path(tempfile.mkdtemp(prefix='vfc.'))
state={'root':str(root),'runtime':str(runtime)}; output=None; inner=None; pid=None
rootenv=os.environ.copy()
def ctl(*args,env=None):
 p=subprocess.run(['/usr/bin/hyprctl',*args],env=env or rootenv,text=True,capture_output=True,timeout=10)
 if p.returncode:raise RuntimeError((args,p.returncode,p.stdout,p.stderr))
 return p.stdout
def info(*args,env=None):return json.loads(ctl('-j',*args,env=env))
def save():
 (root/'state.json').write_text(json.dumps(state,indent=2)+'\n');pathlib.Path('/tmp/viewflow-commit-nested-latest.json').write_text(json.dumps(state,indent=2)+'\n')
def alive(p):
 try:return pathlib.Path(f'/proc/{p}/stat').read_text().split(') ')[1][0]!='Z'
 except FileNotFoundError:return False
try:
 state['before_monitors']=info('monitors','all');state['before_focus']=info('activewindow');state['before_plugins']=ctl('plugin','list');save()
 config=root/'hyprland.lua'
 config.write_text('''hl.monitor({output="",mode="1280x960@60",position="auto",scale=1})
hl.config({general={gaps_in=0,gaps_out=0,border_size=0}, animations={enabled=false},decoration={rounding=0,shadow={enabled=false},blur={enabled=false}},misc={disable_hyprland_logo=true,disable_splash_rendering=true},xwayland={enabled=false}})
hl.window_rule({name="owned-fixture",match={class="^viewflow-frame-fixture$"},float=true,size="1920 1200",move="0 0",no_initial_focus=true,no_anim=true,border_size=0,rounding=0})
''')
 subprocess.run(['/home/wilf/.codex/skills/hyprland-lua/scripts/check-hyprland-lua.sh',str(config)],check=True)
 names={x['name'] for x in state['before_monitors']};ctl('output','create','headless')
 new=[x for x in info('monitors','all') if x['name'] not in names];assert len(new)==1
 output=new[0]['name'];state['output']=output
 ctl('eval','hl.monitor({output='+json.dumps(output)+',mode="1280x960@60",position="6000x0",scale=1})')
 for _ in range(40):
  m=[x for x in info('monitors') if x['name']==output]
  if m and m[0]['activeWorkspace']['id']>0:break
  time.sleep(.1)
 else:raise RuntimeError('outer output unavailable')
 ws=m[0]['activeWorkspace']['id'];state['outer_monitor']=m[0]
 assert info('activewindow').get('address')==state['before_focus'].get('address')
 innerlaunch=root/'inner.py';innerlaunch.write_text('import os,pathlib\npathlib.Path('+repr(str(root/'pid'))+').write_text(str(os.getpid()))\nos.execv("/usr/bin/Hyprland",["Hyprland","--config",'+repr(str(config))+'])\n')
 launcher=root/'launch.py'
 cmd=['bwrap','--die-with-parent','--bind','/','/','--dev','/dev','--bind','/dev/shm/hyprcapture-1000','/dev/shm/hyprcapture-1000']
 for device in ['/dev/dri/renderD128','/dev/nvidia0','/dev/nvidiactl','/dev/nvidia-uvm']:cmd+=['--dev-bind',device,device]
 for key in ['HYPRLAND_INSTANCE_SIGNATURE','DISPLAY','DBUS_SESSION_BUS_ADDRESS']:cmd+=['--unsetenv',key]
 parentwayland=rootenv['WAYLAND_DISPLAY'];parentwayland=parentwayland if parentwayland.startswith('/') else rootenv['XDG_RUNTIME_DIR']+'/'+parentwayland
 for k,v in {'XDG_RUNTIME_DIR':str(runtime),'WAYLAND_DISPLAY':parentwayland,'HYPRLAND_NO_SD_VARS':'1','HYPRLAND_NO_SD_NOTIFY':'1','LIBSEAT_BACKEND':'seatd','SEATD_SOCK':str(root/'no-seat'),'AQ_DRM_DEVICES':str(root/'no-drm')}.items():cmd+=['--setenv',k,v]
 cmd+=['/usr/bin/python3',str(innerlaunch)]
 launcher.write_text('#!/usr/bin/python3\nimport os\nf=os.open('+repr(str(root/'compositor.log'))+',os.O_CREAT|os.O_WRONLY|os.O_TRUNC,0o600)\nos.dup2(f,1);os.dup2(f,2)\nos.execvp("bwrap",'+repr(cmd)+')\n');launcher.chmod(0o700)
 ctl('eval','hl.exec_cmd('+json.dumps(str(launcher))+', {no_initial_focus=true,monitor='+json.dumps(output)+',workspace='+json.dumps(str(ws)+' silent')+',float=true,size="1280 960",move="0 0",no_anim=true,no_shadow=true,no_blur=true})')
 for _ in range(120):
  if (root/'pid').exists():pid=int((root/'pid').read_text())
  instances=list((runtime/'hypr').glob('*/.socket.sock'))
  if pid and instances:break
  if pid and not alive(pid):raise RuntimeError('nested died: '+(root/'compositor.log').read_text()[-5000:])
  time.sleep(.1)
 else:raise RuntimeError('nested socket timeout')
 assert len(instances)==1
 signature=instances[0].parent.name
 inner=dict(rootenv,XDG_RUNTIME_DIR=str(runtime),HYPRLAND_INSTANCE_SIGNATURE=signature)
 state['pid']=pid;state['signature']=signature
 for _ in range(100):
  try:status=info('instances',env=inner)
  except json.JSONDecodeError:status=[]
  if any(x['instance']==signature for x in status):break
  if not alive(pid):raise RuntimeError('nested process stopped before instance registration')
  time.sleep(.1)
 else:raise RuntimeError('nested instance registration timed out')
 state['instances']=status
 for _ in range(70):
  wins=[x for x in info('clients') if x['pid']==pid]
  if wins:break
  time.sleep(.1)
 assert len(wins)==1 and wins[0]['monitor']==m[0]['id'],wins
 assert info('activewindow').get('address')==state['before_focus'].get('address'),'outer focus changed'
 state['outer_window']=wins[0];state['nested_status']=ctl('status',env=inner);state['configerrors']=ctl('configerrors',env=inner)
 assert state['configerrors'].strip()=='',state['configerrors']
 state['nested_version']=info('version',env=inner)
 socketname=next(x['wl_socket'] for x in status if x['instance']==signature)
 inner['WAYLAND_DISPLAY']=socketname;state['wayland_display']=socketname
 oldnames={x['name'] for x in info('monitors','all',env=inner)};ctl('output','create','headless',env=inner)
 innermon=[x for x in info('monitors','all',env=inner) if x['name'] not in oldnames];assert len(innermon)==1
 screen=innermon[0]['name'];state['screen']=screen
 ctl('eval','hl.monitor({output='+json.dumps(screen)+',mode="3840x2400@60",position="1280x0",scale=2})',env=inner)
 for _ in range(80):
  settled=[x for x in info('monitors',env=inner) if x['name']==screen and x['width']==3840 and x['height']==2400 and x['scale']==2]
  if settled:break
  time.sleep(.1)
 else:raise RuntimeError('inner 4K output did not settle')
 state['inner_monitor']=settled[0]
 ctl('eval','hl.window_rule({name="owned-fixture-screen",match={class="^viewflow-frame-fixture$"},monitor='+json.dumps(screen)+',workspace='+json.dumps(str(settled[0]['activeWorkspace']['id'])+' silent')+',no_initial_focus=true})',env=inner)
 so='/tmp/viewflow-commit-cadence-build/viewflow-capture-commit-test.so'
 state['test_so_sha256']=hashlib.sha256(pathlib.Path(so).read_bytes()).hexdigest()
 state['plugin_load']=ctl('plugin','load',so,env=inner);state['nested_plugins']=ctl('plugin','list',env=inner)
 assert 'function' in ctl('repl','return type(hl.plugin.viewflow_capture_commit_test.window_stream_start_commit)',env=inner)
 save();print('NESTED_READY',root,signature,pid,screen,flush=True)
 inner['VIEWFLOW_COMMIT_STATE']=str(root/'state.json')
 subprocess.run(['/usr/bin/python3','/tmp/viewflow-commit-cohort-smoke.py'],env=inner,check=True)
 state['smoke']='passed';save()
finally:
 if pid and alive(pid):
  try:ctl('dispatch','hl.dsp.exit()',env=inner)
  except Exception as e:state['exit_error']=str(e)
  for _ in range(50):
   if not alive(pid):break
   time.sleep(.1)
  if alive(pid):os.kill(pid,signal.SIGTERM)
  for _ in range(30):
   if not alive(pid):break
   time.sleep(.1)
  state['nested_stopped']=not alive(pid)
 if output:
  remaining=[x for x in info('clients') if x['monitor']==state['outer_monitor']['id']]
  state['remaining_clients']=remaining
  if not remaining:ctl('output','remove',output)
 state['after_monitors']=info('monitors','all');state['after_focus']=info('activewindow');state['after_plugins']=ctl('plugin','list');save()
 print('FINAL_STATE',root/'state.json',flush=True)
 assert state['after_focus'].get('address')==state['before_focus'].get('address')
 assert {x['name'] for x in state['after_monitors']}=={x['name'] for x in state['before_monitors']}
 assert state['before_plugins']==state['after_plugins']
