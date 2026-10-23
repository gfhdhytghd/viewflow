from pathlib import Path
import shutil
b=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');p=b/'lifecycle-v3';p.mkdir();(p/'method').mkdir();shutil.copytree(b/'lifecycle-v2/source',p/'source')
f=p/'source/lifecycle_runner.cpp';s=f.read_text();needle='int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){';assert needle in s;s=s.replace(needle,needle+'\n SetEnvironmentVariableW(L"VIEWFLOW_REVERSE_DIAGNOSTICS",L"1");');f.write_text(s)
for name in ['build.py','build.cmd','run.py','analyze.py']:
 s=(b/'lifecycle-v2/method'/name).read_text().replace('lifecycle-v2','lifecycle-v3').replace('LifecycleV2','LifecycleV3')
 if name=='run.py':
  s=s.replace("variants={'integrated':'integrated-candidate'}", "variants={'root':'root-performance'}")
  needle=" deadline=time.monotonic()+45\n";assert needle in s
  s=s.replace(needle,""" import importlib.util
 control_path=Path('/home/wilf/data/viewflow/tools/viewflow-reverse-performance.py')
 spec=importlib.util.spec_from_file_location('control',control_path);control=importlib.util.module_from_spec(spec);spec.loader.exec_module(control)
 config={'ssh_host':'wilf@172.16.105.70','native':remote+r'\\build\\Release\\viewflow_windows_reverse.exe'}
 report['mode_switches']=[];iteration=0
 deadline=time.monotonic()+45
""")
  needle="  if info['state']!='Running':break";assert needle in s
  s=s.replace(needle,"""  if info['state']!='Running':break
  iteration+=1
  requested={1:'latency',3:'frame-rate',5:'latency'}.get(iteration)
  if requested:
   result=control.request(config,requested);assert result['mode']==requested and not result['restarted']
   report['mode_switches'].append({'iteration':iteration,'result':result});save()
""")
 if name=='analyze.py':
  s=s.replace("p=b/'runs/integrated'","p=b/'runs/root'")
  needle="summary={'scope':";at=s.index(needle);s=s[:at]+"""switches=state['mode_switches'];assert [x['result']['mode'] for x in switches]==['latency','frame-rate','latency']
mode_events=rows('source.log','reverse_performance');assert [x['mode'] for x in mode_events]==['frame-rate','latency','frame-rate','latency']
assert [int(x['max_pending']) for x in mode_events]==[4,1,4,1]
"""+s[at:];s=s.replace("'frames':len(frames)","'mode_events':mode_events,'frames':len(frames)")
 (p/'method'/name).write_text(s)
shutil.copy2(__file__,p/'method/prepare.py')
