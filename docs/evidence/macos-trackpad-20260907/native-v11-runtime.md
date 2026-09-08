# Corrected version 11: native initialization passed

2026-09-08, normal reboot at 16:50:52 EDT. Actual PID 297 runs
`/Library/SystemExtensions/CB4C64DF-4224-4FD0-9959-3954F5CFA58F/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe`.
Only version 11 is activated/enabled. Its installed executable matches the
signed embedded artifact SHA256
`4f25c32c326eccfbe66231306462a87d7193936bed8c47c5ea518a4220451f0c`.
Signature/profile checks and installation recovery history are in
[native-v11-install-result.md](native-v11-install-result.md).

The [runtime tree](native-v11-runtime-tree.json) shows:

- AppleMultitouchTrackpadHIDEventDriver → AppleMultitouchDevice → native
  AppleMultitouchDeviceUserClient created by WindowServer PID 172.
- Native parser 1000, options 39; surface width 16000, height 11490;
  sensor rows 22, columns 30; Critical Errors 0.
- Viewflow product and serial `Viewflow-Native-MT-v11` on the actual chain.

Read-only host status: ABI 2, native_profile 1, native attachment true,
feature_gets 5, feature_sets 4, unknown_features 0, last_feature_request 258.
Input errors, submissions, contacts, button transitions and releases are all
zero. The status operation does not submit input.

The [initialization log](native-v11-feature-log.txt) records successful get
reports 0, 1, 0xdb and 0xc8, successful query/configuration writes 1 and 0xc8,
and successful mode report 2 at 16:50:58. Every callback returns status 0.
Public DriverKit CPU-copy operations complete successfully for the previously
unmappable external buffers. No synthetic inputs were sent.

Offline validation: native C++ contact/cleanup/feature tests pass, including
configuration-byte write/readback and malformed-write state preservation.
All eight Python forwarding tests pass. The final sources compile and sign
through Xcode. Linux inventory still identifies the physical Magic Trackpad
at /dev/input/event17, with 16 slots and pressure/geometry axes; inventory did
not read events or grab the device.

This is native initialization and deployment acceptance only. Real scrolling,
pinch/rotation and three/four-finger gestures require the user's physical test.
The forwarding command and stop procedure are in
[NATIVE.md](../../../platform/macos-trackpad-probe/NATIVE.md).
