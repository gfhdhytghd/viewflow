# macOS shutdown and restart exit recovery — 2026-09-13

The user reported that Viewflow repeatedly prevented system restart by failing
to quit. The old running application reproduced the failure after a normal
NSRunningApplication termination request: its child services stopped, but the
GUI remained alive. A passive `sample` showed `_handleAEQuit` →
`-[NSApplication _shouldTerminate]` → nested AppKit/CFRunLoop event waiting.

The delegate returned `terminateLater` and scheduled a default-mode Timer,
then dispatched its work through an extra main-actor Task. AppKit waits in
NSModalPanelRunLoopMode after that reply, so the default timer cannot deliver
the eventual affirmative termination response. See Apple's documentation for
[terminateLater](https://developer.apple.com/documentation/appkit/nsapplication/terminatereply/terminatelater)
and [run-loop modes](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html).

The new TerminationCoordinator uses a selector timer explicitly registered in
the modal mode as well as common modes, invokes cleanup directly on the main
thread, and coalesces repeated termination requests. Worker state is inspected
without depending on a queued terminationHandler. Explicit application exit
starts with interrupt for normal peer cleanup, escalates still-running owned
workers to TERM at two seconds and KILL at four, and returns the termination
reply by six seconds if an OS/native cleanup thread remains stuck. These are
application-exit operation watchdogs, not normal-stream performance cutoffs.

The HID relay now polls both its stdin and owner socket. Previously, an idle
SSH stdin could keep the relay blocked even after the GUI closed its socket.
It now reads the owner's final result or exits on owner EOF without waiting
for another physical input event.

## Verification

- Dedicated native tests passed: only the modal run-loop mode was pumped;
  the old default-mode timer stayed unfired while the new completion ran;
  repeated quit did not replace the pending completion; a child ignoring
  INT/TERM was reaped; socketpair relays exited on owner result and EOF while
  their stdin writers remained open. No real driver or input injection used.
- Native app built with Swift 5 language mode / arm64 macOS 13 target. The
  existing HID timestamp normalization change was preserved in TrackpadBridge.
- Packaging tests: 10 run, nine passed and one platform skip. Diff whitespace
  checks passed. Existing permission-delegate Swift concurrency warnings remain.
- Installed `/Applications/Viewflow.app` passed deep/strict signature checks;
  existing identity, helper binaries and driver bundle were retained. Main
  executable SHA-256: `1e99172f75d9e2ecc1e2ffae146b60eb20f314a77ea856c7b06b49868f59dfea`.
  Removed the stale embedded main-executable checksum when re-signing; a
  self-referential checksum cannot describe the final resource-sealed binary.
- Real normal quit of the new GUI PID 3636 finished in 3.1955 seconds. GUI,
  window peers 3639/3650, clipboard 3641, and HID relay 3662 were all absent
  afterward. Viewflow was subsequently relaunched in the background.
- The obsolete GUI required TERM during replacement after its quit deadlock
  was sampled. No system reboot, mouse/keyboard injection, or focus test was
  performed. The next user-operated system restart remains the full OS check.

Run the targeted regression tests on macOS:

```sh
swiftc -swift-version 5 -parse-as-library \
  platform/macos-app/Sources/Configuration.swift \
  platform/macos-app/Sources/Processes.swift \
  platform/macos-app/Sources/HIDServer.swift \
  platform/macos-app/Sources/TerminationCoordinator.swift \
  platform/macos-app/Tests/TerminationTests.swift -o /tmp/viewflow-termination-tests
/tmp/viewflow-termination-tests
```
