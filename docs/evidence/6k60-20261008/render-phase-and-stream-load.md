# Render phase attribution and opt-in copy candidate

Reused existing render-order analyzer with separate plugin artifact path.80samples from pixel-stamp-deadline1: accept→next recorded render P50 11.203ms/P95 16.201;render-start→feedback4.949/4.997ms (max21.653). Most samples have one completed render before feedback,maximum2. These are temporal ordering,not proof of which commit/fence the compositor sampled. No general extra-frame queue proven. Do not claimGPU render execution time from these boundaries.

Reviewed earlier wake/poll and dynamic-worker results before selecting a different copy experiment. Added VIEWFLOW_SHM_STREAM_LOAD=1,defaultoff,to AVX2 row copy. Uses aligned32byte streaming source loads only when source after destination alignment is32byte aligned; otherwise original unaligned loads. Destination streaming stores,per-thread sfence,completion ownership remain unchanged. Candidate hypothesis is potential benefit on GPU mapped memory; current mapped memory cache type is not established, and normal-RAM correctness tests do not establish speedup.

Host tests passed: aligned/unaligned source/destination,byte tails around32/128boundaries,guards; existing parallel copy matrix1/2/4/8threads,SSE2/AVX2/cached,paddedpitch,6K with opt-in enabled. Windows native Release build passed; shared-frame test run tracked separately. Candidate not deployed or performance-tested yet. Next bounded pixel-verified6K comparison with identical generator/compositor parameters. Goal remains unmet.

Windows shared-frame test with stream-load enabled completed: ownership,overwrite,pitch,wire,concurrent integrity passed (received835 is a test count,notfps). Formal deployment unchanged.
