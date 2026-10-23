# Targeted GPU trace capability audit

Live provider query confirms Microsoft-Windows-DxgKrnl GUID802ec45a-1e99-4b83-9920-87c98277ba9d. Get-WinEvent manifest reports DMA start175v1/stop176v0/info177v1,queue start178v1/stop180v1 under Base keyword0x1. Templates expose hContext,submission/completion or submit-sequence identifiers, packet type,preemption and timeout fields. These are available schemas, not proof events will be emitted or joinable to a captured window.

Standalone ETL reader now accepts optional --dxg, selecting DxgKrnl provider and emitting full event records/schema/counts. Default DWM mode unchanged. Plan: own bounded Base-only ETW session without kernel syscall profiling, assess event count/loss/fixture cadence, map GPU context ownership before assigning delays to WGC or DWM. Do not equate ETW CPU event timestamps to hardware execution time without event semantics verification. No live trace started or production settings changed this turn.

## Progressive28 Base-only capture

Own Viewflow6KProgressive28 trace completed/stopped.663820totalevents,663818DxgKrnl,headerlost0,readerstatus0. DMA175/176 each10144events. Generator900interior intervals min13.799/median16.681/P9517.016/max19.744ms,none<8/>25ms.1543host markers all match,foreground/trace drops0. Software feedback median46.186/P9551.028/max60.732ms,80samples,clock±0.083ms; slower than27 and no transport improvement claim.

Paired DMA175v1→176v0 by hContext,PacketType,queue sequence; excluded preempted stop. Most active contexts:0xffffe3028f8e3250 n3599 median0.337/P953.894ms;0xffffe302610e6de0 n3354 median5.405/P959.306ms;0xffffe3028fb6cb30 n3099 median2.944/P954.860ms. Start event PID4 for these; not actual owner identity. Saved raw/schema and progressive28-dma-intervals.json. Need context/device lifecycle mapping before relating spans to DWM or Viewflow; CPU ETW span is not independently verified hardware timing.

Normal binaries/wrappers/probe restored by runner; plugin inventory restored. No keyboard/mouse/focus injection. Goal unmet.

## Context attribution audit

Base-only capture omitted lifecycle events: live manifest reports Device27/28/29v2 and Context30/31/32v0 require Resource0x40 or LongHaul0x800. Therefore PID4 DMA headers cannot directly map owner. Existing QueuePacket178 submit events consistently associate0xffffe302610e6de0 withPID1552(3354),0xffffe3028f8e3250 withPID19212(5396),0xffffe3028fb6cb30 withPID11192(3099). Priority21 also associates the latter two PIDs once each.

Read-only Get-Process1552 identifies dwm,StartTime epochms1791497890542,earlier than capture. Other two processes already exited,so no live-name claim.5.405ms context is strongly associated with DWM submitter but lifecycle ownership and per-frame association remain unverified. Do not label this WGC copy duration. Next targeted capture should use Base|Resource0x41 and save process inventory during fixture. Normal session not changed by this audit.

## Progressive29 Base|Resource

Own trace stopped;684883events,headerlost0. Saved contemporaneous process inventory: DWM1552,fixture7564,Viewflow6488. Device27v2 maps device→PID;Context30v0 maps context→device/node. Parser snapshots lifecycle mapping at DMA start to avoid retroactively assigning reused pointers; queue-submitter counts are whole-trace observations and may span reused context handles. Existing DWM context has no creation/rundown in this trace and remains submitter-attributed only.

Active fixture context node0 DMA median~0.165ms,P952.702;Viewflow node0 median2.610/P954.878ms;DWM-submitted context5.338/P959.374ms. These are ETW interval observations, not hardware timestamps or per-window copy proof. Viewflow shared device can include several operations. Next relate queue submission→DMA-start delay and capture timing per process; do not assume DWM execution dominates purely from these independently aggregated medians.

Generator900intervals16.020..17.232ms,median16.656/P9516.995. No observed validation reasons. Software feedback80samples median41.097/P9546.803/max65.076ms. Normal guest/host restored, plugin inventory restored. Goal unmet.

## Submission-to-DMA start partition

Extended lifecycle analyzer with QueuePacket178→DmaPacket175 join by context and SubmitSequence, retaining queue/DMA packet types and submitter PID. Context31stop clears ownership/pending queue entries; snapshots at DMA start avoid pointer-reuse relabeling. Dominant pairs both packettype0.

Progressive29:fixture7564 n3605 queue→DMAstart median0.0226/P953.9047/max11.8271ms;DWM1552 n3298 median0.0169/P950.5883/max4.773ms;Viewflow6488 n2946 median0.0142/P950.0536/max28.5429ms. Kernel event timestamps do not by themselves certify hardware execution duration. Typical Viewflow/DWM scheduler queue residence is small, while earlier start-stop intervals are multiple ms. Therefore another priority-only sweep is poorly motivated; investigate actual composition/capture work and GPU scheduling spans, retaining rare long queue tails as separate evidence. No runtime changes this turn.

## DWM phase workload around capture attachment

Offline progressive29-dwm-phase-cost.json aligns DWM-submitted context DMA spans with fixture generation and first capture callback at+5.0945s. Before capture,fixture seconds1-3 show60/61/58DMA starts per second; after attachment seconds6-29 mostly112-120persecond. Sum of matched spans rises from~266-397ms/sec before to~662-789ms/sec after. These intervals can include scheduling/overlap and are not utilization; phase association alone does not identify each packet's purpose or prove a causal double-composition model.

Source inspection finds one CreateForWindow/free-threaded frame pool/StartCapture per Source; inventory keyed by HWND. Run29 logs only initial geometry forid1 at6K, no capture-retry records in inspected matching log. No evidence of duplicate Viewflow sessions for the fixture. Next inspect DWM capture workload or alternative window capture delivery without sacrificing per-window/alpha/snapshot semantics; do not remove a presumed duplicate capture without evidence.
