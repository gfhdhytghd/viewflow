#!/usr/bin/env python3
"""Create-once approval publisher for op442 post-commit recovery v3."""

import argparse
import ctypes
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

OP = "442fe737e67f43b89d85a7e33149a072"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
OUTPUT = ROOT / "schema5-abort-442fe737-recovery-v3-execution-approval.json"
PREDECESSOR_V2_APPROVAL = ROOT / "schema5-abort-442fe737-successor-v2-execution-approval.json"
PREDECESSOR_V2_APPROVAL_SHA = "e741232ce133ac10fc0dafa7b130caa5ec2ba7b2132f8374eb01bf82ac66518e"
MANIFEST = Path("/home/wilf/data/viewflow/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-manifest.json")
GATE = Path("/home/wilf/data/viewflow/deploy/failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3-gate.py")
LAUNCHER = Path("/home/wilf/data/viewflow/deploy/launch-failed-v21-post-permit-rollback-schema5-abort-442fe737-recovery-v3.sh")
MANIFEST_SHA = "1038b5add1d420210befe78756d0daa9963febf0daa878fc2079d4011dc0806d"
GATE_SHA = "589df74d2174fc1e1bbb9ca6027ddabe482c932470996faf72146f00f55d9fd1"
LAUNCHER_SHA = "aaacaf726759c65bc37fe63914da92bc6e61241e04af0267bb9d475e1be59e9c"
SHA = re.compile(r"[0-9a-f]{64}\Z")
UTC_MS = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def stable_read(path, expected, mode):
    if not SHA.fullmatch(expected):
        raise RuntimeError("publisher is not refrozen")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        if not (identity(before) == identity(named) and stat.S_ISREG(before.st_mode)
                and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == mode
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(fd))):
            raise RuntimeError("publisher input metadata differs")
        raw = b""
        while len(raw) < before.st_size:
            chunk = os.read(fd, before.st_size - len(raw))
            if not chunk:
                raise RuntimeError("publisher input short read")
            raw += chunk
        if os.read(fd, 1) or identity(os.fstat(fd)) != identity(before):
            raise RuntimeError("publisher input changed while read")
        if hashlib.sha256(raw).hexdigest() != expected:
            raise RuntimeError("publisher input hash differs")
        return raw
    finally:
        os.close(fd)


def create_once(raw):
    parent = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    temporary = "." + OUTPUT.name + ".tmp." + str(os.getpid()) + "." + os.urandom(8).hex()
    try:
        parent_stat = os.fstat(parent)
        named = os.stat(ROOT, follow_symlinks=False)
        if not ((parent_stat.st_dev, parent_stat.st_ino) == (named.st_dev, named.st_ino)
                and parent_stat.st_uid == os.geteuid() and stat.S_IMODE(parent_stat.st_mode) == 0o700
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(parent))):
            raise RuntimeError("approval parent differs")
        try:
            os.stat(OUTPUT.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise RuntimeError("approval already exists; old approval reuse is forbidden")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                     0o600, dir_fd=parent)
        try:
            view = memoryview(raw)
            while view:
                count = os.write(fd, view)
                if count <= 0:
                    raise RuntimeError("approval short write")
                view = view[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renameat2(parent, os.fsencode(temporary), parent,
                          os.fsencode(OUTPUT.name), 1) != 0:
            raise RuntimeError("approval no-replace publish failed")
        os.fsync(parent)
        if stable_read(OUTPUT, hashlib.sha256(raw).hexdigest(), 0o600) != raw:
            raise RuntimeError("approval readback differs")
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def main():
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--check-only", action="store_true")
    modes.add_argument("--publish", action="store_true")
    parser.add_argument("--approved-at-utc", default="")
    args = parser.parse_args()
    stable_read(MANIFEST, MANIFEST_SHA, 0o600)
    stable_read(GATE, GATE_SHA, 0o700)
    stable_read(LAUNCHER, LAUNCHER_SHA, 0o700)
    stable_read(PREDECESSOR_V2_APPROVAL, PREDECESSOR_V2_APPROVAL_SHA, 0o600)
    if OUTPUT.exists() or OUTPUT.is_symlink():
        raise RuntimeError("approval output is not fresh; no prior approval may be reused")
    if args.check_only:
        if args.approved_at_utc:
            raise RuntimeError("check-only rejects approval timestamp")
        print("442fe737 schema5 abort recovery-v3 approval publisher check passed; no write")
        return
    if not UTC_MS.fullmatch(args.approved_at_utc):
        raise RuntimeError("publish requires canonical millisecond UTC timestamp")
    value = {"schema_version": 3,
        "state": "viewflow-op442-schema5-abort-recovery-v3-execution-approved",
        "approved": True, "operation_id": OP, "manifest_sha256": MANIFEST_SHA,
        "gate_sha256": GATE_SHA, "launcher_sha256": LAUNCHER_SHA,
        "predecessor_v2_approval_sha256": PREDECESSOR_V2_APPROVAL_SHA,
        "publication_method": "create-once-no-replace-and-parent-fsync",
        "approved_at_utc": args.approved_at_utc}
    create_once((json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode())
    print("442fe737 schema5 abort recovery-v3 execution approval published create-once")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print("442fe737 schema5 approval publisher: " + str(error), file=sys.stderr)
        raise SystemExit(1)
