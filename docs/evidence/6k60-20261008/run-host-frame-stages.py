"""Scoped CUDA upload timing. Restore service configuration on exit."""
import os,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent
unit='viewflow-ivshmem-windows.service'
tag=os.environ.get('CUDA_RUN_TAG','host-frame-stages')
if not all(c.isalnum() or c=='-' for c in tag):raise ValueError('invalid tag')
p=Path.home()/'.config/systemd/user'/f'{unit}.d/45-host-frame-experiment.conf'
if p.exists():raise RuntimeError('experiment override already exists')
try:
    p.write_text('[Service]\nEnvironment=VIEWFLOW_CUDA_UPLOAD_TRACE=1 VIEWFLOW_HOST_FRAME_TRACE=1\n')
    subprocess.run(['systemctl','--user','daemon-reload'],check=True)
    subprocess.run(['python',str(root/'record-host-pressure.py'),str(root/(tag+'-pressure.json')),'python',str(root/'run-wgc4ms-timer.py')],env=os.environ|{'DEADLINE_RUN_SUFFIX':tag},check=True)
finally:
    p.unlink(missing_ok=True)
    subprocess.run(['systemctl','--user','daemon-reload'],check=True)
    subprocess.run(['systemctl','--user','restart',unit],check=True)
