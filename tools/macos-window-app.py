#!/usr/bin/python3
"""Run the authorized Mac app via Launch Services with bounded FIFO stdio."""
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time


def copy_fd(source, target):
    try:
        while True:
            data = os.read(source, 65536)
            if not data:
                break
            view = memoryview(data)
            while view:
                view = view[os.write(target, view):]
    except OSError:
        pass


def main():
    app = Path(os.environ.get('VIEWFLOW_MACOS_SOURCE_APP',
                              str(Path.home() / 'Applications/Viewflow Window Sharing.app')))
    probe = sys.argv[1:] in (['--permissions'], ['--list-windows'])
    if not app.is_dir():
        raise FileNotFoundError(app)
    with tempfile.TemporaryDirectory(prefix='viewflow-app-') as directory:
        paths = [Path(directory) / name for name in ('stdin', 'stdout', 'stderr')]
        for path in paths:
            os.mkfifo(path, 0o600)
        incoming = os.open(paths[0], os.O_RDWR)
        readers = [os.open(path, os.O_RDONLY | os.O_NONBLOCK) for path in paths[1:]]
        guards = [os.open(path, os.O_WRONLY | os.O_NONBLOCK) for path in paths[1:]]
        for fd in readers:
            os.set_blocking(fd, True)
        closed = False
        disconnected = threading.Event()
        pidfile = Path(directory) / 'owner.pid'
        lock = threading.RLock()

        def close_input(*_args):
            nonlocal closed
            with lock:
                if not closed:
                    closed = True
                    if not probe:
                        # A readable terminal frame also wakes Darwin FIFO poll
                        # when closing the last writer alone does not. The native
                        # reader treats length zero as terminal, then releases its
                        # owned input. This is framing, never an input event.
                        try:
                            os.write(incoming, b'\0\0\0\0')
                        except OSError:
                            pass
                    os.close(incoming)
                    disconnected.set()

        def reap_disconnected():
            disconnected.wait()
            # This watchdog starts only after transport EOF or explicit stop,
            # never because a frame is late. Give native teardown time first.
            time.sleep(10)
            try:
                pid = int(pidfile.read_text())
                command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'command='], text=True)
                if str(pidfile) in command and str(app / 'Contents/MacOS/viewflow-macos-windows') in command:
                    os.kill(pid, signal.SIGTERM)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass

        def forward_input():
            def read_exact(size):
                data = bytearray()
                while len(data) < size:
                    part = os.read(0, size - len(data))
                    if not part:
                        return None
                    data.extend(part)
                return bytes(data)
            try:
                while True:
                    prefix = read_exact(4)
                    if prefix is None:
                        break
                    size = struct.unpack('<I', prefix)[0]
                    # Matches the native framed protocol's allocation ceiling.
                    if size < 4 or size > 96 * 1024 * 1024:
                        break
                    payload = read_exact(size)
                    if payload is None:
                        break
                    # Never append termination inside a partially forwarded
                    # record, including when SIGTERM interrupts this adapter.
                    with lock:
                        if closed:
                            break
                        view = memoryview(prefix + payload)
                        while view:
                            view = view[os.write(incoming, view):]
            except OSError:
                pass
            finally:
                close_input()

        signal.signal(signal.SIGTERM, close_input)
        signal.signal(signal.SIGINT, close_input)
        output_threads = [threading.Thread(target=copy_fd, args=(fd, target), daemon=True)
                          for fd, target in zip(readers, (1, 2))]
        for thread in output_threads:
            thread.start()
        # Launch Services preserves the user-authorized app identity. Hidden,
        # background launch does not activate it or alter desktop focus.
        wait_args = [] if probe else ['-W']
        process = subprocess.Popen(['/usr/bin/open', '-n', '-g', '-j', *wait_args, '-a', str(app),
                                    '--stdin', str(paths[0]), '--stdout', str(paths[1]),
                                    '--stderr', str(paths[2]), '--args', '--owner-pid', str(os.getpid()),
                                    '--owner-pid-file', str(pidfile), *sys.argv[1:]],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        threading.Thread(target=forward_input, daemon=True).start()
        if not probe:
            threading.Thread(target=reap_disconnected, daemon=True).start()
        try:
            result = process.wait()
        finally:
            close_input()
            for fd in guards:
                os.close(fd)
            for thread in output_threads:
                thread.join(timeout=20 if probe else 2)
            for fd in readers:
                os.close(fd)
        return result


if __name__ == '__main__':
    sys.exit(main())
