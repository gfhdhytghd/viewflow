# Desktop window drag integration

The [security and availability policy](security-and-availability-policy.md)
supersedes older strict timing/fail-closed requirements below. Normal focus
changes and performance misses require local recovery, not whole-session exit.

Current implementation/build status and remaining work are tracked in
[project status](project-status.md). Use [desktop start](desktop-start.md) for
the manual trial; the [previous handoff](../HANDOFF-2026-09-06.md) is a historical
checkpoint, not the current build status.

This work turns a Linux application window into a spatially placed Windows
proxy while retaining the application on its Linux source. Dragging it back
moves that same Linux window back to the local monitor; it is not Windows
application capture or process migration.

## Implementation contract

- One explicitly paired device session, one atlas, up to eight enrolled source
  windows. Source windows are enrolled only by the user's chosen candidate list
  or by their crossing into the explicitly created Viewflow virtual output.
- A virtual output uses explicit physical resolution, scale and global logical
  coordinates, as defined by [display layout](display-layout.md). Its rectangle
  represents the configured Windows viewport (which may be a subrectangle of
  a display). Do not alter existing monitors or
  take over an existing headless output. Startup/shutdown own only this output.
- Desktop placement is distinct from encoder atlas allocation. Per-frame desktop
  metadata binds logical capture bounds and topology to the exact captured tile.
  The destination positions/scales the full decorated texture and clips its HWND
  to the configured display rectangle. It must not add a second titlebar.
- Native move gestures are not application pointer drags. Windows uses held-Win
  + left-drag. A focused proxy forwards Win immediately; starting a drag emits
  an explicit source Win release before the move can be admitted. A separate explicitly opted-in
  control path carries peer/window/topology identity, a drag
  generation and sequence, an original event deadline, and source acknowledgment.
  Source input is drained before changing real window placement; app input cannot
  resume under an old geometry or held-input state.
- A focused proxy forwards physical keyboard events, including Win+Space, to
  the Linux source in one FIFO with their original OS timestamps. Its local
  Windows IME is disabled; Linux owns composition for Linux applications.
  Either Windows key can also arm a move. Win+left-drag releases the source Win
  ledger first; the receiver waits for that release's source acknowledgment
  before Begin, within the original mouse-down deadline. Physical Win release
  is then consumed without a duplicate source release or Start-menu replay.
- Focus is not required for dragging: while the pointer is over an unfocused
  visible movable proxy and application keys/buttons are released, a scoped
  hook reserves Win. Unused taps and keyboard chords in that unfocused case
  replay to Windows. Keys outside our proxies pass through. Focus loss, hiding
  or destruction cancels the move, releases mouse capture and retains only
  drain-only tails for already-owned physical keys. Releasing Win early cancels
  the move; its still-held mouse button remains drain-only until release, so
  that release cannot become an application click without a matching down.
  The hook ignores only its
  own tagged replay, so the authorized cross-desktop injected input also works.
- Direct source-titlebar dragging is not advertised: captured decorations have
  no trusted titlebar hit-test regions. A fixed top strip would misclassify app
  tabs/toolbars. Supporting this needs source-authoritative decoration hit-test
  metadata; the receiver does not invent a titlebar or intercept ordinary app
  drags based on pixel position.
- Releasing a drag toward Linux after the requested window bounds cross the
  local display rectangle places the window inside the local viewport. Oversized windows
  align to its origin without resizing. Linux performs the workspace handoff;
  the receiver still waits for captured placement before changing its proxy.
  A no-op drag or motion away from Linux must not trigger this return.
- Linux remains authoritative. A move request can change only an enrolled live
  window with the exact native identity. Source commands use current supported
  Hyprland APIs and retain cleanup/return information. No shell interpolation of
  titles, arbitrary commands, or remote-provided native addresses.
- Normal End retains the final source placement. Cancel and orderly retirement
  of an active drag request restoration of that drag's retained position,
  workspace and floating state. Restoration is checked for every owned token;
  failed or expired cleanup is reported, never treated as a successful return.
  A killed process or expired native token is not a guarantee of restoration.
- Geometry/visibility changes are bound to subsequent captured frames; receiving
  a request or issuing an OS call is not evidence that pixels were presented.
- Startup tools must produce runnable paired configuration and explain the
  gestures and stop/restore operation. Main-desktop changes and real interaction
  acceptance are left for the user's explicitly started test run.

This document defines the implementation target, not completed acceptance.
