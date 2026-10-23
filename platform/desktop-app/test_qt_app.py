"""Offscreen UI and supervisor binding checks; never send desktop input."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

# Never inherit a real Wayland/Windows platform from the user's desktop.
os.environ['QT_QPA_PLATFORM'] = 'offscreen'
os.environ['QT_QUICK_BACKEND'] = 'software'
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
        self.patch_pairing = patch.object(qt_app, 'PairingService')
        self.mock_pairing = self.patch_pairing.start()
        self.mock_pairing.return_value.snapshot.return_value = dict(machines=[], code='', addresses=[], warning='')
        self.addCleanup(self.patch_pairing.stop)
        self.manifest = {'platform': qt_app.PLATFORM, 'programs': {'fixture': 'bin/fixture'}}
        self.model = qt_app.ApplicationModel(self.manifest, passive=True)
        self.model.timer.stop()
        self.addCleanup(lambda: shiboken6.delete(self.model))

    def profile(self, title='My computer'):
        return {'version': 2, 'platform': qt_app.PLATFORM, 'name': title,
                'components': [{'id': 'windows', 'title': '窗口共享', 'program': 'fixture', 'args': [], 'enabled': True},
                               {'id': 'clipboard', 'title': '剪贴板', 'program': 'fixture', 'args': [], 'enabled': False}]}

    def test_display_drag_previews_snap_and_saves_snapped_position(self):
        from PySide6.QtCore import Qt, QPointF
        from PySide6.QtQuick import QQuickItem
        self.model._state['discovery'].update(role='host', groupID='test', displays=[
            dict(id='host',name='Host',x=0,y=0,width=100,height=100,host=True),
            dict(id='client',name='Client',x=130,y=30,width=80,height=60,host=False)])
        engine = QQmlApplicationEngine()
        engine.setInitialProperties({'backend': self.model})
        engine.load(QUrl.fromLocalFile(str(Path(__file__).parent/'qml/Main.qml')))
        self.addCleanup(lambda: shiboken6.delete(engine))
        window=engine.rootObjects()[0]; window.setProperty('page',3); QTest.qWait(30)
        def named(item,name):
            if item.objectName()==name:return item
            for child in item.childItems():
                found=named(child,name)
                if found is not None:return found
        tile=named(window.contentItem(),'displayTile-client')
        canvas=named(window.contentItem(),'displayCanvas')
        layout=named(window.contentItem(),'displayLayout')
        saved=[]; layout.positionChanged.connect(lambda identity,x,y:saved.append((identity,x,y)))
        zoom=canvas.property('zoom')
        start=tile.mapToScene(QPointF(tile.width()/2,tile.height()/2)).toPoint()
        target=start+QPointF(-25*zoom,-27*zoom).toPoint()
        expected_y=round(30+(target.y()-start.y())/zoom)
        QTest.mousePress(window,Qt.MouseButton.LeftButton,Qt.KeyboardModifier.NoModifier,start)
        QTest.mouseMove(window,target,30)
        QTest.qWait(20)
        guides=canvas.property('guides').toVariant()
        self.assertTrue(guides)
        self.assertEqual(saved,[])
        # Status publications during a held drag must not replace its MouseArea.
        for step in range(4):
            self.model._state['message'] = f'Component status {step}'
            self.model.changed.emit()
            QTest.qWait(210)
            self.assertTrue(shiboken6.isValid(tile), 'status refresh destroyed the held display tile')
            self.assertIs(named(window.contentItem(),'displayTile-client'), tile)
            self.assertEqual(saved, [])
            target += QPointF(0, 3).toPoint()
            expected_y=round(30+(target.y()-start.y())/zoom)
            QTest.mouseMove(window,target,20)
            QTest.qWait(10)
            self.assertAlmostEqual(tile.property('preview').toVariant()['y'],expected_y)
        window.grabWindow().save('/tmp/viewflow-edge-snap-preview.png')
        QTest.mouseRelease(window,Qt.MouseButton.LeftButton,Qt.KeyboardModifier.NoModifier,target)
        self.assertEqual(saved,[('client',100,expected_y)])
        self.model._state['discovery']['displays'][1].update(x=100,y=expected_y)
        self.model.changed.emit(); QTest.qWait(30)
        tile=named(window.contentItem(),'displayTile-client')
        host=named(window.contentItem(),'displayTile-host')
        self.assertAlmostEqual(tile.x(),host.x()+host.width(),places=5)
        self.assertAlmostEqual(tile.y()-host.y(),expected_y*canvas.property("zoom"),places=5)

    def test_long_device_names_keep_component_rows_compact(self):
        profile = self.profile()
        for item in profile['components']:
            item['title'] = 'linhaikuodeMac-mini.local · 剪贴板同步'
        self.model.activate(profile)
        self.model.language = 'en'; self.model.publish()
        self.assertTrue(all('Clipboard' in item['title'] for item in self.model.components))
        engine = QQmlApplicationEngine()
        engine.setInitialProperties({'backend': self.model})
        engine.load(QUrl.fromLocalFile(str(Path(__file__).parent/'qml/Main.qml')))
        self.addCleanup(lambda: shiboken6.delete(engine))
        window = engine.rootObjects()[0]
        from PySide6.QtQuick import QQuickItem
        def cards(item):
            return ([item] if item.objectName() == 'componentCard' else []) + [c for child in item.childItems() for c in cards(child)]
        for width, height in ((900, 720), (820, 1116), (1200, 1600)):
            window.setWidth(width); window.setHeight(height); QTest.qWait(30)
            rows = cards(window.contentItem())
            self.assertEqual(len(rows), 2)
            self.assertTrue(all(50 <= row.height() < 140 for row in rows), [row.height() for row in rows])
        window.setWidth(900); window.setHeight(720); QTest.qWait(30)
        window.grabWindow().save('/tmp/viewflow-compact-ui.png')

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

    def test_group_admission_replaces_legacy_connection(self):
        self.model.activate(self.profile('Legacy'))
        self.model.running = True
        worker = self.model.workers[0]
        worker.process = Mock()
        worker.stop = Mock()
        incoming = dict(self.profile('Group'), groupID='a'*32)
        with patch.object(qt_app, 'build_group_profile', return_value=incoming):
            self.model.paired_connection(dict(reason='joined'))
        worker.stop.assert_called_once()
        self.assertEqual(self.model.pending, incoming)
        self.assertTrue(self.model.pending_start)
        self.assertEqual(self.model.pending_reuse, {})

    def test_third_member_keeps_existing_group_workers(self):
        old = dict(self.profile('Group'), groupID='a'*32)
        self.model.activate(old)
        self.model.running = True
        workers = list(self.model.workers)
        for worker in workers:
            worker.process = Mock()
            worker.stop = Mock()
            worker.tick = Mock()
        new = dict(old, components=[*old['components'], dict(id='third', peerID='c'*32,
                   title='Third computer', program='fixture', args=[], enabled=False)])
        with patch.object(qt_app, 'build_group_profile', return_value=new):
            self.model.paired_connection(dict(reason='joined'))
        self.assertEqual(set(self.model.pending_reuse), {'windows', 'clipboard'})
        for worker in workers: worker.stop.assert_not_called()
        self.model.passive = False
        self.model.next_recall_poll = float('inf')
        with patch.object(self.model, 'start'):
            self.model.tick()
        self.assertIs(self.model.workers[0], workers[0])
        self.assertEqual(len(self.model.workers), 3)
        self.assertIsNone(self.model.pending)

    def test_reconnect_waits_for_old_workers_and_survives_updates(self):
        import copy
        profile = dict(self.profile('Group'), groupID='a'*32)
        self.model.activate(profile)
        self.model.passive = False
        self.model.initial_check_pending = False
        self.model.next_recall_poll = float('inf')
        self.model.running = True
        old_workers = list(self.model.workers)
        for worker in old_workers:
            worker.process = Mock()
            worker.process.poll.return_value = None
            worker.stopping = 1
            worker.tick = Mock()
        with patch.object(qt_app, 'build_group_profile', return_value=None):
            self.model.paired_connection(dict(reason='disconnected', group={'id':'a'*32}))
        with patch.object(qt_app, 'build_group_profile', side_effect=lambda _:copy.deepcopy(profile)):
            self.model.paired_connection(dict(reason='connected'))
            self.assertFalse(self.model.pending_clear)
            self.assertTrue(self.model.pending_start)
            self.model.paired_connection(dict(reason='updated'))
            self.assertTrue(self.model.pending_start)
        self.model.tick()
        self.assertIsNotNone(self.model.pending)
        self.assertFalse(self.model.running)
        for worker in old_workers:
            worker.process = None
            worker.stopping = None
        self.model.tick()
        self.assertIsNone(self.model.pending)
        self.assertIsNotNone(self.model.profile)
        self.assertTrue(self.model.running)
        self.assertTrue(self.model.workers[0].desired)
        self.assertFalse(self.model.workers[1].desired)
        self.assertTrue((self.data/'connection.json').exists())

    def test_role_change_stops_and_clears_only_group_profile(self):
        self.model.activate(dict(self.profile(), groupID='a'*32))
        for worker in self.model.workers: worker.tick = Mock()
        with patch.object(qt_app, 'build_group_profile', return_value=None):
            self.model.paired_connection(dict(reason='reset'))
        self.model.passive = False
        self.model.next_recall_poll = float('inf')
        self.model.tick()
        self.assertIsNone(self.model.profile)
        self.assertFalse(self.model.workers)
        self.assertFalse(self.model.running)

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
        self.model.pairing = self.mock_pairing.return_value
        self.model.pairing.snapshot.return_value = dict(name='This computer', code='123456',
            role='client', groupID='', members=[], count=0, maximum=3,
            addresses=['192.0.2.1:44331'], warning='', machines=[dict(id='a'*32, name='MacBook',
            platform='macos', address='192.0.2.2:44331', paired=False, online=True, count=1),
            dict(id='b'*32, name='Windows', platform='windows', address='192.0.2.3:44331', paired=True, online=False, count=2)])
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
                for page in range(5):
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

    def test_legacy_import_cannot_replace_group(self):
        self.model.activate(dict(self.profile('Group'), groupID='a'*32))
        incoming = self.data / 'legacy.viewflowconnection'
        incoming.write_text(json.dumps(self.profile('Old pair')))
        with patch.object(self.model, 'stop') as stop:
            self.model.import_path(incoming)
            stop.assert_not_called()
        self.assertEqual(self.model.profile['name'], 'Group')
        self.assertIsNone(self.model.pending)

    def test_starting_message_tracks_process_launch_without_claiming_connection(self):
        self.model.activate(self.profile())
        self.model.passive = False
        self.model.next_recall_poll = float('inf')
        self.model.running = True
        self.model.message = '正在启动当前连接组。'
        for worker in self.model.workers:
            worker.process = Mock()
            worker.tick = Mock()
            worker.status = '正在运行'
        self.model.tick()
        self.assertEqual(self.model.message, '组件进程已启动；正在建立设备连接。')
        self.model.workers[0].status = '组件已退出，正在恢复（1）'
        self.model.tick()
        self.assertEqual(self.model.message, '部分组件正在恢复，请查看下方状态或日志。')

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
