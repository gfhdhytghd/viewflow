"""Offscreen UI and supervisor binding checks; never send desktop input."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
os.environ.setdefault('QT_QUICK_BACKEND', 'software')
from PySide6.QtCore import QObject, QUrl, QThread, qInstallMessageHandler
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuickControls2 import QQuickStyle
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
import shiboken6
import qt_app
from i18n import resolve_language


class QtAppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        QQuickStyle.setStyle('Basic')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        self.patch_data = patch.object(qt_app, 'DATA', self.data)
        self.patch_data.start()
        self.addCleanup(self.patch_data.stop)
        self.manifest = {'platform': qt_app.PLATFORM, 'programs': {'fixture': 'bin/fixture'}}
        self.model = qt_app.ApplicationModel(self.manifest, passive=True)
        self.model.timer.stop()
        self.addCleanup(lambda: shiboken6.delete(self.model))

    def profile(self, title='My computer'):
        return {'version': 2, 'platform': qt_app.PLATFORM, 'name': title,
                'components': [{'id': 'windows', 'title': '窗口共享', 'program': 'fixture', 'args': [], 'enabled': True},
                               {'id': 'clipboard', 'title': '剪贴板', 'program': 'fixture', 'args': [], 'enabled': False}]}

    def test_passive_mode_does_not_touch_runtime(self):
        with patch.object(qt_app, 'InstanceLock') as lock, patch.object(qt_app, 'RecallController') as recall, patch.object(qt_app, 'private_write') as write:
            recall.return_value.status = ''
            model = qt_app.ApplicationModel(self.manifest, passive=True)
            model.action('start')
            model.setOption('login', True)
            model.applyShortcut('Ctrl+H')
            model.setLanguage('en')
            model.copyPluginCommands()
            model.tick()
            model.quit()
            lock.assert_not_called()
            write.assert_not_called()
            recall.return_value.poll.assert_not_called()
            recall.return_value.configure.assert_not_called()
            shiboken6.delete(model)
        self.assertEqual(list(self.data.iterdir()), [])

    def test_media_selection_reaches_workers_and_preserves_language(self):
        self.model.activate(self.profile())
        self.model.passive = False
        language = self.model.language
        self.model.setMedia('vaapi', '/dev/dri/renderD129')
        for worker in self.model.workers:
            self.assertEqual(worker.environment['VIEWFLOW_MEDIA_BACKEND'], 'vaapi')
            self.assertEqual(worker.environment['VIEWFLOW_MEDIA_RENDER_NODE'], '/dev/dri/renderD129')
        saved = json.loads((self.data / 'settings.json').read_text())
        self.assertEqual(saved['media_render_node'], '/dev/dri/renderD129')
        self.assertEqual(self.model.language, language)
        self.model.running = True
        self.model.publish()
        self.model.setMedia('nvidia', '/dev/dri/renderD128')
        self.assertEqual(self.model.media_backend, 'vaapi')
        self.model.running = False
        self.model.publish()
        self.model.setMedia('auto', '')
        for worker in self.model.workers:
            self.assertEqual(worker.environment['VIEWFLOW_MEDIA_RENDER_NODE'], '')
        self.model.activate(self.profile('Reloaded'))
        self.assertEqual(self.model.workers[0].environment['VIEWFLOW_MEDIA_BACKEND'], 'auto')

    def test_pages_render_both_platforms_and_minimum_size(self):
        messages = []
        previous = qInstallMessageHandler(lambda kind, context, text: messages.append(text))
        self.addCleanup(lambda: qInstallMessageHandler(previous))
        self.model.activate(self.profile())
        self.model.manifest['hyprland_build'] = {'commit': 'abc'}
        for platform, language in ((p, lang) for p in ('linux', 'windows') for lang in ('zh-CN', 'en')):
            self.model.language = language
            self.model.permission_report = {'platform': platform, 'hyprland': {'version': '0.56.2', 'commit': 'abc'},
                'plugin_build': {'commit': 'abc'}, 'input_devices': [{'device': '/dev/input/event17', 'readable': True}],
                'input_service_code': 1060, 'plugins': [], 'linux_setup': {'arch': True}}
            self.model.permission_details = json.dumps(self.model.permission_report)
            self.model.publish()
            self.model._state['platform'] = platform
            self.model.changed.emit()
            engine = QQmlApplicationEngine()
            engine.setInitialProperties({'backend': self.model})
            engine.load(QUrl.fromLocalFile(str(Path(__file__).parent / 'qml/Main.qml')))
            self.assertTrue(engine.rootObjects(), messages)
            window = engine.rootObjects()[0]
            for width, height in ((900, 720), (720, 520)):
                window.setWidth(width); window.setHeight(height)
                for page in range(4):
                    window.setProperty('page', page)
                    QTest.qWait(30)
                    image = window.grabWindow()
                    self.assertFalse(image.isNull())
                    self.assertEqual(image.width(), round(width * window.devicePixelRatio()))
                    directory = os.environ.get('VIEWFLOW_UI_SCREENSHOTS')
                    if directory:
                        Path(directory).mkdir(parents=True, exist_ok=True)
                        image.save(str(Path(directory) / f'{platform}-{language}-{page}-{width}.png'))
                        if page == 1 and platform == 'linux':
                            flickable = window.findChild(QObject, 'pageScroll').property('contentItem')
                            for offset in (700, 1100):
                                flickable.setProperty('contentY', offset)
                                QTest.qWait(10)
                                window.grabWindow().save(str(Path(directory) / f'{platform}-{language}-setup-{width}-{offset}.png'))
                            flickable.setProperty('contentY', 0)
            shiboken6.delete(engine)
        self.assertEqual(messages, [])

    def test_language_switch_preserves_runtime_and_retranslates_status(self):
        self.model.activate(self.profile('我的电脑'))
        self.model.passive = False
        workers = list(self.model.workers)
        self.model.message = '正在启动已启用的组件。'
        self.model.recall.status = '收回本机窗口：Ctrl+Alt+Shift+H'
        self.model.setLanguage('en')
        self.assertEqual(self.model.state['language'], 'en')
        self.assertEqual(self.model.state['profileName'], '我的电脑')
        self.assertEqual(self.model.state['message'], 'Starting enabled components.')
        self.assertEqual(self.model.state['recallStatus'], 'Bring windows back: Ctrl+Alt+Shift+H')
        self.assertEqual(self.model.state['components'][0]['status'], 'Stopped')
        self.assertEqual(self.model.workers, workers)
        self.assertEqual(json.loads((self.data / 'settings.json').read_text())['language'], 'en')
        self.model.setLanguage('zh-CN')
        self.assertEqual(self.model.state['message'], self.model.message)
        self.model.setLanguage('system')
        self.assertEqual(self.model.language, resolve_language('system', qt_app.QLocale.system().name()))
        self.model.setLanguage('invalid')
        self.assertEqual(self.model.language_preference, 'system')

    def test_language_preference_is_restored(self):
        (self.data / 'settings.json').write_text('{"language":"en"}')
        with patch.object(qt_app, 'InstanceLock'):
            model = qt_app.ApplicationModel(self.manifest)
            model.timer.stop()
            self.assertEqual(model.language_preference, 'en')
            shiboken6.delete(model)

    def test_open_qml_reacts_to_language_changes(self):
        engine = QQmlApplicationEngine()
        engine.setInitialProperties({'backend': self.model})
        engine.load(QUrl.fromLocalFile(str(Path(__file__).parent / 'qml/Main.qml')))
        self.addCleanup(lambda: shiboken6.delete(engine))
        window = engine.rootObjects()[0]
        self.model.passive = False
        self.model.setLanguage('en')
        QTest.qWait(10)
        self.assertEqual(window.property('titles').toVariant()[1], 'Permissions')
        self.model.setLanguage('zh-CN')
        QTest.qWait(10)
        self.assertEqual(window.property('titles').toVariant()[1], '权限设置')

    def test_gui_has_no_linux_package_installation_entry(self):
        self.assertFalse(hasattr(self.model, 'installLinux'))
        self.assertFalse(hasattr(qt_app.linux_setup, 'install_plan'))
        self.assertFalse(hasattr(qt_app.linux_setup, 'run_install'))

    def test_component_toggle_and_stop_preserve_other_workers(self):
        self.model.activate(self.profile())
        self.model.passive = False
        self.model.start()
        self.assertTrue(self.model.workers[0].desired)
        self.assertFalse(self.model.workers[1].desired)
        self.model.setComponentEnabled('clipboard', True)
        self.model.setComponentEnabled('windows', False)
        self.assertFalse(self.model.workers[0].desired)
        self.assertTrue(self.model.workers[1].desired)
        self.assertTrue(self.model.running)
        self.model.stop()
        self.assertFalse(any(worker.desired for worker in self.model.workers))
        saved = json.loads((self.data / 'connection.json').read_text())
        self.assertFalse(saved['components'][0]['enabled'])
        self.assertTrue(saved['components'][1]['enabled'])

    def test_pairing_waits_for_old_workers_and_invalid_import_keeps_profile(self):
        self.model.activate(self.profile('Old'))
        self.model.passive = False
        self.model.next_recall_poll = float('inf')
        worker = self.model.workers[0]
        worker.process = Mock()
        worker.stop = Mock()
        worker.tick = Mock()
        incoming = self.data / 'new.viewflowconnection'
        incoming.write_text(json.dumps(self.profile('New')))
        self.model.import_path(incoming)
        self.model.tick()
        self.assertEqual(self.model.profile['name'], 'Old')
        self.assertTrue(self.model.state['transitioning'])
        worker.process = None
        self.model.tick()
        self.assertEqual(self.model.profile['name'], 'New')
        incoming.write_text('{}')
        with self.assertRaises(ValueError): self.model.import_path(incoming)
        self.assertEqual(self.model.profile['name'], 'New')

    def test_background_completion_runs_on_qt_thread(self):
        completed = []
        self.model.background(lambda: 'ready', lambda value: completed.append((value, QThread.currentThread())))
        for _ in range(100):
            if completed: break
            QTest.qWait(10)
        self.assertEqual(completed, [('ready', self.app.thread())])
        self.assertFalse(self.model.busy)

    def test_close_preserves_running_preference_until_workers_exit(self):
        self.model.activate(self.profile())
        self.model.passive = False
        self.model.instance = Mock()
        self.model.recall.stop = Mock()
        self.model.start()
        worker = self.model.workers[0]
        worker.process = Mock()
        worker.stop = Mock()
        worker.tick = Mock()
        finished = []
        self.model.finished.connect(lambda: finished.append(True))
        self.model.quit()
        self.model.tick()
        self.assertEqual(finished, [])
        worker.process = None
        self.model.tick()
        self.assertEqual(finished, [True])
        self.assertTrue(json.loads((self.data / 'settings.json').read_text())['running'])


if __name__ == '__main__': unittest.main()
