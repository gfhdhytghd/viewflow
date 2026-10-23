#!/usr/bin/env python3
"""Read-only host check for the dedicated 16 MiB D3D12 scratch device.

Run --expect-zero on a freshly created scratch backing before the guest probe,
then run without it only after the guest's GPU fence and process have completed.
This checks cross-host memory contents, not capture or presentation performance.
"""
import argparse
import hashlib
import json
import os
import stat

SIZE = 16 * 1024 * 1024
PAYLOAD = 1024 * 1024


def verify(path, expect_zero=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size != SIZE:
            raise ValueError("requires dedicated regular 16 MiB scratch backing")
        with os.fdopen(fd, "rb", closefd=False) as source:
            data = source.read(SIZE + 1)
        if len(data) != SIZE:
            raise ValueError("scratch extent changed while reading")
        expected = (bytes(PAYLOAD) if expect_zero else
                    bytes((i * 37 + (i >> 8) + 91) & 255 for i in range(PAYLOAD)))
        payload = data[:PAYLOAD]
        mismatches = sum(a != b for a, b in zip(payload, expected))
        first = next((i for i, (a, b) in enumerate(zip(payload, expected)) if a != b), None)
        tail_nonzero = sum(value != 0 for value in data[PAYLOAD:])
        return {"result": "passed" if not mismatches and not tail_nonzero else "failed",
                "expected": "zero-before-probe" if expect_zero else "guest-gpu-pattern",
                "bytes": SIZE, "payload_bytes": PAYLOAD, "mismatches": mismatches,
                "first_mismatch": first, "tail_nonzero_bytes": tail_nonzero,
                "payload_sha256": hashlib.sha256(payload).hexdigest(),
                "device": before.st_dev, "inode": before.st_ino,
                "scope": "host-memory-only-not-capture-or-presentation"}
    finally:
        os.close(fd)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--expect-zero", action="store_true")
    args = parser.parse_args()
    try:
        result = verify(args.path, args.expect_zero)
    except (OSError, ValueError) as error:
        parser.exit(2, f"scratch verification rejected: {error}\n")
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["result"] == "passed" else 1)
