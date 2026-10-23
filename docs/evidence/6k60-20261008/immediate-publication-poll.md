# Immediate post-enqueue publication poll

Evidence40 exact-PTS overlap join:1447 matched frames;1331 first-band publications observed before last-band GPU staging completed;1426 multiple host upload submissions. First publication poll median1.560/P954.787/max35.608ms. This supports actual prefix delivery, not proof of concurrent DMA/CPU execution. Result physical-pixel-progressive40-band-overlap-join.json retained.

Added default-off VIEWFLOW_SHM_IMMEDIATE_POLL=1. After successful adoption/enqueue, source lock release, metadata diagnostics and lane/geometry bookkeeping, invoke existing poll_shared once before outer-loop wait. GetData/Map still use nonblocking flags; ready data may perform the normal copy/publication work. No busy spin, no new cutoff, no changed lease ownership or error semantics. Existing next-loop polling remains. Unlike earlier EARLY_POLL (top of next loop), this removes mandatory loop sleep before the first check.

Windows Release reverse build passed. Experimental build updated only; normal installed binary unchanged. Live phase-matched validation is still required; no speedup or target completion claim. Enable only this new option relative to40 for next trial and compare first_poll_ms with exact-PTS host upload/presentation, retaining source/drop/phase confounders.

## Live41 result

Explicit flag1, otherwise40 settings, runner exit0. First-poll n1383 median0.023/P955.058/max25.226ms versus40 joined median1.560/P954.787ms. Common initial loop wait removed, but long tail persists. Whole sampled software feedback n64 median43.877/P9563.047/max80.145ms, versus40 42.290/57.871ms. Interior20s generated1165/accepted1086; generator itself below60fps, so no sustained target evidence. Foreground/trace-drop flags absent. Source/load differences prevent isolated end-to-end causal comparison. No demonstrated whole-path gain; keep option default-off and do not promote. Original plugin inventory equal,normalnative/wrapper/probe restored by runner,Linuxserviceactive.

The early SHM2 metadata publication precedes BandPublication::poll; first_poll can therefore include metadata/output work even without the outer-loop sleep. Next attribute the remaining tail to metadata publication versus source scheduling instead of further shortening sleeps.
