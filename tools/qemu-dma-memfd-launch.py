#!/usr/bin/env python3
"""Experimental single scratch-bank keeper; launches only an explicit child command."""
import argparse
import array
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys

TOKEN = '@VIEWFLOW_DMA_MEMFD@'
CAPACITY = 1 << 30


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', required=True, help='New Unix socket path; existing paths rejected')
    parser.add_argument('--owner-uid', type=int, default=os.getuid())
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not any(TOKEN in part for part in command):
        parser.error('Explicit child command must contain @VIEWFLOW_DMA_MEMFD@')
    if args.owner_uid < 0 or (os.geteuid() != 0 and args.owner_uid != os.getuid()):
        parser.error('Non-root callers may select only their own UID')
    path = os.path.abspath(args.socket)
    if os.path.lexists(path):
        parser.error('Socket path already exists; refusing to remove it')
    fd = None
    listener = None
    child = None
    identity = None
    clients = {}
    pending_signals = []
    previous = {}

    def forward(signum, _frame):
        if child is not None and child.poll() is None:
            child.send_signal(signum)
        else:
            pending_signals.append(signum)

    try:
        fd = os.memfd_create('viewflow-dma-scratch', os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
        os.ftruncate(fd, CAPACITY)
        os.fchown(fd, args.owner_uid, -1)
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW)
        info = os.fstat(fd)
        metadata = json.dumps({'version': 1, 'capacity': CAPACITY, 'inode': info.st_ino,
                               'device': info.st_dev, 'owner_uid': info.st_uid}).encode() + b'\n'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        mask = os.umask(0o177)
        try:
            listener.bind(path)
        finally:
            os.umask(mask)
        st = os.lstat(path)
        identity = (st.st_dev, st.st_ino)
        os.chown(path, args.owner_uid, -1)
        os.chmod(path, 0o600)
        listener.listen(8)
        listener.setblocking(False)
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            previous[signum] = signal.signal(signum, forward)
        command = [part.replace(TOKEN, f'/proc/self/fd/{fd}') for part in command]
        child = subprocess.Popen(command, pass_fds=(fd,))
        for signum in pending_signals:
            if child.poll() is None:
                child.send_signal(signum)
        while child.poll() is None:
            ready, _, _ = select.select([listener, *clients], [], [], .2)
            for channel in ready:
                if channel is listener:
                    connection, _ = listener.accept()
                    connection.setblocking(False)
                    if len(clients) >= 32:
                        connection.close()
                    else:
                        clients[connection] = b''
                    continue
                try:
                    part = channel.recv(4 - len(clients[channel]))
                    if not part:
                        channel.close()
                        del clients[channel]
                        continue
                    request = clients[channel] + part
                    clients[channel] = request
                    if request in (b'GET', b'GET\n'):
                        # A small response fits Unix socket buffers; send rights once.
                        count = channel.sendmsg([metadata], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                                             array.array('i', [fd]))])
                        if count != len(metadata):
                            print('scratch fd response was incomplete', file=sys.stderr)
                        channel.close()
                        del clients[channel]
                    elif not b'GET\n'.startswith(request):
                        channel.close()
                        del clients[channel]
                except (OSError, KeyError):
                    channel.close()
                    clients.pop(channel, None)
        result = child.wait()
        return result if result >= 0 else 128 - result
    finally:
        # Never force-kill or act on other processes. If setup after spawn failed,
        # retain the backing until this same child exits.
        if child is not None and child.poll() is None:
            child.wait()
        for channel in clients:
            channel.close()
        if listener is not None:
            listener.close()
        if identity is not None:
            try:
                st = os.lstat(path)
                if (st.st_dev, st.st_ino) == identity:
                    os.unlink(path)
            except FileNotFoundError:
                pass
        if fd is not None:
            os.close(fd)
        for signum, handler in previous.items():
            signal.signal(signum, handler)


if __name__ == '__main__':
    raise SystemExit(main())
