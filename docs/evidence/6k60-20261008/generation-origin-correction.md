# Generation timestamp boundary correction

Audit found fixture ClearRenderTargetView was called before qpc timestamp embedded in pixel marker. Earlier wording "before GPU submission" was too broad: clear command had already been submitted, though marker update/copy and Present followed. Historical numbers remain measured legacy-origin intervals and underestimate complete command-generation latency by an unmeasured clear-call duration; never retroactively adjust numeric samples or invent the missing duration. This does not change the conclusion that16.7ms is unmet.

Moved qpc marker before first ClearRenderTargetView, added one startup record motion-generation-origin before_clear=1 version=2. Pixel identity and all downstream joins use the same timestamp. Analyzer now detects marker and reports actual origin, explicitly labels unmarked historical logs legacy-after-clear; historical31 output verified labeledlegacy. Future live trials must verify version2 before calling them full-generation software latency. No photon claim.

Windows motion fixture Release build passed. Normal transport binaries and desktop state unchanged; fixture origin runtime verification pending. Reboot authorization remains pending user reply.

## Progressive32 full-origin baseline

Runtime version2 verified, analyzer reports before first ClearRenderTargetView.1525host markers allmatch; no observed foreground or trace-loss flags. Four interior5s bins each300generated/300accepted =1200/1200over20s. Counts alone do not certify every presentation interval; cadence audit has one6.144ms and one27.063ms interval despite900generated intervals10-25s. Full sustained presentation60fps remains unproven.

80same-frame SHM2 software feedback samples median47.311/P9552.675/max69.665ms,clock±0.091ms. Generation→callbackmedian21.043/P9523.565ms. Differences from older-origin runs cannot quantify omitted clear cost because phase/load also differ; do not subtract independent run medians. No16.7ms or photon claim.

Normal guest/host restored by hashes, plugin inventory restored,serviceactive. Full-origin baseline now available for pending high-refresh test; no Windows reboot performed while saved-work confirmation remains unanswered.
