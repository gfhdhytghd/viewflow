# Progressive24 completion-observation control

Added default-off VIEWFLOW_PROGRESSIVE_BUSY_POLL=1: while a progressive upload is pending, use poll timeout0 instead of1ms; idle timeout remains8ms and all input/Wayland dispatch remains active. No synchronous CUDA wait or freshness cutoff. Linux build passed.

Bounded live control otherwise matches progressive23.1449upload observations: final-event-observed wait median1.159/P952.205/max4.331ms versus2.116/2.687/14.854. Upload lifecycle median4.995ms versus6.284, but P9513.430 versus8.859ms. This supports roughly1ms typical completion-observation overhead; not a pure GPU-timing measurement or a stable end-to-end win. One ps sample during fixture showed receiver34.7%CPU, not a controlled utilization comparison.

1451host markers all match, observed trace drops0,foreground0.80sample software latency median42.434/P9552.405/max103.094ms; includes startup,not photons.5s generated/accepted bins292/256,298/297,300/297,300/300. No sustained60fps or16.7ms claim. Source callback median18.473 versus previous20.476ms also changed, so total-latency difference cannot be assigned entirely to host polling.

Keep control default off. Normal binaries/wrappers/probe restored by hash checks, temporary plugin inventory restored, normal service active. Next investigate asynchronous completion notification or adaptive short polling to recover the observation delay without sustained busy loops; must preserve DMA ownership and snapshot behavior.
