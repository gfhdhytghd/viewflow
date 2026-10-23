# Controlled phase comparison: 1/8 versus 7/8

Run38 changes only VIEWFLOW_FIXTURE_PHASE_EIGHTH1→7 from37; same transparent fixture/rawSHM2/native binaries. Actual matched-generation phase median0.893806,P950.906922;1404/1408 unique capture identities in[0.875,1), wrap/outliers retained. Run37 actualmedian0.141943. Explicit requested phase did change observed phase as intended, though sparse desktop timing and capture-conditioned sampling limit interpretation.

38 generation→callback median19.095/P9528.386ms versus37 30.127/33.417ms. Full-origin sampled software feedback n80 median41.901/P9558.815/max108.962ms versus37 52.175/71.445ms. Clock envelope±0.095410ms. Interior20s generated1200/accepted1124 versus37 1199/1083. All1409host markers match;foreground changes0 and diagnostic drops0.

Phase affects this baseline and must be reported. One sequential pair is not a statistical causal estimate under controlled host/GPU load. Even this lower-latency phase fails both objectives; fixing fixture phase cannot count as production latency optimization for arbitrary Windows apps. Avoid more phase-only tuning as the path to success. Investigate reducing composition/capture work or transport cost with phase-matched controls and maintain transparency semantics.

Runner exit0, original plugin inventory restored, normal binaries/wrapper/probe restored by runner,Linux service active. No experimental runtime setting promoted.
