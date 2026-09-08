# CoreHID signing result — blocked by ungranted capability

## Follow-up after root source fix — 2026-09-08 16:11 EDT

Root's unsigned build log rechecked: BUILD SUCCEEDED. Retried Xcode GUI signed build after the ProtocolData.swift fix; automatic provisioning still fails with the same missing HID Virtual Device capability/Apple approval errors below. Refreshed Developer App ID page: Capability Requests → HID Virtual Device remains Submitted. Current profile remains d21d56e4-9493-4f57-a4d7-be768c3fc991, whose decoded entitlement dictionary still lacks com.apple.developer.hid.virtual.device.

Stage classification: **compile PASS; normal signing/provisioning BLOCKED; app creation NOT TESTED; Accessibility/TCC NOT TESTED; native feature dialogue NOT TESTED.** No runtime failure or native protocol conclusion can be inferred from this signing blocker. No Swift edits, deployment, execution or DEXT6 changes were made in this follow-up.

Verified 2026-09-08 approximately 16:07–16:11 America/New_York.

## Outcome

Opened CoreHIDProbe.xcodeproj through desktop CUA and built using Xcode automatic development signing, My Mac. Unsigned root build log says BUILD SUCCEEDED; no Swift edits made here. GUI signed build failed during provisioning. No properly signed app was deployed or run, so no runtime feature replies, serial-specific IORegistry subtree, or corehid-probe-run.log was produced by this task.

## Actual account evidence (not only Xcode inference)

Apple Developer App ID configuration: https://developer.apple.com/account/resources/identifiers/bundleId/edit/R945YJ9R8B

Bundle `org.viewflow.trackpad-corehid-probe` (explicit), team `9887KU7FN7`.

- Full ordinary Capabilities list shows DriverKit (development), DriverKit Allow Any UserClient (development), DriverKit Family HID Device (development), and DriverKit Transport HID (development), but no HID Virtual Device development toggle. These DriverKit capabilities were not enabled for this separate CoreHID app.
- Capability Requests lists **HID Virtual Device**, identifier HID_VIRTUAL_DEVICE, with **Submitted** button.
- Clicking Submitted opened read-only Request History: request **949M5UA4HW**, requested **August 25, 2026**, by **Haikuo Lin**, type **Team**, status **Submitted**. This predates this task. No new request was submitted.

## Actual generated development profile

`/Users/linhaikuo/Library/Developer/Xcode/UserData/Provisioning Profiles/d21d56e4-9493-4f57-a4d7-be768c3fc991.provisionprofile`

- Name: Mac Team Provisioning Profile: org.viewflow.trackpad-corehid-probe
- UUID: d21d56e4-9493-4f57-a4d7-be768c3fc991
- Created 2026-09-08 20:07:37 UTC, expires 2027-09-08 20:07:37 UTC; Xcode-managed OSX profile.
- Includes current Mac provisioning UDID `00008132-000161422E38801C`; verify-profile-device.py PASS.
- Decoded Entitlements contains only com.apple.application-identifier = 9887KU7FN7.org.viewflow.trackpad-corehid-probe, com.apple.developer.team-identifier = 9887KU7FN7, and keychain-access-groups = 9887KU7FN7.*. **com.apple.developer.hid.virtual.device is absent.** Device inclusion is not the blocker.

## Exact Xcode errors

> Provisioning profile "Mac Team Provisioning Profile: org.viewflow.trackpad-corehid-probe" doesn't include the HID Virtual Device capability. HID Virtual Device capability needs to be assigned to your team and bundle identifier by Apple in order to be included in a profile.

> Entitlement com.apple.developer.hid.virtual.device requires approval from Apple to include in a profile. Please request access to the associated capability. To continue building for device during request processing, remove entitlement and add upon approval.

The entitlement was NOT removed or bypassed. Existing pending team request plus absent capability in the freshly generated profile prevents normal signed deployment at this time; this is not a claim that every DriverKit development capability requires approval.

## Safety and handoff

SIP verified enabled. Installed DEXT6 was not changed. No ad-hoc signing, synthetic input, dispatchInputReport, receive-stdin, focus tests, Accessibility grant, driver kills or restart. Source review confirms this prototype responds to feature requests and has bounded observation loops; it was not executed without a valid profile. Resume normal GUI signing after HID Virtual Device is granted and included in a matching development profile. No distribution/special request submitted and no messages sent to other people.
