# Trusted-local input recovery record

VFGP v6 is a fixed 152-byte control record, not a video frame or network
authorization. The receiver may construct it only after validating the source's
post-cleanup authorization and its exact committed tile. Native resume must also
check the cancelled binding, physical-release drain, grant continuity and QPC
expiry. The codec alone proves none of those runtime conditions.

All integer fields are big-endian. The first 40 bytes retain VFGP framing:
magic `VFGP`, version byte 6, three zero reserved bytes, header length 152,
zero payload length, nonzero control sequence, and sixteen zero picture bytes.

| Offset | Field | Bytes |
| --- | --- | --- |
| 40 | Stream ID | 16 |
| 56 | Window ID | 16 |
| 72 | Atlas epoch | 8 |
| 80 | Configuration generation | 8 |
| 88 | Previous source geometry epoch | 8 |
| 96 | New source geometry epoch | 8 |
| 104 | Source-confirmed grant generation | 8 |
| 112 | Committed atlas frame | 8 |
| 120 | Corresponding source frame | 8 |
| 128 | Placement generation | 8 |
| 136 | Receiver-local QPC deadline | 8 |
| 144 | Receiver-local QPC frequency | 8 |

Every listed field must be nonzero, the IDs must differ, and the new geometry
epoch must exceed the previous one. The native parser requires explicit atlas
and v6 opt-in. Its control replay ledger is independent of both picture ledgers;
controls return a distinct kind with empty color/alpha data and zero picture
identity. Invalid controls poison the parser; there is no resynchronization scan.

Implemented: Rust encoder, native decoder, explicitly opted-in streaming parser,
and tests for every split size, truncated records, malformed fields, replay,
disabled modes, limits and interleaving controls with pictures. Default receiver
launches do not enable v6 or write these records. Source-confirmation routing,
cancellation request and live held-input recovery remain
implementation work.

The atlas input state now distinguishes recoverable geometry suspension from
permanent pointer retirement. Its confirmation method checks the cancelled
binding, exact current committed tile, advancing source geometry/frame, unchanged
stream/atlas/configuration, a drained physical-key ledger, local QPC expiry, and
strictly increasing recovery sequence/grant generations. A successful confirmation
clears the old admitted key ledger and starts pointer timestamp history at the
recovery boundary, so queued pre-recovery motion cannot use the new authority.
Retirement, invalid physical drain, regressed frame/time, and a mouse button held
at cancellation prevent this keyboard-only recovery path. The last confirmed
recovery generation is not a substitute for validating the actual source lease.

The native renderer now has an explicit `--atlas-input-recovery-v1` option after
`--atlas-keyboard-v1` in its ordered atlas argument list. This option requires
keyboard/wheel/pointer/disposition capabilities and a record limit of at least
152 bytes. Only this mode preserves a recoverable geometry suspension and enables
v6 parsing. Its control handler requires a live, visible foreground/focused proxy,
no physically held key or mouse button, and the state checks above. Failure is
terminal; a confirmation received before physical release is not queued or retried.
The input owner must eventually coordinate cancellation, cleanup, physical drain,
and a fresh committed-frame confirmation before enabling this option in the
normal launcher. The normal launcher currently never supplies it.

After applying a control, the renderer emits `atlas-input-recovered-v1` with every
control field echoed in a fixed order and a `recovered_qpc` timestamp. Rust's
`validate_receipt` requires exact canonical values for the pending control and
`sent_qpc <= recovered_qpc <= observed_qpc`, with recovery strictly before the
control deadline. A video disposition cannot satisfy this receipt.

The supervised child now exposes an explicit recovery launch/transaction API.
Its recovery-aware stdout dispatcher routes recovery receipts only to the receipt
pipe, never the pointer/key queue. Default dispatch rejects such output. The
exclusive `recover_input` transaction requires the exact most recently committed
atlas frame, negotiated recovery readiness and an increasing control sequence.
It writes all 152 bytes, flushes, and consumes the exact reply under the lesser
of the supplied timeout and the same-host QPC budget. There is no late-receipt
grace in this recovery transaction. Partial writes, timeout, cancellation, wrong
receipt or frequency change retire the pipe; the child wrapper kills/reaps its
owned native process on errors and retains kill-on-drop on cancellation.

The ordinary receiver/input supervisor does not yet call these APIs. It still
needs source cleanup/cancellation coordination, a physical-drain notification,
and validated source authority bound to the current committed tile. Exposing
the lower-level transaction does not close those runtime gates.

## Verification (2026-09-06)

The Windows Release clean rebuild passed all 22 CTests, including the new
control-record test and all existing v1–v5 parser tests. The resulting preview
executable has SHA-256
`9A81DC08FBB45F7921DC7E503A3EC4B15F7D41774693D85A4451A32E1F1C402E`.

