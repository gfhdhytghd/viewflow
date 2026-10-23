# Shared physical-bank arbitration for early SHM2 references

Frames now provides begin_progressive/acquire_progressive over the actual
control header and pixel banks. Callers must negotiate SHM2 before use; live
sender/receiver do not yet invoke these APIs. Normal SHM1 remains deployed.

Legacy slot state4 reserves a physical bank while SHM2 owns it. SHM1 writer
claims only0/2, reader only2, recovery only1/3, so even old binaries skip4.
SHM2 reader ownership remains in its generation-specific progressive header.
A writer can atomically discard an unclaimed ready generation, then reclaim a
free progressive header's reservation. An active reader or writer prevents
reclamation. Stale SHM2 references must still claim and compare identity before
reading. Aborted writer+active reader stays reserved until reader releases.
Mapping recovery repairs same-side progressive state under the existing process
lock and reaps only truly unused reservations. No wall-clock cutoff introduced.

New progressive_bank test passes Linux and Windows Release. It holds three
legacy-reader banks and a fourth SHM2 reader, proves neither writer path can
reuse that bank, checks writer recovery preserves the reader, verifies ready
reference retirement and aborted-reader holding, and races retirement against
reader acquisition200times. Existing SHM1 regression passes separately.

This is prerequisite plumbing, not end-to-end deployment or latency evidence.
Old binaries intentionally do not reclaim state4; rollback after enabling SHM2
will need both sides stopped/drained and reservations cleaned by a SHM2-aware
endpoint. Until that transition is implemented, do not enable SHM2 in production.
