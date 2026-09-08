# Standard digitizer native-service experiment, version 7

The installed Mac's AppleMultitouchDriver Info.plist contains personality
`AppleMultitouchHIDService (0x0D,0x04)`, with provider IOHIDInterface, class
AppleMultitouchHIDService, DeviceUsagePairs 13/4, and Manufacturer Apple.
Unlike the previously matched native bridge personality, it has no
BuildAMDWithMTInit property in that plist. This supports testing a different
entry point, but does not prove that it avoids all initialization queries.

Version 7 publishes the matching standard Digitizers/Touch Screen collection
with five logical fingers, stable contact IDs, tip/confidence/in-range, XY,
physical surface units, width, height, pressure, contact count, scan time and
primary button. Manufacturer is a required compatibility identifier for this
observed personality. Product/serial explicitly identify the Viewflow experiment;
this is not a claim of physical Apple hardware. No system plist is modified.

The existing ABI 2 wire and ownership/release state remain. An adapter converts
the native contact representation to the standard 60-byte report. Version 7
reports protocol profile 2; the current sender intentionally does not assume
this is ready for physical acceptance.

Validation before installation: C++ tests pass for five contacts, coordinate
conversion, pressure, primary button and release. Independent hid-tools parse
confirms application 0x0d0004 and report 1 length 60. Unsigned DriverKit build
passes on the Mac. Native service attachment and gestures remain unverified.
