import os,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parent
finish=len(sys.argv)>1 and sys.argv[1]=='finish'
tag='physical-finish-before-swap' if finish else 'physical-async-swap'
drop=Path.home()/'.config/systemd/user/viewflow-ivshmem-windows.service.d/42-finish-experiment.conf'
if drop.exists():raise RuntimeError('experiment drop-in already exists; inspect before changing it')
try:
 drop.write_text('[Service]\nEnvironment=VIEWFLOW_FINISH_BEFORE_SWAP='+('1' if finish else '0')+'\n')
 subprocess.run(['systemctl','--user','daemon-reload'],check=True)
 subprocess.run(['python',str(root/'run-physical-motion.py')],env=os.environ|{'MOTION_TAG':tag},check=True)
finally:
 drop.unlink(missing_ok=True)
 subprocess.run(['systemctl','--user','daemon-reload'],check=True)
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
