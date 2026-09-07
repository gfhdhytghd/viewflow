# Device-pair atlas layout

`viewflow_core::StableAtlas` is a bounded capture/composition layout, now owned
by `Coordinator` under an explicitly configured `(source_device, remote_device)`
pair. Multiple windows share that layout. The native GPU composition/encoder
and Rust batch adapter now exist; authenticated wire publication and remote
multi-proxy integration remain separate work.

## Implemented invariants

- Dimensions come from the full decorated capture in pixels, not desktop DIP
  bounds or destination scale. Canvas size, pixel alignment and window capacity
  are explicit local policy; 6K is not a hard-coded ceiling.
- Adding/removing/resizing a window never repacks unrelated windows. Alignment
  padding is distinct from content. Shrinking can retain the previous reservation.
- Failed placement leaves the complete previous layout unchanged. Free space
  uses bounded guillotine partitions with adjacent-rectangle merging; fragmentation
  can reject a placement instead of silently moving other windows.
- Layout revision and placement generation do not wrap. Reusing a freed region
  does not reuse its identity. Snapshots are deterministic by window ID.
- A geometry commit invalidates only that window's tile while retaining its
  reservation for new capture. The coordinator rejects capture staging during
  an uncommitted geometry phase or with the wrong committed epoch. Invalidations
  are prepared before committing the coordinator's updated window state.
- Disconnect suspension invalidates all tiles without discarding reservations
  or geometry epochs. Fresh capture produces a new placement generation. It
  cannot change known dimensions under the old geometry epoch.

`configure_media_atlas`, `place_captured_window`, `media_atlas`,
`suspend_media_atlas` and `remove_atlas_window` are local coordinator APIs.
Peer control messages cannot implicitly configure an atlas. The future
per-device owner must retain the coordinator across attempts; existing generic
connection-local coordinators do not establish that lifetime automatically.

## Remaining integration

The native coded example still captures/encodes a single window. The native
`encodeAtlas` path now composes independent DMA-BUF crops into shared color/alpha,
clears retired regions and respects the earliest original capture deadline.
`GpuAtlasCompatibleEncoder` connects `AtlasSnapshot` and borrowed GPU sources to
the H.264/VFAR adapter. It requires exactly one fresh source for every placement,
checks geometry, dimensions, layout/placement generations and source lineage,
and returns the layout/source identities with the paired coded media. The atlas
stream ID cannot alias a constituent window; its capture timestamp is the oldest
source timestamp. Layout revisions are separate from codec geometry epochs.
GPU initialization must precede held capture leases. No adapter sends HCGR.

The reliable control schema now has a distinct version-1 `AtlasFrame` payload,
bound to the atlas stream/frame/codec identity. Its canonical tile list carries
window epochs, placement generations, source frame IDs and content rectangles.
The batch adapter builds this manifest with each tile timestamp mapped by the
same session-clock offset; the oldest tile remains the atlas timestamp. Parsing
rejects duplicate/unsorted windows, overlapping or overflowing rectangles,
stream/window aliasing and timestamp renewal. A plain coordinator explicitly
returns `AtlasRuntimeRequired`, so adding the schema does not silently enable
atlas reception in the legacy single-window runtime. Live daemon orchestration
and publication acknowledgements are still needed.

`atlas_session::offer_atlas` / `accept_atlas` now negotiate an exact local plan
on a dedicated bounded bidirectional QUIC stream. The reply echoes resource
limits and both codec descriptors, bound to the current TLS connection using a
dedicated exporter label. There is one absolute handshake deadline and no
single-window fallback. The caller must first establish paired authentication
and probe its native decoder; descriptor validation is not a hardware probe.
The returned sessions send reliable manifests and stage them through the
receiver gate with control-sequence validation. Loopback mTLS tests cover that
path, mismatched plans, altered acceptance, per-connection binding and timeout.
Reliable enqueue still does not prove remote publication or presentation.

`offer_warmed_atlas` and `AtlasReceiverPresenter::accept_warmed` add the
version-2 startup path for the native receiver. A `VFAW` stream carries a bounded
version-2 offer and exactly three length-delimited H.264/VFAR pairs, then EOF.
The offer must match the locally authorized plan and this TLS connection before
payloads reach the native child. The receiver sends its version-2 acceptance
only after all three native unbound-copy completions. Both peers retain one
absolute startup deadline, reject trailing/oversized/truncated data and close
the dedicated connection on failure or cancellation. There is no downgrade to
the cold version-1 handshake in this path. Decoded alpha and encoded payload
limits remain separate. Startup pictures do not carry live source timestamps
or authorize input, and the first live pair still requires paired keyframes.

