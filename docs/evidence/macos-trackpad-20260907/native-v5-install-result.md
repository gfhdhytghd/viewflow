# Native v5 installation result

Verified 2026-09-08 15:31–15:32 America/New_York.

## Outcome

DEXT v5 and host were built/signed successfully through desktop CUA Xcode (Build Succeeded at 15:30 and 15:31). Signed DEXT copied into the existing build-signed embed source; GUI-built host embeds CFBundleVersion 5. Normal host UI Request Driver Installation returned “Activation completed. Device enumeration and gestures have NOT been verified.”

**v5 is installed/registered, but v4 is still actually running. Update is deferred until a normal reboot; no reboot was performed. v5 callback changes have NOT received runtime verification.**

## Signing and profiles

- Installed host: `/Applications/VFTrackpadHost.app`; deep/strict codesign verification passed.
- Installed v5 DEXT: `/Library/SystemExtensions/9E5AFF95-B66B-4F22-B36E-0FA1FB6AE017/org.viewflow.trackpad-probe.dext`; strict codesign verification passed.
- Apple Development: Haikuo Lin (5843T48V3V), TeamIdentifier 9887KU7FN7; driver signed 15:30:21.
- Actual driver signature contains driverkit, driverkit.allow-any-userclient-access=true, driverkit.family.hid.device, development get-task-allow, exact application identifier 9887KU7FN7.org.viewflow.trackpad-probe.
- Actual host signature retains system-extension.install, app-sandbox and IOUserUserClient IOKit exception; no exact userclient-access request.
- Device verification script PASS for DEXT profile `b935fc60-a890-4161-a7df-db559f4f5db9` and host profile `e5eff746-99b1-442c-8788-aeaa3229a446`: both authorize this Mac. Installed DEXT profile also rechecked PASS.
- Installed and host-embedded DEXT executable SHA256 agree: `10a5440cfa535df9841a78ad69a4f032c1d88237e8e4d7acf1ed660155beceae`.

## Actual runtime / deferred upgrade

systemextensionsctl lists v5 `(0.1/5) [activated enabled]`, v4 `(0.1/4) [terminating for upgrade via delegate]`.

Actual PID **303** still executes `/Library/SystemExtensions/70F3ACEE-EB0F-41AC-86E7-CEF8D70E8BF3/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe`; its bundle CFBundleVersion is **4**.

sysextd at 15:31:37.980: `turning the responsibility for termination of org.viewflow.trackpad-probe, version 4 over to delegate (with uninstallation at the next reboot)`.

Read-only `/Applications/VFTrackpadHost.app/Contents/MacOS/VFTrackpadHost --driver-status` returned from **v4**, not v5:

```json
{"abi":2,"active_contacts":false,"button_down":false,"button_transitions":0,"current_contacts":0,"errors":0,"feature_gets":4,"feature_sets":0,"last_feature_request":0,"last_report_contacts":0,"last_scan_ticks":0,"native_multitouch_attached":false,"native_profile":1,"peak_contacts":0,"releases":0,"status_call_submits_input":false,"submitted":0,"unknown_features":0}
```

VFTrackpad subtree: AppleUserHIDDevice `0x100000c88` → IOHIDInterface `0x100000c8b` → AppleMultitouchTrackpadHIDEventDriver `0x100000c8d`. No AppleMultitouchDevice. Product Viewflow Native MT Protocol Experiment, MaxInputReportSize 1388. No claim that v5 resolved initialization or that v5 diagnostic logs ran.

## Backups / boundaries

- Previous installed v4 host preserved at `installation-backups/VFTrackpadHost-v4-before-native-v5.app`.
- Previous embed DEXT preserved at `installation-backups/DEXT-before-native-v5.dext`.
- Existing Xcode signing configuration retained. No C++/Swift edits, no distribution requests, no synthetic input, receive-stdin, focus tests, force kill, or messages to other people.
- `csrutil status`: System Integrity Protection status: enabled.
- Next verification requires user-controlled normal reboot, then process-path/version confirmation and read-only status/log inspection.
