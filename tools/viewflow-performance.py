#!/usr/bin/env python3
"""Select the forward capture mode without changing image quality or geometry."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

MODES = ('frame-rate', 'latency')
DEFAULT_SERVICE = 'viewflow-desktop.service'


def load_config(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError('source configuration must be an object')
    mode = value.get('performance_mode', 'frame-rate')
    if mode not in MODES:
        raise ValueError(f'unknown configured performance mode: {mode}')
    return value


def service_settings(service):
    # Read structured effective arguments, including systemd drop-ins.
    unit = json.loads(subprocess.check_output([
        'busctl', '--user', '--json=short', 'call', 'org.freedesktop.systemd1',
        '/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager',
        'GetUnit', 's', service], timeout=10))['data'][0]
    starts = json.loads(subprocess.check_output([
        'busctl', '--user', '--json=short', 'get-property', 'org.freedesktop.systemd1',
        unit, 'org.freedesktop.systemd1.Service', 'ExecStart'], timeout=10))['data']
    if len(starts) != 1:
        raise RuntimeError('expected one Viewflow service command')
    arguments = starts[0][1]
    def argument(name):
        if arguments.count(name) != 1 or arguments.index(name) + 1 >= len(arguments):
            raise RuntimeError(f'Viewflow service has no unique {name} argument')
        path = Path(arguments[arguments.index(name) + 1])
        if not path.is_absolute():
            raise RuntimeError(f'Viewflow service {name} must be an absolute path')
        return path
    return argument('--config'), argument('--peer')


def service_active(service):
    result = subprocess.run(['systemctl', '--user', 'is-active', '--quiet', service],
                            timeout=10, check=False)
    return result.returncode == 0


def restart_service(service):
    subprocess.run(['systemctl', '--user', 'restart', service], check=True, timeout=45)
    if not service_active(service):
        raise RuntimeError('Viewflow service did not become active after restart')


def require_capture_api(mode):
    name = 'window_stream_start_commit' if mode == 'latency' else 'window_stream_start'
    result = subprocess.run(['hyprctl', 'repl', f'return type(hl.plugin.viewflow_capture.{name})'],
                            capture_output=True, text=True, check=True, timeout=5)
    if result.stdout.strip() != 'function':
        raise RuntimeError(f'installed capture plugin does not support {mode} mode')


def atomic_write(path, data, permissions):
    fd, name = tempfile.mkstemp(prefix=f'.{path.name}.performance-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, 'wb') as out:
            os.fchmod(out.fileno(), permissions)
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_config(peer, path):
    # This command validates configuration only; it starts no stream.
    subprocess.run([str(peer), 'validate-send', '--config', str(path)],
                   stdout=subprocess.DEVNULL, check=True, timeout=15)


def set_mode(path, mode, peer, service=DEFAULT_SERVICE):
    if mode not in MODES:
        raise ValueError(f'unknown performance mode: {mode}')
    path = path.resolve(strict=True)
    lock_path = path.with_name(path.name + '.performance.lock')
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        original = path.read_bytes()
        config = load_config(path)
        previous = config.get('performance_mode', 'frame-rate')
        if previous == mode:
            return {'mode': mode, 'changed': False, 'restarted': False}
        if config.get('capture_provider', 'viewflow') != 'viewflow':
            raise ValueError('performance selection requires the Viewflow capture provider')
        service_config, service_peer = service_settings(service)
        if service_config.resolve() != path:
            raise RuntimeError('selected source configuration differs from the service configuration')
        if peer is not None and peer.resolve() != service_peer.resolve():
            raise RuntimeError('validation peer differs from the executable used by the service')
        peer = service_peer
        require_capture_api(mode)
        config['performance_mode'] = mode
        updated = (json.dumps(config, indent=2) + '\n').encode()
        permissions = stat.S_IMODE(path.stat().st_mode)
        fd, name = tempfile.mkstemp(prefix='.viewflow-mode-check-', suffix='.json', dir=path.parent)
        candidate = Path(name)
        try:
            with os.fdopen(fd, 'wb') as out:
                out.write(updated)
            validate_config(peer, candidate)
        finally:
            candidate.unlink(missing_ok=True)
        active = service_active(service)
        backup = path.with_name(path.name + '.performance-backup')
        atomic_write(backup, original, permissions)
        atomic_write(path, updated, permissions)
        if active:
            try:
                restart_service(service)
            except Exception as error:
                atomic_write(path, original, permissions)
                try:
                    restart_service(service)
                except Exception as rollback_error:
                    raise RuntimeError('mode change failed; configuration restored, '
                                       f'but service recovery failed: {rollback_error}') from error
                raise RuntimeError('mode change failed; previous configuration and service restored') from error
        return {'mode': mode, 'changed': True, 'restarted': active, 'backup': str(backup)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, help='defaults to the effective service configuration')
    parser.add_argument('--peer', type=Path, help='optional check against the effective service executable')
    parser.add_argument('--service', default=DEFAULT_SERVICE)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('status')
    select = commands.add_parser('set')
    select.add_argument('mode', choices=MODES)
    args = parser.parse_args()
    try:
        if args.config is None:
            args.config, _ = service_settings(args.service)
        if args.command == 'status':
            config = load_config(args.config)
            result = {'mode': config.get('performance_mode', 'frame-rate'),
                      'capture_fps': config.get('fps'),
                      'active': service_active(args.service)}
        else:
            result = set_mode(args.config, args.mode, args.peer, args.service)
        print(json.dumps(result))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'viewflow-performance: {error}\n')


if __name__ == '__main__':
    main()
