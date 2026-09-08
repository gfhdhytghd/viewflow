# CoreHID initialization probe

This separate app uses Apple's public CoreHID HIDVirtualDevice API to return
native feature replies as Data. It uses the same descriptor and feature values
as the version 4–6 DriverKit native bridge. It never dispatches an input report.
The process exits after a bounded initialization observation (30–60 seconds).

Unsigned Xcode build passes on the M4 macOS 27 host. Normal development signing
is currently unavailable: the freshly generated profile lacks
com.apple.developer.hid.virtual.device, and the developer account shows an
existing team request still Submitted. No new request or workaround was used.
See the [account verification](../../../docs/evidence/macos-trackpad-20260907/corehid-install-result.md).

After Apple grants this entitlement, build with automatic signing in Xcode,
inspect the resulting profile/entitlements, and run the signed app executable.
Its JSON output distinguishes creation failure, initialization requests, and a
serial-specific AppleMultitouchDevice attachment. Physical forwarding is not
implemented in this probe yet; no gesture success has been claimed.