The supervised receiver API handles native process readiness, warmup and
negotiation failure cleanup together. The mTLS loopback/child-pipe test now
covers this startup followed by live frame 1. Other tests cover withheld
acceptance, native failure, cancellation, original-deadline expiry and malformed
startup data. This is a usable startup boundary, not yet the daemon's complete
device-pair discovery/capture/clock/entry-point orchestration.

The Windows receive side now has a separate [process entry and refreshable
clock stream](atlas-peer.md). Source process orchestration/discovery, actual
live proxy acceptance and input remain outstanding.

Version-2 verification (2026-09-06): workspace tests passed in default and GPU
configurations; strict GPU-enabled library Clippy passed. The Windows library
compiled and its atlas-session suite passed 14 tests (one native test initially
ignored). That explicit native test then passed in WindowsVM session 1: real
H.264 I/P/P fixtures crossed loopback mTLS QUIC, the supervised Rust receiver
completed native 1626x1240 startup, and checked shutdown reaped the child. No
V5 frame or input was sent. The temporary interactive task was removed after
verifying its exit and child absence. Logs under
`/tmp/viewflow-atlas-warmup-20260906.VGQyPg/`:
`warmed-windows-check.log`, `native-quic.log`, `native-quic-cleanup.log`,
`warmed-default-tests.log`, and `warmed-handshake-tests.log`.
Rust source archive SHA-256:
`23c051c0800d6b0d6ecabd57948d11fda51c2ef363bfa5687d6987a303f9209b`.
This proves startup handoff, not physical multi-window presentation or latency.

The negotiated receiver session now consumes actual `VFMD` datagrams through a
bounded assembler and its accepted `CodecSession`. Each reliable atlas manifest
carries both keyframe flags. Only packets for the current staged frame enter
reassembly; a newer manifest clears old partial planes. The completed pair is
checked against that exact manifest before handoff. A replaced incomplete frame
or frame-number gap requires a paired keyframe; an invalid completed media
admission retires the receiver session. This is conservative when IDs skip for
non-codec reasons and still needs live recovery orchestration. Loopback tests
exercise reversed fragments, exact byte pairing, ordinary consecutive P frames
and rejection after a reference gap. Color payloads in these tests are synthetic
and are not native decode/presentation evidence.

Datagrams may now arrive before their reliable manifest: one newest early frame
is buffered with at most the negotiated encoded byte count and 16,384 unique
fragments (8,192 per plane). Exact duplicates retain the first arrival time and
do not consume extra space; conflicting duplicates or metadata retire the
session. Older early frames are replaced rather than accumulated. When the
matching manifest arrives, reassembly uses original packet receive times and
admission uses current time. Both receive APIs sample time again after processing
before returning a frame. `receive_manifest` can therefore return an admitted
frame immediately, and its caller must forward that result. Tests exercise this
data-before-control ordering over QUIC, late-manifest expiry, duplicate handling,
capacity limits, conflicts and expiry during processing. The bounded buffer
removes the need for a per-frame layout ACK solely to solve packet arrival order;
native presentation receipts and live owner integration are still outstanding.

`AtlasReceiverSession::next_frame` provides the unified control/datagram pump.
It stores the in-progress reliable read and its control sequencer in the session,
so waiting timeouts, cancellation and returning an admitted frame do not discard
partially read control bytes. Datagram reads only consume a packet when ready.
Waiting-only deadlines return the typed `AtlasWaitExpired` error, distinct from
terminal protocol/media errors or expiry after coded admission.
Individual receive calls cannot replace the pump after it starts. A real QUIC
test pauses the second reliable message halfway, exercises timeout and external
cancellation, delivers the first frame, then completes the same message and
delivers the second frame. This establishes the reader lifetime, not native
decode, proxy lifetime or presentation acceptance. The pump currently dispatches
atlas control only; the full device-session owner still needs other control
domains, capture orchestration and native backend integration.

