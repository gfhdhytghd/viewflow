#!/usr/bin/env python3
"""Supervise an additional input route while retaining the other connected peers."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time

_spec = importlib.util.spec_from_file_location('desktop_autostart', Path(__file__).with_name('desktop-autostart-linux.py'))
autostart = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(autostart)


def prepare(template, route, runtime, monitor_name=None, state_dir=None):
    instances = autostart.read_json('hyprctl', '-j', 'instances')
    instance = next((item for item in instances if item['instance'] == os.environ.get('HYPRLAND_INSTANCE_SIGNATURE')), None)
    if instance is None and len(instances) == 1:
        instance = instances[0]
    if instance is None:
        raise RuntimeError('Cannot select the current compositor')
    os.environ['HYPRLAND_INSTANCE_SIGNATURE'] = instance['instance']
    os.environ['WAYLAND_DISPLAY'] = instance['wl_socket']
    state = state_dir or runtime / 'viewflow' / route
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    monitors = autostart.read_json('hyprctl', '-j', 'monitors', 'all')
    local = next(m for m in monitors if m['name'] == monitor_name) if monitor_name else next(
        m for m in monitors if not m['name'].startswith('HEADLESS-') and not m.get('disabled'))
    config = autostart.prepare(template, instance, local, runtime)
    remote = config['desktop']['remote_display']
    output = None
    record = state / 'output.json'
    if record.exists():
        previous = json.loads(record.read_text())
        if previous['instance'] == instance['instance']:
            output = next((m for m in monitors if m['name'] == previous['name']), None)
    if output is None:
        old = {m['name'] for m in monitors}
        subprocess.run(['hyprctl', 'output', 'create', 'headless'], check=True, timeout=5)
        for _ in range(30):
            new = [m for m in autostart.read_json('hyprctl', '-j', 'monitors', 'all') if m['name'] not in old]
            if len(new) == 1:
                output = new[0]
                break
            time.sleep(.1)
        if output is None:
            raise RuntimeError('New Viewflow output did not appear')
        autostart.save(record, {'name': output['name'], 'instance': instance['instance']})
    if output.get('disabled', False) or any(output[k] != remote[k] for k in ('x', 'y', 'width', 'height', 'scale')):
        output = autostart.restore_existing_output(output['name'], remote)
    if not autostart.special_workspace_active(output, 'viewflow-' + route):
        autostart.activate_special_workspace(output['name'], workspace='viewflow-' + route,
                                             underlay='viewflow-' + route)
    config['pointer']['native_socket'] = str(runtime / 'viewflow' / (route + '.sock'))
    config['pointer']['cursor_monitor_id'] = output['id']
    config['desktop']['native_control_dir'] = str(state / 'native-control')
    Path(config['desktop']['native_control_dir']).mkdir(mode=0o700, exist_ok=True)
    fd = os.open(state / 'native-control/desktop-window.json', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    autostart.save(state / 'config', config)
    return state, config


def ensure_plugins(bundle):
    """Reuse installed plugins; load missing bundled plugins without reloading."""
    for name in ('viewflow-capture', 'viewflow-hyprland'):
        loaded = autostart.read_json('hyprctl', '-j', 'plugin', 'list')
        if any(item.get('name') == name for item in loaded): continue
        plugin = bundle / 'plugins' / (name + '.so')
        safety = Path(__file__).with_name('plugin_safety.py')
        if not safety.exists():
            safety = Path(__file__).resolve().parents[1] / 'platform/desktop-app/plugin_safety.py'
        subprocess.run(['python3', str(safety), str(plugin)], check=True, timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--route', required=True)
    parser.add_argument('--peer', type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--monitor')
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--bundle', type=Path)
    args = parser.parse_args()
    if not args.route or len(args.route) > 32 or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in args.route):
        parser.error('Invalid route name')
    if not args.prepare_only and args.peer is None:
        parser.error('--peer is required')
    runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    if args.bundle: ensure_plugins(args.bundle)
    state, config = prepare(args.config, args.route, runtime, args.monitor, args.state_dir)
    if args.prepare_only:
        print(f'Prepared {args.route}: monitor={config["pointer"]["cursor_monitor_id"]}', flush=True)
        return
    stopping = False
    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    child = None
    ready = state / 'cursor-ready'
    environment = dict(os.environ, VIEWFLOW_CURSOR_READY_FILE=str(ready))
    native = json.loads(args.config.read_text()).get('native_cursor')
    if native:
        environment['VIEWFLOW_CURSOR_OUTPUT_SIZE'] = f'{native["width"]}x{native["height"]}'
        environment['VIEWFLOW_CURSOR_OUTPUT_ORIGIN'] = f'{native["x"]},{native["y"]}'
    try:
        while not stopping:
            # Idempotent registration also recovers after an authorized plugin reload.
            subprocess.run(['hyprctl', '-q', 'eval', 'hl.plugin.viewflow.add_input_route(' + json.dumps(args.route) + ')'],
                           check=True, timeout=5)
            # Loading a plugin can reapply the compositor's fallback monitor
            # rules. Keep this route's existing output in sync with its topology,
            # just as the primary desktop launcher does for its adopted output.
            output_name = json.loads((state / 'output.json').read_text())['name']
            monitors = autostart.read_json('hyprctl', '-j', 'monitors', 'all')
            output = next((m for m in monitors if m['name'] == output_name), None)
            remote = config['desktop']['remote_display']
            if output is not None and any(output[k] != remote[k] for k in ('x', 'y', 'width', 'height', 'scale')):
                autostart.restore_existing_output(output_name, remote)
                print(f'{args.route} output geometry restored after compositor reconfiguration', flush=True)
            if child is None or child.poll() is not None:
                if child is not None:
                    print(f'{args.route} peer exited {child.returncode}; reconnecting', flush=True)
                with (state / 'source.log').open('ab') as log:
                    child = subprocess.Popen([str(args.peer), 'send', '--config', str(state / 'config')],
                                             stdout=log, stderr=subprocess.STDOUT, env=environment)
                (state / 'daemon.pid').write_text(str(child.pid) + '\n')
                print(f'{args.route} peer running: PID {child.pid}', flush=True)
            time.sleep(1)
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait(timeout=15)
        ready.unlink(missing_ok=True)
        # Retain the output and windows during input disconnects and service restarts.


if __name__ == '__main__':
    main()
