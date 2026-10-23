# Explicit fixture phase control

Added default-off VIEWFLOW_FIXTURE_PHASE_EIGHTH accepting a single digit0..7, requiring present-zero and high-resolution timer. Reads desktop DWM timing once, computes a target at least two periods ahead and offsets the initial steady-clock deadline; subsequent60Hz pacing and missed-period skipping unchanged. Logs requested fraction, targetQPC,frequency,period. This is fixture reproducibility only, not arbitrary-application optimization or physical synchronization. Windows Release build passed.

Run37 requested1/8 with transparent fixture. Actual matched capture generation phase median0.141943/P950.159349;1394/1407 identities in[0.125,0.25), outliers retained,max0.639531. Requested phase is not exact achieved phase; timer overhead, scheduler and sparse desktop extrapolation remain. Captured identities omit uncaptured generated frames, so phase summary is conditional on capture.

No foreground changes/diagnostic drops;1408host markers match. Interior20s generated1199/accepted1083. Full-origin software feedback n80 median52.175/P9571.445/max89.400ms,clock±0.096797ms. Source generation→callback median30.127/P9533.417ms. No claim of target completion. Next matched phase controls can use same binary/flag with another phase, followed by repeat to assess variability; do not pick a favorable phase as end-state acceptance.

Runner exit0, normal programs restored, exact plugin inventory restored,Linux service active. No production option enabled.
