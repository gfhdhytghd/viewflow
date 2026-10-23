# Special workspace compatibility

Hyprland master reports workspace type explicitly. A missing numeric `id`
does not distinguish a named normal workspace from a special workspace.
Viewflow now checks `type: "special"` and retains the legacy `special:` name
fallback. Viewport selection and the shell crossing selector also handle
special workspaces without numeric IDs, using type and address/name identity.

The route launcher previously activated an ordinary named workspace and only
opened a special workspace if it already existed. It now creates/activates the
special workspace unconditionally. The monitor Lua setter takes the bare
special name and adds `special:` itself; workspace rules and window moves use
the full selector.

An existing internal normal workspace is migrated without selecting a user's
numbered workspace: its windows move with `follow=false`, then the virtual
monitor gets an unused numbered backing workspace. Subsequent activation is
idempotent. No pointer warp or input injection is used.

Applied to the source launchers and rootless installed overlay at
`~/.local/lib/viewflow/hyprland-master-e5a03b6a5`. Live readback on `HEADLESS-1`
confirmed `special:viewflow-gui-a4834581f2f870e0-1` with `type: "special"`;
the former normal workspace no longer exists. The backing workspace is `4`.
The physical monitor and active window retained focus during application.

Validation: autostart configuration tests, executable Lua migration model
(including bare-name and repeated-activation checks), viewport regressions,
hermetic desktop launcher suite, Lua syntax, bundle checksums and live
`hyprctl configerrors`. Live input and visual bar acceptance are not inferred
from the compositor readback.
