#!/usr/bin/env python3
"""Prepare fresh sparse IVSHMEM banks before QEMU starts (VM must be stopped).

PCI bus 0: control device 5, pixel devices 6..9. The signed Windows driver
maps each 1 GiB BAR separately. This prepares virtual extents, not pixel RAM.
Requires Viewflow's CPU-only QEMU backend opt-in with VFIO passthrough.
"""
import os
from pathlib import Path
import struct
import sys
import tempfile


def prepare(path):
    path = Path(path)
    layout = struct.pack('<QQ6I', 0x324B4E4142465656, 1 << 30, 0,
                         6 << 16, 7 << 16, 8 << 16, 9 << 16, 0)
    for index in range(5):
        target = path if index == 0 else Path(str(path) + f'.slot{index-1}')
        fd, temporary = tempfile.mkstemp(prefix=target.name + '.', dir=target.parent)
        try:
            os.ftruncate(fd, (1 << 20) if index == 0 else (1 << 30))
            if index == 0:
                os.pwrite(fd, layout, 1024)
            os.close(fd)
            fd = -1
            os.replace(temporary, target)
        finally:
            if fd != -1:
                os.close(fd)
            if os.path.exists(temporary):
                os.unlink(temporary)


if __name__ == '__main__':
    prepare(sys.argv[1])
