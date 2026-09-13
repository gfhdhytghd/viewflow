#!/usr/bin/env python3
"""User service: discover the live Hyprland session, then supervise the desktop peer."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

stopping = False
SPECIAL_WORKSPACE = 'viewflow'
UNDERLAY_WORKSPACE = 'viewflow-underlay'

def launch_command(prepared, monitor, peer, existing_output=None):
    if getattr(sys, 'frozen', False):
        bundle = Path(sys.executable).resolve().parent
        helper = Path(__file__).resolve().with_name('desktop-drag-linux.sh')
        plugins = ['--capture-plugin', str(bundle / 'plugins/viewflow-capture.so'),
                   '--input-plugin', str(bundle / 'plugins/viewflow-hyprland.so')]
    else:
        helper = Path(__file__).resolve().with_name('desktop-drag-linux.sh')
        plugins = []
    command = [str(helper), 'start', '--config', str(prepared), '--monitor', monitor,
               '--peer', str(peer), '--empty-desktop', *plugins]
    if existing_output:
        command.extend(['--existing-output', existing_output])
    return command

def stop(_signal, _frame):
    global stopping
    stopping = True


def read_json(*args):
    return json.loads(subprocess.check_output(args, stderr=subprocess.DEVNULL, timeout=5))


def identity(pid):
    try:
        # The process name may contain spaces or parentheses.
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
    except FileNotFoundError:
        return None


def save(path, value):
    temporary = path.with_suffix('.next')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def special_workspace_expression(output, workspace=SPECIAL_WORKSPACE,
                                 underlay=UNDERLAY_WORKSPACE):
    output_value = json.dumps(output)
    workspace_value = json.dumps(workspace)
    underlay_value = json.dumps(underlay)
    return (f'local monitor = hl.get_monitor({output_value}); '
            f'if not monitor then error("Viewflow output is unavailable") end; '
            f'hl.workspace_rule({{ workspace = "name:" .. {underlay_value}, monitor = {output_value}, persistent = true }}); '
            f'monitor:set_workspace({{ workspace = {underlay_value} }}); '
            f'if hl.get_workspace("special:" .. {workspace_value}) then '
            f'monitor:set_special_workspace({{ workspace = "special:" .. {workspace_value} }}) end')


def activate_special_workspace(output, workspace=SPECIAL_WORKSPACE,
                               underlay=UNDERLAY_WORKSPACE):
    subprocess.run(['hyprctl', 'eval', special_workspace_expression(output, workspace, underlay)],
                   check=True, timeout=5)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        monitors = read_json('hyprctl', '-j', 'monitors')
        if any(m['name'] == output and m.get('activeWorkspace', {}).get('name') == underlay
               for m in monitors):
            return
        # Persistent workspaces may be materialized on a later compositor tick.
        subprocess.run(['hyprctl', 'eval',
                        'hl.get_monitor(' + json.dumps(output) + '):set_workspace({workspace=' + json.dumps(underlay) + '})'],
                       check=True, timeout=5)
        time.sleep(0.1)
    raise RuntimeError(f'Owned output did not activate Viewflow underlay workspace {underlay}')


def restore_existing_output(output, remote):
    """Recover an adopted output after a plugin/config reload reset its mode."""
    expression = ('hl.monitor({ output = ' + json.dumps(output) +
                  ', mode = ' + json.dumps(f'{remote["width"]}x{remote["height"]}@60') +
                  ', position = ' + json.dumps(f'{remote["x"]}x{remote["y"]}') +
                  ', scale = ' + json.dumps(remote['scale']) + ' })')
    def apply_geometry():
        subprocess.run(['hyprctl', '-q', 'eval', expression], check=True)

    apply_geometry()
    stable = 0
    for _ in range(50):
        monitors = read_json('hyprctl', '-j', 'monitors', 'all')
        current = next((monitor for monitor in monitors if monitor['name'] == output), None)
        if current is not None and all(current[key] == remote[key]
                                       for key in ('x', 'y', 'width', 'height', 'scale')):
            stable += 1
            if stable >= 5:
                return current
        else:
            stable = 0
            # A mode-set may race the compositor's fallback update. Reapply
            # only after a bad sample, then start the stability count again.
            apply_geometry()
        time.sleep(0.1)
    raise RuntimeError(f'Existing output did not recover its configured geometry: {output}')


def prepare(template, instance, monitor, runtime):
    config = json.loads(template.read_text())
    if config.get("peer_discovery"):
        from desktop_peer_discovery import resolve
        config["remote"] = resolve(config)
        config.pop("peer_discovery")
    config['compositor_pid'] = instance['pid']
    config['windows'] = []
    desktop = config['desktop']
    desktop['candidates'] = []
    desktop['auto_enroll'] = True
    desktop['hyprland_socket'] = str(runtime / 'hypr' / instance['instance'] / '.socket.sock')
    local = {k: monitor[k] for k in ('x', 'y', 'width', 'height', 'scale')}
    if monitor.get('transform', 0) in (1, 3, 5, 7):
        local['width'], local['height'] = local['height'], local['width']
    desktop['local_display'] = local
    config['pointer']['native_socket'] = str(runtime / 'viewflow/hyprland.sock')
    return config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--monitor', required=True)
    parser.add_argument('--peer', type=Path, required=True)
    parser.add_argument('--existing-output', help='reuse an existing output without creating or removing it')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    state = runtime / 'viewflow/desktop-drag'
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    pid = None
    token = None
    child = None
    try:
        while not stopping:
            try:
                instances = read_json('hyprctl', '-j', 'instances')
                live = [i for i in instances if identity(i['pid']) is not None]
                selected = next((i for i in live if i['instance'] == os.environ.get('HYPRLAND_INSTANCE_SIGNATURE')), None)
                if selected is None and len(live) == 1:
                    selected = live[0]
                if selected is None:
                    time.sleep(1)
                    continue
                os.environ['HYPRLAND_INSTANCE_SIGNATURE'] = selected['instance']
                os.environ['WAYLAND_DISPLAY'] = selected['wl_socket']
                monitors = read_json('hyprctl', '-j', 'monitors', 'all')
                monitor = next(m for m in monitors if m['name'] == args.monitor)
                config = prepare(args.config, selected, monitor, runtime)
                break
            except (OSError, ValueError, RuntimeError, StopIteration, subprocess.SubprocessError) as error:
                print(f'Waiting for Hyprland: {error}', flush=True)
                time.sleep(1)
        if stopping:
            return
        if state.exists():
            previous = json.loads((state / 'config').read_text())
            if previous['desktop']['hyprland_socket'] != config['desktop']['hyprland_socket']:
                if any(i['pid'] == previous['compositor_pid'] for i in live):
                    raise RuntimeError('Existing runtime state belongs to another live compositor')
                # Logout can leave runtime state until the user manager exits.
                # Archive only after both the old compositor and peer have gone.
                if (state / 'daemon.pid').exists() and identity(int((state / 'daemon.pid').read_text())) is not None:
                    raise RuntimeError('Previous session peer is still shutting down')
                state.rename(state.with_name(f'desktop-drag.previous-{time.time_ns()}'))
        if not state.exists():
            prepared = runtime / 'viewflow/autostart-source.json'
            prepared.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            save(prepared, config)
            command = launch_command(prepared, args.monitor, args.peer, args.existing_output)
            subprocess.run(command, check=True)
        else:
            # Reuse this session's owned output/plugins without moving windows.
            previous = json.loads((state / 'config').read_text())
            if previous['compositor_pid'] != selected['pid'] or previous['desktop']['hyprland_socket'] != config['desktop']['hyprland_socket']:
                raise RuntimeError('Existing runtime state belongs to a different compositor; refusing to reuse its output')
            output = (state / 'output').read_text().strip()
            owned = next(m for m in monitors if m['name'] == output)
            remote = config['desktop']['remote_display']
            if args.existing_output:
                # A reload may reset an adopted output after the initial monitor
                # snapshot.  Always reapply it and require consecutive read-backs
                # before attaching the cursor peer.
                owned = restore_existing_output(output, remote)
            elif any(owned[k] != remote[k] for k in ('x', 'y', 'width', 'height', 'scale')):
                raise RuntimeError('Owned output differs from configured remote display')
            if not args.existing_output:
                activate_special_workspace(output)
            config['pointer']['cursor_monitor_id'] = owned['id']
            config['desktop']['native_control_dir'] = str(state / 'native-control')
            (state / 'native-control').mkdir(mode=0o700, exist_ok=True)
            # Older peers open this request/reply file without O_CREAT.
            # Preserve an existing exchange when adopting a running peer.
            request_fd = os.open(state / 'native-control' / 'desktop-window.json',
                                 os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            os.close(request_fd)
            # Adopt a running manual launch only after checking PID/start/executable.
            if (state / 'daemon.pid').exists():
                candidate = int((state / 'daemon.pid').read_text())
                recorded = (state / 'daemon.start').read_text().strip()
                if identity(candidate) is not None:
                    if identity(candidate) != recorded or Path(f'/proc/{candidate}/exe').resolve() != args.peer.resolve():
                        raise RuntimeError('Recorded source process identity changed')
                    pid, token = candidate, recorded
            if pid is None:
                save(state / 'config', config)
        if pid is None and (state / 'daemon.pid').exists():
            candidate = int((state / 'daemon.pid').read_text())
            recorded = (state / 'daemon.start').read_text().strip()
            if identity(candidate) == recorded:
                pid, token = candidate, recorded
        while not stopping:
            if not Path(config['desktop']['hyprland_socket']).exists():
                raise RuntimeError('Hyprland session ended; waiting for the next login')
            if child is not None:
                child.poll()  # Reap an exited source before inspecting /proc.
            if pid is None or identity(pid) != token:
                if child is not None:
                    print(f'Desktop peer exited {child.returncode}; restarting', flush=True)
                template_config = json.loads(args.config.read_text())
                if template_config.get('peer_discovery'):
                    from desktop_peer_discovery import resolve
                    try:
                        config['remote'] = resolve(template_config)
                        save(state / 'config', config)
                    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                        print(f'Waiting for desktop peer: {error}', flush=True)
                        time.sleep(1)
                        continue
                with (state / 'source.log').open('ab') as log:
                    child = subprocess.Popen([str(args.peer), 'send', '--config', str(state / 'config')], stdout=log, stderr=subprocess.STDOUT)
                pid, token = child.pid, identity(child.pid)
                (state / 'daemon.pid').write_text(f'{pid}\n')
                (state / 'daemon.start').write_text(f'{token}\n')
                print(f'Desktop peer running: PID {pid}', flush=True)
            time.sleep(1)
    finally:
        if pid is not None and identity(pid) == token:
            os.kill(pid, signal.SIGTERM)
            if child is not None:
                child.wait(timeout=15)
            else:
                deadline = time.monotonic() + 15
                while identity(pid) == token and time.monotonic() < deadline:
                    time.sleep(0.1)


if __name__ == '__main__':
    main()
