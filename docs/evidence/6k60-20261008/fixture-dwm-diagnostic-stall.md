# Fixture diagnostic stall attribution

Run40 worst generation gap374.681ms at sequence299 (5.341s);41 gap620.105ms at sequence299(5.587s). Prior Present CPU duration0.047/0.049ms. Both coincide with first periodic DWM diagnostic, while41 interior10–25s had max18.510ms. Existing cadence analyzer explicitly covered10–25s but missed this early stall; added whole_run largest gaps and>25ms counts while retaining labeled interior statistics.

Fixture report_dwm previously called DwmGetCompositionTimingInfo then synchronous fprintf on generation thread every5s. Moved its output to end-of-test via bounded64record vector reserved before start, preserving legacy motion-dwm fields and recording query begin/endQPC separately. Periodic query itself remains on generation thread to distinguish API latency from logging; no unsupported claim that logging alone caused the stall. Windows Release fixture build passed. No live verification or production changes this turn. Next same-settings run must inspect query durations and whole-run cadence, not only10–25s.

## Live42 verification

Same41 settings with deferred DWM output, runner exit0. Whole1797generation intervals max19.376ms,zero>25ms; interior20s generated1200/accepted1188. Periodic DWM queries0.0047,0.0077,0.0058,0.0050,0.0083ms; startup0.0183/end0.0068ms. Previous41 first5sdiagnostic gap620.105ms is absent. This supports synchronous output interference rather than a typical slow DWM API query, though one sequential run is not absolute causal proof against variable system scheduling. Keep output off generation loop.

No foreground change or diagnostic drops. Sampled full-origin software feedback n64 median48.103/P9565.890/max70.952ms. This remains above16.7ms and accepted frames below sustained60fps; improved fixture cadence is measurement repair, not transport speedup. Original plugin inventory restored,normalprograms restored by runner,Linuxserviceactive. Fixture diagnostic repair retained for later trials.
