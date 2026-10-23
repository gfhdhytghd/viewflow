# Mac proxy native HID deployment, 2026-09-11

Implemented physical evdev slots -> VFTP ABI 2 -> existing ordered QUIC window
input -> GUI-owned HID socket -> existing DriverKit native multitouch service.
Only multifinger reports use HID; ordinary pointer/buttons stay on Wayland.
Capability negotiation keeps old Mac sources on wheel fallback and avoids
advertising the new tile flag to Windows presenters. See macos-window-sharing.md.

## Checks

- Linux native Release build; reverse wire and geometry CTests: 2/2 passed.
- Strict C++ wire test: native report field encoding, stable IDs, retirement,
  single-finger release, complete chunk roundtrip, skipped offsets and mixed IDs.
- Strict C++ evdev slot test: pressure, major/minor diameters and orientation,
  existing palm/overflow/SYN_DROPPED cases passed.
- Mac native CTests: 10/10 passed. GUI-context full app build and strict signing
  verification passed. Existing Swift delegate isolation warnings remain.
- git diff --check passed.

## Live readback

At 04:17 UTC the three Linux presenters restarted under the existing receiver,
PIDs 3903179, 3903180, 3903181. Each opened /dev/input/event17 without a grab.
All /proc/PID/exe hashes match the installed Linux binary:
60c1040ffc2f13cbea6674a08af04b8bb115e92c61848728f916f7907fbbb7fd.

Mac runtime source-151-433-linux, source-179-23390-linux and
source-227-24963-linux logs report `window HID capability=1`, proving the
capability request reached each source. The Settings runtime helper hash matches
the newly signed build:
f9eba74d7ca029b9db75fbd1ebc6bca8b3be87bbd0b35682e0befc4eb3d9b88e.
The existing GUI app PID 67987 remained running. Whole-desktop input and the
standalone HID forwarding service stayed stopped; Windows stayed paused.

The read-only driver status reports ABI 2, native_profile 1,
native_multitouch_attached true, errors 0, current_contacts 0, button_down false.
Submitted reports stayed at 12098 before and after deployment. No mouse,
keyboard, focus or gesture input was synthesized. Capability and build evidence
are not proof of native scroll acceptance: user-operated scrolling is pending.

## Artifacts and persistence

Live Linux binaries: build/window-mesh-linux/viewflow_linux_reverse and
~/.local/share/viewflow/app/bin/viewflow_linux_reverse.
Mac signed bundle: ~/viewflow-unified-20260910/mac-linux-hid-proxy-r3/Viewflow.app
(and its zip). Latest full app staged at ~/Viewflow-Install/Viewflow.app.
Only the runtime Mac capture helpers were hot-replaced; /Applications/Viewflow.app
was not overwritten. Install the staged app before a later app restart to keep
the updated bundled helper. Existing staged bundles were retained as backups.
