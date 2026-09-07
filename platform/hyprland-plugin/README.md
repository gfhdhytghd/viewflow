# Viewflow Hyprland metadata plugin

This GPL-3.0-only plugin is the Hyprland 0.56+ compositor-side metadata and
physical edge-input bridge for Viewflow. It emits bounded, non-blocking window,
monitor, and input messages over a local Unix `SOCK_SEQPACKET` socket. It does
**not** capture pixels, export DMA-BUFs, or implement blur reconstruction yet.

## Build

```sh
cmake -S platform/hyprland-plugin -B build/hyprland-plugin \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build/hyprland-plugin --parallel
ctest --test-dir build/hyprland-plugin --output-on-failure
```

The plugin compares the full Hyprland/dependency ABI hash at load time and
refuses to load if it was not built against the running compositor. Rebuild it
after every Hyprland ABI update.

## Socket

The default socket is `$XDG_RUNTIME_DIR/viewflow/hyprland.sock`. Set
`VIEWFLOW_HYPRLAND_SOCKET` in Hyprland's environment to override it. Viewflowd
must create and listen on the `AF_UNIX`, `SOCK_SEQPACKET` endpoint. The plugin is
a non-blocking client; a missing daemon or full socket buffer cannot stall the
compositor. State is resynchronized after every reconnect.

Every packet is at most 16 KiB and uses a 20-byte little-endian header:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | `u32` | magic `VFHY` |
| 4 | `u16` | protocol version (`1`) |
| 6 | `u16` | message type |
| 8 | `u32` | payload byte length |
| 12 | `u64` | monotonically increasing connection-local sequence |

Strings are `u16 byte_length` followed by UTF-8 bytes. Titles are bounded to
4096 bytes, classes and descriptions to 1024 bytes, and names to 256 bytes.
Overlong window text is truncated and marked with `WINDOW_TEXT_TRUNCATED`.
Window object IDs are opaque and valid only for the current Hyprland process.

Metadata messages are `HELLO`, `SNAPSHOT_BEGIN`, `SNAPSHOT_END`,
`WINDOW_UPSERT`, `WINDOW_REMOVE`, `MONITOR_UPSERT`, and `MONITOR_REMOVE`.

The input bridge attaches raw listeners only to non-virtual devices that are
not tagged `viewflow-injected`. An outward raw motion at a compositor-layout
edge emits `EDGE_CANDIDATE`; the daemon must reply with a strictly sequenced
`INPUT_LEASE_ACTIVATE` packet before local delivery is suppressed. Captured
relative motion includes accelerated and unaccelerated deltas. Buttons use
Linux evdev button codes; keys use Linux evdev keycodes; axis messages retain
source, axis, relative direction, smooth delta, discrete/v120 data, and pointer
frame boundaries. Every input packet carries the active lease generation,
target device ID, and a lease-local event sequence.

`INPUT_LEASE_RELEASE`, a socket disconnect, a physical device removal, or
plugin unload ends capture. The plugin emits `INPUT_RELEASE_ALL` when the
connection still exists and always clears its own held button/key sets. The
receiver must independently release held input on transport loss, because a
disconnected sender cannot deliver cleanup.

Viewflow must be the sole edge owner while this lease is active. Deskflow may
remain a sidecar, but its own edge forwarding must be disabled for this source;
do not inject inbound virtual/EIS input into a host while it is the outbound
source because Hyprland's cancellable global events do not identify the source
device.

During an active lease the plugin temporarily disables each tracked physical
keyboard through Hyprland's `m_enabled` flag. The global key event is
cancellable, but the modifier signal is not; disabling the physical keyboard
blocks both local paths while raw per-device key listeners continue to feed
Viewflow. Release, disconnect, device loss, and plugin unload restore the exact
pre-lease value through weak device references, then resynchronize the current
modifier state for keyboards that were enabled before capture.

Lease activation is rejected while Hyprland reports locally held keys. This
prevents a key pressed before capture from remaining logically held by the
local seat when its release occurs remotely. While captured, tick and raw
key/modifier listeners reassert suppression in case a config reload rewrites a
keyboard's enabled flag.

See `include/viewflow_hyprland/protocol.hpp` for numeric message constants.

### Window-pointer revocation

The ordinary `WINDOW_POINTER_BEGIN` (50) is motion-only. A trusted local caller
must explicitly use `WINDOW_POINTER_BEGIN_BUTTONS` (56) to authorize buttons;
its binding layout is identical to BEGIN. Renewal requires an unchanged mode
and target and preserves the native session and focus. Button authority must
never be inferred from an existing motion-only source option.

`WINDOW_INPUT_REBIND_RESIZED` (61) is a separate, trusted-local reauthorization
command with the same 56-byte binding payload as BEGIN. After resize cleanup,
the controller retains the inert session's exact target listeners until the
original grant expires. No input command is accepted by that ended session.
Ordinary BEGIN/renewal cannot leave this suspension; a rebind requires a strictly
newer generation, the same live window/surface/PID, and the exact current extent.
Capabilities are inherited from the suspended session, not supplied by rebind.
Repeated resize does not extend the original suspension deadline. Local takeover,
lock, target loss, seat exclusion, expiry, END, disconnect, or failed rebind
destroys recovery authority. The new session must be active before RESULT Begun.
The daemon must separately authorize the newer captured/presented geometry;
this local opcode is not remote authorization. The native implementation and
Rust codec have unit/build coverage. The selected-authorization daemon route
supports resize-only suspension when idle, with newer frame/epoch authorization
required before rebind; other routes and pending commands remain fail-closed.
Live acceptance remains pending; the deployed daemon/plugin have not been updated.

