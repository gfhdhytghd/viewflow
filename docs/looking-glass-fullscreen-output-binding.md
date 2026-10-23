# Fullscreen Windows output binding for the Looking Glass path

Read-only integration findings, 2026-10-09. No display configuration, focus,
input, driver state, or production route was changed for this investigation.
The source locations below describe the inspected worktree; they are not live
proof of a reserved output or Desktop Duplication support.

## Existing ownership and geometry

- `platform/windows-reverse/main.cpp:108`, `Source`: HWND, WGC, capture geometry,
  staging, and identity exist; source-output binding and output leases do not.
- `main.cpp:342`, `App::candidate()`, uses the configured guest viewport;
  inventory removal at approximately line 474 removes sources outside it.
  An owned output lease must preserve the existing Source identity when moving
  its backing HWND outside that viewport.
- `main.cpp:294`, geometry input, uses `SetWindowPos` with `SWP_NOACTIVATE` and
  `SWP_NOZORDER`. This is reusable for targeted geometry changes, without the
  separate `App::focus()` helper or input injection.
- `main.cpp:813` emits guest HWND coordinates in Tile metadata. Linux
  `platform/linux-reverse/main.cpp:938` converts those into proxy coordinates.
  A reserved-output route needs distinct backing and presentation coordinates;
  publishing the reserved output origin unchanged would move the Linux proxy.
- `platform/linux-reverse/main.cpp:543`, `top_configure`, can observe actual
  fullscreen state; `synchronize_geometry()` already inventories outputs.
  Its current fullscreen early exit around line 1047 skips source resize.
- `platform/windows-reverse/main.cpp:897` has a single-surface atlas bypass;
  it still consumes window capture. It is not a desktop-output binding.

## Existing virtual display capabilities

`platform/windows-reverse/virtual_display.cpp:163` configures an **existing**
virtual display's mode and position. DPI handling starts around line 80.
There is no per-window monitor lease or monitor hotplug API in this utility.
Its configure command persists settings; production temporary leasing should
instead save/read back/restore the selected output mode.

Do not use `primary()` at line 23 as the default: it translates the entire
active display layout. Switching primary would disturb unrelated outputs.

The local driver source in
`build/vdd-upstream/Virtual Display Driver (HDR)/MttVDD/Driver.cpp:3775`
creates the configured monitor count during `FinishInit()`. Maximum monitors
are set from that count around line 3711. The IO-control callback registration
around line 2842 is commented out. This is not an available runtime hotplug
service. Existing per-monitor swapchain ownership can support several outputs,
but does not establish allocation or release on a window's behalf.

## Smallest production implementation

1. Use one explicitly reserved, already existing non-primary virtual output.
   Inventory its adapter LUID, display source/target IDs, HMONITOR, physical mode
   and DXGI output. Do not treat a Linux output index or persistent DISPLAYn
   string as sufficient identity. Enumerate actual Desktop Duplication support
   on that output; D12 shared-texture success is not evidence of DD support.
2. On a Linux fullscreen request, lease that output to the existing window ID
   and route epoch. Save the target HWND's original geometry and output mode.
   Keep the Source enrolled before moving it; leave unrelated windows alone.
3. Move/resize the target backing window without activation. Read back actual
   bounds because an application may reject the requested dimensions. Maintain
   backing-to-presentation coordinate translation, including input coordinates
   and dependent popup positioning.
4. Add a separate Desktop Duplication backend for the exact leased output and
   adapter. Feed acquired textures through the D12 shared-copy/external-memory
   path. Preserve the existing window-only WGC backend and its tests.
5. Keep WGC/last snapshot until a completed frame matches the current route
   epoch, window ID and physical size. Whole-output pixels must actually
   represent the intended window: destination fullscreen alone does not prove
   source isolation. If other windows, taskbar or overlays invalidate that
   mapping, retain per-window WGC/D12 instead of hiding or moving unrelated
   windows. Decide how owned popups are represented so they are not both baked
   into the desktop image and rendered as duplicate proxies.