`viewflowd::atlas_runtime::AtlasReceiver` now provides the bounded admission
component for that negotiated runtime. It holds one pending manifest,
checks exact media/frame/config/clock identities, requires a nonempty alpha
plane, limits encoded bytes and rechecks freshness at delivery. New manifests
replace old pending frames without renewing timestamps. Source replay, stale
placement resurrection and unversioned layout changes are rejected; first
delivery and changed layouts require a paired keyframe. Its output bundles the
layout with encoded media for the platform owner. It does not perform the
handshake, native decode, presentation acknowledgements or input authorization,
and is not yet wired into the live receiver loop.

The source owner still needs to collect and release the batch, retain the
device-pair lifetime and call this adapter from the daemon. Transport must
publish an authenticated layout revision atomically with the matching atlas
frame. Multiple native proxies must crop the correct tile and bind their input
receipts to the actually presented layout. A local layout snapshot is not
permission to inject input and does not prove any of those native boundaries.

## Verification

Core tests exercise real coordinator geometry transactions, stable reservations,
alignment, stale/conflicting epochs, failed resize rollback, removal/reuse,
disconnect suspension, overflow and bounded configuration. A deterministic
2000-operation trace performs successful placements and removals, verifies that
free/reserved rectangles partition the canvas without overlap after each step,
and checks that rejected operations preserve all state.

Run `cargo test -p viewflow-core --lib`. Native multi-window display, performance
and reconnect acceptance remain separate gates.

Linux and Windows core suites passed 56 tests. Linux workspace library tests
passed 392 with one hardware test ignored; Windows `viewflowd --lib` check also
passed. Core library Clippy passed with warnings denied. The unmodified
decoration tests still trigger five `float_cmp` warnings under strict all-target
Clippy; an additional run allowing only that lint passed. No native atlas
composition was exercised by these checks.

Later native component checks (2026-09-05) exercised two independent owned
DMA-BUF images through C++ and C ABI atlas encoding, software-decoded color and
exact alpha placement through two/one/zero-tile layouts. Rust's native wrapper
also encoded an owned 256x256 empty atlas. These are not captured-window or remote
presentation proofs. Batch adapter unit tests additionally reject missing or
duplicate sources, wrong dimensions/epochs, overlapping/out-of-bounds layouts,
replayed frames, unversioned mutation, stale slot reuse and timestamp renewal.
## Sender transport boundary

`AtlasCapturePool` collects one authenticated outstanding allocation per window,
preserves its original capture-plus-age deadline while other sources arrive,
and releases unencoded expired slots without GPU access. It never receives a
second frame from a held slot. Any malformed/disconnected source closes the
collection without releasing remaining uncertain allocations. Real seqpacket
tests verify waiting, expiry, restoration and disconnect behavior.

`GpuAtlasDevice::poll_and_send` now joins that collector to the batch driver,
preserving both across polls and constructing each atlas identity from the
oldest source timestamp. A full success restores the released receivers; errors
or cancellation retire the owner. The application still needs to supply capture
discovery, prepared/negotiated sessions, clock mapping and polling cadence, and
to dispatch native presentation receipts. Layout or membership changes require
an explicitly negotiated replacement owner.

`GpuAtlasSession` now accepts real `GpuStreamSession` values and retains their
exact producer controls while moving their authenticated receivers into the
shared atlas. Media failure attempts checked cleanup of every producer. Normal
shutdown freezes further submissions, waits for each exact stop response, and
then drops the GPU/socket owner. An invalid stop timeout leaves the owner intact.
`GpuStreamShutdown` retains the actual pending stop worker across cancelled
waits; resuming shutdown does not replay that stop or discard its result. One
failed stop does not prevent attempts for remaining streams, and its failure
cannot be cleared by calling shutdown again. Dropping an owner is still not
proof of checked producer shutdown.

Portable Linux tests cover exact stop identity, independent receiver/control
lifetimes over a real seqpacket pair, resumed waiting on the same worker,
continuation after failure, retained failure state and invalid timeout handling.
The stop-command tests use an injected responder; they do not operate the live
desktop or prove multi-window capture cleanup on a loaded compositor. Capture
startup/discovery and the final process entry point remain to be wired.

On Linux GPU builds, `GpuAtlasSender::submit_batch` owns the encoder and
negotiated sender throughout submission, source release and transport enqueue.
Each batch owns all source receivers and outstanding frames. Foreign source
leases are rejected before GPU import; an encoding error closes every source
without HCGR. Only `Encoded` or `ExpiredClean` permits source releases. A partial
release failure, transport failure or cancellation retires the owner and drops
the remaining receivers. Full success returns reusable receivers plus the exact
enqueued manifest (or no manifest for clean expiry). The native encode deadline
is capped by the original transport deadline, and transport is also capped by
the earliest original source deadline. Neither budget is renewed.
Its GPU success path is not yet a
physical multi-window acceptance result.

