"""Apply the user-approved CPU options, preserving a root-owned rollback copy.

Run with sudo only after diagnostic streams have exited. Does not stop the VM.
"""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, tempfile

unit = Path('/etc/systemd/system/windows-autoshop.service')
expected = '7e7df26dec0ec0e166be016ac52e4509fa17ae7aa61c208edcb24196c7379592'
before = unit.read_bytes()
assert hashlib.sha256(before).hexdigest() == expected, 'unit changed since review'
old = b'    -cpu host \\\n'
new = b'    -cpu host,hv-vpindex=on,hv-time=on,hv-synic=on,hv-stimer=on \\\n'
assert before.count(old) == 1
after = before.replace(old, new)
backup = unit.with_name(unit.name + '.viewflow-timer-20260909.bak')
assert not backup.exists(), 'preserve existing backup'
shutil.copy2(unit, backup)
assert backup.read_bytes() == before
st = unit.stat()
def replace(data):
    fd, name = tempfile.mkstemp(prefix='.viewflow-timer-', dir=unit.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(name, st.st_mode)
        os.chown(name, st.st_uid, st.st_gid)
        os.replace(name, unit)
    finally:
        if os.path.exists(name): os.unlink(name)
replace(after)
try:
    subprocess.run(['systemd-analyze', 'verify', str(unit)], check=True)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
except BaseException:
    replace(before)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    raise
print(json.dumps(dict(unit=str(unit), backup=str(backup), before_sha256=expected,
    after_sha256=hashlib.sha256(unit.read_bytes()).hexdigest(), applied=True,
    running_vm_unchanged=True), indent=2))
