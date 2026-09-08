# Offline CPU performance measurements (2026-09-07)

These measurements use synthetic in-memory payloads and release builds on the
local development host. They do not measure capture, GPU encoding/decoding,
network latency, presentation, or live input. Each table is one before/after
run, not a statistically controlled latency distribution.

## Media reassembly

Run `cargo run --release -p viewflow-transport --example reassembly_profile`.
Each case completes 100,000 frames with 1,148 bytes per chunk. Multi-chunk cases
retain incomplete frames across windows to exercise supersession under loss.
Times include packet construction and, for multi-chunk cases, starting another
incomplete frame. The 1,024-window case is a scaling stress test, not a claim
about a typical desktop workload.

| Windows | Chunks | Before ns/frame | After ns/frame |
| --- | --- | --- | --- |
| 1 | 1 | 175.5 | 88.7 |
| 64 | 1 | 174.2 | 86.6 |
| 64 | 8 | 969.3 | 781.0 |
| 1024 | 8 | 3240.8 | 1039.0 |

Changes included in `2c66ebd`: replace global pending-map retention with direct
removal of the superseded frame, and transfer single-chunk payload ownership
without allocating chunk slots or copying the completed payload. The watermark
invariant permits at most one pending frame per window/plane. Transport library
validation: 52 tests passed, including replay, size limits, conflicting counts,
zero-copy ownership, and preservation of other windows and planes.

## Native presenter record construction

Run `cargo run --release -p viewflowd --example presenter_record_profile`.
Each case constructs 1,000 v4 records, with an opaque 1920x1080 VFAR alpha plane
and a synthetic color payload. VFAR validation is included in the timing.

| Color bytes | Before us/record | After us/record |
| --- | --- | --- |
| 65,536 | 34.80 | 33.68 |
| 1,048,576 | 63.18 | 50.82 |
| 8,388,608 | 495.92 | 386.57 |

Before: build the v2 record then insert deadline fields, moving the payload.
Atlas v5/v7/v8 additionally inserted the layout after building v4. After: build
the full extension first, allocate the exact complete record size, and copy each
plane once. Version bytes, payload length, header length, and resource checks
remain intact. Atlas extensions also reserve space for sparse patches.
The benchmark measures v4; removal of the second insertion for Atlas is evident
in the code but is not separately quantified here.

Validation: `cargo test -p viewflowd --lib gpu_presenter_pipe::tests` passed
all 9 tests. Coverage includes v4/v5/v7 header offsets and payload bytes, a v8
whole-record wire expectation, malformed alpha, invalid deadlines, geometry,
and exact record-size boundaries. Live input was not exercised.

## Alpha validation and decode

Run `cargo run --release -p viewflow-transport --example alpha_decode_profile`.
Each case uses 1920x1080 alpha and 1,000 iterations. The mixed pattern alternates
128 repeated samples and 128 literal samples. Raw mode returns shared storage;
its near-zero timings should not be interpreted as copying a 2 MB buffer.

| Pattern | VFAR bytes | Before validate us | After validate us | Before decode us | After decode us |
| --- | --- | --- | --- | --- | --- |
| Opaque | 32,424 | 25.27 | 25.03 | 70.85 | 55.86 |
| Mixed | 1,061,124 | 63.60 | 61.05 | 135.06 | 55.06 |
| Raw | 2,073,624 | 0.02 | 0.02 | 0.02 | 0.03 |

RLE validation and decode now walk borrowed slices while retaining one owner.
Literal decode previously split a new reference-counted Bytes handle for each
run before immediately copying and dropping it. The wire format and encoder
are unchanged. Validation timing changes are small and may be noise; the mixed
RLE decode improvement is the primary result. Tests include mixed literal/run
wire bytes and truncations/mutations of mixed, constant, and raw records.

## GPU allocation reuse experiment (not retained)

A native synthetic-texture test exposed per-tile cudaMallocPitch/cudaFree in
multi-window preparation. A candidate reused exact-sized per-index buffers and
released slots on membership shrink. The GPU was shared with other workloads
(44% utilization was observed between runs), so we alternated baseline and
candidate binaries rather than interpreting a single timing as a win.

Build the native probes with:

```
cmake -S platform/nvenc-encoder -B /tmp/viewflow-perf-native \
  -DVIEWFLOW_BUILD_GPU_DMABUF_ENCODER=ON -DBUILD_TESTING=ON \
  -DVIEWFLOW_TEST_GPU_EXPIRY=ON -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/viewflow-perf-native -j 4
VIEWFLOW_SPARSE_PROFILE=1 /tmp/viewflow-perf-native/viewflow-gpu-sparse-encoder-test
ctest --test-dir /tmp/viewflow-perf-native --output-on-failure
```

The opt-in profile uses two owned 256x256 EGL textures, 200 frames per mode,
AV1 encode, and no desktop capture or input. Mode 1 retains opaque-occlusion
contributors; mode 2 flattens composition. Output allocation/destruction is
included, with encoder initialization outside timing.

| Trial | Baseline mode 1 us/frame | Candidate mode 1 | Baseline mode 2 | Candidate mode 2 |
| --- | --- | --- | --- | --- |
| 1 | 2064.20 | 2113.40 | 2095.23 | 2104.66 |
| 2 | 2220.35 | 2169.36 | 2243.44 | 2148.66 |
| 3 | 2400.35 | 2139.18 | 2132.07 | 2207.86 |
| 4 | 2139.01 | 3379.40 | 2165.50 | 2170.21 |

No stable throughput improvement was established. The pooling implementation
was reverted; the opt-in measurement remains for future larger-window testing.
This does not prove pooling cannot help larger frames or a less loaded GPU.

Both builds reproduced the existing integration failure asserting that an
already-expired frame must report permanent failure. The native implementation
already reports ExpiredBeforeSubmission before importing or reading sources.
The test now expects that clean disposition and verifies a subsequent frame
encodes successfully, in accordance with the availability policy. This changes
no production expiry behavior.

## Alpha encoder repeat scanning

The contiguous-alpha RLE writer compares long repeated spans in 16-byte blocks,
with scalar checks for the first two following bytes so literal regions avoid
unnecessary block comparisons. The generic strided-RGBA path remains unchanged.
An exhaustive boundary check compares the new wire bytes against the scalar
writer for repeat lengths 0..260 and tail lengths 0..17, including run splits
at 128 and block boundaries. Decoded bytes and mode selection remain exact.

Use `cargo run --release -p viewflow-transport --example alpha_encode_profile`
for complete encode timing and roundtrip validation. To compare scan algorithms
in the same optimized binary and alternate execution order, use:

```
cargo test --release -p viewflow-transport --lib block_repeat_scan_profile -- --ignored --nocapture
```

The latter measures RLE payload generation on 6144x3456 planes, 10 iterations
per trial (it excludes VFAR header construction and the raw-mode precheck):

| Pattern/trial | Scalar us | Block us |
| --- | --- | --- |
| Opaque 1 | 9461.93 | 2001.20 |
| Opaque 2 | 9430.84 | 2134.56 |
| Opaque 3 | 9419.17 | 2053.16 |
| Opaque 4 | 9432.41 | 2025.17 |
| Mixed 1 | 31265.00 | 25564.35 |
| Mixed 2 | 29687.05 | 24665.43 |
| Mixed 3 | 18351.55 | 12859.88 |
| Mixed 4 | 23160.00 | 17889.34 |

Every paired trial improved: opaque roughly 77-79%, mixed 17-30%. Absolute
numbers vary with host load; these are CPU measurements, not a frame-rate
claim. Gradient/raw input bypasses this RLE writer and is not improved by it.

Validation at this stage: 54 transport unit tests pass, with the optional
release profile separate. Before this encoder-only change, the full viewflowd
library suite passed all 472 tests, covering the earlier presenter/decode edits.

## Linux deployment and real-session verification

User selected the configured 3840x2400 remote display at logical position
(3072,390), scale 2. Read-back confirmed HEADLESS-6 matches; DP-4 remained
focused and HEADLESS-1 was unchanged. Previously the headless mode was
1920x1080 at (4448,0), and the supervisor repeatedly rejected the mismatch.
The runtime output was corrected using the same `hl.monitor` form as the
project launcher; no input or focus command was sent.

The optimized source was built with the required production feature:

```
cargo build --release -p viewflowd --features native-gpu-nvenc --bin vf-media-peer
cargo test -p viewflowd --features native-gpu-nvenc --lib
```

The feature-enabled suite passed 608 tests, with 9 opt-in tests ignored. The
window discovery suite (9 tests) specifically covers reuse of the previously
parsed client list; default-feature tests do not compile that path.

The installed service actually executes
`~/.local/lib/viewflow/desktop/vf-media-peer-main` through an existing systemd
drop-in. That executable was atomically replaced by the native GPU build;
`vf-media-peer-main.before-performance-20260907` in the same directory retains
the previous binary. Running executable hash and service state are recorded in
`linux-deployment.json`.

Windows' existing ViewflowMain-Active receiver is one-shot. Restarting only the
Linux source leaves it waiting after the receiver exits; starting Windows while
an old source handshake is expiring can also abort that receiver. Deployment
verification therefore stopped the Linux supervisor, started the existing
Windows task, then started Linux. The resulting paired session remained active.
No Windows executable was changed, so receiver-side presenter and decode
improvements are not yet deployed there.

A runtime-only systemd drop-in at
`$XDG_RUNTIME_DIR/systemd/user/viewflow-desktop.service.d/90-performance.conf`
sets VIEWFLOW_ATLAS_TIMINGS=1. It samples startup and every 30th frame using the
existing diagnostic facility. Removing it and reloading systemd disables it for
future starts (the currently running process retains its environment).

