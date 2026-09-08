# Version 4 after restart — 2026-09-08

Read-only verification of the user's Mac confirms boot time 02:51:59 EDT,
only version 4 activated/enabled, ABI 2, and the expected native product.
No input reports were submitted by this check.

Status: submitted=0, errors=0, feature_gets=4, feature_sets=0,
unknown_features=0, last_feature_request=0, native_multitouch_attached=false.

The actual VFTrackpad subtree is now:

```text
VFTrackpad (AppleUserHIDDevice)
  IOHIDInterface
    AppleMultitouchTrackpadHIDEventDriver
```

Thus native bridge matching succeeded, but no AppleMultitouchDevice child
was created. Do not confuse another physical Bluetooth mouse's native child
with this Viewflow device.

Boot logs at 02:52:05.372 show four identical sequences:

```text
Viewflow MT getReport id=0 bytes=2
AppleMultitouchHIDEventDriverV2::simpleGetReport [0x100000c8d]
returned 0xE00002EB for reportID 0x00
```

Then `Failed to get device initialized state. Result = 0xe00002eb`.
The SDK defines this as kIOReturnAborted. This is an initialization failure,
not a contact-count or user gesture failure.

Version 4 logs before mapping and completes its callback only on success.
Consequently its counters do not distinguish mapping/length failure from a
completion problem. Apple's published AppleUserHIDDevice implementation aborts
pending requests when their action is disposed without completion:
[AppleUserHIDDevice.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/AppleUserHIDDevice.cpp).
That is a plausible explanation, not yet a proven origin of this Mac's error.

Version 5 preserves the native protocol and adds original-error completion on
every callback path, report type/logical length/mapping capacity/status logging,
and uses the logical length for setReport parsing. Unsigned Mac build passed.
Signed deployment and subsequent initialization diagnosis remain pending.
