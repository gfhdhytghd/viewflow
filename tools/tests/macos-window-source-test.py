#!/usr/bin/env python3
"""Offline source enrollment and three-system feedback prevention."""
import importlib.util
from pathlib import Path

path = Path(__file__).resolve().parents[1] / 'macos-window-source.py'
spec = importlib.util.spec_from_file_location('source', path)
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)
window = dict(window_id=1, pid=101, on_screen=True, layer=0,
              frame_points=[-400, 100, 600, 500], bundle_id='com.example.Editor')
assert source.eligible(window)
assert not source.eligible(dict(window, bundle_id='org.viewflow.WindowSource'))
assert not source.eligible(dict(window, executable_name='viewflow-macos-windows-multi'))
assert not source.eligible(dict(window, application_name='viewflow-macos-windows'))
assert not source.eligible(dict(window, on_screen=False))
assert not source.eligible(dict(window, frame_points=[0, 0, float('nan'), 100]))
report = dict(schema_version=1, enumeration='ok', windows=[dict(window, window_id=2), window],
              physical_displays=[[0,0,1920,1200]], remote_displays=[[-3072,0,3072,1728]])
assert list(source.selected_windows(report, {(2, 101)}, 1)) == [(2, 101)]
assert list(source.selected_windows(report, set(), 1)) == [(1, 101)]
report['windows'] = [dict(window, pid=102)]
assert list(source.selected_windows(report, {(1, 101)}, 1)) == [(1, 102)]
try:
    source.selected_windows(dict(report, enumeration='permission_required'), {(1, 101)}, 8)
except ValueError:
    pass
else:
    raise AssertionError('permission failure must not be treated as an empty desktop')
print('Mac source enrollment/feedback/identity tests passed; no capture or input')

assert not source.needs_remote(dict(window, frame_points=[0,0,800,600]), [[0,0,1920,1200]], [[-3072,0,3072,1728]])
assert source.needs_remote(window, [[0,0,1920,1200]], [[-3072,0,3072,1728]])
assert not source.needs_remote(dict(window, frame_points=[0,0,800,600]), [[0,0,400,1200],[400,0,400,1200]], [[-1,0,2,1200]])
assert source.needs_remote(dict(window, frame_points=[0,0,800,600]), [[0,0,300,1200],[400,0,400,1200]], [[300,0,100,1200]])