6. On exit or backend failure, request window capture locally, retain the last
   snapshot, drain in-flight GPU leases, and restore only the owned HWND/output
   geometry. Route failure must not terminate unrelated streams or the session.

Steps 1-6 can be implemented for an **existing reserved output** using ordinary
window/output management. Creating additional outputs dynamically when the
reserved pool is exhausted requires additional driver/control-plane capability;
this repository has no current implementation. A fixed preconfigured pool is
an incremental option, not proof of arbitrary per-window output allocation.

Interactive acceptance remains user-operated. Capability inventory, owned
synthetic fixtures, build checks, and non-input inspection must be distinguished
from actual user fullscreen transitions and application-specific popup behavior.

## Output lease coordinator candidate (2026-10-09)

`platform/reverse-common/fullscreen_output_lease.hpp` adds a per-reserved-output
coordinator, not an enabled capture route. It requires positive runtime evidence
of an existing reserved non-primary output, actual DD capability, desktop
exclusivity, window incarnation, route ticket and source identity (adapter LUID,
DisplayConfig source/target IDs and inventory generation). Binding requires
actual bounds readback. Each GPU consumer gets a unique completion token, so a
duplicate completion cannot release another frame. Exit/failure stops accepting
DD frames, waits for outstanding tokens, exposes original-window restoration,
and releases the reservation only after readback or confirmed destruction of
the original window. Failed restoration retains the reservation and can be
retried without closing the session. Last-snapshot ownership remains with the
existing presentation transition class.

The first integration should lease only an output already in the required mode;
this coordinator does not change or restore display modes. Do not claim an
arbitrary-resolution output pool until mode snapshot/apply/readback/restore is
implemented. No primary-output relocation or driver hotplug is implied.

Concrete integration remaining (current source locations):

1. Windows `main.cpp:109`, Source: add window incarnation, lease coordinator
   reference and separate backing/presentation rectangles. Preserve enrolled
   Source identity when backing HWND moves outside the ordinary guest viewport.
2. At fullscreen request handling, use QueryDisplayConfig to map the reserved
   output to source/target IDs and LUID. Validate the exact DXGI output and actual
   DD capability; reject the DD candidate locally if unsupported. Reserve before
   `SetWindowPos(SWP_NOACTIVATE|SWP_NOZORDER)`; call `bound()` only after actual
   geometry and output-isolation readback. The existing WGC backing-resize
   candidate alone does not establish any of these output-binding facts.
3. `d12_desktop_capture.hpp:26` reopen currently matches LUID and DeviceName.
   Revalidate DisplayConfig target/source identity against the lease before every
   reopen/acquired-frame acceptance. DISPLAYn alone can resolve to a different
   target after topology changes. A mismatch requests WGC fallback/restoration;
   it must not silently capture the replacement output.
4. `DesktopCapture::acquire` at line 114 returns a full DD frame lease. Retain
   that object through D12 copy completion, not just its texture COM pointer.
   After checking actual frame extent and output exclusivity, call `begin_frame`
   and bind its unique token to the D12 completion job. Only actual consumer GPU
   completion calls `complete_frame` and releases DD ownership.
5. Windows `main.cpp:921` is the existing single-source bypass; its D12 submission
   path can take the leased DD texture instead of WGC only for the matching route
   ticket. Keep the regular WGC producer and last snapshot until a completed new
   route frame activates `FullscreenDmaTransition`. Preserve presentation/input
   coordinates, and do not double-render owned popups baked into DD output.
6. Fullscreen exit, DD access loss/unsupported frame, topology mismatch, or
   desktop isolation loss calls `retire()`, requests WGC fallback, drains jobs,
   then `take_restore()`. The Win32 adapter rechecks window incarnation before
   restoring only that HWND and acknowledges actual readback via `restored()`.
   Never apply saved geometry to a reused HWND.

CPU test built with `c++ -std=c++20 -Wall -Wextra -Werror` and executed:
`platform/reverse-common/fullscreen_output_lease_test.cpp`. Covers busy output,
unsupported DD, correct binding, in-flight retirement, stale/duplicate completion,
failed restoration, target mismatch, HWND reuse and source-isolation loss.
No display/window/input/focus operation or hardware DD acceptance was performed.

