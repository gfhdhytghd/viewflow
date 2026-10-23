# Local discovery and pairing

Viewflow maintains one connection group: one host and at most two clients.
In **Pairing**, first choose **Host** or **Client**. The host shows the six-digit
code. Each client selects that host from nearby hosts (or enters its address)
and enters the code. The host can use the same code to admit both clients.
Clients cannot join another group until they leave the current group.

The group roster replaces the old independent connection list. The host can
remove a member or dissolve the group; clients can leave. Switching roles
leaves/dissolves the current group. Group links form a star through the host;
there is no separate client-to-client pairing. Each link has its own transport
identity, ports, and display route. Adding a member retains unchanged workers.
Temporary discovery or network failures retain the group and allow recovery.
After startup, paired clients immediately attempt to resume and poll every three
seconds; the host never initiates the pairing control connection. Runtime workers
start after an authenticated client request, without pressing a Connect button.
The disconnect icon pauses connections without deleting pairing; the circular
arrow disconnects and resumes automatic connection. A host resumes by waiting
for the next client request. Restarting the app re-enables automatic connection.

Version 1 pairing records and imported connection profiles are archived locally
on migration. Pair the devices once using the new roles. GUI file import is no
longer available. Existing native driver and OS permission prerequisites remain.

## Network and identity

- Dual-stack discovery advertises IPv4 and IPv6 addresses using `_viewflow._tcp.local.` with a name, platform and stable
  random device ID. Advertisements are hints, not authentication.
- Pairing listens on TCP 44331; if occupied it chooses another available port
  and displays/advertises that port. Manual addresses work without multicast.
- SPAKE2 authenticates the six-digit code. The code is not transmitted, stored
  as a password hash, or used directly as a TLS key. Codes remain available
  until canceled, replaced, the group fills, or the app exits.
- AES-GCM protects the authenticated exchange. Each machine creates and keeps
  its own Ed25519 private key. A pair-specific CA issues client/server
  certificates; the CA signing key is discarded. Existing Rust transports
  continue using mutual TLS. A saved random 256-bit secret authenticates later
  reconnections through the same PAKE channel.
- Only device descriptions, public keys, certificates and the reconnect secret
  cross the pairing channel. Remote peers cannot supply executables, component
  arguments, or runtime configuration files. Local allowlisted recipes select
  those components.
- Normal handshake timeouts and online-code attempt throttling apply only to
  new pairing operations, never to an established media/input session.

The OS firewall must permit local discovery (mDNS UDP 5353), the displayed TCP
pairing port, and the app's QUIC UDP ports. No firewall policy is changed by the
pairing code. Manual address entry is useful when multicast is unavailable; it
cannot bypass a firewall blocking the receiving app.

## IPv6 and display arrangement

Manual addresses accept `[IPv6]:port` and scoped link-local addresses such as
`[fe80::1234%4]:44331` (the scope is the connecting computer's interface index).
Discovery supplies scoped addresses automatically. Resume tries discovered
IPv6 addresses first and falls back to other discovered/saved addresses. The
active numeric address propagates into the native media, window, input and
clipboard configurations; identity and TLS certificates stay unchanged.

The **Displays** page shows the current main display of each group member in
logical pixels. The host can drag client screens or apply exact X/Y values.
Dragging previews four-edge snapping and edge/center alignment with guide lines.
Screens always attach to the nearest available edge, with alignment guides
and a usable shared edge segment. Both dragging and numeric edits are normalized
by the host into one connected, non-overlapping layout. Moving or removing a
bridge screen reattaches any stranded member; saved older gaps are repaired. The host display stays at `(0, 0)`. Positions are saved in the host group,
synchronized over authenticated resume, and expanded into each side's source,
presentation and parking coordinates. Only changed links restart. Clients
show the host's arrangement. This does not reposition physical OS displays or
replace the separate advanced multi-monitor selection workflow.

## Existing platform prerequisites

Pairing does not install drivers, grant OS permissions, or synthesize input.
Linux uses the existing Hyprland capture/input components. macOS still needs
Screen Recording and Accessibility permissions, with DriverKit permissions for
the separate native touchpad path. Windows reverse sharing uses one existing,
enabled virtual display, whose geometry is read without changing the display
layout. If none is present or the choice is ambiguous, receiving windows and
clipboard remain usable and the UI reports the sharing prerequisite. Raw
touchpad-device selection is not part of the new pairing exchange.

Automatic layout assigns distinct display positions to the two client slots.
This does not replace the existing advanced multi-screen topology workflow.

## Build and checks

Linux/Windows build dependencies are in
`platform/desktop-app/requirements.txt`. The macOS build requires PyInstaller
and `requirements-pairing.txt` in the Python environment used to run
`tools/build-macos-app.py`; the resulting helper is self-contained and signed
with the supplied app identity. macOS users do not need Python or Qt installed.

Run the desktop-app unit tests, `tools/tests/unified-apps-test.py`, and the
desktop autostart/window-share tests. Pairing tests use local TCP sockets and
temporary identities, including wrong codes, identity mismatch, saved-peer
reconnection and service restart. Native profile checks use `validate` modes
only. GUI checks render offscreen. None constitute physical mouse, keyboard,
window-drag or cross-device acceptance; those tests remain user-operated.
