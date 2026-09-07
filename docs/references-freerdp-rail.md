# FreeRDP RemoteApp/RAIL geometry notes

Source inspected: FreeRDP commit
`b2a12143658cfb8667406f224488a1b5dcbd221d`. The X11 frontend is the useful
reference for move/resize lifecycle behavior. The Windows RemoteApp frontend
currently acknowledges `LOCALMOVESIZE` without implementing it, so its normal
desktop `WM_EXITSIZEMOVE` handling must not be treated as a RemoteApp lifecycle.

This note is about control and geometry, not the graphics transport. In
particular, a core RemoteApp `WINDOW_STATE_ORDER`, a RAIL virtual-channel PDU,
ordinary RDP pointer input, a local compositor configure event, and a Viewflow
geometry epoch are different events even when they describe one user gesture.

## Conclusions for Viewflow

- FreeRDP has no continuous RAIL move/resize PDU. A server-directed pointer
  drag is bracketed by `LOCALMOVESIZE(start=true/false)`, while the continuous
  network traffic is ordinary RDP pointer input and the local geometry samples
  are X11 `ConfigureNotify` events.
- `WINDOWMOVE` is client-to-server geometry feedback. It is not the authoritative
  server-to-client window-state stream and is not emitted continuously during
  an active server-directed pointer drag.
- The RAIL window-state order carries outer/window geometry, client/content
  geometry, resize margins, and visibility geometry separately. These fields
  must remain separate in the adapter.
- X11 FreeRDP treats RemoteApp coordinates as local X root pixels. It does not
  apply display-channel scale factors, smart-sizing transforms, monitor-origin
  normalization, or `_NET_FRAME_EXTENTS` correction to RAIL geometry.
- Viewflow must convert protocol pixels to canonical DIP at its adapter boundary
  using a topology/scale snapshot pinned for the whole geometry epoch.
- `bounds_dip` should mean the outer proxy/window bounds. Capture/content bounds,
  invisible resize margins, and local compositor decorations are related but
  distinct rectangles.
- `Begin` and `Update` are provisional. Only `End` commits an epoch and permits
  content tagged with that epoch to be presented.

## Protocol layers and direction

| Signal | Direction | Purpose | FreeRDP source |
| --- | --- | --- | --- |
| Client status | client to server | Advertises local move/size and resize-margin support | `include/freerdp/rail.h:163-175`, `channels/rail/client/client_rails.c:9-30` |
| `LOCALMOVESIZE` | server to client | Starts or ends a client-side move/size operation | `include/freerdp/rail.h:453-460`, `channels/rail/client/rail_orders.c:119-136` |
| Ordinary pointer input | client to server | Carries pointer motion/button state during a pointer drag | `client/X11/xf_event.c:406-475` |
| `WINDOWMOVE` | client to server | Reports a client/WM-selected final or independent geometry | `include/freerdp/rail.h:462-469`, `channels/rail/client/rail_orders.c:1359-1385` |
| `WINDOW_STATE_ORDER` | server to client | Authoritative RemoteApp window metadata and geometry | `include/freerdp/window.h:194-228`, `libfreerdp/core/window.c:310-420` |
| X11 `ConfigureNotify` | local WM to client | Reports the local top-level window's actual geometry | `client/X11/xf_event.c:883-914` |

`TS_RAIL_ORDER_WINDOWMOVE` is order type `0x0008` and
`TS_RAIL_ORDER_LOCALMOVESIZE` is `0x0009` (`include/freerdp/rail.h:576-586`).
Both bodies are fixed at 12 bytes (`channels/rail/rail_common.h:42-47`), but
their payloads and directions differ:

```text
LOCALMOVESIZE:
  windowId:u32, isMoveSizeStart:u16, moveSizeType:u16, posX:i16, posY:i16

WINDOWMOVE:
  windowId:u32, left:i16, top:i16, right:i16, bottom:i16
```

The move/size type is one of left, right, top, the four corners, bottom,
`MOVE`, `KEYMOVE`, or `KEYSIZE` (`include/freerdp/rail.h:178-192`). The X11
callback is installed in `client/X11/xf_rail.c:1393-1406`; channel dispatch and
decode are in `channels/rail/client/rail_orders.c:593-616,1019-1047`.

## X11 server-directed move/resize lifecycle

The X11 frontend uses this explicit state machine
(`client/X11/xf_rail.h:30-47`):

```text
LMS_NOT_ACTIVE
    -> LMS_STARTING
    -> LMS_ACTIVE
    -> LMS_TERMINATING
    -> LMS_NOT_ACTIVE
```

The full pointer-driven sequence is:

