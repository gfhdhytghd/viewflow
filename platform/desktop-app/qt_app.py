"""Qt Quick frontend for the shared Linux/Windows component supervisor."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

from PySide6.QtCore import QObject, Property, QTimer, QUrl, Signal, Slot, Qt, QLocale
from PySide6.QtGui import QIcon
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuickControls2 import QQuickStyle
from PySide6.QtWidgets import QApplication, QFileDialog, QMenu, QSystemTrayIcon

from main import desktop_entry, enable_windows_service, open_path, permission_report, resources
from runtime import DATA, PLATFORM, ROOT, InstanceLock, Worker, command, expand, materialize, private_write, validate_profile
from window_recall import DEFAULT_SHORTCUT, RecallController
from i18n import EN, resolve_language, translate, status_text
from permissions import permission_rows
import linux_setup
import media_settings


class ApplicationModel(QObject):
    changed = Signal()
    componentsChanged = Signal()
    finished = Signal()
    completed = Signal(object, object, str)

    def __init__(self, manifest, *, passive=False):
        super().__init__()
        self.manifest = manifest
        self.passive = passive
        self.instance = None if passive else InstanceLock()
        self.settings = {}
        if not passive:
            try: self.settings = json.loads((DATA / 'settings.json').read_text(encoding='utf-8'))
            except (OSError, ValueError): pass
        self.media_backend = self.settings.get('media_backend', 'auto')
        self.media_node = self.settings.get('media_render_node', '')
        try: media_settings.normalize(self.media_backend, self.media_node)
        except ValueError: self.media_backend, self.media_node = 'auto', ''
        self.media_devices = media_settings.render_devices() if PLATFORM == 'linux' else []
        self.media_report = {}
        self.profile = None
        self.language_preference = self.settings.get('language', 'system')
        if self.language_preference not in ('system', 'en', 'zh-CN'):
            self.language_preference = 'system'
        self.language = resolve_language(self.language_preference, QLocale.system().name())
        self.workers = []
        self.pending = None
        self.quitting = False
        self.running = False
        self.busy = False
        self.message = ''
        self.permission_details = ''
        self.permission_report = None
        self.initial_check_pending = not passive and PLATFORM == 'linux'
        self.lock_input = self.settings.get('lock_input', False)
        self.login = self.settings.get('login', False)
        self.recall = RecallController(PLATFORM, ROOT / manifest['programs'].get('viewflow-window-recall', 'bin/viewflow-window-recall.exe'), DATA, self.settings.get('recall_shortcut', DEFAULT_SHORTCUT))
        self._state = {}
        self._components = []
        self.next_recall_poll = 0
        self.completed.connect(self.complete, Qt.ConnectionType.QueuedConnection)
        if not passive:
            path = DATA / 'connection.json'
            if path.exists():
                try: self.activate(json.loads(path.read_text(encoding='utf-8')))
                except Exception as error: self.message = str(error)
        self.publish()
        self.timer = QTimer(self)
        self.timer.setInterval(200)
        self.timer.timeout.connect(self.tick)
        self.timer.start()

    @Property('QVariantMap', notify=changed)
    def state(self):
        return self._state

    @Property('QVariantList', notify=componentsChanged)
    def components(self):
        return self._components

    def publish(self):
        state = dict(platform=PLATFORM, paired=self.profile is not None,
                     profileName=self.profile['name'] if self.profile else self.tr_text('尚未配对'),
                     running=self.running, busy=self.busy, quitting=self.quitting,
                     transitioning=self.pending is not None or any(w.stopping is not None for w in self.workers),
                     message=status_text(self.message, self.language), login=self.login, lockInput=self.lock_input,
                     recallShortcut=self.recall.shortcut, recallStatus=status_text(self.recall.status, self.language),
                     language=self.language, languagePreference=self.language_preference,
                     translations=EN if self.language == 'en' else {},
                     mediaBackend=self.media_backend, mediaRenderNode=self.media_node,
                     mediaDevices=self.media_devices, mediaReport=self.media_report,
                     mediaEditable=not self.running and self.pending is None and not self.busy and not any(w.process is not None for w in self.workers),
                     permissionDetails=self.permission_details,
                     permissionRows=permission_rows(self.permission_report, self.language),
                     pluginCommands=linux_setup.plugin_commands(ROOT, self.manifest, self.permission_report or {}) if PLATFORM == 'linux' else '',
                     linuxSetup=(self.permission_report or {}).get('linux_setup', {}),
                     dependencyHints=linux_setup.dependency_hints((self.permission_report or {}).get('linux_setup', {}), self.language),
                     version=self.manifest.get('build', {}).get('version', self.tr_text('开发版')),
                     components=[dict(id=w.item['id'], title=w.item.get('title', w.item['id']),
                                      enabled=w.item.get('enabled', True), status=status_text(w.status, self.language)) for w in self.workers])
        if state['components'] != self._components:
            self._components = state['components']
            self.componentsChanged.emit()
        if state != self._state:
            self._state = state
            self.changed.emit()

    def set_message(self, value):
        self.message = value
        self.publish()

    def tr_text(self, source):
        return translate(source, self.language)

    @Slot(str)
    def setLanguage(self, preference):
        if self.passive or self.quitting or preference not in ('system', 'en', 'zh-CN'):
            return
        previous = self.language_preference
        self.settings['language'] = preference
        try:
            self.save_settings()
        except OSError as error:
            self.settings['language'] = previous
            self.set_message(str(error))
            return
        self.language_preference = preference
        self.language = resolve_language(preference, QLocale.system().name())
        self.publish()

    @Slot(object, object, str)
    def complete(self, done, value, error):
        self.busy = False
        if not self.quitting:
            if error: self.set_message(error)
            else:
                try: done(value)
                except Exception as failure: self.set_message(str(failure))
        self.publish()

    def background(self, work, done):
        if self.busy or self.quitting: return
        self.busy = True
        self.publish()
        def task():
            try: value, error = work(), ''
            except Exception as failure: value, error = None, str(failure)
            self.completed.emit(done, value, error)
        threading.Thread(target=task, daemon=True).start()

    def activate(self, profile):
        validate_profile(profile, self.manifest)
        materialize(profile, self.manifest, ROOT, DATA)
        workers = [Worker(item, command(item, self.manifest, ROOT, DATA), DATA,
                          expand(item.get('environment', {}), ROOT, DATA, self.manifest))
                   for item in profile['components']]
        if PLATFORM == 'linux':
            for worker in workers:
                worker.environment.update(media_settings.environment(self.media_backend, self.media_node))
        self.profile, self.workers = profile, workers
        self.publish()

    @Slot(str)
    def action(self, name):
        # A smoke render must never start helpers, register shortcuts or mutate settings.
        if self.passive or self.quitting: return
        actions = dict(start=self.start, stop=self.stop, importProfile=self.import_profile,
                       checkPermissions=self.check_permissions, checkMedia=self.check_media, installService=self.install_service,
                       loadPlugins=self.load_plugins, openLogs=self.open_logs,
                       exportDiagnostics=self.export_diagnostics, recall=self.recall_windows,
                       firewall=lambda: open_path('windowsdefender://network/'),
                       deviceHelp=lambda: open_path(ROOT / ('setup/linux-permissions.en.txt' if self.language == 'en' else 'setup/linux-permissions.txt')))
        try:
            if name not in actions: raise ValueError('未知操作')
            actions[name]()
        except Exception as error: self.set_message(str(error))
        self.publish()

    @Slot()
    def copyPluginCommands(self):
        if self.passive or self.quitting: return
        commands = self.state.get('pluginCommands', '')
        if commands:
            QApplication.clipboard().setText(commands)
            self.set_message('插件命令已复制。请在当前 Hyprland 会话的终端中执行。')

    @Slot(str, bool)
    def setOption(self, name, enabled):
        if self.passive or self.quitting: return
        try:
            if name == 'login': self.login = enabled; self.set_login()
            elif name == 'lockInput': self.lock_input = enabled; self.lock_changed()
            else: raise ValueError('未知设置')
        except Exception as error: self.set_message(str(error))
        self.publish()

    @Slot(str, bool)
    def setComponentEnabled(self, name, enabled):
        if self.passive or self.quitting: return
        try:
            for worker in self.workers:
                if worker.item['id'] == name: worker.item['enabled'] = enabled
            self.selection_changed()
        except Exception as error: self.set_message(str(error))
        self.publish()

    @Slot(str)
    def applyShortcut(self, value):
        if self.passive or self.quitting: return
        self.background(lambda: self.recall.configure(value),
                        lambda _: self.set_message('收回窗口快捷键已设置；注册状态见下方。'))

    def recall_windows(self):
        self.background(self.recall.recall, self.set_message)

    def check_permissions(self):
        def show(value):
            self.permission_report = value
            if PLATFORM == 'linux': self.media_devices = media_settings.render_devices()
            self.permission_details = json.dumps(value, ensure_ascii=False, indent=2)
        self.background(lambda: permission_report(self.manifest), show)

    @Slot(str, str)
    def setMedia(self, backend, node):
        if self.passive or self.quitting or PLATFORM != 'linux' or not self.state['mediaEditable']:
            return
        try:
            media_settings.normalize(backend, node)
            previous = dict(self.settings)
            self.settings.update(media_backend=backend, media_render_node=node)
            try: self.save_settings()
            except OSError:
                self.settings = previous
                raise
            self.media_backend, self.media_node = backend, node
            self.media_report = {}
            for worker in self.workers:
                worker.environment.update(media_settings.environment(backend, node))
            self.publish()
        except (ValueError, OSError) as error:
            self.set_message(str(error))

    def check_media(self):
        if PLATFORM != 'linux': return
        backend, node = self.media_backend, self.media_node
        program = ROOT / self.manifest.get('programs', {}).get('viewflow-media-probe', 'bin/viewflow-media-probe')
        def show(value):
            self.media_report = value
            self.media_devices = media_settings.render_devices()
            self.publish()
        self.background(lambda: media_settings.probe(program, backend, node), show)

    def import_profile(self):
        path, _ = QFileDialog.getOpenFileName(None, self.tr_text('导入配对文件'), '',
                                            'Viewflow (*.viewflowconnection);;JSON (*.json)')
        if path: self.import_path(Path(path))

    def import_path(self, path):
        with path.open('rb') as stream: data = stream.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024: raise ValueError('配对文件过大')
        profile = validate_profile(json.loads(data), self.manifest)
        self.stop()
        self.pending = profile
        self.set_message('正在结束旧连接并保存新配对。')

    def selection_changed(self):
        for worker in self.workers:
            if not worker.item.get('enabled', True): worker.stop()
            elif self.running and worker.stopping is None: worker.desired = True
        if self.profile: private_write(DATA / 'connection.json', json.dumps(self.profile).encode())

    def start(self):
        if not self.profile: self.set_message('请先导入配对文件。'); return
        if self.pending is not None or any(w.stopping is not None for w in self.workers):
            self.set_message('正在结束旧连接，请稍候。'); return
        for worker in self.workers:
            if PLATFORM == 'windows':
                worker.environment['VIEWFLOW_WINDOWS_INPUT_SERVICE'] = '1' if self.lock_input else '0'
        self.running = True
        self.settings['running'] = True
        self.save_settings()
        self.selection_changed()
        self.set_message('正在启动已启用的组件。')

    def stop(self, persist=True):
        self.running = False
        if persist: self.settings['running'] = False; self.save_settings()
        for worker in self.workers: worker.stop()
        self.set_message('正在结束连接。')

    def tick(self):
        if self.passive: return
        if self.initial_check_pending and not self.busy and not self.quitting:
            self.initial_check_pending = False
            self.check_permissions()
        # Poll native helpers off the GUI thread; completion is queued back to Qt.
        if not self.quitting and not self.busy and time.monotonic() >= self.next_recall_poll:
            self.next_recall_poll = time.monotonic() + 5
            def recalled(status):
                if status.startswith('收回本机窗口：') and self.settings.get('recall_shortcut') != self.recall.shortcut:
                    self.settings['recall_shortcut'] = self.recall.shortcut
                    self.save_settings()
            self.background(self.recall.poll, recalled)
        for worker in self.workers:
            if self.running and worker.item.get('enabled', True) and worker.stopping is None:
                worker.desired = True
            try: worker.tick()
            except Exception as error: worker.status = str(error)
        if all(w.process is None for w in self.workers):
            if self.quitting:
                if self.busy: return
                self.recall.stop()
                self.instance.close()
                self.timer.stop()
                self.finished.emit()
                return
            if self.pending is not None:
                profile, self.pending = self.pending, None
                try:
                    self.activate(profile)
                    private_write(DATA / 'connection.json', json.dumps(profile).encode())
                    self.set_message('配对已保存，点击启动即可连接。')
                except Exception as error: self.set_message(str(error))
        self.publish()

    @Slot()
    def quit(self):
        if self.passive:
            self.timer.stop()
            self.finished.emit()
            return
        if self.quitting: return
        self.quitting = True
        self.stop(persist=False)

    def open_logs(self):
        (DATA / 'logs').mkdir(parents=True, exist_ok=True, mode=0o700)
        open_path(DATA / 'logs')

    def export_diagnostics(self):
        path, _ = QFileDialog.getSaveFileName(None, self.tr_text('导出诊断报告'), 'Viewflow-diagnostics.json', 'JSON (*.json)')
        if not path: return
        report = {'platform': PLATFORM, 'bundle': str(ROOT), 'build': self.manifest.get('build', {}),
                  'permissions': self.permission_report,
                  'media': {'backend': self.media_backend, 'render_node': self.media_node, 'check': self.media_report},
                  'running': self.running, 'components': [{'id': w.item['id'], 'status': w.status,
                  'pid': w.process.pid if w.process else None, 'last_exit': w.last_exit} for w in self.workers]}
        private_write(Path(path), json.dumps(report, indent=2, ensure_ascii=False).encode())
        self.set_message('诊断报告已导出。')

    def save_settings(self):
        private_write(DATA / 'settings.json', json.dumps(self.settings).encode())

    def lock_changed(self):
        self.settings['lock_input'] = self.lock_input; self.save_settings()
        self.set_message('锁屏输入设置将在下次启动组件时生效。')

    def set_login(self):
        try:
            executable = ROOT / ('Viewflow.exe' if PLATFORM == 'windows' else 'viewflow')
            if PLATFORM == 'windows':
                import winreg
                with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Run') as key:
                    if self.login: winreg.SetValueEx(key, 'Viewflow', 0, winreg.REG_SZ, subprocess.list2cmdline([str(executable), '--autostart']))
                    else:
                        try: winreg.DeleteValue(key, 'Viewflow')
                        except FileNotFoundError: pass
            else:
                path = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'autostart/org.viewflow.app.desktop'
                if self.login: private_write(path, desktop_entry(executable, '--autostart').encode())
                else: path.unlink(missing_ok=True)
            self.settings['login'] = self.login; self.save_settings()
            self.set_message('登录启动设置已保存。')
        except Exception as error:
            self.login = self.settings.get('login', False); self.set_message(str(error))

    def install_service(self):
        try: enable_windows_service(); self.set_message('请完成 Windows 安装提示，然后重新检查服务状态。')
        except Exception as error: self.set_message(str(error))

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
        def done(value):
            self.set_message(value)
            self.check_permissions()
        self.background(work, done)


def run_application(manifest, *, smoke=False):
    app = QApplication.instance() or QApplication(sys.argv[:1])
    app.setApplicationName('Viewflow')
    app.setOrganizationName('Viewflow')
    app.setQuitOnLastWindowClosed(False)
    QQuickStyle.setStyle('Basic')
    model = ApplicationModel(manifest, passive=smoke)
    engine = QQmlApplicationEngine()
    engine.setInitialProperties({'backend': model})
    engine.load(QUrl.fromLocalFile(str(resources() / 'qml/Main.qml')))
    if not engine.rootObjects():
        if model.instance: model.instance.close()
        raise RuntimeError('无法加载 Viewflow QML 界面')
    window = engine.rootObjects()[0]
    model.finished.connect(app.quit)
    icon = QIcon(str(resources() / 'qml/viewflow.svg'))
    app.setWindowIcon(icon)
    tray = None
    if not smoke and QSystemTrayIcon.isSystemTrayAvailable():
        tray = QSystemTrayIcon(icon, app)
        tray.setToolTip('Viewflow')
        menu = QMenu()
        def show():
            window.show()
            window.raise_()
            window.requestActivate()
        open_action = menu.addAction(model.tr_text('打开 Viewflow'), show)
        toggle = menu.addAction(model.tr_text('启动 Viewflow'), lambda: model.action('stop' if model.running else 'start'))
        recall_action = menu.addAction(model.tr_text('收回本机窗口'), lambda: model.action('recall'))
        menu.addSeparator()
        quit_action = menu.addAction(model.tr_text('退出 Viewflow'), model.quit)
        def update_menu():
            open_action.setText(model.tr_text('打开 Viewflow'))
            toggle.setText(model.tr_text('停止全部连接' if model.running else '启动 Viewflow'))
            recall_action.setText(model.tr_text('收回本机窗口'))
            quit_action.setText(model.tr_text('退出 Viewflow'))
        model.changed.connect(update_menu)
        update_menu()
        tray.setContextMenu(menu)
        tray.activated.connect(lambda reason: show() if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
        tray.show()
    window.setProperty('trayAvailable', tray is not None)
    if smoke: QTimer.singleShot(500, model.quit)
    elif model.settings.get('running', False) and model.profile: model.action('start')
    result = app.exec()
    if tray: tray.hide()
    # Destroy QML objects before their Python backend goes out of scope.
    import shiboken6
    shiboken6.delete(engine)
    return result
