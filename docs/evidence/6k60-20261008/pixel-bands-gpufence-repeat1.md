# Full6K GPU completion observation repeat

Analyzer now explicitly requires both source callback extent and published atlas extent6144x3456, reports excluded extents and matched capture span. Reanalysis of previous gpufence1 confirms61full6K samples but only1115.1773ms coverage; previous values were not cropped-frame contamination, just a short unrepresentative interval.

Repeated unchanged candidate with unique tags after optional quiet-window question remained unanswered. No assumption of user inactivity; live observations determine validity. physical-pixel-bands-gpufence-repeat1 has1599matched full6K samples spanning26718.3322ms, no foreground change, no zero/non6K residency flagged, no reported trace drops, exact plugin inventory restored. GPU probe reports1800observed, pending0,dropped0. All1599host markers matched source,1597unique sequences,2duplicates and7gaps.

Generation→CPU-observed-GPU-completion median2.3358ms,P955.3178ms,max16.1195ms. Observed-GPU→WGC-entry median14.4983ms,P9517.4916ms,min6.3647ms,max35.0491ms. This is a same-frame positive lower bound on actual preceding-draw-completion→callback delay, because CPU polling can only observe completion late. It does not distinguish DWM composition, WGC internal GPU work or event scheduling; do not call it exact compositor latency. Generation→WGC-entry median16.5449ms.

80generation→Waylandfeedback samples median42.038ms,P9555.497ms,min29.102ms; not photons. Five accept intervals297–301frames/~5s (~59.3–60.1fps), not proof of continuous unique60fps. Goal remains unmet.

Windows wrapper/probe/native and Linux binary restored with runner checks; receiver active; standalone plugin unloaded and exact inventory preserved. Backup moved to build/ivshmem-backup/pixel-bands-gpufence-repeat-native.backup. No input/focus operations. Current WGC getter40000ticks confirms4ms requested minimum. Next controlled change: test1ms WGC minimum while holding fixture60Hz and transport options fixed; do not repeat virtual120Hz configuration changes with prior known drawbacks.
