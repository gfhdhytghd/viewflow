# Audio forwarding

The requested playback policies are:

| Setting | Playback location | Capture scope |
| --- | --- | --- |
| 不转发 | The application's source/owner machine | None |
| 在对应设备上播放 | The machine currently displaying the window | Application and its audio subprocesses |
| 在指定设备上播放 | One selected paired machine, including all other machines' system sounds and applications without shared windows | One system mix per source machine |

For an application with multiple main windows on different machines, the last
moved main window selects the application's output. Moving it home restores
local playback. Dialogs, menus, keyboard focus and hover do not select a new
output. The selected destination's own system audio remains local. Received
audio must be excluded from capture, not sent around the mesh again.

## Implementation status

This is currently backend work, **not a completed application feature**.
`AudioPlaybackMode` and `ApplicationAudioLocations` implement the policy and
application-lifetime/last-main-window state. The existing application UI and
window move pipelines do not yet feed this new state or supervise audio peers.
Do not present these three settings as operational until that wiring exists.

`vf-audio-peer` implements a separate authenticated QUIC audio connection,
using the existing pairing certificate format. A playback listener accepts
multiple sources concurrently; the native audio server mixes them. The wire
format is version 1 stereo 48 kHz signed 16-bit little-endian PCM: 240 frames
per datagram, an 8-byte magic/version and two 64-bit generation/sequence fields.
Each 984-byte packet fits a standard QUIC datagram. It uses about 1.536 Mbit/s
of PCM payload per source; no Opus compression is claimed.

The receiver starts with 15 ms of jitter allowance, reorders a bounded queue,
substitutes silence for missing packets, and resynchronizes on overflow or
clock underflow. These are audio-local recovery decisions. Audio does not
own or close window, video, or input connections. A separate A/V clock mapping
and measured synchronization with displayed video are not implemented yet.

Native helper contract:

- Capture writes raw PCM to stdout and observes stdin EOF for shutdown.
- Playback reads raw PCM from stdin and exits on EOF.
- Helpers restore their native routes on normal shutdown. They must not leave
  a forwarding route active after their supervising connection disappears.
- Stderr contains diagnostics, never raw PCM. Helpers must preserve full PCM
  frames across pipe reads/writes. Transport may discard whole datagrams.

### Linux

`platform/audio/linux_audio.py` uses PipeWire's PulseAudio interface (`pactl`,
`parec`, `pacat`). Capture creates a private null sink and moves selected
sink inputs to it. System scope includes new streams as they appear, including
system sounds. Application scope follows the selected process and descendants,
checking root process start ticks against PID reuse. It does not change the
user's default output. The original output of each moved stream is restored
on exit; a user move away from the private sink is preserved at cleanup.
Viewflow playback is tagged `org.viewflow.audio.playback` and excluded.

Run the helper through the installed Python interpreter, for example:

```json
{
  "program": "/usr/bin/python3",
  "args": ["/absolute/path/linux_audio.py", "capture", "--scope", "application", "--pid", "1234"]
}
```

For whole-system capture use `capture --scope system`. Playback is `playback`.

### macOS

`platform/audio/macos_audio.mm` uses Core Audio process taps and AVAudioEngine
playback. It uses `CATapMutedWhenTapped` to suppress source playback only while
the tap is being read. Destruction restores normal playback. It updates process
selection/exclusions, and system scope excludes other `viewflow-audio` helpers.
The audio converter emits the common PCM format on a bounded worker queue.
This helper requires macOS 14.2 or later and native audio capture permission.
`macos_app.mm` supplies an accessory AppKit host for the standalone audio bundle,
so its transport and capture helpers have an application identity for privacy.
The private aggregate includes the current output device as its clock source,
and its IO callback runs on an explicit serial dispatch queue. The personal
deployment is signed; integration into the main product installer remains open.

Build with `cmake -S platform/audio -B <build>` on macOS. The same helper uses
`playback`, `capture --scope system`, or
`capture --scope application --pid <pid> [--pid <pid> ...]`.

Apple's [Core Audio taps documentation](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
describes the source API; compile success is not permission or audible proof.

### Windows

`platform/audio/windows_audio.cpp` implements WASAPI playback and process
loopback PCM capture. `capture --scope application --pid <pid>` captures a
process tree. `capture --scope system --exclude-pid <Viewflow-root-pid>` excludes
the supervisor's entire process tree, including playback helpers.

**Source suppression is not implemented/verified yet.** This capture helper
currently copies audio; it must not be enabled by a shipping forwarding mode
that promises source playback will stop. `--probe-session-mute` checks whether
process capture remains nonzero while muting the probe's own isolated render
session. It does not touch other applications or master volume. This informs
whether a native session path suffices or a virtual output is required.