At the recorded observation there were no enrolled windows. Only one blank
startup frame and continuing idle retention were observed, which cannot prove
active-window latency or throughput. The user was asked to perform an ordinary
window transfer/scroll manually for the next measurement. Input was not injected.

### Live regression and rollback

The user reported increased lag and a freeze during the requested manual test.
Source samples showed encoding around 8-14 ms and previous-frame feedback waits
of 45.6 ms and 145.7 ms (capture-to-batch-return reached 156.3 ms). These are
sampled source-side timings, not physical presentation latency. Windows then
reported `desktop begin lacks exact committed frame` and closed the connection
with `atlas selected input ended`. Offline benchmark improvements therefore do
not establish a net improvement for this deployment.

The Linux executable was rolled back to the verified prior hash
`de5b22c8c574fb18d781ca1ab7d893594dc4099c428bb9b205eeada29882aa6b`.
The runtime timing drop-in was removed. Windows receiver and Linux source were
restarted in order. Read-back verified the old running executable and resumed
paired probes plus activity through sparse frame 240. The chosen 3840x2400
output was retained. This proves resumed transport, not subjective smoothness.
Further deployment is deferred until the drag-state failure and feedback stalls
are reproduced and checked in isolation on both ends. Source edits remain for
review; no performance release has been accepted on the basis of this test.

## Isolated desktop Begin recovery candidate

The observed fatal message is emitted when DesktopReceiverState::prepare cannot
find the exact native-selected picture in the receiver's bounded committed
history. The live logs do not include the failing selection and complete
history, so they do not distinguish an out-of-order commit notice, eviction,
or another identity mismatch. Tests now cover the first two timing cases and a
withdrawn target without interacting with the desktop.

The caller uses prepare_when_committed: if the requested picture is ahead of
published history, retain the Begin ahead of its queued updates; if an old
picture is gone, use the latest committed placement only for the same stream,
configuration, topology, window, source geometry, and placement generation.
Subsequent drag events retain that one chosen base frame. Missing/mismatched
current targets locally reject and drain that gesture. A Begin whose operation
watchdog expires while waiting is likewise discarded locally, rather than
closing the media connection. Existing acknowledgement/order checks remain.

Validation: 9 desktop receiver state tests passed (including the three new
recovery cases); all 15 atlas preview input tests passed. These are isolated
logic/loopback checks, not Windows modal-loop or end-to-end performance proof.
The candidate is not deployed. The restored executable remains in use.

## Isolated receiver acknowledgement recovery and cross-platform validation

The source's DesktopMoveWorker can legitimately return Ended to an Update after
a window is handed back to the source desktop. The receiver previously required
Applied for every Update and propagated this normal handoff as a fatal error.
The candidate now accepts this terminal acknowledgement after checking its exact
lineage, drains the remaining events of that gesture through End/Cancel, and
permits the next drag. Source Rejected acknowledgements for Update, End, and
Cancel receive the same local treatment already used for a rejected Begin.
Two regression tests cover these paths and subsequent gesture/ordinal behavior.

Validation used an isolated Windows source/build directory, with no replacement
of the live receiver binary. The initial full Windows test run exposed a test
fixture using Unix absolute paths; the topology test now derives its unused IPC
paths from std::env::temp_dir() so it tests topology on both platforms. Final
`cargo test -p viewflowd --lib`: Linux 477 passed; Windows 388 passed, 1 ignored.
The desktop receiver subset contains 11 passing tests on both platforms.

No live input was injected, no focus changed, and no candidate executable was
deployed for these checks. Missing acknowledgement watchdogs and expired
non-Begin event handling still warrant separate recovery work. The measured
previous-feedback waits are unresolved; these tests do not reproduce the native
modal loop or prove end-to-end latency improvement.

## Feedback stage timing and later rollback-session observation

Added opt-in `VIEWFLOW_ATLAS_TIMINGS=1` sender timing for fragmentation/validation,
manifest send, media enqueue, and disposition wait. Startup frames 1-8 and every
30th frame are sampled. Receiver pipe timing uses the same opt-in sampling, so
short failures no longer need to reach frame 60 to leave a stage measurement.
All durations use local monotonic instants; enqueue is not wire delivery, receipt
is not a physical screen-present receipt, and sender feedback wait includes
network transit and receiver processing. No deadline or pipeline depth changed.

The existing feedback-blocking loopback test passed on Linux and Windows with
timing enabled. With its intentional 2ms Tokio sleep before replying, Linux
reported 3.36-4.01ms feedback wait and Windows 15.06-16.36ms. Those are debug test
observations, not native renderer latency or proof of a specific timer cause.
The 24 presenter tests also passed, including the delayed-write test whose
20.06ms delay appeared in write_us rather than receipt_us.

A later read-only inspection of the rollback session found Windows had closed
after 3480 native visual submissions, expired_unbound=0; its final error says
connection lost/closed. Linux's service was active but repeatedly reporting
`drained atlas startup timed out`. This is not an active paired session. No
restart, deployment, input injection, or focus change was performed.

Selected last Windows samples (frames 3780/3840/3900) reported record assembly
440-896us, pipe write 317-1046us, and native receipt wait 9008-14344us. Native
pipe-admission-to-decoded was 2307/2371/3082us; copy-ready-to-committed was
3203/7158/4130us. These samples concern the restored binary, not the candidate
and not necessarily the earlier 45-146ms source stalls. They prioritize further
inspection of native binding/window management and scheduling before more
small buffer-copy optimizations.

## Sparse proxy patch selection

DecodeSparsePatches already validates strict ordering by tile/source position.
The native presenter's stage_sparse_visuals nevertheless scanned the entire
patch list and copied a vector for every visible window. PatchesForTile now
borrows the matching contiguous span using lower/upper bounds. Visual matching,
brush replacement, patch order, and hidden-window behavior remain the same.

The standalone `patch-range-profile.cpp` compares the old scan/copy with the
borrowed range for 128 patches per window, 500 frame iterations (GCC -O2). Two
local runs measured per-frame selection: 8 windows 3.47-3.50us -> 0.103us;
32 windows 33.2-36.0us -> 0.418-0.491us; 128 windows 480.6-488.3us ->
2.26-2.27us. Checksums matched. This synthetic measurement isolates selection,
not rendering, and does not explain the observed millisecond-scale receipt
waits. Compile from repository root with `g++ -std=c++20 -O2 -I
platform/windows-composition-preview docs/evidence/performance-20260907/patch-range-profile.cpp
-o /tmp/viewflow-patch-range-profile` (join the wrapped command lines).

V8 parser tests include empty/gapped ranges, largest tile id, identical selected
records and borrowed addresses. Linux normal and AddressSanitizer plus UBSan
runs passed. No live visual test or input injection was performed.
Windows isolated Release native presenter build passed (default H264/MF
configuration, without the optional FFmpeg decoder); Debug V8 parser test
passed with assertions enabled. The executable was not launched or deployed.

## Sparse overlap validation scaling

DecodeSparsePatches compared every destination rectangle with every earlier
rectangle for that window. Large valid sparse frames therefore paid quadratic
validation work before native decoding. The candidate uses the validated
(tile, source-y, source-x) order as a sweep: expire rectangles whose bottom is
at/before the current y, retain active nonoverlapping x intervals, and check
the predecessor/successor of each new interval. Different windows reset the
sweep. Records of at most 128 total patches retain a contiguous scan because
tree allocation cost exceeded the small scan in measurement. No format limits,
layout acceptance rules, input restrictions, or frame deadlines changed.

A new standalone/CMake sparse_overlap test compares the decoder against a
quadratic rectangle oracle over 10000 seeded cases with 0-299 patches, spanning
both algorithm branches. It checks accepted patch identity and covers touching
edges, overlap, tile isolation, bottom-order expiry, and large coordinates.
Linux optimized and ASan/UBSan runs passed.

`sparse-validation-profile.cpp` measures complete parsing of one window's
valid 128x128 patch grid, five iterations per size. GCC -O2 baseline first run:
128/1024/4096/16384/32768 patches took 10/246/3995/69638/279148us. Final hybrid
runs measured 10-11/176-177/727-729/2989-3076/6270-6532us respectively. This is
a large-frame parser improvement; it does not establish live frame-rate gain
or identify how many patches occurred during the earlier freeze. The profile
uses /tmp/viewflow-atlas-record-before-sweep.h for -DVIEWFLOW_BASELINE; recreate
that baseline from the pre-change atlas_record.h (HEAD has the old decoder).
Use -I platform/windows-composition-preview when compiling the current variant.

The initial sweep-only Windows native Release build and Debug V8/overlap tests
passed. Final hybrid validation is recorded below when complete. No native
window was opened and no live binary was replaced for these checks.
Final hybrid Windows Release native presenter build and both Debug V8 and
sparse_overlap tests passed (native-sweep-final.log in the isolated directory).
A reversed-order profile run measured baseline 13/367/4951/72609/277984us at
the same five sizes, confirming the large-frame gap across measurement order.

## Rust sparse validation

AtlasFrame::validate_patches used the same quadratic destination comparisons.
It now uses the hybrid small-record scan and large-record sweep used by the
native parser. Existing checked-coordinate arithmetic, canonical ordering,
occupied-slot checks, and format limits are retained. The old implementation
is preserved only in tests as a reference; 10000 seeded cases spanning both
branches compare acceptance. The ignored release sparse_validation_profile
compares both implementations in the same binary.

Per-validation times for 128/1024/4096/16384/32768 valid grid patches were
8/339/4508/69795/268344us (reference) and 6/142/566/1988/4541us (candidate).
Linux protocol tests: 50 passed, 1 ignored profile; viewflowd library tests:
477 passed. The reference is test-only and not part of the production path.

