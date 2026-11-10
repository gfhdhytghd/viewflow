#!/usr/bin/env python3
"""Supervise one transport route inside the GUI's only connection group."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--peer-platform', choices=('linux', 'windows', 'macos'), required=True)
    parser.add_argument('--window-remote', required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--route', help='isolated group input route')
    args = parser.parse_args()
    stopping = False
    children = []
    def stop(*_):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    scripts = Path(__file__).resolve().parent
    app = args.bundle / 'Viewflow'
    def script(name, *options):
        if getattr(sys, 'frozen', False):
            return [str(app), '--run-script', name, *map(str, options)]
        names = {'desktop-autostart-linux': 'desktop-autostart-linux.py', 'linux-window-share': 'macos-window-share-linux.py',
                 'group-input-route': 'multiscreen-input-linux.py'}
        return [sys.executable, str(scripts / names[name]), *map(str, options)]
    args.runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    state = args.runtime / 'desktop'
    try:
        while not stopping:
            try:
                monitors = json.loads(subprocess.check_output(['hyprctl', '-j', 'monitors'], timeout=5))
                monitor = next(m for m in monitors if not m['name'].startswith(('HEADLESS-', 'viewflow-')) and not m.get('disabled'))
                break
            except (OSError, ValueError, StopIteration, subprocess.SubprocessError): time.sleep(1)
        if stopping: return
        peer = args.bundle / 'bin' / ('vf-media-peer' if args.peer_platform == 'windows' else 'vf-cursor-peer')
        if args.route:
            commands = [script('group-input-route', '--config', args.config, '--route', args.route,
                '--monitor', monitor['name'], '--peer', peer, '--state-dir', state, '--bundle', args.bundle)]
        else:
            commands = [script('desktop-autostart-linux', '--config', args.config, '--monitor', monitor['name'],
                               '--peer', peer, '--state-dir', state)]
        if args.peer_platform != 'windows':
            commands.append(script('linux-window-share', '--route-config', state / 'config',
                '--remote', args.window_remote, '--peer', args.bundle / 'bin/vf-window-peer',
                '--source', args.bundle / 'bin/vf-hyprland-windows',
                '--input-native', args.bundle / 'bin/viewflow-linux-window-input', '--runtime', args.runtime / 'windows'))
        children = [None] * len(commands)
        shortcut_ready = None
        while not stopping:
            # GUI startup can precede plugin load. Read back the plugin's
            # active physical-key chord after the route loader has run.
            try:
                result = subprocess.check_output(['hyprctl', 'repl',
                    'return hl.plugin.viewflow.recall_shortcut()'], text=True, timeout=5).strip()
                if result != shortcut_ready and '+' in result and 'error' not in result.lower():
                    print('Window recall shortcut ready: ' + result, flush=True)
                    shortcut_ready = result
            except (OSError, subprocess.SubprocessError): pass
            for index, command in enumerate(commands):
                if children[index] is None or children[index].poll() is not None:
                    children[index] = subprocess.Popen(command)
            time.sleep(1)
    finally:
        for child in children:
            if child is not None and child.poll() is None: child.terminate()
        for child in children:
            if child is not None:
                try: child.wait(timeout=20)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
        # Only our explicit per-pair directory is eligible for cleanup.
        if state.exists() and not args.route:
            subprocess.run([str(scripts / 'desktop-drag-linux.sh'), 'stop', '--state-dir', str(state)], timeout=30)


if __name__ == '__main__': main()
