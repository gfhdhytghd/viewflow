# Explicit zero capture minimum interval control

configureCaptureInterval now accepts explicit VIEWFLOW_WGC_INTERVAL_US=0 in
addition to1000/4000. Missing/other values keep the current API behavior. Default
production environment remains4000. Microsoft documents the property but gives
no latency guarantee or useful zero-value semantics on the current reference:
https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval
The experiment therefore relies on actual setter/getter and frame measurements.

Windows Release build passed. physical-pixel-progressive5 used the same SHM2,
first-commit measurement and temporary5ms deadline setup asprogressive4, changing
only the requested capture minimum interval. Runtime logs verify requested_us=0,
before_100ns=160000,after_100ns=0.1548host pixel markers all match; zero upload
recoveries, no foreground change or reported trace drops. Source marker gaps5.
Five full6K accept intervals287/294/285/295/292frames over~5s; not continuous60fps.

80same-frame first-commit feedback samples: generation→feedback median39.712ms,
P9550.170,min25.913,max294.878ms. The long tail remains in the data. Same-frame
median generation→callback15.823ms,callback→host accept-end9.611ms,
accept-end→feedback13.410ms. Prior4ms run had21.113/9.821/9.370ms respectively.
Different generation/composition phases may explain some change; one sequential
control is insufficient for attributing the entire difference to interval0.
No photon evidence and no<=16.7ms achievement. Do not promote zero as default.

Original host/guest binaries and wrappers restored; service active, standalone
plugin unloaded, exact before/after plugin inventory equal. Native backup moved
to build/ivshmem-backup. No display-refresh, driver, VM reboot, input or focus
changes. Existing low-rate DWM timing records have suspicious call-count-like
refresh/frame counters and displayed0; they cannot yet establish real refresh
phase. Any further phase investigation must validate actual timestamps first.