`send_coded_frame` accepts the encoder's `MediaFrame` directly and verifies both
plane identities, timestamps, roles, codec generations and keyframe flags against
the manifest before extracting payloads. This is the checked handoff for an atlas
encoder result used by the device driver. Tests reject each metadata mismatch before sending a valid pair
through the same negotiated session.

`AtlasSenderSession::send_frame` sends a manifest and both encoded planes using
the connection's current datagram budget and one caller-supplied absolute
deadline. It checks the aggregate encoded-byte and per-plane chunk limits before
enqueueing. A cancelled or partially failed send poisons this sender; callers
must renegotiate rather than continue an uncertain reference chain. Successful
enqueue is not a native presentation receipt. The caller still owns source-age
deadline derivation, matching the encoded planes to the manifest, and device
capture/encoder orchestration. The mTLS roundtrip test verifies exact payload
delivery through `next_frame`, not native decode or physical presentation.

## Native texture-region boundary

Windows `MakeCompositedRegion` creates a retained view of a decoded BGRA atlas
without another decoder, GPU allocation or pixel copy. Each view keeps the atlas
frame identity, an explicit source region and its own visible size. Nested crops
are rejected. The composition preview's surface-copy path uses the shared
`CopyCompositedRegion` helper to copy only that region, validating device,
format, sample layout and source/destination bounds first. Odd BGRA tile sizes
are legal; these are not subsampled decoder apertures.

The portable geometry test passes on Linux. The Windows hardware-only crop test
now also passes: it checks exact BGRA bytes and untouched destination padding
through the same copy helper. Both native projects built in Release and all
2 compositor / 13 preview tests passed; see
[native region evidence](evidence/windows-atlas-region-20260906.md). The opt-in
multi-proxy mode below now dispatches manifests to these views; its visible
behavior and per-window presentation/input receipts still need verification
and integration. A region view alone
does not authorize input or prove that any proxy was presented.

## Atlas presenter record (VFGP v5)

`encode_atlas_record` takes admitted atlas metadata/media together, validates
their stream/frame/geometry/source-clock identity, validates VFAR dimensions and
adds the unchanged native QPC deadline. All integers are big-endian. The first
40 bytes retain the VFGP lengths, identity and dimensions; byte 4 is version 5,
byte 5 and bytes 6..7 are zero. Header length is `112 + 64 * tile_count`; payload
length remains color AU plus VFAR, excluding the entire metadata header.

| Offset | Size | Field |
| --- | --- | --- |
| 40 | 8 + 8 | Absolute QPC deadline, frequency |
| 56 | 16 | Atlas stream ID |
| 72 | 8 + 8 | Geometry epoch, codec configuration generation |
| 88 | 8 + 8 | Layout revision, original oldest source timestamp |
| 104 | 4 + 4 | Tile count, keyframe flags (color bit 0, alpha bit 1) |
| 112 | 64 each | Canonical tile entries |

Each tile entry contains window ID (16), placement generation (8), geometry
epoch (8), source frame ID (8), source timestamp (8), then x/y/width/height
(4 each). Native parsing requires nonzero identities, strictly ascending window
IDs, no stream alias, valid placement generations, nonoverlapping bounded
rectangles and the exact oldest source timestamp. No unknown flags are accepted.

V5 requires a separate explicit parser opt-in. The existing single-window
preview does **not** enable it in its legacy modes; only `--stdin-atlas-v5`
selects multi-proxy dispatch. Rust fixture bytes matched the C++
fixture and parsed byte-by-byte under Linux ASan/UBSan and on Windows. The native
preview Release build passed 14/14 tests in a new isolated staging directory
`C:\Users\wilf\AppData\Local\Temp\viewflow-atlas-v5-20260906-YzKlvq`.
No GUI ran. Local log: `/tmp/viewflow-atlas-v5-20260906.YzKlvq/build.log`.

