#!/usr/bin/env python3
"""Configuration transactions only: never start a desktop or inject input."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'viewflow-performance.py'
spec = importlib.util.spec_from_file_location('performance', SCRIPT)
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class ModeSelection(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.config = Path(self.temporary.name) / 'source.json'
        self.original = {'capture_provider': 'viewflow', 'fps': 60,
                         'media': {'refresh_hz': 60, 'color_codec': 'h264'},
                         'remote': '192.0.2.2:44129', 'private_key': '/private/key',
                         'desktop': {'remote_display': {'width': 3840, 'height': 2400}}}
        self.config.write_text(json.dumps(self.original))
        self.config.chmod(0o600)
        self.bytes = self.config.read_bytes()
        self.peer = Path(self.temporary.name) / 'peer'
        self.settings = self.enterContext(patch.object(performance, 'service_settings', return_value=(self.config, self.peer)))
        self.api = self.enterContext(patch.object(performance, 'require_capture_api'))
        self.validate = self.enterContext(patch.object(performance, 'validate_config'))
        self.active = self.enterContext(patch.object(performance, 'service_active', return_value=False))
        self.restart = self.enterContext(patch.object(performance, 'restart_service'))

    def choose(self, mode='latency'):
        return performance.set_mode(self.config, mode, self.peer)

    def test_modes_preserve_visuals_geometry_and_endpoints(self):
        result = self.choose()
        self.assertTrue(result['changed'])
        self.assertFalse(result['restarted'])
        expected = dict(self.original, performance_mode='latency')
        self.assertEqual(json.loads(self.config.read_text()), expected)
        self.assertEqual(Path(result['backup']).read_bytes(), self.bytes)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.restart.assert_not_called()
        self.choose('frame-rate')
        self.assertEqual(json.loads(self.config.read_text()), dict(self.original, performance_mode='frame-rate'))

    def test_failed_validation_never_mutates_configuration(self):
        self.validate.side_effect = RuntimeError('unsupported peer')
        with self.assertRaises(RuntimeError):
            self.choose()
        self.assertEqual(self.config.read_bytes(), self.bytes)
        self.restart.assert_not_called()

    def test_missing_plugin_leaves_configuration_unchanged(self):
        self.api.side_effect = RuntimeError('unsupported plugin')
        with self.assertRaises(RuntimeError):
            self.choose()
        self.assertEqual(self.config.read_bytes(), self.bytes)
        self.validate.assert_not_called()

    def test_restart_failure_restores_exact_prior_configuration(self):
        self.active.return_value = True
        self.restart.side_effect = [RuntimeError('restart failed'), None]
        with self.assertRaisesRegex(RuntimeError, 'previous configuration and service restored'):
            self.choose()
        self.assertEqual(self.config.read_bytes(), self.bytes)
        self.assertEqual(self.restart.call_count, 2)

    def test_active_service_restarts_once(self):
        self.active.return_value = True
        self.assertTrue(self.choose()['restarted'])
        self.restart.assert_called_once_with(performance.DEFAULT_SERVICE)

    def test_same_selection_does_not_restart_or_rewrite(self):
        result = self.choose('frame-rate')
        self.assertFalse(result['changed'])
        self.assertEqual(self.config.read_bytes(), self.bytes)
        self.restart.assert_not_called()

    def test_mismatched_service_binary_is_rejected_before_mutation(self):
        with self.assertRaisesRegex(RuntimeError, 'executable used by the service'):
            performance.set_mode(self.config, 'latency', Path('/different/peer'))
        self.assertEqual(self.config.read_bytes(), self.bytes)
        self.validate.assert_not_called()

    def test_unknown_mode_is_rejected_without_mutation(self):
        with self.assertRaises(ValueError):
            self.choose('unsafe-guess')
        self.assertEqual(self.config.read_bytes(), self.bytes)


if __name__ == '__main__':
    unittest.main()
