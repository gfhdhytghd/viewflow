import base64
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import windows_virtual_display_scale as dpi


class DpiStartupTests(unittest.TestCase):
    def test_supported_hyprland_scales(self):
        for percent in dpi.SUPPORTED_PERCENT:
            self.assertEqual(dpi.percent_for_monitor({'scale': percent / 100}), percent)

    def test_no_silent_rounding(self):
        for scale in (1.2, 0, -2, float('nan'), float('inf')):
            with self.assertRaises(ValueError):
                dpi.percent_for_monitor({'scale': scale})

    def test_powershell_literal(self):
        self.assertEqual(dpi.quote("a'b$();`"), "'a''b$();`'")

    def test_ssh_target_and_worker_readback(self):
        config = {'windows_virtual_display': {'device': r'\\.\DISPLAY6', 'utility': r'C:\Viewflow\display.exe'},
                  'peer_discovery': {'ssh_host_key_alias': 'windows', 'ssh_user': 'wilf'}}
        with patch.object(dpi.subprocess, 'run') as run:
            dpi.sync_scale(config, '192.0.2.1:44100', {'scale': 2.5})
        argv = run.call_args.args[0]
        self.assertIn('wilf@192.0.2.1', argv)
        self.assertEqual(argv[-2:], ['-Command', '-'])
        script = run.call_args.kwargs['input']
        worker64 = script.split('-EncodedCommand ')[1].split("'")[0]
        worker = base64.b64decode(worker64).decode('utf-16le')
        self.assertIn("dpi '\\\\.\\DISPLAY6' 250", worker)
        self.assertIn('dpi_verified=250', worker)
        self.assertIn('-LogonType Interactive', script)
        self.assertIn('Unregister-ScheduledTask', script)
        self.assertNotIn('configure ', worker)


if __name__ == '__main__':
    unittest.main()
