#!/usr/bin/env python3
"""Share windows intersecting the active Mac viewport; never move or focus them."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def eligible(client, monitors, remote_id):
    remote = next((m for m in monitors if m['id'] == remote_id), None)
    if not remote or not client.get('mapped', False) or client.get('hidden', False):
        return False
    if client.get('class', '').startswith('ViewflowReverse-'):
        return False
    # Scrolling columns extend beyond their owning monitor in global coordinates.
    # Those overflow pixels are clipped by Hyprland, not windows on the Mac.
    # Floating windows still cross displays normally; active native drags are
    # retained separately below until Hyprland finishes transferring ownership.
    if (client.get('fullscreenHandler') == 'scrolling'
            and not client.get('floating', False)
            and client.get('monitor') != remote_id):
        return False
    visible = {m['activeWorkspace']['id'] for m in monitors}
    visible.update(m['specialWorkspace']['id'] for m in monitors
                   if m.get('specialWorkspace', {}).get('id', 0))
    if client.get('workspace', {}).get('id') not in visible:
        return False
    width, height = remote['width'], remote['height']
    if remote.get('transform', 0) % 2:
        width, height = height, width
    rx, ry = remote['x'], remote['y']
    rw, rh = width / remote['scale'], height / remote['scale']
    x, y = client['at']
    w, h = client['size']
    return w > 0 and h > 0 and x < rx + rw and x + w > rx and y < ry + rh and y + h > ry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--route-config', type=Path, required=True)
    parser.add_argument('--peer', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--input-native', type=Path, required=True)
    parser.add_argument('--remote', default='172.16.105.83:44220')
    parser.add_argument('--performance-mode', choices=('frame-rate', 'latency'),
                        default=os.environ.get('VIEWFLOW_WINDOW_PERFORMANCE_MODE', 'frame-rate'))
    args = parser.parse_args()
    runtime = Path(os.environ['XDG_RUNTIME_DIR']) / 'viewflow' / 'macos-windows'
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    stopped = False
    children = {}
    retiring = []

    def stop(_sig, _frame):
        nonlocal stopped
        stopped = True

    def retire(child):
        process, log = child
        if process.poll() is None:
            process.terminate()  # Peer closes QUIC; native input releases on EOF.
            retiring.append((time.monotonic(), process, log))
        else:
            log.close()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last_error = None
    session = None
    try:
        while not stopped:
            try:
                route = json.loads(args.route_config.read_text())
                if route['remote'].rsplit(':', 1)[0] != args.remote.rsplit(':', 1)[0]:
                    raise ValueError('active input target is not the Mac window receiver')
                socket = Path(route['desktop']['hyprland_socket'])
                os.environ['HYPRLAND_INSTANCE_SIGNATURE'] = socket.parent.name
                current_session = (socket.parent.name, route['compositor_pid'])
                if session != current_session:
                    instances = json.loads(subprocess.check_output(['hyprctl', '-j', 'instances'], timeout=3))
                    instance = next((item for item in instances if
                        (item['instance'], item['pid']) == current_session), None)
                    if instance is None:
                        raise ValueError('waiting for the configured compositor session')
                    os.environ['WAYLAND_DISPLAY'] = instance['wl_socket']
                    session = current_session
                monitors = json.loads(subprocess.check_output(['hyprctl', '-j', 'monitors'], timeout=3))
                clients = json.loads(subprocess.check_output(['hyprctl', '-j', 'clients'], timeout=3))
                live = {(w['address'], w['pid'], w['stableId']): w for w in clients
                        if eligible(w, monitors, route['pointer']['cursor_monitor_id'])}
                # Keep a source alive while Hyprland owns its native drag,
                # including the last pixels beyond the viewport on return.
                try:
                    status = json.loads(subprocess.check_output(
                        ['hyprctl', 'repl', 'return hl.plugin.viewflow.capture_status()'], timeout=3))
                    dragging = status.get('native_drag_window', 0)
                    for window in clients:
                        identity = (window['address'], window['pid'], window['stableId'])
                        if identity in children and int(window['address'], 16) == dragging and window.get('mapped'):
                            live[identity] = window
                except (OSError, ValueError, subprocess.SubprocessError):
                    pass
                for identity in list(children):
                    if identity not in live or children[identity][0].poll() is not None:
                        retire(children.pop(identity))
                        print(f'window-share retired address={identity[0]}', flush=True)
                for identity, window in live.items():
                    if identity in children:
                        continue
                    # Each capture has its own native encoder and paired stream.
                    # Retiring children keep their leases until normal cleanup.
                    if len(children) + len(retiring) >= route['desktop'].get('max_enrolled_windows', 8):
                        break
                    address, pid, stable = identity
                    config = {k: route[k] for k in ('server_name', 'certificate', 'private_key', 'certificate_authority')}
                    config.update(bind='0.0.0.0:0', remote=args.remote, role='source', backend={
                        'native': str(args.source), 'args': ['--window', address, '--compositor-pid',
                        str(route['compositor_pid']), '--fps', '60', '--performance-mode',
                        args.performance_mode, '--input-native', str(args.input_native)]})
                    path = runtime / f'{address[2:]}-{pid}.json'
                    path.write_text(json.dumps(config, indent=2) + '\n')
                    path.chmod(0o600)
                    log = path.with_suffix('.log').open('ab')
                    try:
                        process = subprocess.Popen([str(args.peer), '--config', str(path)],
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    except Exception:
                        log.close()
                        raise
                    children[identity] = process, log
                    print(f'window-share started address={address} pid={pid} peer={process.pid}', flush=True)
                last_error = None
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                # Temporary inventory failure retains existing paired windows.
                if str(error) != last_error:
                    print(f'window-share inventory retry: {error}', flush=True)
                    last_error = str(error)
            for entry in list(retiring):
                started, process, log = entry
                if process.poll() is not None:
                    log.close()
                    retiring.remove(entry)
                elif time.monotonic() - started > 12:
                    # Process teardown watchdog, independent of frame cadence.
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    log.close()
                    retiring.remove(entry)
            time.sleep(0.25)
    finally:
        for child in children.values():
            retire(child)
        for _, process, log in retiring:
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            log.close()


if __name__ == '__main__':
    main()
