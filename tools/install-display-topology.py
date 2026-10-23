#!/usr/bin/env python3
"""Install the Linux topology supervisor and route-specific service overrides."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mac-ssh', required=True)
    parser.add_argument('--mac-helper', required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    home = Path.home(); config = home / '.config/viewflow'; units = home / '.config/systemd/user'
    runtime = Path(os.environ['XDG_RUNTIME_DIR']) / 'viewflow'
    generated = config / 'topology'
    peer = home / '.local/lib/viewflow/topology/vf-cursor-peer'
    settings = dict(mac_ssh=args.mac_ssh, mac_helper=args.mac_helper, generated=str(generated),
        mac_template=str(config / 'macos-input-source.json'), windows_template=str(config / 'desktop-source.json'),
        reverse_template=str(home / '.local/state/viewflow/window-mesh-20260910/linux-receive.json'),
        selector=str(home / '.local/state/hyprv/hdmi-target'), local_monitor='DP-4',
        primary_output='HEADLESS-1')
    files = {
        config / 'display-topology.json': json.dumps(settings, indent=2) + '\n',
        units / 'viewflow-display-topology.service': f'''[Unit]
Description=Viewflow automatic HDMI and Sidecar topology
After=graphical-session.target network-online.target
[Service]
ExecStart=/usr/bin/python3 {ROOT}/tools/display_topology.py --config {config}/display-topology.json
Restart=on-failure
RestartSec=3
TimeoutStopSec=40
[Install]
WantedBy=default.target
''',
        units / 'viewflow-desktop.service.d/95-three-screen-layout.conf': '''[Unit]
# Sidecar output is managed by the topology supervisor, not Windows startup.
After=graphical-session.target
''',
        units / 'viewflow-macos-input.service.d/99-topology.conf': f'''[Service]
ExecStart=
ExecStart=/usr/bin/python3 {ROOT}/tools/desktop-autostart-linux.py --config {generated}/right-macos.json --monitor DP-4 --peer {peer} --existing-output HEADLESS-1
''',
        units / 'viewflow-multiscreen-layout.service': f'''[Unit]
Description=Viewflow Sidecar viewport
After=graphical-session.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 {ROOT}/tools/multiscreen-input-linux.py --config {generated}/sidecar.json --route macos --prepare-only
''',
        units / 'viewflow-multiscreen-macos.service': f'''[Unit]
Description=Viewflow Sidecar input route
Requires=viewflow-multiscreen-layout.service
After=viewflow-multiscreen-layout.service
[Service]
Environment=VIEWFLOW_CURSOR_EXTERNAL_TOUCHPAD=1
ExecStart=/usr/bin/python3 {ROOT}/tools/multiscreen-input-linux.py --config {generated}/sidecar.json --route macos --peer {peer}
Restart=on-failure
RestartSec=2
TimeoutStopSec=20
KillMode=mixed
''',
        units / 'viewflow-macos-hid.service.d/zz-display-topology.conf': f'''[Unit]
PartOf=
After=
After=network-online.target
[Service]
ExecStart=
ExecStart=/usr/bin/python3 -u {ROOT}/platform/macos-trackpad-probe/linux_native_forward.py forward --device /dev/input/event17 --ssh {args.mac_ssh} --route-config {runtime}/desktop-drag/config --ready-file {runtime}/cursor-ready --additional-route {runtime}/macos/config,{runtime}/macos/cursor-ready,macos --receiver /Applications/Viewflow.app/Contents/MacOS/Viewflow
''',
        units / 'viewflow-macos-receiver.service.d/zz-display-topology.conf': f'''[Service]
ExecStart=
ExecStart={home}/.local/lib/viewflow/macos/vf-window-peer --config {generated}/linux-receive.json
''',
        units / 'viewflow-topology-windows.service': f'''[Unit]
Description=Viewflow Linux windows on all active Mac viewports
After=graphical-session.target
[Service]
Environment=EGL_PLATFORM=wayland
Environment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
ExecStart=/usr/bin/python3 {ROOT}/tools/macos-window-share-linux.py --routes-file {runtime}/topology/mac-routes.json --remote {args.mac_ssh.rsplit('@', 1)[-1]}:44221 --peer {home}/.local/lib/viewflow/macos/vf-window-peer --source {home}/.local/lib/viewflow/macos/vf-hyprland-windows --input-native {ROOT}/build/macos-window-input/viewflow-linux-window-input
Restart=on-failure
RestartSec=2
TimeoutStopSec=20
KillMode=mixed
''',
    }
    if args.check:
        print('\n'.join(map(str, files))); return
    backup = home / '.local/state/viewflow' / ('topology-backup-' + time.strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True)
    manifest = []
    for index, (path, content) in enumerate(files.items()):
        previous = None
        if path.exists():
            previous = str(backup / str(index)); shutil.copy2(path, previous)
        manifest.append(dict(path=str(path), backup=previous))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content); path.chmod(0o600 if path.suffix == '.json' else 0o644)
    (backup / 'files.json').write_text(json.dumps(manifest, indent=2))
    peer.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'target/debug/vf-cursor-peer', peer.with_suffix('.next'))
    peer.with_suffix('.next').replace(peer)
    # Only the supervisor is enabled; targets are reconciled after discovery.
    old = ['viewflow-desktop.service', 'viewflow-macos-input.service', 'viewflow-windows-input.service',
           'viewflow-macos-hid.service', 'viewflow-macos-receiver.service', 'viewflow-macos-windows.service']
    enabled = {unit: subprocess.run(['systemctl', '--user', 'is-enabled', unit], capture_output=True, text=True).stdout.strip() for unit in old}
    (backup / 'enabled.json').write_text(json.dumps(enabled, indent=2))
    subprocess.run(['systemctl', '--user', 'disable', *old], check=True)
    subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', '--user', 'enable', 'viewflow-display-topology.service'], check=True)
    print(f'Installed; rollback files: {backup}; supervisor not started yet')


if __name__ == '__main__': main()
