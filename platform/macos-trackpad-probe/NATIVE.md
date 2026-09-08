# Native multitouch protocol experiment — version 12 / ABI 2

This replaces the version 3 generic Digitizer report with a native MT bridge
experiment. It is not a proven gesture implementation until physical testing
succeeds. It does not synthesize shortcuts or gesture CGEvents.

Installation status, 2026-09-08 17:07 EDT: corrected version 12 runs with
ABI 2/profile 1. AppleMultitouchTrackpadHIDEventDriver creates a native device
with parser 1000/options 39, correct surface/row/column metadata, and a
WindowServer user client. All five initialization reads and four writes
succeed; unknown features and input errors are zero. Physical input reports
remain zero: this is ready for a user-operated trial, not proof of gestures.
The fix uses public DriverKit CPU access for unmappable feature buffers and
implements the native 0xc8 configuration register, including explicit initial
state for DriverKit's raw allocation. See the
[runtime evidence](../../docs/evidence/macos-trackpad-20260907/native-v11-runtime.md).
Versions 7–8 used a separate standard digitizer profile 2 for diagnosis; the
installed version is back on the native bridge protocol documented below.

The user reported that version 11 gestures respond but roll back on finger lift.
Version 12 routes normal all-up through stop/inactive/empty completion, orders
native timestamps, and retries failed completion before starting a new gesture.
Offline regressions and signed deployment pass; physical retest is pending.
See the [gesture-end fix](../../docs/evidence/macos-trackpad-20260907/native-v12-gesture-end.md).

## Native path and evidence

The macOS 27 M4 installation contains `Trackpad HID Bridge - MT` in
AppleTopCaseHIDEventDriver's Info.plist. It matches VendorID 0x05ac, ProductID 2,
Mouse usage 0x01/0x02, and configures the native MT parser (type 1000, options 39).
The experiment uses those matching identifiers, while its product, manufacturer
and serial explicitly name Viewflow. This is a protocol compatibility identity,
not a claim of physical Apple hardware. No system driver/plist is modified.

The implementation combines a mouse/native report descriptor, packed native
contacts, and feature-report initialization. Unknown feature requests return an
error and are counted/logged, so a missing handshake cannot look like success.
It is not sufficient to change only the IDs or descriptor.

Protocol field layouts and initialization values were researched using:

- [VoodooInput simulator implementation](https://github.com/acidanthera/VoodooInput/blob/master/VoodooInput/VoodooInputSimulator/VoodooInputSimulatorDevice.cpp)
- [VoodooInput packed field documentation](https://github.com/acidanthera/VoodooInput/blob/master/VoodooInput/VoodooInputSimulator/VoodooInputSimulatorDevice.hpp)
- [Linux hid-magicmouse decoder](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c)
- The above matching personality read from this Mac, not assumed from an Intel machine.

The encoder is byte-oriented independent code; this directory does not bundle
the VoodooInput kernel extension. Native M4 initialization remains an experiment.

## Wire format

SSH header: `VFTP 02 00 00 00`. Each snapshot is 72 bytes:

| Offset | Field |
|---|---|
| 0 | Number of meaningful contact records, including explicit lifts, 0..5 |
| 1 | Physical primary button, 0/1 |
| 2..3 | Reserved zero |
| 4..7 | Little-endian scan timestamp in 100 microsecond ticks, modulo 2^32 |
| 8..9 | Surface width 16000 (0.01 mm) |
| 10..11 | Surface height 11490 (0.01 mm) |
| 12..71 | Five 12-byte contact records, unused records zero |

A contact is: ID (0..14), down (0/1), X u16, Y u16, pressure u8, major u8,
minor u8, size u8, angle (0..7), finger classification (0..6). XY range is
0..32767. This version uses the known Magic Trackpad 2/USB-C physical surface;
it is not a calibration protocol for arbitrary devices.

Linux preserves stable IDs, button-only changes, pressure, contact diameters and
orientation. It resynchronizes slots **and button state** after SYN_DROPPED.
The evdev file uses CLOCK_MONOTONIC timestamps. The kernel does not expose raw
Apple Size or anatomical finger identity through these evdev fields: Size uses
mean contact diameter and classification uses ordinary finger (2). These are
explicit approximations to evaluate in physical acceptance, not raw-HID parity.

The driver turns each snapshot into a 12-byte native header plus 9 bytes per
contact, including packed signed 13-bit coordinates, begin/move/end state,
button, timestamp, pressure and contact dimensions. Feature requests expose
sensor initialization and surface metadata. Disconnect cleanup sends lifted,
inactive and empty reports, retaining state on failure for retry. No frame-age
security cutoff is used.

## Read-only installation check

On Mac:

```sh
/Applications/VFTrackpadHost.app/Contents/MacOS/VFTrackpadHost --driver-status
```

Expected ABI=2 and native_profile=1. `native_multitouch_attached` must be true
before offering a physical trial. It checks for AppleMultitouchDevice below
this driver, not any unrelated physical trackpad. Inspect feature_gets,
feature_sets, unknown_features and last_feature_request to diagnose handshake
failures. `status_call_submits_input=false` describes this status invocation;
`submitted` describes the driver's input history.

The existing development Allow Any UserClient entitlement and valid development
profiles are retained. SIP remains enabled. A successful signature or status ABI
alone does not prove native device attachment or usable gestures.

## User-operated trial

For combined Viewflow coordinate and HID operation, keep the HID receiver
connected and add `--route-config /run/user/1000/viewflow/macos-cursor.json` to
the forwarding command. This follows the compositor's actual capture phase
and matching Mac peer/output, not keyboard focus or a guessed cursor position.
On return to Linux it sends the contact/button release and suppresses local
snapshots while preserving SSH. Entering Mac resumes content on that same
connection. The standalone command below forwards unconditionally and is only
for a dedicated manual test, not combined cross-desktop use.

Only after the native attachment check passes, run on Linux:

```sh
python3 /home/wilf/data/viewflow/platform/macos-trackpad-probe/linux_native_forward.py inspect --device /dev/input/event17
python3 /home/wilf/data/viewflow/platform/macos-trackpad-probe/linux_native_forward.py forward --device /dev/input/event17 --ssh linhaikuo@172.16.105.83
```

The sender refuses an incompatible ABI or missing native device before reading
physical input. **It never grabs the touchpad**: Linux keeps receiving input,
so local gestures may also occur. Ctrl-C stops forwarding. Physical tests remain
user-operated. The sender prints report/peak-contact statistics when it stops.
On Mac, compare current_contacts/peak_contacts/button_transitions with the user's
actual action and observe native gestures separately. No automatic input replay.

## Offline checks

```sh
python3 -m unittest discover -s platform/macos-trackpad-probe -p 'test_*.py'
c++ -std=c++17 -Wall -Wextra -Werror platform/macos-trackpad-probe/native_protocol_test.cpp -o /tmp/vf-native-test
/tmp/vf-native-test
```

These validate five contact packing, signed coordinates, stable IDs, button-only
changes, retained failed cleanup and feature request/response framing. They do
not substitute for the macOS native service and physical gesture checks.

Version 3's `linux_forward.py`, descriptor and tests remain for historical
comparison; its ABI 1 does not connect to the version 4 driver. The pre-native
source archive and Mac host backup provide rollback without deleting unrelated
Viewflow work. Production Viewflow's QUIC input backend is unchanged.
