# Source capture-entry accounting

Re-examined progressive16. Callback-QPC aligned5second intervals have successful capture callbacks246,292,280,279, versus generated294,301,291,292. Only1callback in the first interval and0in later intervals lacked any selected shared-capture identity across collected logs. Clock-bin boundaries are not exact same-frame matching, so differences are approximate. Successful-capture-to-source-selection is not the main observed omission point in the later intervals.

Found a diagnostic blind spot: band_pool.copy returning no staging snapshot exits callback before profile_capture logging, without drop attribution. Added metrics-gated profile_capture_entry before source mutex and profile_capture_drop reason=band_pool_busy after unlocking on failed band allocation. Existing asynchronous bounded trace mode is used in controls; normal metrics-disabled path adds no trace. No scheduling/copy/ownership changes. The entry trace itself is diagnostic overhead and must be considered in comparisons.

Windows Release viewflow_windows_reverse build passed and diff whitespace check passed. Only build-16k experimental binary updated; normal runtime not deployed/restarted this turn. Next bounded run distinguish delivered-but-pool-busy from absent delivery and source selection before deciding on staging-pool or capture changes. Full6K60/16.7ms goal remains unmet.

## Live progressive17 result

Metrics build temporarily deployed, normal endpoints restored after runner exit0. No foreground changes/non6Kaccept intervals/async trace drops. Total1407capture entries, zero band_pool_busy records. Interior10–15s294entries/294successful/294published/294hostaccepted;15–20s294across all stages;20–25s298across all stages. All886observed callbacks in those15seconds propagated without internal omission. Corresponding generator-clock bins299,299,301; counts have boundary caveat but no evidence for staging-pool exhaustion. First5–10sstartup-affected interval225entries,2successfulneverselected,2hostqueuedreplacements remains documented.

1405host markers all match.64software-feedback samples median47.368ms,p9559.303ms,max101.964ms,clock envelope+/-0.095ms. No16.7ms/photon claim.5second host intervals around59fps early, final223/5803.793msincludes lifecycle effects; no uninterrupted60proof. Corrected retention behavior repeats across a second observed run, but does not fix upstream capture delivery or overall latency.

Exact plugin inventory restored, backup moved to build/ivshmem-backup/pixel-progressive17-native.backup. Normal stream restored. Next target upstream composition/capture delivery; widening staging pool has no evidence-based justification from this run.
