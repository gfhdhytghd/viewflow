"""Keep only the benchmark proxy pinned, without input/focus operations."""
import importlib.util,subprocess,json,time,os
from pathlib import Path
root=Path(__file__).resolve().parent;tag=os.environ.get('MOTION_TAG','physical-visible-baseline1')
if not all(c.isalnum() or c=='-' for c in tag):raise ValueError('invalid tag')
if list(root.glob(tag+'-*')):raise RuntimeError('evidence already exists')
s=importlib.util.spec_from_file_location('fusion',root.parents[2]/'tools/windows-fusion.py');f=importlib.util.module_from_spec(s);s.loader.exec_module(f);env=f.hyprland_env()
def ctl(*a):return subprocess.check_output(['hyprctl',*a],env=env,text=True,timeout=10)
def fixtures():return [c for c in json.loads(ctl('-j','clients')) if c.get('mapped') and c.get('title')=='Viewflow 6K performance fixture' and c.get('class','').startswith('ViewflowReverse-WindowsNative-')]
if fixtures():raise RuntimeError('preexisting fixture; inspect first')
events=[];changed={};errors=[]
p=subprocess.Popen(['python3',str(root/'run-physical-motion.py')],env=os.environ|{'MOTION_TAG':tag})
try:
 while p.poll() is None:
  try:
   for c in fixtures():
    address=c['address'];key=(address,c['pid'])
    events.append({'monotonic_ns':time.monotonic_ns(),'address':address,'pid':c['pid'],'pinned':c['pinned'],'workspace':c['workspace'],'monitor':c['monitor'],'size':c['size']})
    if not c['pinned']:
     changed[key]=True
     reply=ctl('dispatch','hl.dsp.window.pin({action="set",window='+json.dumps('address:'+address)+'})')
     if reply.strip()!='ok':raise RuntimeError(reply)
   time.sleep(.25)
  except Exception as e:
   errors.append(str(e));time.sleep(.5)
 if p.returncode:raise RuntimeError(f'benchmark exit {p.returncode}')
finally:
 for c in fixtures():
  if (c['address'],c['pid']) in changed and c['pinned']:
   ctl('dispatch','hl.dsp.window.pin({action="unset",window='+json.dumps('address:'+c['address'])+'})')
 (root/f'{tag}-pin-observations.json').write_text(json.dumps({'observations':events,'errors':errors},indent=2))
print('pinned observations',sum(e['pinned'] for e in events),'of',len(events),'errors',errors)
