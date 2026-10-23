#!/usr/bin/env python3
"""Reconcile the right-hand HDMI selector and live Mac Sidecar topology."""
import argparse
import copy
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time


WINDOWS = 'viewflow-desktop.service'
MAC = 'viewflow-macos-input.service'
SIDECAR = 'viewflow-multiscreen-macos.service'
HID = 'viewflow-macos-hid.service'
SHARE = 'viewflow-topology-windows.service'
RECEIVE = 'viewflow-macos-receiver.service'


def plan(right, report, local, remote):
    if right not in ('windows', 'macos'):
        raise ValueError('Unknown HDMI selector')
    displays = report['displays']
    sidecar = next((d for d in displays if d['kind'] == 'sidecar'), None)
    hdmi = next((d for d in displays if d['kind'] == 'physical' and 'HDMI' in d['name']), None)
    hdmi = hdmi or next((d for d in displays if d['kind'] == 'physical'), None)
    if right == 'macos' and hdmi is None:
        raise ValueError('Waiting for the Mac HDMI display after switching')
    rw, rh = remote['width'] / remote['scale'], remote['height'] / remote['scale']
    lw, lh = local['width'] / local['scale'], local['height'] / local['scale']
    if local.get('transform', 0) % 2:
        lw, lh = lh, lw
    x, y = local['x'] + lw, remote['y']
    side_x, side_y = x, y + rh
    anchor = (x, y) if right == 'macos' else (side_x, side_y)
    request = dict(right=right, localWidth=int(lw), localHeight=int(lh), rightX=int(x), rightY=int(y),
                   rightWidth=int(rw), rightHeight=int(rh), sidecarX=int(side_x), sidecarY=int(side_y))
    connected = right == 'macos' or sidecar is not None
    units = {WINDOWS} if right == 'windows' else {MAC}
    if sidecar: units.add(SIDECAR)
    if connected: units.update((HID, SHARE, RECEIVE))
    native = None
    side_remote = None
    if sidecar:
        sw, sh = sidecar['width'], sidecar['height']
        if sw <= 0 or sh <= 0: raise ValueError('Invalid Sidecar dimensions')
        scale = sidecar['pixelsWidth'] / sw
        # Hyprland's mode and scale must describe the same logical viewport.
        side_remote = dict(x=int(side_x), y=int(side_y), width=int(sw * scale), height=int(sh * scale), scale=scale)
        native = dict(x=int(side_x-anchor[0]), y=int(side_y-anchor[1]), width=sw, height=sh)
    return dict(right=right, sidecar=bool(sidecar), connected=connected, units=sorted(units), request=request,
                anchor=list(map(int, anchor)), sidecar_remote=side_remote, sidecar_native=native,
                primary_remote=dict(remote, x=int(x)),
                primary_native=None if hdmi is None else dict(x=0, y=0, width=hdmi['width'], height=hdmi['height']))


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=35, **kwargs).stdout.strip()


def save(path, value):
    path = Path(path)
    content = json.dumps(value, sort_keys=True, indent=2) + '\n'
    if path.exists() and path.read_text() == content: return False
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_suffix('.next')
    temp.write_text(content); temp.chmod(0o600); temp.replace(path)
    return True


def active_units():
    output = run(['systemctl', '--user', 'list-units', '--state=active', '--plain', '--no-legend', 'viewflow*.service'])
    return {line.split()[0] for line in output.splitlines() if line.strip()}