```text
client status capability
  -> local pointer button down reaches the server
  -> server LOCALMOVESIZE(start=true)
  -> X11 sends _NET_WM_MOVERESIZE and enters LMS_STARTING
  -> first ConfigureNotify enters LMS_ACTIVE
  -> subsequent ConfigureNotify updates local geometry
  -> ordinary RDP pointer MOVE input continues during the drag
  -> local end sends simulated RDP button-1 up and enters LMS_TERMINATING
  -> server LOCALMOVESIZE(start=false)
  -> LMS_NOT_ACTIVE
```

### Start

`xf_rail_server_local_move_size()` maps the server move type to an EWMH
`_NET_WM_MOVERESIZE` direction (`client/X11/xf_rail.c:1199-1296`). For `MOVE`
only, the PDU point is window-relative and is translated to root coordinates
before starting (`client/X11/xf_rail.c:1267-1271`).

`xf_StartLocalMoveSize()` saves the root point and direction, changes state to
`LMS_STARTING`, ungrabs the pointer, and sends `_NET_WM_MOVERESIZE`
(`client/X11/xf_window.c:1156-1181`). The first `ConfigureNotify` changes
`LMS_STARTING` to `LMS_ACTIVE` (`client/X11/xf_event.c:1176-1188`).

### Continuous phase

Each configure event translates the X window position to root coordinates and
updates `x`, `y`, `width`, and `height` (`client/X11/xf_event.c:883-914`). While
the state is active, configure, visibility, property, expose, and gravity
events are allowed to continue; other events terminate the local move
(`client/X11/xf_event.c:1215-1231`).

FreeRDP deliberately does not send a continuous `WINDOWMOVE` stream during this
server-directed gesture: `xf_rail_adjust_position()` returns unless the state
is `LMS_NOT_ACTIVE` (`client/X11/xf_rail.c:280-310`). Pointer motion still goes
to the server through normal RDP input (`client/X11/xf_event.c:406-475`). Thus,
local configure callbacks are the right source for provisional Viewflow
`Update` samples; RAIL PDUs alone do not provide them.

### End

`xf_rail_end_local_move()` queries the final pointer position and, for pointer
move/resize, sends a simulated RDP button-1 release as required by the protocol
(`client/X11/xf_rail.c:315-383`, especially `359-370`). It then copies the local
geometry into the cached server fields before entering `LMS_TERMINATING`. The
comment explains that this avoids a graphics update arriving before the later
RAIL geometry update (`client/X11/xf_rail.c:373-382`).

Keyboard move/size differs: FreeRDP sends one explicit final `WINDOWMOVE`
(`client/X11/xf_rail.c:328-356`). When the server's
`LOCALMOVESIZE(start=false)` arrives, `xf_EndLocalMoveSize()` cancels an EWMH
operation that never advanced past `LMS_STARTING`, then returns to
`LMS_NOT_ACTIVE` (`client/X11/xf_window.c:1183-1208`).

For Viewflow, pointer release is evidence that the local gesture stopped, but
it is not by itself an authoritative remote geometry commit. Prefer the server
end bracket plus a confirmed final geometry. If the server corrects geometry
after an epoch has committed, emit a new correction epoch rather than changing
the meaning of the committed epoch.

## Locally initiated WM geometry

A user or local WM may move a RemoteApp window without a server
`LOCALMOVESIZE(start=true)`. On `ConfigureNotify`, FreeRDP translates
parent-relative coordinates to X root coordinates and calls
`xf_rail_adjust_position()` (`client/X11/xf_event.c:887-914`). Focus return also
flushes deferred position changes (`client/X11/xf_event.c:662-700`).

The outbound rectangle is expanded by the server-provided resize margins:

```text
left   = x - resizeMarginLeft
top    = y - resizeMarginTop
right  = x + width  + resizeMarginRight
bottom = y + height + resizeMarginBottom
```

This is implemented in `client/X11/xf_rail.c:294-310`. Right and bottom are
one-past extents, and all four coordinates are cast to signed 16-bit values.
The call path is `ClientWindowMove` -> `rail_client_window_move()`
(`channels/rail/client/rail_main.c:407-416`) ->
`rail_send_client_window_move_order()`
(`channels/rail/client/rail_orders.c:1359-1385`).

A Viewflow backend that receives only configure callbacks may synthesize
`Begin` on the first confirmed geometry change, coalesce subsequent changes as
`Update`, and end on a real compositor grab-end signal or a carefully bounded
settle rule. It must not synthesize independent committed epochs for every
configure callback.

## Window, client, margin, and decoration geometry

`WINDOW_STATE_ORDER` keeps these values separate
(`include/freerdp/window.h:194-228`):

- `clientOffsetX/Y` and `clientAreaWidth/Height`: remote client/content area.
- `windowOffsetX/Y` and `windowWidth/Height`: remote window rectangle.
- `windowClientDeltaX/Y`: offset used when mapping window and client geometry.
- `resizeMarginLeft/Top/Right/Bottom`: invisible resize affordance.
- `visibleOffsetX/Y` and `visibilityRects`: clipping geometry.

