#!/usr/bin/python3
"""Launch the stable GUI input app and terminate its exact launcher on stop."""
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile


def main():
    app = Path.home() / 'Applications/Viewflow Input.app'
    state = Path.home() / '.local/state/viewflow/input'
    state.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='viewflow-input-') as directory:
        pidfile = Path(directory) / 'pid'
        def stop(*_):
            try:
                pid = int(pidfile.read_text())
                command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'command='], text=True)
                if str(app / 'Contents/MacOS/ViewflowInputLauncher') in command:
                    os.kill(pid, signal.SIGTERM)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        child = subprocess.Popen(['open', '-W', '-n', '-g', '-j',
            '--stdout', str(state / 'stdout.log'), '--stderr', str(state / 'stderr.log'),
            str(app), '--args', str(pidfile), *sys.argv[1:]])
        return child.wait()


if __name__ == '__main__':
    raise SystemExit(main())
