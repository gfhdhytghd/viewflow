# Progressive20 baseline retest

User authorized retesting. Actual 6144x3456 raw BGRA SHM2, two capture bands, WGC polling off, relative GPU priority 0, WGC interval 0, experimental host presentation lead 5 ms. No injected input/focus. Existing completion-retention patch remains in experimental binary.

1410 host pixel markers all matched source; no observed foreground changes or trace drops. 80 generation-to-sampled-Wayland-feedback observations: median 42.583 ms, P95 53.303 ms, maximum 65.071 ms; clock envelope half-width 0.092 ms. These are software feedback measurements, not photons or continuous presentation proof.

Generation-aligned 10-15 seconds delivered all 300 generated frames to host acceptance; 15-20 seconds generated 300 but published/accepted only 262. Callback-clock bin has 264 entries and zero pool-busy failures. This localizes most of that shortfall before successful source publication, with bin-boundary ambiguity; it does not prove a specific Windows subsystem responsible. 5-10 seconds fixture itself generated only 272 frames and four published records were not accepted, including two queued supersessions. No sustained 60 fps or one-frame latency claim.

Guest runner restored and hash-verified normal binary, wrapper and probe after shared-state recovery with both endpoints stopped and mappings locked. Host binary restored to 2e3008638c8f9498668c1921ccca045306ab16bead216e7511ef76c468cf88d2, service active. Plugin inventory byte-identical before/after. No experiment promoted.
