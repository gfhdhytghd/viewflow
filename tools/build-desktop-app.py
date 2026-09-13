#!/usr/bin/env python3
"""Build the complete Windows/Linux Viewflow application and installation archive.

Requires native build dependencies plus PyInstaller. Builds locally, never
connects to another computer, installs services, loads plugins or starts input.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
COMMON = ['viewflowd', 'vf-media-peer', 'vf-window-peer', 'vf-clipboard-peer', 'vf-cursor-peer']
PROGRAMS = {
    'linux': COMMON + ['vf-hyprland-windows', 'viewflow_linux_reverse', 'viewflow-linux-window-input'],
    'windows': COMMON + ['vf-input-service', 'viewflow_windows_reverse', 'viewflow_windows_composition_preview',
                        'viewflow-windows-windows', 'viewflow_virtual_display'],
}
NATIVE = {
    'linux': {'linux-reverse': ['viewflow_linux_reverse'], 'linux-window-input': ['viewflow-linux-window-input'],
              'hyprland-plugin': ['viewflow-hyprland'], 'viewflow-capture': ['viewflow-capture']},
    'windows': {'windows-reverse': ['viewflow_windows_reverse', 'viewflow_virtual_display'],
                'windows-composition-preview': ['viewflow_windows_composition_preview'],
                'windows-window-presenter': ['viewflow-windows-windows']},
}


def run(args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def output(args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs).strip()

def source_metadata():
    snapshot = ROOT / "source-build.json"
    if snapshot.is_file(): return json.loads(snapshot.read_text(encoding='utf-8'))
    return {"revision": output(["git", "-C", ROOT, "rev-parse", "HEAD"]),
            "dirty": bool(output(["git", "-C", ROOT, "status", "--porcelain"]))}


def required_files(target):
    extension = '.exe' if target == 'windows' else ''
    result = ['bin/' + x + extension for x in PROGRAMS[target]]
    if target == 'linux': result += ['plugins/viewflow-hyprland.so', 'plugins/viewflow-capture.so']
    return result


def inspect_payload(directory, target):
    missing = [x for x in required_files(target) if not (directory / x).is_file()]
    if missing: raise ValueError('incomplete runtime payload: ' + ', '.join(missing))
    for relative in required_files(target):
        path = directory / relative
        with path.open('rb') as stream: magic = stream.read(4)
        if target == 'linux' and magic != b'\x7fELF': raise ValueError(f'not a Linux binary: {relative}')
        if target == 'windows' and magic[:2] != b'MZ': raise ValueError(f'not a Windows binary: {relative}')


def native_build(target, work):
    payload = work / 'payload'; (payload / 'bin').mkdir(parents=True, exist_ok=True)
    (payload / 'plugins').mkdir(exist_ok=True)
    rust = COMMON + (['vf-input-service'] if target == 'windows' else ['vf-hyprland-windows'])
    argv = ['cargo', 'build', '--locked', '--release', '-p', 'viewflowd']
    if target == 'linux': argv += ['--features', 'native-gpu-nvenc']
    for name in rust: argv += ['--bin', name]
    run(argv, cwd=ROOT)
    extension = '.exe' if target == 'windows' else ''
    target_dir = Path(json.loads(output(['cargo', 'metadata', '--no-deps', '--format-version', '1'], cwd=ROOT))['target_directory'])
    for name in rust: shutil.copy2(target_dir / 'release' / (name + extension), payload / 'bin' / (name + extension))
    for project, targets in NATIVE[target].items():
        build = work / project
        args = ['cmake', '-S', ROOT / 'platform' / project, '-B', build, '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTING=OFF']
        if target == 'windows': args += ['-A', 'x64', '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded']
        run(args)
        run(['cmake', '--build', build, '--config', 'Release', '--parallel', '4', '--target', *targets])
        for name in targets:
            plugin = target == 'linux' and project in ('hyprland-plugin', 'viewflow-capture')
            filename = name + ('.so' if plugin else extension)
            source = build / filename if target == 'linux' else build / 'Release' / filename
            shutil.copy2(source, payload / ('plugins' if plugin else 'bin') / filename)
    if target == 'linux': (payload / 'hyprland-build.json').write_text(json.dumps(hyprland_build()))
    return payload


def linux_dependencies(app):
    """Ship user-space shared libraries; keep the host GPU driver and glibc ABI."""
    libraries = app / 'lib'; libraries.mkdir(exist_ok=True)
    # Plugins load into the host compositor and must use its libraries. Copying
    # the app's FFmpeg/Qt stack into Hyprland would cause symbol collisions.
    host_prefixes = ('libc.so', 'libm.so', 'libpthread.so', 'libdl.so', 'librt.so', 'ld-linux',
                     'libcuda.so', 'libnvidia-', 'libGLX_nvidia', 'libEGL_nvidia')
    dependencies = {}
    for binary in (app / 'bin').iterdir():
        result = output(['ldd', binary])
        if 'not found' in result: raise ValueError(f'unresolved dependency for {binary.name}: {result}')
        for line in result.splitlines():
            match = re.search(r'^\s*(\S+) => (/\S+) \(', line)
            if not match: continue
            name, path = match.groups()
            name = Path(name).name
            if name.startswith(host_prefixes): continue
            dependencies[name] = path
    for name, path in dependencies.items(): shutil.copy2(path, libraries / name)
    for binary in (app / 'bin').iterdir(): run(['patchelf', '--set-rpath', '$ORIGIN/../lib', binary])
    for library in libraries.iterdir(): run(['patchelf', '--set-rpath', '$ORIGIN', library])
    return sorted(dependencies)


def windows_dependencies(app):
    """Resolve native PE imports and include the required Visual C++ runtime."""
    import pefile
    system = Path(os.environ['SystemRoot']) / 'System32'
    visited = set()
    pending = list((app / 'bin').glob('*.exe')) + list((app / 'bin').glob('*.dll'))
    while pending:
        binary = pending.pop()
        if binary.name.lower() in visited: continue
        visited.add(binary.name.lower())
        with pefile.PE(str(binary), fast_load=True) as pe:
            if pe.FILE_HEADER.Machine != 0x8664: raise ValueError(f'not an x64 Windows component: {binary.name}')
            pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT']])
            imports = [entry.dll.decode('ascii') for entry in getattr(pe, 'DIRECTORY_ENTRY_IMPORT', [])]
        for name in imports:
            if name.lower().startswith(('api-ms-win-', 'ext-ms-win-')): continue
            candidates = [app / 'bin' / name, app / '_internal' / name, system / name]
            source = next((path for path in candidates if path.is_file()), None)
            if source is None: raise ValueError(f'unresolved Windows import: {binary.name} -> {name}')
            redistributable = name.lower().startswith(('vcruntime', 'msvcp', 'concrt'))
            if source.parent == system and not redistributable: continue
            destination = app / 'bin' / name
            if not destination.exists(): shutil.copy2(source, destination)
            pending.append(destination)
    return sorted(visited)


def hyprland_build():
    includes = output(['pkg-config', '--cflags-only-I', 'hyprland']).split()
    for flag in includes:
        for relative in ('src/version.h', 'hyprland/src/version.h'):
            path = Path(flag[2:]) / relative
            if path.is_file():
                match = re.search(r'#define\s+GIT_COMMIT_HASH\s+"([a-f0-9]+)"', path.read_text(encoding='utf-8'))
                if match: return {'version': output(['pkg-config', '--modversion', 'hyprland']), 'commit': match[1]}
    raise ValueError('cannot determine Hyprland plugin build ABI from installed headers')


def package(args):
    target = 'windows' if sys.platform == 'win32' else 'linux' if sys.platform == 'linux' else None
    if target is None: raise ValueError('use build-macos-app.py for macOS')
    if platform.machine().lower() not in ('x86_64', 'amd64'): raise ValueError('current Windows/Linux native builds target x86_64')
    build_source = source_metadata()
    destination = args.output.resolve()
    if destination.exists(): raise ValueError('output must be a new directory; installed apps are not overwritten')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.viewflow-package-', dir=destination.parent) as tmp:
        work = Path(tmp)
        native_work = ROOT / 'build' / ('unified-app-' + target)
        native_work.mkdir(parents=True, exist_ok=True)
        payload = args.payload.resolve() if args.payload else native_build(target, native_work)
        inspect_payload(payload, target)
        scripts = work / 'scripts'; scripts.mkdir()
        for name in ('desktop-autostart-linux.py', 'desktop-drag-linux.sh', 'macos-window-source.py'):
            shutil.copy2(ROOT / 'tools' / name, scripts / name)
        for name in ('linux_native_forward.py', 'linux_forward.py'):
            shutil.copy2(ROOT / 'platform/macos-trackpad-probe' / name, scripts / name)
        run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--name', 'Viewflow',
             '--distpath', work / 'dist', '--workpath', work / 'freeze', '--specpath', work,
             '--paths', ROOT / 'platform/desktop-app', '--add-data', str(scripts) + os.pathsep + 'scripts',
             '--hidden-import', 'fcntl' if target == 'linux' else 'ctypes.wintypes',
             '--hidden-import', 'shlex', '--hidden-import', 'select',
             *(['--windowed'] if target == 'windows' else []),
             ROOT / 'platform/desktop-app/main.py'])
        app = work / 'dist/Viewflow'
        for directory in ('bin', 'plugins'):
            if (payload / directory).exists(): shutil.copytree(payload / directory, app / directory)
        # Optional runtime DLLs are explicit payload files, not searched on PATH.
        dll_directory = args.runtime_dlls or payload / 'dll'
        if target == 'windows' and dll_directory.exists():
            for dll in dll_directory.glob('*.dll'): shutil.copy2(dll, app / 'bin' / dll.name)
        setup = app / 'setup'; setup.mkdir()
        shutil.copy2(ROOT / 'tools/install-windows-input-service.ps1', setup / 'install-windows-input-service.ps1')
        shutil.copy2(ROOT / 'platform/desktop-app/linux-permissions.txt', setup / 'linux-permissions.txt')
        shutil.copy2(ROOT / 'platform/desktop-app/install-linux.sh', app / 'install.sh')
        os.chmod(app / 'install.sh', 0o755)
        shutil.copy2(ROOT / 'LICENSE', app / 'LICENSE')
        shutil.copy2(ROOT / 'docs/unified-apps.md', app / 'README.md')
        extra_libraries = linux_dependencies(app) if target == 'linux' else windows_dependencies(app)
        licenses = app / 'licenses'; licenses.mkdir()
        for source, name in [(ROOT / 'platform/windows-reverse/VPL-LICENSE', 'oneVPL.txt'),
                             (ROOT / 'platform/windows-composition-preview/Hyprland-LICENSE', 'Hyprland.txt')]:
            if source.exists(): shutil.copy2(source, licenses / name)
        if target == 'linux':
            launcher = app / 'viewflow'
            launcher.write_text('#!/bin/sh\napp_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$app_dir/Viewflow" "$@"\n')
            launcher.chmod(0o755)
        extension = '.exe' if target == 'windows' else ''
        manifest = {'schema_version': 1, 'platform': target, 'architecture': 'x86_64',
                    'build_system': platform.platform(), 'libc': platform.libc_ver() if target == 'linux' else None,
                    'programs': {x: 'bin/' + x + extension for x in PROGRAMS[target]},
                    'build': dict(build_source, desktop_input_verified=False),
                    'scripts': ['desktop-autostart-linux', 'native-trackpad-forward'] if target == 'linux' else [],
                    'hid': 'windows-system-input-api' if target == 'windows' else 'hyprland-and-evdev',
                    'libraries': extra_libraries}
        if target == 'linux':
            metadata = payload / 'hyprland-build.json'
            if args.payload and not metadata.is_file(): raise ValueError('prebuilt Linux payload requires hyprland-build.json for its actual plugin ABI')
            manifest['hyprland_build'] = json.loads(metadata.read_text(encoding='utf-8')) if metadata.exists() else hyprland_build()
        manifest['files'] = {str(x.relative_to(app)): hashlib.sha256(x.read_bytes()).hexdigest() for x in app.rglob('*') if x.is_file()}
        (app / 'bundle-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        inspect_payload(app, target)
        run([app / ('Viewflow.exe' if target == 'windows' else 'Viewflow'), '--check-bundle'])
        app.rename(destination)
    if args.installer:
        if target == 'windows':
            run([args.iscc, f'/DPayload={destination}', f'/DOutput={destination.parent}', ROOT / 'platform/desktop-app/Viewflow.iss'])
        else:
            archive = destination.with_suffix('.tar.gz')
            if archive.exists(): raise ValueError(f'archive exists: {archive}')
            import tarfile
            with tarfile.open(archive, 'w:gz') as stream: stream.add(destination, arcname='Viewflow')
    print(json.dumps({'application': str(destination), 'platform': target, 'input_verified': False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--payload', type=Path, help='complete previously built native bin/plugins payload')
    parser.add_argument('--runtime-dlls', type=Path, help='explicit directory of Windows native runtime DLLs to include')
    parser.add_argument('--installer', action='store_true', help='build Linux install archive or Windows Inno Setup installer')
    parser.add_argument('--iscc', default='ISCC.exe', help='Inno Setup compiler on Windows')
    args = parser.parse_args()
    try: package(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error: parser.exit(1, f'Viewflow packaging: {error}\n')


if __name__ == '__main__': main()
