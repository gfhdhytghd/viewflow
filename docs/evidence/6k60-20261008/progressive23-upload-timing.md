# Progressive23 async host diagnostic run

Two-band baseline plus VIEWFLOW_ASYNC_TRACE=1 and VIEWFLOW_PROGRESSIVE_UPLOAD_TRACE=1 on host; guest settings unchanged from21.1394 host markers all match source; observed guest/host trace drops0,foreground changes0. Validity analyzer now checks host queue drops too.

1391 completed6K progressive uploads: setup median0.040/P950.075ms; pin0.001/0.002ms; submissionCPU0.037/0.060ms; final event observed wait2.116/2.687ms; upload lifecycle6.284/8.859ms. Median andP95 submissions2. Cold maxima setup7.129,pin7.423ms retained. These are CPU wall observations including poll/scheduling delays, not GPU timestamps; upload diagnostics lack PTS so cannot individually join presentation samples.

64 software feedback samples median46.393/P9553.424/max130.839ms,clock envelope±0.096ms. No speedup established. Generation-aligned5-10s generated293,callback-bin197,published196 unique,accepted194; this upstream shortfall makes the whole run insufficient for60fps.10-25s generated901,accepted899. No pool-busy drops. Sampling changes and upstream scheduling preclude attributing overall latency variation to host async logging.

Normal guest/host restored by runner hash checks, plugin inventory restored. Next investigate completion polling versus actual DMA using event-based timing or a bounded polling control; do not infer a2ms GPU copy from observed final-event wait. Goal unmet.
