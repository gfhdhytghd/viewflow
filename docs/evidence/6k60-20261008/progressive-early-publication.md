# Windows staging early-reference publication

BandPublication now accepts a ProgressiveStorage writer as well as the existing
SHM1 writer. Readback.progressive is false by default and has no runtime enable
call yet. Its band-adoption path uses the cross-protocol bank reservation API.
On first poll it publishes one SHM2 reference before polling/copying any bands.
The same transaction remains alive until all bands are copied and marked
complete; final completion does not send a duplicate reference. Destruction
aborts the in-progress generation, preserving any active reader lease.

Progressive append now supports the existing streaming_rows/ParallelCopy path.
Prefix publication follows the existing streaming-store fences and all worker
completion. Frames passes its existing streaming/parallel settings. Plain-copy
storage tests and probes keep their previous default behavior.

Windows Release build and capture_staging_test passed on WARP17x13 and real
hardware6144x3456. Test callback acquires the reference while prefix is empty,
asserts exactly one callback, then checks every completed pixel. A callback
interruption followed by Readback destruction verifies the delivered reader
sees aborted state. Existing staging/crop/pool/atlas tests still pass. The6K
hardware suite passed again after enabling streaming/parallel copy inheritance.

No production deployment or source runtime enablement. Reader routing/polling
and capability lifecycle remain to be wired. Early callback timing fields are
-1 until completion; existing profile_shared_ready interpretation must be
updated when enabling this path. This is correctness/build evidence, not an
end-to-end latency or sustained-fps measurement.
