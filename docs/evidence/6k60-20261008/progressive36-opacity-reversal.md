# Transparent reversal after opaque control

Same rebuilt fixture and native binaries as35, explicitly VIEWFLOW_FIXTURE_OPAQUE=0; logged alpha1/255. Bounded runner exit0, no input/focus injection. Original plugin inventory restored, runner restored normal binaries/wrapper/probe, Linux service active.

Run36:20s generated1200/accepted1188,1540 host markers all match,0foreground changes and0guest/host trace drops. Full-origin sampled software latency n80 median46.116/P9553.093/max103.349ms,clock±0.093706ms. Generation→callback median17.694/P9523.190/min8.415ms.

A-B-A:transparent34 latency55.999/73.071ms,opaque35 50.751/54.819ms,transparent36 46.116/53.093ms. Acceptance1090/1200,1200/1200,1188/1200 respectively. Transparent reversal does not reproduce the assumption that opacity yields lower latency. Do not promote an opacity-based optimization or omit transparency requirements. Scheduling/refresh phase and varying load remain confounders; no causal claim about opacity throughput from these three runs.

The source uses independent high-resolution60Hz pacing; phase relative to DWM refresh is not fixed between processes. Next correlate actual per-frame generation QPC with recorded DWM vblank/refresh metadata, preserving source-identity matching and explicit limitations of compositor timestamps. Neither throughput nor <=16.7ms target is certified.
