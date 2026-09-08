from pathlib import Path
import subprocess,json,time,os,re
state=Path('/tmp/viewflow-owned-output-observer-timer-state.json');data={};output=None

def info(*args):return json.loads(subprocess.check_output(['hyprctl','-j',*args]))
def lua(expr):subprocess.run(['hyprctl','eval',expr],check=True)
try:
 data['before_monitors']=info('monitors','all');data['before_focus']=info('activewindow')
 names={x['name'] for x in data['before_monitors']}
 subprocess.run(['hyprctl','output','create','headless'],check=True)
 new=[x for x in info('monitors','all') if x['name'] not in names]
 if len(new)!=1:raise RuntimeError('cannot identify exactly one owned output')
 output=new[0]['name'];monitorId=new[0]['id'];assert re.fullmatch(r'HEADLESS-\d+',output)
 lua('hl.monitor({output='+json.dumps(output)+',mode="3840x2400@60",position="3072x390",scale="2"})')
 for _ in range(30):
  match=[x for x in info('monitors') if x['name']==output and x['width']==3840 and x['height']==2400 and x['scale']==2]
  if match and match[0]['activeWorkspace']['id']>0:break
  time.sleep(.1)
 else:raise RuntimeError('owned output mode did not settle')
 workspace=match[0]['activeWorkspace']['id'];monitorId=match[0]['id']
 assert not [x for x in info('clients') if x['monitor']==monitorId]
 data['owned_output']=match[0];data['after_create_focus']=info('activewindow')
 if data['after_create_focus'].get('address')!=data['before_focus'].get('address'):raise RuntimeError('focus changed while output was created')
 lua('_G.viewflow_frame_fixture_saved_rule=_G.viewflow_frame_fixture_rule; if _G.viewflow_frame_fixture_rule then _G.viewflow_frame_fixture_rule:set_enabled(false) end; _G.viewflow_frame_fixture_rule=hl.window_rule({name="viewflow-isolated-frame-fixture-owned-output",match={class="^viewflow-frame-fixture$"},monitor='+json.dumps(output)+',workspace='+json.dumps(str(workspace)+' silent')+',float=true,size="1920 1200",move="0 0",no_initial_focus=true,no_anim=true,no_shadow=true,no_blur=true,border_size=0,rounding=0})')
 state.write_text(json.dumps(data,indent=2)+'\n')
 env=os.environ.copy();env['VIEWFLOW_TRIAL_SCREEN']=output
 subprocess.run(['python3','/tmp/viewflow-observer-timer-trials.py'],env=env,check=True)
finally:
 lua('if _G.viewflow_frame_fixture_rule then _G.viewflow_frame_fixture_rule:set_enabled(false) end; if _G.viewflow_frame_fixture_saved_rule then _G.viewflow_frame_fixture_rule=_G.viewflow_frame_fixture_saved_rule; _G.viewflow_frame_fixture_saved_rule=nil end')
 if output:
  remaining=[x for x in info('clients') if x['monitor']==monitorId]
  data['remaining_owned_output_clients']=remaining
  if not remaining:subprocess.run(['hyprctl','output','remove',output],check=True)
  else:print('owned output retained because clients remain',flush=True)
 data['after_monitors']=info('monitors','all');data['after_focus']=info('activewindow');state.write_text(json.dumps(data,indent=2)+'\n')
