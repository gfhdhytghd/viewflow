#!/usr/bin/env python3
"""Create-once publisher for operation 845ce422 schema1 abort approval."""

import argparse
import ctypes
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

OP = "845ce4223e4f426a8a0015d3355595e8"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
OUTPUT = ROOT / "failed-v21-rollback-abort-845ce422-v2-execution-approval.json"
MANIFEST = Path("/home/wilf/data/viewflow/deploy/failed-v21-rollback-abort-845ce422-v2-manifest.json")
GATE = Path("/home/wilf/data/viewflow/deploy/failed-v21-rollback-abort-845ce422-v2-gate.py")
LAUNCHER = Path("/home/wilf/data/viewflow/deploy/launch-failed-v21-rollback-abort-845ce422-v2.sh")
MANIFEST_SHA = "475070271f1ded3b17826f615be88a0382ba37eed5a95cdbac997163f6cc54a8"
GATE_SHA = "61241d107668001080bbdfa341205b17b9d92d0ba43ad5ee8577e92ee0ab8b7a"
LAUNCHER_SHA = "fbdef1d02422b039d22d4a992ae261f357f1be53a60951e857b2216a7684a98c"
COORDINATOR_SHA = "6e50c84886895959b954c7b4fa682258c4484e47f3663741ead4d1fb5f74b995"
STATE_SHA = "6653e38910c957775fca6beea08b07fcd3e6b64d678694e53d9f5bbd2e4b406c"
LINEAGE_SHA = "0c32f1f3524945355c20dfdf5cd7ce6a15e5d02a0331362288a9d8c22646aa78"
MARKER_SHA = "12c7e6a5ce122f67c1d190a5ad122d51f17b360aa844589d6b23aa019055fe97"
SHA = re.compile(r"[0-9a-f]{64}")
UTC_MS = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z")


def stable_read(path, expected, mode):
    if not SHA.fullmatch(expected):
        raise RuntimeError("publisher is not refrozen")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd); named = os.stat(path, follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid,
                                 item.st_gid, item.st_nlink, item.st_size,
                                 item.st_mtime_ns, item.st_ctime_ns)
        if not (identity(before) == identity(named) and stat.S_ISREG(before.st_mode)
                and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == mode
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(fd))):
            raise RuntimeError("publisher input metadata differs")
        raw = b""
        while len(raw) < before.st_size:
            raw += os.read(fd, before.st_size - len(raw))
        if os.read(fd, 1) or identity(os.fstat(fd)) != identity(before) or hashlib.sha256(raw).hexdigest() != expected:
            raise RuntimeError("publisher input changed")
        return raw
    finally:
        os.close(fd)


def create_once(raw):
    parent = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    temp = "." + OUTPUT.name + ".tmp." + str(os.getpid()) + "." + os.urandom(8).hex()
    try:
        pst = os.fstat(parent); named = os.stat(ROOT, follow_symlinks=False)
        if not ((pst.st_dev, pst.st_ino) == (named.st_dev, named.st_ino)
                and pst.st_uid == os.geteuid() and stat.S_IMODE(pst.st_mode) == 0o700
                and not any(name in ("system.posix_acl_access", "system.posix_acl_default")
                            for name in os.listxattr(parent))):
            raise RuntimeError("approval parent differs")
        try:
            os.stat(OUTPUT.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise RuntimeError("approval already exists; old approval reuse is forbidden")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600,
                     dir_fd=parent)
        try:
            os.write(fd, raw); os.fsync(fd)
        finally:
            os.close(fd)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renameat2(parent, os.fsencode(temp), parent, os.fsencode(OUTPUT.name), 1) != 0:
            raise RuntimeError("approval no-replace publish failed")
        os.fsync(parent)
        if stable_read(OUTPUT, hashlib.sha256(raw).hexdigest(), 0o600) != raw:
            raise RuntimeError("approval readback differs")
    finally:
        try:
            os.unlink(temp, dir_fd=parent)
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
    if OUTPUT.exists() or OUTPUT.is_symlink():
        raise RuntimeError("approval output is not fresh; no prior approval may be reused")
    if args.check_only:
        if args.approved_at_utc:
            raise RuntimeError("check-only rejects approval timestamp")
        print("845ce422 approval publisher check passed; no write")
        return
    if not UTC_MS.fullmatch(args.approved_at_utc):
        raise RuntimeError("publish requires canonical millisecond UTC timestamp")
    value = {"schema_version": 1,
             "state": "viewflow-failed-v21-rollback-abort-845ce422-v2-execution-approved",
             "approved": True, "operation_id": OP, "manifest_sha256": MANIFEST_SHA,
             "gate_sha256": GATE_SHA, "launcher_sha256": LAUNCHER_SHA,
             "coordinator_sha256": COORDINATOR_SHA, "coordinator_state_sha256": STATE_SHA,
             "lineage_sha256": LINEAGE_SHA, "marker_sha256": MARKER_SHA,
             "publication_method": "create-once-no-replace-and-parent-fsync",
             "approved_at_utc": args.approved_at_utc}
    create_once((json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode())
    print("845ce422 execution approval published create-once")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print("845ce422 approval publisher: " + str(error), file=sys.stderr)
        raise SystemExit(1)
