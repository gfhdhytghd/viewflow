from pathlib import Path
import subprocess,json,os,time,re,traceback
b=Path(__file__).resolve().parent;state={};output=None;fixture=None;rule=False

def ctl(*a):return subprocess.check_output(['hyprctl',*a],text=True).strip()
def info(*a):return json.loads(ctl('-j',*a))
try:
 state['before_monitors']=info('monitors','all');state['before_focus']=info('activewindow');state['before_plugins']=info('plugin','list')
 assert ctl('repl','return type(_G.viewflow_passive_fixture_rule)')=='nil'
 old={m['name'] for m in state['before_monitors']};ctl('output','create','headless');created=[m for m in info('monitors','all') if m['name'] not in old];assert len(created)==1;output=created[0]['name'];state['owned_output']=output
 # A disconnected test output must not introduce a new reachable screen edge.
 x=max(m['x']+round(m['width']/m['scale']) for m in state['before_monitors'])+32768
 y=max(m['y']+round(m['height']/m['scale']) for m in state['before_monitors'])+32768
 lua='hl.monitor({output='+json.dumps(output)+',mode="3840x2400@60",position='+json.dumps(str(x)+'x'+str(y))+',scale=2})'
 p=b/'passive-output.lua';p.write_text(lua+'\n');subprocess.run(['/home/wilf/.codex/skills/hyprland-lua/scripts/check-hyprland-lua.sh',str(p)],check=True);assert ctl('eval',lua)=='ok'
 for _ in range(50):
  m=next(m for m in info('monitors','all') if m['name']==output)
  if (m['x'],m['y'],m['width'],m['height'],m['scale'])==(x,y,3840,2400,2):break
  time.sleep(.1)
 else:raise RuntimeError('isolated output geometry did not settle')
 state['monitor']=m
 lua='_G.viewflow_passive_fixture_rule=hl.window_rule({name="viewflow-passive-owned",match={class="^viewflow-full-glass-fixture$"},monitor='+json.dumps(output)+',workspace='+json.dumps(str(m['activeWorkspace']['id'])+' silent')+',float=true,size="1920 1200",move="0 0",no_initial_focus=true,no_focus=true,no_anim=true,no_shadow=true,no_blur=true,border_size=0,rounding=0})'
 p=b/'passive-rule.lua';p.write_text(lua+'\n');subprocess.run(['/home/wilf/.codex/skills/hyprland-lua/scripts/check-hyprland-lua.sh',str(p)],check=True);assert ctl('eval',lua)=='ok';rule=True
 env=dict(os.environ,QT_QPA_PLATFORM='wayland',VIEWFLOW_FIXTURE_PASSIVE='1',WAYLAND_DEBUG='client')
 with (b/'passive-fixture.log').open('w') as log:
  fixture=subprocess.Popen(['/tmp/viewflow-passive-fixture-build/viewflow_linux_frame_fixture',output,'5000'],env=env,stdout=log,stderr=subprocess.STDOUT)
  for _ in range(50):
   clients=[c for c in info('clients') if c['pid']==fixture.pid]
   if clients:break
   time.sleep(.05)
  assert len(clients)==1;state['client']=clients[0];state['during_focus']=info('activewindow');assert state['during_focus'].get('address')!=clients[0]['address']
  state['exit']=fixture.wait(timeout=15);assert state['exit']==0
 log=(b/'passive-fixture.log').read_text();assert 'fixture-input-policy passive=1' in log
 region_ids=re.findall(r'create_region\(new id wl_region#(\d+)\)',log)
 empty=[]
 for rid in region_ids:
  if re.search(r'set_input_region\(wl_region#'+rid+r'\)',log) and not re.search(r'wl_region#'+rid+r'\.add\(',log):empty.append(rid)
 assert empty, 'Wayland did not receive an empty input region'
 state['empty_input_regions']=empty;state['frames_rendered']=len(re.findall(r'fixture-render frame=',log));assert state['frames_rendered']>100
except BaseException:
 state['error']=traceback.format_exc();raise
finally:
 if fixture and fixture.poll() is None:
  fixture.terminate();fixture.wait(timeout=5)
 if rule:assert ctl('eval','if _G.viewflow_passive_fixture_rule then _G.viewflow_passive_fixture_rule:set_enabled(false);_G.viewflow_passive_fixture_rule=nil end')=='ok'
 if output:
  m=next((m for m in info('monitors','all') if m['name']==output),None)
  if m:
   assert not any(c['monitor']==m['id'] for c in info('clients')),'preserve occupied test output'
   ctl('output','remove',output)
 state['after_monitors']=info('monitors','all');state['after_focus']=info('activewindow');state['after_plugins']=info('plugin','list');state['configerrors']=ctl('configerrors')
 (b/'passive-fixture-state.json').write_text(json.dumps(state,indent=2)+'\n')
print('PASS passive fixture: empty Wayland input region, separated output,',state['frames_rendered'],'dynamic frames, cleanup')
