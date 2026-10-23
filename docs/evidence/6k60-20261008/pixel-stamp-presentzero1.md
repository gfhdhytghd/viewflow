# Present0 control - workload mismatch detected

Actual argv verified waitable present-zero.1602 valid pixel stamps/1604publications,1602unique,zero repeats. Generation-to-callback P50 12.119ms/P95 28.943ms;80 generation-to-feedback samples52.078/68.382ms. Foreground changes0. Runner exited0 and restored probe/native/wrapper with equality checks.

INVALID as equal-load60Hz comparison: fixture submitted710.068fps,waitable median0.167ms. A waitable object with maximum latency1 bounds queue occupancy, not necessarily refresh cadence under Present0.9252 sequence gaps represent unsampled/dropped high-rate generated frames; do not call them60Hz transport losses. Receiver aggregateacceptance~59.5–60fps does not fix this workload mismatch. No production speedup claim.

Added explicit60Hz steady-clock pacing to the opt-in present-zero control, skipping missed deadlines rather than catch-up bursts. This change is not yet Windows built/live measured. Also added default-off Linux decoded-pixel marker logging after acquiring frame ownership, to validate SHM pixels independently of Windows source logs. Host viewflow_linux_reverse build passed. No host diagnostic deployed. Goal remains unmet.
