# Bounded GPU/composition ETW recording

run-progressive9-etw.py starts an independently named WPR instance Viewflow6KProgressive9 using installed GPU and DesktopComposition profiles in memory mode; named stop in finally avoids manipulating other WPR instances. Runtime status confirmed recording and zero dropped events at18seconds (not final loss proof). Recording successfully stopped; readback confirms WPR no longer recording.

Guest artifact C:\Users\wilf\Viewflow\progressive9.etl is1,178,599,424bytes. Keep large raw artifact outside repository. tracerpt summary extraction started; inspect its live process/handle and final report before assuming completion or no event loss.

Full workload/control tag physical-pixel-progressive9 retains progressive8 settings plus ETW. No observed foreground changes, source async trace drops0.1070host pixel markers all match. Reception5second intervals only~39–42fps;77software feedback samples median47.642ms,p9560.771ms,max145.541ms. GPU observation median5.044ms and post-observation-to-WGC17.355ms over1438matched6Kframes. Trace adds substantial observed load relative to previous run; do not promote as optimization baseline or infer causality from individual percentile differences.

Runner exit0; banks recovered with both endpoints excluded, guest/native/wrapper/probe and host hashes restored, plugin inventory exact before/after. Host backup moved to build/ivshmem-backup/pixel-progressive9-native.backup. No injected input or focus. Goal unmet. Next inspect ETW coverage/loss and select bounded time windows for GPU/composition event attribution; avoid retaining this heavy recording configuration for future performance comparisons.

## Completed summary audit

tracerpt completed exit0:1124buffers,20,938,664events,0reported events lost,56second elapsed trace. It warned that some event schemas did not match; zero transport loss does not imply successful schema decoding. Raw summary saved as progressive9-etw-summary.txt. About13.64million events are syscall entry/exit, showing that built-in verbose profiles include substantial unrelated kernel traffic. Future recording should use selected provider/event keywords rather than these broad profiles.

DWM provider is present in summary, including1992event385(SCHEDULED_COMPOSITION_REASON) and1648event304(ETWGUID_PRESENT) records. Nevertheless Get-WinEvent FilterHashtable(provider name plus selected event IDs) returned NoMatchingEventsFound. That query must not be interpreted as absence: decoded summary contradicts it. Initial Get-WinEvent events reported empty ProviderName/Id0. Next use a native EVENT_RECORD consumer with provider GUID/EventDescriptor filtering and TDH metadata, preserving raw payload on schema failure, instead of assuming Event Log query supports this ETL correctly.

Installed Capture-Server manifest has only CAPTURE_STARTED/STOPPED events1/2 with processId; not a per-frame timing source. Selected DWM schemas saved progressive9-dwm-schema.json; RT capture253–255have empty manifest templates, so do not invent fields. All parsing processes from this turn completed; normal stream untouched.

## Native raw-event extraction

Built etl_reader.cpp with MSVC19.44/WindowsSDK via standalone CMake (recipe etl-reader-CMakeLists.txt). Native OpenTrace/ProcessTrace uses EVENT_RECORD and RAW_TIMESTAMP, filters actual DWM provider GUID and event descriptor IDs, retains complete hex payload and records TDH property schema. ProcessTrace status0,total20,938,664 matches tracerpt;21,820selected events. Header QPC frequency10,000,000,clock1,reported lost0. Reader metadata and selected payloads saved as progressive9-dwm-{metadata,raw}.txt. Initial PowerShell stderr-as-error invocation terminated; verified no reader remained before rerunning via cmd redirection, which completed successfully.

analyze-dwm-waits.py restricts events to fixture generation interval and pairs matching PID/TID start/stop.1788frame-processing spans:median3.476ms,p955.368ms;1787wait-for-work spans:median12.134ms,p9521.008ms;1787wait-for-vblank spans:median0.066ms,p9515.789ms. All decoded vblank sleep flags/values0/0. Render/present scopes overlap and must not be added. One unmatched end at interval boundary retained as diagnostic count.

This identifies the dominant observed compositor-thread wait category, NOT a causal per-window capture delay. ETW-heavy run is perturbed; no direct association between a particular pixel-marked window and each DWM frame established. Do not patch a global sleep based on these numbers. Next join source submission/GPU/callback QPC with per-thread frame boundaries and surface/update events to determine whether this window consistently misses a composition opportunity, and validate any resulting hypothesis with low-overhead instrumentation.

## GPU/compositor temporal join and surface expansion

