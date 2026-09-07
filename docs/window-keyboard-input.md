# Window-scoped physical keyboard input

Status: protocol/source admission, an explicitly authorized Linux native
direct-application path, source-side QUIC dispatch and receiver mixed FIFO are
implemented. Product configuration is connected with keyboard **disabled by default**;
Windows native scan-code capture is implemented and has a bounded two-window
Windows `SendInput` to Linux Qt QUIC delivery trial. This is not physical hardware
keyboard, all-key/layout or sustained latency acceptance. A later
[source Qt/Fcitx IME follow-up](window-ime-integration.md) committed Chinese text
in both windows after a pointer-lifetime correction; full source IME acceptance
and sustained input timing remain open.

`WindowKeyboardEvent` uses control-envelope tag 36, separate from device-wide
`InputEvent` and every pointer payload. It carries the full target device/window,
lease generation, committed geometry/frame, event sequence, original sender
deadline and USB HID usage/state/repeat. It deliberately has no pointer position
or composed text. The eventual native receiver must sample the focused proxy's
actual committed visual and original event time. The source application/input
method performs composition, as required by the architecture.

Parsing validates nonzero binding fields, 128-bit IDs, 16-bit HID components and
repeat-on-press semantics. It does not authorize input or claim every usage has a
native mapping. Old device/pointer/wheel decoders do not reinterpret tag 36.
The coordinator and daemon dispatch reject keyboard events without an explicitly
authorized source keyboard session. The atlas sole reader can forward keyboard
authorization/ACK to an installed input dispatcher. The selected-window atlas
adapter supports explicit keyboard opt-in and the native Windows producer is
connected under matching local/native capabilities. No device-input fallback was added.

`WindowKeyboardGrant` is a separate source-owned state machine, not an upgrade
of a pointer lease. The caller must first obtain local keyboard permission and
bind the exact native source window. Its current contract is:

- Match authenticated owner, device, window, generation and an exact retained
  source-verified presentation receipt (bounded to 32).
- Spend a validly bound sequence even when timing or key-state validation fails.
  A new clock estimate cannot make a rejected sequence replayable.
- Use the earlier of lease expiry and uncertainty-subtracted event deadline.
  Advancing frame history does not renew a lease or change window/geometry.
- Permit one pending native operation. Press adds a possibly-held usage before
  dispatch; release removes it only after exact, timely native confirmation.
- Accept repeat only for an already-held key; reject duplicate ordinary presses
  and unmatched releases. Bound cleanup bookkeeping to 256 distinct usages.
- Preserve possibly-held usages on uncertainty/revocation. The runtime must
  release them on the original native binding and fence reuse if cleanup fails.
  Dropping this Rust object does not perform native release.

The state machine cannot verify native focus, surface lifetime, injection,
clock mapping or cleanup itself. Its caller must enforce those boundaries.
QUIC has separate keyboard authorization/ACK wire types. The source shared reader
now dispatches events and publishes native-confirmed acknowledgements under an
explicit local keyboard session. Fixed-window receiver dispatch is connected;
destination native capture has the bounded evidence described below. Local native IPC
has a separate keyboard capability and a typed key-send result, described below.
Held-key switching/renewal, reconnect cleanup, physical layout/modifiers/repeat,
and source IME preedit/candidate/commit behavior remain required integration work.

## Source-native keyboard state

### IME integration boundary audit and application witness

