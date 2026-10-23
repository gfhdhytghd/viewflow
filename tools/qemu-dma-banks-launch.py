#!/usr/bin/env python3
"""Experimental four-bank keeper. Explicit control file, child command and QMP only."""
import argparse
import array
import ctypes
import fcntl
import json
import mmap
import os
import platform
import secrets
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import time

CAPACITY = 1 << 30
SEGMENT = 64 << 20
OFFSET = 2048
MAGIC = 0x31414D4442465656
BANK_MAGIC = 0x324B4E4142465656
HEADER = struct.Struct('<QIIQQIIII4Q4Q2Q')


def load64(control, offset):
    return ctypes.c_uint64.from_buffer(control, offset).value


def store64(control, offset, value):
    # Aligned single native uint64 store, supported only on x86-64 here.
    ctypes.c_uint64.from_buffer(control, offset).value = value


def initialize(control, fds, generation, bus, first_slot):
    if len(control) != 1 << 20:
        raise ValueError('Control extent must be exactly 1 MiB')
    old = struct.unpack_from('<QQI4II', control, 1024)
    if old[0] != BANK_MAGIC or old[1] != CAPACITY:
        raise ValueError('Existing BankLayout magic/capacity mismatch')
    infos = [os.fstat(fd) for fd in fds]
    extension = HEADER.pack(MAGIC, 1, 1, generation, CAPACITY, SEGMENT, 16,
                            bus, first_slot, *(v.st_dev for v in infos),
                            *(v.st_ino for v in infos), 0, 0) + bytes(192)
    control[OFFSET:OFFSET+320] = extension
    struct.pack_into('<I', control, 1024+36, 6)
    control.flush()
    return {'version': 2, 'generation': generation, 'capacity': CAPACITY,
            'owner_uid': infos[0].st_uid, 'devices': [v.st_dev for v in infos],
            'inodes': [v.st_ino for v in infos]}


