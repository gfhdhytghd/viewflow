# Linux / macOS connection recovery

The previous plugin compatibility repair did not cover the packaged launcher
scripts. The input route was repeatedly exiting because `HLMonitor.set_workspace`
now accepts a selector or workspace object, rather than a table. The named
workspace is now selected with `name:...`; special workspaces use `special:...`.
Both the Python and shell launchers were repaired in source and in the rootless
installed overlay.

The Mac still held the same connection group and device identity as Linux.
Its disk was full: creating temporary directories failed and the app had no
current `connection.json` or input workers. This was not evidence that pairing
credentials had been lost.

The obsolete `Viewflow/run/capture-helpers` executable cache was copied to
`build/pairing-recovery-20261017/mac-capture-helpers-contents.tar.gz` on Linux.
All 1,454 regular file contents were verified against SHA-256 hashes before
their Mac copies were removed. The archive omits extended attributes and is
an executable-content backup, not a signed application distribution.
Pairing state, certificates and the installed app were retained.
Approximately 719 MiB of generated cache was removed; subsequent disk readback
showed approximately 959 MiB available. The Mac remains short of disk space.

After restarting Viewflow in the background, the Mac saved its current group
profile and started its authenticated input server, window workers, clipboard
worker and CoreHID receiver. Linux's cursor peer reached readiness and both
ends exchanged authenticated QUIC clock probes successfully. No re-pairing or
new credentials were necessary.

A second master compatibility issue affected window enumeration: named and
special workspaces no longer necessarily have numeric IDs in `hyprctl` JSON.
Viewport selection now uses workspace selectors when available, retaining the
numeric fallback for older output and ignoring empty workspace entries. The
window inventory worker was restarted without restarting the input route.

Verification passed:

- Autostart configuration and output recovery test.
- Hermetic desktop launcher suite, including updated selector/quiet-command mocks.
- Window viewport selection regressions for named, special, empty and hidden workspaces.
- Lua syntax check and bundle checksum validation.
- Live virtual output workspace readback, Linux cursor readiness and Mac workers.

No input was injected or focus changed for testing. Physical mouse movement,
clicks and gestures remain user-operated acceptance checks.