Scope limit: the rollback log's frame 3780 record had 650967 total bytes,
489979 color bytes and 155240 alpha bytes, leaving 5748 metadata bytes. With
28 bytes per V8 patch plus other metadata, this sample cannot contain thousands
of patches. Thus these large-layout improvements do not establish the cause
of that sampled native receipt wait. Native binding/window-management timing
and actual frame complexity remain necessary to explain the observed lag.
Windows isolated final protocol tests: 50 passed, 1 ignored; viewflowd library
tests: 388 passed, 1 ignored. No live executable or session was changed.

## Offscreen native sparse binding probe

Added `viewflow_sparse_bind_profile` (not a CTest): creates Composition/D3D
resources and alternates two drawing surfaces through the existing sparse
stage/commit code. It never creates an HWND/desktop target, shows a window,
changes focus, or emits input. Each size has 10 warmup and 240 sampled iterations;
the probe verifies unchanged layouts use descriptor reuse. This measures host
setter work and Composition contention, not GPU completion or physical output.

Release build passed on Windows. SSH-session execution returned HRESULT
80070005 while creating resources. A one-shot `ViewflowPerf-Offscreen` task
using the existing desktop task's principal ran the same offscreen binary;
it completed with result 0 and was unregistered after completion. The live
receiver task and binaries were not changed.

Measured stage median / bind median / bind p95 (microseconds):
- 32 patches: 3.130 / 10.100 / 1960.250.
- 195 patches: 3.640 / 1672.460 / 4156.700.
- 256 patches: 3.980 / 1758.140 / 4163.620.

At about the complexity allowed by the sampled live record metadata, per-patch
Surface setters in commit_sparse_visuals plus its fixed setters can occupy
milliseconds even with cached descriptors. This is stronger evidence for
optimizing native binding than extrapolating thousand-patch parser results.
It does not prove the split within those setters or visual correctness of any
alternative binding strategy; the production binder is unchanged.

Also checked the timer hypothesis: atlas_peer already owns
enable_windows_timer_resolution during receive, and the native presenter has
its own TimerResolutionGuard. The earlier 2ms-sleep loopback test without that
receiver startup cannot establish that the live receiver lacks timer setup.

## Shared-brush offscreen prototype (not production)

The experimental sparse_shared_brush_prototype.h represents each patch with
a clipped container at its destination and a full-atlas sprite offset by the
negative atlas coordinate. All sprites in one scene share a surface brush.
Changing that brush's Surface replaces N per-patch setters with one. It is
referenced only by sparse_bind_profile.cpp; production stage/commit code is
unchanged. It currently models foreground pixels, not host-backdrop masking.

Within the same offscreen run, 195 patches measured bind median/p95 of
1696.960/4198.910us for the current code and 3.630/3.750us for the prototype.
32 patches measured 9.770/1581.600us vs 3.570/3.770us; 256 measured
3527.010/4251.590us vs 8.530/10.160us. Fixed setter sets differ, and neither
scene is bound to a physical output. These numbers motivate the prototype;
they do not constitute a deployed frame-rate claim.

The --pixels probe uses GraphicsCaptureItem::CreateFromVisual to capture only
a test-owned 512x256 visual tree containing both implementations side by side.
Microsoft documents this own-visual capture mechanism at
https://blogs.windows.com/windowsdeveloper/2019/09/16/new-ways-to-do-screen-capture/
and https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscaptureitem.createfromvisual .
No HWND or desktop capture target is created. The test uploads patterned
premultiplied BGRA pixels, compares all channels in both halves with tolerance
1, and requires nonempty pixels to reject an all-empty false pass.

Windows Release build passed after moving SDK includes before main.cpp's
namespace imports and defining INITGUID before those includes. The one-shot
ViewflowPerf-Offscreen task completed result 0 and was unregistered. Pixel
variants: arbitrary crop/partial-patch/alpha (46592 nonzero pixels), one hidden
patch (38912), half scale (11648); all had zero channels exceeding tolerance.
No live receiver binary was replaced, no window shown, and no input injected.
Continuous surface replacement, multiple windows and backdrop-mask equivalence
remain to be covered before moving this representation into production.

## Continuous replacement and backdrop qualification

The own-visual probe now includes a solid backdrop mask and six continuous
surface replacements on the same cached scene. Every replacement changes a
known opaque marker color; the capture must match that new marker as well as
the reference pixels, so stale captured frames cannot satisfy the check.
Both cases passed with zero channels outside tolerance; cached descriptors
were retained throughout all six replacements.

A Gaussian-blurred patterned CompositionBackdropBrush case failed: 419
channels exceeded tolerance 1. A same-location-pattern calibration using the
original per-patch implementation on both halves produced zero differences.
Thus the shared clipped full-atlas background sprite is not yet equivalent
to the existing backdrop path. The native presenter defaults backdrop sigma
to 12, so simply optimizing only an unblurred path would miss normal usage.
Production binding remains unchanged; the prototype must not be deployed.

The probe reports all variants, including the calibration, then returns failure
if any variant failed. Earlier diagnostic calibration temporarily continued
past variant 5; the final harness no longer returns success for a mixed result.
A possible next approach is keeping each backdrop sprite at its original
patch geometry and transforming only its shared alpha source in an effect
graph. Microsoft lists 2D affine transform support among Composition effects:
https://learn.microsoft.com/en-us/windows/apps/develop/composition/composition-effects .
This is a candidate for validation, not an implemented or proven remedy.

## Backdrop-preserving shared-source effect graph

The prototype now keeps backdrop sprites at the original patch size and
destination. It translates the shared atlas alpha inside a 2D affine effect,
then uses SourceIn composition with the backdrop (including Gaussian blur when
requested). The foreground still uses a shared brush with clipped sprites.
Inputs to the prototype are raw backdrop/color brushes plus a blur sigma,
not a precompiled effect brush. Production code remains unchanged.

The first attempt passed a transformed effect brush into MaskBrush.Mask; this
combination is unsupported according to Microsoft's brush-combination table:
https://learn.microsoft.com/en-us/windows/apps/develop/composition/composition-brushes .
The replacement uses a single composite effect graph instead. An intermediate
prototype also exposed a descriptor lifetime error (isolated task status
0xc0000374). Descriptor children now use owned C++/WinRT make_self references
with non-final implementation types, including a test-local blur descriptor.
The local task runner normalizes any nonzero Windows task status to failure
so large exception statuses cannot truncate to an apparent successful exit.

Final Windows Release build passed. The own-visual task completed result 0:
all variants 0-6 reported zero channels outside tolerance 1. In particular the
blurred-pattern variant 5 changed from 419 differing channels to zero, and the
original-vs-original calibration stayed zero. The six continuous replacements
remain part of variant 4 (unblurred); continuous blurred replacement and scene
construction/performance costs still require qualification. The temporary task
was removed. No live binary or production binder was changed.

## Blurred update and construction measurements

The probe now times cold scene construction separately and includes the
default-sized blur effect (sigma 12) in both reference and candidate scenes.
For 195 patches the first run measured reference/candidate construction
32.336/32.285ms and bind median 1698.660/3.560us. For 256 patches candidate
construction was 41.722ms versus reference 29.344ms. These single cold samples
are noisy but contradict a claim that faster setters alone solve layout-change
latency. No production integration follows from these measurements.

The prototype was changed to compile one effect factory per scene with a
dynamic TransformMatrix, creating per-patch brushes from that shared factory.
A subsequent run measured 195-patch construction 25.793/34.531ms and bind median
1685.550/3.540us; 256-patch construction 52.919/42.983ms. Factory reuse did not
establish a construction-time reduction. Object creation/reconstruction needs
further attention, especially when a small layout change rebuilds every node.

The final pixel probe adds variant 7: six continuous blurred replacements with
changing transparent/semitransparent alpha regions. A known opaque marker
changes on every replacement and must be observed before acceptance. All eight
variants passed with zero channels outside tolerance 1 after factory reuse.
This closes the blurred dynamic-alpha test gap, not physical-present or live
HostBackdrop qualification. The Release build and one-shot task succeeded;
the task was unregistered. No live process, window, focus or input was changed.

### Incremental sparse prototype layout updates

The isolated prototype now retains per-patch foreground and background visuals
by exact source rectangle and atlas rectangle, scoped to one scene. It stages
new nodes before changing the active tree, removes missing nodes, inserts new
nodes, and retains surviving nodes when relative ordering is unchanged. A
reorder reattaches existing nodes; an atlas-size change rebuilds nodes so the
full-atlas foreground sprite has the correct dimensions. Hidden nodes are
removed from the cache, so storage is bounded by the current layout.

The Release build and nine own-visual pixel variants passed (zero channels
outside tolerance 1). Variant 8 applies six sequential layout changes while
changing alpha and a known fresh-frame marker: deletion, reinsertion, width
crop, atlas-coordinate change, reordering, and height crop. It also asserts
that the unchanged first node retains identity and that only expected nodes
are created. This extends the existing blurred continuous-surface check.

The repeated layout benchmark alternates N and N-1 patches (40 iterations,
first four excluded). Both paths include layout staging and commit. The
reference rebuilds its layout; the candidate creates at most one node. In this
run, for 195 patches with blur sigma 12, reference/candidate median was
51.507170/0.069330 ms and P95 was 76.824000/2.532400 ms. Without blur, median
was 27.713020/0.054520 ms. This is a mixed add/remove workload, not a worst-case
bound; individual insertions and removals may differ. Raw results are in
`sparse-incremental-layout.log`.

