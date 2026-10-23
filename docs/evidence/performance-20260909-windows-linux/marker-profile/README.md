# Exact fixture marker and native PTS stage pairing

The isolated Linux receiver reads two 3 KiB luma rows from the decoded 6K CUDA image, recognizes the complementary 24-bit fixture marker and logs its actual PTS. The source fixture, observer, full-resolution path and original full-route analyzer are unchanged. This adds synchronous GPU readback overhead, reported separately rather than subtracted. Fourteen source inputs are archived; the release build and two Linux CTests pass.

| Trial | WGC minimum us | FPS | Full P95 upper ms | Draw to WGC copy median / P95 ms | Submit to color median / P95 ms |
|---|---:|---:|---:|---:|---:|
| marker-profile-a1 | default | 52.818 | 75.280 | 24.573 / 25.669 | 21.653 / 27.697 |
| markerinterval-default-a1 | 16000 | 53.929 | 65.903 | 24.480 / 25.065 | 21.487 / 27.451 |
| markerinterval-zero-b1 | 0 | 54.759 | 72.849 | 24.542 / 25.340 | 21.155 / 22.854 |
| markerinterval-zero-b2 | 0 | 59.295 | 61.287 | 24.391 / 25.148 | 21.189 / 23.849 |
| markerinterval-default-a2 | 16000 | 52.338 | 75.430 | 24.494 / 25.318 | 21.536 / 27.698 |

All steady desktop observations match exactly one decoded marker and native PTS; there are no ambiguous marker IDs in these five trials. Capture copy logs are joined by WGC timestamp, while pixel age is established by the decoded fixture identity and fixture QPC. WGC timestamps alone are not treated as pixel birth times. Every raw pair and statistic is retained under transport/runs.

The four interval trials use the same Windows executable, with default/zero/zero/default intervals. Draw-to-WGC-copy median remains 24.39–24.54 ms. Zero interval does not remove this dominant delay. Encoder completion is about 21 ms at the median, Linux decode about 4.5 ms, and transport about 1–2 ms using the sampled clock envelope. Desktop scheduling remains variable; the best individual P95 is 61.29 ms, still above 60. Quantiles are not additive, and these diagnostics do not measure physical scanout.

All source/receiver tasks exit normally, native identities and restored mode values match, and private proxies/compositors/outputs are removed. No production behavior is changed. The full-route archive now contains 106 qualified trials.
