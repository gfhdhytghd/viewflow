# Source capture-path diagnostic snapshot

Inspection found `profile_shared_capture` reading `direct_source->bands` after
`direct_lock.unlock()`. The capture callback replaces that shared_ptr under the
source mutex. Reading the same shared_ptr object without that mutex is a race
and can also describe a later capture instead of the adopted frame.

Snapshot `captured_bands` beside `captured_staging`, while the source lock is
held, and use that boolean for adoption selection and the later diagnostic.
Actual shared_ptr adoption remains under the lock. No new locks, GPU commands,
copying, scheduling restrictions, or encoding changes.

Windows Release `viewflow_windows_reverse` rebuilt successfully in the existing
`fusion-20261007/build-16k` candidate directory. Normal executable/task unchanged;
no deployment or GPU test. This is a measurement-correctness fix with no claimed
latency improvement. Research jobs were not modified.