class MappingPump:
    def __init__(self, control, path, retry=1.):
        self.control, self.path, self.retry = control, path, retry
        self.connection = None
        self.buffer = b''
        self.sequence = 0
        self.next_attempt = {}

    def close(self):
        if self.connection:
            self.connection.close()
        self.connection = None
        self.buffer = b''

    def receive(self):
        while b'\n' not in self.buffer:
            part = self.connection.recv(65536)
            if not part:
                raise ConnectionError('QMP disconnected')
            self.buffer += part
            if len(self.buffer) > 1 << 20:
                raise ValueError('Oversized QMP response')
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)

    def command(self, name, arguments=None):
        self.sequence += 1
        message = {'execute': name, 'id': self.sequence}
        if arguments is not None:
            message['arguments'] = arguments
        self.connection.sendall(json.dumps(message).encode()+b'\n')
        while True:
            response = self.receive()
            if 'event' in response:
                continue
            if response.get('id') != self.sequence:
                raise ValueError('Unexpected QMP response ID')
            if 'error' in response:
                raise RuntimeError(str(response['error']))
            return response.get('return')

    def connect(self):
        if self.connection is not None:
            return
        self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.connection.settimeout(.5)
        self.connection.connect(self.path)
        if 'QMP' not in self.receive():
            raise ValueError('Invalid QMP greeting')
        self.command('qmp_capabilities')

    def poll_interval(self):
        now = time.monotonic()
        for bank in range(4):
            pending = (load64(self.control, OFFSET+128+bank*8) & 0xffff) & ~load64(self.control, OFFSET+192+bank*8)
            if any(pending & (1 << segment) and now >= self.next_attempt.get((bank, segment), 0)
                   for segment in range(16)):
                return .001
        return .05

    def step(self):
        now = time.monotonic()
        for bank in range(4):
            request = load64(self.control, OFFSET+128+bank*8) & 0xffff
            ready = load64(self.control, OFFSET+192+bank*8)
            for segment in range(16):
                bit = 1 << segment
                if not request & bit or ready & bit or now < self.next_attempt.get((bank, segment), 0):
                    continue
                try:
                    self.connect()
                    self.command('qom-set', {'path': f'/objects/viewflow_dma_bank{bank}_segment{segment}',
                                 'property': 'x-viewflow-dma-prefix', 'value': SEGMENT})
                    ready |= bit
                    store64(self.control, OFFSET+192+bank*8, ready)
                    failed = load64(self.control, OFFSET+256+bank*8)
                    store64(self.control, OFFSET+256+bank*8, failed & ~bit)
                except (OSError, ValueError, RuntimeError) as error:
                    failed = load64(self.control, OFFSET+256+bank*8)
                    store64(self.control, OFFSET+256+bank*8, failed | bit)
                    self.next_attempt[(bank, segment)] = now + self.retry
                    self.close()
                    print(f'DMA mapping pending bank={bank} segment={segment}: {error}', file=sys.stderr)
                # One operation per poll keeps fd service and signal handling responsive.
                return


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--control', required=True)
    p.add_argument('--socket', required=True)
    p.add_argument('--qmp', required=True)
    p.add_argument('--owner-uid', type=int, default=os.getuid())
    p.add_argument('--bus', type=int, default=0)
    p.add_argument('--first-slot', type=int, default=10)
    p.add_argument('command', nargs=argparse.REMAINDER)
    args = p.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if platform.machine().lower() not in ('x86_64', 'amd64'):
        p.error('Shared atomic mask ABI requires x86-64')
    if not command or any(not any(f'@VIEWFLOW_DMA_BANK{b}@' in s for s in command) for b in range(4)):
        p.error('Explicit command must contain all four bank tokens')
    if not 0 <= args.bus <= 255 or not 10 <= args.first_slot <= 24:
        p.error('Invalid bus/first-slot')
    if args.owner_uid < 0 or (os.geteuid() and args.owner_uid != os.getuid()):
        p.error('Invalid owner UID')
    path = os.path.abspath(args.socket)
    if os.path.lexists(path):
        p.error('Socket already exists')
    controlfd = os.open(args.control, os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW)
    banks, clients, handlers = [], {}, {}
    control = listener = child = pump = None
    identity = None
    keeperfd = None
    pending = []
    def forward(number, _frame):
        if child is not None and child.poll() is None:
            child.send_signal(number)
        else:
            pending.append(number)
    try:
        info = os.fstat(controlfd)
        if not stat.S_ISREG(info.st_mode) or info.st_size != 1 << 20 or info.st_uid != args.owner_uid:
            raise ValueError('Control must be owner-owned regular 1 MiB file')
        # Separate persistent inode: never unlink a flock file while another
        # keeper may have it open, and leave the receiver's control lock free.
        keeperfd = os.open(path+'.lock', os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
        lockinfo = os.fstat(keeperfd)
        if not stat.S_ISREG(lockinfo.st_mode) or lockinfo.st_uid not in (os.geteuid(), args.owner_uid):
            raise ValueError('Invalid keeper lock owner/type')
        fcntl.flock(keeperfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.fchmod(keeperfd, 0o600)
        control = mmap.mmap(controlfd, info.st_size)
        for bank in range(4):
            fd = os.memfd_create(f'viewflow-dma-bank{bank}', os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
            banks.append(fd)
            os.ftruncate(fd, CAPACITY)
            os.fchown(fd, args.owner_uid, -1)
            fcntl.fcntl(fd, fcntl.F_ADD_SEALS, fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW)
            command = [s.replace(f'@VIEWFLOW_DMA_BANK{bank}@', f'/proc/self/fd/{fd}') for s in command]
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        previous = os.umask(0o177)
        try:
            listener.bind(path)
        finally:
            os.umask(previous)
        info = os.lstat(path)
        identity = info.st_dev, info.st_ino
        os.chown(path, args.owner_uid, -1)
        os.chmod(path, 0o600)
        listener.listen(8)
        listener.setblocking(False)
        generation = secrets.randbits(64) or 1
        metadata = initialize(control, banks, generation, args.bus, args.first_slot)
        response = json.dumps(metadata).encode()+b'\n'
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            handlers[number] = signal.signal(number, forward)
        child = subprocess.Popen(command, pass_fds=tuple(banks))
        for number in pending:
            if child.poll() is None:
                child.send_signal(number)
        pump = MappingPump(control, args.qmp)
        while child.poll() is None:
            readable, _, _ = select.select([listener, *clients], [], [], pump.poll_interval())
            for channel in readable:
                if channel is listener:
                    connection, _ = listener.accept()
                    connection.setblocking(False)
                    if len(clients) < 32:
                        clients[connection] = b''
                    else:
                        connection.close()
                    continue
                try:
                    part = channel.recv(4-len(clients[channel]))
                    request = clients[channel]+part
                    clients[channel] = request
                    if request in (b'GET', b'GET\n'):
                        count = channel.sendmsg([response], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                                             array.array('i', banks))])
                        if count != len(response):
                            print('Incomplete bank fd response', file=sys.stderr)
                    elif part and b'GET\n'.startswith(request):
                        continue
                except OSError:
                    pass
                channel.close()
                del clients[channel]
            pump.step()
        result = child.wait()
        return result if result >= 0 else 128-result
    finally:
        if child is not None and child.poll() is None:
            child.wait()
        if pump:
            pump.close()
        for channel in clients:
            channel.close()
        if listener:
            listener.close()
        if identity:
            try:
                info = os.lstat(path)
                if (info.st_dev, info.st_ino) == identity:
                    os.unlink(path)
            except FileNotFoundError:
                pass
        if control:
            control.close()
        for fd in banks:
            os.close(fd)
        os.close(controlfd)
        if keeperfd is not None:
            os.close(keeperfd)
        for number, handler in handlers.items():
            signal.signal(number, handler)


if __name__ == '__main__':
    raise SystemExit(main())
