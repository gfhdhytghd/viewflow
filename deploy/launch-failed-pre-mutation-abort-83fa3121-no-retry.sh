#!/usr/bin/env bash
set -euo pipefail

launcher=/home/wilf/data/viewflow/deploy/launch-failed-pre-mutation-abort-83fa3121-no-retry.sh
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
  /usr/bin/python3 -I - "$launcher" "$@" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

GATE = "/home/wilf/data/viewflow/deploy/gate-failed-pre-mutation-abort-83fa3121-no-retry.py"
MANIFEST = "/home/wilf/data/viewflow/deploy/failed-pre-mutation-abort-83fa3121-no-retry-manifest.json"
GATE_SHA = "e2c0f4a2968bfb9f23fe224d1f9ec815c22ce1bb953151a55c4d44c166087a29"
MANIFEST_SHA = "8a13bf6f5df4fb6cc6fb36e4a0d7a6be65d787a358a0259d360862e8ac62cf11"


def stable_read(path, expected_sha, mode):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_gid,
                                 item.st_nlink, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
        if not (identity(before) == identity(named) and stat.S_ISREG(before.st_mode)
                and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == mode
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(fd))):
            raise SystemExit("launcher stable-open metadata differs: " + path)
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(1 << 20, before.st_size - len(data)))
            if not chunk:
                raise SystemExit("launcher stable-open short read: " + path)
            data += chunk
        if (os.read(fd, 1) or identity(os.fstat(fd)) != identity(before)
                or identity(before) != identity(os.stat(path, follow_symlinks=False))):
            raise SystemExit("launcher stable-open identity changed: " + path)
        digest = hashlib.sha256(data).hexdigest()
        if expected_sha is not None and digest != expected_sha:
            raise SystemExit("launcher fixed binding differs: " + path)
        return data, digest
    finally:
        os.close(fd)


def seal(name, data, mode):
    fd = os.memfd_create(name, os.MFD_ALLOW_SEALING)
    view = memoryview(data)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise SystemExit("launcher memfd short write")
        view = view[count:]
    os.fchmod(fd, mode)
    seals = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
    fcntl.fcntl(fd, fcntl.F_ADD_SEALS, seals)
    if fcntl.fcntl(fd, fcntl.F_GET_SEALS) != seals:
        raise SystemExit("launcher memfd seals differ")
    os.set_inheritable(fd, True)
    return fd


if os.geteuid() != 1000 or len(sys.argv) not in (3, 4):
    raise SystemExit(64)
launcher_path, mode = sys.argv[1], sys.argv[2]
if mode not in ("--offline-check", "--live-check-only", "--execute"):
    raise SystemExit(64)
if mode == "--execute" and (len(sys.argv) != 4 or len(sys.argv[3]) != 64
                             or any(char not in "0123456789abcdef" for char in sys.argv[3])):
    raise SystemExit(64)
if mode != "--execute" and len(sys.argv) != 3:
    raise SystemExit(64)

gate, gate_sha = stable_read(GATE, GATE_SHA, 0o700)
manifest, manifest_sha = stable_read(MANIFEST, MANIFEST_SHA, 0o600)
launcher, launcher_sha = stable_read(launcher_path, None, 0o700)
gate_fd = seal("viewflow-v4-gate-83fa", gate, 0o700)
manifest_fd = seal("viewflow-v4-manifest-83fa", manifest, 0o600)
launcher_fd = seal("viewflow-v4-launcher-83fa", launcher, 0o700)
arguments = ["/usr/bin/python3", "-I", f"/proc/self/fd/{gate_fd}",
             "--manifest", f"/proc/self/fd/{manifest_fd}",
             "--manifest-sha256", manifest_sha, "--gate-sha256", gate_sha,
             "--launcher-sha256", launcher_sha,
             "--launcher-sealed-fd", f"/proc/self/fd/{launcher_fd}", mode]
if mode == "--execute":
    arguments.extend(["--approval-sha256", sys.argv[3]])
environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
               "PYTHONHASHSEED": "0"}
os.execve("/usr/bin/python3", arguments, environment)
PY
