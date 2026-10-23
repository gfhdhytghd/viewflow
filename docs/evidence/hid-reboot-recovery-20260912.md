# HID restart recovery — 2026-09-12

After the user rebooted the Mac, Linux reconnected and activated cursor lease 2.
The Mac receiver rejected its first DesktopPointerPosition with InjectionFailed:
`macOS event posting permission missing; grant Accessibility access to the receiver in System Settings`.
The Linux source treated that ACK as unmatched because streaming cursor input
intentionally does not await per-event Applied acknowledgments. Capture stayed
remote; the HID driver later reported 1279 received reports and zero errors.
Those counters did not establish working cursor motion. Stopping Linux HID and
cursor services released capture from phase 3 to phase 0, and the user confirmed
local touchpad recovery.

## Changes

- Explicit InjectionFailed ACKs are delivered independently of pending per-event
  waiters. Cursor capture checks the target, current lease, and sent sequence.
- A matching failure immediately releases local capture before requesting remote
  held-state cleanup. A delayed cleanup receipt cannot keep local input captive.
- Missing/slow Applied ACKs do not trigger this recovery. Motion remains streamed
  without a per-event round trip; no frame-age or cursor-motion cutoff was added.
- The local `viewflow-macos-input.service` now binds its lifetime to
  `viewflow-macos-hid.service` via `95-hid-lifecycle.conf`. An actual HID transport
  exit also retires local capture, even if the cursor QUIC connection survives.

## Validation

20 cursor handoff tests passed, including an explicit injection failure with an
unanswered remote revoke and a stale-generation failure that must be ignored.
Existing tests also retain input without per-event Applied ACKs. The Linux
`vf-cursor-peer` binary built successfully and systemd unit verification passed.
Services remain stopped pending user restoration of macOS Accessibility access.
No mouse or keyboard input was injected for testing. The earlier half-second
physical touch-onset delay is not explained or proven fixed by this recovery.

## Resumed input and unified installation (18:00 EDT)

At the user's next request, the installed app's `viewflowd --macos-input-status`
reported `event_post_authorized=true`; the driver reported
`native_multitouch_attached=true` and zero errors. The Linux input and HID
services were restarted at 17:57:22 using the previously built recovery fix.
The cursor QUIC connection established and clock probes continued at roughly
0.7–1.2 ms RTT. Its route remained local during the observed interval. A
user-operated Mac crossing and return was requested; no new crossing sample or
user result had arrived, so real cursor recovery and touch-onset latency are
not asserted by this evidence.

72 legacy paths (62 app bundles, the old standalone application binary, six
launch-agent files, and three companion files) were archived on the Mac under
`Library/Application Support/Viewflow/legacy-archive`. Legacy agents were
unloaded and disabled. The old independent presenter exited. Process inspection
showed app-owned components, the app's stdin relay and the system HID extension;
the source checkouts, pairing identity, and current app runtime were retained.

`dist/macos/Viewflow-0.1.0-arm64.dmg` contains the unified application with five
helpers and the HID extension. All seven binaries passed arm64 checks and had
only system/relative dynamic dependencies. Embedded hashes, deep/strict app
signature, Finder positions and the disk image checksum passed validation.
The DMG uses the existing Apple Development signing identity; notarization was
not performed. Installation artwork was rendered from AppKit at 2x density and
inspected with native app/folder icons; a Finder UI screenshot was not taken.
The updated application was installed without restarting active input workers.
The same DMG was copied to the Mac Downloads folder.
