#!/usr/bin/env python3
"""Pure configuration checks: no compositor or process management."""
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
    assert 'monitor:set_workspace("name:viewflow-underlay")' in expression
    assert 'monitor:set_special_workspace("viewflow")' in expression
print('autostart configuration test passed')
