# Opaque fixture control

Added default-off VIEWFLOW_FIXTURE_OPAQUE=1 to motion_fixture; changes only clear alpha from1/255 to1, preserving low-amplitude RGB changes, dimensions, high-resolution60Hz pacing, swapchain format/type, noactivate style, and frame origin/stamp. Windows Release fixture build passed. Does not alter normal applications or replace transparent-window acceptance.

Bounded progressive35 runner exited0, actual6144x3456, logged alpha=1. Interior5–25s generated1200/host accepted1200. All1590 host pixel identities match source, foreground changes0, guest/host trace drops0. Generation→callback median24.363/P9526.517ms. Sampled full-origin software feedback n80 median50.751/P9554.819/max83.932ms,clock±0.101972ms; not photon latency or continuous60Hz presentation proof.

Previous transparent progressive34:1200generated/1090accepted, callback29.166/32.559ms,feedback55.999/73.071ms. This single sequential comparison suggests investigating composition/alpha workload, but does not isolate it from phase/load variability or prove repeatable causality. Repeat matched transparent/opaque controls before changing production behavior. Both still exceed16.7ms. The opaque control cannot fulfill fusion transparency requirements.

Normal binary/wrapper/probe restored by runner, exact plugin inventory restored, Linux service active. Experimental fixture flag absent by default; no production promotion. Future benchmark runs should explicitly state opacity.
