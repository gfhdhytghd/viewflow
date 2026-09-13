#!/usr/bin/env python3
"""No live peers, desktop input, service install or permission mutation."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'platform/desktop-app'))
import runtime


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); sys.modules[name] = result; spec.loader.exec_module(result)
    return result


mac = module('mac_packager', ROOT / 'tools/build-macos-app.py')
desktop = module('desktop_packager', ROOT / 'tools/build-desktop-app.py')
export = module('pairing_export', ROOT / 'tools/export-app-connection.py')


class PackagingTests(unittest.TestCase):
    def test_full_mac_payload_requires_driver_and_every_helper(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); app = root / 'Viewflow.app'; helpers = root / 'helpers'; helpers.mkdir()
            binary = root / 'Viewflow'; binary.write_bytes(b'mock'); binary.chmod(0o755)
            for name in mac.HELPERS: (helpers / name).write_bytes(b'mock'); (helpers / name).chmod(0o755)
            mac.copy_payload(app, binary, helpers, None)
            self.assertEqual(len(mac.inspect_bundle(app, require_driver=False)), 6)
            with self.assertRaises(ValueError): mac.inspect_bundle(app)
            driver = app / 'Contents/Library/SystemExtensions/org.viewflow.trackpad-probe.dext'; driver.mkdir(parents=True)
            (driver / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': mac.DRIVER_ID, 'CFBundleExecutable': 'Driver'}))
            (driver / 'Driver').write_bytes(b'mock')
            self.assertEqual(len(mac.inspect_bundle(app)), 7)
            (app / 'Contents/Helpers/vf-clipboard-peer').unlink()
            with self.assertRaises(ValueError): mac.inspect_bundle(app)

    def test_desktop_payload_cannot_silently_drop_hid_or_plugins(self):
        for target in ('linux', 'windows'):
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                for relative in desktop.required_files(target):
                    path = root / relative; path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'\x7fELFfixture' if target == 'linux' else b'MZfixture')
                desktop.inspect_payload(root, target)
                required = 'plugins/viewflow-hyprland.so' if target == 'linux' else 'bin/vf-input-service.exe'
                (root / required).unlink()
                with self.assertRaises(ValueError): desktop.inspect_payload(root, target)

    def test_export_never_overwrites_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'test.viewflowconnection'
            export.write_new(path, {'secret': 'first'})
            with self.assertRaises(FileExistsError): export.write_new(path, {'secret': 'second'})
            self.assertEqual(json.loads(path.read_text(encoding='utf-8')), {'secret': 'first'})
            if os.name != 'nt': self.assertEqual(path.stat().st_mode & 0o777, 0o600)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {'platform': 'linux', 'programs': {'vf-window-peer': 'bin/vf-window-peer'}}
        self.profile = {'version': 2, 'platform': 'linux', 'name': 'test',
            'components': [{'id': 'windows', 'program': 'vf-window-peer', 'args': ['--config', '${profile}/windows.json']}],
            'files': {'device.key': base64.b64encode(b'test-key').decode()},
            'configs': {'windows.json': {'private_key': '${profile}/device.key', 'native': '${program:vf-window-peer}'}}}

    def test_profile_relocates_without_repo_paths(self):
        with tempfile.TemporaryDirectory(prefix='viewflow space ') as temp:
            root = Path(temp) / 'app'; data = Path(temp) / 'profile'
            runtime.materialize(self.profile, self.manifest, root, data)
            config = json.loads((data / 'windows.json').read_text(encoding='utf-8'))
            self.assertEqual(config['native'], str(root / 'bin/vf-window-peer'))
            self.assertEqual((data / 'device.key').read_bytes(), b'test-key')
            self.assertEqual(runtime.command(self.profile['components'][0], self.manifest, root, data),
                             [str(root / 'bin/vf-window-peer'), '--config', str(data / 'windows.json')])

    def test_invalid_attachment_and_duplicate_component_do_not_write(self):
        self.profile['files']['../escape'] = 'dGVzdA=='
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError): runtime.materialize(self.profile, self.manifest, data=Path(temp))
            self.assertFalse(list(Path(temp).iterdir()))
        del self.profile['files']['../escape']
        self.profile['components'].append(dict(self.profile['components'][0]))
        with self.assertRaises(ValueError): runtime.validate_profile(self.profile, self.manifest)

    def test_platform_and_program_mismatch(self):
        self.profile['platform'] = 'windows'
        with self.assertRaises(ValueError): runtime.validate_profile(self.profile, self.manifest)
        self.profile['platform'] = 'linux'; self.profile['components'][0]['program'] = '/bin/sh'
        with self.assertRaises(ValueError): runtime.validate_profile(self.profile, self.manifest)

    def test_windows_example_has_valid_presenter_arguments(self):
        example = json.loads((ROOT / 'platform/desktop-app/example-plan.json').read_text(encoding='utf-8'))
        runtime.validate_profile(example, {'platform': 'windows', 'programs': {name: '' for name in desktop.PROGRAMS['windows']}})
        self.assertEqual(example['configs']['windows.json']['backend']['args'], [])


@unittest.skipIf(os.name == 'nt', 'Linux process group semantics tested on Linux')
class SupervisorTests(unittest.TestCase):
    def test_crash_recovers_without_stopping_other_worker(self):
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp)
            failing = runtime.Worker({'id': 'failure'}, [sys.executable, '-c', 'raise SystemExit(7)'], data, desired=True)
            healthy = runtime.Worker({'id': 'healthy'}, [sys.executable, '-c', 'import time; time.sleep(60)'], data, desired=True)
            try:
                failing.tick(); healthy.tick(); healthy_pid = healthy.process.pid
                failing.process.wait(timeout=3); failing.tick()
                self.assertEqual(failing.last_exit, 7); self.assertTrue(failing.desired)
                self.assertIsNone(failing.process); self.assertEqual(healthy.process.pid, healthy_pid)
                failing.next_start = 0; failing.tick(); self.assertIsNotNone(failing.process)
                failing.stop(); self.assertTrue(healthy.desired); self.assertIsNone(healthy.process.poll())
            finally:
                for worker in (failing, healthy):
                    worker.stop()
                    if worker.process: worker.process.wait(timeout=3)
                    worker.tick()

    def test_stop_allows_cleanup_and_does_not_restart(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); released = root / 'released'
            code = 'import signal,time,pathlib,sys; signal.signal(signal.SIGINT, lambda *_: (pathlib.Path(sys.argv[1]).write_text("released"),sys.exit(0))); print("ready",flush=True); time.sleep(60)'
            worker = runtime.Worker({'id': 'cleanup'}, [sys.executable, '-c', code, str(released)], root, desired=True)
            try:
                worker.tick()
                limit = time.monotonic() + 3
                while 'ready' not in (root / 'logs/cleanup.log').read_text(encoding='utf-8') and time.monotonic() < limit: time.sleep(.01)
                worker.stop(); worker.process.wait(timeout=3); worker.tick()
                self.assertEqual(released.read_text(encoding='utf-8'), 'released')
                self.assertFalse(worker.desired); self.assertIsNone(worker.process)
                worker.tick(now=time.monotonic()+100); self.assertIsNone(worker.process)
            finally:
                if worker.process and worker.process.poll() is None: worker.process.kill(); worker.process.wait()


@unittest.skipUnless(os.name == 'nt', 'Windows console/job semantics require Windows')
class WindowsSupervisorTests(unittest.TestCase):
    def test_console_teardown_keeps_manager_and_other_worker_alive(self):
        code = """import signal,time,pathlib,sys
