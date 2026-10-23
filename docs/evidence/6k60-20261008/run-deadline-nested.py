"""Isolated lifecycle test; creates no surface on the user's compositor."""
import os,subprocess,tempfile,time,json
from pathlib import Path
root=Path(__file__).resolve().parent
repo=root.parents[2]
run=Path(tempfile.mkdtemp(prefix='vfd-',dir='/tmp'));run.chmod(0o700)
config=run/'hyprland.lua';config.write_text('hl.config({debug={vfr=false},animations={enabled=false}})\nhl.monitor({output="WAYLAND-1",mode="1280x720@60",position="0x0",scale=1})\n')
env=os.environ.copy()
for key in ('HYPRLAND_INSTANCE_SIGNATURE','WAYLAND_DISPLAY','DISPLAY','XDG_SESSION_ID','NOTIFY_SOCKET'):env.pop(key,None)
env.update(XDG_RUNTIME_DIR=str(run),LIBSEAT_BACKEND='seatd',SEATD_SOCK=str(run/'no-seatd.sock'),HYPRLAND_NO_SD_VARS='1',HYPRLAND_NO_SD_NOTIFY='1',XDG_SESSION_TYPE='wayland')
children=[];files=[]
def launch(args,name,custom):
 f=(root/name).open('wb');files.append(f);p=subprocess.Popen(args,env=custom,stdout=f,stderr=subprocess.STDOUT);children.append(p);return p
try:
 weston=launch(['weston','--backend=headless','--renderer=gl','--no-config','--socket=parent','--idle-time=0'],'deadline-nested-weston.log',env)
 for _ in range(100):
  if (run/'parent').exists():break
  if weston.poll() is not None:raise RuntimeError('private Weston exited')
  time.sleep(.1)
 else:raise RuntimeError('private Weston socket timeout')
 env['WAYLAND_DISPLAY']='parent'
 env['LD_LIBRARY_PATH']=str(repo/'build/aquamarine-nested')
 hypr=launch(['Hyprland','--config',str(config)],'deadline-nested-hyprland.log',env)
 sockets=[]
 for _ in range(150):
  sockets=list((run/'hypr').glob('*/.socket.sock'))
  if sockets:break
  if hypr.poll() is not None:raise RuntimeError('private Hyprland exited')
  time.sleep(.1)
 else:raise RuntimeError('private Hyprland IPC timeout')
 env['HYPRLAND_INSTANCE_SIGNATURE']=sockets[0].parent.name
 def ctl(*args):return subprocess.check_output(['hyprctl',*args],env=env,text=True,timeout=10)
 time.sleep(2)
 monitors=json.loads(ctl('-j','monitors'));(root/'deadline-nested-monitors.json').write_text(json.dumps(monitors,indent=2))
 if not monitors:raise RuntimeError('private compositor has no output')
 plugin=str(repo/'build/hyprland-deadline-experiment/viewflow-deadline-experiment.so')
 results={'load':ctl('plugin','load',plugin),'before':ctl('repl','return hl.plugin.viewflow_deadline.status()')}
 name=monitors[0]['name'];results['enable']=ctl('eval','hl.plugin.viewflow_deadline.set('+json.dumps(name)+',true,3)')
 displays=[x.name for x in run.glob('wayland-*') if x.is_socket()]
 if not displays:raise RuntimeError('private Wayland socket missing')
 launch(['weston-simple-egl'],'deadline-nested-client.log',env|{'WAYLAND_DISPLAY':displays[0]})
 time.sleep(3)
 results['enabled']=ctl('repl','return hl.plugin.viewflow_deadline.status()')
 results['disable']=ctl('eval','hl.plugin.viewflow_deadline.set('+json.dumps(name)+',false,3)')
 results['disabled']=ctl('repl','return hl.plugin.viewflow_deadline.status()')
 observed=json.loads(results['enabled'])
 if observed['fired']==0 or observed['coalesced']==0:raise RuntimeError('deadline render/coalescing not exercised')
 ctl('eval','hl.plugin.viewflow_deadline.set('+json.dumps(name)+',true,3)')
 for _ in range(100):
  pending=json.loads(ctl('repl','return hl.plugin.viewflow_deadline.status()'))
  if pending['pending']:break
  time.sleep(.002)
 else:raise RuntimeError('pending-unload opportunity not observed')
 results['before_pending_unload']=pending
 results['unload']=ctl('plugin','unload',plugin)
 results['errors']=ctl('configerrors');results['alive_after_unload']=hypr.poll() is None
 (root/'deadline-nested-result.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
finally:
 for log in (run/"hypr").glob("*/hyprland.log"):
  (root/"deadline-nested-runtime.log").write_bytes(log.read_bytes())
 for p in reversed(children):
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)
 for f in files:f.close()
