from pathlib import Path
import subprocess,json,time,os,re
state=Path('/tmp/viewflow-owned-output-binary-backdrop-state.json');work=Path('/tmp/viewflow-binary-backdrop-output');work.mkdir(exist_ok=True)
data={};output=None;rule_attempted=False;monitor_id=None

def info(*args):return json.loads(subprocess.check_output(['hyprctl','-j',*args]))
def repl(expr):return subprocess.check_output(['hyprctl','repl',expr],text=True).strip()
def lua(name,expr):
 p=work/(name+'.lua');p.write_text(expr+'\n')
 subprocess.run(['/home/wilf/.codex/skills/hyprland-lua/scripts/check-hyprland-lua.sh',str(p)],check=True)
 subprocess.run(['hyprctl','eval',expr],check=True)
try:
 assert repl('return type(_G.viewflow_binary_backdrop_fixture_rule)')=='nil'
 data['old_fixture_rule_enabled']=repl('return _G.viewflow_frame_fixture_rule:is_enabled()');assert data['old_fixture_rule_enabled']=='false'
 data['before_monitors']=info('monitors','all');data['before_focus']=info('activewindow');data['before_plugins']=info('plugin','list')
 data['before_configerrors']=subprocess.check_output(['hyprctl','configerrors'],text=True)
 instances=info('instances');match=[x for x in instances if x['instance']==os.environ['HYPRLAND_INSTANCE_SIGNATURE']];assert len(match)==1
 data['compositor']=match[0];names={x['name'] for x in data['before_monitors']}
 subprocess.run(['hyprctl','output','create','headless'],check=True)
 new=[x for x in info('monitors','all') if x['name'] not in names];assert len(new)==1
 output=new[0]['name'];monitor_id=new[0]['id'];assert re.fullmatch(r'HEADLESS-\d+',output)
 lua('monitor','hl.monitor({output='+json.dumps(output)+',mode="3840x2400@60",position="3072x390",scale="2"})')
 for _ in range(30):
  current=[x for x in info('monitors') if x['name']==output and x['width']==3840 and x['height']==2400 and x['scale']==2]
  if current and current[0]['activeWorkspace']['id']>0:break
  time.sleep(.1)
 else:raise RuntimeError('owned output did not settle')
 m=current[0];monitor_id=m['id'];assert not [x for x in info('clients') if x['monitor']==monitor_id]
 assert info('activewindow').get('address')==data['before_focus'].get('address')
 rule_attempted=True
 lua('fixture-rule','_G.viewflow_binary_backdrop_fixture_rule=hl.window_rule({name="viewflow-binary-backdrop-owned-fixture",match={class="^viewflow-frame-fixture$"},monitor='+json.dumps(output)+',workspace='+json.dumps(str(m['activeWorkspace']['id'])+' silent')+',float=true,size="1920 1200",move="0 0",no_initial_focus=true,no_anim=true,no_shadow=true,no_blur=true,border_size=0,rounding=0})')
 data['owned_output']=m;state.write_text(json.dumps(data,indent=2)+'\n')
 env=dict(os.environ,VIEWFLOW_TRIAL_SCREEN=output,VIEWFLOW_TRIAL_COMPOSITOR_PID=str(match[0]['pid']))
 r=subprocess.run(['python3','/tmp/viewflow-binary-backdrop-trials.py'],env=env);data['trials_exit']=r.returncode;r.check_returncode()
finally:
 if rule_attempted:lua('restore-rule','if _G.viewflow_binary_backdrop_fixture_rule then _G.viewflow_binary_backdrop_fixture_rule:set_enabled(false);_G.viewflow_binary_backdrop_fixture_rule=nil end')
 if output:
  remaining=[x for x in info('clients') if x['monitor']==monitor_id];data['remaining_owned_clients']=remaining
  if not remaining:subprocess.run(['hyprctl','output','remove',output],check=True)
  else:print('retained owned output because clients remain',flush=True)
 data['after_monitors']=info('monitors','all');data['after_focus']=info('activewindow');data['after_plugins']=info('plugin','list')
 data['after_old_fixture_rule_enabled']=repl('return _G.viewflow_frame_fixture_rule:is_enabled()')
 data['after_configerrors']=subprocess.check_output(['hyprctl','configerrors'],text=True)
 state.write_text(json.dumps(data,indent=2)+'\n')
 assert data['after_monitors']==data['before_monitors'] and data['after_focus']==data['before_focus'] and data['after_plugins']==data['before_plugins']
 assert data['after_old_fixture_rule_enabled']==data['old_fixture_rule_enabled'] and data['after_configerrors']==data['before_configerrors']