Cold full construction remains expensive (195 blurred patches: reference
23.937 ms, candidate 62.834 ms in this run). No full-rebuild improvement or
physical-present improvement is established. Multi-proxy independence,
atlas resizing, empty-to-visible transitions and live HostBackdrop behavior
still need qualification before production integration. The one-shot task
returned zero and was unregistered. No deployment, focus or input changes.

### Atlas resize and empty layout qualification

Pixel variants 9 and 10 extend the same-scene blurred comparisons. Variant 9
alternates atlas width 512/1024 for six replacements, checks the fresh pixel
marker, and asserts every node is recreated for the changed atlas dimensions.
Variant 10 alternates empty/all four patches, asserting zero/four created
nodes; its empty-state marker is the known underlying stripe color, so a stale
visible frame cannot satisfy the check. Both variants passed, as did all nine
prior variants, with zero channels outside tolerance 1.

The original per-patch stage/commit code is now frozen in
`sparse_visual_reference.h`, and both the pixel and timing probes call this
independent reference. A source comparison confirmed exact equivalence after
identifier normalization. A subsequent Release build and all eleven pixel
variants passed using the frozen reference. Raw evidence is
`sparse-resize-empty-reference.log`; the one-shot task returned zero and was
unregistered. Production binding remains unchanged, with no deployment or
injected input. Integration still requires splitting prototype preparation
from visible commit, plus multi-proxy and HostBackdrop qualification.

### Separate preparation/commit and independent proxy check

The prototype now returns a `SharedSparsePlan` from preparation, retaining new
unbound nodes and references to reused nodes without changing the active tree.
A separate commit applies membership/order and the surface binding. Plans are
scene-specific and intended for serial commit by the presentation loop. The
existing update helper delegates to these two steps for profiling.

Variant 11 captures four panels: old/new implementations of an updating proxy,
and old/new implementations of a second unchanged proxy. Six replacements
change the first proxy's alpha and marker. Before each update, it stages and
discards a changed-width plan, asserting that active surface, child count and
cached last-node identity remain unchanged. It then stages/commits the actual
update and asserts the second proxy's surface is unchanged. Both proxy pairs
compare equal in the captured image (zero channels outside tolerance 1).

Release compilation, all twelve pixel variants, and the layout profile passed;
raw evidence is `sparse-stage-commit-independent.log`. The one-shot task returned
zero and was unregistered. This validates discarded preparation and independent
surface bindings in the isolated own-visual setup. It does not establish live
HostBackdrop behavior, production integration, or physical-present performance.
No live deployment or input/focus change was performed.

### Production binding integration (not deployed)

The shared scene implementation is now `sparse_shared_visuals.h`, included by
`main.cpp`. Production preparation compares the per-proxy patch layout, atlas
size, raw backdrop identity and blur sigma. Unchanged frames bypass map/node
construction and commit one Surface assignment. Changed layouts prepare a
shared visual plan; configuration changes prepare a replacement unbound scene.
Commit attaches/applies the candidate and updates scaling. Dense-surface commit
clears the shared sparse state. Each proxy retains its own raw HostBackdrop
brush, while the dense path keeps its existing blurred mask source.

All twelve pixel variants now drive the actual production stage/commit entry
points on the candidate side, against the frozen independent reference. The
Release presenter, bind probe and sparse GPU test executable all compiled.
The own-visual pixel suite passed with zero channels outside tolerance 1. The
manual HWND GPU test was compiled, not run in this iteration.

The final timing probe also calls production stage/commit on the candidate
side. At 195 patches with sigma 12, unchanged-layout binding median was
1714.730 us (reference) versus 3.630 us (candidate), with staging medians
4.000/3.240 us. Alternating 195/194-patch layout updates measured median
54.143900/0.049730 ms and P95 77.001420/0.937990 ms. These are isolated host
costs, not physical presentation results. Full construction remains variable:
256 blurred patches took 42.207/63.820 ms in this run.

Raw results are `sparse-production-integration.log`. The one-shot task returned
zero and was removed. No current desktop executable was replaced. Actual
HostBackdrop sampling, dense/sparse transitions, configuration changes and
end-to-end behavior still need validation before deployment. This integration
adds no input, authorization, focus or timing restrictions.

### Configuration and dense/sparse transition checks

Variants 12 and 13 extend the production-entry pixel comparison. Configuration
updates change sigma 8 to 4, replace the raw backdrop brush, use sigma 0,
disable the backdrop, restore it at sigma 12, then exercise unchanged reuse.
The reference is explicitly rebuilt after configuration changes because its
frozen cache did not track backdrop configuration. The first attempt failed
with E_INVALIDARG when the reference used a raw backdrop directly as a mask
source; wrapping the zero-sigma reference in its usual blur effect resolved the
failure. The candidate implementation was unchanged by that correction.

The mode test alternates three dense and three sparse frames, checks fresh
markers and pixel equivalence, and asserts that dense commit clears sparse
scene/patch/root/child state. The test accesses the current optional scene on
each check, avoiding a dangling reference across replacement or dense reset.
All fourteen variants passed with zero channels outside tolerance 1. All three
Release targets compiled, the one-shot task returned zero and was removed.
Raw evidence: `sparse-mode-config-transitions.log`. No deployment or input/focus
change occurred.

A remaining workload gap is confirmed in `sparse_atlas_plan.hpp`: atlas x/y are
assigned from the current draw index (lines 147-150). Removing an early draw can
therefore shift many later atlas coordinates. The existing alternating N/N-1
benchmark removes the last patch and does not model this repacking cost. The
current scene cache key includes atlas x/y, so representative repacking must be
measured and addressed before claiming efficient general layout changes.

### Retarget retained nodes during atlas repacking

The new benchmark alternates deletion/reinsertion of the first source patch
and recomputes all atlas coordinates, matching the source packer's index-based
placement. Before the retargeting change, the 195-patch blurred candidate
created up to 195 nodes per update, with median 61.673210 ms and P95
98.649880 ms; the original reference measured median 50.958410 ms in that run.
This exposed a regression missed by the last-patch-only workload. Raw evidence
is `sparse-repack-before.log` (reference max_created was not instrumented in
this initial log; its zero is not a claim of zero object creation).

Scene cache keys now contain only the source rectangle. Retained nodes keep
foreground sprite and effect-brush handles plus atlas-coordinate metadata.
Preparation changes candidate metadata only; commit updates sprite offsets,
mask transforms, and atlas sprite size when required. Atlas resizing retains
nodes instead of reconstructing them. Source rectangle changes still create
new nodes; hidden nodes are removed, keeping storage bounded by active layout.

All fifteen production-entry pixel variants passed against the independent
reference. The resize variant now samples x=768 on the expanded atlas and
asserts zero new nodes. A discarded coordinate-update plan is checked for no
visible offset mutation. New variant 14 alternates patch removal/restoration
and repacking for six fresh-marker/alpha frames, asserts at most one created
node and nonzero retargeting, and retains the first node's identity. Captured
pixels have zero channels outside tolerance 1. All three Release targets
compiled. Raw evidence is `sparse-repack-after-pixels.log`; reference creation
counts in this intermediate log are also uninstrumented zeros.

In that post-change run, 195 blurred patches required at most one new node and
194 retargets. Repacking median was 1.644100 ms and P95 3.801520 ms; the
independent reference measured 56.170650/77.265490 ms. Cold full construction
remains expensive (candidate 52.892 ms in this sample). These are isolated
host measurements, not physical-present or end-to-end latency. No deployment,
input injection or focus change was performed.

The benchmark now also counts reference node creation explicitly. A build and
benchmark-only rerun confirmed reference/candidate max_created of 195/1 and
candidate max_retargeted of 194. For 195 blurred patches, repacking median was
52.507800/1.548380 ms and P95 71.558260/3.566780 ms. Raw results are
`sparse-repack-final-benchmark.log`. Both post-change runs support the repacking
improvement; the last run changed only reference count instrumentation, not
the production implementation or pixel probe. All one-shot tasks were removed.

### Rejected foreground-container flattening experiment

A flat foreground sprite with translated InsetClip passed all fifteen pixel
variants, including alpha, blur, retargeting, resize and mode changes. However,
paired alternating-order measurements showed a workload tradeoff rather than
a stable win: at 195 blurred patches, cold median 41.281/37.676 ms accompanied
repack median 1.850/3.725 ms and worse cold P95. The flat path adds a clip-offset
setter to every retarget. Production has been restored to the prior container
implementation, byte-identical to its pre-experiment header snapshot.

The rejected implementation, harness and reproduction notes are archived under
`flatten-experiment/`; results are `sparse-flat-pixels.log` and
`sparse-flat-paired-benchmark.log`. Both experiment tasks returned zero and
were removed. No live executable, focus or input state was changed. Cold
construction remains an open cost; reducing visual count alone did not resolve
it without a measured regression elsewhere.

After restoration, the Release presenter, bind probe and manual GPU test target
all compiled successfully. This restoration check compiled only; it did not
launch another task or repeat unchanged pixel tests.

### Physical HostBackdrop qualification

Added `viewflow_sparse_host_backdrop_test`, a Windows GUI-subsystem probe that
runs without a console. It owns one patterned background window and three
separate 256x256 comparison windows: frozen reference, production candidate,
and unblurred control. All are nonactivating tool windows; no input injection,
focus-setting, or existing remote-process changes are performed. The probe
selects native per-monitor-DPI coordinates, preferring a display other than
the one containing the foreground window. This avoids reusing the managed
screen-listing coordinates queried during initial inspection.

