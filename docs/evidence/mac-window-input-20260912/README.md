# Mac proxy input and transient capture, 2026-09-12

The user reported that Linux windows on Mac continued repainting but could
barely focus, type, or drag. In the reverse direction, IME candidates were
missing and opening Share sometimes produced a low-resolution parent artifact.

The live presenter sample before the change shows 173 of 421 main-thread
samples waiting in `CAMetalLayer nextDrawable`. Receive statistics also showed
presentation means around 298–318 ms during affected intervals. GPU completion
does not imply that WindowServer has returned a drawable to the layer.

`window_presenter.mm` now acquires drawables and encodes Core Image work on a
serial render queue. Window/view mutation remains on the main thread, with
bounded outstanding work and generation checks when a proxy disappears.
Real mouse-down events explicitly select the key window and first responder.
The existing Command-drag path is retained.

`window_source.mm` now captures native windows without folding child windows
into the parent surface; separately discovered windows keep their own body
geometry. Input-method providers identified by their bundle ID or Input Methods
installation directory can join the foreground application's selected stream.
Attached transient focus resolves to the parent application. This fixes a
source-level discovery omission; candidate and Share visual acceptance is pending.
The Share artifact had disappeared before it could be inspected live, so the
child-capture explanation remains a hypothesis, not a confirmed reproduction.

Validation and deployment:

- macOS arm64 clang build with ARC, C++20, `-Wall -Wextra -Werror` passed.
- Presenter and H264/HEVC, NV12/BGRA, Metal alpha/orientation self-tests passed.
- Signed helper and enclosing app passed deep strict code-signature verification.
- Installed helper and running source copy SHA-256:
  `d29433b0ae2247d9bc15af8f50f27278b4cacfafffe54ce66164a3b586032f34`.
- Both directions reconnected. Two live presenter samples after deployment
  showed main threads waiting for events rather than drawable acquisition.
- Initial receive means were 0.340–0.426 ms main handoff and 1.653–2.119 ms
  presentation. Later transient presentation spikes still occurred; this is
  not evidence that every performance target or input symptom is resolved.
- Previous app is retained on Mac under
  `~/viewflow-window-input-20260912/previous.app`.

No mouse/keyboard input was injected and no focus was changed for testing.
Click, typing, title/Command drag, IME selection, and Share reproduction remain
user-operated acceptance checks.

## Follow-up: clicks reached Linux but were suppressed

The user reported both a Mac-local mouse and Linux-forwarded mouse still failed.
Diagnostic logging in the Linux window input helper recorded the user's down/up
pairs arriving. A read-only capture-state query showed phase 3 (REMOTE_CAPTURED).
The plugin's global button/axis/key listeners unconditionally cancelled input in
that phase, and its keyboard suppression loop disabled virtual keyboards too.
The window helper's cursor dispatch was also subject to capture's anchor warp.

The input plugin now observes device origin before the compositor callback and
suppresses physical forwarded input only. Virtual input remains available to
the Linux window. IME virtual keyboards retain their existing explicit route.
The helper uses `with_forwarded_motion` for synchronous cursor positioning;
this skips the physical handoff/anchor logic for that operation and restores the
previous scope after success or Lua failure. The API does not change pairing or
window identity checks. `returned_buttons` counts virtual transitions admitted
while physical desktop capture is active.

The plugin and Linux helper were rebuilt; all 10 plugin CTest tests passed.
The plugin was reloaded successfully, the new API was read back, the metadata
connection recovered, all relevant services were active, and configerrors was
empty. No synthetic input was used. Final click/typing acceptance is pending.

The user then confirmed a stronger reproducer: the Mac-local mouse works while
the Linux pointer stays on Linux, and fails after the Linux pointer crosses to
Mac. `returned_buttons=13` showed the first suppression correction was active,
but did not fix end-to-end delivery. Position/focus IPC and Wayland button
submission were still separate compositor turns, with capture anchor restoration
able to run between them or inside button-triggered refocus.

The helper now submits focus, position, and `forwarded_button` in one guarded
Lua IPC operation. The plugin keeps forwarded-motion scope through normal
InputManager button handling and emits the pointer frame synchronously. Release
uses the same button path. It does not inject an extra click for validation.
Build, 10 CTests, reload, API read-back and connection checks passed again;
the exact user-operated captured-pointer reproducer remains pending.

The next user test activated the window but still could not operate it. Inspection
of the loaded companion `hypr-edgehover` source found an independent cancellation
in both `handleMouseMove` and `handleMouseButton`: they call the exported
`viewflow_input_capture_active_v1` and cancel when true. That query still returned
true inside Viewflow's synchronous forwarded-motion scope, defeating the earlier
internal bypass. The exported query now excludes that scope as well. Physical
capture is unchanged outside the synchronous returned operation. This follow-up
was rebuilt and reloaded; user acceptance remains pending.

## Physical cursor return and intermittent backdrop stalls

The user reported repeated recapture after returning the mouse to Linux. The
returned-input scope was leaving the global seat cursor at the remote window's
backing coordinates. It now restores the original physical cursor position at
the outermost scope exit, including a Lua error exit, without simulating another
motion or edge crossing. Keyboard focus requests use the same scope. This was
built and loaded, with live operation still user-operated.

Source-stage diagnostics then measured roughly 3–5 ms encoding, 8–12 ms record
packing, and 386–796 ms waiting on the output pipe during stalls. A simultaneous
Mac sample caught the remaining main-thread hotspot: `update_backdrop` called
`NSBitmapImageRep.bitmapData` twice for every pixel. Millions of Objective-C
backing-store/property/autorelease operations ran whenever alpha changed; static
alpha skipped this via the existing cache. The pixel pointer is now obtained
once before filling the mask.

The expanded no-window/no-input presenter self-test changes a 2560×1440 mask
four times and checks its pixel values; measured mean was 0.908 ms. The deployed
signed helper is SHA-256
`beeeb4d7b4d7cdf577629a1a46e37f40eafaa00f692ff4beb4e060bb602e4e45`.
The app signature passed deep strict verification, only window receiver/source
streams were restarted, and desktop HID stayed running. Initial real receive
presentation means were 0.093–0.117 ms. These short samples are not final proof
against every intermittent stall.

The user also correctly questioned blur parity. Windows' custom background
capture/cache and Hyprland prepare/down/up/finish shader pipeline in
`platform/windows-composition-preview` have NOT been ported to Mac. Mac still
uses an AppKit behind-window material and alpha coverage, which is not the same
algorithm or a validated equivalent visual result. The mask performance fix
does not complete that missing implementation.
