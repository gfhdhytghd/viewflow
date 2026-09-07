#!/usr/bin/env python3
"""Sealed operation adapter for the 4fba early-bootstrap abort helper.

The reviewed generic helper is intentionally frozen to operation 2ca3.  This
adapter attest-reads those exact bytes, substitutes only the fixed operation
identifier, and executes the resulting operation-specific helper in memory.
No generic source file is modified and no transformed helper is written to
disk.
"""

from __future__ import annotations

import hashlib
import os
import stat


GENERIC_HELPER = "/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper.py"
GENERIC_HELPER_SHA256 = "bd562f25214cf337bd09c5b82c4ed866fdc8ac79ffb9da22ac8f5b380d659ac7"
OLD_OPERATION_ID = "2ca3f46635b65615a1cffc1970d73911"
OPERATION_ID = "4fba4c832389436ba980efaa4540f6bf"
EXPECTED_OPERATION_OCCURRENCES = 2


def read_generic_helper() -> bytes:
    fd = os.open(GENERIC_HELPER, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not (
            stat.S_ISREG(before.st_mode)
            and before.st_uid == os.geteuid()
            and before.st_nlink == 1
            and stat.S_IMODE(before.st_mode) == 0o755
            and not any(
                name in ("system.posix_acl_access", "system.posix_acl_default")
                for name in os.listxattr(fd)
            )
        ):
            raise RuntimeError("generic helper ownership/mode/link contract differs")
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(1 << 20, before.st_size - len(data)))
            if not chunk:
                raise RuntimeError("generic helper short read")
            data += chunk
        if os.read(fd, 1):
            raise RuntimeError("generic helper grew while read")
        after = os.fstat(fd)
        current = os.stat(GENERIC_HELPER, follow_symlinks=False)
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_uid,
            value.st_gid,
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if (
            identity(before) != identity(after)
            or identity(after) != identity(current)
            or hashlib.sha256(data).hexdigest() != GENERIC_HELPER_SHA256
        ):
            raise RuntimeError("generic helper identity or SHA-256 differs")
        return data
    finally:
        os.close(fd)


def operation_source() -> bytes:
    source = read_generic_helper()
    old = OLD_OPERATION_ID.encode("ascii")
    new = OPERATION_ID.encode("ascii")
    if len(old) != len(new) or source.count(old) != EXPECTED_OPERATION_OCCURRENCES:
        raise RuntimeError("generic helper operation substitution boundary differs")
    transformed = source.replace(old, new)
    if old in transformed or transformed.count(new) != EXPECTED_OPERATION_OCCURRENCES:
        raise RuntimeError("operation-specific helper substitution differs")
    return transformed


def main() -> None:
    source = operation_source()
    code = compile(source, GENERIC_HELPER + "#operation-4fba4c83", "exec")
    namespace = {
        "__name__": "__main__",
        "__file__": GENERIC_HELPER + "#operation-4fba4c83",
        "__package__": None,
        "__builtins__": __builtins__,
    }
    exec(code, namespace, namespace)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"4fba early bootstrap runtime helper adapter: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
