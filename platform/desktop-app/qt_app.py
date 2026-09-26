"""Qt Quick frontend for the shared Linux/Windows component supervisor."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import queue

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
from pairing_service import PairingService
from pairing_profiles import build_group_profile


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
        self.pairing = None
        self.pairing_error = ''
        self.pending_start = False
        self.pending_reuse = {}
        self.pending_clear = False
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
            try:
                screen = QApplication.primaryScreen()
                size, scale = screen.size(), screen.devicePixelRatio()
                self.pairing = PairingService(DATA / 'pairing', PLATFORM,
                    dict(width=round(size.width() * scale), height=round(size.height() * scale), scale=scale))
                if PLATFORM == 'windows':
                    from pairing_display import windows_share_bounds
                    try: self.pairing.device['share_bounds'] = windows_share_bounds(ROOT / self.manifest['programs']['viewflow_virtual_display'])
                    except (OSError, KeyError, subprocess.SubprocessError): pass
            except Exception as error: self.pairing_error = str(error)
            path = DATA / 'connection.json'
            stored = {}
            if path.exists():
                try:
                    stored = json.loads(path.read_text(encoding='utf-8'))
                    current = self.pairing.connection_state() if self.pairing else None
                    if not stored.get('groupID') or not current or not current['group'] or stored['groupID'] != current['group']['id']:
                        archive = DATA / 'legacy' / ('connection-' + str(time.time_ns()) + '.json')
                        archive.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                        path.replace(archive)
                        self.settings['running'] = False
                        self.save_settings()
                        self.message = '旧版连接已归档。请选择主机或从机，建立唯一连接组。'
                except Exception as error: self.message = str(error)
            if self.pairing:
                try:
                    profile = build_group_profile(self.pairing.connection_state())
                    if profile:
                        previous = {item['id']: item for item in stored.get('components', [])} if stored.get('groupID') == profile.get('groupID') else {}
                        for item in profile['components']:
                            if item['id'] in previous: item['enabled'] = previous[item['id']].get('enabled', True)
                        self.activate(profile)
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

    def component_presentation(self, worker):
        item = worker.item
        title = item.get('title', item['id'])
        parts = title.rsplit(' · ', 1)
        kind = next((k for k in ('windows-receive', 'windows-share', 'desktop-share', 'desktop-receive', 'clipboard') if item['id'].endswith(k)), '')
        icons = {'windows-receive':'windows-receive.svg', 'windows-share':'windows-share.svg',
                 'desktop-share':'keyboard.svg', 'desktop-receive':'keyboard.svg', 'clipboard':'clipboard.svg'}
        labels = {'windows-receive':'接收其他电脑的窗口', 'windows-share':'共享本机窗口',
                  'desktop-share':'共享桌面与输入', 'desktop-receive':'接收桌面与输入', 'clipboard':'剪贴板同步'}
        return dict(displayTitle=self.tr_text(labels.get(kind,parts[-1])),
                    order={'desktop-share':0,'desktop-receive':0,'windows-receive':1,'windows-share':2,'clipboard':3}.get(kind,4),
                    deviceName=parts[0] if len(parts)>1 else '', icon=icons.get(kind,'connection.svg'))

    def publish(self):
        state = dict(platform=PLATFORM, paired=self.profile is not None,
                     profileName=self.profile['name'] if self.profile else (self.pairing.snapshot()['members'][0]['name'] + ' · Viewflow' if self.pairing and self.pairing.snapshot().get('members') else self.tr_text('尚未配对')),
                     running=self.running, busy=self.busy, quitting=self.quitting,
                     transitioning=self.pending is not None or self.pending_clear or any(w.stopping is not None for w in self.workers),
                     message=status_text(self.message, self.language), login=self.login, lockInput=self.lock_input,
                     recallShortcut=self.recall.shortcut, recallStatus=status_text(self.recall.status, self.language),
                     language=self.language, languagePreference=self.language_preference,
                     translations=EN if self.language == 'en' else {},
                     mediaBackend=self.media_backend, mediaRenderNode=self.media_node,
                     mediaDevices=self.media_devices, mediaReport=self.media_report,
                     mediaEditable=not self.running and self.pending is None and not self.busy and not any(w.process is not None for w in self.workers),
                     permissionDetails=self.permission_details,
                     discovery=self.pairing.snapshot() if self.pairing else dict(role='', groupID='', members=[], count=0, maximum=3,
                         machines=[], code='', addresses=[], warning=self.pairing_error),
                     permissionRows=permission_rows(self.permission_report, self.language),
                     pluginCommands=linux_setup.plugin_commands(ROOT, self.manifest, self.permission_report or {}) if PLATFORM == 'linux' else '',
                     linuxSetup=(self.permission_report or {}).get('linux_setup', {}),
                     dependencyHints=linux_setup.dependency_hints((self.permission_report or {}).get('linux_setup', {}), self.language),
                     version=self.manifest.get('build', {}).get('version', self.tr_text('开发版')),
                     components=[dict(id=w.item['id'], title=' · '.join(self.tr_text(part) for part in w.item.get('title', w.item['id']).split(' · ')),
                                      enabled=w.item.get('enabled', True), status=status_text(w.status, self.language), **self.component_presentation(w)) for w in self.workers])
        state['components'].sort(key=lambda c:(c['deviceName'],c['order']))
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

    def activate(self, profile, reuse=None):
        validate_profile(profile, self.manifest)
        from pairing_protocol import valid_id
        data = DATA / 'groups' / valid_id(profile['groupID']) if profile.get('groupID') else DATA
        materialize(profile, self.manifest, ROOT, data)
        workers = [(reuse or {}).get(item['id']) or Worker(item, command(item, self.manifest, ROOT, data), data,
                          expand(item.get('environment', {}), ROOT, data, self.manifest))
                   for item in profile['components']]
        for worker, item in zip(workers, profile['components']): worker.item = item
        if PLATFORM == 'linux':
            for worker in workers:
                worker.environment.update(media_settings.environment(self.media_backend, self.media_node))
        self.profile, self.workers = profile, workers
        self.publish()

    @Slot()
    def showPairingCode(self):
        if self.passive or self.quitting or not self.pairing: return
        try: self.pairing.show_code()
        except Exception as error: self.set_message(str(error))
        self.publish()

    @Slot(str)
    def setPairingRole(self, role):
        if self.passive or self.quitting or not self.pairing: return
        self.background(lambda: self.pairing.set_role(role), lambda _: None)

    @Slot()
    def leaveGroup(self):
        if self.passive or self.quitting or not self.pairing: return
        self.background(self.pairing.leave_group, lambda _: None)

    @Slot(str)
    def removeGroupMember(self, identity):
        if self.passive or self.quitting or not self.pairing: return
        self.background(lambda: self.pairing.remove_member(identity), lambda _: None)

    @Slot()
    def reconnectGroup(self):
        if self.passive or self.quitting or not self.pairing: return
        self.background(self.pairing.restart_connection, lambda _: None)

    @Slot()
    def disconnectGroup(self):
        if self.passive or self.quitting or not self.pairing: return
        self.background(self.pairing.disconnect, lambda _: None)

    @Slot(str, int, int)
    def setDisplayPosition(self, identity, x, y):
        if self.passive or self.quitting or not self.pairing: return
        self.background(lambda: self.pairing.set_display_position(identity, x, y), lambda _: None)

    @Slot()
    def cancelPairingCode(self):
        if self.pairing: self.pairing.cancel_code()
        self.publish()

    @Slot(str, str, str)
    def connectMachine(self, target, code, identity):
        if self.passive or self.quitting or not self.pairing: return
        self.background(lambda: self.pairing.connect(target, code, identity or None), lambda _: None)

    @staticmethod
    def link_signature(profile, item):
        prefix = item.get('peerID', '') + '-'
        return (item, {k: v for k, v in profile.get('configs', {}).items() if k.startswith(prefix)},
                {k: v for k, v in profile.get('files', {}).items() if k.startswith(prefix)})

    def paired_connection(self, event):
        profile = build_group_profile(event)
        if profile is None:
            self.pending = None; self.pending_reuse = {}; self.pending_start = False
            self.pending_clear = True
            self.stop()
            self.set_message('连接已断开，配对关系保留。' if event.get('paused') else '等待从机自动连接。' if event.get('group') else '请选择主机或从机，或等待从机加入当前连接组。')
            return
        same_group = self.profile and self.profile.get('groupID') == profile['groupID']
        old = {worker.item['id']: worker for worker in self.workers} if same_group else {}
        for item in profile['components']:
            if item['id'] in old: item['enabled'] = old[item['id']].item.get('enabled', True)
        auto_start = event.get('reason') in ('joined', 'connected')
        if (self.profile == profile and self.pending is None and not self.pending_clear
                and not any(worker.stopping is not None for worker in self.workers)):
            if auto_start and not self.running: self.start()
            return
        validate_profile(profile, self.manifest)
        reuse = {}
        for item in profile['components']:
            worker = old.get(item['id'])
            if worker and worker.stopping is None and self.link_signature(self.profile, worker.item) == self.link_signature(profile, item):
                reuse[item['id']] = worker
        for worker in self.workers:
            if worker.item['id'] not in reuse: worker.stop()
        self.pending, self.pending_reuse = profile, reuse
        # A later layout/status update must not consume a queued reconnect.
        self.pending_start = self.pending_start or auto_start or self.running or (event.get('reason') == 'restored' and self.settings.get('running', False))
        self.pending_clear = False
        self.set_message('正在同步当前连接组。')

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
        self.set_message('请在配对页面选择主机或从机；旧版配对文件不能与连接组同时使用。')

    def import_path(self, path):
        self.import_profile()

    def selection_changed(self):
        for worker in self.workers:
            if not worker.item.get('enabled', True): worker.stop()
            elif self.running and worker.stopping is None: worker.desired = True
        if self.profile: private_write(DATA / 'connection.json', json.dumps(self.profile).encode())

    def start(self):
        if not self.profile: self.set_message('请先建立或加入连接组。'); return
        if self.pending is not None or any(w.stopping is not None for w in self.workers):
            self.set_message('正在结束旧连接，请稍候。'); return
        for worker in self.workers:
            if PLATFORM == 'windows':
                worker.environment['VIEWFLOW_WINDOWS_INPUT_SERVICE'] = '1' if self.lock_input else '0'
        self.running = True
        self.settings['running'] = True
        self.save_settings()
        self.selection_changed()
        self.set_message('正在启动当前连接组。')
        if self.profile.get('notice'): self.set_message(self.profile['notice'])

    def stop(self, persist=True):
        self.pending_start = False
        self.running = False
        if persist: self.settings['running'] = False; self.save_settings()
        for worker in self.workers: worker.stop()
        self.set_message('正在结束连接。')

    def tick(self):
        if self.passive: return
        if self.pairing and not self.quitting:
            while True:
                try: event = self.pairing.events.get_nowait()
                except queue.Empty: break
                try: self.paired_connection(event)
                except Exception as error: self.set_message(str(error))
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
            retained = self.pending is None or worker.item['id'] in self.pending_reuse
            if self.running and not self.pending_clear and retained and worker.item.get('enabled', True) and worker.stopping is None:
                worker.desired = True
            try: worker.tick()
            except Exception as error: worker.status = str(error)
        if self.pending is not None and all(w.process is None or w.item['id'] in self.pending_reuse for w in self.workers):
            profile, reuse = self.pending, self.pending_reuse
            self.pending = None; self.pending_reuse = {}
            try:
                self.activate(profile, reuse)
                private_write(DATA / 'connection.json', json.dumps(profile).encode())
                if self.pending_start:
                    self.pending_start = False
                    self.start()
                else: self.set_message('连接组已同步，点击启动即可连接。')
            except Exception as error: self.set_message(str(error))
        if all(w.process is None for w in self.workers):
            if self.pending_clear:
                self.pending_clear = False
                self.profile = None; self.workers = []
                (DATA / 'connection.json').unlink(missing_ok=True)
            if self.quitting:
                if self.busy: return
                self.recall.stop()
                self.instance.close()
                self.timer.stop()
                self.finished.emit()
                return
        if self.running and self.message in ('正在启动当前连接组。', '组件进程已启动；正在建立设备连接。', '部分组件正在恢复，请查看下方状态或日志。'):
            active = [w for w in self.workers if w.item.get('enabled', True)]
            if any(w.status.startswith(('启动失败', '组件已退出')) for w in active):
                self.message = '部分组件正在恢复，请查看下方状态或日志。'
            elif active and all(w.process is not None for w in active):
                self.message = '组件进程已启动；正在建立设备连接。'
        self.publish()

    @Slot()
    def quit(self):
        if self.passive:
            self.timer.stop()
            self.finished.emit()
            return
        if self.quitting: return
        self.quitting = True
        if self.pairing:
            threading.Thread(target=self.pairing.close, daemon=True).start()
        self.stop(persist=False)

    def open_logs(self):
        root = DATA / 'groups' / self.profile['groupID'] if self.profile and self.profile.get('groupID') else DATA
        (root / 'logs').mkdir(parents=True, exist_ok=True, mode=0o700)
        open_path(root / 'logs')

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
    if PLATFORM == 'windows' and not smoke:
        import ctypes
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID('org.viewflow.app')
    app = QApplication.instance() or QApplication(sys.argv[:1])
    if PLATFORM == 'linux':
        app.setDesktopFileName('org.viewflow.app')
    app.setApplicationName('Viewflow')
    app.setOrganizationName('Viewflow')
    app.setQuitOnLastWindowClosed(False)
    QQuickStyle.setStyle('Basic')
    icon = QIcon(str(resources() / 'qml/viewflow.svg'))
    app.setWindowIcon(icon)
    model = ApplicationModel(manifest, passive=smoke)
    engine = QQmlApplicationEngine()
    engine.setInitialProperties({'backend': model})
    engine.load(QUrl.fromLocalFile(str(resources() / 'qml/Main.qml')))
    if not engine.rootObjects():
        if model.instance: model.instance.close()
        raise RuntimeError('无法加载 Viewflow QML 界面')
    window = engine.rootObjects()[0]
    model.finished.connect(app.quit)
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
