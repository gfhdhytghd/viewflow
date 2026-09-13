#!/usr/bin/env python3
"""Supervise Mac native windows on a paired link without recapturing proxies."""
import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import time


def eligible(window):
    if not window.get('on_screen') or window.get('layer') != 0:
        return False
    if not isinstance(window.get('window_id'), int) or window['window_id'] <= 0:
        return False
    if not isinstance(window.get('pid'), int) or window['pid'] <= 0:
        return False
    # Different incoming connections use different native processes. Excluding
    # only this supervisor's PID would feed their proxies back into the mesh.
    if window.get('bundle_id', '').startswith('org.viewflow.'):
        return False
    if any(window.get(field, '').startswith('viewflow-macos-windows')
           for field in ('application_name', 'executable_name')):
        return False
    bounds = window.get('frame_points', [])
    return (len(bounds) == 4 and all(isinstance(v, (int, float)) and math.isfinite(v) for v in bounds)
            and bounds[2] > 0 and bounds[3] > 0)


def needs_remote(window, physical, remote):
    frame = window['frame_points']
    def intersect(a, b):
        x, y = max(a[0], b[0]), max(a[1], b[1])
        w, h = min(a[0]+a[2], b[0]+b[2])-x, min(a[1]+a[3], b[1]+b[3])-y
        return (x, y, w, h) if w > 0 and h > 0 else None
    if not any(intersect(frame, region) for region in remote):
        return False
    uncovered = [frame]
    for display in physical:
        remaining = []
        for part in uncovered:
            hit = intersect(part, display)
            if not hit:
                remaining.append(part)
                continue
            x, y, w, h = part
            hx, hy, hw, hh = hit
            remaining.extend(rect for rect in [(x, y, w, hy-y), (x, hy+hh, w, y+h-hy-hh),
                                               (x, hy, hx-x, hh), (hx+hw, hy, x+w-hx-hw, hh)]
                             if rect[2] > 0 and rect[3] > 0)
        uncovered = remaining
    return bool(uncovered)


def selected_windows(report, existing, limit):
    if report.get('schema_version') != 1 or report.get('enumeration') != 'ok':
        raise ValueError(report.get('enumeration', 'invalid native inventory'))
    physical, remote = report.get('physical_displays'), report.get('remote_displays')
    if (not isinstance(physical, list) or not isinstance(remote, list) or
            any(not isinstance(r, list) or len(r) != 4 or
                not all(isinstance(v, (int, float)) and math.isfinite(v) for v in r) or
                r[2] <= 0 or r[3] <= 0 for r in physical + remote)):
        raise ValueError('display geometry unavailable; retain existing window connections')
    live = {(w['window_id'], w['pid']): w for w in report.get('windows', [])
            if eligible(w) and needs_remote(w, physical, remote)}
    # Retain current selections when inventory order changes at the window limit.
    ordered = [key for key in existing if key in live]
    ordered += sorted(key for key in live if key not in existing)
    return {key: live[key] for key in ordered[:limit]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--template', type=Path, required=True)
    parser.add_argument('--peer', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--max-windows', type=int, default=8)
    parser.add_argument('--validate', action='store_true')
    args = parser.parse_args()
    template = json.loads(args.template.read_text())
    backend = template['backend']
    native = Path(backend['native'])
    if (template.get('role') != 'source' or not template.get('remote') or not native.is_absolute()
            or not args.peer.is_absolute() or not args.runtime.is_absolute()
            or not 1 <= args.max_windows <= 32 or '--window' in backend.get('args', [])
            or not backend.get('args') or backend['args'][0] != 'source'):
        raise ValueError('expected a connecting native Mac source template without a fixed window')
    if args.validate:
        print('macos-window-source-template-valid')
        return
    args.runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    stopped = False
    children = {}
    retiring = []

    def stop(_signal, _frame):
        nonlocal stopped
        stopped = True

    def retire(child):
        process, log = child
        if process.poll() is None:
            process.terminate()  # Paired peer closes native stdin; held input releases.
            retiring.append((time.monotonic(), process, log))
        else:
            log.close()

    def reap():
        for item in list(retiring):
            since, process, log = item
            if process.poll() is None and time.monotonic() - since > 15:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            if process.poll() is not None:
                log.close()
                retiring.remove(item)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last_error = None
    try:
        while not stopped:
            try:
                result = subprocess.run([str(native), '--list-windows'], capture_output=True, text=True, timeout=20)
                report = json.loads(result.stdout)
                live = selected_windows(report, children, args.max_windows)
                for key in list(children):
                    if key not in live or children[key][0].poll() is not None:
                        retire(children.pop(key))
                        print(f'mac-window retired id={key[0]} pid={key[1]}', flush=True)
                for key in live:
                    if key in children or len(children) + len(retiring) >= args.max_windows:
                        continue
                    config = dict(template, backend=dict(backend, args=backend['args'] + ['--window', str(key[0])]))
                    path = args.runtime / f'{key[0]}-{key[1]}.json'
                    path.write_text(json.dumps(config, indent=2) + '\n')
                    path.chmod(0o600)
                    log = path.with_suffix('.log').open('ab')
                    try:
                        child = subprocess.Popen([str(args.peer), '--config', str(path)],
                                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    except Exception:
                        log.close()
                        raise
                    children[key] = (child, log)
                    print(f'mac-window started id={key[0]} pid={key[1]} peer={child.pid}', flush=True)
                last_error = None
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                # Missing OS permission or transient enumeration failure leaves
                # unrelated established sources alone and retries locally.
                if str(error) != last_error:
                    print(f'mac-window inventory waiting: {error}', flush=True)
                    last_error = str(error)
            reap()
            for _ in range(10):
                if stopped:
                    break
                time.sleep(0.1)
    finally:
        for child in children.values():
            retire(child)
        while retiring:
            reap()
            time.sleep(0.1)


if __name__ == '__main__':
    main()
