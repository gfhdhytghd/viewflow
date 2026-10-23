from pathlib import Path
import time,json,os
root=13805;seen={};visits=0;deadline=time.monotonic()+23
start=time.monotonic_ns();ticks=os.sysconf('SC_CLK_TCK')
while time.monotonic()<deadline:
 todo=[root];visited=set();stamp=time.monotonic_ns()
 while todo:
  pid=todo.pop()
  if pid in visited:continue
  visited.add(pid)
  p=Path('/proc')/str(pid)
  try:
   if pid!=root:
    comm=(p/'comm').read_text().strip();stat=(p/'stat').read_text().rsplit(')',1)[1].split();key=f'{pid}:{stat[19]}'
    known_status=b'/quickshell/scripts/control-panel-status.sh' in (p/'cmdline').read_bytes()
    if key not in seen:seen[key]={'known_status_helper':known_status,'pid':pid,'comm':comm,'start_ticks':int(stat[19]),'first_seen_ns':stamp,'parent':int(stat[1])}
    seen[key]['last_seen_ns']=stamp
   for task in (p/'task').iterdir():
    todo.extend(int(c) for c in (task/'children').read_text().split())
  except OSError:pass
 visits+=1;time.sleep(.02)
state={'root_pid':root,'clock_ticks':ticks,'start_ns':start,'end_ns':time.monotonic_ns(),'visits':visits,'processes':[s for s in seen.values() if s['comm']=='ddcutil' or s['known_status_helper']]}
Path('docs/evidence/performance-20260908/periodic-ddc-stall/method/applied-processes.json').write_text(json.dumps(state,indent=2)+'\n')
print(json.dumps([s for s in seen.values() if s['comm']=='ddcutil'],indent=2))