signal.signal(signal.SIGINT, lambda *_: (pathlib.Path(sys.argv[1]).write_text('released'),sys.exit(0)))
print('READY',flush=True)
while True:
    time.sleep(.05)
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workers = [runtime.Worker({'id': name}, [sys.executable, '-c', code, str(root/name)], root, desired=True)
                       for name in ('first', 'second')]
            try:
                for worker in workers:
                    worker.tick(); self.assertIsNotNone(worker.process, worker.status)
                    deadline = time.monotonic() + 5
                    log = root / 'logs' / (worker.item['id'] + '.log')
                    while 'READY' not in log.read_text(encoding='utf-8').splitlines() and time.monotonic() < deadline: time.sleep(.02)
                    self.assertIn('READY', log.read_text(encoding='utf-8').splitlines())
                workers[0].stop(); workers[0].process.wait(timeout=5); workers[0].tick()
                self.assertEqual((root/'first').read_text(encoding='utf-8'), 'released')
                self.assertIsNone(workers[1].process.poll())
                workers[1].stop(); workers[1].process.wait(timeout=5); workers[1].tick()
                self.assertEqual((root/'second').read_text(encoding='utf-8'), 'released')
            finally:
                for worker in workers:
                    if worker.process is not None and worker.process.poll() is None: worker.process.kill(); worker.process.wait()
                    if worker.job: worker.job.close()
                    if worker.output: worker.output.close()


if __name__ == '__main__': unittest.main()
