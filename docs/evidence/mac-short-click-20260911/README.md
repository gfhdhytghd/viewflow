# Mac short-click loss: synchronized observation

User-operated trial, 2026-09-11 23:39 EDT. No input was injected by the probes.
Window: Linux wall time 1789184344 through 1789184371.5 seconds. Both Mac
listen-only event taps were attached before this trial (HID and session layers).

| Boundary | Down/up pairs |
| --- | ---: |
| Physical evdev BTN_LEFT | 22 |
| Actual sender writes | 22 |
| Driver button-transition counter | 22 (936 to 980: 44 transitions) |
| Mac HID mouse events | 6 |
| Mac session mouse events | 6 |

Physical and transmitted scan timestamps match for all pairs. Press durations
range from 31.9 to 237 ms. Every button-edge report carries one active contact,
and every physical edge was observed while the Mac route was active. Driver
errors remained zero. The six mouse event numbers are 441 through 446; each
has both down and up at both taps, click count 1, flags 0, and Photos as target.
Event 447 belongs to an additional later press outside this bounded trial.

This localizes missing clicks after successful driver report submission and
before the Quartz HID event tap. It does not establish which native report
field or parser behavior causes the loss. Transport ordering, sender edge loss,
missing contact at the button boundary, and application-specific consumption
do not explain these missing pairs. Other latency or compatibility issues may
still exist.

The previously deployed route-query recovery and pressed-pressure mapping did
not resolve the user-observed issue. Do not treat their offline tests or driver
acceptance as physical click acceptance. Next investigation must compare native
physical reports against reconstructed contact states, classification, Size,
pressure and report timing; do not stretch clicks to conceal the discrepancy.

Temporary sender tracing is controlled by VIEWFLOW_HID_TRACE_BUTTONS and records
only button transitions, counts and timestamps, not keyboard content or XY.
