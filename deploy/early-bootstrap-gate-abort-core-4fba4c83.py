#!/usr/bin/env python3
"""Sealed 4fba adapter for the reviewed early-bootstrap abort core.

Operation 4fba was created without a Windows task-XML override.  The generic
core's older operation required that field to repeat the old task hash.  This
adapter attest-reads the frozen generic core and changes exactly that one
comparison to require the empty string.  The manifest baseline remains a
nonzero SHA and the runtime helper still verifies the live task XML against it.
"""

from __future__ import annotations

import hashlib
import os
import stat


GENERIC_CORE = "/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort.py"
GENERIC_CORE_SHA256 = "feb107342827abc813f5262829a77ddecb6ca1cc19e30cde2710dff540ce87f6"
OLD_CONDITION = (
    'contract["identity"]["windows_task_xml_sha256_override"] '
    '!= manifest["windows_baseline"]["task_xml_sha256"]'
)
NEW_CONDITION = 'contract["identity"]["windows_task_xml_sha256_override"] != ""'


def read_generic_core() -> bytes:
    fd = os.open(GENERIC_CORE, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
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
            raise RuntimeError("generic core ownership/mode/link contract differs")
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(1 << 20, before.st_size - len(data)))
            if not chunk:
                raise RuntimeError("generic core short read")
            data += chunk
        if os.read(fd, 1):
            raise RuntimeError("generic core grew while read")
        after = os.fstat(fd)
        current = os.stat(GENERIC_CORE, follow_symlinks=False)
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
            or hashlib.sha256(data).hexdigest() != GENERIC_CORE_SHA256
        ):
            raise RuntimeError("generic core identity or SHA-256 differs")
        return data
    finally:
        os.close(fd)


def operation_source() -> bytes:
    source = read_generic_core()
    old = OLD_CONDITION.encode("utf-8")
    new = NEW_CONDITION.encode("utf-8")
    if source.count(old) != 1 or new in source:
        raise RuntimeError("generic core override condition boundary differs")
    transformed = source.replace(old, new)
    if old in transformed or transformed.count(new) != 1:
        raise RuntimeError("4fba core override condition substitution differs")
    return transformed


def main() -> None:
    source = operation_source()
    code = compile(source, GENERIC_CORE + "#operation-4fba4c83", "exec")
    namespace = {
        "__name__": "__main__",
        "__file__": GENERIC_CORE + "#operation-4fba4c83",
        "__package__": None,
        "__builtins__": __builtins__,
    }
    exec(code, namespace, namespace)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"4fba early bootstrap abort core adapter: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
