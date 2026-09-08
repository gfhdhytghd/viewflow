# v7 installation COMPLETE — ready for root normal restart

2026-09-08 16:15 EDT. Normal installation completed; root may perform the authorized normal restart. This task did not restart.

## Build and signing evidence

- Desktop CUA Xcode GUI: VFTrackpadProbe Build Succeeded 16:13; VFTrackpadHost Build Succeeded 16:14. Original projects, My Mac (DriverKit) / My Mac destinations. No source edits or compiler errors.
- Signed DEXT copied into existing `build-signed/Build/Products/Debug-driverkit/org.viewflow.trackpad-probe.dext` embed source before GUI host build.
- `/Applications/VFTrackpadHost.app` embedded DEXT CFBundleVersion verified **7**. Host deep/strict codesign verification passed.
- Installed v7 DEXT: `/Library/SystemExtensions/832824B0-0718-4094-9576-83BD4F4BF191/org.viewflow.trackpad-probe.dext`; strict signature validation passed.
- Signature: Apple Development: Haikuo Lin (5843T48V3V), Team 9887KU7FN7, signed 16:13:59. Actual driver entitlements retain driverkit, driverkit.allow-any-userclient-access=true, driverkit.family.hid.device and development get-task-allow.
- DEXT profile b935fc60-a890-4161-a7df-db559f4f5db9 and host profile e5eff746-99b1-442c-8788-aeaa3229a446 authorize this Mac (verification script PASS). Installed DEXT profile also rechecked PASS.
- Installed/host-embedded executable SHA256 match: `b87299ecb61e899f26ee838ca05fc9e305e74896ea77fd57a69bb2611d7ae058`.
- Host GUI Request Driver Installation returned “Activation completed. Device enumeration and gestures have NOT been verified.”

## Actual running version — still v6

systemextensionsctl lists v7 `(0.1/7) [activated enabled]` and v6 `(0.1/6) [terminating for upgrade via delegate]`.

Actual PID **310** remains `/Library/SystemExtensions/257D17B6-0997-44B3-B326-62B91DE9E0CD/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe` (installed v6 path).

sysextd at 16:15:18.496: `turning the responsibility for termination of org.viewflow.trackpad-probe, version 6 over to delegate (with uninstallation at the next reboot)`.

Read-only --driver-status: ABI2, submitted0, errors0, releases0, all contact/button counters0, feature_gets4, feature_sets0, unknown_features0, native_profile1, native_multitouch_attached=false, status_call_submits_input=false. These values are from **v6**, not v7. v7 expected native_profile2 and Standard Digitizer personality remain unverified until restart. No native attachment claim is made for v7.

## Backups and boundaries

- Previous installed host: `installation-backups/VFTrackpadHost-v6-before-native-v7.app`.
- Previous embed DEXT: `installation-backups/DEXT-before-native-v7.dext`.
- SIP verified enabled. CoreHID request untouched. No input/focus tests, receive-stdin, source edits, driver kills or concurrent restart. Old installer host quit normally before replacement.
