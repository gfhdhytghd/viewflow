# Aligned AVX2 streaming-load control

Bounded experiment enabled VIEWFLOW_SHM_STREAM_LOAD=1 in guest wrapper, same paced60Hz marker fixture,host marker/stage diagnostics,DP4deadline5ms.1590host markers all match source,1590unique,zero repeats,17sequence gaps;foreground changes0. Temporaryplugin removed,plugin inventory identical,guest/host wrapper/native backups hash-restored,host runtime override removed.

No demonstrated copy benefit:6Kpublish P50/P95 3.237/4.375ms vs baseline3.030/4.051ms. Ready4.892/10.285ms vs4.796/6.254;Map0.002/0.004 unchanged.80matched callback→write8.746/15.942ms vs8.434/10.430. Do not default-enable this candidate. Memory cache type and per-row branch usage are not separately measured; conclusion is no end-to-end path benefit observed under configured candidate,not proof all streaming loads are slower.

80pixel generation→feedback41.123/52.745ms vs44.162/51.647;median improvement accompanies changed source/compositor phases,not reduced copy cost. Sequential runs are not randomizedcausalproof. Receiver five intervals~58.2–59.98fps;fullgoalunmet. No photon measurement.

Keep candidate defaultoff. Further copies/worker/poll micro-tuning now have weak evidence for material gain. Next examine feasibility of eliminating a full staging/publication copy or pipelining readiness in bands, with exact ownership and final-pixel consistency, rather than repeating small parameter sweeps. Do not change rawBGRA transport into encoding.
