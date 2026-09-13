#!/usr/bin/env python3
"""Create a signed, self-contained drag-to-install Viewflow DMG on macOS.

Uses ds-store and mac-alias to write Finder layout without driving Finder or
changing focus. Signing identity/profile remain those of the supplied app.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(f.read()).hexdigest()


def package(args):
    from ds_store import DSStore
    from mac_alias import Alias
    source = args.app.resolve()
    destination = args.output.resolve()
    if sys.platform != 'darwin' or source.suffix != '.app':
        raise ValueError('Run on macOS with --app Viewflow.app')
    if destination.exists() or destination.suffix != '.dmg':
        raise ValueError('--output must be a new .dmg path')
    run(['codesign', '--verify', '--deep', '--strict', source])
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.viewflow-dmg-', dir=destination.parent) as temp:
        work = Path(temp)
        assets = work / 'assets'
        run(['swift', args.artwork, assets])
        run(['iconutil', '-c', 'icns', assets / 'Viewflow.iconset', '-o', assets / 'Viewflow.icns'])
        prepared = work / 'Viewflow.app'
        run(['ditto', source, prepared])
        info_path = prepared / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIconFile'] = 'Viewflow.icns'
        info_path.write_bytes(plistlib.dumps(info))
        resources = prepared / 'Contents/Resources'
        shutil.copy2(assets / 'Viewflow.icns', resources / 'Viewflow.icns')
        manifest_path = resources / 'build-manifest.json'
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        manifest['packaged_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        manifest['helpers'] = {p.name: sha(p) for p in (prepared / 'Contents/Helpers').iterdir() if p.is_file()}
        manifest['application_sha256'] = sha(prepared / 'Contents/MacOS/Viewflow')
        manifest['packaged_from_verified_app'] = True
        # This is an artifact check, never a claim about physical input or TCC.
        manifest['native_permissions_verified'] = False
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        entitlement_data = run(['codesign', '-d', '--entitlements', ':-', source], stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
        entitlements = work / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(plistlib.loads(entitlement_data)))
        run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp',
             '--entitlements', entitlements, prepared])
        run(['codesign', '--verify', '--deep', '--strict', prepared])
        size = sum(p.stat().st_size for p in prepared.rglob('*') if p.is_file() and not p.is_symlink())
        writable = work / 'layout.dmg'
        run(['hdiutil', 'create', '-size', f'{max(128, size // (1024 * 1024) + 80)}m',
             '-fs', 'HFS+', '-volname', 'Viewflow', writable], stdout=subprocess.DEVNULL)
        mount = work / 'volume'; mount.mkdir()
        attached = False
        try:
            run(['hdiutil', 'attach', '-nobrowse', '-noautoopen', '-mountpoint', mount, writable], stdout=subprocess.DEVNULL)
            attached = True
            run(['ditto', prepared, mount / 'Viewflow.app'])
            (mount / 'Applications').symlink_to('/Applications')
            background = mount / '.background'
            background.mkdir()
            shutil.copy2(assets / 'background.tiff', background / 'background.tiff')
            with DSStore.open(str(mount / '.DS_Store'), 'w+') as store:
                store['.']['bwsp'] = {'ShowStatusBar': False, 'ShowToolbar': False, 'ShowPathbar': False,
                    'ShowSidebar': False, 'ShowTabView': False, 'ContainerShowSidebar': False,
                    'SidebarWidth': 0, 'WindowBounds': '{{180, 120}, {760, 500}}'}
                store['.']['icvp'] = {'viewOptionsVersion': 1, 'backgroundType': 2,
                    'backgroundImageAlias': Alias.for_file(str(background / 'background.tiff')).to_bytes(),
                    'iconSize': 112.0, 'textSize': 13.0, 'gridSpacing': 100.0, 'gridOffsetX': 0.0,
                    'gridOffsetY': 0.0, 'arrangeBy': 'none', 'labelOnBottom': True,
                    'showIconPreview': True, 'showItemInfo': False}
                store['.']['vSrn'] = ('long', 1)
                store['.']['vstl'] = ('type', b'icnv')
                store['Viewflow.app']['Iloc'] = (225, 260)
                store['Applications']['Iloc'] = (535, 260)
            # Validate layout and the embedded signature before sealing the image.
            with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
                assert store['Viewflow.app']['Iloc'] == (225, 260)
                assert store['.']['icvp']['backgroundType'] == 2
            run(['codesign', '--verify', '--deep', '--strict', mount / 'Viewflow.app'])
        finally:
            if attached:
                run(['hdiutil', 'detach', mount], stdout=subprocess.DEVNULL)
        run(['hdiutil', 'convert', writable, '-format', 'UDZO', '-imagekey', 'zlib-level=9', '-o', destination], stdout=subprocess.DEVNULL)
        run(['codesign', '--sign', args.identity, '--timestamp', destination])
        run(['hdiutil', 'verify', destination], stdout=subprocess.DEVNULL)
        # Save an optional finalized app for atomic installation; never overwrite it here.
        if args.prepared_app:
            if args.prepared_app.exists():
                raise ValueError('--prepared-app already exists')
            run(['ditto', prepared, args.prepared_app])
        shutil.copy2(assets / 'background-preview.png', destination.with_suffix('.background.png'))
    digest = sha(destination)
    destination.with_suffix('.dmg.sha256').write_text(f'{digest}  {destination.name}\n')
    print(json.dumps({'dmg': str(destination), 'bytes': destination.stat().st_size, 'sha256': digest}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--prepared-app', type=Path)
    parser.add_argument('--artwork', type=Path, default=ROOT / 'tools/macos-dmg/render-assets.swift')
    package(parser.parse_args())
