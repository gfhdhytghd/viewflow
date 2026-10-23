# Deferred drains with explicit WGC cadence

This candidate combines the qualified deferred-drain gate and two/four admission bounds with the isolated WGC minimum-interval override. All six runs use the same executable. The source logs prove the requested and actual interval, VPL depth two, three input surfaces and admission limit.

| Trial | WGC interval us | Outer limit | FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|---:|---:|
| combinedzero-four-a1 | 0 | 4 | 57.108 | 57.486 | 58.417 | 274.209 |
| combineddefault-two-b1 | 16000 | 2 | 54.819 | 66.510 | 71.993 | 88.728 |
| combineddefault-two-b2 | 16000 | 2 | 55.054 | 59.683 | 76.317 | 78.692 |
| combinedzero-four-a2 | 0 | 4 | 59.057 | 58.399 | 58.959 | 75.654 |
| combinedzero-two-c1 | 0 | 2 | 59.059 | 56.895 | 73.291 | 89.583 |
| combinedzero-two-c2 | 0 | 2 | 55.643 | 69.877 | 70.659 | 86.718 |

Both zero-interval/four-frame trials meet the unchanged 30 FPS and upper-envelope P95 at most 60 ms criterion, at 57.11/59.06 FPS and P95 58.42/58.96 ms. The first run still has a 274.21 ms maximum; no hard delay bound is claimed. The two-frame settings are variable and do not meet the criterion in these samples. Longer observation and the explicit reverse-only cadence API candidate are being validated before deployment.

69 local/remote inputs match, six Windows CTests pass, every transport output is the exact ordered accepted prefix, and the bounded-stop tails are recorded. Native identities, restored modes and private cleanup pass. Installed C914 remains unchanged. These results exclude physical scanout.
