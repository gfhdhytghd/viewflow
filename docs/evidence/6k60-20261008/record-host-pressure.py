"""Read-only host pressure/vCPU telemetry around an explicit benchmark command.

Samples use monotonic time, for correlation with calibrated presentation logs.
Counters are cumulative; report deltas, not historical process CPU percentages.
"""
import json,subprocess,sys,time
from pathlib import Path
out=Path(sys.argv[1]);command=sys.argv[2:]
if not command:raise SystemExit('usage: record-host-pressure.py output.json command ...')
if out.exists():raise SystemExit('refusing to overwrite evidence')
pid=int(subprocess.check_output(['systemctl','show','windows-autoshop.service','-p','MainPID','--value'],text=True))
def numbers(path):
    return {a:int(b) for a,b,*_ in (s.split() for s in Path(path).read_text().splitlines())}
def sample():
    row={'monotonic_ns':time.monotonic_ns(),'vm_pid':pid}
    row['psi']={}
    for kind in ('cpu','memory','io'):
        row['psi'][kind]={s.split()[0]:{k:float(v) for k,v in (pair.split('=') for pair in s.split()[1:])} for s in Path('/proc/pressure',kind).read_text().splitlines()}
    v=numbers('/proc/vmstat');row['vmstat']={k:v[k] for k in v if k.startswith(('pswp','pgmajfault','allocstall','pgscan_direct','pgsteal_direct'))}
    m=numbers('/proc/meminfo');row['memory_kib']={k:m[k+':'] for k in ('MemAvailable','SwapFree','Dirty','Writeback')}
    row['vcpu']=[]
    for task in Path('/proc',str(pid),'task').glob('*'):
        try:
            name=(task/'comm').read_text().strip()
            if name.startswith('CPU '):row['vcpu'].append({'tid':int(task.name),'name':name,'schedstat':list(map(int,(task/'schedstat').read_text().split()))})
        except (FileNotFoundError,ProcessLookupError):pass
    return row
rows=[sample()];proc=subprocess.Popen(command)
try:
    while proc.poll() is None:
        time.sleep(.25);rows.append(sample())
finally:
    # An observation failure does not terminate or restart the benchmark.
    out.write_text(json.dumps({'command':command,'child_pid':proc.pid,'returncode':proc.poll(),'samples':rows},indent=2))
raise SystemExit(proc.returncode)
