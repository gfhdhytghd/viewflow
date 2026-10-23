# Optional ready-frame polling experiment

Upstream omission/latency persists after pool accounting found zero exhaustion. Existing backend uses CreateFreeThreaded frame pool and FrameArrived only. Added default-off VIEWFLOW_WGC_POLL_READY=1: an MTA worker calls existing onFrame/TryGetNextFrame then Sleep(1), retaining normal FrameArrived path. Existing delivery mutex serializes acquisition/geometry/copy across both callers. Empty polls return without frame publication. Sleep(1) is requested cadence, not guaranteed1ms resolution.

Lifecycle: closeState sets atomic stop and joins polling worker before taking delivery/state locks or closing WGC resources. Worker keeps capture state alive while running and exits on terminal state. Initialization failure logs fallback and retains event path. Existing contract forbids calling stop synchronously from on_frame callbacks; this change does not relax that contract. No monitor capture, input/focus, codec, alpha or shared-memory format changes.

Windows Release receiver source build passed; window-only static source check and diff whitespace check passed. Experimental build-16k only, normal installed binary unchanged. Runtime polling/shutdown/performance not yet tested. Next bounded synthetic-window run should inspect recovery errors, callback/published/accepted identities, CPU overhead and generation-to-callback latency. This is a hypothesis test for notification-delivery delay, not proof frames are available earlier. Default remains off; retain event-only behavior if it provides no measurable benefit.

## Bounded live control progressive18

Opt-in enabled readback in guest log; runner exit0, normal endpoints restored with coordinated bank recovery and hash checks, plugin inventory exact.1470host markers all match; no foreground/non6K/async trace issues. No pool-busy records. All published identities across four interior5second bins reached ready/accept:294,293,257,295. The15–20sfixture itself generated only261frames, so the corresponding51fps acceptance does not isolate transport throughput. Other bins generated300/299/300 and delivered~293–295.

Generation-to-callback median15.886ms,p9520.861ms.80software feedback samples median39.804ms,p9550.763ms,max95.396ms,clock envelope+/-0.082ms. Similar values existed in event-only runs; phase/load variability and fixture slowdown prevent claiming causal polling benefit. No <=16.7ms or continuous60proof. No observed capture terminal/recovery attributable to polling; process lifecycle restoration succeeded, but this does not exhaustively prove all shutdown races. CPU overhead not separately measured. Keep default off.

Next useful validation requires delivered-frame attribution to polling versus event path, or a matched alternating control; raw total latency alone cannot prove polling acquired frames before notification. Source/host architecture remains unchanged. Host native backup moved to build/ivshmem-backup/pixel-progressive18-native.backup.

## Delivery-origin control progressive19

Added delivery-trace-only counters under existing delivery mutex: successful acquisition and empty attempts separately for poll/event callers, reported each120acquisitions. Windows Release build passed. Experiment enables polling and delivery trace; no change in acquisition policy.

Last periodic snapshot covers1440acquisitions:poll28,event1412,poll_empty13917,event_empty28. Thus polling acquired1.94%of sampled frames and made~497empty attempts per acquired frame. Final partial interval is not in this snapshot; do not label it full-lifetime totals. This measures winner, not exact saved time, and does not establish absolute notification-latency bounds. No evidence of a multi-millisecond benefit across most frames; keep default off and avoid expanding polling investment without stronger evidence.

No foreground/non6K/async trace disturbances;1439host markers all matched. Generation-to-callback median16.163ms,p9520.397ms.80software feedback samples median42.917ms,p9550.931ms,max69.571ms,clock envelope+/-0.095ms. Interior successful callbacks297/300/297 in10–25second bins all selected, pool_busy0. Aggregate host intervals near59–60fps except final lifecycle-affected interval, not continuous60presentation proof. Goal unmet.

Runner exit0, normal endpoints/probe/wrapper/native hashes restored with bank recovery; plugin inventory exact. Backup moved to build/ivshmem-backup/pixel-progressive19-native.backup. No live input/focus injection. No polling promotion.
