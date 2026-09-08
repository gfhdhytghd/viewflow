# v9 installation COMPLETE — ready for root normal restart

2026-09-08 16:34 EDT. Normal GUI installation completed. Root may now perform the authorized normal restart; this task did not restart or kill any driver.

## Build / signature / backups

- CUA desktop Xcode: VFTrackpadProbe Build Succeeded 16:33; VFTrackpadHost Build Succeeded 16:34. No source edits or compilation errors.
- GUI-signed DEXT copied into `build-signed/Build/Products/Debug-driverkit/org.viewflow.trackpad-probe.dext` before GUI host build.
- v8 embed backup: `installation-backups/DEXT-before-native-v9.dext`; v8 installed host backup: `installation-backups/VFTrackpadHost-v8-before-native-v9.app`.
- Installed host `/Applications/VFTrackpadHost.app`: deep/strict signature validation passed; embedded DEXT version 9.
- Installed DEXT `/Library/SystemExtensions/01B670A3-0AA3-462F-AEC2-8255E4657973/org.viewflow.trackpad-probe.dext`: strict signature validation passed, Info.plist CFBundleVersion 9.
- Apple Development: Haikuo Lin (5843T48V3V), team 9887KU7FN7, signed 16:33:14. Actual DEXT signature retains driverkit, driverkit.allow-any-userclient-access=true, driverkit.family.hid.device and development get-task-allow.
- Profiles authorize this Mac: DEXT b935fc60-a890-4161-a7df-db559f4f5db9; host e5eff746-99b1-442c-8788-aeaa3229a446. Device verification PASS, including separate installed DEXT profile recheck.
- Installed and host-embedded DEXT executable SHA256 match: `3f43168aeba0171c823038db6400ae0a8d2c3d44f20ea2bcc409a80a479c8b7b`.
- GUI Request Driver Installation returned “Activation completed. Device enumeration and gestures have NOT been verified.”

## Installed v9 versus running v8

systemextensionsctl lists v9 `(0.1/9) [activated enabled]`, v8 `(0.1/8) [terminating for upgrade via delegate]`.

Actual PID **300** remains `/Library/SystemExtensions/7D91883A-076D-4077-ABB3-8CFB7CE7C1E5/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe`; its Info.plist version was verified **8**.

sysextd 16:34:33.930: `turning the responsibility for termination of org.viewflow.trackpad-probe, version 8 over to delegate (with uninstallation at the next reboot)`.

Read-only --driver-status from still-running **v8**, not v9:

```json
{"abi":2,"active_contacts":false,"button_down":false,"button_transitions":0,"current_contacts":0,"errors":0,"feature_gets":2,"feature_sets":0,"last_feature_request":115,"last_report_contacts":0,"last_scan_ticks":0,"native_multitouch_attached":true,"native_profile":2,"peak_contacts":0,"releases":0,"status_call_submits_input":false,"submitted":0,"unknown_features":1}
```

v9 profile1/native bridge behavior remains unverified until root restarts and confirms actual process version. Above native attachment is v8 evidence only, not a v9 or gesture success claim.

SIP verified enabled. No physical/synthetic input or focus tests, receive-stdin, source edits, driver kills or restart. CoreHID request unchanged. Old installer host quit normally before replacement.
