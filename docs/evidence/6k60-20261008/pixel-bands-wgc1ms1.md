# WGC1ms minimum update interval control

Capture setter now accepts explicit1000 or4000microsecond values, preserving4000 default in session helper and existing unsupported/exception recovery. Windows Release source and fixture build passed. Only experimental runner requests1000. Getter verified requested_us=1000,before160000ticks,after10000ticks. Property reference: https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval . Getter readback proves requested setting, not a guarantee of delivery latency.

physical-pixel-bands-wgc1ms1:1580matched full6K records spanning26.723s, all1580host pixel markers matched; no foreground change, no flagged residency discontinuity, reported trace drops0. GPU probe1796observed,pending0,dropped0. Generation→GPU-observed median2.123ms,P956.071ms; GPU-observed→WGC-entry median14.915ms,P9521.261ms; generation→WGC-entry17.014/27.498ms. Previous matched4ms run14.498/17.492ms GPU-observed→entry. No evidence that1ms removes the approximatelyone-refresh upstream delay; do not promote it as optimization.

80generation→Waylandfeedback samples median41.618ms,P9562.256ms,min27.480ms,max76.566ms.23sequence gaps versus7 in prior4ms run. Receive286–299frames/~5s. Sequential runs are not randomized and differences may include system variance; sufficient to reject an improvement claim, not to prove1ms inherently worse. Both fail original16.7ms/continuous60fps objective. No photon measurement.

Guest wrapper/probe/native and host binary restored with hash checks; receiver active; experimental deadline plugin unloaded and exact plugin inventory restored. Backup in build/ivshmem-backup/pixel-bands-wgc1ms-native.backup. No mouse/keyboard/focus operations. Source supports opt-in1ms for reproducibility, production stays4ms.

Next direction should examine capture/compositor delivery architecture rather than smaller update intervals: at this workload the measured upstream delay alone is approximatelyone16.7ms frame before readback, SHM transfer, host upload and display scheduling. This is observed behavior, not a proof that every possible WGC configuration has that lower bound.
