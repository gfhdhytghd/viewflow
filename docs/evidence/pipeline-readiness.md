# Negotiated per-lane pipeline readiness (2026-10-29 UTC)

Scope: branch `pipeline`, starting commit `9acc768b`. No desktop capture,
input injection, focus change, deployment or push. This is the task's explicitly
permitted disabled fallback, not a completed transport pipeline.

## Decision

Do not advertise a pipeline version. Reserve protobuf field 21 and let the V3
receiver decline optional future offers without rejecting the rest of startup.
Current sender offers and receiver responses contain version 0 (omitted on wire).
A nonzero unsolicited acceptance fails the existing startup-plan equality check;
there is no new active-session failure or timeout path.

Three is a fixed experimental metadata capacity, not a measured choice of N.
The reusable core state machine is deliberately disconnected from production.
No new per-frame allocations/locks, buffering, queue-age changes or feedback
readers are added to either the CPU sender or GPU sender.

## Source audit and unresolved owner contracts

Locations below are symbols, which remain stable when test lines are added.

| Owner | Current contract | Required before activation |
|---|---|---|
| `atlas_session.rs:AtlasReceiveLane`, `stage_manifest` | One staged manifest, assembler, color/alpha pair and exact native disposition per lane; rejects advance before disposition | Separate bounded metadata/media slots, byte accounting and per-slot loss timers; retain earlier incomplete media instead of superseding on later traffic |
| `atlas_session.rs:expire_superseded`, `poll_loss` | Later same-lane media/manifest expires the earlier incomplete frame | Recognize the whole receive window; NACK exact older frames; expire and invalidate only dependent pictures |
| `atlas_runtime.rs:AtlasReceiver::stage_with_expiry`, `admit` | One pending/observed/delivered layout; staging replaces previous metadata | Preserve sequential layout validation and deliver actual codec admission in lane order |
| `atlas_session.rs:send_frame` | `&mut self` held through exact feedback; alpha baseline installed after Committed/Superseded | Split enqueue and completion ownership; bounded unacked descriptors with exact feedback; retain partial reliable reads across cancellation |
| `atlas_activity_feedback.rs:AtlasActivityFeedback::register` | Shared reader, BTreeMap/oneshot ticket, two pending records total | Preallocated per-lane exact slots; do not multiply existing per-frame allocation/lock path to implement N=3 |
| `gpu_atlas_sender.rs:submit_batch_with_release`, `finish_pending` | Entire sender moves into one pending task; next batch encodes ahead but waits before sending | Keep a persistent wire owner plus bounded publications; reconcile late rejection with pictures already encoded; preserve producer release and publication/input receipt identity |
| `alpha_reference.rs:AlphaReferenceCache`, `atlas_session.rs:finish_pair` | Single full-alpha baseline; sender installs on feedback, receiver resolves against its current cache | Pin all referenced full-alpha bytes until every dependent retires; never resolve by whichever baseline arrived latest |
| `gpu_compatible_encoder.rs:submit_recoverable`, `atlas_frame_bindings.h:Stage` | Current sparse patches map spatial cells; mapping changes require paired keyframes, and native bindings retain each frame's exact patch/placement metadata | Preserve per-slot spatial mapping and surface lifetimes; do not assume every patch list is a temporal pixel delta |
| `atlas_session.rs:with_fenced_controls` and fenced manifest slots | One deferred manifest per lane behind recovery fence | Drain/cancel all exact slots before fence/generation/geometry reset; keep ordered controls flowing; stale callbacks cannot rebind to reused frame IDs |
| `atlas_receiver_presenter.rs:activity_pending` | Rust runner permits at most two handoffs across two lanes, one per lane | Ordered decode/native commit and explicit surface/receipt capacity for N per lane; Committed/Superseded/ExpiredUnbound remain distinct |
| `platform/windows-composition-preview/atlas_frame_bindings.h:Stage/Commit/DiscardUnbound` | Native Stage allows eight bindings, Commit erases the resolved prefix, but DiscardUnbound requires exactly one pending binding (lines 23, 102, 110) | Design lane-local window rejection and exact receipts before native activation; capacity eight alone does not establish pipeline recovery |
| `atlas_loss.rs:Retransmit` | Two frames per lane and 5-second retention | At least N frames per lane or select N=2 after measurements; retain repair identity through window retirement |
| `quality.rs:QualityTelemetry` | Original enqueue age excludes exact disposition/NACK waits | Account oldest outstanding original enqueue, real Quinn backlog and concurrent sends; never count feedback waits as network queue age |

