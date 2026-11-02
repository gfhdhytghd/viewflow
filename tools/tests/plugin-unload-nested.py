#!/usr/bin/env python3
"""Own a nested compositor and exercise real dlclose/reload; never select a live instance."""
import argparse
import array
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time


def wait_for(check, description, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.05)
    raise RuntimeError('timed out: ' + description)


class Receiver:
    def __init__(self, path):
        self.path = path
        self.frames = 0
        self.error = None
        self.stopped = threading.Event()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.server.bind(str(path))
        path.chmod(0o600)
        self.server.listen()
        self.server.settimeout(.1)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            while not self.stopped.is_set():
                try:
                    peer, _ = self.server.accept()
                except socket.timeout:
                    continue
                with peer:
                    peer.settimeout(.1)
                    while not self.stopped.is_set():
                        try:
                            data, anc, flags, _ = peer.recvmsg(4096, socket.CMSG_SPACE(16 * 4))
                        except socket.timeout:
                            continue
                        if not data:
                            break
                        for level, kind, payload in anc:
                            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                                fds = array.array('i')
                                fds.frombytes(payload)
                                for fd in fds:
                                    os.close(fd)
                        assert data[:4] == b'HCGF' and not flags, (data[:8], flags)
                        peer.sendall(b'HCGR\0\1\0\x20' + data[8:16] + data[24:32] + bytes(8))
                        self.frames += 1
        except Exception as error:
            self.error = str(error)

    def close(self):
        self.stopped.set()
        self.thread.join(2)
        self.server.close()


