from pathlib import Path
import subprocess,json
p=Path(__file__).resolve().parent.parent
for label,experiment in [('auto-a1',0),('disabled-b1',1),('disabled-b2',1),('auto-a2',0)]:
    print('RUN',label,flush=True)
    subprocess.run(['python3',str(p/'method/run.py'),label,'1','2','0',str(experiment)],check=True)
    assert json.loads((p/'runs'/label/'status.json').read_text())['exit']==0
