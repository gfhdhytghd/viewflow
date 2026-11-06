# Symmetric desktop handoff

## Design (handoff-matrix)

The input-only lane is independent of window, clipboard, HID and atlas video
lanes. Each link has one authenticated, ordered QUIC bidirectional stream and
both endpoints have capture and injection adapters. Device identity, never OS,
selects the dialer and arbitration authority (lexicographically smaller ID).
The existing Linux atlas sender remains a compatibility path; its wire format
and video prerequisites do not change.

The authority serializes ownership changes. A lease identifies the controller,
target and monotonically increasing generation. Local physical edge crossing
requests ownership. A grant enters the target at the reciprocal edge and only
then enables capture. Simultaneous requests have one winner. Input carries the
lease generation; retired generations cannot inject or release a newer lease.
Return, disconnect, adapter loss and ownership replacement release held keys
and buttons and restore local capture. Recoverable injection failures release
only this input lane; window and clipboard workers continue. No frame deadline
or 33 ms timer revokes ownership.

Layout uses logical display rectangles and the existing per-link share_origin.
Only touching edges with a nonempty overlapping interval are eligible. Entry
preserves the position along that interval. Remote motion runs in target-local
coordinates; crossing the reciprocal edge returns to the controller. Return
places the local cursor one logical unit inside its edge. A physical inward
motion rearms the edge; warps and injected events never initiate a capture.

Native adapters distinguish physical and injected events. Windows uses low-level
hook injected flags and an injection marker. macOS uses CGEvent source userdata.
Hyprland uses its physical-device classification and forwarded-motion guard.
A target-wide ownership guard covers all links, not just one connection.
Capturing while receiving is suppressed; an injected cursor at an edge is not
an ownership request. A missing sender or receiver capability disables only that
direction and produces a capability notice.

Keyboard transport is physical evdev key position with explicit up/down events.
Control and GUI remain distinct, including Mac to Mac. Existing configured
Linux/Mac shortcut policy remains on the compatibility path. Scroll uses signed
120 units per detent or signed milli-points for precise input, with explicit
phase/end metadata. Native HID remains on the existing Mac receiver lane.

## Delivery and verification

Implementation phases: design; Linux receiver; Windows sender; Mac sender;
profiles and Mac worker launch; offline tests; native acceptance documentation.
Every phase is committed independently. Native acceptance remains user-operated.
No development check may inject input, change focus, load a plugin or restart a
live service. Offline tests must not open native capture or injection devices.

The final support table will distinguish implemented paths, offline verification,
and native acceptance. Pairing success and generated profiles alone are not
handoff acceptance.
