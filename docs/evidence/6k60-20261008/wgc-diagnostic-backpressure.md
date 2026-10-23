# WGC diagnostic backpressure: progressive20/21

Progressive20 had four acquired-to-geometry spans above 16.7 ms, including 332.430 ms. Each followed the synchronous wgc_delivery_origin diagnostic emitted at acquired counts 600,720,840,960. That diagnostic runs after the acquired timestamp and before geometry, under the delivery mutex; therefore the original geometry label did not identify geometry API cost.

Change: retain counters on the callback path, emit totals once at capture closure rather than every 120 acquisitions. Default-off delivery tracing still controls counters. Polling remains disabled. Windows Release build passed. All other progressive20 runner settings retained for progressive21.

Progressive21: 1495 callbacks, acquired-to-geometry max 0.159 ms (no >16.7 ms samples). Consumer callback median 0.196/P95 0.374/max 16.798 ms. Generation-to-callback median 16.878/P95 22.144/max 29.522 ms. This supports diagnostic pipe backpressure as the prior long-tail cause, not proof of a general WGC/DWM fix. Earlier periodic-origin-trace runs are perturbed measurements.

1491 host markers all match source, no foreground change, zero trace drops. Generation-aligned 10-25 seconds: 900 generated,899 published and accepted; final ten seconds 600/600. Earlier five-second bin accepted293/300. Continuous whole-run60fps remains unproven. Software generation-to-sampled-Wayland-feedback median41.500/P95 54.968/max57.916 ms,80samples,clock envelope±0.093ms; excludes photons and remains above16.7ms. Do not claim latency target met.

Normal guest binary/wrapper/probe and host binary restored with runner hash checks. Temporary scheduling plugin removed and inventory restored. Change remains in experimental build/source. Next optimize the remaining generation-to-callback and callback-to-presentation intervals using the unperturbed instrumentation.