These are concrete cross-owner gaps. The metadata tests below do not prove media,
codec, input-publication or native-presenter correctness. Windows/macOS owners
were read only; no native platform compilation or device validation was done.

## Experimental metadata dependency contract

- A `PipelineLineage` binds stream, lane, geometry epoch, config generation and a
  local increasing recovery serial. A token adds exact frame ID. Dual lanes
  validate even/odd frame routing independently.
- Manifests enqueue in lane order. Up to three fixed slots admit completion in
  arbitrary order. Retirement emits dispositions only from the head. Full windows
  return a local `Full` result; no timer/session close exists in this component.
- Color dependencies explicitly name the preceding submitted lane frame.
  Independent color means a validated codec keyframe. A canvas dependency is
  present only for a genuinely temporal delta and names that same predecessor;
  a self-contained spatial patch layout does not require it. Current AtlasPatch
  lists describe spatial mappings, not an automatic temporal pixel dependency.
  The owner must retain the exact patch/placement layout for each picture and
  derive dependency values from actual codec/canvas semantics; no adapter exists.
- Alpha dependencies name an exact full-alpha baseline, either committed or an
  earlier outstanding independent-alpha frame. Referencing a reference is rejected.
  The owner must pin each named baseline's actual bytes across all dependents,
  including a newer full-alpha commit. The metadata window stores no alpha bytes.
  The latest committed full alpha remains eligible for subsequent enqueue;
  enqueue and out-of-order completion never install it.
- Loss marks transitive color/alpha/patch dependents Lost, including successors
  whose media is already ready. Independent full snapshots survive. The owner
  must map these retirements to ExpiredUnbound and request the existing paired
  keyframe/full-canvas recovery; it must not submit invalidated media to decoder.
- Reset returns all outstanding exact tokens in a fixed array before clearing
  metadata. The owner must send/cancel dispositions, release byte/surface slots,
  reset codec/canvas/alpha state, then resume with independent baselines. Already
  bound native work must finish with its exact real receipt before a resource
  reset; returning tokens does not prove resources are drained and cannot justify
  reporting ExpiredUnbound for bound visuals. A larger local recovery serial
  rejects stale callbacks even if wire IDs are reused.
- `PipelineOutcome::Committed` is bookkeeping readiness followed by ordered
  retirement, not evidence of native display. There is no adapter for native
  Superseded receipts yet. The future adapter must preserve decoder/canvas
  reference state for successfully decoded but visually superseded pictures.

## Validation and measurement

Commands, exit statuses and counts are in [the check summary](pipeline-checks-summary.md).
Raw Cargo output is in `pipeline-checks-*.txt`. Raw netem evidence is in
`pipeline-netem-*.txt`. The preliminary clean snapshot (before comment freeze)
and two preliminary cap20 modes (before the launcher mutual-wait fix) are retained
separately and excluded from the final comparison. Only our waiting launcher was
stopped; no owned test child was active and no peer process was signalled.
The launcher elects lower PID among waiting launchers and always waits for any
actual test executable; every start/poll and source hash is in the raw evidence.
Launcher coordination revisions do not change encoded media or transport code.
Measurements exercise the unchanged version-0 CPU-owned
RGBA/NVENC/QUIC path, not the experimental window. They do not decode/present.
Historical numbers are retained in `weak-network.md` and are not paired trials.
After measurement, final Clippy review added only Markdown backticks around
`AtlasPatch` in the core module's line-32 doc comment. No executable statement,
media path, test or dependency contract changed. The measured core SHA256 is in
each netem log; `pipeline-source-sha256.json` records the final comment formatting.
Final Clippy checks cover this formatting cleanup.
No throughput improvement or p95 non-regression from an enabled pipeline is
claimed. Native GPU source, dual-lane network, actual alpha/patch pipeline,
recovery fences with real in-flight media, real Wi-Fi and physical display all
remain unverified for pipelining.
