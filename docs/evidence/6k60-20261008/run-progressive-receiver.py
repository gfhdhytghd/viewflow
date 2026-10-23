"""Exercise actual receiver queue/render loop without creating desktop windows."""
import os,subprocess,tempfile,json
from pathlib import Path
root=Path(__file__).resolve().parent
instances=json.loads(subprocess.check_output(['hyprctl','instances','-j']))
assert instances
env=os.environ|{'WAYLAND_DISPLAY':instances[0]['wl_socket'],'HYPRLAND_INSTANCE_SIGNATURE':instances[0]['instance']}
with tempfile.NamedTemporaryFile(prefix='viewflow-progressive-',dir='/dev/shm') as bank:
 bank.truncate(4096+4*6144*3456*4);bank.flush()
 producer=subprocess.Popen(['build/ivshmem-linux/viewflow_progressive_receiver_fixture',bank.name],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 try:
  receiver=subprocess.run(['build/ivshmem-linux/viewflow_linux_reverse','--validate','--ivshmem',bank.name],env=env,stdin=producer.stdout,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=20)
  (root/'progressive-receiver.log').write_bytes(receiver.stderr)
  print(receiver.stderr.decode(errors='replace'),flush=True)
  if receiver.returncode:raise RuntimeError(f'receiver exit {receiver.returncode}')
  producer.stdout.close();_,pe=producer.communicate(timeout=5)
  log=receiver.stderr.decode(errors='replace')+pe.decode(errors='replace')
  (root/'progressive-receiver.log').write_text(log)
  print(log)
  assert receiver.returncode==producer.returncode==0
  validated=[line for line in log.splitlines() if 'reverse-validated frame=' in line]
  assert len(validated)==6 and all(line.endswith('pts='+str(pts)) for line,pts in zip(validated,[1,3,4,5,6,7]))
  assert 'recovering' not in log
 finally:
  if producer.poll() is None:producer.terminate();producer.wait(timeout=5)