The WindowsVM at `172.16.105.131` now has the official VB-CABLE Pack45
(driver 3.3.1.7) installed, with valid installer, driver and Microsoft catalog
signatures. The original missing-device blocker is resolved. Playback, recording
and MEDIA device status are OK. `--probe-cable` rendered a known tone and
captured it through the cable recording endpoint (peak 33), without a reboot.

The process-loopback suppression probe measured peak 33 unmuted and only 1
muted (dither/noise floor), so muting the application is **not** a working source
suppression strategy on this VM. The probe now requires a meaningful fraction
of the tone rather than treating any nonzero sample as success. Source routing
to a private virtual output still needs integration. VB-CABLE was installed
on this VM separately; it is not included in the Viewflow installer. Microsoft's
[application loopback sample](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)
describes the capture API, not source suppression.

## Verification so far

- Core tests cover all three policy decisions, no duplicate system capture,
  last-main-window moves, return home, stale updates and application lifetime.
- Wire tests reject truncated/unknown packets and verify byte-exact PCM.
- A real loopback QUIC test with temporary native fixtures verifies received
  PCM and capture EOF cleanup after disconnect. It accesses no audio device.
- Linux fake-server tests cover playback exclusion, late streams, restoring
  observed outputs and preserving a user reroute.
- A real PipeWire check used only a synthetic source on a temporary null sink:
  captured peak 999, source restored, default output unchanged, helper exit 0.
  Temporary sinks were removed. This does not establish physical playback.
- Native helpers compile with the actual Mac Apple SDK and Windows MSVC.

Remaining integration includes application settings/persistence, authenticated
policy propagation across paired devices, committed main-window move events,
source helper supervision, signed/bundled native helpers, Windows source
suppression, and real cross-device playback/A/V acceptance. These are required
before the requested feature can be called complete.

## Current personal configuration: Linux destination

The current configured destination is Linux (`172.16.105.62`), using its normal
`alsa_output.pci-0000_02_00.1.hdmi-stereo` output. Local Linux audio remains local.
Two independent receiver services preserve each existing pairing identity:

- `viewflow-audio-windows.service`: UDP 44311, original Windows/Linux pairing.
- `viewflow-audio-macos.service`: UDP 44310, current Mac/Linux mesh pairing.

The Windows logon task `Viewflow Audio to Linux` runs the source from
`%LOCALAPPDATA%\Viewflow\audio\send.json`. System capture excludes its own
process tree (`--exclude-pid 0` resolves to the helper's PID). The default
Windows output is the installed virtual cable. An interactive-session test tone
was received on Linux and measured at its real HDMI sink monitor, peak 33.
A tone launched through SSH belongs to a different Windows audio session and
must not be used as the acceptance test for the interactive logon source.

The Mac launch agent `org.viewflow.audio-to-linux` uses
`~/Library/Application Support/Viewflow/audio/send.json` and the separate
`/Applications/Viewflow Audio.app` bundle, signed with the user's Apple
Development identity. Its AppKit host starts the transport helper and maintains
the responsible application identity; the LaunchAgent declares
`AssociatedBundleIdentifiers = [org.viewflow.audio]`. Direct QUIC connects to
Linux UDP 44310. A known tone measured peak 64 at capture and 65 at the real
Linux HDMI sink monitor. Both Mac and Windows playback streams use sink 73,
unmuted and uncorked; Linux's default output remains unchanged.
Stopping the Mac audio host caused the LaunchAgent to relaunch it with a new
transport/capture process tree; a second tone again measured 65 at Linux's
output monitor. No orphan capture process remained after that restart.

During diagnosis the user's saved Local Network permission was confirmed to
allow this application, while actual background UDP sends returned OS error 65
(`No route to host`). Direct connectivity recovered after native app hosting,
standard application installation and registration; the exact OS policy/cache
transition was not isolated. A temporary SSH proxy was removed and is not part
of the deployment. SSH-launched capture had a separate, explicit TCC denial
attributed to sshd; it was not evidence that the user's app grant was absent.
After connectivity recovered, the original aggregate/callback arrangement
produced no useful samples. Adding the output clock device and explicit IO
queue produced the verified end-to-end signal. Physical listening and A/V sync
remain user acceptance checks.

During sustained Windows testing, quinn-proto 0.11.17's drop-oldest datagram
path panicked because it decremented the outgoing byte count twice. The audio
source now uses the non-dropping send API with immediate cancellation when
blocked, dropping that whole PCM block locally without ending the session.
The Windows stream has subsequently run for multiple minutes without the panic.