The first design placed panels inside one larger HostBackdrop window. It
failed on stripes with 71,168 channels outside tolerance, but an independent
old-versus-old calibration produced exactly the same failure. That comparison
was therefore not a valid implementation oracle (`host-backdrop-first.log`
and `host-backdrop-first-calibration.log`). The final design gives each panel
an equal host window and separates windows by 256 pixels over a padded owned
background, matching their window-relative boundary conditions. No production
rendering change was needed to resolve this test-design issue.

The final GUI probe passed both calibration and production comparisons in
four phases: two different uniform backgrounds, stripes, and sparse repacking.
Every phase reported zero RGB channels outside tolerance 2 and unchanged
foreground identity. Fresh opaque markers and known control colors ensure
that stale or unrelated screen pixels cannot pass. At alpha 128, the residual
`2 * reference_color_change - control_color_change` reached 80, ruling out a
constant/black HostBackdrop response; stripes differed from the unblurred
control in 110,592 channels by more than 5. Thus equality was checked against
an active background effect, not just equal empty output.

Logs: `host-backdrop-gui-calibration.log`,
`host-backdrop-gui-production.log`; a preceding console-coordinated matching
host run is in `host-backdrop-separated-hosts.log`. The GUI executable is
launched directly by its one-shot task. It writes `host-backdrop-result.log`
in its working directory; `--calibrate` substitutes the frozen reference on
the candidate side. It is intentionally not registered as an automatic CTest.

Both GUI runs returned zero. Final read-only cleanup verification reported
zero host-test processes and zero ViewflowPerf tasks (`host-backdrop-cleanup.log`).
No live receiver/source executable was replaced. This establishes sampled
physical HostBackdrop equivalence in the current Windows environment, not
end-to-end stream latency, sustained load, or real drag recovery.

### Isolated dual-end media run and buffered native receipts

A real Linux capture → NVENC H.264 → authenticated QUIC → Windows hardware
decode → sparse Windows Composition pipeline was run against a separate
receiver checkout. The source was an already-open animated browser window,
2566 × 1492 physical pixels, packed into a 2688 × 1536 canvas with 240 patches.
This is not the requested full 3840 × 2400 desktop workload. The current
installed source and receiver were not replaced. Both endpoints had pointer
and desktop input disabled; no input or focus commands were issued.

`tools/windows_isolated_media_run.cpp` provides a GUI-subsystem launcher with
no console window. It owns only the isolated receiver process tree in a private
kill-on-close job, redirects logs to files, and has a 90-second operation
watchdog. This test duration is independent of the frame performance target.
The receiver task is removed after completion. Each source run used a bounded
25-second timeout; its exit 124 is the requested stop. Receiver exit 1 reports
peer closure or clock expiry during teardown, not a successful application exit.
All runners reported `watchdog=0`. The last unbuffered run exceeded the helper's
initial cleanup polling window and subsequently exited with a clock timeout;
final inspection confirmed no owned processes before deleting its task. This
teardown delay remains a separate finding, not evidence of prompt shutdown.

The first discovery run unintentionally used the default clipboard lane.
Code inspection shows startup only establishes a baseline and subsequent
clipboard changes may synchronize. Logs do not establish whether any clipboard
content changed; no contents were inspected. Every following A/B run explicitly
set `VIEWFLOW_CLIPBOARD=0` at both endpoints using the existing opt-out.
Credentials and configs containing private-key paths are not included here.

The discovery run showed 13.33 ms median receiver receipt wait but only 2.97 ms
median native admission-to-commit (sample counts 33 and 15 respectively).
`read_line_bounded` read each byte from an unbuffered `ChildStdout` when pointer
events were disabled. On Windows this can schedule a blocking pipe read per
byte. `AtlasPresenterPipe` now retains a 4096-byte `BufReader` across readiness,
recovery, and frame receipts. Line limits and exact receipt checks are unchanged;
read-ahead is retained for the next transaction. The normal input-enabled
stdout demultiplexer already had its own buffer, so this finding does **not**
establish the same gain for normal interactive sessions.

The comparison order was unbuffered, buffered, buffered repeat, unbuffered
repeat. Before the repeat pair the baseline was rebuilt from the exact same
isolated source snapshot, changing only the reader storage/constructor back
to unbuffered operation; the buffered binary was preserved and restored.
Both variants used the same native renderer and unchanged Linux sender.
`integrated-media/build-provenance.json` records the binary/source hashes.

All numbers below are sampled diagnostics excluding frame IDs below 30.
They are microseconds, not physical display latency. Each cell is median / p95;
counts are shown because these are small samples from short shared-machine runs.

| Variant | Receiver receipt wait (n) | Sender feedback wait (n) | Native admission to commit (n) |
| --- | --- | --- | --- |
| Unbuffered | 12604 / 69462 (34) | 17683.5 / 75589 (34) | 3173 / 3886 (16) |
| Buffered | 5127.5 / 10275 (40) | 10109 / 27269 (40) | 3083 / 7705 (19) |
| Buffered repeat | 4780 / 6740 (43) | 9260 / 13825 (43) | 2647 / 4005 (22) |
| Unbuffered repeat, controlled rebuild | 13300.5 / 17175 (40) | 18785 / 29546 (40) | 3305.5 / 4678 (20) |

The controlled repeat reduced receiver receipt-wait median by about 64% and
sender feedback-wait median by about 51%. Native processing changed much less;
this localizes most of the gain to receipt delivery. The measurements do not
isolate every OS scheduling or pipe-parsing cost and do not establish stable
physical FPS. Committed frames beyond their 33 ms targets were followed by
later commits; the source remained active until the planned stop. Cold start
and occasional long-tail stalls remain, and the runs do not test user dragging,
keyboard routing, multiple windows, or full-desktop load.

Validation: 478 Linux `viewflowd` library tests passed, including a new counted
reader test proving readiness and a following line share one underlying read
without losing read-ahead. Windows release builds and both real media variants
ran successfully through planned source stop, with the teardown caveat above.
`integrated-media/` contains source/receiver logs, runner outcomes, cleanup
results, sampled summaries, and the test log. Recompute a summary using:

```sh
python3 tools/summarize_atlas_timings.py \
  docs/evidence/performance-20260907/integrated-media/source-buffered-repeat.log \
  docs/evidence/performance-20260907/integrated-media/receiver-buffered-repeat.log
```

This completes the first isolated real-codec dual-end qualification and fixes
an actual noninteractive receiver bottleneck. It does not complete the overall
performance goal or authorize replacing the known-working desktop deployment.

### Updated acceptance target

The user clarified the goal: stable 60 FPS at 4K, with no more than two frames
of end-to-end latency. At 60 FPS this is 33.33 ms. Continue using the previously
specified 3840 × 2400 workload; the smaller isolated browser runs above do not
qualify this resolution. Receipt throughput, native visual submission counts,
and individual stage timings are diagnostic evidence, not substitutes for
actual presentation cadence and full end-to-end latency. Performance misses
must be measured while retaining the session, per the project availability
policy. Physical presentation measurement and the required resolution/load
qualification remain outstanding.

### 4K motion qualification: eliminate hidden backdrop work

The updated user goal explicitly permits mouse/keyboard injection. The runs
below still use input-disabled media; interactive latency remains outstanding.
`platform/linux-frame-fixture` now supplies an owned, NVIDIA GLES-rendered
3840 × 2400 moving pattern on the existing 60 Hz headless output. A precise
producer timer generated approximately 60 swaps per second. Its frame and input
markers support future presentation observation; swaps are not physical receipts.
The capture includes normal bounds outside the content: 3848 × 2408, packed as
589 patches in a 3968 × 2432 canvas. No installed desktop program was replaced.
During the final run, process inspection found only the isolated media receiver
and its isolated native presenter, not another concurrent native receiver.

The first full-resolution run produced only 362 native submissions in 25 seconds.
Sampling every 30 frames misleadingly showed approximately 11 ms encode and
14 ms feedback waits. An explicit `VIEWFLOW_ATLAS_TIMINGS=all` mode now logs every
frame on both endpoints. It exposed recurrent 400–900 ms receipt waits, with the
native diagnostic watchdog locating stalls inside Windows message processing.
A temporary blur-disabled diagnostic eliminated most of those waits, pointing
to the cost of per-patch background effects. That diagnostic is not the product
fix and is not used as acceptance evidence for normal effects.

The renderer now classifies each patch using its exact decoded alpha plane,
including a two-pixel sampling halo. Only fully opaque patches elide the
background effect hidden behind their foreground pixels. Missing alpha and
atlas edges remain conservative. Classification stays with the immutable
frame binding, independent of later alpha/layout changes. Scene cache identity
includes the classification, so an opaque-to-transparent transition restores
its background; the reverse transition removes it. The alpha scan checks
unaligned 64-bit blocks without zero-copy aliasing assumptions or loss of the
254-versus-255 distinction. No wire format, codec quality, input routing,
performance cutoff, or ordinary session behavior was changed by this fix.

The owned-visual GPU oracle passed 24 phases against the frozen rendering
reference: opaque / half-transparent / opaque / hole transitions, scales 1,
0.75, and 0.5, and offsets 0 and 0.25 pixels. Every phase had zero RGB channels
outside tolerance 2 and a fresh expected foreground marker. It also verified
that the corresponding effect nodes were actually removed/restored. Tests
cover alpha sampling halos, missing/invalid dimensions, unaligned word/tail
reads and every non-255 byte value, plus delayed decoder output retaining its
own frame's opacity classification. Native Windows builds and these CPU tests
passed; the classifier/binding tests also passed with Linux GCC. The pure
word-scan refinement retains the classifier behavior tested by the GPU oracle.

Observed 25-second runs (shared machines, includes startup):

