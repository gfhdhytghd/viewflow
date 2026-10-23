# VFGP v4 native deadline (partial, not runtime accepted)

Current implementation: Rust v4 encoding/conservative QPC conversion and C++
opt-in parsing have matching golden tests. The Rust diagnostic receiver has
an explicit `--require-deadline-v4` switch (default off), derives the deadline
before queueing and passes the same switch to the native process. Native
pre-bind enforcement is now present in source, while Windows end-to-end
verification is pending; do not treat plumbing as a completed presentation guarantee.
Linux example tests 29/29 and Clippy pass; the Windows-only QPC call path still
needs a Windows build. Warmup remains decode-only v3.

Native source follow-up now implements the explicit switch, required-v4 live
admission, frequency checks, an eight-entry identity/deadline bound, and checks
before decode and before/after unbound staging copy. Visual brush swap is the
first action after the final check; old resources remain owned through swap.
No expired disposition becomes a successful ACK. A pure admission helper test
passes locally. Windows build and actual expired-surface nonvisibility remain
unverified: source-level wiring is not runtime acceptance. Native r15 staging
is separate from the pre-enforcement r14 snapshot.

Windows Rust build snapshot: `/tmp/viewflow-rust-v4.lL4JqU/rust-source.tar`,
SHA `5d7714a4022dbff670127d49ab8cbf2257b1c61bc5c71e490e4365299f9d14d7`.
Log `/tmp/viewflow-rust-v4.lL4JqU/build.log`; build runs in the isolated
`viewflow-native-submit-r14-20260905-8C2A/rust-source` subtree without replacing
any existing native or running receiver binary.

The frozen Windows Rust snapshot compiled and passed 29 example tests,
including the receive-only opt-in CLI and real socket-buffer test; Release
build remains in progress. A subsequent source-only Windows QPC smoke test
was added to exercise stable frequency and monotonic samples, and is not part
of that already-tested snapshot yet.

The first native r15 configuration found a duplicate CMake registration from
parallel integration. The duplicate was removed locally; a separate rebuilt
snapshot is required. Failed configuration is not counted as passing CTest.

Corrected native snapshot built successfully on Windows with CTest 9/9.
Staging `C:\Users\wilf\AppData\Local\Temp\viewflow-deadline-r15b-20260905-5F7C`;
source SHA `53a6fa0d0dbb32f41670a1edb7f836fa619475c248c3d3ca6382fe710ea9687d`;
presenter SHA `5d63ba2dd5207ffe1dc8f2794fd928737944964698cdc3bb66462cb49a5fde37`.
CTest log SHA `f6150da2a90673c5fc39129c025bc532dd8ee1232ac04b95c342d363feda14bb`.
This includes source enforcement but not GUI nonvisibility or end-to-end proof.

Windows Rust Release build completed successfully (29 snapshot tests passed).
Receiver path in r14 staging: `rust-source/target/release/examples/coded_window_peer.exe`;
SHA `b684abf909399b2c39a2f59a768f3c3161e488f44df28aa7f786914335f15e53`.
The build retains seven platform-unused-code warnings; it is not claimed as
a warning-free Windows Clippy run. The prepared `run-coded-deadline.ps1`
explicitly enables v4 and retains the bounded original diagnostic lifecycle;
its SHA is `8eec6cb2ced8d094ce628061702f810ae51c85a476b4f0ebc677cf224076989b`.
It has not yet been run as the full cross-host acceptance trial.

## r16 first full-mode diagnostic

The existing Linux sender and frozen Windows Rust/native candidates were run
with `--require-deadline-v4`. Decode-only warmup completed. The first live
record reached `native submit begin frame=26 decode_only=0`, proving it passed
native format/frequency/pre-decode deadline admission. No Submit-return or
presented completion was observed before the parent's original deadline.
Assembly 9.093 ms; remaining after assembly 14.283 ms, before presenter 12.486 ms.
The parent reported timeout, not success (zero ACKs). This does not prove
post-copy expiry rejection or physical nonvisibility under every race.
Receiver PID 22660 exited at 07:51:30 UTC; r16 task removed after no diagnostic
process and no UDP endpoint were observed. Logs `sender-r16.stderr` and remote
`terminal-r16.json` are preserved. Separate injected-expiry/v2 rejection tests
did not produce case logs and were cleaned up; they are not recorded as PASS.

