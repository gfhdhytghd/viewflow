# Five-contact SSH forwarding experiment (version 3)

Historical ABI 1 path. Version 4 uses [NATIVE.md](NATIVE.md) and
`linux_native_forward.py`; the old sender is not compatible with ABI 2.

This extends the enumeration probe with a DriverKit user client and a physical
Linux input sender. Native macOS gesture recognition is still unverified.
Do not interpret successful `handleReport` submission as a delivered gesture.

## Data path

Linux Magic Trackpad evdev MT slots → full contact snapshots → stable HID contact
IDs → SSH stdin → signed host executable → VFTrackpadClient → VFTrackpadRoot →
VFTrackpad::handleReport → the macOS HID event system.

SSH uses the user's existing authentication and ordered stream. There is no
new unauthenticated LAN listener. One producing user client owns the virtual
trackpad at a time; status clients do not acquire ownership. DriverKit checks the
driver's development user-client access entitlement. No focus or capture-freshness checks and
no 33 ms expiry are introduced.

The first eight stream bytes are `VFTP 01 00 00 00`, followed by fixed 32-byte HID
reports. Report ID 1 contains up to five six-byte contact records (flags, ID,
little-endian X/Y) and the count in byte 31. Coordinates are 0..32767. Count
includes explicit lifted contact records. Unused records are zeroed.
A read can split anywhere; the receiver accumulates complete reports and rejects
truncated input. Invalid reports do not change the driver's last successful state.

This initial descriptor/transmission deliberately has only IDs, positions and
contact flags; pressure, contact area, orientation, scan time, haptics and feature
reports are not implemented. Linux can expose more than five slots; the sender
keeps up to five existing contacts stable and admits additional fingers as space
becomes available. More slots do not imply support for more simultaneous HID
contacts in this prototype.

## User-operated trial

First, install version 3 through the normal signed host app. Both the DEXT and
host profiles must include this Mac. The current development configuration uses
`com.apple.developer.driverkit.allow-any-userclient-access=true` on the DEXT,
backed by DriverKit Allow Any UserClient (development) in its development profile.
The host retains its sandbox IOKit class permission and installation entitlement;
it does not request the separately managed `userclient-access` capability.
This configuration permits any local application to attempt a user-client
connection. It is for development builds only, not distribution. SIP stays enabled.
Confirm the entitlement in the actual driver signature and profile before testing.

Read-only Mac check (does not acquire input ownership or submit a report):

```sh
/Applications/VFTrackpadHost.app/Contents/MacOS/VFTrackpadHost --driver-status
```

The returned ABI must be 1. Before the first test, submitted/release/error
counters should be zero and active_contacts false. Counters reset when the
installed driver process restarts.

On Linux, first find/confirm the current device; event numbers are not stable:

```sh
python3 platform/macos-trackpad-probe/linux_inventory.py
python3 platform/macos-trackpad-probe/linux_forward.py inspect --device /dev/input/event17
```

When ready to physically test, the user runs:

```sh
python3 platform/macos-trackpad-probe/linux_forward.py forward \
  --device /dev/input/event17 --ssh linhaikuo@172.16.105.83
```

The first trial leaves Linux input handling active, so local desktop gestures
may occur too. Do not use `--grab` for initial gesture acceptance: it removes
this touchpad from Linux input while the sender runs, even if Mac gestures do
not work. Exclusive routing is an explicit later option and releases on exit.
Start with fingers lifted. The sender checks
Mac driver status before grabbing/forwarding. SSH host-key verification and
existing keys are preserved. No password is written into the sender.

Ctrl-C closes the stream; the Mac receiver requests release, then closes its user
client. DriverKit also releases on client Stop if the receiver dies. A failed
release retains the last active state for retry; a new producer must release it
successfully before submitting new touches. A driver/OS failure can still prevent
release delivery. SSH keepalives detect a broken connection independently of the
frame-rate target. Linux SYN_DROPPED triggers a full MT-slot resynchronization.

Manually check: single/two/five contacts, one finger lifting while others remain,
pinch, rotation, three/four-finger swipes, desktop animations, stopping the sender
while touching, and reconnecting. Record physical behavior separately from driver
submitted counters. No automated test in this directory injects touch reports.

## Offline verification

```sh
python3 -m unittest discover -s platform/macos-trackpad-probe -p 'test_*.py'
c++ -std=c++17 -Wall -Wextra -Werror \
  platform/macos-trackpad-probe/report_state_test.cpp -o /tmp/vf-report-test
/tmp/vf-report-test
```

The tests use in-memory snapshots and a recording/failing submission callback.
They cover ID reuse, simultaneous replacement, over-capacity recovery, coordinate
mapping, SYN_DROPPED, invalid reports, retained failed-release state and cleanup.
This is an isolated feasibility bridge; it does not change the production
Viewflow QUIC input backend, which still rejects native macOS touchpad frames.
