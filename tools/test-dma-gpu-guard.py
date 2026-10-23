#!/usr/bin/env python3
"""CPU-only fake nvidia-smi tests; never queries GPUs or starts a guest."""
import subprocess,tempfile,json,os,sys
from pathlib import Path
from dma_gpu_guard import sample,write_state

def fake(text):
 def run(*args,**kwargs):return subprocess.CompletedProcess(args,0,text,'')
 return run
assert sample(fake('0, 12\n1, 94\n'))['status']=='available'
r=sample(fake('0, 5\n1, 95\n'));assert r['status']=='busy' and len(r['gpus'])==2
for bad in ['', '0, N/A', '0, 101', '0, nan','bad']:
 assert sample(fake(bad))['status']=='unknown',bad
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'state.json';write_state(p,r);assert json.loads(p.read_text())==r
print('PASS: available/busy/all-device/unknown/atomic status; no GPU or guest used')

# Exercise the actual runner's preflight boundary. Every external command is
# replaced: no Hyprland state, system service, guest, or physical GPU is used.
with tempfile.TemporaryDirectory() as directory:
 root=Path(directory);commands=root/'commands';commands.mkdir();calls=root/'calls.jsonl'
 stub='''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ['VF_TEST_CALLS'],'a') as f:f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='nvidia-smi':print(os.environ['VF_TEST_GPU']);sys.exit(0)
if name=='hyprctl' and sys.argv[1:]==['instances','-j']:print('[{"instance":"fake","wl_socket":"fake"}]');sys.exit(0)
if name=='systemctl' and sys.argv[1:]==['--user','is-active','--quiet','viewflow-ivshmem-windows.service']:sys.exit(0)
sys.exit(99)
'''
 for name in ['nvidia-smi','hyprctl','systemctl','ssh','scp']:
  p=commands/name;p.write_text(stub);p.chmod(0o755)
 for status,output in [('busy','0, 100'),('unknown','0, N/A')]:
  calls.write_text('');out=root/status
  env=dict(os.environ,PATH=str(commands)+os.pathsep+os.environ['PATH'],VF_TEST_CALLS=str(calls),VF_TEST_GPU=output)
  result=subprocess.run([sys.executable,str(Path(__file__).with_name('run-dma-6k60.py')),'--output',str(out)],env=env,capture_output=True,text=True)
  assert result.returncode==0,result.stderr
  assert json.loads((out/'aborted.json').read_text())['observation']['status']==status
  recorded=[json.loads(line) for line in calls.read_text().splitlines()]
  assert all(c[0] in ['hyprctl','systemctl','nvidia-smi'] for c in recorded),recorded
  assert [c for c in recorded if c[0]=='systemctl']==[['systemctl','--user','is-active','--quiet','viewflow-ivshmem-windows.service']],recorded
  assert not (out/'task-result.json').exists()
print('PASS: actual runner busy/unknown preflight performs no service mutation or guest call')
