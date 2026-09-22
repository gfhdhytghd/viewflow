import json
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
import media_settings


class MediaSettingsTests(unittest.TestCase):
    def test_probe_requires_full_hardware_proof(self):
        with patch.object(media_settings.subprocess, 'run', return_value=Mock(returncode=0, stdout='{"ok":true}', stderr='')):
            self.assertFalse(media_settings.probe(Path('/app/bin/probe'), 'vaapi', '/dev/dri/renderD129')['ok'])
        proof = dict(ok=True, codec='h264', frames=8, backend='vaapi', render_node='/dev/dri/renderD129', hardware_encode=True, hardware_decode=True, egl_import=True, alpha_atlas=True, synthetic_only=True)
        with patch.object(media_settings.subprocess, 'run', return_value=Mock(returncode=0, stdout=json.dumps(proof), stderr='')) as run:
            self.assertTrue(media_settings.probe(Path('/app/bin/probe'), 'vaapi', '/dev/dri/renderD129')['ok'])
            self.assertEqual(run.call_args.args[0], ['/app/bin/probe', '--backend', 'vaapi', '--render-node', '/dev/dri/renderD129'])
            self.assertEqual(run.call_args.kwargs['env']['VIEWFLOW_MEDIA_RENDER_NODE'], '/dev/dri/renderD129')
        proof['backend'] = 'nvidia'
        with patch.object(media_settings.subprocess, 'run', return_value=Mock(returncode=0, stdout=json.dumps(proof), stderr='')):
            self.assertFalse(media_settings.probe(Path('/app/bin/probe'), 'vaapi', '')['ok'])
        with patch.object(media_settings.subprocess, 'run', return_value=Mock(returncode=1, stdout=json.dumps(proof), stderr='failed')):
            self.assertFalse(media_settings.probe(Path('/app/bin/probe'), 'vaapi', '')['ok'])

    def test_empty_device_clears_inherited_selection(self):
        self.assertEqual(media_settings.environment('auto', '')['VIEWFLOW_MEDIA_RENDER_NODE'], '')
        with self.assertRaises(ValueError): media_settings.environment('amd', '')
        with self.assertRaises(ValueError): media_settings.environment('vaapi', 'relative/path')

    def test_missing_probe_is_not_hardware_success(self):
        with patch.object(media_settings.subprocess, 'run', side_effect=FileNotFoundError('probe absent')):
            self.assertFalse(media_settings.probe(Path('/absent'), 'auto', '')['ok'])