def ensure_primary_output(name, geometry):
    """Restore the supervisor-owned primary viewport after a compositor restart."""
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,64}', name):
        raise ValueError('Invalid primary output name')
    monitors = json.loads(run(['hyprctl', '-j', 'monitors', 'all']))
    output = next((monitor for monitor in monitors if monitor['name'] == name), None)
    if output is None:
        # A named output is stable across fresh Hyprland sessions, unlike the
        # automatically allocated HEADLESS-N sequence.
        run(['hyprctl', 'output', 'create', 'headless', name])
        for _ in range(20):
            monitors = json.loads(run(['hyprctl', '-j', 'monitors', 'all']))
            output = next((monitor for monitor in monitors if monitor['name'] == name), None)
            if output is not None:
                break
            time.sleep(.1)
        if output is None:
            raise RuntimeError('Created primary output did not appear: ' + name)
    if output.get('disabled', False):
        expression = ('hl.monitor({ output = ' + json.dumps(name) +
                      ', mode = ' + json.dumps(f'{geometry["width"]}x{geometry["height"]}@60') +
                      ', position = ' + json.dumps(f'{geometry["x"]}x{geometry["y"]}') +
                      ', scale = ' + json.dumps(geometry['scale']) + ', disabled = false })')
        run(['hyprctl', 'eval', expression])
    return output


