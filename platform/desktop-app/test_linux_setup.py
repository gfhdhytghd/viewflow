from pathlib import Path
import shlex
import tempfile
import unittest
from unittest.mock import patch, Mock

import linux_setup


class LinuxSetupTests(unittest.TestCase):
    def report(self, **extra):
        return {'arch': True, 'tools': {'pacman': '/usr/bin/pacman', 'pkexec': '/usr/bin/pkexec'},
                'gpu_devices': [{'vendor': '0x10de'}], 'kernel_package': 'linux-zen', 'packages': {}, **extra}

    def test_dependencies_are_vendor_specific_and_never_install(self):
        self.assertFalse(hasattr(linux_setup, 'install_plan'))
        self.assertFalse(hasattr(linux_setup, 'run_install'))
        for vendor, expected in [('0x10de', 'nvidia-utils'), ('0x1002', 'mesa'), ('0x8086', 'intel-media-driver')]:
            hints = linux_setup.dependency_hints(self.report(gpu_devices=[{'vendor': vendor}]), 'en')
            self.assertIn(expected, '\\n'.join(hints))
            if vendor != '0x10de':
                self.assertNotIn('nvidia-utils', '\\n'.join(hints))

    def test_plugin_commands_quote_paths_and_skip_loaded(self):
        root = Path('/tmp/space and $shell/')
        manifest = {'hyprland_build': {'commit': 'abc'}}
        report = {'hyprland': {'commit': 'abc'}, 'plugins': [{'name': 'viewflow-hyprland'}]}
        command = linux_setup.plugin_commands(root, manifest, report)
        self.assertEqual(shlex.split(command), ['hyprctl', 'plugin', 'load', str(root / 'plugins/viewflow-capture.so')])
        report['hyprland']['commit'] = 'different'
        self.assertEqual(linux_setup.plugin_commands(root, manifest, report), '')
        self.assertEqual(linux_setup.plugin_commands(root, manifest, {}), '')



if __name__ == '__main__': unittest.main()
