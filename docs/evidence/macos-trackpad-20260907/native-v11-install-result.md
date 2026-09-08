# Corrected v11 installation COMPLETE — ready for root normal restart

## Superseding successful result — 2026-09-08 16:49 EDT

After root's normal restart, verified /Applications host embeds version11 and expected executable SHA256 `4f25c32c326eccfbe66231306462a87d7193936bed8c47c5ea518a4220451f0c`. No rebuild was needed. Normal desktop CUA Request Driver Installation returned “Activation completed. Device enumeration and gestures have NOT been verified.”

- **Installed corrected v11:** `/Library/SystemExtensions/CB4C64DF-4224-4FD0-9959-3954F5CFA58F/org.viewflow.trackpad-probe.dext`; Info.plist version11; strict signature validation PASS. Installed executable SHA256 exactly matches embedded/expected `4f25c32c326eccfbe66231306462a87d7193936bed8c47c5ea518a4220451f0c`.
- Host deep/strict signature validation PASS. Installed DEXT and host profile verification both PASS for this Mac: b935fc60-a890-4161-a7df-db559f4f5db9 and e5eff746-99b1-442c-8788-aeaa3229a446.
- systemextensionsctl: v11 activated enabled; v10 terminating for upgrade via delegate.
- **Actually running: v10 PID297**, executable under B208E020-B23B-4C2E-A7AF-D7BD63E700E4, not newly installed v11.
- sysextd 16:49:07.115 explicitly delegates v10 termination “with uninstallation at the next reboot”. Root may now perform the final authorized normal restart to run corrected v11. This task did not restart.
- Read-only status from current v10: ABI2, native_profile1, native_multitouch_attached=true, submitted0, errors0, feature_gets5, feature_sets4, unknown_features0, last_feature_request258; all contact/button/release counters0, status_call_submits_input=false. These are not v11 runtime results.
- SIP verified enabled. No input/focus tests, source edits, driver kills or SIP changes.

### Error terminology correction / failure history

SDK SystemExtensions.h line52 explicitly defines `OSSystemExtensionErrorExtensionNotFound = 4`. Earlier error4 is **ExtensionNotFound**, not a dedicated pending-upgrade error. The concurrent two-entry sysextd log is contextual evidence only. One final pre-restart retry at 16:47:22 returned the same failure and two-entry log; retries stopped. Earlier “corrected-v10” artifact labels are superseded: the corrected embedded artifact was verified as version11. Historical observations below are preserved.

## Historical unsuccessful pre-restart attempt

2026-09-08 16:46 EDT. No restart performed.

## Source and GUI build

- Verified current VFTrackpad.cpp init line20 explicitly sets `ivars->features.mode=8;` after IONewZero/null check. Serial line45 is `Viewflow-Native-MT-v11`; source Info.plist CFBundleVersion is 11.
- Source mtime 16:41:56; source SHA256 `57919b3d32c8ae8994747ad66cede0fe9f65825f89e91f5320be56e08473f4ff`. Info.plist SHA256 `e9eb8a82e58ea24cad22609880cd264624ef1a9eda977680b94216a8cd830378`.
- After latest message, Xcode GUI driver Build Succeeded 16:45; copied GUI product into build-signed embed source; host GUI Build Succeeded 16:45. No source edits.
- Xcode incremental build retained signed time **16:42:36**, which is newer than observed correction source mtime. It did not generate a fresh signing timestamp at 16:45. Current signed product Info.plist and installed host-embedded DEXT both verify version **11**.
- Host deep/strict signature validation passed. DEXT/host device profile verification PASS: b935fc60-a890-4161-a7df-db559f4f5db9 / e5eff746-99b1-442c-8788-aeaa3229a446, team9887KU7FN7.
- Host-embedded DEXT executable SHA256 `4f25c32c326eccfbe66231306462a87d7193936bed8c47c5ea518a4220451f0c`.
- Backups: `installation-backups/DEXT-before-native-v11.dext`, `installation-backups/VFTrackpadHost-before-native-v11.app`. Earlier v9 and pre-correction backups preserved.

## Normal installation rejected

GUI Request Driver Installation at 16:46 returned:

`Installation failed: OSSystemExtensionErrorDomain (4): The operation couldn’t be completed. (OSSystemExtensionErrorDomain error 4.)`

sysextd at 16:46:19.913: `activateDecision found two entries for teamID("9887KU7FN7") org.viewflow.trackpad-probe in state:`

- B208E020-B23B-4C2E-A7AF-D7BD63E700E4: activated_enabled (pre-correction v10).
- 01B670A3-0AA3-462F-AEC2-8255E4657973: terminating_for_upgrade_via_delegate (v9).

systemextensionsctl still lists only registered v10 and terminating v9; **no installed v11**. Actual driver remains v9 PID311 from 01B670A3 path. The pending registered v10 is not corrected v11. New version number did not bypass the outstanding upgrade state.

Corrected v11 host is present in /Applications, but normal system activation must be retried after the outstanding state is resolved. Cannot honestly satisfy “restart only once corrected11 installed” under this observed state. No force kills, source edits, input/focus tests, SIP changes, restart, or system-extension database manipulation performed. Root must choose the next normal recovery step; do not interpret this report as successful v11 deployment.
