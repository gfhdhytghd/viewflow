# Immutable alpha texture reuse candidate

`GpuVideoCompositor::Submit` previously created/uploaded an R8 texture for
every frame, including unchanged alpha after decode-only warmup. The candidate
retains one exact alpha byte vector, dimensions, and COM texture reference in
the compositor instance. A hit requires matching dimensions and every byte.
A miss allocates a new texture; pending frames keep their own old COM reference.
No in-flight texture is updated, no identity or timestamp is reused, and color
decoding still processes every accepted frame.

Timing now exposes `alpha_texture_reused`. Headless tests assert hits against
adjacent fixture alpha equality and retain all output frames for final alpha
readback. These tests still require a native Windows hardware run; source
inspection alone is not pixel or timing acceptance.

Isolated build root: `C:\Users\wilf\AppData\Local\Temp\viewflow-alpha-cache-106JMY`.
Local build log: `/tmp/viewflow-alpha-cache.106JMY/build.log`.
Source archive SHA: `1bf4108de5a3ababb5be0565bcc62a7d60e9c8dd9c8569e963a895d6ddae9dc6`.
CPP SHA: `1c91fe7ddecaa5e88ede6ac7478193a1a3aa058a76147df3caa468572a9a19b6`.
Header SHA: `a6c5fe163929ccc0c5ce60ac1fad65279392a5e0731ad95dbbfbedd4004c1fa4`.
The existing live receiver/presenter candidates are not overwritten.
Native Release build and preview CTest completed successfully (5/5). Presenter
SHA `1bd8bf341794719d3f027a7aeb725ebf7a158fd07d913e3870470a30f3bf3f42`.
These parser/pipe/timer tests do not replace the pending headless GPU cache-hit
and real live latency tests. Offline profile tests 3/3 and Clippy passed.

Independent offline tools now accept bounded VFBG or VFAR v1 samples. Current
r11 alpha fixture SHA `a1a3d48f91dd834da30f7b70496a68bc4c8ac1b073129d0ee628e2f87fffc805`:
raw 2,016,240 bytes, VFAR RLE 138,721. Node zlib-wrapper DEFLATE levels 1/3/6
produced 69,110 / 61,683 / 48,974 bytes with exact roundtrip. A root rerun took
9.221 / 8.559 / 18.985 ms encode and 6.337 / 5.995 / 7.940 ms decode.
These are offline Linux CPU measurements, not native Windows or live claims.
No new compression mode has been inserted into the media protocol.

## Follow-up gates identified by source inspection

Warmup currently calls `prepare_gpu_surface` only. First live presentation
still incurs BeginDraw, destination backing allocation/interop, GPU copy,
EndDraw and Flush. A separate follow-up can exercise this path on the unbound
surface during decode-only startup, but must never attach its brush to the
visual until a fresh live frame has fully overwritten the surface. Flush is
submission, not a GPU completion fence. Keep this separate from the alpha-cache
candidate to retain a useful single-change comparison.

VFGP currently carries identity/geometry/payload, not an absolute native
presentation deadline. Rust checks freshness before pipe write and after ACK
and times out the worker, but this is not a native pre-bind expiry check.
Consequently successful Rust ACK admission would still not prove that a late
native surface can never briefly be bound during a timeout race. The final
two-frame claim requires a native deadline contract and pre-presentation checks,
in addition to end-to-end measurement. No such stronger guarantee is claimed.

## Native hardware readback validation

The isolated `headless-build` EXE SHA is
`554625ec33eff3efc5a356f17e76aca5d92da5a468e6a3e255cebf1aab54224e`.
1936x1732 and 256x256 original three-frame fixtures passed with all three
retained output alpha readbacks exact (all cache misses for distinct inputs).
A separate A/A/B alpha fixture passed with flags false/true/false, and all
three retained outputs remained exact. Alpha-stage host times there were
7993/27/238 us; these three samples prove behavior, not a latency distribution.
A/A/B expected-alpha SHA
`007f3fda03c59414b01dd840b1cf73634f2c12e6cb98197923d1895ef7cdc5fd`.
Logs in the same Windows staging root: `headless-large.out`,
`headless-small.out`, `headless-aab.out`. No GUI or service was touched by these
headless tests.

## r12 live outcome and next candidate

The alpha-cache-only presenter ran with the same sender as r11. Receiver
assembled its first live frame in 9.083 ms with 13.418 ms remaining, then
timed out waiting for native presentation. No live ACK and no live-stage
native timing were obtained, so this run cannot prove a cache hit or speedup.
Receiver PID 18296 exited at 07:28:37 UTC; exact r12 task removed after process
and port checks. Logs `sender-r12.stderr` and remote `terminal-r12.json` remain.

The next source candidate exercises GPU copy/EndDraw/Flush during decode-only
warmup on an unbound visual. It checks the visual is unbound before copy and
after completion; only live calls bind the brush. This candidate is not yet
built or runtime verified and does not implement the proposed native deadline.

## r13 invisible-copy warmup outcome

Built in separate `viewflow-gpu-copy-warmup-20260905-7B4Q` Windows staging,
Release CTest 6/6 passed. Presenter SHA
`a2942006570823ca2c6e7939fa92ead6dc88e4feadcc967670edc8e902988669`.
Actual decode-only warmup completed with the unbound-copy checks intact.
First live frame assembled in 8.900 ms; 13.233 ms remained after assembly,
12.062 ms before presenter. Native ACK still timed out, with no completed
live native-stage timing. No success is inferred from warmup completion.
Receiver 12968 exited at 07:33:00 UTC; r13 task removed after process/port checks.
Logs remain `sender-r13.stderr` and remote `terminal-r13.json`.