## Opt-in Windows producer integration candidate

`fullscreen_window_capture.hpp` and `main.cpp` now provide a compile-checked
producer candidate. Both `VIEWFLOW_FULLSCREEN_DMA=1` and the paired IVSHMEM/D12
path are required. `VIEWFLOW_FULLSCREEN_OUTPUT` explicitly selects an already
reserved GDI device name; runtime resolves its complete DisplayConfig identity,
checks non-primary status and exact existing physical mode, then establishes DD
capability before moving only the requested HWND without activation. No mode or
primary-display setting is changed. Missing/unusable output selects WGC backing
resize at the existing presentation origin.

Control 17 uses `(a=0|2,b=1,c=width,d=height)` and the ordered sequence as request
generation. The input thread queues control/geometry; the render thread restores
before applying later ordinary geometry. The same Source/window ID and existing
SHM ordering are retained, so there is no independent receiver route transition
requiring a new frame wire epoch.

DD snapshots use `CopyResource` into an owned D11 texture and an EVENT query;
the complete DD frame remains leased until this copy completes. The existing
Transport enqueue then supplies its D11 shared snapshot → D12 DMA path. WGC
callbacks cannot replace a bound DD source. Exit/failure drains the DD copy,
restores the owned window, restarts WGC and excludes frames older than the
restoration timestamp. The last completed snapshot stays available meanwhile.
Metadata keeps presentation coordinates; absolute pointer coordinates receive
the lease delta while ordinary relative input uses actual window bounds.

Any visible owned popup or another intersecting top-level surface above the
source invalidates DD and returns to WGC. Covered windows below do not block DD.
Only owned popups recorded before binding have proven restoration positions;
those positions, identity properties and readback govern restoration. Newly born
popups without a proven coordinate-domain mapping are not moved by guessing
from intersection with the reserved output.
Failed restoration retains the source/reservation for a subsequent render-loop
retry. Shutdown makes a final restoration attempt and reports failure; it cannot
promise restoration when the application refuses its original bounds.

Windows MSVC Release builds of `viewflow_windows_reverse` and
`viewflow_d12_desktop_copy_probe` passed after integration. No candidate process
was started, no user window was moved, and no display setting changed. This is
not live DD/fullscreen acceptance. Main-loop and coordinator behavior still need
an explicitly owned fixture transition test and user-operated fullscreen tests;
keep the experimental environment opt-in disabled until that evidence exists.


Review corrections: DD images must have LastPresentTime newer than the completed
bind/readback QPC boundary; older and pointer-only acquisitions retain the last
snapshot. WGC is stopped outside the Source lock after binding and restarted on
restoration. Removed sources with failed restoration remain in a retiring list
and retain the output owner until restored or the original HWND disappears.
DD snapshots use two reusable D11 textures with prebuilt SRVs and EVENT queries;
no per-frame texture/query/SRV allocation remains after slot initialization.
Reuse relies on the existing Transport immediately copying on the same D11
context into its own shared snapshot; direct D12 adoption requires a real lease.
Drain flushes once and polls DONOTFLUSH with Sleep(1), without a frame-time cutoff.

Fullscreen DD means final Windows desktop composition, including its background,
not preservation of WGC window alpha. Explicit layered/transparent/region windows
still select WGC. Actual DD snapshots carry windows_desktop_output_flag=8192;
the Linux copy/display path can force opaque alpha in its existing shader pass,
with a full input/opaque region and no added fusion shadow. The old DD snapshot
retains this flag during recovery until a successful WGC frame replaces it.
No unobservable strict opaque-window proof or window-style mutation is required.

EVENT query errors are not treated as GPU completion. If the device remains
alive, a replacement EVENT is enqueued after the copy on the same immediate
context and flushed. Failed recovery retains the full DD frame lease; normal
restore returns pending for a later render-loop retry. Only confirmed completion
or device removal releases it. Teardown waits with DONOTFLUSH and Sleep(1).