def backdrop_sequence(path):
    with path.open('rb') as file:
        file.seek(64)
        return struct.unpack('<Q', file.read(8))[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hyprland', type=Path, required=True)
    parser.add_argument('--input-plugin', type=Path, required=True)
    parser.add_argument('--capture-plugin', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=24)
    parser.add_argument('--headless', action='store_true')
    parser.add_argument('--headless-format-preload', type=Path)
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    assert args.cycles >= 20
    args.artifacts.mkdir(parents=True, exist_ok=True)
    # Short paths are essential: Hyprland signatures approach sockaddr_un's limit.
    runtime = Path(tempfile.mkdtemp(prefix='vu-'))
    children, receivers = [], []
    env = os.environ.copy()
    parent = env['WAYLAND_DISPLAY']
    if not parent.startswith('/'):
        parent = str(Path(env['XDG_RUNTIME_DIR']) / parent)
    env.update(XDG_RUNTIME_DIR=str(runtime), WAYLAND_DISPLAY=parent,
               XDG_CONFIG_HOME=str(runtime / 'config'), XDG_CACHE_HOME=str(runtime / 'cache'),
               HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1', HYPRLAND_NO_DBUS='1')
    env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
    env.pop('LD_PRELOAD', None)
    if args.headless_format_preload:
        env['LD_PRELOAD'] = str(args.headless_format_preload.resolve())
    config = runtime / 'test.lua'
    config.write_text("hl.monitor({output='',mode='preferred',position='auto',scale=1})\n"
                      "hl.config({animations={enabled=false},misc={disable_hyprland_logo=true,disable_splash_rendering=true}})\n")
    log = open(args.artifacts / 'compositor.log', 'w')
    compositor = subprocess.Popen([str(args.hyprland.resolve()), '-c', str(config)],
                                  env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    result = {'cycles': 0, 'headless': args.headless, 'frames': 0, 'pid': compositor.pid,
              'format_preload': str(args.headless_format_preload or '')}
    try:
        def instance():
            if compositor.poll() is not None:
                raise RuntimeError('nested compositor exited: ' + str(compositor.returncode))
            for lock in (runtime / 'hypr').glob('*/hyprland.lock'):
                if lock.read_text().splitlines()[0] == str(compositor.pid) and (lock.parent / '.socket.sock').exists():
                    return lock.parent.name
        signature = wait_for(instance, 'owned IPC socket')
        env.update(HYPRLAND_INSTANCE_SIGNATURE=signature, WAYLAND_DISPLAY=(runtime / 'hypr' / signature / 'hyprland.lock').read_text().splitlines()[1])
        env.pop('LD_PRELOAD', None)  # Only the nested server needs the GPU allocation fixture.
        result['signature'] = signature

        def ctl(*words, json_result=False, expect_error=False, batch=False):
            # Assert ownership before every IPC mutation, not just at startup.
            assert compositor.poll() is None, 'nested compositor exited'
            lock = runtime / 'hypr' / signature / 'hyprland.lock'
            assert lock.read_text().splitlines()[0] == str(compositor.pid)
            value = subprocess.check_output(['hyprctl', *words], env=env, text=True, timeout=15).strip()
            if json_result:
                return json.loads(value)
            valid = bool(value.split()) and all(word == 'ok' for word in value.split()) if batch else value == 'ok'
            assert not valid if expect_error else valid, (words, value)
            return value

        def request(namespace, method, data):
            path = runtime / 'request.json'
            path.write_text(json.dumps(data))
            path.chmod(0o600)
            ctl('eval', f'assert(hl.plugin.{namespace}.{method}({json.dumps(str(path))}))')
            value = json.loads(path.read_text())
            assert value.get('ok'), value
            return value

        result['version'] = ctl('-j', 'version', json_result=True)
        if args.headless:
            ctl('output', 'create', 'headless', 'VF-UNLOAD')
            wait_for(lambda: any(m['name'] == 'VF-UNLOAD' and m['width'] > 0
                                 for m in ctl('-j', 'monitors', json_result=True)), 'usable headless output')
        for path, namespace, first in [(args.input_plugin, 'viewflow', 'recall_windows'),
                                        (args.capture_plugin, 'viewflow_capture', 'window_stream_start')]:
            ctl('eval', f'hl.plugin.{namespace}={{{first}=42}}')
            ctl('plugin', 'load', str(path.resolve()), expect_error=True)
            assert ctl('-j', 'plugin', 'list', json_result=True) == []
            assert str(path.resolve()) not in Path(f'/proc/{compositor.pid}/maps').read_text()
            ctl('eval', f'hl.plugin.{namespace}=nil')
        result['failed_init_rollbacks'] = 2
        for cls in ['ViewflowReverse-MacNative-UnloadTest', 'ViewflowReverse-WindowsNative-UnloadTest', 'unloadtest']:
            children.append(subprocess.Popen(['kitty', '--config', 'NONE', '--class', cls, 'sh', '-c',
                                               'while :; do date; sleep .1; done'], env=env,
                                              stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
        clients = wait_for(lambda: (c if len(c := ctl('-j', 'clients', json_result=True)) == 3 else None), 'three mapped clients')
        result['clients'] = [{'class': c['class'], 'pid': c['pid']} for c in clients]
        # Exercise popup-backdrop GPU objects without creating a proxy app or input.
        backdrops = runtime / 'viewflow/backdrops'
        backdrops.mkdir(parents=True, exist_ok=True)
        mac = next(c for c in clients if c['class'].startswith('ViewflowReverse-MacNative-'))
        backdrop = backdrops / 'fixture'
        with backdrop.open('wb') as file:
            file.write(struct.pack('<IIQ', 0x56464248, mac['pid'], int(mac['address'], 16)))
            file.truncate(128 + 32 * 1024 * 1024 * 4)
        backdrop.chmod(0o600)
        for i in range(3):
            receivers.append(Receiver(runtime / f'r{i}.sock'))
        # Alternate actual .so paths to cover loading a new build after dlclose.
        variants = []
        for suffix in ('a', 'b'):
            pair = []
            for source in (args.input_plugin, args.capture_plugin):
                dest = runtime / (source.stem + '-' + suffix + '.so')
                shutil.copy2(source, dest)
                pair.append(dest)
            variants.append(pair)
        for cycle in range(args.cycles):
            pair = variants[cycle % 2]
            for path in pair[::1 if cycle % 2 == 0 else -1]:
                ctl('plugin', 'load', str(path))
            before = [r.frames for r in receivers]
            for i, (client, receiver) in enumerate(zip(clients, receivers)):
                request('viewflow_capture', 'window_stream_start' if i == 0 else 'window_stream_start_commit',
                        {'id': f'test-{i}', 'socketPath': str(receiver.path), 'windowAddress': client['address'],
                         'fps': 30, 'mode': 'window-gpu'})
            wait_for(lambda: all(r.frames > n for r, n in zip(receivers, before)), 'three active GPU streams')
            if cycle % 2:
                for i in range(3):
                    request('viewflow_capture', 'window_stream_stop', {'streamId': f'test-{i}'})
            ordinary = next(c for c in ctl('-j', 'clients', json_result=True) if c['class'] == 'unloadtest')
            deadline = time.monotonic_ns() + (300_000_000 if cycle == 0 else 5_000_000_000)
            enrolled = request('viewflow', 'desktop_window',
                               {'version': 1, 'operation': 'enroll', 'localWindowId': 'restore',
                                'windowAddress': ordinary['address'], 'pid': ordinary['pid'],
                                'notAfterMonotonicNs': deadline})
            request('viewflow', 'desktop_window',
                    {'version': 1, 'operation': 'move', 'localWindowId': 'restore', 'token': enrolled['token'],
                     'sequence': 1, 'notAfterMonotonicNs': deadline,
                     'desiredFullCaptureX': 100, 'desiredFullCaptureY': 100})
            if cycle == 0:
                time.sleep(.35)
                # A later request purges expired command authority. Restoration
                # ownership must survive that purge until PLUGIN_EXIT.
                request('viewflow', 'desktop_window',
                        {'version': 1, 'operation': 'enroll', 'localWindowId': 'after-expiry',
                         'windowAddress': ordinary['address'], 'pid': ordinary['pid'],
                         'notAfterMonotonicNs': time.monotonic_ns() + 5_000_000_000})
            wait_for(lambda: backdrop_sequence(backdrop) > 0,
                     'popup backdrop readback')
            # Even cycles unload live streams; odd cycles unload stopped streams.
            for index, path in enumerate(pair[::1 if cycle % 2 == 0 else -1]):
                count = sum(r.frames for r in receivers)
                namespace, method = ('viewflow', 'capture_status') if path == pair[0] else ('viewflow_capture', 'window_stream_stop')
                ctl('eval', f'_vf_saved_unload=hl.plugin.{namespace}.{method}')
                # Same IPC batch: prove the cached closure is still a function
                # before the host's deferred config reload can discard globals.
                check = ('assert(type(_vf_saved_unload)=="function") '
                         'local ok,err=pcall(_vf_saved_unload) '
                         'assert(not ok and tostring(err):find("plugin unloaded",1,true))')
                ctl('--batch', f'plugin unload {path}; eval {check}', batch=True)
                if index == 0 and cycle % 2 == 0:
                    wait_for(lambda: sum(r.frames for r in receivers) > count, 'capture survives input-plugin unload')
                elif index == 0:
                    ctl('eval', 'assert(hl.plugin.viewflow.capture_status())')
            assert ctl('-j', 'plugin', 'list', json_result=True) == []
            if args.headless:
                assert any(m['name'] == 'VF-UNLOAD' and m['width'] > 0
                           for m in ctl('-j', 'monitors', json_result=True)), 'headless output lost on unload'
            maps = Path(f'/proc/{compositor.pid}/maps').read_text()
            assert all(str(path) not in maps for paths in variants for path in paths), 'plugin still mapped after unload'
            assert 'libaquamarine.so.14' not in maps, 'foreign Aquamarine loaded'
            current_clients = ctl('-j', 'clients', json_result=True)
            assert len(current_clients) == 3
            restored = next(c for c in current_clients if c['address'] == ordinary['address'])
            assert restored['floating'] == ordinary['floating'], ('floating restoration', ordinary, restored)
            assert restored['workspace'] == ordinary['workspace'], ('workspace restoration', ordinary, restored)
            assert all(r.error is None for r in receivers), [r.error for r in receivers]
            result['cycles'] += 1
            print(json.dumps({'cycle': cycle + 1, 'frames': [r.frames for r in receivers]}), flush=True)
        result['backdrop_sequence'] = backdrop_sequence(backdrop)
        result['frames'] = sum(r.frames for r in receivers)
        result['status'] = 'PASS'
    except BaseException as error:
        result.update(status='FAIL', error=str(error))
        raise
    finally:
        (args.artifacts / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        for receiver in receivers:
            receiver.close()
        for child in children:
            if child.poll() is None:
                child.terminate()
        for child in children:
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        if compositor.poll() is None:
            compositor.terminate()
            try:
                compositor.wait(timeout=8)
            except subprocess.TimeoutExpired:
                compositor.kill()
                compositor.wait()
        log.close()
        shutil.rmtree(runtime)


if __name__ == '__main__':
    main()
