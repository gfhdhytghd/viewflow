"""Read-only Linux dependency inventory and user-copyable plugin commands."""
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess

DRIVERS = ('nvidia-open', 'nvidia-open-lts', 'nvidia-open-dkms', 'nvidia', 'nvidia-lts', 'nvidia-dkms')
HEADERS = {'linux': 'linux-headers', 'linux-lts': 'linux-lts-headers',
           'linux-zen': 'linux-zen-headers', 'linux-hardened': 'linux-hardened-headers'}
PLUGINS = ('viewflow-hyprland', 'viewflow-capture')


def dependency_hints(report, language):
    from i18n import translate
    if not report:
        return [translate('先检查环境以显示所需依赖。', language)]
    hints = []
    installed = report.get('packages', {})
    if report.get('arch'):
        if 'hyprland' not in installed:
            hints.append(translate('窗口共享需要安装：hyprland。', language))
        vendors = {device.get('vendor') for device in report.get('gpu_devices', []) if device.get('driver') != 'vfio-pci'}
        if '0x10de' in vendors:
            hints.append(translate('NVIDIA：NVENC / NVDEC 需要 nvidia-utils 和与显卡、内核匹配的驱动。', language))
        if '0x1002' in vendors:
            hints.append(translate('AMD：VA-API 通常需要 mesa、libva；libva-utils 可用于检查硬件能力。', language))
        if '0x8086' in vendors:
            hints.append(translate('Intel：VA-API 通常需要 intel-media-driver、libva；旧型号可能需要 libva-intel-driver。', language))
    else:
        hints.append(translate('请使用发行版的软件包管理器安装 Hyprland 和对应显卡的视频加速运行库。', language))
    hints.append(translate('VA-API 已接入媒体管线；依赖已安装不代表硬件链路可用，请运行合成媒体检查。', language))
    return hints


def query(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, errors='replace',
                                timeout=8, env={**os.environ, 'LC_ALL': 'C'})
        return {'code': result.returncode, 'output': (result.stdout + result.stderr).strip()}
    except (OSError, subprocess.SubprocessError) as error:
        return {'code': None, 'output': str(error)}


def read(path):
    try: return Path(path).read_text().strip()
    except OSError: return ''


def inventory():
    try: distro = platform.freedesktop_os_release()
    except OSError: distro = {}
    kernel = platform.release()
    kernel_package = read(Path('/usr/lib/modules') / kernel / 'pkgbase')
    devices = []
    for device in sorted(Path('/sys/bus/pci/devices').glob('*')):
        if read(device / 'class').startswith('0x03'):
            devices.append({'vendor': read(device / 'vendor'), 'device': read(device / 'device'),
                            'driver': (device / 'driver').resolve().name if (device / 'driver').exists() else ''})
    report = {'distro': distro.get('PRETTY_NAME', distro.get('ID', 'Linux')),
              'arch': distro.get('ID') == 'arch' or 'arch' in distro.get('ID_LIKE', '').split(),
              'kernel': kernel, 'kernel_package': kernel_package, 'gpu_devices': devices,
              'nvidia_kernel': read('/sys/module/nvidia/version'),
              'tools': {name: shutil.which(name) or '' for name in ('hyprctl', 'hyprpm', 'pacman', 'nvidia-smi')},
              'packages': {}, 'repository_versions': {}, 'custom_nvidia_packages': []}
    if report['arch'] and report['tools']['pacman']:
        names = ('hyprland', 'nvidia-utils', 'mesa', 'libva', 'libva-utils', 'intel-media-driver', 'libva-intel-driver', *DRIVERS, *HEADERS.values())
        installed = query(['/usr/bin/pacman', '-Q'])
        # Missing packages return nonzero alongside the successfully queried packages.
        for line in installed['output'].splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] in names:
                report['packages'][parts[0]] = parts[1]
            if len(parts) == 2 and parts[0] not in names and re.match(r'^nvidia-(?:\d+xx|beta|vulkan|tkg|all|open-dkms-|dkms-)', parts[0]):
                report['custom_nvidia_packages'].append(parts[0])
        repository = query(['/usr/bin/pacman', '-Si', 'hyprland', 'nvidia-utils'])
        name = ''
        for line in repository['output'].splitlines():
            key, separator, value = line.partition(':')
            if not separator: continue
            if key.strip() == 'Name': name = value.strip()
            if key.strip() == 'Version' and name in ('hyprland', 'nvidia-utils'):
                report['repository_versions'][name] = value.strip()
    if any(device['vendor'] == '0x10de' for device in devices):
        report['nvidia_query'] = query(['nvidia-smi', '--query-gpu=name,driver_version', '--format=csv,noheader'])
    return report


def plugin_commands(root, manifest, report):
    version = report.get('hyprland', {})
    built = manifest.get('hyprland_build', {})
    if not isinstance(version, dict) or not isinstance(built, dict) or not built.get('commit') or built['commit'] != version.get('commit'):
        return ''
    loaded = report.get('plugins')
    if not isinstance(loaded, list):
        return ''
    names = {item.get('name') for item in loaded if isinstance(item, dict)}
    return '\n'.join(shlex.join(['hyprctl', 'plugin', 'load', str(root / 'plugins' / (name + '.so'))])
                     for name in PLUGINS if name not in names)