| Configuration | Native submissions | Receipt-wait median / p95, ms, frame >=30 | Receipt waits >50 ms, all frames |
| --- | ---: | --- | ---: |
| Normal blur, before elision | 309 | 9.003 / 535.960 (287 samples) | 36 |
| Blur disabled, diagnostic only | 1358 | 8.607 / 15.576 (1336 samples) | 2 |
| Normal blur, opacity elision | 1105 | 11.211 / 18.471 (1085 samples) | 12 |
| Normal blur, elision with word scan | 1173 | 9.676 / 17.468 (1151 samples) | 13 |

This is an observed approximately 3.8× increase in native submission throughput,
not a claim of 60 physical FPS. Cold startup and occasional stalls remain. The
last diagnostic used the existing `VIEWFLOW_GPU_TIMINGS=1`; twenty steady-state
samples split native encoding into median import 0.898 ms, preparation 2.119 ms,
NV12/alpha readback 2.007 ms, and NVENC 4.215 ms (total 9.206 ms), before Rust
output adaptation. These identify subsequent work rather than proving the
33.33 ms end-to-end target.

Logs and the pixel oracle are in `4k-motion/`. All valid media sources stopped
at the planned 25-second timeout, receiver runners reported watchdog=0, and
owned receiver tasks/processes were cleared. Fixtures were stopped only after
their media run ended. One earlier exact-dimension probe was rejected because
of capture decorations; its accidentally started small-window trial was stopped
and excluded from every 4K result. The temporary fixture placement rule was
disabled after the final run. No injected-input result or physical presentation
latency result is claimed here. The goal remains active.

### Desktop frame witness and output-copy initialization

The source's Rust output adapter reserved and zero-filled each raw alpha plane
before the native C ABI immediately overwrote it with `memcpy`. At the tested
3968x2432 atlas size this is 9,650,176 redundant byte writes per frame. The
adapter now reserves storage, calls the existing complete-copy operation, and
sets Vec length only after success plus the exact returned byte count. The
failure path retains length zero. Audited native `copy_plane` performs the
complete copy before returning success. The feature-enabled release source
build and all five `gpu_nvenc_runtime` tests, including the opt-in owned-buffer
CUDA/NVENC integration test, passed.

The first 25-second pair used a frozen pre-change source binary against the
same receiver: encoding median 11.616 -> 10.892 ms (frame >=30), with native
submissions 1227 -> 1251. These shared-host samples support a small reduction
in encoding work, not achievement of 60 FPS. One run's process-exit polling
window elapsed; a subsequent authoritative process/task check confirmed the
receiver had exited with watchdog=0, then collected logs and removed its task.
It was not restarted on the observation timeout.

Added `tools/windows_frame_observer.cpp` and its manual CMake target, plus
`tools/summarize_desktop_markers.py`. The observer matches the exact owned
preview PID, samples only the fixture marker scanline, checks all marker bits,
and records changing frame IDs at DXGI desktop-present QPC timestamps. It does
not save screenshots or inject input. Source/native submission counts are
explicitly separate from this witness; even this witness is not panel photon
measurement and has capture overhead.

| 20-second desktop observation | Changing IDs | Observed changes/s | Change-gap median / p95, ms |
| --- | ---: | ---: | --- |
| Normal blur, opacity elision, run A | 186 | 9.54 | 87.30 / 182.34 |
| Normal blur, opacity elision, run B | 184 | 9.37 | 85.84 / 196.44 |
| Blur disabled, diagnostic only | 695 | 35.12 | 26.48 / 45.74 |

The normal-blur run B had median successful acquisition 19.337 ms and scanline
copy/map 17.562 ms. Its acquired frames each reported AccumulatedFrames=1, and
all validated IDs and present timestamps increased. This is strong evidence
that the earlier approximately 50 native submissions/s cannot serve as proof
of display rate. The blur-disabled comparison implicates remaining backdrop
composition work, but does not quantify the observer's contribution or qualify
an unobserved physical panel at 60 FPS. Normal production blur remains enabled;
the no-blur launcher is a separate isolated diagnostic executable.

The active interactive session enumerated only a 6144x3456, 60 Hz monitor. DXGI
reported Intel hardware adapter vendor=32902, device=32103, software=0. WMI also
listed a 3840x2400 Intel controller mode, but the observer found no corresponding
active monitor. The attempted optional 4K placement returned `no_4k_monitor`
(exit 14), without moving any window; that run is not a valid desktop-rate
sample. The source content was verified at 3840x2400, captured as 3848x2408,
throughout. Logs, exact monitor diagnostics, cleanup evidence and desktop JSON
summaries are under `4k-motion/`. End-to-end input latency remains unmeasured.

### Adjacent sparse-patch union: preserving blur with fewer nodes

The full-window fixture carried 589 wire patches. Exact alpha classification
removed 493 backdrops, but the other 96 still covered 1,188,672 pixels and each
owned a separate blur/mask operation. The presentation path now combines
adjacent, nonoverlapping rectangles only when their source-to-atlas translation,
tile identity and backdrop disposition agree. Source overlap retains the
original painter order without union. A sweep and two sorted union passes keep
this helper O(n log n); the unchanged-layout/opacity fast path reuses the prior
scene without recomputing unions. Wire layouts, frame lineage and input geometry
retain the original patch list.

At full 4K this produces **5 nodes, including 4 backdrops**, instead of 589/96.
The CPU tests compare exact per-pixel source/atlas/opacity coverage across 200
randomized arrangements and a 32,768-patch grid, plus overlap fallback, holes,
invalid count and overflowing bounds. They pass with Linux GCC and Windows
MSVC. The GPU comparison uses 64 contiguous patches, a varying color field and
freshness marker, opaque/partial-alpha/hole/repacked states, three scales and
fractional offsets: all 30 phases had zero channel mismatches above tolerance 2.
The real HostBackdrop comparison also passed four phases, including changed
backgrounds and repacking; the blurred result differed from its unblurred
control in 110,592 channels. Logs are `coalesce-pixels.log` and
`coalesce-host-backdrop.log`. The later sweep refactor changed only overlap
validation, retaining the same unions; the CPU coverage checks passed again.

The Windows display topology changed during this work. Subsequent live monitor
enumeration showed the 3840x2400 primary display plus the 6144x3456 virtual
secondary. The observer now handles DXGI output rotation; the actual 4K output
reported rotation 180 degrees. It validated all changing marker IDs after that
mapping. Optional `physical4k` placement aligns the four-pixel capture border at
(-4,-4), placing the full 3840x2400 fixture content on the 4K display, without
focus, size or z-order changes. The earlier unsupported-rotation run is excluded
from frame-rate results.

A same-binary comparison used normal sigma-12 blur throughout. Only the isolated
baseline launcher sets `VIEWFLOW_ATLAS_DIAGNOSTIC_NO_COALESCE=1`; ordinary runs
use the union. Both variants ran on the same enumerated 4K output and placement:

| Configuration | Changing desktop IDs | Observed changes/s | Median / p95 change gap, ms |
| --- | ---: | ---: | --- |
| Union enabled, A | 793 | 40.03 | 20.75 / 48.33 |
| Union disabled | 164 | 8.32 | 114.41 / 186.14 |
| Union enabled, B | 780 | 39.37 | 21.77 / 47.08 |

The current evidence supports a large improvement in observed desktop updates,
while still failing the 60 FPS objective. Desktop duplication overhead remains
part of these tests. The second source-output-copy pair also retained lower
encoding median (11.422 -> 10.972 ms), with native counts 1133 -> 1165; it is a
smaller source improvement, not the explanation for the desktop union result.

### Clock-aligned latency and the remaining post-mutation delay

Source diagnostics now expose the existing minimum-RTT paired clock estimate
and uncertainty without changing calibration. The receiver's media clock is
**connection-relative**, so it must not be compared directly with raw desktop
QPC. `atlas-receiver-clock-anchor` brackets a QPC sample with two receiver-clock
samples. The summarizer requires that anchor, the source clock log and the
matching fixture producer log together, rejects expired/missing mappings, and
reports bounds under the existing clock-estimate model. It does not claim
input-to-photon timing or panel scanout measurement.

In `4k-physical-latency-b`, all 754 desktop markers matched a fixture render and
valid clock estimate. Pre-draw to desktop latency had median bounds
79.109–79.340 ms and p95 bounds 96.140–96.418 ms. Median clock uncertainty was
0.109 ms and the receiver anchor interval was 12.030 microseconds. Every sample
was definitely above 33.33 ms under this clock model. `latency-a` had no receiver
anchor and is excluded from latency analysis, though its desktop count is valid.

An additional opt-in `VIEWFLOW_GPU_FIXTURE_MARKER=1` witness samples the retained
3848x2408 source tile before atlas packing/encoding. It reads the known marker
row, checks the marker, and logs its atlas-frame ID and original capture time.
It is off in normal use. The first stage run read 1283 valid markers, with
median/p95 readback cost 23/34 microseconds. Repeated producer IDs are ambiguous
and excluded from the exact capture-stage join, rather than assigned to a
convenient frame. Native `VIEWFLOW_ATLAS_TIMINGS=all` additionally logs the CPU
visual-mutation timestamp; this is explicitly not a compositor/panel receipt.

`4k-physical-latency-mutation` yielded 460 unambiguous observed frames (190
repeated-marker observations excluded; no missing native mutation or negative
mutation-to-desktop intervals):

| Segment | Median, ms | P95, ms |
| --- | --- | --- |
| Fixture pre-draw -> capture | 16.744 | 17.540 |
| Capture -> native CPU visual mutation, clock bounds | 32.542–32.756 | 45.590–45.964 |
| Native CPU visual mutation -> desktop update | 39.194 | 56.180 |
| Capture -> desktop update, clock bounds | 72.465–72.720 | 94.163–94.536 |

