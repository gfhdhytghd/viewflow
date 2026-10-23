# Progressive reference identity and initialization ordering

Extended ownership prototype with explicit initializing phase. begin reserves free slot and clears prefix while readers cannot acquire; announce release-publishes metadata after initialization. Abort is valid before announcement. publish_prefix rejects non-writer phases. A stale consumer must never infer metadata stability merely from a reused slot index.

Added independent SHM2 reference serialization (magic0x324d4853) with epoch,sequence,slot,width,height,capacity checks. ProgressiveFrame wraps immutable identity and ownership in128bytes. acquire claims ownership before identity check; mismatch rolls ownership back while preserving a ready newer generation even if writer completed concurrently. Complete publication requires exactly frame-height committed rows; oversized/non-monotonic prefixes rejected. Abort retains storage while reader holds it.

Linux optimized tests and Windows Release tests passed: updated2000-generation concurrent prefix visibility/ownership test plus version/extent/epoch/sequence/stale-reference/complete/abort checks. These are CPU-level tests; stale identity tests cover writing and completed states, not a randomized cross-VM stress test. No GPU-upload fence correctness or BAR coherency proof claimed.

Still isolated from current transport. SHM2 must not be sent to SHM1 consumers. Capability negotiation, mapped-slot lifetime, process crash recovery, early frame metadata delivery, progressive host uploads and complete-frame presentation integration remain required. No native production binary deployed, no service restart or desktop input/focus operation. No performance claim; original6K60/16.7ms objective remains unmet.
