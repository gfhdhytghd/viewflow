from pathlib import Path
import subprocess,json
p=Path(__file__).resolve().parent.parent
for label,experiment in [('cbr-a1',0),('gpb-off-b1',1),('cqp-c1',2),('cqp-gpb-off-d1',3),('cqp-gpb-off-d2',3),('cqp-c2',2),('gpb-off-b2',1),('cbr-a2',0)]:
    print('RUN',label,flush=True)
    subprocess.run(['python3',str(p/'method/run.py'),label,'1','2','0',str(experiment)],check=True)
    assert json.loads((p/'runs'/label/'status.json').read_text())['exit']==0