Source archive SHA-256:
`2b88884721e912f3c3eda1c5989a603652b4c18c0ab4eebeb4ccd35e23175122`.
Rust/native fixture SHA-256:
`789c40ed0083ebb0aa978b37ca53517298c3ece222fc2c3a11f3d2e8b0e8fe1d`.
Preview EXE SHA-256:
`da62f438d039840bee73ddc8e27e07b109415f48498be97cd45d823648e6e3ca`.
The archive and fixture hashes were read back from Windows and matched the
transferred inputs; the EXE hash identifies the resulting native build.
The metadata path is verified. The new native dispatch mode below still needs
end-to-end execution and native presentation receipts.

## Opt-in native multi-proxy mode

`viewflow_windows_composition_preview.exe --stdin-atlas-v5` now uses one
hardware decoder and one independent HWND/composition target per tile window
ID. New windows remain hidden until their candidate pixels are ready; existing
window positions remain unchanged, and removed tile windows are destroyed.
Every candidate surface is copied before any new brush is bound. Deadline
checks bracket lineage validation, GPU copies and visual changes. Any failure
closes the entire owner without a successful submission message. This is not an
atomic DWM scanout guarantee.

`AtlasFrameBindings` retains at most eight immutable frame/layout/deadline
records across decoder delay. Decoded pixels must match an exact retained frame
ID and dimensions. Stream/codec identity stays fixed; per-window source lineage
must advance. Changed layouts or frame gaps require paired keyframes. A newer
commit cannot later be overwritten by an older decoded frame. The native mode
uses this registry directly; portable tests cover delayed layout binding,
unknown dimensions/identities, stale commits, keyframe requirements and bounds.

The mode prints `atlas-native-ready input_enabled=false` and emits
`atlas-submitted ... physical_present_receipt=false` only after all visual
mutations pass their deadline checks. It deliberately does not emit the legacy
single-window acknowledgement or enable input routing. Optional startup warmup
now sends exactly three V3 decode-only records, waiting for each unbound GPU-copy
completion under one startup deadline. Codec-local identities separate these
records from V5 live frame IDs, so live frame 1 remains valid after warmup 1–3.
Started warmup must finish before live submission; repeat/late warmup and geometry
drift are rejected. Cold startup is still allowed. Warmup does not attach a visual
to a window or produce a presentation receipt. The Rust pipe/child API exposes
this sequence; its duplex test covers three completions followed by live frame 1.
Host-backdrop blur configuration, dynamic codec reconfiguration, physical
multi-window/DPI testing and presentation-bound input receipts remain required;
this mode is not a completed production acceptance result. Native GPU warmup
has been verified separately in a Windows interactive session, as recorded below.

Warmup revision verification (2026-09-06): Windows Release build and all 16 native
CTest cases passed, including decode identity separation. Build log:
`/tmp/viewflow-atlas-warmup-20260906.VGQyPg/final-build.log`.
Rust workspace tests with `viewflowd/native-gpu-nvenc` passed (hardware tests
remain ignored); strict `viewflowd` library Clippy passed. Workspace all-target
Clippy remains blocked by 13 `clone_on_copy` diagnostics in protocol input tests.
No visible proxy or actual native GPU warmup was run for this revision.

A subsequent warmup-only process attempt over Windows SSH reached decoder,
STA, dispatcher and DPI initialization, but failed constructing the Windows
Composition `Compositor` with `0x80070005` before readiness. No warmup records
were submitted. This establishes an initialization failure in that launch
context, not a decoder or warmup failure. Added stage diagnostics compiled in
Release and passed all 16 native tests. Logs:
`/tmp/viewflow-atlas-warmup-20260906.VGQyPg/warmup-diagnostic.log` and
`/tmp/viewflow-atlas-warmup-20260906.VGQyPg/diagnostic-build.log`.
The same binary subsequently passed in the logged-in WindowsVM session 1 using
a temporary limited interactive task. It decoded the existing H.264 I/P/P
fixtures with raw VFAR zero-alpha planes, returned all three exact
`atlas-warmup-completed` responses at 1626x1240, and exited successfully on EOF.
No V5 record was sent; this is unbound startup decode/copy evidence, not visual
presentation, nonzero-alpha correctness or live stream performance evidence.
The collector verified task exit 0 and absence of the owned native child, then
removed the temporary task. Runtime log:
`/tmp/viewflow-atlas-warmup-20260906.VGQyPg/interactive-warmup.log`.
Direct SSH launch still fails at Composition initialization; the application
must arrange a usable desktop-session context for this native presenter.

