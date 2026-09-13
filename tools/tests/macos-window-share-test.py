#!/usr/bin/env python3
"""Offline viewport selection; no input or compositor changes."""
import importlib.util
from pathlib import Path

path = Path(__file__).resolve().parents[1] / 'macos-window-share-linux.py'
spec = importlib.util.spec_from_file_location('share', path)
share = importlib.util.module_from_spec(spec)
spec.loader.exec_module(share)
monitors = [dict(id=0, x=0, y=0, width=6144, height=3456, scale=2,
                 activeWorkspace={'id': 5}, specialWorkspace={'id': 0}),
            dict(id=2, x=3072, y=390, width=3840, height=2400, scale=2,
                 activeWorkspace={'id': 8}, specialWorkspace={'id': 0})]
window = dict(mapped=True, hidden=False, workspace={'id': 5}, at=[2900, 500], size=[900, 600])
assert share.eligible(window, monitors, 2)  # Partial crossing from the physical display.
scrolling = dict(window, monitor=0, floating=False, fullscreenHandler='scrolling')
assert not share.eligible(scrolling, monitors, 2)  # Overflow of a local column.
assert not share.eligible(dict(scrolling, at=[3200, 500]), monitors, 2)
assert share.eligible(dict(scrolling, floating=True), monitors, 2)  # Real cross-display drag.
assert share.eligible(dict(scrolling, monitor=2, workspace={'id': 8}), monitors, 2)
assert share.eligible(dict(scrolling, fullscreenHandler='default'), monitors, 2)
assert not share.eligible(dict(window, at=[2172, 500]), monitors, 2)  # Shared edge only.
assert not share.eligible(dict(window, workspace={'id': 3}), monitors, 2)
assert not share.eligible(dict(window, hidden=True), monitors, 2)
assert not share.eligible(dict(window, **{'class': 'ViewflowReverse-4'}), monitors, 2)
assert not share.eligible(dict(window, at=[5100, 500]), monitors, 2)
assert not share.eligible(window, monitors, 6)
rotated = [dict(monitors[1], transform=1)]
assert not share.eligible(dict(window, at=[4300, 500], workspace={'id': 8}), rotated, 2)
print('Mac window viewport selection passed')
