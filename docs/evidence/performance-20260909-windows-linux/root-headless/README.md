# Root compositor versus nested compositor

The same installed canonical VPL source (875E56F9) and the same passive Linux presenter are used in this A/B/B/A comparison. Both render the complete 6144×3456 stream at scale 2. The passive presenter only changes its app class, lets the wrapper own the temporary window rule, and skips the user's global touchpad subscription. Its decoder/upload/draw code is otherwise the canonical implementation. Two Linux CTests pass.

| Trial | Compositor | Distinct FPS | Median upper ms | P95 upper ms | Maximum upper ms |
|---|---|---:|---:|---:|---:|
| topology-inner-c1 | nested | 40.745 | 73.338 | 80.972 | 97.392 |
| topology-direct-d1 | root-headless | 38.076 | 81.240 | 85.471 | 149.419 |
| topology-direct-d2 | root-headless | 40.391 | 79.828 | 81.705 | 147.509 |
| topology-inner-c2 | nested | 38.332 | 77.801 | 95.083 | 112.390 |

The root arm creates one far-away 6144×3456@60 virtual output on the existing DRM compositor. It uses a unique class rule with no initial focus and no focus. The rule is disabled on cleanup and its Lua handle cleared; this inert named runtime rule is reused by the following root arm. The private output is removed, monitor rectangles and plugin lists match, and original input/main services are not reconfigured. No input events are injected. The nested arms keep the previous isolated compositor method. Neither arm measures physical screen scanout.

The first top-marker root attempt recorded 1201 screenshots but zero valid marker frames, and was explicitly rejected. The layer inventory includes existing root desktop layers in the top region; the exact pixels that invalidated the first marker were not retained, so the cause is not established. The repeated comparison moves the fixture fiducial to physical y=256 and observes that interior region in **both** arms; stream dimensions stay 6K. First-ROI images and the observed layer inventory are retained. The direct-d1 image was visually checked as unobstructed complementary black/white marker rows. The earlier nested top-marker result remains a separate record, outside the four-row comparison.

The P95 ranges overlap: root 81.70–85.47 ms, nested 80.97–95.08 ms. This does not support attributing the latency gap to an extra nested desktop frame. The installed source remains unchanged, and the 60 ms target is still unmet. There are now 81 qualified full-route trials, plus two explicitly rejected profiling/top-marker attempts.
