# Window-scoped wheel integration

Status: wire contract, source daemon dispatch and Hyprland native command/session
implementation exist. Ordered preview wheel forwarding and native-record decoding
now exist and are connected to explicit receiver atlas policy. Windows native
event capture is implemented and build-tested, and trial 56 proves eight unheld
fractional wheel events reached two source Qt windows. Full mixed-input,
held-wheel, negative-path and sustained acceptance remain pending.

`WindowPointerWheel` has its own reliable control tag (35), separate from
device-wide `InputEvent`, window motion, and window buttons. `position` reuses
the complete `WindowPointerMotion` contract: lease generation, target device and
window, geometry epoch, presented source frame, event sequence, original sender
deadline, client point and viewport. Parsing is not authorization. The existing
window/atlas selection, exact visual receipt, clock and native target checks
must also run before delivery.

The `delta` retains both fractional axes, in standard detents. Positive vertical
means up and positive horizontal means right, matching `PointerWheelEvent`.
Non-finite numbers, absent position/delta and zero on both axes are invalid.
Native conversion must reject values outside its representable range rather
than wrap, silently clamp, or convert a fractional event to a full detent.

ACK result 4 is `WheelSent`. It is not a motion/button receipt and may only be
emitted after native wheel delivery. Existing preview pending-motion/button
paths reject it without clearing the pending event or incrementing receipts.
Older protobuf decoders see none of the device/motion/button payloads for tag 35.
Unconfigured device connections and the coordinator reject wheel input explicitly.
Source window routes require an explicit local wheel grant; they do not fall
back to global seat input. The wire version remains 2.1 with a new optional payload; absence
of this route means unsupported, never implicit capability/permission.

Remaining implementation and verification:

1. Exercise Windows atlas pointer-wheel capture with real OS messages, verifying
   timestamps, exact event-time visual binding and client hit points.
2. Verify the new native child capability together with the rebuilt receiver in
   the owned Windows desktop session. Build proof is not runtime proof.
3. Exercise daemon source authorization and the Hyprland connection-local native
   wheel capability in a live source route. Dispatch and explicit local policy
   now exist, but have only socket/QUIC regression coverage so far.
4. Real source probes must verify vertical/horizontal signs, fractional deltas,
   ordering across motion/button input, unchanged-coordinate repetitions,
   outside-window rejection, and expiry/disconnect. No physical wheel success
   has yet been recorded for this new route.

Current regression coverage: all 34 protocol unit tests, 57 core tests,
15 preview-input tests, and 83 atlas-feature tests passed (two hardware-only
tests explicitly ignored). Strict Clippy passed for protocol/core/daemon with
the native GPU feature enabled. Protocol tests
exercise complete identity preservation, malformed values and legacy tag
isolation. Preview tests reject cross-kind wheel ACKs while preserving the
pending motion/button and accepting its subsequent exact ACK. These are source
tests, not native runtime evidence.

