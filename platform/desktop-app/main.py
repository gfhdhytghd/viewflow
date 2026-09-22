#!/usr/bin/env python3
"""Viewflow desktop entry point for Windows and Linux; no desktop input at startup."""
import argparse
import json
import os
import re
from pathlib import Path
import runpy
import subprocess
import sys

from runtime import PLATFORM, ROOT, SCRIPTS, signal_console, load_manifest, private_write


def resources():
    return Path(getattr(sys, '_MEIPASS', ROOT))


def run_script(name, args):
    if name not in SCRIPTS:
        raise ValueError('unknown bundled script')
    path = resources() / 'scripts' / SCRIPTS[name]
    if not path.exists() and not getattr(sys, 'frozen', False):
        repository = ROOT.parents[1]
        path = repository / ('platform/macos-trackpad-probe' if name == 'native-trackpad-forward' else 'tools') / SCRIPTS[name]
    sys.path.insert(0, str(path.parent))
    if name == 'native-trackpad-forward' and not any(value == '--receiver' or value.startswith('--receiver=') for value in args):
        args = [*args, '--receiver', '/Applications/Viewflow.app/Contents/MacOS/Viewflow']
    sys.argv = [str(path), *args]
    runpy.run_path(str(path), run_name='__main__')


def open_path(path):
    if PLATFORM == 'windows': os.startfile(str(path))
    else: subprocess.Popen(['xdg-open', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def enable_windows_service():
    import ctypes
    script = ROOT / 'setup/install-windows-input-service.ps1'
    binary = ROOT / 'bin/vf-input-service.exe'
    # Preserve the interactive receiver account when UAC uses another admin account.
    account = os.environ.get('USERDOMAIN', '.') + '\\' + os.environ.get('USERNAME', '')
    args = subprocess.list2cmdline(['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script),
                                   '-Binary', str(binary), '-ReceiverAccount', account])
    result = ctypes.windll.shell32.ShellExecuteW(None, 'runas', 'powershell.exe', args, str(ROOT), 1)
    if result <= 32: raise OSError('系统未能启动输入服务安装，请稍后重试')


def permission_report(manifest):
    report = {'platform': PLATFORM, 'checks_post_input': False}
    if PLATFORM == 'windows':
        result = subprocess.run(['sc.exe', 'query', 'ViewflowInput'], capture_output=True, text=True, timeout=5,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        report['input_service'] = result.stdout.strip() or result.stderr.strip() or '未安装锁屏输入服务'
        report['input_service_code'] = result.returncode
        state = re.search(r'STATE\s*:\s*(\d+)', result.stdout)
        report['input_service_state'] = int(state.group(1)) if state else None
        report['touchpad'] = '触控板组件随应用内置；系统 API 支持和真实手势效果需在此电脑确认。'
    else:
        report['session'] = os.environ.get('XDG_SESSION_TYPE', '未检测到桌面会话')
        report['hyprland_session'] = bool(os.environ.get('HYPRLAND_INSTANCE_SIGNATURE'))
        try:
            result = subprocess.run(['hyprctl', '-j', 'version'], capture_output=True, text=True, timeout=5, check=True)
            report['hyprland'] = json.loads(result.stdout)
            if result.returncode == 0 and isinstance(report['hyprland'], dict) and report['hyprland'].get('commit'):
                report['session'] = 'wayland'
                report['hyprland_session'] = True
        except (OSError, ValueError, subprocess.SubprocessError) as error: report['hyprland'] = str(error)
        try:
            result = subprocess.run(['hyprctl', '-j', 'plugin', 'list'], capture_output=True, text=True, timeout=5, check=True)
            report['plugins'] = json.loads(result.stdout)
        except (OSError, ValueError, subprocess.SubprocessError) as error: report['plugins'] = str(error)
        report['input_devices'] = [{'device': str(path), 'readable': os.access(path, os.R_OK)} for path in sorted(Path('/dev/input').glob('event*'))]
        report['plugin_build'] = manifest.get('hyprland_build', '未知')
        from linux_setup import inventory
        report['linux_setup'] = inventory()
    return report



def install_desktop_entry():
    if PLATFORM != 'linux': raise ValueError('desktop entry installation requires Linux')
    directory = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'applications'
    private_write(directory / 'org.viewflow.app.desktop', desktop_entry(ROOT / 'viewflow').encode())


def desktop_entry(executable, arguments=''):
    executable = str(executable)
    # Exec escaping is distinct from shell escaping; percent is a field code.
    escaped = executable.replace('\\', '\\\\\\\\').replace('"', '\\\\"').replace('`', '\\\\`').replace('$', '\\\\$').replace('%', '%%')
    if '\n' in escaped or '\r' in escaped: raise ValueError('unsupported newline in installation path')
    entry = '[Desktop Entry]\nType=Application\nName=Viewflow\nComment=Windows, input and clipboard across your computers\nExec="' + escaped + '"' + (' ' + arguments if arguments else '') + '\nTerminal=false\nCategories=Network;RemoteAccess;\n'
    return entry


def main():
    if PLATFORM == 'windows' and len(sys.argv) == 3 and sys.argv[1] == '--signal-console':
        raise SystemExit(0 if signal_console(int(sys.argv[2])) else 1)
    if len(sys.argv) > 2 and sys.argv[1] == '--run-script':
        run_script(sys.argv[2], sys.argv[3:]); return
    parser = argparse.ArgumentParser()
    parser.add_argument('--autostart', action='store_true')
    parser.add_argument('--install-desktop-entry', action='store_true')
    parser.add_argument('--check-bundle', action='store_true', help='verify inventory without opening UI or starting components')
    parser.add_argument('--smoke-ui', action='store_true', help='construct and close UI without starting components; use an isolated display')
    args = parser.parse_args()
    try:
        manifest = load_manifest()
        if args.install_desktop_entry:
            install_desktop_entry(); return
        if args.check_bundle:
            print(json.dumps({'bundle_valid': True, 'platform': PLATFORM, 'programs': list(manifest['programs']), 'input_posted': False})); return
        from qt_app import run_application
        raise SystemExit(run_application(manifest, smoke=args.smoke_ui))
    except Exception as error:
        if args.check_bundle or args.smoke_ui: raise
        from PySide6.QtWidgets import QApplication, QMessageBox
        from PySide6.QtCore import QLocale
        from runtime import DATA
        from i18n import resolve_language, status_text
        application = QApplication.instance() or QApplication(sys.argv[:1])
        try: preference = json.loads((DATA / 'settings.json').read_text()).get('language', 'system')
        except (OSError, ValueError): preference = 'system'
        QMessageBox.critical(None, 'Viewflow', status_text(str(error), resolve_language(preference, QLocale.system().name())))
        raise


if __name__ == '__main__':
    main()
