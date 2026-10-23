# Two-frame outer limit with a two-task encoder

An isolated copy changes the public latency mode admission limit from one to two, leaving frame-rate at four. The one corresponding expected-value test is updated. All other source files match the installed canonical snapshot; 69 local/remote inputs match and six Windows CTests pass. The same executable runs four/two/two/four, using actual controller readback, source mode logs, queue occupancy and the same VPL depth-two pool.

| Trial | Outer limit | FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|---:|
| depthlimit-four-a1 | 4 | 54.465 | 63.003 | 63.803 | 80.382 |
| depthlimit-two-b1 | 2 | 48.460 | 64.762 | 81.850 | 99.497 |
| depthlimit-two-b2 | 2 | 48.509 | 68.278 | 85.089 | 87.023 |
| depthlimit-four-a2 | 4 | 53.993 | 59.210 | 75.749 | 78.442 |

The two-frame limit falls to 48.46–48.51 FPS and raises P95 to 81.85–85.09 ms; four-frame controls are 53.99–54.46 FPS with P95 63.80–75.75 ms. It is rejected for deployment. Normal drain requests can limit overlap when the outer queue is full; exact causal GPU scheduling is not proven by these logs. The current public limits remain four and one.

All complete 6K transport trials qualify and drain/PTS accounting passes. Bounded transport stop tails remain explicitly counted. The installed source, mode configuration and unrelated desktop/input services are unchanged, with private tasks, proxies and nested compositors removed. No physical scanout or physical input acceptance is claimed.
