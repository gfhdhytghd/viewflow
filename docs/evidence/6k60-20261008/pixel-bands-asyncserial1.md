# Contention-preserving asynchronous trace queue

Replaced producer try-lock/drop with a mutex limited to copying a bounded record into the queue. Consumer still releases that lock before calling the potentially blocking sink. This prevents ordinary contention from discarding records; queue-full and oversized records remain explicitly counted. This is not wait-free: OS scheduling can delay mutex acquisition. No unbounded queue or sink I/O under producer lock.

Linux and Windows tests passed: blocked sink, bounded4096 capacity, overflow counters, oversized record rejection, drain, plus8 concurrent producers writing3200 uniquely identified records with no drops/duplicates and per-producer ordering preserved. Windows Release build passed.

physical-pixel-bands-asyncserial1: last observed periodic trace dropped=0;1326 decoded source markers and1326 host markers matched with no mismatch.1037 correlated band frames: callback-to-write median6.9092ms,P9513.1501ms,max43.4983ms; pre-publish diagnostics median0.010ms,P950.014ms,max0.090ms. These are observed samples only; final periodic status cannot certify forced-shutdown tail completeness.

Run INVALID/CONFOUNDED for sustained6K comparison: foreground changed once; last accept interval6016x3456 rather than6144x3456;1320 unique sequences with282 gaps.80 generation-to-feedback samples median39.600ms,P95133.823ms, not photon latency. Do not attribute aggregate regression to the queue without a matched workload.

Plugin inventory also changed during test: hymission0.8.0 handle changed from56125b6c2ae0 to56125b0d9350 and list order changed. Runner contains no hymission load/reload command; cause not established. Preserved current plugin state rather than trying to restore external changes. Other listed plugin identities unchanged. Our standalone deadline plugin unload returned ok and is absent in after inventory. Host binary restored SHA2562e3008638c8f9498668c1921ccca045306ab16bead216e7511ef76c468cf88d2; guest wrapper/probe/native restoration checks passed; Linux service active. No input/focus injection. Backup moved to build/ivshmem-backup/pixel-bands-asyncserial-native.backup.

Next usable baseline requires stable full6K residency and compositor/plugin state. Independent work can continue on source first-poll scheduling and pre-callback capture timing. Original sustained60fps and16.7ms end-to-end objective remains unachieved.