The preceding incremental build failed six existing parser/reader tests
(`vfgp_recycle`, `vfgp_parser`, `vfgp_parser_negative`, `compressed_pipe_reader`,
`vfgp_parser_v4`, and `vfgp_parser_v5`). A clean rebuild, without changing parser
logic, cleared those failures. This is consistent with stale objects after the
`Frame` layout changed; the precise incremental dependency failure is not yet
proven. MSBuild also warned that this temporary-directory build may have
incremental-build problems. Use a clean rebuild for acceptance of this staged
binary, not the earlier incremental result.

These tests verify framing and parsing, not live input recovery. No recovery
controls are enabled or sent by the active runtime yet.

After adding the atlas-state confirmation method, a second Windows clean Release
build also passed all 22 CTests (1.52 seconds). Its preview executable SHA-256 is
`CA6EBB4611FCCA35E113B37802DFFF3BE7A8E8D0CA694FEB4AEEE4478A73C6A9`.
The expanded atlas-pointer test covers field mismatches, expiry, physical drain,
permanent retirement, regressed frame/time, pre-recovery event timestamps,
repeated recovery with replayed sequence/grant, and held-button exclusion. The
same test passed portable GCC builds with warnings-as-errors and ASan/UBSan;
the existing pointer-motion and keyboard-state portable tests also passed.
These remain state-machine tests, not native OS recovery acceptance.

The explicit native control-handler build passed a third clean Windows Release
build and all 22 CTests (1.46 seconds), SHA-256
`FD464B259075D23EBE730A8F30546E921E26251ECD3317A8281B6F40F02C7F30`.
Rust's two focused codec/receipt tests passed, including every echoed-field
mismatch, noncanonical timestamps, timing bounds and cross-kind receipt rejection.
This does not yet prove a successful recovery receipt from a real native window.

After wiring the opt-in pipe/child/dispatcher APIs, the focused Rust atlas suite
passed 91 tests. Added coverage includes exact readiness (no silent upgrade or
downgrade), recovery/picture receipt separation, unchanged picture replay floor,
wrong frame/capability/clock, expiry, one-byte partial writes, cancellation, and
actual owned-child reaping after recovery without a committed frame. These tests
exercise duplex pipes and an owned local contract subprocess; they do not provide
Windows OS input or source-native cleanup acceptance.

The subsequent typed-notice and source-cleanup implementation passed the combined
98-test Rust atlas suite. Native suspension/drain notices have their own bounded
64-entry queue; they cannot become input events or completion receipts. An ended
consumer, overflow, or malformed notice is terminal. The source recovery API
performs the old native route's `END`/`Ended` exchange before new authorization,
and the receiver fence prevents that transaction from overlapping a new media
forward. Ordinary media-owner opt-in wiring remains a separate integration gate.

The first run of the expanded suite hung because two test fixtures wrote literal
backslash-n instead of a newline. That owned test run was terminated, the fixtures
were corrected and their asynchronous waits bounded, and the complete rerun
passed: 98 passed, zero failed (0.45 seconds). The terminated run is not a pass.

The corresponding native suspension/drain-notice and retirement-hardening build
passed a clean Windows Release build and all 22 CTests (1.59 seconds), executable
SHA-256 `273E3FBADCF9E329F8BED77B25F775A75065FA1FF74F966FED314605100284EF`.
This still does not prove a live held-input recovery or physical-release drain.

After adding the default-off peer option and delayed-frame fence, the combined
Rust atlas suite passed 100 tests (0.45 seconds), and Linux
`cargo check -p viewflowd --all-targets` passed with two dead-code warnings.
The Windows-specific peer branch was also compiled on WindowsVM with MSVC:
`cargo build --release --offline --locked -p viewflowd --bin vf-media-peer`
passed (31.01 seconds; existing target-specific dead-code warnings). That staged
`vf-media-peer.exe` has SHA-256
`E944625121491992FB70C68F4FBC94AA2A6A3590CA4399572DDD4BAF28D6CD3C`.
This is the Rust peer executable, not the native renderer hash above. Neither
executable was launched into a live recovery session for this checkpoint.

## Receiver opt-in and fail-closed timing

The receiver's `input_recovery` configuration remains false by default. Setting
it to true requires the existing `pointer` configuration plus
`disposition_recovery: true`, `wheel: true`, and `direct_keyboard: true`; the
launcher then selects the distinct recovery-capable native child and wires its
typed notice queue to the input supervisor. Normal pointer launches neither
start that child nor consume recovery notices.

The sole media owner serializes recovery requests with native frame forwarding.
It never cancels an admitted native forward in a `select!`; a drain fence waits
for that handoff and prevents the next one from beginning. If a media receive
was already waiting when the physical drain armed the fence and returns a frame
before any native child handoff, the receiver retires that attempt instead of
presenting or deferring the pair. There is no safe replay/defer contract for
such a received pair. Therefore this timing path is terminal, not a successful
input recovery. A positive live recovery still requires source cleanup,
physical drain, an exact new committed tile, and a real native V6 receipt.
