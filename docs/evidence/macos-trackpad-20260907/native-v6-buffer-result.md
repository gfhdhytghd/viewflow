# Native initialization buffer failure, versions 5–6

2026-09-08. The user authorized normal Mac restarts for this driver work,
with automatic login. Both restarts were requested normally through System
Events and verified by changed boot times and successful SSH reconnection.
No physical input was injected.

## Runtime evidence

- v5 boot: 15:33:39 EDT; only v5 activated/enabled, ABI 2, submitted=0.
- v6 boot: 15:39:27 EDT; only v6 activated/enabled, ABI 2, submitted=0.
- v6 installed host deep/strict signature verification passed; embedded DEXT
  CFBundleVersion=6. SIP remained enabled.
- Native bridge matching succeeds; AppleMultitouchDevice remains absent.

Both versions log four initialization feature reads with:

```text
id=0 type=2 length=2 capacity=0 bytes=2 status=0xe00002bc action=1
```

In v6 these occur at 15:39:33.255–256. The native driver subsequently reports
`Failed to get device initialized state. Result = 0xe00002bc`.

Version 5 fixed callback error completion: the native caller now receives the
original error instead of kIOReturnAborted. Version 6 replaced internal Map
with the public CreateMapping API, but mapping still returns kIOReturnError.
Thus the API correction is valid cleanup, not a demonstrated initialization fix.

## Scope of the finding

The supplied descriptor has logical length 2. Mapping fails before any feature
reply bytes are written. No evidence yet implicates the contact encoder or
gesture settings. No unknown feature request has been received.

Apple's [CreateMapping documentation](https://developer.apple.com/documentation/driverkit/iomemorydescriptor/createmapping)
describes external memory mapping and ownership of the returned IOMemoryMap.
The driver now follows that API and releases the mapping before completion.
The [published AppleUserHIDDevice source](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/AppleUserHIDDevice.cpp)
forwards getReport's supplied descriptor directly, whereas setReport has a
separate copy into a shared buffer for some descriptors. That suggests an
incompatibility with the native caller's buffer allocation; it does not prove
the exact implementation or cause on macOS 27.

A separate non-seizing, read-only IOHIDDeviceGetReport probe could not proceed:
IOHIDDeviceOpen returned 0xe00002e2. No permission was bypassed, no feature was
written, and no input report was submitted. This did not test an alternative
buffer allocation successfully.

Current status: native multitouch is NOT usable or physically accepted. The
remaining work is to establish a supported way to return this native feature
reply across the kernel/DriverKit boundary, or evaluate another supported HID
transport. More restarts of this same code would not resolve the finding.
