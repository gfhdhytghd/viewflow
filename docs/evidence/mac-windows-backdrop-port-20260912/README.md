# Mac backdrop port and source settings, 2026-09-12

The Mac presenter now captures the actual host background below each proxy with
ScreenCaptureKit and composites GPU-blurred pixels using foreground alpha.
Captures exclude the proxy and higher windows. The Windows region planner,
motion reserve, per-display cache, immutable output and texture reuse underpin
the Mac implementation. No AppKit material or CPU-derived mask is used.

Linux publishes eight effective Hyprland blur parameters through H.264 SEI:
enabled, size, passes, contrast, brightness, noise, vibrancy, vibrancy_darkness.
Polling runs independently every 500 ms; errors preserve the last valid value.
Mac parameter changes reblur retained captures and reject obsolete GPU results.
Scene flags (including xray and ignore_opacity) are outside this kernel mapping.
Older sources fall back to Gaussian sigma 12 physical pixels unless the custom
kernel environment option is selected.

Validation completed:

- Portable recipe parsing test, Rust native-window tests (six library tests and
  one source binary test), and Linux source build passed.
- Mac native build, presenter tests, and codec self-tests passed, including SEI
  compatibility with NV12 and BGRA decode paths.
- Gaussian reference check measured sigma 12.090 with maximum channel error 1.
- Earlier captured composition evidence contained 112592 clear pixels with no
  opacity violations; mean alpha formula error was 0.475 byte units.
- Signed application passed deep strict codesign verification after deployment.
- Both live Mac presenters logged enabled=1, size=5, passes=4, contrast=0.891600,
  brightness=1.000000, noise=0.011700, vibrancy=0.169600, darkness=0.000000,
  source=hyprland. Live Linux getoption confirmed size=5 and passes=4.
- Temporary image export arguments were removed from the receiver configuration.

No mouse/keyboard injection or focus testing was performed. Physical interaction
acceptance remains user-operated. Live configuration was read, not modified for
testing; hot-update behavior was validated through the implementation tests.
