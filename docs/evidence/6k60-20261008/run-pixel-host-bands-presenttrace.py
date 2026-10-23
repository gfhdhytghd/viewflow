"""Bounded host marker diagnostic; restore binary and remove own override."""
import os,subprocess,shutil,hashlib
from pathlib import Path
r=Path(__file__).resolve().parent
native=Path.home()/'.local/lib/viewflow/ivshmem/viewflow_linux_reverse'
backup=r/'pixel-bands-presenttrace-native.backup'
override=Path(os.environ.get('XDG_RUNTIME_DIR',f'/run/user/{os.getuid()}'))/'systemd/user/viewflow-ivshmem-windows.service.d/91-pixel-stamp-test.conf'
if backup.exists() or override.exists():raise RuntimeError('existing backup/override; inspect first')
def ctl(*a):subprocess.run(['systemctl','--user',*a],check=True)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
shutil.copy2(native,backup);old=digest(backup)
try:
 ctl('stop','viewflow-ivshmem-windows.service')
 shutil.copy2(r.parents[2]/'build/ivshmem-linux/viewflow_linux_reverse',native)
 override.parent.mkdir(parents=True,exist_ok=True);override.write_text('[Service]\nEnvironment=VIEWFLOW_FIXTURE_PIXEL_STAMP=1\nEnvironment=VIEWFLOW_HOST_FRAME_TRACE=1\n')
 ctl('daemon-reload');ctl('start','viewflow-ivshmem-windows.service')
 subprocess.run(['python3',str(r/'run-pixel-bands-presenttrace.py')],check=True)
finally:
 ctl('stop','viewflow-ivshmem-windows.service');shutil.copy2(backup,native);override.unlink(missing_ok=True)
 ctl('daemon-reload');ctl('start','viewflow-ivshmem-windows.service')
 if digest(native)!=old:raise RuntimeError('host restore hash mismatch')
 (r/'physical-pixel-bands-presenttrace1-host-restore.txt').write_text(old+'\n')
