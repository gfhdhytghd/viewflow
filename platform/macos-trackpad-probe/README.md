# macOS DriverKit trackpad experiment

Version 4 adds native MT bridge report encoding, initialization feature reports,
button/pressure/geometry forwarding and contact/handshake diagnostics. See
[NATIVE.md](NATIVE.md). Local offline tests and the Mac unsigned DriverKit build
pass. Corrected version 12 is installed and running with the native trackpad
bridge, parser 1000/options 39, correct sensor metadata and a WindowServer
native user client. Public DriverKit CPU access resolves feature-buffer mapping
failures; a stateful configuration register resolves the remaining write
retries. All initialization requests succeed with zero unknown features.
Version 11's user trial found gestures roll back on finger lift; version 12
fixes the missing inactive-contact phase on normal all-up and orders end-frame
timestamps. Offline regressions pass; physical gesture retest is pending.
See the [gesture-end fix](../../docs/evidence/macos-trackpad-20260907/native-v12-gesture-end.md).
See the [runtime evidence](../../docs/evidence/macos-trackpad-20260907/native-v11-runtime.md)
and the trial command in [NATIVE.md](NATIVE.md).

Version 3's generic Digitizer path successfully enumerated and received reports,
but the user reported no multi-finger gestures. That is a failed gesture gate,
not evidence that native multitouch works. See the
[review](../../docs/evidence/macos-trackpad-20260907/hid-gesture-review.md).

## What is implemented

- `VFTrackpadRoot`: IOUserResources-backed service creating an AppleUserHIDDevice
  child through `TrackpadProperties`; version 2 was verified active on the Mac.
- `VFTrackpad`: IOUserHIDDevice subclass publishing a mouse/native MT bridge
  descriptor, explicit feature replies and packed contacts.
  Version 4 uses protocol-matching identifiers documented in NATIVE.md.
- `VFTrackpadClient` and `TrackpadBridge.swift`: ABI 2 report submission,
  read-only counters and disconnect cleanup through a signed host user client.
- `linux_inventory.py`: reads the actual device's descriptor and axis capability
  ranges, without reading input events, grabbing the device or changing focus.
- `linux_native_forward.py`: nonexclusive physical forwarding of contacts and
  clicks, plus pressure/geometry. The old linux_forward.py is ABI 1 only.
- Offline Python and C++ state/encoding tests pass; the native version 4 DEXT
  builds on the Mac. Native gesture acceptance is still pending.

## Reproduce

On Linux:

```sh
python3 platform/macos-trackpad-probe/linux_inventory.py
c++ -Wall -Wextra -Werror platform/macos-trackpad-probe/dump_descriptor.cpp -o /tmp/vf-descriptor
/tmp/vf-descriptor > /tmp/vf-descriptor.bin
```

The descriptor was independently parsed with Linux `hid-tools`:

```python
from pathlib import Path
from hidtools.hid import ReportDescriptor
r = ReportDescriptor.from_bytes(Path('/tmp/vf-descriptor.bin').read_bytes()).input_reports[1]
assert r.application == 0x000d0005  # Digitizers / Touch Pad
assert r.size == 32
assert sum(f.usage == 0x000d0051 for f in r.fields) == 5
```

Copy this directory to the Mac and run `./build.sh`. Override `DEVELOPER_DIR`
if Xcode is installed elsewhere. Output is
`build/Debug-driverkit/org.viewflow.trackpad-probe.dext`.
The Xcode project does not automatically contact the developer portal, sign,
install or activate anything. `entitlements.plist` is a starting request template;
it does not confer privileges and must match Apple's eventual profile.

## Next gates

1. Install version 4 with the existing development signing setup.
2. Verify ABI 2, feature dialogue and AppleMultitouchDevice attachment without
   input. If native attachment fails, investigate logged requests before testing.
3. Complete user-operated gestures and click acceptance following NATIVE.md.
4. Integrate only a verified backend into production Viewflow transport.

No 33 ms session cutoff or focus restriction is added. Physical input tests
remain user-operated under the repository policy.

References:
- https://developer.apple.com/documentation/hiddriverkit/iouserhiddevice
- https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development
- https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice (reference for service creation and registration; this probe does not bundle its driver)

See [the evidence](../../docs/evidence/macos-trackpad-20260907/README.md).
