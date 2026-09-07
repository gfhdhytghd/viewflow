# Nested independent-capture atlas trials — 2026-09-06

These are partial runtime results, not completed MVP acceptance. Main desktop
Hyprland PID 3386992 stayed alive; no Viewflow plugin was loaded into it.

## Isolation and source

Task configuration and evidence: `/tmp/viewflow-nested.UgMEB2/`.
Nested runtime: `/tmp/vf.NwCEHJ/`, Hyprland 0.56.2 Lua, verified Wayland backend.
Physical DRM card/input nodes and seat acquisition were unavailable to the
nested process. Render/NVIDIA compute nodes and the private capture IPC
directory were exposed. This isolates compositor state, not the shared GPU
driver. No user autostart, session environment publication, or existing plugin
configuration was used.

The initial independent-plugin first-call failure was reproduced as a dynamic
loader exit 127: C++-mangled `lua_tolstring` was unresolved. C linkage and eager
symbol resolution fixed it. CTest passed 3/3. A standalone consumer then
received three DMA-BUF/native-fence pairs, waited fences, sent exact releases,
and visually inspected upright fixture pixels before confirmed stop/unload.
Actual decorated capture size was **795x602** for a 791x598 Qt client.

The Rust listener initially created its socket with mode 0755; the independent
provider correctly refused it. The listener now sets 0600 inside its validated
private parent before listening, without changing process-wide umask. Its 16
socket tests passed, including the new permission assertion and exact peer
authentication. Strict GPU library/binary Clippy and formatting passed.

## Cross-host runs

Receiver host was read back as WindowsVM (`wilf@172.16.105.70`). Only the owned
temporary staging directory and interactive task were used; no installed
service or firewall setting was replaced. Fresh Rust receiver build passed;
Windows atlas tests: 43 passed, one explicitly hardware-dependent test ignored.
Linux GPU atlas tests: 60 passed, two explicit hardware tests ignored.

The source used the independent provider, native CUDA/NVENC, V3 disposition
feedback, one atlas stream, 30 fps capture, and an unchanged 60 Hz / two-frame
age policy. Both ends used the measured capture geometry, with 800x608 atlas
for one window and 1600x608 for two labeled fixtures, Atlas-A and Atlas-B.

- `receiver-single.log`: 424 native visual submissions in a bounded 20-second
  trial. Source reported 424 enqueued and two clean expiries; no capture stop
  failure. The timeout supervisor requested termination at the planned limit.
- `source-multi.log`, `receiver-multi.log`: two-window startup succeeded and four
  native submissions completed, then an original operation deadline expired.
- `source-multi-3523079.log`, `receiver-multi-repeat.log`: a two-window repeat
  ran to the planned 20-second stop, with 537 native submissions and two clean
  source expiries. The local stop closed QUIC while a handoff was in progress,
  producing a transport error. This was not clean source-exit acceptance.
- `source-multi-3531176.log`, `receiver-multi-stop-test.log`: after changing local
  stop to drain bounded work before endpoint close, another trial failed before
  the planned stop. Two expired-unbound frames were recovered, then the next
  frame completed both tile copies with only 430 microseconds left and failed
  during visual mutation. No successful submission was claimed for that frame.

All admitted source cleanup paths in these post-permission-fix trials completed
without an unconfirmed producer-stop error. Windows temporary task and owned
process cleanup was checked separately after each completed trial.

## Aligned cadence repeat and visible-window check

Independent per-window relative timers accumulated render duration into their
next timeout. Equal-fps streams now target the same monotonic grid and skip
missed ticks without catch-up spinning. The new deterministic cadence test plus
the existing linkage/wire/sender tests passed 4/4. Native Windows code was not
changed for this comparison.

Three subsequent two-window 20-second trials completed with source exit zero:

| Source log | Receiver log | Native submissions |
| --- | --- | ---: |
| `source-multi-3573642.log` | `receiver-cadence-1.log` | 530 |
| `source-multi-3583969.log` | `receiver-cadence-2.log` | 512 |
| `source-multi-3588852.log` | `receiver-cadence-3.log` | 498 |

Each source reported two clean expiries; the receivers reported zero remote
expired-unbound dispositions in those trials. The SIGTERM supervisor stopped
admission at 20 seconds and awaited the source rather than killing it. Earlier
failures above remain evidence; three bounded successes are not a reliability
guarantee under arbitrary load.

A task-owned Windows observer selected only the exact native presenter's two
visible `ViewflowAtlasProxy` HWNDs. With a thread-local physical-pixel DPI
context it moved each owned window to an onscreen position without activation
and captured its 795x602 rectangle. Inspection of `windows-atlas-A.png` and
`windows-atlas-B.png` confirmed upright grids and distinct Atlas-A/Atlas-B labels
for proxy IDs 0:1 and 0:2, with no black frame or tile swap in those snapshots.
The first observer attempt rejected virtualized/offscreen geometry before
capturing; DPI context correction fixed the observer, not the video pipeline.
This checks desktop-composed content, not a hardware scanout timestamp.

## Frozen input geometry transport

The independent capture plugin now optionally appends the existing 88-byte
HCGI geometry record to HCGF in the same seqpacket and with the same two FDs.
Its codec matches the Rust golden bytes and rejects invalid identity, geometry,
reserved fields and lengths. Invalid optional metadata is rejected before the
sender advances sequence state. Five CTest cases passed, plus the Rust golden
boundary and same-frame-with-FDs receive tests.

An isolated Wayland compositor (PID 3651827, main desktop unchanged) loaded
the rebuilt plugin. Owned Qt fixture PID 3654336 produced three consecutive
320-byte packets, sequences 1–3, without data or ancillary truncation. Every
packet's window address and PID matched live client state; its nonzero surface
identity stayed stable. Content was `(245,181,791,598)` and surface extent
`791x598`, exactly matching the fixture, while the captured image was `795x602`.
The consumer waited for each fence, successfully read back the first DMA-BUF,
released all frame FDs and received a confirmed stream stop. Local fixture
artifacts are under `/tmp/viewflow-nested.UgMEB2/` (`frame3654896.ppm` and
`input-geometry-3651827.jsonl`).

This proves metadata transport for this Wayland fixture, not input injection or
complex decorated/fractionally scaled geometry. XWayland does not receive this
input binding. Atlas input remains disabled pending retained per-window capture
snapshots, committed-feedback mapping and shared control-channel routing.

## Remaining acceptance

Longer/load-varied multi-window reliability, physical scanout and latency, dynamic window
membership/geometry, input/Deskflow integration and host-blur behavior remain
open. Native submission counts are not physical present receipts. The failed
trials must not be discarded when evaluating stability.
