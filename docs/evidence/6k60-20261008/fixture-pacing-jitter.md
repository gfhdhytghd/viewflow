# Generator cadence audit

Progressive25 interior10-25s has28generated identities absent from published pixel markers. Their next-generation gap median5.848/P9515.331ms versus captured identities15.627/P9530.677ms. Missing-frame Present calls median0.061ms. Missing spacing4-72sequences, not a fixed skip interval. This is consistent with uneven generator cadence and overwrite before capture; not proof of exact DWM/WGC drop mechanism.

Fixture used std::this_thread::sleep_until on a60Hz deadline without a high-resolution timer. Deadline catch-up can yield short gaps after late wakeups despite skipping already expired deadlines. Added opt-in VIEWFLOW_FIXTURE_HIGH_RES_TIMER using CreateWaitableTimerExW high-resolution flag and one-shot relative SetWaitableTimerEx with zero tolerable delay. Same60Hz target and missed-period skip policy; no busy spin or production transport change. Initialization/wait failure explicit, no silent low-resolution fallback. Actual cadence must be measured before claiming improvement.

Microsoft API references: https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw and https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setwaitabletimerex . Live control pending.

## Progressive26 high-resolution live control

Timer initialization explicitly logged.10-25seconds contains900generation intervals: min16.110,median16.665,P9516.998,max17.251ms,zero intervals<8ms or>25ms. Previous25 had898intervals,min0.624,median15.605,P9530.674,max32.391ms,60<8ms and120>25ms. This verifies the corrected fixture cadence rather than assuming target60Hz equals actual60Hz.

1589host markers all match source; zero observed trace drops/foreground changes. Interior5s bins generated300each,accepted297/300/300/299; all published frames accepted.20seconds1196/1200accepted still not uninterrupted60fps. Generation→callback median16.653/P9518.456ms.80software feedback samples median39.926/P9544.044/max111.224ms,clock±0.095ms; includes startup and excludes photons. Improvement cannot be attributed to transport change because only fixture timer changed; older jittered-fixture throughput conclusions require this caveat.

Use high-resolution fixture for subsequent60Hz controls. Normal guest/host restored, plugin inventory restored. Goal remains unmet, with source capture alone roughly one refresh median before transfer/presentation. Next investigate capture/virtual-display phase rather than further optimizing generator beyond measured cadence.
