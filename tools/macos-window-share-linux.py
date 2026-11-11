#!/usr/bin/env python3
"""Share windows intersecting the active Mac viewport; never move or focus them."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

# Frozen bundles ship log_limit.py beside this script; source checkouts keep it
# in platform/desktop-app.
for _directory in (Path(__file__).resolve().parent, Path(__file__).resolve().parents[1] / 'platform/desktop-app'):
    if str(_directory) not in sys.path:
        sys.path.append(str(_directory))
from log_limit import limit_log, open_log, previous_path  # noqa: E402


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
    # Master uses an explicit type for special workspaces without numeric IDs.
    def workspace_key(workspace):
        selector = workspace.get('address') or workspace.get('name')
        if selector:
            kind = workspace.get('type') or ('special' if selector.startswith('special:') else 'normal')
            return (kind, selector.removeprefix('special:') if kind == 'special' else selector)
        number = workspace.get('id')
        return ('id', number) if number not in (None, 0) else None

    visible = {workspace_key(ws) for m in monitors
               for ws in ([m['specialWorkspace']] if workspace_key(m.get('specialWorkspace', {}))
                          else [m.get('activeWorkspace', {})])}
    visible.discard(None)
    if workspace_key(client.get('workspace', {})) not in visible:
        return False
    width, height = remote['width'], remote['height']
    if remote.get('transform', 0) % 2:
        width, height = height, width
    rx, ry = remote['x'], remote['y']
    rw, rh = width / remote['scale'], height / remote['scale']
    x, y = client['at']
    w, h = client['size']
    return w > 0 and h > 0 and x < rx + rw and x + w > rx and y < ry + rh and y + h > ry


def selected_windows(clients, monitors, remote_ids, existing):
    # Visibility controls enrollment and pixels, never established ownership.
    # Full identity prevents a reused address from inheriting an old proxy.
    return {(w['address'], w['pid'], w['stableId']): w for w in clients
            if (w['address'], w['pid'], w['stableId']) in existing
            or any(eligible(w, monitors, mid) for mid in remote_ids)}


class RestartBackoff:
    """Identity-scoped retry delay; a failure never discards window ownership."""
    def __init__(self):
        self.failures = {}
        self.until = {}

    def failed(self, identity, now):
        count = min(self.failures.get(identity, 0) + 1, 5)
        self.failures[identity] = count
        self.until[identity] = now + min(30, 2 ** count)

    def ready(self, identity, now):
        return now >= self.until.get(identity, 0)

    def stable(self, identity):
        self.failures.pop(identity, None)
        self.until.pop(identity, None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--route-config', type=Path)
    parser.add_argument('--routes-file', type=Path, help='JSON array of active Mac route config paths')
    parser.add_argument('--peer', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--input-native', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, help='isolated runtime directory for an app-owned pair')
    parser.add_argument('--remote', default='172.16.105.83:44220')
    parser.add_argument('--performance-mode', choices=('frame-rate', 'latency'),
                        default=os.environ.get('VIEWFLOW_WINDOW_PERFORMANCE_MODE', 'frame-rate'))
    args = parser.parse_args()
    if not args.route_config and not args.routes_file:
        parser.error("--route-config or --routes-file required")
    runtime = args.runtime or Path(os.environ['XDG_RUNTIME_DIR']) / 'viewflow' / 'macos-windows'
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    stopped = False
    children = {}
    retiring = []
    backoff = RestartBackoff()
    started_at = {}
    retained = set()

    def stop(_sig, _frame):
        nonlocal stopped
        stopped = True

    def close_log(process, log, discard):
        log.close()
        # A window that left the Mac viewport and whose peer ended normally
        # has nothing worth keeping; failed peers keep their log.
        if discard and process.returncode in (0, -signal.SIGTERM):
            Path(log.name).unlink(missing_ok=True)
            previous_path(log.name).unlink(missing_ok=True)

    def retire(child, discard=False):
        process, log = child
        if process.poll() is None:
            process.terminate()  # Peer closes QUIC; native input releases on EOF.
            retiring.append((time.monotonic(), process, log, discard))
        else:
            close_log(process, log, discard)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last_error = None
    session = None
    try:
        while not stopped:
            try:
                paths = json.loads(args.routes_file.read_text()) if args.routes_file else [str(args.route_config)]
                routes = [json.loads(Path(path).read_text()) for path in paths]
                if not routes:
                    for child in children.values(): retire(child)
                    children.clear()
                    time.sleep(.25)
                    continue
                route = routes[0]
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
                live = selected_windows(clients, monitors,
                    [item['pointer']['cursor_monitor_id'] for item in routes], set(children) | retained)
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
                now = time.monotonic()
                for identity in list(children):
                    if identity not in live:
                        retire(children.pop(identity), discard=True)
                        backoff.stable(identity)
                        retained.discard(identity)
                    elif children[identity][0].poll() is not None:
                        retire(children.pop(identity))
                        backoff.failed(identity, now)
                        retained.add(identity)
                        print(f'window-share recovering address={identity[0]} retry-after={backoff.until[identity]-now:.0f}s', flush=True)
                    elif now - started_at.get(identity, now) >= 60:
                        backoff.stable(identity)
                for identity in list(retained):
                    if identity not in live:
                        retained.discard(identity)
                        backoff.stable(identity)
                for identity, window in live.items():
                    if identity in children or not backoff.ready(identity, now):
                        continue
                    # Each capture has its own native encoder and paired stream.
                    # Retiring children keep their leases until normal cleanup.
                    if len(children) + len(retiring) >= route['desktop'].get('max_enrolled_windows', 8):
                        break
                    address, pid, stable = identity
                    config = {k: route[k] for k in ('server_name', 'certificate', 'private_key', 'certificate_authority')}
                    config['transparency'] = os.environ.get('VIEWFLOW_TRANSPARENCY', '1') != '0'
                    config.update(bind='[::]:0' if args.remote.startswith('[') else '0.0.0.0:0', remote=args.remote, role='source', backend={
                        'native': str(args.source), 'args': ['--window', address, '--compositor-pid',
                        str(route['compositor_pid']), '--fps', '60', '--performance-mode',
                        args.performance_mode, '--input-native', str(args.input_native)]})
                    path = runtime / f'{address[2:]}-{pid}.json'
                    path.write_text(json.dumps(config, indent=2) + '\n')
                    path.chmod(0o600)
                    log = open_log(path.with_suffix('.log'))
                    try:
                        process = subprocess.Popen([str(args.peer), '--config', str(path)],
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    except Exception:
                        log.close()
                        backoff.failed(identity, now)
                        retained.add(identity)
                        raise
                    children[identity] = process, log
                    started_at[identity] = now
                    retained.discard(identity)
                    print(f'window-share started address={address} pid={pid} peer={process.pid}', flush=True)
                last_error = None
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                # Temporary inventory failure retains existing paired windows.
                if str(error) != last_error:
                    print(f'window-share inventory retry: {error}', flush=True)
                    last_error = str(error)
            for entry in list(retiring):
                started, process, log, discard = entry
                if process.poll() is not None:
                    close_log(process, log, discard)
                    retiring.remove(entry)
                elif time.monotonic() - started > 12:
                    # Process teardown watchdog, independent of frame cadence.
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    log.close()
                    retiring.remove(entry)
            for _, log in children.values():
                limit_log(log.name)
            time.sleep(0.25)
    finally:
        for child in children.values():
            retire(child)
        for _, process, log, _ in retiring:
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            log.close()


if __name__ == '__main__':
    main()
