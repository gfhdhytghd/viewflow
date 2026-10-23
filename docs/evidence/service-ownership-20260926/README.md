# macOS managed service ownership repair

## Failure observed

The previous application left input, window receiver and clipboard services
reparented to PID 1. Their listening ports remained bound. The current
application repeatedly launched replacements, which exited with macOS error 48
(Address already in use), leaving the UI in recovery. Live examples were input
PID 19158, window receiver PID 19159 and clipboard PID 19161.

## Repair

- ManagedWorker supplies VIEWFLOW_OWNER_PID to its services.
- viewflowd, vf-window-peer and vf-clipboard-peer monitor their actual parent.
  Reparenting initiates SIGINT cleanup, followed by SIGTERM after five seconds
  and SIGKILL two seconds later if necessary. Only owner death triggers this
  watchdog; congestion, input timing and ordinary focus changes do not.
- Before starting a managed worker, ServiceOwnership reclaims legacy orphans
  matching the current UID, complete executable path and arguments. It waits
  for exit before binding a replacement, and never reclaims a live parent's
  worker. The app's existing single-instance lock serializes this recovery.
- CLI services without the owner environment variable retain their existing
  lifetime. No listening-port process is killed merely for occupying a port.

## Validation

`python tools/tests/managed-owner-test.py` compiles the production owner module
in an isolated test harness. Real subprocess tests passed on Linux and macOS:
owner alive, owner killed, stubborn child ignoring INT/TERM, and standalone
service surviving the launcher's exit.

`ServiceOwnershipTests.swift` passed on macOS: exact identity selection rejects
other users/configurations/executables and live parents; a real orphaned sleep
process is reclaimed while a matching live child remains running.

Both tests are included in the macOS package build. The Swift application and
three release services compiled and the installed bundle passed deep/strict
codesign verification. The update automatically reclaimed the two remaining
legacy orphans without manual kill commands. The new input/window/clipboard
workers belong to the current GUI, and all three UDP ports are bound by them.
The clipboard peer logged an actual connection. Window rendering and copy/paste
content remain user-operated acceptance; process/listener proof is not content
or presentation proof.
