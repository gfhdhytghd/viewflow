import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from window_recall import RecallController, DEFAULT_SHORTCUT


class RecallLifecycleTests(unittest.TestCase):
    def test_missing_helper_retries_after_delay(self):
        with tempfile.TemporaryDirectory() as directory:
            controller = RecallController('windows', Path(directory) / 'missing', directory)
            with patch.object(controller, '_start', side_effect=FileNotFoundError('missing')) as start, patch('window_recall.time.monotonic', return_value=10):
                controller.poll()
                controller.poll()
            self.assertEqual(start.call_count, 1)
            self.assertEqual(controller.retry_at, 15)

    def test_registration_conflict_restores_previous_shortcut(self):
        with tempfile.TemporaryDirectory() as directory:
            controller = RecallController('windows', 'helper', directory, 'Ctrl+J')
            controller.previous = DEFAULT_SHORTCUT
            controller.process = Mock()
            controller.process.poll.return_value = 3
            (Path(directory) / 'window-recall.log').write_text('recall shortcut unavailable: 1409')
            with patch.object(controller, '_start') as start:
                controller.poll()
            self.assertEqual(controller.shortcut, DEFAULT_SHORTCUT)
            start.assert_called_once()
            self.assertIn('unavailable', controller.status)

    def test_invalid_saved_setting_does_not_prevent_app_start(self):
        controller = RecallController('linux', 'unused', '.', 'bad')
        self.assertEqual(controller.shortcut, DEFAULT_SHORTCUT)


if __name__ == '__main__':
    unittest.main()
