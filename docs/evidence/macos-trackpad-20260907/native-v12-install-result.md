# v12 installation COMPLETE — ready for root normal restart

2026-09-08 17:04 EDT. Normal desktop CUA installation completed. Root may now perform the authorized normal restart; this task did not restart.

## Build, signatures, profiles and backups

- Xcode GUI VFTrackpadProbe Build Succeeded 17:02; host Build Succeeded 17:03. Signed DEXT copied into existing build-signed embed source before GUI host build. No source edits.
- v11 backups: `installation-backups/DEXT-before-native-v12.dext` and `installation-backups/VFTrackpadHost-v11-before-native-v12.app`.
- Installed host `/Applications/VFTrackpadHost.app` passes deep/strict signature validation; embedded DEXT version12.
- Installed DEXT `/Library/SystemExtensions/4087A9C6-83A1-48EC-AC94-3BC69BBB9CDC/org.viewflow.trackpad-probe.dext`: Info.plist version12; strict signature validation PASS.
- Apple Development: Haikuo Lin (5843T48V3V), Team9887KU7FN7, signed 17:02:32.
- Installed/host-embedded DEXT executable SHA256 both `87e5641fedb87611c08b2b48f24b77f9b8c56b6b93fb206b81a91dc47a8cfe9a`.
- Installed DEXT profile b935fc60-a890-4161-a7df-db559f4f5db9 and host profile e5eff746-99b1-442c-8788-aeaa3229a446 authorize this Mac; device verification PASS.
- GUI Request Driver Installation returned “Activation completed. Device enumeration and gestures have NOT been verified.”

## Installed 12 versus running 11

systemextensionsctl lists v12 activated enabled and v11 terminating for upgrade via delegate. Actual PID297 remains under `/Library/SystemExtensions/CB4C64DF-4224-4FD0-9959-3954F5CFA58F/org.viewflow.trackpad-probe.dext/org.viewflow.trackpad-probe` (v11).

sysextd 17:03:53.972 explicitly delegates version11 termination “with uninstallation at the next reboot”. v12 lifecycle behavior has not yet been runtime tested.

Read-only --driver-status returned from **v11**, not v12:

```json
{"abi":2,"active_contacts":false,"button_down":false,"button_transitions":4,"current_contacts":0,"errors":0,"feature_gets":5,"feature_sets":4,"last_feature_request":258,"last_report_contacts":0,"last_scan_ticks":225130153,"native_multitouch_attached":true,"native_profile":1,"peak_contacts":4,"releases":0,"status_call_submits_input":false,"submitted":3804,"unknown_features":0}
```

submitted3804 is the observed accumulated v11 counter; this task did not submit input. Do not report submitted0 or attribute these existing submissions to this installation task. No gesture/focus tests were performed.

SIP verified enabled. No source edits, input injection, receive-stdin, driver kills or restart. Old installer host quit normally before replacement. CoreHID request unchanged. Root should confirm v12 process path after restart before interpreting lifecycle results.
