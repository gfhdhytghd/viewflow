#!/usr/bin/env python3
"""Read-only verification of one explicitly named, user-owned DMA scratch file.

Only the 6K pixel prefix is read. mincore inspects residency without reading the
tail. Residency does not prove DMA mappings or pinned-page ownership.
"""
import argparse
import ctypes
import json
import os
import stat


EXTENT = 1 << 30
PREFIX = 6144 * 3456 * 4
CHUNK = 1 << 20


def residency(fd):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                          ctypes.c_int, ctypes.c_int, ctypes.c_longlong]
    libc.mmap.restype = ctypes.c_void_p
    libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    libc.mincore.restype = ctypes.c_int
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    libc.munmap.restype = ctypes.c_int
    # Linux PROT_READ | MAP_SHARED; no MAP_POPULATE, pixel dereference, or write.
    address = libc.mmap(None, EXTENT, 1, 1, fd, 0)
    if address == ctypes.c_void_p(-1).value:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    try:
        page = os.sysconf("SC_PAGE_SIZE")
        if PREFIX % page or EXTENT % page:
            raise RuntimeError("Frame and extent must be host-page aligned")
        bits = (ctypes.c_ubyte * (EXTENT // page))()
        if libc.mincore(address, EXTENT, bits):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        split = PREFIX // page
        return {"page_bytes": page,
                "prefix_resident_bytes": sum(bits[i] & 1 for i in range(split)) * page,
                "tail_resident_bytes": sum(bits[i] & 1 for i in range(split, len(bits))) * page}
    finally:
        if libc.munmap(address, EXTENT):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))


def verify(path, expect_zero):
    report = {"path": os.path.abspath(path), "status": "failed",
              "expected_extent_bytes": EXTENT, "pixel_prefix_bytes": PREFIX,
              "mode": "residency_only" if expect_zero else "pattern_compare",
              "bytes_read": 0, "tail_bytes_read": 0,
              "residency_is_pin_proof": False}
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Scratch must be a regular file")
        if info.st_uid != os.getuid():
            raise ValueError("Scratch must be owned by the invoking user")
        if info.st_size != EXTENT:
            raise ValueError(f"Wrong scratch extent: {info.st_size}, expected {EXTENT}")
        report["identity"] = {"device": info.st_dev, "inode": info.st_ino,
                              "owner_uid": info.st_uid, "size_bytes": info.st_size}
        report["before"] = residency(fd)
        if expect_zero:
            if report["before"]["prefix_resident_bytes"] or report["before"]["tail_resident_bytes"]:
                raise ValueError("Expected completely nonresident scratch baseline")
        else:
            # This formula repeats every 65536 bytes; 1 MiB chunk boundaries are
            # exact multiples. Only unequal chunks need a Python per-byte loop.
            period = bytes((i * 37 + (i >> 8) + 91) & 255 for i in range(65536))
            expected = period * (CHUNK // len(period))
            mismatch = 0
            first = []
            for offset in range(0, PREFIX, CHUNK):
                length = min(CHUNK, PREFIX - offset)
                data = os.pread(fd, length, offset)
                report["bytes_read"] += len(data)
                if len(data) != length:
                    raise IOError(f"Short prefix read at {offset}: {len(data)}/{length}")
                target = expected[:length]
                if data != target:
                    for index, (actual, wanted) in enumerate(zip(data, target)):
                        if actual != wanted:
                            mismatch += 1
                            if len(first) < 16:
                                first.append({"offset": offset + index,
                                              "actual": actual, "expected": wanted})
            report["mismatch_count"] = mismatch
            report["first_mismatches"] = first
        report["after"] = residency(fd)
        if os.fstat(fd).st_size != EXTENT:
            raise ValueError("Scratch extent changed during verification")
        if expect_zero:
            if report["after"]["prefix_resident_bytes"] or report["after"]["tail_resident_bytes"]:
                raise ValueError("Scratch baseline became resident during verification")
        elif report["mismatch_count"]:
            raise ValueError(f"Pixel mismatch count: {report['mismatch_count']}")
        report["status"] = "passed"
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        if fd is not None:
            os.close(fd)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="Exact scratch file path; symlinks rejected")
    parser.add_argument("--expect-zero", action="store_true",
                        help="Check residency is zero; do not read any pixels")
    args = parser.parse_args()
    report = verify(args.path, args.expect_zero)
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
