#!/usr/bin/env python3
"""Export an existing pairing for the unified Viewflow app, without connecting.

Output contains private pairing material. No credentials enter an application
bundle. Windows/Linux use a version-2 component plan; macOS uses native version 1.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def write_new(path, value):
    encoded = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream: stream.write(encoded)


def mac_profile(args):
    for name in ('certificate', 'private_key', 'authority', 'device_id'):
        if getattr(args, name) is None: raise ValueError(f'macOS export requires --{name.replace("_", "-")}')
    if len(args.device_id) != 32 or any(x not in '0123456789abcdefABCDEF' for x in args.device_id):
        raise ValueError('device ID must be 32 hexadecimal characters')
    destinations = []
    for index, item in enumerate(args.window_peer):
        address, separator, server_name = item.partition(',')
        if not separator or not server_name: raise ValueError('--window-peer format is IP:PORT,TLS_NAME')
        destinations.append({'id': f'peer-{index+1}', 'address': address, 'serverName': server_name, 'captureScale': 2, 'codec': 'h264'})
    profile = {'version': 1, 'name': args.name, 'deviceID': args.device_id,
               'certificatePEM': args.certificate.read_text(encoding='utf-8'), 'privateKeyPEM': args.private_key.read_text(encoding='utf-8'),
               'authorityPEM': args.authority.read_text(encoding='utf-8'), 'inputBind': args.input_bind,
               'windowsBind': args.windows_bind, 'clipboardBind': args.clipboard_bind,
               'windowDestinations': destinations, 'presentationScale': 1.0,
               'presentationOriginX': 0, 'presentationOriginY': 0, 'frameRate': 60, 'maxWindows': 8,
               'performanceMode': 'frame-rate'}
    if args.clipboard_peer:
        address, separator, server_name = args.clipboard_peer.partition(',')
        if not separator or not server_name: raise ValueError('--clipboard-peer format is IP:PORT,TLS_NAME')
        profile['clipboardRemote'] = {'address': address, 'serverName': server_name}
    return profile


def desktop_profile(args):
    if args.plan is None: raise ValueError('Windows/Linux export requires --plan with existing component configurations')
    sys.path.insert(0, str(ROOT / 'platform/desktop-app'))
    from runtime import safe_name, validate_profile
    profile = json.loads(args.plan.read_text(encoding='utf-8'))
    profile.update(version=2, platform=args.platform, name=args.name)
    files = profile.setdefault('files', {})
    for item in args.file:
        name, separator, path = item.partition('=')
        if not separator or not safe_name(name): raise ValueError('--file format is NAME=PATH; NAME must be a filename')
        if name in files: raise ValueError(f'duplicate attachment: {name}')
        files[name] = base64.b64encode(Path(path).read_bytes()).decode('ascii')
    import importlib.util
    spec = importlib.util.spec_from_file_location('desktop_packager', ROOT / 'tools/build-desktop-app.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    validate_profile(profile, {'platform': args.platform, 'programs': {name: '' for name in module.PROGRAMS[args.platform]}, 'scripts': list(__import__('runtime').SCRIPTS) if args.platform == 'linux' else []})
    return profile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['macos', 'windows', 'linux'], required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--file', action='append', default=[], help='attach existing pairing file as NAME=PATH')
    parser.add_argument('--certificate', type=Path)
    parser.add_argument('--private-key', type=Path)
    parser.add_argument('--authority', type=Path)
    parser.add_argument('--device-id')
    parser.add_argument('--input-bind', default='0.0.0.0:44139')
    parser.add_argument('--windows-bind', default='0.0.0.0:44220')
    parser.add_argument('--clipboard-bind', default='0.0.0.0:44141')
    parser.add_argument('--window-peer', action='append', default=[])
    parser.add_argument('--clipboard-peer')
    args = parser.parse_args()
    try:
        profile = mac_profile(args) if args.platform == 'macos' else desktop_profile(args)
        write_new(args.output, profile)
        print(f'Exported {args.platform} pairing to {args.output}; contains private pairing material.')
    except (OSError, ValueError) as error: parser.exit(1, f'Viewflow pairing export: {error}\n')


if __name__ == '__main__': main()
