#!/usr/bin/env python3
"""Configuration and mocked output-recovery checks; no compositor management."""
import importlib.util
import json
from pathlib import Path
import tempfile

script = Path(__file__).resolve().parents[1] / 'desktop-autostart-linux.py'
spec = importlib.util.spec_from_file_location('autostart', script)
autostart = importlib.util.module_from_spec(spec)
spec.loader.exec_module(autostart)
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'source.json'
    old = {'compositor_pid': 1, 'windows': [{'address': 'stale'}], 'pointer': {'native_socket': 'old'}, 'desktop': {'candidates': [{'pid': 1}], 'hyprland_socket': 'old', 'auto_enroll': False}, 'remote': '192.0.2.1:44129'}
    path.write_text(json.dumps(old))
    result = autostart.prepare(path, {'pid': 42, 'instance': 'new-instance'}, {'x': -200, 'y': 0, 'width': 1080, 'height': 1920, 'scale': 1.5, 'transform': 1}, Path('/run/user/1234'))
    assert result['compositor_pid'] == 42
    assert result['windows'] == [] and result['desktop']['candidates'] == []
    assert result['desktop']['auto_enroll']
    assert result['desktop']['hyprland_socket'] == '/run/user/1234/hypr/new-instance/.socket.sock'
    assert result['desktop']['local_display']['width'] == 1920
    assert result['desktop']['local_display']['height'] == 1080
    assert result['remote'] == old['remote']
    assert json.loads(path.read_text()) == old
    expression = autostart.special_workspace_expression('HEADLESS-6')
    assert 'hl.get_monitor("HEADLESS-6")' in expression
    assert 'monitor:set_workspace({ workspace = "viewflow-underlay" })' in expression
    assert 'persistent = true' in expression
    assert 'workspace.rename' not in expression
    assert 'monitor:set_special_workspace({ workspace = "special:" .. "viewflow" })' in expression

    # An adopted output can be reset by a reload between the initial inventory
    # and a service restart.  Recovery must reapply the full geometry and wait
    # for five consecutive matching read-backs before the cursor peer starts.
    remote = {'x': 3072, 'y': 390, 'width': 3840, 'height': 2400, 'scale': 2}
    reset = {'id': 158, 'name': 'HEADLESS-158', 'x': 3072, 'y': 390,
             'width': 1920, 'height': 1080, 'scale': 1}
    restored = {**reset, **remote}
    samples = iter([[reset], [restored], [restored], [restored], [restored], [restored]])
    commands = []
    original_run, original_read_json, original_sleep = (
        autostart.subprocess.run, autostart.read_json, autostart.time.sleep)
    try:
        def fake_run(command, **kwargs):
            commands.append((command, kwargs))

        def fake_read_json(*command):
            assert command == ('hyprctl', '-j', 'monitors', 'all')
            return next(samples)

        autostart.subprocess.run = fake_run
        autostart.read_json = fake_read_json
        autostart.time.sleep = lambda _: None
        assert autostart.restore_existing_output('HEADLESS-158', remote) == restored
    finally:
        autostart.subprocess.run = original_run
        autostart.read_json = original_read_json
        autostart.time.sleep = original_sleep
    # One initial restore and one retry after the first bad read-back; the five
    # following read-backs must all agree without repeatedly reconfiguring it.
    assert len(commands) == 2
    assert all(command == ['hyprctl', '-q', 'eval', commands[0][0][3]] and
               kwargs == {'check': True} for command, kwargs in commands)
    assert 'HEADLESS-158' in commands[0][0][3]
    assert '3840x2400@60' in commands[0][0][3]
    assert '3072x390' in commands[0][0][3]
    assert 'scale = 2' in commands[0][0][3]
print('autostart configuration test passed')