These are distributions of matched frames; marginal medians must not be added
to reconstruct another distribution. They identify substantial work/wait after
CPU mutation, in addition to the capture/encode/receive cost. The next experiment
should distinguish GPU execution from composition submission scheduling.
All logs and JSON summaries are in `4k-motion/`. The 60 FPS / two-frame latency
goal remains unfulfilled, and no installed daily-use executable was replaced.

### Explicit compositor commit experiment (rejected)

An isolated opt-in `CompositorController` experiment tested whether explicitly
committing each completed frame removes the post-mutation delay. The initial
CommitNeeded event integration crashed during initialization in two trials
(`4k-physical-explicit-a/b`); these produced no usable performance result.
Removing the event registration allowed the bounded video trial
`4k-physical-explicit-c` to complete with observer exit 0 and no owned processes
remaining. Its 676 desktop changes over 19.680 seconds yielded 34.30 changes/s.
For 578 unambiguous capture-marker matches, capture-to-desktop median was
72.202–72.441 ms (clock bounds), capture-to-CPU-mutation was 33.440–33.744 ms,
and CPU-mutation-to-desktop was 39.648 ms (P95 55.897 ms). No missing mutation
records or negative intervals occurred; 98 repeated-marker matches were excluded.

These measurements do not show a material improvement over the prior ordinary
compositor result (72.465–72.720 ms capture-to-desktop, 39.194 ms after mutation).
They are separate runs, not a controlled statistical equivalence proof. The
experimental controller code was removed and the qualified ordinary compositor
source restored. Installed daily-use binaries were never changed. This result
does not distinguish GPU execution delay from compositor queueing; it provides
no input-to-photon or 60 FPS qualification. Logs and the computed summary are
in `4k-motion/*4k-physical-explicit-*`.

### Nonblocking GPU completion bounds

With `VIEWFLOW_ATLAS_TIMINGS=all`, the native copy path now inserts an event
query after EndDraw and before the already existing Flush. The message loop
polls GetData with DONOTFLUSH, never waits, and retains at most 64 probes. A
query failure is diagnostic only. The preceding unsuccessful poll and first
successful poll bound completion on the application's D3D queue; neither is
an exact GPU timestamp or DWM receipt. Normal runs do not create queries.

The display topology changed to a sole 6144x3456 virtual monitor. Accordingly
`4k-physical-gpu-completion-a` exited the observer with `no_4k_monitor`/14 and
is excluded from desktop metrics. After that trial fully exited,
`4k-virtual-gpu-completion-a` measured the same 3848x2408 source fixture on
the available virtual desktop without changing monitor settings. Observer
exit was 0: 675 changes over 19.743 seconds, 34.139 observed changes/s.

568 unambiguous marker matches had valid, unique GPU completion records
(107 repeated capture markers excluded, zero missing/invalid probes). Median
submitted-to-GPU-completion lower/upper bounds were 7.741/16.103 ms. Median
GPU-completion-to-desktop lower/upper bounds were 18.760/28.601 ms; 539 of 568
queries were observed complete before the matching desktop timestamp. The
other 29 were polled too late to establish a positive lower bound, not proof
of negative physical latency. Capture-to-desktop clock bounds had medians
65.776–66.062 ms, with CPU-mutation-to-desktop median 34.812 ms. These bounds
show material work before GPU completion and material delay afterward.
Different topology prevents a controlled comparison with earlier physical
monitor trials. No 60 FPS or input-to-photon qualification is implied.

Native MSVC build and three CPU tests passed; the analysis script passed
known-QPC interval checks against 460 recorded marker joins, including the
missing-probe case. Both trials terminated with zero owned processes and
removed their tasks. Logs and summary use the labels above in `4k-motion`.

### Negotiated unchanged-alpha references

Implemented the optional Atlas V3 capability described in
[atlas-alpha-reference.md](../../atlas-alpha-reference.md). It replaces a
byte-identical, independently encoded VFAR alpha plane with an 84-byte reference
to an acknowledged full baseline. Changed alpha and color keyframes remain full.
The receiver expands references before native handoff; no native decoder or
pixel composition changes are involved. Full and expanded byte limits still
apply. References preserve the current frame identity and source timestamp.

Linux session tests passed 31/31. Native Windows session tests passed 30 with
one existing interactive native warmup test ignored. Separate real interactive
trials below did complete warmup and display animation. The new round-trip test
checks baseline retention across two references, changed alpha followed by
ExpiredUnbound, independent full keyframe recovery, subsequent reuse, exact
expanded payload bytes, and current timestamps. Existing reference tests cover
every modified key byte and incompatible lineage. The fixture used 3848x2408
captured pixels on the currently available 6144x3456 virtual desktop, normal
blur 12, coalescing, and the same GPU/desktop timing diagnostics throughout.

| Trial | Compatibility / mode | Median packets | Feedback median ms | Capture-to-CPU-mutation upper median ms | Capture-to-desktop upper median / P95 ms | Observed desktop changes/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| old-receiver | New source / frozen old receiver; full VFAR | 133 | 15.654 | 31.638 | 66.496 / 83.292 | 35.03 |
| old-source | Frozen old source / new receiver; full VFAR | 133 | 15.741 | 31.724 | 66.810 / 89.397 | 34.35 |
| new-a | New source / new receiver; negotiated references | 23 | 13.065 | 28.593 | 64.377 / 82.834 | 34.91 |
| old-source-b | Repeated full VFAR baseline | 133 | 15.636 | 31.741 | 67.555 / 91.125 | 33.59 |
| new-b | Repeated negotiated references | 23 | 13.038 | 27.434 | 63.509 / 81.764 | 37.96 |

Trial labels above have prefix `4k-alpha-reference-`. The first mixed-version
trial had 1,057 completed wire records, all explicitly `alpha_referenced=false`.
The new/new trials used references for 1,176/1,202 and 1,219/1,248 completed
records. Median wire bytes fell from 180,164 in the new-source/old-receiver
trial to 29,625 and 29,497: about 84% less for this mostly unchanged-alpha
fixture. Encoded full-pair bytes remain logged separately from wire bytes.
This is lossless alpha reuse; color encoding quality is unchanged. Other
workloads with continually changing alpha will send more full payloads.

The two paired repetitions support a modest latency improvement, not a 60 FPS
claim. These are finite desktop-duplication observations with observer overhead,
not input-to-photon measurements or a physical 4K monitor qualification. All
five observers exited 0, receivers had watchdog=0, and each owned test task and
process was removed after its trial. Installed daily-use binaries were not
changed. Source/receiver/producer/desktop logs and computed summaries are in
`4k-motion`; the archived summary adds per-trial wire distributions.

### Reusable pinned alpha readback staging

The CUDA encoder now owns one fixed-size pinned host alpha buffer, allocated
once per encoder. The completed download is copied into the ordinary owned
output vector without first zero-initializing that vector. Every frame still
reads its complete current alpha plane; no alpha-change inference or ABI
change is involved. The destination remains alive until stream completion,
and teardown synchronizes before releasing it. Allocation failure retains the
original pageable-vector readback path. `VIEWFLOW_GPU_PINNED_ALPHA=0` selects
that baseline for diagnostics; pinned staging is otherwise enabled by default
(or explicitly with value `1`). Persistent pinned memory is one byte per coded
pixel (9,650,176 bytes for the measured atlas canvas), released with the encoder.

The native integration oracle passed with pinned staging, including alpha,
color/GOP, fence/expiry recovery, atlas holes and C ABI output checks. The sparse
encoder oracle also passed. A test-build-only injected pinned allocation failure
(`VIEWFLOW_TEST_PINNED_ALPHA_ALLOC_FAIL=1`, gated by VIEWFLOW_TEST_GPU_EXPIRY)
logged `pinned=0` and passed the same integration oracle. This failure injection
is absent from the release library. The final release build passed and a final
trial verified default activation with no pinning environment override.

All trials below used the previous negotiated alpha-reference optimization,
normal blur, 3848x2408 captured fixture, and the available 6K virtual desktop.
GPU host-stage medians exclude the three warmup frame samples. They include
NV12 preparation and required synchronization, not solely PCIe transfer time.

| Trial | Readback stage median us | Source encode median us | Desktop changes/s | Capture-to-desktop upper median ms |
| --- | ---: | ---: | ---: | ---: |
| 4k-pinned-alpha-a | 1691.5 | 11532 | 36.766 | 63.186 |
| 4k-pageable-alpha-a | 2934 | 13298 | 34.111 | 63.426 |
| 4k-pinned-alpha-b | 1534 | 11374 | 37.978 | 63.471 |
| 4k-pinned-alpha-default | 1757 | 12284 | 35.974 | 63.402 |

The first pinned trial overlapped native test compilation and is exploratory;
the pageable comparison, repeated pinned run, and final default run did not
run GPU tests concurrently. The readback improvement did not materially lower
the approximately 63 ms desktop latency in these runs. Further receiver-side
composition work is required; 60 FPS and two-frame input latency remain unproven.
All observers exited 0, receiver watchdogs stayed 0, and owned processes/tasks
were cleared. Installed daily-use binaries remain unchanged. Logs, summaries,
and pinned/default/fallback native oracle logs are archived in `4k-motion`.

### Rejected shared backdrop brush experiments

Two native brush arrangements were tested against the retained original
per-patch effect graph. The first used one shared Gaussian blur EffectBrush
with separate MaskBrush/SurfaceBrush instances per translucent region. The
second shared the complete MaskBrush, drawing full-atlas-sized background
visuals clipped to each patch. These use supported MaskBrush.Source inputs;
EffectBrush-to-EffectBrush source binding is not supported by the Composition
brush combination contract.

