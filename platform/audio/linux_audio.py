#!/usr/bin/env python3
"""Viewflow PulseAudio/PipeWire PCM helper.

capture --scope system, or capture --scope application --pid PID [...].
Only capture uses a private sink. Playback streams are always excluded from
capture; no global/default sink is changed. stdin EOF releases capture routes.
"""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import uuid

APP_ID = 'org.viewflow.audio.playback'


def pactl(*args):
    return subprocess.check_output(['pactl', *map(str, args)], text=True, timeout=3).strip()


def inputs():
    return json.loads(pactl('--format=json', 'list', 'sink-inputs'))


def sinks():
    return {int(s['index']): s['name'] for s in json.loads(pactl('--format=json', 'list', 'sinks'))}


def selected(stream, scope, pids):
    props = stream.get('properties', {})
    if props.get('application.id') == APP_ID or props.get('application.name') == 'Viewflow playback':
        return False
    if scope == 'system':
        return True
    return str(props.get('application.process.id', '')) in pids


def process_identity(pid):
    try:
        fields = Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()
        return int(fields[1]), fields[19]  # parent PID and process start ticks
    except (OSError, ValueError, IndexError):
        return None


def application_processes(roots):
    """Include audio subprocesses while rejecting a reused source PID."""
    valid = set()
    for pid, identity in roots.items():
        current = process_identity(pid)
        if identity is not None and current is not None and current[1] == identity[1]:
            valid.add(pid)
    found = set()
    for path in Path('/proc').iterdir():
        if not path.name.isdigit(): continue
        pid = int(path.name)
        current = pid
        for _ in range(64):
            if current in valid:
                found.add(str(pid)); break
            info = process_identity(current)
            if not info or info[0] <= 1 or info[0] == current: break
            current = info[0]
    return found


class Capture:
    def __init__(self, scope, pids):
        self.scope, self.pids = scope, set(map(str, pids))
        self.roots = {pid: process_identity(pid) for pid in pids}
        self.name = 'viewflow.audio.' + uuid.uuid4().hex
        self.module = None
        self.original = {}
        self.reader = None

    def reconcile(self):
        outputs = sinks()
        pids = application_processes(self.roots) if self.scope == 'application' else self.pids
        for stream in inputs():
            index = int(stream['index'])
            sink = outputs.get(int(stream['sink']))
            if sink == self.name:
                continue
            if not sink or sink.startswith(('viewflow.audio.', 'viewflow.family.')) or not selected(stream, self.scope, pids):
                continue
            # Keep the actual host target; applications may intentionally change
            # output while forwarding. Restore the most recent observed choice.
            self.original[index] = sink
            pactl('move-sink-input', index, self.name)

    def start(self):
        self.module = int(pactl('load-module', 'module-null-sink', 'sink_name=' + self.name,
                                'rate=48000', 'channels=2', 'format=s16le',
                                'sink_properties=device.description=Viewflow-Audio'))
        self.reader = subprocess.Popen(['parec', '--raw', '--format=s16le', '--rate=48000',
                                        '--channels=2', '--latency-msec=10',
                                        '--device=' + self.name + '.monitor'],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
        self.reconcile()

    def close(self):
        if self.reader:
            self.reader.terminate()
            try: self.reader.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.reader.kill(); self.reader.wait()
        if self.module is None:
            return
        failures = []
        outputs = sinks()
        default = pactl('get-default-sink')
        for stream in inputs():
            index = int(stream['index'])
            if outputs.get(int(stream['sink'])) != self.name:
                continue
            destination = self.original.get(index, default)
            if destination not in outputs.values(): destination = default
            try: pactl('move-sink-input', index, destination)
            except Exception as error: failures.append(str(error))
        # Unloading the private sink also lets the server rescue streams that
        # raced the enumeration. Never unload modules owned by another helper.
        pactl('unload-module', self.module)
        self.module = None
        if failures: print('audio restore: ' + '; '.join(failures), file=sys.stderr)


def capture(args):
    active = Capture(args.scope, args.pid)
    try:
        active.start()
        deadline = time.monotonic()
        while True:
            ready, _, _ = select.select([sys.stdin.buffer, active.reader.stdout], [], [], 0.1)
            if sys.stdin.buffer in ready and not os.read(sys.stdin.fileno(), 1024): break
            if active.reader.stdout in ready:
                data = os.read(active.reader.stdout.fileno(), 3840)
                if not data: raise RuntimeError('PulseAudio capture ended')
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            if time.monotonic() >= deadline:
                active.reconcile()
                deadline = time.monotonic() + 0.25
    finally:
        active.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['capture', 'playback'])
    parser.add_argument('--scope', choices=['system', 'application'], default='application')
    parser.add_argument('--pid', type=int, action='append', default=[])
    args = parser.parse_args()
    if args.operation == 'playback':
        os.execvp('pacat', ['pacat', '--playback', '--raw', '--format=s16le', '--rate=48000',
                            '--channels=2', '--latency-msec=20', '--client-name=Viewflow playback',
                            '--property=application.id=' + APP_ID])
    if args.scope == 'application' and not args.pid:
        parser.error('application capture requires --pid')
    def stop(_signum, _frame): raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    capture(args)


if __name__ == '__main__':
    main()