The current v2/v3 records remain unchanged. A new v4 live record must be
explicitly supported by both pipe writer and native presenter; no silent
fallback from deadline-protected live mode to v2 is acceptable. Decode-only
startup remains v3 and must never bind its surface as live output.

Proposed v4 header: existing identity/geometry/plane lengths at offsets 0..40,
magic version 4 with zero reserved bytes, header length 56, then big-endian
u64 absolute QPC deadline at offset 40 and u64 QPC frequency at offset 48.
Payload length excludes the header, as before. Frequency must equal the local
QueryPerformanceFrequency result, deadline must be nonzero and still future.
All existing size, identity, alpha and exact-length checks continue to apply.

The Rust receiver derives the deadline from the original source freshness
budget and the same Windows host's QPC. Sample QPC *before* measuring the
remaining source budget; subtract measurement uncertainty through the existing
clock-estimate admission. Convert positive nanoseconds to ticks by flooring,
never ceiling; reject zero-tick budget and checked arithmetic overflow. This
does not exchange QPC values between Linux and Windows. The deadline is fixed
before pipe transfer, not restarted after parse, decode, or scheduling delay.

Native checks are required before decode admission, before GPU work, and
immediately before composition commit. A delayed decoded frame must retain
its own deadline by identity, not acquire the newest frame's deadline.
Expired frame disposition must be explicit and never logged as `submitted`.
Reference-chain recovery remains required where dropping encoded work can
invalidate a subsequent P-frame; do not invent an ACK for a discarded frame.

Important: updating an already-visible DrawingSurface before checking expiry
can expose expired pixels even if Brush assignment is skipped. The commit
path therefore needs an unbound staging surface (or equivalent atomic visual
swap discipline), with exact live content copied before binding. Warmup must
not become visible through that staging path. Old surfaces cannot be reused
until their ownership/composition use is safe.

Checks immediately before an asynchronous composition submission do not prove
physical scanout within budget. Final latency acceptance still needs actual
capture-to-display measurement; QPC checks provide admission guarantees only.

Required tests: exact/expired/zero/overflow boundaries; frequency mismatch;
partial and malformed v4 input; delayed decoded identity; warmup never binds;
expired staged copy never replaces the visible surface; old surface ownership;
real Windows live tests with the unchanged 33,333,333 ns diagnostic budget.

## Rejection-harness diagnostic correction

The r15f isolated expired-v4 and missing-v2 cases both launched successfully,
exited with code 2 without timeout, and produced no native Submit entry or live
frame acknowledgment. Their stderr reported `stage=show-window` and
`HRESULT=0x80070057`. This is **not evidence of ShowWindow failure**: the stage
label was never updated in the compressed-input loop and the catch handler
discarded the exception message. The generated records and source paths are
consistent with the intended admission rejection, but that inference does not
substitute for the expected-reason assertion. The old harness also did not
retain the exact record bytes and sampled QPC frequency.

Current source reports `compressed-input`/`compressed-eof` and the HRESULT
exception message. A fresh native build and isolated cases must verify the
specific rejection reasons. The old r15f task was removed and both child PIDs
were confirmed exited; its JSON evidence remains in the private Windows
`viewflow-deadline-reject-r15f-20260905-N6T1` temporary staging directory.

The fresh r17b native candidate passed Windows Release build and all 10 CTest
tests. EXE SHA256:
`f0bf051d3f6a6d116bf06a5c1abec5c7adba51216d856a7f432534c7382ae10d`.
Private path:
`C:\Users\wilf\AppData\Local\Temp\viewflow-deadline-r17b-20260905-H2L8\native-build\Release\viewflow_windows_composition_preview.exe`.

The r17c isolated repeat retained actual wire bytes/base64, arguments and QPC
frequency in its JSON evidence. Expired v4 (89 bytes, QPC frequency 100,000,000)
exited 2 with `message=VFGP v4 deadline expired`. V2 under required-v4 mode
(73 bytes) exited 2 with `message=VFGP v4 required for live frame`. Both reported
`stage=compressed-input`, neither timed out, and neither logged native Submit
entry or a live frame acknowledgment. Their tasks were removed and presenter
process count was verified zero. Evidence root:
`C:\Users\wilf\AppData\Local\Temp\viewflow-deadline-r17c-reject-J7R4`.
These verify pre-decode rejection only, not post-copy expiry or scanout timing.
