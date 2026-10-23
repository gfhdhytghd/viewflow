# Remove redundant completed-upload synchronization

GpuDecoder::Impl::cancel_progressive retains the initial CUDA StreamSynchronize (including completion host callback lifetime), but performs the second synchronize only when it actually enqueues cancellation GraphicsUnmapResources. Completed uploads already enqueue unmap before recording the completion event; previously their cleanup synchronized an unchanged stream twice. Cancellation of mapped in-flight resources retains both waits. No ownership/presentation policy changes.

Linux reverse and progressive texture test builds passed. Headless NVIDIA hardware test verifies all84934656bytes,mismatches0,completion_notification1,abort_snapshot_preserved1,lease_reusable1,shared_decoder_registration1,warm_generations5,shrink_grow1. Exact test output in progressive-single-drain-test.log.

Live39 uses same7/8 transparent fixture settings as38. Runner exit0,1513host markers all match,no foreground changes/diagnostic drops. Interior20s generated1200/accepted1188. Sampled full-origin software latency n80 median38.927/P9554.538/max108.971ms,clock±0.096144ms; source callback17.396/P9523.011ms. Previous38 feedback41.901/58.815 andcallback19.095/28.386. Source timing also changed, so the whole-run difference is not attributable to removal of one host CUDA call. Build/hardware/live correctness evidence supports the cleanup, not a quantified latency gain. Still fails16.7ms and sustained60fps.

Normal binary restored by runner; original plugin inventory equal; Linux service active. Experimental source/build retains cleanup for subsequent experiments, no production promotion.
