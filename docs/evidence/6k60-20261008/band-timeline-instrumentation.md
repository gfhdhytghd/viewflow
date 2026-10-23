# Prefix publication and upload enqueue timeline

Windows BandPublication records fixed-capacity16element per-band metadata(row range,copy-startQPC100ns,publishedQPC100ns) only with existing band tracing enabled. Snapshot copied before publication object destruction; deferred diagnostics consume the copy, avoiding dangling access. Published time follows append(release publication), so it is an upper observation bound on prefix visibility, not the exact atomic store time.

Linux records exactPTS,row range,steady-clock nanosecond begin/end around cuMemcpy2DAsync. Submit CPU metric excludes the subsequent async diagnostic call. Scope explicitly says CPU-enqueue-not-DMA-completion. Cross-system comparison must use existing measured clock-offset envelope; enqueue before next-band publication is opportunity for overlap, not proof of actual GPU execution overlap.

Windows Release reverse and Linux reverse/texture-test builds passed. Hardware6K test with diagnostics preserves explicitPTS424242 in submit trace and validates84934656bytes,mismatches0,completionnotification,abortretention,bankreuse,warmgenerations,shrinkgrow. Output band-timeline-gpu-test.log. Normal runtime not replaced this turn; live timeline validation remains next action. No target completion or performance gain claim.

## Live43

Runner exit0;1474two-band/first-upload-extent matches.1471first uploads CPU-enqueued before final source publication even using conservative offset low bound;clock envelope±0.095543ms,0clock-order violations. Firstprefix→enqueue median0.587/P951.243/max10.247ms. Enqueue-end→finalpublication lead median2.030/P9513.570ms;negative leads retained,min-3.517ms. These show opportunity for overlap, not actual DMA execution overlap. Next GPU completion observation needed before claiming benefit or changing band granularity.

Actual6K transparent fixture, interior20s1199generated/1120accepted;80software feedback samples median44.606/P9562.671/max65.643ms. No foreground change/trace drops. Original plugin inventory restored,normalprograms restored by runner,Linuxserviceactive. Target unmet and no production promotion.
