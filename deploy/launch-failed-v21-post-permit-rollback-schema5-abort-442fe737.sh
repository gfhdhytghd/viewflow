#!/usr/bin/env bash
set -euo pipefail

launcher=/home/wilf/data/viewflow/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737.sh
exec /usr/bin/env -i HOME=/home/wilf USER=wilf LOGNAME=wilf PATH=/usr/bin:/bin \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 XDG_RUNTIME_DIR=/run/user/1000 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus PYTHONHASHSEED=0 \
  /usr/bin/python3 -I - "$launcher" "$@" <<'PY'
import fcntl
import hashlib
import os
import re
import stat
import sys

GATE = "/home/wilf/data/viewflow/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-gate.py"
MANIFEST = "/home/wilf/data/viewflow/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-manifest.json"
GATE_SHA = "8a023fe9e026f49d4edaf1fba4a4b6fd5b29bce2f0d7419f7b870aa60664f2f6"
MANIFEST_SHA = "187f135df50f75f24e16e3ba81fec545946406b552f96a1b25eb03f4bd2b726b"
SHA = re.compile(r"[0-9a-f]{64}\Z")


def stable_read(path, expected, mode):
    if not SHA.fullmatch(expected):
        raise SystemExit("launcher is not refrozen: " + path)
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid,
                                 item.st_gid, item.st_nlink, item.st_size,
                                 item.st_mtime_ns, item.st_ctime_ns)
        if not (identity(before) == identity(named) and stat.S_ISREG(before.st_mode)
                and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == mode
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(fd))):
            raise SystemExit("launcher input metadata differs: " + path)
        chunks = []
        while sum(map(len, chunks)) < before.st_size:
            chunk = os.read(fd, before.st_size - sum(map(len, chunks)))
            if not chunk:
                raise SystemExit("launcher input short read: " + path)
            chunks.append(chunk)
        raw = b"".join(chunks)
        if (os.read(fd, 1) or identity(os.fstat(fd)) != identity(before)
                or hashlib.sha256(raw).hexdigest() != expected):
            raise SystemExit("launcher input changed: " + path)
        return raw
    finally:
        os.close(fd)


def seal(name, raw, mode):
    fd = os.memfd_create(name, os.MFD_ALLOW_SEALING)
    view = memoryview(raw)
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
if mode not in ("--offline-check", "--live-check-only", "--execute", "--resume"):
    raise SystemExit(64)
if mode in ("--execute", "--resume"):
    if len(sys.argv) != 4 or not SHA.fullmatch(sys.argv[3]):
        raise SystemExit(64)
elif len(sys.argv) != 3:
    raise SystemExit(64)

gate = stable_read(GATE, GATE_SHA, 0o700)
manifest = stable_read(MANIFEST, MANIFEST_SHA, 0o600)
launcher_fd_source = os.open(launcher_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    launcher_expected = hashlib.sha256(os.read(launcher_fd_source,
                                               os.fstat(launcher_fd_source).st_size + 1)).hexdigest()
finally:
    os.close(launcher_fd_source)
launcher_raw = stable_read(launcher_path, launcher_expected, 0o700)
gate_fd = seal("viewflow-schema5-abort-gate-442fe737", gate, 0o700)
manifest_fd = seal("viewflow-schema5-abort-manifest-442fe737", manifest, 0o600)
launcher_fd = seal("viewflow-schema5-abort-launcher-442fe737", launcher_raw, 0o700)
argv = ["/usr/bin/python3", "-I", f"/proc/self/fd/{gate_fd}",
        "--manifest", f"/proc/self/fd/{manifest_fd}", "--manifest-sha256", MANIFEST_SHA,
        "--gate-sha256", GATE_SHA,
        "--launcher-sha256", hashlib.sha256(launcher_raw).hexdigest(),
        "--launcher-sealed-fd", f"/proc/self/fd/{launcher_fd}", mode]
if mode in ("--execute", "--resume"):
    argv.extend(["--approval-sha256", sys.argv[3]])
environment = {"HOME": "/home/wilf", "USER": "wilf", "LOGNAME": "wilf",
               "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
               "XDG_RUNTIME_DIR": "/run/user/1000",
               "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
               "PYTHONHASHSEED": "0"}
os.execve("/usr/bin/python3", argv, environment)
PY
