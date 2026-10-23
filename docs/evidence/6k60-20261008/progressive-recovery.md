# Progressive side-specific recovery

Added recovery primitive exposed through ProgressiveFrame. It is valid only after acquiring existing same-side exclusive process ownership and ensuring that side's abandoned GPU DMA no longer uses the mapping. This is a resource-lifetime precondition, not a timing/security cutoff.

Writer recovery frees initializing/writer-only/unclaimed-ready states, changes writer+reader to aborted-reader, and preserves complete/aborted reader-held storage. Reader recovery removes reader ownership from concurrent writing, frees complete/aborted reader states and unclaimed-ready snapshots, while preserving writer-only initialization/writing. CAS loops account for simultaneous progress by the surviving opposite side. Prefix bytes are not cleared or rewritten. Recovery is idempotent.

Linux optimized and Windows Release state/frame tests passed. Coverage: all7states for each side, idempotence, prefix preservation,200races of reader recovery against live writer finish/abort, plus existing2000generation visibility and stale-reference/extent checks. Completion/recovery race permits ready or free when successful because either ordering is valid; cancelled race must end free. This is CPU-level proof, not real process-kill/DMA/IVSHMEM acceptance.

New protocol remains unadvertised/unintegrated. A writer completing after reader recovery can still leave ready data; integration needs explicit retirement when its delivery reference is discarded, or replacement of unclaimed complete frames with identity-protected acquisition. Negotiation and progressive GPU upload remain outstanding. No production binaries/services/plugins changed; no input/focus operations. No new performance claim; original6K60/16.7ms goal remains unmet.
