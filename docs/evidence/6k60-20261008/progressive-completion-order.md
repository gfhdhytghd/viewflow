# Harvest completed progressive upload before new announcement

Code inspection of App::run found queue consumption/begin_progressive ran before poll_progressive. begin_progressive cancels the prior upload even if its GPU completion became ready since the previous loop iteration; a new SHM2 announcement does not mean its pixels are already ready. Added nonblocking poll_progressive before queue consumption, retaining the existing post-consumption poll. No waits, presentation of partial pixels, freshness cutoff, input or focus changes. This preserves a completed usable frame before replacing the pending slot.

Linux receiver build passed. Actual --validate receiver processed exactly six complete6Kframes pts1,3,4,5,6,7, retained abort/incomplete behavior and produced no recovery error. Full84934656byte texture correctness test passed, warm generations/shrink-grow/shared registrations and abort snapshot checks passed. These tests verify no observed regression, not a deterministic reproduction of the completion/new-announcement race. Live throughput benefit remains unmeasured; normal deployed binary not replaced in this turn.

Re-examined progressive13 with source-generation-aligned interior windows:5–10s170accepted pixel identities(34fps),10–15s283(56.6),15–20s287(57.4),20–25s288(57.6). Thus low acceptance is not solely the final5second log interval including fixture shutdown. First interior interval may still include service startup/calibration; do not label all loss steady state. Original logs preserved; progressive13-steady-accept.json records scope. No sustained60proof.

Next run matched priority0 baseline with completion ordering fix, count announcements/readiness/accepts byPTS, and distinguish source omissions from local supersession. Do not attribute all prior losses to this code issue without that evidence. Goal remains unmet.

## Bounded live run progressive14

Temporary deployment tested with explicit GPUpriority0, other control settings unchanged. Runner exit0, guest/host/probe/wrapper restored with coordinated bank recovery; exact plugin inventory restored.1557host markers all match, foreground changes0, async trace drops0, all accept intervals6144x3456.80software feedback samples median47.325ms,p9557.970ms,max105.793ms,clock envelope+/-0.099ms. No photon measurement or achieved target.

New analyze-frame-accounting.py joins generation-relative interior5second windows to published PTS, host announcement/readiness/accept stage sets.5–10s297published/290accepted;10–15s295/280;15–20s299/298;20–25s299/297. Every ready identity was accepted. Missing published identities all had host announcements but no ready stage. Source also omits some generated sequences. Last two intervals better than older run13's300/287 and300/288, but priority differs(0vs7), phases/load differ, and middle interval still loses15. Do not infer stable causal improvement from these runs.

Remaining failure localized to announced-to-ready stage; next instrument queued replacement versus active upload supersession/abort explicitly rather than assigning all losses to one mechanism. Runtime normal binary remains restored; experimental corrected binary retained in build. Backup moved to build/ivshmem-backup/pixel-progressive14-native.backup.

## Cancellation attribution and bounded queue repair

Added default-off HOST_FRAME_TRACE stages superseded_active/superseded_queued/producer_aborted/replaced_by_ordinary. Bounded progressive15 run: all51announced-but-not-ready identities in four5second interior intervals attributed to superseded_active(14,11,13,13), zero other recorded reasons. No foreground/extent/async-trace disturbance;1556host markers matched.80software samples median41.076ms,p9549.819ms;not goal success. Normal endpoints restored, plugin inventory exact; backup moved to build/ivshmem-backup.

Implemented queue-selection change: when a lane has an active progressive frame whose producer has completed, leave the latest waiting raw frame queued and continue nonblocking GPU polling. Reader still replaces that single waiting slot with newest arrivals. This prevents cancelling a source-complete upload just because another generation was announced, without accumulating an unbounded queue or waiting synchronously. Incomplete producer frames retain prior supersession behavior, aborts retain snapshots. Both lanes continue polling. Source-complete status is not GPU-complete status and does not prove a bounded wall-clock duration in a GPU failure.

Build passed; actual6Kreceiver fixture validation checked separately. New policy not live-tested or normally deployed yet; next matched run must quantify throughput AND latency because finishing older work can trade freshness for throughput. Remaining source omissions/capture latency still prevent full goal completion.

## Complete-source upload retention live run progressive16

New policy temporarily deployed with same explicit GPUpriority0 and previous instrumentation. No foreground changes/non6Kintervals/async trace drops.1388host pixel markers all matched. Interior10–15s293published/293ready/293accepted;15–20s279/279/279;20–25s279/279/279. All851published identities across those15seconds survived locally, with zero active supersessions, queued supersessions or producer aborts recorded there. Earlier5–10s startup-affected interval had2queued replacements and2ready-not-accepted identities; retained in accounting. Previous progressive15 had51active supersessions across four interior intervals. Mechanism change is supported by per-identity reason records, but broader throughput/latency causality remains affected by source/load differences.

Source generated301,291,292frames in corresponding5second intervals, publishing293,279,279unique sequences. Thus receiver cancellation is no longer the only bottleneck; fixture pacing/source publication itself falls short.80software feedback samples median42.227ms,p9559.319ms,max72.861ms,clock envelope+/-0.091ms. Compared to preceding41.076/49.819ms, no established latency improvement; no <=16.7ms or photon proof. Next optimize generation/capture/publication path while preserving latest-only bounded queue and measure whether retention adds avoidable delay under overload.

Runner exit0, coordinated bank recovery and normal guest/native/wrapper/probe/host restoration completed. Plugin inventory exact before/after. Host backup moved to build/ivshmem-backup/pixel-progressive16-native.backup. Corrected experimental binary retained, normal deployment not promoted. Goal remains active/unmet.