The core parser updates them under separate field flags
(`libfreerdp/core/window.c:334-410`). X11 mirrors the fields independently in
`xfAppWindow` (`client/X11/xf_rail.h:49-112`) and creates the local app window
from `windowOffsetX/Y` plus `windowWidth/Height`, not from the client area
(`client/X11/xf_rail.c:1461-1486`, `client/X11/xf_window.c:1030-1081`). Local X
decorations begin disabled.

Client geometry is used when translating visibility clipping:

```text
visibilityRectsOffsetX =
    visibleOffsetX - (clientOffsetX - windowClientDeltaX)
visibilityRectsOffsetY =
    visibleOffsetY - (clientOffsetY - windowClientDeltaY)
```

See `client/X11/xf_rail.c:685-692`. It is not a general outer-to-client DPI or
frame transform.

When all fields come from one complete authoritative snapshot, remote frame
insets can be derived as follows:

```text
left   = clientOffsetX - windowOffsetX
top    = clientOffsetY - windowOffsetY
right  = windowWidth  - left - clientAreaWidth
bottom = windowHeight - top  - clientAreaHeight
```

This formula is a Viewflow-side derivation, not code copied from FreeRDP. Do not
derive it from partial updates or combine it with local compositor decorations.

The adapter should retain at least:

```text
remote_outer_rect_px
remote_client_rect_px
remote_resize_margins_px
local_decoration_insets_px
capture_content_rect_px
topology_generation
pixel_to_dip_transform
```

The canonical Viewflow `bounds_dip` is `remote_outer_rect_px` mapped into the
shared DIP space. Capture dimensions and texture dimensions correspond to the
content rect and remain separate.

### FreeRDP margin inconsistencies to avoid

There are two concrete implementation hazards in the inspected X11 code:

1. `xf_rail_adjust_position()` compares the unexpanded local `x/y/width/height`
   directly with cached server outer geometry before sending a margin-expanded
   rectangle (`client/X11/xf_rail.c:289-308`). Nonzero margins can therefore
   cause repeated mismatch reports.
2. At pointer-drag end, FreeRDP sends the protocol button release but stores the
   unexpanded local geometry into fields that normally track server outer
   geometry (`client/X11/xf_rail.c:373-381`). This is race-prone and must not be
   used as evidence that outer and client rectangles are interchangeable.

Viewflow should compare like coordinate spaces and update cached authoritative
state only from an authoritative snapshot.

## DPI and multi-monitor coordinates

X11 input scaling is explicitly guarded by `if (!xfc->remote_app)`
(`client/X11/xf_event.c:312-365`). RemoteApp input bypasses smart-sizing and
XRender coordinate transforms. Window geometry likewise moves directly between
server fields and X root coordinates; `xf_MoveWindow()` passes the supplied
position and size directly to X (`client/X11/xf_window.c:1210-1225`). FreeRDP
does not query `_NET_FRAME_EXTENTS` for this path.

The display-control channel does carry `DesktopScaleFactor` and
`DeviceScaleFactor` (`client/X11/xf_disp.c:45-127,190-224,430-458`), but those
values are not applied to the RAIL window/input/move paths above. Likewise,
`TS_RAIL_CLIENTSTATUS_HIGH_DPI_ICONS_SUPPORTED` is an icon capability, not a
geometry-scale contract (`include/freerdp/rail.h:169-170`).

Therefore a FreeRDP RAIL coordinate must not be labeled DIP merely because a
desktop scale factor was negotiated. Viewflow must explicitly map it:

1. Resolve the remote desktop pixel point/rect against the current remote
   monitor topology.
2. Resolve the target proxy against the local/shared canvas topology.
3. Apply a recorded pixel-to-DIP transform and rounding policy.
4. Pin the topology generation and transform from `Begin` through `End`.

If topology or scale changes during a drag, either finish the epoch under its
original transform and start a correction epoch, or cancel and restart the
interaction explicitly. Never reinterpret earlier `Update` samples under a new
scale.

RAIL move rectangles are signed 16-bit. Some X11 work-area/monitor paths cast
coordinates to unsigned 16-bit, so negative monitor origins and very large
virtual desktops are additional compatibility hazards. The Viewflow model
must preserve signed, sufficiently wide coordinates internally and validate
range only at a legacy RAIL boundary.

## Maximize and fullscreen

Desktop fullscreen and RemoteApp maximize are separate mechanisms:

- Ordinary xfreerdp desktop fullscreen uses `xf_SetWindowFullscreen()` and
  display-channel state (`client/X11/xf_window.c:264+`).
- A RemoteApp sends minimize, maximize, and restore system commands
  (`client/X11/xf_event.c:1117-1143`) and receives subsequent window state.
