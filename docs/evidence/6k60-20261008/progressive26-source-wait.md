# Source latency after corrected generator pacing

Saved same-identity GPU and Present analyses for progressive26.1589matched6K stamps over26.643s: generation→CPU-observed GPU fence median2.268/P955.056ms; observed fence→WGC callback14.552/16.861ms. CPU observation is an upper bound on GPU completion, making the latter gap a lower bound on completion→callback for each frame; not photons. Present CPU call median0.053/P950.079ms,Present-return→callback16.372/18.124ms. No Present/generation identity mismatches.

This narrows the main source delay to post-render capture/composition delivery, not expensive Present calls or pixel memcpy in the consumer. It does not distinguish DWM phase, VDD pacing, WGC copy scheduling, or notification dispatch.

Read-only virtual_display enumeration through SSH returned no display records, so no current refresh capability claim. Prior README lines1241-1247 documents120Hz trials with unpaced fixture69.864fps,readback backlog, and driver restart3010 then50. Those results are not a controlled60Hz-generator comparison, but known hot-reload failures make another blind VDD restart inappropriate. No display mode or driver changed this turn.

Next gather display capability/topology from the interactive scheduled-task environment using existing read-only inventory tooling, then decide whether a60Hz-generator/high-refresh-capture control can be performed without driver restart. Otherwise focus on capture/compositor instrumentation. Goal unmet.

## Interactive display inventory

Unique read-only scheduled task completed result0 and was unregistered. First attempt failed due execution setup; terminal result1 verified before corrected action with explicit execution policy and redirected diagnostics. No display mutation. DISPLAY5 is primary6144x3456@60 at0,0; DISPLAY6 is3078x2310@60 at6144,3180; IntelDISPLAY1 is3840x2400@60 at6144,780. Both virtual displays enumerate only one6144x3456mode at60Hz. Saved display-capabilities-20261009.txt. Higher-refresh live control cannot use a currently advertised mode, so do not repeat mode switching without driver configuration/reload work and a concrete recovery plan. Continue examining60Hz capture delivery rather than assume120Hz available.
