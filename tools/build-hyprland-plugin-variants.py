#!/usr/bin/env python3
"""Isolated header generation, plugin builds and CTest for both maintained lines.

Never installs system headers or connects to a compositor. Dependencies must be
available through pkg-config/CMAKE_PREFIX_PATH (private prefixes are supported).
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'platform/desktop-app'))
from hyprland_plugins import header_build, PROJECTS, PLUGINS

RELEASE = '0aa6745f705f2c4b0a5004eb019ef76e5bbdb426'
MAIN = 'd55a55d72a2ecfbb31b875b0b45c27559ce86691'


def run(argv, **kwargs):
    print('+', ' '.join(map(str, argv)), flush=True)
    return subprocess.run(list(map(str, argv)), check=True, **kwargs)


def prepare_headers(checkout, prefix, jobs):
    build = checkout / 'build'
    run(['git', '-C', checkout, 'submodule', 'update', '--init', '--recursive', 'subprojects/udis86'])
    run(['cmake', '-S', checkout, '-B', build, '-DCMAKE_BUILD_TYPE=Release',
         '-DCMAKE_INSTALL_PREFIX=' + str(prefix), '-DCMAKE_INSTALL_LIBDIR=lib'])
    run(['cmake', '--build', build, '--target', 'generate-protocol-headers', '--parallel', jobs])
    # Do not call make installheaders: upstream also writes /usr/share/pkgconfig.
    destination = prefix / 'include/hyprland'
    for path in (checkout / 'src').rglob('*'):
        if path.is_file() and path.suffix in ('.h', '.hpp', '.inc'):
            target = destination / path.relative_to(checkout)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
    protocols = destination / 'protocols'; protocols.mkdir(parents=True, exist_ok=True)
    for path in (checkout / 'protocols').glob('*.h*'): shutil.copy2(path, protocols / path.name)
    pc = prefix / 'share/pkgconfig'; pc.mkdir(parents=True, exist_ok=True)
    shutil.copy2(build / 'hyprland.pc', pc / 'hyprland.pc')


def build_plugins(source, work, destination, env, jobs):
    destination.mkdir(parents=True, exist_ok=True)
    for project, name in zip(PROJECTS, PLUGINS):
        build = work / project
        run(['cmake', '-S', source / 'platform' / project, '-B', build,
             '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTING=ON'], env=env)
        run(['cmake', '--build', build, '--parallel', jobs], env=env)
        run(['ctest', '--test-dir', build, '--output-on-failure'], env=env)
        shutil.copy2(build / (name + '.so'), destination / (name + '.so'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hyprland', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='new output directory')
    parser.add_argument('--release', default=RELEASE, help='upstream release commit/ref')
    parser.add_argument('--main', default=MAIN, help='upstream main commit/ref')
    parser.add_argument('--jobs', default='2')
    parser.add_argument('--keep-work', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    scratch = Path(tempfile.mkdtemp(prefix='viewflow-variants-'))
    variants = []
    try:
        for line, ref in [('release', args.release), ('main', args.main)]:
            checkout = scratch / line
            run(['git', '-C', args.hyprland, 'worktree', 'add', '--detach', checkout, ref])
            try:
                prefix = scratch / (line + '-headers')
                prepare_headers(checkout, prefix, args.jobs)
                env = os.environ.copy()
                env['PKG_CONFIG_PATH'] = str(prefix / 'share/pkgconfig') + os.pathsep + env.get('PKG_CONFIG_PATH', '')
                metadata = header_build(env)
                relative = Path('plugins') / line / metadata['api_hash']
                build_plugins(ROOT, scratch / (line + '-plugins'), output / relative, env, args.jobs)
                variants.append(dict(metadata, line=line, path=str(relative)))
            finally:
                if not args.keep_work:
                    run(['git', '-C', args.hyprland, 'worktree', 'remove', '--force', checkout])
        (output / 'hyprland-build.json').write_text(json.dumps({'hyprland_variants': variants}, indent=2) + '\n')
        print('Built and tested both variants:', output)
    finally:
        if args.keep_work: print('Retained scratch:', scratch)
        else: shutil.rmtree(scratch)


if __name__ == '__main__': main()
