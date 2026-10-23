# Window mesh deployment, 2026-09-10

This is a window-sharing transport setup. The existing desktop cursor/HID and
clipboard services retain their own connections and ownership. No live input,
focus, lock-screen or gesture test was synthesized.

| Direction | Endpoint and geometry | Verified state |
| --- | --- | --- |
| Linux → Mac | Mac UDP 44220, scale 2, origin -3072,-390 | Real Linux windows, hardware decode and completed Metal submissions |
| Windows → Mac | Mac UDP 44221, scale 4; Windows capture rectangle 0,0,6144,3456 | Real WGC fixture/native-window frames decoded at 2624x1280, then window withdrawals; actual presenter enabled |
| Mac → Windows | Windows UDP 44221, scale 1; source scale 2 | Generated H.264 crossed the paired network and decoded through 64x64/80x64 resize; real Mac capture awaits Screen Recording |
| Mac → Linux | Linux UDP 44222 test endpoint, common mesh pairing | Generated Mac H.264 decoded on NVIDIA GPU through 64x64/80x64 resize; temporary listener stopped after validation |
| Linux ↔ Windows | Existing desktop route is independent | Not replaced or retested by this work |

The Windows source rectangle comes from the interactive session's real DISPLAY5
monitor, not SSH Session 0's synthetic 1024x768 display. Scale values are per
endpoint and are not a unified physical display-coordinate model. Mac→Windows
currently presents source pixels directly at scale 1; physical point-size parity
and window placement still need user acceptance.

## Runtime ownership

- Mac `org.viewflow.window-presenter` owns the existing Linux listener.
- Mac `org.viewflow.mesh-presenter` owns the Windows listener, using
  `~/.config/viewflow/window-mesh/receive.json`.
- Mac `org.viewflow.mesh-source` owns `macos-window-source.py`, its source template
  and per-window children. It waits locally on `permission_required` without
  interrupting either receiver.
- Windows interactive scheduled tasks `ViewflowWindowsMacSource` and
  `ViewflowWindowsMacReceiver` run the connecting WGC source and listening native
  presenter under `C:\Users\wilf\Viewflow\windows-macos-20260910`.
- Windows UDP 44221 has a program-scoped inbound rule for this window peer.

The source's stable permission identity is
`/Users/linhaikuo/Applications/Viewflow Window Sharing.app`, bundle identifier
`org.viewflow.WindowSharing`. Current readback reports Screen Recording false,
event posting true. The source app was not replaced during receiver-only NV12
optimization; changing an ad-hoc signed app unnecessarily could disturb its OS
permission identity. The user must grant Screen & System Audio Recording in
System Settings before real Mac window capture can be accepted. A generated
fixture is not evidence of that permission or of real Mac capture.

## Three-device connection preparation

A fresh common CA and distinct Linux, Mac and Windows leaf identities were
prepared for the mesh. Each device receives only its own leaf/private key and
the public CA. The CA private key remains in private local state and is absent
from evidence. Names are `viewflow-mesh-linux`, `viewflow-mesh-macos` and
`viewflow-mesh-windows`. The live Linux→Mac route still uses its existing pairing;
it has not silently been migrated to the new CA or to the Windows scale-4
listener. A common CA alone is not proof that all six directed routes work.

Before enabling the remaining routes, assign receiving endpoints with the right
origin/scale and verify that only native source windows enroll. Windows excludes
Viewflow window classes; the Mac supervisor excludes all Viewflow bundle IDs and
presenter executable names, including presenters owned by other connections.
A window closes independently of unrelated routes. Five-second QUIC keepalive
preserves quiet/empty desktops, and the integration test covers data transfer
after multiple transport idle periods without using desktop input.

## Evidence boundaries

The Windows→Mac WGC probe used an existing nonactivating, automatically exiting
capture fixture; its scheduled task was removed after the test. Mac→Windows used
generated VideoToolbox H.264 through the actual TLS endpoints. Both receivers
were returned to real presentation mode afterward. Real input, real Mac capture,
mixed-scale placement and visual blur acceptance remain user-operated.


## Linux receiver preparation and network validation

The Linux receiver was rebuilt separately at `build/window-mesh-linux` in Release
mode; both native CTests passed. A temporary Linux `--validate` endpoint on UDP
44222 accepted the Mac-generated fixture with the **common mesh CA and Linux
certificate name**. It logged NVIDIA GPU decoding and four frames per fixture
sequence including resize. No proxy windows or desktop input were created. The
sender and temporary listener were stopped after the eight-second test.

`prepared-mesh.json` identifies the staged production Linux receiver and the
Mac/Windows source configurations. All three configurations were validated by
the peer executable on their target operating systems. The new production
routes are prepared, not running; Mac real capture remains explicitly deferred.
Linux uses scale 2 for Mac source pixels. Windows→Linux placement still needs an
intentional source rectangle and receiving scale before enabling that route.

Public certificate readback from Mac and Windows matches the provisioned leaves;
all three leaf names and chains verify against the common CA. Public PEM hashes
and verification results are in `mesh-public-identities.json`. No key material is
included. PowerShell inventory attempts timed out; those were cancelled and
configuration/log reads used SFTP and direct native validation instead. A later
direct `schtasks /Query` readback succeeded: both owned tasks report running in
`windows-mesh-tasks.json`. This proves task state, not input execution.


## Persistent Windows startup correction

A later authoritative task XML read found that both Windows mesh tasks had empty
trigger lists, default battery stop conditions, and no explicit unlimited
execution duration. They would not provide the intended persistent login-time
connection setup.

Both existing task definitions were updated in place, retaining their
InteractiveToken principal, least-privilege behavior, executable action and
IgnoreNew instance policy. They now have a logon trigger for the same user,
`ExecutionTimeLimit=PT0S`, start-when-available enabled, battery start/stop
restrictions disabled, and Task Scheduler failure retries at one-minute intervals
(up to 999 attempts). This retry is for a failed task process; normal QUIC
reconnection continues inside the peer without waiting a minute.

Exported XML readback verified every setting, and both tasks still reported
running after the update. `windows-persistent-tasks.json` records the checked
values. Mac's three owned LaunchAgents already had RunAtLoad and KeepAlive
with a three-second throttle. No login, reboot, power transition or desktop
input was synthesized, so those physical transitions are not claimed as tested.
