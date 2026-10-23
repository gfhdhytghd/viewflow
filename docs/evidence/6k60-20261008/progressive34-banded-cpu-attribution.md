# Banded CPU submission attribution

Added optional CaptureStaging::Timing to BandedStaging::copy and enabled existing async profile_capture_stages on banded captures. Null timing pointer avoids clock reads; copy/End/Flush sums cover both bands, preparation includes pool allocation. These are CPU API durations, not GPU execution. Windows Release build succeeded and bounded progressive34 trial exited0; original binaries/wrapper restored by runner, original plugin inventory equal, Linux service active. No production promotion.

At actual6144x3456@60, high-resolution60fps fixture:1453 callback records, Copy CPU median0.011ms/P950.017/max0.082, End0.002/0.003/0.055, Flush0.197/0.374/14.470, source lock0/0/0.048. Preparation max10.293ms includes allocation/startup. No pervasive CPU API submission stall is demonstrated.

Full-origin generation→WGC callback median29.166/P9532.559ms; software sampled feedback n80 median55.999/P9573.071/max92.584ms, clock±0.103847ms. All1450 host markers match. Foreground changes0, trace drops0. Interior20s generated1200/accepted1090. Callback-clock bins contain271,275,270,273 entries per5s; all successfully staged/selected, poolbusy0. Different clock-bin boundaries preclude exact drop attribution, but evidence directs investigation upstream of staging rather than pool capacity. Generator10–25s900 intervals median16.666ms,min13.016,max20.428; no<8ms or>25ms intervals.

One live run does not prove the additional timing had zero overhead or isolate the cause of change from prior60Hz baselines. Do not call the target achieved. Next investigate compositor/WGC delivery cadence and GPU resource contention before changing CPU submission calls.