The mode compiled in a Windows Release build on 2026-09-06; native CTest passed
15/15 including `atlas_frame_bindings`. The same binding test passed Linux
ASan/UBSan. No visible proxy execution was performed. Final Windows staging:
`C:\Users\wilf\AppData\Local\Temp\viewflow-atlas-proxies-20260906-qD3u6e`.
Log: `/tmp/viewflow-atlas-proxies-20260906.qD3u6e/final-build.log`.
Final source archive SHA-256:
`20b1bd7caefe9ea8fb9af457186561a3c5f228d4734e2b298a83d661f44e40ff`.
Preview EXE SHA-256:
`930509d5d71a3835dba761992d40fa2296d7b0a0459969fa46dc5957e03f272c`.
The earlier build in this staging directory is superseded by these final
hashes, which include the post-lineage deadline check and linear source matching.

## Rust native-pipe handoff

`AtlasPresenterPipe` now writes the admitted V5 record and waits for the exact
atlas-mode response under one original source deadline. It requires the distinct
atlas readiness line, bounds each response line to 160 bytes, and verifies frame
ID plus tile count. The return type is `AtlasVisualSubmission`, not a physical
presentation or input receipt. Legacy single-window output and any claimed
`physical_present_receipt=true` are rejected.

Both I/O handles move into the active operation and are restored only on full
success. Timeout, cancellation or partial read/write drops those handles and
permanently retires the adapter. A 16-byte duplex test exercises fragmented V5
write/read handoff; a cancellation test proves the partial ready reader closes
instead of accepting a later suffix. These are Rust I/O tests, not another
native-window execution. The supervised child below supplies process ownership;
the receiver pump still needs to connect to this adapter with a deadline derived
from the original admitted source timestamp.

`AtlasPresenterChild` now supervises a child launched with only the explicit
`--stdin-atlas-v5` mode. It pipes stdin/stdout, inherits diagnostics on stderr and
uses a no-console creation flag on Windows. Startup waits for the atlas-specific
ready response. Normal startup/submission errors close the I/O and kill/reap the
owned child under a separate two-second teardown bound; teardown failure is
reported, never interpreted as successful frame delivery. Operations take
exclusive ownership of the process state, so cancellation cannot restore a
partly used child. Tokio kill-on-drop is the cancellation backup, not a claim
that every OS termination error is impossible.

Linux tests use actual isolated shell processes and verify their PIDs disappear
after explicit shutdown, rejected readiness and cancellation during a partial
ready response. The cancellation test also waits for reaping. This does not yet
prove native Windows child/window teardown. No Windows UI was launched for these
tests. End-to-end Windows child/window execution remains unverified.

`AtlasReceiverPresenter` now owns the QUIC receiver and supervised child together.
Waiting-only `AtlasWaitExpired` results (or cancellation while waiting) preserve
the pending control read and the ready child. Once a frame is admitted, both
sessions move into the active handoff: error or cancellation retires them rather
than continuing a codec chain after lost output. Explicit errors also wait for
bounded child shutdown.

The native Windows entry samples Tokio time, then QPC, then the negotiated
receiver clock. Remaining budget comes from the original oldest source timestamp
plus the negotiated age limit, capped by the original call deadline. Both QPC
and Tokio deadlines are derived from that same remaining budget, using earlier
clock samples so conversion cannot extend it. There is no fresh per-frame timeout
starting after encoding or pipe transmission.

A real mTLS/QUIC test forwards a matched frame into a supervised local process
after a prior wait timeout. The child reads the entire encoded record before
returning a matching visual-submission response. This verifies the connected
receive/pipe/process path, but uses synthetic media and a simulated native
response; it does not establish hardware decode or physical presentation.

Windows validation (2026-09-06) used fresh staging
`C:\Users\wilf\AppData\Local\Temp\viewflow-atlas-rust-20260906-oCEbqj`:
`cargo check --offline --locked -p viewflowd --lib` passed, followed by
`cargo test --offline --locked -p viewflowd --lib atlas_presenter` (3/3 passed).
This compiled the Windows QPC/process branches and ran the bounded pipe tests;
it did not launch the native window presenter. Existing Windows dead-code
warnings remain. Source archive SHA-256, matched on Windows:
`15f049ee95970f94a26354f5ef2c5121f43986d89e09e28b11589591cc15507d`.
Local log: `/tmp/viewflow-atlas-rust-20260906.oCEbqj/check.log`.
Linux full tests passed 243 default / 350 GPU-feature (7 ignored), with
GPU-feature library Clippy clean.
