#!/usr/bin/env python3
"""Observe Linux shared-file page residency without reading/faulting pixel data.

This is page-cache residency, NOT GPU pin counts, QEMU RSS, or working-set proof.
Use paired observations around an isolated import to detect eager residency.
"""
import argparse
import ctypes
import json
import os
import stat
import time


def measure(path):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                          ctypes.c_int, ctypes.c_int, ctypes.c_long]
    libc.mmap.restype = ctypes.c_void_p
    libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    libc.mincore.restype = ctypes.c_int
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    libc.munmap.restype = ctypes.c_int
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size <= 0:
            raise ValueError('nonempty regular backing file required')
        # Linux may deliberately return all-resident information to a caller
        # lacking ownership/write permission. Require ownership for this probe.
        if before.st_uid != os.geteuid():
            raise ValueError('file ownership required for meaningful mincore data')
        page = os.sysconf('SC_PAGE_SIZE')
        count = (before.st_size + page - 1) // page
        vector = (ctypes.c_ubyte * count)()
        address = libc.mmap(None, before.st_size, 1, 1, fd, 0)  # READ, SHARED
        if address == ctypes.c_void_p(-1).value:
            raise OSError(ctypes.get_errno(), 'mmap')
        try:
            if libc.mincore(address, before.st_size, vector):
                raise OSError(ctypes.get_errno(), 'mincore')
        finally:
            libc.munmap(address, before.st_size)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size) != (
                after.st_dev, after.st_ino, after.st_size):
            raise RuntimeError('backing extent changed during observation')
        resident = sum(bool(value & 1) for value in vector)
        chunk_pages = max(1, (64 * 1024 * 1024) // page)
        chunks = [dict(offset_bytes=start * page,
                       extent_bytes=min(chunk_pages * page, before.st_size - start * page),
                       resident_page_bytes=sum(bool(vector[i] & 1) for i in
                           range(start, min(start + chunk_pages, count))) * page)
                  for start in range(0, count, chunk_pages)]
        return dict(path=path, device=before.st_dev, inode=before.st_ino,
                    extent_bytes=before.st_size, page_bytes=page,
                    resident_pages=resident, total_pages=count,
                    resident_page_bytes=resident * page, chunks_64m=chunks)
    finally:
        os.close(fd)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+')
    args = parser.parse_args()
    print(json.dumps(dict(time_ns=time.time_ns(), scope='file-page-residency',
                         pixel_reads=False, pin_counts_measured=False,
                         files=[measure(path) for path in args.paths]), indent=2))
