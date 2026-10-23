# Single-buffer retest with corrected pacing

Changed only guest VIEWFLOW_WGC_BUFFERS=1 from progressive26 settings (high-res60Hz,interval0,two-bandSHM2,host completion notification/async traces). Runtime logs buffers1. No ETW.

1485host markers allmatch, no observed foreground/trace disruptions. Source gen→callback median14.917/P9517.455ms versus26 median16.653/P9518.456ms, but20second generated1194/accepted1122 versus baseline1200/1196. Bins300/283,300/283,294/276,300/280; loss persists in bins where fixturegenerated300. Generator has one116.869ms stall,so whole-run continuous60Hz input not proven.80softwarefeedback median41.586/P9547.190/max65.207ms,clock±0.103ms; no end-to-end benefit.

Reject single-buffer promotion despite smaller surviving-frame callback median; losing frames is not the requested optimization. Keep two-buffer baseline. This retest addressed prior jitter/interval4ms confounding and still shows poorer throughput. Further buffer-count sweeps not justified absent new mechanism evidence. Normal guest/host restored by hashes, plugin inventory restored, serviceactive. Goal unmet.
