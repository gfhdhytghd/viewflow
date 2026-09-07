#!/usr/bin/env python3
"""Reviewed create-once publisher for the operation-83fa V4 execution approval."""

import argparse
import ctypes
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

OP = "83fa3121bcb645e5847db05cc8cd5250"
ROOT = Path("/home/wilf/.local/state/viewflow/deployments") / OP
OUTPUT = ROOT / "failed-pre-mutation-abort-83fa3121-no-retry-execution-approval.json"
MANIFEST = Path("/home/wilf/data/viewflow/deploy/failed-pre-mutation-abort-83fa3121-no-retry-manifest.json")
GATE = Path("/home/wilf/data/viewflow/deploy/gate-failed-pre-mutation-abort-83fa3121-no-retry.py")
LAUNCHER = Path("/home/wilf/data/viewflow/deploy/launch-failed-pre-mutation-abort-83fa3121-no-retry.sh")
MANIFEST_SHA = "8a13bf6f5df4fb6cc6fb36e4a0d7a6be65d787a358a0259d360862e8ac62cf11"
GATE_SHA = "e2c0f4a2968bfb9f23fe224d1f9ec815c22ce1bb953151a55c4d44c166087a29"
LAUNCHER_SHA = "a23dba7212fab71b50d9d4508d2ee1e834af87495a65bcae059b0a4208fcd9d1"
UTC_MS = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z")


def stable_read(path, expected_sha, mode):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
                                  value.st_gid, value.st_nlink, value.st_size,
                                  value.st_mtime_ns, value.st_ctime_ns)
        if not (identity(before) == identity(named) and stat.S_ISREG(before.st_mode)
                and before.st_uid == os.geteuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == mode
                and not any(item in ("system.posix_acl_access", "system.posix_acl_default")
                            for item in os.listxattr(fd))):
            raise RuntimeError("approval input metadata differs: " + str(path))
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, before.st_size - len(data))
            if not chunk:
                raise RuntimeError("approval input short read")
            data += chunk
        if (os.read(fd, 1) or identity(os.fstat(fd)) != identity(before)
                or identity(before) != identity(os.stat(path, follow_symlinks=False))
                or hashlib.sha256(data).hexdigest() != expected_sha):
            raise RuntimeError("approval input bytes changed: " + str(path))
        return data
    finally:
        os.close(fd)


def publish(data):
    parent = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    temporary = "." + OUTPUT.name + ".tmp." + str(os.getpid()) + "." + os.urandom(8).hex()
    try:
        before = os.fstat(parent)
        named_parent = os.stat(ROOT, follow_symlinks=False)
        if not ((before.st_dev, before.st_ino) == (named_parent.st_dev, named_parent.st_ino)
                and before.st_uid == os.geteuid() and stat.S_IMODE(before.st_mode) == 0o700
                and not any(item in ("system.posix_acl_access", "system.posix_acl_default")
                            for item in os.listxattr(parent))):
            raise RuntimeError("approval parent identity/ACL differs")
        try:
            os.stat(OUTPUT.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise RuntimeError("approval already exists")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                     0o600, dir_fd=parent)
        try:
            if os.listxattr(fd):
                raise RuntimeError("approval staging ACL/xattr differs")
            view = memoryview(data)
            while view:
                count = os.write(fd, view)
                if count <= 0:
                    raise RuntimeError("approval staging short write")
                view = view[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renameat2(parent, os.fsencode(temporary), parent, os.fsencode(OUTPUT.name), 1) != 0:
            raise RuntimeError("approval no-replace rename failed")
        os.fsync(parent)
        if stable_read(OUTPUT, hashlib.sha256(data).hexdigest(), 0o600) != data:
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
    if OUTPUT.exists() or OUTPUT.is_symlink():
        raise RuntimeError("approval output is not fresh")
    if args.check_only:
        if args.approved_at_utc:
            raise RuntimeError("check-only rejects approval timestamp")
        print("83fa no-retry V4 approval publisher check passed; no write")
        return
    if not UTC_MS.fullmatch(args.approved_at_utc):
        raise RuntimeError("publish requires canonical millisecond UTC timestamp")
    value = {
        "schema_version": 4,
        "state": "viewflow-failed-pre-mutation-no-retry-abort-execution-approved",
        "approved": True,
        "operation_id": OP,
        "manifest_sha256": MANIFEST_SHA,
        "gate_sha256": GATE_SHA,
        "launcher_sha256": LAUNCHER_SHA,
        "coordinator_state_sha256": "f63b55ab66a5e74a6ee26f1d567ac9670d4783f9daa494aaae4df649035f6da0",
        "marker_sha256": "f5ec68a7dcb1dc04484e128e81a12de76817ed4d778d6090fe353a36f14e0a62",
        "v4_marker_cli_sha256": "c237736c4d8d4db6ba6e118ac46dc083bdf3d8ae99a0b08716bc5d3206fc6c57",
        "v4_marker_cli_provenance_sha256": "f3023dd53acade01874af56a22fda0be126fd3bdb8160d9a471cc17cd320b7bd",
        "transaction_implementation": "sealed-fd-native-rust-v4-abort-then-query",
        "approved_at_utc": args.approved_at_utc,
    }
    publish((json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode())
    print("83fa no-retry V4 execution approval published create-once")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print("83fa no-retry V4 approval publisher: " + str(error), file=sys.stderr)
        raise SystemExit(1)