Both arrangements passed the expanded 42-phase pixel oracle and four real
desktop HostBackdrop phases: zero channels beyond the comparison tolerance,
background response 80, and 110,592 channels different from the unblurred
control. The new oracle cases include four separated translucent regions and
128-to-192 alpha changes with unchanged patch/opacity classification, exercising
surface rebinding on the reuse path. The expanded oracle is retained.

| Trial | Graph | Desktop changes/s | Capture-to-desktop upper median ms |
| --- | --- | ---: | ---: |
| 4k-shared-blur-a | Shared blur, separate masks | 37.186 | 63.584 |
| 4k-unshared-blur-a | Original graph, same binary | 39.377 | 63.677 |
| 4k-shared-blur-b | Repeated shared blur | 34.258 | 63.692 |
| 4k-shared-global-mask-a | Shared complete mask, atlas-sized clipped visuals | 19.356 | 71.896 |

The first variation showed no useful latency improvement; the second materially
regressed throughput. Sharing brush objects therefore did not establish less
GPU work, and increasing the background visual bounds was counterproductive
in this test. Both experimental graph implementations and their native timing
flag were removed; the qualified original main/header sources were restored
and rebuilt. The Windows build and three CPU tests passed after restoration.
The source alpha-reference and pinned-readback improvements remain in place.
Installed daily-use binaries were never changed.

All four trials used the same 3848x2408 captured source on the available 6K
virtual desktop, blur sigma 12, and the same observers. Observer exit codes were
0, receiver watchdogs were 0, and owned processes/tasks were cleaned up. Logs
and summaries are archived under the trial labels in `4k-motion`, together with
`shared-blur-pixels.log`, `shared-blur-host.log`, and `global-mask-*.log`.
An initial outdated HostBackdrop launcher returned 2 because shell redirection
conflicted with the GUI program opening its own log; it supplied no pixel result.
The corrected launcher executes the GUI test directly and completed the four
phases. These results do not establish 60 FPS or two-frame input latency.

The restored original graph also passed all 42 pixel phases (exit 0); see `4k-motion/restored-coalesce-42.log`.


### Atlas native host-stage attribution and observer contrast

The asynchronous MTA submission now carries its existing `SubmitHostDurations`
value with the completed frames. With `VIEWFLOW_ATLAS_TIMINGS=all`, the STA
buffers an `atlas-native-host-us` record. It does not invoke a second MTA job,
wait for GPU completion, or change admission/recovery. Normal logging is off.
Windows MSVC rebuilt the native presenter and all three existing CPU checks
passed. Two isolated 25-second source runs used the existing 3848x2408 fixture,
blur 12, alpha wire references, pinned alpha staging, and the unchanged 6K
virtual Windows desktop. Neither run injected input or changed focus.

| Trial | Live submissions | CPU Submit median / P95 ms | Resource preparation median ms | Native mutations/s |
| --- | ---: | ---: | ---: | ---: |
| 4k-native-host-stages-a, observer on | 1195 | 2.847 / 5.129 | 0.753 | 49.49 |
| 4k-native-host-stages-no-observer | 1339 | 2.570 / 4.452 | 0.732 | 55.03 |

The first three warmup submissions are excluded. Both runs returned successful
status and one completed frame for every live submission. Alpha cache hits
accounted for 1194/1195 and 1338/1339 live submissions; the alpha-stage medians
were 1.244 and 1.125 ms. Decoder output medians were 0.503 and 0.466 ms; shader
submission medians were 0.026 and 0.028 ms. The video-processor timing bucket
was zero throughout. Resource preparation includes texture/view allocation
AND decoder-to-shader texture copy submission, so it is not an isolated
allocation measurement. These are host durations, not GPU execution durations.
One observed-run live resource-stage outlier was 104.177 ms (frame 6); it is
retained in the distributions and did not close the session.

With the observer on, 713 unique markers produced 36.07 observed desktop
changes/s. Capture-to-desktop upper median/P95 were 63.827/83.915 ms;
capture-to-native-mutation upper median was 26.931 ms and mutation-to-desktop
median was 36.287 ms. All 713 markers had unambiguous capture and mutation
matches. Producer-to-capture phase was 14.846 ms median, so producer-to-desktop
was 78.599 ms upper median. The marker observer already copies only one small
scanline, but its synchronous copy/map interval was 9.180 ms median. Removing
it coincided with 11.2% higher native mutation throughput. This sequential pair
supports observer interference but is not a randomized estimate of its size.
Native mutation throughput does not prove displayed frame rate. The no-observer
run cannot establish desktop latency, and neither run qualifies physical 4K60,
33 ms latency, or input-to-photon performance.

Logs, producer records, and host-stage summaries use these two labels under
`4k-motion/`; only the observed run has a desktop summary. Both sources ended
at the planned timeout; receivers ended on peer closure with watchdog=0 and
all owned tasks/processes and fixture windows were removed. The fixture rule
was disabled after testing. Installed daily-use binaries were untouched.


### DXGI swap-chain experiments (2026-09-08; rejected)

Tested replacement of the CompositionDrawingSurface copy target with a
premultiplied BGRA composition swap chain. The experiment used
`CreateSwapChainForComposition`, two buffers, `FLIP_SEQUENTIAL`, a per-chain
maximum frame latency of one, and `Present(0, DO_NOT_WAIT)`. A zero-time poll
reserved the DXGI slot before copying. Temporary back pressure retained the
session and used the drawing path. The API choices follow Microsoft's
[composition swap-chain requirements](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgifactory2-createswapchainforcomposition)
and [frame-latency waitable-object contract](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_3/nf-dxgi1_3-idxgiswapchain2-getframelatencywaitableobject).

The first version discarded a busy unbound chain; after two such events it
remained on the drawing path. `4k-swapchain-a` therefore used swap chains for
only 170/1230 live frames and is excluded as a swap-chain performance trial.
The second version retained up to two chains per geometry and retried them on
later frames, never writing the currently bound chain. It used swap chains for
1152/1171 live frames; 19 frames used drawing surfaces after transient back
pressure. Its 20 failed availability attempts include one frame that succeeded
with the other chain.

A third version updated the currently bound chain when the complete
pixel-to-window mapping and opacity classification were unchanged. It checked
stream/epoch/configuration/revision, dimensions, patches, tile identities and
geometry, and desktop placement. Frame timestamps could advance. Changed
mappings used an unbound candidate. Redundant brush/size/scale setters were
skipped when their values were equal. A pending GPU slot was integrated with
the existing message loop, including the auto-reset event consumption by
MsgWait; no input was injected. A 250 ms lack of swap-chain progress had a
local drawing-surface recovery path, not a session-exit or frame-age cutoff.
That recovery branch did not fire in this trial and was not separately
qualified. The steady-chain trial used swap chains for all 1111 live frames,
with 1110 updates to the same bound chain. There were 431 slot waits; the
coarse GetTickCount64 measurements had median/P95/max 15/16/47 ms. They are not
precise GPU timings.

| Trial, in run order | Observed desktop changes/s | Capture-to-desktop upper median / P95 ms | Capture-to-native-mutation upper median ms | Native-mutation-to-desktop median ms |
| --- | ---: | ---: | ---: | ---: |
| 4k-swapchain-pooled-a | 36.25 | 67.578 / 112.012 | 32.294 | 35.774 |
| 4k-drawing-after-swap-a | 38.18 | 64.114 / 83.004 | 27.567 | 36.375 |
| 4k-swapchain-stable-a | 38.38 | 68.267 / 88.401 | 35.373 | 32.195 |
| 4k-drawing-after-stable-a | 34.69 | 63.167 / 81.552 | 27.988 | 34.866 |

All runs kept the 3848x2408 source, blur 12, alpha wire references, pinned alpha
staging, and the available 6K virtual Windows desktop. These are sequential
shared-host trials, not randomized measurements. The steady-chain path
shortened the post-mutation interval but added more time before mutation;
its overall latency did not improve. Observed frame rate varied between
baselines and does not establish a reliable frame-rate improvement. Neither
path reaches 4K60 or two 60 Hz frames of latency. No physical-panel or
input-to-photon qualification is implied.

Every experiment passed the 42-phase GPU pixel comparison against a separately
copied drawing-surface reference and the four real-desktop HostBackdrop phases.
The latter covered changing owned background colors, blur versus an unblurred
control, and repacking while verifying that foreground focus did not change.
The steady-chain checks explicitly exercised six same-chain alpha changes in
the 42-phase oracle and two same-chain real-desktop updates. These prove pixel
behavior in those cases, not complete product readiness or the untriggered
recovery branch. The logs are `swapchain[-pooled|-stable]-pixels.log` and
`swapchain[-pooled|-stable]-host.log` under `4k-motion/`.

All experimental changes to the five native implementation/reference/oracle
files were restored byte-for-byte to their pre-experiment versions. The
pre-existing asynchronous host-stage diagnostics remain. The rejected final
experiment is retained only as `4k-motion/swapchain-experiment.patch` for
inspection; it is not enabled or compiled into the restored presenter.
Per-trial source/receiver/producer/desktop/runner/cleanup logs and desktop and
surface-path summaries are retained alongside it. Each source ended at its
planned timeout, each receiver closed with watchdog=0, and owned trial tasks
were removed. Installed daily-use binaries were unchanged. The original
presentation path remains the qualified baseline.

Restoration was verified by byte comparison for all five files, a fresh native
MSVC build with the three existing CPU checks passing, and all 42 restored
pixel phases passing with zero mismatches (`restored-after-swapchain-pixels.log`).
Final inspection found zero owned Windows processes/tasks and zero Linux
fixture windows; the fixture-only Hyprland rule was disabled.
