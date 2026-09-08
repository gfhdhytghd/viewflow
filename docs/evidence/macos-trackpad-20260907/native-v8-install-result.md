# v8 installation COMPLETE — ready for root normal restart

2026-09-08 16:29 EDT. Normal GUI installation completed. Root may now perform the authorized normal restart; this task did not restart or kill the driver.

## Build, backups, signatures

- Desktop CUA Xcode: VFTrackpadProbe Build Succeeded 16:27; VFTrackpadHost Build Succeeded 16:28. No source edits. Signed DEXT copied from GUI DerivedData output to existing build-signed embed source before GUI host build.
- Previous embed DEXT preserved at `installation-backups/DEXT-before-native-v8.dext`; previous installed v7 host preserved at `installation-backups/VFTrackpadHost-v7-before-native-v8.app`.
- Installed host `/Applications/VFTrackpadHost.app` passes deep/strict signature verification; embedded DEXT CFBundleVersion 8.
- Installed v8 DEXT `/Library/SystemExtensions/7D91883A-076D-4077-ABB3-8CFB7CE7C1E5/org.viewflow.trackpad-probe.dext` passes strict signature verification; Info.plist version 8.
- Apple Development: Haikuo Lin (5843T48V3V), Team 9887KU7FN7, signed 16:27:51. Actual DEXT signature includes driverkit, driverkit.allow-any-userclient-access=true, driverkit.family.hid.device and development get-task-allow.
- DEXT profile b935fc60-a890-4161-a7df-db559f4f5db9 and host profile e5eff746-99b1-442c-8788-aeaa3229a446 authorize this Mac; verification PASS. Installed DEXT profile separately rechecked PASS.
- Installed and host-embedded DEXT executable SHA256 both `dc20ccd711d53da55f91c6e2cf42da4793e9d2e1ea3e6685a2b8e69becd47b7f`.
- Request Driver Installation GUI returned “Activation completed. Device enumeration and gestures have NOT been verified.”

## Actual running version remains 7

systemextensionsctl: v8 `(0.1/8) [activated enabled]`; v7 `(0.1/7) [terminating for upgrade via delegate]`.

Actual PID **293** executes `/Library/SystemExtensions/832824B0-0718-4094-9576-83BD4F4BF191/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe`; that bundle's Info.plist version was verified **7**.

sysextd 16:29:14.928: `turning the responsibility for termination of org.viewflow.trackpad-probe, version 7 over to delegate (with uninstallation at the next reboot)`.

Read-only host --driver-status (from still-running **v7**, NOT v8):

```json
{"abi":2,"active_contacts":false,"button_down":false,"button_transitions":0,"current_contacts":0,"errors":0,"feature_gets":15,"feature_sets":0,"last_feature_request":127,"last_report_contacts":0,"last_scan_ticks":0,"native_multitouch_attached":true,"native_profile":2,"peak_contacts":0,"releases":0,"status_call_submits_input":false,"submitted":0,"unknown_features":1}
```

v8 CPU-copy fallback has not yet run in the active driver. Its behavior requires post-restart read-only verification by root; native attachment above is a v7 observation, not evidence for v8 fallback success or gestures.

SIP verified enabled. No input injection, gesture/focus tests, receive-stdin, source edits, driver kills or restart. Existing CoreHID request unchanged. Old installer host was quit normally before replacement.