Next diagnostic must distinguish GPU/interop latency from a decoder retaining
the first P-picture until later input. Existing independent-keyframe headless
tests do not establish immediate IDR/P/P completion. Also audit the current
CleanPoint assignment (`pending_.size()==1`), which is not actual NAL identity.

## Continuous P-chain test and clean-point correction

The existing native headless candidate decoded a true IDR/P/P encoder chain
with completed_delta=1 on every Submit; Finish succeeded with three retained
frames and exact alpha readbacks. `headless-ipp.out` SHA
`2db65ed56ddc3ee5a4fb5f10cbd93ef9d9b81b71b539395e8580c9240637c68e`.
This contradicts normal P-picture buffering as a sufficient explanation for
r13. It does not reproduce the exact live fixture/geometry or pipe scheduling.

Separately corrected the native CleanPoint hint to inspect Annex-B IDR VCL
instead of queue size. The conservative helper does not mark non-IDR/mixed
VCL, parameter-only or truncated headers as clean points. Local explicit-check
tests pass; Windows rebuild and runtime regression remain pending. Both this
test and opt-in VFGP v4 parser tests are now registered in preview CMake.

## Matching-size I/P/P observation

The same existing headless EXE tested 1626x1240 native I/P/P with decoded
r11 alpha repeated A/A/A. All three Submit calls returned one completed frame;
all retained alpha readbacks were exact. Host submit times were
150.720 / 34.886 / 4.959 ms. Alpha times 12.291 / 0.230 / 0.815 ms
(miss/hit/hit); MF output 8.164 / 16.607 / 1.498 ms and resource creation
8.044 / 16.719 / 2.279 ms. The second picture can therefore exceed the live
budget despite alpha-cache reuse and immediate output semantics. One decode-only
picture does not prove all native resource first-use costs are warmed.
Log `headless-ipp-1626.out` SHA
`0c22657ddb2527bb45830cedc501bb55b2042ed9ce3131395a2c0d56e311b457`.
These are three observations, not stable performance percentiles.

Current source additionally logs the first four native Submit entries and
returns (HRESULT and completed delta), including failure returns previously
hidden by check_hresult. This diagnostic source awaits its separate build/live
test; it does not alter deadlines or claim that blocked API calls completed.

## Low-latency attribute result checking

The native initializer used to ignore GetAttributes/SetUINT32 failures when
requesting MF_LOW_LATENCY. It now requires successful get/set/readback and a
TRUE result before continuing. This preserves the existing requested mode;
it does not lower image quality or introduce a new codec setting. Successful
readback alone does not prove a decoding-time improvement or hardware behavior.
Microsoft documents this attribute as BOOL stored via UINT32 and supports
GetUINT32/SetUINT32:
https://learn.microsoft.com/en-us/windows/win32/medfound/mf-low-latency
The checked candidate passed separate Windows headless execution in private
staging `C:\Users\wilf\AppData\Local\Temp\viewflow-lowlatency-r16-20260905-7C4D`.
Previously built diagnostic candidates remain unchanged.

Exact source archive SHA256:
`aa7bd007a0269c469efa96dd2eea1e57c423a0ad6cc9e803563a8d62ab858546`.
Headless EXE SHA256:
`3280ca340e7447113a97877cf6b80b2cd0e39ef48572eb049e2a199255dc8fe9`.
The existing read-only `fixtures-ipp-1626` produced initializer HRESULT 0,
three Submit HRESULTs 0 with completed_delta=1 each, and Finish HRESULT 0
with three completed frames. All three retained alpha readbacks matched exactly
(2,016,240 bytes each). Run log SHA256:
`d9ce5885689743937fac4d878da4b64a4fd122f2814f55b32befbaa33eec1ccb`.
This confirms the stricter attribute handling works on this decoder, not that
live frame deadlines or physical presentation have been achieved. No GUI/live
process was started by this headless verification.

## r22 immutable alpha texture/SRV pair

Pending and the one-entry cache now retain the shader-resource view alongside
the immutable R8 texture. A cache miss creates both in local COM pointers before
publishing either; a hit copies both references. Composite no longer creates
the same alpha view on every frame. Delivered BGRA targets remain individually
owned; MF, fallback conversion and final target allocation were not changed.
The existing alpha-upload timing bucket now includes miss-time SRV creation,
while total Submit still includes all work. No performance benefit is claimed
from merely moving work between timing buckets.

Source header SHA256:
`d4c3c6f9b2f5cb100f878ac6f265af1c3d19043b8bd684b0d20d0d9fc8c2ea63`.
Source implementation SHA256:
`82d19d4cbd989fcd3bafcf9c154409a79b474f89a94f60d69e0d43b8d2d43a03`.
Windows staging:
`C:\Users\wilf\AppData\Local\Temp\viewflow-alpha-srv-r22-20260905-2E6C`.
Source archive SHA256:
`8ad704351362a500cc7090ce343f0bbb1d6a952cf35a49a19260829a2b5e7ac0`.
Headless EXE SHA256:
`7982ab46f6d1289ac7bf0d6eb6ba2064305cfd8cc17511742f8029eb0f1a6270`.
Preview EXE SHA256:
`ec90dfcc55b48ce61eede1d4b8cc5179d44fc4d50cb75dd023b5283f40d02e46`.

Windows Release build and preview CTest 10/10 passed. Matching 1626x1240 I/P/P
retained-alpha readbacks were all exact (2,016,240 bytes each), with cache
false/true/true. A/A/B retained-alpha readbacks were all exact (65,536 bytes
each), with cache false/true/false. Initialize, every Submit and Finish succeeded.
Logs are `headless-ipp-1626.log`, `headless-aab.log` and `preview-ctest.log` under
the staging root. The worker and headless processes exited; no GUI/live run was
performed. These establish correctness, not reduced live latency or r21's
improvement (r21 used the previous, separately frozen compositor).
