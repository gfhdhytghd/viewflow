"""Root-only bounded CPU-set comparison; no VM reboot or desktop input."""
import json,os,pwd,subprocess,sys,time
from pathlib import Path
root=Path(__file__).resolve().parent;repo=root.parents[2]
if os.geteuid()!=0:raise RuntimeError('requires root for runtime service CPU set')
account=pwd.getpwnam('wilf');service='windows-autoshop.service'
def property(name):return subprocess.check_output(['systemctl','show',service,'-p',name,'--value'],text=True).strip()
original=property('AllowedCPUs');pid=int(property('MainPID'))
if original!='4-13':raise RuntimeError('unexpected current CPU allocation; inspect first')
mode=sys.argv[1] if len(sys.argv)>1 else 'baseline'
if mode not in ('baseline','pcores'):raise ValueError('unknown experiment')
tag='physical-deadline-3p0-cpuset-'+mode
def snapshot():
    rows=[]
    for task in (Path('/proc')/str(pid)/'task').iterdir():
        try:
            name=(task/'comm').read_text().strip()
            if not name.startswith('CPU '):continue
            runtime,wait,slices=map(int,(task/'schedstat').read_text().split())
            rows.append(dict(tid=int(task.name),name=name,affinity=sorted(os.sched_getaffinity(int(task.name))),runtime_ns=runtime,wait_ns=wait,slices=slices))
        except FileNotFoundError:continue
    return dict(monotonic_ns=time.monotonic_ns(),pid=pid,allowed=property('AllowedCPUs'),threads=rows)
def save(name,data):
    path=root/f'{tag}-{name}.json';path.write_text(json.dumps(data,indent=2));os.chown(path,account.pw_uid,account.pw_gid)
save('before',snapshot())
try:
    if mode=='pcores':subprocess.run(['systemctl','set-property','--runtime',service,'AllowedCPUs=0-7'],check=True)
    save('during-start',snapshot())
    subprocess.run(['runuser','-u','wilf','--','env',f'DEADLINE_RUN_SUFFIX=cpuset-{mode}','python',str(root/'run-capture-event-paced.py')],cwd=repo,check=True)
    save('during-end',snapshot())
finally:
    if mode=='pcores':subprocess.run(['systemctl','set-property','--runtime',service,'AllowedCPUs='+original],check=True)
    if int(property('MainPID'))!=pid:raise RuntimeError('VM process changed during CPU experiment; allocation restored, inspect lifecycle')
    save('restored',snapshot())
    if property('AllowedCPUs')!=original:raise RuntimeError('CPU allocation restore failed')
