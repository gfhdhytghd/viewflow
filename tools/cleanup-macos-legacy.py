#!/usr/bin/env python3
"""Archive retired Viewflow app bundles and launch agents; keep the unified app.

Run on the Mac after verifying /Applications/Viewflow.app. Pairing material,
source checkouts, the installed system extension, and the unified run directory
are deliberately outside this migration. No input or focus is changed.
"""
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile

KEEP = Path('/Applications/Viewflow.app')
LABELS = {'org.viewflow.input-receiver', 'org.viewflow.mesh-linux-source',
          'org.viewflow.mesh-source', 'org.viewflow.mesh-presenter',
          'org.viewflow.window-presenter', 'org.viewflow.material-sign'}
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def collect():
    home = Path.home()
    roots = [home / 'Applications', Path('/Applications')]
    roots += [p for p in home.iterdir() if p.is_dir() and 'viewflow' in p.name.lower()]
    paths = set()
    for root in roots:
        for app in root.glob('*.app'):
            if app == KEEP or app.is_symlink():
                continue
            try:
                info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            except (OSError, ValueError):
                continue
            if str(info.get('CFBundleIdentifier', '')).startswith('org.viewflow.'):
                paths.add(app)
    standalone = Path('/Applications/Viewflow')
    if standalone.is_file() and not standalone.is_symlink():
        paths.add(standalone)
    for plist in (home / 'Library/LaunchAgents').glob('org.viewflow*.plist'):
        if plistlib.loads(plist.read_bytes()).get('Label') in LABELS:
            paths.add(plist)
    for relative in ['.config/viewflow/macos-input-app.py',
                     '.config/viewflow/window-mesh/macos-window-source.py',
                     '.config/viewflow/window-mesh/vf-window-peer']:
        path = home / relative
        if path.is_file():
            paths.add(path)
    return sorted(paths)


def main():
    if sys.platform != 'darwin':
        raise SystemExit('Run on macOS')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(KEEP)], check=True)
    paths = collect()
    if '--apply' not in sys.argv:
        print(json.dumps({'retired_paths': [str(p) for p in paths]}, indent=2))
        return
    domain = f'gui/{os.getuid()}'
    for label in sorted(LABELS):
        subprocess.run(['launchctl', 'disable', f'{domain}/{label}'], check=True)
        # bootout is idempotent: a disabled/unloaded job is already retired.
        subprocess.run(['launchctl', 'bootout', f'{domain}/{label}'], capture_output=True)
    archive_root = Path.home() / 'Library/Application Support/Viewflow/legacy-archive'
    archive_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    archive = archive_root / f'retired-{stamp}.tar.gz'
    with tarfile.open(archive, 'w:gz', compresslevel=1) as tar:
        for path in paths:
            tar.add(path, arcname=str(path).lstrip('/'), recursive=True)
    # Verify archive membership before removing any original.
    with tarfile.open(archive, 'r:gz') as tar:
        names = set(tar.getnames())
    if any(str(path).lstrip('/') not in names for path in paths):
        raise RuntimeError('Archive verification failed; originals retained')
    for path in paths:
        if path.suffix == '.app':
            subprocess.run([LSREGISTER, '-u', str(path)], capture_output=True)
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
    subprocess.run([LSREGISTER, '-f', str(KEEP)], check=True)
    report = {'kept': str(KEEP), 'archive': str(archive),
              'retired_paths': [str(p) for p in paths], 'disabled_labels': sorted(LABELS)}
    (archive_root / f'retired-{stamp}.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'kept': str(KEEP), 'archived_paths': len(paths), 'archive': str(archive)}))


if __name__ == '__main__':
    main()
