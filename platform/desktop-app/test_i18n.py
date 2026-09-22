import json
from pathlib import Path
import re
import string
import unittest
from unittest.mock import patch, Mock

from i18n import EN, resolve_language, translate, status_text
from permissions import permission_rows
import main


class TranslationTests(unittest.TestCase):
    def test_system_locale_and_explicit_selection(self):
        for locale in ('zh_CN', 'zh_TW', 'zh-Hans-CN'):
            self.assertEqual(resolve_language('system', locale), 'zh-CN')
        for locale in ('en_US', 'de_DE', 'C'):
            self.assertEqual(resolve_language('system', locale), 'en')
        self.assertEqual(resolve_language('en', 'zh_CN'), 'en')
        self.assertEqual(resolve_language('zh-CN', 'en_US'), 'zh-CN')

    def test_qml_catalog_is_complete(self):
        qml = (Path(__file__).parent / 'qml/Main.qml').read_text()
        keys = [json.loads(value) for value in re.findall(r'window\.t\(("(?:[^"\\]|\\.)*")\)', qml)]
        self.assertGreater(len(keys), 40)
        self.assertEqual(set(keys) - EN.keys(), set())

    def test_placeholders_match_and_unknown_output_is_preserved(self):
        def fields(value):
            return {field for _, field, _, _ in string.Formatter().parse(value) if field}
        for key, value in EN.items():
            self.assertEqual(fields(key), fields(value), key)
        self.assertEqual(status_text('组件已退出，正在恢复（12）', 'en'), 'Component exited; recovering (12)')
        self.assertEqual(status_text('启动失败：example error', 'en'), 'Could not start: example error')
        self.assertEqual(status_text('opaque {native} output', 'en'), 'opaque {native} output')
        self.assertEqual(translate('连接组件：{count} 项', 'en', count=2), 'Connection components: 2')


class PermissionTests(unittest.TestCase):
    def test_all_successful_linux_checks_are_green(self):
        report = {'platform': 'linux', 'hyprland': {'commit': 'abc'}, 'plugin_build': {'commit': 'abc'},
                  'plugins': [{'name': name} for name in ('viewflow-hyprland', 'viewflow-capture')],
                  'input_devices': [{'readable': True}],
                  'linux_setup': {'distro': 'Arch', 'kernel': 'test', 'gpu_devices': [{'vendor': '0x10de'}],
                                  'packages': {'hyprland': '1', 'nvidia-utils': '1'}, 'nvidia_query': {'code': 0, 'output': 'GPU'}}}
        self.assertTrue(all(row['tone'] == 'good' for row in permission_rows(report, 'en')))
        report['input_devices'].append({'readable': False})
        self.assertEqual(permission_rows(report, 'en')[3]['tone'], 'warning')

    def test_hyprland_detection_without_session_environment(self):
        with patch('linux_setup.inventory', return_value={}), patch.object(main, 'PLATFORM', 'linux'), patch.dict(main.os.environ, {}, clear=True), \
             patch.object(main.subprocess, 'run', return_value=Mock(returncode=0, stdout='{"commit":"abc","version":"0.56.2"}')):
            report = main.permission_report({'hyprland_build': {'commit': 'abc'}})
        self.assertEqual(report['session'], 'wayland')
        self.assertTrue(report['hyprland_session'])
        rows = permission_rows(report, 'en')
        self.assertEqual(rows[0]['status'], 'Detected')
        self.assertEqual(rows[1]['status'], 'Version matches')
        self.assertIn('does not confirm', rows[1]['detail'])

    def test_unavailable_checks_and_device_access(self):
        report = {'platform': 'linux', 'hyprland': 'failed', 'plugin_build': 'unknown'}
        self.assertEqual(permission_rows(report, 'en')[0]['status'], 'Unconfirmed')
        self.assertEqual(permission_rows(report, 'en')[3]['status'], 'No devices found')
        report['input_devices'] = [{'readable': False}, {'readable': True}]
        self.assertEqual(permission_rows(report, 'en')[3]['status'], 'Partly readable')
        report['input_devices'] = [{'readable': False}]
        self.assertEqual(permission_rows(report, 'en')[3]['status'], 'Setup needed')

    def test_windows_service_results(self):
        for code, state, expected in ((1060, None, 'Not installed'), (5, None, 'Unconfirmed'), (0, 1, 'Stopped'), (0, 4, 'Running')):
            rows = permission_rows({'platform': 'windows', 'input_service_code': code, 'input_service_state': state}, 'en')
            self.assertEqual(rows[0]['status'], expected)


if __name__ == '__main__':
    unittest.main()
