"""Passive fixture output on the existing compositor, with no global input subscription."""
from pathlib import Path
import subprocess,json,os,time,tempfile,sys
root=Path(tempfile.mkdtemp(prefix='viewflow-root-headless-'));state={'root':str(root),'presentation_topology':'root-headless'};output=None;rule=None
rule_name='viewflow-owned-perf-root-output';global_name='viewflow_owned_perf_root_output'
def ctl(*args):
 r=subprocess.run(['/usr/bin/hyprctl',*args],capture_output=True,text=True,timeout=10)
 if r.returncode:raise RuntimeError((args,r.returncode,r.stdout,r.stderr))
 return r.stdout
def info(*args):return json.loads(ctl('-j',*args))
def save():(root/'state.json').write_text(json.dumps(state,indent=2)+'\n')
try:
 state['before_monitors']=info('monitors','all');state['before_focus']=info('activewindow');state['before_plugins']=ctl('plugin','list');state['version']=info('version');state['status']=json.loads(ctl('status','-j'));state['configerrors_before']=ctl('configerrors');state['before_clients']=info('clients');save()
 assert state['status']['configProvider']=='lua' and not any(c['class'].startswith('ViewflowPerfReverse-') for c in state['before_clients'])
 assert ctl('repl','return type('+global_name+')').strip()=='nil'
 names={x['name'] for x in state['before_monitors']};ctl('output','create','headless')
 new=[m for m in info('monitors','all') if m['name'] not in names];assert len(new)==1;output=new[0]['name'];state['screen']=output
 ox=max(round(m['x']+m['width']/m['scale']) for m in state['before_monitors'])+32768;oy=max(round(m['y']+m['height']/m['scale']) for m in state['before_monitors'])+32768
 ctl('eval','hl.monitor({output='+json.dumps(output)+',mode="6144x3456@60",position='+json.dumps(str(ox)+'x'+str(oy))+',scale=2})')
 for _ in range(50):
  selected=[m for m in info('monitors') if m['name']==output and m['width']==6144 and m['height']==3456 and m['scale']==2 and m['activeWorkspace']['id']>0]
  if selected:break
  time.sleep(.1)
 else:raise RuntimeError('private output did not settle')
 monitor=selected[0];state['output_origin']=[monitor['x'],monitor['y']];state['monitor']=monitor;ws=monitor['activeWorkspace']['id']
 lua=global_name+'=hl.window_rule({enabled=true,name='+json.dumps(rule_name)+',match={class="^ViewflowPerfReverse-.*$"},monitor='+json.dumps(output)+',workspace='+json.dumps(str(ws)+' silent')+',float=true,no_initial_focus=true,no_focus=true,decorate=false,border_size=0,no_shadow=true,rounding=0,no_blur=true,no_anim=true})'
 (root/'rule.lua').write_text(lua+'\n');subprocess.run(['/home/wilf/.codex/skills/hyprland-lua/scripts/check-hyprland-lua.sh',str(root/'rule.lua')],check=True)
 ctl('eval',lua);rule=True;state['rule_enabled']=ctl('repl','return '+global_name+':is_enabled()').strip();assert state['rule_enabled']=='true';state['configerrors_during']=ctl('configerrors');assert state['configerrors_during']==state['configerrors_before'];save()
 env=os.environ.copy();env['VIEWFLOW_REVERSE_NESTED_STATE']=str(root/'state.json');print('ROOT_HEADLESS_READY',root,output,state['output_origin'],flush=True)
 subprocess.run(['/usr/bin/python3',str(Path(__file__).parent/'run-real-output.py'),sys.argv[1],sys.argv[2],sys.argv[3]],env=env,check=True,timeout=100)
 state['transport_trial']='passed';save()
finally:
 if rule:
  ctl('eval',global_name+':set_enabled(false)');state['rule_disabled']=ctl('repl','return '+global_name+':is_enabled()').strip()=='false';ctl('eval',global_name+'=nil')
 if output:
  monitor=next((m for m in info('monitors','all') if m['name']==output),None);remaining=[c for c in info('clients') if monitor and c['monitor']==monitor['id']];state['remaining_clients']=remaining
  if not any(c['class'].startswith('ViewflowPerfReverse-') for c in remaining):
   ctl('output','remove',output);clients={c['address']:c for c in info('clients')};state['preserved_after_unplug']=[clients.get(c['address']) for c in remaining];assert all(state['preserved_after_unplug'])
 state['after_monitors']=info('monitors','all');state['after_focus']=info('activewindow');state['after_plugins']=ctl('plugin','list');state['configerrors_after']=ctl('configerrors');save()
 if 'before_monitors' in state:
  fields=['name','width','height','x','y','scale','transform','disabled'];normalize=lambda ms:sorted([{k:m.get(k) for k in fields} for m in ms],key=lambda m:m['name']);assert normalize(state['before_monitors'])==normalize(state['after_monitors']);assert state['before_plugins']==state['after_plugins'];assert state['configerrors_before']==state['configerrors_after']
 print('ROOT_HEADLESS_FINAL_STATE',root/'state.json',flush=True)
