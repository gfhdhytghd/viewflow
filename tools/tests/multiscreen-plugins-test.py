#!/usr/bin/env python3
"""Mocked plugin selection for the group input route; no compositor access."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root.parent / 'platform/desktop-app'))
spec = importlib.util.spec_from_file_location('multiscreen', root / 'multiscreen-input-linux.py')
multiscreen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(multiscreen)

with tempfile.TemporaryDirectory() as directory:
    bundle = Path(directory)
    (bundle / 'bundle-manifest.json').write_text('{}')
    selected = [bundle / 'cache/viewflow-hyprland.so', bundle / 'cache/viewflow-capture.so']
    calls = []
    hyprland_plugins = types.ModuleType('hyprland_plugins')
    hyprland_plugins.resolve_plugins = lambda b, m: (calls.append(('resolve', b)), (selected, 'built'))[1]
    plugin_safety = types.ModuleType('plugin_safety')
    plugin_safety.validate_plugin_for_load = lambda path: calls.append(('validate', path))
    sys.modules['hyprland_plugins'] = hyprland_plugins
    sys.modules['plugin_safety'] = plugin_safety
    multiscreen.subprocess = types.SimpleNamespace(run=lambda argv, **kw: calls.append(tuple(argv)))

    # A new session has neither plugin: both resolved paths are validated and loaded.
    multiscreen.autostart.read_json = lambda *a: [{'name': 'other'}]
    multiscreen.ensure_plugins(bundle)
    loads = [c for c in calls if c[:3] == ('hyprctl', 'plugin', 'load')]
    assert [c[3] for c in loads] == [str(p) for p in selected], calls
    assert ('validate', selected[0]) in calls and ('validate', selected[1]) in calls

    # Already-loaded plugins are retained; nothing is resolved, unloaded or reloaded.
    calls.clear()
    multiscreen.autostart.read_json = lambda *a: [{'name': 'viewflow-capture'}, {'name': 'viewflow-hyprland'}]
    multiscreen.ensure_plugins(bundle)
    assert calls == [], calls

    # One missing plugin: only that one is loaded.
    calls.clear()
    multiscreen.autostart.read_json = lambda *a: [{'name': 'viewflow-hyprland'}]
    multiscreen.ensure_plugins(bundle)
    loads = [c for c in calls if c[:3] == ('hyprctl', 'plugin', 'load')]
    assert [c[3] for c in loads] == [str(selected[1])], calls
    assert not any('unload' in c for c in calls if isinstance(c, tuple))
print('ok')
