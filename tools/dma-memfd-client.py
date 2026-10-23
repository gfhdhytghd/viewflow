#!/usr/bin/env python3
"""Receive and inspect one explicit scratch memfd; optional owned child command."""
import argparse
import array
import ctypes
import fcntl
import json
import os
import socket
import stat
import subprocess

CAPACITY = 1 << 30
CHUNK = 64 << 20
TOKEN = '@VIEWFLOW_DMA_FD@'


def receive(path):
    descriptors = []
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
            channel.settimeout(10)
            channel.connect(path)
            channel.sendall(b'GET')
            payload = b''
            while b'\n' not in payload:
                data, ancillary, flags, _ = channel.recvmsg(
                    4096, socket.CMSG_SPACE(256 * array.array('i').itemsize),
                    socket.MSG_CMSG_CLOEXEC)
                for level, kind, content in ancillary:
                    if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                        values = array.array('i')
                        values.frombytes(content[:len(content) // values.itemsize * values.itemsize])
                        descriptors.extend(values)
                if flags & (socket.MSG_CTRUNC | socket.MSG_TRUNC):
                    raise ValueError('Truncated fd/metadata response')
                if not data:
                    raise ValueError('Response ended before metadata newline')
                payload += data
                if len(payload) > 16384:
                    raise ValueError('Oversized metadata response')
            line, trailing = payload.split(b'\n', 1)
            if trailing:
                raise ValueError('Unexpected data following metadata')
        if len(descriptors) != 1:
            raise ValueError(f'Expected exactly one fd, received {len(descriptors)}')
        metadata = json.loads(line)
        fd = descriptors[0]
        os.set_inheritable(fd, False)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('Received fd is not a regular file')
        if metadata.get('version') != 1 or metadata.get('capacity') != CAPACITY:
            raise ValueError('Unsupported metadata version/capacity')
        if (info.st_size != CAPACITY or info.st_ino != metadata.get('inode') or
                info.st_dev != metadata.get('device') or info.st_uid != metadata.get('owner_uid')):
            raise ValueError('Received fd does not match metadata')
        seals = fcntl.fcntl(fd, fcntl.F_GET_SEALS)
        required = fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW
        denied = fcntl.F_SEAL_WRITE | getattr(fcntl, 'F_SEAL_FUTURE_WRITE', 0x10)
        if seals & required != required or seals & denied:
            raise ValueError(f'Unexpected memfd seals: {seals}')
        metadata['seals'] = seals
        descriptors.clear()
        return fd, metadata
    finally:
        for fd in descriptors:
            os.close(fd)


def inspect(fd):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                         ctypes.c_int, ctypes.c_int, ctypes.c_longlong]
    libc.mmap.restype = ctypes.c_void_p
    libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    libc.mincore.restype = ctypes.c_int
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    libc.munmap.restype = ctypes.c_int
    address = libc.mmap(None, CAPACITY, 1, 1, fd, 0)
    if address == ctypes.c_void_p(-1).value:
        raise OSError(ctypes.get_errno(), 'mmap')
    try:
        page = os.sysconf('SC_PAGE_SIZE')
        if CHUNK % page:
            raise ValueError('64 MiB chunks must be page aligned')
        vector = (ctypes.c_ubyte * (CAPACITY // page))()
        if libc.mincore(address, CAPACITY, vector):
            raise OSError(ctypes.get_errno(), 'mincore')
        chunks = []
        for offset in range(0, CAPACITY, CHUNK):
            count = sum(vector[i] & 1 for i in range(offset // page, (offset + CHUNK) // page)) * page
            chunks.append({'offset': offset, 'bytes': CHUNK, 'resident_bytes': count})
        return {'resident_bytes': sum(c['resident_bytes'] for c in chunks),
                'chunks': chunks, 'pixel_bytes_read': 0, 'residency_is_pin_proof': False}
    finally:
        if libc.munmap(address, CAPACITY):
            raise OSError(ctypes.get_errno(), 'munmap')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if command and not any(TOKEN in part for part in command):
        parser.error('Command must contain @VIEWFLOW_DMA_FD@')
    report = {'status': 'failed', 'scope': 'scratch memfd client'}
    fd = None
    result = 1
    try:
        fd, report['metadata'] = receive(args.socket)
        report['before'] = inspect(fd)
        if command:
            command = [part.replace(TOKEN, str(fd)) for part in command]
            # Child output remains stderr so stdout contains one JSON record.
            child = subprocess.run(command, pass_fds=(fd,), stdout=2, check=False)
            report['child_returncode'] = child.returncode
            result = child.returncode if child.returncode >= 0 else 128 - child.returncode
            report['after'] = inspect(fd)
        else:
            result = 0
        report['status'] = 'passed' if result == 0 else 'child_failed'
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
        result = 1
    finally:
        if fd is not None:
            os.close(fd)
    print(json.dumps(report, indent=2))
    return result


if __name__ == '__main__':
    raise SystemExit(main())
