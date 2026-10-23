# SHM2 deadline control and first-commit measurement

Common same-frame boundary added to analyze-pixel-stages: capture callback→host
accept-end, using actual6144x3456atlas only and joined timestamps, not sums of
independent medians. Historical no-deadline SHM1negotiation1 median11.853ms vs
SHM2progressive2 median9.387ms (80samples each). Runs are separated in time,
so this is suggestive transport improvement, not a paired causal A/B proof.

First5ms standalone deadline control(progressive3) finished its fixture after
the runner's fixed log-collection delay. Collector encountered an open fixture
log; nested finally restored services/slots/plugin. Task then observed Ready,
no motion process, logs recovered separately (initial guest log preserved).
Do not certify this interrupted control. Recovered feedback also includes old
retained-frame redraws: source sequence1798 appeared in a sampled feedback about
2039ms after generation. That is not necessarily its first presentation.

Fixes: run-motion now observes scheduled-task completion/exit result before
clock-end and log collection. PresentationTiming requests a sample only for the
first commit of each new per-window source PTS; retained redraws still render
normally. Even when sampling capacity is exhausted the first PTS is recorded,
so a later redraw cannot be mislabeled first. Window deletion/reset clears the
tracking entry. Trace explicitly labels first_commit=1. This changes measurement
only, no capture-freshness/session restriction.

Repeat physical-pixel-progressive4 completed normally. All80clock samples label
first_commit=1.1565host pixel markers match source, zero mismatch/unmatched,
zero progressive upload recoveries, foreground changes0 and trace drops0.
Source has19sequence gaps; accept intervals285,296,296,296,300frames per~5s.
This does not prove continuous60fps. Full generated→first-commit feedback:
median41.123ms,P9551.311ms,min28.936,max65.911,clock envelope±0.085ms.
No photons measured. Same-frame median partitions (do not sum medians):
generation→capture callback21.113ms; callback→host accept-end9.821ms;
accept-end→feedback9.370ms. Previous no-deadline progressive2 accept-end→feedback
median23.127ms, but source generation phase differed between runs.

Plugin status:5ms lead,3213timer firings,31CPU budget misses,14present intervals
above1.5periods across whole enabled interval. Status counters include fixture
setup/teardown, not only its steady portion. Existing plugin inventory exactly
matches before/after; standalone experiment unloaded successfully. Original
host/guest binaries and wrappers restored via coordinated slot cleanup. Host
active/hash2e3008638c8f9498668c1921ccca045306ab16bead216e7511ef76c468cf88d2.
No input/focus injection, existing-plugin reload, or virtual-monitor changes.

The goal remains unmet. Capture delivery before our callback is now the largest
remaining median component; reducing transfer time alone cannot meet16.7ms.
Future capture work must preserve real app/window semantics and measure its
upstream delay, rather than substituting callback latency for end-to-end latency.
