# Per-application audio runtime boundary

`viewflow-core::AudioRouter` decides the current `AudioRoute` for a window
family.  `viewflow_platform::application_audio::ApplicationAudioRuntime` is the
source-local boundary that can carry that decision out against a native audio
server.  It is deliberately not a system-audio capture API.

## Scope and safety contract

- A native stream is admitted only after a platform adapter explicitly binds it
  to a `WindowDescriptor`; the descriptor's `family_id` is canonical across
  main windows, dialogs, moves, and bounds changes.  The runtime has no
  PID-only or `application.name`-only match operation.
- A route is applied only by the runtime whose `local_device` equals
  `AudioRoute.source_device`.  Generations advance strictly per family.
- For an enabled route, the adapter creates a private, deterministic
  `viewflow.family.<family>.generation.<generation>` capture sink and moves
  only registered inputs in that family.  The native control trait has no
  operation for changing a global/default sink.
- Before the first move the runtime queries the input's actual sink and retains
  it as a restore target.  A route replacement retains that host target rather
  than mistaking the previous Viewflow sink for the target.  Revocation and
  explicit `shutdown()` restore only streams that still point at the matching
  private sink, then destroy the private sink.  `Drop` intentionally does not
  hide fallible cleanup.
- PCM bytes stay caller-owned.  The runtime admits only bounded metadata for an
  active generation with non-overlapping source `CLOCK_MONOTONIC` intervals and
  returns the selected device/output to the caller's encoder/transport stage.

## Native adapter requirements

The Linux `PactlApplicationAudioControl` is the concrete PulseAudio-compatible
adapter for PipeWire's `pipewire-pulse` service. It uses only the documented
`pactl --format=json list sink-inputs`, `pactl --format=json list sinks`,
`load-module module-null-sink`, `move-sink-input`, and `unload-module`
commands. Every command has a finite process budget and its child is killed and
reaped on timeout. It resolves exact numeric sink-input/sink identities from
bounded JSON before moving an input. The adapter tracks only module identifiers
it created and only restore sink names it observed, so it rejects a direct move
to an arbitrary host output.

If `load-module` succeeds but returns an invalid module identifier, the adapter
fences the private sink name as unresolved rather than guessing an unload target
or potentially destroying a different user's module. That condition requires
explicit native reconciliation before a retry. Failed retirement after an
otherwise committed generation replacement is likewise retained for explicit
`shutdown()` retry. A source backend must not use `pactl set-default-sink`,
PipeWire's global default-node metadata, monitor an arbitrary host sink, or
infer stream ownership merely from a reusable PID.

`linux_application_audio_capture::PrivateSinkPcmCapture` is the paired,
explicit Linux producer boundary. It starts `parec` only after checking the
active runtime's family/generation/sink identity and the adapter's owned-module
identity. Its only device argument is the exact owned `<private-sink>.monitor`;
default monitors and arbitrary host sources are not expressible. It requests
raw `s16le` PCM with bounded blocks and a bounded worker queue. Queue overflow
is terminal and stops/reaps the child rather than silently dropping raw bytes,
because a pipe read boundary can split a PCM frame. Every poll rechecks that
the same route generation remains active before exposing bytes.

Block arrival is not source capture time. This adapter does not claim a
receiver-clock mapping or A/V synchronization; a later source clock service
must timestamp an accepted PCM boundary under a separate media contract. Call
`stop()` before revoking/destroying its private sink so cleanup failures remain
observable.

The route target in the protocol identifies receiver playback.  This source
boundary does not create a receiver sink, encode PCM, carry it over QUIC, map
the source clock to the receiver clock, or synchronize audio with a presented
video frame.  Those stages need an explicit media format/packet contract,
remote clock estimate, receiver-side output adapter, and live per-family
acceptance evidence.

## Current proof and remaining acceptance gates

The module has deterministic tests for family isolation, late stream binding,
generation replacement, route rejection, source-clock admission, explicit
resource retirement, failed-cleanup retry, and no-partial-restore preflight.
The Linux adapter tests record the exact `pactl` argv and fake JSON replies;
they never invoke a user's audio server. They do not exercise PipeWire,
PulseAudio, CoreAudio, WASAPI, encoded audio, transport, or physical playback.
Private-monitor capture tests use a fake process and assert exact bounded
monitor argv/lifecycle; they do not launch `parec` or access user audio.
They do not establish audio/video synchronization, audio latency, native
permissions, source restart recovery, or audible per-application isolation.

To integrate it, instantiate one runtime for each local source device, and feed it only
coordinator-approved `AudioRoute` updates and platform-observed
stream-to-window associations. Invoke `shutdown()` on the native owner before
tearing down its audio-server client and preserve/report a cleanup failure
rather than treating process exit as successful restoration.
