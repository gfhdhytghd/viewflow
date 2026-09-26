# Viewflow macOS virtual HID receiver

Separate macOS 26+ receiver using CoreHID `HIDVirtualDevice` and the managed
`com.apple.developer.hid.virtual.device` entitlement. No DriverKit extension
is needed for this receiver. The existing Viewflow.app / DriverKit deployment
is not modified by its build or invocation.

This receives Viewflow **VFTP v2 trackpad snapshots**, using the existing native
descriptor, feature handshake, contact encoder, timestamp ordering and
lift/inactive/empty release sequence. It is not arbitrary USB passthrough or a
new keyboard forwarding protocol. Viewflow's existing keyboard path remains
separate. Apple native multitouch attachment has been verified on the target
Mac, and the user accepted the live forwarding trial on 2026-09-21.

Validation on 2026-09-21: the receiver compiled successfully for arm64 on
`linhaikuo@172.16.105.83` (macOS 27, Xcode-beta), in the isolated directory
`/Users/linhaikuo/viewflow-hid-receiver.ixBsdN`. Native protocol regressions,
three provisioning validation tests, and the macOS fake-driver stream/socket
tests passed. The latter reported zero OS input submissions. The receiver was
not launched. After enabling HID Virtual Device on the existing
`org.viewflow.trackpad-corehid-probe` App ID through Apple Developer, Xcode
generated profile `d32f1441-97dc-4651-8cc4-a777850f5534` for team `9887KU7FN7`.
The decoded profile contains `com.apple.developer.hid.virtual.device = true`
and expires on 2027-09-21 at 16:56:59 UTC. Use
`--bundle-id org.viewflow.trackpad-corehid-probe` when building with this profile.
The subsequent SSH build compiled but codesign returned
`errSecInternalComponent`; querying the login keychain in that SSH session
returned `User interaction is not allowed`. Repeating the build through the
Mac Codex shell reproduced both errors and produced no signed app.

The user subsequently completed the signed build in the Mac's local terminal.
An independent SSH `codesign --verify --strict` check passed, then the signed
receiver's `--probe` returned exit 0 with these results:

```json
{"event":"activated","input_submitted":0,"serial":"Viewflow-UserHID-MT-v1"}
{"counters":{"feature_errors":0,"feature_gets":5,"feature_sets":4},"event":"probe_complete","input_submitted":0,"native_multitouch_attached":true}
```

This confirms device creation, the feature handshake and serial-specific native
multitouch attachment. The probe sent no input reports. The subsequent live
forwarding trial was user-operated and accepted ("非常好用"); concurrent producer
integration and notarized distribution remain unverified.

## Current default deployment (2026-09-21)

At the user's request, the accepted signed bundle was copied to
`/Applications/ViewflowHIDReceiver.app` and its signature was verified again.
The Linux `viewflow-macos-hid.service` now selects that executable via the
persistent user-unit drop-in
`~/.config/systemd/user/viewflow-macos-hid.service.d/zzzz-corehid-default.conf`.
The temporary runtime trial override was removed. The enabled display topology
supervisor retains startup and route selection ownership; normal Linux/Mac
route switching and both configured Mac viewports are preserved.

This changes the configured physical trackpad sender's default receiver. It
does not replace `/Applications/Viewflow.app`, its keyboard/window helpers, or
its shared socket backend. To roll back, remove only the CoreHID default drop-in,
reload user systemd and restart `viewflow-macos-hid.service`; the older topology
drop-in then selects the original GUI receiver, which must be running with HID
enabled. The existing app and DriverKit installation are retained for rollback.

## Provision and build

Account approval does not update an old provisioning profile. In Apple
Developer Certificates, Identifiers & Profiles, enable **HID Virtual Device**
for an explicit App ID (default `org.viewflow.hid-receiver`), then generate and
download a new macOS profile containing the entitlement. Use a signing
certificate covered by that profile. If the capability is enabled on an
existing App ID instead, supply that ID with `--bundle-id`.

See [Apple's managed capabilities instructions](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities)
and [HIDVirtualDevice](https://developer.apple.com/documentation/corehid/hidvirtualdevice).
The email alone does not establish which distribution methods are enabled;
check those in the account before preparing a Developer ID release.

On the Mac, with full Xcode selected (adjust its path if needed):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 platform/macos-hid-receiver/build.py \
  --profile /absolute/path/receiver.provisionprofile \
  --identity 'Apple Development: YOUR NAME (CERTIFICATE ID)' \
  --output /absolute/path/ViewflowHIDReceiver.app
```

The builder checks the profile's app ID, team, expiry and virtual HID grant,
then checks the resulting signature and signed entitlements. It does not
install, launch, change permissions, or notarize the app. A build/signature
check is not proof of device creation or gestures.

## Initialization-only check

```sh
/absolute/path/ViewflowHIDReceiver.app/Contents/MacOS/ViewflowHIDReceiver --probe
```

This creates the virtual device and handles feature requests, but **never
dispatches input reports**. It observes the receiver's own serial-numbered
IORegistry subtree for up to 30 seconds. JSON diagnostics go to stderr:
creation, activation, feature counters and `native_multitouch_attached`.
Exit 0 means native attachment, 1 creation failure, 3 no attachment observed.
The observation deadline is not used in receive mode.

## User-operated forwarding trial

The receiver accepts `--receive-stdin`, compatible with the existing
`platform/macos-trackpad-probe/linux_native_forward.py --receiver` option.
Use the existing authenticated SSH transport and point the sender's remote
receiver path at this app's executable (the sender adds `--receive-stdin`). Its
`--driver-status` compatibility entry point runs the initialization-only check
and prints the VFTP ABI/profile status JSON to stdout. Preserve the
sender's normal device selection and routing settings. Do not send the same
physical stream to both this receiver and the DriverKit receiver during a trial.

Each process owns one virtual trackpad and consumes one ordered stream. This
standalone receiver does not yet replace the GUI's shared `hid.sock` arbitration
for concurrent desktop and window producers. Do not select it as that shared
backend until those paths are integrated and tested.

EOF or malformed input follows the existing stream release path; a failed
release is retried before process exit. Device teardown on process exit removes
the virtual device. Incoming clocks are replaced with the receiver's monotonic
clock. There is no focus requirement, frame-age cutoff or gesture timer.

Physical acceptance is user-operated: movement, short clicks, multi-finger
gestures, lifting all fingers, and disconnect while touching. Feature counters
and successful dispatch calls alone do not establish acceptance.
