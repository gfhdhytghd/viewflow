#!/usr/bin/env python3
"""Viewflow desktop entry point for Windows and Linux; no desktop input at startup."""
import argparse
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import threading
import time

from runtime import DATA, PLATFORM, ROOT, SCRIPTS, InstanceLock, Worker, signal_console, command, expand, load_manifest, materialize, private_write, validate_profile


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
        report['touchpad'] = '触控板组件随应用内置；系统 API 支持和真实手势效果需在此电脑确认。'
    else:
        report['session'] = os.environ.get('XDG_SESSION_TYPE', '未检测到桌面会话')
        report['hyprland_session'] = bool(os.environ.get('HYPRLAND_INSTANCE_SIGNATURE'))
        try:
            result = subprocess.run(['hyprctl', '-j', 'version'], capture_output=True, text=True, timeout=5)
            report['hyprland'] = json.loads(result.stdout)
        except (OSError, ValueError, subprocess.SubprocessError) as error: report['hyprland'] = str(error)
        report['input_devices'] = [{'device': str(path), 'readable': os.access(path, os.R_OK)} for path in sorted(Path('/dev/input').glob('event*'))]
        report['plugin_build'] = manifest.get('hyprland_build', '未知')
    return report


class Application:
    def __init__(self, manifest, auto_start=True):
        import tkinter as tk
        from tkinter import ttk
        self.tk, self.ttk = tk, ttk
        self.root = tk.Tk(); self.root.title('Viewflow'); self.root.geometry('850x620'); self.root.minsize(680, 480)
        self.instance = InstanceLock()
        self.settings = {}
        try: self.settings = json.loads((DATA / 'settings.json').read_text(encoding='utf-8'))
        except (OSError, ValueError): pass
        self.manifest = manifest; self.profile = None; self.workers = []; self.pending = None; self.quitting = False
        self.variables = {}; self.status_vars = {}; self.running = False
        self.message = tk.StringVar(value='导入配对文件，然后设置需要的权限并启动连接。')
        style = ttk.Style()
        if PLATFORM == 'windows': style.theme_use('vista')
        else:
            style.theme_use('clam')
            style.configure('.', background='#f5f6f8', foreground='#202b3a', font=('sans', 10))
            style.configure('TButton', padding=(12, 7))
            style.configure('TNotebook', borderwidth=0)
            style.configure('TNotebook.Tab', padding=(14, 8))
            style.map('TNotebook.Tab', background=[('selected', '#ffffff')])
            style.configure('TCheckbutton', padding=(4, 5))
        style.configure('Title.TLabel', font=('Segoe UI' if PLATFORM == 'windows' else 'sans', 22, 'bold'))
        container = ttk.Frame(self.root, padding=22); container.pack(fill='both', expand=True)
        ttk.Label(container, text='Viewflow', style='Title.TLabel').pack(anchor='w')
        ttk.Label(container, text='窗口 · 输入 · 剪贴板 · 触控板').pack(anchor='w', pady=(4,18))
        tabs = ttk.Notebook(container); tabs.pack(fill='both', expand=True)
        self.connection = ttk.Frame(tabs, padding=18); permissions = ttk.Frame(tabs, padding=18); diagnostics = ttk.Frame(tabs, padding=18)
        tabs.add(self.connection, text='连接与配对'); tabs.add(permissions, text='权限设置'); tabs.add(diagnostics, text='诊断')
        actions = ttk.Frame(self.connection); actions.pack(fill='x')
        ttk.Button(actions, text='导入配对文件', command=self.import_profile).pack(side='left')
        ttk.Button(actions, text='启动', command=self.start).pack(side='left', padx=8)
        ttk.Button(actions, text='停止全部', command=self.stop).pack(side='left')
        self.profile_label = ttk.Label(self.connection, text='尚未配对'); self.profile_label.pack(anchor='w', pady=14)
        self.rows = ttk.Frame(self.connection); self.rows.pack(fill='both', expand=True)
        welcome = ttk.LabelFrame(self.rows, text='首次使用', padding=20); welcome.pack(fill='x', pady=12)
        for title, detail in [('1  导入配对', '沿用已配对电脑的设备身份和连接地址。'), ('2  设置权限', '在权限设置页开启需要的系统权限或驱动。'), ('3  启动连接', '窗口、输入、触控板和剪贴板由同一应用管理。')]:
            ttk.Label(welcome, text=title, font=('Segoe UI' if PLATFORM == 'windows' else 'sans', 12, 'bold')).pack(anchor='w', pady=(8,4))
            ttk.Label(welcome, text=detail, wraplength=600).pack(anchor='w', pady=(0,12))
        ttk.Label(self.connection, text='“正在运行”表示组件已启动；连接和操作效果需在两端确认。', wraplength=650).pack(anchor='w', pady=12)
        self.lock_input = tk.BooleanVar(value=self.settings.get('lock_input', False))
        self.login = tk.BooleanVar(value=self.settings.get('login', False))
        self.build_permissions(permissions)
        ttk.Button(diagnostics, text='导出诊断报告', command=self.export_diagnostics).pack(anchor='w', pady=6)
        ttk.Button(diagnostics, text='打开日志文件夹', command=self.open_logs).pack(anchor='w', pady=6)
        ttk.Label(diagnostics, text='诊断报告不包含配对私钥、窗口内容或截图。\n日志保存在当前用户目录。', wraplength=650).pack(anchor='w', pady=12)
        ttk.Label(container, textvariable=self.message, wraplength=760).pack(anchor='w', pady=(12,0))
        self.root.protocol('WM_DELETE_WINDOW', self.quit)
        path = DATA / 'connection.json'
        if path.exists():
            try: self.activate(json.loads(path.read_text(encoding='utf-8')))
            except Exception as error: self.message.set(str(error))
        self.root.after(200, self.tick)
        if auto_start and self.settings.get('running', False) and self.profile: self.start()

    def build_permissions(self, parent):
        ttk = self.ttk
        if PLATFORM == 'windows':
            text = ('普通窗口、输入和剪贴板使用当前登录会话。\n'
                    '首次联网时按 Windows 提示允许 Viewflow。\n\n'
                    '需要操作 Windows 锁屏时，安装内置输入服务；这一步会由系统请求管理员权限。\n'
                    '原生触控板代码已内置，无需另装 Viewflow HID 驱动。')
            ttk.Label(parent, text=text, wraplength=650).pack(anchor='w', pady=10)
            ttk.Button(parent, text='安装 / 更新锁屏输入服务', command=self.install_service).pack(anchor='w', pady=6)
            ttk.Checkbutton(parent, text='通过输入服务接收锁屏输入（需已安装）', variable=self.lock_input, command=self.lock_changed).pack(anchor='w', pady=6)
            ttk.Button(parent, text='打开防火墙设置', command=lambda: open_path('windowsdefender://network/')).pack(anchor='w', pady=6)
        else:
            text = ('在 Hyprland 会话中使用窗口共享。安装包包含输入和捕获插件。\n'
                    '插件需要匹配当前 Hyprland 版本；检查通过后可点击加载。\n\n'
                    '原始触控板转发需要读取所选 /dev/input/event 设备。\n'
                    '在本地登录会话为该设备启用访问权限后，再启动触控板组件。')
            ttk.Label(parent, text=text, wraplength=650).pack(anchor='w', pady=10)
            ttk.Button(parent, text='加载 Viewflow 插件', command=self.load_plugins).pack(anchor='w', pady=6)
            ttk.Button(parent, text='打开设备权限说明', command=lambda: open_path(ROOT / 'setup/linux-permissions.txt')).pack(anchor='w', pady=6)
        ttk.Checkbutton(parent, text='登录后打开 Viewflow', variable=self.login, command=self.set_login).pack(anchor='w', pady=6)
        ttk.Button(parent, text='检查权限与组件', command=self.check_permissions).pack(anchor='w', pady=6)
        self.permission_text = self.tk.Text(parent, height=8, wrap='word', state='disabled'); self.permission_text.pack(fill='both', expand=True, pady=10)

    def save_settings(self):
        private_write(DATA / 'settings.json', json.dumps(self.settings).encode())

    def lock_changed(self):
        self.settings['lock_input'] = self.lock_input.get(); self.save_settings()
        self.message.set('锁屏输入设置将在下次启动组件时生效。')

    def set_login(self):
        try:
            executable = ROOT / ('Viewflow.exe' if PLATFORM == 'windows' else 'viewflow')
            if PLATFORM == 'windows':
                import winreg
                with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Run') as key:
                    if self.login.get(): winreg.SetValueEx(key, 'Viewflow', 0, winreg.REG_SZ, subprocess.list2cmdline([str(executable), '--autostart']))
                    else:
                        try: winreg.DeleteValue(key, 'Viewflow')
                        except FileNotFoundError: pass
            else:
                path = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'autostart/org.viewflow.app.desktop'
                if self.login.get(): private_write(path, desktop_entry(executable, '--autostart').encode())
                else: path.unlink(missing_ok=True)
            self.settings['login'] = self.login.get(); self.save_settings()
            self.message.set('登录启动设置已保存。')
        except Exception as error:
            self.login.set(self.settings.get('login', False)); self.message.set(str(error))

    def install_service(self):
        try: enable_windows_service(); self.message.set('请完成 Windows 安装提示，然后重新检查服务状态。')
        except Exception as error: self.message.set(str(error))

    def load_plugins(self):
        def work():
            version = json.loads(subprocess.check_output(['hyprctl', '-j', 'version'], timeout=5))
            built = self.manifest.get('hyprland_build', {})
            if not built.get('commit') or built['commit'] != version.get('commit'):
                raise ValueError('插件与当前 Hyprland 版本不匹配，请使用为当前版本构建的安装包。')
            loaded = json.loads(subprocess.check_output(['hyprctl', '-j', 'plugin', 'list'], timeout=5))
            paths = {item.get('path') for item in loaded} if isinstance(loaded, list) else set()
            names = {item.get('name') for item in loaded} if isinstance(loaded, list) else set()
            for name in ('viewflow-hyprland.so', 'viewflow-capture.so'):
                path = str(ROOT / 'plugins' / name)
                if path not in paths and name.removesuffix('.so') not in names:
                    subprocess.run(['hyprctl', 'plugin', 'load', path], check=True, capture_output=True, timeout=10)
            return '已提交插件加载；请检查组件状态。'
        self.background(work, lambda value: self.message.set(value))

    def check_permissions(self):
        def show(value):
            self.permission_text.configure(state='normal'); self.permission_text.delete('1.0', 'end')
            self.permission_text.insert('1.0', json.dumps(value, ensure_ascii=False, indent=2)); self.permission_text.configure(state='disabled')
        self.background(lambda: permission_report(self.manifest), show)

    def background(self, work, done):
        def task():
            try:
                value = work(); self.root.after(0, lambda: done(value))
            except Exception as error:
                message = str(error); self.root.after(0, lambda: self.message.set(message))
        threading.Thread(target=task, daemon=True).start()

    def activate(self, profile):
        validate_profile(profile, self.manifest); materialize(profile, self.manifest)
        self.profile = profile; self.workers = []; self.variables = {}; self.status_vars = {}
        for child in self.rows.winfo_children(): child.destroy()
        self.profile_label.configure(text=profile['name'])
        for item in profile['components']:
            worker = Worker(item, command(item, self.manifest), DATA,
                            expand(item.get('environment', {}), ROOT, DATA, self.manifest))
            self.workers.append(worker)
            selected = self.tk.BooleanVar(value=item.get('enabled', True)); self.variables[item['id']] = selected
            status = self.tk.StringVar(value='已停止'); self.status_vars[item['id']] = status
            row = self.ttk.Frame(self.rows, padding=(0,8)); row.pack(fill='x')
            self.ttk.Checkbutton(row, text=item.get('title', item['id']), variable=selected, command=self.selection_changed).pack(side='left')
            self.ttk.Label(row, textvariable=status, wraplength=380).pack(side='right')

    def import_profile(self):
        from tkinter import filedialog
        path = filedialog.askopenfilename(title='导入 Viewflow 配对文件', filetypes=[('Viewflow', '*.viewflowconnection'), ('JSON', '*.json')])
        if not path: return
        try:
            data = Path(path).read_bytes()
            if len(data) > 4 * 1024 * 1024: raise ValueError('配对文件过大')
            profile = validate_profile(json.loads(data), self.manifest)
            self.stop(); self.pending = profile; self.message.set('正在结束旧连接并保存新配对。')
        except Exception as error: self.message.set(str(error))

    def selection_changed(self):
        for worker in self.workers:
            enabled = self.variables[worker.item['id']].get()
            worker.item['enabled'] = enabled
            if not enabled: worker.stop()
            elif self.running and worker.stopping is None: worker.desired = True
        if self.profile: private_write(DATA / 'connection.json', json.dumps(self.profile).encode())

    def start(self):
        if not self.profile: self.message.set('请先导入配对文件。'); return
        if self.pending is not None or any(w.stopping is not None for w in self.workers):
            self.message.set('正在结束旧连接，请稍候。'); return
        for worker in self.workers:
            if PLATFORM == 'windows':
                worker.environment['VIEWFLOW_WINDOWS_INPUT_SERVICE'] = '1' if self.lock_input.get() else '0'
        self.running = True; self.settings['running'] = True; self.save_settings(); self.selection_changed(); self.message.set('正在启动已启用的组件。')

    def stop(self, persist=True):
        self.running = False
        if persist: self.settings['running'] = False; self.save_settings()
        for worker in self.workers: worker.stop()
        self.message.set('正在结束连接。')

    def tick(self):
        for worker in self.workers:
            if self.running and self.variables[worker.item['id']].get() and worker.stopping is None:
                worker.desired = True
            try: worker.tick()
            except Exception as error: worker.status = str(error)
            self.status_vars[worker.item['id']].set(worker.status)
        if all(w.process is None for w in self.workers):
            if self.quitting: self.instance.close(); self.root.destroy(); return
            if self.pending is not None:
                profile = self.pending; self.pending = None
                try:
                    self.activate(profile); private_write(DATA / 'connection.json', json.dumps(profile).encode())
                    self.message.set('配对已保存，点击启动即可连接。')
                except Exception as error: self.message.set(str(error))
        self.root.after(200, self.tick)

    def quit(self):
        self.quitting = True; self.stop(persist=False)

    def open_logs(self):
        (DATA / 'logs').mkdir(parents=True, exist_ok=True, mode=0o700); open_path(DATA / 'logs')

    def export_diagnostics(self):
        from tkinter import filedialog
        path = filedialog.asksaveasfilename(initialfile='Viewflow-diagnostics.json', defaultextension='.json')
        if not path: return
        report = {'platform': PLATFORM, 'bundle': str(ROOT), 'build': self.manifest.get('build', {}),
                  'running': self.running, 'components': [{'id': w.item['id'], 'status': w.status,
                  'pid': w.process.pid if w.process else None, 'last_exit': w.last_exit} for w in self.workers]}
        try: private_write(Path(path), json.dumps(report, indent=2, ensure_ascii=False).encode()); self.message.set('诊断报告已导出。')
        except Exception as error: self.message.set(str(error))


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
        app = Application(manifest, auto_start=not args.smoke_ui)
        if args.smoke_ui: app.root.after(400, app.quit)
        app.root.mainloop()
    except Exception as error:
        if args.check_bundle: raise
        from tkinter import messagebox
        messagebox.showerror('Viewflow', str(error))
        raise


if __name__ == '__main__':
    main()