analyze-gpu-dwm-capture.py joined1438pixel-identified6Kframes to DWM PID1552/TID1612 frame-start timestamps. Median observed-GPU-to-next-frame-start5.620ms; next-frame-start-to-callback15.054ms. Negative latter values retained(min-18.472ms), showing that the nearest temporal frame start is not necessarily the frame that captured this window. No causal attribution or sum-of-medians claim. Heavy ETW overhead persists.

Expanded native reader to surface-update/render events; rebuild and ProcessTrace completed successfully. Event196 exposes luidSurface,bindId,PresentCount,fenceValue plus composition flags; event183 exposes visual/surface/source pointers and rectangle. Raw events and TDH schema saved progressive9-dwm-surfaces*.txt. First four196fields decoded only after confirming nested LUID consists of two32bit parts; inventory in progressive9-surface-inventory.json is NOT HWND attribution. Next correlate actual application swapchain identity/PresentCount to a specific surface before interpreting frame selection delay. Runtime transport unchanged.

## Keyword-limited trace and actual PresentCount

Reused existing VIEWFLOW_FIXTURE_MEDIA_TRACE (GetLastPresentCount with HRESULT), no duplicate instrumentation added. run-progressive10-etw.py uses unique logman session Viewflow6KProgressive10, DWM provider keyword0x80 level5, QPC clock,64KiB buffers16–64. Keyword verified against installed event definitions for10/12/196/385. Session stop completed and ETL size2,228,224bytes versus1.18GB broad trace. Existing system trace sessions untouched. Native extraction succeeded.

analyze-surface-capture.py matches actual successful GetLastPresentCount to event196, generated QPC to pixel marker, source capture identity to WGC entry, and restricts both transport dimensions to6144x3456. Candidate LUID0x4028a38/bind1 yields254records, no repeated-count ambiguity; no other surface candidate yields matches. Median generation-to-surface-update7.909ms,update-to-callback12.546ms,p9516.609ms. Candidate attribution is supported by counts/timing but not independently HWND-bound; do not label proven per-window mechanism. No negative intervals in this candidate.

Run invalid for sustained6K performance: foreground changes1; later accept extents6016,5888,5120wide. Only248host pixel markers (all matched),15software feedback samples. Do not infer speedup from this partial/confounded workload. Normal guest/native/probe/wrapper and host restored with runner checks; plugin inventories identical; coordinated bank recovery succeeded. Host backup moved to build/ivshmem-backup/pixel-progressive10-native.backup. No input/focus injected. Goal unmet.

## Surface-containing DWM frame partition

Extended analyze-surface-capture.py to associate event196 with the currently open event10/12 frame span on the exact same PID/TID. Match frame-end by start identity, not nearest timestamp. All254candidate6Ksurface updates have containing frame-end records. Update-to-frame-end median3.3225ms,p955.7104ms,max9.2792ms; frame-end-to-WGC-entry median9.0759ms,p9511.6465ms,min5.2784ms,max14.776ms. This more specific association avoids the prior nearest-frame-start heuristic. Surface HWND identity caveat and run10foreground/extent-confounding remain.

DWM event12 is CPU frame-processing completion, not a GPU fence/display event. Remaining9ms may include GPU queue/copy and capture delivery; do not call it exclusively callback-thread delay. It also cannot be fixed just by reducing the measured3msCPU frame scope. Repository search found no existing SetGPUThreadPriority or GPU process scheduling priority control in the Windows paths; a bounded capture-device priority experiment may be justified only after confirming capability/scope and preserving default behavior. No production mutation or live input in this analysis turn.

## Progressive27: corrected cadence, light DWM trace

Only DWM keyword0x80, own Viewflow6KProgressive27 session stopped in finally. High-resolution60Hz fixture, SHM2 two bands, completion notification, async host logs. Generator10-25s900intervals,min16.119/median16.676/P9516.952/max17.250ms. Zero observed foreground changes or host trace drops.1542host markers all match.80software presentation samples median39.847/P9544.051/max93.972ms,clock±0.092ms. No goal completion.

Actual DXGI PresentCount plus time consistency gives candidate surfaceLUID0x9e3adfd,bind1,1545matches,noambiguouscounts. Same-frame partitions: generation→surfaceupdate median4.743/P955.126ms; update→callback11.502/13.540ms; update→DWM CPU frame end3.395/4.802ms; CPU frame end→callback8.060/9.114ms. Surface remains candidate without independent HWND binding; CPU frame end is not GPU completion. Do not sum independent medians as an exact decomposition or call the8ms pure notification latency.

This unconfounded-cadence trace supports substantial delay after DWM CPU frame processing. Next distinguish GPU composition/capture copy from WGC notification using targeted GPU events with low volume; broad syscall-heavy trace remains unsuitable. Both normal endpoints restored by runner, plugin inventory restored, named trace stopped. No input/focus operations.
