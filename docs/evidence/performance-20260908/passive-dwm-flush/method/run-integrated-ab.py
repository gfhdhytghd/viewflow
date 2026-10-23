from pathlib import Path
import subprocess,json,os,time,traceback
root=Path('/tmp/viewflow-passive-dwm-flush');root.mkdir(exist_ok=True);state={};output=None
method=Path(__file__).resolve().parent

def ctl(*a):return subprocess.check_output(['hyprctl',*a],text=True).strip()
def info(*a):return json.loads(ctl('-j',*a))
try:
 state['before_monitors']=info('monitors','all');state['before_focus']=info('activewindow');state['before_plugins']=info('plugin','list')
 names={m['name'] for m in state['before_monitors']};ctl('output','create','headless');new=[m for m in info('monitors','all') if m['name'] not in names];assert len(new)==1;output=new[0]['name'];state['owned_output']=output
 x=max(round(m['x']+m['width']/m['scale']) for m in state['before_monitors'])+32768
 y=max(round(m['y']+m['height']/m['scale']) for m in state['before_monitors'])+32768
 lua='hl.monitor({output='+json.dumps(output)+',mode="3840x2400@60",position='+json.dumps(str(x)+'x'+str(y))+',scale=2})'
 p=root/'output.lua';p.write_text(lua+'\n');subprocess.run(['/home/wilf/.codex/skills/hyprland-lua/scripts/check-hyprland-lua.sh',str(p)],check=True);assert ctl('eval',lua)=='ok'
 for _ in range(50):
  m=next(m for m in info('monitors','all') if m['name']==output)
  if (m['width'],m['height'],m['scale'])==(3840,2400,2):break
  time.sleep(.1)
 else:raise RuntimeError('owned output did not settle')
 state['owned_monitor']=m
 env=dict(os.environ,VIEWFLOW_PASSIVE_OUTPUT=output)
 trials=[('off-a1','0'),('on-b1','1'),('on-b2','1'),('off-a2','0')]
 for label,mode in trials:
  label=os.environ.get('VIEWFLOW_DWM_FLUSH_TRIAL_PREFIX','')+label
  env['VIEWFLOW_DWM_FLUSH_MODE']=mode
  print('TRIAL_START',label,flush=True)
  subprocess.run(['python3',str(method/'run-integrated.py'),label],env=env,check=True,timeout=180)
 state['trials']='completed'
except BaseException:
 state['error']=traceback.format_exc();raise
finally:
 if output:
  m=next((m for m in info('monitors','all') if m['name']==output),None)
  if m:
   remaining=[c for c in info('clients') if c['monitor']==m['id']];state['remaining_before_unplug']=remaining;state['focus_before_unplug']=info('activewindow')
   if any(c['class']=='viewflow-full-glass-fixture' for c in remaining):raise RuntimeError('owned fixture remains; preserve output for cleanup')
   ctl('output','remove',output);time.sleep(.1)
   windows={c['address']:c for c in info('clients')};state['preserved_after_unplug']=[windows.get(c['address']) for c in remaining]
   state['focus_after_unplug']=info('activewindow')
 state['after_monitors']=info('monitors','all');state['after_plugins']=info('plugin','list');state['configerrors']=ctl('configerrors')
 (root/('integrated-control-state-'+os.environ.get('VIEWFLOW_DWM_FLUSH_TRIAL_PREFIX','')+'passive'+'.json')).write_text(json.dumps(state,indent=2)+'\n')
 print('CONTROL_END',state.get('trials'),output,flush=True)
 assert not state['configerrors'] and state['before_plugins']==state['after_plugins']
 assert output not in {m['name'] for m in state['after_monitors']}
