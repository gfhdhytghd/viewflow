# Pixel-verified5ms compositor deadline control

Rebuilt existing ABI-checked standalone deadline plugin; CTest1/1passed. Bounded enabledDP4lead5ms run with same paced60Hz6K marker fixture and host stage diagnostics. No existing plugins reloaded. Original plugin inventory exactly equal before/after; temporary plugin unloaded. Host/guest binaries and wrappers restored by hash-checked runners, runtime host diagnostic override removed.

1589host pixel markers all match source,1589unique,zero repeats,18gaps within observed source range;1591publications. Foreground changes0, no zero-residency/non6K interval violation after initial placement. This is not continuous unique presentation certification.

80 pixel-identified feedback samples: generation→feedback P50 44.162ms/P95 51.647ms versus preceding normal scheduling52.877/67.916. Host accept-end→feedback16.158/21.236 versus23.554/29.796. Source callback→write8.434/10.430,host queue0.013/0.150,host accept2.972/4.944. Sequential comparison, not randomizedAB; phase and system load can vary. Minimum total29.447ms remains above16.7ms.

Plugin whole-experiment counters:2813present intervals,8>1.5period,5CPU budget misses,3timer lateness>1ms;fallback_mask0,busy0. These include setup/restoration beyond the30second fixture and are event-arrival estimates,not hardware-vblank or unique frame counters. Receiver five intervals about58.95–59.91fps. Goal unmet. No default deployment justified yet.

Next examine matching host accept timestamps to recorded compositor render spans to identify frames that missed the scheduled render selection window versus render→flip cost; retain pixel identity,60Hz workload and no-focus controls. Avoid smaller lead sweeps without distinguishing those mechanisms.
