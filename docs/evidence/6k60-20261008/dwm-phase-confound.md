# Refresh phase confound in opacity comparison

Offline identity-deduplicated analysis `analyze-dwm-phase.py` correlates embedded source generation QPC with nearest sparse desktop DWM timing observation, using `(generation_ticks-vblank_qpc) modulo refresh_period_qpc`. No live mutations or new input. Results retain all valid matched identities and include metadata sample distance.

Run34 transparent:phase median0.204679,1432/1451samples in[0.125,0.25); callback median29.166ms. Run35 opaque:phase median0.222580,1589/1592 in same bin; callback24.363ms. Run36 transparent:phase median0.890548,1493/1540 in[0.875,1); callback17.694ms. Thus the faster transparent reversal also has a substantially different generation phase. Do not use it as an isolated opacity comparison or infer a production transparency optimization.

Nearest metadata can be almost3s away; counters are desktop-scoped, not per-window physical scanout. Results are exploratory correlations, not causal proof. Frame origin and callback are independently recorded CPU clocks; no negative intervals removed. Existing sustained throughput and software feedback analyses remain authoritative and unchanged.

Next reproducible control needs explicit fixture start phase relative to observed DWM period, with recorded actual rather than requested phase, and multiple phases for both opacity values. This improves baseline design only; phase-tuning a synthetic fixture must never be presented as satisfying arbitrary-application latency. Actual transport still requires <=16.7ms full-origin and continuous60fps evidence, including separate photon limits.