class Supervisor:
    def __init__(self, settings):
        self.settings = settings
        self.runtime = Path(os.environ['XDG_RUNTIME_DIR']) / 'viewflow'
        self.generated = Path(settings['generated'])
        self.last = None
        self.source = json.loads(Path(settings['mac_template']).read_text())
        self.reverse = json.loads(Path(settings['reverse_template']).read_text())
        self.remote = json.loads(Path(settings['windows_template']).read_text())['desktop']['remote_display']
        self.ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', '-o', 'ServerAliveInterval=3',
                    '-o', 'ServerAliveCountMax=2', settings['mac_ssh']]

    def probe(self):
        return json.loads(run(self.ssh + [shlex.quote(self.settings['mac_helper']) + ' --probe']))

    def selected(self):
        return Path(self.settings['selector']).read_text().strip()

    def local(self):
        monitors = json.loads(run(['hyprctl', '-j', 'monitors']))
        return next(m for m in monitors if m['name'] == self.settings['local_monitor'])

    def keep_windows_available(self):
        # A selected Windows desktop does not depend on Mac SSH availability.
        # Keep the last independent Sidecar route, but retire the primary Mac
        # viewport because the user explicitly selected Windows on that screen.
        if self.selected() != 'windows': return
        before = active_units()
        if MAC in before:
            run(['systemctl', '--user', 'stop', MAC])
        routes = [str(self.runtime / 'macos/config')] if SIDECAR in before else []
        save(self.runtime / 'topology/mac-routes.json', routes)
        ensure_primary_output(self.settings.get('primary_output', 'HEADLESS-1'), self.remote)
        run(['systemctl', '--user', 'start', WINDOWS])

    def reconcile(self, desired):
        # Always let the local Mac verify its selected main display. Temporary
        # SSH/inventory errors leave existing routes running, not disconnected.
        actual = json.loads(run(self.ssh + [shlex.quote(self.settings['mac_helper']) + ' --apply'],
                                input=json.dumps(desired['request'])))
        if self.selected() != desired['right']:
            raise RuntimeError('HDMI selector changed during probe; retrying latest selection')
        before = active_units()
        wanted = set(desired['units'])
        changed = set()
        for name, geometry, native in [('right-macos', desired['primary_remote'], desired['primary_native']),
                                        ('sidecar', desired['sidecar_remote'], desired['sidecar_native'])]:
            if geometry is None or native is None: continue
            config = copy.deepcopy(self.source)
            config['desktop']['remote_display'] = geometry
            config['native_cursor'] = native
            # Two viewports can enter the same Mac independently; do not bind
            # both client endpoints to the legacy fixed UDP source port.
            config['bind'] = '0.0.0.0:0'
            if save(self.generated / (name + '.json'), config):
                changed.add(MAC if name == 'right-macos' else SIDECAR)
        reverse = copy.deepcopy(self.reverse)
        reverse['backend']['args'][:2] = list(map(str, desired['anchor']))
        if save(self.generated / 'linux-receive.json', reverse): changed.add(RECEIVE)
        # Retire only routes that no longer belong to this topology. Stopping
        # the Windows desktop also releases its held input through normal EOF.
        managed = {WINDOWS, MAC, SIDECAR, HID, SHARE, RECEIVE, 'viewflow-windows-input.service',
                   'viewflow-macos-windows.service', 'viewflow-multiscreen-windows.service'}
        stop = (before & managed) - wanted
        stop |= before & changed
        if stop: run(['systemctl', '--user', 'stop', *sorted(stop)])
        if desired['sidecar']:
            # A oneshot layout unit may still be active with the old geometry.
            if SIDECAR in changed or SIDECAR not in before:
                run(['systemctl', '--user', 'restart', 'viewflow-multiscreen-layout.service'])
        else:
            record = self.runtime / 'macos/output.json'
            if record.exists():
                output = json.loads(record.read_text())
                monitors = json.loads(run(['hyprctl', '-j', 'monitors']))
                if any(m['name'] == output['name'] for m in monitors):
                    run(['hyprctl', 'eval', 'hl.monitor({output=' + json.dumps(output['name']) + ',disabled=true})'])
        if MAC in wanted or WINDOWS in wanted:
            ensure_primary_output(self.settings.get('primary_output', 'HEADLESS-1'), desired['primary_remote'])
        # HID transport is shared by both Mac viewports. The primary Mac unit
        # binds to it, so establish it before enabling input capture.
        if HID in wanted: run(['systemctl', '--user', 'start', HID])
        peers = wanted & {MAC, SIDECAR, WINDOWS}
        if peers: run(['systemctl', '--user', 'start', *sorted(peers)])
        routes = []
        if MAC in wanted: routes.append(str(self.runtime / 'desktop-drag/config'))
        if SIDECAR in wanted: routes.append(str(self.runtime / 'macos/config'))
        save(self.runtime / 'topology/mac-routes.json', routes)
        rest = wanted - peers - {HID}
        if rest: run(['systemctl', '--user', 'start', *sorted(rest)])
        if desired['right'] == 'macos' and 'viewflow-wallpaper.service' in before:
            run(['systemctl', '--user', 'stop', 'viewflow-wallpaper.service'])
        after = active_units()
        missing = wanted - after
        if missing: raise RuntimeError('Topology services still starting: ' + ', '.join(sorted(missing)))
        status = dict(desired, mac_main=actual['main'], mac_displays=actual['displays'],
                      active=sorted(after & managed), updated=time.time(), error=None)
        save(self.runtime / 'topology/status.json', status)
        key = (desired['right'], desired['sidecar'], desired['anchor'], desired['sidecar_remote'])
        if key != self.last:
            print(f'topology applied: right={desired["right"]} sidecar={desired["sidecar"]} active={sorted(wanted)}', flush=True)
            self.last = key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--check', action='store_true', help='Read inventory and print the proposed topology without changing it')
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    settings = json.loads(args.config.read_text())
    supervisor = Supervisor(settings)
    if args.check:
        print(json.dumps(plan(supervisor.selected(), supervisor.probe(), supervisor.local(), supervisor.remote), indent=2)); return
    supervisor.runtime.mkdir(parents=True, exist_ok=True)
    lock = (supervisor.runtime / 'display-topology.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    stopping = False
    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    last_error = None
    while not stopping:
        try:
            desired = plan(supervisor.selected(), supervisor.probe(), supervisor.local(), supervisor.remote)
            supervisor.reconcile(desired)
            last_error = None
        except (OSError, ValueError, KeyError, StopIteration, RuntimeError, subprocess.SubprocessError) as error:
            message = str(error)
            if isinstance(error, subprocess.CalledProcessError): message += ': ' + (error.stderr or '')[-1000:]
            if message != last_error: print('topology retry: ' + message, flush=True)
            last_error = message
            try:
                supervisor.keep_windows_available()
            except (OSError, ValueError, subprocess.SubprocessError) as fallback_error:
                print('Windows fallback pending: ' + str(fallback_error), flush=True)
            status_path = supervisor.runtime / 'topology/status.json'
            try: status = json.loads(status_path.read_text())
            except (OSError, ValueError): status = {}
            status.update(error=message, updated=time.time())
            save(status_path, status)
            if args.once: raise
        if args.once: break
        for _ in range(30):
            if stopping: break
            time.sleep(.1)


if __name__ == '__main__':
    main()
