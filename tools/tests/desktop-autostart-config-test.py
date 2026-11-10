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
    assert 'monitor:set_workspace("name:viewflow-underlay")' in expression
    assert 'if hl.get_workspace' not in expression
    assert 'workspace.rename' not in expression
    assert 'monitor:set_special_workspace("viewflow")' in expression

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

# Named normal workspaces are not special merely because they lack a number.
assert not autostart.special_workspace_active({'specialWorkspace': {'type': 'normal', 'name': 'viewflow'}}, 'viewflow')
assert autostart.special_workspace_active({'specialWorkspace': {'type': 'special', 'name': 'viewflow'}}, 'viewflow')
assert autostart.special_workspace_active({'specialWorkspace': {'type': 'special', 'address': 'special:viewflow', 'name': 'special:viewflow'}}, 'viewflow')
assert autostart.special_workspace_active({'specialWorkspace': {'id': -99, 'name': 'special:viewflow'}}, 'viewflow')
assert not autostart.special_workspace_active({'specialWorkspace': {'type': '', 'name': ''}}, 'viewflow')
assert not autostart.special_workspace_active({'specialWorkspace': {'type': 'special', 'name': 'other'}}, 'viewflow')

# Run the emitted Lua against a compositor model. The setter accepts a bare
# special name; passing a selector would create a doubled special: prefix.
import subprocess
migration = autostart.special_workspace_expression('HEADLESS-test', 'viewflow-route', 'viewflow-route')
mock = """local previous = {name='7',id=7,special=false}; local moved=0
local monitor={active_workspace=previous}
local pending={{id=123},{id=124}}
function monitor:set_special_workspace(name)
    self.special='special:'..name; assert(self.special=='special:viewflow-route')
end
function monitor:set_workspace(selector)
    assert(selector=='name:viewflow-route-underlay')
    self.active_workspace={name='viewflow-route-underlay',special=false}
end
hl={dsp={window={}}}
function hl.dispatch(action) action.run() end
function hl.get_monitor(name) assert(name=='HEADLESS-test'); return monitor end
function hl.workspace_rule(rule) assert(not rule.workspace:match('^%d+$')) end
function hl.get_workspace_windows(ws) assert(ws==monitor.active_workspace); return pending end
function hl.dsp.window.move(args)
    assert(args.workspace=='special:viewflow-route' and args.follow==false)
    return {run=function() moved=moved+1 end}
end
"""
subprocess.run(['lua', '-'], input=(mock + migration +
    "\nassert(monitor.active_workspace.name=='viewflow-route-underlay' and moved==2)\n" +
    "pending={}; monitor.special=nil\n" + migration +
    "\nassert(moved==2 and monitor.special=='special:viewflow-route')\n" +
    "pending={{id=125}}\n" + migration + "\nassert(moved==3)\n"), text=True, check=True)

# Older Lua lines expose callable actions rather than hl.dispatch.
legacy = mock.replace('function hl.dispatch(action) action.run() end', '').replace(
    'return {run=function() moved=moved+1 end}', 'return function() moved=moved+1 end')
subprocess.run(['lua', '-'], input=legacy + migration + '\nassert(moved==2)\n', text=True, check=True)

# The frozen helper uses the same ABI selector as the GUI, including local cache
# paths. Never resolve or load a real compositor during this configuration test.
from unittest.mock import patch
import sys
sys.path.insert(0, str(script.parents[1] / 'platform/desktop-app'))
with tempfile.TemporaryDirectory() as directory:
    bundle = Path(directory)
    manifest = {'hyprland_variants': []}
    (bundle / 'bundle-manifest.json').write_text(json.dumps(manifest))
    selected = [bundle / 'data/input.so', bundle / 'data/capture.so']
    with patch.object(autostart.sys, 'frozen', True, create=True), \
         patch.object(autostart.sys, 'executable', str(bundle / 'Viewflow')), \
         patch('hyprland_plugins.resolve_plugins', return_value=(selected, 'cached')) as resolve:
        command = autostart.launch_command(bundle / 'config', 'HEADLESS-1', bundle / 'peer')
    resolve.assert_called_once_with(bundle, manifest)
    assert command[command.index('--capture-plugin') + 1] == str(selected[1])
    assert command[command.index('--input-plugin') + 1] == str(selected[0])
assert autostart.route_output_name('gui-a4834581f2f870e0-1') == 'viewflow-gui-a4834581f2f870e0-1'
assert autostart.virtual_output('viewflow-gui-1') and autostart.virtual_output('HEADLESS-3')
assert not autostart.virtual_output('DP-4')
print('autostart plugin selection test passed')