Wheel authority additionally requires `WINDOW_POINTER_BEGIN_BUTTONS_WHEEL` (58),
with the same binding payload. Renewal cannot add or remove wheel/button
capabilities. `WINDOW_POINTER_WHEEL` (57) has a 40-byte little-endian payload:
`generation:u64, deadline_ns:u64, x:f64, y:f64, vertical_up_120:i32, horizontal_right_120:i32`.
One detent is 120 units. Both-zero or axes outside ±67108863 are rejected before
native conversion; the bound keeps the 15-surface-unit detent in signed 24.8.
RESULT outcome 5 is WheelSent, distinct from button and motion. No existing
source route enables this new grant automatically.

The session resolves/focuses the authorized point, rechecks deadline and focus,
and sends only to pointer resources currently bound to its exact owned surface.
Both axes share one wheel frame per resource. Wayland v8+ receives value120;
older clients receive proportional axis distance and discrete steps only for
whole detents, without storing residual scroll that could cross into another
target. DnD, missing pointer capability, absent recipients and lost authority
reject delivery. This implementation has build/unit coverage, not live wheel
acceptance yet. The Qt probe now logs angle/pixel deltas to support that check.

`WINDOW_POINTER_BUTTON` (55) has a 40-byte little-endian payload:
`generation:u64, deadline_ns:u64, x:f64, y:f64, button:u32, state:u32`.
Buttons 1..5 mean left/middle/right/back/forward; state 1 is down and 2 is up.
RESULT (53) outcome 4 means ButtonSent and cannot complete a motion request.
Duplicates and orphan ups are rejected. Recipients are exact weak native
pointer-resource references (at most 64 per button, at most 1024 inspected).
Disconnect, expiry, target loss, local takeover and end release only recorded
presses still belonging to the original surface; physical held buttons prevent
initial target binding. Local revocation invokes cleanup synchronously.

Dragging within the same surface can retain presses across renewal. Crossing
subsurfaces or implementing native file DnD requires additional routing and is
not claimed here. An active DnD rejects further button commands and retires the
session; cleanup cancels DnD only when its origin is the session's exact owned
surface and the session still has pressed records. No unrelated DnD is cancelled.
The source/Windows button producers are now wired under independent explicit
opt-ins. These paths still need completed application-side press/release/cleanup
acceptance; the first live probe received a press and terminal release but its
video deadline failure prevents claiming a completed gesture.

Window-pointer sessions are separate from the device-wide input lease. Native
IPC `WINDOW_POINTER_REVOKED` (54) is an unsolicited terminal notification with
payload `generation:u64, reason:u32, reserved_zero:u32`, all little-endian. It is
sent once when the retained native session is retired while the connection is
still live; it does not acknowledge an outstanding command. The daemon must
close its window-input route immediately, including while idle. An explicit
normal END or a valid BEGIN renewal does not itself emit this notification.

Reason codes are: 1 cancelled, 2 window unmapped, 3 surface unmapped, 4 surface
destroyed, 5 resized, 6 session locked, 7 local motion, 8 local button, 9 local
axis, 10 local key, 11 invalid target, 12 seat unavailable, 13 expired, 14 focus
changed, 15 competing route. No key code, text, or button value is disclosed.
Revoked authority cannot be renewed on that connection; reconnect requires a
fresh source authorization. Socket readability, not animation activity, drives
command handling. A low-rate watchdog maintains idle/disconnected state.

### Input payloads

All numeric fields below are little-endian. `target_device` is the raw 16-byte
Viewflow `Id128`; edge values are left=0, right=1, top=2, bottom=3. Daemon
command sequences in the common header must be non-zero and strictly increase
for the life of one socket connection. Lease generations must also be non-zero
and strictly increase across reconnects for the life of the loaded plugin.

| Direction | Message | Payload fields in order |
| --- | --- | --- |
| plugin -> daemon | `EDGE_CANDIDATE` | `monitor_id:i64`, `edge:u8`, `edge_position:f64`, `anchor_x:f64`, `anchor_y:f64`, `time_ms:u32` |
| daemon -> plugin | `INPUT_LEASE_ACTIVATE` | `generation:u64`, `target_device:[u8;16]` |
| daemon -> plugin | `INPUT_LEASE_RELEASE` | `generation:u64` |
| plugin -> daemon | `INPUT_RELATIVE_MOTION` | `generation:u64`, `target_device:[u8;16]`, `event_sequence:u64`, `time_ms:u32`, `delta_x:f64`, `delta_y:f64`, `unaccel_x:f64`, `unaccel_y:f64` |
| plugin -> daemon | `INPUT_POINTER_BUTTON` | `generation:u64`, `target_device:[u8;16]`, `event_sequence:u64`, `time_ms:u32`, `evdev_button:u32`, `pressed:u8` |
| plugin -> daemon | `INPUT_POINTER_AXIS` | `generation:u64`, `target_device:[u8;16]`, `event_sequence:u64`, `time_ms:u32`, `wl_source:u32`, `wl_axis:u32`, `wl_relative_direction:u32`, `smooth_delta:f64`, `discrete_v120:i32` |
| plugin -> daemon | `INPUT_POINTER_FRAME` | `generation:u64`, `target_device:[u8;16]`, `event_sequence:u64` |
| plugin -> daemon | `INPUT_KEY` | `generation:u64`, `target_device:[u8;16]`, `event_sequence:u64`, `time_ms:u32`, `evdev_keycode:u32`, `pressed:u8`, `update_modifiers:u8` |
| plugin -> daemon | `INPUT_RELEASE_ALL` | `generation:u64`, `target_device:[u8;16]`, `event_sequence:u64` |

`INPUT_LEASE_ACTIVATE` is accepted only while an edge candidate is pending and
only for a non-zero target device. The pending state expires after 250 ms, so a
late grant is ignored rather than stealing input after the user has moved on.