Native-source follow-up: explicit VFHY grant 58 and wheel command 57 preserve
generation, Linux monotonic deadline, exact point and signed 1/120-detent axes.
The old BEGIN/BEGIN_BUTTONS modes do not gain wheel permission. A renewal cannot
change capabilities. Vertical up is converted to Wayland's negative vertical
direction; horizontal right stays positive. Version 8+ receives value120, as
specified by the [Wayland protocol](https://wayland.freedesktop.org/docs/html/apa.html).
Legacy clients receive proportional axis distance without rounding a fraction
into a full discrete step or retaining it for a later target. Rust/C++ wire
tests cover layout, sign, range and result correlation. The plugin Release
build against installed Hyprland 0.56.2 and all five CTests passed in
`/tmp/viewflow-wheel-build.7U63ed`; SHA-256
`13686399c2746bdf4f2797a3657cc28e958aca5a4e18a8e9a481a924788ee835`.
All 18 non-live Hyprland Rust tests passed (one live-session test ignored), and
strict native-GPU daemon/Hyprland Clippy passed. The plugin was not loaded and
no compositor was restarted for these checks.

Daemon source follow-up: the local atlas source config has `pointer.wheel`, a
strict boolean defaulting to false. True selects the explicit buttons+wheel
native grant; old configurations stay buttons-only. Renewals and confirmed
END/BEGIN window switches preserve these capabilities. An incoming wheel never
promotes permission. The shared source dispatcher reuses the original event's
position/identity, conservative clock mapping and sequence admission before
constructing VFHY command 57. It only returns QUIC `WheelSent` after correlated
native outcome 5. Any rejected/uncertain scroll retires the source session,
preventing a non-idempotent replay. No unrelated protocol loop or global input
backend is used.

Fractional detents must convert to integer value120 without meaningful rounding:
only floating-point multiplication noise within four scaled machine epsilons
is tolerated. Nonrepresentable sub-tick deltas, overflow, NaN and zero are
rejected, not rounded into different scrolling. Source tests verify 1/120 and
signed fractions, exact surface-coordinate scaling, renewal mode, denied old
grants, and replay closure. Real mTLS QUIC plus a local SOCK_SEQPACKET native
witness verifies delayed ACK until outcome 5 and refusal to grant wheel from an
incoming request. These are 26 source-runtime tests, not compositor/application
wheel acceptance. The Windows native producer implementation is described below.

Ordered-preview follow-up: `with_buttons_and_wheel` is an explicit local opt-in;
the older constructor rejects wheel input. Motion/button/wheel share one bounded
FIFO and one exact pending receipt. Repeated same-coordinate wheel events retain
their sequence and original deadline. Missing authorization, expired visual or
clock context, ambiguous event kinds and queue overflow fail closed. A wheel
cannot be dropped as expired motion or retried as another event. `WheelSent`
alone completes a pending wheel and increments its separate native receipt count;
writer completion does not count as native delivery. A writer-queue test verifies
the distinct protobuf payload, original deadline and unchanged window identity.

Native-record decoding now accepts `kind=wheel` with canonical signed 16-bit
`wheel_vertical_120` and `wheel_horizontal_120` fields, converting each to detents
without losing 1/120-unit precision. Both-zero, malformed, out-of-range and
expired wheel records are rejected. Existing motion/button records are unchanged.
This parser does not confer source authority.

Verification: 19 preview tests and nine wheel-filtered tests passed. Strict
native-GPU daemon Clippy passed. The first atlas suite run had 83 passes, one
failure and two ignored hardware tests: the existing
`atlas_pool_disconnect_closes_pending_sources_without_release` test observed
`recv=-1` instead of zero. Its isolated rerun passed and the subsequent complete
atlas run passed 84 tests with two ignored. The intermittent failure's cause is
not established; no socket/runtime workaround was introduced. No new native
binary was staged and no compositor or desktop session was changed.

Receiver-policy follow-up: receiver `pointer.wheel` now defaults to false and is
strictly boolean. It is separate from the source's local `pointer.wheel` grant;
both sides must opt in. True configures ordered wheel forwarding for every local
window selection and launches the native child with `--atlas-wheel-v1` in
addition to the existing pointer/disposition flags. Readiness must exactly be
`atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1`.
Old pointer-only readiness is rejected, as is unexpected wheel readiness on a
pointer-only route. Missing capability retires the owned child, with no fallback.
The native executable now implements this flag; earlier binaries reject it.

Real loopback QUIC tests now forward fractional two-axis wheel events across two
atlas windows through exact committed-layout/selection/source-authorization
gates. They verify window/source-frame identity and increasing event sequence.
A negative case injects a wheel record into a locally disabled route and requires
closure before selection or input. Native pipe tests verify exact capability
matching, and owned shell-child tests verify the wheel-mode stdout worker and
process reaping. These witnesses are not Windows OS event capture or real
compositor/application wheel acceptance. After the local-opt-in negative test,
the complete atlas suite passed 88 tests with two hardware cases ignored;
strict native-GPU daemon Clippy passed.

Windows producer follow-up: `WM_POINTERWHEEL` and `WM_POINTERHWHEEL` are handled
only in the explicit atlas wheel mode. `GetPointerInfo` supplies the event QPC,
mouse type, exact target and screen position; `GET_WHEEL_DELTA_WPARAM` supplies
the signed 1/120-detent amount and must agree with `InputData`. Coalesced records,
button-change ambiguity and keyboard modifiers are rejected (keyboard forwarding
is not implemented). Wheel input outside the client rectangle, missing event-time
visual binding, resized binding or expired original budget retires input. This
matters because Windows may send wheel messages to the focused window even while
the cursor is outside it, as documented for
[WM_POINTERWHEEL](https://learn.microsoft.com/en-us/windows/win32/inputmsg/wm-pointerwheel).
The [POINTER_INFO timestamp](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-pointer_info)
is used directly; receipt time does not establish a new event deadline.

The pure native state test checks repeated unchanged-coordinate samples, old
event-time visual selection, original deadline, signed fractional ticks, scrolling
while pressed without changing button state, invalid positions/ranges, expiry and
retirement. Windows Release build and all 18 CTests passed. Staged native SHA-256:
`4EF7306734CC77A9277E53F0FC6C6D8E4A980A1F4451C96BDDA0DC095D0069B9`.
The temporary build used a process-local PowerShell execution-policy override;
no system policy or desktop session was changed. These tests do not prove Windows
OS wheel delivery, horizontal sign or source Qt application behavior.

The corresponding Windows Rust receiver Release build also passed, with 16
platform-conditional dead-code warnings. Staged receiver SHA-256:
`66A4EC578C1A70929886886C6F9B21839150D66A197BF6501DB8FE9781C896BB`.
No live wheel session was launched in this build step. The Linux source Release
binary and the loaded isolated compositor plugin still require updating before
end-to-end testing; passing tests do not imply those running components changed.

Live follow-up, trials 52–56: the Linux source Release binary was rebuilt
(SHA-256 `2e9a76c8e9e078bb4f26499240ae68902e3e47d5de099d0436909d9611d1ec36`).
Only the owned nested Hyprland PID 4039456 had its input plugin replaced with
the wheel build `13686399...`; plugin listing and empty config errors were checked.
The capture plugin, main desktop and persistent configuration were unchanged.
Both endpoint test configs explicitly enabled `pointer.wheel`.

- Trial 52: the helper stopped at its wheel target/focus guard before sending any
  wheel. The source completed 12 seconds / 438 frames; this is not a wheel test.
- Trial 53: after explicit owned foreground acquisition, the first vertical
  `+30` Windows wheel was sent while left was held. Native rejected it as
  `wheel-capability-or-record-rejected`; no source wheel was observed. The exact
  rejected field was not logged yet, so its cause remains unproven.
- A bounded rejection diagnostic was added (delta, InputData, history count,
  button change, key states, local capability). No admission check was removed.
  Release build / 18 CTests passed; native SHA-256 is now
  `2526F189B5A21A42439289F0A41F55F0AC1E08C79FE453CDD2FEC56900D946F2`.
- Trial 54 ended before wheel at a source native `Pressing` ACK timeout
  (24,652 us); it cannot identify the wheel rejection.
- Trial 55 sent no input because C# rejected an unreachable test branch. Its
  leftover event log is stale and excluded. The helper now clears that log
  before compilation and uses a wheel-only phase; held ordering remains open.
- Trial 56: two fresh Qt probes each received four real `QWheelEvent`s from
  guarded Windows `SendInput`: vertical `+30,-30`, horizontal `+60,-60` at one
  unchanged client point. Qt records were exactly `(angle_x,angle_y)`:
  `(0,30),(0,-30),(-60,0),(60,0)`, all at `(93,98)`, buttons zero, inverted false.
  Independent `jq -e` assertions passed for both files. Qt documents positive
  horizontal wheel rotation as leftward in
  [QWheelEvent::inverted](https://doc.qt.io/qt-6/qwheelevent.html#inverted), so
  negative Qt x for the protocol's positive-right value is consistent with that
  convention, not evidence to reverse the source mapping.

Trial 56 completed the planned 12-second run with 350 native frames, eight
observed application wheel events and no capture discards, but three motion
timing discards. It proves bounded unheld fractional wheel delivery and order,
not full mixed-input reliability, held-wheel correctness, physical hardware
capture, outside-window rejection, reconnect or sustained performance. All
52–56 scheduled tasks were verified Ready with no staged processes and removed.
All owned probe processes ended; the isolated compositor remains available with
the new input plugin and no clients. Evidence logs are under
`/tmp/viewflow-input-20260906.J4vBWv/`, with trial suffixes fiftysecond through
fiftysixth. No failed trial is counted as a pass.

Held-wheel correction, trials 57–59: trial 57 reproduced the rejection with
`delta120=30 input_data=30 history_count=1 button_change=0 key_states=1 capability=1`.
The only failing field was the requirement for zero key state: a PT_MOUSE wheel
while left was held includes the Win32 left-button bit. Native input now requires
the complete wheel key-state field to equal the exact MK_* encoding of its
previously admitted button transitions. It does not ignore arbitrary bits or
create a pressed state. Shift/Ctrl, unknown bits and missing/extra mouse-button
bits remain rejected. Windows SDK constants are checked with `static_assert`;
all 32 mouse-button combinations, mismatch, modifiers, unknown bits and retired
state are covered by the native state test. The
[Microsoft state constants](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-get_keystate_wparam)
provide the bit encoding; inclusion in this PT_MOUSE wheel record is live evidence,
not an assumption that every pointer type reports identical state.

Release build and all 18 CTests passed. New native SHA-256:
`FE1D6BE9A23EFEF35FA4EBC400A9C5DC65DE3EFE2C89C4F85232EB26E83404EF`.
Trial 58 then delivered four wheel events with `qt_buttons=1` to the first source
window, but stopped at `atlas input renewal lacks a fresh unchanged capture`
after 157 native frames. The source probe recorded a release to buttons zero on
retirement. This was partial interaction evidence, not a full pass; the renewal
failure remains a reliability issue to investigate.

Trial 59 completed 12 seconds with 389 native visual submissions, no timing or
capture input discards, and 53 authorized inputs including lifecycle traffic.
Each of the two fresh Qt probes recorded exactly 20 motions, one press, four
wheel events while held, and one release. Independent `jq -e` checks verified
every motion coordinate and held-state interval, plus the four wheel tuples
`(0,30),(0,-30),(-60,0),(60,0)` at `(93,98)` with buttons=1, followed by a balanced
release. No helper exception occurred. This proves one bounded two-window
move/drag/wheel run on the current build; it does not erase trial 58 or establish
sustained, hardware-device, outside-window or reconnect acceptance. Trials 57–59
used the owned nested session only; scheduled tasks were verified idle and
removed after their child processes exited.

Renewal-policy follow-up: a deterministic source-policy regression reproduced
the old `atlas input renewal lacks a fresh unchanged capture` error by polling
the same still-fresh committed frame after half the existing lease had elapsed.
The lease was still valid and the native surface/PID/geometry unchanged. This
conflicted with the policy's documented ability to wait for new evidence within
the unextended lease. The previous combined error also covered true rebinding
and regression, so this reproduction alone does not prove which subcondition
occurred in live trial 58.

The same-frame branch now returns no new authorization without changing the
current generation, presented geometry or expiry. A strictly newer capture can
still renew after the normal checks. Native surface/PID/address changes, epoch
changes and frame regression still fail; reaching the original expiry fails
even if a newer capture arrives then. Repeated polling is not renewed authority.
The regression failed before the fix and passed afterward. Added cases cover
repeated same-frame polls through the last valid tick, original-expiry closure,
newer-frame recovery before expiry and five binding/regression failures. All 26
source-runtime tests, 88 atlas tests (two hardware cases ignored), and strict
native-GPU daemon Clippy passed. This code change still needs live validation;
trial 59 used the previous source binary.

Outside-wheel investigation, trials 60–63, using rebuilt Linux source SHA-256
`f3185772735b3daa0067de33384de47e52a850a062aca94c7f43f5f141b55731` and unchanged
Windows receiver/native binaries from trial 59:

- Trial 60 sent no input due to a C# helper variable-scope compile error; fixed
  and followed by a compile-only preflight that performs no desktop input.
- Trial 61 used a built-in STATIC witness and stopped at the outside-input
  guard before sending. Its exact failing guard component was not recorded.
- Trial 62 used a dedicated owned blank window class with no-activate/topmost
  flags. Exact foreground, cursor and witness hit guards passed; one `+120`
  outside wheel was sent. Source probes recorded no wheel, but the proxy did not
  retire. Without processing the witness queue, this did not identify routing.
- Trial 63 added a bounded message pump restricted to that owned witness HWND.
  The foreground HWND equaled the proxy, hit HWND equaled the helper-owned
  witness, and the point `(1011,236)` was outside the proxy client rectangle
  `[176,176,971,778)`. The witness received `WM_MOUSEWHEEL` (522), delta `+120`.
  Both Qt source probes recorded zero wheel events (checked with `jq -e`).
  No helper exception or native input-retirement message occurred. The proxy
  remained available until the planned source shutdown after 12 seconds / 348
  native visual submissions.

This proves no source input leakage for the current Windows outside-wheel
routing: the OS delivered the event to the local window under the cursor despite
the proxy retaining foreground focus. It does **not** exercise the proxy's
outside-coordinate rejection/retirement branch or prove behavior under other
OS routing settings. Those checks retain their native unit coverage, not a new
live-pass claim. No OS wheel-routing setting was changed to force the branch.
The blank witness was destroyed and cursor restoration was conditional on it
remaining at the test point. All 60–63 scheduled tasks were checked idle with no
staged processes and removed. These idle/outside runs do not replace a mixed
interaction renewal stress test of the new Linux source policy.
