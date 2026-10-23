# Native process priority comparison

2026-09-09. The private candidate requests Normal priority for its own process only. Its main thread and 15 sampled threads move from base 6 to 8; ten lower-priority threads move from 4 to 6. The task remains priority 7. All changes are private to the bounded native child, with no registry or installed program change.

| Trial | Distinct FPS | Median upper ms | P95 upper ms | Maximum upper ms |
|---|---:|---:|---:|---:|
| priority-off-a1 | 32.503 | 81.307 | 98.581 | 148.805 |
| priority-on-b1 | 32.829 | 79.314 | 96.158 | 146.071 |
| priority-on-b2 | 32.713 | 83.419 | 100.090 | 101.230 |
| priority-off-a2 | 32.743 | 76.419 | 93.699 | 159.582 |

The repeated distributions overlap and median/P95 reverse direction, so Normal process priority is not adopted. The 39-file local and Windows source maps match; the tracker test passes. Actual process/thread snapshots are in each transport state.json.
