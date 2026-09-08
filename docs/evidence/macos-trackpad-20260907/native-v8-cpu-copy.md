# DriverKit report CPU-copy experiment, version 8

Version 7 after the normal restart did create this native chain:
VFTrackpad → IOHIDInterface → AppleMultitouchHIDService →
AppleMultitouchDevice → AppleMultitouchDeviceUserClient (WindowServer).
Read-only status reports ABI 2, profile 2, 15 feature gets, zero sets,
one unsupported feature, and zero submitted input reports.

This is attachment evidence, not gesture readiness. Initialization feature
buffers still failed CreateMapping with 0xe00002bc. The native device used
parser type 1/options 16 and lacked SensorSurfaceDimensions. No physical
gesture test was requested on that basis.

Version 8 preserves the version 7 descriptor/profile and adds a fallback using
public DriverKit IODMACommand PrepareForDMA, PerformOperation and CompleteDMA.
PerformOperation is documented as CPU access to a supplied memory descriptor,
including copying to/from a driver-owned buffer. It does not submit hardware
DMA. The fallback only uses the report descriptor supplied to getReport or
setReport; it does not use physical addresses or modify system drivers.

Bounds are checked before copying, preparation is completed on both success
and failure, and the original asynchronous HID request is completed with the
operation result. Input encoding and producer/release behavior are unchanged.

The macOS DriverKit SDK build and signed GUI installation passed. After the
normal restart at 16:31:07 EDT, version 8 is the sole activated Viewflow DEXT.
At 16:31:13.597, CPU copy of the 74-byte 0xdb initialization report returned
success, followed by successful asynchronous getReport completion. The 0x73
request remains unsupported and is reported as such.

The native child now exposes Sensor Surface Width 16000, Height 11490,
Rows 22, Columns 30, and the supplied sensor descriptors. WindowServer has
its native user client attached; input submissions remain zero. The compact
runtime tree is saved beside this file as native-v8-runtime-tree.json.

Profile 2 still selects parser 1/options 16. Version 9 therefore restores the
original native bridge descriptor/profile 1, whose matching personality selects
parser 1000/options 39 for the existing packed contact encoding, while retaining
the verified CPU-copy fix. Physical gesture behavior remains untested.