- For server-driven maximize, X11 lets the WM choose the work-area size rather
  than forcing the server rectangle (`client/X11/xf_rail.c:699-717`).
- Restore suppresses one transient configure event so an intermediate geometry
  is not echoed back (`client/X11/xf_window.c:1284-1297`,
  `client/X11/xf_event.c:1162-1172`).
- Cinnamon/Muffin may report a RAIL maximize as fullscreen. FreeRDP normalizes
  that local state without feeding a spurious transition back to the server
  (`client/X11/xf_event.c:1045-1086`).

For a maximized GFX surface larger than the local window, X11 shifts the blit by
the left/top resize margins so the off-screen margin frame is clipped
(`client/X11/xf_window.c:1597-1602`). Maximized windows also clear visibility
clipping (`client/X11/xf_rail.c:719-727`). These are rendering exceptions, not
permission to redefine outer bounds as content bounds.

Viewflow should keep fullscreen/maximize/migration state separate from geometry.
A transition can use a geometry epoch for its final bounds, but transient
compositor configure events must be suppressed until the target state is
confirmed.

## Windows frontend caveat

The current Windows RemoteApp frontend is not a lifecycle reference:

- `wf_rail_server_local_move_size()` simply returns success
  (`client/Windows/wf_rail.c:893-897`).
- It removes a set of native frame styles, creates the window directly from
  `windowOffsetX/Y/windowWidth/Height`, and applies later server offsets/sizes
  with `SetWindowPos()` (`client/Windows/wf_rail.c:413-417,419-554`).
- It does not provide a RemoteApp-specific begin/update/end implementation or a
  RAIL-specific DPI transform.
- `WM_EXITSIZEMOVE` in `client/Windows/wf_event.c:485-488` belongs to the main
  desktop window path, not this RemoteApp window path.

## Mapping RAIL behavior to Viewflow geometry epochs

The following is the required adapter policy, not a claim about FreeRDP's wire
format.

### 1. Allocate and begin

- Allocate one strictly increasing epoch per window at actual interaction
  start.
- Emit `Begin(e)` for server `LOCALMOVESIZE(start=true)`, a compositor
  grab-start callback, or a synthesized locally initiated WM drag.
- Snapshot topology generation, pixel-to-DIP transform, rounding policy, and
  the outer/client/margin relationship. Keep that snapshot for all phases of
  `e`.

### 2. Update provisionally

- Emit coalesced `Update(e)` from confirmed compositor configure/geometry
  callbacks, not from pointer prediction.
- Keep the same transform snapshot for every update.
- During an active local drag, server `WINDOW_STATE_ORDER` messages may update
  remote metadata but must not fight the local proxy position. This mirrors the
  ownership guard in FreeRDP's `xf_rail_adjust_position()` and local-move path.
- Media produced before commit remains tagged with committed epoch `N`. The
  first content encoded with the new dimensions is tagged `e`, but the receiver
  must not present it before `End(e)`.

### 3. End and commit

- Emit `End(e)` only after the actual compositor grab ends and final geometry
  is confirmed. For server-directed RAIL pointer drag, prefer
  `LOCALMOVESIZE(start=false)` plus the authoritative final window state.
- On commit, purge pending frames tagged below `e`.
- The committed geometry for `e` and frame dimensions tagged `e` must agree.
  A move-only epoch may reuse the existing texture if content size is unchanged.
- A later server correction gets a new epoch. Never mutate a committed epoch.

### 4. Preserve state boundaries

- Fullscreen, maximize, and cross-device migration are state transitions with
  their own ownership and suppression rules. Their final bounds still commit
  through a geometry epoch.
- A topology change mid-gesture does not retroactively rescale the active
  epoch.
- Outer proxy geometry, content capture geometry, and local decoration geometry
  remain separately inspectable in diagnostics.

## Current Viewflow implementation check

The protocol already models `Begin`, `Update`, and `End` in
`protocol/viewflow/v1/control.proto:48-60`. `WindowSession::apply_geometry()`
requires a begin, matching updates, and a matching end; only end advances
`committed_epoch` (`crates/viewflow-core/src/window.rs:61-96`). The coordinator
advances the frame queue when the geometry commit succeeds
(`crates/viewflow-core/src/coordinator.rs:133-153`).

`FrameQueue::set_geometry_epoch()` purges older pending frames, and `push()`
rejects frames below or above the committed epoch. The queue therefore enforces:

```text
present(frame.geometry_epoch) only if
    frame.geometry_epoch == committed_geometry_epoch
```

Viewflow currently chooses explicit rejection for future-epoch planes; the
producer must retransmit or reproduce them after `End(e)` commits. This keeps
the queue bounded and prevents new-size content from becoming presentable
early.
