# First live pixel identity measurement

Fixture sequence/QPC marker survived WGC and mapped staging:1583 decoded records /1584 publications,1582 distinct sequences,1 repeat,23 sequence gaps within the observed range. One missing marker is not silently counted as unique. Foreground changes0,103/104 pin observations, restoration runner exited0 and verified original wrapper/native/probe hashes. Production receiver remains active.

80 sampled correlations from marker generation before GPU submission/Present to Wayland feedback: P50 110.973ms/P95 122.949ms, min105.214ms. Guest-local pixel generation to capture callback over1583frames: P50 78.456ms/P95 79.792ms. These expose substantial pre-callback latency that WGC timestamps did not describe. No photon measurement, no validation of host rendered pixels yet. Not evidence that arbitrary applications have identical latency.

Fixture normally uses Present(1,0) without waitable max-frame-latency1. Next bounded control enables its existing waitable option to distinguish fixture queueing from capture delay, while keeping6K pixels and full transport. This control changes generator scheduling, not production encoding or transport semantics. Marker GPU update itself may affect workload; retain that caveat. Goal remains unmet.
