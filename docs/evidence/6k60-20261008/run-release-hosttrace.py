import os,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent
setting=Path(os.environ['XDG_RUNTIME_DIR'])/'systemd/user/viewflow-ivshmem-windows.service.d/99-viewflow-release-hosttrace.conf'
assert not setting.exists()
setting.parent.mkdir(parents=True,exist_ok=True)
try:
 setting.write_text('[Service]\nEnvironment=VIEWFLOW_HOST_FRAME_TRACE=1\n')
 subprocess.run(['systemctl','--user','daemon-reload'],check=True)
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
 subprocess.run(['python',str(root/'run-physical-motion.py')],env=os.environ|{'MOTION_TAG':'physical-release-hosttrace1'},check=True)
finally:
 setting.unlink(missing_ok=True)
 subprocess.run(['systemctl','--user','daemon-reload'],check=True)
 subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
