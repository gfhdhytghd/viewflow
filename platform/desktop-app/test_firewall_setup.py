"""No UAC, subprocess, firewall API, or installed file mutations."""
import ctypes
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import main


class FirewallSetupTests(unittest.TestCase):
    def test_elevation_uses_exact_bundle_path_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='Viewflow setup ') as temporary:
            root = Path(temporary)
            script = root / 'setup/configure-windows-firewall.ps1'
            script.parent.mkdir()
            script.touch()
            shell = Mock(return_value=33)
            with patch.object(main, 'ROOT', root), patch.object(main, 'PLATFORM', 'windows'), \
                 patch.object(ctypes, 'windll', SimpleNamespace(shell32=SimpleNamespace(ShellExecuteW=shell)), create=True):
                main.configure_windows_firewall()
                shell.assert_called_once_with(None, 'runas', 'powershell.exe',
                    subprocess.list2cmdline(['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script), '-InstallRoot', str(root), '-PauseOnError']),
                    str(root), 1)
                shell.return_value = 5
                with self.assertRaises(OSError):
                    main.configure_windows_firewall()

    def test_missing_script_and_wrong_platform_do_not_launch(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(main, 'ROOT', Path(temporary)), \
             patch.object(ctypes, 'windll', Mock(), create=True) as windows:
            with patch.object(main, 'PLATFORM', 'windows'):
                with self.assertRaises(FileNotFoundError):
                    main.configure_windows_firewall()
            with patch.object(main, 'PLATFORM', 'linux'):
                with self.assertRaises(ValueError):
                    main.configure_windows_firewall()
            windows.shell32.ShellExecuteW.assert_not_called()


if __name__ == '__main__':
    unittest.main()
