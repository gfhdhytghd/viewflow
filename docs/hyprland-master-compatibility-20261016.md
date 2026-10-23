# Local Hyprland master compatibility repair

The running compositor and hyprpm headers both identify commit
`e5a03b6a5ce64ec4c85954649bad4df083627574` (reported version `0.56.0`).
The installed `/opt/viewflow` package instead contains plugins for
`efb50993780079460b0cbed1363e2166a2de1d9f` (reported version `0.56.2`).
The commit/ABI identity, rather than the apparent version ordering, determines
plugin compatibility.

The plugin adapters now use the moved window/workspace headers, window
metadata/backend/presentation accessors, shared decoration ownership, explicit
render contexts and render presentations, and the renamed exclusive keyboard
layer list. Numbered workspace IDs remain numeric on the metadata wire;
workspaces without a numbered ID use the existing unknown value `-1`.
An overlapping compositor render defers a capture without ending its stream.

## Build and verification

```sh
cmake -S platform/hyprland-plugin -B build/hyprland-master-20261016 \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build/hyprland-master-20261016 --parallel 4
ctest --test-dir build/hyprland-master-20261016 --output-on-failure
cmake -S platform/viewflow-capture -B build/capture-master-20261016 \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build/capture-master-20261016 --parallel 4
ctest --test-dir build/capture-master-20261016 --output-on-failure
```

- Input/metadata plugin: 10/10 tests passed.
- Capture plugin: 8/8 tests passed.
- Both plugins' strong dynamic imports resolve against the running compositor
  and its/plugin dependencies.
- Both rebuilt plugins loaded successfully into the existing compositor;
  `hyprctl -j plugin list` reports both names. No compositor restart occurred.
- `hl.plugin.viewflow.capture_status()` responds successfully, with no active
  capture lease at verification time.
- Bundle validation and the offscreen UI smoke check succeeded.
- `hyprctl configerrors` and `git diff --check` returned no errors.

## Local deployment

Rootless overlay: `/home/wilf/.local/lib/viewflow/hyprland-master-e5a03b6a5`.
It contains a copy of the installed GUI executable, rebuilt plugins and an
updated manifest with their actual checksums and compositor commit. Other
runtime components link to the existing `/opt/viewflow` installation.

`~/.local/bin/viewflow` and the user desktop entry
`~/.local/share/applications/org.viewflow.app.desktop` select this overlay.
The system installation remains available through `/usr/bin/viewflow`.
This overlay depends on that installation; re-evaluate it after a package or
Hyprland upgrade. Rebuild both plugins after any compositor ABI change.

To restore the system application entry, remove the two user entry files
above. That restores the previous application package, whose plugins remain
incompatible with this compositor. It does not unload the current session's
plugins.

No mouse/keyboard input was injected, no focus-changing test was performed,
and no remote peer was restarted. Cross-machine streaming, physical input,
gesture and visual acceptance remain user-operated and unverified here.
