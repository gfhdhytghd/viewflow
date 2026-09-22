#!/usr/bin/env python3
"""Wrap a verified Linux application bundle in a pacman package, without installing it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pkgver', required=True, help='Arch package version without a release suffix')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.+]+', args.pkgver):
        parser.error('invalid package version')
    bundle = args.bundle.resolve(strict=True)
    manifest = json.loads((bundle / 'bundle-manifest.json').read_text())
    if manifest.get('platform') != 'linux' or manifest.get('architecture') != 'x86_64':
        parser.error('an x86_64 Linux bundle is required')
    hyprland = manifest['hyprland_build']['version']
    if not re.fullmatch(r'[A-Za-z0-9_.+]+', hyprland):
        parser.error('invalid Hyprland build version')
    subprocess.run([bundle / 'Viewflow', '--check-bundle'], check=True)
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    artifact = destination / f'viewflow-{args.pkgver}-1-x86_64.pkg.tar.zst'
    if artifact.exists():
        parser.error(f'package already exists: {artifact}')
    # Preserve the bundle hashes: makepkg must not strip/rewrite frozen binaries.
    recipe = f'''pkgname=viewflow
pkgver={args.pkgver}
pkgrel=1
pkgdesc='Cross-computer windows, keyboard, pointer, clipboard and native trackpad forwarding'
arch=('x86_64')
url='https://github.com/gfhdhytghd/viewflow'
license=('GPL-3.0-only')
depends=('glibc' 'gcc-libs')
optdepends=('openssh: native remote input transport'
            'hyprland: window sharing and input; bundled plugin ABI is checked by the GUI'
            'nvidia-utils: NVIDIA GPU components; driver setup is checked by the GUI'
            'mesa: AMD graphics and VA-API driver'
            'intel-media-driver: Intel VA-API driver for recent GPUs'
            'libva-intel-driver: Intel VA-API driver for older GPUs'
            'libva-utils: optional VA-API capability inspection'
            'xdg-utils: open configuration folders from the dashboard')
options=('!strip' '!debug')
_bundle={shlex.quote(str(bundle))}
package() {{
    install -dm755 "$pkgdir/opt/viewflow" "$pkgdir/usr/bin" "$pkgdir/usr/share/applications" "$pkgdir/usr/share/licenses/viewflow"
    cp -a "$_bundle/." "$pkgdir/opt/viewflow/"
    install -m755 "$startdir/viewflow" "$pkgdir/usr/bin/viewflow"
    install -m644 "$startdir/org.viewflow.app.desktop" "$pkgdir/usr/share/applications/org.viewflow.app.desktop"
    install -m644 "$_bundle/LICENSE" "$pkgdir/usr/share/licenses/viewflow/LICENSE"
}}
'''
    # Retain the recipe alongside the artifact for reproducibility with this bundle.
    with tempfile.TemporaryDirectory(prefix='viewflow-makepkg-') as temporary:
        work = Path(temporary)
        (work / 'PKGBUILD').write_text(recipe)
        (work / 'viewflow').write_text('#!/bin/sh\nexec /opt/viewflow/Viewflow "$@"\n')
        desktop = ('[Desktop Entry]\nType=Application\nName=Viewflow\n'
                   'Comment=Windows, input and clipboard across your computers\n'
                   'Exec=/usr/bin/viewflow\nTerminal=false\nCategories=Network;RemoteAccess;\n')
        (work / 'org.viewflow.app.desktop').write_text(desktop)
        env = dict(os.environ, PKGDEST=str(destination), PKGEXT='.pkg.tar.zst')
        subprocess.run(['makepkg', '--noconfirm'], cwd=work, env=env, check=True)
        recipe_dir = destination / f'viewflow-{args.pkgver}-recipe'
        recipe_dir.mkdir()
        for name in ('PKGBUILD', 'viewflow', 'org.viewflow.app.desktop'):
            (recipe_dir / name).write_bytes((work / name).read_bytes())
    if not artifact.is_file():
        raise RuntimeError(f'makepkg did not produce {artifact}')
    with artifact.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    artifact.with_name(artifact.name + '.sha256').write_text(f'{digest}  {artifact.name}\n')
    subprocess.run(['pacman', '-Qip', artifact], check=True)
    print(artifact)


if __name__ == '__main__':
    main()
