"""Select an exact Hyprland ABI or compile bundled sources in the user data dir.

This module has no Qt dependency and is also used by the Linux autostart helper.
No compositor queries or loads happen at import time.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

PLUGINS = ('viewflow-hyprland', 'viewflow-capture')
PROJECTS = ('hyprland-plugin', 'viewflow-capture')


def host_environment():
    env = os.environ.copy()
    # PyInstaller's library path belongs to the app, not the host toolchain.
    if 'LD_LIBRARY_PATH_ORIG' in env:
        env['LD_LIBRARY_PATH'] = env['LD_LIBRARY_PATH_ORIG']
    elif getattr(__import__('sys'), 'frozen', False):
        env.pop('LD_LIBRARY_PATH', None)
    return env


def output(argv, **kwargs):
    return subprocess.check_output(list(map(str, argv)), text=True, stderr=subprocess.PIPE,
                                   env=host_environment(), **kwargs).strip()


def running_build(version):
    """Hyprland exposes the actual plugin hash as abiHash (not its version tag)."""
    if not isinstance(version, dict):
        raise ValueError('Hyprland version response is not an object')
    commit = version.get('commit', '')
    if not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Hyprland did not report a full build commit')
    api_hash = version.get('abiHash', '')
    if not api_hash:
        # Older forks expose dependency build versions but not abiHash.
        parts = []
        for key, suffix in [('Aquamarine', 'aq'), ('Hyprutils', 'hu'), ('Hyprgraphics', 'hg'),
                            ('Hyprcursor', 'hc'), ('Hyprlang', 'hlg')]:
            value = version.get('build' + key)
            if not value:
                raise ValueError('Hyprland did not report abiHash or dependency build versions; update hyprctl')
            parts.append(suffix + '_' + str(value).rsplit('.', 1)[0])
        api_hash = commit + '_' + '_'.join(parts)
    return dict(commit=commit, api_hash=api_hash, version=version.get('version', ''), tag=version.get('tag', ''))


def exact_variant(manifest, running):
    for variant in manifest.get('hyprland_variants', []):
        if (variant.get('commit') == running['commit'] and
                variant.get('api_hash') == running['api_hash']):
            return variant
    return None


def header_build(env=None):
    """Execute a tiny header-only probe: use upstream's hash function verbatim."""
    env = env or host_environment()
    try:
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'hyprland'],
                            text=True, stderr=subprocess.PIPE, env=env))
        version = subprocess.check_output(['pkg-config', '--modversion', 'hyprland'], text=True, env=env).strip()
        with tempfile.TemporaryDirectory(prefix='viewflow-hyprland-probe-') as temporary:
            source = Path(temporary) / 'probe.cpp'
            api_header = next(Path(flag[2:]) / relative for flag in flags if flag.startswith('-I')
                              for relative in ('hyprland/src/plugins/PluginAPI.hpp', 'src/plugins/PluginAPI.hpp')
                              if (Path(flag[2:]) / relative).is_file())
            api_text = api_header.read_text()
            function = api_text.split('APICALL inline EXPORT const char* __hyprland_api_get_client_hash()', 1)[1].split('// NOLINTEND', 1)[0]
            api_version = re.search(r'#define\s+HYPRLAND_API_VERSION\s+"([^"]+)"', api_text)[1]
            source.write_text('#include <hyprland/src/version.h>\n#include <iostream>\n#include <format>\n#include <string_view>\n'
                              'const char* __hyprland_api_get_client_hash()' + function + '\n'
                              '#define HYPRLAND_API_VERSION "' + api_version + '"\n'
                              'int main() { std::cout << GIT_COMMIT_HASH << "\\n" << '
                              '__hyprland_api_get_client_hash() << "\\n" << HYPRLAND_API_VERSION; }\n')
            executable = Path(temporary) / 'probe'
            subprocess.run([*shlex.split(env.get('CXX', 'c++')), '-std=c++23', *flags,
                            str(source), '-o', str(executable)], env=env, check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            commit, api_hash, api_version = subprocess.check_output([str(executable)], text=True, env=env).splitlines()
        return dict(version=version, commit=commit, api_hash=api_hash, api_version=api_version)
    except (OSError, subprocess.SubprocessError, ValueError, IndexError, StopIteration, TypeError) as error:
        detail = getattr(error, 'stderr', '') or str(error)
        if isinstance(detail, bytes): detail = detail.decode(errors='replace')
        raise RuntimeError('Cannot compile Hyprland header probe. Install matching Hyprland development headers, '
                           'pkg-config, CMake and a C++23 compiler. ' + detail[-4000:]) from error


def source_digest(source):
    digest = hashlib.sha256()
    for path in sorted(source.rglob('*')):
        if path.is_file():
            digest.update(str(path.relative_to(source)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def plugin_paths(directory):
    paths = [directory / (name + '.so') for name in PLUGINS]
    if not all(path.is_file() for path in paths):
        raise RuntimeError('Missing Hyprland plugin binary in ' + str(directory))
    return paths


def resolve_plugins(bundle, manifest, version=None, data_home=None):
    """Return (paths, status). Does not load plugins or modify the bundle."""
    bundle = Path(bundle)
    running = running_build(version if version is not None else json.loads(output(['hyprctl', '-j', 'version'], timeout=5)))
    variant = exact_variant(manifest, running)
    if variant:
        relative = Path(variant['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid plugin variant path')
        return plugin_paths(bundle / relative), 'prebuilt'
    source = bundle / 'plugin-source'
    if not all((source / 'platform' / project / 'CMakeLists.txt').is_file() for project in PROJECTS):
        raise RuntimeError('Bundle is missing plugin-source; reinstall the complete Viewflow bundle')
    base = Path(data_home or os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    key = hashlib.sha256((running['api_hash'] + source_digest(source)).encode()).hexdigest()[:24]
    cache = base / 'viewflow/plugins' / running['commit'] / key
    cache.parent.mkdir(parents=True, exist_ok=True)
    import fcntl
    with (cache.parent / (key + '.lock')).open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (cache / 'build.json').is_file():
            try:
                if all(json.loads((cache / 'build.json').read_text()).get(key) == running[key]
                       for key in ('commit', 'api_hash')):
                    return plugin_paths(cache), 'cached'
            except (ValueError, RuntimeError): pass
        headers = header_build()
        if headers['commit'] != running['commit'] or headers['api_hash'] != running['api_hash']:
            raise RuntimeError('Hyprland headers/compositor ABI mismatch: running ' + running['api_hash'] +
                               '; pkg-config headers ' + headers['api_hash'] +
                               '. Install headers for the running build (or restart into the installed build).')
        with tempfile.TemporaryDirectory(prefix=key + '-', dir=cache.parent) as temporary:
            work = Path(temporary)
            log_path = cache.parent / (key + '.log')
            try:
                with log_path.open('w') as log:
                    for project, name in zip(PROJECTS, PLUGINS):
                        build = work / project
                        for argv in (["cmake", '-S', source / 'platform' / project, '-B', build,
                                      '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTING=OFF'],
                                     ['cmake', '--build', build, '--parallel', '2', '--target', name]):
                            subprocess.run(list(map(str, argv)), env=host_environment(), check=True, stdout=log, stderr=log)
                        shutil.copy2(build / (name + '.so'), work / (name + '.so'))
                result = work / 'result'; result.mkdir()
                for name in PLUGINS: shutil.move(work / (name + '.so'), result / (name + '.so'))
                (result / 'build.json').write_text(json.dumps(headers))
                if cache.exists(): shutil.rmtree(cache)
                result.rename(cache)
            except (OSError, subprocess.SubprocessError) as error:
                raise RuntimeError('Local Hyprland plugin build failed. Install CMake and matching development '
                                   'dependencies. Build log: ' + str(log_path)) from error
    return plugin_paths(cache), 'built'
