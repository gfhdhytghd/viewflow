# Four-band SHM2 control after diagnostic backpressure repair

Progressive22 changes only capture bands2→4 relative to progressive21. Both use repaired closure-only WGC origin tracing, polling off, GPU priority0, WGC interval0, SHM2, host experimental deadline lead5ms. This rechecks band count under progressive upload, unlike older SHM1 controls.

1498 host markers all match source; zero foreground changes and trace drops. Interior generated/accepted5s bins:300/296,300/300,300/294,298/297. No continuous60fps certification.

Same-frame80sample callback→accept median10.179ms/P9520.071 versus two-band10.598/17.963. Write→ready6.826/16.570 versus7.413/14.716. Total software feedback39.926/52.109ms,max111.180; two-band41.500/54.968,max57.916. Small median difference and worsened local tails do not establish four-band benefit; retain two-band experimental baseline. No promotion or goal completion. Source callback→write35.864ms and host acceptance32.307ms maximum warrant per-frame attribution rather than more band-count sweeps.

Guest and host restore checks passed, normal service active, temporary plugin inventory unchanged. No mouse/keyboard/focus input injected.

## Per-frame attribution correction

The111.180ms maximum is sequence289,PTS349371279375,source capture version2: SHM1 during startup negotiation, not SHM2. Its callback→write35.864ms and host acceptance32.307ms must not be attributed to progressive four-band upload. The overall result intentionally still includes this startup sample.

Analyzer now reports both overall and by_protocol distributions. Remaining79SHM2 samples: total median39.792/P9551.249/max54.712ms; host acceptance median0.306/P951.238/max1.559ms; callback→write2.661/5.455ms; write→ready6.831/16.570ms. Progressive21 has80SHM2 samples and noSHM1 sampled feedback. This corrects the prior local-tail comparison; neither small single-run median difference nor unequal startup sampling establishes a preferred band count.

Next action: inspect GPU upload completion and presentation scheduling, not rewrite host accept based on the32ms startup outlier. Any additional live upload tracing must avoid synchronous per-frame stderr backpressure identified in the WGC diagnostic experiment.
