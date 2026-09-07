# Source-side input method integration

Status (2026-09-06): trials 80 and 81 displayed real candidate lists in both
Windows proxies and committed Chinese text in both source applications over
Windows OS scan-code -> QUIC -> Linux Qt/Fcitx. Both reached their planned
12-second stop. Trial 81 still discarded one input by timing; this is not
sustained latency acceptance. Earlier failures are retained below.
This is **not** full multi-window IME acceptance,
native Wayland input-method-grab support, general candidate-popup placement/interaction acceptance,
physical USB keyboard evidence or sustained latency acceptance.

## Trial isolation and route

Trial 68 used the existing owned nested Hyprland 0.56.2 compositor, two fresh
`viewflow_linux_pointer_probe --ime` processes, and a private `dbus-run-session`.
The bus configuration had no service activation directories. Fcitx configuration,
cache and data were under the trial's owner-only temporary directory, not the
user's directories. Only `keyboard,dbus,dbusfrontend,pinyin,punctuation,classicui,
wayland` addons were enabled; `waylandim` was not enabled. Source Qt selected its
Fcitx module through process-local `QT_IM_MODULE=fcitx`. This is an application
input-context route, not permission to bypass a compositor keyboard grab.
Fcitx documents the [Qt module route](https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland).

The Windows helper checked the exact receiver parent, native executable, session,
proxy class/title, foreground window, held modifiers and cursor ownership before
using `SendInput`. It sent an ordinary hover, waited 600 ms for source focus/input
context setup, then sent individual down/up Scan 1 events for `n i h a o Space`.
No Unicode text injection or synthetic Qt input-method events were used in this
live trial. The destination proxy's UI-thread IME disable remained enabled.
The hover and every later key retained their own original deadline; the setup
wait was not added to an existing event's budget.

## Failures and change leading to trial 68

- Trial 65: first Windows key retired under the old combined
  `keyboard-deadline-binding-or-held-state` error. No source key was authorized.
  Its exact subcondition is unknown. The native producer now reports these three
  failures separately and emits only clock values for a rejected deadline, never
  typed keys/text. Windows Release and all 19 native CTests passed.
- Trial 66: real Fcitx preedit reached Qt, then the native session was revoked as
  `LocalMotion`. The first `n` was inserted directly before input context setup;
  this was not a correct complete composition result.
- Trial 67: targeted native diagnostics reproduced the revocation and recorded
  `initial=317,960 current=317,960`. The public compositor motion signal had fired
  for a stationary focus recheck while the candidate interface appeared.
- The native target now ignores only unchanged finite global coordinates in this
  signal. Any coordinate change or malformed coordinate still revokes; button,
  wheel and key takeover listeners are unchanged. Seven native Linux CTests pass,
  including the recorded stationary case, coordinate changes and nonfinite input.
  Real physical-mouse takeover after this change still requires a separate trial.

This is consistent with the exact installed revision's
[mouseMoveUnified implementation](https://raw.githubusercontent.com/hyprwm/Hyprland/efb50993780079460b0cbed1363e2166a2de1d9f/src/managers/input/InputManager.cpp):
its forced refocus path can emit the floored position without a position change.
It is not an exemption for an IME client or a device.

## Observed result and limits

Application A recorded preedit `n`, `ni`, `ni h`, `ni ha`, `ni hao`, followed by
one commit of `你好`. Its only committed editor-text change was exactly `你好`.
The [application A JSONL](evidence/window-ime-quic-20260906-A.jsonl) is the
application-side witness; separate `jq` assertions verified exactly one matching
commit and exactly that editor-text sequence. Fcitx-generated Qt IME events have
`spontaneous=false`; this field alone must not be mistaken for test injection.
The release records also distinguish native spontaneous delivery from Qt module
reprocessing and are not a count of network key messages.

Application B received preedit `n`, then the source retired generation 2 with
`FocusChanged`. The [application B JSONL](evidence/window-ime-quic-20260906-B.jsonl)
records the following leave and key release. `WindowPointerSession` currently
requires its exact pointer-focus surface even in keyboard-capable mode. The
remaining investigation is exact popup/family pointer ownership; it must not be
resolved by accepting arbitrary focus or globally disabling revocation.

The source counted 15 authorized operations, zero timing/capture discards and 178
enqueued atlas frames before the early error. Zero discards do not make this a
successful run: it ended before both windows completed. The
[Windows retirement log](evidence/window-ime-quic-20260906-windows.log) records the
peer-side disconnect. Candidate rendering/positioning in the remote atlas was not
visually inspected. Active Wayland IME grabs are still rejected, and native-grab
reinjection, cancellation/reconnect, first-key readiness without prior hover,
all layouts/repeat and sustained two-refresh-period behavior remain open.

## Build and cleanup identity

- Linux native-GPU source unchanged from trial 64:
  `f061c18b35a017c3a5605b45b777d80a0e7cc470edf9fd262aa1827f05cf8e7e`.
- Windows Rust receiver unchanged from trial 64:
  `61CA915F6EA17B0AA596A9095DE5B258EF17ECB45F25570C4891B674826E0A08`.
- Windows native producer with split rejection diagnostics:
  `1CCC7669C4B08323DD1D47DACF3032712FC95C9CB014CFA73FE2B28E03281911`.
- Linux native plugin with stationary-recheck correction:
  `cea288853d27269c321eb758fa5f99ee9baeebb5986365186ce867cb3839f710`.
- Qt input-method witness:
  `42a97995bc0adb8ee782640e98d63417569bc0d7ad85344a902d3b49920db309`.

All owned Qt/Fcitx/private-bus processes ended. The Windows task was Ready with no
owned staged processes and was unregistered. The nested compositor's clients were
empty and config errors empty. Only its owned input plugin was replaced; the main
compositor and user's input-method configuration were not reloaded or changed.

## Follow-up trials 69–73: independent keyboard and pointer lifetime

Trial 69 again stopped during initial composition; an exit-only diagnostic did
not report the original focus condition because controller retirement called
ordinary `end()` after observing the failure. Trial 70 stopped at a different
boundary: the Windows producer recorded **16 ms queued age**, which together
with its unchanged **20 ms clock allowance** exceeded the original input budget.
The [trial 70 native log](evidence/window-ime-quic-trial70-windows.log) identifies
that rejection. A later successful run does not erase this latency failure.

The owned native diagnostic gained an explicit `ime` mode. It requires the exact
`viewflow_linux_pointer_probe --ime` process, sends a native hover, waits for the
source input context, then sends physical HID usages for `nihao Space`. It uses
the same plugin route but does not involve Windows or QUIC. In trial 71 it
reproduced `FocusChanged` and logged:

```text
owned_present=1 current_present=0 same_client=0 held_buttons=0 keyboard_active=1
```

Thus the observed case was a **cleared pointer focus**, not a replacement input
recipient and not loss of the exact keyboard binding. The session now retains
keyboard authority only when that binding remains active, the original pointer
surface still exists, the seat exists, current pointer focus is null and no
pointer buttons are held. A replacement pointer recipient, held pointer button,
invalid target, local takeover or lost keyboard binding still fails closed.
This does not admit an arbitrary popup/client or add Wayland-grab support.

A subsequent authorized motion can reacquire only its resolved exact target.
Before doing so it discards the old pointer restoration snapshot; it cannot
restore a focus it no longer owns. The source controller also preserves the
actual retirement reason. Both pointer and keyboard restore previous focus only
for ordinary, unrevoked END, not expiry/focus/route failures. Pointer restoration
additionally requires successful keyboard cleanup. Eight native CTests pass,
including the full boolean admission matrix and all current retirement reasons.
These policy tests do not substitute for all physical takeover/failure trials.

With that change, native trial 72 committed `你好` in both owned editors and
delivered a following motion at `(200, 300)` to the same target. Both helper runs
received exact native completion and ended successfully; see
[A](evidence/window-ime-native-trial72-A.jsonl) and
[B](evidence/window-ime-native-trial72-B.jsonl). The example also passed strict
Clippy with `native-gpu-nvenc` enabled.

Trial 73 then returned to the real Windows/QUIC route with fresh applications,
the same private Fcitx setup, ordinary hover followed by `nihao Space`, and no
deadline changes. The guarded Windows helper sent 24 balanced key transitions
across the two exact proxy windows and recorded no helper error. Each source
editor recorded exactly one `你好` commit and exactly one editor-text value of
`你好`; separate JSON assertions checked both
[A](evidence/window-ime-quic-trial73-A.jsonl) and
[B](evidence/window-ime-quic-trial73-B.jsonl).

The source reached `PLANNED_STOP_EXIT 0` after 12 seconds: 28 authorized mixed
operations, zero input timing/capture discards, 402 enqueued atlas frames and one
clean expired media frame. The [receiver log](evidence/window-ime-quic-trial73-windows.log)
reports 402 native visual submissions and peer shutdown because the source
stopped; these are not physical presentation receipts. This bounded success does
not prove 60 FPS or the two-refresh-period performance target. The earlier
16 ms queue-age rejection remains an open sustained-input performance issue.

Latest plugin SHA-256:
`7678089da01339b06275776ecf0d7ec108bdd2f2479edb7d3e67224af2d26290`.
Other trial-68 executable identities above are unchanged. All owned Qt/Fcitx/bus
processes exited, the Windows task was removed after its idle/no-child check,
the native socket was absent and nested compositor clients/config errors were
empty. Only the isolated compositor's input plugin was replaced.

Remaining IME gates include remote candidate-popup capture/placement and
interaction, active native Wayland input-method grabs, first-key readiness
without prior hover, cancellation/reconnect/fault cleanup, physical keyboard and
layout/repeat coverage, and sustained latency. The full project plan remains open.

## Trial 74: candidate surface creation is not proven by composition

A fresh private Fcitx bus/profile and one owned Qt editor repeated the native
`ime` diagnostic with Fcitx-only `WAYLAND_DEBUG=client`. It completed `你好` and
the following pointer motion; see the [editor witness](evidence/window-ime-native-trial74-A.jsonl).
The [Fcitx protocol trace](evidence/window-ime-native-trial74-wayland.log) records
one `wl_surface` creation but **no** XDG popup/toplevel, layer-surface or
input-popup role request, and no surface buffer attachment. This trace covers
**only the Fcitx process**, not the Qt client. It cannot establish whether the
client-side candidate UI exists; the original stronger conclusion was incorrect
and is superseded by trial 75 below. It does not prove the capture renderer
dropped a candidate surface, and it is not a Windows visual test.
Two harness setup attempts ended before input (title-prefix match,
then the wrong native socket); the retained trace is the successful final run.

Separately, source inspection against the installed Hyprland revision confirmed
that `renderWindow(RENDER_PASS_ALL)` traverses the window's XDG popup tree, while
the capture visibility override only traversed its main wl_surface/subsurfaces.
The override now also visits visible owner XDG popups and their subsurfaces,
deduplicates saved surfaces and restores their original regions on scope exit.
It does not include other windows, layer surfaces or compositor-wide IME popups.
Capture bounds still reject geometry changes; popup expansion/renegotiation is
not solved by this visibility correction. The modified plugin builds and the
five existing capture CTests pass, but these are not a live popup-occlusion
regression test. No plugin reload was performed for this change.

All trial children exited, the native input socket was absent and the isolated
compositor's clients/config errors were empty. Main desktop configuration and
input method were unchanged.

## Trial 75: Qt owns the candidate popup

Repeating the private native-input test with **both** processes' protocol traces
found the missing witness. The [Qt trace](evidence/window-ime-native-trial75-qt-wayland.log)
creates `xdg_popup#49` through `xdg_surface#47`, with the editor's
`xdg_surface#37` as parent. Its `wl_surface#40` attaches non-null buffers during
composition and detaches its buffer at commit. The [editor log](evidence/window-ime-native-trial75-A.jsonl)
again records one `你好` commit. This is a client-side XDG popup, not an independent
Fcitx-process surface. That ownership is consistent with Fcitx's documented
[client-rendered input method UI](https://fcitx-im.org/wiki/Special%3AMyLanguage/Q%26A_for_developer).
It corrects the trial-74 inference; protocol creation/attachments still do not
prove the candidate's pixels are visible in the Windows proxy or positioned
correctly. The next visual trial remains on this exact Qt/QUIC route rather
than changing to native Wayland grabs on the basis of the incomplete trace.

## Trials 76–78: first bounded Windows candidate image

The guarded Windows helper now pauses before Space and captures only the owned
proxy's client rectangle after checking its process/title/foreground and sampled
occlusion points. Trial 76 was invalidated by harness startup/lifetime timing.
Trial 77 produced candidate images and two Chinese commits but its screenshot
thread used DPI-virtualized coordinates; those images are not retained as
correctly scoped visual evidence. It also ended early with stale-capture/input
selection expiry and is not a successful bounded stream.

Trial 78 scopes the helper thread to per-monitor-v2 DPI awareness, restoring the
previous context afterward. The inspected [A proxy image](evidence/window-ime-quic-trial78-A.png)
is 795 by 602 pixels and shows the owned editor, `ni hao` preedit, and a candidate
list with `你好` as its first entry directly below the input. The image was taken
before Space, through the real Windows/QUIC/Linux Qt route. The
[A application witness](evidence/window-ime-quic-trial78-A.jsonl) records the
following `你好` commit. No candidate pixels were generated or composited by the
test helper. This proves one bounded visible candidate case, not all placement,
edge expansion, occlusion or mouse-selection cases. The isolated capture plugin
was not reloaded: it still ran the pre-visibility-fix mapped code, so this image
is not acceptance evidence for that new source change.

B reached `n`, `ni`, then the Windows producer rejected a key's original deadline:
the [native log](evidence/window-ime-quic-trial78-windows.log) records 16 ms
message age. Its unchanged clock allowance still applies; no deadline was
extended. No B screenshot was produced. Its [application trace](evidence/window-ime-quic-trial78-B.jsonl)
later committed `ni` during focus/teardown, not the requested `你好`. The
[source log](evidence/window-ime-quic-trial78-source.log) records early exit,
18 authorized operations and 249 enqueued frames. This is not a successful
two-window IME or sustained-latency run. Next work must address the measured
keyboard timestamp/dispatch boundary and then repeat both windows, while keeping
the original deadline semantics.

All trial children and the Windows receiver exited. The guarded Ready/no-child
cleanup unregistered the Windows task; the isolated compositor had no clients
or config errors and the native input socket was absent. The main desktop was
not changed.

## Trials 79–81: asynchronous decode and observed original keyboard time

Trial 79 changed atlas decode from a synchronous UI-thread future wait to a
single owned asynchronous MTA submission, with its completion event in the UI
message wait. It still encountered a 16 ms coarse message age rejection;
see the [retained Windows log](evidence/window-ime-quic-trial79-windows.log).
Thus asynchronous decode removes a known UI blocking interval but is not by
itself evidence that the clock/latency failure was solved.

The subsequent `KeyboardClockBounds` change derives a conservative original
event-time lower bound from a **strictly older** observed Windows tick and its
pre-read QPC. Same-tick observations are excluded. The unchanged 20 ms coarse
fallback remains available; no event is assigned a fresh dequeue-time budget.
The [keyboard implementation notes](window-keyboard-input.md#observed-original-time-bounds-and-asynchronous-atlas-decode)
document the proof, bounded ownership, regressions and test scope. Windows
Release and all 21 native CTests passed. Native executable SHA-256:
`1595B4F1A035EAF7E782DAA2A2B73CAE6583C585D53AECC7181F3CE45CB55650`.
Linux source, input plugin, capture mapping and Windows Rust receiver were
unchanged; this did not test the pending capture-visibility source correction.

Trial 80 used fresh owned Qt windows, the same private Fcitx toolkit route, and
the DPI-correct Windows screenshot helper. Both precommit images were inspected:
[A](evidence/window-ime-quic-trial80-A.png) and
[B](evidence/window-ime-quic-trial80-B.png) show the source `ni hao` preedit and
Chinese candidate rows directly below the editor. Both application witnesses
([A](evidence/window-ime-quic-trial80-A.jsonl),
[B](evidence/window-ime-quic-trial80-B.jsonl)) contain exactly one `你好` commit,
checked separately with JSON assertions. The [source log](evidence/window-ime-quic-trial80-source.log)
records planned stop exit 0, 28 authorized operations, no timing/capture input
discards, 510 enqueued frames and two clean expired media frames. The
[Windows log](evidence/window-ime-quic-trial80-windows.log) reports 510 native
visual submissions and shutdown after the source stopped, not physical receipts.

Trial 81 repeated this with new windows and the same executable. Its inspected
[A](evidence/window-ime-quic-trial81-A.png) and
[B](evidence/window-ime-quic-trial81-B.png) images again show both candidate rows,
and both [A](evidence/window-ime-quic-trial81-A.jsonl) and
[B](evidence/window-ime-quic-trial81-B.jsonl) passed the one-`你好`-commit assertion.
The [source](evidence/window-ime-quic-trial81-source.log) again reached planned
stop exit 0, but recorded **one timing-discarded input**, 27 authorized operations,
631 enqueued frames and one clean expired media frame. Its
[receiver](evidence/window-ime-quic-trial81-windows.log) recorded 631 submissions.
The discarded operation has not been independently identified; successful text
commits must not be described as a zero-loss or sustained-latency pass.

These trials prove two bounded keyboard-selected candidate display/commit cases,
not mouse selection, edge expansion, popup occlusion, every IME/layout, physical
keyboard timing, or the full project plan. All owned test processes exited; each
Windows task was unregistered only after Ready/no-child checks. The isolated
compositor had no remaining clients/config errors and its input socket was
absent. The main desktop was not reconfigured or reloaded.

## Trials 83–85: pointer-selected XDG candidates

Trial 83 established a negative baseline with the previous input plugin. The
Windows helper moved to client `(130,151)` and sent an owned mouse down/up over
the third candidate, with **no Space key**. The inspected
[precommit image](evidence/window-ime-click-trial83-A.png) shows `拟好` there.
The [application trace](evidence/window-ime-click-trial83-A.jsonl) instead records
main-widget press/release at `(128,149)` and a later literal `ni hao` commit.
The root surface hit test walked subsurfaces but omitted the XDG popup tree.

`WindowInputTarget::resolve` now visits only the bound window's mapped, non-inert
XDG popups in reverse breadth-first stacking order, verifies the exact root
surface owner and Wayland client, converts main-local to popup-local coordinates,
and honors popup/subsurface input regions before considering the main surface.
Non-finite coordinates are rejected. The existing main-surface negotiated bounds,
seat/grab/lock checks and pressed-surface ownership rules remain unchanged.

The rebuilt input plugin (SHA-256
`3fdb21affc539479bc820225aadc1a5eab20664392305f9d82252ec3d7ff1edb`)
was loaded only into the isolated Hyprland 0.56.2 test instance. The Linux C++
build and all eight existing CTests passed; these are regression checks, not
unit coverage of compositor popup stacking.

The identical click in [trial 84](evidence/window-ime-click-trial84-A.jsonl) and
[trial 85](evidence/window-ime-click-trial85-A.jsonl) committed `拟好` in source
window A without main-widget press/release events. This is application-level
evidence of pointer selection of a non-default candidate, beyond screenshot or
transport acknowledgement. Neither whole two-window trial passed: trial 84's
[source log](evidence/window-ime-click-trial84-source.log) reports one timing and
one capture discard before early exit; trial 85's
[Windows log](evidence/window-ime-click-trial85-windows.log) reports `atlas button
expired awaiting selection` while the helper was typing in window B. No timing
limits were widened. Both owned process groups exited and Windows cleanup ran.

Still pending: a full clean two-window mouse-selection run, focused popup-tree
regressions (overlap, nested/subsurface and input-region cases), out-of-main
extent geometry negotiation, and the remaining full-plan requirements. The
pending capture-visibility binary was not loaded in these trials.

## Trial 86: two-window pointer commit and selection diagnostics

The receiver's selection-expiry error previously called every ordered event a
button, including keys and wheels. `AtlasPreviewInput` now reports the original
sequence/window/frame, event-kind booleans, overdue duration, pointer/keyboard
authorization matches, and native queue length. It deliberately excludes key
usages and text. This is a diagnostic correction, not a latency fix: the same
original deadlines and fail-closed ordered-input handling remain in force.
The new `missing_keyboard_authority_expires_with_exact_event_diagnostic` QUIC
test withholds only keyboard authority, verifies the exact missing-authority
diagnostic and zero forwarded input. All seven atlas preview tests and formatting
passed. A strict Clippy run failed on three existing findings (test-module
ordering in atlas preview/input runtime and a boolean comparison in capture
socket tests); it is not a clean-lint claim.

Windows Release receiver SHA-256:
`5C2C1D5921DAAAB32DB44176BFFE0257937E60E643410C2AB2181C42C801927C`.
Its production code includes the new diagnostic; the subsequently added test
was exercised on Linux. The native Windows presenter and isolated input/capture
plugins were unchanged from trial 85.

Trial 86 inspected both pre-click screenshots:
[A](evidence/window-ime-click-trial86-A.png) has third candidate `拟好`, while
[B](evidence/window-ime-click-trial86-B.png) has third candidate `👋` after the
private input method learned the first choice. Do not hardcode the same third
candidate text across both windows. The corresponding source witnesses
[A](evidence/window-ime-click-trial86-A.jsonl) and
[B](evidence/window-ime-click-trial86-B.jsonl) each passed JSON assertions for
exactly one matching commit and zero main-widget mouse press/release events.
The helper used mouse selection without Space in both cases.

The [source](evidence/window-ime-click-trial86-source.log) reached planned stop
exit 0 with 617 enqueued frames, 29 authorized selections, one timing discard,
zero capture discards and one clean expired media frame. The
[receiver](evidence/window-ime-click-trial86-windows.log) reported 617 native
visual submissions, not physical receipts, then shutdown on source closure.
The selection-expiry error did not recur in this run; its latency cause is not
claimed fixed. This completes a bounded two-window non-default candidate mouse
selection case, not a zero-loss or sustained-latency gate. Owned processes were
reaped and the Windows task was unregistered after Ready/no-child checks.
