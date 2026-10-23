# Guest DWM timing capability check

Added refresh-period, vblank, compose, displayed, and complete QPC fields to the fixture's existing low-frequency DWM report. Windows Release fixture build passed. Fields follow https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ns-dwmapi-dwm_timing_info . Analyzer: analyze-dwm-phase.py.

Bounded run physical-pixel-progressive7 retained progressive6 settings. Desktop DWM reports a 16.6666 ms period. Vblank advances approximately with elapsed time; compose equals vblank for all seven samples. Relative to query completion, vblank is 2–13 ms in the future in four early samples, 1.7–4.0 ms old in two, and 661 ms old after fixture completion. Displayed QPC stays zero. Refresh and composed counters advance exactly once per five-second query, not about 300 times. These values do not establish a trustworthy per-window display/composition clock; do not use them as an automatic phase scheduler or photon evidence. Future timestamps alone do not establish API failure.

Run validity: one observed foreground change, zero trace drops. Therefore not a clean performance comparison. 1,533 host markers match, zero mismatches; 61 source sequence gaps. Five accept intervals range approximately 51.3–60.0 fps. 80 feedback samples have median43.911 ms, p9555.184 ms, max106.752 ms; clock envelope +/-0.111 ms. These numbers neither demonstrate improvement nor satisfy the target.

Runner exit0; coordinated bank recovery and guest/native/wrapper/probe hash restoration completed. Exact standalone-plugin inventory restored. Host binary backup moved to build/ivshmem-backup/pixel-progressive7-native.backup. No mouse/keyboard/focus injection. Fixture diagnostic binary retained only in experimental build-16k; production transport restored.

Next: use pixel-identity-correlated capture/present timing to test whether callback phase is stable relative to a measured fixture presentation, rather than trusting desktop DWM counters. Any phase experiment must retain a true 60 Hz generated workload and distinguish synthetic-source scheduling gains from general-app latency.
