import importlib.util,subprocess,time,json,datetime
from pathlib import Path
s=importlib.util.spec_from_file_location('f','tools/windows-fusion.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);env=m.hyprland_env()
def ctl(args):return subprocess.check_output(['hyprctl']+args,env=env,text=True)
old=json.loads(ctl(['descriptions','-j']));old=next(v['current'] for v in old if v['name']=='debug:vfr')
result={'original':old,'phases':[]}
try:
 for value in (True,False,True):
  started=datetime.datetime.now(datetime.timezone.utc).isoformat()
  print(ctl(['eval',f'hl.config({{ debug = {{ vfr = {str(value).lower()} }} }})']),flush=True)
  print(ctl(['getoption','debug:vfr']),flush=True)
  time.sleep(25)
  result['phases'].append({'value':value,'started':started,'ended':datetime.datetime.now(datetime.timezone.utc).isoformat()})
finally:
 print('restore',ctl(['eval',f'hl.config({{ debug = {{ vfr = {str(old).lower()} }} }})']),flush=True)
 print(ctl(['getoption','debug:vfr']),flush=True)
 Path('docs/evidence/6k60-20261008/vfr-ab.json').write_text(json.dumps(result,indent=2))
