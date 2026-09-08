# Version 3 physical gesture acceptance: failed

2026-09-08: user reports multi-finger gestures do not work.
Read-only SSH inspection observed submitted reports increasing from 2235 to 2681,
with errors=0. The final active_contacts value was false. This confirms successful
report submission; it does not prove multiple simultaneous contacts were encoded
correctly because ABI1 has no peak-contact or per-contact counters.

IORegistry: VFTrackpad -> IOHIDInterface -> AppleUserHIDEventDriver ->
IOHIDEventServiceUserClient (WindowServer). InputReportCount tracks submissions;
WindowServer queue counters show delivered events (LastEventType=11).
No Apple multitouch-specific service is visible under this virtual device.

The descriptor is a generic Digitizers/Touch Pad with five Finger collections,
logical XY only; physical dimensions/units, pressure, contact area, scan time,
feature reports, and Apple-specific reporting are absent. The current data cannot
isolate malformed/incomplete reporting from a missing native gesture integration.
Do not label successful enumeration, signing, or handleReport calls as native
multitouch support. Next diagnosis needs decoded multi-contact telemetry and a
comparison with Apple's native trackpad reporting and service chain.

No input was injected by the agent during this investigation.
