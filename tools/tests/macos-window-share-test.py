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
# HDMI + Sidecar use one sender set, even while a window spans both viewports.
monitors.append(dict(id=3, x=3072, y=1590, width=3078, height=2310, scale=2,
                     activeWorkspace={'id': 9}, specialWorkspace={'id': 0}))
sidecar_window = dict(window, at=[3200, 1700], workspace={'id': 9})
assert share.eligible(sidecar_window, monitors, 3)
assert not share.eligible(sidecar_window, monitors, 2)
spanning = dict(window, at=[3200, 1500], workspace={'id': 8})
identities = {1: w for w in [spanning] if any(share.eligible(w, monitors, mid) for mid in (2, 3))}
assert len(identities) == 1

# Master omits numeric IDs for named and special workspaces. Empty special
# workspace entries must never make every unnamed workspace visible.
named = [dict(monitors[1], activeWorkspace={'address': 'viewflow-route', 'type': 'normal', 'name': 'viewflow-route'},
              specialWorkspace={'address': '', 'type': '', 'name': ''})]
assert share.eligible(dict(window, workspace={'address': 'viewflow-route', 'name': 'viewflow-route'}), named, 2)
assert not share.eligible(dict(window, workspace={'address': 'other-route', 'name': 'other-route'}), named, 2)
assert not share.eligible(dict(window, workspace={}), named, 2)
assert not share.eligible(dict(window, workspace={'name': 'special:hidden'}), named, 2)
named[0]['specialWorkspace'] = {'address': 'special:active', 'name': 'special:active'}
assert share.eligible(dict(window, workspace={'address': 'special:active', 'name': 'special:active'}), named, 2)

# Explicit type remains authoritative even when the special name has no prefix.
named[0]['specialWorkspace'] = {'type': 'special', 'name': 'active'}
assert share.eligible(dict(window, workspace={'type': 'special', 'name': 'active'}), named, 2)
assert not share.eligible(dict(window, workspace={'type': 'normal', 'name': 'active'}), named, 2)

identity = ('0x123', 42, 'abc')
existing = {identity}
base = dict(window, address=identity[0], pid=identity[1], stableId=identity[2])
for paused in [dict(base, hidden=True), dict(base, mapped=False),
               dict(base, workspace={'name':'special:hidden'}), dict(base, at=[9000,9000])]:
    assert identity in share.selected_windows([paused], monitors, [2], existing)
    assert not share.selected_windows([paused], monitors, [2], set())
assert not share.selected_windows([], monitors, [2], existing)
assert identity not in share.selected_windows([dict(base, stableId='def')], monitors, [2], existing)

# The normal underlay is hidden while a special workspace is displayed.
assert not share.eligible(dict(window, workspace={'name': 'viewflow-route'}), named, 2)

backoff = share.RestartBackoff()
now = 100
for delay in (2, 4, 8, 16, 30, 30):
    backoff.failed(identity, now)
    assert not backoff.ready(identity, now + delay - .01)
    assert backoff.ready(identity, now + delay)
    assert backoff.ready(('another', 7, 'window'), now)
    now += delay
backoff.stable(identity)
assert backoff.ready(identity, now)
backoff.failed(identity, now)
assert backoff.until[identity] == now + 2
