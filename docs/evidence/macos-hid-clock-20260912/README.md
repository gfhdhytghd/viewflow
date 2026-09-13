# Mac HID short-contact clock recovery

The user reported that contacts shorter than approximately one second produced
no cursor movement, while longer contacts eventually moved. The user explicitly
authorized simulated HID input for this investigation. Tests sent single-contact
motion only, without buttons or keyboard input, through the installed app relay.

## Findings

Passive sampling found physical active contacts and changing XY on Linux and
increasing driver `submitted` counters with `current_contacts=1` on Mac, while
the Mac cursor position remained constant. Driver errors were zero.

Before the change, 300 ms synthetic strokes produced no cursor movement. At
700 native coordinate units/second, 1.5 s strokes first moved after
548–561 ms. Finger classifications 2, 3, 4 and 5 behaved alike. A temporary,
device-specific `Dragging=false` preference did not change this behavior and
was restored before deployment.

Changing only the synthetic sender timestamp epoch to Mac uptime allowed the
same 300 ms strokes to move. The shared driver's `State::emit` retains one
timestamp history across producers and advances by only 1 ms when an incoming
timestamp appears backwards. Unrelated producer uptime epochs can therefore
compress the native timeline after handoff.

## Change

`TrackpadBridge.receiveStream` stamps reports with the receiving Mac's monotonic
clock, in 100 us units, wrapping at the native 21-bit millisecond period.
It preserves all contact fields and button edges. No input dwell time, minimum
gesture duration, or transport cutoff was added.

The stream regression tests inject unrelated sender epochs and a receiver clock
crossing wraparound; they check 10 ms output intervals and unchanged payloads,
as well as existing concurrent producer ownership and disconnect behavior.
These tests submit no OS input and passed on macOS.

## Initial deployment observations (not reproducible)

Only the app executable changed; existing helpers and the installed version 12
DriverKit extension were retained. The candidate and installed executable have
SHA-256 `8fa98c6d9e05a8ec6360eb680ef9b5c2eaf6040fa19383b1224add17e19926bd`.
The original developer identity was used and strict bundle verification passed.
The GUI restarted as PID 91652; its input/window/clipboard workers subsequently
replaced the previous orphan workers. Input, HID, window sender and receiver
services on Linux were restored to active after simulation.

Repeating the original Linux-clock test after deployment gave first movement
at 135–144 ms at 700 coordinate units/second, and every 300 ms stroke moved.
At 2800 coordinate units/second, alternating directions produced:

| Contact duration | First movement (ms) | Cursor X displacement (logical pixels) |
| --- | --- | --- |
| 100 ms | 56.4 | 26.31 |
| 300 ms | 62.2 | 109.98 |
| 100 ms | 51.2 | -29.05 |
| 300 ms | 47.4 | -110.77 |
| 100 ms | 48.8 | 27.12 |
| 300 ms | 52.5 | 109.88 |
| 100 ms | 52.4 | -26.04 |
| 300 ms | 53.6 | -109.30 |

First movement was sampled using `CGEvent(source:nil).location` about every
10 ms and defined as a change larger than one logical pixel. These are cursor
observation measurements, not physical display latency or proof of a 33 ms
target. Physical touchpad acceptance remains for the user. Driver status after
testing retained native attachment, zero errors and no held contacts/buttons.

## Follow-up: issue persists, driver update pending

The user reported the same problem after the initial deployment. Subsequent
same-host tests sent reports directly to the Mac app HID Unix socket and sampled
CGEvent positions on that same Mac. All 100 ms and 300 ms strokes failed to move;
1 second strokes first moved after about 580–600 ms. The earlier successful
samples above do not establish a resolved issue.

A second source change preserves source-to-source timestamp deltas after a
backwards clock handoff instead of clipping every subsequent frame against the
previous emitted timestamp. Regression tests cover 100 subsequent 10 ms frames,
wraparound, and failed submission preserving the anchor; they passed.

Driver version 13 was built, signed with the existing developer identity, copied
into the installed app, and accepted by System Extensions. However, runtime
IORegistry still reports `Viewflow-Native-MT-v12`, and version 12 remains
`terminating for upgrade via delegate`. Closing the app and restarting it did
not complete that transition. Version 13 has therefore NOT been tested live.
The installed app backup is `BeforeDriver13.app` in the Mac deployment folder.
The Linux HID/input services were restored after the attempt. A Mac restart is
the next activation step before repeating the same-host short-stroke tests.

## User acceptance after restart (2026-09-13)

The user confirmed that the issue was resolved after restarting the Mac. This
is user-reported physical acceptance following the pending driver upgrade;
no additional post-restart latency measurement was taken. The driver v13
implementation and regressions are already in commit `bbe28fe3`.
