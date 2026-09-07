# Raw peer cross-host attempt

2026-09-04, Linux `172.16.105.62` to Windows `172.16.105.70:4433`.
The staged 564x262 decorated VFBG frame was sent with fresh one-day test
certificates and mutual TLS. No fixture credentials were used on the LAN.

Earlier attempts timed out before media admission. Windows had explicit
inbound block rules for this test executable. The user subsequently disabled
the Private/Public firewall profiles; Domain remained enabled. Our temporary
rule script failed its original-rule validation before any rule mutation, and
the proposed temporary allow rule was confirmed absent. We did not change
global firewall or UAC settings.

The subsequent receiver ran as PID 21000, Session 1, then exited 1:

```text
Error: media receive error: Receiver(Assembly(Late))
{"visual_verified":false,"pid":21000,"session":1,"exit_code":1}
```

This proves connection/clock/control/media traffic reached receiver admission,
not successful presentation. The unchanged 33,333,333 ns admission budget
rejected the raw frame. Sender later timed out waiting for completion; error
signalling should be improved so rejection is returned immediately.

This used the debug Windows executable recorded in raw-peer-windows-build.md.
The exact timing bottleneck is not yet isolated: do not attribute it solely to
capture, network, or debug-build cost. Capture occurred before the staged-file
send, so this experiment cannot establish capture-to-display latency.

Temporary scheduled task `Viewflow Raw Test pTgxe7-r2` was removed after exit.
Native raw peer was absent; original Deskflow GUI/core remained running.
Temporary logs/artifacts remain under
`C:\Users\wilf\AppData\Local\Temp\viewflow-raw-live-pTgxe7-r2`.
