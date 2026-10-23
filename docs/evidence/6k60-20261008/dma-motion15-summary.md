# Motion15: sustained 60-second baseline after GPU idle

The idle hook delivered its notice; a live host query showed 4% GPU utilization
before the owned-fixture run. No desktop input or focus was injected. Candidate
configuration: Windows integrated-v3 source pool, Linux presentation-stats,
async alpha enabled, one in-flight frame, GPU timing queries disabled.

The generator submitted 3600 frames over 60.0001388 seconds at 6144x3456.
Recorded foreground/input/extent checks accepted a stable baseline. Published
atlas rate was 53.2832 fps. Two entire per-proxy feedback-arrival intervals
within the motion loop measured 51.7380 and 52.1486 fps (20.0046 and 20.0005 s).
They are separate intervals, not exact-loop presentation FPS or photon counts.
The startup-straddling interval is excluded from steady-state interpretation.

Sampled WGC timestamp to Wayland presentation feedback: n=190, P50=44.669183 ms,
P95=54.878483 ms, maximum=74.863783 ms. WGC timestamps do not measure generation;
Wayland feedback does not measure photons. Thus neither sustained 60 fps nor
one-frame end-to-end latency is established. Source acquisition/publication
still falls short of 60 fps with the current WGC path; the prepared Desktop
Duplication shared-source path remains the next distinct candidate to validate.

Task exit 0, native drained, wrapper unchanged, normal task Running; Linux user
service was active after runner completion. Full logs and analyzer output are
in `dma-production-motion15/`. No fullscreen DD mode change was made in this run.