The installed Hyprland headers identify commit
`efb50993780079460b0cbed1363e2166a2de1d9f`. Its
[keyboard dispatcher](https://raw.githubusercontent.com/hyprwm/Hyprland/efb50993780079460b0cbed1363e2166a2de1d9f/src/managers/input/InputManager.cpp)
has the actual keyboard object, but emits the public key event without it before
normal routing. The existing local-key revocation listener therefore cannot
distinguish trusted IME reinjection from local takeover. Its
[input-method implementation](https://raw.githubusercontent.com/hyprwm/Hyprland/efb50993780079460b0cbed1363e2166a2de1d9f/src/protocols/InputMethodV2.cpp)
also emits commit notification without retaining the request serial. Simply
allowing `hasGrab()` or exempting an entire client is insufficient. This was the
original direct-mode audit; the exact source IME route described below now
addresses keyboard dispatch ownership, while asynchronous composition receipts
remain unavailable.
Local Hyprland checkout HEADs differ from the installed build; these conclusions
were checked against the exact installed revision, not those working trees.

The owned Linux Qt probe now has a separate `--ime` mode with a real line editor.
It records preedit/commit/replacement/attribute geometry, committed editor text
and focus changes without composing text itself. Its offscreen test covers
Chinese commit, replacement and cancellation and asserts the serialized witness
records. This makes application-side IME results observable for subsequent
integration; it does **not** close the source IME gate or prove candidate popups.
See `platform/linux-pointer-probe/README.md`. Event interpretation follows
[Qt's input-method event contract](https://doc.qt.io/qt-6/qinputmethodevent.html).

### Source session runtime (2026-09-06)

`WindowInputSession::begin_direct_keyboard` now explicitly selects native
capability 59 and creates a separate `WindowKeyboardGrant`. Existing constructors
remain keyboard-disabled. The source product configuration now selects this API
only under the explicit `direct_keyboard` policy described below.

Keys share the same single-pending native FIFO as pointer operations. Admission
uses the authenticated session owner, retained presentation and conservative
clock deadline. Only exact, timely native `KeySent` confirmation clears the
pending key; wrong/late replies and rejected requests revoke the route and close
the native connection for cleanup. Possibly-held usages remain recorded on
uncertainty. No network acknowledgement is emitted by this low-level API.

Same-binding renewal preserves held usages and key replay state, keeps capability
59, and hides keyboard authorization until native BEGIN confirmation. Window
switching revokes the old grant and constructs the new one only after confirmed
native END. Source-verified presentation advances update both grants.

Verification: 29 source input runtime tests pass over real local seqpacket
sockets with a simulated native peer, including held-key renewal/release,
wrong/late confirmation, replay, default-denied keyboard and shared-FIFO rejection.
The existing switch matrix now covers keyboard capability preservation and
rejected/expired switch cleanup. These are not compositor or cross-device tests;
the earlier native Qt proof remains a separate boundary.

### Source shared QUIC dispatcher

The source shared writer publishes a distinct keyboard authorization only after
native BEGIN/renewal confirmation and connection-owned clock evidence. Pointer
authorization is never promoted. It suppresses announcements while a source
decision is pending and resets publication state across window switches.

The sole shared reader dispatches keyboard events through `deliver_key`, applying
pending source authorization and presentation updates before admission. Success
requires the exact native FIFO completion under the original event deadline;
only then does the bounded shared writer send a full-event keyboard `KeySent`
ACK. Errors close the route instead of retrying uncertain keys. Unconfigured
connections and receiver-side unsupported keyboard controls remain rejected.

Verification: all 32 source input runtime tests pass. Three new real mTLS QUIC
tests use a simulated native seqpacket peer: balanced down/up produces exact
keyboard ACKs only after native replies; duplicate network sequences retire the
route; pointer-only authority and a wrong native ACK produce no success and close
the native connection. Strict native-GPU library Clippy passes. These tests prove
the dispatcher boundary, not Windows event sampling or actual compositor input.

### Receiver mixed input FIFO

`WindowPreviewInput::with_direct_keyboard` explicitly enables physical usages on
the existing bounded motion/button/wheel stream. Defaults and all previous
constructors remain keyboard-disabled. The queue rejects ambiguous event kinds,
zero HID identifiers and repeat-on-release. A key retains the original sample's
committed window/frame/epoch, sequence and deadline; its pointer coordinates are
ignored and never serialized into the keyboard payload.

The receiver requires a separate exact keyboard authorization in addition to the
matching pointer presentation. Keyboard receipt history is bounded to 32 and
cleared on target changes/renewal. The effective send deadline is the minimum of
the original sample deadline and both uncertainty-adjusted source leases. Keys
share the existing one-pending FIFO, cancellation gate and bounded writer.
Only a full matching timely `KeySent` keyboard ACK clears a pending key; pointer
ACKs cannot do so. Keyboard confirmations do not inflate pointer receipt counts.

Both the standalone preview dispatcher and the atlas-forwarded fixed-window
dispatcher handle these dedicated controls. The atlas media reader forwards
them only to an attached bounded control queue; it does not authorize keys.

Verification: 22 receiver unit tests pass, including mixed-key ordering,
separate/local authorization, identity/generation mismatches, late ACK and
switch invalidation. Two additional real mTLS integration tests connect the
receiver producer to the source dispatcher and a simulated native endpoint,
one standalone and one sharing the atlas reader/writer. Both complete
down/motion/up/motion with matching native key payloads and prove queued motion
cannot overtake an unconfirmed key. These do not exercise Windows native events,
actual compositor keyboard injection. Selected-atlas coverage was added afterward,
as described below.

### Selected-atlas keyboard adapter

The native stdout parser now accepts a distinct `atlas-keyboard-v1` record with
19 ordered fields: full atlas/window/source-frame identity, duplicate atlas frame
identity, original QPC deadline/frequency and physical usage/state/repeat. There
are no pointer coordinates. It rejects truncation, extra fields, noncanonical
integers, malformed usages/repeats and identity mismatch. QPC conversion retains
the original deadline; an expired key retires input rather than becoming a
droppable motion. The continuously running stdout dispatcher delivers these
records to the same bounded queue without requiring a pending video read.

`AtlasPreviewInput::with_direct_keyboard` is an explicit local opt-in. It checks
the committed atlas layout before selection and waits for both matching pointer
presentation and separate keyboard authorization before releasing a queued key.
Old-window grants cannot select a different window. ACKs go to the mixed FIFO;
closed/expired queues or unsupported keyboard events retire the route.

Verification: two-window mTLS adapter tests retain window/source-frame identity
and increasing event sequences. They deliberately delay keyboard authorization
after pointer readiness and verify no key is forwarded during that gap. A
default-disabled test rejects a key before selection. Parser tests cover deadline,
clock and malformed-record boundaries. The atlas-filtered suite has 92 passing
tests and two pre-existing hardware ignores. The source in these adapter tests
supplies fixture grants/ACKs; Windows native event generation remains untested.

### Product configuration and native capability handshake

Source `AtlasSourcePointerConfig` and receiver `AtlasReceiverPointerConfig` now
have `direct_keyboard: bool`, defaulting to false when omitted. Both require
`wheel: true` when keyboard is enabled, as native capability 59 includes buttons
and wheel. Existing pairing/disposition checks remain mandatory. The source
supervisor selects `begin_direct_keyboard` only under this local decision; the
receiver selects the keyboard-aware atlas adapter only under its own decision.

Keyboard-enabled child launch requires all four flags: `--atlas-disposition-v1`,
`--atlas-pointer-v1`, `--atlas-wheel-v1`, `--atlas-keyboard-v1`. Its readiness must
be exactly `atlas-native-ready disposition=v1 input_enabled=true pointer=v1
wheel=v1 keyboard=v1` (one line). Missing/old/unknown capabilities poison and retire
the pipe; there is no input-disabled or pointer-only fallback. The Windows native
executable now implements this mode. Only owned diagnostic configurations were
enabled for the live trial; no user's persistent configuration was changed.

Verification: source/receiver configuration tests cover omitted defaults and
the wheel prerequisite. Readiness tests reject legacy/incomplete/version-mismatched
declarations. A supervised test child with exact keyboard readiness starts with
its stdout worker and is killed/reaped on shutdown. The atlas-filtered suite has
94 passing tests and two pre-existing hardware ignores. These are Rust config and
capability tests, not Windows native keyboard acceptance.

### Windows native producer and cross-device trial 64

The keyboard-capable proxy handles `WM_KEYDOWN/UP` and `WM_SYSKEYDOWN/UP` using
Scan 1 make codes plus the E0 flag, not layout-translated VK/text. Native modifier
state must match the locally tracked usages. Duplicate downs, unmatched releases,
coalesced repeats without individual timestamps, E1 Pause and unknown scans are
rejected. Left/right modifiers, letters, digits, function/navigation/keypad and
listed international keys have explicit mappings; this is not all-HID support.
Character/dead-character messages are consumed without forwarding. The existing
thread-scoped destination IME disable remains in effect.

The target is the proxy's currently committed visual when its UI thread samples
the key; unlike pointer hit testing, key samples have no coordinates. Foreground,
focus, visibility and exact native binding must remain valid. Keyboard-enabled
windows permit ordinary click activation but still show with `SW_SHOWNOACTIVATE`.
Held keys prevent an internal focus transfer; changing the binding/geometry while
held retires the input route. Disconnect then relies on the source's existing
native cleanup, not invented receiver-side release confirmations.

Message creation time uses the wrapping `GetMessageTime`/`GetTickCount` domain.
The initial producer samples QPC before the current tick, charges the entire queued age
plus a conservative **20 ms tick-quantization allowance**, and rejects platforms
whose reported nominal system-time increment exceeds 20 ms. It checks the derived
absolute QPC deadline again before emitting. This supported-clock assumption is
not a measured high-resolution hardware timestamp, and the remaining ~13 ms on
fresh messages needs sustained-load validation. See Microsoft's
[keyboard scan-code/message reference](https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input)
and [message clock explanation](https://devblogs.microsoft.com/oldnewthing/20140122-00/?p=2013).
The later observed-clock bound below supplements this algorithm; the unchanged
coarse calculation remains its fallback.

### Observed original-time bounds and asynchronous atlas decode

`KeyboardClockBounds` retains 32 distinct tick observations from the ordinary UI
loop, each with QPC sampled before/after `GetTickCount`. It keeps the latest
sample for a given tick. For a keyboard message, only a sample with a **strictly
older** wrapping tick can establish a lower bound on its creation time. A
same-tick or later sample cannot prove this and is never used. Because the
message and sampled tick use the same clock, an older tick observation predates
the message; its pre-read QPC minus one tick is a conservative original-time
lower bound. Adding the unchanged 33,333,334 ns budget to this lower bound gives
an absolute deadline no later than the real event deadline.

The producer chooses the tighter valid bound from this observation and the old
coarse calculation. It does not replace the event time with dequeue time, start
a fresh budget, reduce the fallback's 20 ms allowance, or revise a serialized
deadline later. Counter-domain changes, regressions, missing observations,
future/ambiguous message ticks and expired bounds are rejected by the observed
path. Sampling uses the existing UI loop and creates no additional polling timer.
Tests cover wrap, same-tick exclusion, missing/stale evidence, counter anomalies,
ring eviction, and 24,750 event/queue/sampling-phase combinations, checking that
every admitted bound stays at or before the real original deadline.

The atlas previously waited synchronously on an MTA decoder future. It now hands
off one owned color/alpha input, waits on a completion event together with UI
messages, and returns completed frames to the same STA for copy/visual mutation.
It does not dispatch messages from inside a mutation or borrow parser spans
across an asynchronous call. While that task is pending, pipe consumption stops;
only records already parsed from the current bounded pipe chunk are retained.
Frame identity, immutable layout, warmup and original presentation deadlines
remain checked at their existing boundaries. Startup and EOF flushing retain
their existing synchronous behavior.

`SignalledTask` tests completion, exception notification, early nonblocking take
rejection, abandoned-result ownership, and delivery of an own-thread message
while the worker is deliberately held. All 21 Windows Release CTests passed;
the clock-bound tests also compiled and passed independently with GCC on Linux.
The resulting native executable SHA-256 is
`1595B4F1A035EAF7E782DAA2A2B73CAE6583C585D53AECC7181F3CE45CB55650`.
These tests do not prove physical keyboard or sustained two-refresh latency.

For the earlier trial 64, Windows Release compiled and all 19 CTest targets
passed, including the portable scan/held-state/deadline tests. That native executable SHA-256:
`18AB12C77688988BB50023C360AC9CBA2008820183AE0BC8B29E1A946C4E2DCF`.
Windows Rust receiver SHA-256:
`61CA915F6EA17B0AA596A9095DE5B258EF17ECB45F25570C4891B674826E0A08`.
Linux native-GPU source SHA-256:
`f061c18b35a017c3a5605b45b777d80a0e7cc470edf9fd262aa1827f05cf8e7e`.

Trial 64 used the existing isolated Linux compositor, two empty Qt keyboard
probes, paired mTLS fixture identities and the real Windows atlas receiver.
An interactive-session helper checked exact receiver/native executable paths,
parent PID, class/title/visibility/foreground, then used scan-code `SendInput`
for Shift down, A down, A up, Shift up in each proxy. Source A and source B each
recorded exactly four spontaneous key events, uppercase `A` and final modifier
mask zero; per-file tuple assertions passed. Evidence:
[source A](evidence/window-keyboard-quic-20260906-A.jsonl),
[source B](evidence/window-keyboard-quic-20260906-B.jsonl).

This exercises actual Windows window-message handling, typed native output,
selected-atlas input, QUIC, source authorization/native keyboard dispatch and Qt
application delivery. It uses OS-synthesized scan-code input, **not a physical
USB keyboard**. It does not prove source IME composition, repeats/all layouts,
failure cleanup across this full path, physical scanout or sustained 6K60 latency.
The source stopped cleanly at the harness's planned limit; only owned probes and
the owned Windows scheduled test task were cleaned up. Main desktop configuration
and compositor were not modified or reloaded.

The Hyprland plugin now builds `WindowKeyboardState`, an isolated XKB state
created from a source keyboard keymap plus an explicit source lock/layout
snapshot. It rejects imported depressed/latched local modifiers, unknown modifier
bits and nonexistent layout groups. Remote key state never modifies the source
`IKeyboard`, its LEDs or compositor input configuration. Keymap replacement can
be detected by exact retained-keymap identity before native dispatch.

The USB usage mapper covers normal alphanumeric/punctuation keys, F1–F24,
navigation/keypad, left/right modifiers, selected international keys and selected
consumer keys. These are physical Linux evdev mappings, not destination keysyms
or text. Unsupported and rollover/error usages are rejected; a mapped key also
must exist in the selected source keymap. The mapping is based on the physical
usage/code associations documented by Linux's
[HID input implementation](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-input.c),
expressed with the installed `linux/input-event-codes.h` constants.

Distinct USB usages may map to one evdev key (for example the two backslash
usages). State tracks the original usage by native code and rejects overlapping
aliases, including alias releases. This avoids prematurely releasing another
usage's key. A repeat does not update XKB twice; it produces a distinct repeated
transition. Its eventual native sender must negotiate support for that state,
not turn it into an ordinary duplicate down.

This helper does not yet send to a Wayland resource. Exact installed Hyprland
commit `efb50993780079460b0cbed1363e2166a2de1d9f` source inspection identifies an
important integration boundary: ordinary keys can go through an input-method
grab, while direct `wl_keyboard` resource sends bypass that route. See
[source keyboard dispatch](https://github.com/hyprwm/Hyprland/blob/efb50993780079460b0cbed1363e2166a2de1d9f/src/managers/input/InputManager.cpp)
and [input-method grab delivery](https://github.com/hyprwm/Hyprland/blob/efb50993780079460b0cbed1363e2166a2de1d9f/src/protocols/InputMethodV2.cpp).
Native wiring must therefore pin the actual application/IME recipients, send
private modifier state, and clean the original recipients on focus loss or
disconnect. Merely calling `sendKey` on the global seat is not that wiring.

`viewflow-window-keyboard-state-test` uses real libxkbcommon states to verify
physical mapping, unknown/error rejection, aliases, duplicate/repeat/up handling,
both Shift keys, independent Caps Lock, German AltGr-Q and retained source layout
group. This is native state/mapping evidence, **not** live application input,
IME composition, candidate-window capture or disconnect-release evidence.

The full plugin and six CTest executables build and pass against installed
Hyprland 0.56.2 and libxkbcommon 1.13.2. The new test compiles with conversion
warnings and `-Werror`. The initial state-only build was not loaded; the later
direct-application build below was loaded only in the existing isolated compositor.

## Local native direct-application session

VFHY begin tag 59 explicitly grants pointer/buttons/wheel plus the direct
keyboard capability. Tags 50/56/58 do not grant keyboard authority. Key tag 60
has a 32-byte payload (generation, monotonic deadline, 32-bit page/usage,
32-bit state/repeat). Values must be canonical and usages must fit 16 bits.
Result 6 means exact native key delivery APIs accepted the event; wrong-kind
ACKs cannot complete a pointer or keyboard request.

`WindowKeyboardSession` resolves the exact bound main surface without a fake
pointer hit-test. It rejects local held keys, unsupported keymaps, missing seat
capability, source-keyboard replacement, expired grants and changed focus. It
retains the source keymap, application keyboard resources and potentially-held
native recipients separately. It never calls the global InputManager keyboard
pipeline, changes compositor keybinds, or injects text.

The source route accepts an active Wayland IME only when its enabled text input,
keyboard focus, desktop focus and exact bound application surface agree. It pins
a permitted physical source keyboard, including when the current seat keyboard
is an ephemeral IME virtual keyboard. Physical HID presses go to exact current
IME grab resources; releases and cleanup retain their original resources.
Without a grab, ordinary application keyboard delivery remains available.

Raw virtual-device listeners recognize returns only from that scoped IME client
while the exact session remains active. They suppress normal duplicate/global
routing and send returned keys only to retained application keyboard resources,
using the virtual keyboard's actual keymap and modifiers. Physical capture is
not ended merely because an IME virtual keyboard is destroyed. Configured-disabled
keyboards stay denied, and suppression restores their prior enabled state.

A native ACK confirms dispatch to the source application or source IME. It does
not confirm asynchronous preedit or committed text: the compositor's IME commit
path lacks the serial needed for a per-key completion receipt. Source composition,
candidate selection and layout switching still require user acceptance. Candidate
hit tests retain exact ownership and the negotiated main-window bounds; areas
outside those bounds do not gain click authority from visibility alone.

On disconnect/end, it releases keys only to original still-focused recipients;
a resource that has received leave is never sent keys for its replacement
surface. Modifiers are restored after the whole release batch. A failed native
cleanup fences the controller across reconnects and prevents a successful END
acknowledgement. Forced capability-loss cleanup/fencing is implemented but not
yet fault-injected live. Normal focus restoration is conditional on retained
ownership and target validity.

### Isolated native evidence

The final loaded plugin SHA-256 is
`84a02e0d35d70a4425203c75b46b9b50af1f7be5bcd744ba82116ceb8252f5c7`.
The local `window_keyboard_native_probe` example restricts its target to an
explicit `viewflow_linux_pointer_probe --keyboard` process, obtains its exact
surface/PID/extent from an independent Viewflow GPU capture frame, and uses the
same-user/exact-compositor-PID socket. It sends only fixed Shift/A patterns.
It does not exercise QUIC or claim the captured frame was remotely presented.

- An initial balanced Shift+A run reached Qt with native scan codes 50/38,
  uppercase `A`, balanced releases and final modifiers zero.
- The initial disconnect run exposed incorrect modifier ordering: restoring
  the mask between A-up and Shift-up made Qt report Shift-up with Shift still
  set. This was not recorded as a full cleanup pass.
- After moving mask restoration after all releases, an abrupt socket shutdown
  following only Shift-down/A-down caused Qt to receive A-up and Shift-up,
  with final modifiers zero. The exact four-event assertion passed.
- A new tag-58 mouse/wheel-only grant rejected a key request and added no Qt key
  events (four-event count unchanged).
- A subsequent explicit keyboard grant sent unmodified A down/up. Qt observed
  lowercase `a` and modifiers zero; the resulting six-event assertion passed.

The corrected application witness is retained in
[`evidence/window-keyboard-native-20260906.jsonl`](evidence/window-keyboard-native-20260906.jsonl).
All capture stops and native socket removals succeeded. The two owned probes
exited; final isolated clients were empty and configuration errors were empty.
The main compositor was not reloaded, restarted or reconfigured.

Rust native transport tests: 19 passed, one pre-existing ignored test. Six native
CTest tests passed; native-GPU library and diagnostic-example strict Clippy
passed. This is bounded local direct-application proof, not multi-window keyboard
switching, long-duration repeat, Windows physical capture, or source IME proof.

## Dedicated QUIC authorization and receipt

Control tags 37 and 38 now carry `WindowKeyboardAck` and
`WindowKeyboardAuthorization`, independently of pointer acknowledgements and
pointer grants. Authorization retains owner, target device/window, generation,
committed geometry/frame, source expiry and an explicit mode. Only
`DirectApplication` is currently recognized; absent/unknown modes fail parsing.
There is no implicit conversion from pointer authority to keyboard authority.

A keyboard ACK echoes the full event, including physical usage/state/repeat and
the original sender deadline, as well as the lease/window/frame/sequence tuple.
Only explicit `KeySent` and `Rejected` results parse. The eventual pending-event
dispatcher must compare this whole echoed event; matching only a sequence is
insufficient. No pending keyboard dispatcher is claimed implemented here.

Source `WindowKeyboardGrant` can produce a typed announcement after the caller
confirms native begin. A fresh local renewal must advance generation, source
frame and expiry on the same owner/device/window/epoch before the old expiry,
and cannot occur while an operation is pending. Renewal preserves possibly-held
keys and replay sequence state; it does not turn an old down/up into a retry.
Native binding/renewal confirmation remains the caller's responsibility.

The new authenticated QUIC loopback test sends a fixture authorization, a
physical Shift request and an explicit rejected receipt. It checks that the
generic coordinator refuses the keyboard request as device-wide input, and
that replaying its control-envelope sequence fails. This fixture has **no native
keyboard backend** and deliberately never returns `KeySent`; its result cannot
be combined with the separate native Qt trial to claim cross-device delivery.

Verification: 40 protocol tests, 67 core tests and all three QUIC loopback tests
pass, including malformed mode/identity/ACK cases, old-message non-aliasing,
held-key renewal, expiry and replay tests. Strict native-GPU daemon library
Clippy passes. The source dispatcher integration added afterward is described
above; the subsequent receiver FIFO/dispatch work is also described above.
Native capture and product policy were connected afterward with the bounded
cross-device trial described above. Full hardware/layout/IME gates remain open.

Verification for this change:

- Protocol tests cover round trips, malformed/overflow fields and old-payload
  non-aliasing. Core tests cover bound identity, timing/replay, transition order,
  exact confirmation, uncertain cleanup, history limits and held-key capacity.
- Full protocol/core unit suites pass (37/65), as do 76 default-feature atlas
  tests. Linux native-GPU daemon builds and strict library Clippy pass.
  All-target Clippy is not a pass: older
  test modules have `clone_on_copy`, test-placement and float-comparison lints.
- No desktop input was generated and no compositor was restarted for this work.

### Bounded focus admission before direct keyboard BEGIN

A native direct-keyboard BEGIN may encounter an IME grab belonging to the
previously focused application. It now focuses only the already-authorized
exact target with `rawSurfaceFocus`, which does not warp the pointer, and waits
for a previous application grab to disappear or become the exact target-owned
source IME route. This phase does not
inject pointer or keyboard input. The original BEGIN receipt is held until
admission finishes; it retains the original sequence, generation and deadline.

The wait ends at the earlier of the original lease deadline and 20 ms after
admission starts. Polling cannot extend it. Target, surface, keyboard identity,
keymap, seat capability, focus or route changes reject admission. An overlapping
application command also rejects the pending BEGIN. A foreign grab still present at the
bound rejects the original command, and a later release cannot replay it.
An active exact target-owned IME grab is an admitted source keyboard route.
If the old grab disappears before its virtual keyboard is destroyed, an isolated
foreign-virtual seat mismatch stays pending within that same original bound.
Missing physical keyboard, permission, keymap or focus still rejects immediately;
post-admission keyboard identity checks are unchanged.

Native timing diagnostics keep successful BEGIN at stage 9. Rejected admission
uses keyboard startup failure 10 when the grab persisted through the bound;
other invalid admission evidence uses failure 9. Initial route diagnostics
encode `1 | (reason << 16)`, where reasons 1–5 identify missing seat manager,
input manager, seat protocol, keyboard capability and an input-method grab.
